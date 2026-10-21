import ArgumentParser
import BashToolContext
import Foundation
import SQLite3
import XCTest
import ios_system

@testable import AppleUtilities

final class AppleUtilitiesTests: XCTestCase {
  private static let register: Void = {
    initializeEnvironment()
    precondition(ios_registerCommand("calendar", calendar_main) != 0)
  }()

  func testCalendarOptionsAcceptDashesEqualsAndLocalDates() throws {
    let create = try XCTUnwrap(
      CalendarCommand.parseAsRoot([
        "events", "create", "--title=Team sync", "--start", "2026-10-03T19:00", "--notes",
        "-- bring slides", "--location", "-1 floor", "--all-day",
      ]) as? CalendarCommand.Events.Create)
    XCTAssertEqual(create.title, "Team sync")
    XCTAssertEqual(create.notes, "-- bring slides")
    XCTAssertEqual(create.location, "-1 floor")
    XCTAssertTrue(create.allDay)
    XCTAssertNil(create.end)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    XCTAssertEqual(
      create.start, calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 19)))

    let update = try XCTUnwrap(
      CalendarCommand.parseAsRoot(["events", "update", "EVENT:1", "--no-all-day", "--notes", ""])
        as? CalendarCommand.Events.Update)
    XCTAssertEqual(update.id, "EVENT:1")
    XCTAssertEqual(update.allDay, false)
    XCTAssertEqual(update.notes, "")
    XCTAssertThrowsError(try CalendarCommand.parseAsRoot(["events", "update", "EVENT:1"]))
  }

  func testCalendarEventsListValidatesRange() throws {
    let list = try XCTUnwrap(
      CalendarCommand.parseAsRoot([
        "events", "list", "--from", "2026-10-03T09:00:00-04:00", "--to", "2026-10-04T13:00:00Z",
        "--calendar", "A", "--calendar", "B", "--limit", "5",
      ]) as? CalendarCommand.Events.List)
    XCTAssertEqual(try XCTUnwrap(list.to).timeIntervalSince(try XCTUnwrap(list.from)), 86_400)
    XCTAssertEqual(list.calendar, ["A", "B"])
    XCTAssertEqual(list.pagination.limit, 5)
    for arguments in [
      ["events", "list", "--from", "2026-10-04", "--to", "2026-10-03"],
      ["events", "list", "--from", "2026-01-01", "--to", "2031-01-01"],
      ["events", "list", "--from", "tomorrow"],
      ["events", "list", "--limit", "0"],
      ["events", "list", "--sql", "anything"],
    ] {
      XCTAssertThrowsError(try CalendarCommand.parseAsRoot(arguments), "\(arguments)")
    }
  }

  func testIMessageOptions() throws {
    let messages = try XCTUnwrap(
      IMessageCommand.parseAsRoot([
        "messages", "--chat=3", "--query", "-1 ' OR 1=1 --", "--before-id", "42",
      ]) as? IMessageCommand.Messages)
    XCTAssertEqual(messages.chat, 3)
    XCTAssertEqual(messages.query, "-1 ' OR 1=1 --")
    XCTAssertEqual(messages.beforeID, 42)
    XCTAssertEqual(messages.limit, 50)
    for arguments in [
      ["messages", "--chat", "1 OR 1=1"], ["messages", "--query", ""],
      ["messages", "--limit", "0"],
      ["messages", "--from", "2026-10-04", "--to", "2026-10-03"], ["chats", "--offset", "-1"],
      ["send", "hello"],
    ] {
      XCTAssertThrowsError(try IMessageCommand.parseAsRoot(arguments), "\(arguments)")
    }
  }

  func testMailOptions() throws {
    let messages = try XCTUnwrap(
      MailCommand.parseAsRoot([
        "messages", "--mailbox=3", "--query", "-1 ' OR 1=1 --", "--unread", "--limit", "5",
        "--offset", "10",
      ]) as? MailCommand.Messages)
    XCTAssertEqual(messages.mailbox, 3)
    XCTAssertEqual(messages.query, "-1 ' OR 1=1 --")
    XCTAssertTrue(messages.unread)
    XCTAssertEqual(messages.pagination.limit, 5)
    XCTAssertEqual(messages.pagination.offset, 10)
    let show = try XCTUnwrap(MailCommand.parseAsRoot(["show", "42"]) as? MailCommand.Show)
    XCTAssertEqual(show.id, 42)
    for arguments in [
      ["messages", "--mailbox", "INBOX"], ["messages", "--query", ""],
      ["messages", "--limit", "0"], ["messages", "--from", "ada@example.com"],
      ["messages", "--from", "2026-10-04", "--to", "2026-10-03"], ["show"], ["show", "abc"],
      ["send", "hello"],
    ] {
      XCTAssertThrowsError(try MailCommand.parseAsRoot(arguments), "\(arguments)")
    }
  }

  func testPhotosOptions() throws {
    let list = try XCTUnwrap(
      PhotosCommand.parseAsRoot([
        "list", "--subtype", "screenshot", "--subtype", "live", "--near", "-33.86,151.21",
        "--radius", "2.5", "--favorite", "--type", "video", "--limit", "5",
      ]) as? PhotosCommand.List)
    XCTAssertEqual(list.subtype, ["screenshot", "live"])
    XCTAssertEqual(list.near, PhotoLibrary.Coordinate(latitude: -33.86, longitude: 151.21))
    XCTAssertEqual(list.radius, 2.5)
    XCTAssertEqual(list.type, .video)
    XCTAssertTrue(list.favorite)
    XCTAssertEqual(list.pagination.limit, 5)
    let add = try XCTUnwrap(
      PhotosCommand.parseAsRoot(["albums", "add", "ALBUM/L0/040", "A", "B"])
        as? PhotosCommand.Albums.Add)
    XCTAssertEqual(add.albumID, "ALBUM/L0/040")
    XCTAssertEqual(add.ids, ["A", "B"])
    let update = try XCTUnwrap(
      PhotosCommand.parseAsRoot(["update", "A", "--no-favorite", "--location", "-1,-2"])
        as? PhotosCommand.Update)
    XCTAssertEqual(update.favorite, false)
    XCTAssertEqual(update.location, "-1,-2")
    XCTAssertNoThrow(try PhotosCommand.parseAsRoot(["update", "A", "--location", ""]))
    for arguments in [
      ["list", "--subtype", "selfie"], ["list", "--album", "A", "--burst", "B"],
      ["list", "--radius", "1"], ["list", "--near", "100,0"], ["list", "--near", "1"],
      ["list", "--from", "2026-10-04", "--to", "2026-10-03"], ["list", "--type", "image"],
      ["update", "A"], ["update", "A", "--rating", "6"], ["update", "A", "--location", "north"],
      ["export", "A", "--original", "--jpeg"], ["export", "A", "--max-size", "100"],
      ["export", "A", "--jpeg", "--max-size", "0"], ["show"], ["edit", "A"],
      ["albums", "rename", "A"], ["share", "A"],
    ] {
      XCTAssertThrowsError(try PhotosCommand.parseAsRoot(arguments), "\(arguments)")
    }
  }

  func testPhotoMetadataRequiresSupportedSDKAndOS() {
    #if !compiler(>=6.4)
      XCTAssertFalse(PhotoLibrary.supportsExtendedMetadata)
    #endif
    for arguments in [
      ["list", "--query", "notes"], ["update", "A", "--caption", "notes"],
      ["update", "A", "--add-keyword", "notes"], ["update", "A", "--remove-keyword", "notes"],
      ["update", "A", "--rating", "3"],
    ] {
      if PhotoLibrary.supportsExtendedMetadata {
        XCTAssertNoThrow(try PhotosCommand.parseAsRoot(arguments), "\(arguments)")
      } else {
        XCTAssertThrowsError(try PhotosCommand.parseAsRoot(arguments), "\(arguments)") { error in
          XCTAssertTrue(String(describing: error).contains("corresponding SDK"))
        }
      }
    }
  }

  func testPhotosNeedsLocalCodeBeforeReadingTheLibrary() {
    let status = run(PhotosCommand.self, ["status"])
    XCTAssertEqual(status.status, 0)
    XCTAssertTrue(status.output.contains("\"authorized\":false"))
    let list = run(PhotosCommand.self, ["list"])
    XCTAssertEqual(list.status, 1)
    XCTAssertTrue(list.error.contains("only available in Local Code"))
    let help = run(PhotosCommand.self, ["albums"])
    XCTAssertEqual(help.status, 0)
    XCTAssertTrue(help.output.contains("move"))
  }

  func testPhotoIDs() {
    XCTAssertEqual(PhotoLibrary.assetID(inPath: "photos://ABC-1"), "ABC-1")
    XCTAssertEqual(PhotoLibrary.assetID(inPath: "Photos://ABC/L0/001"), "ABC/L0/001")
    XCTAssertNil(PhotoLibrary.assetID(inPath: "photos://"))
    XCTAssertNil(PhotoLibrary.assetID(inPath: "photos/ABC.jpg"))
    XCTAssertEqual(PhotoLibrary.id(forLocalIdentifier: "ABC/L0/001"), "ABC")
    XCTAssertEqual(PhotoLibrary.id(forLocalIdentifier: "ABC/L0/040"), "ABC/L0/040")
    XCTAssertEqual(PhotoLibrary.localIdentifier(forAssetID: "ABC"), "ABC/L0/001")
    XCTAssertEqual(PhotoLibrary.localIdentifier(forAssetID: "photos://ABC"), "ABC/L0/001")
    XCTAssertEqual(PhotoLibrary.localIdentifier(forAssetID: "ABC/L0/002"), "ABC/L0/002")
  }

  func testPhotoChangesCombineInOrder() {
    var changes = PhotosCommand.Changes.NetChanges()
    changes.apply(inserted: ["A", "B"], updated: ["C"], deleted: [])
    changes.apply(inserted: [], updated: ["A", "D"], deleted: ["B", "C", "E"])
    let result = changes.changes(id: { $0 })
    XCTAssertEqual(result.inserted, ["A"])
    XCTAssertEqual(result.updated, ["D"])
    XCTAssertEqual(result.deleted, ["C", "E"])
  }

  func testPhotoExportKeepsExistingFiles() throws {
    let directory = try temporaryDirectory()
    let first = availableURL(directory, name: "IMG_1", extension: "HEIC")
    XCTAssertEqual(first.lastPathComponent, "IMG_1.HEIC")
    try Data().write(to: first)
    XCTAssertEqual(
      availableURL(directory, name: "IMG_1", extension: "HEIC")
        .lastPathComponent, "IMG_1-1.HEIC")
  }

  func testRunPrintsHelpAndUsageWithoutTouchingData() {
    let help = run(CalendarCommand.self, ["events", "create", "--help"])
    XCTAssertEqual(help.status, 0)
    XCTAssertTrue(help.output.contains("--all-day"))
    let group = run(IMessageCommand.self, [])
    XCTAssertEqual(group.status, 0)
    XCTAssertTrue(group.output.contains("chats"))
    let nested = run(CalendarCommand.self, ["events"])
    XCTAssertEqual(nested.status, 0)
    XCTAssertTrue(nested.output.contains("delete"))
    let usage = run(CalendarCommand.self, ["events", "list", "--from", "tomorrow"])
    XCTAssertEqual(usage.status, 64)
    XCTAssertTrue(usage.error.contains("--from"))
    XCTAssertEqual(usage.output, "")
  }

  func testCancelledCommandDoesNotRun() {
    Probe.Action.runs = 0
    XCTAssertEqual(run(Probe.self, ["action"], isCancelled: true).status, 130)
    XCTAssertEqual(Probe.Action.runs, 0)
    XCTAssertEqual(run(Probe.self, ["action"]).status, 0)
    XCTAssertEqual(Probe.Action.runs, 1)
  }

  func testRegisteredCommandWritesToSessionStreams() throws {
    _ = Self.register
    let output = tmpfile()!
    let error = tmpfile()!
    let session = try XCTUnwrap(strdup(UUID().uuidString))
    defer {
      ios_setStreams(stdin, stdout, stderr)
      ios_closeSession(UnsafeRawPointer(session))
      free(session)
      fclose(output)
      fclose(error)
    }
    ios_switchSession(UnsafeRawPointer(session))
    ios_setStreams(stdin, output, error)
    let arguments = [strdup("calendar"), strdup("events"), strdup("--help")]
    defer { arguments.forEach { free($0) } }
    var pointers = arguments.map { $0.map { UnsafePointer($0) } }
    pointers.append(nil)
    let status = pointers.withUnsafeBufferPointer { ios_system(3, $0.baseAddress) }
    XCTAssertEqual(status, 0)
    XCTAssertTrue(contents(output).contains("delete"))
  }

  func testMessagesReadsLiveWALWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let path = directory.appendingPathComponent("chat.db").path
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
    defer { sqlite3_close(writer) }
    func sql(_ value: String) {
      XCTAssertEqual(sqlite3_exec(writer, value, nil, nil, nil), SQLITE_OK, value)
    }
    sql(
      """
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      CREATE TABLE chat (guid TEXT, display_name TEXT, chat_identifier TEXT);
      CREATE TABLE handle (id TEXT);
      CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
      CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
      CREATE TABLE message (guid TEXT, text TEXT, attributedBody BLOB, date INTEGER, is_from_me INTEGER, handle_id INTEGER);
      INSERT INTO chat VALUES ('chat-1', 'Dinner', 'chat123'), ('chat-2', '', '+456');
      INSERT INTO handle VALUES ('+123'), ('a@example.com'), ('+456');
      INSERT INTO chat_handle_join VALUES (1, 2), (1, 1), (2, 3);
      INSERT INTO message VALUES ('one', 'older', NULL, 810000000, 0, 1);
      INSERT INTO chat_message_join VALUES (1, 1);
      PRAGMA wal_checkpoint(TRUNCATE);
      INSERT INTO message VALUES ('two', 'hi from two', NULL, 810000001000000000, 0, 3);
      INSERT INTO chat_message_join VALUES (2, 2);
      INSERT INTO message VALUES ('three', NULL, X'000102', 810000002000000000, 0, 1);
      INSERT INTO chat_message_join VALUES (1, 3);
      INSERT INTO message VALUES ('four', 'In WAL: Hello 👋', NULL, 810000003000000000, 1, 1);
      INSERT INTO chat_message_join VALUES (1, 4);
      """)
    let mainFile = try Data(contentsOf: URL(fileURLWithPath: path))
    let database = try MessagesDatabase(directory: directory)

    let chats = try database.chats(limit: 1, offset: 0)
    XCTAssertEqual(
      chats.chats,
      [
        MessagesDatabase.Chat(
          id: 1, name: "Dinner", identifier: "chat123", participants: ["+123", "a@example.com"],
          lastMessageDate: Date(timeIntervalSinceReferenceDate: 810_000_003))
      ])
    XCTAssertEqual(chats.nextOffset, 1)
    XCTAssertEqual(try database.chats(limit: .max, offset: 0).chats.map(\.id), [1, 2])
    XCTAssertEqual(try database.chats(limit: 1, offset: .max).chats, [])
    let lastChats = try database.chats(limit: 1, offset: 1)
    XCTAssertEqual(lastChats.chats.map(\.name), [nil])
    XCTAssertNil(lastChats.nextOffset)

    let first = try database.messages(limit: 2)
    XCTAssertEqual(
      first.messages.first,
      MessagesDatabase.Message(
        id: 4, chatID: 1, date: Date(timeIntervalSinceReferenceDate: 810_000_003), fromMe: true,
        sender: nil, text: "In WAL: Hello 👋"))
    XCTAssertEqual(first.messages.map(\.text), ["In WAL: Hello 👋", nil])
    XCTAssertEqual(first.nextBeforeID, 3)
    let second = try database.messages(beforeID: 3, limit: 2)
    XCTAssertEqual(second.messages.map(\.id), [2, 1])
    XCTAssertEqual(second.messages.map(\.sender), ["+456", "+123"])
    XCTAssertEqual(
      second.messages.last?.date, Date(timeIntervalSinceReferenceDate: 810_000_000))
    XCTAssertNil(second.nextBeforeID)

    XCTAssertEqual(try database.messages(chatID: 1, limit: 10).messages.map(\.id), [4, 3, 1])
    XCTAssertEqual(try database.messages(query: "hello", limit: 10).messages.map(\.id), [4])
    XCTAssertEqual(try database.messages(query: "' OR 1=1 --", limit: 10).messages, [])
    let range = try database.messages(
      from: Date(timeIntervalSinceReferenceDate: 810_000_001),
      to: Date(timeIntervalSinceReferenceDate: 810_000_003), limit: 10)
    XCTAssertEqual(range.messages.map(\.id), [3, 2])
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), mainFile)

    // An open connection sees messages that arrive later.
    sql(
      """
      INSERT INTO message VALUES ('five', 'arrived later', NULL, 810000004000000000, 0, 1);
      INSERT INTO chat_message_join VALUES (1, 5);
      """)
    XCTAssertEqual(try database.messages(limit: 1).messages.map(\.text), ["arrived later"])

    var isCancelled = false
    let cancellable = try MessagesDatabase(directory: directory, isCancelled: { isCancelled })
    isCancelled = true
    XCTAssertThrowsError(try cancellable.messages(query: "missing", limit: 1))
  }

  func testMessagesPageEncodesSnakeCaseKeysAndLocalDates() throws {
    let page = MessagesDatabase.MessagePage(
      messages: [
        MessagesDatabase.Message(
          id: 4, chatID: 1, date: Date(timeIntervalSinceReferenceDate: 0), fromMe: true,
          sender: nil, text: "hi")
      ], nextBeforeID: 4)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: jsonEncoder().encode(page))
        as? [String: Any])
    XCTAssertEqual(json["next_before_id"] as? Int, 4)
    let message = try XCTUnwrap((json["messages"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(message.keys), ["id", "chat_id", "date", "from_me", "text"])
    let date = try XCTUnwrap(message["date"] as? String)
    XCTAssertEqual(ISO8601DateFormatter().date(from: date), Date(timeIntervalSinceReferenceDate: 0))
  }

  func testMessagesOpenFailuresDoNotCreateDatabase() throws {
    let missing = try temporaryDirectory()
    XCTAssertThrowsError(try MessagesDatabase(directory: missing)) { error in
      guard case AppDataError.unreadable = error else {
        return XCTFail("\(error)")
      }
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: missing.appendingPathComponent("chat.db").path))

    let unknown = try temporaryDirectory()
    var writer: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open(unknown.appendingPathComponent("chat.db").path, &writer), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(writer, "CREATE TABLE message (text TEXT)", nil, nil, nil), SQLITE_OK)
    sqlite3_close(writer)
    XCTAssertThrowsError(try MessagesDatabase(directory: unknown)) { error in
      guard case AppDataError.unsupportedSchema = error else {
        return XCTFail("\(error)")
      }
    }
  }

  func testMailStoreReadsLiveIndexAndMessageFiles() throws {
    let mail = try temporaryDirectory()
    let account = "6B1F0A6E-5C3D-4E2A-9F10-2B7C8D9E0A1B"
    let store = "8DA4E7AC-B281-4A60-85CD-270DE7B00644"
    // macOS leaves the folders of older versions behind, and the newest one wins.
    for version in ["V9", "V10"] {
      try FileManager.default.createDirectory(
        at: mail.appendingPathComponent("\(version)/MailData"), withIntermediateDirectories: true)
    }
    try Data("not a database".utf8).write(
      to: mail.appendingPathComponent("V9/MailData/Envelope Index"))
    let path = mail.appendingPathComponent("V10/MailData/Envelope Index").path
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
    defer { sqlite3_close(writer) }
    func sql(_ value: String) {
      XCTAssertEqual(sqlite3_exec(writer, value, nil, nil, nil), SQLITE_OK, value)
    }
    sql(
      """
      PRAGMA journal_mode=WAL;
      PRAGMA wal_autocheckpoint=0;
      CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT, total_count INTEGER, unread_count INTEGER);
      CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
      CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
      CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT);
      CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, sender INTEGER, subject_prefix TEXT, subject INTEGER, summary INTEGER, date_received INTEGER, mailbox INTEGER, read INTEGER, flagged INTEGER, deleted INTEGER);
      CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER);
      CREATE TABLE recipients (message INTEGER, address INTEGER, type INTEGER, position INTEGER);
      CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER, name TEXT);
      INSERT INTO mailboxes VALUES (1, 'imap://\(account)/INBOX', 2, 1),
        (2, 'imap://\(account)/%5BGmail%5D/All%20Mail', 3, 1),
        (3, 'local://\(account)/Trips%2F2026', 0, 0);
      INSERT INTO subjects VALUES (1, 'Lunch'), (2, '周报'), (3, 'Removed');
      INSERT INTO addresses VALUES (1, 'ada@example.com', 'Ada Lovelace'), (2, 'me@example.com', ''),
        (3, 'bob@example.com', 'Bob');
      INSERT INTO summaries VALUES (1, 'Shall we meet at noon?');
      INSERT INTO messages VALUES (5, 1, 'Re:', 1, 1, 1790000000, 1, 0, 1, 0),
        (1500, 3, NULL, 2, NULL, 1790000100, 2, 1, 0, 0),
        (7, 1, NULL, 3, NULL, 1790000200, 1, 0, 0, 1),
        (8, 3, NULL, 2, NULL, 1780000000, 2, 1, 0, 0);
      INSERT INTO labels VALUES (1500, 1);
      INSERT INTO recipients VALUES (5, 2, 0, 0), (5, 3, 1, 0);
      INSERT INTO attachments VALUES (1, 5, 'menu.pdf');
      PRAGMA wal_checkpoint(TRUNCATE);
      INSERT INTO messages VALUES (9, 2, NULL, 3, NULL, 1790000300, 1, 0, 0, 0);
      """)
    let mainFile = try Data(contentsOf: URL(fileURLWithPath: path))

    let alternative = [
      "From: Ada Lovelace <ada@example.com>", "Subject: Re: Lunch", "MIME-Version: 1.0",
      "Content-Type: multipart/mixed; boundary=\"mixed\"", "", "--mixed",
      "Content-Type: multipart/alternative;", " boundary=\"alt=_1\"", "", "--alt=_1",
      "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable",
      "", "Caf=C3=A9 at noon? =3D sure, and let's make this a long line=", " that wraps.",
      "--alt=_1", "Content-Type: text/html; charset=utf-8", "", "<p>Ignored HTML</p>",
      "--alt=_1--", "", "--mixed", "Content-Type: application/pdf; name=\"menu.pdf\"",
      "Content-Disposition: attachment; filename=\"menu.pdf\"",
      "Content-Transfer-Encoding: base64", "", "JVBERi0xLjQK", "--mixed--", "",
    ].joined(separator: "\r\n")
    let inbox = mail.appendingPathComponent("V10/\(account)/INBOX.mbox/\(store)/Data/Messages")
    try writeEMLX(Data(alternative.utf8), to: inbox.appendingPathComponent("5.emlx"))
    let gb18030 = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let report = try XCTUnwrap("周报：本周完成。".data(using: gb18030)).base64EncodedString()
    // Mail leaves out downloaded attachments, and labels them with their length.
    let partial = [
      "Content-Type: multipart/mixed; boundary=b1", "", "--b1",
      "Content-Type: text/plain; charset=\"gb2312\"", "Content-Transfer-Encoding: base64", "",
      report, "--b1", "Content-Type: image/png; name=\"chart.png\"",
      "X-Apple-Content-Length: 1000", "", "--b1--",
    ].joined(separator: "\n")
    try writeEMLX(
      Data(partial.utf8),
      to: mail.appendingPathComponent(
        "V10/\(account)/[Gmail].mbox/All Mail.mbox/\(store)/Data/1/Messages/1500.partial.emlx"))

    let mailStore = try MailStore(directory: mail)
    XCTAssertEqual(
      try mailStore.mailboxes(),
      [
        MailStore.Mailbox(
          id: 2, account: account, name: "[Gmail]/All Mail", messageCount: 3, unreadCount: 1),
        MailStore.Mailbox(id: 1, account: account, name: "INBOX", messageCount: 2, unreadCount: 1),
        MailStore.Mailbox(
          id: 3, account: account, name: "Trips/2026", messageCount: 0, unreadCount: 0),
      ])

    let first = try mailStore.messages(limit: 2, offset: 0)
    XCTAssertEqual(first.messages.map(\.id), [9, 1500])
    XCTAssertEqual(first.nextOffset, 2)
    XCTAssertEqual(try mailStore.messages(limit: 2, offset: 2).messages.map(\.id), [5, 8])
    XCTAssertNil(try mailStore.messages(limit: 2, offset: 2).nextOffset)
    let lunch = try XCTUnwrap(
      try mailStore.messages(query: "NOON", limit: 10, offset: 0).messages.first)
    XCTAssertEqual(
      lunch,
      MailStore.Message(
        id: 5, mailboxID: 1, date: Date(timeIntervalSince1970: 1_790_000_000),
        sender: "Ada Lovelace <ada@example.com>", subject: "Re: Lunch",
        preview: "Shall we meet at noon?", read: false, flagged: true))
    XCTAssertEqual(
      try mailStore.messages(query: "lovelace", limit: 10, offset: 0).messages.map(\.id), [5])
    XCTAssertEqual(
      try mailStore.messages(query: "周报", limit: 10, offset: 0).messages.map(\.id), [1500, 8])
    XCTAssertEqual(
      try mailStore.messages(query: "Removed", limit: 10, offset: 0).messages.map(\.id), [9])
    XCTAssertEqual(try mailStore.messages(query: "' OR 1=1 --", limit: 10, offset: 0).messages, [])
    // Gmail lists All Mail messages in INBOX by label.
    XCTAssertEqual(
      try mailStore.messages(mailboxID: 1, limit: 10, offset: 0).messages.map(\.id), [9, 1500, 5])
    XCTAssertEqual(
      try mailStore.messages(unreadOnly: true, limit: 10, offset: 0).messages.map(\.id), [9, 5])
    XCTAssertEqual(
      try mailStore.messages(
        from: Date(timeIntervalSince1970: 1_790_000_000),
        to: Date(timeIntervalSince1970: 1_790_000_300), limit: 10, offset: 0
      ).messages.map(\.id), [1500, 5])

    let detail = try mailStore.message(id: 5)
    XCTAssertEqual(detail.to, ["me@example.com"])
    XCTAssertEqual(detail.cc, ["Bob <bob@example.com>"])
    XCTAssertEqual(detail.attachments, ["menu.pdf"])
    XCTAssertEqual(detail.text, "Café at noon? = sure, and let's make this a long line that wraps.")
    XCTAssertEqual(try mailStore.message(id: 1500).text, "周报：本周完成。")
    XCTAssertNil(try mailStore.message(id: 8).text)
    XCTAssertThrowsError(try mailStore.message(id: 404)) { error in
      guard case MailStoreError.messageNotFound(404) = error else { return XCTFail("\(error)") }
    }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), mainFile)

    XCTAssertThrowsError(try MailStore(directory: try temporaryDirectory())) { error in
      guard case MailStoreError.noStore = error else { return XCTFail("\(error)") }
    }
  }

  func testMIMETextReadsNestedPartsAndHTML() {
    let html = [
      "Content-Type: multipart/alternative; boundary=x", "", "preamble", "--x",
      "Content-Type: text/html; charset=iso-8859-1", "Content-Transfer-Encoding: quoted-printable",
      "", "<p>Price: 5=80</p>", "--x",
    ].joined(separator: "\n")
    XCTAssertEqual(MIMEText.text(of: Array(html.utf8)), "Price: 5€")
    XCTAssertEqual(MIMEText.text(of: Array("Subject: hi\n\nPlain body\n".utf8)), "Plain body")
    XCTAssertNil(MIMEText.text(of: Array("Content-Type: image/png\n\nabc".utf8)))
    XCTAssertEqual(
      MIMEText.htmlText(
        """
        <html><head><title>T</title><style>p { color: red }</style></head>
        <body><p>Hello&nbsp;<b>world</b>
          &amp; friends</p><ul><li>One</li><li>Two</li></ul>Line<br>Break &#x1F44B; &unknown;
        <!-- a < b --><script>if (a < b) { x = "</p>" }</script>&zwnj;End</BODY></html>
        """),
      "Hello world & friends\n\n- One\n- Two\n\nLine\nBreak 👋 &unknown; End")
    XCTAssertEqual(MIMEText.htmlText("a < b <i class=\"x>y\">c</i> <unclosed"), "a < b c <unclosed")
  }

  func testMalformedMailFailsWithoutCrashing() {
    func nested(_ levels: Int) -> [UInt8] {
      var message = ""
      for level in 0..<levels {
        message += "Content-Type: multipart/mixed; boundary=b\(level)\n\n--b\(level)\n"
      }
      return Array((message + "Content-Type: text/plain\n\ndeep\n").utf8)
    }
    XCTAssertEqual(MIMEText.text(of: nested(3)), "deep")
    XCTAssertNil(MIMEText.text(of: nested(64)))
    for length in 0..<256 {
      let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ length) }
      _ = MIMEText.text(of: bytes)
      _ = MailStore.messageBytes(fromEMLX: Data(bytes))
    }
    XCTAssertNil(MailStore.messageBytes(fromEMLX: Data("99\nshort".utf8)))
    XCTAssertEqual(
      MailStore.messageBytes(fromEMLX: Data("5\nhello<plist/>".utf8)), Array("hello".utf8))
    XCTAssertNil(MailStore.mailboxLocation("INBOX"))
    XCTAssertEqual(MailStore.mailboxLocation("imap://A/a%2Fb/c")?.path, ["a/b", "c"])
  }

  #if os(macOS)
    func testAttributedTextPreservesEmojiAndFoundationLikeWords() throws {
      for text in ["👋", "DNS and NSAttributedString", "hello\nworld", ""] {
        let archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
        XCTAssertEqual(MessagesDatabase.decodeBody(archive), text)
      }
    }
  #endif

  func testMalformedAttributedBodiesFailWithoutCrashing() {
    for length in 0..<256 {
      XCTAssertNil(MessagesDatabase.decodeBody(Data(repeating: UInt8(length), count: length)))
    }
    XCTAssertNil(MessagesDatabase.decodeBody(Data(repeating: 0, count: 1_048_577)))
  }

  func testNotesOptions() throws {
    let list = try XCTUnwrap(
      NotesCommand.parseAsRoot([
        "list", "--folder=3", "--query", "-1 ' OR 1=1 --", "--pinned", "--limit", "5",
      ]) as? NotesCommand.List)
    XCTAssertEqual(list.folder, 3)
    XCTAssertEqual(list.query, "-1 ' OR 1=1 --")
    XCTAssertTrue(list.pinned)
    XCTAssertEqual(list.pagination.limit, 5)
    let link = "applenotes:note/a1b2c3d4-0000-4000-8000-000000000001?ownerIdentifier=_abc"
    let show = try XCTUnwrap(NotesCommand.parseAsRoot(["show", link]) as? NotesCommand.Show)
    XCTAssertEqual(show.id, .identifier("A1B2C3D4-0000-4000-8000-000000000001"))
    let export = try XCTUnwrap(
      NotesCommand.parseAsRoot(["export", "42", "--folder", "3", "--output", "out"])
        as? NotesCommand.Export)
    XCTAssertEqual(export.ids, [.id(42)])
    XCTAssertEqual(export.folder, 3)
    XCTAssertEqual(export.output, "out")
    for arguments in [
      ["list", "--folder", "Notes"], ["list", "--query", ""], ["list", "--limit", "0"],
      ["list", "--from", "2026-10-04", "--to", "2026-10-03"], ["show"], ["show", "Groceries"],
      ["show", "applenotes:note/nope"], ["export"], ["create", "hello"],
    ] {
      XCTAssertThrowsError(try NotesCommand.parseAsRoot(arguments), "\(arguments)")
    }
  }

  func testNoteMarkdownFromProtobuf() throws {
    let object = "\u{FFFC}"
    let data = try gzip(
      noteProtobuf([
        ("Trip\n", NoteRun(style: 0, weight: 1)), ("Pack ", NoteRun()),
        ("bags", NoteRun(weight: 1)),
        (" now\n", NoteRun()), ("Tickets\n", NoteRun(style: 103, checked: true)),
        ("Hotel\n", NoteRun(style: 103, checked: false)), ("One\n", NoteRun(style: 102)),
        ("Sub\n", NoteRun(style: 102, indent: 1)), ("Two\n", NoteRun(style: 102)),
        ("Line\u{2028}more\n", NoteRun(style: 100)), ("Quote\n", NoteRun(style: -1, quote: true)),
        ("docs", NoteRun(link: "https://example.com/a(b)")), (" ", NoteRun()),
        (object, NoteRun(attachment: ("TAG", "com.apple.notes.inlinetextattachment.hashtag"))),
        ("\n", NoteRun()), ("let x = 1\n", NoteRun(style: 4)),
        (object, NoteRun(attachment: ("IMAGE", "public.jpeg"))), ("\n", NoteRun()),
        ("~gone~", NoteRun(strikethrough: true)), (" 👋", NoteRun()),
      ]))
    let note = try XCTUnwrap(NoteDocument.note(fromData: data))
    let markdown = NoteMarkdown.markdown(note) { info in
      info.type == "public.jpeg" ? "\n![a](attachment:\(info.identifier))\n" : "#tag"
    }
    XCTAssertEqual(
      markdown,
      """
      # Trip
      Pack **bags** now
      - [x] Tickets
      - [ ] Hotel
      1. One
      \t1. Sub
      2. Two
      - Line
      \tmore
      > Quote
      [docs](<https://example.com/a(b)>) #tag

      ```
      let x = 1
      ```

      ![a](attachment:IMAGE)

      ~~~gone~~~ 👋
      """)
  }

  func testNoteTableReadsCellsInRowAndColumnOrder() throws {
    let uuids = (0..<4).map { [UInt8](repeating: UInt8($0), count: 16) }
    func objectID(index: Int? = nil, number: Int? = nil) -> [UInt8] {
      index.map { protobufField(6, $0) } ?? number.map { protobufField(2, $0) } ?? []
    }
    func customMap(type: Int, _ entries: [(Int, [UInt8])]) -> [UInt8] {
      protobufField(
        13,
        protobufField(1, type)
          + entries.flatMap { protobufField(3, protobufField(1, $0.0) + protobufField(2, $0.1)) })
    }
    func dictionary(_ elements: [(Int, Int)]) -> [UInt8] {
      elements.flatMap {
        protobufField(
          1, protobufField(1, objectID(index: $0.0)) + protobufField(2, objectID(index: $0.1)))
      }
    }
    func orderedSet(_ order: [Int], _ contents: [(Int, Int)]) -> [UInt8] {
      let array = order.flatMap { protobufField(2, protobufField(2, uuids[$0])) }
      return protobufField(
        16, protobufField(1, protobufField(1, array) + protobufField(2, dictionary(contents))))
    }
    func cell(_ text: String) -> [UInt8] {
      protobufField(
        10, protobufField(2, text) + protobufField(5, protobufField(1, text.utf16.count)))
    }
    // Rows list the second UUID first, so the table's first row is entry 11.
    let entries: [[UInt8]] = [
      customMap(
        type: 0, [(0, objectID(index: 1)), (1, objectID(index: 2)), (2, objectID(index: 3))]),
      orderedSet([1, 0], [(4, 4), (5, 5)]),
      orderedSet([2, 3], [(6, 6), (7, 7)]),
      protobufField(6, dictionary([(6, 8), (7, 9)])),
      customMap(type: 1, [(0, objectID(number: 0))]),
      customMap(type: 1, [(0, objectID(number: 1))]),
      customMap(type: 1, [(0, objectID(number: 2))]),
      customMap(type: 1, [(0, objectID(number: 3))]),
      protobufField(6, dictionary([(4, 10), (5, 11)])),
      protobufField(6, dictionary([(4, 12), (5, 99)])),
      cell("A0"), cell("B0"), cell("A|1"),
    ]
    var data = entries.flatMap { protobufField(3, $0) }
    data += ["crRows", "crColumns", "cellColumns"].flatMap { protobufField(4, $0) }
    data += ["com.apple.notes.ICTable", "com.apple.CRDT.NSUUID"].flatMap { protobufField(5, $0) }
    data += uuids.flatMap { protobufField(6, $0) }
    let table = try XCTUnwrap(
      NoteDocument.MergeableData(
        data: try gzip(protobufField(2, protobufField(2, 1) + protobufField(3, data)))))
    let cells = try XCTUnwrap(table.tableCells())
    XCTAssertEqual(cells.map { $0.map { $0?.text } }, [["B0", nil], ["A0", "A|1"]])
    XCTAssertEqual(
      NoteMarkdown.table(
        cells.map {
          $0.map { $0.map { NoteMarkdown.markdown($0, isTableCell: true) { _ in "" } } ?? "" }
        }),
      "\n| B0 |  |\n| --- | --- |\n| A0 | A\\|1 |\n\n")
  }

  func testNoteStoreReadsLiveStoreAndAttachments() throws {
    let directory = try temporaryDirectory()
    let path = directory.appendingPathComponent("NoteStore.sqlite").path
    var writer: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
    defer { sqlite3_close(writer) }
    func sql(_ value: String, _ blobs: [Data] = []) {
      var statement: OpaquePointer?
      XCTAssertEqual(sqlite3_prepare_v2(writer, value, -1, &statement, nil), SQLITE_OK, value)
      for (index, blob) in blobs.enumerated() {
        _ = blob.withUnsafeBytes {
          sqlite3_bind_blob(
            statement, Int32(index + 1), $0.baseAddress, Int32(blob.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      }
      XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE, value)
      sqlite3_finalize(statement)
    }
    XCTAssertEqual(
      sqlite3_exec(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0", nil, nil, nil),
      SQLITE_OK)
    // Like the schema of an older Notes, without ZCREATIONDATE2 or ZCREATIONDATE3.
    for statement in [
      "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR)",
      "CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB)",
      """
      CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER,
        ZIDENTIFIER VARCHAR, ZMARKEDFORDELETION INTEGER, ZNAME VARCHAR, ZTITLE2 VARCHAR,
        ZOWNER INTEGER, ZPARENT INTEGER, ZFOLDERTYPE INTEGER, ZTITLE1 VARCHAR, ZSNIPPET VARCHAR,
        ZFOLDER INTEGER, ZCREATIONDATE1 TIMESTAMP, ZMODIFICATIONDATE1 TIMESTAMP,
        ZISPINNED INTEGER, ZISPASSWORDPROTECTED INTEGER, ZTYPEUTI VARCHAR, ZALTTEXT VARCHAR,
        ZTITLE VARCHAR, ZURLSTRING VARCHAR, ZMERGEABLEDATA1 BLOB, ZSIZEWIDTH FLOAT,
        ZSIZEHEIGHT FLOAT, ZMEDIA INTEGER, ZFILENAME VARCHAR)
      """,
      """
      INSERT INTO Z_PRIMARYKEY VALUES (5, 'ICAttachment'), (9, 'ICInlineAttachment'),
        (11, 'ICMedia'), (12, 'ICNote'), (14, 'ICAccount'), (15, 'ICFolder')
      """,
      """
      INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZNAME, ZTITLE2, ZOWNER,
        ZPARENT, ZFOLDERTYPE, ZMARKEDFORDELETION) VALUES
        (1, 14, 'ACCOUNT', 'iCloud', NULL, NULL, NULL, NULL, 0),
        (2, 15, 'DefaultFolder-CloudKit', NULL, 'Notes', 1, NULL, 0, 0),
        (3, 15, 'TRIPS', NULL, 'Trips', 1, 2, 0, 0),
        (4, 15, 'TrashFolder-CloudKit', NULL, 'Recently Deleted', 1, NULL, 1, 0),
        (5, 15, 'SMART', NULL, 'Smart', 1, NULL, 3, 0),
        (6, 15, 'GONE', NULL, 'Gone', 1, NULL, 0, 1),
        (7, 15, 'TRIPSUB', NULL, 'Trip', 1, 3, 0, 0)
      """,
      """
      INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZALTTEXT, ZMEDIA,
        ZFILENAME) VALUES
        (20, 5, 'IMAGE', 'public.jpeg', NULL, 21, NULL), (21, 11, 'MEDIA', NULL, NULL, NULL, 'Photo.jpeg'),
        (22, 5, 'DRAWING', 'com.apple.drawing.2', NULL, NULL, NULL),
        (23, 5, 'MISSING', 'com.apple.m4a-audio', NULL, 24, NULL),
        (24, 11, 'VOICE', NULL, NULL, NULL, 'Voice.m4a'),
        (25, 9, 'TAG', NULL, '#trip', NULL, NULL)
      """,
    ] {
      sql(statement)
    }
    let object = "\u{FFFC}"
    let trip = try gzip(
      noteProtobuf([
        ("Trip\n", NoteRun(style: 0)), ("Pack ", NoteRun()),
        (object, NoteRun(attachment: ("TAG", "com.apple.notes.inlinetextattachment.hashtag"))),
        ("\n", NoteRun()), (object, NoteRun(attachment: ("IMAGE", "public.jpeg"))),
        ("\n", NoteRun()), (object, NoteRun(attachment: ("DRAWING", "com.apple.drawing.2"))),
        ("\n", NoteRun()), (object, NoteRun(attachment: ("MISSING", "com.apple.m4a-audio"))),
        ("\n", NoteRun()), (object, NoteRun(attachment: ("UNKNOWN", "com.example.thing"))),
      ]))
    let groceries = try gzip(
      noteProtobuf([("Groceries\n", NoteRun(style: 0)), ("Milk and eggs", NoteRun())]))
    let tokyo = try gzip(noteProtobuf([("Tokyo\n", NoteRun(style: 0)), ("Ramen", NoteRun())]))
    let identifier = "A1B2C3D4-0000-4000-8000-000000000001"
    let insertNote = """
      INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTITLE1, ZSNIPPET, ZFOLDER,
        ZCREATIONDATE1, ZMODIFICATIONDATE1, ZISPINNED, ZISPASSWORDPROTECTED, ZMARKEDFORDELETION)
      VALUES
      """
    sql(
      insertNote + """
        (10, 12, 'TRIP', 'Trip', 'Pack', 3, 810000000, 810000300, 0, 0, 0),
        (11, 12, '\(identifier)', 'Groceries', NULL, 2, 810000001, 810000200, 1, 0, 0),
        (12, 12, 'LOCKED', 'Secret', NULL, 2, 810000002, 810000100, 0, 1, 0),
        (13, 12, 'DELETED', 'Old idea', NULL, 4, 810000003, 810000400, 0, 0, 0),
        (14, 12, 'PURGED', 'Purged', NULL, 2, 810000004, 810000500, 0, 0, 1),
        (15, 12, 'UNTITLED', NULL, NULL, 2, 810000005, 810000600, 0, 0, 0),
        (16, 12, 'TOKYO', 'Tokyo', NULL, 7, 810000006, 810000050, 0, 0, 0)
        """)
    sql(
      "INSERT INTO ZICNOTEDATA (ZNOTE, ZDATA) VALUES (10, ?), (11, ?), (12, ?), (13, ?), (16, ?)",
      [trip, groceries, Data("encrypted".utf8), groceries, tokyo])
    let photo = directory.appendingPathComponent("Accounts/ACCOUNT/Media/MEDIA/Photo.jpeg")
    // Older versions of Notes kept attachments outside the account folder.
    let drawing = directory.appendingPathComponent("FallbackImages/DRAWING.jpg")
    for file in [photo, drawing] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(file.lastPathComponent.utf8).write(to: file)
    }

    let store = try NoteStore(directory: directory)
    XCTAssertEqual(
      try store.folders(),
      [
        NoteStore.Folder(
          id: 2, account: "iCloud", name: "Notes", parentID: nil, recentlyDeleted: false,
          noteCount: 2, accountID: 1, isDefault: true),
        NoteStore.Folder(
          id: 4, account: "iCloud", name: "Recently Deleted", parentID: nil, recentlyDeleted: true,
          noteCount: 1, accountID: 1, isDefault: false),
        NoteStore.Folder(
          id: 7, account: "iCloud", name: "Trip", parentID: 3, recentlyDeleted: false,
          noteCount: 1, accountID: 1, isDefault: false),
        NoteStore.Folder(
          id: 3, account: "iCloud", name: "Trips", parentID: 2, recentlyDeleted: false,
          noteCount: 1, accountID: 1, isDefault: false),
      ])
    let first = try store.notes(limit: 2, offset: 0)
    XCTAssertEqual(first.notes.map(\.id), [10, 11])
    XCTAssertEqual(first.nextOffset, 2)
    XCTAssertEqual(
      first.notes.last,
      NoteStore.Note(
        id: 11, folderID: 2, folder: "Notes", title: "Groceries", snippet: nil,
        created: Date(timeIntervalSinceReferenceDate: 810_000_001),
        modified: Date(timeIntervalSinceReferenceDate: 810_000_200), pinned: true, locked: false))
    XCTAssertEqual(try store.notes(limit: 2, offset: 2).notes.map(\.id), [12, 16])
    XCTAssertEqual(try store.notes(folderID: 4, limit: 10, offset: 0).notes.map(\.id), [13])
    XCTAssertEqual(try store.notes(query: "EGGS", limit: 10, offset: 0).notes.map(\.id), [11])
    XCTAssertEqual(try store.notes(query: "secret", limit: 10, offset: 0).notes.map(\.id), [12])
    XCTAssertEqual(try store.notes(query: "' OR 1=1 --", limit: 10, offset: 0).notes, [])
    XCTAssertEqual(try store.notes(pinnedOnly: true, limit: 10, offset: 0).notes.map(\.id), [11])
    XCTAssertEqual(
      try store.notes(
        from: Date(timeIntervalSinceReferenceDate: 810_000_100),
        to: Date(timeIntervalSinceReferenceDate: 810_000_300), limit: 10, offset: 0
      ).notes.map(\.id), [11, 12])

    let detail = try store.note(id: 10)
    XCTAssertEqual(
      detail.text,
      """
      # Trip
      Pack #trip

      ![Photo.jpeg](attachment:20)

      ![Drawing.jpg](attachment:22)

      [Voice.m4a](attachment:23)

      (unsupported attachment: com.example.thing)
      """)
    XCTAssertEqual(
      detail.attachments,
      [
        NoteStore.Attachment(
          id: 20, type: "public.jpeg", name: "Photo.jpeg", available: true, file: photo),
        NoteStore.Attachment(
          id: 22, type: "com.apple.drawing.2", name: "Drawing.jpg", available: true, file: drawing),
        NoteStore.Attachment(
          id: 23, type: "com.apple.m4a-audio", name: "Voice.m4a", available: false),
      ])
    XCTAssertEqual(try store.noteID(.identifier(identifier)), 11)
    XCTAssertThrowsError(try store.noteID(.identifier("TRIP-NOT-A-NOTE")))
    let locked = try store.note(id: 12)
    XCTAssertTrue(locked.locked)
    XCTAssertNil(locked.text)
    XCTAssertThrowsError(try store.note(id: 404)) { error in
      guard case NoteStoreError.noteNotFound("404") = error else { return XCTFail("\(error)") }
    }

    // The command exports through the folder that Local Code grants.
    let context = BashToolContext(accessNotesDirectory: { _, _, _, completion in
      completion(.success(directory))
    })
    BashToolContext.current = context
    defer { BashToolContext.current = nil }
    let output = try temporaryDirectory()
    let export = run(
      NotesCommand.self,
      ["export", "10", "applenotes:note/\(identifier)", "12", "--output", output.path])
    XCTAssertEqual(export.status, 0, export.error)
    let result = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(export.output.utf8)) as? [String: Any])
    let exported = try XCTUnwrap(result["exported"] as? [[String: Any]])
    XCTAssertEqual(exported.map { $0["id"] as? Int }, [10, 11])
    XCTAssertEqual(exported.first?["missing_attachments"] as? [String], ["Voice.m4a"])
    XCTAssertEqual((result["skipped"] as? [[String: Any]])?.map { $0["id"] as? Int }, [12])
    // Trips has a subfolder named Trip, so the note and its attachments folder are Trip-1.
    let markdown = try String(
      contentsOf: output.appendingPathComponent("Trips/Trip-1.md"), encoding: .utf8)
    XCTAssertTrue(markdown.contains("![Photo.jpeg](Trip-1/Photo.jpeg)"), markdown)
    XCTAssertTrue(markdown.contains("![Drawing.jpg](Trip-1/Drawing.jpg)"), markdown)
    XCTAssertEqual(
      try Data(contentsOf: output.appendingPathComponent("Trips/Trip-1/Photo.jpeg")),
      Data("Photo.jpeg".utf8))
    // Notes in the Notes folder go at the top.
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(
        atPath: output.appendingPathComponent("Groceries.md").path)[.modificationDate] as? Date,
      Date(timeIntervalSinceReferenceDate: 810_000_200))
    // Exporting again keeps the earlier files.
    XCTAssertEqual(run(NotesCommand.self, ["export", "10", "--output", output.path]).status, 0)
    let again = try String(
      contentsOf: output.appendingPathComponent("Trips/Trip-2.md"), encoding: .utf8)
    XCTAssertTrue(again.contains("![Photo.jpeg](Trip-2/Photo.jpeg)"), again)
    // A folder is exported with its subfolders.
    let folderOutput = try temporaryDirectory()
    let folderExport = run(
      NotesCommand.self, ["export", "--folder", "3", "--output", folderOutput.path])
    XCTAssertEqual(folderExport.status, 0, folderExport.error)
    for path in ["Trips/Trip-1.md", "Trips/Trip/Tokyo.md"] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: folderOutput.appendingPathComponent(path).path), path
      )
    }
    let show = run(NotesCommand.self, ["show", "11"])
    XCTAssertTrue(show.output.contains("Milk and eggs"), show.output)
  }

  func testNoteExportFolderPaths() {
    func folder(
      _ id: Int64, account: Int64, _ name: String, parentID: Int64? = nil, isDefault: Bool = false
    ) -> NoteStore.Folder {
      NoteStore.Folder(
        id: id, account: account == 1 ? "iCloud" : "On My Mac", name: name, parentID: parentID,
        recentlyDeleted: false, noteCount: 0, accountID: account, isDefault: isDefault)
    }
    let folders = [
      folder(1, account: 1, "Notes", isDefault: true), folder(2, account: 1, "Work"),
      folder(3, account: 1, "Meetings", parentID: 2),
      folder(4, account: 2, "Notes", isDefault: true),
      folder(5, account: 2, "a/b"),
      // Parents that loop, as in a damaged store.
      folder(6, account: 2, "Loop", parentID: 7), folder(7, account: 2, "Back", parentID: 6),
    ]
    XCTAssertEqual(
      NotesCommand.Export.folderPaths(folders),
      [
        1: "iCloud", 2: "iCloud/Work", 3: "iCloud/Work/Meetings", 4: "On My Mac",
        5: "On My Mac/a-b", 6: "On My Mac/Back/Loop", 7: "On My Mac/Back",
      ])
    // With one account, there is no account directory.
    XCTAssertEqual(
      NotesCommand.Export.folderPaths(Array(folders.prefix(3))),
      [1: "", 2: "Work", 3: "Work/Meetings"])
  }

  func testMalformedNotesFailWithoutCrashing() {
    for length in 0..<256 {
      let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ length) }
      for data in [Data(bytes), Data([0x1f, 0x8b, 8, 0x1f] + bytes)] {
        if let note = NoteDocument.note(fromData: data) {
          _ = NoteMarkdown.markdown(note) { _ in "" }
        }
        _ = NoteDocument.MergeableData(data: data)?.tableCells()
      }
    }
    // A run longer than the text, and one with a negative length.
    let note = NoteDocument.Note(
      text: "ab\u{2028}",
      runs: [NoteDocument.AttributeRun(length: -3), NoteDocument.AttributeRun(length: 9)])
    XCTAssertEqual(NoteMarkdown.markdown(note) { _ in "" }, "ab")
  }

  private struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "probe", subcommands: [Action.self])

    struct Action: AppleUtilitySubcommand {
      static var runs = 0

      func result() throws -> any Encodable {
        Self.runs += 1
        return [String]()
      }
    }
  }

  private struct NoteRun {
    var style: Int?
    var indent: Int?
    var checked: Bool?
    var quote = false
    var weight: Int?
    var strikethrough = false
    var link: String?
    var attachment: (identifier: String, type: String)?
  }

  /// A NoteStoreProto with the text and styles of `parts`.
  private func noteProtobuf(_ parts: [(String, NoteRun)]) -> [UInt8] {
    var note = protobufField(2, parts.map(\.0).joined())
    for (text, run) in parts {
      var bytes = protobufField(1, text.utf16.count)
      var style = [UInt8]()
      if let type = run.style { style += protobufField(1, type) }
      if let indent = run.indent { style += protobufField(4, indent) }
      if let checked = run.checked {
        style += protobufField(
          5, protobufField(1, [UInt8](repeating: 1, count: 16)) + protobufField(2, checked ? 1 : 0))
      }
      if run.quote { style += protobufField(8, 1) }
      if !style.isEmpty { bytes += protobufField(2, style) }
      if let weight = run.weight { bytes += protobufField(5, weight) }
      if run.strikethrough { bytes += protobufField(7, 1) }
      if let link = run.link { bytes += protobufField(9, link) }
      if let (identifier, type) = run.attachment {
        bytes += protobufField(12, protobufField(1, identifier) + protobufField(2, type))
      }
      note += protobufField(5, bytes)
    }
    return protobufField(2, protobufField(2, 1) + protobufField(3, note))
  }

  private func protobufField(_ number: Int, _ value: Int) -> [UInt8] {
    protobufVarint(UInt64(number) << 3) + protobufVarint(UInt64(bitPattern: Int64(value)))
  }

  private func protobufField(_ number: Int, _ value: String) -> [UInt8] {
    protobufField(number, Array(value.utf8))
  }

  private func protobufField(_ number: Int, _ value: [UInt8]) -> [UInt8] {
    protobufVarint(UInt64(number) << 3 | 2) + protobufVarint(UInt64(value.count)) + value
  }

  private func protobufVarint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes = [UInt8]()
    while value >= 0x80 {
      bytes.append(UInt8(value & 0x7f) | 0x80)
      value >>= 7
    }
    return bytes + [UInt8(value)]
  }

  /// Reading skips the CRC and size in the trailer, so they are left as zeros.
  private func gzip(_ bytes: [UInt8]) throws -> Data {
    var data = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
    data.append(try (Data(bytes) as NSData).compressed(using: .zlib) as Data)
    data.append(contentsOf: [UInt8](repeating: 0, count: 8))
    return data
  }

  private func writeEMLX(_ message: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = Data("\(message.count)\n".utf8)
    data.append(message)
    data.append(Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8))
    try data.write(to: url)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func run(
    _ command: ParsableCommand.Type, _ arguments: [String], isCancelled: Bool = false
  ) -> (status: Int32, output: String, error: String) {
    let output = tmpfile()!
    let error = tmpfile()!
    defer {
      fclose(output)
      fclose(error)
    }
    let status = runCommand(
      command, arguments: arguments, output: output, errorOutput: error,
      isCancelled: { isCancelled })
    return (status, contents(output), contents(error))
  }

  private func contents(_ file: UnsafeMutablePointer<FILE>) -> String {
    fflush(file)
    rewind(file)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while case let count = fread(&buffer, 1, buffer.count, file), count > 0 {
      data.append(buffer, count: count)
    }
    return String(decoding: data, as: UTF8.self)
  }
}
