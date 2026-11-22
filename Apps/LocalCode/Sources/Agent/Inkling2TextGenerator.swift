import LLM
import NNC
import ProjectHistoryManager
import Tokenizer

public protocol Inkling2KVCache: DeepSeekKVCache {
  /// Whether it holds no layers yet, so that the next decode restores what the context cache has.
  var isEmpty: Bool { get }
}

/// Inkling 2 Small and Inkling 2 Mini share a tokenizer, a chat format and image placeholders, so
/// one agent runs either.
public protocol Inkling2TextGenerator: TextGenerator {
  associatedtype KVCache: Inkling2KVCache
  associatedtype ContextCache: DeepSeekContextCache

  /// The longest context the agent keeps before it compacts.
  static var contextWindowLength: Int { get }
  var chunkedPrefillMaxLength: Int { get }
  var checkpointStride: Int { get }
  var statistics: DeepSeekGenerationStatistics { get }
  /// The latest decode on its own; `statistics` averages the recent ones.
  var lastInteractionStatistics: DeepSeekGenerationStatistics { get }
  static func imageTokenCount(filePath: String) -> Int?

  /// Pause retains one pending prediction; abort returns only evaluated tokens. A context that ends
  /// in end of sentence, such as a pending one a pause returned, is evaluated and generates nothing.
  mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool, kvCache: inout KVCache,
    contextTokens: [Int32], contextCache: ContextCache,
    embedSpans: [EmbedSpan], projectPath: String?,
    continuationHandler: (Int, Int, [Int32], DeepSeekGenerationStatistics) ->
      DeepSeekGenerationContinuationState
  ) -> [Int32]
}

extension Inkling2SmallTextGenerator: Inkling2TextGenerator {
  public static var contextWindowLength: Int { 256 * 1_024 }
}

extension Inkling2SmallTextGenerator.KVCache: Inkling2KVCache {
  public var isEmpty: Bool { layers.isEmpty }
}

extension Inkling2SmallContextCache: DeepSeekContextCache {}

extension Inkling2MiniTextGenerator: Inkling2TextGenerator {}

extension Inkling2MiniTextGenerator.KVCache: Inkling2KVCache {
  public var isEmpty: Bool { layers.isEmpty }
}

extension Inkling2MiniContextCache: DeepSeekContextCache {}
