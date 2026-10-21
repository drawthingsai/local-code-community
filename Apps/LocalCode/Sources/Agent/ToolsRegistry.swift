import BashToolContext
import Foundation
import Localization
import WebSearch

private struct WebToolErrorResponse: Encodable {
  var body: String?
  var byteCount: Int?
  var code: Int?
  var domain: String?
  var error: String
  var failingURL: String?
  var headers: [String: String]?
  var maximumBytes: Int?
  var query: String?
  var statusCode: Int?
  var tool: String
  var type: String
  var url: String?
}

private enum WebToolDisabledError: LocalizedError {
  case webSearch

  var errorDescription: String? {
    switch self {
    case .webSearch:
      return "Web search is disabled."
    }
  }
}

private func webToolErrorResponse(
  tool: String, error: Error, url: URL? = nil, query: String? = nil
) -> String {
  var response = WebToolErrorResponse(
    body: nil, byteCount: nil, code: nil, domain: nil,
    error: error.localizedDescription, failingURL: nil, headers: nil, maximumBytes: nil,
    query: query, statusCode: nil, tool: tool, type: "error", url: url?.absoluteString)
  if let error = error as? WebSearchError {
    switch error {
    case .invalidURL(let value):
      response.type = "invalid_url"
      response.url = value
    case .invalidResponse:
      response.type = "invalid_response"
    case .unexpectedSearchResponse(let responseURL):
      response.type = "unexpected_search_response"
      response.url = responseURL?.absoluteString ?? response.url
    case .httpStatus(let statusCode, let responseURL, let body, let headers, let byteCount):
      response.type = "http_error"
      response.statusCode = statusCode
      response.url = responseURL?.absoluteString ?? response.url
      response.body = body
      response.headers = headers
      response.byteCount = byteCount
    case .bodyDecodingFailed(let responseURL):
      response.type = "body_decoding_failed"
      response.url = responseURL?.absoluteString ?? response.url
    case .unsupportedScheme(let scheme):
      response.type = "unsupported_scheme"
      response.url = scheme
    case .unsupportedContentType:
      response.type = "unsupported_content_type"
    case .responseTooLarge(let byteCount, let maximumBytes):
      response.type = "response_too_large"
      response.byteCount = byteCount
      response.maximumBytes = maximumBytes
    case .queryTooLong:
      response.type = "query_too_long"
    case .searchBlocked(let message, let responseURL):
      response.type = "search_blocked"
      response.error = message
      response.url = responseURL?.absoluteString ?? response.url
    }
  } else {
    let nsError = error as NSError
    response.type = nsError.domain == NSURLErrorDomain ? "network_error" : "error"
    response.domain = nsError.domain
    response.code = nsError.code
    if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
      response.failingURL = failingURL.absoluteString
    } else if let failingURL = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
      response.failingURL = failingURL
    }
  }
  let encoder = JSONEncoder()
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(response),
    let json = String(data: data, encoding: .utf8)
  else {
    return "{\"error\":\"\(error.localizedDescription)\"}"
  }
  return json
}

