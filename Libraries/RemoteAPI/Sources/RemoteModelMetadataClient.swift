import Foundation

public struct RemoteModelLimits: Equatable, Sendable {
  // A fallback, not a claim about the server's actual model capacity.
  public static let openAICompatibleFallback = RemoteModelLimits(
    contextWindowTokens: 16_384, maximumOutputTokens: 2_048)

  public var contextWindowTokens: Int
  public var maximumOutputTokens: Int

  public init(contextWindowTokens: Int, maximumOutputTokens: Int) {
    self.contextWindowTokens = contextWindowTokens
    self.maximumOutputTokens = maximumOutputTokens
  }
}

public enum RemoteModelMetadataError: LocalizedError, Equatable {
  case cancelled
  case invalidModelIdentifier
  case authentication(String)
  case transport(String)
  case httpStatus(Int, String)
  case limitsUnavailable
  case modelsUnavailable

  public var errorDescription: String? {
    switch self {
    case .cancelled:
      return "Model metadata request cancelled."
    case .invalidModelIdentifier:
      return "The remote model identifier is invalid."
    case .authentication(let message):
      return "Could not authorize the model metadata request. \(message)"
    case .transport(let message):
      return "Could not load remote model metadata: \(message)"
    case .httpStatus(let statusCode, let message):
      if [301, 302, 303, 307, 308].contains(statusCode) {
        return
          "The model metadata endpoint returned HTTP \(statusCode). \(RemoteEndpointURL.redirectPolicyMessage)"
      }
      return "The model metadata endpoint returned HTTP \(statusCode). \(message)"
    case .limitsUnavailable:
      return
        "The provider's model metadata did not include usable limits. A context window of at least 4,096 tokens and a maximum-output limit are required."
    case .modelsUnavailable:
      return "The provider returned an invalid model list."
    }
  }
}

public final class RemoteModelMetadataClient {
  private let session: URLSession

