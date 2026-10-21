import LLM
import NNC
import ProjectHistoryManager
import Tokenizer

public enum DeepSeekGenerationContinuationState {
  case `continue`, pause, abort
}

public struct DeepSeekGenerationStatistics: Sendable {
  public var prefillDurationSoFar: Float
  public var prefillTokensSoFar: Int
  public var tokenGenerationDurationSoFar: Float
  public var tokenGeneratedSoFar: Int

  public var prefillTokensPerSecond: Float {
    guard prefillDurationSoFar > 0 else { return 0 }
    return Float(prefillTokensSoFar) / prefillDurationSoFar
  }

  public var tokenGeneratedPerSecond: Float {
    guard tokenGenerationDurationSoFar > 0 else { return 0 }
    return Float(tokenGeneratedSoFar) / tokenGenerationDurationSoFar
  }

  public init(
    prefillDurationSoFar: Float = 0,
    prefillTokensSoFar: Int = 0,
    tokenGenerationDurationSoFar: Float = 0,
    tokenGeneratedSoFar: Int = 0
  ) {
    self.prefillDurationSoFar = prefillDurationSoFar
    self.prefillTokensSoFar = prefillTokensSoFar
    self.tokenGenerationDurationSoFar = tokenGenerationDurationSoFar
    self.tokenGeneratedSoFar = tokenGeneratedSoFar
  }
}

public protocol DeepSeekKVCache {
  init()
  /// Preserve mutable local windows; append-only global KV can remain shared.
  func snapshot() -> Self
}

public protocol DeepSeekContextCache: ContextCache {
  init(projectPath: String?, checkpointStride: Int)
  /// A cache at `storePath` that restores at most `maximumRestoredTokenLength` tokens and, when
  /// read-only, saves nothing.
  init(
    storePath: String, checkpointStride: Int, isReadOnly: Bool, maximumRestoredTokenLength: Int)
  /// How many tokens the latest restore brought back, or nil before any restore.
  var restoredTokenLength: Int? { get }
}

public protocol DeepSeekTextGenerator: TextGenerator {
  associatedtype KVCache: DeepSeekKVCache
  associatedtype ContextCache: DeepSeekContextCache

  static var version: LLMVersion { get }
  static var unsafeTokenizer: TiktokenTokenizer { get }
  static var safeTokenizer: TiktokenTokenizer { get }
  var chunkedPrefillMaxLength: Int { get }
  var statistics: DeepSeekGenerationStatistics { get }
  /// The latest decode on its own; `statistics` averages the recent ones.
  var lastInteractionStatistics: DeepSeekGenerationStatistics { get }
  static var isImageSupported: Bool { get }
  static func imageTokenCount(filePath: String) -> Int?

  /// Pause retains one pending prediction; abort returns only evaluated tokens.
  mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool, kvCache: inout KVCache,
    contextTokens: [Int32], contextCache: ContextCache,
    embedSpans: [EmbedSpan], projectPath: String?,
    continuationHandler: (Int, Int, [Int32], DeepSeekGenerationStatistics) ->
      DeepSeekGenerationContinuationState
  ) -> [Int32]
}

extension DeepSeekTextGenerator {
  public static var isImageSupported: Bool { false }

  /// Checkpoints land on whole prefill chunks and on every compressor boundary: the chunk length
  /// rounded down to a multiple of 4,096 tokens, and at least 4,096.
  public var checkpointStride: Int { max(4_096, chunkedPrefillMaxLength / 4_096 * 4_096) }

  public static func imageTokenCount(filePath: String) -> Int? {
    nil
  }

  public var safeTokenizer: TiktokenTokenizer { Self.safeTokenizer }
}