#if canImport(UIKit)
  /// In Lockdown Mode, files in the app container, projects inside App Documents included, are
  /// Complete, so they cannot be opened while the device is locked; commands then fail with
  /// "Operation not permitted". A probe file with Complete protection fails exactly when they do.
  /// On Mac Catalyst, `UIApplication.isProtectedDataAvailable` stays true across a screen lock
  /// and the protected-data callbacks never arrive, so the probe is the reliable signal.
  private enum ProtectedData {
    private static let probeURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("localc-protected-data-probe")

    static var isAvailable: Bool {
      // Outside Lockdown Mode the container is not Complete, so a lock blocks nothing.
      // ContainerProtection converts the container root last, so its protection tells the mode.
      let home = open(NSHomeDirectory(), O_RDONLY)
      guard home >= 0 else { return errno != EPERM }
      let homeProtectionClass = fcntl(home, F_GETPROTECTIONCLASS)
      close(home)
      // Class 1 is Complete protection.
      guard homeProtectionClass == 1 else { return true }
      // Only a Complete file can be locked out; a weaker file or a symlink to one opens even
      // while locked. Without a valid probe, report available and replace it, which also fails
      // while locked.
      let descriptor = open(probeURL.path, O_RDONLY | O_NOFOLLOW)
      if descriptor >= 0 {
        let protectionClass = fcntl(descriptor, F_GETPROTECTIONCLASS)
        close(descriptor)
        if protectionClass == 1 { return true }
      } else if errno == EPERM {
        return false
      }
      try? Data([1]).write(to: probeURL, options: [.atomic, .completeFileProtection])
      return true
    }

    /// Tells the model that the device was locked during the tool call, so it does not treat
    /// the failures as a permission problem.
    static func reportingLock(_ completion: @escaping (ToolResponse) -> Void) -> (
      ToolResponse
    ) -> Void {
      #if targetEnvironment(macCatalyst)
        let device = "Mac"
      #else
        let device = "device"
      #endif
      let wasAvailable = isAvailable
      return { response in
        var response = response
        if !isAvailable {
          response.content.append(
            .text(
              """
              Note: The \(device) is locked and Lockdown Mode is on, so Local Code's files, \
              including projects inside App Documents, cannot be opened until it is unlocked, \
              and commands that use them fail with "Operation not permitted". This is not a \
              permission problem, so do not change permissions or file attributes. Wait until \
              the \(device) is unlocked, or stop and tell the user.
              """))
        } else if !wasAvailable {
          response.content.append(
            .text(
              """
              Note: The \(device) was locked while this tool ran, and Lockdown Mode kept Local \
              Code's files from being opened, so "Operation not permitted" errors above come \
              from that. It is unlocked now; retry the failed steps.
              """))
        }
        completion(response)
      }
    }
  }
#endif

public enum ToolsRegistry {
  public enum Tool: String, CaseIterable, Sendable {
    case bash
    case bashStatus = "bash_status"
    case bashWait = "bash_wait"
    case bashStop = "bash_stop"
    case read
    case view
    case more
    case write
    case edit
    case search
    case list
    case datetime
    case memory
    case checkSmt = "check_smt"
    case webSearch = "websearch"
    case webFetch = "webfetch"

    public var toolType: Any.Type {
      switch self {
      case .bash:
        return BashTool.self
      case .bashStatus:
        return BashStatusTool.self
      case .bashWait:
        return BashWaitTool.self
      case .bashStop:
        return BashStopTool.self
      case .view:
        return ViewTool.self
      case .read:
        return ReadTool.self
      case .more:
        return MoreTool.self
      case .write:
        return WriteTool.self
      case .edit:
        return EditTool.self
      case .search:
        return SearchTool.self
      case .list:
        return ListTool.self
      case .datetime:
        return DateTimeTool.self
      case .memory:
        return MemoryTool.self
      case .checkSmt:
        return CheckSmtTool.self
      case .webSearch:
        return WebSearchTool.self
      case .webFetch:
        return WebFetchTool.self
      }
    }
  }

  public enum Invocation {
    case bash(BashTool)
    case bashStatus(BashStatusTool)
    case bashWait(BashWaitTool)
    case bashStop(BashStopTool)
    case view(ViewTool)
    case read(ReadTool)
    case more(MoreTool)
    case write(WriteTool)
    case edit(EditTool)
    case search(SearchTool)
    case list(ListTool)
    case dateTime(DateTimeTool)
    case memory(MemoryTool)
    case checkSmt(CheckSmtTool)
    case webSearch(WebSearchTool)
    case webFetch(WebFetchTool)