  public init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
    session = URLSession(configuration: sessionConfiguration)
  }

  @discardableResult
  public func fetch(
    endpoint: RemoteProviderEndpoint, authorization: any RemoteAuthorizationProviding,
    fallbackLimits: RemoteModelLimits = .openAICompatibleFallback,
    completion: @escaping (Result<RemoteModelLimits, RemoteModelMetadataError>) -> Void
  ) -> RemoteRequestCancellable {
    guard let url = endpointURL(endpoint, authenticationKind: authorization.kind) else {
      completion(.failure(.invalidModelIdentifier))
      return CompletedRemoteRequest.shared
    }
    return RemoteAuthorizedRequest(
      authorization: authorization,
      failure: { error in
        completion(
          .failure(
            error is CancellationError
              ? .cancelled : .authentication(error.localizedDescription)))
      }
    ) { [session] value in
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.timeoutInterval = 15
      Self.applyHeaders(value, endpoint: endpoint, to: &request)
      let task = session.dataTask(with: request) { data, response, error in
        if let error {
          if (error as? URLError)?.code == .cancelled {
            completion(.failure(.cancelled))
          } else {
            completion(.failure(.transport(error.localizedDescription)))
          }
          return
        }
        guard let response = response as? HTTPURLResponse else {
          completion(.failure(.transport("The provider returned no HTTP response.")))
          return
        }
        guard (200...299).contains(response.statusCode) else {
          // Some compatible servers expose chat and model lists, but no model-detail route.
          // Never conceal authentication, throttling, transport, or TLS failures.
          if endpoint.provider == .openAICompatible,
            [404, 405, 501].contains(response.statusCode)
          {
            completion(.success(fallbackLimits))
            return
          }
          var message = Self.errorMessage(from: data) ?? "Request failed."
          if !value.token.isEmpty {
            message = message.replacingOccurrences(of: value.token, with: "[REDACTED]")
          }
          completion(.failure(.httpStatus(response.statusCode, message)))
          return
        }
        guard let data,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let limits = Self.limits(in: root, endpoint: endpoint, fallbackLimits: fallbackLimits)
        else {
          completion(.failure(.limitsUnavailable))
          return
        }
        completion(.success(limits))
      }
      task.delegate = RemoteSessionDelegate()
      task.resume()
      return task
    }
  }

  @discardableResult
  public func fetchModels(
    endpoint: RemoteProviderEndpoint, authorization: any RemoteAuthorizationProviding,
    completion: @escaping (Result<[String], RemoteModelMetadataError>) -> Void
  ) -> RemoteRequestCancellable {
    fetchModels(
      provider: endpoint.provider, baseURL: endpoint.baseURL, authorization: authorization,
      completion: completion)
  }

  @discardableResult
  public func fetchModels(
    accountEndpoint: RemoteProviderAccountEndpoint,
    authorization: any RemoteAuthorizationProviding,
    completion: @escaping (Result<[String], RemoteModelMetadataError>) -> Void
  ) -> RemoteRequestCancellable {
    fetchModels(
      provider: accountEndpoint.provider, baseURL: accountEndpoint.baseURL,
      authorization: authorization, completion: completion)
  }

  private func fetchModels(
    provider: RemoteProvider, baseURL: URL,
    authorization: any RemoteAuthorizationProviding,
    completion: @escaping (Result<[String], RemoteModelMetadataError>) -> Void
  ) -> RemoteRequestCancellable {
    guard
      let url = modelListURL(
        provider: provider, baseURL: baseURL, authenticationKind: authorization.kind)
    else {
      completion(.failure(.invalidModelIdentifier))
      return CompletedRemoteRequest.shared
    }
    return RemoteAuthorizedRequest(
      authorization: authorization,
      failure: { error in
        completion(
          .failure(
            error is CancellationError
              ? .cancelled : .authentication(error.localizedDescription)))
      }
    ) { [session] value in
      let request = ModelListRequest(
        session: session, url: url, provider: provider, authorization: value,
        completion: completion)
      request.start()
      return request
    }
  }

  private func endpointURL(
    _ endpoint: RemoteProviderEndpoint, authenticationKind: RemoteAuthenticationKind
  ) -> URL? {
    switch endpoint.provider {
    case .localCode, .openRouter:
      let components = endpoint.model.split(
        separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
      guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty,
        let authorURL = appendPathParameter(
          String(components[0]), to: endpoint.baseURL.appendingPathComponent("model"))
      else { return nil }
      return appendPathParameter(String(components[1]), to: authorURL)
    case .openAI:
      return modelListURL(
        provider: endpoint.provider, baseURL: endpoint.baseURL,
        authenticationKind: authenticationKind)
    case .openAICompatible:
      guard authenticationKind == .apiKey || authenticationKind == .unauthenticated else {
        return nil
      }
      let versionedBaseURL = RemoteEndpointURL.openAICompatibleAPIBaseURL(endpoint.baseURL)
      return appendPathParameter(
        endpoint.model, to: versionedBaseURL.appendingPathComponent("models"))
    case .anthropic:
      return appendPathParameter(
        endpoint.model, to: endpoint.baseURL.appendingPathComponent("models"))
    }
  }

  private func modelListURL(
    provider: RemoteProvider, baseURL: URL, authenticationKind: RemoteAuthenticationKind
  ) -> URL? {
    guard provider != .openAICompatible || authenticationKind != .oauth else { return nil }
    if provider == .openAI {
      guard authenticationKind == .oauth else { return nil }
      var components = URLComponents(
        url: URL(string: "https://chatgpt.com/backend-api/codex/models")!,
        resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "client_version", value: "1.0.0")]
      return components.url
    }
    let modelListBaseURL: URL
    if provider == .openAICompatible {
      modelListBaseURL = RemoteEndpointURL.openAICompatibleAPIBaseURL(baseURL)
    } else {
      modelListBaseURL = baseURL
    }
    let url = modelListBaseURL.appendingPathComponent("models", isDirectory: false)
    guard provider == .anthropic else { return url }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "limit", value: "1000")]
    return components?.url
  }

  private func appendPathParameter(_ value: String, to baseURL: URL) -> URL? {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/%")
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return URL(string: baseURL.absoluteString + "/" + encoded)
  }

  private static func applyHeaders(
    _ authorization: RemoteRequestAuthorization, endpoint: RemoteProviderEndpoint,
    to request: inout URLRequest
  ) {
    applyHeaders(authorization, provider: endpoint.provider, to: &request)
  }

  private static func applyHeaders(
    _ authorization: RemoteRequestAuthorization, provider: RemoteProvider,
    to request: inout URLRequest
  ) {
    switch provider {
    case .openAI:
      RemoteAuthorizationHeaders.applyOpenAICodex(authorization, to: &request)
    case .localCode, .openAICompatible, .openRouter:
      RemoteAuthorizationHeaders.applyBearer(authorization, to: &request)
    case .anthropic:
      RemoteAuthorizationHeaders.applyAnthropic(authorization, to: &request)
    }
  }

  private static func limits(
    in root: [String: Any], endpoint: RemoteProviderEndpoint, fallbackLimits: RemoteModelLimits
  ) -> RemoteModelLimits? {
    if endpoint.provider == .openAI {
      guard let models = root["models"] as? [[String: Any]],
        let model = models.first(where: {
          ($0["slug"] as? String) == endpoint.model || ($0["model"] as? String) == endpoint.model
        }),
        let contextWindow = firstInteger([model["context_window"], model["max_context_window"]]),
        contextWindow >= 4_096
      else { return nil }
      let percent = min(max(integer(model["effective_context_window_percent"]) ?? 95, 1), 99)
      let effectiveInput = contextWindow * percent / 100
      return RemoteModelLimits(
        contextWindowTokens: contextWindow,
        maximumOutputTokens: max(512, contextWindow - effectiveInput))
    }

    let modelObject: [String: Any]
    if endpoint.provider == .localCode || endpoint.provider == .openRouter,
      let data = root["data"] as? [String: Any]
    {
      modelObject = data
    } else {
      modelObject = root
    }
    let topProvider = modelObject["top_provider"] as? [String: Any]
    let contextWindowTokens = firstInteger([
      topProvider?["context_length"], modelObject["context_length"],
      modelObject["max_context_length"], modelObject["max_input_tokens"],
    ])
    let maximumOutputTokens = firstInteger([
      topProvider?["max_completion_tokens"], modelObject["max_completion_tokens"],
      modelObject["max_output_tokens"], modelObject["max_tokens"],
    ])
    if endpoint.provider == .openAICompatible {
      guard root["error"] == nil else { return nil }
      // The detail route already selects the requested model. Servers may resolve an
      // alias to a canonical ID, or omit the ID and limits from a successful response.
      // Honor published limits and fill only the missing values from the fallback.
      let context =
        contextWindowTokens.flatMap { $0 > 0 ? $0 : nil } ?? fallbackLimits.contextWindowTokens
      guard context >= 4_096 else { return nil }
      let output =
        maximumOutputTokens.flatMap { $0 > 0 ? $0 : nil }
        ?? fallbackLimits.maximumOutputTokens
      return RemoteModelLimits(
        contextWindowTokens: context, maximumOutputTokens: output)
    }
    guard let contextWindowTokens, contextWindowTokens >= 4_096,
      let maximumOutputTokens, maximumOutputTokens > 0
    else { return nil }
    return RemoteModelLimits(
      contextWindowTokens: contextWindowTokens, maximumOutputTokens: maximumOutputTokens)
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private static func firstInteger(_ values: [Any?]) -> Int? {
    values.lazy.compactMap(integer).first
  }

  private static func errorMessage(from data: Data?) -> String? {
    guard let data,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let message = root["message"] as? String { return message }
    if let error = root["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    return nil
  }

  private final class ModelListRequest: RemoteRequestCancellable, @unchecked Sendable {
    private let session: URLSession
    private let firstURL: URL
    private let provider: RemoteProvider
    private let authorization: RemoteRequestAuthorization
    private let completion: (Result<[String], RemoteModelMetadataError>) -> Void
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isFinished = false
    private var modelIDs = [String]()
    private var seenModelIDs = Set<String>()
    private var seenCursors = Set<String>()

    init(
      session: URLSession, url: URL, provider: RemoteProvider,
      authorization: RemoteRequestAuthorization,
      completion: @escaping (Result<[String], RemoteModelMetadataError>) -> Void
    ) {
      self.session = session
      self.firstURL = url
      self.provider = provider
      self.authorization = authorization
      self.completion = completion
    }

    func start() {
      load(firstURL)
    }

    func cancel() {
      let task: URLSessionDataTask?
      lock.lock()
      guard !isFinished else {
        lock.unlock()
        return
      }
      isFinished = true
      task = self.task
      self.task = nil
      lock.unlock()
      task?.cancel()
      completion(.failure(.cancelled))
    }

    private func load(_ url: URL) {
      var request = URLRequest(url: url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.timeoutInterval = 15
      RemoteModelMetadataClient.applyHeaders(authorization, provider: provider, to: &request)
      let task = session.dataTask(with: request) { [self] data, response, error in
        handle(data: data, response: response, error: error)
      }
      lock.lock()
      guard !isFinished else {
        lock.unlock()
        task.cancel()
        return
      }
      self.task = task
      lock.unlock()
      task.delegate = RemoteSessionDelegate()
      task.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
      lock.lock()
      guard !isFinished else {
        lock.unlock()
        return
      }
      task = nil
      lock.unlock()
      if let error {
        finish(
          .failure(
            (error as? URLError)?.code == .cancelled
              ? .cancelled : .transport(error.localizedDescription)))
        return
      }
      guard let response = response as? HTTPURLResponse else {
        finish(.failure(.transport("The provider returned no HTTP response.")))
        return
      }
      guard (200...299).contains(response.statusCode) else {
        var message = RemoteModelMetadataClient.errorMessage(from: data) ?? "Request failed."
        if !authorization.token.isEmpty {
          message = message.replacingOccurrences(of: authorization.token, with: "[REDACTED]")
        }
        finish(.failure(.httpStatus(response.statusCode, message)))
        return
      }
      guard let data,
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let pageModelIDs = Self.modelIDs(in: root, provider: provider)
      else {
        finish(.failure(.modelsUnavailable))
        return
      }
      for modelID in pageModelIDs {
        let modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, seenModelIDs.insert(modelID).inserted else { continue }
        modelIDs.append(modelID)
      }
      guard provider == .anthropic, root["has_more"] as? Bool == true else {
        finish(.success(modelIDs))
        return
      }
      guard
        let cursor = (root["last_id"] as? String)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !cursor.isEmpty, seenCursors.insert(cursor).inserted,
        var components = URLComponents(url: firstURL, resolvingAgainstBaseURL: false)
      else {
        finish(.failure(.modelsUnavailable))
        return
      }
      components.queryItems =
        (components.queryItems ?? []).filter { $0.name != "after_id" }
        + [URLQueryItem(name: "after_id", value: cursor)]
      guard let nextURL = components.url else {
        finish(.failure(.modelsUnavailable))
        return
      }
      load(nextURL)
    }

    private func finish(_ result: Result<[String], RemoteModelMetadataError>) {
      lock.lock()
      guard !isFinished else {
        lock.unlock()
        return
      }
      isFinished = true
      task = nil
      lock.unlock()
      completion(result)
    }

    private static func modelIDs(
      in root: [String: Any], provider: RemoteProvider
    ) -> [String]? {
      if provider == .openAI {
        guard let models = root["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { model in
          [model["slug"], model["model"]].compactMap { $0 as? String }.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          }
        }
      }
      guard let models = root["data"] as? [[String: Any]] else { return nil }
      return models.compactMap { $0["id"] as? String }
    }
  }
}
