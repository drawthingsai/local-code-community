import Atomics
import BashToolContext
import DataModels
import Foundation
import NNC

protocol ResponsesAgentDelegate: AnyObject {
  /// Arrives on the generation queue, at most a few times a second.
  func responsesAgent(_ agent: ResponsesAgent, didUpdate progress: ResponsesAgent.Progress)
  /// Arrives on the generation queue, before the scheduler's completion.
  func responsesAgent(_ agent: ResponsesAgent, didFinish summary: ResponsesAgent.Summary)
}

/// Runs one conversation's requests as turns of `AgentScheduler`, which is what shares the generation
/// queue with the chat and the other conversations: a foreground turn pauses it, memory pressure
/// evicts it, and its activity keeps the Mac awake and the model loaded.
///
/// It is never the foreground agent, so the scheduler's progress callback doesn't reach anyone. The
/// agent writes to the client itself and ends the turn itself when the client leaves. The client
/// supplies the conversation and runs the tools, so `ask`'s prompt and project go unused.
final class ResponsesAgent: CodeAgent {
  /// Set before submitting a turn and read on the generation queue once the scheduler runs it.
  struct Request {
    let request: ResponsesRequest
    /// The whole conversation up to and including the assistant's opening tokens.
    let baseTokens: [Int32]
    /// 0 when the model doesn't think.
    let thinkingBudget: Int
    let writer: any ResponseWriter
    let transport: ResponsesTransport
  }

  enum Progress: Equatable {
    case preparing
    case prefilling(finished: Int, total: Int)
    case generating(tokens: Int, tokensPerSecond: Float)
    /// The chat has the model, or the agent gave its memory back to it.
    case paused
  }

  struct Summary: Equatable {
    var usage: ResponseUsage
    var prefillTokensPerSecond: Float
    var generationTokensPerSecond: Float
    /// "completed", "incomplete", "failed" or "cancelled".
    var status: String
    /// What the KV cache holds now, for a later request to continue. Empty if it holds nothing.
    var retainedTokens: [Int32]
  }

  private struct Turn {
    let request: ResponsesRequest
    let writer: any ResponseWriter
    let transport: ResponsesTransport
    let startTokenOffset: Int
    var baseTokens: [Int32]
    let thinkingBudget: Int
    var outputTokens = [Int32]()
    var parser: ResponsesOutputParser
    var parsedTokenCount = 0
    var sentText = ""
    var sentThink = ""
    var sentToolCallCount = 0
    var cachedInputTokens = 0
    var statistics = CodeAgentStatistics()
    var incompleteReason: String?
  }

  weak var delegate: ResponsesAgentDelegate?
  let adapter: any ResponsesModelAdapter
  // Set on the main queue before each turn is submitted.
  var nextRequest: Request?

  // The rest is accessed only on the generation queue.
  private let graph: DynamicGraph
  private let streamContext: StreamContext
  private let timeSlice: TimeInterval
  /// The turns serving has underway, which is what there can be to yield to.
  private let activeTurnCount: ManagedAtomic<Int>
  private var turn: Turn?
  /// The tokens in the KV cache, from the turn before. A request that continues them skips right
  /// to its new tokens; any other starts from the context cache on disk.
  private var cachedTokens = [Int32]()
  private var cachedTokenLength = 0
  private var lastProgressTime = Date.distantPast

  init(
    adapter: any ResponsesModelAdapter, graph: DynamicGraph, streamContext: StreamContext,
    timeSlice: TimeInterval, activeTurnCount: ManagedAtomic<Int>
  ) {
    self.adapter = adapter
    self.graph = graph
    self.streamContext = streamContext
    self.timeSlice = timeSlice
    self.activeTurnCount = activeTurnCount
  }

  // MARK: - CodeAgent members the scheduler doesn't use for this agent.

