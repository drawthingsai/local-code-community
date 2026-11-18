import Foundation
import SQLiteDflat
import XCTest

private final class FakeChannel: MessagingChannel {
  let platform: MessagingPlatform
  weak var delegate: (any MessagingChannelDelegate)?
  private(set) var sent = [(text: String, conversationID: String)]()
  private(set) var isStarted = false

  init(platform: MessagingPlatform) {
    self.platform = platform
  }

  func start() { isStarted = true }
  func stop() { isStarted = false }
  func send(_ text: String, to conversationID: String) { sent.append((text, conversationID)) }
  func showTyping(in conversationID: String) {}

  func receive(_ text: String, from senderID: String = "42", in conversationID: String = "chat") {
    delegate?.messagingChannel(
      self,
      didReceive: MessagingIncomingMessage(
        platform: platform, conversationID: conversationID, senderID: senderID, text: text,
        isFromOwner: platform == .iMessage))
  }

  /// The texts sent since the last call.
  func takeSent() -> [String] {
    defer { sent.removeAll() }
    return sent.map(\.text)
  }
}

private final class FakeDelegate: MessagingBridgeDelegate {
  var threads = [MessagingThread]()
  var nextThreadId: Int64 = 100
  var isRunning = false
  private(set) var sends = [(text: String, thread: MessagingThreadReference)]()
  private(set) var starts = [(text: String, title: String, projectPath: String)]()
  private(set) var stops = [MessagingThreadReference]()

  func messagingBridgeThreads(_ bridge: MessagingBridge) -> [MessagingThread] { threads }

  func messagingBridgeWorkspaceFolder(_ bridge: MessagingBridge) -> String { "/p" }

  func messagingBridge(
    _ bridge: MessagingBridge, send text: String, to thread: MessagingThreadReference
  ) -> MessagingSendResult {
    sends.append((text, thread))
    let title = threads.first { $0.reference == thread }?.title ?? ""
    return isRunning ? .queued(thread, title: title) : .started(thread, title: title)
  }

  func messagingBridge(
    _ bridge: MessagingBridge, startThreadWith text: String, title: String,
    inProject projectPath: String
  ) -> MessagingSendResult {
    starts.append((text, title, projectPath))
    let reference = MessagingThreadReference(projectPath: projectPath, threadId: nextThreadId)
    nextThreadId += 1
    threads.insert(
      MessagingThread(
        reference: reference, projectTitle: "New", title: "", status: .working, lastMessage: nil),
      at: 0)
    return .started(reference, title: "")
  }

  func messagingBridge(_ bridge: MessagingBridge, stop thread: MessagingThreadReference) -> Bool {
    stops.append(thread)
    return isRunning
  }
}

