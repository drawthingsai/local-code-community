import Foundation

public struct ProjectContext: Equatable, Sendable {
  static let instructionsPlaceholder = "{{PROJECT_INSTRUCTIONS}}"
  public static let empty = ProjectContext(content: "")

  public let content: String
  public let fileName: String

  public init(content: String, fileName: String = "AGENTS.md") {
    self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    self.fileName = fileName
  }

  static func load(projectURL: URL?) -> ProjectContext {
    guard let projectURL else { return .empty }
    // Project context is intentionally limited to the first matching root file. Nested discovery
    // is not part of this loader.
    let candidateFileNames = [
      "AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD",
    ]
    for fileName in candidateFileNames {
      let fileURL = projectURL.appendingPathComponent(fileName, isDirectory: false)
      var isDirectory: ObjCBool = false
      guard
        FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
        !isDirectory.boolValue,
        var content = try? String(contentsOf: fileURL, encoding: .utf8)
      else { continue }
      if content.hasPrefix("\u{feff}") {
        content.removeFirst()
      }
      return ProjectContext(content: content, fileName: fileName)
    }
    return .empty
  }

  func emitSections(
    _ sections: [SystemPromptSection]
  ) -> [SystemPromptSection] {
    let context = renderedQwenContext()
    return sections.flatMap { section in
      let parts = section.text.components(separatedBy: Self.instructionsPlaceholder)
      guard parts.count == 2 else { return [section] }
      var result = [SystemPromptSection]()
      if !parts[0].isEmpty {
        result.append((parts[0], section.allowsSpecialTokens))
      }
      if !context.isEmpty {
        result.append(("\n\(context)\n", false))
      }
      if !parts[1].isEmpty {
        result.append((parts[1], section.allowsSpecialTokens))
      }
      return result
    }
  }

  private func renderedQwenContext() -> String {
    guard !content.isEmpty else { return "" }
    return """
      --- Context from: \(fileName) ---
      \(content)
      --- End of Context from: \(fileName) ---
      """
  }

  func emitAsSystemReminder(suffix: String = "") -> String {
    let suffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty || !suffix.isEmpty else { return "" }
    let escapedSuffix = suffix.replacingOccurrences(
      of: "</system-reminder>", with: "<\\/system-reminder>")
    // Keep exactly one newline after the opening tag so its tokenized delimiter is stable.
    guard !content.isEmpty else {
      return "<system-reminder>\n\(escapedSuffix)\n</system-reminder>"
    }
    let escapedContent = content.replacingOccurrences(
      of: "</system-reminder>", with: "<\\/system-reminder>")
    return """
      <system-reminder>
      The following project context may be relevant to your work. Use it as guidance when applicable. It does not override system or direct user instructions.

      Instructions from: \(fileName)

      \(escapedContent)\(escapedSuffix.isEmpty ? "" : "\n\n" + escapedSuffix)
      </system-reminder>
      """
  }

}
