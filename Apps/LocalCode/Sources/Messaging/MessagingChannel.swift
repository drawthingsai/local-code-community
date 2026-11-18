import Foundation

/// A chat app that people can message this app's threads from.
enum MessagingPlatform: String, CaseIterable, Hashable {
  case iMessage = "imessage"
  case telegram
  case discord

  /// The app's own name, which isn't translated.
  var title: String {
    switch self {
    case .iMessage: return "iMessage"
    case .telegram: return "Telegram"
    case .discord: return "Discord"
    }
  }

  /// The workspace key that is true while the platform is on in Kit.
  var enabledKey: String { "messaging_\(rawValue)_enabled" }
  /// The workspace key that Kit changes to have the platform connect again: when it saves a bot
  /// token, which is kept in the keychain, or when asked to reconnect.
  var revisionKey: String { "messaging_\(rawValue)_revision" }
  /// The workspace key of the paired senders' IDs. iMessage has none: it only answers the account's
  /// own messages to itself.
  var pairedSendersKey: String { "messaging_\(rawValue)_paired_senders" }
  var needsPairing: Bool { self != .iMessage }
}

/// A message from a chat app, as its channel received it.
struct MessagingIncomingMessage: Equatable {
  let platform: MessagingPlatform
  /// Where replies go: a Telegram chat, a Discord channel, or a Messages chat.
  let conversationID: String
  /// Who sent it, as the platform identifies them.
  let senderID: String
  let text: String
  /// Only the account's owner can write there, as in an iMessage note to self, so it needs no
  /// pairing.
  let isFromOwner: Bool
}

enum MessagingConnection: Equatable {
  case connecting
  /// With the bot's or account's name.
  case connected(String)
  /// With what to fix, for Kit to show.
  case failed(String)
}

protocol MessagingChannelDelegate: AnyObject {
  func messagingChannel(
    _ channel: any MessagingChannel, didReceive message: MessagingIncomingMessage)
  func messagingChannel(_ channel: any MessagingChannel, didChange connection: MessagingConnection)
}

/// One chat app's connection. It calls its delegate on the main queue, and its methods are called
/// there.
protocol MessagingChannel: AnyObject {
  var platform: MessagingPlatform { get }
  var delegate: (any MessagingChannelDelegate)? { get set }
  func start()
  func stop()
  /// Splits text longer than the platform takes into several messages.
  func send(_ text: String, to conversationID: String)
  /// Shows that a reply is being written, where the platform can.
  func showTyping(in conversationID: String)
}

extension MessagingChannel {
  /// Pieces of at most `limit` UTF-16 units, split at a line break or space where there is one.
  static func chunks(of text: String, limit: Int) -> [String] {
    var chunks = [String]()
    var rest = Substring(text)
    while rest.utf16.count > limit {
      // Never inside a character, so an emoji stays whole.
      var end = rest.rangeOfComposedCharacterSequence(
        at: rest.utf16.index(rest.startIndex, offsetBy: limit)
      ).lowerBound
      if end == rest.startIndex {
        // A character longer than the limit goes alone.
        end = rest.index(after: end)
      }
      // A break right at the end counts too, since breaks are dropped.
      let breakable = end < rest.endIndex ? rest[...end] : rest[..<end]
      let split =
        breakable.lastIndex(of: "\n").flatMap { $0 > rest.startIndex ? $0 : nil }
        ?? breakable.lastIndex(of: " ").flatMap { $0 > rest.startIndex ? $0 : nil }
        ?? end
      chunks.append(String(rest[..<split]))
      rest = rest[split...].drop(while: { $0 == "\n" || $0 == " " })
    }
    if !rest.isEmpty || chunks.isEmpty { chunks.append(String(rest)) }
    return chunks
  }
}
