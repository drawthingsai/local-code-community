import Atomics
import BashToolContext
import DataModels
import Dispatch
import Foundation
import LLM
import NNC
import ProjectHistoryManager
import Tokenizer
import WebSearch
import os.lock

extension Qwen3_5CodeAgent {
  public enum ReasoningEffort: Int {
    case low
    case medium
    case xhigh

    init(_ reasoningEffort: CodeAgentReasoningEffort) {
      switch reasoningEffort {
      case .low:
        self = .low
      case .medium:
        self = .medium
      case .high, .max:
        self = .xhigh
      }
    }

    func emitSections(_ sections: [SystemPromptSection]) -> [SystemPromptSection] {
      let instructions: String?
      switch self {
      case .low:
        instructions =
          "Reasoning effort is set to low. Keep your thinking brief and focused, moving directly to the conclusion without unnecessary elaboration.\n\n"
      case .medium:
        instructions = nil
      case .xhigh:
        instructions =
          "Reasoning effort is set to xhigh. Please think carefully through the task, validate key assumptions, consider plausible alternatives, and prioritize correctness, consistency, and clarity in the final answer.\n\n"
      }
      return sections.map { section in
        let parts = section.text.components(separatedBy: "{{REASONING_EFFORT}}")
        guard parts.count == 2 else { return section }
        if let instructions {
          return (parts[0] + instructions + parts[1], section.allowsSpecialTokens)
        } else {
          return (parts[0] + parts[1], section.allowsSpecialTokens)
        }
      }
    }
  }

  public func isCapReachedForStopping(
    from resultAtStop: CodeAgentResult, to result: CodeAgentResult
  ) -> Bool {
    let thinkAtStop = resultAtStop.think
    let outputAtStop = resultAtStop.output
    let additionalThink =
      result.think.hasPrefix(thinkAtStop)
      ? result.think.dropFirst(thinkAtStop.count) : result.think[...]
    let additionalOutput =
      result.output.hasPrefix(outputAtStop)
      ? result.output.dropFirst(outputAtStop.count) : result.output[...]
    let tokenCountAtStop = resultAtStop.thinkTokens.count + resultAtStop.outputTokens.count
    let tokenCount = result.thinkTokens.count + result.outputTokens.count
    let additionalTokenCount =
      tokenCount >= tokenCountAtStop ? tokenCount - tokenCountAtStop : tokenCount
    return additionalTokenCount >= 60 || additionalThink.contains("\n")
      || additionalOutput.contains("\n")
  }

  public func canStopImmediately(with result: CodeAgentResult) -> Bool {
    guard let lastToken = result.outputTokens.last ?? result.thinkTokens.last else { return false }
    return safeTokenizer.decode([lastToken]).contains("\n")
  }
}

extension Qwen3_5CodeAgent {
  private enum CompactionState: String, Codable {
    case none
    case handoffSummary
    case bridge

    var isOn: Bool { self != .none }
  }

  private struct SuspendedGeneration: Codable {
    var userTurnTokens: [Int32]
    var baseContextTokens: [Int32]
    var userTurnEmbedSpans: [EmbedSpan]?
    var baseContextEmbedSpans: [EmbedSpan]?
    var thinkingBudget: Int
    var outputTokens = [Int32]()
    var stoppedByUser = false
    var shouldTriggerCompaction = false
    var compactionTriggerTokenCount: Int?
    var didFinish = false

    init(userTurnTokens: [Int32], baseContextTokens: [Int32], thinkingBudget: Int) {
      self.userTurnTokens = userTurnTokens
      self.baseContextTokens = baseContextTokens
      self.thinkingBudget = thinkingBudget
    }
  }

  private final class PendingToolInvocations {
    let group = DispatchGroup()
    private var lock = os_unfair_lock()
    private var responses = [Int32: ToolResponse]()

    func invoke(id: Int32, invocation: ToolsRegistry.Invocation, context: BashToolContext) {
      group.enter()
      invocation.invoke(context: context, isImageSupported: true) { [weak self] response in
        guard let self else { return }
        os_unfair_lock_lock(&lock)
        responses[id] = response
        os_unfair_lock_unlock(&lock)
        group.leave()
      }
    }

    func completedResponses() -> [Int32: ToolResponse] {
      group.wait()
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      return responses
    }
  }

  private struct SuspendedToolExecution: Codable {
    var toolCalls = [ToolCall]()
    var responses = [Int32: ToolResponse]()
    var pending: PendingToolInvocations? = nil

    private enum CodingKeys: String, CodingKey {
      case toolCalls
      case responses
    }
  }

  private struct TemporaryState {
    var prefixEmbedSpans: [EmbedSpan]
    var ropeDelta: Int
    var hasPaddedImages: Bool
    var prefixTokens: [Int32]
    var cachedTokenLength: Int
    var tokensSinceLastCompact: Int
    var kvCache: [DynamicGraph.AnyTensor]
    var draftCache: [DynamicGraph.AnyTensor]
  }

  private struct SuspensionState: Codable {
    var prefixEmbedSpans: [EmbedSpan]?
    var userEmbedSpans: [EmbedSpan]?
    var logEmbedSpans: [EmbedSpan]?
    var prefixEmbedSpansBeforeCompaction: [EmbedSpan]?
    var embedSpansToContinueAfterCompaction: [EmbedSpan]?
    var ropeDelta: Int?

    var systemSeenMemoryContext: MemoryContext?
    var memoryContext: MemoryContext?
    var allowedTools: [String]?
    var projectPath: String?
    var workspacePath: String?
    var webSearchProviderIdentifier: String
    var webSearchProviderAPIKey: String
    var thinkingBudget: Int
    var deterministic: Bool
    var seed: UInt32
    var shouldSetSeed = true
    var userTokens: [Int32]
    var localPrefixTokens: [Int32]
    var thinkingSuffixTokens: [Int32]
    var noThinkingSuffixTokens: [Int32]
    var compactionPromptTokens: [Int32]
    var continuationTokens: [Int32]
    var thinkTokens = [Int32]()
    var outputTokens = [Int32]()
    var logTokens = [Int32]()
    var toolCallHistory = [ToolCall]()
    var compactionState = CompactionState.none
    var prefixTokensBeforeCompaction: [Int32]?
    var tokensToContinueAfterCompaction: [Int32]?
    var didCompact = false
    var currentGeneration: SuspendedGeneration?
    var toolExecution: SuspendedToolExecution?
    var stopAfterTools = false
    var prefixTokens: [Int32]
    var tokensSinceLastCompact: Int
    var file: String
    var threadId: Int64

