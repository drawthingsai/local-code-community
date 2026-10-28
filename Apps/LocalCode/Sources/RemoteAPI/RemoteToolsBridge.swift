import BashToolContext
import CryptoKit
import Foundation
import Localization
import ProjectHistoryManager
import RemoteAPI
import WebSearch

struct RemoteToolsBridge {
  let tools: [RemoteFunctionTool]

  private let supportsImageInput: Bool
  private let bashToolContext: BashToolContext
  private let projectPath: String
  private let workspacePath: String
  private let webSearchProvider: WebSearchProvider

  init(
    projectPath: String, workspacePath: String,
    webSearchProvider: WebSearchProvider,
    supportsImageInput: Bool = false,
    bashToolContext: BashToolContext = .init()
  ) {
    self.supportsImageInput = supportsImageInput
    self.bashToolContext = bashToolContext
    self.projectPath = projectPath
    self.workspacePath = workspacePath
    self.webSearchProvider = webSearchProvider
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    let currentDate = formatter.string(from: Date())
    tools = RemoteToolSchema.tools.compactMap {
      guard
        $0.name != ToolsRegistry.Tool.webSearch.rawValue
          || webSearchProvider != .disabled,
        $0.name != ToolsRegistry.Tool.view.rawValue || supportsImageInput
      else { return nil }
      var tool = $0
      if tool.name == ToolsRegistry.Tool.webSearch.rawValue {
        tool.description =
          "The authoritative runtime date is \(currentDate) in \(TimeZone.current.identifier). "
          + tool.description
      }
      if supportsImageInput && tool.name == ToolsRegistry.Tool.read.rawValue {
        tool.description +=
          " For PNG, JPEG, WebP, and GIF files, returns the image for visual inspection, resized to at most 1,024 pixels on its long side. Line options do not apply to images."
      }
      return tool
    }
  }

