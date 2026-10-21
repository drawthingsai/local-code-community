import Foundation
import SQLite3
import UniformTypeIdentifiers

enum NoteStoreError: LocalizedError {
  case noteNotFound(String)

  var errorDescription: String? {
    switch self {
    case .noteNotFound(let id): return "No note has ID \(id)."
    }
  }
}

/// Read-only access to the store Notes keeps in ~/Library/Group Containers/group.com.apple.notes:
/// NoteStore.sqlite, a Core Data store with accounts, folders, notes and attachments as rows of
/// one table, and the attachment files under Accounts/<account>/. Like the Obsidian Importer,
/// this decodes the text and tables of notes from their protobufs.
final class NoteStore {
  struct Folder: Encodable, Equatable {
    var id: Int64
    var account: String
    var name: String
    var parentID: Int64?
    /// Recently Deleted, whose notes `list` leaves out unless asked for this folder.
    var recentlyDeleted: Bool
    var noteCount: Int
    var accountID: Int64?
    /// The Notes folder that each account starts with.
    var isDefault: Bool

    private enum CodingKeys: String, CodingKey {
      case id, account, name, parentID, recentlyDeleted, noteCount
    }
  }

  struct Note: Encodable, Equatable {
    var id: Int64
    var folderID: Int64
    var folder: String?
    var title: String
    /// The start of the text after the title, as Notes shows it in the note list.
    var snippet: String?
    var created: Date?
    var modified: Date?
    var pinned: Bool
    /// Locked with a password, so its text cannot be read.
    var locked: Bool
  }

  struct NotePage: Encodable, Equatable {
    var notes: [Note]
    var nextOffset: Int?
  }

  struct Attachment: Encodable, Equatable {
    var id: Int64
    /// The uniform type identifier, such as public.jpeg, or com.apple.paper for a drawing.
    var type: String
    var name: String
    /// False when the file is only in iCloud.
    var available: Bool
    /// The handwriting that Notes recognized in a drawing.
    var handwriting: String?
    var file: URL?

    private enum CodingKeys: String, CodingKey {
      case id, type, name, available, handwriting
    }
  }

  struct NoteDetail: Encodable, Equatable {
    var id: Int64
    var folderID: Int64
    var folder: String?
    var title: String
    var created: Date?
    var modified: Date?
    var pinned: Bool
    var locked: Bool
    /// Markdown, where each attachment links to attachment:<id>; nil for a locked note.
    var text: String?
    var attachments: [Attachment]
  }

  private struct AttachmentRow {
    var id: Int64
    var identifier: String
    var type: String?
    var altText: String?
    var linkTarget: String?
    var title: String?
    var url: String?
    var mergeableData: Data?
    var fallbackImageGeneration: String?
    var fallbackPDFGeneration: String?
    var handwriting: String?
    var width: Int64
    var height: Int64
    var mediaIdentifier: String?
    var mediaFilename: String?
    var mediaGeneration: String?
  }

