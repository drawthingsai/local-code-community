import Foundation

/// A dropped file, kept as a session copy until the message that attaches it is sent.
struct ChatAttachment {
  /// The session copy: a drop's file representation is deleted once its callback returns.
  let url: URL
  /// The dropped file, when the drop carried its location.
  let sourceURL: URL?

  var name: String { url.lastPathComponent }

  /// Copies attachments into the directory and returns their paths relative to it. A file
  /// already in the directory is referenced in place; otherwise a name conflict with different
  /// contents is resolved the way Finder does ("name 2.ext").
  static func copy(_ attachments: [ChatAttachment], into directory: URL) throws -> [String] {
    let fileManager = FileManager.default
    let accessed = directory.startAccessingSecurityScopedResource()
    defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
    let directoryPath = directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
    return try attachments.map { attachment in
      if let sourcePath = attachment.sourceURL?.standardizedFileURL.resolvingSymlinksInPath()
        .path, sourcePath.hasPrefix(directoryPath), fileManager.fileExists(atPath: sourcePath)
      {
        return String(sourcePath.dropFirst(directoryPath.count))
      }
      let baseName = (attachment.name as NSString).deletingPathExtension
      let pathExtension = (attachment.name as NSString).pathExtension
      var name = attachment.name
      var index = 1
      while true {
        let url = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: url.path) else {
          try fileManager.copyItem(at: attachment.url, to: url)
          return name
        }
        if fileManager.contentsEqual(atPath: url.path, andPath: attachment.url.path) {
          return name
        }
        index += 1
        name =
          pathExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(pathExtension)"
      }
    }
  }

  /// Appends the attached files to the user's text as project-relative links.
  static func emitSections(_ text: String, paths: [String]) -> String {
    guard !paths.isEmpty else { return text }
    let links = paths.map { path in
      let name = (path as NSString).lastPathComponent
      // Angle brackets keep spaces and parentheses in file names valid link destinations.
      return path.contains(where: { " ()".contains($0) })
        ? "[\(name)](<\(path)>)" : "[\(name)](\(path))"
    }
    return [text, "**Attached**: " + links.joined(separator: ", ")].filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  /// Takes the attachment line `emitSections` appended back out of a message being restored into
  /// the draft, returning the remaining text and the linked paths.
  static func parseSections(_ text: String) -> (text: String, paths: [String]) {
    var paragraphs = text.components(separatedBy: "\n\n")
    guard let paths = paragraphs.last.flatMap(linkedPaths(in:)) else { return (text, []) }
    paragraphs.removeLast()
    return (paragraphs.joined(separator: "\n\n"), paths)
  }

  /// The paths of an "**Attached**: [name](path), [name](<path>)" line, or nil for anything else.
  private static func linkedPaths(in line: String) -> [String]? {
    let prefix = "**Attached**: "
    guard line.hasPrefix(prefix) else { return nil }
    var rest = line.dropFirst(prefix.count)
    var paths = [String]()
    while true {
      guard rest.hasPrefix("["), let destination = rest.range(of: "](") else { return nil }
      rest = rest[destination.upperBound...]
      if rest.hasPrefix("<") {
        guard let end = rest.range(of: ">)") else { return nil }
        paths.append(String(rest[rest.index(after: rest.startIndex)..<end.lowerBound]))
        rest = rest[end.upperBound...]
      } else {
        // emitSections only leaves paths without spaces or parentheses unbracketed.
        guard let end = rest.firstIndex(of: ")") else { return nil }
        paths.append(String(rest[..<end]))
        rest = rest[rest.index(after: end)...]
      }
      if rest.isEmpty { return paths }
      guard rest.hasPrefix(", ") else { return nil }
      rest = rest.dropFirst(2)
    }
  }
}
