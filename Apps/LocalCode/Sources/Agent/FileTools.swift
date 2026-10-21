import BashToolContext
import CryptoKit
import Foundation
import Localization
import PDFKit
import PDFTextExtractor
import Ripgrep

private let fileOperationQueue: OperationQueue = {
  let queue = OperationQueue()
  queue.name = "com.liuliu.local-code.tools.file"
  queue.maxConcurrentOperationCount = 2
  return queue
}()
private let fileStateLock = NSLock()
private var readContinuations = [String: ReadContinuation]()

private func resolvedPath(
  _ path: String, projectPath: String?, workspacePath: String?, permittedDirectoryURLs: [URL] = []
) throws -> LocalPathResolver.Resolution {
  let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedPath.isEmpty else {
    throw FileToolError.missingPath
  }
  let localPathResolver = LocalPathResolver(
    projectPath: projectPath, workspacePath: workspacePath,
    permittedDirectoryURLs: permittedDirectoryURLs)
  guard let resolution = localPathResolver.resolve(trimmedPath) else {
    throw FileToolError.pathEscapesWorkspace
  }
  return resolution
}

private func validateCanModifyProjectFile(
  at url: URL, localPathResolver: LocalPathResolver
) throws {
  let workspacePath = localPathResolver.workspaceURL.path
  let path = url.standardizedFileURL.resolvingSymlinksInPath().path
  guard path == workspacePath || path.hasPrefix(workspacePath + "/") else { return }
  let relativePath = path == workspacePath ? "" : String(path.dropFirst(workspacePath.count + 1))
  guard !relativePath.split(separator: "/").contains(".localc") else {
    throw FileToolError.cannotModifyProjectMetadata
  }
}

private func savedToolResponseHashPrefix(
  for path: String, projectPath: String?, workspacePath: String?
) -> String? {
  let projectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  guard
    let url = try? resolvedPath(
      path, projectPath: projectPath, workspacePath: workspacePath
    ).url
  else { return nil }
  let responseDirectoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    .appendingPathComponent(".localc", isDirectory: true)
    .appendingPathComponent("tool_responses", isDirectory: true)
    .standardizedFileURL.resolvingSymlinksInPath()
  let responseURL = url.standardizedFileURL.resolvingSymlinksInPath()
  guard responseURL.deletingLastPathComponent().path == responseDirectoryURL.path else {
    return nil
  }
  let filename = responseURL.lastPathComponent
  guard filename.hasSuffix(".md") else { return nil }
  let hash = String(filename.dropLast(".md".count))
  guard hash.count >= 6,
    hash.unicodeScalars.allSatisfy({
      switch $0.value {
      case 48...57, 65...70, 97...102:
        return true
      default:
        return false
      }
    })
  else {
    return nil
  }
  return String(hash.prefix(6))
}

private func markdownEscapedLabel(_ text: String) -> String {
  text.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "[", with: "\\[")
    .replacingOccurrences(of: "]", with: "\\]")
}

func fileMarkdownLink(
  for path: String, projectPath: String?, workspacePath: String?
) -> String {
  let label = markdownEscapedLabel(path)
  guard
    let fileURL = try? resolvedPath(
      path, projectPath: projectPath, workspacePath: workspacePath
    ).url
  else { return label }
  return "[\(label)](<\(fileURL.absoluteString)>)"
}

private func lineTag(_ line: String) -> String {
  let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_-")
  var hash: UInt32 = 2_166_136_261
  for byte in line.utf8 {
    hash ^= UInt32(byte)
    hash = hash &* 16_777_619
  }
  var tag = ""
  for shift in stride(from: 18, through: 0, by: -6) {
    tag.append(alphabet[Int((hash >> UInt32(shift)) & 0x3f)])
  }
  return tag
}

private func boolValue(_ parameter: ToolCall.Request.Parameter) -> Bool? {
  switch parameter.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "true":
    return true
  case "false":
    return false
  default:
    return nil
  }
}

private func setReadContinuation(
  _ continuation: ReadContinuation?, projectPath: String?
) {
  let key = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  fileStateLock.lock()
  if let continuation = continuation {
    readContinuations[key] = continuation
  } else {
    readContinuations[key] = nil
  }
  fileStateLock.unlock()
}

