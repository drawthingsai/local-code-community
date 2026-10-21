import BashToolContext
import ProjectHistoryManager
import WebSearch

enum CodeAgentReasoningEffort: String, Codable, CaseIterable {
  case low
  case medium
  case high
  case max
}

typealias ReasoningEffort = CodeAgentReasoningEffort

public struct CodeAgentStatistics: Sendable {
  public var prefillDurationSoFar: Float
  public var prefillTokensSoFar: Int
  public var tokenGenerationDurationSoFar: Float
  public var tokenGeneratedSoFar: Int
  public var contextUsedTokens: Int
  public var contextWindowTokens: Int

  public var prefillTokensPerSecond: Float {
    guard prefillDurationSoFar > 0 else { return 0 }
    return Float(prefillTokensSoFar) / prefillDurationSoFar
  }

  public var tokenGeneratedPerSecond: Float {
    guard tokenGenerationDurationSoFar > 0 else { return 0 }
    return Float(tokenGeneratedSoFar) / tokenGenerationDurationSoFar
  }

  public var contextUsed: Double {
    guard contextWindowTokens > 0 else { return 0 }
    return min(max(Double(contextUsedTokens) / Double(contextWindowTokens), 0), 1)
  }

  public init(
    prefillDurationSoFar: Float = 0,
    prefillTokensSoFar: Int = 0,
    tokenGenerationDurationSoFar: Float = 0,
    tokenGeneratedSoFar: Int = 0,
    contextUsedTokens: Int = 0,
    contextWindowTokens: Int = 0
  ) {
    self.prefillDurationSoFar = prefillDurationSoFar
    self.prefillTokensSoFar = prefillTokensSoFar
    self.tokenGenerationDurationSoFar = tokenGenerationDurationSoFar
    self.tokenGeneratedSoFar = tokenGeneratedSoFar
    self.contextUsedTokens = contextUsedTokens
    self.contextWindowTokens = contextWindowTokens
  }
}

public struct CodeAgentResult: Sendable {
  public var thinkTokens: [Int32]
  public var outputTokens: [Int32]
  public var think: String
  public var output: String
  public var logTokens: [Int32]
  public var embedSpans: [EmbedSpan] = []
  public var compacted: Bool
  public var toolCalls: [ToolCall]
  public var toolCallHistory: [ToolCall]
  public var incompleteToolCall: ToolCall?
  public var hasIncompleteToolCall: Bool
  /// A snapshot observed this turn; nil when no memory event occurred. Equal reads still emit.
  public var memoryContext: MemoryContext?
  /// A newly ingested system snapshot; nil when unchanged or during a temporary review.
  public var systemSeenMemoryContext: MemoryContext?

  init(
    thinkTokens: [Int32], outputTokens: [Int32], think: String, output: String,
    logTokens: [Int32], embedSpans: [EmbedSpan] = [], compacted: Bool,
    toolCalls: [ToolCall], toolCallHistory: [ToolCall], incompleteToolCall: ToolCall?,
    hasIncompleteToolCall: Bool, memoryContext: MemoryContext?,
    systemSeenMemoryContext: MemoryContext?
  ) {
    self.thinkTokens = thinkTokens
    self.outputTokens = outputTokens
    self.think = think
    self.output = output
    self.logTokens = logTokens
    self.embedSpans = embedSpans
    self.compacted = compacted
    self.toolCalls = toolCalls
    self.toolCallHistory = toolCallHistory
    self.incompleteToolCall = incompleteToolCall
    self.hasIncompleteToolCall = hasIncompleteToolCall
    self.memoryContext = memoryContext
    self.systemSeenMemoryContext = systemSeenMemoryContext
  }

  public var isEmpty: Bool {
    thinkTokens.isEmpty && output.isEmpty && toolCalls.isEmpty && toolCallHistory.isEmpty
  }

  static let empty = CodeAgentResult(
    thinkTokens: [], outputTokens: [], think: "", output: "", logTokens: [], compacted: false,
    toolCalls: [], toolCallHistory: [], incompleteToolCall: nil, hasIncompleteToolCall: false,
    memoryContext: nil, systemSeenMemoryContext: nil)
}

public enum ContinuationState: Equatable, Sendable {
  case `continue`
  case checkpoint
  case pause
  case abort
}

public enum CodeAgentProgress: Sendable {
  case prefill([ToolCall], Int, Int)
  case generate(CodeAgentResult)
  case toolsWait(CodeAgentResult)
  case compact([ToolCall], Int, Int)
}

public protocol CodeAgent: AnyObject {
  var bashUserInteraction: BashUserInteraction { get }
  var thinkingBudget: Int32 { get set }
  var deterministic: Bool { get set }
  var statistics: CodeAgentStatistics { get }
  var suspendedResult: CodeAgentResult? { get }
  var toolCallStart: String { get }
  var toolCallEnd: String { get }
  var toolCallSpecialTokens: [Int32: String] { get }

  /// A temporary ask restores the original context on completion, retaining its restore point
  /// across pause/resume. Apply a changed isMemoryEnabled before capturing that restore point.
  /// Results and tool side effects remain; the caller decides whether to
  /// persist the result. Conversation compaction and durable suspension are disabled.
  /// Relative image paths resolve against projectPath; each image is labeled with its path as
  /// given, in the model's own format, ahead of the prompt.
  func ask(
    _ prompt: String, imagePaths: [String], isMemoryEnabled: Bool, temporary: Bool,
    allowedTools: Set<ToolsRegistry.Tool>?, threadId: Int64,
    projectPath: String?,
    workspacePath: String?,
    webSearchProvider: WebSearchProvider,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult

  func resume(
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult

  /// Cancels a suspended temporary ask; ordinary suspended turns are persisted.
  func hibernate(threadId: Int64) throws

  /// Release inference caches between turns, preserving the logical conversation state.
  /// Called only on the generation queue when no turn is active.
  func unloadCaches()

  func isCapReachedForStopping(
    from resultAtStop: CodeAgentResult, to result: CodeAgentResult
  ) -> Bool

  func canStopImmediately(with result: CodeAgentResult) -> Bool

  func restoreSuspension(threadId: Int64, projectPath: String) throws -> Bool
}
