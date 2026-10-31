import Foundation

public final class OpenAICompatibleClient: RemoteChatProviding {
  public let modelIdentity: RemoteModelIdentity

  public var supportsImageInput: Bool { true }

  private let configuration: OpenAICompatibleConfiguration
  private let authorization: any RemoteAuthorizationProviding
  private let sessionConfiguration: URLSessionConfiguration
  private let reasoningEffort: RemoteReasoningEffort?
  private let usesOpenRouterReasoning: Bool

  public init(
    configuration: OpenAICompatibleConfiguration,
    authorization: any RemoteAuthorizationProviding,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    modelIdentity: RemoteModelIdentity? = nil,
    reasoningEffort: RemoteReasoningEffort? = nil,
    usesOpenRouterReasoning: Bool? = nil
  ) {
    self.configuration = configuration
    self.authorization = authorization
    self.sessionConfiguration = sessionConfiguration
    self.reasoningEffort = reasoningEffort
    self.usesOpenRouterReasoning =
      usesOpenRouterReasoning ?? configuration.preservesReasoningAcrossTurns
    self.modelIdentity =
      modelIdentity
      ?? RemoteModelIdentity(
        provider: RemoteProvider.openAICompatible.rawValue, model: configuration.model)
  }

  @discardableResult
  public func streamChat(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    let request = OpenAICompatibleChatRequest(
      maximumOutputTokens: configuration.maximumOutputTokens,
      progress: progress, completion: completion
    ) {
      [
        configuration, authorization, sessionConfiguration, modelIdentity, reasoningEffort,
        usesOpenRouterReasoning
      ]
      maximumOutputTokens, progress, completion in
      RemoteAuthorizedRequest(
        authorization: authorization,
        failure: { error in
          completion(
            .failure(
              error is CancellationError
                ? .cancelled : .authentication(error.localizedDescription)))
        }
      ) { value in
        Self.startAuthorizedChat(
          configuration: configuration, authorization: value,
          sessionConfiguration: sessionConfiguration, messages: messages, tools: tools,
          modelIdentity: modelIdentity, maximumOutputTokens: maximumOutputTokens,
          reasoningEffort: reasoningEffort, usesOpenRouterReasoning: usesOpenRouterReasoning,
          progress: progress, completion: completion)
      }
    }
    request.start()
    return request
  }

