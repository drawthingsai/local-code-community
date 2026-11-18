import Foundation
import Localization

/// A Telegram bot, reached through the Bot API with long polling, so nothing needs to reach this
/// device from outside. Main queue only: its session calls back there.
final class TelegramChannel: MessagingChannel {
  enum Error: Swift.Error, Equatable {
    case unauthorized
    case api(String)
    case invalidResponse
  }

  struct User: Decodable, Equatable {
    let id: Int64
    let isBot: Bool
    let username: String?
  }

  struct Update: Decodable, Equatable {
    struct Message: Decodable, Equatable {
      struct Chat: Decodable, Equatable {
        let id: Int64
      }
      let chat: Chat
      let from: User?
      let text: String?
    }
    let updateId: Int
    let message: Message?
  }

  private struct Response<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let errorCode: Int?
    let description: String?
  }

  weak var delegate: (any MessagingChannelDelegate)?

  private static let maximumMessageLength = 4096
  private static let pollTimeout = 50

  private let token: String
  private let session: URLSession
  /// Changes on every start and stop, so the callbacks of a run that ended do nothing.
  private var run = 0
  private var retryDelay: TimeInterval = 1
  /// The next update to ask for. Nil until the updates sent before starting are skipped.
  private var offset: Int?
  private var pollTask: URLSessionDataTask?
  /// Replies go out one piece at a time, so a long one arrives in order.
  private var outgoing = [(conversationID: String, chunks: [String])]()
  private var isSending = false

  init(
    token: String,
    session: URLSession = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: .main)
  ) {
    self.token = token
    self.session = session
  }

  func start() {
    stop()
    offset = nil
    retryDelay = 1
    connect()
  }

  func stop() {
    run += 1
    pollTask?.cancel()
    pollTask = nil
  }

  func send(_ text: String, to conversationID: String) {
    outgoing.append((conversationID, Self.chunks(of: text, limit: Self.maximumMessageLength)))
    sendNext()
  }

  func showTyping(in conversationID: String) {
    call("sendChatAction", ["chat_id": conversationID, "action": "typing"]) {
      (_: Result<Bool, Swift.Error>) in
    }
  }

  /// Checks the token, then polls.
  private func connect() {
    let run = self.run
    call("getMe", [:]) { [weak self] (result: Result<User, Swift.Error>) in
      guard let self, self.run == run else { return }
      switch result {
      case .success(let bot):
        self.report(.connected(bot.username.map { "@\($0)" } ?? String(bot.id)))
        guard self.offset == nil else {
          self.poll()
          return
        }
        // Messages sent while this wasn't listening are skipped: a stale command shouldn't run when
        // the app opens.
        self.call("getUpdates", ["offset": -1, "timeout": 0]) {
          [weak self] (result: Result<[Update], Swift.Error>) in
          guard let self, self.run == run else { return }
          switch result {
          case .success(let pending):
            self.offset = pending.last.map { $0.updateId + 1 } ?? 0
            self.poll()
          case .failure(let error):
            self.retry(after: error)
          }
        }
      case .failure(let error):
        self.retry(after: error)
      }
    }
  }

  /// Waits for the next updates, hands their messages over, and waits again.
  private func poll() {
    guard let offset else { return }
    let run = self.run
    pollTask = call(
      "getUpdates",
      ["offset": offset, "timeout": Self.pollTimeout, "allowed_updates": ["message"]],
      timeout: TimeInterval(Self.pollTimeout + 15)
    ) { [weak self] (result: Result<[Update], Swift.Error>) in
      guard let self, self.run == run else { return }
      switch result {
      case .success(let updates):
        self.retryDelay = 1
        for update in updates {
          self.offset = update.updateId + 1
          guard let message = Self.incomingMessage(from: update) else { continue }
          self.delegate?.messagingChannel(self, didReceive: message)
        }
        // The delegate can stop this.
        guard self.run == run else { return }
        self.poll()
      case .failure(let error):
        self.retry(after: error)
      }
    }
  }

  /// A rejected token stops the bot until Kit sets another. Anything else tries again after a wait
  /// that doubles up to a minute.
  private func retry(after error: Swift.Error) {
    switch error {
    case Error.unauthorized:
      report(.failed(LocalizedString.forKey("bot_token_rejected_detail")))
      return
    case Error.api(let description):
      report(.failed(description))
    default:
      report(.connecting)
    }
    let run = self.run
    DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
      guard let self, self.run == run else { return }
      self.connect()
    }
    retryDelay = min(retryDelay * 2, 60)
  }

  private func sendNext() {
    guard !isSending, let reply = outgoing.first, let chunk = reply.chunks.first else { return }
    isSending = true
    call("sendMessage", ["chat_id": reply.conversationID, "text": chunk]) {
      [weak self] (result: Result<Update.Message, Swift.Error>) in
      guard let self else { return }
      self.isSending = false
      switch result {
      case .success:
        self.outgoing[0].chunks.removeFirst()
        if self.outgoing[0].chunks.isEmpty {
          self.outgoing.removeFirst()
        }
      case .failure(let error):
        print("Unable to send a Telegram message: \(error)")
        // The rest of the reply would make no sense alone.
        self.outgoing.removeFirst()
      }
      self.sendNext()
    }
  }

  /// A text message from a person, as the bridge takes it.
  static func incomingMessage(from update: Update) -> MessagingIncomingMessage? {
    guard let message = update.message, let text = message.text, let from = message.from,
      !from.isBot
    else { return nil }
    return MessagingIncomingMessage(
      conversationID: String(message.chat.id), senderID: String(from.id), text: text)
  }

  private func report(_ connection: MessagingConnection) {
    delegate?.messagingChannel(self, didChange: connection)
  }

  @discardableResult
  private func call<Value: Decodable>(
    _ method: String, _ parameters: [String: Any], timeout: TimeInterval = 30,
    completion: @escaping (Result<Value, Swift.Error>) -> Void
  ) -> URLSessionDataTask? {
    guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
      completion(.failure(Error.unauthorized))
      return nil
    }
    guard let body = try? JSONSerialization.data(withJSONObject: parameters) else {
      completion(.failure(Error.invalidResponse))
      return nil
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let task = session.dataTask(with: request) { data, _, error in
      if let error {
        completion(.failure(error))
        return
      }
      completion(Result { try Self.decode(data ?? Data()) })
    }
    task.resume()
    return task
  }

  static func decode<Result: Decodable>(_ data: Data) throws -> Result {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let response = try? decoder.decode(Response<Result>.self, from: data) else {
      throw Error.invalidResponse
    }
    guard response.ok, let result = response.result else {
      // 404 is what Telegram answers a token that names no bot.
      if response.errorCode == 401 || response.errorCode == 404 { throw Error.unauthorized }
      throw Error.api(response.description ?? "Telegram error \(response.errorCode ?? 0)")
    }
    return result
  }
}