  func execute(
    _ call: RemoteToolCall, bashUserInteraction: BashUserInteraction,
    progress: @escaping (String) -> Void,
    completion: @escaping (RemoteToolExecutionResult) -> Void
  ) -> (() -> Void)? {
    guard supportsImageInput || call.name != ToolsRegistry.Tool.view.rawValue else {
      completion(
        RemoteToolExecutionResult(
          content: "View is not available because this provider does not accept images.",
          subtitle: LocalizedString.format(key: "could_not_run_tool", call.name),
          isError: true))
      return nil
    }
    guard let request = request(from: call) else {
      completion(
        RemoteToolExecutionResult(
          content: RemoteToolError.content(
            type: "invalid_arguments", function: call.name,
            message:
              "Arguments must be a JSON object whose values are strings, numbers, booleans, or null only where supported."
          ),
          subtitle: LocalizedString.format(key: "could_not_run_tool", call.name), isError: true))
      return nil
    }
    guard
      let invocation = ToolsRegistry.parse(
        request, projectPath: projectPath, workspacePath: workspacePath,
        webSearchProvider: webSearchProvider)
    else {
      completion(
        RemoteToolExecutionResult(
          content: RemoteToolError.content(
            type: "invalid_arguments", function: call.name,
            message: "Missing or invalid tool arguments."),
          subtitle: LocalizedString.format(key: "could_not_run_tool", call.name), isError: true))
      return nil
    }
    progress(invocation.subtitle(for: .now))
    if supportsImageInput, case .read = invocation,
      let path = request.parameters["path"]?.value,
      ["png", "jpg", "jpeg", "webp", "gif"].contains(
        URL(fileURLWithPath: path).pathExtension.lowercased())
    {
      let resolver = LocalPathResolver(
        projectPath: projectPath, workspacePath: workspacePath,
        permittedDirectoryURLs: bashToolContext.permittedDirectoryURLs())
      guard let resolution = resolver.resolve(path) else {
        completion(
          RemoteToolExecutionResult(
            content: "Cannot read image outside permitted directories: \(path)",
            subtitle: invocation.subtitle(for: .past), isError: true))
        return nil
      }
      do {
        let image = try RemoteImage(attachmentContentsOf: resolution.url)
        completion(
          RemoteToolExecutionResult(
            content: "Image from \(path): \(image.width)×\(image.height), \(image.mediaType).",
            subtitle: invocation.subtitle(for: .past), images: [image]))
      } catch {
        completion(
          RemoteToolExecutionResult(
            content: "Could not read image \(path): \(error.localizedDescription)",
            subtitle: invocation.subtitle(for: .past), isError: true))
      }
      return nil
    }
    invocation.invoke(
      context: bashToolContext.with(bashUserInteraction: bashUserInteraction),
      isImageSupported: supportsImageInput
    ) { response in
      var texts = [String]()
      var images = [RemoteImage]()
      for part in response.content {
        switch part {
        case .text(let text):
          texts.append(text)
        case .imageDigest(let digest):
          // Bash and view return images as large as 2,048 pixels; resize them as attachments
          // are, and skip one that cannot be read.
          let path = EmbedsFileStore(projectPath: self.projectPath).filePath(for: digest)
          if let image = try? RemoteImage(attachmentContentsOf: URL(fileURLWithPath: path)) {
            images.append(image)
          }
        }
      }
      let result = texts.joined(separator: "\n")
      let content: String
      if call.name == ToolsRegistry.Tool.webSearch.rawValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        content =
          """
          Authoritative runtime time: \(formatter.string(from: Date()))
          Interpret "latest" relative to this time. If the query used stale years or the results do not cover the current reporting period, search again before selecting a source.
          Prefer an issuer, regulator, or other primary source when one appears below. Pass the exact returned URL to webfetch; do not rewrite it.
          If the user asked to read a report or provide detailed analysis, do not answer from these snippets. Fetch the exact primary-source URL first; a failed fetch does not satisfy that requirement.

          """
          + result
      } else {
        content = result
      }
      let presentedContent: String
      if call.name == ToolsRegistry.Tool.read.rawValue {
        presentedContent = self.previewLargeReadResult(
          content, request: request, thresholdBytes: 64 * 1_024)
      } else {
        presentedContent = self.archiveLargeToolResult(content, thresholdBytes: 64 * 1_024)
      }
      completion(
        RemoteToolExecutionResult(
          content: presentedContent,
          subtitle: invocation.subtitle(for: .past), images: images))
    }
    return nil
  }

  private func request(from call: RemoteToolCall) -> ToolCall.Request? {
    guard let data = call.arguments.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    var parameters = [String: ToolCall.Request.Parameter]()
    for (key, value) in object {
      switch value {
      case let value as String:
        parameters[key] = .init(string: true, value: value)
      case let value as NSNumber:
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
          parameters[key] = .init(string: false, value: value.boolValue ? "true" : "false")
        } else {
          parameters[key] = .init(string: false, value: value.stringValue)
        }
      case is NSNull:
        continue
      default:
        return nil
      }
    }
    return ToolCall.Request(function: call.name, parameters: parameters)
  }

  private func archiveLargeToolResult(_ value: String, thresholdBytes: Int) -> String {
    let bytes = Array(value.utf8)
    guard bytes.count > thresholdBytes else { return value }
    let excerptBytes = thresholdBytes / 2
    let beginning = String(decoding: bytes.prefix(excerptBytes), as: UTF8.self)
    let ending = String(decoding: bytes.suffix(excerptBytes), as: UTF8.self)
    let omittedBytes = bytes.count - excerptBytes * 2
    let digest = SHA256.hash(data: Data(bytes))
    let name = digest.map { String(format: "%02x", $0) }.joined() + ".md"
    let relativePath = ".localc/tool_responses/\(name)"
    let directoryURL =
      URL(fileURLWithPath: projectPath, isDirectory: true)
      .appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("tool_responses", isDirectory: true)
    let responseURL = directoryURL.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(
        at: directoryURL, withIntermediateDirectories: true)
      try Data(bytes).write(to: responseURL, options: .atomic)
      return
        "[\(omittedBytes) bytes omitted from this context. The exact tool result is at "
        + "\(relativePath). Read it in bounded chunks with start_line and max_lines; do not use "
        + "whole=true.]\n\n" + beginning + "\n\n[...]\n\n" + ending
    } catch {
      return beginning
        + "\n\n[\(omittedBytes) bytes omitted from this context and could not be saved: "
        + "\(error.localizedDescription)]\n\n" + ending
    }
  }

  private func previewLargeReadResult(
    _ value: String, request: ToolCall.Request, thresholdBytes: Int
  ) -> String {
    let bytes = Array(value.utf8)
    guard bytes.count > thresholdBytes else { return value }
    let excerptBytes = thresholdBytes / 8
    let beginning = String(decoding: bytes.prefix(excerptBytes), as: UTF8.self)
    let ending = String(decoding: bytes.suffix(excerptBytes), as: UTF8.self)
    let omittedBytes = bytes.count - excerptBytes * 2
    let path = request.parameters["path"]?.value ?? "the same path"
    let startLine = request.parameters["start_line"].flatMap { Int($0.value) } ?? 1
    return
      "[\(omittedBytes) bytes omitted from this context. This read result was not saved as "
      + "another tool response. Re-read \(String(reflecting: path)) with whole=false, a smaller "
      + "max_lines, and start_line=\(startLine). Do not use whole=true.]\n\n" + beginning
      + "\n\n[...]\n\n" + ending
  }
}
