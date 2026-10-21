import Foundation
import SQLiteDflat

enum DirectoryPermissionError: Error, Equatable, LocalizedError {
  case unavailable
  case cancelled
  case differentDirectory
  case permissionDenied
  case notDirectory
  case featureDisabled
  case folderDisabled
  case notAppDataDirectory(AppDataDirectory)
  case appDataDirectoryNotGranted(AppDataDirectory)
  case appDataDirectoryDenied(AppDataDirectory)

  var errorDescription: String? {
    switch self {
    case .unavailable: return "Unable to present the folder picker. Try again from Local Code."
    case .cancelled: return "Folder permission was cancelled."
    case .differentDirectory:
      return "Select the requested directory, or run permit with a different path."
    case .notAppDataDirectory(let directory):
      return "Select the ~/\(directory.path) folder."
    case .appDataDirectoryNotGranted(let directory):
      return "\(directory.name) folder access has not been granted."
    case .appDataDirectoryDenied(let directory):
      return "\(directory.name) Permission is set to Denied in Kit."
    case .permissionDenied: return "Unable to access the selected folder."
    case .notDirectory: return "The selected path is not a directory."
    case .featureDisabled: return "Folder access has been disabled by the user."
    case .folderDisabled:
      return
        "The user explicitly disabled access to this folder in Kit. They must re-enable it before access can be requested again."
    }
  }
}

/// A folder where an app keeps its data, read by one command with its own read-only grant.
/// Unlike permitted directories, its security scope is active only while that command runs, and
/// the permit switch does not affect it.
enum AppDataDirectory {
  /// Read by the imessage command.
  case messages
  /// Read by the mail command.
  case mail
  /// Read by the notes command.
  case notes

  var name: String {
    switch self {
    case .messages: return "Messages"
    case .mail: return "Mail"
    case .notes: return "Notes"
    }
  }

  /// The folder's path in the home folder.
  var path: String {
    switch self {
    case .messages: return "Library/Messages"
    case .mail: return "Library/Mail"
    case .notes: return "Library/Group Containers/group.com.apple.notes"
    }
  }

  /// HOME points into the app container, but these apps keep their data in the real home.
  var url: URL {
    let home = getpwuid(getuid())?.pointee.pw_dir.map { String(cString: $0) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(path, isDirectory: true)
  }

  /// The workspace key of the saved grant.
  var bookmarkKey: String {
    switch self {
    case .messages: return "messages_directory"
    case .mail: return "mail_directory"
    case .notes: return "notes_directory"
    }
  }

  /// The workspace key that is true when the permission is Denied in Kit.
  var deniedKey: String {
    switch self {
    case .messages: return "is_messages_denied"
    case .mail: return "is_mail_denied"
    case .notes: return "is_notes_denied"
    }
  }
}

/// Owns the app's saved grants and keeps their security scopes active between commands and turns.
final class PermittedDirectories {
  private let workspace: SQLiteWorkspace
  private let lock = NSLock()
  private var activeURLs = [String: URL]()

  var isEnabled: Bool { workspace.dictionary["is_permit_enabled", Bool.self] ?? true }

  var urls: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return Array(activeURLs.values)
  }

  init(workspace: SQLiteWorkspace) {
    self.workspace = workspace
    updateAccess()
  }

  private func updateAccess() {
    let isEnabled = self.isEnabled
    let disabled = workspace.dictionary["disabled_permitted_directories", Set<String>.self] ?? []
    lock.lock()
    let removed = activeURLs.filter { !isEnabled || disabled.contains($0.key) }
    for path in removed.keys { activeURLs[path] = nil }
    lock.unlock()
    for url in removed.values { url.stopAccessingSecurityScopedResource() }
    let savedBookmarks = workspace.dictionary["permitted_directories", [String: Data].self] ?? [:]
    var bookmarks = [String: Data]()
    for (path, data) in savedBookmarks {
      lock.lock()
      let isActive = activeURLs[path] != nil
      lock.unlock()
      guard isEnabled, !disabled.contains(path), !isActive else {
        if bookmarks[path] == nil { bookmarks[path] = data }
        continue
      }
      var stale = false
      #if os(macOS) || targetEnvironment(macCatalyst)
        let options: URL.BookmarkResolutionOptions = .withSecurityScope
      #else
        let options: URL.BookmarkResolutionOptions = []
      #endif
      guard
        let url = try? URL(
          resolvingBookmarkData: data, options: options, bookmarkDataIsStale: &stale),
        url.startAccessingSecurityScopedResource()
      else {
        if bookmarks[path] == nil { bookmarks[path] = data }
        continue
      }
      let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
      var key = path
      var bookmark = data
      if stale || resolvedPath != path, let updated = try? Self.bookmark(for: url) {
        bookmark = updated
        key = resolvedPath
      }
      bookmarks[key] = bookmark
      lock.lock()
      let previous = activeURLs.updateValue(url, forKey: key)
      lock.unlock()
      previous?.stopAccessingSecurityScopedResource()
    }
    if bookmarks != savedBookmarks {
      workspace.dictionary["permitted_directories", [String: Data].self] = bookmarks
    }
  }