  private static func startAuthorizedChat(
    configuration: OpenAICompatibleConfiguration, authorization: RemoteRequestAuthorization,
    sessionConfiguration: URLSessionConfiguration, messages: [RemoteTranscriptEntry],
    tools: [RemoteFunctionTool], modelIdentity: RemoteModelIdentity, maximumOutputTokens: Int,
    reasoningEffort: RemoteReasoningEffort?, usesOpenRouterReasoning: Bool,
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    let requestMessages = OpenAICompatibleMessage.convert(
      messages, currentModel: modelIdentity,
      supportsReasoningFields: configuration.supportsReasoningMessageFields)
    let body: Data
    do {
      body = try JSONEncoder().encode(
        OpenAICompatibleRequest(
          model: configuration.model, messages: requestMessages, tools: tools,
          includeUsage: configuration.includeUsageInStream,
          maximumOutputTokens: maximumOutputTokens,
          usesMaxCompletionTokens: configuration.usesMaxCompletionTokens,
          reasoningEffort: reasoningEffort,
          usesOpenRouterReasoning: usesOpenRouterReasoning))
    } catch {
      completion(.failure(.malformedStream("could not encode the request")))
      return CompletedRemoteRequest.shared
    }
    guard body.count <= configuration.maximumRequestBytes else {
      completion(.failure(.requestTooLarge(maximumBytes: configuration.maximumRequestBytes)))
      return CompletedRemoteRequest.shared
    }

    var request = URLRequest(url: configuration.endpointURL)
    request.httpMethod = "POST"
    request.httpBody = body
    RemoteAuthorizationHeaders.applyBearer(authorization, to: &request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    if configuration.sendsAppAttribution {
      // OpenRouter ranks apps by these headers. Keep them in step with providerHeaders in
      // Cloudflare/local-code-router, so hosted and own-key usage count as one app.
      request.setValue("https://getlocalcode.app", forHTTPHeaderField: "HTTP-Referer")
      request.setValue("Local Code", forHTTPHeaderField: "X-OpenRouter-Title")
      request.setValue(
        "programming-app,personal-agent", forHTTPHeaderField: "X-OpenRouter-Categories")
    }

    var accumulator = OpenAICompatibleStreamAccumulator()
    let stream = RemoteStreamingRequest(
      redactedSecret: authorization.token, maximumEventBytes: configuration.maximumEventBytes,
      maximumErrorBytes: configuration.maximumErrorBytes, progress: progress,
      completion: completion,
      handleEvent: { event in
        switch event {
        case .done:
          guard accumulator.didFinish else {
            throw RemoteChatError.malformedStream(
              "OpenAI-compatible stream ended before finish_reason")
          }
          return .complete(accumulator.completion)
        case .data(let payload):
          guard let update = try accumulator.append(payload) else { return .none }
          return .progress(update)
        }
      },
      handleEnd: {
        guard accumulator.didFinish else {
          throw RemoteChatError.malformedStream(
            "OpenAI-compatible stream ended before finish_reason")
        }
        return accumulator.completion
      })
    stream.start(request, configuration: sessionConfiguration)
    return stream
  }
}

private final class OpenAICompatibleChatRequest: RemoteRequestCancellable {
  typealias StartAttempt = (
    _ maximumOutputTokens: Int, _ progress: @escaping (RemoteStreamProgress) -> Void,
    _ completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable

  private let lock = NSLock()
  private let progress: (RemoteStreamProgress) -> Void
  private let completion: (Result<RemoteCompletion, RemoteChatError>) -> Void
  private let startAttempt: StartAttempt
  private var maximumOutputTokens: Int
  private var attemptIdentifier = 0
  private var adaptationCount = 0
  private var request: RemoteRequestCancellable?
  private var isCancelled = false
  private var isFinished = false

  init(
    maximumOutputTokens: Int, progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void,
    startAttempt: @escaping StartAttempt
  ) {
    self.maximumOutputTokens = maximumOutputTokens
    self.progress = progress
    self.completion = completion
    self.startAttempt = startAttempt
  }

  func start() {
    start(maximumOutputTokens: maximumOutputTokens)
  }

  func cancel() {
    let request: RemoteRequestCancellable?
    lock.lock()
    guard !isFinished else {
      lock.unlock()
      return
    }
    isCancelled = true
    isFinished = true
    request = self.request
    self.request = nil
    lock.unlock()
    request?.cancel()
    completion(.failure(.cancelled))
  }

  private func start(maximumOutputTokens: Int) {
    let attemptIdentifier: Int
    lock.lock()
    guard !isCancelled, !isFinished else {
      lock.unlock()
      return
    }
    self.maximumOutputTokens = maximumOutputTokens
    self.attemptIdentifier += 1
    attemptIdentifier = self.attemptIdentifier
    lock.unlock()

    let request = startAttempt(
      maximumOutputTokens, progress,
      { result in
        self.handle(
          result, requestedOutputTokens: maximumOutputTokens,
          attemptIdentifier: attemptIdentifier)
      })
    lock.lock()
    if !isCancelled, !isFinished, self.attemptIdentifier == attemptIdentifier {
      self.request = request
      lock.unlock()
    } else {
      lock.unlock()
      request.cancel()
    }
  }

  private func handle(
    _ result: Result<RemoteCompletion, RemoteChatError>, requestedOutputTokens: Int,
    attemptIdentifier: Int
  ) {
    var adaptedMaximum: Int?
    var shouldComplete = false
    lock.lock()
    guard !isFinished, self.attemptIdentifier == attemptIdentifier else {
      lock.unlock()
      return
    }
    request = nil
    if !isCancelled, adaptationCount < 2,
      case .failure(let error) = result,
      let affordable = Self.adaptedOutputTokens(from: error),
      affordable >= 16, affordable < requestedOutputTokens
    {
      adaptationCount += 1
      adaptedMaximum = affordable
    } else {
      isFinished = true
      shouldComplete = true
    }
    lock.unlock()

    if let adaptedMaximum {
      start(maximumOutputTokens: adaptedMaximum)
    } else if shouldComplete {
      completion(result)
    }
  }

  /// The output budget a rejection allows: what OpenRouter credits can afford, or the
  /// max_tokens limit a server states when the requested output exceeds it.
  private static func adaptedOutputTokens(from error: RemoteChatError) -> Int? {
    guard case .provider(let statusCode, let message) = error else { return nil }
    let patterns: [String]
    switch statusCode {
    case 402:
      patterns = [#"can only afford\s+([0-9][0-9,]*)"#]
    case 400, 422:
      patterns = [
        // OpenAI: "This model supports at most 16384 completion tokens".
        #"at most\s+([0-9][0-9,]*)\s+completion tokens"#,
        // DeepSeek: "the valid range of max_tokens is [1, 8192]".
        #"range of max_tokens is \[\s*1\s*,\s*([0-9][0-9,]*)\s*\]"#,
        // Groq: "`max_tokens` must be less than or equal to `32768`".
        #"max_(?:completion_)?tokens`?\s+must be less than or equal to\s+`?([0-9][0-9,]*)"#,
      ]
    default:
      return nil
    }
    let range = NSRange(message.startIndex..<message.endIndex, in: message)
    for pattern in patterns {
      guard
        let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
        let match = expression.firstMatch(in: message, range: range),
        let tokenRange = Range(match.range(at: 1), in: message)
      else { continue }
      return Int(message[tokenRange].replacingOccurrences(of: ",", with: ""))
    }
    return nil
  }
}
