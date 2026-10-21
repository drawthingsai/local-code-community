import Foundation
import SQLite3

enum MailStoreError: LocalizedError {
  case noStore
  case messageNotFound(Int64)

  var errorDescription: String? {
    switch self {
    case .noStore: return "Mail has no mailboxes on this Mac. Set up an account in Mail first."
    case .messageNotFound(let id): return "No message has ID \(id)."
    }
  }
}

/// Read-only access to the store Mail keeps in ~/Library/Mail: the Envelope Index database, with
/// one row per message, and an .emlx file for each message Mail has downloaded.
public final class MailStore {
  public struct Mailbox: Encodable, Equatable {
    public var id: Int64
    /// The store's ID for the account, shared by its mailboxes.
    public var account: String
    /// The path on the server, such as INBOX or [Gmail]/All Mail.
    public var name: String
    public var messageCount: Int
    public var unreadCount: Int
  }

  public struct Message: Encodable, Equatable {
    public var id: Int64
    public var mailboxID: Int64
    public var date: Date
    /// The display name and address, such as "Ada Lovelace <ada@example.com>".
    public var sender: String?
    public var subject: String
    /// The start of the text, as Mail shows it in the message list.
    public var preview: String?
    public var read: Bool
    public var flagged: Bool
  }

  public struct MessagePage: Encodable, Equatable {
    public var messages: [Message]
    public var nextOffset: Int?
  }

  public struct MessageDetail: Encodable, Equatable {
    public var id: Int64
    public var mailboxID: Int64
    public var date: Date
    public var sender: String?
    public var to: [String]
    public var cc: [String]
    public var subject: String
    public var read: Bool
    public var flagged: Bool
    public var attachments: [String]
    /// Nil when Mail has not downloaded the message.
    public var text: String?
  }

  private static let columns = """
    m.ROWID, m.mailbox, m.date_received, a.address, a.comment, m.subject_prefix, s.subject,
      su.summary, m.read, m.flagged
    """
  private static let joins = """
    LEFT JOIN subjects s ON s.ROWID = m.subject
      LEFT JOIN addresses a ON a.ROWID = m.sender
      LEFT JOIN summaries su ON su.ROWID = m.summary
    """
  private static let mailboxesQuery = """
    SELECT ROWID, url, total_count, unread_count FROM mailboxes ORDER BY url
    """
  // Gmail keeps each message once, in All Mail, and lists it in other mailboxes by label.
  // Dates count seconds from 1970.
  private static let messagesQuery = """
    SELECT \(columns) FROM messages m \(joins)
    WHERE m.deleted = 0
      AND (?1 IS NULL OR m.mailbox = ?1
        OR m.ROWID IN (SELECT message_id FROM labels WHERE mailbox_id = ?1))
      AND (?2 IS NULL OR m.date_received >= ?2) AND (?3 IS NULL OR m.date_received < ?3)
      AND (?4 = 0 OR m.read = 0)
    ORDER BY m.date_received DESC, m.ROWID DESC
    """
  private static let messageQuery = """
    SELECT \(columns), mb.url FROM messages m JOIN mailboxes mb ON mb.ROWID = m.mailbox \(joins)
    WHERE m.ROWID = ?1
    """
  private static let recipientsQuery = """
    SELECT r.type, a.address, a.comment FROM recipients r JOIN addresses a ON a.ROWID = r.address
    WHERE r.message = ?1 ORDER BY r.type, r.position
    """
  private static let attachmentsQuery = """
    SELECT name FROM attachments WHERE message = ?1 AND name IS NOT NULL ORDER BY ROWID
    """

  private let database: ReadOnlyDatabase
  private let versionDirectory: URL

