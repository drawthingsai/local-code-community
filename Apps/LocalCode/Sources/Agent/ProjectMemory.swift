import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum ProjectMemory {
  enum Target: String, CaseIterable {
    case user
    case memory

    var fileName: String { self == .user ? "USER.md" : "MEMORY.md" }
    var limit: Int { self == .user ? 1_375 : 2_200 }
    var relativePath: String { ".localc/\(fileName)" }
  }

  enum Error: LocalizedError {
    case invalidArguments(String)
    case unavailableProject
    case invalidPath
    case invalidFile(String)
    case busy
    case changed
    case writeFailed

    var errorDescription: String? {
      switch self {
      case .invalidArguments(let message), .invalidFile(let message): return message
      case .unavailableProject: return "No project is available for memory."
      case .invalidPath: return "Memory paths must stay inside the project and use regular files."
      case .busy: return "Memory is being updated by another writer. Retry later."
      case .changed:
        return "The memory file changed during this call. Read it again before retrying."
      case .writeFailed: return "Unable to write the memory file."
      }
    }
  }

  static let maximumBytes = 64 * 1_024
  static let memoryReviewInterval = 10

  // Follows Hermes's review questions about personal details and preferred assistant behavior:
  // https://github.com/NousResearch/hermes-agent/blob/b2aa855b626ff8688eb34b95c60ee8b6a4af3679/agent/background_review.py#L299-L308
  // https://github.com/NousResearch/hermes-agent/blob/b2aa855b626ff8688eb34b95c60ee8b6a4af3679/tools/memory_tool.py#L235-L244
  // Target labels route personal details to USER.md and operating expectations to MEMORY.md.
  // This focus replaced broader project-fact extraction after an off-target review in local use.
  // This temporary ask inherits MemoryContext's policy and the tool schema, so keep the follow-up
  // focused on what to notice instead of repeating editing rules. Read both files because the
  // frozen prompt can lag disk changes. The host owns temporary execution and the review heading.
  // Source comparison and wording rationale: Apps/LocalCode/DDDoc/MemoryPromptStudy.md, section 4.
  static let reviewPrompt = """
    Review the conversation and consider saving to memory if appropriate:

    1. USER.md: Has the user revealed things about themselves — their persona, desires, preferences, or personal details worth remembering?
    2. MEMORY.md: Has the user expressed expectations about how you should behave, their work style, or ways they want you to operate??

    Use only the memory tool. Read both files before making changes. Save or update worthwhile entries, then briefly report what changed. If nothing needs saving, say "Nothing to save."
    """

  static func parse(_ data: Data) throws -> [String] {
    guard data.count <= maximumBytes else {
      throw Error.invalidFile("Memory exceeds the 64 KiB read limit.")
    }
    guard var text = String(data: data, encoding: .utf8) else {
      throw Error.invalidFile("Memory must be UTF-8 text.")
    }
    if text.hasPrefix("\u{feff}") { text.removeFirst() }
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    var entries = [String]()
    var lines = [String]()
    for line in text.components(separatedBy: "\n") {
      if line == "§" {
        entries.append(
          lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        lines.removeAll(keepingCapacity: true)
      } else {
        lines.append(line)
      }
    }
    entries.append(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    guard entries.allSatisfy({ !$0.isEmpty }) else {
      throw Error.invalidFile(
        "Memory contains an empty entry around a § separator. Correct the file before editing it.")
    }
    return entries
  }

  static func fileURL(projectPath: String?, target: Target, createDirectory: Bool = false) throws
    -> URL
  {
    guard let projectPath, !projectPath.isEmpty else { throw Error.unavailableProject }
    let root = URL(fileURLWithPath: projectPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw Error.unavailableProject
    }
    let directory = root.appendingPathComponent(".localc", isDirectory: true)
      .resolvingSymlinksInPath()
    guard directory.path.hasPrefix(root.path + "/") else { throw Error.invalidPath }
    if createDirectory {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let file = directory.appendingPathComponent(target.fileName)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
      attributes[.type] as? FileAttributeType != .typeRegular
    {
      throw Error.invalidPath
    }
    return file
  }

  static func read(_ file: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else {
      throw Error.invalidFile("Memory exceeds the 64 KiB read limit.")
    }
    return data
  }

  static func contents(_ entries: [String], target: Target) -> String {
    let body = entries.joined(separator: "\n§\n")
    let usage = "\(body.unicodeScalars.count) / \(target.limit) characters used."
    return body.isEmpty ? "\(usage)\nNo entries." : "\(usage)\n\nCurrent contents:\n\(body)"
  }

  /// Returns the response, shown entries, and pre-write entries only when a write occurred.
  static func update(
    projectPath: String?, target: Target, action: String, content: String?, oldText: String?
  ) throws -> (response: String, entries: [String], previousEntries: [String]?) {
    let file = try fileURL(projectPath: projectPath, target: target, createDirectory: true)
    let lockPath = file.deletingLastPathComponent().appendingPathComponent("memory.lock").path
    let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
    guard descriptor >= 0 else { throw Error.writeFailed }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Error.busy }
    defer { flock(descriptor, LOCK_UN) }
    let original = try read(file)
    let entries = try parse(original ?? Data())
    var candidate = entries
    let result: String
    switch action {
    case "append":
      if entries.contains(where: { $0.utf8.elementsEqual(content!.utf8) }) {
        return (
          "Entry already present in \(target.relativePath); no changes.\n\(contents(entries, target: target))",
          entries, nil
        )
      }
      candidate.append(content!)
      result = "Appended to \(target.relativePath)."
    case "remove", "replace":
      let matches = entries.indices.filter {
        entries[$0].range(of: oldText!, options: .literal) != nil
      }
      guard matches.count == 1 else {
        throw Error.invalidArguments(
          "old_text matches \(matches.count) entries in \(target.relativePath). Use a substring that identifies exactly one entry."
        )
      }
      if action == "remove" {
        candidate.remove(at: matches[0])
        result = "Removed entry from \(target.relativePath)."
      } else {
        candidate[matches[0]] = content!
        result = "Replaced entry in \(target.relativePath)."
      }
    default: throw Error.invalidArguments("Unsupported memory action.")
    }
    let body = candidate.joined(separator: "\n§\n")
    guard body.unicodeScalars.count <= target.limit else {
      throw Error.invalidArguments(
        "The change would use \(body.unicodeScalars.count) / \(target.limit) characters in \(target.relativePath). Shorten or remove an entry first."
      )
    }
    if body.utf8.elementsEqual(entries.joined(separator: "\n§\n").utf8) {
      return (
        "No changes to \(target.relativePath).\n\(contents(entries, target: target))", entries,
        nil
      )
    }
    let currentFile = try fileURL(projectPath: projectPath, target: target)
    guard currentFile == file, try read(currentFile) == original else { throw Error.changed }
    try Data((body.isEmpty ? "" : body + "\n").utf8).write(to: file, options: .atomic)
    return ("\(result)\n\(contents(candidate, target: target))", candidate, entries)
  }
}
