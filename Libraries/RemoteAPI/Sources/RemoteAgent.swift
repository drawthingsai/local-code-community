import Foundation

public enum RemoteToolError {
  public static func content(type: String, function: String, message: String) -> String {
    let object = ["type": type, "function": function, "error": message]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return "{\"type\":\"tool_error\"}" }
    return String(data: data, encoding: .utf8) ?? "{\"type\":\"tool_error\"}"
  }
}

public struct RemoteToolExecutionResult: Equatable, Sendable {
  public var content: String
  public var images: [RemoteImage]
  public var subtitle: String
  public var isError: Bool

  public init(content: String, subtitle: String, isError: Bool = false, images: [RemoteImage] = [])
  {
    self.content = content
    self.images = images
    self.subtitle = subtitle
    self.isError = isError
  }
}

public struct RemoteAgentToolProgress: Equatable, Sendable {
  public var id: String
  public var subtitle: String
  public var isCompleted: Bool

  public init(id: String, subtitle: String, isCompleted: Bool) {
    self.id = id
    self.subtitle = subtitle
    self.isCompleted = isCompleted
  }
}

public struct RemoteAgentMetrics: Equatable, Sendable {
  public var averageTimeToFirstToken: TimeInterval?
  public var observedOutputTokensPerSecond: Double?
  public var isOutputRateEstimated: Bool

  public init(
    averageTimeToFirstToken: TimeInterval? = nil,
    observedOutputTokensPerSecond: Double? = nil, isOutputRateEstimated: Bool = false
  ) {
    self.averageTimeToFirstToken = averageTimeToFirstToken
    self.observedOutputTokensPerSecond = observedOutputTokensPerSecond
    self.isOutputRateEstimated = isOutputRateEstimated
  }
}

public struct RemoteAgentProgress: Equatable, Sendable {
  public var text: String
  public var streamingToolCalls: [RemoteToolCall]
  public var tools: [RemoteAgentToolProgress]
  public var metrics: RemoteAgentMetrics

  public init(
    text: String, streamingToolCalls: [RemoteToolCall], tools: [RemoteAgentToolProgress],
    metrics: RemoteAgentMetrics = RemoteAgentMetrics()
  ) {
    self.text = text
    self.streamingToolCalls = streamingToolCalls
    self.tools = tools
    self.metrics = metrics
  }
}

public struct RemoteAgentCompletion: Equatable, Sendable {
  public var text: String
  public var tools: [RemoteAgentToolProgress]
  public var metrics: RemoteAgentMetrics

  public init(
    text: String, tools: [RemoteAgentToolProgress],
    metrics: RemoteAgentMetrics = RemoteAgentMetrics()
  ) {
    self.text = text
    self.tools = tools
    self.metrics = metrics
  }
}

public final class RemoteAgent {
  public typealias ToolExecutor = (
    _ call: RemoteToolCall, _ progress: @escaping (String) -> Void,
    _ completion: @escaping (RemoteToolExecutionResult) -> Void
  ) -> (() -> Void)?

  private enum RequestPurpose {
    case model(encodedBytes: Int, estimatedTokens: Int)
    case compaction(RemoteCompactionRequest)
  }

  private enum RecoveryAction {
    case retry
    case retryAfter(TimeInterval)
    case finish(RemoteChatError)
  }

  private final class Generation {
    let progress: (RemoteAgentProgress) -> Void
    let completion: (Result<RemoteAgentCompletion, RemoteChatError>) -> Void
    var round = 0
    var requestIdentifier = 0
    var completedRequestIdentifier = 0
    var request: RemoteRequestCancellable?
    var completedText = [String]()
    var currentText = ""
    var streamingToolCalls = [RemoteToolCall]()
    var toolProgress = [RemoteAgentToolProgress]()
    var pendingToolCalls = [RemoteToolCall]()
    var pendingToolIndex = 0
    var toolCancellation: (() -> Void)?
    var compactionsForNextRequest = 0
    var bypassCompaction = false
    var forceCompaction = false
    var contextRecoveryAttempts = 0
    var requestRetryCount = 0
    var toolArgumentRegenerationAttempts = 0
    var requestStartedAt: TimeInterval?
    var firstOutputAt: TimeInterval?
    var totalTimeToFirstToken: TimeInterval = 0
    var timedRequestCount = 0
    var totalCompletionTokens: Double = 0
    var totalRequestDuration: TimeInterval = 0
    var hasEstimatedCompletionTokens = false
    var currentEstimatedCompletionTokens: Double?
    var currentRequestDuration: TimeInterval?

    init(
      progress: @escaping (RemoteAgentProgress) -> Void,
      completion: @escaping (Result<RemoteAgentCompletion, RemoteChatError>) -> Void
    ) {
      self.progress = progress
      self.completion = completion
    }

    var visibleText: String {
      (completedText + (currentText.isEmpty ? [] : [currentText])).joined(separator: "\n\n")
    }

