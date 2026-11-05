import BashToolContext
import CryptoKit
import Foundation
import ProjectHistoryManager
import WebSearch

/// Where an agent's turn runs its tools and keeps its caches.
public protocol CodeAgentEnvironment {
  /// The folder the agent keeps its context caches, paused turn and images under.
  var cachePath: String? { get }

  /// The project's memory, as the memory tool last left it.
  func loadMemoryContext() -> MemoryContext

  /// Keeps a tool response too long for the context where the agent's tools can read it, and
  /// returns the path to give the model.
  func saveToolResponse(_ text: String) -> String?

  /// Runs a tool call and completes on any queue. `context` carries the agent's own closures and
  /// thread; `isImageSupported` keeps images bash commands write instead of stripping them.
  func invoke(
    _ request: ToolCall.Request, context: BashToolContext, isImageSupported: Bool,
    completion: @escaping (ToolResponse) -> Void)
}

/// A project: tools run in process on its folder, which also holds the agent's caches.
public struct ProjectEnvironment: CodeAgentEnvironment {
  public var projectPath: String?
  public var workspacePath: String?
  public var webSearchProvider: WebSearchProvider

  public init(
    projectPath: String? = nil, workspacePath: String? = nil,
    webSearchProvider: WebSearchProvider = .duckDuckGo
  ) {
    self.projectPath = projectPath
    self.workspacePath = workspacePath
    self.webSearchProvider = webSearchProvider
  }

  public var cachePath: String? { projectPath }

  public func loadMemoryContext() -> MemoryContext {
    MemoryContext.load(projectPath: projectPath)
  }

  public func saveToolResponse(_ text: String) -> String? {
    guard let projectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !projectPath.isEmpty
    else { return nil }
    let digest = SHA256.hash(data: Data(text.utf8))
    let sha256 = digest.map { String(format: "%02x", $0) }.joined()
    let relativePath = ".localc/tool_responses/\(sha256).md"
    let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    let responseDirectoryURL =
      projectURL
      .appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("tool_responses", isDirectory: true)
    let responseURL = responseDirectoryURL.appendingPathComponent("\(sha256).md")
    do {
      try FileManager.default.createDirectory(
        at: responseDirectoryURL, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: responseURL, options: .atomic)
      return relativePath
    } catch {
      return nil
    }
  }

  public func invoke(
    _ request: ToolCall.Request, context: BashToolContext, isImageSupported: Bool,
    completion: @escaping (ToolResponse) -> Void
  ) {
    guard
      let invocation = ToolsRegistry.parse(
        request, projectPath: projectPath, workspacePath: workspacePath,
        webSearchProvider: webSearchProvider)
    else {
      completion(
        ToolResponse(text: "Tool error: invalid or unknown tool request: \(request.function)"))
      return
    }
    invocation.invoke(
      context: context.with(
        projectURL: projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) }),
      isImageSupported: isImageSupported, completion: completion)
  }
}