  private static let entitiesQuery = "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY"
  // Smart folders only show notes from other folders.
  private static let foldersQuery = """
    SELECT f.Z_PK, a.ZNAME, f.ZTITLE2, f.ZPARENT, f.ZFOLDERTYPE,
      (SELECT COUNT(*) FROM ZICCLOUDSYNCINGOBJECT n WHERE n.Z_ENT = ?2 AND n.ZFOLDER = f.Z_PK
        AND n.ZTITLE1 IS NOT NULL AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0),
      f.ZOWNER, f.ZIDENTIFIER
    FROM ZICCLOUDSYNCINGOBJECT f LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = f.ZOWNER
    WHERE f.Z_ENT = ?1 AND f.ZTITLE2 IS NOT NULL AND IFNULL(f.ZFOLDERTYPE, 0) != 3
      AND IFNULL(f.ZMARKEDFORDELETION, 0) = 0
    ORDER BY a.ZNAME, f.ZTITLE2
    """
  // Columns that older versions of Notes lack read as NULL. Dates count seconds from 2001.
  private static let noteColumns = """
    n.Z_PK, n.ZFOLDER, f.ZTITLE2, n.ZTITLE1, n.ZSNIPPET,
      COALESCE(NULLIF(n.ZCREATIONDATE3, 0), NULLIF(n.ZCREATIONDATE2, 0), n.ZCREATIONDATE1),
      n.ZMODIFICATIONDATE1, n.ZISPINNED, n.ZISPASSWORDPROTECTED, d.ZDATA, a.ZIDENTIFIER
    """
  private static let noteJoins = """
    (SELECT *, NULL AS ZCREATIONDATE3, NULL AS ZCREATIONDATE2 FROM ZICCLOUDSYNCINGOBJECT) n
      LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER
      LEFT JOIN ZICCLOUDSYNCINGOBJECT a ON a.Z_PK = f.ZOWNER
      LEFT JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
    """
  private static let notesQuery = """
    SELECT \(noteColumns) FROM \(noteJoins)
    WHERE n.Z_ENT = ?1 AND n.ZTITLE1 IS NOT NULL AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0
      AND (?2 IS NULL OR n.ZFOLDER = ?2) AND (?2 IS NOT NULL OR IFNULL(f.ZFOLDERTYPE, 0) != 1)
      AND (?3 IS NULL OR n.ZMODIFICATIONDATE1 >= ?3) AND (?4 IS NULL OR n.ZMODIFICATIONDATE1 < ?4)
      AND (?5 = 0 OR n.ZISPINNED = 1)
    ORDER BY n.ZMODIFICATIONDATE1 DESC, n.Z_PK DESC
    """
  private static let noteQuery = """
    SELECT \(noteColumns) FROM \(noteJoins) WHERE n.Z_ENT = ?1 AND n.Z_PK = ?2
    """
  private static let identifierQuery = """
    SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ?1 AND ZIDENTIFIER = ?2
    """
  private static let attachmentQuery = """
    SELECT t.Z_PK, t.ZIDENTIFIER, t.ZTYPEUTI, t.ZALTTEXT, t.ZTOKENCONTENTIDENTIFIER, t.ZTITLE,
      t.ZURLSTRING, t.ZMERGEABLEDATA1, t.ZFALLBACKIMAGEGENERATION, t.ZFALLBACKPDFGENERATION,
      t.ZHANDWRITINGSUMMARY, t.ZSIZEWIDTH, t.ZSIZEHEIGHT, m.ZIDENTIFIER, m.ZFILENAME,
      m.ZGENERATION1
    FROM (SELECT *, NULL AS ZTOKENCONTENTIDENTIFIER, NULL AS ZFALLBACKIMAGEGENERATION,
        NULL AS ZFALLBACKPDFGENERATION, NULL AS ZHANDWRITINGSUMMARY FROM ZICCLOUDSYNCINGOBJECT) t
      LEFT JOIN (SELECT *, NULL AS ZGENERATION1 FROM ZICCLOUDSYNCINGOBJECT) m ON m.Z_PK = t.ZMEDIA
    WHERE t.ZIDENTIFIER = ?1
    """

  private let database: ReadOnlyDatabase
  private let directory: URL
  private let folderEntity: Int64
  private let noteEntity: Int64

  /// `directory` is ~/Library/Group Containers/group.com.apple.notes. The caller keeps access to
  /// it for the lifetime of this object.
  init(directory: URL, isCancelled: @escaping () -> Bool = { false }) throws {
    self.directory = directory
    database = try ReadOnlyDatabase(
      path: directory.appendingPathComponent("NoteStore.sqlite").path, app: "Notes",
      queries: [
        Self.entitiesQuery, Self.foldersQuery, Self.notesQuery, Self.noteQuery,
        Self.identifierQuery, Self.attachmentQuery,
      ], isCancelled: isCancelled)
    // Each kind of row has its own entity number.
    let statement = try database.prepare(Self.entitiesQuery)
    defer { sqlite3_finalize(statement) }
    var entities = [String: Int64]()
    while try database.step(statement) {
      if let name = columnText(statement, 0) { entities[name] = sqlite3_column_int64(statement, 1) }
    }
    guard let folderEntity = entities["ICFolder"], let noteEntity = entities["ICNote"] else {
      throw AppDataError.unsupportedSchema(app: "Notes", reason: "no folders or notes")
    }
    self.folderEntity = folderEntity
    self.noteEntity = noteEntity
  }

