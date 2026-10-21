import Foundation
import Yams

struct SkillRoot: Equatable, Sendable {
  enum Scope: Int, Equatable, Sendable {
    case builtIn
    case workspace
  }

  let url: URL
  let allowedRootURL: URL
  let scope: Scope
  let modelRootPath: String?

  init(url: URL, allowedRootURL: URL, scope: Scope, modelRootPath: String? = nil) {
    self.url = Self.canonicalURL(url)
    self.allowedRootURL = Self.canonicalURL(allowedRootURL)
    self.scope = scope
    self.modelRootPath = modelRootPath
  }

  private static func canonicalURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }
}

struct SkillCatalogEntry: Equatable, Sendable {
  let name: String
  let description: String
  let fileURL: URL
  let scope: SkillRoot.Scope
  let modelPath: String

  init(
    name: String, description: String, fileURL: URL, scope: SkillRoot.Scope,
    modelPath: String? = nil
  ) {
    self.name = name
    self.description = description
    self.fileURL = fileURL
    self.scope = scope
    self.modelPath = modelPath ?? fileURL.path
  }
}

struct SkillCatalogWarning: Equatable, Sendable {
  let path: String
  let message: String
}

public struct SkillCatalog: Equatable, Sendable {
  static let instructionsPlaceholder = "{{SKILLS_INSTRUCTIONS}}"
  static let metadataCharacterBudget = 8_000
  static let injectedSkillByteLimit = 8_000
  static let maxScanDepth = 6
  static let maxDirectoriesPerRoot = 2_000
  static let maxEntriesPerRoot = 20_000

  public static let empty = SkillCatalog(entries: [], warnings: [])

  let entries: [SkillCatalogEntry]
  let warnings: [SkillCatalogWarning]

  static func roots(
    builtInSkillsURL: URL?, projectURL: URL?, workspaceURL: URL
  ) -> [SkillRoot] {
    let workspaceURL = canonicalURL(workspaceURL)
    var roots = [SkillRoot]()
    if let builtInSkillsURL {
      roots.append(
        SkillRoot(
          url: builtInSkillsURL, allowedRootURL: builtInSkillsURL, scope: .builtIn,
          modelRootPath: "/app_bundle/Skills"))
    }

    let projectURL = projectURL.map(canonicalURL)
    let startURL = projectURL.flatMap { contains($0, in: workspaceURL) ? $0 : nil } ?? workspaceURL
    var ancestorURLs = [URL]()
    var ancestorURL = startURL
    while true {
      ancestorURLs.append(ancestorURL)
      guard ancestorURL.path != workspaceURL.path else { break }
      let parentURL = ancestorURL.deletingLastPathComponent()
      guard parentURL.path != ancestorURL.path, contains(parentURL, in: workspaceURL) else {
        ancestorURLs = [workspaceURL]
        break
      }
      ancestorURL = parentURL
    }
    for ancestorURL in ancestorURLs.reversed() {
      roots.append(
        SkillRoot(
          url: ancestorURL.appendingPathComponent(".agents/skills", isDirectory: true),
          allowedRootURL: workspaceURL, scope: .workspace))
    }

    var seen = Set<String>()
    return roots.filter { seen.insert($0.url.path).inserted }
  }

  static func find(roots: [SkillRoot]) -> SkillCatalog {
    let fileManager = FileManager.default
    var entries = [SkillCatalogEntry]()
    var warnings = [SkillCatalogWarning]()
    var seenSkillPaths = Set<String>()

    for root in roots {
      var isDirectory = ObjCBool(false)
      guard fileManager.fileExists(atPath: root.url.path, isDirectory: &isDirectory) else {
        continue
      }
      guard isDirectory.boolValue else {
        warnings.append(
          SkillCatalogWarning(path: root.url.path, message: "Skills root is not a directory."))
        continue
      }

      let discovery = discoverSkillFiles(in: root, fileManager: fileManager)
      warnings.append(contentsOf: discovery.warnings)
      for skillFileURL in discovery.urls {
        let canonicalSkillFileURL = canonicalURL(skillFileURL)
        guard contains(canonicalSkillFileURL, in: root.allowedRootURL) else {
          warnings.append(
            SkillCatalogWarning(
              path: skillFileURL.path,
              message: "Skill resolves outside its allowed root."))
          continue
        }
        guard seenSkillPaths.insert(canonicalSkillFileURL.path).inserted else { continue }
        do {
          let contents = try String(contentsOf: canonicalSkillFileURL, encoding: .utf8)
          let metadata = try parseFrontmatter(
            contents,
            defaultName: canonicalSkillFileURL.deletingLastPathComponent()
              .lastPathComponent)
          entries.append(
            SkillCatalogEntry(
              name: metadata.name, description: metadata.description,
              fileURL: canonicalSkillFileURL, scope: root.scope,
              modelPath: modelPath(for: canonicalSkillFileURL, in: root)))
        } catch {
          warnings.append(
            SkillCatalogWarning(
              path: canonicalSkillFileURL.path, message: error.localizedDescription))
        }
      }
    }

    entries.sort {
      if $0.scope.rawValue != $1.scope.rawValue {
        return $0.scope.rawValue < $1.scope.rawValue
      }
      let leftName = $0.name.lowercased()
      let rightName = $1.name.lowercased()
      if leftName != rightName { return leftName < rightName }
      return $0.fileURL.path < $1.fileURL.path
    }
    return SkillCatalog(entries: entries, warnings: warnings)
  }