  let bashUserInteraction = BashUserInteraction()
  var thinkingBudget: Int32 = 0
  var deterministic = false
  var statistics: CodeAgentStatistics { turn?.statistics ?? CodeAgentStatistics() }
  var suspendedResult: CodeAgentResult? { nil }
  var toolCallStart: String { "" }
  var toolCallEnd: String { "" }
  var toolCallSpecialTokens: [Int32: String] { [:] }
  func isCapReachedForStopping(from resultAtStop: CodeAgentResult, to result: CodeAgentResult)
    -> Bool
  { true }
  func canStopImmediately(with result: CodeAgentResult) -> Bool { true }
  func restoreSuspension(threadId: Int64, environment: any CodeAgentEnvironment) throws -> Bool {
    false
  }

  // MARK: - CodeAgent

  func ask(
    _ prompt: String, imagePaths: [String], isMemoryEnabled: Bool, temporary: Bool,
    allowedTools: Set<ToolsRegistry.Tool>?, threadId: Int64,
    environment: any CodeAgentEnvironment,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    guard let nextRequest else { return .empty }
    self.nextRequest = nil
    guard start(nextRequest) else { return .empty }
    return run(progress: progress)
  }

  func resume(
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    // A turn evicted before it ever started resumes as the start it missed.
    if turn == nil, let nextRequest {
      self.nextRequest = nil
      guard start(nextRequest) else { return .empty }
    }
    return run(progress: progress)
  }

  /// The turn lives on in this object, since its client is still connected. Only the memory goes
  /// back, and `run` builds it again from the context cache and the tokens so far.
  func hibernate(threadId: Int64) throws {
    unloadCaches()
    delegate?.responsesAgent(self, didUpdate: .paused)
  }

  func unloadCaches() {
    streamContext.joined()
    adapter.resetCaches()
    cachedTokens = []
    cachedTokenLength = 0
  }

  // MARK: - Generation

  private func start(_ request: Request) -> Bool {
    delegate?.responsesAgent(self, didUpdate: .preparing)
    let wantedThinkingBudget = request.thinkingBudget
    let baseTokens = request.baseTokens
    guard baseTokens.count + adapter.minimumGenerationReserve <= adapter.maximumContextLength else {
      request.writer.fail(
        status: 400, type: "invalid_request_error", code: "context_length_exceeded",
        message:
          "The input is \(baseTokens.count) tokens, and this model takes \(adapter.maximumContextLength - adapter.minimumGenerationReserve). There is no compaction when serving, so the client needs to shorten it."
      )
      finish(
        usage: .init(
          inputTokens: baseTokens.count, cachedInputTokens: 0, outputTokens: 0, reasoningTokens: 0),
        status: "failed", statistics: CodeAgentStatistics())
      return false
    }
    let thinkingBudget =
      wantedThinkingBudget > 0
      ? min(
        wantedThinkingBudget,
        max(1, adapter.maximumContextLength - baseTokens.count - adapter.minimumGenerationReserve))
      : 0
    if !(cachedTokenLength > 0 && baseTokens.count > cachedTokenLength
      && baseTokens.starts(with: cachedTokens))
    {
      unloadCaches()
    }
    request.writer.startTurn(inputTokens: baseTokens.count, cachedInputTokens: cachedTokenLength)
    DynamicGraph.setSeed(
      ContextCachePrefixHasher.hash(tokens: baseTokens).prefix(4).reduce(UInt32(0)) {
        ($0 << 8) | UInt32($1)
      })
    turn = Turn(
      request: request.request, writer: request.writer, transport: request.transport,
      startTokenOffset: cachedTokenLength, baseTokens: baseTokens, thinkingBudget: thinkingBudget,
      parser: adapter.makeOutputParser(isThinking: thinkingBudget > 0))
    return true
  }