    public var tool: Tool {
      switch self {
      case .bash:
        return .bash
      case .bashStatus:
        return .bashStatus
      case .bashWait:
        return .bashWait
      case .bashStop:
        return .bashStop
      case .view:
        return .view
      case .read:
        return .read
      case .more:
        return .more
      case .write:
        return .write
      case .edit:
        return .edit
      case .search:
        return .search
      case .list:
        return .list
      case .dateTime:
        return .datetime
      case .memory:
        return .memory
      case .checkSmt:
        return .checkSmt
      case .webSearch:
        return .webSearch
      case .webFetch:
        return .webFetch
      }
    }

    public func subtitle(for moment: ToolSubtitleMoment) -> String {
      switch self {
      case .bash(let tool):
        return tool.subtitle(for: moment)
      case .bashStatus(let tool):
        return tool.subtitle(for: moment)
      case .bashWait(let tool):
        return tool.subtitle(for: moment)
      case .bashStop(let tool):
        return tool.subtitle(for: moment)
      case .view(let tool):
        return tool.subtitle(for: moment)
      case .read(let tool):
        return tool.subtitle(for: moment)
      case .more(let tool):
        return tool.subtitle(for: moment)
      case .write(let tool):
        return tool.subtitle(for: moment)
      case .edit(let tool):
        return tool.subtitle(for: moment)
      case .search(let tool):
        return tool.subtitle(for: moment)
      case .list(let tool):
        return tool.subtitle(for: moment)
      case .dateTime(let tool):
        return tool.subtitle(for: moment)
      case .memory(let tool):
        return tool.subtitle(for: moment)
      case .checkSmt(let tool):
        return tool.subtitle(for: moment)
      case .webSearch(let tool):
        return tool.subtitle(for: moment)
      case .webFetch(let tool):
        return tool.subtitle(for: moment)
      }
    }

    /// `isImageSupported` returns images bash commands write instead of stripping them.
    public func invoke(
      context: BashToolContext = .init(), isImageSupported: Bool = false,
      completion: @escaping (ToolResponse) -> Void
    ) {
      #if canImport(UIKit)
        let completion = ProtectedData.reportingLock(completion)
      #endif
      let textCompletion: (String) -> Void = { text in completion(ToolResponse(text: text)) }
      switch self {
      case .view(let tool):
        tool.invoke(context: context, completion: completion)
      case .bash(let tool):
        tool.invoke(context: context, isImageSupported: isImageSupported, completion: completion)
      case .bashStatus(let tool):
        tool.invoke(completion: completion)
      case .bashWait(let tool):
        tool.invoke(completion: completion)
      case .bashStop(let tool):
        tool.invoke(completion: completion)
      case .read(let tool):
        tool.invoke(context: context, completion: textCompletion)
      case .more(let tool):
        tool.invoke(context: context, completion: textCompletion)
      case .write(let tool):
        tool.invoke(
          permittedDirectoryURLs: context.permittedDirectoryURLs, completion: textCompletion)
      case .edit(let tool):
        tool.invoke(
          permittedDirectoryURLs: context.permittedDirectoryURLs, completion: textCompletion)
      case .search(let tool):
        tool.invoke(
          permittedDirectoryURLs: context.permittedDirectoryURLs, completion: textCompletion)
      case .list(let tool):
        tool.invoke(
          permittedDirectoryURLs: context.permittedDirectoryURLs, completion: textCompletion)
      case .dateTime(let tool):
        tool.invoke(completion: textCompletion)
      case .memory(let tool):
        tool.invoke(completion: completion)
      case .checkSmt(let tool):
        tool.invoke(completion: textCompletion)
      case .webSearch(let tool):
        tool.invoke(completion: textCompletion)
      case .webFetch(let tool):
        tool.invoke(completion: textCompletion)
      }
    }
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String? = nil,
    workspacePath: String? = nil,
    webSearchProvider: WebSearchProvider = .duckDuckGo
  ) -> Invocation? {
    guard let tool = Tool(rawValue: request.function) else {
      return nil
    }
    switch tool {
    case .view:
      guard
        let tool = ViewTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .view(tool)
    case .bash:
      guard
        let tool = BashTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .bash(tool)
    case .bashStatus:
      guard let tool = BashStatusTool.parse(request) else { return nil }
      return .bashStatus(tool)
    case .bashWait:
      guard let tool = BashWaitTool.parse(request) else { return nil }
      return .bashWait(tool)
    case .bashStop:
      guard let tool = BashStopTool.parse(request) else { return nil }
      return .bashStop(tool)
    case .read:
      guard
        let tool = ReadTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .read(tool)
    case .more:
      guard
        let tool = MoreTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .more(tool)
    case .write:
      guard
        let tool = WriteTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .write(tool)
    case .edit:
      guard
        let tool = EditTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .edit(tool)
    case .search:
      guard
        let tool = SearchTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .search(tool)
    case .list:
      guard
        let tool = ListTool.parse(
          request, projectPath: projectPath, workspacePath: workspacePath)
      else { return nil }
      return .list(tool)
    case .datetime:
      guard let tool = DateTimeTool.parse(request) else { return nil }
      return .dateTime(tool)
    case .memory:
      guard let tool = MemoryTool.parse(request, projectPath: projectPath) else { return nil }
      return .memory(tool)
    case .checkSmt:
      guard let tool = CheckSmtTool.parse(request) else { return nil }
      return .checkSmt(tool)
    case .webSearch:
      guard let tool = WebSearchTool.parse(request, provider: webSearchProvider) else {
        return nil
      }
      return .webSearch(tool)
    case .webFetch:
      guard let tool = WebFetchTool.parse(request) else { return nil }
      return .webFetch(tool)
    }
  }

}
public struct DateTimeTool {
  public var timeZone: TimeZone

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_datetime_now")
    case .past:
      title = LocalizedString.forKey("tool_datetime_past")
    }
    return "**\(title)**: \(timeZone.identifier)"
  }

  public static func parse(_ request: ToolCall.Request) -> DateTimeTool? {
    let timeZone: TimeZone
    if let parameter = request.parameters["timezone"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.isEmpty {
        timeZone = .current
      } else {
        guard let parsed = TimeZone(identifier: value) else { return nil }
        timeZone = parsed
      }
    } else {
      timeZone = .current
    }
    return DateTimeTool(timeZone: timeZone)
  }

  public func invoke(completion: @escaping (String) -> Void) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = timeZone
    completion(
      """
      DateTime: \(formatter.string(from: Date()))
      Timezone: \(timeZone.identifier)
      """)
  }
}

