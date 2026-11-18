import Atomics
import BashToolContext
import DataModels
import Dispatch
import Foundation
import LLM
import NNC
import ProjectHistoryManager
import Tokenizer
import os.lock

extension Inkling2CodeAgent {
  /// The chat template's thinking effort levels. `none` is thinking turned off.
  public enum ReasoningEffort: Int {
    case high
    case max
    case low
    case medium
    case none

    init(_ reasoningEffort: CodeAgentReasoningEffort) {
      switch reasoningEffort {
      case .low: self = .low
      case .medium: self = .medium
      case .high: self = .high
      case .max: self = .max
      }
    }

    /// As the chat template writes it, from its `effort_map`.
    var level: String {
      switch self {
      case .none: return "0"
      case .low: return "0.2"
      case .medium: return "0.7"
      case .high: return "0.9"
      case .max: return "0.99"
      }
    }

    func emitSections(_ sections: [SystemPromptSection]) -> [SystemPromptSection] {
      sections.map {
        (
          $0.text.replacingOccurrences(of: "{{REASONING_EFFORT}}", with: level),
          $0.allowsSpecialTokens
        )
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

/// Separates generated tokens into the content of a leading thinking message and everything after
/// it, token by token as they stream. The model opens its own messages, so a `<|message_model|>` is
/// held until the content marker after it shows whether the message is thinking.
struct Inkling2ThinkingSplitter {
  private enum Phase {
    case pending
    case thinking
    case ended
  }

  private var phase = Phase.pending
  private var heldTokens = [Int32]()

  var isThinkingEnded: Bool { phase == .ended }

  /// Where `token` goes: thinking content, or output tokens (with any held before it). Markers of
  /// the thinking message go nowhere.
  mutating func append(_ token: Int32) -> (thinking: [Int32], output: [Int32]) {
    switch phase {
    case .pending:
      if token == Inkling2CodeAgent.modelMessageToken && heldTokens.isEmpty {
        heldTokens.append(token)
        return ([], [])
      }
      if token == Inkling2CodeAgent.thinkingContentToken {
        heldTokens = []
        phase = .thinking
        return ([], [])
      }
      phase = .ended
      let output = heldTokens + [token]
      heldTokens = []
      return ([], output)
    case .thinking:
      if token == Inkling2CodeAgent.endMessageToken {
        phase = .ended
        return ([], [])
      }
      return ([token], [])
    case .ended:
      return ([], [token])
    }
  }

  /// Tokens still held when the output ends.
  mutating func finish() -> [Int32] {
    let held = heldTokens
    heldTokens = []
    return held
  }

  static func split(_ tokens: [Int32]) -> (thinking: [Int32], output: [Int32]) {
    var splitter = Inkling2ThinkingSplitter()
    var thinking = [Int32]()
    var output = [Int32]()
    for token in tokens {
      let split = splitter.append(token)
      thinking += split.thinking
      output += split.output
    }
    return (thinking, output + splitter.finish())
  }
}

public final class Inkling2CodeAgent: CodeAgent {
  public typealias KVCache = Inkling2SmallTextGenerator.KVCache
  public typealias ContextCache = Inkling2SmallContextCache
  static let endOfTextToken: Int32 = 199_999
  static let userMessageToken: Int32 = 200_000
  static let modelMessageToken: Int32 = 200_001
  static let systemMessageToken: Int32 = 200_002
  static let toolMessageToken: Int32 = 200_003
  static let textContentToken: Int32 = 200_004
  static let imageContentToken: Int32 = 200_005
  /// `<|content_model_end_sampling|>` ends the model's turn.
  static let endOfTurnToken: Int32 = 200_006
  static let thinkingContentToken: Int32 = 200_008
  static let endMessageToken: Int32 = 200_010
  static let toolErrorContentToken: Int32 = 200_022
  static let invokeToolJSONContentToken: Int32 = 200_049
  static let invokeToolTextContentToken: Int32 = 200_057
  static var imageToken: Int32 { Inkling2SmallVisionConfiguration.inkling2Small.imageTokenID }
  static let stopTokens: Set<Int32> = [endOfTurnToken, endOfTextToken]
  static let roleTokens: Set<Int32> = [
    userMessageToken, modelMessageToken, systemMessageToken, toolMessageToken,
  ]
  static let contentTokens: Set<Int32> = [
    textContentToken, imageContentToken, thinkingContentToken, toolErrorContentToken,
    invokeToolJSONContentToken, invokeToolTextContentToken,
  ]

  private let thinkingBudgetStorage = ManagedAtomic<Int32>(131_072)
  private let deterministicStorage = ManagedAtomic<Bool>(false)
  private let reasoningEffortStorage: ManagedAtomic<Int>
  private var systemTokens: [Int32]
  private var prefixTokens: [Int32]
  private var prefixEmbedSpans: [EmbedSpan]
  public var bashUserInteraction: BashUserInteraction { bashToolContext.bashUserInteraction }

  private var bashToolContext: BashToolContext
  /// Where the current or paused turn runs its tools and keeps its caches.
  private var environment: any CodeAgentEnvironment = ProjectEnvironment()
  private var textGenerator: Inkling2SmallTextGenerator
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

  /// The reminder as a user message of its own, or empty without one.
  private var systemReminderTokens: [Int32]
  private let systemReminderDelimiters: (start: [Int32], end: [Int32])
  private var shouldInjectSystemReminder: Bool
  private let graph: DynamicGraph
  private let streamContext: StreamContext
  private var kvCache: KVCache
  private var cachedTokenLength = 0
  public private(set) var restoredTokenLength = 0
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

  // The effort the system prompt was tokenized with, `none` while thinking is off. The KV cache
  // holds it.
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
      return parseSuspendedGeneration(generation.outputTokens)
        .result(toolCallHistory: state.toolCallHistory)
    }
    return CodeAgentResult(
      thinkTokens: state.thinkTokens, outputTokens: state.outputTokens,
      think: safeTokenizer.decode(state.thinkTokens),
      output: safeTokenizer.decode(state.outputTokens),
      logTokens: state.didCompact ? prefixTokens : state.logTokens,
      embedSpans: state.didCompact ? prefixEmbedSpans : (state.logEmbedSpans ?? []),
      compacted: state.didCompact,
      toolCalls: state.toolExecution?.toolCalls ?? [], toolCallHistory: state.toolCallHistory,
      incompleteToolCall: nil, hasIncompleteToolCall: false, memoryContext: nil,
      systemSeenMemoryContext: nil)
  }

  // Results carry only the visible text, so there is nothing to remove or render.
  public var toolCallStart: String { "" }
  public var toolCallEnd: String { "" }
  public var toolCallSpecialTokens: [Int32: String] { [:] }

  public init(
    textGenerator: Inkling2SmallTextGenerator,
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
        text: "<system-reminder>\n", addSpecialTokens: false
      ).0,
      end: safeTokenizer.tokenize(
        text: "</system-reminder>\n", addSpecialTokens: false
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
    systemPromptTemplate: String, reasoningEffort: ReasoningEffort,
    skillCatalog: SkillCatalog,
    environmentContext: EnvironmentContext,
    unsafeTokenizer: TiktokenTokenizer, safeTokenizer: TiktokenTokenizer
  ) -> [Int32] {
    var sections: [SystemPromptSection] = [(systemPromptTemplate, true)]
    sections = reasoningEffort.emitSections(sections)
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
    return [userMessageToken, textContentToken]
      + safeTokenizer.tokenize(text: systemReminder + "\n", addSpecialTokens: false).0
      + [endMessageToken]
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
      _ requests: [(id: Int32, request: ToolCall.Request)],
      environment: any CodeAgentEnvironment, context: BashToolContext
    ) {
      for (id, request) in requests {
        group.enter()
        environment.invoke(
          request, context: context, isImageSupported: true
        ) { [weak self] response in
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
    var thinkingBudget: Int
    var reasoningEffort: Int?
    var deterministic: Bool
    var seed: UInt32
    var shouldSetSeed = true
    var userTokens: [Int32]
    var isToolResultTurn = false
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
      thinkingBudget: Int, deterministic: Bool, seed: UInt32, userTokens: [Int32],
      compactionPromptTokens: [Int32], continuationTokens: [Int32],
      prefixTokens: [Int32], shouldInjectSystemReminder: Bool, file: String, threadId: Int64
    ) {
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
  }

  private struct ParsedSuspendedGeneration {
    var thinkTokens: [Int32]
    /// Everything after the thinking message, markers and calls included, which counts as output
    /// while it streams.
    var outputTokens: [Int32]
    var think: String
    var output: String
    var parser: Inkling2ToolCallParser

    /// A finished turn keeps only its visible text, which history shows decoded as it is.
    func visibleOutputTokens(_ tokenizer: TiktokenTokenizer) -> [Int32] {
      tokenizer.tokenize(text: output, addSpecialTokens: false).0
    }

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
    environment: any CodeAgentEnvironment = ProjectEnvironment(),
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    precondition(suspensionState == nil && temporaryState == nil)
    self.environment = environment
    // The chat template renders a user message's parts as messages of their own, in order: each
    // image after its label, then the text.
    var userTokens = [Int32]()
    var imageSpans = [EmbedSpan]()
    for path in imagePaths {
      guard let cachePath = environment.cachePath else { continue }
      let store = EmbedsFileStore(projectPath: cachePath)
      let filePath =
        (path as NSString).isAbsolutePath
        ? path : (cachePath as NSString).appendingPathComponent(path)
      guard let digest = try? store.insert(filePath: filePath),
        let count = Inkling2SmallTextGenerator.imageTokenCount(
          filePath: store.filePath(for: digest))
      else { continue }
      userTokens += Self.message(
        Self.userMessageToken,
        safeTokenizer.tokenize(text: "Image from \(path):", addSpecialTokens: false).0)
      userTokens += [Self.userMessageToken, Self.imageContentToken]
      imageSpans.append(
        EmbedSpan(
          start: Int64(userTokens.count), length: Int64(count), digest: Array(digest),
          kind: .image))
      userTokens += Array(repeating: Self.imageToken, count: count)
      userTokens.append(Self.endMessageToken)
    }
    if userTokens.isEmpty || !prompt.isEmpty {
      userTokens += Self.message(
        Self.userMessageToken, safeTokenizer.tokenize(text: prompt, addSpecialTokens: false).0)
    }
    bashToolContext = bashToolContext.with(bashUserInteraction: BashUserInteraction())
    if isMemoryEnabled != !systemSeenMemoryContext.isEmpty {
      setSystemReminderTokensAndMemoryContext(
        isMemoryEnabled ? environment.loadMemoryContext() : .empty)
    }
    if temporary {
      let cache = graph.withStream(streamContext) {
        graph.withNoGrad { kvCache.snapshot() }
      }
      graph.joined()
      temporaryState = TemporaryState(
        systemTokens: systemTokens, reasoningEffort: systemPromptReasoningEffort,
        prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
        cachedTokenLength: cachedTokenLength,
        shouldInjectSystemReminder: shouldInjectSystemReminder, kvCache: cache)
    }
    let thinkingBudget = Int(self.thinkingBudget)
    let deterministic = self.deterministic
    let seedHash = ContextCachePrefixHasher.hash(tokens: userTokens, embeddingSpans: imageSpans)
    let seed = seedHash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let compactionPromptTokens = Self.message(
      Self.userMessageToken,
      safeTokenizer.tokenize(text: Self.contextCheckpointCompactionPrompt, addSpecialTokens: false)
        .0)
    let continuationTokens = Self.message(
      Self.userMessageToken,
      safeTokenizer.tokenize(text: Self.continueAfterCompactionPrompt, addSpecialTokens: false).0)
    var state = SuspensionState(
      thinkingBudget: thinkingBudget, deterministic: deterministic, seed: seed,
      userTokens: userTokens,
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
      preconditionFailure("Inkling2CodeAgent.resume requires a suspended turn")
    }
    suspensionState = nil
    return runSuspended(state, progress: progress)
  }

  public func hibernate(threadId: Int64) throws {
    guard var state = suspensionState else {
      preconditionFailure("Inkling2CodeAgent.hibernate requires a suspended turn")
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
    ContextCache(
      projectPath: environment.cachePath, checkpointStride: textGenerator.checkpointStride
    ).saveSuspension(data, threadId: threadId)
  }

  @discardableResult
  public func restoreSuspension(
    threadId: Int64, environment: any CodeAgentEnvironment
  ) throws -> Bool {
    precondition(temporaryState == nil)
    guard
      let data = ContextCache(
        projectPath: environment.cachePath, checkpointStride: textGenerator.checkpointStride
      ).loadSuspension(threadId: threadId)
    else { return false }
    var state = try JSONDecoder().decode(SuspensionState.self, from: data)
    guard state.file == URL(fileURLWithPath: textGenerator.filePath).lastPathComponent else {
      return false
    }
    self.environment = environment
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
      let userStart = prefixTokens.firstIndex(of: Self.userMessageToken)
    {
      // The reminder precedes the first user message, including when enabled mid-conversation.
      prefixEmbedSpans = EmbedSpan.replacingTokens(
        prefixEmbedSpans, range: userStart..<userStart,
        replacementCount: systemReminderTokens.count)
      prefixTokens.insert(contentsOf: systemReminderTokens, at: userStart)
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
    // The effort is a system message, so thinking turned off is effort 0 there.
    let reasoningEffort =
      state.thinkingBudget > 0
      ? state.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:)) ?? self.reasoningEffort
      : .none
    if reasoningEffort != systemPromptReasoningEffort {
      systemTokens = Self.systemTokens(
        systemPromptTemplate: systemPromptTemplate, reasoningEffort: reasoningEffort,
        skillCatalog: skillCatalog,
        environmentContext: environmentContext, unsafeTokenizer: unsafeTokenizer,
        safeTokenizer: safeTokenizer)
      systemPromptReasoningEffort = reasoningEffort
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
          projectPath: environment.cachePath, checkpointStride: textGenerator.checkpointStride)
        // Checkpoints save from inside the mutating `textGenerator.decode` callback, so they must
        // not read `textGenerator` again.
        let suspensionCache = ContextCache(
          projectPath: environment.cachePath, checkpointStride: textGenerator.checkpointStride)
        let thinkingBudget = state.thinkingBudget
        let deterministic = state.deterministic
        var userTokens = state.userTokens
        var isToolResultTurn = state.isToolResultTurn
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
          state.isToolResultTurn = isToolResultTurn
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

        // The previous round's calls are in the context, so their completed results must follow
        // even when the user stops before the next round.
        func keepToolResults() {
          logEmbedSpans += userEmbedSpans.map { $0.offset(by: logTokens.count) }
          prefixEmbedSpans += userEmbedSpans.map { $0.offset(by: prefixTokens.count) }
          logTokens += userTokens
          prefixTokens += userTokens
        }

        func beginContextCheckpointCompaction(
          continueWith tokens: [Int32]?, embedSpans: [EmbedSpan] = []
        ) {
          compactionState = .handoffSummary
          prefixTokensBeforeContextCheckpointCompaction = prefixTokens
          state.prefixEmbedSpansBeforeContextCheckpointCompaction = prefixEmbedSpans
          shouldReinsertSystemReminderAfterCompaction = !systemReminderTokens.isEmpty
          tokensToContinueAfterContextCheckpointCompaction = tokens
          state.embedSpansToContinueAfterContextCheckpointCompaction = embedSpans
          userEmbedSpans = []
          userTokens = state.compactionPromptTokens
          isToolResultTurn = false
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
            let systemReminderTokensForThisTurn: [Int32]
            if compactionState == .bridge && shouldReinsertSystemReminderAfterCompaction {
              systemReminderTokensForThisTurn = systemReminderTokens
            } else if compactionState == .none && shouldInjectSystemReminder && !isToolResultTurn {
              systemReminderTokensForThisTurn = systemReminderTokens
            } else {
              systemReminderTokensForThisTurn = []
            }
            // There is no generation prompt: the model opens its own message.
            let userTurnTokens = systemReminderTokensForThisTurn + userTokens
            let expectedTokenOffset = systemTokens.count + prefixTokens.count
            // The context only grows, so a shorter cache is a prefix that decoding extends.
            if cachedTokenLength > expectedTokenOffset {
              kvCache = KVCache()
              cachedTokenLength = 0
            }
            let contextTokens = systemTokens + prefixTokens + userTurnTokens
            let thisThinkingBudget =
              thinkingBudget > 0
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
            thisGeneration.userTurnEmbedSpans = userEmbedSpans.map {
              $0.offset(by: systemReminderTokensForThisTurn.count)
            }
            thisGeneration.baseContextEmbedSpans =
              prefixEmbedSpans.map { $0.offset(by: systemTokens.count) }
              + (thisGeneration.userTurnEmbedSpans ?? []).map { $0.offset(by: expectedTokenOffset) }
            state.thisGeneration = thisGeneration
            generation = thisGeneration
          }
          let thisThinkingBudget = generation.thinkingBudget
          if var toolExecution = state.toolExecution {
            let latestParsed = parseSuspendedGeneration(generation.outputTokens)
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
            let reason = latestParsed.output.trimmingCharacters(in: .whitespacesAndNewlines)
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
              environment: environment)
            isToolResultTurn = true
            state.toolExecution = nil
            state.thisGeneration = nil
            if state.stopAfterTools {
              keepToolResults()
              break
            }
            continue
          }
          let existingOutputTokens = generation.outputTokens
          let outputTokensBeforeDecode: [Int32]
          let inputTokens: [Int32]
          let tokenOffset: Int
          let contextTokens: [Int32]
          if cachedTokenLength < generation.baseContextTokens.count {
            // Replay all but the last output token, which decoding predicts again. An interrupted
            // replay can leave the cache partway through the base context, so replay from there.
            outputTokensBeforeDecode = Array(existingOutputTokens.dropLast())
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
          var splitter = Inkling2ThinkingSplitter()
          var toolCallParser = Inkling2ToolCallParser()
          var outputStreamer = unsafeTokenizer.makeTokenStreamer()
          var thinkStreamer = safeTokenizer.makeTokenStreamer()
          var stoppedByUser = generation.stoppedByUser
          var resultAtCompactionTrigger = generation.resultAtCompactionTrigger?.result
          var shouldTriggerCompaction = generation.shouldTriggerCompaction
          func appendGeneratedTokens(_ tokens: [Int32]) {
            for token in tokens where !Self.stopTokens.contains(token) {
              let wasThinkingEnded = splitter.isThinkingEnded
              let split = splitter.append(token)
              incrementalThinkTokens += split.thinking
              incrementalThinkText += thinkStreamer.append(split.thinking)
              if !wasThinkingEnded && splitter.isThinkingEnded {
                incrementalThinkText += thinkStreamer.finish()
              }
              incrementalOutputTokens += split.output
              toolCallParser.append(outputStreamer.append(split.output))
            }
          }
          appendGeneratedTokens(outputTokensBeforeDecode)
          var generated = [Int32]()
          var didPause = false
          let shouldRestoreFromCache = kvCache.layers.isEmpty
          restoredTokenLength = 0
          let tokenGPU = graph.variable(Tensor<Int32>(inputTokens).toGPU(0))
          let thisOutputTokens = textGenerator.decode(
            graph: graph, tokens: tokenGPU, tokenOffset: tokenOffset,
            thinkingBudget: thisThinkingBudget, deterministic: deterministic,
            kvCache: &kvCache, contextTokens: contextTokens, contextCache: contextCache,
            embedSpans: generation.baseContextEmbedSpans ?? [], projectPath: environment.cachePath
          ) { prefillStart, prefillLength, tokens, generatorStatistics in
            let statistics = CodeAgentStatistics(
              prefillDurationSoFar: generatorStatistics.prefillDurationSoFar,
              prefillTokensSoFar: generatorStatistics.prefillTokensSoFar,
              tokenGenerationDurationSoFar: generatorStatistics.tokenGenerationDurationSoFar,
              tokenGeneratedSoFar: generatorStatistics.tokenGeneratedSoFar,
              contextUsedTokens: contextTokens.count + tokens.count,
              contextWindowTokens: Self.maximumContextLength)
            if shouldRestoreFromCache, prefillStart > 0 {
              restoredTokenLength = contextCache.restoredTokenLength ?? 0
            }
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
              think: incrementalThinkText, output: toolCallParser.text,
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
          let decodedOutputTokens = outputTokensBeforeDecode + thisOutputTokens
          // A replay stopped before it predicts the dropped token again keeps the saved output.
          generation.outputTokens =
            decodedOutputTokens.count < existingOutputTokens.count
            ? existingOutputTokens : decodedOutputTokens
          generation.stoppedByUser = stoppedByUser
          generation.resultAtCompactionTrigger = resultAtCompactionTrigger.map(SuspendedResult.init)
          generation.shouldTriggerCompaction = shouldTriggerCompaction
          var latestParsed = parseSuspendedGeneration(generation.outputTokens)

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
            // A stop during a tool-result prefill still keeps those results.
            if isToolResultTurn {
              keepToolResults()
            }
            // Finalize earlier completed rounds even if this generation produced no output.
            kvCache = KVCache()
            cachedTokenLength = 0
            break
          }
          // Every returned token has been evaluated, apart from a first-token stop and a pending
          // token at the context limit; a shorter cache is extended on the next turn.
          cachedTokenLength = kvCache.tokenLength
          // The turn ends in <|content_model_end_sampling|>, as the chat template renders it.
          if generation.outputTokens.last == Self.endOfTextToken {
            generation.outputTokens[generation.outputTokens.count - 1] = Self.endOfTurnToken
            kvCache = KVCache()
            cachedTokenLength = 0
          }
          // A stop or the context limit cuts the turn off: close the message it was in, then the
          // turn.
          var forcedTerminalTokens = [Int32]()
          if generation.outputTokens.last != Self.endOfTurnToken {
            let lastBoundary = generation.outputTokens.lastIndex {
              $0 == Self.endMessageToken || $0 == Self.modelMessageToken
                || Self.contentTokens.contains($0)
            }
            if let lastBoundary, generation.outputTokens[lastBoundary] != Self.endMessageToken {
              forcedTerminalTokens.append(Self.endMessageToken)
            }
            forcedTerminalTokens.append(Self.endOfTurnToken)
          }
          // Evaluate the terminal tokens rather than resetting, so a compaction summary extends
          // the cache.
          if !forcedTerminalTokens.isEmpty, cachedTokenLength > 0,
            cachedTokenLength == generation.baseContextTokens.count + generation.outputTokens.count
          {
            let forcedTokenGPU = graph.variable(Tensor<Int32>(forcedTerminalTokens).toGPU(0))
            let forcedTokenOffset = cachedTokenLength
            _ = textGenerator.decode(
              graph: graph, tokens: forcedTokenGPU, tokenOffset: forcedTokenOffset,
              thinkingBudget: 0, deterministic: deterministic, kvCache: &kvCache,
              contextTokens: generation.baseContextTokens + generation.outputTokens
                + forcedTerminalTokens, contextCache: contextCache,
              embedSpans: generation.baseContextEmbedSpans ?? [], projectPath: environment.cachePath
            ) { prefillStart, prefillLength, _, _ in
              return prefillStart < prefillLength ? .continue : .abort
            }
            cachedTokenLength = kvCache.tokenLength
          }
          generation.outputTokens += forcedTerminalTokens
          latestParsed = parseSuspendedGeneration(generation.outputTokens)

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
            // Strip the reminder only after the summary, so the summary turn extended the cache.
            // The bridge turn reinserts it.
            let withoutSystemReminder =
              Self.replaceSystemReminder(
                in: prefixTokens, embedSpans: prefixEmbedSpans, with: [],
                startTokens: systemReminderDelimiters.start,
                endTokens: systemReminderDelimiters.end)
              ?? (tokens: prefixTokens, embedSpans: prefixEmbedSpans)
            let retained = Self.retainedConversationTokens(
              in: withoutSystemReminder.tokens, embedSpans: withoutSystemReminder.embedSpans,
              tokenBudget: Self.contextCheckpointCompactionHistoryTokenBudget)
            prefixTokens = retained.tokens
            prefixEmbedSpans = retained.embedSpans
            userEmbedSpans = []
            userTokens = Self.message(
              Self.userMessageToken,
              safeTokenizer.tokenize(
                text: Self.contextCheckpointCompactionSummaryPrefix + "\n" + handoffSummary,
                addSpecialTokens: false
              ).0)
            isToolResultTurn = false
            kvCache = KVCache()
            cachedTokenLength = 0
            didCompact = true
            compactionState = .bridge
            state.thisGeneration = nil
            continue
          }

          let toolCalls =
            !compactionState.isOn && !stoppedByUser && !shouldTriggerCompaction
            ? latestParsed.parser.toolCalls : []
          if !toolCalls.isEmpty {
            state.thisGeneration = generation
            var toolExecution = SuspendedToolExecution(toolCalls: toolCalls)
            var requests = [(id: Int32, request: ToolCall.Request)]()
            for toolCall in toolCalls {
              if let allowedTools = state.allowedTools,
                !allowedTools.contains(toolCall.request.function)
              {
                toolExecution.responses[toolCall.id] =
                  ToolResponse(
                    text: "Error: This ask only permits: \(allowedTools.joined(separator: ", ")).")
                continue
              }
              requests.append((toolCall.id, toolCall.request))
            }
            if !requests.isEmpty {
              toolExecution.pending = PendingToolInvocations(
                requests, environment: environment,
                context: bashToolContext.with(threadId: state.threadId))
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
              let context = environment.loadMemoryContext()
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
            isToolResultTurn = false
            userEmbedSpans = state.embedSpansToContinueAfterContextCheckpointCompaction ?? []
            state.embedSpansToContinueAfterContextCheckpointCompaction = nil
            state.thisGeneration = nil
            continue
          }

          if shouldTriggerCompaction {
            thinkTokens += latestParsed.thinkTokens
            outputTokens = latestParsed.visibleOutputTokens(safeTokenizer)
            beginContextCheckpointCompaction(continueWith: state.continuationTokens)
            state.thisGeneration = nil
            continue
          }

          thinkTokens += latestParsed.thinkTokens
          outputTokens = latestParsed.visibleOutputTokens(safeTokenizer)
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
          output: safeTokenizer.decode(outputTokens),
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
          ContextCache(
            projectPath: environment.cachePath, checkpointStride: textGenerator.checkpointStride
          ).removeSuspension(threadId: state.threadId)
        }
        suspensionState = nil
        return result
      }
    }
  }

