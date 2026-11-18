#if targetEnvironment(macCatalyst)
  import AppleUtilities
  import Foundation
  import Localization

  /// The account's notes to itself in Messages: what someone sends to their own phone number or
  /// email, from any of their devices, reaches this Mac's Messages database, and answers go back to
  /// the same chat through Messages' scripting. Only the account's owner can write there, so it
  /// needs no pairing.
  final class IMessageChannel: MessagingChannel {
    let platform = MessagingPlatform.iMessage
    weak var delegate: (any MessagingChannelDelegate)?

    private static let pollInterval: DispatchTimeInterval = .seconds(2)
    /// How often to look for a note to self begun since, which takes a scan of every message.
    private static let selfChatsInterval: TimeInterval = 30
    /// An answer's own copy, and the copy a note gets on arriving at the account's other address,
    /// show up within this long.
    private static let echoLifetime: TimeInterval = 120
    /// Starts every answer, so its copy in the chat is never taken for a message to answer.
    private static let answerMarker = "\u{2063}"

    private let directoryURL: URL
    /// Reads the database and runs scripts, both of which can take a while.
    private let queue = DispatchQueue(label: "com.liuliu.local-code.imessage")
    // Queue only.
    private var timer: DispatchSourceTimer?
    private var database: MessagesDatabase?
    private var selfChats = [MessagesDatabase.SelfChat]()
    private var selfChatsDate = Date.distantPast
    private var lastMessageID: Int64 = 0
    private var sentAnswers = [(text: String, date: Date)]()
    private var receivedNotes = [(text: String, fromMe: Bool, date: Date)]()

    /// `directoryURL` is the Messages folder with its security scope started; stopping ends it.
    init(directoryURL: URL) {
      self.directoryURL = directoryURL
    }

    func start() {
      queue.async { [weak self] in
        guard let self else { return }
        do {
          let database = try MessagesDatabase(directory: self.directoryURL)
          self.database = database
          // Notes written before this started aren't answered.
          self.lastMessageID = try database.latestMessageID()
          try self.refreshSelfChats(force: true)
        } catch {
          self.report(.failed(error.localizedDescription))
          return
        }
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
      }
    }

    func stop() {
      queue.async { [self] in
        timer?.cancel()
        timer = nil
        database = nil
        directoryURL.stopAccessingSecurityScopedResource()
      }
    }

    func send(_ text: String, to conversationID: String) {
      queue.async { [weak self] in
        guard let self else { return }
        let identifier = self.selfChats.first { $0.guid == conversationID }?.identifier ?? ""
        let answer = Self.answerMarker + text
        self.sentAnswers.append((answer, Date()))
        do {
          try AppleScript.run(
            Self.sendScript(answer, chatID: conversationID, identifier: identifier))
        } catch AppleScript.Error.notAuthorized {
          self.report(.failed(LocalizedString.forKey("messages_automation_detail")))
        } catch {
          print("Unable to send an iMessage: \(error)")
        }
      }
    }

    /// Messages shows no typing from scripts.
    func showTyping(in conversationID: String) {}

    private func poll() {
      guard let database else { return }
      do {
        try refreshSelfChats(force: false)
        let messages = try database.messages(
          afterID: lastMessageID, chatIDs: selfChats.map(\.id), limit: 100)
        // Messages in other chats move the mark too, so they're never read again.
        lastMessageID = max(messages.last?.id ?? 0, try database.latestMessageID())
        let now = Date()
        sentAnswers.removeAll { now.timeIntervalSince($0.date) > Self.echoLifetime }
        receivedNotes.removeAll { now.timeIntervalSince($0.date) > Self.echoLifetime }
        for message in messages {
          guard let text = message.text, let chatID = message.chatID,
            let chat = selfChats.first(where: { $0.id == chatID }),
            let incoming = takeNote(text, fromMe: message.fromMe, conversationID: chat.guid)
          else { continue }
          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.messagingChannel(self, didReceive: incoming)
          }
        }
      } catch {
        report(.failed(error.localizedDescription))
      }
    }

    /// The note as a message to answer, or nil for an answer's copy or a second copy of a note.
    private func takeNote(_ text: String, fromMe: Bool, conversationID: String)
      -> MessagingIncomingMessage?
    {
      if text.hasPrefix(Self.answerMarker) { return nil }
      if let index = sentAnswers.firstIndex(where: {
        $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
          == text.trimmingCharacters(in: .whitespacesAndNewlines)
      }) {
        // In case Messages dropped the marker.
        sentAnswers.remove(at: index)
        return nil
      }
      // A note sent from another device can arrive both as sent and as received; the first one
      // counts.
      if let index = receivedNotes.firstIndex(where: { $0.text == text && $0.fromMe != fromMe }) {
        receivedNotes.remove(at: index)
        return nil
      }
      receivedNotes.append((text, fromMe, Date()))
      return MessagingIncomingMessage(
        platform: .iMessage, conversationID: conversationID, senderID: "", text: text,
        isFromOwner: true)
    }

    private func refreshSelfChats(force: Bool) throws {
      guard let database,
        force || Date().timeIntervalSince(selfChatsDate) > Self.selfChatsInterval
      else { return }
      selfChatsDate = Date()
      selfChats = try database.selfChats()
      // Kit asks for a note to self while there's none.
      report(.connected(selfChats.map(\.identifier).joined(separator: ", ")))
    }

    private func report(_ connection: MessagingConnection) {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.messagingChannel(self, didChange: connection)
      }
    }

    /// Sends to the chat by its ID, or failing that to the address in it.
    static func sendScript(_ text: String, chatID: String, identifier: String) -> String {
      func quoted(_ value: String) -> String {
        "\""
          + value.replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\"", with: "\\\"") + "\""
      }
      return """
        tell application id "com.apple.MobileSMS"
          try
            send \(quoted(text)) to chat id \(quoted(chatID))
          on error number errorNumber
            if errorNumber is -1743 then error number errorNumber
            send \(quoted(text)) to participant \(quoted(identifier)) of (1st account whose service type = iMessage)
          end try
        end tell
        """
    }
  }

  /// Runs AppleScript with Foundation's NSAppleScript, which Mac Catalyst has at run time but
  /// doesn't declare.
  enum AppleScript {
    enum Error: Swift.Error, Equatable {
      case unavailable
      /// The user didn't allow this app to control the other one.
      case notAuthorized
      case failed(Int, String)
    }

    @objc private protocol Script {
      func executeAndReturnError(
        _ errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?
      ) -> NSObject?
    }

    /// Blocks until the script finishes, which takes the user's answer the first time it controls
    /// an app.
    static func run(_ source: String) throws {
      guard let type = NSClassFromString("NSAppleScript") as? NSObject.Type,
        let allocated = (type as AnyObject).perform(NSSelectorFromString("alloc")),
        // `initWithSource:` takes over the allocation and returns the object to release.
        let initialized = allocated.takeUnretainedValue().perform(
          NSSelectorFromString("initWithSource:"), with: source)
      else { throw Error.unavailable }
      let script = unsafeBitCast(initialized.takeRetainedValue(), to: Script.self)
      var errorInfo: NSDictionary?
      guard script.executeAndReturnError(&errorInfo) == nil, let errorInfo else { return }
      let number = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
      if number == -1743 { throw Error.notAuthorized }
      throw Error.failed(number, errorInfo["NSAppleScriptErrorMessage"] as? String ?? "")
    }
  }
#endif