    var metrics: RemoteAgentMetrics {
      let currentTimeToFirstToken: TimeInterval? =
        requestIdentifier != completedRequestIdentifier
        ? requestStartedAt.flatMap { requestStartedAt in
          firstOutputAt.map { $0 - requestStartedAt }
        } : nil
      let currentCompletionTokens =
        requestIdentifier != completedRequestIdentifier ? currentEstimatedCompletionTokens : nil
      let currentDuration =
        requestIdentifier != completedRequestIdentifier && currentCompletionTokens != nil
        ? currentRequestDuration : nil
      let completionTokens = totalCompletionTokens + (currentCompletionTokens ?? 0)
      let requestDuration = totalRequestDuration + (currentDuration ?? 0)
      return RemoteAgentMetrics(
        averageTimeToFirstToken: timedRequestCount > 0 || currentTimeToFirstToken != nil
          ? (totalTimeToFirstToken + (currentTimeToFirstToken ?? 0))
            / Double(timedRequestCount + (currentTimeToFirstToken == nil ? 0 : 1)) : nil,
        observedOutputTokensPerSecond: completionTokens > 0 && requestDuration > 0
          ? completionTokens / requestDuration : nil,
        isOutputRateEstimated: hasEstimatedCompletionTokens || currentCompletionTokens != nil)
    }

    var progressSnapshot: RemoteAgentProgress {
      RemoteAgentProgress(
        text: visibleText, streamingToolCalls: streamingToolCalls, tools: toolProgress,
        metrics: metrics)
    }
  }

  private static let interruptedTurn =
    "[The previous remote-agent turn ended before a complete model response was received.]"
  private static let maximumToolArgumentRegenerationAttempts = 2

  private let lock = NSLock()
  private let contextQueue = DispatchQueue(
    label: "com.liuliu.local-code.remote-agent.context", qos: .utility)
  private let provider: RemoteChatProviding
  private let systemPrompt: String
  private let tools: [RemoteFunctionTool]
  private let configuration: RemoteAgentConfiguration
  private let stateDidChange: () -> Void
  private let timeProvider: () -> TimeInterval
  private let toolExecutor: ToolExecutor
  private var storedState: RemoteAgentState
  private var activeGeneration: Generation?
  private var statusRevision = 0
  private var cachedStatus: (revision: Int, status: RemoteAgentStatus)?

  public init(
    provider: RemoteChatProviding, systemPrompt: String, tools: [RemoteFunctionTool],
    configuration: RemoteAgentConfiguration = RemoteAgentConfiguration(),
    state: RemoteAgentState = RemoteAgentState(),
    stateDidChange: @escaping () -> Void = {},
    timeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    toolExecutor: @escaping ToolExecutor
  ) {
    self.provider = provider
    self.systemPrompt = systemPrompt
    self.tools = tools
    self.configuration = configuration
    self.stateDidChange = stateDidChange
    self.timeProvider = timeProvider
    self.toolExecutor = toolExecutor
    storedState = RemoteContext.normalized(
      state, configuredContextWindowTokens: configuration.contextWindowTokens)
  }