    init(
      projectPath: String?, workspacePath: String?, webSearchProvider: WebSearchProvider,
      thinkingBudget: Int, deterministic: Bool, seed: UInt32, userTokens: [Int32],
      localPrefixTokens: [Int32], thinkingSuffixTokens: [Int32],
      noThinkingSuffixTokens: [Int32], compactionPromptTokens: [Int32],
      continuationTokens: [Int32], prefixTokens: [Int32],
      tokensSinceLastCompact: Int, file: String, threadId: Int64
    ) {
      self.projectPath = projectPath
      self.workspacePath = workspacePath
      switch webSearchProvider {
      case .duckDuckGo:
        webSearchProviderIdentifier = "duckduckgo"
        webSearchProviderAPIKey = ""
      case .sogou:
        webSearchProviderIdentifier = "sogou"
        webSearchProviderAPIKey = ""
      case .kagi(let apiKey):
        webSearchProviderIdentifier = "kagi"
        webSearchProviderAPIKey = apiKey
      case .brave(let apiKey):
        webSearchProviderIdentifier = "brave"
        webSearchProviderAPIKey = apiKey
      case .disabled:
        webSearchProviderIdentifier = "disabled"
        webSearchProviderAPIKey = ""
      }
      self.thinkingBudget = thinkingBudget
      self.deterministic = deterministic
      self.seed = seed
      self.userTokens = userTokens
      self.localPrefixTokens = localPrefixTokens
      self.thinkingSuffixTokens = thinkingSuffixTokens
      self.noThinkingSuffixTokens = noThinkingSuffixTokens
      self.compactionPromptTokens = compactionPromptTokens
      self.continuationTokens = continuationTokens
      self.prefixTokens = prefixTokens
      self.tokensSinceLastCompact = tokensSinceLastCompact
      self.file = file
      self.threadId = threadId
    }

    var webSearchProvider: WebSearchProvider {
      WebSearchProvider(
        identifier: webSearchProviderIdentifier, apiKey: webSearchProviderAPIKey) ?? .disabled
    }
  }

  private struct ParsedSuspendedGeneration {
    var thinkTokens: [Int32]
    var outputTokens: [Int32]
    var think: String
    var output: String
    var parser: Qwen3_5ToolCallParser

    func result(toolCallHistory: [ToolCall]) -> CodeAgentResult {
      CodeAgentResult(
        thinkTokens: thinkTokens, outputTokens: outputTokens, think: think, output: output,
        logTokens: [], compacted: false, toolCalls: parser.toolCalls,
        toolCallHistory: toolCallHistory, incompleteToolCall: parser.incompleteToolCall,
        hasIncompleteToolCall: parser.hasIncompleteToolCall, memoryContext: nil,
        systemSeenMemoryContext: nil)
    }
  }

