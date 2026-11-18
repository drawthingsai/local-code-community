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

  let identifier: ProjectThreadIdentifier
  let projectTitle: String
  let title: String
  let status: Status
  let lastMessage: String?
}

enum MessagingSendResult: Equatable {
  /// A turn started with the message.
  case started(ProjectThreadIdentifier, title: String)
  /// The message waits behind the thread's running turn.
  case queued(ProjectThreadIdentifier, title: String)
  /// Why it didn't go out.
  case failed(String)
}

protocol MessagingBridgeDelegate: AnyObject {
  /// Every thread, most recently updated first.
  func messagingBridgeThreads(_ bridge: MessagingBridge) -> [MessagingThread]
  /// The workspace's base folder, where a chat's thread starts, whatever is open on the Mac.
  func messagingBridgeWorkspaceFolder(_ bridge: MessagingBridge) -> String
  func messagingBridge(
    _ bridge: MessagingBridge, send text: String, to thread: ProjectThreadIdentifier
  ) -> MessagingSendResult
  /// Starts a thread named `title` with the message.
  func messagingBridge(
    _ bridge: MessagingBridge, startThreadWith text: String, title: String,
    inProject projectPath: String
  ) -> MessagingSendResult
  /// Whether a turn was running to stop.
  func messagingBridge(_ bridge: MessagingBridge, stop thread: ProjectThreadIdentifier) -> Bool
}

/// Lets chat apps work with the app's threads. Each chat is one thread, which its first message
/// starts in the workspace folder, and gets the thread's answer once its turn ends. A chat can also
/// list the threads and their status, send to one, and stop one. Main queue only.
final class MessagingBridge {
  struct Status: Equatable {
    /// Each chat app's connection, nil while it's off or can't start.
    var iMessage: MessagingConnection?
    var telegram: MessagingConnection?
    var discord: MessagingConnection?
    /// The code a new sender messages a bot to pair; it changes once someone uses it.
    var pairingCode: String
  }

  private struct ConversationKey: Hashable {
    let platform: MessagingPlatform
    let id: String
  }

  private struct Conversation {
    var thread: ProjectThreadIdentifier?
    /// The numbers its last list gave.
    var threads = [ProjectThreadIdentifier]()
  }

  /// Sent whole on every change.
  let status: CurrentValueSubject<Status, Never>
  weak var delegate: (any MessagingBridgeDelegate)?

  private static let listedThreads = 20
  private static let typingInterval: TimeInterval = 8

  private let workspace: SQLiteWorkspace
  private let permittedDirectories: PermittedDirectories
  private var subscriptions = [Workspace.Subscription]()
  /// What each chat app's channel was made from, so only a change in Kit makes a new one.
  private var channelConfigurations = [MessagingPlatform: String]()
  private var channels = [MessagingPlatform: any MessagingChannel]()
  private var conversations = [ConversationKey: Conversation]()
  /// The chats waiting for each thread's turn to end.
  private var waiting = [ProjectThreadIdentifier: Set<ConversationKey>]()
  /// Senders already told how to pair, so a stranger gets one answer.
  private var toldToPair = Set<ConversationKey>()
  /// Waited-on threads that had no turn running at the last typing tick.
  private var idleWaitingThreads = Set<ProjectThreadIdentifier>()
  private var typingTimer: Timer?

  init(workspace: SQLiteWorkspace, permittedDirectories: PermittedDirectories) {
    self.workspace = workspace
    self.permittedDirectories = permittedDirectories
    status = CurrentValueSubject(Status(pairingCode: Self.makePairingCode()))
    // Chats keep their threads when the app quits.
    for (platform, key) in [
      (MessagingPlatform.iMessage, "messaging_imessage_chat_threads"),
      (.telegram, "messaging_telegram_chat_threads"), (.discord, "messaging_discord_chat_threads"),
    ] {
      for (id, thread) in workspace.dictionary[key, [String: ProjectThreadIdentifier].self] ?? [:] {
        conversations[ConversationKey(platform: platform, id: id)] = Conversation(thread: thread)
      }
    }
  }