  public var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeGeneration != nil
  }

  public var state: RemoteAgentState {
    lock.lock()
    defer { lock.unlock() }
    return storedState
  }

  public func status(completion: @escaping (RemoteAgentStatus) -> Void) {
    contextQueue.async { [weak self] in
      guard let self else { return }
      completion(currentStatus())
    }
  }

  private func currentStatus() -> RemoteAgentStatus {
    let state: RemoteAgentState
    let currentRound: Int?
    let revision: Int
    lock.lock()
    if let cachedStatus {
      if cachedStatus.revision == statusRevision {
        lock.unlock()
        return cachedStatus.status
      }
    }
    state = storedState
    currentRound = activeGeneration?.round
    revision = statusRevision
    lock.unlock()

    let preparedContext = RemoteContext.preparedContext(
      state: state, systemPrompt: systemPrompt, tools: tools, configuration: configuration)
    let status = makeStatus(
      state: state, currentRound: currentRound, preparedContext: preparedContext)
    lock.lock()
    if revision == statusRevision {
      cachedStatus = (revision, status)
    }
    lock.unlock()
    return status
  }

  private func makeStatus(
    state: RemoteAgentState, currentRound: Int?, preparedContext: RemotePreparedContext
  ) -> RemoteAgentStatus {
    let effectiveContextWindowTokens =
      state.effectiveContextWindowTokens ?? configuration.contextWindowTokens
    let compactionReserveTokens = RemoteContext.compactionReserveTokens(
      contextWindowTokens: effectiveContextWindowTokens)
    return RemoteAgentStatus(
      estimatedContextTokens: preparedContext.estimatedTokens,
      configuredContextWindowTokens: configuration.contextWindowTokens,
      effectiveContextWindowTokens: effectiveContextWindowTokens,
      compactionThresholdTokens: RemoteContext.compactionThresholdTokens(
        contextWindowTokens: effectiveContextWindowTokens, configuration: configuration),
      compactionReserveTokens: compactionReserveTokens,
      reservedOutputTokens: configuration.reservedOutputTokens,
      transcriptMessageCount: state.transcript.count,
      maximumRounds: configuration.maximumRounds,
      currentRound: currentRound)
  }

  public func send(
    _ userMessage: String, images: [RemoteImage] = [],
    progress: @escaping (RemoteAgentProgress) -> Void,
    completion: @escaping (Result<RemoteAgentCompletion, RemoteChatError>) -> Void
  ) {
    lock.lock()
    guard activeGeneration == nil else {
      lock.unlock()
      completion(.failure(.alreadyRunning))
      return
    }
    guard
      provider.supportsImageInput
        || (images.isEmpty && storedState.transcript.allSatisfy({ $0.images.isEmpty }))
    else {
      lock.unlock()
      completion(.failure(.imageInputUnsupported))
      return
    }
    storedState.transcript.append(.user(userMessage, images: images))
    let generation = Generation(progress: progress, completion: completion)
    activeGeneration = generation
    statusRevision += 1
    lock.unlock()
    stateDidChange()
    schedulePrepareRequest(for: generation)
  }

  public func cancel() {
    let request: RemoteRequestCancellable?
    let toolCancellation: (() -> Void)?
    let completion: ((Result<RemoteAgentCompletion, RemoteChatError>) -> Void)?
    lock.lock()
    if let generation = activeGeneration {
      request = generation.request
      toolCancellation = generation.toolCancellation
      generation.toolCancellation = nil
      completion = generation.completion
      closeIncompleteTurn(generation, note: Self.interruptedTurn)
      activeGeneration = nil
      statusRevision += 1
    } else {
      request = nil
      toolCancellation = nil
      completion = nil
    }
    lock.unlock()
    request?.cancel()
    toolCancellation?()
    if completion != nil { stateDidChange() }
    completion?(.failure(.cancelled))
  }

  private func prepareRequest(for generation: Generation) {
    let state: RemoteAgentState
    let revision: Int
    let forceCompaction: Bool
    let bypassCompaction: Bool
    let compactionsForNextRequest: Int
    let round: Int
    let previousRequestIdentifier: Int
    lock.lock()
    guard activeGeneration === generation, generation.request == nil else {
      lock.unlock()
      return
    }
    state = storedState
    revision = statusRevision
    forceCompaction = generation.forceCompaction
    bypassCompaction = generation.bypassCompaction
    compactionsForNextRequest = generation.compactionsForNextRequest
    round = generation.round
    previousRequestIdentifier = generation.requestIdentifier
    lock.unlock()

    let requestIdentifier: Int

    let prepared = RemoteContext.preparedContext(
      state: state, systemPrompt: systemPrompt, tools: tools, configuration: configuration)
    let compactionRequest = RemoteContext.compactionRequest(
      state: state, preparedContext: prepared, systemPrompt: systemPrompt, tools: tools,
      configuration: configuration, force: forceCompaction)
    let compactionToStart =
      !bypassCompaction
        && compactionsForNextRequest < configuration.maximumCompactionsPerRequest
      ? compactionRequest : nil
    let immediateFailure: RemoteChatError?
    if compactionToStart != nil {
      immediateFailure = nil
    } else if RemoteContext.isHardLimitExceeded(
      prepared, state: state, configuration: configuration)
    {
      immediateFailure =
        compactionRequest == nil
        ? .contextLimitReached
        : .compactionFailed(
          "Repeated compaction did not restore enough context capacity.")
    } else if round >= configuration.maximumRounds {
      immediateFailure = .roundLimitReached(maximumRounds: configuration.maximumRounds)
    } else {
      immediateFailure = nil
    }

    lock.lock()
    guard activeGeneration === generation, generation.request == nil,
      statusRevision == revision, generation.forceCompaction == forceCompaction,
      generation.bypassCompaction == bypassCompaction,
      generation.compactionsForNextRequest == compactionsForNextRequest,
      generation.round == round,
      generation.requestIdentifier == previousRequestIdentifier
    else {
      let shouldRetry = activeGeneration === generation && generation.request == nil
      lock.unlock()
      if shouldRetry {
        schedulePrepareRequest(for: generation)
      }
      return
    }
    cachedStatus = (
      revision,
      makeStatus(state: state, currentRound: round, preparedContext: prepared)
    )
    if compactionToStart != nil {
      generation.compactionsForNextRequest += 1
      generation.forceCompaction = false
    } else if immediateFailure == nil {
      generation.currentText = ""
      generation.streamingToolCalls = []
    }
    generation.requestIdentifier += 1
    requestIdentifier = generation.requestIdentifier
    lock.unlock()

    if let immediateFailure {
      finishGeneration(generation, error: immediateFailure)
      return
    }
    if let compactionToStart {
      startRequest(
        messages: compactionToStart.messages, tools: [], purpose: .compaction(compactionToStart),
        generation: generation, requestIdentifier: requestIdentifier)
    } else {
      startRequest(
        messages: prepared.messages, tools: tools,
        purpose: .model(
          encodedBytes: prepared.encodedBytes, estimatedTokens: prepared.estimatedTokens),
        generation: generation, requestIdentifier: requestIdentifier)
    }
  }

  private func startRequest(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool], purpose: RequestPurpose,
    generation: Generation, requestIdentifier: Int
  ) {
    if case .model = purpose {
      let requestStartedAt = timeProvider()
      lock.lock()
      guard activeGeneration === generation,
        generation.requestIdentifier == requestIdentifier
      else {
        lock.unlock()
        return
      }
      generation.requestStartedAt = requestStartedAt
      generation.firstOutputAt = nil
      generation.currentEstimatedCompletionTokens = nil
      generation.currentRequestDuration = nil
      lock.unlock()
    }
    let request = provider.streamChat(
      messages: messages, tools: tools,
      progress: { [weak self] progress in
        self?.handleProgress(
          progress, purpose: purpose, generation: generation,
          requestIdentifier: requestIdentifier)
      },
      completion: { [weak self] result in
        self?.handleResult(
          result, purpose: purpose, generation: generation,
          requestIdentifier: requestIdentifier)
      })
    lock.lock()
    if activeGeneration === generation,
      generation.requestIdentifier == requestIdentifier,
      generation.completedRequestIdentifier != requestIdentifier
    {
      generation.request = request
      lock.unlock()
    } else {
      lock.unlock()
      request.cancel()
    }
  }

  private func handleProgress(
    _ progress: RemoteStreamProgress, purpose: RequestPurpose, generation: Generation,
    requestIdentifier: Int
  ) {
    guard case .model = purpose else { return }
    let progressAt = timeProvider()
    let callback: ((RemoteAgentProgress) -> Void)?
    let snapshot: RemoteAgentProgress?
    lock.lock()
    if activeGeneration === generation,
      generation.requestIdentifier == requestIdentifier
    {
      if generation.firstOutputAt == nil, progress.hasMeaningfulOutput {
        generation.firstOutputAt = progressAt
      }
      if let requestStartedAt = generation.requestStartedAt,
        progress.estimatedOutputBytes > 0, progressAt > requestStartedAt
      {
        generation.currentEstimatedCompletionTokens =
          Double(progress.estimatedOutputBytes) * (storedState.tokenPerByte ?? (1.0 / 3.0))
        generation.currentRequestDuration = progressAt - requestStartedAt
      }
      generation.currentText = progress.text
      generation.streamingToolCalls = progress.toolCalls
      callback = generation.progress
      snapshot = generation.progressSnapshot
    } else {
      callback = nil
      snapshot = nil
    }
    lock.unlock()
    if let callback, let snapshot { callback(snapshot) }
  }

  private func handleResult(
    _ result: Result<RemoteCompletion, RemoteChatError>, purpose: RequestPurpose,
    generation: Generation, requestIdentifier: Int
  ) {
    switch purpose {
    case .compaction(let request):
      handleCompactionResult(
        result, request: request, generation: generation, requestIdentifier: requestIdentifier)
    case .model(let encodedBytes, let estimatedTokens):
      handleModelResult(
        result, encodedBytes: encodedBytes, estimatedTokens: estimatedTokens,
        generation: generation, requestIdentifier: requestIdentifier)
    }
  }

  private func handleCompactionResult(
    _ result: Result<RemoteCompletion, RemoteChatError>, request: RemoteCompactionRequest,
    generation: Generation, requestIdentifier: Int
  ) {
    var action: RecoveryAction
    lock.lock()
    guard activeGeneration === generation,
      generation.requestIdentifier == requestIdentifier
    else {
      lock.unlock()
      return
    }
    generation.request = nil
    generation.completedRequestIdentifier = requestIdentifier
    switch result {
    case .success(let completion):
      if let promptTokens = completion.usage?.promptTokens {
        storedState.tokenPerByte = RemoteContext.calibratedTokenPerByte(
          promptTokens: promptTokens, encodedBytes: request.encodedBytes,
          previous: storedState.tokenPerByte)
      }
      let completionError: RemoteChatError?
      if let stopReason = completion.stopReason?.lowercased(),
        ["length", "max_tokens", "max_output_tokens", "content_filter", "error"].contains(
          stopReason)
      {
        completionError = .incompleteResponse(stopReason)
      } else if !completion.toolCalls.isEmpty {
        completionError = .compactionFailed(
          "The checkpoint request unexpectedly returned a tool call.")
      } else {
        completionError = nil
      }
      if let completionError {
        action = recover(
          from: completionError, estimatedTokens: request.estimatedTokens,
          generation: generation, compactionRequest: request)
      } else if let updated = RemoteContext.state(
        byApplying: completion.text, request: request, to: storedState,
        systemPrompt: systemPrompt,
        tools: tools, configuration: configuration)
      {
        storedState = updated
        generation.requestRetryCount = 0
        generation.bypassCompaction = false
        action = .retry
      } else {
        let error = RemoteChatError.compactionFailed(
          "The generated checkpoint was empty, oversized, or did not reduce context.")
        action = recover(
          from: error, estimatedTokens: request.estimatedTokens, generation: generation,
          compactionRequest: request)
      }
    case .failure(let error):
      action = recover(
        from: error, estimatedTokens: request.estimatedTokens, generation: generation,
        compactionRequest: request)
    }
    statusRevision += 1
    lock.unlock()

    stateDidChange()
    switch action {
    case .retry:
      schedulePrepareRequest(for: generation)
    case .retryAfter(let delay):
      scheduleRetry(generation, requestIdentifier: requestIdentifier, delay: delay)
    case .finish(let error):
      finishGeneration(generation, error: error)
    }
  }

  private func handleModelResult(
    _ result: Result<RemoteCompletion, RemoteChatError>, encodedBytes: Int,
    estimatedTokens: Int, generation: Generation, requestIdentifier: Int
  ) {
    switch result {
    case .failure(let error):
      lock.lock()
      guard activeGeneration === generation,
        generation.requestIdentifier == requestIdentifier
      else {
        lock.unlock()
        return
      }
      generation.request = nil
      generation.completedRequestIdentifier = requestIdentifier
      let previousStatusRevision = statusRevision
      let action = recover(
        from: error, estimatedTokens: estimatedTokens, generation: generation)
      let stateChanged = statusRevision != previousStatusRevision
      lock.unlock()
      if stateChanged { stateDidChange() }
      switch action {
      case .retry:
        schedulePrepareRequest(for: generation)
      case .retryAfter(let delay):
        scheduleRetry(generation, requestIdentifier: requestIdentifier, delay: delay)
      case .finish(let error):
        finishGeneration(generation, error: error)
      }
    case .success(let completion):
      handleModelCompletion(
        completion, encodedBytes: encodedBytes, generation: generation,
        requestIdentifier: requestIdentifier)
    }
  }

  private func handleModelCompletion(
    _ receivedCompletion: RemoteCompletion, encodedBytes: Int, generation: Generation,
    requestIdentifier: Int
  ) {
    let completedAt = timeProvider()
    var completion = receivedCompletion
    let validatesOpenRouterReasoning =
      provider.modelIdentity.provider == RemoteProvider.openRouter.rawValue
      || provider.modelIdentity.provider == RemoteProvider.localCode.rawValue
    let hasMalformedReasoningDetails =
      validatesOpenRouterReasoning
      && completion.content.remoteThinking.contains {
        guard let metadata = $0.providerMetadata else { return false }
        return !metadata.allSatisfy(\.isValidOpenRouterReasoningDetail)
      }
    if hasMalformedReasoningDetails {
      completion.content.removeAll { block in
        if case .thinking = block { return true }
        return false
      }
    }
    var progressCallback: ((RemoteAgentProgress) -> Void)?
    var progressSnapshot: RemoteAgentProgress?
    var completionCallback: ((Result<RemoteAgentCompletion, RemoteChatError>) -> Void)?
    var completionResult: Result<RemoteAgentCompletion, RemoteChatError>?
    var shouldExecuteTools = false
    var shouldRegenerateToolArguments = false

    lock.lock()
    guard activeGeneration === generation,
      generation.requestIdentifier == requestIdentifier
    else {
      lock.unlock()
      return
    }
    generation.request = nil
    generation.completedRequestIdentifier = requestIdentifier
    if generation.firstOutputAt == nil, completion.content.hasMeaningfulRemoteOutput {
      generation.firstOutputAt = completedAt
    }
    if let requestStartedAt = generation.requestStartedAt,
      let firstOutputAt = generation.firstOutputAt, firstOutputAt >= requestStartedAt
    {
      generation.totalTimeToFirstToken += firstOutputAt - requestStartedAt
      generation.timedRequestCount += 1
    }
    if let requestStartedAt = generation.requestStartedAt, completedAt > requestStartedAt {
      if let completionTokens = completion.usage?.completionTokens, completionTokens > 0 {
        generation.totalCompletionTokens += Double(completionTokens)
        generation.totalRequestDuration += completedAt - requestStartedAt
      } else if let completionTokens = generation.currentEstimatedCompletionTokens,
        completionTokens > 0
      {
        generation.totalCompletionTokens += completionTokens
        generation.totalRequestDuration += completedAt - requestStartedAt
        generation.hasEstimatedCompletionTokens = true
      }
    }
    if let promptTokens = completion.usage?.promptTokens {
      storedState.tokenPerByte = RemoteContext.calibratedTokenPerByte(
        promptTokens: promptTokens, encodedBytes: encodedBytes,
        previous: storedState.tokenPerByte)
    }
    generation.round += 1
    generation.requestRetryCount = 0
    generation.compactionsForNextRequest = 0
    generation.bypassCompaction = false
    generation.forceCompaction = false
    generation.currentText = completion.text
    generation.streamingToolCalls = completion.toolCalls
    progressCallback = generation.progress

    if hasMalformedReasoningDetails, !completion.toolCalls.isEmpty {
      closeIncompleteTurn(
        generation,
        note:
          "[The remote provider returned malformed reasoning metadata, so its tool call was not executed.]"
      )
      completionCallback = generation.completion
      completionResult = .failure(
        .malformedStream("reasoning_details did not match the documented OpenRouter schema"))
      activeGeneration = nil
    } else if let stopReason = completion.stopReason?.lowercased(),
      ["length", "max_tokens", "max_output_tokens", "content_filter", "error"].contains(stopReason)
    {
      closeIncompleteTurn(
        generation, note: "[The remote provider stopped this response early: \(stopReason).]")
      completionCallback = generation.completion
      completionResult = .failure(.incompleteResponse(stopReason))
      activeGeneration = nil
    } else {
      let callIDs = completion.toolCalls.map(\.id)
      let validCalls =
        Set(callIDs).count == callIDs.count
        && completion.toolCalls.allSatisfy {
          !$0.id.isEmpty && !$0.name.isEmpty
        }
      if !validCalls {
        closeIncompleteTurn(
          generation, note: "[The remote provider returned malformed or duplicate tool calls.]")
        completionCallback = generation.completion
        completionResult = .failure(
          .malformedStream("tool calls must have unique IDs and non-empty function names"))
        activeGeneration = nil
      } else if completion.toolCalls.contains(where: { !$0.hasJSONObjectArguments }) {
        let invalidToolCalls = completion.toolCalls.filter { !$0.hasJSONObjectArguments }
        let function = invalidToolCalls.map(\.name).joined(separator: ", ")
        storedState.transcript.append(
          RemoteTranscriptEntry(
            role: .assistant, content: completion.content, source: provider.modelIdentity,
            providerOutputItems: completion.providerOutputItems
          ).replacingMalformedToolArguments())
        for call in completion.toolCalls {
          let invalidArguments = !call.hasJSONObjectArguments
          storedState.transcript.append(
            .toolResult(
              RemoteToolError.content(
                type: invalidArguments ? "invalid_arguments" : "cancelled",
                function: call.name,
                message: invalidArguments
                  ? "The model did not produce a well-formed JSON object. Regenerate this tool call with one valid JSON object."
                  : "This call was not run because another tool call in the same model response contained malformed JSON. Regenerate the tool calls."
              ),
              toolCallID: call.id, toolName: call.name, isError: true))
        }
        if !completion.text.isEmpty {
          generation.completedText.append(completion.text)
        }
        generation.currentText = ""
        generation.streamingToolCalls = []
        generation.round -= 1
        if generation.toolArgumentRegenerationAttempts
          < Self.maximumToolArgumentRegenerationAttempts
        {
          generation.toolArgumentRegenerationAttempts += 1
          let attempt = generation.toolArgumentRegenerationAttempts
          generation.toolProgress.append(
            RemoteAgentToolProgress(
              id: "\(invalidToolCalls[0].id)-invalid-arguments-\(attempt)",
              subtitle:
                "Model didn't produce well-formed JSON for \(function); asking it to regenerate (\(attempt)/\(Self.maximumToolArgumentRegenerationAttempts))",
              isCompleted: true))
          shouldRegenerateToolArguments = true
        } else {
          let error = RemoteChatError.invalidToolArguments(function: function)
          closeIncompleteTurn(
            generation,
            note:
              "[The remote model repeatedly returned malformed JSON arguments for \(function).]")
          completionCallback = generation.completion
          completionResult = .failure(error)
          activeGeneration = nil
        }
      } else if completion.toolCalls.isEmpty {
        if completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          closeIncompleteTurn(
            generation, note: "[The remote provider returned an empty response.]")
          completionCallback = generation.completion
          completionResult = .failure(.emptyResponse)
          activeGeneration = nil
        } else {
          storedState.transcript.append(
            RemoteTranscriptEntry(
              role: .assistant, content: completion.content, source: provider.modelIdentity,
              providerOutputItems: completion.providerOutputItems))
          completionCallback = generation.completion
          completionResult = .success(
            RemoteAgentCompletion(
              text: generation.visibleText, tools: generation.toolProgress,
              metrics: generation.metrics))
          activeGeneration = nil
        }
      } else {
        generation.toolArgumentRegenerationAttempts = 0
        storedState.transcript.append(
          RemoteTranscriptEntry(
            role: .assistant, content: completion.content, source: provider.modelIdentity,
            providerOutputItems: completion.providerOutputItems))
        if !completion.text.isEmpty {
          generation.completedText.append(completion.text)
        }
        generation.currentText = ""
        generation.streamingToolCalls = []
        if generation.round >= configuration.maximumRounds {
          for call in completion.toolCalls {
            storedState.transcript.append(
              .toolResult(
                RemoteToolError.content(
                  type: "round_limit_reached", function: call.name,
                  message: "The agent model/tool round limit was reached."),
                toolCallID: call.id, toolName: call.name, isError: true))
          }
          storedState.transcript.append(
            .assistant(
              "[The remote agent stopped because its model/tool round limit was reached.]"))
          completionCallback = generation.completion
          completionResult = .failure(
            .roundLimitReached(maximumRounds: configuration.maximumRounds))
          activeGeneration = nil
        } else {
          generation.pendingToolCalls = completion.toolCalls
          generation.pendingToolIndex = 0
          shouldExecuteTools = true
        }
      }
    }
    progressSnapshot = generation.progressSnapshot
    statusRevision += 1
    lock.unlock()

    stateDidChange()
    if let progressCallback, let progressSnapshot { progressCallback(progressSnapshot) }
    if let completionCallback, let completionResult { completionCallback(completionResult) }
    if shouldRegenerateToolArguments { schedulePrepareRequest(for: generation) }
    if shouldExecuteTools { executeNextTool(for: generation) }
  }

  private func executeNextTool(for generation: Generation) {
    let call: RemoteToolCall
    let progressCallback: (RemoteAgentProgress) -> Void
    let progressSnapshot: RemoteAgentProgress
    lock.lock()
    guard activeGeneration === generation else {
      lock.unlock()
      return
    }
    guard generation.pendingToolIndex < generation.pendingToolCalls.count else {
      lock.unlock()
      schedulePrepareRequest(for: generation)
      return
    }
    call = generation.pendingToolCalls[generation.pendingToolIndex]
    generation.toolProgress.append(
      RemoteAgentToolProgress(id: call.id, subtitle: call.name, isCompleted: false))
    progressCallback = generation.progress
    progressSnapshot = generation.progressSnapshot
    lock.unlock()
    progressCallback(progressSnapshot)

    guard tools.contains(where: { $0.name == call.name }) else {
      completedTool(
        call: call,
        result: RemoteToolExecutionResult(
          content: RemoteToolError.content(
            type: "unavailable_tool", function: call.name,
            message: "This tool was not supplied for this request."),
          subtitle: "Could not run \(call.name)", isError: true),
        generation: generation)
      return
    }
    guard let data = call.arguments.data(using: .utf8),
      let arguments = try? JSONSerialization.jsonObject(with: data),
      arguments is [String: Any]
    else {
      completedTool(
        call: call,
        result: RemoteToolExecutionResult(
          content: RemoteToolError.content(
            type: "invalid_arguments", function: call.name,
            message: "Tool arguments must be a valid JSON object."),
          subtitle: "Could not run \(call.name)", isError: true),
        generation: generation)
      return
    }

    let cancellation = toolExecutor(
      call,
      { [weak self] subtitle in
        guard let self else { return }
        let callback: ((RemoteAgentProgress) -> Void)?
        let snapshot: RemoteAgentProgress?
        lock.lock()
        if activeGeneration === generation,
          !generation.toolProgress.isEmpty
        {
          generation.toolProgress[generation.toolProgress.count - 1].subtitle = subtitle
          callback = generation.progress
          snapshot = generation.progressSnapshot
        } else {
          callback = nil
          snapshot = nil
        }
        lock.unlock()
        if let callback, let snapshot { callback(snapshot) }
      },
      { [weak self] result in
        self?.completedTool(call: call, result: result, generation: generation)
      })
    guard let cancellation else { return }
    lock.lock()
    if activeGeneration === generation {
      if generation.pendingToolIndex < generation.pendingToolCalls.count,
        generation.pendingToolCalls[generation.pendingToolIndex].id == call.id
      {
        generation.toolCancellation = cancellation
      }
      lock.unlock()
    } else {
      lock.unlock()
      cancellation()
    }
  }

  private func completedTool(
    call: RemoteToolCall, result: RemoteToolExecutionResult, generation: Generation
  ) {
    let callback: ((RemoteAgentProgress) -> Void)?
    let snapshot: RemoteAgentProgress?
    lock.lock()
    guard activeGeneration === generation,
      generation.pendingToolIndex < generation.pendingToolCalls.count,
      generation.pendingToolCalls[generation.pendingToolIndex].id == call.id
    else {
      lock.unlock()
      return
    }
    storedState.transcript.append(
      .toolResult(
        result.content, toolCallID: call.id, toolName: call.name, isError: result.isError,
        images: result.images))
    generation.toolCancellation = nil
    if !generation.toolProgress.isEmpty {
      generation.toolProgress[generation.toolProgress.count - 1].subtitle = result.subtitle
      generation.toolProgress[generation.toolProgress.count - 1].isCompleted = true
    }
    generation.pendingToolIndex += 1
    statusRevision += 1
    callback = generation.progress
    snapshot = generation.progressSnapshot
    lock.unlock()
    stateDidChange()
    if let callback, let snapshot { callback(snapshot) }
    executeNextTool(for: generation)
  }

  private func finishGeneration(_ generation: Generation, error: RemoteChatError) {
    let callback: ((Result<RemoteAgentCompletion, RemoteChatError>) -> Void)?
    lock.lock()
    if activeGeneration === generation {
      generation.request = nil
      closeIncompleteTurn(
        generation, note: "[Remote agent error: \(error.localizedDescription)]")
      callback = generation.completion
      activeGeneration = nil
      statusRevision += 1
    } else {
      callback = nil
    }
    lock.unlock()
    if callback != nil { stateDidChange() }
    callback?(.failure(error))
  }

  private func closeIncompleteTurn(_ generation: Generation, note: String) {
    if generation.pendingToolIndex < generation.pendingToolCalls.count {
      for call in generation.pendingToolCalls[generation.pendingToolIndex...] {
        storedState.transcript.append(
          .toolResult(
            RemoteToolError.content(
              type: "cancelled", function: call.name,
              message: "The tool call was not completed."),
            toolCallID: call.id, toolName: call.name, isError: true))
      }
      generation.pendingToolIndex = generation.pendingToolCalls.count
    }
    let partialText = generation.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !partialText.isEmpty {
      storedState.transcript.append(
        .assistant(partialText + "\n\n" + note, source: provider.modelIdentity))
    } else if storedState.transcript.last?.role != .assistant
      || storedState.transcript.last?.toolCalls.isEmpty == false
    {
      storedState.transcript.append(.assistant(note, source: provider.modelIdentity))
    }
  }

  private func recover(
    from error: RemoteChatError, estimatedTokens: Int, generation: Generation,
    compactionRequest: RemoteCompactionRequest? = nil
  ) -> RecoveryAction {
    let duringCompaction = compactionRequest != nil
    if error.indicatesContextLimit, generation.contextRecoveryAttempts < 2,
      reduceContextWindow(estimatedTokens: estimatedTokens)
    {
      generation.contextRecoveryAttempts += 1
      generation.requestRetryCount = 0
      generation.forceCompaction = true
      generation.bypassCompaction = false
      generation.compactionsForNextRequest =
        duringCompaction
        ? max(0, generation.compactionsForNextRequest - 1) : 0
      return .retry
    }
    if error.isRetryableRequestFailure,
      generation.requestRetryCount < configuration.maximumRequestRetries
    {
      generation.requestRetryCount += 1
      if duringCompaction {
        generation.compactionsForNextRequest = max(
          0, generation.compactionsForNextRequest - 1)
      }
      let delay =
        configuration.retryBaseDelay
        * pow(2, Double(generation.requestRetryCount - 1))
      return .retryAfter(delay)
    }
    let terminalProviderFailure: Bool
    switch error {
    case .provider(let statusCode, _):
      terminalProviderFailure =
        statusCode == 401 || statusCode == 402 || statusCode == 403 || statusCode == 429
    case .cancelled:
      terminalProviderFailure = true
    default:
      terminalProviderFailure = false
    }
    if let compactionRequest, !compactionRequest.requiresCapacityRecovery,
      !terminalProviderFailure
    {
      generation.requestRetryCount = 0
      generation.bypassCompaction = true
      return .retry
    }
    return .finish(error)
  }

  private func reduceContextWindow(estimatedTokens: Int) -> Bool {
    let currentWindow =
      storedState.effectiveContextWindowTokens ?? configuration.contextWindowTokens
    let minimumWindow = max(4_096, configuration.reservedOutputTokens * 2)
    let inferredWindow = max(
      minimumWindow, estimatedTokens + configuration.reservedOutputTokens)
    let reducedWindow = max(
      minimumWindow, min(currentWindow - 1, min(currentWindow * 3 / 4, inferredWindow)))
    guard reducedWindow < currentWindow else { return false }
    storedState.effectiveContextWindowTokens = reducedWindow
    statusRevision += 1
    return true
  }

  private func schedulePrepareRequest(for generation: Generation) {
    contextQueue.async { [weak self, weak generation] in
      guard let self, let generation else { return }
      prepareRequest(for: generation)
    }
  }

  private func scheduleRetry(
    _ generation: Generation, requestIdentifier: Int, delay: TimeInterval
  ) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
      [weak self, weak generation] in
      guard let generation else { return }
      guard let self else { return }
      self.lock.lock()
      let shouldRetry =
        self.activeGeneration === generation
        && generation.requestIdentifier == requestIdentifier
      self.lock.unlock()
      if shouldRetry {
        self.schedulePrepareRequest(for: generation)
      }
    }
  }

}
