import Atomics
import BashToolContext
import DataModels
import Dispatch
import Foundation
import NNC
import ProjectHistoryManager
import Tokenizer
import WebSearch
import os.lock

extension DeepSeek4CodeAgent {
  public enum ReasoningEffort: Int {
    case high
    case max
    case low

    init(_ reasoningEffort: CodeAgentReasoningEffort) {
      switch Generator.version {
      case .deepseek_4_flash:
        switch reasoningEffort {
        case .low, .medium, .high: self = .high
        case .max: self = .max
        }
      case .deepseek_4_1_flash:
        switch reasoningEffort {
        case .low: self = .low
        case .medium, .high: self = .high
        case .max: self = .max
        }
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
        fatalError("DeepSeek reasoning effort requires a DeepSeek model version")
      }
    }

    func emitSections(
      _ sections: [SystemPromptSection], thinkingEnabled: Bool = true
    ) -> [SystemPromptSection] {
      let instructions: String?
      switch Generator.version {
      case .deepseek_4_1_flash:
        let budget: Int
        switch self {
        case .low: budget = 50
        case .high: budget = 75
        case .max: budget = 100
        }
        instructions =
          thinkingEnabled
          ? "Reasoning Effort: \(budget) (range 1-100, the higher the value, the more thorough the reasoning)\n\n"
          : nil
      case .deepseek_4_flash:
        switch self {
        case .low, .high:
          instructions = nil
        case .max:
          instructions =
            "Reasoning Effort: Absolute maximum with no shortcuts permitted.\n"
            + "You MUST be very thorough in your thinking and comprehensively decompose the problem to resolve the root cause, rigorously stress-testing your logic against all potential paths, edge cases, and adversarial scenarios.\n"
            + "Explicitly write out your entire deliberation process, documenting every intermediate step, considered alternative, and rejected hypothesis to ensure absolutely no assumption is left unchecked.\n\n"
        }
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
        fatalError("DeepSeek reasoning effort requires a DeepSeek model version")
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

public final class DeepSeek4CodeAgent<Generator: DeepSeekTextGenerator>: CodeAgent {
  public typealias KVCache = Generator.KVCache
  public typealias ContextCache = Generator.ContextCache
  private static var endOfSentenceToken: Int32 { 1 }
  static var userToken: Int32 { 128_803 }
  private static var assistantToken: Int32 { 128_804 }
  private static var thinkStartToken: Int32 { 128_821 }
  private static var thinkEndToken: Int32 { 128_822 }

  private let thinkingBudgetStorage = ManagedAtomic<Int32>(65_536)
  private let deterministicStorage = ManagedAtomic<Bool>(false)
  private let reasoningEffortStorage: ManagedAtomic<Int>
  private var systemTokens: [Int32]
  private var prefixTokens: [Int32]
  private var prefixEmbedSpans: [EmbedSpan]
  public var bashUserInteraction: BashUserInteraction { bashToolContext.bashUserInteraction }

  private var bashToolContext: BashToolContext
  private var textGenerator: Generator
  private let unsafeTokenizer: TiktokenTokenizer  // Supports the full control-token vocabulary.
  public let safeTokenizer: TiktokenTokenizer  // Prevents user text from injecting control tokens.
  private let skillCatalog: SkillCatalog
  private let projectContext: ProjectContext
  private let environmentContext: EnvironmentContext
  private let systemPromptTemplate: String
  // Keep the frozen prompt snapshot for cache reconstruction. Latest memory belongs to history
  // and the active turn's SuspensionState.
  private var systemSeenMemoryContext: MemoryContext
  // Record a freshly supplied snapshot on the next retained turn.
  private var shouldInjectSystemSeenMemoryContext: Bool

  private var systemReminderTokens: [Int32]
  private let systemReminderDelimiters: (start: [Int32], end: [Int32])
  private var shouldInjectSystemReminder: Bool
  private let graph: DynamicGraph
  private let streamContext: StreamContext
  private var kvCache: KVCache
  private var cachedTokenLength = 0
  private var suspensionState: SuspensionState?
  private var temporaryState: TemporaryState?

  public var thinkingBudget: Int32 {
    get { thinkingBudgetStorage.load(ordering: .acquiring) }
    set { thinkingBudgetStorage.store(newValue, ordering: .releasing) }
  }

  public var deterministic: Bool {
    get { deterministicStorage.load(ordering: .acquiring) }
    set { deterministicStorage.store(newValue, ordering: .releasing) }
  }

  // Track the settings used to tokenize the system prompt and populate the KV cache.
  private var systemPromptThinkingEnabled = true
  private var systemPromptReasoningEffort: ReasoningEffort
  var reasoningEffort: ReasoningEffort {
    get {
      ReasoningEffort(rawValue: reasoningEffortStorage.load(ordering: .acquiring)) ?? .high
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
    if !state.compactionState.isOn, let generation = state.thisGeneration {
      return parseSuspendedGeneration(
        generation.outputTokens, thinkingBudget: generation.thinkingBudget
      ).result(toolCallHistory: state.toolCallHistory)
    }
    return CodeAgentResult(
      thinkTokens: state.thinkTokens, outputTokens: state.outputTokens,
      think: safeTokenizer.decode(state.thinkTokens),
      output: safeTokenizer.decode(
        state.outputTokens, specialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens),
      logTokens: state.didCompact ? prefixTokens : state.logTokens,
      embedSpans: state.didCompact ? prefixEmbedSpans : (state.logEmbedSpans ?? []),
      compacted: state.didCompact,
      toolCalls: state.toolExecution?.toolCalls ?? [], toolCallHistory: state.toolCallHistory,
      incompleteToolCall: nil, hasIncompleteToolCall: false, memoryContext: nil,
      systemSeenMemoryContext: nil)
  }

  static var toolCallFormat: DeepSeek4ToolCallParser.Format {
    DeepSeek4ToolCallParser.Format(version: Generator.version)
  }

  public var toolCallStart: String {
    Self.toolCallFormat.toolCallStart
  }

  public var toolCallEnd: String {
    Self.toolCallFormat.toolCallEnd
  }

  public var toolCallSpecialTokens: [Int32: String] {
    DeepSeek4ToolCallParser.toolCallSpecialTokens
  }

  public init(
    textGenerator: Generator,
    graph: DynamicGraph,
    streamContext: StreamContext,
    unsafeTokenizer: TiktokenTokenizer,
    safeTokenizer: TiktokenTokenizer,
    systemPromptTemplate: String,
    reasoningEffort: ReasoningEffort = .high,
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
    systemReminderTokens = Self.systemReminderTokens(
      projectContext: projectContext, memoryContext: memoryContext,
      safeTokenizer: safeTokenizer)
    let delimiters = (
      start: safeTokenizer.tokenize(
        text: "\n\n<system-reminder>\n", addSpecialTokens: false
      ).0,
      end: safeTokenizer.tokenize(
        text: "</system-reminder>", addSpecialTokens: false
      ).0
    )
    systemReminderDelimiters = delimiters
    shouldInjectSystemReminder =
      Self.replaceSystemReminder(
        in: prefixTokens, with: [],
        startTokens: delimiters.start,
        endTokens: delimiters.end) == nil
      && !systemReminderTokens.isEmpty
    reasoningEffortStorage = ManagedAtomic(reasoningEffort.rawValue)
    systemPromptReasoningEffort = reasoningEffort
    self.graph = graph
    self.streamContext = streamContext
    systemTokens = Self.systemTokens(
      systemPromptTemplate: systemPromptTemplate, reasoningEffort: reasoningEffort,
      skillCatalog: skillCatalog,
      environmentContext: environmentContext,
      unsafeTokenizer: unsafeTokenizer, safeTokenizer: safeTokenizer)
    let prefix = Self.replaceSystemReminder(
      in: prefixTokens, embedSpans: prefixEmbedSpans, with: systemReminderTokens,
      startTokens: delimiters.start, endTokens: delimiters.end)
    self.prefixTokens = prefix?.tokens ?? prefixTokens
    self.prefixEmbedSpans = prefix?.embedSpans ?? prefixEmbedSpans
    self.shouldInjectSystemSeenMemoryContext = shouldInjectSystemSeenMemoryContext
    kvCache = KVCache()
  }

  private static func systemTokens(
    systemPromptTemplate: String, reasoningEffort: ReasoningEffort, thinkingEnabled: Bool = true,
    skillCatalog: SkillCatalog,
    environmentContext: EnvironmentContext,
    unsafeTokenizer: TiktokenTokenizer, safeTokenizer: TiktokenTokenizer
  ) -> [Int32] {
    var sections: [SystemPromptSection] = [(systemPromptTemplate, true)]
    sections = reasoningEffort.emitSections(sections, thinkingEnabled: thinkingEnabled)
    sections = skillCatalog.emitSections(sections)
    sections = environmentContext.emitSections(sections)
    return tokenizeSystemPromptSections(
      sections, unsafeTokenizer: unsafeTokenizer, safeTokenizer: safeTokenizer)
  }

  private static func systemReminderTokens(
    projectContext: ProjectContext, memoryContext: MemoryContext, safeTokenizer: TiktokenTokenizer
  ) -> [Int32] {
    let memorySections = memoryContext.emitSections([(MemoryContext.instructionsPlaceholder, true)])
    let systemReminder = projectContext.emitAsSystemReminder(
      suffix: memorySections.map(\.text).joined())
    guard !systemReminder.isEmpty else { return [] }
    return safeTokenizer.tokenize(text: "\n\n" + systemReminder, addSpecialTokens: false).0
  }

  private enum CompactionState: String, Codable {
    case none
    case handoffSummary
    case bridge

    var isOn: Bool { self != .none }
  }

  private struct SuspendedResult: Codable {
    var thinkTokens: [Int32]
    var outputTokens: [Int32]
    var think: String
    var output: String

    init(_ result: CodeAgentResult) {
      thinkTokens = result.thinkTokens
      outputTokens = result.outputTokens
      think = result.think
      output = result.output
    }

    var result: CodeAgentResult {
      CodeAgentResult(
        thinkTokens: thinkTokens, outputTokens: outputTokens, think: think, output: output,
        logTokens: [], compacted: false, toolCalls: [], toolCallHistory: [],
        incompleteToolCall: nil, hasIncompleteToolCall: false, memoryContext: nil,
        systemSeenMemoryContext: nil)
    }
  }

  private struct SuspendedGeneration: Codable {
    var userTurnTokens: [Int32]
    var baseContextTokens: [Int32]
    var userTurnEmbedSpans: [EmbedSpan]?
    var baseContextEmbedSpans: [EmbedSpan]?
    var thinkingBudget: Int
    var systemReminderTokens: [Int32]
    var outputTokens: [Int32]
    var stoppedByUser = false
    var stoppedForCompletedToolCalls = false
    var shouldTriggerCompaction = false
    var resultAtCompactionTrigger: SuspendedResult?

    init(
      userTurnTokens: [Int32], baseContextTokens: [Int32], thinkingBudget: Int,
      systemReminderTokens: [Int32]
    ) {
      self.userTurnTokens = userTurnTokens
      self.baseContextTokens = baseContextTokens
      self.thinkingBudget = thinkingBudget
      self.systemReminderTokens = systemReminderTokens
      outputTokens = []
    }
  }

  private final class PendingToolInvocations {
    let group = DispatchGroup()
    private var lock = os_unfair_lock()
    private var responses = [Int32: ToolResponse]()

    init(
      _ invocations: [(id: Int32, invocation: ToolsRegistry.Invocation)],
      context: BashToolContext
    ) {
      for (id, invocation) in invocations {
        group.enter()
        invocation.invoke(context: context, isImageSupported: Generator.isImageSupported) {
          [weak self] response in
          guard let self else { return }
          os_unfair_lock_lock(&lock)
          responses[id] = response
          os_unfair_lock_unlock(&lock)
          group.leave()
        }
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
    var toolCalls: [ToolCall]
    var responses: [Int32: ToolResponse]
    var pending: PendingToolInvocations? = nil

    private enum CodingKeys: String, CodingKey {
      case toolCalls
      case responses
    }

    init(toolCalls: [ToolCall]) {
      self.toolCalls = toolCalls
      responses = [:]
    }
  }

  private struct TemporaryState {
    var systemTokens: [Int32]
    var reasoningEffort: ReasoningEffort
    var thinkingEnabled: Bool
    var prefixTokens: [Int32]
    var prefixEmbedSpans: [EmbedSpan]
    var cachedTokenLength: Int
    var shouldInjectSystemReminder: Bool
    var kvCache: KVCache
  }

  private struct SuspensionState: Codable {
    var systemSeenMemoryContext: MemoryContext?
    var memoryContext: MemoryContext?
    var allowedTools: [String]?
    var projectPath: String?
    var workspacePath: String?
    var webSearchProviderIdentifier: String
    var webSearchProviderAPIKey: String
    var thinkingBudget: Int
    var reasoningEffort: Int?
    var deterministic: Bool
    var seed: UInt32
    var shouldSetSeed = true
    var userTokens: [Int32]
    var compactionPromptTokens: [Int32]
    var continuationTokens: [Int32]
    var thinkTokens: [Int32] = []
    var outputTokens: [Int32] = []
    var logTokens: [Int32] = []
    var logEmbedSpans: [EmbedSpan]?
    var userEmbedSpans: [EmbedSpan]?
    var prefixEmbedSpans: [EmbedSpan]?
    var prefixEmbedSpansBeforeContextCheckpointCompaction: [EmbedSpan]?
    var embedSpansToContinueAfterContextCheckpointCompaction: [EmbedSpan]?
    var toolCallHistory: [ToolCall] = []
    var compactionState = CompactionState.none
    var prefixTokensBeforeContextCheckpointCompaction: [Int32]?
    var tokensToContinueAfterContextCheckpointCompaction: [Int32]?
    var shouldReinsertSystemReminderAfterCompaction = false
    var didCompact = false
    var shouldCheckInitialCompaction = true
    var thisGeneration: SuspendedGeneration?
    var toolExecution: SuspendedToolExecution?
    var stopAfterTools = false
    var prefixTokens: [Int32]
    var shouldInjectSystemReminder: Bool
    var file: String
    var threadId: Int64

    init(
      projectPath: String?, workspacePath: String?, webSearchProvider: WebSearchProvider,
      thinkingBudget: Int, deterministic: Bool, seed: UInt32, userTokens: [Int32],
      compactionPromptTokens: [Int32], continuationTokens: [Int32],
      prefixTokens: [Int32], shouldInjectSystemReminder: Bool, file: String, threadId: Int64
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
      self.compactionPromptTokens = compactionPromptTokens
      self.continuationTokens = continuationTokens
      self.prefixTokens = prefixTokens
      self.shouldInjectSystemReminder = shouldInjectSystemReminder
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
    var parser: DeepSeek4ToolCallParser

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
        let count = Generator.imageTokenCount(filePath: store.filePath(for: digest))
      else { continue }
      // Label each image with its path as given; the official encoding joins blocks with "\n\n".
      let (_, labelTokens, _, _, _) = safeTokenizer.tokenize(
        text: (imageTokens.isEmpty ? "" : "\n\n") + "Image from \(path):\n\n", truncation: false,
        maxLength: 0, paddingToken: nil, addSpecialTokens: false)
      imageTokens += labelTokens
      imageSpans.append(
        EmbedSpan(
          start: Int64(imageTokens.count), length: Int64(count), digest: Array(digest),
          kind: .image))
      imageTokens += Array(repeating: 129_264, count: count)
    }
    bashToolContext = bashToolContext.with(bashUserInteraction: BashUserInteraction())
    if isMemoryEnabled != !systemSeenMemoryContext.isEmpty {
      setSystemReminderTokensAndMemoryContext(
        isMemoryEnabled ? MemoryContext.load(projectPath: projectPath) : .empty)
    }
    if temporary {
      let cache = graph.withStream(streamContext) {
        graph.withNoGrad { kvCache.snapshot() }
      }
      graph.joined()
      temporaryState = TemporaryState(
        systemTokens: systemTokens, reasoningEffort: systemPromptReasoningEffort,
        thinkingEnabled: systemPromptThinkingEnabled,
        prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
        cachedTokenLength: cachedTokenLength,
        shouldInjectSystemReminder: shouldInjectSystemReminder, kvCache: cache)
    }
    let thinkingBudget = Int(self.thinkingBudget)
    let deterministic = self.deterministic
    let (_, textTokens, _, _, _) = safeTokenizer.tokenize(
      text: imageTokens.isEmpty || prompt.isEmpty ? prompt : "\n\n" + prompt, truncation: false,
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
      compactionPromptTokens: compactionPromptTokens, continuationTokens: continuationTokens,
      prefixTokens: prefixTokens, shouldInjectSystemReminder: shouldInjectSystemReminder,
      file: URL(fileURLWithPath: textGenerator.filePath).lastPathComponent, threadId: threadId)
    if !temporary, shouldInjectSystemSeenMemoryContext {
      state.systemSeenMemoryContext = systemSeenMemoryContext
      state.memoryContext = systemSeenMemoryContext
    }
    state.prefixEmbedSpans = prefixEmbedSpans
    state.userEmbedSpans = imageSpans
    state.allowedTools = allowedTools?.map(\.rawValue).sorted()
    state.reasoningEffort = reasoningEffort.rawValue
    return runSuspended(state, progress: progress)
  }

  public func resume(
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    guard let state = suspensionState else {
      preconditionFailure("DeepSeek4CodeAgent.resume requires a suspended turn")
    }
    suspensionState = nil
    return runSuspended(state, progress: progress)
  }

  public func hibernate(threadId: Int64) throws {
    guard var state = suspensionState else {
      preconditionFailure("DeepSeek4CodeAgent.hibernate requires a suspended turn")
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
    state.shouldInjectSystemReminder = shouldInjectSystemReminder
    state.threadId = threadId
    suspensionState = state
    graph.joined()
    try saveSuspension(state, threadId: threadId)
    kvCache = KVCache()
    cachedTokenLength = 0
  }

  public func unloadCaches() {
    precondition(temporaryState == nil)
    streamContext.joined()
    kvCache = KVCache()
    cachedTokenLength = 0
  }

  private func saveSuspension(_ state: SuspensionState, threadId: Int64) throws {
    guard temporaryState == nil else { return }
    let data = try JSONEncoder().encode(state)
    DeepSeek4ContextCache(
      projectPath: state.projectPath, checkpointStride: textGenerator.checkpointStride
    ).saveSuspension(data, threadId: threadId)
  }

  @discardableResult
  public func restoreSuspension(threadId: Int64, projectPath: String) throws -> Bool {
    precondition(temporaryState == nil)
    guard
      let data = DeepSeek4ContextCache(
        projectPath: projectPath, checkpointStride: textGenerator.checkpointStride
      ).loadSuspension(threadId: threadId)
    else { return false }
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
    shouldInjectSystemReminder = state.shouldInjectSystemReminder
    kvCache = KVCache()
    cachedTokenLength = 0
    suspensionState = state
    return true
  }

  private func setSystemReminderTokensAndMemoryContext(_ context: MemoryContext) {
    guard context != systemSeenMemoryContext else { return }
    systemSeenMemoryContext = context
    shouldInjectSystemSeenMemoryContext = true
    systemReminderTokens = Self.systemReminderTokens(
      projectContext: projectContext, memoryContext: systemSeenMemoryContext,
      safeTokenizer: safeTokenizer)
    if let updatedPrefix = Self.replaceSystemReminder(
      in: prefixTokens, embedSpans: prefixEmbedSpans, with: systemReminderTokens,
      startTokens: systemReminderDelimiters.start, endTokens: systemReminderDelimiters.end)
    {
      prefixTokens = updatedPrefix.tokens
      prefixEmbedSpans = updatedPrefix.embedSpans
      shouldInjectSystemReminder = false
    } else if !systemReminderTokens.isEmpty,
      let assistantStart = prefixTokens.firstIndex(of: Self.assistantToken)
    {
      // Enabling memory can introduce the first reminder into an existing conversation.
      prefixEmbedSpans = EmbedSpan.replacingTokens(
        prefixEmbedSpans, range: assistantStart..<assistantStart,
        replacementCount: systemReminderTokens.count)
      prefixTokens.insert(contentsOf: systemReminderTokens, at: assistantStart)
      shouldInjectSystemReminder = false
    } else {
      shouldInjectSystemReminder = !systemReminderTokens.isEmpty
    }
    kvCache = KVCache()
    cachedTokenLength = 0
  }

  private func restoreTemporaryState(_ state: TemporaryState) {
    graph.joined()
    systemTokens = state.systemTokens
    systemPromptReasoningEffort = state.reasoningEffort
    systemPromptThinkingEnabled = state.thinkingEnabled
    prefixTokens = state.prefixTokens
    prefixEmbedSpans = state.prefixEmbedSpans
    cachedTokenLength = state.cachedTokenLength
    shouldInjectSystemReminder = state.shouldInjectSystemReminder
    kvCache = state.kvCache
    temporaryState = nil
  }

  private func runSuspended(
    _ initialState: SuspensionState,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    var state = initialState
    let thinkingEnabled = state.thinkingBudget > 0
    let reasoningEffort =
      thinkingEnabled
      ? state.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:)) ?? self.reasoningEffort
      : .high
    let shouldUpdateSystemPrompt: Bool
    switch Generator.version {
    case .deepseek_4_flash:
      shouldUpdateSystemPrompt =
        temporaryState == nil && reasoningEffort != systemPromptReasoningEffort
    case .deepseek_4_1_flash:
      shouldUpdateSystemPrompt =
        reasoningEffort != systemPromptReasoningEffort
        || thinkingEnabled != systemPromptThinkingEnabled
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      fatalError("DeepSeek system prompt requires a DeepSeek model version")
    }
    if shouldUpdateSystemPrompt {
      systemTokens = Self.systemTokens(
        systemPromptTemplate: systemPromptTemplate, reasoningEffort: reasoningEffort,
        thinkingEnabled: thinkingEnabled, skillCatalog: skillCatalog,
        environmentContext: environmentContext, unsafeTokenizer: unsafeTokenizer,
        safeTokenizer: safeTokenizer)
      systemPromptReasoningEffort = reasoningEffort
      systemPromptThinkingEnabled = thinkingEnabled
      kvCache = KVCache()
      cachedTokenLength = 0
    }
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

    return graph.withStream(streamContext) {
      graph.withNoGrad {
        let contextCache = ContextCache(
          projectPath: state.projectPath, checkpointStride: textGenerator.checkpointStride)
        // Checkpoints save from inside the mutating `textGenerator.decode` callback, so they must
        // not read `textGenerator` again.
        let suspensionCache = DeepSeek4ContextCache(
          projectPath: state.projectPath, checkpointStride: textGenerator.checkpointStride)
        let thinkingSuffixTokens = [Self.assistantToken, Self.thinkStartToken]
        let noThinkingSuffixTokens = [Self.assistantToken, Self.thinkEndToken]
        let thinkingBudget = state.thinkingBudget
        let deterministic = state.deterministic
        var userTokens = state.userTokens
        var thinkTokens = state.thinkTokens
        var outputTokens = state.outputTokens
        var logTokens = state.logTokens
        var logEmbedSpans = state.logEmbedSpans ?? []
        var userEmbedSpans = state.userEmbedSpans ?? []
        var toolCallHistory = state.toolCallHistory
        var compactionState = state.compactionState
        var prefixTokensBeforeContextCheckpointCompaction =
          state.prefixTokensBeforeContextCheckpointCompaction
        var tokensToContinueAfterContextCheckpointCompaction =
          state.tokensToContinueAfterContextCheckpointCompaction
        var shouldReinsertSystemReminderAfterCompaction =
          state.shouldReinsertSystemReminderAfterCompaction
        var didCompact = state.didCompact

        func updateSuspensionState() {
          state.userTokens = userTokens
          state.thinkTokens = thinkTokens
          state.outputTokens = outputTokens
          state.logTokens = logTokens
          state.logEmbedSpans = logEmbedSpans
          state.userEmbedSpans = userEmbedSpans
          state.toolCallHistory = toolCallHistory
          state.compactionState = compactionState
          state.prefixTokensBeforeContextCheckpointCompaction =
            prefixTokensBeforeContextCheckpointCompaction
          state.tokensToContinueAfterContextCheckpointCompaction =
            tokensToContinueAfterContextCheckpointCompaction
          state.shouldReinsertSystemReminderAfterCompaction =
            shouldReinsertSystemReminderAfterCompaction
          state.didCompact = didCompact
        }

        func saveCheckpoint(_ generation: SuspendedGeneration) {
          guard temporaryState == nil, state.toolExecution?.pending == nil else { return }
          updateSuspensionState()
          state.prefixTokens = prefixTokens
          state.prefixEmbedSpans = prefixEmbedSpans
          state.shouldInjectSystemReminder = shouldInjectSystemReminder
          var checkpointState = state
          checkpointState.thisGeneration = generation
          guard let data = try? JSONEncoder().encode(checkpointState) else { return }
          suspensionCache.saveSuspension(data, threadId: state.threadId)
        }

        func beginContextCheckpointCompaction(
          continueWith tokens: [Int32]?, embedSpans: [EmbedSpan] = []
        ) {
          compactionState = .handoffSummary
          prefixTokensBeforeContextCheckpointCompaction = prefixTokens
          state.prefixEmbedSpansBeforeContextCheckpointCompaction = prefixEmbedSpans
          if let tokensWithoutSystemReminder = Self.replaceSystemReminder(
            in: prefixTokens, embedSpans: prefixEmbedSpans, with: [],
            startTokens: systemReminderDelimiters.start,
            endTokens: systemReminderDelimiters.end)
          {
            prefixTokens = tokensWithoutSystemReminder.tokens
            prefixEmbedSpans = tokensWithoutSystemReminder.embedSpans
          }
          shouldReinsertSystemReminderAfterCompaction = !systemReminderTokens.isEmpty
          tokensToContinueAfterContextCheckpointCompaction = tokens
          state.embedSpansToContinueAfterContextCheckpointCompaction = embedSpans
          userEmbedSpans = []
          userTokens = state.compactionPromptTokens
        }

        if !isCompactionDisabled, state.shouldCheckInitialCompaction {
          state.shouldCheckInitialCompaction = false
          if systemTokens.count + prefixTokens.count
            > Self.contextCheckpointCompactionTokenThreshold
          {
            beginContextCheckpointCompaction(continueWith: userTokens, embedSpans: userEmbedSpans)
          }
        }
        if state.shouldSetSeed {
          DynamicGraph.setSeed(state.seed)
          state.shouldSetSeed = false
        }
        while true {
          var generation: SuspendedGeneration
          if let thisGeneration = state.thisGeneration {
            generation = thisGeneration
          } else {
            let suffixTokens =
              compactionState == .bridge || thinkingBudget <= 0
              ? noThinkingSuffixTokens : thinkingSuffixTokens
            let systemReminderTokensForThisTurn: [Int32]
            if compactionState == .bridge && shouldReinsertSystemReminderAfterCompaction {
              systemReminderTokensForThisTurn = systemReminderTokens
            } else if compactionState == .none && shouldInjectSystemReminder {
              systemReminderTokensForThisTurn = systemReminderTokens
            } else {
              systemReminderTokensForThisTurn = []
            }
            let userTurnTokens =
              [Self.userToken] + userTokens + systemReminderTokensForThisTurn + suffixTokens
            let expectedTokenOffset = systemTokens.count + prefixTokens.count
            if cachedTokenLength != expectedTokenOffset {
              kvCache = KVCache()
              cachedTokenLength = 0
            }
            let contextTokens = systemTokens + prefixTokens + userTurnTokens
            let thisThinkingBudget =
              thinkingBudget > 0 && compactionState != .bridge
              ? min(
                thinkingBudget,
                max(
                  1,
                  Self.maximumContextLength - contextTokens.count
                    - Self.minimumGenerationReserve))
              : 0
            var thisGeneration = SuspendedGeneration(
              userTurnTokens: userTurnTokens, baseContextTokens: contextTokens,
              thinkingBudget: thisThinkingBudget,
              systemReminderTokens: systemReminderTokensForThisTurn)
            thisGeneration.userTurnEmbedSpans = userEmbedSpans.map { $0.offset(by: 1) }
            thisGeneration.baseContextEmbedSpans =
              prefixEmbedSpans.map { $0.offset(by: systemTokens.count) }
              + (thisGeneration.userTurnEmbedSpans ?? []).map { $0.offset(by: expectedTokenOffset) }
            state.thisGeneration = thisGeneration
            generation = thisGeneration
          }
          let thisThinkingBudget = generation.thinkingBudget
          if var toolExecution = state.toolExecution {
            let latestParsed = parseSuspendedGeneration(
              generation.outputTokens, thinkingBudget: thisThinkingBudget)
            let partialResult = latestParsed.result(toolCallHistory: toolCallHistory)
            if let pending = toolExecution.pending {
              switch waitForToolResponses(
                pending, partialResult: partialResult, progress: progress)
              {
              case .continue, .checkpoint:
                break
              case .pause:
                state.toolExecution = toolExecution
                updateSuspensionState()
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
            let visibleText = ToolCallParser.removeToolCalls(
              latestParsed.output, format: Self.toolCallFormat
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = visibleText.isEmpty ? nil : visibleText
            for index in toolCalls.indices {
              toolCalls[index].response = toolExecution.responses[toolCalls[index].id]
              toolCalls[index].reason = reason
            }
            let turnTokens = generation.userTurnTokens + generation.outputTokens
            logEmbedSpans += (generation.userTurnEmbedSpans ?? []).map {
              $0.offset(by: logTokens.count)
            }
            prefixEmbedSpans += (generation.userTurnEmbedSpans ?? []).map {
              $0.offset(by: prefixTokens.count)
            }
            logTokens += turnTokens
            prefixTokens += turnTokens
            if !generation.systemReminderTokens.isEmpty {
              shouldInjectSystemReminder = false
              shouldReinsertSystemReminderAfterCompaction = false
            }
            toolCallHistory += toolCalls
            thinkTokens += latestParsed.thinkTokens
            // Retained tool results record only the targets observed during this turn.
            if temporaryState == nil, !systemSeenMemoryContext.isEmpty {
              for case let memory? in toolCalls.map({ $0.response?.memory }) {
                state.memoryContext = (state.memoryContext ?? MemoryContext()).replacing(memory)
              }
            }
            (userTokens, userEmbedSpans) = Self.toolResultTokens(
              for: toolCalls, responses: toolExecution.responses, tokenizer: safeTokenizer,
              projectPath: state.projectPath)
            state.toolExecution = nil
            state.thisGeneration = nil
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
              kvCache = KVCache()
              cachedTokenLength = 0
              continue
            }
            tokenOffset = cachedTokenLength
            inputTokens = Array(existingOutputTokens.dropFirst(evaluatedOutputCount))
            contextTokens = generation.baseContextTokens + existingOutputTokens
            outputTokensBeforeDecode = existingOutputTokens
          }
          guard !inputTokens.isEmpty else {
            kvCache = KVCache()
            cachedTokenLength = 0
            continue
          }
          let isEvaluatingPendingGeneratedTokens =
            !existingOutputTokens.isEmpty
            && tokenOffset >= generation.baseContextTokens.count

          var incrementalThinkTokens = [Int32]()
          var incrementalOutputTokens = [Int32]()
          var incrementalThinkText = ""
          var incrementalOutputText = ""
          var toolCallParser = DeepSeek4ToolCallParser(format: Self.toolCallFormat)
          var toolCallStreamer = unsafeTokenizer.makeTokenStreamer()
          var thinkStreamer = safeTokenizer.makeTokenStreamer()
          var outputStreamer = safeTokenizer.makeTokenStreamer(
            specialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens)
          var thinkEnded = thisThinkingBudget <= 0
          var stoppedByUser = generation.stoppedByUser
          var stoppedForCompletedToolCalls = generation.stoppedForCompletedToolCalls
          var resultAtCompactionTrigger = generation.resultAtCompactionTrigger?.result
          var shouldTriggerCompaction = generation.shouldTriggerCompaction
          func appendGeneratedTokens(_ tokens: [Int32]) {
            if thisThinkingBudget > 0 {
              if let endThinkIndex = tokens.firstIndex(of: Self.thinkEndToken) {
                let thinkTokens = tokens[..<endThinkIndex]
                if !thinkTokens.isEmpty {
                  incrementalThinkTokens.append(contentsOf: thinkTokens)
                  incrementalThinkText += thinkStreamer.append(Array(thinkTokens))
                }
                incrementalThinkText += thinkStreamer.finish()
                let outputTokens = tokens[tokens.index(after: endThinkIndex)...].filter {
                  $0 != Self.endOfSentenceToken
                }
                if !outputTokens.isEmpty {
                  incrementalOutputTokens.append(contentsOf: outputTokens)
                  incrementalOutputText += outputStreamer.append(outputTokens)
                  toolCallParser.append(toolCallStreamer.append(outputTokens))
                }
                thinkEnded = true
              } else if !thinkEnded {
                let visibleTokens = tokens.filter { $0 != Self.endOfSentenceToken }
                if !visibleTokens.isEmpty {
                  incrementalThinkTokens += visibleTokens
                  incrementalThinkText += thinkStreamer.append(visibleTokens)
                }
              } else {
                let visibleTokens = tokens.filter { $0 != Self.endOfSentenceToken }
                if !visibleTokens.isEmpty {
                  incrementalOutputTokens += visibleTokens
                  incrementalOutputText += outputStreamer.append(visibleTokens)
                  toolCallParser.append(toolCallStreamer.append(visibleTokens))
                }
              }
            } else {
              let visibleTokens = tokens.filter { $0 != Self.endOfSentenceToken }
              if !visibleTokens.isEmpty {
                incrementalOutputTokens += visibleTokens
                incrementalOutputText += outputStreamer.append(visibleTokens)
                toolCallParser.append(toolCallStreamer.append(visibleTokens))
              }
            }
          }
          appendGeneratedTokens(outputTokensBeforeDecode)
          var generated = [Int32]()
          var didPause = false
          let tokenGPU = graph.variable(Tensor<Int32>(inputTokens).toGPU(0))
          let thisOutputTokens = textGenerator.decode(
            graph: graph, tokens: tokenGPU, tokenOffset: tokenOffset,
            thinkingBudget: thisThinkingBudget, deterministic: deterministic,
            kvCache: &kvCache, contextTokens: contextTokens, contextCache: contextCache,
            embedSpans: generation.baseContextEmbedSpans ?? [], projectPath: state.projectPath
          ) { prefillStart, prefillLength, tokens, generatorStatistics in
            let statistics = CodeAgentStatistics(
              prefillDurationSoFar: generatorStatistics.prefillDurationSoFar,
              prefillTokensSoFar: generatorStatistics.prefillTokensSoFar,
              tokenGenerationDurationSoFar: generatorStatistics.tokenGenerationDurationSoFar,
              tokenGeneratedSoFar: generatorStatistics.tokenGeneratedSoFar,
              contextUsedTokens: contextTokens.count + tokens.count,
              contextWindowTokens: Self.maximumContextLength)
            guard !tokens.isEmpty else {
              cachedTokenLength = tokenOffset + prefillStart
              if isEvaluatingPendingGeneratedTokens { return .continue }
              let decision = progress(
                compactionState.isOn
                  ? .compact(toolCallHistory, prefillStart, prefillLength)
                  : .prefill(toolCallHistory, prefillStart, prefillLength),
                statistics)
              if decision == .pause {
                didPause = true
              }
              if decision == .abort {
                stoppedByUser = true
              }
              return DeepSeekGenerationContinuationState(decision)
            }
            cachedTokenLength = prefillStart
            let newTokens: [Int32]
            if tokens.count > generated.count {
              newTokens = Array(tokens[generated.count..<tokens.count])
            } else {
              newTokens = []
            }
            generated = tokens
            appendGeneratedTokens(newTokens)
            if compactionState.isOn {
              let decision = progress(
                .compact(toolCallHistory, tokens.count, 0), statistics)
              if decision == .pause {
                didPause = true
              }
              if decision == .abort {
                stoppedByUser = true
              }
              return DeepSeekGenerationContinuationState(decision)
            }
            let partialResult = CodeAgentResult(
              thinkTokens: incrementalThinkTokens, outputTokens: incrementalOutputTokens,
              think: incrementalThinkText, output: incrementalOutputText,
              logTokens: [], compacted: false, toolCalls: toolCallParser.toolCalls,
              toolCallHistory: toolCallHistory,
              incompleteToolCall: toolCallParser.incompleteToolCall,
              hasIncompleteToolCall: toolCallParser.hasIncompleteToolCall, memoryContext: nil,
              systemSeenMemoryContext: nil)
            let decision = progress(.generate(partialResult), statistics)
            if decision == .checkpoint, toolCallParser.toolCalls.isEmpty,
              !toolCallParser.hasIncompleteToolCall
            {
              var checkpointGeneration = generation
              checkpointGeneration.outputTokens = outputTokensBeforeDecode + tokens
              checkpointGeneration.stoppedByUser = stoppedByUser
              checkpointGeneration.stoppedForCompletedToolCalls = stoppedForCompletedToolCalls
              checkpointGeneration.resultAtCompactionTrigger =
                resultAtCompactionTrigger.map(SuspendedResult.init)
              checkpointGeneration.shouldTriggerCompaction = shouldTriggerCompaction
              saveCheckpoint(checkpointGeneration)
            }
            if decision == .pause {
              didPause = true
              return .pause
            }
            if decision == .abort {
              stoppedByUser = true
              return .abort
            }
            if toolCallParser.didCompleteToolCallBlock {
              stoppedForCompletedToolCalls = true
              return .abort
            }
            guard !isCompactionDisabled,
              contextTokens.count + generated.count
                > Self.contextCheckpointCompactionTokenThreshold,
              toolCallParser.toolCalls.isEmpty, !toolCallParser.hasIncompleteToolCall
            else { return .continue }
            if let resultAtCompactionTrigger {
              if isCapReachedForStopping(from: resultAtCompactionTrigger, to: partialResult) {
                shouldTriggerCompaction = true
                return .abort
              }
            } else if canStopImmediately(with: partialResult) {
              shouldTriggerCompaction = true
              return .abort
            } else {
              resultAtCompactionTrigger = partialResult
            }
            return .continue
          }
          generation.outputTokens = outputTokensBeforeDecode + thisOutputTokens
          generation.stoppedByUser = stoppedByUser
          generation.stoppedForCompletedToolCalls = stoppedForCompletedToolCalls
          generation.resultAtCompactionTrigger = resultAtCompactionTrigger.map(SuspendedResult.init)
          generation.shouldTriggerCompaction = shouldTriggerCompaction
          var latestParsed = parseSuspendedGeneration(
            generation.outputTokens, thinkingBudget: thisThinkingBudget)

          if didPause {
            state.thisGeneration = generation
            updateSuspensionState()
            suspensionState = state
            return latestParsed.result(toolCallHistory: toolCallHistory)
          }
          if compactionState.isOn && stoppedByUser {
            if let prefixTokensBeforeContextCheckpointCompaction {
              prefixTokens = prefixTokensBeforeContextCheckpointCompaction
              prefixEmbedSpans = state.prefixEmbedSpansBeforeContextCheckpointCompaction ?? []
            }
            compactionState = .none
            shouldReinsertSystemReminderAfterCompaction = false
            kvCache = KVCache()
            cachedTokenLength = 0
            break
          }
          guard !generation.outputTokens.isEmpty else {
            // Finalize earlier completed rounds even if this generation produced no output.
            kvCache = KVCache()
            cachedTokenLength = 0
            break
          }
          if generation.outputTokens.count > 1,
            generation.outputTokens.last == Self.endOfSentenceToken
          {
            // The generator does not report the terminal token through the callback, but it has
            // evaluated that token into the cache. A first-token EOS is only predicted, not cached.
            cachedTokenLength = generation.baseContextTokens.count + generation.outputTokens.count
          }

          var forcedTerminalTokens = [Int32]()
          if stoppedForCompletedToolCalls {
            forcedTerminalTokens.append(Self.endOfSentenceToken)
          } else if stoppedByUser || shouldTriggerCompaction {
            if thisThinkingBudget > 0
              && !generation.outputTokens.contains(Self.thinkEndToken)
            {
              forcedTerminalTokens.append(Self.thinkEndToken)
            }
            if generation.outputTokens.last != Self.endOfSentenceToken {
              forcedTerminalTokens.append(Self.endOfSentenceToken)
            }
          }
          if (stoppedForCompletedToolCalls || stoppedByUser)
            && !forcedTerminalTokens.isEmpty
          {
            let forcedTokenGPU = graph.variable(
              Tensor<Int32>(
                forcedTerminalTokens, kind: .CPU, format: .NHWC,
                shape: [forcedTerminalTokens.count]
              ).toGPU(0))
            let forcedTokenOffset = cachedTokenLength
            _ = textGenerator.decode(
              graph: graph, tokens: forcedTokenGPU, tokenOffset: forcedTokenOffset,
              thinkingBudget: 0, deterministic: deterministic, kvCache: &kvCache,
              contextTokens: generation.baseContextTokens + generation.outputTokens
                + forcedTerminalTokens,
              contextCache: contextCache,
              embedSpans: generation.baseContextEmbedSpans ?? [], projectPath: state.projectPath
            ) { prefillStart, prefillLength, _, _ in
              cachedTokenLength = forcedTokenOffset + prefillStart
              return prefillStart < prefillLength ? .continue : .abort
            }
          } else if shouldTriggerCompaction {
            kvCache = KVCache()
            cachedTokenLength = 0
          }
          generation.outputTokens += forcedTerminalTokens
          latestParsed = parseSuspendedGeneration(
            generation.outputTokens, thinkingBudget: thisThinkingBudget)

          if compactionState == .handoffSummary {
            let handoffSummary = latestParsed.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !handoffSummary.isEmpty else {
              if let prefixTokensBeforeContextCheckpointCompaction {
                prefixTokens = prefixTokensBeforeContextCheckpointCompaction
                prefixEmbedSpans = state.prefixEmbedSpansBeforeContextCheckpointCompaction ?? []
              }
              shouldReinsertSystemReminderAfterCompaction = false
              kvCache = KVCache()
              cachedTokenLength = 0
              break
            }
            let (_, safeHandoffTokens, _, _, _) = safeTokenizer.tokenize(
              text: handoffSummary, truncation: false, maxLength: 0, paddingToken: nil,
              addSpecialTokens: false)
            let retained = Self.retainedConversationTokens(
              in: prefixTokens, embedSpans: prefixEmbedSpans,
              tokenBudget: Self.contextCheckpointCompactionHistoryTokenBudget)
            prefixTokens = retained.tokens
            prefixEmbedSpans = retained.embedSpans
            userEmbedSpans = []
            let (_, summaryPrefixTokens, _, _, _) = safeTokenizer.tokenize(
              text: Self.contextCheckpointCompactionSummaryPrefix + "\n", truncation: false,
              maxLength: 0, paddingToken: nil, addSpecialTokens: false)
            userTokens = summaryPrefixTokens + safeHandoffTokens
            kvCache = KVCache()
            cachedTokenLength = 0
            didCompact = true
            compactionState = .bridge
            state.thisGeneration = nil
            continue
          }

          let toolCalls =
            !compactionState.isOn && latestParsed.parser.didCompleteToolCallBlock
              && !stoppedByUser
            ? latestParsed.parser.toolCalls : []
          if !toolCalls.isEmpty {
            state.thisGeneration = generation
            var toolExecution = SuspendedToolExecution(toolCalls: toolCalls)
            var invocations = [(id: Int32, invocation: ToolsRegistry.Invocation)]()
            for toolCall in toolCalls {
              if let allowedTools = state.allowedTools,
                !allowedTools.contains(toolCall.request.function)
              {
                toolExecution.responses[toolCall.id] =
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
                toolExecution.responses[toolCall.id] =
                  ToolResponse(
                    text:
                      "Tool error: invalid or unknown tool request: \(toolCall.request.function)")
                continue
              }
              invocations.append((toolCall.id, invocation))
            }
            if !invocations.isEmpty {
              toolExecution.pending = PendingToolInvocations(
                invocations,
                context: bashToolContext.with(
                  projectURL: state.projectPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
                  threadId: state.threadId))
            }
            state.toolExecution = toolExecution
            continue
          }

          let turnTokens = generation.userTurnTokens + generation.outputTokens
          logEmbedSpans += (generation.userTurnEmbedSpans ?? []).map {
            $0.offset(by: logTokens.count)
          }
          prefixEmbedSpans += (generation.userTurnEmbedSpans ?? []).map {
            $0.offset(by: prefixTokens.count)
          }
          logTokens += turnTokens
          prefixTokens += turnTokens
          if !generation.systemReminderTokens.isEmpty {
            shouldInjectSystemReminder = false
            shouldReinsertSystemReminderAfterCompaction = false
          }

          if compactionState == .bridge {
            compactionState = .none
            if !systemSeenMemoryContext.isEmpty {
              let context = MemoryContext.load(projectPath: state.projectPath)
              if context != systemSeenMemoryContext {
                setSystemReminderTokensAndMemoryContext(context)
                state.systemSeenMemoryContext = context
                state.memoryContext = context
              }
            }
            prefixTokensBeforeContextCheckpointCompaction = nil
            state.prefixEmbedSpansBeforeContextCheckpointCompaction = nil
            guard let queuedTokens = tokensToContinueAfterContextCheckpointCompaction else {
              break
            }
            tokensToContinueAfterContextCheckpointCompaction = nil
            userTokens = queuedTokens
            userEmbedSpans = state.embedSpansToContinueAfterContextCheckpointCompaction ?? []
            state.embedSpansToContinueAfterContextCheckpointCompaction = nil
            state.thisGeneration = nil
            continue
          }

          if shouldTriggerCompaction {
            thinkTokens += latestParsed.thinkTokens
            outputTokens = latestParsed.outputTokens
            beginContextCheckpointCompaction(continueWith: state.continuationTokens)
            state.thisGeneration = nil
            continue
          }

          thinkTokens += latestParsed.thinkTokens
          outputTokens = latestParsed.outputTokens
          guard !stoppedByUser && !state.stopAfterTools else { break }
          if !isCompactionDisabled,
            systemTokens.count + prefixTokens.count
              > Self.contextCheckpointCompactionTokenThreshold
          {
            beginContextCheckpointCompaction(continueWith: nil)
            state.thisGeneration = nil
            continue
          }
          break
        }

        let result = CodeAgentResult(
          thinkTokens: thinkTokens, outputTokens: outputTokens,
          think: safeTokenizer.decode(thinkTokens),
          output: safeTokenizer.decode(
            outputTokens, specialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens),
          logTokens: didCompact ? prefixTokens : logTokens,
          embedSpans: didCompact ? prefixEmbedSpans : logEmbedSpans,
          compacted: didCompact, toolCalls: [], toolCallHistory: toolCallHistory,
          incompleteToolCall: nil, hasIncompleteToolCall: false,
          memoryContext: state.memoryContext,
          systemSeenMemoryContext: state.systemSeenMemoryContext)
        if temporaryState == nil, !result.isEmpty, state.systemSeenMemoryContext != nil {
          shouldInjectSystemSeenMemoryContext = false
        }
        if temporaryState == nil {
          DeepSeek4ContextCache(
            projectPath: state.projectPath, checkpointStride: textGenerator.checkpointStride
          ).removeSuspension(threadId: state.threadId)
        }
        suspensionState = nil
        return result
      }
    }
  }

  private func parseSuspendedGeneration(
    _ tokens: [Int32], thinkingBudget: Int
  ) -> ParsedSuspendedGeneration {
    let visibleTokens = tokens.filter { $0 != Self.endOfSentenceToken }
    let thinkTokens: [Int32]
    let outputTokens: [Int32]
    if thinkingBudget > 0 {
      if let endThinkIndex = visibleTokens.firstIndex(of: Self.thinkEndToken) {
        thinkTokens = Array(visibleTokens[..<endThinkIndex])
        outputTokens = Array(visibleTokens[visibleTokens.index(after: endThinkIndex)...])
      } else {
        thinkTokens = visibleTokens
        outputTokens = []
      }
    } else {
      thinkTokens = []
      outputTokens = visibleTokens
    }
    var parser = DeepSeek4ToolCallParser(format: Self.toolCallFormat)
    var streamer = unsafeTokenizer.makeTokenStreamer()
    parser.append(streamer.append(outputTokens))
    parser.append(streamer.finish())
    return ParsedSuspendedGeneration(
      thinkTokens: thinkTokens, outputTokens: outputTokens,
      think: safeTokenizer.decode(thinkTokens),
      output: safeTokenizer.decode(
        outputTokens, specialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens),
      parser: parser)
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
}

extension DeepSeekGenerationContinuationState {
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

extension DeepSeek4CodeAgent {
  static func toolResultTokens(
    for toolCalls: [ToolCall], responses: [Int32: ToolResponse], tokenizer: TiktokenTokenizer,
    projectPath: String?
  ) -> (tokens: [Int32], embedSpans: [EmbedSpan]) {
    let (_, separatorTokens, _, _, _) = tokenizer.tokenize(
      text: "\n\n", truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    let (_, toolResultStartTokens, _, _, _) = tokenizer.tokenize(
      text: "<tool_result>", truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    let (_, toolResultEndTokens, _, _, _) = tokenizer.tokenize(
      text: "</tool_result>", truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    var result = [Int32]()
    var embedSpans = [EmbedSpan]()
    for (index, toolCall) in toolCalls.enumerated() {
      if index > 0 {
        result += separatorTokens
      }
      let response = responses[toolCall.id] ?? ToolResponse(text: "")
      result += toolResultStartTokens
      // The official encoding joins a tool result's text and image blocks with "\n\n".
      var hasBlock = false
      for part in response.content {
        switch part {
        case .text(let text):
          let text = text.replacingOccurrences(of: "</tool_result>", with: "&lt;/tool_result>")
          var (_, responseTokens, _, _, _) = tokenizer.tokenize(
            text: text, truncation: false, maxLength: 0, paddingToken: nil,
            addSpecialTokens: false)
          if toolCall.request.function == ToolsRegistry.Tool.read.rawValue {
            if responseTokens.count > readResponsePreviewTokenThreshold {
              responseTokens = previewedReadResponseTokens(
                responseTokens, request: toolCall.request, tokenizer: tokenizer)
            }
          } else if responseTokens.count > toolResponseExternalizationTokenThreshold,
            let compactedTokens = compactedToolResponseTokens(
              responseTokens, tokenizer: tokenizer, projectPath: projectPath)
          {
            responseTokens = compactedTokens
          }
          if hasBlock {
            result += separatorTokens
          }
          result += responseTokens
          hasBlock = true
        case .imageDigest(let digest):
          if let projectPath,
            let count = Generator.imageTokenCount(
              filePath: EmbedsFileStore(projectPath: projectPath).filePath(for: digest))
          {
            if hasBlock {
              result += separatorTokens
            }
            embedSpans.append(
              EmbedSpan(
                start: Int64(result.count), length: Int64(count), digest: Array(digest),
                kind: .image))
            result += Array(repeating: 129_264, count: count)
            hasBlock = true
          }
        }
      }
      result += toolResultEndTokens
    }
    return (result, embedSpans)
  }
}

extension DeepSeek4CodeAgent where Generator == DeepSeek4TextGenerator {
  /// Warm real model weights on disposable state using the agent's inference backend settings.
  @discardableResult
  public static func warmupPrefill(
    _ textGenerator: Generator, graph: DynamicGraph, streamContext: StreamContext
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
}