public struct WebSearchTool {
  public var query: String
  public var provider: WebSearchProvider
  public var timeFilter: WebSearchTimeFilter?
  public var maxResults: Int
  public var pages: Int
  public var timeout: TimeInterval

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_web_search_now")
    case .past:
      title = LocalizedString.forKey("tool_web_search_past")
    }
    return "**\(title)**: \(query)"
  }

  public static func parse(
    _ request: ToolCall.Request,
    provider: WebSearchProvider = .duckDuckGo
  ) -> WebSearchTool? {
    guard let queryParameter = request.parameters["query"] else { return nil }
    let query = queryParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    let timeFilter: WebSearchTimeFilter?
    if let parameter = request.parameters["timeFilter"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard value.isEmpty == false else { return nil }
      guard let parsed = WebSearchTimeFilter(rawValue: value) else { return nil }
      timeFilter = parsed
    } else {
      timeFilter = nil
    }
    let maxResults: Int
    if let parameter = request.parameters["maxResults"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value) else { return nil }
      maxResults = parsed
    } else {
      maxResults = 10
    }
    let pages: Int
    if let parameter = request.parameters["pages"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value) else { return nil }
      pages = parsed
    } else {
      pages = 1
    }
    let timeout: TimeInterval
    if let parameter = request.parameters["timeout"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Double(value) else { return nil }
      timeout = parsed
    } else {
      timeout = 15
    }
    return WebSearchTool(
      query: query, provider: provider, timeFilter: timeFilter, maxResults: maxResults,
      pages: pages, timeout: timeout)
  }

  public func invoke(completion: @escaping (String) -> Void) {
    let completionHandler: (Result<[SearchResult], Error>) -> Void = { result in
      switch result {
      case .success(let results):
        completion(
          results.map {
            """
            # \($0.rank). \($0.title)
            URL: \($0.url.absoluteString)

            \($0.snippet)
            """
          }.joined(separator: "\n\n"))
      case .failure(let error):
        completion(webToolErrorResponse(tool: "websearch", error: error, query: query))
      }
    }
    switch provider {
    case .duckDuckGo:
      let options = DuckDuckGoSearchOptions(
        timeFilter: timeFilter, maxResults: maxResults, pages: pages, timeout: timeout)
      #if canImport(UIKit)
        let browser = WebKitDuckDuckGoSearch(
          challengeHandler: WebSearchChallengeViewController.present)
        let search = DuckDuckGoSearch(browserSearch: browser)
      #else
        let search = DuckDuckGoSearch()
      #endif
      search.search(query: query, options: options, completion: completionHandler)
    case .sogou:
      let options = SogouSearchOptions(
        timeFilter: timeFilter, maxResults: maxResults, pages: pages, timeout: timeout)
      #if canImport(UIKit)
        let browser = WebKitSogouSearch(
          challengeHandler: WebSearchChallengeViewController.present)
        let search = SogouSearch(browserSearch: browser)
      #else
        let search = SogouSearch()
      #endif
      search.search(query: query, options: options, completion: completionHandler)
    case .kagi(let apiKey):
      let options = KagiSearchOptions(
        timeFilter: timeFilter, maxResults: maxResults, pages: pages, timeout: timeout)
      KagiSearch(apiKey: apiKey).search(
        query: query, options: options, completion: completionHandler)
    case .brave(let apiKey):
      let options = BraveSearchOptions(
        timeFilter: timeFilter, maxResults: maxResults, pages: pages, timeout: timeout)
      BraveSearch(apiKey: apiKey).search(
        query: query, options: options, completion: completionHandler)
    case .disabled:
      completion(
        webToolErrorResponse(
          tool: "websearch", error: WebToolDisabledError.webSearch, query: query))
    }
  }
}