final class MessagingBridgeTests: XCTestCase {
  private var root: URL!
  private var workspace: SQLiteWorkspace!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    workspace = SQLiteWorkspace(
      filePath: root.appendingPathComponent("config.sqlite3").path,
      fileProtectionLevel: .noProtection)
  }

  override func tearDownWithError() throws {
    workspace.shutdown(flags: .truncate)
    workspace = nil
    try FileManager.default.removeItem(at: root)
  }

  private func onMain(_ body: () throws -> Void) rethrows {
    if Thread.isMainThread {
      try body()
    } else {
      try DispatchQueue.main.sync(execute: body)
    }
  }

  /// The thread each chat is in, as the bridge saves it for the next launch.
  private func savedBindings() -> [String: String] {
    workspace.dictionary["messaging_conversation_threads", [String: String].self] ?? [:]
  }

  private func thread(_ id: Int64, _ title: String, status: MessagingThread.Status = .idle)
    -> MessagingThread
  {
    MessagingThread(
      reference: MessagingThreadReference(projectPath: "/p/app", threadId: id),
      projectTitle: "App", title: title, status: status, lastMessage: "Last \(title)")
  }

  // MARK: - Commands

  func testCommandsParse() {
    XCTAssertEqual(MessagingCommand("fix the build"), .message("fix the build"))
    XCTAssertEqual(MessagingCommand("  /help "), .help)
    XCTAssertEqual(MessagingCommand("/threads@LocalCodeBot"), .threads)
    XCTAssertEqual(MessagingCommand("/LIST"), .threads)
    XCTAssertEqual(MessagingCommand("/status"), .status(nil))
    XCTAssertEqual(MessagingCommand("/status 3"), .status(3))
    XCTAssertEqual(MessagingCommand("/status three"), .unknown("/status three"))
    XCTAssertEqual(MessagingCommand("/new"), .unknown("/new"))
    XCTAssertEqual(MessagingCommand("/send 2 run it\nagain"), .send(2, "run it\nagain"))
    XCTAssertEqual(MessagingCommand("/send 2"), .unknown("/send 2"))
    XCTAssertEqual(MessagingCommand("/stop"), .stop(nil))
    XCTAssertEqual(MessagingCommand("/stop 4"), .stop(4))
    XCTAssertEqual(MessagingCommand("/start"), .help)
    XCTAssertEqual(MessagingCommand("/start 123456"), .pair("123456"))
    XCTAssertEqual(MessagingCommand("/pair 123456"), .pair("123456"))
    XCTAssertEqual(MessagingCommand("/frobnicate"), .unknown("/frobnicate"))
  }

  func testChunksSplitAtBreaksAndKeepCharactersWhole() {
    XCTAssertEqual(FakeChannel.chunks(of: "", limit: 10), [""])
    XCTAssertEqual(FakeChannel.chunks(of: "short", limit: 10), ["short"])
    XCTAssertEqual(
      FakeChannel.chunks(of: "line one\nline two", limit: 12), ["line one", "line two"])
    XCTAssertEqual(FakeChannel.chunks(of: "aaaa bbbb cccc", limit: 9), ["aaaa bbbb", "cccc"])
    XCTAssertEqual(FakeChannel.chunks(of: "abcdefghij", limit: 4), ["abcd", "efgh", "ij"])
    // A family emoji is 11 UTF-16 units; the split moves before it instead of through it.
    let family = "👨‍👩‍👧‍👦"
    let chunks = FakeChannel.chunks(of: "abc" + family + "def", limit: 8)
    XCTAssertEqual(chunks.joined(), "abc" + family + "def")
    XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 11 })
    XCTAssertTrue(chunks.contains { $0.contains(family) })
  }

  // MARK: - Telegram

  func testTelegramDecodesMessagesAndRejectedTokens() throws {
    let data = Data(
      """
      {"ok":true,"result":[
        {"update_id":7,"message":{"message_id":1,"chat":{"id":-55,"type":"private"},
          "from":{"id":42,"is_bot":false,"username":"me"},"text":"/threads"}},
        {"update_id":8,"message":{"message_id":2,"chat":{"id":-55,"type":"private"},
          "from":{"id":43,"is_bot":true},"text":"bot talk"}},
        {"update_id":9,"message":{"message_id":3,"chat":{"id":-55,"type":"private"},
          "from":{"id":42,"is_bot":false},"photo":[]}}
      ]}
      """.utf8)
    let updates: [TelegramChannel.Update] = try TelegramChannel.decode(data)
    XCTAssertEqual(updates.map(\.updateId), [7, 8, 9])
    let messages = updates.compactMap(TelegramChannel.incomingMessage(from:))
    XCTAssertEqual(
      messages,
      [
        MessagingIncomingMessage(
          platform: .telegram, conversationID: "-55", senderID: "42", text: "/threads",
          isFromOwner: false)
      ])
    let rejected = Data(#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8)
    XCTAssertThrowsError(try TelegramChannel.decode(rejected) as [TelegramChannel.Update]) {
      XCTAssertEqual($0 as? TelegramChannel.Error, .unauthorized)
    }
    let conflict = Data(#"{"ok":false,"error_code":409,"description":"Conflict"}"#.utf8)
    XCTAssertThrowsError(try TelegramChannel.decode(conflict) as [TelegramChannel.Update]) {
      XCTAssertEqual($0 as? TelegramChannel.Error, .api("Conflict"))
    }
  }

  // MARK: - Discord

  func testDiscordTakesDirectMessagesAndMentionsOnly() {
    let botID = "999"
    let direct: [String: Any] = [
      "author": ["id": "42", "username": "me"], "channel_id": "dm", "content": " hello ",
    ]
    XCTAssertEqual(
      DiscordChannel.incomingMessage(from: direct, botID: botID),
      MessagingIncomingMessage(
        platform: .discord, conversationID: "dm", senderID: "42", text: "hello",
        isFromOwner: false))
    let fromBot: [String: Any] = [
      "author": ["id": "7", "bot": true], "channel_id": "dm", "content": "hi",
    ]
    XCTAssertNil(DiscordChannel.incomingMessage(from: fromBot, botID: botID))
    let own: [String: Any] = ["author": ["id": botID], "channel_id": "dm", "content": "echo"]
    XCTAssertNil(DiscordChannel.incomingMessage(from: own, botID: botID))
    let unmentioned: [String: Any] = [
      "author": ["id": "42"], "channel_id": "general", "guild_id": "g", "content": "chatter",
      "mentions": [[String: Any]](),
    ]
    XCTAssertNil(DiscordChannel.incomingMessage(from: unmentioned, botID: botID))
    let mentioned: [String: Any] = [
      "author": ["id": "42"], "channel_id": "general", "guild_id": "g",
      "content": "<@!999> /threads", "mentions": [["id": botID]],
    ]
    XCTAssertEqual(
      DiscordChannel.incomingMessage(from: mentioned, botID: botID)?.text, "/threads")
    let onlyMention: [String: Any] = [
      "author": ["id": "42"], "channel_id": "general", "guild_id": "g", "content": "<@999>",
      "mentions": [["id": botID]],
    ]
    XCTAssertNil(DiscordChannel.incomingMessage(from: onlyMention, botID: botID))
  }

  // MARK: - Bridge

  func testStrangersPairWithTheCodeOnly() throws {
    try onMain {
      let bridge = MessagingBridge(
        workspace: workspace, permittedDirectories: PermittedDirectories(workspace: workspace))
      let delegate = FakeDelegate()
      delegate.threads = [thread(1, "Build")]
      bridge.delegate = delegate
      let channel = FakeChannel(platform: .discord)
      bridge.setChannel(channel, for: .discord)
      XCTAssertTrue(channel.isStarted)
      XCTAssertEqual(bridge.status.value.connections[.discord], .connecting)

      channel.receive("/threads")
      channel.receive("hello")
      // Told once how to pair, and nothing else reaches the threads.
      XCTAssertEqual(channel.takeSent(), ["send_pairing_code_detail"])
      XCTAssertTrue(delegate.sends.isEmpty)

      let code = bridge.status.value.pairingCode
      XCTAssertEqual(code.count, 6)
      channel.receive(code)
      XCTAssertEqual(channel.takeSent(), ["paired_with_local_code_detail"])
      XCTAssertEqual(
        workspace.dictionary[MessagingPlatform.discord.pairedSendersKey, [String].self], ["42"])
      // The code changes once used, so a second stranger can't reuse it.
      XCTAssertNotEqual(bridge.status.value.pairingCode, code)
      channel.receive(code, from: "66", in: "other")
      XCTAssertEqual(channel.takeSent(), ["send_pairing_code_detail"])

      channel.receive("/threads")
      XCTAssertEqual(channel.takeSent(), ["1. Build · App · idle"])
    }
  }

  func testMessagesGoToTheChatsThreadAndAnswersComeBack() throws {
    try onMain {
      workspace.dictionary[MessagingPlatform.telegram.pairedSendersKey, [String].self] = ["42"]
      let bridge = MessagingBridge(
        workspace: workspace, permittedDirectories: PermittedDirectories(workspace: workspace))
      let delegate = FakeDelegate()
      delegate.threads = [
        thread(1, "Build", status: .working), thread(2, "Docs", status: .newReply),
      ]
      bridge.delegate = delegate
      let channel = FakeChannel(platform: .telegram)
      bridge.setChannel(channel, for: .telegram)

      channel.receive("/status")
      XCTAssertEqual(
        channel.takeSent(),
        ["thread_status_summary_detail\n1. Build · App · working\n2. Docs · App · new_reply"])
      channel.receive("/status 2")
      XCTAssertEqual(channel.takeSent(), ["Docs · App · new_reply\n\nLast Docs"])

      // With no thread yet, a message starts one in the workspace folder, whatever is open.
      channel.receive("write a readme")
      XCTAssertEqual(delegate.starts.map(\.projectPath), ["/p"])
      XCTAssertEqual(delegate.starts.map(\.title), ["x_conversations"])
      XCTAssertEqual(channel.takeSent(), ["started_thread_detail"])
      let started = MessagingThreadReference(projectPath: "/p", threadId: 100)
      XCTAssertEqual(savedBindings(), ["telegram:chat": "/p\n100"])

      // The next message goes on in that thread.
      channel.receive("and a license")
      XCTAssertEqual(delegate.sends.last?.thread, started)
      XCTAssertEqual(delegate.sends.last?.text, "and a license")
      XCTAssertEqual(channel.takeSent(), ["sent_to_thread_detail"])

      // Its answer comes back once, under the thread's title.
      bridge.threadDidFinishTurn(started, title: "Readme", response: " Done. ")
      XCTAssertEqual(channel.takeSent(), ["Readme\n\nDone."])
      bridge.threadDidFinishTurn(started, title: "Readme", response: "Again")
      XCTAssertTrue(channel.takeSent().isEmpty)

      // /send reaches another thread; the chat's messages stay in its own.
      channel.receive("/threads")
      XCTAssertEqual(
        channel.takeSent(),
        ["1. untitled · New · working ←\n2. Build · App · working\n3. Docs · App · new_reply"]
      )
      delegate.isRunning = true
      channel.receive("/send 3 check the links")
      XCTAssertEqual(delegate.sends.last?.thread.threadId, 2)
      XCTAssertEqual(channel.takeSent(), ["queued_in_thread_detail"])
      channel.receive("more docs")
      XCTAssertEqual(delegate.sends.last?.thread, started)
      _ = channel.takeSent()

      channel.receive("/stop")
      XCTAssertEqual(delegate.stops.last, started)
      XCTAssertEqual(channel.takeSent(), ["stopped_thread_detail"])
      channel.receive("/send 40 hi")
      XCTAssertEqual(channel.takeSent(), ["no_thread_numbered_detail"])

      // Once its thread is deleted, the chat's next message starts another in the workspace folder,
      // even when a later thread got the deleted one's identifier.
      delegate.threads.removeAll { $0.reference == started }
      bridge.threadWasRemoved(started)
      XCTAssertEqual(savedBindings(), [:])
      delegate.threads.append(
        MessagingThread(
          reference: started, projectTitle: "./", title: "Someone else's", status: .idle,
          lastMessage: nil))
      channel.receive("start over")
      XCTAssertEqual(delegate.starts.map(\.projectPath), ["/p", "/p"])
      XCTAssertEqual(channel.takeSent(), ["started_thread_detail"])
      XCTAssertEqual(savedBindings(), ["telegram:chat": "/p\n101"])
      channel.receive("/bogus")
      XCTAssertEqual(channel.takeSent(), ["unknown_command_detail"])
    }
  }

  func testChatsKeepTheirThreadsAcrossLaunches() throws {
    try onMain {
      workspace.dictionary[MessagingPlatform.telegram.pairedSendersKey, [String].self] = ["42"]
      let delegate = FakeDelegate()
      delegate.threads = [thread(1, "Build"), thread(2, "Docs")]
      do {
        let bridge = MessagingBridge(
          workspace: workspace, permittedDirectories: PermittedDirectories(workspace: workspace))
        bridge.delegate = delegate
        let channel = FakeChannel(platform: .telegram)
        bridge.setChannel(channel, for: .telegram)
        channel.receive("hello")
      }
      let bridge = MessagingBridge(
        workspace: workspace, permittedDirectories: PermittedDirectories(workspace: workspace))
      bridge.delegate = delegate
      let channel = FakeChannel(platform: .telegram)
      bridge.setChannel(channel, for: .telegram)
      channel.receive("hello again")
      XCTAssertEqual(delegate.sends.last?.thread.threadId, 100)
      XCTAssertEqual(delegate.starts.count, 1)

      // Its thread is deleted where the bridge doesn't hear of it, and another chat's first message
      // starts a thread with the same identifier: only that chat is in it.
      delegate.threads.removeAll { $0.reference.threadId == 100 }
      delegate.nextThreadId = 100
      channel.receive("hi", in: "other chat")
      XCTAssertEqual(delegate.starts.count, 2)
      XCTAssertEqual(savedBindings(), ["telegram:other chat": "/p\n100"])
      channel.receive("still there?")
      XCTAssertEqual(delegate.starts.count, 3)
    }
  }

  func testOwnersNeedNoPairingAndOldChannelsAreIgnored() throws {
    try onMain {
      let bridge = MessagingBridge(
        workspace: workspace, permittedDirectories: PermittedDirectories(workspace: workspace))
      let delegate = FakeDelegate()
      delegate.threads = [thread(1, "Build")]
      bridge.delegate = delegate
      let old = FakeChannel(platform: .iMessage)
      bridge.setChannel(old, for: .iMessage)
      let channel = FakeChannel(platform: .iMessage)
      bridge.setChannel(channel, for: .iMessage)
      XCTAssertFalse(old.isStarted)
      channel.receive("/threads", from: "")
      XCTAssertEqual(channel.takeSent(), ["1. Build · App · idle"])
      channel.messagingChannelDidConnect()
      XCTAssertEqual(bridge.status.value.connections[.iMessage], .connected("me"))
      bridge.setChannel(nil, for: .iMessage)
      XCTAssertNil(bridge.status.value.connections[.iMessage])
    }
  }
}

extension FakeChannel {
  fileprivate func messagingChannelDidConnect() {
    delegate?.messagingChannel(self, didChange: .connected("me"))
  }
}
