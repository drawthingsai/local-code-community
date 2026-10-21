import Foundation

public final class AnthropicClient: RemoteChatProviding {
  public let modelIdentity: RemoteModelIdentity

  private let configuration: AnthropicConfiguration
  private let authorization: any RemoteAuthorizationProviding
  private let sessionConfiguration: URLSessionConfiguration
  private let reasoningEffort: RemoteReasoningEffort?

  public init(
    configuration: AnthropicConfiguration,
    authorization: any RemoteAuthorizationProviding,
    sessionConfiguration: URLSessionConfiguration = .ephemeral,
    reasoningEffort: RemoteReasoningEffort? = nil
  ) {
    self.configuration = configuration
    self.authorization = authorization
    self.sessionConfiguration = sessionConfiguration
    self.reasoningEffort = reasoningEffort
    modelIdentity = RemoteModelIdentity(
      provider: RemoteProvider.anthropic.rawValue, model: configuration.model)
  }

  @discardableResult
  public func streamChat(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    guard messages.allSatisfy({ $0.images.isEmpty }) else {
      completion(.failure(.imageInputUnsupported))
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
    ) { [configuration, sessionConfiguration, modelIdentity, reasoningEffort] authorization in
      Self.startChat(
        configuration: configuration, authorization: authorization,
        sessionConfiguration: sessionConfiguration, messages: messages, tools: tools,
        modelIdentity: modelIdentity, reasoningEffort: reasoningEffort,
        progress: progress, completion: completion)
    }
  }

  private static func startChat(
    configuration: AnthropicConfiguration, authorization: RemoteRequestAuthorization,
    sessionConfiguration: URLSessionConfiguration, messages: [RemoteTranscriptEntry],
    tools: [RemoteFunctionTool], modelIdentity: RemoteModelIdentity,
    reasoningEffort: RemoteReasoningEffort?,
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    let usesOAuth = authorization.kind == .oauth
    let body: Data
    do {
      body = try JSONEncoder().encode(
        AnthropicRequest(
          model: configuration.model, maxTokens: configuration.maximumOutputTokens,
          transcript: messages, remoteTools: tools, currentModel: modelIdentity,
          usesOAuth: usesOAuth, reasoningEffort: reasoningEffort))
    } catch let error as RemoteChatError {
      completion(.failure(error))
      return CompletedRemoteRequest.shared
    } catch {
      completion(.failure(.malformedStream("could not encode the Claude request")))
      return CompletedRemoteRequest.shared
    }
    guard body.count <= configuration.maximumRequestBytes else {
      completion(.failure(.requestTooLarge(maximumBytes: configuration.maximumRequestBytes)))
      return CompletedRemoteRequest.shared
    }

    var request = URLRequest(url: configuration.endpointURL)
    request.httpMethod = "POST"
    request.httpBody = body
    RemoteAuthorizationHeaders.applyAnthropic(authorization, to: &request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

    let toolNames = tools.reduce(into: [String: String]()) {
      $0[$1.name.lowercased()] = $1.name
    }
    var accumulator = AnthropicStreamAccumulator(toolNames: toolNames)
    let stream = RemoteStreamingRequest(
      redactedSecret: authorization.token, maximumEventBytes: configuration.maximumEventBytes,
      maximumErrorBytes: configuration.maximumErrorBytes, progress: progress,
      completion: completion,
      handleEvent: { event in
        guard case .data(let payload) = event else {
          throw RemoteChatError.malformedStream(
            "Claude stream used an unexpected [DONE] marker")
        }
        let update = try accumulator.append(payload)
        if update.didComplete {
          return .complete(accumulator.completion)
        }
        guard let progress = update.progress else { return .none }
        return .progress(progress)
      },
      handleEnd: {
        throw RemoteChatError.malformedStream(
          "Claude stream ended before message_stop")
      })
    stream.start(request, configuration: sessionConfiguration)
    return stream
  }
}