private func readContinuation(projectPath: String?) -> ReadContinuation? {
  let key = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  fileStateLock.lock()
  let continuation = readContinuations[key]
  fileStateLock.unlock()
  return continuation
}

private func fileToolResponse(_ body: () throws -> String) -> String {
  do {
    return try body()
  } catch {
    return "Error: \(error.localizedDescription)"
  }
}

fileprivate struct PDFReadSnapshot {
  var url: URL
  var digest: SHA256.Digest
  var content: String
}

fileprivate struct ReadContinuation {
  var path: String
  var startLine: Int
  var raw: Bool
  var pdf: PDFReadSnapshot? = nil
}

fileprivate enum FileToolError: Error, LocalizedError {
  case missingPath
  case missingContent
  case missingReplacement
  case pathEscapesWorkspace
  case cannotModifyAppBundlePath
  case cannotModifyProjectMetadata
  case fileNotFound(String)
  case cannotReadDirectoryAsFile(String)
  case cannotWriteDirectory(String)
  case invalidLine(Int)
  case invalidTaggedLines
  case nonContiguousTaggedLines
  case tagMismatch(line: Int, current: String)
  case emptyOldText
  case oldTextNotFound
  case oldTextNotFoundOnTaggedLine
  case oldTextNotUnique
  case oldTextNotUniqueOnTaggedLine
  case invalidEditRequest
  case noReadContinuation
  case notDirectory(String)
  case invalidSearchMode(String)
  case invalidRegularExpression(String)
  case searchFailed(String)
  case notUTF8(String)
  case cannotEditPDF

  var errorDescription: String? {
    switch self {
    case .missingPath:
      return "Missing file path."
    case .missingContent:
      return "Missing file content."
    case .missingReplacement:
      return "Missing replacement text."
    case .pathEscapesWorkspace:
      return
        "Path is outside the project, workspace, temporary directory, app bundle, and permitted folders. Use permit <directory> in Bash to request folder access."
    case .cannotModifyAppBundlePath:
      return "Cannot modify an app bundle resource."
    case .cannotModifyProjectMetadata:
      return "Cannot modify project metadata."
    case .fileNotFound(let path):
      return "File not found: \(path)"
    case .cannotReadDirectoryAsFile(let path):
      return "Cannot edit directory: \(path)"
    case .cannotWriteDirectory(let path):
      return "Cannot write over directory: \(path)"
    case .invalidLine(let line):
      return "Invalid line number: \(line)"
    case .invalidTaggedLines:
      return "Invalid lines format; use one LINE:TAG entry per line being replaced."
    case .nonContiguousTaggedLines:
      return "Bulk tagged edit lines must be contiguous."
    case .tagMismatch(let line, let current):
      return
        "Line tag mismatch at line \(line); current tag=\(current). Re-read and retry with fresh lines."
    case .emptyOldText:
      return "Edit old/new requires non-empty old text."
    case .oldTextNotFound:
      return "Old text not found."
    case .oldTextNotFoundOnTaggedLine:
      return "Old text not found on the tagged line."
    case .oldTextNotUnique:
      return "Old text is not unique; use line tags."
    case .oldTextNotUniqueOnTaggedLine:
      return "Old text is not unique on the tagged line."
    case .invalidEditRequest:
      return "Edit requires line+tag+new, lines+new, or old+new."
    case .noReadContinuation:
      return "No previous read output is available to continue."
    case .notDirectory(let path):
      return "Not a directory: \(path)"
    case .invalidSearchMode(let mode):
      return "Invalid search mode: \(mode)"
    case .invalidRegularExpression(let pattern):
      return "Invalid regular expression: \(pattern)"
    case .searchFailed(let message):
      return "Search failed: \(message)"
    case .cannotEditPDF:
      return "PDF reads contain extracted Markdown. Save it to a Markdown file to edit it."
    case .notUTF8(let path):
      return "File is not UTF-8 text: \(path)"
    }
  }
}

