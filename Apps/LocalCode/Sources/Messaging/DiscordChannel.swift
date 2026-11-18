import Foundation
import Localization

/// A Discord bot: it receives messages over the Gateway's WebSocket and answers through the REST
/// API. It takes direct messages, and messages that mention it in a server. Both carry their text
/// without the privileged Message Content intent, so the bot needs no extra setup in Discord.
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

  let platform = MessagingPlatform.discord
  weak var delegate: (any MessagingChannelDelegate)?

  private static let apiURL = "https://discord.com/api/v10"
  private static let maximumMessageLength = 2000

  /// What the heartbeat and the receive loop share during one connection.
  private actor Connection {
    var sequence: Int?
    var isAcknowledged = true

    func received(sequence: Int?) {
      if let sequence { self.sequence = sequence }
    }

    func acknowledge() { isAcknowledged = true }

    /// The sequence to send, or nil when the last heartbeat went unanswered.
    func beat() -> Int?? {
      guard isAcknowledged else { return nil }
      isAcknowledged = false
      return .some(sequence)
    }
  }

  private let token: String
  private let session: URLSession
  private var runTask: Task<Void, Never>?
  private var lastSend: Task<Void, Never>?

  init(token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
    self.token = token
    self.session = session
  }

  func start() {
    runTask?.cancel()
    runTask = Task { [weak self] in await self?.run() }
  }

  func stop() {
    runTask?.cancel()
    runTask = nil
  }

  func send(_ text: String, to conversationID: String) {
    let previous = lastSend
    lastSend = Task { [weak self] in
      await previous?.value
      for chunk in Self.chunks(of: text, limit: Self.maximumMessageLength) {
        guard let self else { return }
        do {
          // Nobody gets pinged by what a thread wrote.
          _ = try await self.rest(
            "POST", "/channels/\(conversationID)/messages",
            body: ["content": chunk, "allowed_mentions": ["parse": [String]()]])
        } catch {
          print("Unable to send a Discord message: \(error)")
          return
        }
      }
    }
  }

  func showTyping(in conversationID: String) {
    Task { [weak self] in
      _ = try? await self?.rest("POST", "/channels/\(conversationID)/typing", body: nil)
    }
  }

  private func run() async {
    var retryDelay: UInt64 = 1
    while !Task.isCancelled {
      do {
        guard
          let gateway = try await rest("GET", "/gateway/bot", body: nil)["url"] as? String,
          let url = URL(string: "\(gateway)/?v=10&encoding=json")
        else { throw Error.invalidResponse }
        try await connect(to: url)
        retryDelay = 1
      } catch Error.unauthorized {
        await report(.failed(LocalizedString.forKey("bot_token_rejected_detail")))
        return
      } catch Error.disallowedIntents {
        await report(.failed(LocalizedString.forKey("discord_intents_refused_detail")))
        return
      } catch Error.reconnect {
        // Discord asks for a short wait before identifying again.
        try? await Task.sleep(nanoseconds: UInt64.random(in: 1...5) * 1_000_000_000)
      } catch {
        guard !Task.isCancelled else { return }
        await report(.connecting)
        try? await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
        retryDelay = min(retryDelay * 2, 60)
      }
    }
  }

  /// One Gateway connection, until it closes.
  private func connect(to url: URL) async throws {
    let socket = session.webSocketTask(with: url)
    socket.maximumMessageSize = 16 * 1024 * 1024
    socket.resume()
    let connection = Connection()
    var heartbeat: Task<Void, Never>?
    defer {
      heartbeat?.cancel()
      socket.cancel(with: .goingAway, reason: nil)
    }
    var botID = ""
    while !Task.isCancelled {
      let payload: [String: Any]
      do {
        // Stopping cancels the socket, which ends a receive that would otherwise wait.
        payload = try await withTaskCancellationHandler {
          try await Self.receive(socket)
        } onCancel: {
          socket.cancel(with: .goingAway, reason: nil)
        }
      } catch {
        switch socket.closeCode.rawValue {
        case 4004: throw Error.unauthorized
        case 4013, 4014: throw Error.disallowedIntents
        default: throw error
        }
      }
      await connection.received(sequence: payload["s"] as? Int)
      switch payload["op"] as? Int {
      case 10:  // Hello
        guard let data = payload["d"] as? [String: Any],
          let interval = data["heartbeat_interval"] as? Double
        else { throw Error.invalidResponse }
        heartbeat = Task {
          // The first beat comes after a random part of the interval, as Discord asks.
          var delay = interval * Double.random(in: 0..<1)
          while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
            guard !Task.isCancelled else { return }
            guard let sequence = await connection.beat() else {
              // A zombie connection: close it, and the receive loop reconnects.
              socket.cancel(with: .abnormalClosure, reason: nil)
              return
            }
            try? await Self.send(Self.heartbeat(sequence), on: socket)
            delay = interval
          }
        }
        try await Self.send(
          [
            "op": 2,
            "d": [
              "token": token, "intents": Self.intents,
              "properties": ["os": "macos", "browser": "Local Code", "device": "Local Code"],
            ],
          ], on: socket)
      case 11:  // Heartbeat ACK
        await connection.acknowledge()
      case 1:  // Heartbeat request
        try await Self.send(Self.heartbeat(await connection.sequence), on: socket)
      case 7, 9:  // Reconnect, Invalid Session
        throw Error.reconnect
      case 0:  // Dispatch
        let data = payload["d"] as? [String: Any] ?? [:]
        switch payload["t"] as? String {
        case "READY":
          let user = data["user"] as? [String: Any] ?? [:]
          botID = user["id"] as? String ?? ""
          await report(.connected(user["username"] as? String ?? botID))
        case "MESSAGE_CREATE":
          guard let message = Self.incomingMessage(from: data, botID: botID) else { continue }
          await MainActor.run { [weak self] in
            guard let self else { return }
            self.delegate?.messagingChannel(self, didReceive: message)
          }
        default:
          break
        }
      default:
        break
      }
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
    return MessagingIncomingMessage(
      platform: .discord, conversationID: channelID, senderID: authorID, text: text,
      isFromOwner: false)
  }

  @MainActor
  private func report(_ connection: MessagingConnection) {
    delegate?.messagingChannel(self, didChange: connection)
  }

  private static func heartbeat(_ sequence: Int?) -> [String: Any] {
    ["op": 1, "d": sequence.map { $0 as Any } ?? NSNull()]
  }

  private static func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
    let data: Data
    switch try await socket.receive() {
    case .string(let text): data = Data(text.utf8)
    case .data(let bytes): data = bytes
    @unknown default: throw Error.invalidResponse
    }
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Error.invalidResponse
    }
    return payload
  }

  private static func send(_ payload: [String: Any], on socket: URLSessionWebSocketTask)
    async throws
  {
    let data = try JSONSerialization.data(withJSONObject: payload)
    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
  }

  /// Retries once after a rate limit.
  @discardableResult
  private func rest(_ method: String, _ path: String, body: [String: Any]?) async throws
    -> [String: Any]
  {
    guard let url = URL(string: Self.apiURL + path) else { throw Error.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = method
    request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("DiscordBot (https://getlocalcode.app, 1)", forHTTPHeaderField: "User-Agent")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    for attempt in 0..<2 {
      let (data, response) = try await session.data(for: request)
      let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
      switch statusCode {
      case 200..<300:
        return object
      case 401:
        throw Error.unauthorized
      case 429 where attempt == 0:
        let retryAfter = object["retry_after"] as? Double ?? 1
        try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 30) * 1_000_000_000))
      default:
        throw Error.http(statusCode)
      }
    }
    throw Error.http(429)
  }
}
