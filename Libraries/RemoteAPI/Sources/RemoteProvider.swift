import Foundation

enum RemoteEndpointURL {
  static func normalizedBaseURL(_ url: URL, allowsLocalHTTP: Bool = false) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else { throw RemoteChatError.invalidBaseURL }
    guard scheme == "https" || (allowsLocalHTTP && isLocalHost(host)) else {
      throw RemoteChatError.insecureBaseURL
    }
    if let port = components.port, !(1...65_535).contains(port) {
      throw RemoteChatError.invalidBaseURL
    }
    components.scheme = scheme
    var path = components.percentEncodedPath
    while path.count > 1 && path.hasSuffix("/") {
      path.removeLast()
    }
    components.percentEncodedPath = path == "/" ? "" : path
    guard let normalizedURL = components.url else { throw RemoteChatError.invalidBaseURL }
    return normalizedURL
  }

  private static func isLocalHost(_ host: String) -> Bool {
    let host = host.lowercased()
    if host == "localhost" || host == "localhost." { return true }
    if host.hasSuffix(".local") || host.hasSuffix(".local.") { return true }
    var ipv4 = in_addr()
    if inet_pton(AF_INET, host, &ipv4) == 1 {
      let address = UInt32(bigEndian: ipv4.s_addr)
      return address >> 24 == 127 || address >> 24 == 10
        || address >> 20 == 0xac1 || address >> 16 == 0xc0a8
    }
    var ipv6 = in6_addr()
    let literal =
      host.hasPrefix("[") && host.hasSuffix("]")
      ? String(host.dropFirst().dropLast()) : host
    guard inet_pton(AF_INET6, literal, &ipv6) == 1 else { return false }
    return withUnsafeBytes(of: ipv6) { bytes in
      // Loopback and unique-local IPv6 only; exclude mapped public IPv4 addresses.
      (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
        || bytes[0] & 0xfe == 0xfc
    }
  }

  static func openAICompatibleAPIBaseURL(_ baseURL: URL) -> URL {
    var url = baseURL
    for suffix in ["/chat/completions", "/responses", "/models"] {
      if URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.hasSuffix(
        suffix)
        == true
      {
        for _ in suffix.split(separator: "/") { url.deleteLastPathComponent() }
        // A full endpoint can explicitly select an unversioned API at the server root.
        return url
      }
    }
    // Preserve existing root-level APIs and their Keychain account URLs.
    if RemoteProvider.isOpenAIAPIHost(url), url.path.isEmpty || url.path == "/" {
      url.appendPathComponent("v1", isDirectory: true)
    }
    return url
  }

  static let redirectPolicyMessage =
    "Only redirects within the same scheme, host, and port are followed. Enter the server's final API URL directly."

  static func permitsRedirect(from source: URL, to destination: URL) -> Bool {
    guard let scheme = source.scheme?.lowercased(), scheme == "http" || scheme == "https",
      destination.scheme?.lowercased() == scheme,
      let host = source.host?.lowercased(), destination.host?.lowercased() == host,
      destination.user == nil, destination.password == nil
    else { return false }
    let defaultPort = scheme == "https" ? 443 : 80
    return (source.port ?? defaultPort) == (destination.port ?? defaultPort)
  }
}

public enum RemoteProvider: String, CaseIterable, Equatable, Sendable {
  case localCode = "localcode"
  case openRouter = "openrouter"
  case openAI = "openai"
  case openAICompatible = "openai-compatible"
  case anthropic

  public static func isOpenAIAPIHost(_ url: URL) -> Bool {
    url.host?.lowercased() == "api.openai.com"
  }

  public var defaultBaseURL: URL? {
    switch self {
    case .localCode:
      return nil
    case .openRouter:
      return URL(string: "https://openrouter.ai/api/v1")!
    case .openAI, .openAICompatible:
      return URL(string: "https://api.openai.com")!
    case .anthropic:
      return AnthropicConfiguration.defaultBaseURL
    }
  }

  public var defaultAPIKeyEnvironment: String {
    switch self {
    case .localCode:
      return "LOCAL_CODE_API_KEY"
    case .openRouter:
      return "OPENROUTER_API_KEY"
    case .openAI, .openAICompatible:
      return "OPENAI_API_KEY"
    case .anthropic:
      return "ANTHROPIC_API_KEY"
    }
  }
}