public struct ReadTool {
  public var path: String
  public var startLine: Int
  public var maxLines: Int
  public var whole: Bool
  public var raw: Bool
  public var projectPath: String?
  public var workspacePath: String?

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_read_now")
    case .past:
      title = LocalizedString.forKey("tool_read_past")
    }
    if let hashPrefix = savedToolResponseHashPrefix(
      for: path, projectPath: projectPath, workspacePath: workspacePath)
    {
      return
        "**\(title)**: \(LocalizedString.forKey("tool_saved_response")) (\(hashPrefix))"
    }
    return
      "**\(title)**: \(fileMarkdownLink(for: path, projectPath: projectPath, workspacePath: workspacePath))"
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> ReadTool? {
    guard let pathParameter = request.parameters["path"] else { return nil }
    let path = pathParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    let startLine: Int
    if let parameter = request.parameters["start_line"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value), parsed > 0 else { return nil }
      startLine = parsed
    } else {
      startLine = 1
    }
    let maxLines: Int
    if let parameter = request.parameters["max_lines"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value), parsed > 0 else { return nil }
      maxLines = parsed
    } else {
      maxLines = 500
    }
    let whole: Bool
    if let parameter = request.parameters["whole"] {
      guard let parsed = boolValue(parameter) else { return nil }
      whole = parsed
    } else {
      whole = false
    }
    let raw: Bool
    if let parameter = request.parameters["raw"] {
      guard let parsed = boolValue(parameter) else { return nil }
      raw = parsed
    } else {
      raw = false
    }
    return ReadTool(
      path: path, startLine: startLine, maxLines: maxLines, whole: whole, raw: raw,
      projectPath: projectPath, workspacePath: workspacePath)
  }

  public func invoke(
    context: BashToolContext = .init(), completion: @escaping (String) -> Void
  ) {
    fileOperationQueue.addOperation {
      do {
        let url = try resolvedPath(
          path, projectPath: projectPath, workspacePath: workspacePath,
          permittedDirectoryURLs: context.permittedDirectoryURLs()
        ).url
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
          throw FileToolError.fileNotFound(path)
        }
        if isDirectory.boolValue {
          setReadContinuation(nil, projectPath: projectPath)
          let entries = try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
          let output = try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            return values.isDirectory == true ? "\(url.lastPathComponent)/" : url.lastPathComponent
          }
          completion(output.isEmpty ? "(empty directory)" : output.joined(separator: "\n"))
          return
        }
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "pdf" || data.starts(with: Data("%PDF-".utf8)) {
          let digest = SHA256.hash(data: data)
          if let snapshot = readContinuation(projectPath: projectPath)?.pdf,
            snapshot.url == url, snapshot.digest == digest
          {
            completion(try read(snapshot.content, pdf: snapshot))
          } else {
            readPDF(data, url: url, digest: digest, context: context, completion: completion)
          }
          return
        }
        guard let content = String(data: data, encoding: .utf8) else {
          throw FileToolError.notUTF8(path)
        }
        completion(try read(content))
      } catch {
        completion("Error: \(error.localizedDescription)")
      }
    }
  }

  private func readPDF(
    _ data: Data, url: URL, digest: SHA256.Digest, context: BashToolContext,
    password: String? = nil, completion: @escaping (String) -> Void
  ) {
    // PDFKit validates the password before extraction. An unsupported Rust-side
    // encryption method must produce an error rather than another password prompt.
    if let document = PDFDocument(data: data), document.isLocked,
      !document.unlock(withPassword: password ?? "")
    {
      guard let requestPassword = context.requestPDFPassword else {
        completion("Error: PDF requires a password: \(path)")
        return
      }
      requestPassword(url, password != nil, context.bashUserInteraction) { password in
        guard let password else {
          completion("Error: PDF password entry was cancelled: \(path)")
          return
        }
        fileOperationQueue.addOperation {
          // Recheck folder permission after waiting for the user.
          do {
            _ = try resolvedPath(
              url.path, projectPath: projectPath, workspacePath: workspacePath,
              permittedDirectoryURLs: context.permittedDirectoryURLs())
            readPDF(
              data, url: url, digest: digest, context: context,
              password: password, completion: completion)
          } catch {
            completion("Error: \(error.localizedDescription)")
          }
        }
      }
      return
    }
    completion(
      fileToolResponse {
        let pages = try PDFTextExtractor.extract(data, password: password)
        let content = pages.map { page in
          let text =
            page.needsOCR
            ? "[No reliable text extracted from this page. OCR or visual inspection is needed.]"
            : page.markdown
          return "<!-- Page \(page.number) -->\n" + text
        }.joined(separator: "\n\n")
        return try read(content, pdf: PDFReadSnapshot(url: url, digest: digest, content: content))
      })
  }

  private func read(_ content: String, pdf: PDFReadSnapshot? = nil) throws -> String {
    if whole && raw {
      setReadContinuation(nil, projectPath: projectPath)
      return content
    }
    let lines = content.components(separatedBy: "\n")
    guard startLine <= lines.count else {
      throw FileToolError.invalidLine(startLine)
    }
    let endLine = whole ? lines.count : min(lines.count, startLine + maxLines - 1)
    let selectedLines = lines[(startLine - 1)..<endLine]
    if !whole && endLine < lines.count {
      setReadContinuation(
        ReadContinuation(path: path, startLine: endLine + 1, raw: raw, pdf: pdf),
        projectPath: projectPath)
    } else {
      setReadContinuation(nil, projectPath: projectPath)
    }
    if raw {
      var output = selectedLines.joined(separator: "\n")
      if !whole && endLine < lines.count {
        if !output.hasSuffix("\n") {
          output += "\n"
        }
        output +=
          "[Read truncated at line \(endLine) of \(lines.count). continue_offset=\(endLine + 1). "
          + "Call the more tool with count=\(maxLines) to read the next chunk.]"
      }
      return output
    }
    let source = pdf == nil ? path : "\(path) (extracted PDF Markdown)"
    let header: String
    if !whole && endLine < lines.count {
      header =
        "\(source): lines \(startLine)-\(endLine) of \(lines.count); "
        + "continue_offset=\(endLine + 1); "
        + "call the more tool with count=\(maxLines) to read the next chunk"
    } else {
      header = "\(source): lines \(startLine)-\(endLine) of \(lines.count)"
    }
    let body = selectedLines.enumerated().map { offset, line in
      "\(startLine + offset):\(lineTag(line))> \(line)"
    }.joined(separator: "\n")
    return body.isEmpty ? header : header + "\n" + body
  }
}

