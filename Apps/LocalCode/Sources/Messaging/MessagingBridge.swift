import Combine
import Dflat
import Foundation
import Localization
import SQLiteDflat

/// A thread as chat apps see it.
struct MessagingThread: Equatable {
  enum Status: Equatable {
    case idle
    case working
    case incomplete
    case newReply
  }

  let reference: MessagingThreadReference
  let projectTitle: String
  let title: String
  let status: Status
  let lastMessage: String?
}

struct MessagingThreadReference: Hashable {
  /// Standardized, with symlinks resolved.
  let projectPath: String
  let threadId: Int64
}

enum MessagingSendResult: Equatable {
  /// A turn started with the message.
  case started(MessagingThreadReference, title: String)
  /// The message waits behind the thread's running turn.
  case queued(MessagingThreadReference, title: String)
  /// Why it didn't go out.
  case failed(String)
}

protocol MessagingBridgeDelegate: AnyObject {
  /// Every thread, most recently updated first.
  func messagingBridgeThreads(_ bridge: MessagingBridge) -> [MessagingThread]
  /// The workspace's base folder, where a chat's thread starts, whatever is open on the Mac.
  func messagingBridgeWorkspaceFolder(_ bridge: MessagingBridge) -> String
  func messagingBridge(
    _ bridge: MessagingBridge, send text: String, to thread: MessagingThreadReference
  ) -> MessagingSendResult
  /// Starts a thread named `title` with the message.
  func messagingBridge(
    _ bridge: MessagingBridge, startThreadWith text: String, title: String,
    inProject projectPath: String
  ) -> MessagingSendResult
  /// Whether a turn was running to stop.
  func messagingBridge(_ bridge: MessagingBridge, stop thread: MessagingThreadReference) -> Bool
}

/// Lets chat apps work with the app's threads. Each chat is one thread, which its first message
/// starts in the workspace folder, and gets the thread's answer once its turn ends. A chat can also
/// list the threads and their status, send to one, and stop one. Main queue only.
final class MessagingBridge {
  struct Status: Equatable {
    var connections = [MessagingPlatform: MessagingConnection]()
    /// The code a new sender messages a bot to pair; it changes once someone uses it.
    var pairingCode: String
  }

  private struct ConversationKey: Hashable {
    let platform: MessagingPlatform
    let id: String

    /// As kept in the workspace.
    var storageKey: String { "\(platform.rawValue):\(id)" }
  }

  private struct Conversation {
    var thread: MessagingThreadReference?
    /// The numbers its last list gave.
    var threads = [MessagingThreadReference]()
  }

  /// Sent whole on every change.
  let status: CurrentValueSubject<Status, Never>
  /// The thread each chat is in, with its chat app. Sent whole on every change.
  let chatThreads = CurrentValueSubject<[MessagingThreadReference: MessagingPlatform], Never>([:])
  weak var delegate: (any MessagingBridgeDelegate)?

  private static let bindingsKey = "messaging_conversation_threads"
  private static let listedThreads = 20
  private static let typingInterval: TimeInterval = 8

  private let workspace: SQLiteWorkspace
  private let permittedDirectories: PermittedDirectories
  private var subscriptions = [Workspace.Subscription]()
  /// What each platform's channel was made from, so only a change in Kit makes a new one.
  private var channelConfigurations = [MessagingPlatform: String]()
  private var channels = [MessagingPlatform: any MessagingChannel]()
  private var conversations = [ConversationKey: Conversation]()
  /// The chats waiting for each thread's turn to end.
  private var waiting = [MessagingThreadReference: Set<ConversationKey>]()
  /// Senders already told how to pair, so a stranger gets one answer.
  private var toldToPair = Set<ConversationKey>()
  /// Waited-on threads that had no turn running at the last typing tick.
  private var idleWaitingThreads = Set<MessagingThreadReference>()
  private var typingTimer: Timer?

  init(workspace: SQLiteWorkspace, permittedDirectories: PermittedDirectories) {
    self.workspace = workspace
    self.permittedDirectories = permittedDirectories
    status = CurrentValueSubject(Status(pairingCode: Self.makePairingCode()))
    // Chats keep their threads when the app quits.
    for (key, value) in workspace.dictionary[Self.bindingsKey, [String: String].self] ?? [:] {
      let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
      let thread = value.split(separator: "\n", maxSplits: 1).map(String.init)
      guard parts.count == 2, let platform = MessagingPlatform(rawValue: parts[0]),
        thread.count == 2, let threadId = Int64(thread[1])
      else { continue }
      conversations[ConversationKey(platform: platform, id: parts[1])] = Conversation(
        thread: MessagingThreadReference(projectPath: thread[0], threadId: threadId))
    }
    updateBindings()
  }