  func emitSections(_ sections: [SystemPromptSection]) -> [SystemPromptSection] {
    let instructions = renderedInstructions()
    return sections.flatMap { section in
      let parts = section.text.components(separatedBy: Self.instructionsPlaceholder)
      guard parts.count == 2 else { return [section] }
      var result = [SystemPromptSection]()
      if !parts[0].isEmpty {
        result.append((parts[0], section.allowsSpecialTokens))
      }
      if !instructions.isEmpty {
        result.append(("\n\(instructions)\n", false))
      }
      if !parts[1].isEmpty {
        result.append((parts[1], section.allowsSpecialTokens))
      }
      return result
    }
  }

  private func renderedInstructions(characterBudget: Int = SkillCatalog.metadataCharacterBudget)
    -> String
  {
    guard !entries.isEmpty else { return "" }

    let blocks = renderedMetadataBlocks(characterBudget: max(0, characterBudget))
    return """
      The following skills provide specialized instructions for specific tasks.
      Use the read tool to load a skill's file when the task matches its description.
      When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.

      <available_skills>
      \(blocks.joined(separator: "\n"))
      </available_skills>
      """
  }

  private func explicitlyMentionedSkills(in text: String) -> [SkillCatalogEntry] {
    let mentions = Self.parseMentions(in: text)
    guard !mentions.names.isEmpty || !mentions.paths.isEmpty else { return [] }

    let linkedPaths = Set(mentions.paths.map(Self.normalizedMentionPath))
    var selected = [SkillCatalogEntry]()
    var seenPaths = Set<String>()
    for entry in entries where linkedPaths.contains(entry.modelPath) {
      if seenPaths.insert(entry.fileURL.path).inserted {
        selected.append(entry)
      }
    }

    let nameCounts = Dictionary(grouping: entries, by: \.name).mapValues(\.count)
    for entry in entries
    where mentions.names.contains(entry.name) && nameCounts[entry.name] == 1
      && !seenPaths.contains(entry.fileURL.path)
    {
      seenPaths.insert(entry.fileURL.path)
      selected.append(entry)
    }
    return selected
  }

  func prompt(
    for userPrompt: String,
    injectedSkillByteLimit: Int = SkillCatalog.injectedSkillByteLimit
  ) -> String {
    let selected = explicitlyMentionedSkills(in: userPrompt)
    guard !selected.isEmpty else { return userPrompt }
    let blocks = selected.map { entry -> String in
      let contents = try? String(contentsOf: entry.fileURL, encoding: .utf8)
      let body: String
      if let contents, contents.utf8.count <= max(0, injectedSkillByteLimit) {
        body = contents
      } else if contents == nil {
        body =
          "The skill could not be loaded by the host. Read the complete file at the path above "
          + "with the read tool before acting."
      } else {
        body =
          "This skill is larger than the host injection limit. Read the complete file at the "
          + "path above with the read tool before acting; do not rely on a partial read."
      }
      return """
        <skill>
        <name>\(Self.xmlEscaped(entry.name))</name>
        <path>\(Self.xmlEscaped(entry.modelPath))</path>
        \(body)
        </skill>
        """
    }
    return blocks.joined(separator: "\n\n") + "\n\n" + userPrompt
  }

  private func renderedMetadataBlocks(characterBudget: Int) -> [String] {
    let minimumBlocks = entries.map {
      Self.renderedMetadataBlock(for: $0, description: "")
    }
    let minimumCost = minimumBlocks.reduce(0) { $0 + $1.count + 1 }
    guard minimumCost <= characterBudget else {
      var result = [String]()
      var used = 0
      for block in minimumBlocks where used + block.count + 1 <= characterBudget {
        result.append(block)
        used += block.count + 1
      }
      return result
    }

    let fullBlocks = entries.map {
      Self.renderedMetadataBlock(for: $0, description: $0.description)
    }
    guard fullBlocks.reduce(0, { $0 + $1.count + 1 }) > characterBudget else {
      return fullBlocks
    }

    var descriptionLengths = Array(repeating: 0, count: entries.count)
    var remaining = characterBudget - minimumCost
    var madeProgress = true
    while remaining > 0 && madeProgress {
      madeProgress = false
      for index in entries.indices
      where descriptionLengths[index] < entries[index].description.count {
        let characterIndex = entries[index].description.index(
          entries[index].description.startIndex, offsetBy: descriptionLengths[index])
        let cost = Self.xmlEscaped(String(entries[index].description[characterIndex])).count
        guard remaining >= cost else { continue }
        descriptionLengths[index] += 1
        remaining -= cost
        madeProgress = true
      }
    }
    return zip(entries, descriptionLengths).map { entry, length in
      let endIndex = entry.description.index(
        entry.description.startIndex,
        offsetBy: min(length, entry.description.count))
      return Self.renderedMetadataBlock(
        for: entry, description: String(entry.description[..<endIndex]))
    }
  }

