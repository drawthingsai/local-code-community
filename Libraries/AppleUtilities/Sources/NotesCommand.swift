import ArgumentParser
import BashToolContext
import Foundation
import ios_system

struct NotesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "notes",
    abstract: "Read and export notes that the Notes app keeps on this Mac.",
    discussion: """
      Read-only: it cannot create, edit or delete notes. Results are JSON, most recently \
      modified first, with IDs local to this Mac. A note's text is Markdown, where each \
      attachment links to attachment:<id>; export writes notes as Markdown files with their \
      attachments. Locked notes cannot be read. The first command asks for access to the \
      ~/Library/Group Containers/group.com.apple.notes folder.
      """,
    subcommands: [Status.self, Folders.self, List.self, Show.self, Export.self])

  /// Runs `body` with the store. Local Code decides whether the command may read the Notes
  /// folder, asking the user for it when `prompt` is true; that access lasts only for `body`.
  static func withStore<T>(prompt: Bool = true, _ body: (NoteStore) throws -> T) throws -> T {
    guard let context = BashToolContext.current,
      let accessNotesDirectory = context.accessNotesDirectory
    else { throw AppleUtilityError.unavailable }
    // The host checks this from the main thread while its folder picker is shown.
    let cancellation = ios_getCommandCancellationContext()
    let isCancelled = { ios_commandCancellationRequested(cancellation) != 0 }
    // ios_system needs a synchronous exit status. The host also completes on cancellation, by
    // dismissing its picker.
    let group = DispatchGroup()
    var result: Result<URL, Error> = .failure(AppleUtilityError.cancelled)
    group.enter()
    accessNotesDirectory(prompt, context.bashUserInteraction, isCancelled) {
      result = $0
      group.leave()
    }
    group.wait()
    let directory = try result.get()
    defer { directory.stopAccessingSecurityScopedResource() }
    return try body(NoteStore(directory: directory, isCancelled: isCancelled))
  }
}

/// A note's ID, or the applenotes:note/<identifier> link that notes use to link to each other.
enum NoteReference: Equatable, ExpressibleByArgument {
  case id(Int64)
  case identifier(String)

  init?(argument: String) {
    if let id = Int64(argument) {
      self = .id(id)
      return
    }
    var identifier = Substring(argument)
    if argument.lowercased().hasPrefix("applenotes:note/") {
      identifier = argument.dropFirst("applenotes:note/".count).prefix { $0 != "?" }
    }
    guard UUID(uuidString: String(identifier)) != nil else { return nil }
    self = .identifier(identifier.uppercased())
  }
}

extension NotesCommand {
  struct Status: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Check whether notes are readable, without asking for access.")

    struct Access: Encodable {
      var readable: Bool
      var reason: String?
    }

