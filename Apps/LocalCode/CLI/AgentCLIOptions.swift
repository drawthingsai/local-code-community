import ArgumentParser
import Foundation
import WebSearch

extension WebSearchProvider: @retroactive ExpressibleByArgument {
  public var defaultValueDescription: String { identifier }
  public static var allValueStrings: [String] { allCases.map(\.identifier) }
  public init?(argument: String) { self.init(identifier: argument, apiKey: "") }
}

struct AgentCLIOptions: ParsableArguments {
  // Capture the caller's directory before embedded commands change directory.
  // Bazel launches binaries in runfiles, but preserves the caller here.
  static let workingDirectoryURL = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["BUILD_WORKING_DIRECTORY"]
      ?? FileManager.default.currentDirectoryPath,
    isDirectory: true)

  @Option(help: "Local Code project directory.")
  var project: String = "."

  @Option(help: "Workspace root for /home and ancestor skills. Defaults to the project.")
  var workspace: String?

  @Option(help: "User request. Use either --message or --prompt-file.")
  var message: String?

  @Option(help: "File containing the request. Use '-' to read standard input.")
  var promptFile: String?

  @Option(help: "Write the complete run record and resumable conversation as JSON.")
  var resultJSON: String?

  @Option(help: "Continue a conversation saved by this agent's --result-json option.")
  var resume: String?

  @Option(help: "Web-search provider available to the agent.")
  var webSearchProvider: WebSearchProvider = .duckDuckGo

  @Option(help: "Environment variable containing the Kagi or Brave Search API key.")
  var webSearchAPIKeyEnvironment: String?

  @Flag(help: "Stream assistant and tool progress to standard error.")
  var trace = false

  mutating func validate() throws {
    guard (message != nil) != (promptFile != nil) else {
      throw ValidationError("Provide exactly one of --message or --prompt-file.")
    }
  }

  func readPrompt() throws -> String {
    let prompt: String
    if let message {
      prompt = message
    } else if promptFile == "-" {
      prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else if let promptFile {
      prompt = try String(contentsOf: Self.fileURL(promptFile), encoding: .utf8)
    } else {
      throw ValidationError("Provide exactly one of --message or --prompt-file.")
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ValidationError("The prompt is empty.")
    }
    return prompt
  }

  func directories() throws -> (project: URL, workspace: URL) {
    let projectURL = try Self.directory(project)
    let workspaceURL = try workspace.map(Self.directory) ?? projectURL
    guard
      projectURL.path == workspaceURL.path || workspaceURL.path == "/"
        || projectURL.path.hasPrefix(workspaceURL.path + "/")
    else {
      throw ValidationError("The project must be inside --workspace.")
    }
    return (projectURL, workspaceURL)
  }

  func configuredWebSearchProvider() throws -> WebSearchProvider {
    switch webSearchProvider {
    case .kagi:
      let name = webSearchAPIKeyEnvironment ?? "KAGI_API_KEY"
      guard
        let key = ProcessInfo.processInfo.environment[name]?
          .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
      else { throw ValidationError("Set \(name) to the Kagi Search API key.") }
      return .kagi(apiKey: key)
    case .brave:
      let name = webSearchAPIKeyEnvironment ?? "BRAVE_API_KEY"
      guard
        let key = ProcessInfo.processInfo.environment[name]?
          .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
      else { throw ValidationError("Set \(name) to the Brave Search API key.") }
      return .brave(apiKey: key)
    case .duckDuckGo, .sogou, .disabled:
      return webSearchProvider
    }
  }

  static func fileURL(_ path: String) -> URL {
    URL(
      fileURLWithPath: (path as NSString).expandingTildeInPath,
      relativeTo: workingDirectoryURL
    )
    .standardizedFileURL.resolvingSymlinksInPath()
  }

  static func directory(_ path: String) throws -> URL {
    let url = fileURL(path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ValidationError("Directory does not exist: \(url.path)") }
    return url
  }

  func writeResult<T: Encodable>(_ result: T) throws {
    guard let resultJSON else { return }
    let url = Self.fileURL(resultJSON)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(result).write(to: url, options: .atomic)
  }
}