  private func run(
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    guard var turn else { return .empty }
    self.turn = nil
    let oldFlags = DynamicGraph.flags
    defer { DynamicGraph.flags = oldFlags }
    applyInferenceBackendFlags()

    let existingOutputTokens = turn.outputTokens
    let outputTokensBeforeDecode: [Int32]
    let inputTokens: [Int32]
    let tokenOffset: Int
    let contextTokens: [Int32]
    if cachedTokenLength >= turn.baseTokens.count,
      cachedTokenLength - turn.baseTokens.count <= existingOutputTokens.count,
      cachedTokenLength < turn.baseTokens.count + existingOutputTokens.count
    {
      // Hot: a pause keeps one token predicted but not yet evaluated.
      tokenOffset = cachedTokenLength
      inputTokens = Array(
        existingOutputTokens.dropFirst(cachedTokenLength - turn.baseTokens.count))
      contextTokens = turn.baseTokens + existingOutputTokens
      outputTokensBeforeDecode = existingOutputTokens
    } else {
      // Starting, paused in the prefill, or evicted: every token already sent to the client is part
      // of the context, so a stochastic decode can't take back what the client read.
      if cachedTokenLength >= turn.baseTokens.count {
        unloadCaches()
      }
      tokenOffset = cachedTokenLength
      contextTokens = turn.baseTokens + existingOutputTokens
      inputTokens = Array(contextTokens.dropFirst(cachedTokenLength))
      outputTokensBeforeDecode = existingOutputTokens
    }

    var didPause = false
    var didStop = false
    var didFinishGenerating = false
    var seenGeneratedTokenCount = 0
    let baseTokenCount = turn.baseTokens.count
    let maximumOutputTokens = turn.request.maximumOutputTokens
    // Drafting and pauses can hand back several tokens at once. Those past the limit are neither
    // sent nor kept.
    let outputLimit = maximumOutputTokens ?? Int.max
    let isEvaluatingPendingGeneratedTokens =
      !existingOutputTokens.isEmpty && tokenOffset >= baseTokenCount
    let safeStopThreshold = adapter.maximumContextLength - 4_096
    var sliceDeadline = Date().addingTimeInterval(timeSlice)
    // The scheduler pauses it if someone else can run, and lets it carry on if not. Only other
    // requests are worth asking for, so that a background chat turn doesn't get to pre-empt a
    // request.
    func shouldYield() -> Bool {
      let now = Date()
      guard now >= sliceDeadline, activeTurnCount.load(ordering: .relaxed) > 1 else { return false }
      sliceDeadline = now.addingTimeInterval(timeSlice)
      return progress(.timeSliceEnded, turn.statistics) == .pause
    }
    let tokensGPU = graph.variable(Tensor<Int32>(inputTokens).toGPU(0))
    // The generators count the budget from the start of each decode, and only see the thinking end
    // within it. So a resume gets what's left of it, or none once the thinking is over. At 0 they
    // take the model to be answering, so a budget used up is 1, which ends the thinking right away.
    let thinkingBudget =
      turn.parser.isThinkingOpen ? max(1, turn.thinkingBudget - turn.parser.thinkTokenCount) : 0
    let generated = graph.withStream(streamContext) {
      graph.withNoGrad {
        adapter.decode(
          graph: graph, tokens: tokensGPU, tokenOffset: tokenOffset, contextTokens: contextTokens,
          thinkingBudget: thinkingBudget, deterministic: turn.request.isDeterministic
        ) { prefillStart, prefillLength, generatedTokens, statistics in
          turn.statistics = statistics
          guard !turn.transport.isDisconnected else {
            didStop = true
            return .abort
          }
          guard !generatedTokens.isEmpty else {
            if isEvaluatingPendingGeneratedTokens { return .continue }
            report(.prefilling(finished: prefillStart, total: prefillLength))
            let decision = progress(.prefill([], prefillStart, prefillLength), statistics)
            if decision == .pause { didPause = true }
            if decision == .abort { didStop = true }
            if decision == .continue, shouldYield() {
              didPause = true
              return .pause
            }
            return decision
          }
          let keptTokenCount = min(
            generatedTokens.count, max(0, outputLimit - outputTokensBeforeDecode.count))
          if keptTokenCount > seenGeneratedTokenCount {
            turn.parser.append(Array(generatedTokens[seenGeneratedTokenCount..<keptTokenCount]))
            turn.parsedTokenCount = outputTokensBeforeDecode.count + keptTokenCount
            seenGeneratedTokenCount = keptTokenCount
            sendNewOutput(&turn)
          }
          let outputCount = outputTokensBeforeDecode.count + keptTokenCount
          report(
            .generating(tokens: outputCount, tokensPerSecond: statistics.tokenGeneratedPerSecond))
          // Ahead of the scheduler's say, as a pause would hand back yet another token.
          if outputCount >= outputLimit {
            turn.incompleteReason = "max_output_tokens"
            didFinishGenerating = true
            return .abort
          }
          let decision = progress(.generate(.empty), statistics)
          if decision == .pause {
            didPause = true
            return .pause
          }
          if decision == .abort {
            didStop = true
            return .abort
          }
          if baseTokenCount + outputCount > safeStopThreshold {
            turn.incompleteReason = "max_context_length"
            didFinishGenerating = true
            return .abort
          }
          if turn.parser.didCompleteToolCalls {
            didFinishGenerating = true
            return .abort
          }
          if shouldYield() {
            didPause = true
            return .pause
          }
          return .continue
        }
      }
    }
    streamContext.joined()
    // From the caches themselves: what the callbacks saw doesn't always say how far they got.
    cachedTokenLength = adapter.kvCacheTokenLength
    turn.outputTokens = Array((outputTokensBeforeDecode + generated).prefix(outputLimit))
    if turn.outputTokens.count > turn.parsedTokenCount {
      turn.parser.append(Array(turn.outputTokens[turn.parsedTokenCount...]))
      turn.parsedTokenCount = turn.outputTokens.count
    }
    // Restoring after an eviction can bring back some of the output too, which isn't input.
    if tokenOffset == 0, let restored = adapter.restoredTokenLength {
      turn.cachedInputTokens = max(turn.cachedInputTokens, min(restored, turn.baseTokens.count))
    }

    // A pause hands back the prediction it didn't evaluate yet. If that's the end, the turn is over:
    // resuming would feed it to the model, which would carry on past it.
    let didPauseAtEnd = didPause && turn.outputTokens.last.map { adapter.isTerminal($0) } == true
    // So is one whose pause took it to the limit.
    let didPauseAtLimit = didPause && !didPauseAtEnd && turn.outputTokens.count >= outputLimit
    if didPauseAtLimit {
      turn.incompleteReason = "max_output_tokens"
      didFinishGenerating = true
    }
    if didPause, !didPauseAtEnd, !didPauseAtLimit {
      self.turn = turn
      delegate?.responsesAgent(self, didUpdate: .paused)
      return .empty
    }
    let usage = ResponseUsage(
      inputTokens: baseTokenCount,
      cachedInputTokens: max(turn.startTokenOffset, turn.cachedInputTokens),
      outputTokens: turn.outputTokens.count, reasoningTokens: turn.parser.thinkTokenCount)
    let lastToken = turn.outputTokens.last
    // Stopping partway through a drafted block can leave the caches past what came back, which no
    // request could continue.
    let canKeepCache = cachedTokenLength <= turn.baseTokens.count + turn.outputTokens.count
    if canKeepCache, !didStop, !didFinishGenerating, turn.outputTokens.count > 1, let lastToken,
      adapter.isTerminal(lastToken)
    {
      // Ended by itself, with the end gone through the model or, handed back at a pause, not.
      cachedTokens = Array((turn.baseTokens + turn.outputTokens).prefix(cachedTokenLength))
    } else if canKeepCache, !didStop, turn.incompleteReason == nil, turn.parser.didCompleteToolCalls
    {
      // Stopped by us after its tool calls, so the KV cache holds what it evaluated up to there.
      cachedTokens = Array((turn.baseTokens + turn.outputTokens).prefix(cachedTokenLength))
    } else {
      unloadCaches()
    }
    if didStop || turn.transport.isDisconnected {
      turn.writer.abandon()
      finish(usage: usage, status: "cancelled", statistics: turn.statistics)
    } else if turn.outputTokens.isEmpty {
      turn.writer.fail(
        status: 500, type: "server_error", code: "model_error",
        message: "The model produced no output.")
      finish(usage: usage, status: "failed", statistics: turn.statistics)
    } else {
      turn.parser.finish()
      // Text held back as the possible start of a tool call turned out to be text.
      sendNewOutput(&turn)
      // Ahead of the client's last event, so its follow-up finds what this agent retained.
      finish(
        usage: usage, status: turn.incompleteReason == nil ? "completed" : "incomplete",
        statistics: turn.statistics)
      turn.writer.finish(usage: usage, incompleteReason: turn.incompleteReason)
    }
    return .empty
  }