public struct MoreTool {
  public var count: Int
  public var projectPath: String?
  public var workspacePath: String?

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_more_now")
    case .past:
      title = LocalizedString.forKey("tool_more_past")
    }
    return "**\(title)**"
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> MoreTool? {
    let count: Int
    if let parameter = request.parameters["count"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value), parsed > 0 else { return nil }
      count = parsed
    } else {
      count = 500
    }
    return MoreTool(count: count, projectPath: projectPath, workspacePath: workspacePath)
  }

  public func invoke(
    context: BashToolContext = .init(), completion: @escaping (String) -> Void
  ) {
    guard let continuation = readContinuation(projectPath: projectPath) else {
      completion("Error: \(FileToolError.noReadContinuation.localizedDescription)")
      return
    }
    ReadTool(
      path: continuation.path, startLine: continuation.startLine, maxLines: count,
      whole: false, raw: continuation.raw, projectPath: projectPath,
      workspacePath: workspacePath
    ).invoke(context: context, completion: completion)
  }
}

public struct WriteTool {
  public var path: String
  public var content: String
  public var projectPath: String?
  public var workspacePath: String?

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_write_now")
    case .past:
      title = LocalizedString.forKey("tool_write_past")
    }
    return
      "**\(title)**: \(fileMarkdownLink(for: path, projectPath: projectPath, workspacePath: workspacePath))"
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> WriteTool? {
    guard let pathParameter = request.parameters["path"] else { return nil }
    let path = pathParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    guard let contentParameter = request.parameters["content"] else { return nil }
    return WriteTool(
      path: path, content: contentParameter.value, projectPath: projectPath,
      workspacePath: workspacePath)
  }

  public func invoke(
    permittedDirectoryURLs: @escaping () -> [URL] = { [] }, completion: @escaping (String) -> Void
  ) {
    fileOperationQueue.addOperation {
      completion(fileToolResponse { try write(permittedDirectoryURLs: permittedDirectoryURLs()) })
    }
  }

  private func write(permittedDirectoryURLs: [URL]) throws -> String {
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { throw FileToolError.missingPath }
    let localPathResolver = LocalPathResolver(
      projectPath: projectPath, workspacePath: workspacePath,
      permittedDirectoryURLs: permittedDirectoryURLs)
    guard let resolution = localPathResolver.resolve(path) else {
      throw FileToolError.pathEscapesWorkspace
    }
    guard resolution.namespace != .appBundle else {
      throw FileToolError.cannotModifyAppBundlePath
    }
    let url = resolution.url
    try validateCanModifyProjectFile(at: url, localPathResolver: localPathResolver)
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      throw FileToolError.cannotWriteDirectory(path)
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = Data(content.utf8)
    try data.write(to: url, options: .atomic)
    return "Wrote \(data.count) bytes to \(path)"
  }
}