  private func parseSuspendedGeneration(_ tokens: [Int32]) -> ParsedSuspendedGeneration {
    let split = Inkling2ThinkingSplitter.split(tokens.filter { !Self.stopTokens.contains($0) })
    var parser = Inkling2ToolCallParser()
    var streamer = unsafeTokenizer.makeTokenStreamer()
    parser.append(streamer.append(split.output))
    parser.append(streamer.finish())
    parser.finish()
    return ParsedSuspendedGeneration(
      thinkTokens: split.thinking, outputTokens: split.output,
      think: safeTokenizer.decode(split.thinking), output: parser.text, parser: parser)
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

extension Inkling2CodeAgent {
  /// A text message.
  static func message(_ role: Int32, header: [Int32] = [], _ body: [Int32]) -> [Int32] {
    [role] + header + [textContentToken] + body + [endMessageToken]
  }

  /// Each part of a result is a tool message named after the call, as the chat template renders a
  /// tool message's content parts. Adjacent text parts join into one message, which keeps where
  /// one result ends readable when parsing the log.
  static func toolResultTokens(
    for toolCalls: [ToolCall], responses: [Int32: ToolResponse], tokenizer: TiktokenTokenizer,
    environment: any CodeAgentEnvironment
  ) -> (tokens: [Int32], embedSpans: [EmbedSpan]) {
    var result = [Int32]()
    var embedSpans = [EmbedSpan]()
    for toolCall in toolCalls {
      let response = responses[toolCall.id] ?? ToolResponse(text: "")
      let header = tokenizer.tokenize(text: toolCall.request.function, addSpecialTokens: false).0
      let resultStart = result.count
      var textTokens: [Int32]? = nil
      func appendText() {
        guard let tokens = textTokens else { return }
        result += message(toolMessageToken, header: header, tokens)
        textTokens = nil
      }
      for part in response.content {
        switch part {
        case .text(let text):
          var responseTokens = tokenizer.tokenize(text: text, addSpecialTokens: false).0
          if toolCall.request.function == ToolsRegistry.Tool.read.rawValue {
            if responseTokens.count > readResponsePreviewTokenThreshold {
              responseTokens = previewedReadResponseTokens(
                responseTokens, request: toolCall.request, tokenizer: tokenizer)
            }
          } else if responseTokens.count > toolResponseExternalizationTokenThreshold,
            let compactedTokens = compactedToolResponseTokens(
              responseTokens, tokenizer: tokenizer,
              saveToolResponse: environment.saveToolResponse)
          {
            responseTokens = compactedTokens
          }
          textTokens = (textTokens ?? []) + responseTokens
        case .imageDigest(let digest):
          guard let cachePath = environment.cachePath,
            let count = Inkling2SmallTextGenerator.imageTokenCount(
              filePath: EmbedsFileStore(projectPath: cachePath).filePath(for: digest))
          else { continue }
          appendText()
          result += [toolMessageToken] + header + [imageContentToken]
          embedSpans.append(
            EmbedSpan(
              start: Int64(result.count), length: Int64(count), digest: Array(digest),
              kind: .image))
          result += Array(repeating: imageToken, count: count)
          result.append(endMessageToken)
        }
      }
      appendText()
      // A result with nothing to show is still a message, so each call has one.
      if result.count == resultStart {
        result += message(toolMessageToken, header: header, [])
      }
    }
    return (result, embedSpans)
  }
}