  func setEnabled(_ isEnabled: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["is_permit_enabled", Bool.self] = isEnabled
    updateAccess()
  }

  func setEnabled(_ isEnabled: Bool, for path: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard workspace.dictionary["permitted_directories", [String: Data].self]?[path] != nil else {
      return
    }
    var disabled = workspace.dictionary["disabled_permitted_directories", Set<String>.self] ?? []
    if isEnabled {
      disabled.remove(path)
    } else {
      disabled.insert(path)
    }
    workspace.dictionary["disabled_permitted_directories", Set<String>.self] = disabled
    updateAccess()
  }

  func validateRequest(_ url: URL) throws {
    guard isEnabled else { throw DirectoryPermissionError.featureDisabled }
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    let disabled = workspace.dictionary["disabled_permitted_directories", Set<String>.self] ?? []
    if disabled.contains(where: { root in
      path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }) {
      throw DirectoryPermissionError.folderDisabled
    }
  }

  deinit {
    for url in activeURLs.values { url.stopAccessingSecurityScopedResource() }
  }

  func contains(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    return urls.contains {
      let root = $0.standardizedFileURL.resolvingSymlinksInPath().path
      return path == root || path.hasPrefix(root == "/" ? root : root + "/")
    }
  }

  func add(_ url: URL) throws {
    dispatchPrecondition(condition: .onQueue(.main))
    try validateRequest(url)
    guard url.startAccessingSecurityScopedResource() else {
      throw DirectoryPermissionError.permissionDenied
    }
    var keepAccess = false
    defer { if !keepAccess { url.stopAccessingSecurityScopedResource() } }
    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw DirectoryPermissionError.notDirectory
    }
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    let bookmark = try Self.bookmark(for: url)
    lock.lock()
    if activeURLs[path] == nil {
      activeURLs[path] = url
      keepAccess = true
    }
    lock.unlock()
    var bookmarks = workspace.dictionary["permitted_directories", [String: Data].self] ?? [:]
    bookmarks[path] = bookmark
    workspace.dictionary["permitted_directories", [String: Data].self] = bookmarks
  }

  func revoke(_ path: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    var bookmarks = workspace.dictionary["permitted_directories", [String: Data].self] ?? [:]
    bookmarks[path] = nil
    workspace.dictionary["permitted_directories", [String: Data].self] = bookmarks
    var disabled = workspace.dictionary["disabled_permitted_directories", Set<String>.self] ?? []
    if disabled.remove(path) != nil {
      workspace.dictionary["disabled_permitted_directories", Set<String>.self] = disabled
    }
    lock.lock()
    let url = activeURLs.removeValue(forKey: path)
    lock.unlock()
    url?.stopAccessingSecurityScopedResource()
  }

  /// Returns the saved grant with its security scope started; the caller stops it.
  func access(_ directory: AppDataDirectory) -> URL? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let bookmark = workspace.dictionary[directory.bookmarkKey, Data.self] else {
      return nil
    }
    var stale = false
    #if os(macOS) || targetEnvironment(macCatalyst)
      let options: URL.BookmarkResolutionOptions = .withSecurityScope
    #else
      let options: URL.BookmarkResolutionOptions = []
    #endif
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale),
      url.startAccessingSecurityScopedResource()
    else { return nil }
    if stale, let updated = try? Self.readOnlyBookmark(for: url) {
      workspace.dictionary[directory.bookmarkKey, Data.self] = updated
    }
    return url
  }

  /// Saves the grant, replacing any earlier one. `url` must be accessible.
  func set(_ directory: AppDataDirectory, url: URL) throws {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary[directory.bookmarkKey, Data.self] = try Self.readOnlyBookmark(for: url)
  }

  private static func bookmark(for url: URL) throws -> Data {
    #if os(macOS) || targetEnvironment(macCatalyst)
      let options: URL.BookmarkCreationOptions = .withSecurityScope
    #else
      let options: URL.BookmarkCreationOptions = .minimalBookmark
    #endif
    return try url.bookmarkData(
      options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  private static func readOnlyBookmark(for url: URL) throws -> Data {
    #if os(macOS) || targetEnvironment(macCatalyst)
      let options: URL.BookmarkCreationOptions = [
        .withSecurityScope, .securityScopeAllowOnlyReadAccess,
      ]
    #else
      let options: URL.BookmarkCreationOptions = .minimalBookmark
    #endif
    return try url.bookmarkData(
      options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
  }
}