    func result() throws -> any Encodable {
      do {
        return try NotesCommand.withStore(prompt: false) { _ in Access(readable: true) }
      } catch {
        return Access(readable: false, reason: error.localizedDescription)
      }
    }
  }

  struct Folders: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List folders, grouped by account.")

    func result() throws -> any Encodable {
      try NotesCommand.withStore { try $0.folders() }
    }
  }

  struct List: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List or search notes, most recently modified first.",
      discussion: """
        Recently Deleted is left out unless --folder names it. Pass next_offset as --offset, \
        with the same filters, for the next page.
        """)

    @Option(
      help: ArgumentHelp("Only notes in this folder ID from `notes folders`.", valueName: "id"))
    var folder: Int64?
    @Option(
      parsing: .unconditional, help: "Only notes whose title or text contains this, ignoring case.")
    var query: String?
    @Option(
      help: ArgumentHelp("Only notes modified at or after this date.", valueName: "date"),
      transform: parseDate)
    var from: Date?
    @Option(
      help: ArgumentHelp("Only notes modified before this date.", valueName: "date"),
      transform: parseDate)
    var to: Date?
    @Flag(help: "Only pinned notes.") var pinned = false
    @OptionGroup var pagination: Pagination

    func validate() throws {
      guard query?.isEmpty != true else { throw ValidationError("--query must not be empty.") }
      if let from, let to, to <= from { throw ValidationError("--to must be after --from.") }
    }

    func result() throws -> any Encodable {
      try NotesCommand.withStore {
        try $0.notes(
          folderID: folder, query: query, from: from, to: to, pinnedOnly: pinned,
          limit: pagination.limit, offset: pagination.offset)
      }
    }
  }

  struct Show: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Show a note as Markdown, with its attachments.",
      discussion: "text is null for a locked note. Use export to get the attachment files.")

    @Argument(
      help: ArgumentHelp(
        "A note ID from `notes list`, or an applenotes:note/ link from another note.",
        valueName: "id"))
    var id: NoteReference

    func result() throws -> any Encodable {
      try NotesCommand.withStore { try $0.note(id: $0.noteID(id)) }
    }
  }

  struct Export: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Write notes as Markdown files, each with a folder of its attachments.",
      discussion: """
        Folders become directories under the output folder, nested as in Notes. An account's \
        Notes folder is the top, and each account has its own directory when there are several. \
        Each note becomes <title>.md in its folder's directory, and its attachments go in a \
        <title> folder beside it, where the Markdown links to them. Existing files are kept. \
        Locked notes are skipped.
        """)

    @Argument(
      help: ArgumentHelp(
        "Note IDs from `notes list`, or applenotes:note/ links.", valueName: "id"))
    var ids: [NoteReference] = []
    @Option(
      help: ArgumentHelp(
        "Also export the notes in this folder ID and its subfolders.",
        valueName: "id"))
    var folder: Int64?
    @Option(
      help: ArgumentHelp(
        "The folder to write to. Defaults to the current folder.", valueName: "dir"))
    var output = "."

    struct Exported: Encodable {
      var id: Int64
      var file: String
      var attachments: [String]
      /// Attachments that are only in iCloud, which the Markdown still links to.
      var missingAttachments: [String]?
    }

    struct Skipped: Encodable {
      var id: Int64
      var title: String
      var reason: String
    }

    struct Exports: Encodable {
      var exported: [Exported]
      var skipped: [Skipped]
    }

    func validate() throws {
      guard !ids.isEmpty || folder != nil else {
        throw ValidationError("Pass note IDs, --folder, or both.")
      }
    }

    func result() throws -> any Encodable {
      try NotesCommand.withStore { store in
        let folders = try store.folders()
        var noteIDs = try ids.map { try store.noteID($0) }
        if let folder {
          var folderIDs = [folder]
          var index = 0
          while index < folderIDs.count {
            let parentID = folderIDs[index]
            folderIDs += folders.filter { $0.parentID == parentID && !folderIDs.contains($0.id) }
              .map(\.id)
            index += 1
          }
          for id in folderIDs {
            noteIDs += try store.notes(folderID: id, limit: .max, offset: 0).notes.map(\.id)
          }
        }
        var seen = Set<Int64>()
        noteIDs = noteIDs.filter { seen.insert($0).inserted }
        let root = fileURL(output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = Self.folderPaths(folders)
        // The file system may ignore case.
        let reservedPaths = Set(paths.values.map { $0.lowercased() })
        var exports = Exports(exported: [], skipped: [])
        for id in noteIDs {
          try checkCancellation()
          let note = try store.note(id: id)
          guard var text = note.text else {
            exports.skipped.append(
              Skipped(
                id: id, title: note.title,
                reason: note.locked ? "The note is locked." : "The note has no readable text."))
            continue
          }
          let folderPath = paths[note.folderID] ?? ""
          let directory =
            folderPath.isEmpty ? root : root.appendingPathComponent(folderPath, isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          // The attachments folder shares the note's name, so a number is added until neither
          // exists and the name is not a subfolder's.
          let title = Self.fileName(note.title)
          var folderName = title
          var number = 0
          while [folderName + ".md", folderName].contains(where: {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
          })
            || reservedPaths.contains(
              (folderPath as NSString).appendingPathComponent(folderName).lowercased())
          {
            number += 1
            folderName = "\(title)-\(number)"
          }
          let file = directory.appendingPathComponent(folderName + ".md")
          let attachmentsFolder = directory.appendingPathComponent(folderName, isDirectory: true)
          var exported = Exported(id: id, file: file.path, attachments: [])
          for attachment in note.attachments {
            guard let source = attachment.file else {
              exported.missingAttachments = (exported.missingAttachments ?? []) + [attachment.name]
              continue
            }
            try FileManager.default.createDirectory(
              at: attachmentsFolder, withIntermediateDirectories: true)
            let name = Self.fileName(attachment.name) as NSString
            let destination = availableURL(
              attachmentsFolder, name: name.deletingPathExtension, extension: name.pathExtension)
            try FileManager.default.copyItem(at: source, to: destination)
            text = text.replacingOccurrences(
              of: "](attachment:\(attachment.id))",
              with:
                "](\(NoteMarkdown.destination("\(folderName)/\(destination.lastPathComponent)")))")
            exported.attachments.append(destination.path)
          }
          try Data(text.utf8).write(to: file)
          var dates = [FileAttributeKey: Date]()
          dates[.creationDate] = note.created
          dates[.modificationDate] = note.modified
          try? FileManager.default.setAttributes(dates, ofItemAtPath: file.path)
          exports.exported.append(exported)
        }
        return exports
      }
    }

    /// The directory, relative to the output folder, of each folder's notes. Like the Obsidian
    /// Importer, folders nest as in Notes, an account's Notes folder is the top, and accounts have
    /// their own directories when there are several.
    static func folderPaths(_ folders: [NoteStore.Folder]) -> [Int64: String] {
      let foldersByID = Dictionary(folders.map { ($0.id, $0) }) { first, _ in first }
      let isMultiAccount = Set(folders.compactMap(\.accountID)).count > 1
      var paths = [Int64: String]()
      // `visited` ends a loop of parents in a damaged store.
      func resolve(_ folder: NoteStore.Folder, visited: Set<Int64>) -> String {
        if let path = paths[folder.id] { return path }
        let visited = visited.union([folder.id])
        var path = isMultiAccount ? fileName(folder.account) : ""
        if let parent = folder.parentID.flatMap({ foldersByID[$0] }), !visited.contains(parent.id) {
          path = resolve(parent, visited: visited)
        }
        if !folder.isDefault {
          path = (path as NSString).appendingPathComponent(fileName(folder.name))
        }
        paths[folder.id] = path
        return path
      }
      for folder in folders { _ = resolve(folder, visited: []) }
      return paths
    }

    /// A title as a file name, without path separators or a leading dot.
    static func fileName(_ title: String) -> String {
      let separators = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
      var name = title.components(separatedBy: separators).joined(separator: "-")
        .trimmingCharacters(in: .whitespaces)
      while name.hasPrefix(".") { name.removeFirst() }
      if name.count > 100 { name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces) }
      return name.isEmpty ? "Untitled" : name
    }
  }
}