  public func ask(
    _ prompt: String, imagePaths: [String] = [], isMemoryEnabled: Bool, temporary: Bool = false,
    allowedTools: Set<ToolsRegistry.Tool>? = nil,
    threadId: Int64,
    projectPath: String? = nil, workspacePath: String? = nil,
    webSearchProvider: WebSearchProvider = .duckDuckGo,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    precondition(suspensionState == nil && temporaryState == nil)
    var imageTokens = [Int32]()
    var imageSpans = [EmbedSpan]()
    for path in imagePaths {
      guard let projectPath else { continue }
      let store = EmbedsFileStore(projectPath: projectPath)
      let filePath =
        (path as NSString).isAbsolutePath
        ? path : (projectPath as NSString).appendingPathComponent(path)
      guard let digest = try? store.insert(filePath: filePath),
        let grid = Qwen3_5Image.grid(
          filePath: store.filePath(for: digest), configuration: textGenerator.visionConfiguration)
      else { continue }
      let count = Qwen3_5VisionTokenCount(
        gridThw: grid, configuration: textGenerator.visionConfiguration)
      // Label each image with its path as given, and end each image with "\n", tokenized with the
      // text that follows it.
      let (_, labelTokens, _, _, _) = safeTokenizer.tokenize(
        text: (imageTokens.isEmpty ? "" : "\n") + "Image from \(path):", truncation: false,
        maxLength: 0, paddingToken: nil, addSpecialTokens: false)
      imageTokens += labelTokens
      imageTokens.append(248_053)
      imageSpans.append(
        EmbedSpan(
          start: Int64(imageTokens.count), length: Int64(count), digest: Array(digest),
          kind: .image))
      imageTokens += Array(repeating: 248_056, count: count)
      imageTokens.append(248_054)
    }
    bashToolContext = bashToolContext.with(bashUserInteraction: BashUserInteraction())
    if isMemoryEnabled != !systemSeenMemoryContext.isEmpty {
      setSystemReminderTokensAndMemoryContext(
        isMemoryEnabled ? MemoryContext.load(projectPath: projectPath) : .empty)
    }
    if temporary {
      let caches = graph.withStream(streamContext) {
        graph.withNoGrad { textGenerator.cacheSnapshot(kvCache: kvCache, draftCache: draftCache) }
      }
      graph.joined()
      temporaryState = TemporaryState(
        prefixEmbedSpans: prefixEmbedSpans, ropeDelta: textGenerator.ropeDelta,
        hasPaddedImages: textGenerator.hasPaddedImages,
        prefixTokens: prefixTokens, cachedTokenLength: cachedTokenLength,
        tokensSinceLastCompact: tokensSinceLastCompact, kvCache: caches.kvCache,
        draftCache: caches.draftCache)
    }
    let thinkingBudget = Int(self.thinkingBudget)
    let deterministic = self.deterministic
    let reasoningEffort = thinkingBudget > 0 ? self.reasoningEffort : .medium
    if !temporary, reasoningEffort != systemPromptReasoningEffort {
      systemTokens = Self.systemTokens(
        systemPromptTemplate: systemPromptTemplate, reasoningEffort: reasoningEffort,
        memoryContext: systemSeenMemoryContext,
        skillCatalog: skillCatalog,
        projectContext: projectContext, environmentContext: environmentContext,
        unsafeTokenizer: unsafeTokenizer, safeTokenizer: safeTokenizer)
      systemPromptReasoningEffort = reasoningEffort
      resetSuspensionCaches()
    }
    var didCompact = false
    let isCompactionDisabled = temporary
    if !isCompactionDisabled,
      systemTokens.count + prefixTokens.count
        <= Self.contextCheckpointCompactionTokenThreshold,
      tokensSinceLastCompact >= Self.lowCompactTokenThreshold
    {
      prefixTokens = Self.compact(
        prefixTokens, embedSpans: &prefixEmbedSpans, effort: .low, tokenizer: safeTokenizer,
        projectPath: projectPath)
      resetSuspensionCaches()
      tokensSinceLastCompact = 0
      didCompact = true
    }
    let (_, localPrefixTokens, _, _, _) = unsafeTokenizer.tokenize(
      text: "<|im_start|>user\n", truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    let (_, thinkingSuffixTokens, _, _, _) = unsafeTokenizer.tokenize(
      text: "<|im_end|>\n<|im_start|>assistant\n<think>\n", truncation: false,
      maxLength: 0, paddingToken: nil, addSpecialTokens: false)
    let (_, noThinkingSuffixTokens, _, _, _) = unsafeTokenizer.tokenize(
      text: "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
      truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false)
    let (_, textTokens, _, _, _) = safeTokenizer.tokenize(
      text: imageTokens.isEmpty || prompt.isEmpty ? prompt : "\n" + prompt, truncation: false,
      maxLength: 0, paddingToken: nil, addSpecialTokens: false)
    let userTokens = imageTokens + textTokens
    let seedHash = ContextCachePrefixHasher.hash(tokens: userTokens, embeddingSpans: imageSpans)
    let seed = seedHash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let (_, compactionPromptTokens, _, _, _) = safeTokenizer.tokenize(
      text: Self.contextCheckpointCompactionPrompt, truncation: false, maxLength: 0,
      paddingToken: nil, addSpecialTokens: false)
    let (_, continuationTokens, _, _, _) = safeTokenizer.tokenize(
      text: Self.continueAfterCompactionPrompt, truncation: false, maxLength: 0,
      paddingToken: nil, addSpecialTokens: false)
    var state = SuspensionState(
      projectPath: projectPath, workspacePath: workspacePath,
      webSearchProvider: webSearchProvider, thinkingBudget: thinkingBudget,
      deterministic: deterministic, seed: seed, userTokens: userTokens,
      localPrefixTokens: localPrefixTokens, thinkingSuffixTokens: thinkingSuffixTokens,
      noThinkingSuffixTokens: noThinkingSuffixTokens,
      compactionPromptTokens: compactionPromptTokens, continuationTokens: continuationTokens,
      prefixTokens: prefixTokens, tokensSinceLastCompact: tokensSinceLastCompact,
      file: URL(fileURLWithPath: textGenerator.filePath).lastPathComponent, threadId: threadId)
    if !temporary, shouldInjectSystemSeenMemoryContext {
      state.systemSeenMemoryContext = systemSeenMemoryContext
      state.memoryContext = systemSeenMemoryContext
    }
    state.prefixEmbedSpans = prefixEmbedSpans
    state.userEmbedSpans = imageSpans
    state.allowedTools = allowedTools?.map(\.rawValue).sorted()
    state.didCompact = didCompact
    if !isCompactionDisabled,
      systemTokens.count + prefixTokens.count
        > Self.contextCheckpointCompactionTokenThreshold
    {
      beginSuspendedCompaction(&state, continueWith: userTokens, embedSpans: imageSpans)
    }
    return runSuspended(state, progress: progress)
  }

  public func resume(
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    guard let state = suspensionState else {
      preconditionFailure("Qwen3_5CodeAgent.resume requires a suspended turn")
    }
    suspensionState = nil
    return runSuspended(state, progress: progress)
  }

  public func hibernate(threadId: Int64) throws {
    guard var state = suspensionState else {
      preconditionFailure("Qwen3_5CodeAgent.hibernate requires a suspended turn")
    }
    if var toolExecution = state.toolExecution, let pending = toolExecution.pending {
      for (id, response) in pending.completedResponses() {
        toolExecution.responses[id] = response
      }
      toolExecution.pending = nil
      state.toolExecution = toolExecution
    }
    if let temporaryState {
      restoreTemporaryState(temporaryState)
      suspensionState = nil
      return
    }
    state.prefixTokens = prefixTokens
    state.prefixEmbedSpans = prefixEmbedSpans
    state.ropeDelta = textGenerator.ropeDelta
    state.tokensSinceLastCompact = tokensSinceLastCompact
    state.threadId = threadId
    suspensionState = state
    try saveSuspension(state, threadId: threadId)
    graph.joined()
    resetSuspensionCaches()
  }

  private func saveSuspension(_ state: SuspensionState, threadId: Int64) throws {
    guard temporaryState == nil else { return }
    let data = try JSONEncoder().encode(state)
    Qwen3_5ContextCache(
      projectPath: state.projectPath,
      checkpointStride: textGenerator.chunkedPrefillMaxLength
    ).saveSuspension(data, threadId: threadId)
  }

  @discardableResult
  public func restoreSuspension(threadId: Int64, projectPath: String) throws -> Bool {
    precondition(temporaryState == nil)
    let contextCache = Qwen3_5ContextCache(
      projectPath: projectPath, checkpointStride: textGenerator.chunkedPrefillMaxLength)
    guard let data = contextCache.loadSuspension(threadId: threadId) else { return false }
    var state = try JSONDecoder().decode(SuspensionState.self, from: data)
    guard state.file == URL(fileURLWithPath: textGenerator.filePath).lastPathComponent else {
      return false
    }
    state.projectPath = projectPath
    state.threadId = threadId
    if let context = state.systemSeenMemoryContext {
      setSystemReminderTokensAndMemoryContext(context)
    }
    shouldInjectSystemSeenMemoryContext = state.systemSeenMemoryContext != nil
    prefixTokens = state.prefixTokens
    prefixEmbedSpans = state.prefixEmbedSpans ?? []
    tokensSinceLastCompact = state.tokensSinceLastCompact
    resetSuspensionCaches()
    suspensionState = state
    return true
  }

  private func setSystemReminderTokensAndMemoryContext(_ context: MemoryContext) {
    guard context != systemSeenMemoryContext else { return }
    systemSeenMemoryContext = context
    shouldInjectSystemSeenMemoryContext = true
    systemTokens = Self.systemTokens(
      systemPromptTemplate: systemPromptTemplate, reasoningEffort: systemPromptReasoningEffort,
      memoryContext: systemSeenMemoryContext, skillCatalog: skillCatalog,
      projectContext: projectContext, environmentContext: environmentContext,
      unsafeTokenizer: unsafeTokenizer, safeTokenizer: safeTokenizer)
    resetSuspensionCaches()
  }

  private func restoreTemporaryState(_ state: TemporaryState) {
    graph.joined()
    prefixTokens = state.prefixTokens
    prefixEmbedSpans = state.prefixEmbedSpans
    textGenerator.ropeDelta = state.ropeDelta
    textGenerator.hasPaddedImages = state.hasPaddedImages
    cachedTokenLength = state.cachedTokenLength
    tokensSinceLastCompact = state.tokensSinceLastCompact
    kvCache = state.kvCache
    draftCache = state.draftCache
    temporaryState = nil
  }

  /// Warm real model weights on disposable state using the agent's inference backend settings.
  @discardableResult
  public static func warmupPrefill(
    _ textGenerator: Qwen3_5TextGenerator, graph: DynamicGraph, streamContext: StreamContext
  ) -> Bool {
    let oldFlags = DynamicGraph.flags
    let isMFAEnabled = DeviceCapability.isMFAEnabled.load(ordering: .acquiring) > 0
    if !isMFAEnabled {
      DynamicGraph.flags.insert(.disableMFA)
    } else {
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
    defer {
      streamContext.joined()
      graph.garbageCollect()
      DynamicGraph.flags = oldFlags
    }
    return graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.warmupPrefill(graph: graph)
      }
    }
  }