  /// `directory` is ~/Library/Mail. The caller keeps access to it for the lifetime of this object.
  public init(directory: URL, isCancelled: @escaping () -> Bool = { false }) throws {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
      throw AppDataError.unreadable(app: "Mail", reason: error.localizedDescription)
    }
    // A macOS update can move the store to a new V<n> folder and leave the old one behind.
    let versions = names.compactMap { name -> (number: Int, url: URL)? in
      guard name.first == "V", let number = Int(name.dropFirst()) else { return nil }
      let url = directory.appendingPathComponent(name, isDirectory: true)
      guard
        FileManager.default.fileExists(
          atPath: url.appendingPathComponent("MailData/Envelope Index").path)
      else { return nil }
      return (number, url)
    }
    guard let version = versions.max(by: { $0.number < $1.number }) else {
      throw MailStoreError.noStore
    }
    versionDirectory = version.url
    database = try ReadOnlyDatabase(
      path: version.url.appendingPathComponent("MailData/Envelope Index").path, app: "Mail",
      queries: [
        Self.mailboxesQuery, Self.messagesQuery, Self.messageQuery, Self.recipientsQuery,
        Self.attachmentsQuery,
      ], isCancelled: isCancelled)
  }

  public func mailboxes() throws -> [Mailbox] {
    let statement = try database.prepare(Self.mailboxesQuery)
    defer { sqlite3_finalize(statement) }
    var mailboxes = [Mailbox]()
    while try database.step(statement) {
      guard let location = columnText(statement, 1).flatMap(Self.mailboxLocation) else { continue }
      mailboxes.append(
        Mailbox(
          id: sqlite3_column_int64(statement, 0), account: location.account,
          name: location.path.joined(separator: "/"),
          messageCount: Int(sqlite3_column_int64(statement, 2)),
          unreadCount: Int(sqlite3_column_int64(statement, 3))))
    }
    return mailboxes
  }

  /// Messages, newest first. `query` matches the subject, sender and preview, ignoring case, so
  /// it is matched while scanning rather than in SQL; cancellation interrupts the scan.
  public func messages(
    mailboxID: Int64? = nil, query: String? = nil, from: Date? = nil, to: Date? = nil,
    unreadOnly: Bool = false, limit: Int, offset: Int
  ) throws -> MessagePage {
    let statement = try database.prepare(Self.messagesQuery)
    defer { sqlite3_finalize(statement) }
    if let mailboxID { sqlite3_bind_int64(statement, 1, mailboxID) }
    if let from { sqlite3_bind_double(statement, 2, from.timeIntervalSince1970) }
    if let to { sqlite3_bind_double(statement, 3, to.timeIntervalSince1970) }
    sqlite3_bind_int(statement, 4, unreadOnly ? 1 : 0)
    var messages = [Message]()
    var skipped = 0
    // Read one extra match to tell whether there is another page.
    while messages.count <= limit, try database.step(statement) {
      let message = Self.message(statement)
      if let query,
        ![message.subject, message.sender, message.preview].contains(where: {
          $0?.localizedCaseInsensitiveContains(query) == true
        })
      {
        continue
      }
      guard skipped >= offset else {
        skipped += 1
        continue
      }
      messages.append(message)
    }
    let hasMore = messages.count > limit
    if hasMore { messages.removeLast() }
    return MessagePage(messages: messages, nextOffset: hasMore ? offset + limit : nil)
  }

  /// One message with its recipients, attachment names and text.
  public func message(id: Int64) throws -> MessageDetail {
    let statement = try database.prepare(Self.messageQuery)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, id)
    guard try database.step(statement) else { throw MailStoreError.messageNotFound(id) }
    let message = Self.message(statement)
    let mailboxURL = columnText(statement, 10) ?? ""

    let recipients = try database.prepare(Self.recipientsQuery)
    defer { sqlite3_finalize(recipients) }
    sqlite3_bind_int64(recipients, 1, id)
    var to = [String]()
    var cc = [String]()
    while try database.step(recipients) {
      guard let recipient = Self.address(recipients, 1) else { continue }
      switch sqlite3_column_int(recipients, 0) {
      case 0: to.append(recipient)
      case 1: cc.append(recipient)
      default: break
      }
    }

    let attachments = try database.prepare(Self.attachmentsQuery)
    defer { sqlite3_finalize(attachments) }
    sqlite3_bind_int64(attachments, 1, id)
    var names = [String]()
    while try database.step(attachments) {
      if let name = columnText(attachments, 0) { names.append(name) }
    }

    let text = messageFile(id: id, mailboxURL: mailboxURL)
      .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
      .flatMap(Self.messageBytes(fromEMLX:))
      .flatMap(MIMEText.text(of:))
    return MessageDetail(
      id: message.id, mailboxID: message.mailboxID, date: message.date, sender: message.sender,
      to: to, cc: cc, subject: message.subject, read: message.read, flagged: message.flagged,
      attachments: names, text: text)
  }

  /// Mail keeps each message as <ROWID>.emlx, or .partial.emlx without its attachments. The file
  /// is in its mailbox's folder, under a store folder and one folder for each digit of
  /// ROWID / 1000, least significant first.
  func messageFile(id: Int64, mailboxURL: String) -> URL? {
    guard let location = Self.mailboxLocation(mailboxURL) else { return nil }
    var mailbox = versionDirectory.appendingPathComponent(location.account, isDirectory: true)
    for component in location.path {
      mailbox.appendPathComponent(component + ".mbox", isDirectory: true)
    }
    var messages = "Data"
    var bucket = id / 1000
    while bucket > 0 {
      messages += "/\(bucket % 10)"
      bucket /= 10
    }
    messages += "/Messages"
    let stores = (try? FileManager.default.contentsOfDirectory(atPath: mailbox.path)) ?? []
    for store in stores where !store.hasSuffix(".mbox") {
      for name in ["\(id).emlx", "\(id).partial.emlx"] {
        let file = mailbox.appendingPathComponent("\(store)/\(messages)/\(name)")
        if FileManager.default.fileExists(atPath: file.path) { return file }
      }
    }
    return nil
  }

  /// Splits a mailbox URL, such as imap://<account>/%5BGmail%5D/All%20Mail, into its account and
  /// decoded path components. An encoded slash stays inside its component.
  static func mailboxLocation(_ url: String) -> (account: String, path: [String])? {
    guard let scheme = url.range(of: "://") else { return nil }
    let parts = url[scheme.upperBound...].split(separator: "/")
    guard parts.count > 1 else { return nil }
    return (String(parts[0]), parts.dropFirst().map { $0.removingPercentEncoding ?? String($0) })
  }

  /// An .emlx file holds the message's byte count on its first line, the message, and then a
  /// property list of Mail's flags.
  static func messageBytes(fromEMLX data: Data) -> [UInt8]? {
    guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
      let count = Int(
        String(decoding: data[data.startIndex..<newline], as: UTF8.self)
          .trimmingCharacters(in: .whitespaces)),
      count >= 0, count <= data.endIndex - newline - 1
    else { return nil }
    return Array(data[(newline + 1)..<(newline + 1 + count)])
  }

  private static func message(_ statement: OpaquePointer) -> Message {
    // Mail keeps reply and forward prefixes, such as "Re: ", apart from the subject.
    var subject = columnText(statement, 5) ?? ""
    if let last = subject.last, !last.isWhitespace { subject += " " }
    subject += columnText(statement, 6) ?? ""
    return Message(
      id: sqlite3_column_int64(statement, 0), mailboxID: sqlite3_column_int64(statement, 1),
      date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
      sender: address(statement, 3), subject: subject,
      preview: columnText(statement, 7).flatMap { $0.isEmpty ? nil : $0 },
      read: sqlite3_column_int(statement, 8) != 0, flagged: sqlite3_column_int(statement, 9) != 0)
  }

  /// Reads an address column followed by its display name column.
  private static func address(_ statement: OpaquePointer, _ column: Int32) -> String? {
    guard let address = columnText(statement, column), !address.isEmpty else { return nil }
    guard let name = columnText(statement, column + 1), !name.isEmpty, name != address else {
      return address
    }
    return "\(name) <\(address)>"
  }
}