public struct EditTool {
  public var path: String
  public var line: Int?
  public var tag: String?
  public var lines: String?
  public var old: String?
  public var new: String?
  public var projectPath: String?
  public var workspacePath: String?

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_edit_now")
    case .past:
      title = LocalizedString.forKey("tool_edit_past")
    }
    return
      "**\(title)**: \(fileMarkdownLink(for: path, projectPath: projectPath, workspacePath: workspacePath))"
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> EditTool? {
    guard let pathParameter = request.parameters["path"] else { return nil }
    let path = pathParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    let line: Int?
    if let parameter = request.parameters["line"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value), parsed > 0 else { return nil }
      line = parsed
    } else {
      line = nil
    }
    let tag = request.parameters["tag"]?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = request.parameters["lines"]?.value
    let old = request.parameters["old"]?.value
    let new = request.parameters["new"]?.value
    return EditTool(
      path: path, line: line, tag: tag, lines: lines, old: old, new: new,
      projectPath: projectPath, workspacePath: workspacePath)
  }

  public func invoke(
    permittedDirectoryURLs: @escaping () -> [URL] = { [] }, completion: @escaping (String) -> Void
  ) {
    fileOperationQueue.addOperation {
      completion(fileToolResponse { try edit(permittedDirectoryURLs: permittedDirectoryURLs()) })
    }
  }

  private func edit(permittedDirectoryURLs: [URL]) throws -> String {
    let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { throw FileToolError.missingPath }
    let localPathResolver = LocalPathResolver(
      projectPath: projectPath, workspacePath: workspacePath,
      permittedDirectoryURLs: permittedDirectoryURLs)
    guard let resolution = localPathResolver.resolve(path) else {
      throw FileToolError.pathEscapesWorkspace
    }
    guard resolution.namespace != .appBundle else {
      throw FileToolError.cannotModifyAppBundlePath
    }
    let url = resolution.url
    try validateCanModifyProjectFile(at: url, localPathResolver: localPathResolver)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw FileToolError.fileNotFound(path)
    }
    guard !isDirectory.boolValue else {
      throw FileToolError.cannotReadDirectoryAsFile(path)
    }
    let data = try Data(contentsOf: url)
    guard url.pathExtension.lowercased() != "pdf", !data.starts(with: Data("%PDF-".utf8)) else {
      throw FileToolError.cannotEditPDF
    }
    guard var content = String(data: data, encoding: .utf8) else {
      throw FileToolError.notUTF8(path)
    }
    let editMessage: String
    if let taggedLines = lines {
      guard let new = new else { throw FileToolError.missingReplacement }
      var fileLines = content.components(separatedBy: "\n")
      let parsedLines = try parseTaggedLines(taggedLines)
      guard let firstLine = parsedLines.first?.line, let lastLine = parsedLines.last?.line else {
        throw FileToolError.invalidTaggedLines
      }
      for (index, taggedLine) in parsedLines.enumerated() {
        guard taggedLine.line == firstLine + index else {
          throw FileToolError.nonContiguousTaggedLines
        }
        guard taggedLine.line <= fileLines.count else {
          throw FileToolError.invalidLine(taggedLine.line)
        }
        let currentTag = lineTag(fileLines[taggedLine.line - 1])
        guard currentTag == taggedLine.tag else {
          throw FileToolError.tagMismatch(line: taggedLine.line, current: currentTag)
        }
      }
      fileLines.replaceSubrange(
        (firstLine - 1)..<lastLine, with: new.components(separatedBy: "\n"))
      content = fileLines.joined(separator: "\n")
      editMessage = "Edited \(path) lines \(firstLine)-\(lastLine)"
    } else if let old = old, let line = line, let tag = tag, !tag.isEmpty {
      guard let new = new else { throw FileToolError.missingReplacement }
      guard !old.isEmpty else { throw FileToolError.emptyOldText }
      var fileLines = content.components(separatedBy: "\n")
      guard line <= fileLines.count else {
        throw FileToolError.invalidLine(line)
      }
      var lineText = fileLines[line - 1]
      let currentTag = lineTag(lineText)
      guard currentTag == tag else {
        throw FileToolError.tagMismatch(line: line, current: currentTag)
      }
      var ranges = [Range<String.Index>]()
      var searchIndex = lineText.startIndex
      while let range = lineText[searchIndex...].range(of: old) {
        ranges.append(range)
        guard ranges.count < 2 else {
          throw FileToolError.oldTextNotUniqueOnTaggedLine
        }
        searchIndex = range.upperBound
      }
      guard let range = ranges.first else {
        throw FileToolError.oldTextNotFoundOnTaggedLine
      }
      lineText.replaceSubrange(range, with: new)
      fileLines[line - 1] = lineText
      content = fileLines.joined(separator: "\n")
      editMessage = "Edited \(path) line \(line) using tag-restricted old/new"
    } else if let old = old {
      guard let new = new else { throw FileToolError.missingReplacement }
      guard !old.isEmpty else { throw FileToolError.emptyOldText }
      var ranges = [Range<String.Index>]()
      var searchIndex = content.startIndex
      while let range = content[searchIndex...].range(of: old) {
        ranges.append(range)
        guard ranges.count < 2 else {
          throw FileToolError.oldTextNotUnique
        }
        searchIndex = range.upperBound
      }
      guard let range = ranges.first else {
        throw FileToolError.oldTextNotFound
      }
      content.replaceSubrange(range, with: new)
      editMessage = "Edited \(path) using old/new replacement"
    } else if let line = line, let tag = tag {
      guard let new = new else { throw FileToolError.missingReplacement }
      var fileLines = content.components(separatedBy: "\n")
      guard line <= fileLines.count else {
        throw FileToolError.invalidLine(line)
      }
      let currentTag = lineTag(fileLines[line - 1])
      guard currentTag == tag else {
        throw FileToolError.tagMismatch(line: line, current: currentTag)
      }
      fileLines.replaceSubrange((line - 1)..<line, with: new.components(separatedBy: "\n"))
      content = fileLines.joined(separator: "\n")
      editMessage = "Edited \(path) lines \(line)-\(line)"
    } else {
      throw FileToolError.invalidEditRequest
    }
    try Data(content.utf8).write(to: url, options: .atomic)
    return editMessage
  }

  private func parseTaggedLines(_ text: String) throws -> [(line: Int, tag: String)] {
    let rows = text.split(whereSeparator: \.isNewline)
    guard !rows.isEmpty else {
      throw FileToolError.invalidTaggedLines
    }
    return try rows.map { row in
      let trimmed = row.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let colonIndex = trimmed.firstIndex(of: ":") else {
        throw FileToolError.invalidTaggedLines
      }
      let lineText = trimmed[..<colonIndex]
      guard let line = Int(lineText), line > 0 else {
        throw FileToolError.invalidTaggedLines
      }
      let tagStart = trimmed.index(after: colonIndex)
      let tagEnd = trimmed[tagStart...].firstIndex(of: ">") ?? trimmed.endIndex
      let tag = trimmed[tagStart..<tagEnd].trimmingCharacters(in: .whitespacesAndNewlines)
      guard tag.count == 4 else {
        throw FileToolError.invalidTaggedLines
      }
      return (line: line, tag: tag)
    }
  }
}