  /// Whether this device can offer the platform: Messages' database and scripting are only on a Mac.
  static func isAvailable(_ platform: MessagingPlatform) -> Bool {
    #if targetEnvironment(macCatalyst)
      return true
    #else
      return platform != .iMessage
    #endif
  }

  /// Connects the platforms that are on in Kit, and follows Kit's changes to them.
  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    for platform in MessagingPlatform.allCases where Self.isAvailable(platform) {
      let update = { [weak self] in
        DispatchQueue.main.async { self?.updateChannel(platform) }
      }
      subscriptions.append(
        workspace.dictionary.subscribe(platform.enabledKey, of: Bool.self) { _ in update() })
      subscriptions.append(
        workspace.dictionary.subscribe(platform.revisionKey, of: Int.self) { _ in update() })
      if platform == .iMessage {
        subscriptions.append(
          workspace.dictionary.subscribe(AppDataDirectory.messages.bookmarkKey, of: Data.self) {
            _ in update()
          })
      }
      updateChannel(platform)
    }
  }

  private func updateChannel(_ platform: MessagingPlatform) {
    let isEnabled = workspace.dictionary[platform.enabledKey, Bool.self] == true
    let revision = workspace.dictionary[platform.revisionKey, Int.self] ?? 0
    let bookmark =
      platform == .iMessage
      ? workspace.dictionary[AppDataDirectory.messages.bookmarkKey, Data.self]?
        .base64EncodedString()
      : nil
    let configuration = "\(isEnabled) \(revision) \(bookmark ?? "")"
    guard channelConfigurations[platform] != configuration else { return }
    channelConfigurations[platform] = configuration
    guard isEnabled else {
      setChannel(nil, for: platform)
      return
    }
    switch platform {
    case .telegram, .discord:
      guard let token = MessagingTokenStore.token(for: platform), !token.isEmpty else {
        setChannel(nil, for: platform)
        return
      }
      setChannel(
        platform == .telegram ? TelegramChannel(token: token) : DiscordChannel(token: token),
        for: platform)
    case .iMessage:
      #if targetEnvironment(macCatalyst)
        guard let url = permittedDirectories.access(.messages) else {
          setChannel(nil, for: platform)
          return
        }
        setChannel(IMessageChannel(directoryURL: url), for: platform)
      #endif
    }
  }

  /// Replaces the platform's channel, stopping the old one; nil turns the platform off.
  func setChannel(_ channel: (any MessagingChannel)?, for platform: MessagingPlatform) {
    dispatchPrecondition(condition: .onQueue(.main))
    if let old = channels.removeValue(forKey: platform) {
      old.delegate = nil
      old.stop()
    }
    status.value.connections[platform] = nil
    guard let channel else { return }
    channels[platform] = channel
    channel.delegate = self
    status.value.connections[platform] = .connecting
    channel.start()
  }

  /// A turn in the thread ended. The chats that sent to it get its answer.
  func threadDidFinishTurn(_ thread: MessagingThreadReference, title: String, response: String?) {
    dispatchPrecondition(condition: .onQueue(.main))
    idleWaitingThreads.remove(thread)
    guard let keys = waiting.removeValue(forKey: thread) else { return }
    let response = response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text =
      response.isEmpty
      ? LocalizedString.format(key: "turn_finished_detail", Self.displayTitle(title))
      : "\(Self.displayTitle(title))\n\n\(response)"
    for key in keys { reply(text, to: key) }
    updateTypingTimer()
  }

  /// The thread was deleted, or moved to another project. A later thread can get its identifier,
  /// so the chats in it forget it now, and their next message starts a new one.
  func threadWasRemoved(_ thread: MessagingThreadReference) {
    dispatchPrecondition(condition: .onQueue(.main))
    for (key, conversation) in conversations where conversation.thread == thread {
      conversations[key]?.thread = nil
    }
    // No answer comes from it now.
    waiting[thread] = nil
    idleWaitingThreads.remove(thread)
    updateBindings()
    updateTypingTimer()
  }

  // MARK: - Messages

  private func handle(_ message: MessagingIncomingMessage) {
    let key = ConversationKey(platform: message.platform, id: message.conversationID)
    let command = MessagingCommand(message.text)
    guard message.isFromOwner || isPaired(message) else {
      let code: String
      switch command {
      case .pair(let argument): code = argument
      case .message(let text): code = text
      default: code = ""
      }
      if code == status.value.pairingCode {
        var senders = workspace.dictionary[message.platform.pairedSendersKey, [String].self] ?? []
        senders.append(message.senderID)
        workspace.dictionary[message.platform.pairedSendersKey, [String].self] = senders
        status.value.pairingCode = Self.makePairingCode()
        reply(LocalizedString.forKey("paired_with_local_code_detail"), to: key)
      } else if toldToPair.insert(key).inserted {
        reply(
          LocalizedString.format(
            key: "send_pairing_code_detail", message.platform.title), to: key)
      }
      return
    }
    guard let delegate else { return }
    var conversation = conversations[key] ?? Conversation()
    defer {
      conversations[key] = conversation
      updateBindings()
    }
    switch command {
    case .help:
      reply(LocalizedString.forKey("chat_commands_detail"), to: key)
    case .pair:
      reply(LocalizedString.forKey("paired_with_local_code_detail"), to: key)
    case .threads, .status(nil):
      let threads = Array(delegate.messagingBridgeThreads(self).prefix(Self.listedThreads))
      conversation.threads = threads.map(\.reference)
      guard !threads.isEmpty else {
        reply(LocalizedString.forKey("no_threads_yet_detail"), to: key)
        return
      }
      var lines = [String]()
      if case .status = command {
        let working = threads.filter { $0.status == .working }.count
        let newReplies = threads.filter { $0.status == .newReply }.count
        lines.append(
          LocalizedString.format(
            key: "thread_status_summary_detail", threads.count, working, newReplies))
      }
      for (index, thread) in threads.enumerated() {
        let marker = thread.reference == conversation.thread ? " ←" : ""
        lines.append(
          "\(index + 1). \(Self.displayTitle(thread.title)) · \(thread.projectTitle) · "
            + "\(Self.statusTitle(thread.status))\(marker)")
      }
      reply(lines.joined(separator: "\n"), to: key)
    case .status(let number?):
      guard let thread = self.thread(numbered: number, in: &conversation) else {
        reply(LocalizedString.format(key: "no_thread_numbered_detail", number), to: key)
        return
      }
      var text =
        "\(Self.displayTitle(thread.title)) · \(thread.projectTitle) · "
        + Self.statusTitle(thread.status)
      if let lastMessage = thread.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
        !lastMessage.isEmpty
      {
        text += "\n\n" + Self.truncated(lastMessage, to: 1_500)
      }
      reply(text, to: key)
    case .send(let number, let text):
      guard let thread = self.thread(numbered: number, in: &conversation) else {
        reply(LocalizedString.format(key: "no_thread_numbered_detail", number), to: key)
        return
      }
      handle(delegate.messagingBridge(self, send: text, to: thread.reference), key: key)
    case .stop(let number):
      let reference: MessagingThreadReference
      if let number {
        guard let thread = self.thread(numbered: number, in: &conversation) else {
          reply(LocalizedString.format(key: "no_thread_numbered_detail", number), to: key)
          return
        }
        reference = thread.reference
      } else if let thread = conversation.thread {
        reference = thread
      } else {
        reply(LocalizedString.forKey("nothing_running_detail"), to: key)
        return
      }
      let title =
        delegate.messagingBridgeThreads(self).first(where: { $0.reference == reference })?.title
        ?? ""
      if delegate.messagingBridge(self, stop: reference) {
        reply(
          LocalizedString.format(key: "stopped_thread_detail", Self.displayTitle(title)), to: key)
      } else {
        reply(LocalizedString.forKey("nothing_running_detail"), to: key)
      }
    case .message(let text):
      guard !text.isEmpty else { return }
      let threads = delegate.messagingBridgeThreads(self).map(\.reference)
      if let thread = conversation.thread, threads.contains(thread) {
        handle(delegate.messagingBridge(self, send: text, to: thread), key: key)
        return
      }
      // The new thread can get a deleted thread's identifier. A thread deleted where the bridge
      // didn't hear of it, such as in another copy of the app, leaves its chats in it, so those
      // forget it first.
      for (otherKey, other) in conversations
      where other.thread.map({ !threads.contains($0) }) ?? false {
        conversations[otherKey]?.thread = nil
      }
      // The chat's first message, or the first since its thread was deleted. The thread is named
      // after the app rather than its first message, since it holds the whole chat.
      let result = delegate.messagingBridge(
        self, startThreadWith: text,
        title: LocalizedString.format(key: "x_conversations", key.platform.title),
        inProject: delegate.messagingBridgeWorkspaceFolder(self))
      switch result {
      case .started(let thread, _), .queued(let thread, _):
        conversation.thread = thread
      case .failed:
        break
      }
      handle(result, key: key, isNewThread: true)
    case .unknown:
      reply(LocalizedString.forKey("unknown_command_detail"), to: key)
    }
  }

  private func handle(
    _ result: MessagingSendResult, key: ConversationKey, isNewThread: Bool = false
  ) {
    switch result {
    case .started(let thread, let title):
      waiting[thread, default: []].insert(key)
      // A new thread has no title until its first answer.
      if isNewThread {
        reply(LocalizedString.forKey("started_thread_detail"), to: key)
      } else {
        reply(
          LocalizedString.format(key: "sent_to_thread_detail", Self.displayTitle(title)), to: key)
      }
      channels[key.platform]?.showTyping(in: key.id)
    case .queued(let thread, let title):
      waiting[thread, default: []].insert(key)
      reply(
        LocalizedString.format(key: "queued_in_thread_detail", Self.displayTitle(title)), to: key)
    case .failed(let reason):
      reply(reason, to: key)
    }
    updateTypingTimer()
  }

  /// Numbered as the chat's last list was, or as a list now would be.
  private func thread(numbered number: Int, in conversation: inout Conversation)
    -> MessagingThread?
  {
    guard let delegate else { return nil }
    let threads = delegate.messagingBridgeThreads(self)
    if conversation.threads.isEmpty {
      conversation.threads = threads.prefix(Self.listedThreads).map(\.reference)
    }
    guard number >= 1, number <= conversation.threads.count else { return nil }
    let reference = conversation.threads[number - 1]
    return threads.first { $0.reference == reference }
  }

  private func isPaired(_ message: MessagingIncomingMessage) -> Bool {
    guard message.platform.needsPairing else { return false }
    return (workspace.dictionary[message.platform.pairedSendersKey, [String].self] ?? []).contains(
      message.senderID)
  }

  private func reply(_ text: String, to key: ConversationKey) {
    channels[key.platform]?.send(text, to: key.id)
  }

  /// Publishes which thread each chat is in, and saves it.
  private func updateBindings() {
    var bindings = [String: String]()
    var chatThreads = [MessagingThreadReference: MessagingPlatform]()
    // Sorted, so a thread two chats share (as before each chat kept one thread) always shows the
    // same app.
    for (key, conversation) in conversations.sorted(by: { $0.key.storageKey < $1.key.storageKey }) {
      guard let thread = conversation.thread else { continue }
      bindings[key.storageKey] = "\(thread.projectPath)\n\(thread.threadId)"
      if chatThreads[thread] == nil {
        chatThreads[thread] = key.platform
      }
    }
    if chatThreads != self.chatThreads.value {
      self.chatThreads.send(chatThreads)
    }
    guard bindings != workspace.dictionary[Self.bindingsKey, [String: String].self] ?? [:] else {
      return
    }
    workspace.dictionary[Self.bindingsKey, [String: String].self] = bindings
  }

  /// Keeps the typing indicator up in chats that wait for an answer.
  private func updateTypingTimer() {
    guard !waiting.isEmpty else {
      typingTimer?.invalidate()
      typingTimer = nil
      idleWaitingThreads.removeAll()
      return
    }
    guard typingTimer == nil else { return }
    typingTimer = Timer.scheduledTimer(withTimeInterval: Self.typingInterval, repeats: true) {
      [weak self] _ in
      self?.typingTick()
    }
  }

  private func typingTick() {
    // A turn that ends without an answer, as when stopped on the Mac or failing, sends none. A
    // thread seen idle at two ticks in a row ended so; one tick isn't enough, since a turn that
    // just started can take a moment to show as running.
    let threads = delegate?.messagingBridgeThreads(self) ?? []
    for reference in Array(waiting.keys) {
      guard let thread = threads.first(where: { $0.reference == reference }),
        thread.status == .idle || thread.status == .newReply
      else {
        idleWaitingThreads.remove(reference)
        continue
      }
      guard !idleWaitingThreads.insert(reference).inserted else { continue }
      idleWaitingThreads.remove(reference)
      for key in waiting.removeValue(forKey: reference) ?? [] {
        reply(
          LocalizedString.format(key: "stopped_thread_detail", Self.displayTitle(thread.title)),
          to: key)
      }
    }
    for key in Set(waiting.values.joined()) {
      channels[key.platform]?.showTyping(in: key.id)
    }
    updateTypingTimer()
  }

  private static func makePairingCode() -> String {
    String(format: "%06d", Int.random(in: 0..<1_000_000))
  }

  private static func displayTitle(_ title: String) -> String {
    title.isEmpty ? LocalizedString.forKey("untitled") : title
  }

  private static func truncated(_ text: String, to limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
  }

  private static func statusTitle(_ status: MessagingThread.Status) -> String {
    switch status {
    case .idle: return LocalizedString.forKey("idle")
    case .working: return LocalizedString.forKey("working")
    case .incomplete: return LocalizedString.forKey("incomplete")
    case .newReply: return LocalizedString.forKey("new_reply")
    }
  }
}

extension MessagingBridge: MessagingChannelDelegate {
  func messagingChannel(
    _ channel: any MessagingChannel, didReceive message: MessagingIncomingMessage
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard channels[message.platform] === channel else { return }
    handle(message)
  }

  func messagingChannel(_ channel: any MessagingChannel, didChange connection: MessagingConnection)
  {
    dispatchPrecondition(condition: .onQueue(.main))
    guard channels[channel.platform] === channel else { return }
    status.value.connections[channel.platform] = connection
  }
}