public struct WebFetchTool {
  public var url: URL
  public var format: WebFetchFormat
  public var timeout: TimeInterval
  public var maxBytes: Int

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_web_fetch_now")
    case .past:
      title = LocalizedString.forKey("tool_web_fetch_past")
    }
    return "**\(title)**: [\(url.absoluteString)](<\(url.absoluteString)>)"
  }

  public static func parse(_ request: ToolCall.Request) -> WebFetchTool? {
    guard let urlParameter = request.parameters["url"] else { return nil }
    let urlString = urlParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: urlString) else { return nil }
    let format: WebFetchFormat
    if let parameter = request.parameters["format"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard value.isEmpty == false else { return nil }
      guard let parsed = WebFetchFormat(rawValue: value) else { return nil }
      format = parsed
    } else {
      format = .markdown
    }
    let timeout: TimeInterval
    if let parameter = request.parameters["timeout"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Double(value) else { return nil }
      timeout = parsed
    } else {
      timeout = 30
    }
    let maxBytes: Int
    if let parameter = request.parameters["maxBytes"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Int(value) else { return nil }
      maxBytes = max(parsed, 50 * 1024 * 1024)  // It can be too small to be useful.
    } else {
      maxBytes = 50 * 1024 * 1024
    }
    return WebFetchTool(
      url: url, format: format, timeout: timeout, maxBytes: maxBytes)
  }

  public func invoke(completion: @escaping (String) -> Void) {
    let options = WebFetchOptions(format: format, timeout: timeout, maxBytes: maxBytes)
    WebFetch().fetch(url: url, options: options) { result in
      switch result {
      case .success(let output):
        completion(output.output)
      case .failure(let error):
        completion(webToolErrorResponse(tool: "webfetch", error: error, url: url))
      }
    }
  }
}
