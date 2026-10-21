import ArgumentParser
import BashToolContext
import Foundation
import ios_system

struct IMessageCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "imessage",
    abstract: "Read Messages history on this Mac.",
    discussion: """
      Read-only: it cannot send messages or export attachments. Results are JSON, newest \
      first, with IDs local to this Mac. The first command asks for access to the \
      ~/Library/Messages folder.
      """,
    subcommands: [Status.self, Chats.self, Messages.self])

  /// Runs `body` with the database. Local Code decides whether the command may read the Messages
  /// folder, asking the user for it when `prompt` is true; that access lasts only for `body`.
  static func withDatabase<T>(prompt: Bool = true, _ body: (MessagesDatabase) throws -> T)
    throws -> T
  {
    guard let context = BashToolContext.current,
      let accessMessagesDirectory = context.accessMessagesDirectory
    else { throw AppleUtilityError.unavailable }
    // The host checks this from the main thread while its folder picker is shown.
    let cancellation = ios_getCommandCancellationContext()
    let isCancelled = { ios_commandCancellationRequested(cancellation) != 0 }
    // ios_system needs a synchronous exit status. The host also completes on cancellation, by
    // dismissing its picker.
    let group = DispatchGroup()
    var result: Result<URL, Error> = .failure(AppleUtilityError.cancelled)
    group.enter()
    accessMessagesDirectory(prompt, context.bashUserInteraction, isCancelled) {
      result = $0
      group.leave()
    }
    group.wait()
    let directory = try result.get()
    defer { directory.stopAccessingSecurityScopedResource() }
    return try body(MessagesDatabase(directory: directory, isCancelled: isCancelled))
  }
}

extension IMessageCommand {
  struct Status: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Check whether Messages history is readable, without asking for access.")

    struct Access: Encodable {
      var readable: Bool
      var reason: String?
    }

    func result() throws -> any Encodable {
      do {
        return try IMessageCommand.withDatabase(prompt: false) { _ in
          Access(readable: true)
        }
      } catch {
        return Access(readable: false, reason: error.localizedDescription)
      }
    }
  }

  struct Chats: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List chats, most recently active first.")

    @OptionGroup var pagination: Pagination

    func result() throws -> any Encodable {
      try IMessageCommand.withDatabase {
        try $0.chats(limit: pagination.limit, offset: pagination.offset)
      }
    }
  }

  struct Messages: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List or search messages, newest first.",
      discussion: "Pass next_before_id as --before-id, with the same filters, for the next page.")

    @Option(
      help: ArgumentHelp("Only messages in this chat ID from `imessage chats`.", valueName: "id"))
    var chat: Int64?
    @Option(parsing: .unconditional, help: "Only messages containing this text, ignoring case.")
    var query: String?
    @Option(
      help: ArgumentHelp("Only messages sent at or after this date.", valueName: "date"),
      transform: parseDate)
    var from: Date?
    @Option(
      help: ArgumentHelp("Only messages sent before this date.", valueName: "date"),
      transform: parseDate)
    var to: Date?
    @Option(help: "Maximum number of results.") var limit = 50
    @Option(
      name: .customLong("before-id"),
      help: ArgumentHelp("Only messages older than this message ID.", valueName: "id"))
    var beforeID: Int64?

    func validate() throws {
      guard limit > 0 else { throw ValidationError("--limit must be at least 1.") }
      guard query?.isEmpty != true else { throw ValidationError("--query must not be empty.") }
      if let from, let to, to <= from { throw ValidationError("--to must be after --from.") }
    }

    func result() throws -> any Encodable {
      try IMessageCommand.withDatabase {
        try $0.messages(
          chatID: chat, query: query, from: from, to: to, beforeID: beforeID, limit: limit)
      }
    }
  }
}