private enum SearchMode: String {
  case text
  case regex
  case files
}

private final class RipgrepSearchCollector {
  struct Result {
    let kind: Int32
    let path: String
    let lineNumber: Int
    let line: String?
  }

  var results = [Result]()
  var error: String?
}

private let ripgrepSearchResultCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<UInt8>?, Int, UInt64,
    UnsafePointer<UInt8>?, Int
  ) -> Void = { context, kind, path, pathLength, lineNumber, line, lineLength in
    guard let context = context, let path = path else { return }
    let collector = Unmanaged<RipgrepSearchCollector>.fromOpaque(context).takeUnretainedValue()
    guard
      let path = String(
        bytes: UnsafeBufferPointer(start: path, count: pathLength), encoding: .utf8),
      lineNumber <= UInt64(Int.max)
    else {
      collector.error = "Ripgrep returned an invalid path or line number."
      return
    }
    let text: String?
    if kind == LOCAL_CODE_RIPGREP_RESULT_LINE {
      guard
        let decodedText = String(
          bytes: UnsafeBufferPointer(start: line, count: lineLength), encoding: .utf8)
      else {
        collector.error = "Ripgrep returned a non-UTF-8 line."
        return
      }
      text = decodedText
    } else {
      text = nil
    }
    collector.results.append(
      RipgrepSearchCollector.Result(
        kind: kind, path: path, lineNumber: Int(lineNumber), line: text))
  }