  /// Connects the chat apps that are on in Kit, and follows Kit's changes to them.
  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    let update = { [weak self] (platform: MessagingPlatform) in
      DispatchQueue.main.async { self?.updateChannel(platform) }
    }
    subscriptions = [
      workspace.dictionary.subscribe("messaging_telegram_enabled", of: Bool.self) { _ in
        update(.telegram)
      },
      workspace.dictionary.subscribe("messaging_telegram_bot_token", of: String.self) { _ in
        update(.telegram)
      },
      workspace.dictionary.subscribe("messaging_discord_enabled", of: Bool.self) { _ in
        update(.discord)
      },
      workspace.dictionary.subscribe("messaging_discord_bot_token", of: String.self) { _ in
        update(.discord)
      },
    ]
    updateChannel(.telegram)
    updateChannel(.discord)
    // Messages' database and scripting are only on a Mac.
    #if targetEnvironment(macCatalyst)
      subscriptions += [
        workspace.dictionary.subscribe("messaging_imessage_enabled", of: Bool.self) { _ in
          update(.iMessage)
        },
        workspace.dictionary.subscribe(AppDataDirectory.messages.bookmarkKey, of: Data.self) {
          _ in update(.iMessage)
        },
      ]
      updateChannel(.iMessage)
    #endif
  }

  private func updateChannel(_ platform: MessagingPlatform) {
    let isEnabled: Bool
    // What the channel is made from: the bot's token, or the Messages folder's grant.
    let source: String
    switch platform {
    case .iMessage:
      isEnabled = workspace.dictionary["messaging_imessage_enabled", Bool.self] == true
      source =
        workspace.dictionary[AppDataDirectory.messages.bookmarkKey, Data.self]?
        .base64EncodedString() ?? ""
    case .telegram:
      isEnabled = workspace.dictionary["messaging_telegram_enabled", Bool.self] == true
      source = workspace.dictionary["messaging_telegram_bot_token", String.self] ?? ""
    case .discord:
      isEnabled = workspace.dictionary["messaging_discord_enabled", Bool.self] == true
      source = workspace.dictionary["messaging_discord_bot_token", String.self] ?? ""
    }
    let configuration = "\(isEnabled) \(source)"
    guard channelConfigurations[platform] != configuration else { return }
    channelConfigurations[platform] = configuration
    guard isEnabled, !source.isEmpty else {
      setChannel(nil, for: platform)
      return
    }
    switch platform {
    case .telegram:
      setChannel(TelegramChannel(token: source), for: platform)
    case .discord:
      setChannel(DiscordChannel(token: source), for: platform)
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

  /// Replaces the chat app's channel, stopping the old one; nil turns the app off.
  func setChannel(_ channel: (any MessagingChannel)?, for platform: MessagingPlatform) {
    dispatchPrecondition(condition: .onQueue(.main))
    if let old = channels.removeValue(forKey: platform) {
      old.delegate = nil
      old.stop()
    }
    setConnection(nil, for: platform)
    guard let channel else { return }
    channels[platform] = channel
    channel.delegate = self
    setConnection(.connecting, for: platform)
    channel.start()
  }

  private func setConnection(_ connection: MessagingConnection?, for platform: MessagingPlatform) {
    switch platform {
    case .iMessage: status.value.iMessage = connection
    case .telegram: status.value.telegram = connection
    case .discord: status.value.discord = connection
    }
  }

  /// A turn in the thread ended. The chats that sent to it get its answer.
  func threadDidFinishTurn(_ thread: ProjectThreadIdentifier, title: String, response: String?) {
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
  func threadWasRemoved(_ thread: ProjectThreadIdentifier) {
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

  private func handle(_ message: MessagingIncomingMessage, on platform: MessagingPlatform) {
    let key = ConversationKey(platform: platform, id: message.conversationID)
    let command = MessagingCommand(message.text)
    // Anyone can message a bot, so it answers only the senders paired with Kit's code. iMessage
    // reads only the account's notes to itself, which need no pairing.
    let pairedSendersKey: String?
    switch platform {
    case .iMessage: pairedSendersKey = nil
    case .telegram: pairedSendersKey = "messaging_telegram_paired_senders"
    case .discord: pairedSendersKey = "messaging_discord_paired_senders"
    }
    if let pairedSendersKey {
      var senders = workspace.dictionary[pairedSendersKey, [String].self] ?? []
      guard senders.contains(message.senderID) else {
        let code: String
        switch command {
        case .pair(let argument): code = argument
        case .message(let text): code = text
        default: code = ""
        }
        if code == status.value.pairingCode {
          senders.append(message.senderID)
          workspace.dictionary[pairedSendersKey, [String].self] = senders
          status.value.pairingCode = Self.makePairingCode()
          reply(LocalizedString.forKey("paired_with_local_code_detail"), to: key)
        } else if toldToPair.insert(key).inserted {
          reply(
            LocalizedString.format(key: "send_pairing_code_detail", platform.title), to: key)
        }
        return
      }
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
      conversation.threads = threads.map(\.identifier)
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
        let marker = thread.identifier == conversation.thread ? " ←" : ""
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
      handle(delegate.messagingBridge(self, send: text, to: thread.identifier), key: key)
    case .stop(let number):
      let identifier: ProjectThreadIdentifier
      if let number {
        guard let thread = self.thread(numbered: number, in: &conversation) else {
          reply(LocalizedString.format(key: "no_thread_numbered_detail", number), to: key)
          return
        }
        identifier = thread.identifier
      } else if let thread = conversation.thread {
        identifier = thread
      } else {
        reply(LocalizedString.forKey("nothing_running_detail"), to: key)
        return
      }
      let title =
        delegate.messagingBridgeThreads(self).first(where: { $0.identifier == identifier })?.title
        ?? ""
      if delegate.messagingBridge(self, stop: identifier) {
        reply(
          LocalizedString.format(key: "stopped_thread_detail", Self.displayTitle(title)), to: key)
      } else {
        reply(LocalizedString.forKey("nothing_running_detail"), to: key)
      }
    case .message(let text):
      guard !text.isEmpty else { return }
      let threads = delegate.messagingBridgeThreads(self).map(\.identifier)
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
      conversation.threads = threads.prefix(Self.listedThreads).map(\.identifier)
    }
    guard number >= 1, number <= conversation.threads.count else { return nil }
    let identifier = conversation.threads[number - 1]
    return threads.first { $0.identifier == identifier }
  }

  private func reply(_ text: String, to key: ConversationKey) {
    channels[key.platform]?.send(text, to: key.id)
  }

  /// Saves which thread each chat is in, under its chat app's key.
  private func updateBindings() {
    var bindings = [MessagingPlatform: [String: ProjectThreadIdentifier]]()
    for (key, conversation) in conversations {
      guard let thread = conversation.thread else { continue }
      bindings[key.platform, default: [:]][key.id] = thread
    }
    for (platform, key) in [
      (MessagingPlatform.iMessage, "messaging_imessage_chat_threads"),
      (.telegram, "messaging_telegram_chat_threads"), (.discord, "messaging_discord_chat_threads"),
    ] {
      let threads = bindings[platform] ?? [:]
      guard threads != workspace.dictionary[key, [String: ProjectThreadIdentifier].self] ?? [:]
      else { continue }
      workspace.dictionary[key, [String: ProjectThreadIdentifier].self] = threads
    }
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
    for identifier in Array(waiting.keys) {
      guard let thread = threads.first(where: { $0.identifier == identifier }),
        thread.status == .idle || thread.status == .newReply
      else {
        idleWaitingThreads.remove(identifier)
        continue
      }
      guard !idleWaitingThreads.insert(identifier).inserted else { continue }
      idleWaitingThreads.remove(identifier)
      for key in waiting.removeValue(forKey: identifier) ?? [] {
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
    // The channel tells which chat app the message came from; a replaced one's is dropped.
    guard let platform = channels.first(where: { $0.value === channel })?.key else { return }
    handle(message, on: platform)
  }

  func messagingChannel(_ channel: any MessagingChannel, didChange connection: MessagingConnection)
  {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let platform = channels.first(where: { $0.value === channel })?.key else { return }
    setConnection(connection, for: platform)
  }
}
