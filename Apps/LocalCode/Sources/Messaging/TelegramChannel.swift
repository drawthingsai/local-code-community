import Foundation
import Localization

/// A Telegram bot, reached through the Bot API with long polling, so nothing needs to reach this
/// device from outside.
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

  private struct Empty: Decodable {}

  let platform = MessagingPlatform.telegram
  weak var delegate: (any MessagingChannelDelegate)?

  private static let maximumMessageLength = 4096
  private static let pollTimeout = 50

  private let token: String
  private let session: URLSession
  private var pollTask: Task<Void, Never>?
  /// Each send waits for the one before, so long replies arrive in order.
  private var lastSend: Task<Void, Never>?

  init(token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
    self.token = token
    self.session = session
  }

  func start() {
    pollTask?.cancel()
    pollTask = Task { [weak self] in await self?.poll() }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
  }

  func send(_ text: String, to conversationID: String) {
    let previous = lastSend
    lastSend = Task { [weak self] in
      await previous?.value
      for chunk in Self.chunks(of: text, limit: Self.maximumMessageLength) {
        guard let self else { return }
        do {
          let _: Update.Message = try await self.call(
            "sendMessage", ["chat_id": conversationID, "text": chunk])
        } catch {
          print("Unable to send a Telegram message: \(error)")
          return
        }
      }
    }
  }

  func showTyping(in conversationID: String) {
    Task { [weak self] in
      let _: Bool? = try? await self?.call(
        "sendChatAction", ["chat_id": conversationID, "action": "typing"])
    }
  }

  private func poll() async {
    var retryDelay: UInt64 = 1
    var offset: Int?
    while !Task.isCancelled {
      do {
        let bot: User = try await call("getMe", [:])
        await report(.connected(bot.username.map { "@\($0)" } ?? String(bot.id)))
        if offset == nil {
          // Messages sent while this wasn't listening are skipped: a stale command shouldn't run
          // when the app opens.
          let pending: [Update] = try await call("getUpdates", ["offset": -1, "timeout": 0])
          offset = pending.last.map { $0.updateId + 1 } ?? 0
        }
        while !Task.isCancelled, let current = offset {
          let updates: [Update] = try await call(
            "getUpdates",
            [
              "offset": current, "timeout": Self.pollTimeout, "allowed_updates": ["message"],
            ], timeout: TimeInterval(Self.pollTimeout + 15))
          for update in updates {
            offset = update.updateId + 1
            guard let message = Self.incomingMessage(from: update) else { continue }
            await MainActor.run { [weak self] in
              guard let self else { return }
              self.delegate?.messagingChannel(self, didReceive: message)
            }
          }
          retryDelay = 1
        }
      } catch Error.unauthorized {
        await report(.failed(LocalizedString.forKey("bot_token_rejected_detail")))
        return
      } catch {
        guard !Task.isCancelled else { return }
        if case Error.api(let description) = error {
          await report(.failed(description))
        } else {
          await report(.connecting)
        }
        try? await Task.sleep(nanoseconds: retryDelay * 1_000_000_000)
        retryDelay = min(retryDelay * 2, 60)
      }
    }
  }

  /// A text message from a person, as the bridge takes it.
  static func incomingMessage(from update: Update) -> MessagingIncomingMessage? {
    guard let message = update.message, let text = message.text, let from = message.from,
      !from.isBot
    else { return nil }
    return MessagingIncomingMessage(
      platform: .telegram, conversationID: String(message.chat.id), senderID: String(from.id),
      text: text, isFromOwner: false)
  }

  @MainActor
  private func report(_ connection: MessagingConnection) {
    delegate?.messagingChannel(self, didChange: connection)
  }

  private func call<Result: Decodable>(
    _ method: String, _ parameters: [String: Any], timeout: TimeInterval = 30
  ) async throws -> Result {
    guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
      throw Error.unauthorized
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
    let (data, _) = try await session.data(for: request)
    return try Self.decode(data)
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