private let ripgrepSearchErrorCallback:
  @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int
  ) -> Void = { context, message, messageLength in
    guard let context = context else { return }
    let collector = Unmanaged<RipgrepSearchCollector>.fromOpaque(context).takeUnretainedValue()
    guard
      let message = String(
        bytes: UnsafeBufferPointer(start: message, count: messageLength), encoding: .utf8)
    else {
      collector.error = "Ripgrep search failed."
      return
    }
    collector.error = message
  }

public struct SearchTool {
  public var query: String
  public var path: String?
  private var mode: SearchMode
  public var glob: String?
  public var context: Int
  public var maxResults: Int
  public var caseSensitive: Bool
  public var projectPath: String?
  public var workspacePath: String?

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_search_now")
    case .past:
      title = LocalizedString.forKey("tool_search_past")
    }
    return "**\(title)**: \(query)"
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> SearchTool? {
    guard let queryParameter = request.parameters["query"] else { return nil }
    let query = queryParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let path = request.parameters["path"]?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    let mode: SearchMode
    if let parameter = request.parameters["mode"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard let parsed = SearchMode(rawValue: value) else { return nil }
      mode = parsed
    } else {
      mode = .text
    }
    let glob = request.parameters["glob"]?.value.trimmingCharacters(in: .whitespacesAndNewlines)
    let context: Int
    if let parameter = request.parameters["context"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value), parsed >= 0 else { return nil }
      context = parsed
    } else {
      context = 0
    }
    let maxResults: Int
    if let parameter = request.parameters["max_results"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value), parsed > 0 else { return nil }
      maxResults = parsed
    } else {
      maxResults = 100
    }
    let caseSensitive: Bool
    if let parameter = request.parameters["case_sensitive"] {
      guard let parsed = boolValue(parameter) else { return nil }
      caseSensitive = parsed
    } else {
      caseSensitive = false
    }
    return SearchTool(
      query: query, path: path?.isEmpty == true ? nil : path, mode: mode,
      glob: glob?.isEmpty == true ? nil : glob, context: context, maxResults: maxResults,
      caseSensitive: caseSensitive, projectPath: projectPath, workspacePath: workspacePath)
  }

  public func invoke(
    permittedDirectoryURLs: @escaping () -> [URL] = { [] }, completion: @escaping (String) -> Void
  ) {
    fileOperationQueue.addOperation {
      completion(fileToolResponse { try search(permittedDirectoryURLs: permittedDirectoryURLs()) })
    }
  }

  private func search(permittedDirectoryURLs: [URL]) throws -> String {
    let resolution = try resolvedPath(
      path ?? ".", projectPath: projectPath, workspacePath: workspacePath,
      permittedDirectoryURLs: permittedDirectoryURLs)
    let baseURL = resolution.url
    guard FileManager.default.fileExists(atPath: baseURL.path) else {
      throw FileToolError.fileNotFound(path ?? ".")
    }
    let searchRootURL = resolution.rootURL
    let ripgrepMode: Int32
    switch mode {
    case .text:
      ripgrepMode = Int32(LOCAL_CODE_RIPGREP_MODE_TEXT)
    case .regex:
      ripgrepMode = Int32(LOCAL_CODE_RIPGREP_MODE_REGEX)
    case .files:
      ripgrepMode = Int32(LOCAL_CODE_RIPGREP_MODE_FILES)
    }

    let collector = RipgrepSearchCollector()
    let collectorContext = Unmanaged.passUnretained(collector).toOpaque()
    var maxResultsReached = false
    let status = searchRootURL.path.withCString { projectRoot in
      baseURL.path.withCString { root in
        query.withCString { query in
          (glob ?? "").withCString { glob in
            local_code_ripgrep_search(
              projectRoot, root, query, glob, ripgrepMode, caseSensitive, context, maxResults,
              collectorContext, ripgrepSearchResultCallback, ripgrepSearchErrorCallback,
              &maxResultsReached)
          }
        }
      }
    }
    switch status {
    case Int32(LOCAL_CODE_RIPGREP_STATUS_OK):
      break
    case Int32(LOCAL_CODE_RIPGREP_STATUS_INVALID_REGEX) where mode == .regex:
      throw FileToolError.invalidRegularExpression(query)
    default:
      throw FileToolError.searchFailed(collector.error ?? "Ripgrep search failed.")
    }
    if let error = collector.error {
      throw FileToolError.searchFailed(error)
    }

    guard !collector.results.isEmpty else {
      return "(no matches)"
    }
    if mode == .files {
      var output = try collector.results.map { result -> String in
        switch result.kind {
        case Int32(LOCAL_CODE_RIPGREP_RESULT_FILE):
          return resolution.reference(for: result.path)
        case Int32(LOCAL_CODE_RIPGREP_RESULT_DIRECTORY):
          return "\(resolution.reference(for: result.path))/"
        default:
          throw FileToolError.searchFailed("Ripgrep returned an invalid file result.")
        }
      }
      if maxResultsReached {
        output.append("max_results_reached=true")
      }
      return output.joined(separator: "\n")
    }

    var blocks = [String]()
    var currentPath: String?
    var currentLines = [String]()
    for result in collector.results {
      guard result.kind == Int32(LOCAL_CODE_RIPGREP_RESULT_LINE), let line = result.line else {
        throw FileToolError.searchFailed("Ripgrep returned an invalid content result.")
      }
      if currentPath != result.path {
        if let currentPath = currentPath, !currentLines.isEmpty {
          blocks.append(
            "\(resolution.reference(for: currentPath)):\n\(currentLines.joined(separator: "\n"))")
        }
        currentPath = result.path
        currentLines.removeAll(keepingCapacity: true)
      }
      currentLines.append("\(result.lineNumber):\(lineTag(line))> \(line)")
    }
    if let currentPath = currentPath, !currentLines.isEmpty {
      blocks.append(
        "\(resolution.reference(for: currentPath)):\n\(currentLines.joined(separator: "\n"))")
    }
    if maxResultsReached {
      blocks.append("max_results_reached=true")
    }
    return blocks.joined(separator: "\n\n")
  }
}

