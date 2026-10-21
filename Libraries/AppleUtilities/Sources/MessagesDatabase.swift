import Foundation
import SQLite3
import TypedStream

/// A read-only connection to the Messages database, `chat.db`.
public final class MessagesDatabase {
  public struct Chat: Encodable, Equatable {
    public var id: Int64
    /// The group name; nil for chats without one.
    public var name: String?
    /// The phone number or email of a one-to-one chat, or a group's identifier.
    public var identifier: String
    public var participants: [String]
    public var lastMessageDate: Date?
  }

  public struct ChatPage: Encodable, Equatable {
    public var chats: [Chat]
    public var nextOffset: Int?
  }

  public struct Message: Encodable, Equatable {
    public var id: Int64
    public var chatID: Int64?
    public var date: Date
    public var fromMe: Bool
    /// The sender's phone number or email; nil for messages sent from this account.
    public var sender: String?
    /// Nil for messages without text, such as attachments.
    public var text: String?
  }

  public struct MessagePage: Encodable, Equatable {
    public var messages: [Message]
    public var nextBeforeID: Int64?
  }

  // Dates count from 2001, in seconds before macOS 10.13 and in nanoseconds since.
  private static let date = "(CASE WHEN m.date > 1000000000000 THEN m.date / 1e9 ELSE m.date END)"
  private static let chatsQuery = """
    SELECT c.ROWID, c.display_name, c.chat_identifier,
      (SELECT group_concat(h.id, char(10)) FROM chat_handle_join j
        JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = c.ROWID),
      (SELECT MAX(\(date)) FROM chat_message_join j
        JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID) AS last_date
    FROM chat c ORDER BY last_date DESC, c.ROWID DESC LIMIT ?1 OFFSET ?2
    """
  private static let messagesQuery = """
    SELECT m.ROWID, m.text, m.attributedBody, \(date), m.is_from_me, h.id,
      (SELECT chat_id FROM chat_message_join WHERE message_id = m.ROWID LIMIT 1)
    FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE m.ROWID < ?1
      AND (?2 IS NULL OR m.ROWID IN (SELECT message_id FROM chat_message_join WHERE chat_id = ?2))
      AND (?3 IS NULL OR \(date) >= ?3) AND (?4 IS NULL OR \(date) < ?4)
    ORDER BY m.ROWID DESC
    """

  private let database: ReadOnlyDatabase

  /// The caller keeps access to `directory` for the lifetime of this object.
  public init(directory: URL, isCancelled: @escaping () -> Bool = { false }) throws {
    database = try ReadOnlyDatabase(
      path: directory.appendingPathComponent("chat.db").path, app: "Messages",
      queries: [Self.chatsQuery, Self.messagesQuery], isCancelled: isCancelled)
  }

  /// Chats, most recently active first.
  public func chats(limit: Int, offset: Int) throws -> ChatPage {
    let statement = try database.prepare(Self.chatsQuery)
    defer { sqlite3_finalize(statement) }
    // Read one extra chat to tell whether there is another page. SQLite reads a negative limit
    // as no limit, which also covers the largest one.
    sqlite3_bind_int64(statement, 1, limit < Int.max ? Int64(limit + 1) : -1)
    sqlite3_bind_int64(statement, 2, Int64(offset))
    var chats = [Chat]()
    while try database.step(statement) {
      chats.append(
        Chat(
          id: sqlite3_column_int64(statement, 0),
          name: columnText(statement, 1).flatMap { $0.isEmpty ? nil : $0 },
          identifier: columnText(statement, 2) ?? "",
          participants: columnText(statement, 3)?.split(separator: "\n").map(String.init).sorted()
            ?? [],
          lastMessageDate: sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 4))))
    }
    let hasMore = chats.count > limit
    return ChatPage(chats: Array(chats.prefix(limit)), nextOffset: hasMore ? offset + limit : nil)
  }

  /// Messages, newest first. Most message text is archived, so `query` is matched while
  /// scanning rather than in SQL; cancellation interrupts the scan.
  public func messages(
    chatID: Int64? = nil, query: String? = nil, from: Date? = nil, to: Date? = nil,
    beforeID: Int64? = nil, limit: Int
  ) throws -> MessagePage {
    let statement = try database.prepare(Self.messagesQuery)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, beforeID ?? .max)
    if let chatID { sqlite3_bind_int64(statement, 2, chatID) }
    if let from { sqlite3_bind_double(statement, 3, from.timeIntervalSinceReferenceDate) }
    if let to { sqlite3_bind_double(statement, 4, to.timeIntervalSinceReferenceDate) }
    var messages = [Message]()
    // Read one extra match to tell whether there is another page.
    while messages.count <= limit, try database.step(statement) {
      var body = columnText(statement, 1)
      if body == nil, let bytes = sqlite3_column_blob(statement, 2) {
        body = Self.decodeBody(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2))))
      }
      if let query, body?.localizedCaseInsensitiveContains(query) != true { continue }
      let fromMe = sqlite3_column_int(statement, 4) != 0
      messages.append(
        Message(
          id: sqlite3_column_int64(statement, 0),
          chatID: sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 6),
          date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 3)),
          fromMe: fromMe, sender: fromMe ? nil : columnText(statement, 5), text: body))
    }
    let hasMore = messages.count > limit
    if hasMore { messages.removeLast() }
    return MessagePage(messages: messages, nextBeforeID: hasMore ? messages.last?.id : nil)
  }

  /// Reads the first NSString in an attributed string archive. Unlike Madrid's `stringValue`,
  /// this keeps emoji-only text and text containing "NS", and skips attribute metadata.
  static func decodeBody(_ data: Data) -> String? {
    guard let objects = try? TypedStreamDecoder.decode(data) else { return nil }
    for object in objects {
      if case .object(let type, let values) = object,
        type.name == "NSString" || type.name == "NSMutableString",
        let first = values.first, case .string(let value) = first
      {
        return value
      }
    }
    return nil
  }
}