  private static func renderedMetadataBlock(
    for entry: SkillCatalogEntry, description: String
  ) -> String {
    """
     <skill>
     <name>\(xmlEscaped(entry.name))</name>
     <description>\(xmlEscaped(description))</description>
     <location>\(xmlEscaped(entry.modelPath))</location>
     </skill>
    """
  }

  private static func modelPath(for fileURL: URL, in root: SkillRoot) -> String {
    guard let modelRootPath = root.modelRootPath else { return fileURL.path }
    let relativePath = fileURL.path.dropFirst(root.url.path.count).drop(while: { $0 == "/" })
    return relativePath.isEmpty ? modelRootPath : "\(modelRootPath)/\(relativePath)"
  }

  private static func discoverSkillFiles(
    in root: SkillRoot, fileManager: FileManager
  ) -> (urls: [URL], warnings: [SkillCatalogWarning]) {
    var urls = [URL]()
    var warnings = [SkillCatalogWarning]()
    var visitedDirectories = Set<String>()
    var directoryCount = 0
    var entryCount = 0
    var reachedLimit = false

    func visit(_ directoryURL: URL, depth: Int) {
      guard !reachedLimit else { return }
      let canonicalDirectoryURL = canonicalURL(directoryURL)
      guard contains(canonicalDirectoryURL, in: root.allowedRootURL) else {
        warnings.append(
          SkillCatalogWarning(
            path: directoryURL.path, message: "Skill directory resolves outside its allowed root."))
        return
      }
      guard visitedDirectories.insert(canonicalDirectoryURL.path).inserted else { return }
      directoryCount += 1
      guard directoryCount <= maxDirectoriesPerRoot else {
        reachedLimit = true
        return
      }

      let children: [URL]
      do {
        children = try fileManager.contentsOfDirectory(
          at: canonicalDirectoryURL,
          includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles])
      } catch {
        warnings.append(
          SkillCatalogWarning(path: canonicalDirectoryURL.path, message: error.localizedDescription)
        )
        return
      }
      for childURL in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard !childURL.lastPathComponent.hasPrefix(".") else { continue }
        entryCount += 1
        guard entryCount <= maxEntriesPerRoot else {
          reachedLimit = true
          break
        }
        let canonicalChildURL = canonicalURL(childURL)
        guard contains(canonicalChildURL, in: root.allowedRootURL) else {
          warnings.append(
            SkillCatalogWarning(
              path: childURL.path, message: "Skill path resolves outside its allowed root."))
          continue
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: canonicalChildURL.path, isDirectory: &isDirectory)
        else { continue }
        if isDirectory.boolValue {
          if depth < maxScanDepth {
            visit(canonicalChildURL, depth: depth + 1)
          }
        } else if childURL.lastPathComponent == "SKILL.md" {
          urls.append(canonicalChildURL)
        }
      }
    }

    visit(root.url, depth: 0)
    if reachedLimit {
      warnings.append(
        SkillCatalogWarning(
          path: root.url.path, message: "Skills scan reached its traversal limit."))
    }
    return (urls, warnings)
  }

  private static func parseFrontmatter(
    _ contents: String, defaultName: String
  ) throws -> (name: String, description: String) {
    let normalizedContents = contents.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalizedContents.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
      throw SkillCatalogError.missingFrontmatter
    }
    guard
      let closingIndex = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "---"
      })
    else {
      throw SkillCatalogError.missingFrontmatter
    }
    let yaml = lines[1..<closingIndex].joined(separator: "\n")
    let parsed: [String: Any]
    do {
      guard let value = try Yams.load(yaml: yaml) as? [String: Any] else {
        throw SkillCatalogError.invalidFrontmatter("Expected a YAML mapping.")
      }
      parsed = value
    } catch let error as SkillCatalogError {
      throw error
    } catch {
      throw SkillCatalogError.invalidFrontmatter(error.localizedDescription)
    }

    let name: String
    if let rawName = parsed["name"] {
      guard let rawName = rawName as? String else {
        throw SkillCatalogError.invalidField("name")
      }
      let sanitizedName = sanitizeSingleLine(rawName)
      name = sanitizedName.isEmpty ? sanitizeSingleLine(defaultName) : sanitizedName
    } else {
      name = sanitizeSingleLine(defaultName)
    }
    guard !name.isEmpty else { throw SkillCatalogError.missingField("name") }
    guard name.count <= 64 else { throw SkillCatalogError.fieldTooLong("name", 64) }

    guard let rawDescription = parsed["description"] as? String else {
      throw SkillCatalogError.missingField("description")
    }
    let description = sanitizeSingleLine(rawDescription)
    guard !description.isEmpty else { throw SkillCatalogError.missingField("description") }
    guard description.count <= 1_024 else {
      throw SkillCatalogError.fieldTooLong("description", 1_024)
    }
    return (name, description)
  }

  private static func parseMentions(in text: String) -> (names: Set<String>, paths: Set<String>) {
    let bytes = Array(text.utf8)
    var names = Set<String>()
    var paths = Set<String>()
    var index = 0
    while index < bytes.count {
      if bytes[index] == 91,
        let linked = parseLinkedMention(bytes, start: index)
      {
        paths.insert(linked.path)
        index = linked.endIndex
        continue
      }
      guard bytes[index] == 36 else {
        index += 1
        continue
      }
      let nameStart = index + 1
      guard nameStart < bytes.count, isMentionNameByte(bytes[nameStart]) else {
        index += 1
        continue
      }
      var nameEnd = nameStart + 1
      while nameEnd < bytes.count, isMentionNameByte(bytes[nameEnd]) {
        nameEnd += 1
      }
      let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
      names.insert(name)
      index = nameEnd
    }
    return (names, paths)
  }

  private static func parseLinkedMention(
    _ bytes: [UInt8], start: Int
  ) -> (name: String, path: String, endIndex: Int)? {
    guard start + 3 < bytes.count, bytes[start + 1] == 36 else {
      return nil
    }
    let nameStart = start + 2
    guard isMentionNameByte(bytes[nameStart]) else { return nil }
    var nameEnd = nameStart + 1
    while nameEnd < bytes.count, isMentionNameByte(bytes[nameEnd]) {
      nameEnd += 1
    }
    guard nameEnd < bytes.count, bytes[nameEnd] == 93 else { return nil }
    var pathStart = nameEnd + 1
    while pathStart < bytes.count, bytes[pathStart].isASCIIWhitespace { pathStart += 1 }
    guard pathStart < bytes.count, bytes[pathStart] == 40 else { return nil }
    let contentsStart = pathStart + 1
    var pathEnd = contentsStart
    while pathEnd < bytes.count, bytes[pathEnd] != 41 { pathEnd += 1 }
    guard pathEnd < bytes.count else { return nil }
    let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)
    let path = String(decoding: bytes[contentsStart..<pathEnd], as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    return (name, path, pathEnd + 1)
  }

  private static func normalizedMentionPath(_ path: String) -> String {
    var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if path.hasPrefix("<"), path.hasSuffix(">") {
      path.removeFirst()
      path.removeLast()
    }
    if path.hasPrefix("skill://") {
      path.removeFirst("skill://".count)
    }
    if let url = URL(string: path), url.isFileURL {
      return canonicalURL(url).path
    }
    return canonicalURL(URL(fileURLWithPath: path)).path
  }

  private static func isMentionNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 48...57, 65...90, 97...122, 95, 58, 45:
      return true
    default:
      return false
    }
  }

  private static func sanitizeSingleLine(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  private static func canonicalURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private static func contains(_ url: URL, in rootURL: URL) -> Bool {
    let path = canonicalURL(url).path
    let rootPath = canonicalURL(rootURL).path
    return path == rootPath || path.hasPrefix(rootPath + "/")
  }
}

private enum SkillCatalogError: LocalizedError {
  case missingFrontmatter
  case invalidFrontmatter(String)
  case missingField(String)
  case invalidField(String)
  case fieldTooLong(String, Int)

  var errorDescription: String? {
    switch self {
    case .missingFrontmatter:
      return "Missing YAML frontmatter delimited by ---."
    case .invalidFrontmatter(let message):
      return "Invalid YAML frontmatter: \(message)"
    case .missingField(let field):
      return "Missing required skill field `\(field)`."
    case .invalidField(let field):
      return "Skill field `\(field)` must be a string."
    case .fieldTooLong(let field, let limit):
      return "Skill field `\(field)` exceeds \(limit) characters."
    }
  }
}

extension UInt8 {
  fileprivate var isASCIIWhitespace: Bool {
    self == 9 || self == 10 || self == 11 || self == 12 || self == 13 || self == 32
  }
}
