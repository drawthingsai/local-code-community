import Foundation

public struct RemoteModelLimits: Equatable, Sendable {
  // A fallback, not a claim about the server's actual model capacity. The output limit only caps
  // openAICompatibleOutputTokens, so a larger context still reserves more output.
  public static let openAICompatibleFallback = RemoteModelLimits(
    contextWindowTokens: 16_384, maximumOutputTokens: 32_768)

  /// Servers that omit an output limit (llama.cpp, Ollama, LM Studio, vLLM) generate until the
  /// context fills, so reserve a quarter of the context for output, at most `fallback`.
  static func openAICompatibleOutputTokens(contextWindowTokens: Int, fallback: Int) -> Int {
    max(512, min(fallback, contextWindowTokens / 4))
  }

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
      if endpoint.provider == .openAICompatible {
        let request = CompatibleLimitsRequest(
          session: session, endpoint: endpoint, modelURL: url, authorization: value,
          fallbackLimits: fallbackLimits, completion: completion)
        request.start()
        return request
      }
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
          var message = Self.errorMessage(from: data) ?? "Request failed."
          if !value.token.isEmpty {
            message = message.replacingOccurrences(of: value.token, with: "[REDACTED]")
          }
          completion(.failure(.httpStatus(response.statusCode, message)))
          return
        }
        guard let data,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let limits = Self.limits(in: root, endpoint: endpoint)
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
        let authorURL = Self.appendPathParameter(
          String(components[0]), to: endpoint.baseURL.appendingPathComponent("model"))
      else { return nil }
      return Self.appendPathParameter(String(components[1]), to: authorURL)
    case .openAI:
      return modelListURL(
        provider: endpoint.provider, baseURL: endpoint.baseURL,
        authenticationKind: authenticationKind)
    case .openAICompatible:
      guard authenticationKind == .apiKey || authenticationKind == .unauthenticated else {
        return nil
      }
      let versionedBaseURL = RemoteEndpointURL.openAICompatibleAPIBaseURL(endpoint.baseURL)
      return Self.appendPathParameter(
        endpoint.model, to: versionedBaseURL.appendingPathComponent("models"))
    case .anthropic:
      return Self.appendPathParameter(
        endpoint.model, to: endpoint.baseURL.appendingPathComponent("models"))
    case .deviceLink:
      return nil
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

  private static func appendPathParameter(_ value: String, to baseURL: URL) -> URL? {
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
    case .deviceLink:
      break
    }
  }

  private static func limits(
    in root: [String: Any], endpoint: RemoteProviderEndpoint
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
    let (contextWindowTokens, maximumOutputTokens) = publishedLimits(in: modelObject)
    guard let contextWindowTokens, contextWindowTokens >= 4_096,
      let maximumOutputTokens, maximumOutputTokens > 0
    else { return nil }
    return RemoteModelLimits(
      contextWindowTokens: contextWindowTokens, maximumOutputTokens: maximumOutputTokens)
  }

  /// The limits a model object states. Runtime context keys come first: LM Studio's loaded
  /// length, vLLM's max_model_len, and llama.cpp's n_ctx rather than its n_ctx_train.
  private static func publishedLimits(
    in model: [String: Any]
  ) -> (contextWindowTokens: Int?, maximumOutputTokens: Int?) {
    let topProvider = model["top_provider"] as? [String: Any]
    let contextWindowTokens = firstInteger([
      topProvider?["context_length"], model["loaded_context_length"], model["max_model_len"],
      model["context_length"], model["context_window"], model["max_context_length"],
      model["max_input_tokens"], (model["meta"] as? [String: Any])?["n_ctx"],
    ])
    let maximumOutputTokens = firstInteger([
      topProvider?["max_completion_tokens"], model["max_completion_tokens"],
      model["max_output_tokens"], model["max_tokens"],
    ])
    return (contextWindowTokens, maximumOutputTokens)
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

  /// OpenAI-compatible servers state limits in different places, if at all: the model route
  /// (Groq, Mistral), the model list (vLLM, llama.cpp, Together), or native routes beside /v1
  /// (Ollama, LM Studio). Probe them in turn until one states the context the server runs the
  /// model with, loading an Ollama model that is not loaded yet. A model's trained context only
  /// caps the fallback, since servers often load models with less.
  private final class CompatibleLimitsRequest: RemoteRequestCancellable, @unchecked Sendable {
    private struct Probe {
      var url: URL
      var body: Data? = nil
      var timeoutInterval: TimeInterval = 15
      var limits: (Any) -> ProbedLimits?
    }

    private struct ProbedLimits {
      var contextWindowTokens: Int?
      var trainedContextWindowTokens: Int?
      var maximumOutputTokens: Int?
      /// Routes to probe next, before the remaining ones.
      var followingProbes = [Probe]()
    }

    private let session: URLSession
    private let authorization: RemoteRequestAuthorization
    private let fallbackLimits: RemoteModelLimits
    private let completion: (Result<RemoteModelLimits, RemoteModelMetadataError>) -> Void
    private var probes: [Probe]
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isFinished = false
    private var trainedContextWindowTokens: Int?
    private var maximumOutputTokens: Int?

    init(
      session: URLSession, endpoint: RemoteProviderEndpoint, modelURL: URL,
      authorization: RemoteRequestAuthorization, fallbackLimits: RemoteModelLimits,
      completion: @escaping (Result<RemoteModelLimits, RemoteModelMetadataError>) -> Void
    ) {
      self.session = session
      self.authorization = authorization
      self.fallbackLimits = fallbackLimits
      self.completion = completion
      let model = endpoint.model
      let versionedBaseURL = RemoteEndpointURL.openAICompatibleAPIBaseURL(endpoint.baseURL)
      var probes = [
        // The model route already selects the requested model. Servers may resolve an alias
        // to a canonical ID, or omit the ID from a successful response.
        Probe(url: modelURL) { root in
          (root as? [String: Any]).map {
            let limits = RemoteModelMetadataClient.publishedLimits(in: $0)
            return ProbedLimits(
              contextWindowTokens: limits.contextWindowTokens,
              maximumOutputTokens: limits.maximumOutputTokens)
          }
        },
        Probe(url: versionedBaseURL.appendingPathComponent("models", isDirectory: false)) {
          root in
          guard let models = (root as? [String: Any])?["data"] as? [[String: Any]],
            // llama.cpp serves its one model under any requested name.
            let entry = models.first(where: { $0["id"] as? String == model })
              ?? (models.count == 1 ? models[0] : nil)
          else { return nil }
          let limits = RemoteModelMetadataClient.publishedLimits(in: entry)
          return ProbedLimits(
            contextWindowTokens: limits.contextWindowTokens,
            maximumOutputTokens: limits.maximumOutputTokens)
        },
      ]
      if versionedBaseURL.lastPathComponent == "v1" {
        let serverURL = versionedBaseURL.deletingLastPathComponent()
        let modelBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        // Ollama reports the context it loaded a model with only while the model is loaded.
        let runningModels = Probe(
          url: serverURL.appendingPathComponent("api/ps", isDirectory: false)
        ) { root in
          guard let models = (root as? [String: Any])?["models"] as? [[String: Any]],
            let loaded = models.first(where: {
              [model, model + ":latest"].contains($0["name"] as? String ?? "")
            })
          else { return nil }
          return ProbedLimits(
            contextWindowTokens: RemoteModelMetadataClient.integer(loaded["context_length"]))
        }
        // A generate request without a prompt only loads the model, as the next chat would.
        let loadModel = Probe(
          url: serverURL.appendingPathComponent("api/generate", isDirectory: false),
          body: modelBody, timeoutInterval: 120
        ) { _ in nil }
        probes.append(runningModels)
        // A Modelfile num_ctx sets the context before loading; model_info has the trained one.
        probes.append(
          Probe(
            url: serverURL.appendingPathComponent("api/show", isDirectory: false), body: modelBody
          ) { root in
            guard let root = root as? [String: Any],
              let modelInfo = root["model_info"] as? [String: Any]
            else { return nil }
            let numContext = (root["parameters"] as? String)?.split(separator: "\n").lazy
              .compactMap { line -> Int? in
                let fields = line.split(whereSeparator: \.isWhitespace)
                return fields.count == 2 && fields[0] == "num_ctx" ? Int(fields[1]) : nil
              }.first
            let trained = modelInfo.first { $0.key.hasSuffix(".context_length") }.flatMap {
              RemoteModelMetadataClient.integer($0.value)
            }
            return ProbedLimits(
              contextWindowTokens: numContext, trainedContextWindowTokens: trained,
              followingProbes: [loadModel, runningModels])
          })
        if let url = RemoteModelMetadataClient.appendPathParameter(
          model, to: serverURL.appendingPathComponent("api/v0/models"))
        {
          probes.append(
            Probe(url: url) { root in
              guard let root = root as? [String: Any], root["id"] as? String == model else {
                return nil
              }
              return ProbedLimits(
                contextWindowTokens: RemoteModelMetadataClient.integer(
                  root["loaded_context_length"]),
                trainedContextWindowTokens: RemoteModelMetadataClient.integer(
                  root["max_context_length"]))
            })
        }
      }
      self.probes = probes
    }

    func start() {
      load(0)
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

    private func load(_ index: Int) {
      guard index < probes.count else {
        finish(contextWindowTokens: nil)
        return
      }
      var request = URLRequest(url: probes[index].url)
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.timeoutInterval = probes[index].timeoutInterval
      if let body = probes[index].body {
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
      RemoteAuthorizationHeaders.applyBearer(authorization, to: &request)
      let task = session.dataTask(with: request) { [self] data, response, error in
        handle(index, data: data, response: response, error: error)
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

    private func handle(_ index: Int, data: Data?, response: URLResponse?, error: Error?) {
      lock.lock()
      guard !isFinished else {
        lock.unlock()
        return
      }
      task = nil
      lock.unlock()
      if let error {
        if (error as? URLError)?.code == .cancelled {
          finish(.failure(.cancelled))
        } else if index == 0 {
          finish(.failure(.transport(error.localizedDescription)))
        } else {
          load(index + 1)
        }
        return
      }
      let statusCode = (response as? HTTPURLResponse)?.statusCode
      // The model route speaks for the server; the other routes exist only on some servers.
      if index == 0 {
        guard let statusCode else {
          finish(.failure(.transport("The provider returned no HTTP response.")))
          return
        }
        // Some compatible servers expose chat and model lists, but no model-detail route.
        // Never conceal authentication, throttling, transport, or TLS failures.
        if !(200...299).contains(statusCode), ![404, 405, 501].contains(statusCode) {
          var message = RemoteModelMetadataClient.errorMessage(from: data) ?? "Request failed."
          if !authorization.token.isEmpty {
            message = message.replacingOccurrences(of: authorization.token, with: "[REDACTED]")
          }
          finish(.failure(.httpStatus(statusCode, message)))
          return
        }
      }
      guard let statusCode, (200...299).contains(statusCode) else {
        load(index + 1)
        return
      }
      let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
      if index == 0, (root as? [String: Any]).map({ $0["error"] != nil }) ?? true {
        finish(.failure(.limitsUnavailable))
        return
      }
      guard let root, let limits = probes[index].limits(root) else {
        load(index + 1)
        return
      }
      maximumOutputTokens =
        maximumOutputTokens
        ?? limits.maximumOutputTokens.flatMap {
          $0 > 0 ? $0 : nil
        }
      if let trained = limits.trainedContextWindowTokens, trained > 0 {
        trainedContextWindowTokens = min(trainedContextWindowTokens ?? trained, trained)
      }
      if let context = limits.contextWindowTokens, context > 0 {
        finish(contextWindowTokens: context)
      } else {
        probes.insert(contentsOf: limits.followingProbes, at: index + 1)
        load(index + 1)
      }
    }

    private func finish(contextWindowTokens: Int?) {
      let context =
        contextWindowTokens
        ?? min(fallbackLimits.contextWindowTokens, trainedContextWindowTokens ?? .max)
      guard context >= 4_096 else {
        finish(.failure(.limitsUnavailable))
        return
      }
      finish(
        .success(
          RemoteModelLimits(
            contextWindowTokens: context,
            maximumOutputTokens: maximumOutputTokens
              ?? RemoteModelLimits.openAICompatibleOutputTokens(
                contextWindowTokens: context, fallback: fallbackLimits.maximumOutputTokens))))
    }

    private func finish(_ result: Result<RemoteModelLimits, RemoteModelMetadataError>) {
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
