import Foundation

public final class OpenAIResponsesClient: RemoteChatProviding {
  public let modelIdentity: RemoteModelIdentity
  public var supportsImageInput: Bool { true }

  private let model: String
  private let endpointURL: URL
  private let usesCodexHeaders: Bool
  private let authorization: any RemoteAuthorizationProviding
  private let sessionConfiguration: URLSessionConfiguration
  private let maximumRequestBytes: Int
  private let maximumEventBytes: Int
  private let maximumErrorBytes: Int
  private let maximumOutputTokens: Int?
  private let reasoningEffort: RemoteReasoningEffort?
  // One key per client keeps a conversation's requests on the same prompt cache.
  private let promptCacheKey = UUID().uuidString
  private let turnState = CodexTurnState()

  public init(
    configuration: OpenAICompatibleConfiguration,
    authorization: any RemoteAuthorizationProviding,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    modelIdentity: RemoteModelIdentity? = nil,
    reasoningEffort: RemoteReasoningEffort? = nil
  ) {
    model = configuration.model
    endpointURL = configuration.responsesEndpointURL
    usesCodexHeaders = false
    self.authorization = authorization
    self.sessionConfiguration = sessionConfiguration
    maximumRequestBytes = configuration.maximumRequestBytes
    maximumEventBytes = configuration.maximumEventBytes
    maximumErrorBytes = configuration.maximumErrorBytes
    maximumOutputTokens = configuration.maximumOutputTokens
    self.reasoningEffort = reasoningEffort
    self.modelIdentity =
      modelIdentity
      ?? RemoteModelIdentity(
        provider: RemoteProvider.openAICompatible.rawValue, model: configuration.model)
  }

  public init(
    codexModel model: String, authorization: any RemoteAuthorizationProviding,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    maximumRequestBytes: Int = 32 * 1_024 * 1_024,
    maximumEventBytes: Int = 1 * 1_024 * 1_024, maximumErrorBytes: Int = 64 * 1_024,
    reasoningEffort: RemoteReasoningEffort? = nil
  ) {
    self.model = model
    endpointURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    usesCodexHeaders = true
    self.authorization = authorization
    self.sessionConfiguration = sessionConfiguration
    self.maximumRequestBytes = maximumRequestBytes
    self.maximumEventBytes = maximumEventBytes
    self.maximumErrorBytes = maximumErrorBytes
    maximumOutputTokens = nil
    self.reasoningEffort = reasoningEffort
    modelIdentity = RemoteModelIdentity(provider: "openai-codex", model: model)
  }

  @discardableResult
  public func streamChat(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    let body: Data
    do {
      body = try RemoteRequestBody.encode(
        OpenAIResponsesRequest(
          model: model, transcript: messages, tools: tools, currentModel: modelIdentity,
          maximumOutputTokens: maximumOutputTokens, reasoningEffort: reasoningEffort,
          promptCacheKey: promptCacheKey))
    } catch {
      completion(.failure(.malformedStream("could not encode the OpenAI request")))
      return CompletedRemoteRequest.shared
    }
    guard body.count <= maximumRequestBytes else {
      completion(.failure(.requestTooLarge(maximumBytes: maximumRequestBytes)))
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
    ) {
      [
        endpointURL, usesCodexHeaders, sessionConfiguration, maximumEventBytes, maximumErrorBytes,
        promptCacheKey, turnState
      ] authorization in
      guard !usesCodexHeaders || authorization.accountID?.isEmpty == false else {
        completion(
          .failure(.authentication(RemoteOAuthError.missingAccountID.localizedDescription)))
        return CompletedRemoteRequest.shared
      }
      var request = URLRequest(url: endpointURL)
      request.httpMethod = "POST"
      request.httpBody = body
      if usesCodexHeaders {
        RemoteAuthorizationHeaders.applyOpenAICodex(authorization, to: &request)
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        // Codex routes by session and turn state; prompt_cache_key alone never hit its cache.
        request.setValue(promptCacheKey, forHTTPHeaderField: "session_id")
        if let value = turnState.value {
          request.setValue(value, forHTTPHeaderField: CodexTurnState.headerField)
        }
      } else {
        RemoteAuthorizationHeaders.applyBearer(authorization, to: &request)
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

      var accumulator = OpenAIResponsesStreamAccumulator()
      let stream = RemoteStreamingRequest(
        redactedSecret: authorization.token, maximumEventBytes: maximumEventBytes,
        maximumErrorBytes: maximumErrorBytes, progress: progress, completion: completion,
        handleEvent: { event in
          switch event {
          case .done:
            throw RemoteChatError.malformedStream(
              "OpenAI stream ended before response.completed")
          case .data(let payload):
            let update = try accumulator.append(payload)
            if update.didComplete { return .complete(accumulator.completion) }
            if let progress = update.progress { return .progress(progress) }
            return .none
          }
        },
        handleEnd: {
          throw RemoteChatError.malformedStream(
            "OpenAI stream ended before response.completed")
        },
        handleResponse: { response in
          if let value = response.value(forHTTPHeaderField: CodexTurnState.headerField) {
            turnState.value = value
          }
        })
      stream.start(request, configuration: sessionConfiguration)
      return stream
    }
  }
}

// The Codex backend returns this header on a conversation's first response. Sending it back on
// later requests keeps them on the backend that holds the prompt cache.
private final class CodexTurnState: @unchecked Sendable {
  static let headerField = "x-codex-turn-state"

  private let lock = NSLock()
  private var storedValue: String?

  var value: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storedValue
    }
    set {
      lock.lock()
      storedValue = newValue
      lock.unlock()
    }
  }
}