public struct ListTool {
  public var path: String
  public var projectPath: String?
  public var workspacePath: String?

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_list_now")
    case .past:
      title = LocalizedString.forKey("tool_list_past")
    }
    return "**\(title)**: \(path)"
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> ListTool? {
    guard let pathParameter = request.parameters["path"] else { return nil }
    let path = pathParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    return ListTool(path: path, projectPath: projectPath, workspacePath: workspacePath)
  }

  public func invoke(
    permittedDirectoryURLs: @escaping () -> [URL] = { [] }, completion: @escaping (String) -> Void
  ) {
    fileOperationQueue.addOperation {
      completion(fileToolResponse { try list(permittedDirectoryURLs: permittedDirectoryURLs()) })
    }
  }

  private func list(permittedDirectoryURLs: [URL]) throws -> String {
    let url = try resolvedPath(
      path, projectPath: projectPath, workspacePath: workspacePath,
      permittedDirectoryURLs: permittedDirectoryURLs
    ).url
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw FileToolError.fileNotFound(path)
    }
    guard isDirectory.boolValue else {
      throw FileToolError.notDirectory(path)
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    let output = try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      return values.isDirectory == true ? "\(url.lastPathComponent)/" : url.lastPathComponent
    }
    return output.isEmpty ? "(empty directory)" : output.joined(separator: "\n")
  }
}
