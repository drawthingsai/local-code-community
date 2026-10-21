import Foundation

public struct EnvironmentContext: Equatable, Sendable {
  static let instructionsPlaceholder = "{{ENVIRONMENT_INSTRUCTIONS}}"
  public static let empty = EnvironmentContext(
    model: "", provider: "", platform: "", python: "", pythonPackages: [], nodeJS: "",
    nodeJSPackages: [], shellCommands: [])

  let model: String
  let provider: String
  let platform: String
  let python: String
  let pythonPackages: [String]
  let nodeJS: String
  let nodeJSPackages: [String]
  let shellCommands: [String]

  public init(
    model: String, provider: String, platform: String, python: String,
    pythonPackages: [String], nodeJS: String, nodeJSPackages: [String],
    shellCommands: [String]
  ) {
    self.model = Self.singleLine(model)
    self.provider = Self.singleLine(provider)
    self.platform = Self.singleLine(platform)
    self.python = Self.singleLine(python)
    self.pythonPackages = Self.normalizedList(pythonPackages)
    self.nodeJS = Self.singleLine(nodeJS)
    self.nodeJSPackages = Self.normalizedList(nodeJSPackages)
    self.shellCommands = Self.normalizedList(shellCommands)
  }

  func emitSections(
    _ sections: [(text: String, allowsSpecialTokens: Bool)]
  ) -> [(text: String, allowsSpecialTokens: Bool)] {
    let context = renderedContext()
    return sections.flatMap { section in
      let parts = section.text.components(separatedBy: Self.instructionsPlaceholder)
      guard parts.count == 2 else { return [section] }
      var result = [(text: String, allowsSpecialTokens: Bool)]()
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

  func renderedContext() -> String {
    guard !model.isEmpty else { return "" }
    return """
      The following information describes the current model and execution environment.

      Model: \(model)
      Provider: \(provider)
      Platform: \(platform)
      Python: \(python)
      Python Packages: \(Self.renderedList(pythonPackages))
      Node.js: \(nodeJS)
      Node.js Packages: \(Self.renderedList(nodeJSPackages))
      Shell Commands: \(Self.renderedList(shellCommands))
      """
  }

  private static func singleLine(_ value: String) -> String {
    value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
  }

  private static func normalizedList(_ values: [String]) -> [String] {
    Array(Set(values.map(singleLine).filter { !$0.isEmpty })).sorted()
  }

  private static func renderedList(_ values: [String]) -> String {
    values.isEmpty ? "(none)" : values.joined(separator: ", ")
  }
}