  /// Sends what the parser has beyond what the client already got. It counts Unicode scalars, not
  /// characters: a combining mark joins the character before it, which the client may already have.
  private func sendNewOutput(_ turn: inout Turn) {
    let think = turn.parser.think
    let sentThinkLength = turn.sentThink.unicodeScalars.count
    if think.unicodeScalars.count > sentThinkLength {
      turn.writer.appendReasoning(String(think.unicodeScalars.dropFirst(sentThinkLength)))
      turn.sentThink = think
    }
    let text = turn.parser.visibleText
    let sentTextLength = turn.sentText.unicodeScalars.count
    if text.unicodeScalars.count > sentTextLength,
      text.unicodeScalars.starts(with: turn.sentText.unicodeScalars)
    {
      turn.writer.appendText(String(text.unicodeScalars.dropFirst(sentTextLength)))
      turn.sentText = text
    }
    let toolCalls = turn.parser.toolCalls
    for toolCall in toolCalls.dropFirst(turn.sentToolCallCount) {
      turn.writer.appendFunctionCall(
        name: toolCall.request.function, arguments: turn.request.arguments(of: toolCall))
    }
    turn.sentToolCallCount = toolCalls.count
  }

  private func report(_ progress: Progress) {
    let now = Date()
    guard now.timeIntervalSince(lastProgressTime) >= 0.25 else { return }
    lastProgressTime = now
    delegate?.responsesAgent(self, didUpdate: progress)
  }