  func folders() throws -> [Folder] {
    let statement = try database.prepare(Self.foldersQuery)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, folderEntity)
    sqlite3_bind_int64(statement, 2, noteEntity)
    var folders = [Folder]()
    while try database.step(statement) {
      folders.append(
        Folder(
          id: sqlite3_column_int64(statement, 0), account: columnText(statement, 1) ?? "",
          name: columnText(statement, 2) ?? "",
          parentID: sqlite3_column_type(statement, 3) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 3),
          recentlyDeleted: sqlite3_column_int(statement, 4) == 1,
          noteCount: Int(sqlite3_column_int64(statement, 5)),
          accountID: sqlite3_column_type(statement, 6) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 6),
          isDefault: columnText(statement, 7)?.hasPrefix("DefaultFolder") == true))
    }
    return folders
  }

  /// Notes, most recently modified first. Without `folderID`, this leaves out Recently Deleted.
  /// `query` matches the title and text, ignoring case, so it is matched while scanning rather
  /// than in SQL; cancellation interrupts the scan.
  func notes(
    folderID: Int64? = nil, query: String? = nil, from: Date? = nil, to: Date? = nil,
    pinnedOnly: Bool = false, limit: Int, offset: Int
  ) throws -> NotePage {
    let statement = try database.prepare(Self.notesQuery)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, noteEntity)
    if let folderID { sqlite3_bind_int64(statement, 2, folderID) }
    if let from { sqlite3_bind_double(statement, 3, from.timeIntervalSinceReferenceDate) }
    if let to { sqlite3_bind_double(statement, 4, to.timeIntervalSinceReferenceDate) }
    sqlite3_bind_int(statement, 5, pinnedOnly ? 1 : 0)
    var notes = [Note]()
    var skipped = 0
    // Read one extra match to tell whether there is another page.
    while notes.count <= limit, try database.step(statement) {
      let note = Self.note(statement)
      if let query,
        ![note.title, note.snippet].contains(where: {
          $0?.localizedCaseInsensitiveContains(query) == true
        })
      {
        // A locked note's text is encrypted.
        guard !note.locked, let data = Self.data(statement, 9),
          NoteDocument.note(fromData: data)?.text.localizedCaseInsensitiveContains(query) == true
        else { continue }
      }
      guard skipped >= offset else {
        skipped += 1
        continue
      }
      notes.append(note)
    }
    let hasMore = notes.count > limit
    if hasMore { notes.removeLast() }
    return NotePage(notes: notes, nextOffset: hasMore ? offset + limit : nil)
  }

  func noteID(_ reference: NoteReference) throws -> Int64 {
    switch reference {
    case .id(let id): return id
    case .identifier(let identifier):
      let statement = try database.prepare(Self.identifierQuery)
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, noteEntity)
      sqlite3_bind_text(statement, 2, identifier, -1, SQLITE_TRANSIENT)
      guard try database.step(statement) else { throw NoteStoreError.noteNotFound(identifier) }
      return sqlite3_column_int64(statement, 0)
    }
  }

  /// One note with its text as Markdown and its attachments.
  func note(id: Int64) throws -> NoteDetail {
    let statement = try database.prepare(Self.noteQuery)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, noteEntity)
    sqlite3_bind_int64(statement, 2, id)
    guard try database.step(statement) else { throw NoteStoreError.noteNotFound(String(id)) }
    let note = Self.note(statement)
    var text: String?
    var attachments = [Attachment]()
    if !note.locked, let data = Self.data(statement, 9),
      let document = NoteDocument.note(fromData: data)
    {
      text = try markdown(
        document, isTableCell: false, account: columnText(statement, 10),
        attachments: &attachments)
    }
    return NoteDetail(
      id: note.id, folderID: note.folderID, folder: note.folder, title: note.title,
      created: note.created, modified: note.modified, pinned: note.pinned, locked: note.locked,
      text: text, attachments: attachments)
  }

  private func markdown(
    _ note: NoteDocument.Note, isTableCell: Bool, account: String?,
    attachments: inout [Attachment]
  ) throws -> String {
    var failure: Error?
    let markdown = NoteMarkdown.markdown(note, isTableCell: isTableCell) { info in
      do {
        return try self.markdown(info, account: account, attachments: &attachments)
      } catch {
        failure = failure ?? error
        return ""
      }
    }
    if let failure { throw failure }
    return markdown
  }

  /// Like the Obsidian Importer, this reads each kind of attachment from its own place.
  private func markdown(
    _ info: NoteDocument.AttachmentInfo, account: String?, attachments: inout [Attachment]
  ) throws -> String {
    let row = try attachmentRow(info.identifier)
    switch info.type {
    case "com.apple.notes.inlinetextattachment.hashtag",
      "com.apple.notes.inlinetextattachment.mention":
      return row?.altText ?? ""
    case "com.apple.notes.inlinetextattachment.link":
      guard let target = row?.linkTarget else { return row?.altText ?? "" }
      return "[\(row?.altText ?? target)](\(NoteMarkdown.destination(target)))"
    case "public.url":
      guard let url = row?.url else { break }
      guard let title = row?.title, !title.isEmpty else { return "<\(url)>" }
      return "[\(title)](\(NoteMarkdown.destination(url)))"
    case "com.apple.notes.table":
      guard let data = row?.mergeableData,
        let cells = NoteDocument.MergeableData(data: data)?.tableCells(), !cells.isEmpty
      else { break }
      return NoteMarkdown.table(
        try cells.map { row in
          try row.map { cell in
            try cell.map {
              try markdown($0, isTableCell: true, account: account, attachments: &attachments)
            } ?? ""
          }
        })
    case "com.apple.notes.gallery":
      // A scan, whose pages are attachments of their own.
      guard let data = row?.mergeableData,
        let pages = NoteDocument.MergeableData(data: data)?.scanPageIdentifiers(), !pages.isEmpty
      else { break }
      var links = [String]()
      for identifier in pages {
        guard let page = try attachmentRow(identifier) else { continue }
        let preview = "Previews/\(page.identifier)-1-\(page.width)x\(page.height)-0.jpeg"
        let attachment =
          file(preview, account: account).map {
            Attachment(
              id: page.id, type: "public.jpeg", name: "Scan Page.jpg", available: true, file: $0)
          } ?? self.attachment(page, type: page.type ?? "public.jpeg", account: account)
        guard let attachment else { continue }
        links.append(Self.link(attachment, attachments: &attachments))
      }
      return "\n" + links.joined(separator: "\n") + "\n"
    default:
      guard let row, let attachment = attachment(row, type: info.type, account: account) else {
        break
      }
      return "\n" + Self.link(attachment, attachments: &attachments) + "\n"
    }
    return "(unsupported attachment: \(info.type))"
  }

  /// A drawing, a modified scan, or a file such as an image, PDF or recording.
  private func attachment(_ row: AttachmentRow, type: String, account: String?) -> Attachment? {
    let path: [String?]
    let name: String
    var handwriting: String?
    switch type {
    case "com.apple.paper.doc.scan":
      path = ["FallbackPDFs", row.identifier, row.fallbackPDFGeneration, "FallbackPDF.pdf"]
      name = "Scan.pdf"
    case "com.apple.paper", "com.apple.drawing", "com.apple.drawing.2":
      if let generation = row.fallbackImageGeneration, !generation.isEmpty {
        path = ["FallbackImages", row.identifier, generation, "FallbackImage.png"]
        name = "Drawing.png"
      } else {
        path = ["FallbackImages", row.identifier + ".jpg"]
        name = "Drawing.jpg"
      }
      handwriting = row.handwriting.flatMap { $0.isEmpty ? nil : $0 }
    default:
      guard let media = row.mediaIdentifier, let filename = row.mediaFilename, !filename.isEmpty
      else { return nil }
      path = ["Media", media, row.mediaGeneration, filename]
      name = (filename as NSString).lastPathComponent
    }
    let relativePath = path.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    let file = file(relativePath, account: account)
    return Attachment(
      id: row.id, type: type, name: name, available: file != nil, handwriting: handwriting,
      file: file)
  }

  /// Notes keeps attachment files in the account's folder, and older versions kept them at the top.
  private func file(_ relativePath: String, account: String?) -> URL? {
    let candidates =
      (account.map { ["Accounts/\($0)/\(relativePath)"] } ?? []) + [relativePath]
    return candidates.lazy.map { self.directory.appendingPathComponent($0) }.first {
      FileManager.default.fileExists(atPath: $0.path)
    }
  }

  private func attachmentRow(_ identifier: String) throws -> AttachmentRow? {
    let statement = try database.prepare(Self.attachmentQuery)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, identifier, -1, SQLITE_TRANSIENT)
    guard try database.step(statement) else { return nil }
    return AttachmentRow(
      id: sqlite3_column_int64(statement, 0), identifier: columnText(statement, 1) ?? identifier,
      type: columnText(statement, 2), altText: columnText(statement, 3),
      linkTarget: columnText(statement, 4), title: columnText(statement, 5),
      url: columnText(statement, 6), mergeableData: Self.data(statement, 7),
      fallbackImageGeneration: columnText(statement, 8),
      fallbackPDFGeneration: columnText(statement, 9), handwriting: columnText(statement, 10),
      width: sqlite3_column_int64(statement, 11), height: sqlite3_column_int64(statement, 12),
      mediaIdentifier: columnText(statement, 13), mediaFilename: columnText(statement, 14),
      mediaGeneration: columnText(statement, 15))
  }

  /// Images are embedded and other files are linked.
  private static func link(_ attachment: Attachment, attachments: inout [Attachment]) -> String {
    if !attachments.contains(where: { $0.id == attachment.id }) { attachments.append(attachment) }
    let isImage =
      UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.conforms(to: .image)
      ?? false
    return "\(isImage ? "!" : "")[\(attachment.name)](attachment:\(attachment.id))"
  }

  private static func note(_ statement: OpaquePointer) -> Note {
    func date(_ column: Int32) -> Date? {
      sqlite3_column_type(statement, column) == SQLITE_NULL
        ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, column))
    }
    return Note(
      id: sqlite3_column_int64(statement, 0), folderID: sqlite3_column_int64(statement, 1),
      folder: columnText(statement, 2), title: columnText(statement, 3) ?? "",
      snippet: columnText(statement, 4).flatMap { $0.isEmpty ? nil : $0 }, created: date(5),
      modified: date(6), pinned: sqlite3_column_int(statement, 7) != 0,
      locked: sqlite3_column_int(statement, 8) != 0)
  }

  private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
    guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
  }
}

/// SQLite copies the text before the call returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