public enum RemoteReasoningEffort: String, Codable, Equatable, Sendable {
  case low
  case medium
  case high
  case max
}

public struct RemoteProviderAccountEndpoint: Equatable, Sendable {
  public let provider: RemoteProvider
  public let baseURL: URL

  public init(provider: RemoteProvider, baseURL: URL? = nil) throws {
    self.provider = provider
    guard let baseURL = baseURL ?? provider.defaultBaseURL else {
      throw RemoteChatError.invalidBaseURL
    }
    self.baseURL = try RemoteEndpointURL.normalizedBaseURL(
      baseURL, allowsLocalHTTP: provider == .openAICompatible)
    if provider == .openAI, self.baseURL != RemoteProvider.openAI.defaultBaseURL {
      throw RemoteChatError.invalidBaseURL
    }
  }
}

public struct RemoteProviderEndpoint: Equatable, Sendable {
  public let provider: RemoteProvider
  public let baseURL: URL
  public let model: String

  public init(provider: RemoteProvider, baseURL: URL? = nil, model: String) throws {
    let accountEndpoint = try RemoteProviderAccountEndpoint(provider: provider, baseURL: baseURL)
    self.provider = provider
    switch provider {
    case .localCode, .openRouter, .openAI, .openAICompatible:
      let configuration = try OpenAICompatibleConfiguration(
        baseURL: accountEndpoint.baseURL, model: model)
      self.baseURL = configuration.baseURL
      self.model = configuration.model
    case .anthropic:
      let configuration = try AnthropicConfiguration(
        model: model, baseURL: accountEndpoint.baseURL)
      self.baseURL = configuration.baseURL
      self.model = configuration.model
    }
  }

  public var modelIdentity: RemoteModelIdentity {
    RemoteModelIdentity(provider: provider.rawValue, model: model)
  }

  public func makeChatProvider(
    authorization: any RemoteAuthorizationProviding, maximumOutputTokens: Int,
    reasoningEffort: RemoteReasoningEffort? = nil,
    sessionConfiguration: URLSessionConfiguration = .ephemeral
  ) throws -> RemoteChatProviding {
    switch provider {
    case .localCode, .openRouter:
      guard authorization.kind == .apiKey else {
        throw RemoteChatError.authentication("OpenRouter requires an API key.")
      }
      return OpenAICompatibleClient(
        configuration: try OpenAICompatibleConfiguration(
          baseURL: baseURL, model: model, maximumOutputTokens: maximumOutputTokens),
        authorization: authorization, sessionConfiguration: sessionConfiguration,
        modelIdentity: modelIdentity,
        reasoningEffort: reasoningEffort, usesOpenRouterReasoning: true)
    case .openAI:
      guard authorization.kind == .oauth, baseURL == RemoteProvider.openAI.defaultBaseURL else {
        throw RemoteChatError.authentication("OpenAI requires sign-in at the official endpoint.")
      }
      return OpenAIResponsesClient(
        codexModel: model, authorization: authorization,
        sessionConfiguration: sessionConfiguration, reasoningEffort: reasoningEffort)
    case .openAICompatible:
      guard authorization.kind == .apiKey || authorization.kind == .unauthenticated else {
        throw RemoteChatError.authentication("OpenAI Compatible API does not support OAuth.")
      }
      let configuration = try OpenAICompatibleConfiguration(
        baseURL: baseURL, model: model, maximumOutputTokens: maximumOutputTokens)
      if RemoteProvider.isOpenAIAPIHost(baseURL) {
        return OpenAIResponsesClient(
          configuration: configuration, authorization: authorization,
          sessionConfiguration: sessionConfiguration,
          modelIdentity: modelIdentity, reasoningEffort: reasoningEffort)
      }
      return OpenAICompatibleClient(
        configuration: configuration, authorization: authorization,
        sessionConfiguration: sessionConfiguration, modelIdentity: modelIdentity,
        reasoningEffort: reasoningEffort, usesOpenRouterReasoning: false)
    case .anthropic:
      return AnthropicClient(
        configuration: try AnthropicConfiguration(
          model: model, baseURL: baseURL, maximumOutputTokens: maximumOutputTokens),
        authorization: authorization, sessionConfiguration: sessionConfiguration,
        reasoningEffort: reasoningEffort)
    }
  }
}
