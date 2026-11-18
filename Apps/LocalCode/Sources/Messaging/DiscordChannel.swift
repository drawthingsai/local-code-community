import Foundation
import Localization

/// A Discord bot: it receives messages over the Gateway's WebSocket and answers through the REST
/// API. It takes direct messages, and messages that mention it in a server. Both carry their text
/// without the privileged Message Content intent, so the bot needs no extra setup in Discord. Main
/// queue only: its session calls back there.
final class DiscordChannel: MessagingChannel {
  enum Error: Swift.Error, Equatable {
    case unauthorized
    case disallowedIntents
    case invalidResponse
    case http(Int)
    /// The Gateway asked for a new connection.
    case reconnect
  }

  /// GUILD_MESSAGES and DIRECT_MESSAGES.
  static let intents = (1 << 9) | (1 << 12)

  weak var delegate: (any MessagingChannelDelegate)?

  private static let apiURL = "https://discord.com/api/v10"
  private static let maximumMessageLength = 2000

  private let token: String
  private let session: URLSession
  /// Changes on every start, stop and dropped connection, so the callbacks of a connection that
  /// ended do nothing.
  private var connection = 0
  private var retryDelay: TimeInterval = 1
  private var socket: URLSessionWebSocketTask?
  private var heartbeatTimer: DispatchSourceTimer?
  /// The last sequence number the Gateway sent, which heartbeats carry.
  private var sequence: Int?
  /// Whether the Gateway answered the last heartbeat.
  private var isAcknowledged = true
  private var botID = ""
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
    close()
    retryDelay = 1
    connect()
  }

  func stop() {
    close()
  }

  func send(_ text: String, to conversationID: String) {
    outgoing.append((conversationID, Self.chunks(of: text, limit: Self.maximumMessageLength)))
    sendNext()
  }

  func showTyping(in conversationID: String) {
    rest("POST", "/channels/\(conversationID)/typing", body: nil) { _ in }
  }

  /// Asks for the Gateway's address, then connects to it.
  private func connect() {
    let connection = self.connection
    rest("GET", "/gateway/bot", body: nil) { [weak self] result in
      guard let self, self.connection == connection else { return }
      switch result {
      case .success(let object):
        guard let gateway = object["url"] as? String,
          let url = URL(string: "\(gateway)/?v=10&encoding=json")
        else {
          self.retry(after: Error.invalidResponse)
          return
        }
        let socket = self.session.webSocketTask(with: url)
        socket.maximumMessageSize = 16 * 1024 * 1024
        self.socket = socket
        self.sequence = nil
        self.isAcknowledged = true
        self.botID = ""
        socket.resume()
        self.receive()
      case .failure(let error):
        self.retry(after: error)
      }
    }
  }

  /// Takes the Gateway's next event, and waits for the one after.
  private func receive() {
    guard let socket else { return }
    let connection = self.connection
    socket.receive { [weak self] result in
      guard let self, self.connection == connection else { return }
      switch result {
      case .success(let message):
        do {
          try self.handle(Self.payload(from: message))
        } catch {
          self.retry(after: error)
          return
        }
        // The delegate can stop this.
        guard self.connection == connection else { return }
        self.receive()
      case .failure(let error):
        // Discord's close code says why it closed.
        switch socket.closeCode.rawValue {
        case 4004: self.retry(after: Error.unauthorized)
        case 4013, 4014: self.retry(after: Error.disallowedIntents)
        default: self.retry(after: error)
        }
      }
    }
  }

  /// Throws to drop the connection.
  private func handle(_ payload: [String: Any]) throws {
    if let sequence = payload["s"] as? Int {
      self.sequence = sequence
    }
    switch payload["op"] as? Int {
    case 10:  // Hello
      guard let data = payload["d"] as? [String: Any],
        let interval = data["heartbeat_interval"] as? Double
      else { throw Error.invalidResponse }
      startHeartbeat(every: interval / 1_000)
      sendPayload([
        "op": 2,
        "d": [
          "token": token, "intents": Self.intents,
          "properties": ["os": "macos", "browser": "Local Code", "device": "Local Code"],
        ],
      ])
    case 11:  // Heartbeat ACK
      isAcknowledged = true
    case 1:  // Heartbeat request
      sendPayload(Self.heartbeat(sequence))
    case 7, 9:  // Reconnect, Invalid Session
      throw Error.reconnect
    case 0:  // Dispatch
      let data = payload["d"] as? [String: Any] ?? [:]
      switch payload["t"] as? String {
      case "READY":
        let user = data["user"] as? [String: Any] ?? [:]
        botID = user["id"] as? String ?? ""
        retryDelay = 1
        report(.connected(user["username"] as? String ?? botID))
      case "MESSAGE_CREATE":
        guard let message = Self.incomingMessage(from: data, botID: botID) else { return }
        delegate?.messagingChannel(self, didReceive: message)
      default:
        break
      }
    default:
      break
    }
  }

  private func startHeartbeat(every interval: TimeInterval) {
    heartbeatTimer?.cancel()
    let connection = self.connection
    let timer = DispatchSource.makeTimerSource(queue: .main)
    // The first beat comes after a random part of the interval, as Discord asks.
    timer.schedule(deadline: .now() + interval * Double.random(in: 0..<1), repeating: interval)
    timer.setEventHandler { [weak self] in
      guard let self, self.connection == connection, let socket = self.socket else { return }
      guard self.isAcknowledged else {
        // A zombie connection: close it, and receiving fails and connects again.
        socket.cancel(with: .abnormalClosure, reason: nil)
        return
      }
      self.isAcknowledged = false
      self.sendPayload(Self.heartbeat(self.sequence))
    }
    timer.resume()
    heartbeatTimer = timer
  }

  /// Drops the connection. A rejected token or refused intents stop the bot until Kit changes it.
  /// A Gateway that asks for a new connection gets one after a short wait. Anything else tries again
  /// after a wait that doubles up to a minute.
  private func retry(after error: Swift.Error) {
    close()
    let delay: TimeInterval
    switch error {
    case Error.unauthorized:
      report(.failed(LocalizedString.forKey("bot_token_rejected_detail")))
      return
    case Error.disallowedIntents:
      report(.failed(LocalizedString.forKey("discord_intents_refused_detail")))
      return
    case Error.reconnect:
      // Discord asks for a short wait before identifying again.
      delay = TimeInterval(Int.random(in: 1...5))
    default:
      report(.connecting)
      delay = retryDelay
      retryDelay = min(retryDelay * 2, 60)
    }
    let connection = self.connection
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self, self.connection == connection else { return }
      self.connect()
    }
  }

  private func close() {
    connection += 1
    heartbeatTimer?.cancel()
    heartbeatTimer = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
  }

  private func sendNext() {
    guard !isSending, let reply = outgoing.first, let chunk = reply.chunks.first else { return }
    isSending = true
    // Nobody gets pinged by what a thread wrote.
    rest(
      "POST", "/channels/\(reply.conversationID)/messages",
      body: ["content": chunk, "allowed_mentions": ["parse": [String]()]]
    ) { [weak self] result in
      guard let self else { return }
      self.isSending = false
      switch result {
      case .success:
        self.outgoing[0].chunks.removeFirst()
        if self.outgoing[0].chunks.isEmpty {
          self.outgoing.removeFirst()
        }
      case .failure(let error):
        print("Unable to send a Discord message: \(error)")
        // The rest of the reply would make no sense alone.
        self.outgoing.removeFirst()
      }
      self.sendNext()
    }
  }

  /// A message from a person: any direct message, or one in a server that mentions the bot,
  /// without the mention.
  static func incomingMessage(from data: [String: Any], botID: String) -> MessagingIncomingMessage?
  {
    guard let author = data["author"] as? [String: Any], let authorID = author["id"] as? String,
      author["bot"] as? Bool != true, authorID != botID,
      let channelID = data["channel_id"] as? String, var text = data["content"] as? String
    else { return nil }
    if data["guild_id"] is String {
      let mentions = (data["mentions"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
      guard !botID.isEmpty, mentions.contains(botID) else { return nil }
      text = text.replacingOccurrences(of: "<@\(botID)>", with: "")
        .replacingOccurrences(of: "<@!\(botID)>", with: "")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return MessagingIncomingMessage(conversationID: channelID, senderID: authorID, text: text)
  }

  private func report(_ connection: MessagingConnection) {
    delegate?.messagingChannel(self, didChange: connection)
  }

  private static func heartbeat(_ sequence: Int?) -> [String: Any] {
    ["op": 1, "d": sequence.map { $0 as Any } ?? NSNull()]
  }

  private static func payload(from message: URLSessionWebSocketTask.Message) throws -> [String: Any]
  {
    let data: Data
    switch message {
    case .string(let text): data = Data(text.utf8)
    case .data(let bytes): data = bytes
    @unknown default: throw Error.invalidResponse
    }
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Error.invalidResponse
    }
    return payload
  }

  /// A send that fails means the connection is going, which receiving notices.
  private func sendPayload(_ payload: [String: Any]) {
    guard let socket, let data = try? JSONSerialization.data(withJSONObject: payload) else {
      return
    }
    socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
  }

  /// Retries once after a rate limit.
  private func rest(
    _ method: String, _ path: String, body: [String: Any]?, isRetry: Bool = false,
    completion: @escaping (Result<[String: Any], Swift.Error>) -> Void
  ) {
    guard let url = URL(string: Self.apiURL + path) else {
      completion(.failure(Error.invalidResponse))
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("DiscordBot (https://getlocalcode.app, 1)", forHTTPHeaderField: "User-Agent")
    if let body {
      guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        completion(.failure(Error.invalidResponse))
        return
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = data
    }
    session.dataTask(with: request) { [weak self] data, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      let object =
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
      switch statusCode {
      case 200..<300:
        completion(.success(object))
      case 401:
        completion(.failure(Error.unauthorized))
      case 429 where !isRetry:
        let retryAfter = object["retry_after"] as? Double ?? 1
        DispatchQueue.main.asyncAfter(deadline: .now() + min(retryAfter, 30)) {
          guard let self else { return }
          self.rest(method, path, body: body, isRetry: true, completion: completion)
        }
      default:
        completion(.failure(Error.http(statusCode)))
      }
    }.resume()
  }
}