  private func runSuspended(
    _ initialState: SuspensionState,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    var state = initialState
    defer {
      if suspensionState == nil, let temporaryState {
        restoreTemporaryState(temporaryState)
      }
    }
    let oldFlags = DynamicGraph.flags
    let isMFAEnabled = DeviceCapability.isMFAEnabled.load(ordering: .acquiring) > 0
    if !isMFAEnabled {
      DynamicGraph.flags.insert(.disableMFA)
    } else {
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
    defer { DynamicGraph.flags = oldFlags }
    let isCompactionDisabled = temporaryState != nil
    if state.shouldSetSeed {
      DynamicGraph.setSeed(state.seed)
      state.shouldSetSeed = false
    }
    let contextCache = Qwen3_5ContextCache(
      projectPath: state.projectPath,
      checkpointStride: textGenerator.chunkedPrefillMaxLength)
    func saveCheckpoint(_ generation: SuspendedGeneration) {
      guard temporaryState == nil, state.toolExecution?.pending == nil else { return }
      var checkpointState = state
      checkpointState.currentGeneration = generation
      checkpointState.prefixTokens = prefixTokens
      checkpointState.prefixEmbedSpans = prefixEmbedSpans
      checkpointState.tokensSinceLastCompact = tokensSinceLastCompact
      guard let data = try? JSONEncoder().encode(checkpointState) else { return }
      contextCache.saveSuspension(data, threadId: checkpointState.threadId)
    }
    while true {
      if state.currentGeneration == nil {
        state.currentGeneration = makeSuspendedGeneration(state)
      }
      guard var generation = state.currentGeneration else { preconditionFailure() }
      if generation.didFinish, var toolExecution = state.toolExecution {
        let latestParsed = parseSuspendedGeneration(
          generation.outputTokens, thinkingBudget: generation.thinkingBudget)
        let partialResult = latestParsed.result(toolCallHistory: state.toolCallHistory)
        if let pending = toolExecution.pending {
          switch waitForToolResponses(
            pending, partialResult: partialResult, progress: progress)
          {
          case .continue, .checkpoint:
            break
          case .pause:
            state.toolExecution = toolExecution
            suspensionState = state
            return partialResult
          case .abort:
            state.stopAfterTools = true
          }
          for (id, response) in pending.completedResponses() {
            toolExecution.responses[id] = response
          }
          toolExecution.pending = nil
        }
        state.toolExecution = toolExecution
        saveCheckpoint(generation)
        var toolCalls = toolExecution.toolCalls
        let reason = ToolCallParser.removeToolCalls(
          latestParsed.output, toolCallStart: toolCallStart, toolCallEnd: toolCallEnd
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        for index in toolCalls.indices {
          toolCalls[index].response = toolExecution.responses[toolCalls[index].id]
          toolCalls[index].reason = reason
        }
        let turnTokens = generation.userTurnTokens + generation.outputTokens
        state.logEmbedSpans =
          (state.logEmbedSpans ?? [])
          + (generation.userTurnEmbedSpans ?? []).map { $0.offset(by: state.logTokens.count) }
        prefixEmbedSpans += (generation.userTurnEmbedSpans ?? []).map {
          $0.offset(by: prefixTokens.count)
        }
        state.logTokens += turnTokens
        prefixTokens += turnTokens
        tokensSinceLastCompact += turnTokens.count
        state.toolCallHistory += toolCalls
        state.thinkTokens += latestParsed.thinkTokens
        // Retained tool results record only the targets observed during this turn.
        if temporaryState == nil, !systemSeenMemoryContext.isEmpty {
          for case let memory? in toolCalls.map({ $0.response?.memory }) {
            state.memoryContext = (state.memoryContext ?? MemoryContext()).replacing(memory)
          }
        }
        (state.userTokens, state.userEmbedSpans) = suspendedToolResultTokens(
          for: toolCalls, responses: toolExecution.responses,
          projectPath: state.projectPath)
        state.toolExecution = nil
        state.currentGeneration = nil
        if state.stopAfterTools { break }
        continue
      }
      let existingOutputTokens = generation.outputTokens
      let outputTokensBeforeDecode: [Int32]
      let inputTokens: [Int32]
      let tokenOffset: Int
      let contextTokens: [Int32]
      if cachedTokenLength < generation.baseContextTokens.count {
        let replayedOutputCount =
          cachedTokenLength == 0 ? max(0, existingOutputTokens.count - 1) : 0
        outputTokensBeforeDecode = Array(existingOutputTokens.prefix(replayedOutputCount))
        let replayContextTokens = generation.baseContextTokens + outputTokensBeforeDecode
        tokenOffset = cachedTokenLength
        inputTokens = Array(replayContextTokens.dropFirst(cachedTokenLength))
        contextTokens = replayContextTokens
      } else {
        let evaluatedOutputCount = cachedTokenLength - generation.baseContextTokens.count
        guard evaluatedOutputCount <= existingOutputTokens.count else {
          resetSuspensionCaches()
          continue
        }
        tokenOffset = cachedTokenLength
        inputTokens = Array(existingOutputTokens.dropFirst(evaluatedOutputCount))
        contextTokens = generation.baseContextTokens + existingOutputTokens
        outputTokensBeforeDecode = existingOutputTokens
      }
      guard !inputTokens.isEmpty else {
        resetSuspensionCaches()
        continue
      }
      let isEvaluatingPendingGeneratedTokens =
        !existingOutputTokens.isEmpty
        && tokenOffset >= generation.baseContextTokens.count

      var latestParsed = parseSuspendedGeneration(
        outputTokensBeforeDecode, thinkingBudget: generation.thinkingBudget)
      var didPause = false
      let tokenGPU = graph.variable(Tensor<Int32>(inputTokens).toGPU(0))
      let generated = graph.withStream(streamContext) {
        graph.withNoGrad {
          textGenerator.decode(
            graph: graph, tokens: tokenGPU, tokenOffset: tokenOffset,
            thinkingBudget: generation.thinkingBudget, deterministic: state.deterministic,
            kvCache: &kvCache, draftCache: &draftCache,
            contextTokens: contextTokens, contextCache: contextCache,
            embedSpans: generation.baseContextEmbedSpans ?? [], projectPath: state.projectPath
          ) { prefillStart, prefillLength, generatedTokens, generatorStatistics in
            state.ropeDelta = generatorStatistics.ropeDelta
            let statistics = CodeAgentStatistics(
              prefillDurationSoFar: generatorStatistics.prefillDurationSoFar,
              prefillTokensSoFar: generatorStatistics.prefillTokensSoFar,
              tokenGenerationDurationSoFar: generatorStatistics.tokenGenerationDurationSoFar,
              tokenGeneratedSoFar: generatorStatistics.tokenGeneratedSoFar,
              contextUsedTokens: contextTokens.count + generatedTokens.count,
              contextWindowTokens: Self.maximumContextLength)
            guard !generatedTokens.isEmpty else {
              cachedTokenLength = tokenOffset + prefillStart
              if isEvaluatingPendingGeneratedTokens { return .continue }
              let decision = progress(
                state.compactionState.isOn
                  ? .compact(state.toolCallHistory, prefillStart, prefillLength)
                  : .prefill(state.toolCallHistory, prefillStart, prefillLength),
                statistics)
              if decision == .pause { didPause = true }
              if decision == .abort { generation.stoppedByUser = true }
              return Qwen3_5TextGenerator.ContinuationState(decision)
            }
            cachedTokenLength = prefillStart
            latestParsed = parseSuspendedGeneration(
              outputTokensBeforeDecode + generatedTokens,
              thinkingBudget: generation.thinkingBudget)
            if state.compactionState.isOn {
              let decision = progress(
                .compact(state.toolCallHistory, generatedTokens.count, 0), statistics)
              if decision == .pause { didPause = true }
              if decision == .abort { generation.stoppedByUser = true }
              return Qwen3_5TextGenerator.ContinuationState(decision)
            }
            launchToolCalls(latestParsed.parser.toolCalls, state: &state)
            let partialResult = latestParsed.result(toolCallHistory: state.toolCallHistory)
            let decision = progress(.generate(partialResult), statistics)
            if decision == .checkpoint, latestParsed.parser.toolCalls.isEmpty,
              !latestParsed.parser.hasIncompleteToolCall
            {
              var checkpointGeneration = generation
              checkpointGeneration.outputTokens = outputTokensBeforeDecode + generatedTokens
              saveCheckpoint(checkpointGeneration)
            }
            if decision == .pause {
              didPause = true
              return .pause
            }
            if decision == .abort {
              generation.stoppedByUser = true
              return .abort
            }
            guard !isCompactionDisabled,
              contextTokens.count + generatedTokens.count
                > Self.generationSafeStopTokenThreshold,
              latestParsed.parser.toolCalls.isEmpty,
              !latestParsed.parser.hasIncompleteToolCall
            else { return .continue }
            if let triggerTokenCount = generation.compactionTriggerTokenCount {
              let tokenCount = latestParsed.thinkTokens.count + latestParsed.outputTokens.count
              if tokenCount - triggerTokenCount >= 60
                || latestParsed.think.contains("\n") || latestParsed.output.contains("\n")
              {
                generation.shouldTriggerCompaction = true
                return .abort
              }
            } else if canStopImmediately(with: partialResult) {
              generation.shouldTriggerCompaction = true
              return .abort
            } else {
              generation.compactionTriggerTokenCount =
                latestParsed.thinkTokens.count + latestParsed.outputTokens.count
            }
            return .continue
          }
        }
      }
      state.ropeDelta = textGenerator.ropeDelta
      generation.outputTokens = outputTokensBeforeDecode + generated
      latestParsed = parseSuspendedGeneration(
        generation.outputTokens, thinkingBudget: generation.thinkingBudget)
      if didPause {
        state.currentGeneration = generation
        suspensionState = state
        return latestParsed.result(toolCallHistory: state.toolCallHistory)
      }
      if state.compactionState.isOn && generation.stoppedByUser {
        if let prefixTokensBeforeCompaction = state.prefixTokensBeforeCompaction {
          prefixTokens = prefixTokensBeforeCompaction
          prefixEmbedSpans = state.prefixEmbedSpansBeforeCompaction ?? []
        }
        state.compactionState = .none
        resetSuspensionCaches()
        break
      }
      guard !generation.outputTokens.isEmpty else {
        // Finalize earlier completed rounds even if this generation produced no output.
        resetSuspensionCaches()
        break
      }

      if generation.stoppedByUser || generation.shouldTriggerCompaction {
        if generation.thinkingBudget > 0 && !generation.outputTokens.contains(248_069) {
          generation.outputTokens += [248_069, 271]
        }
        if generation.outputTokens.last != 248_046 {
          generation.outputTokens.append(248_046)
        }
        resetSuspensionCaches()
      } else {
        cachedTokenLength = generation.baseContextTokens.count + generation.outputTokens.count
      }
      latestParsed = parseSuspendedGeneration(
        generation.outputTokens, thinkingBudget: generation.thinkingBudget)

      if state.compactionState == .handoffSummary {
        var handoffTokens = latestParsed.outputTokens
        while handoffTokens.last == 248_046 || handoffTokens.last == 248_044 {
          handoffTokens.removeLast()
        }
        let handoffSummary = unsafeTokenizer.decode(handoffTokens)
        let (_, safeHandoffTokens, _, _, _) = safeTokenizer.tokenize(
          text: handoffSummary, truncation: false, maxLength: 0, paddingToken: nil,
          addSpecialTokens: false)
        prefixTokens = Self.retainedConversationTokens(
          in: prefixTokens, embedSpans: &prefixEmbedSpans,
          tokenBudget: Self.contextCheckpointCompactionHistoryTokenBudget)
        let (_, summaryPrefixTokens, _, _, _) = safeTokenizer.tokenize(
          text: Self.contextCheckpointCompactionSummaryPrefix + "\n", truncation: false,
          maxLength: 0, paddingToken: nil, addSpecialTokens: false)
        state.userTokens = summaryPrefixTokens + safeHandoffTokens
        state.userEmbedSpans = []
        resetSuspensionCaches()
        tokensSinceLastCompact = 0
        state.didCompact = true
        state.compactionState = .bridge
        state.currentGeneration = nil
        continue
      }

      launchToolCalls(latestParsed.parser.toolCalls, state: &state)
      if state.toolExecution != nil {
        generation.didFinish = true
        state.currentGeneration = generation
        if generation.stoppedByUser {
          state.stopAfterTools = true
        }
        continue
      }

      let turnTokens = generation.userTurnTokens + generation.outputTokens
      state.logEmbedSpans =
        (state.logEmbedSpans ?? [])
        + (generation.userTurnEmbedSpans ?? []).map { $0.offset(by: state.logTokens.count) }
      prefixEmbedSpans += (generation.userTurnEmbedSpans ?? []).map {
        $0.offset(by: prefixTokens.count)
      }
      state.logTokens += turnTokens
      prefixTokens += turnTokens
      tokensSinceLastCompact += turnTokens.count

      if state.compactionState == .bridge {
        state.compactionState = .none
        if !systemSeenMemoryContext.isEmpty {
          let context = MemoryContext.load(projectPath: state.projectPath)
          if context != systemSeenMemoryContext {
            setSystemReminderTokensAndMemoryContext(context)
            state.systemSeenMemoryContext = context
            state.memoryContext = context
          }
        }
        state.prefixTokensBeforeCompaction = nil
        state.prefixEmbedSpansBeforeCompaction = nil
        guard let queuedTokens = state.tokensToContinueAfterCompaction else { break }
        state.tokensToContinueAfterCompaction = nil
        state.userTokens = queuedTokens
        state.userEmbedSpans = state.embedSpansToContinueAfterCompaction ?? []
        state.embedSpansToContinueAfterCompaction = nil
        state.currentGeneration = nil
        continue
      }

      if generation.shouldTriggerCompaction {
        state.thinkTokens += latestParsed.thinkTokens
        state.outputTokens = latestParsed.outputTokens
        prefixTokens = Self.compact(
          prefixTokens, embedSpans: &prefixEmbedSpans, effort: .high, tokenizer: safeTokenizer,
          projectPath: state.projectPath)
        resetSuspensionCaches()
        tokensSinceLastCompact = 0
        state.didCompact = true
        if systemTokens.count + prefixTokens.count
          > Self.contextCheckpointCompactionTokenThreshold
        {
          let continuationTokens = state.continuationTokens
          beginSuspendedCompaction(&state, continueWith: continuationTokens)
        } else {
          state.userTokens = state.continuationTokens
          state.userEmbedSpans = []
        }
        state.currentGeneration = nil
        continue
      }

      state.thinkTokens += latestParsed.thinkTokens
      state.outputTokens = latestParsed.outputTokens
      guard !generation.stoppedByUser && !state.stopAfterTools else { break }
      if !isCompactionDisabled,
        systemTokens.count + prefixTokens.count > Self.highCompactTokenThreshold
      {
        prefixTokens = Self.compact(
          prefixTokens, embedSpans: &prefixEmbedSpans, effort: .high, tokenizer: safeTokenizer,
          projectPath: state.projectPath)
        resetSuspensionCaches()
        tokensSinceLastCompact = 0
        state.didCompact = true
        if systemTokens.count + prefixTokens.count
          > Self.contextCheckpointCompactionTokenThreshold
        {
          beginSuspendedCompaction(&state, continueWith: nil)
          state.currentGeneration = nil
          continue
        }
      }
      break
    }

    tokensSinceLastCompact = max(tokensSinceLastCompact, 0)
    let result = CodeAgentResult(
      thinkTokens: state.thinkTokens, outputTokens: state.outputTokens,
      think: safeTokenizer.decode(state.thinkTokens),
      output: safeTokenizer.decode(
        state.outputTokens, specialTokens: Qwen3_5ToolCallParser.toolCallSpecialTokens),
      logTokens: state.didCompact ? prefixTokens : state.logTokens,
      embedSpans: state.didCompact ? prefixEmbedSpans : (state.logEmbedSpans ?? []),
      compacted: state.didCompact, toolCalls: [], toolCallHistory: state.toolCallHistory,
      incompleteToolCall: nil, hasIncompleteToolCall: false,
      memoryContext: state.memoryContext,
      systemSeenMemoryContext: state.systemSeenMemoryContext)
    if temporaryState == nil, !result.isEmpty, state.systemSeenMemoryContext != nil {
      shouldInjectSystemSeenMemoryContext = false
    }
    if temporaryState == nil {
      contextCache.removeSuspension(threadId: state.threadId)
    }
    suspensionState = nil
    return result
  }

  private func makeSuspendedGeneration(_ state: SuspensionState) -> SuspendedGeneration {
    let suffixTokens =
      state.compactionState == .bridge || state.thinkingBudget <= 0
      ? state.noThinkingSuffixTokens : state.thinkingSuffixTokens
    let userTurnTokens = state.localPrefixTokens + state.userTokens + suffixTokens
    let expectedTokenOffset = systemTokens.count + prefixTokens.count
    if cachedTokenLength != expectedTokenOffset {
      resetSuspensionCaches()
    }
    let baseContextTokens = systemTokens + prefixTokens + userTurnTokens
    let thisThinkingBudget =
      state.thinkingBudget > 0 && state.compactionState != .bridge
      ? min(
        state.thinkingBudget,
        max(
          1,
          Self.maximumContextLength - baseContextTokens.count - Self.minimumGenerationReserve))
      : 0
    var generation = SuspendedGeneration(
      userTurnTokens: userTurnTokens, baseContextTokens: baseContextTokens,
      thinkingBudget: thisThinkingBudget)
    generation.userTurnEmbedSpans = (state.userEmbedSpans ?? []).map {
      $0.offset(by: state.localPrefixTokens.count)
    }
    generation.baseContextEmbedSpans =
      prefixEmbedSpans.map { $0.offset(by: systemTokens.count) }
      + (generation.userTurnEmbedSpans ?? []).map { $0.offset(by: expectedTokenOffset) }
    return generation
  }

  private func parseSuspendedGeneration(
    _ tokens: [Int32], thinkingBudget: Int
  ) -> ParsedSuspendedGeneration {
    let thinkTokens: [Int32]
    let outputTokens: [Int32]
    if thinkingBudget > 0 {
      if let endThinkIndex = tokens.firstIndex(of: 248_069) {
        thinkTokens = Array(tokens[..<endThinkIndex])
        outputTokens = Array(tokens[tokens.index(after: endThinkIndex)...])
      } else {
        thinkTokens = tokens
        outputTokens = []
      }
    } else {
      thinkTokens = []
      outputTokens = tokens
    }
    var parser = Qwen3_5ToolCallParser()
    var streamer = unsafeTokenizer.makeTokenStreamer()
    parser.append(streamer.append(outputTokens))
    parser.append(streamer.finish())
    return ParsedSuspendedGeneration(
      thinkTokens: thinkTokens, outputTokens: outputTokens,
      think: safeTokenizer.decode(thinkTokens),
      output: safeTokenizer.decode(
        outputTokens, specialTokens: Qwen3_5ToolCallParser.toolCallSpecialTokens),
      parser: parser)
  }

  private func launchToolCalls(_ toolCalls: [ToolCall], state: inout SuspensionState) {
    guard !toolCalls.isEmpty else { return }
    var execution = state.toolExecution ?? SuspendedToolExecution()
    let launchedToolCallIds = Set(execution.toolCalls.map(\.id))
    var pending = execution.pending
    for toolCall in toolCalls where !launchedToolCallIds.contains(toolCall.id) {
      execution.toolCalls.append(toolCall)
      if let allowedTools = state.allowedTools, !allowedTools.contains(toolCall.request.function) {
        execution.responses[toolCall.id] =
          ToolResponse(
            text: "Error: This ask only permits: \(allowedTools.joined(separator: ", ")).")
        continue
      }
      guard
        let invocation = ToolsRegistry.parse(
          toolCall.request, projectPath: state.projectPath,
          workspacePath: state.workspacePath,
          webSearchProvider: state.webSearchProvider)
      else {
        execution.responses[toolCall.id] =
          ToolResponse(
            text: "Tool error: invalid or unknown tool request: \(toolCall.request.function)")
        continue
      }
      let invocations = pending ?? PendingToolInvocations()
      invocations.invoke(
        id: toolCall.id, invocation: invocation,
        context: bashToolContext.with(
          projectURL: state.projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
          threadId: state.threadId))
      pending = invocations
    }
    execution.pending = pending
    state.toolExecution = execution
  }

  private func beginSuspendedCompaction(
    _ state: inout SuspensionState, continueWith tokens: [Int32]?, embedSpans: [EmbedSpan] = []
  ) {
    state.compactionState = .handoffSummary
    state.prefixTokensBeforeCompaction = prefixTokens
    state.prefixEmbedSpansBeforeCompaction = prefixEmbedSpans
    state.embedSpansToContinueAfterCompaction = embedSpans
    state.userEmbedSpans = []
    state.tokensToContinueAfterCompaction = tokens
    state.userTokens = state.compactionPromptTokens
  }

  private func waitForToolResponses(
    _ pending: PendingToolInvocations, partialResult: CodeAgentResult,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> ContinuationState {
    guard pending.group.wait(timeout: .now()) == .timedOut else { return .continue }
    let continuation = progress(.toolsWait(partialResult), statistics)
    if continuation != .pause {
      pending.group.wait()
    }
    return continuation
  }

  func suspendedToolResultTokens(
    for toolCalls: [ToolCall], responses: [Int32: ToolResponse], projectPath: String?
  ) -> (tokens: [Int32], embedSpans: [EmbedSpan]) {
    let (_, prefixTokens, _, _, _) = unsafeTokenizer.tokenize(
      text: "<tool_response>", truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    let (_, suffixTokens, _, _, _) = unsafeTokenizer.tokenize(
      text: "</tool_response>", truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    let (_, newlineTokens, _, _, _) = safeTokenizer.tokenize(
      text: "\n", truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false)
    var toolTokens = [Int32]()
    var embedSpans = [EmbedSpan]()
    for toolCall in toolCalls {
      guard let response = responses[toolCall.id] else {
        toolTokens += prefixTokens + suffixTokens
        continue
      }
      toolTokens += prefixTokens
      // Render "<tool_response>\n" + content + "\n</tool_response>" as the chat template does, and
      // end each image with "\n". A pending "\n" is tokenized with the text part that follows it.
      var hasPendingNewline = true
      for (index, part) in response.content.enumerated() {
        switch part {
        case .text(let text):
          let leading = hasPendingNewline ? "\n" : ""
          let trailing = index == response.content.count - 1 ? "\n" : ""
          hasPendingNewline = false
          var (_, responseTokens, _, _, _) = safeTokenizer.tokenize(
            text: leading + text + trailing, truncation: false, maxLength: 0,
            paddingToken: nil, addSpecialTokens: false)
          if toolCall.request.function == ToolsRegistry.Tool.read.rawValue,
            let compactedTokens = Self.previewedReadResponseTokensIfNeeded(
              responseTokens, request: toolCall.request, tokenizer: safeTokenizer)
          {
            responseTokens = compactedTokens
          } else if responseTokens.count > Self.lowCompactTokenThreshold,
            let compactedTokens = Self.compactedToolResponseTokens(
              responseTokens, tokenizer: safeTokenizer, projectPath: projectPath)
          {
            responseTokens = compactedTokens
          }
          toolTokens += responseTokens
        case .imageDigest(let digest):
          if hasPendingNewline {
            toolTokens += newlineTokens
          }
          hasPendingNewline = true
          if let projectPath,
            let grid = Qwen3_5Image.grid(
              filePath: EmbedsFileStore(projectPath: projectPath).filePath(for: digest),
              configuration: textGenerator.visionConfiguration)
          {
            let count = Qwen3_5VisionTokenCount(
              gridThw: grid, configuration: textGenerator.visionConfiguration)
            toolTokens.append(248_053)
            embedSpans.append(
              EmbedSpan(
                start: Int64(toolTokens.count), length: Int64(count), digest: Array(digest),
                kind: .image))
            toolTokens += Array(repeating: 248_056, count: count)
            toolTokens.append(248_054)
          }
        }
      }
      if hasPendingNewline && !response.content.isEmpty {
        toolTokens += newlineTokens
      }
      toolTokens += suffixTokens
    }
    return (toolTokens, embedSpans)
  }

  public func unloadCaches() {
    precondition(temporaryState == nil)
    streamContext.joined()
    resetSuspensionCaches()
  }

  private func resetSuspensionCaches() {
    textGenerator.ropeDelta = 0
    textGenerator.hasPaddedImages = false
    kvCache.removeAll(keepingCapacity: false)
    draftCache.removeAll(keepingCapacity: false)
    cachedTokenLength = 0
  }

}

extension Qwen3_5TextGenerator.ContinuationState {
  init(_ state: ContinuationState) {
    switch state {
    case .continue:
      self = .continue
    case .checkpoint:
      self = .continue
    case .pause:
      self = .pause
    case .abort:
      self = .abort
    }
  }
}

public final class Qwen3_5CodeAgent: CodeAgent {

  private let thinkingBudgetStorage = ManagedAtomic<Int32>(65_536)
  private let deterministicStorage = ManagedAtomic<Bool>(false)
  private let reasoningEffortStorage: ManagedAtomic<Int>
  private var systemTokens: [Int32]
  private var prefixEmbedSpans: [EmbedSpan]
  private var prefixTokens: [Int32]
  public var bashUserInteraction: BashUserInteraction { bashToolContext.bashUserInteraction }

  private var bashToolContext: BashToolContext
  private var textGenerator: Qwen3_5TextGenerator
  private let unsafeTokenizer: TiktokenTokenizer  // Support full special token vocabulary.
  public let safeTokenizer: TiktokenTokenizer  // Limited special token support, so user cannot escalate into system prompt.
  private let skillCatalog: SkillCatalog
  private let projectContext: ProjectContext
  private let environmentContext: EnvironmentContext
  private let systemPromptTemplate: String
  // Keep the frozen prompt snapshot for cache reconstruction. Latest memory belongs to history
  // and the active turn's SuspensionState.
  private var systemSeenMemoryContext: MemoryContext
  // Record a freshly supplied snapshot on the next retained turn.
  private var shouldInjectSystemSeenMemoryContext: Bool

  private let graph: DynamicGraph
  private let streamContext: StreamContext
  private var kvCache: [DynamicGraph.AnyTensor]
  private var draftCache: [DynamicGraph.AnyTensor]
  private var cachedTokenLength = 0
  private var suspensionState: SuspensionState?
  private var temporaryState: TemporaryState?
  private var tokensSinceLastCompact = 0

  public var thinkingBudget: Int32 {
    get { thinkingBudgetStorage.load(ordering: .acquiring) }
    set { thinkingBudgetStorage.store(newValue, ordering: .releasing) }
  }

  public var deterministic: Bool {
    get { deterministicStorage.load(ordering: .acquiring) }
    set { deterministicStorage.store(newValue, ordering: .releasing) }
  }

  // This is to track which reasoning effort used for current tokenized system prompt.
  private var systemPromptReasoningEffort: ReasoningEffort
  var reasoningEffort: ReasoningEffort {
    get {
      ReasoningEffort(rawValue: reasoningEffortStorage.load(ordering: .acquiring)) ?? .medium
    }
    set { reasoningEffortStorage.store(newValue.rawValue, ordering: .releasing) }
  }

  public var statistics: CodeAgentStatistics {
    let statistics = textGenerator.statistics
    return CodeAgentStatistics(
      prefillDurationSoFar: statistics.prefillDurationSoFar,
      prefillTokensSoFar: statistics.prefillTokensSoFar,
      tokenGenerationDurationSoFar: statistics.tokenGenerationDurationSoFar,
      tokenGeneratedSoFar: statistics.tokenGeneratedSoFar,
      contextUsedTokens: systemTokens.count + prefixTokens.count,
      contextWindowTokens: Self.maximumContextLength)
  }

  public var suspendedResult: CodeAgentResult? {
    guard let state = suspensionState else { return nil }
    if !state.compactionState.isOn, let generation = state.currentGeneration {
      return parseSuspendedGeneration(
        generation.outputTokens, thinkingBudget: generation.thinkingBudget
      ).result(toolCallHistory: state.toolCallHistory)
    }
    return CodeAgentResult(
      thinkTokens: state.thinkTokens, outputTokens: state.outputTokens,
      think: safeTokenizer.decode(state.thinkTokens),
      output: safeTokenizer.decode(
        state.outputTokens, specialTokens: Qwen3_5ToolCallParser.toolCallSpecialTokens),
      logTokens: state.didCompact ? prefixTokens : state.logTokens,
      embedSpans: state.didCompact ? prefixEmbedSpans : (state.logEmbedSpans ?? []),
      compacted: state.didCompact,
      toolCalls: state.toolExecution?.toolCalls ?? [], toolCallHistory: state.toolCallHistory,
      incompleteToolCall: nil, hasIncompleteToolCall: false, memoryContext: nil,
      systemSeenMemoryContext: nil)
  }

  public var toolCallStart: String {
    Qwen3_5ToolCallParser.toolCallStart
  }

  public var toolCallEnd: String {
    Qwen3_5ToolCallParser.toolCallEnd
  }

  public var toolCallSpecialTokens: [Int32: String] {
    Qwen3_5ToolCallParser.toolCallSpecialTokens
  }

  public init(
    textGenerator: Qwen3_5TextGenerator,
    graph: DynamicGraph,
    streamContext: StreamContext,
    unsafeTokenizer: TiktokenTokenizer,
    safeTokenizer: TiktokenTokenizer,
    systemPromptTemplate: String,
    reasoningEffort: ReasoningEffort = .medium,
    skillCatalog: SkillCatalog = .empty,
    projectContext: ProjectContext = .empty,
    environmentContext: EnvironmentContext = .empty,
    memoryContext: MemoryContext = .empty,
    prefixTokens: [Int32] = [],
    prefixEmbedSpans: [EmbedSpan] = [],
    bashToolContext: BashToolContext = .init(),
    shouldInjectSystemSeenMemoryContext: Bool = false
  ) {
    self.bashToolContext = bashToolContext.with(unloadTextGenerator: textGenerator.unload)
    self.textGenerator = textGenerator
    self.unsafeTokenizer = unsafeTokenizer
    self.safeTokenizer = safeTokenizer
    self.skillCatalog = skillCatalog
    self.projectContext = projectContext
    self.environmentContext = environmentContext
    self.systemPromptTemplate = systemPromptTemplate
    self.systemSeenMemoryContext = memoryContext
    self.shouldInjectSystemSeenMemoryContext = shouldInjectSystemSeenMemoryContext
    if !memoryContext.isEmpty, !MemoryContext.hasPlaceholder(systemPromptTemplate) {
      print(
        "Automatic memory inclusion and review require exactly one {{MEMORY_CONTEXT}} placeholder in the system prompt template."
      )
    }
    reasoningEffortStorage = ManagedAtomic(reasoningEffort.rawValue)
    systemPromptReasoningEffort = reasoningEffort
    self.graph = graph
    self.streamContext = streamContext
    systemTokens = Self.systemTokens(
      systemPromptTemplate: systemPromptTemplate, reasoningEffort: reasoningEffort,
      memoryContext: memoryContext,
      skillCatalog: skillCatalog,
      projectContext: projectContext, environmentContext: environmentContext,
      unsafeTokenizer: unsafeTokenizer, safeTokenizer: safeTokenizer)
    self.prefixTokens = prefixTokens
    self.prefixEmbedSpans = prefixEmbedSpans
    kvCache = []
    draftCache = []
    tokensSinceLastCompact = prefixTokens.count
  }

  private static func systemTokens(
    systemPromptTemplate: String, reasoningEffort: ReasoningEffort, memoryContext: MemoryContext,
    skillCatalog: SkillCatalog,
    projectContext: ProjectContext, environmentContext: EnvironmentContext,
    unsafeTokenizer: TiktokenTokenizer, safeTokenizer: TiktokenTokenizer
  ) -> [Int32] {
    var sections: [SystemPromptSection] = [(systemPromptTemplate, true)]
    sections = reasoningEffort.emitSections(sections)
    sections = skillCatalog.emitSections(sections)
    sections = projectContext.emitSections(sections)
    sections = environmentContext.emitSections(sections)
    sections = memoryContext.emitSections(sections)
    return tokenizeSystemPromptSections(
      sections, unsafeTokenizer: unsafeTokenizer, safeTokenizer: safeTokenizer)
  }

}