  private func finish(
    usage: ResponseUsage, status: String, statistics: CodeAgentStatistics
  ) {
    delegate?.responsesAgent(
      self,
      didFinish: Summary(
        usage: usage, prefillTokensPerSecond: statistics.prefillTokensPerSecond,
        generationTokensPerSecond: statistics.tokenGeneratedPerSecond, status: status,
        retainedTokens: cachedTokens))
  }

  /// The inference backend settings every agent runs under.
  private func applyInferenceBackendFlags() {
    let isMFAEnabled = DeviceCapability.isMFAEnabled.load(ordering: .acquiring) > 0
    if !isMFAEnabled {
      DynamicGraph.flags.insert(.disableMFA)
      return
    }
    DynamicGraph.flags.remove(.disableMFA)
    if !DeviceCapability.isMFAGEMMFaster {
      DynamicGraph.flags.insert(.disableMFAGEMM)
    }
    if !DeviceCapability.isMFAAttentionFaster {
      DynamicGraph.flags.insert(.disableMFAAttention)
    }
    switch DeviceCapability.appleNeuralEngineState.load(ordering: .acquiring) {
    case .disabled:
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    case .appleNeuralEngineOnly:
      DynamicGraph.flags.remove(.disableMFAAppleNeuralEngine)
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngineAndGpu)
    case .appleNeuralEngineAndGPU:
      DynamicGraph.flags.remove(.disableMFAAppleNeuralEngine)
      DynamicGraph.flags.remove(.disableMFAAppleNeuralEngineAndGpu)
    }
  }
}
