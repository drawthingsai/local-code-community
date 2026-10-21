import ArgumentParser
import BashToolContext
import Foundation
import ios_system

struct MailCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mail",
    abstract: "Read mail that the Mail app keeps on this Mac.",
    discussion: """
      Read-only: it cannot send, move or delete mail. Results are JSON, newest first, with IDs \
      local to this Mac. It covers every account set up in Mail, and only mail that Mail has \
      downloaded. The first command asks for access to the ~/Library/Mail folder.
      """,
    subcommands: [Status.self, Mailboxes.self, Messages.self, Show.self])

  /// Runs `body` with the store. Local Code decides whether the command may read the Mail
  /// folder, asking the user for it when `prompt` is true; that access lasts only for `body`.
  static func withStore<T>(prompt: Bool = true, _ body: (MailStore) throws -> T) throws -> T {
    guard let context = BashToolContext.current,
      let accessMailDirectory = context.accessMailDirectory
    else { throw AppleUtilityError.unavailable }
    // The host checks this from the main thread while its folder picker is shown.
    let cancellation = ios_getCommandCancellationContext()
    let isCancelled = { ios_commandCancellationRequested(cancellation) != 0 }
    // ios_system needs a synchronous exit status. The host also completes on cancellation, by
    // dismissing its picker.
    let group = DispatchGroup()
    var result: Result<URL, Error> = .failure(AppleUtilityError.cancelled)
    group.enter()
    accessMailDirectory(prompt, context.bashUserInteraction, isCancelled) {
      result = $0
      group.leave()
    }
    group.wait()
    let directory = try result.get()
    defer { directory.stopAccessingSecurityScopedResource() }
    return try body(MailStore(directory: directory, isCancelled: isCancelled))
  }
}

extension MailCommand {
  struct Status: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Check whether mail is readable, without asking for access.")

    struct Access: Encodable {
      var readable: Bool
      var reason: String?
    }

    func result() throws -> any Encodable {
      do {
        return try MailCommand.withStore(prompt: false) { _ in Access(readable: true) }
      } catch {
        return Access(readable: false, reason: error.localizedDescription)
      }
    }
  }

  struct Mailboxes: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List mailboxes, grouped by account.")

    func result() throws -> any Encodable {
      try MailCommand.withStore { try $0.mailboxes() }
    }
  }

  struct Messages: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List or search messages, newest first.",
      discussion: "Pass next_offset as --offset, with the same filters, for the next page.")

    @Option(
      help: ArgumentHelp("Only messages in this mailbox ID from `mail mailboxes`.", valueName: "id")
    )
    var mailbox: Int64?
    @Option(
      parsing: .unconditional,
      help: "Only messages whose subject, sender or preview contains this text, ignoring case.")
    var query: String?
    @Option(
      help: ArgumentHelp("Only messages received at or after this date.", valueName: "date"),
      transform: parseDate)
    var from: Date?
    @Option(
      help: ArgumentHelp("Only messages received before this date.", valueName: "date"),
      transform: parseDate)
    var to: Date?
    @Flag(help: "Only unread messages.") var unread = false
    @OptionGroup var pagination: Pagination

    func validate() throws {
      guard query?.isEmpty != true else { throw ValidationError("--query must not be empty.") }
      if let from, let to, to <= from { throw ValidationError("--to must be after --from.") }
    }

    func result() throws -> any Encodable {
      try MailCommand.withStore {
        try $0.messages(
          mailboxID: mailbox, query: query, from: from, to: to, unreadOnly: unread,
          limit: pagination.limit, offset: pagination.offset)
      }
    }
  }

  struct Show: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Show a message with its recipients and text.",
      discussion: "text is null when Mail has not downloaded the message.")

    @Argument(help: ArgumentHelp("A message ID from `mail messages`.", valueName: "id"))
    var id: Int64

    func result() throws -> any Encodable {
      try MailCommand.withStore { try $0.message(id: id) }
    }
  }
}
