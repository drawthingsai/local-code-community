import Foundation

/// What a message from a chat app asks for. Commands start with a slash, so an ordinary message
/// that happens to start with a command's word still goes to its thread.
enum MessagingCommand: Equatable {
  case help
  /// Lists the threads, numbered for the commands that take a number.
  case threads
  /// Every thread's status, or one thread's in detail.
  case status(Int?)
  /// Sends to the numbered thread; the chat's own messages still go to its thread.
  case send(Int, String)
  /// Stops the turn in the numbered thread, or in this chat's.
  case stop(Int?)
  /// Pairs the sender with the code shown in Kit.
  case pair(String)
  case message(String)
  /// A slash command this doesn't know, or one missing its number.
  case unknown(String)

  init(_ text: String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("/") else {
      self = .message(text)
      return
    }
    let body = text.dropFirst()
    let nameEnd = body.firstIndex(where: \.isWhitespace) ?? body.endIndex
    // Telegram addresses a command to one bot in a group as /threads@BotName.
    let name = body[..<nameEnd].split(separator: "@", maxSplits: 1).first.map {
      $0.lowercased()
    }
    let argument = body[nameEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
    let number = argument.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    let afterNumber = argument.drop(while: { !$0.isWhitespace }).trimmingCharacters(
      in: .whitespacesAndNewlines)
    switch name {
    case "help":
      self = .help
    case "start":
      // Telegram's /start, which a t.me link with ?start=<code> sends with the code.
      self = argument.isEmpty ? .help : .pair(argument)
    case "threads", "list":
      self = .threads
    case "status":
      if argument.isEmpty {
        self = .status(nil)
      } else if let number, afterNumber.isEmpty {
        self = .status(number)
      } else {
        self = .unknown(text)
      }
    case "send", "to":
      if let number, !afterNumber.isEmpty {
        self = .send(number, afterNumber)
      } else {
        self = .unknown(text)
      }
    case "stop":
      if argument.isEmpty {
        self = .stop(nil)
      } else if let number, afterNumber.isEmpty {
        self = .stop(number)
      } else {
        self = .unknown(text)
      }
    case "pair":
      self = .pair(argument)
    default:
      self = .unknown(text)
    }
  }
}
