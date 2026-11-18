import BinaryResources
import DataModels
import Foundation
import LLM
import NNC
import ProjectHistoryManager
import QuartzCore
import Tokenizer
import os.lock

extension DeviceCapability.WeightsStreaming {
  // Fitted for inkling_2_small_i2x_l40_i3xxs_q4k_imatrix_lgain_q8head_trailer.ckpt on routing
  // traces of the ds4 calibration corpus: 7.08 GiB of non-expert weights stay resident (the head in
  // Q8_0), and each tier's pools fill the rest with experts of 8.42 MiB (layers 0-39) and 14.59 MiB
  // (layers 40-47), allocated to read the fewest bytes per decoded token
  // (benchmark-results/inkling2-small-streaming-20261117, refit in
  // benchmark-results/inkling2-small-generator-20261117).
  fileprivate var expertResidentSlotsForInkling2Small: [Int] {
    switch self {
    case ._8GiB, ._16GiB:
      return [
        20, 20, 12, 8, 8, 8, 12, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 20, 16, 20, 20, 24, 20, 24,
        24, 20, 24, 20, 24, 24, 24, 20, 20, 20, 24, 24, 24, 20, 20, 20, 20, 20, 16, 20, 20, 24, 24,
        28,
      ]
    case ._24GiB:
      return [
        48, 44, 40, 32, 32, 28, 32, 32, 32, 36, 44, 44, 28, 36, 32, 36, 36, 40, 36, 44, 36, 44, 44,
        44, 36, 44, 36, 36, 44, 44, 36, 32, 36, 44, 44, 44, 32, 36, 32, 32, 32, 44, 24, 32, 36, 44,
        52, 52,
      ]
    case ._32GiB:
      return [
        84, 72, 72, 72, 64, 52, 72, 52, 44, 52, 64, 64, 36, 52, 52, 52, 52, 64, 52, 52, 52, 52, 64,
        64, 52, 64, 52, 52, 64, 64, 44, 52, 52, 56, 64, 64, 40, 52, 44, 44, 48, 64, 28, 52, 52, 56,
        64, 76,
      ]
    case ._40GiB:
      return [
        116, 112, 112, 112, 92, 92, 92, 64, 56, 64, 84, 92, 44, 64, 64, 64, 72, 76, 72, 72, 64, 72,
        84, 84, 64, 84, 72, 64, 84, 84, 56, 64, 68, 76, 80, 84, 48, 64, 60, 60, 60, 80, 32, 64, 72,
        72, 84, 96,
      ]
    case ._48GiB:
      return [
        144, 144, 152, 144, 132, 132, 124, 84, 72, 72, 96, 112, 48, 84, 76, 84, 84, 96, 96, 84, 76,
        88, 96, 104, 80, 100, 84, 76, 100, 100, 64, 76, 84, 92, 96, 100, 60, 84, 76, 72, 72, 100,
        40, 84, 92, 92, 104, 112,
      ]
    case ._56GiB:
      return [
        164, 164, 176, 184, 172, 164, 152, 96, 84, 92, 116, 132, 56, 104, 100, 100, 104, 116, 124,
        104, 92, 104, 116, 120, 92, 120, 100, 96, 120, 120, 76, 92, 104, 108, 116, 120, 68, 100, 92,
        88, 84, 116, 48, 100, 108, 108, 116, 128,
      ]
    case ._64GiB:
      return [
        184, 184, 204, 212, 200, 192, 176, 124, 104, 112, 136, 148, 64, 128, 120, 120, 128, 140,
        140, 124, 108, 124, 136, 140, 104, 140, 116, 112, 140, 136, 88, 108, 120, 128, 132, 136, 80,
        116, 108, 100, 100, 136, 56, 120, 124, 124, 128, 140,
      ]
    case ._72GiB:
      return [
        200, 204, 228, 236, 228, 220, 200, 144, 124, 128, 156, 164, 72, 148, 148, 140, 148, 160,
        160, 148, 128, 140, 156, 156, 120, 156, 136, 128, 156, 148, 100, 128, 140, 148, 148, 148,
        88, 136, 128, 120, 116, 156, 64, 136, 144, 140, 144, 156,
      ]
    case .disabled:
      return Array(repeating: 384, count: 48)
    }
  }

  // What the weights hold at this tier: each tier's plan fills it, and 8 GiB shares 16 GiB's.
  var residentSizeForInkling2Small: UInt64 {
    switch self {
    case ._8GiB:
      return 16 * 1_024 * 1_024 * 1_024
    case ._16GiB, ._24GiB, ._32GiB, ._40GiB, ._48GiB, ._56GiB, ._64GiB, ._72GiB:
      return UInt64(rawValue) * 1_024 * 1_024 * 1_024
    case .disabled:
      // The whole inkling_2_small_i2x_l40_i3xxs_q4k_imatrix_lgain_q8head_trailer.ckpt, about
      // 177.76 GiB.
      return 190_873_206_784
    }
  }

  // Treat this tier as a ceiling: pick the largest tier at or below it whose resident weights
  // fit in 72% of available memory, falling back to the smallest tier when none fits.
  func residentTierForInkling2Small(availableMemory: UInt64) -> Self {
    let budget = availableMemory / 25 * 18
    // allCases ascends by resident size, ending with .disabled.
    let ceiling = Self.allCases.firstIndex(of: self)!
    return Self.allCases[...ceiling].last { $0.residentSizeForInkling2Small <= budget } ?? ._8GiB
  }

  // An explicit .disabled always loads every weight. Otherwise the requested tier, or the automatic
  // one when nil, is a ceiling for what fits in the memory available now.
  static func residentTierForInkling2Small(requested: Self?) -> Self {
    guard requested != .disabled else { return .disabled }
    return (requested ?? DeviceCapability.weightsStreaming).residentTierForInkling2Small(
      availableMemory: DeviceCapability.availableMemory)
  }
}

public struct Inkling2SmallTextGenerator {
  public static let estimatedKVCacheSize: UInt64 = 4 * 1_024 * 1_024 * 1_024

  public struct KVCache {
    struct Layer {
      var keys: DynamicGraph.Tensor<Float16>
      var values: DynamicGraph.Tensor<Float16>
      // Key and value convolution rows in FP16, post-attention and post-MLP ones in FP32; then
      // the buffers their next values go to.
      var convolutionRows: [DynamicGraph.AnyTensor]
    }

    public internal(set) var tokenLength = 0
    // Rows of the sliding-window caches, which move their window back to the start when full.
    var slidingTokenLength = 0
    var layers = [Layer]()

    public init() {}

    // Sliding-window caches and convolution rows move in place; full-attention caches only append.
    public func snapshot() -> KVCache {
      var snapshot = self
      let configuration = Inkling2SmallConfiguration.inkling2Small
      for index in layers.indices {
        if !configuration.isFullAttentionLayer(index) {
          snapshot.layers[index].keys = layers[index].keys.copied()
          snapshot.layers[index].values = layers[index].values.copied()
        }
        // Each group of four: key and value rows in FP16, post-attention and post-MLP in FP32.
        snapshot.layers[index].convolutionRows = layers[index].convolutionRows.enumerated().map {
          $0 % 4 < 2 ? $1.as(of: Float16.self).copied() : $1.as(of: Float.self).copied()
        }
      }
      return snapshot
    }
  }

  // <|end_message|> closes the thinking message.
  private static let endThinkToken: Int32 = 200_010
  // <|content_model_end_sampling|> ends the model's turn.
  private static let eosTokenIds = Set<Int32>([200_006, 199_999])
  private static let maximumContextLength = 1_024 * 1_024
  private static let recentStatisticsLimit = 3
  private static let specialTokens: [String: Int32] = {
    var tokens: [String: Int32] = [
      "<|unused|>": 199_998,
      "<|endoftext|>": 199_999,
      "<|message_user|>": 200_000,
      "<|message_model|>": 200_001,
      "<|message_system|>": 200_002,
      "<|message_tool|>": 200_003,
      "<|content_text|>": 200_004,
      "<|content_image|>": 200_005,
      "<|content_model_end_sampling|>": 200_006,
      "<|content_thinking|>": 200_008,
      "<|end_message|>": 200_010,
      "<|content_tool_error|>": 200_022,
      "<|content_xml|>": 200_024,
      "<|begin_of_text|>": 200_028,
      "<|content_invoke_tool_json|>": 200_049,
      "<|content_invoke_tool_text|>": 200_057,
    ]
    // The rest of 200,007-200,056 are reserved, spelled <|unused_ID|> (200,054 is the image
    // placeholder).
    let named = Set(tokens.values)
    for id in Int32(200_007)...200_056 where !named.contains(id) {
      tokens["<|unused_\(id)|>"] = id
    }
    return tokens
  }()

  public static let unsafeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_inkling2_json, merges: BinaryResources.merges_inkling2_txt,
    specialTokens: specialTokens, pretokenizer: .o200kBase, ignoreMerges: true)

  public static let safeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_inkling2_json, merges: BinaryResources.merges_inkling2_txt,
    specialTokens: ["<|endoftext|>": 199_999], pretokenizer: .o200kBase, ignoreMerges: true,
    splitSpecialTokens: true)

  public let filePath: String
  private let configuration: Inkling2SmallConfiguration
  public var statistics: DeepSeekGenerationStatistics {
    guard !recentInteractionStatistics.isEmpty else { return DeepSeekGenerationStatistics() }
    var prefillDurationSoFar: Float = 0
    var prefillTokensSoFar = 0
    var tokenGenerationDurationSoFar: Float = 0
    var tokenGeneratedSoFar = 0
    for statistics in recentInteractionStatistics {
      prefillDurationSoFar += statistics.prefillDurationSoFar
      prefillTokensSoFar += statistics.prefillTokensSoFar
      tokenGenerationDurationSoFar += statistics.tokenGenerationDurationSoFar
      tokenGeneratedSoFar += statistics.tokenGeneratedSoFar
    }
    let count = Float(recentInteractionStatistics.count)
    return DeepSeekGenerationStatistics(
      prefillDurationSoFar: prefillDurationSoFar / count,
      prefillTokensSoFar: Int((Float(prefillTokensSoFar) / count).rounded()),
      tokenGenerationDurationSoFar: tokenGenerationDurationSoFar / count,
      tokenGeneratedSoFar: Int((Float(tokenGeneratedSoFar) / count).rounded()))
  }
  public var lastInteractionStatistics: DeepSeekGenerationStatistics {
    recentInteractionStatistics.last ?? DeepSeekGenerationStatistics()
  }
  private var recentInteractionStatistics = [DeepSeekGenerationStatistics]()
  // Keep this storage model-only: no DynamicGraph, graph tensors, or closures
  // capturing them. Reset may release it on the command thread after decode.
  private final class Storage {
    // Serialize reset with decoding across every value copy of the generator.
    var lock = os_unfair_lock()
    // Expert residency is resolved whenever the decoder is built, so each weights load sees
    // the memory available at that moment.
    private let requestedWeightsStreaming: DeviceCapability.WeightsStreaming?
    private(set) var configuration: Inkling2SmallConfiguration
    var decoderIsLoaded = false
    private var cachedDecoder: ModelBuilder<(cached: Int, sliding: Int, count: Int)>?
    var decoder: ModelBuilder<(cached: Int, sliding: Int, count: Int)> {
      if let cachedDecoder { return cachedDecoder }
      let weightsStreaming = DeviceCapability.WeightsStreaming.residentTierForInkling2Small(
        requested: requestedWeightsStreaming)
      configuration.expertResidentSlots = weightsStreaming.expertResidentSlotsForInkling2Small
      let configuration = self.configuration
      let decoder = ModelBuilder { (shape: (cached: Int, sliding: Int, count: Int), _) in
        Inkling2SmallCausalLM(
          Float16.self, tokenLength: shape.count, cachedTokenLength: shape.cached,
          cachedSlidingTokenLength: shape.sliding, configuration: configuration)
      }
      decoder.maxConcurrency = .limit(4)
      cachedDecoder = decoder
      return decoder
    }
    var isVisionLoaded = false
    private var cachedVision: ModelBuilder<(height: Int, width: Int)>?
    // The vision tower's graph depends on the image's token grid.
    var vision: ModelBuilder<(height: Int, width: Int)> {
      if let cachedVision { return cachedVision }
      let vision = ModelBuilder { (grid: (height: Int, width: Int), _) in
        Inkling2SmallVisionTransformer(Float16.self, grid: grid)
      }
      cachedVision = vision
      return vision
    }

    func reset() {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      cachedDecoder = nil
      decoderIsLoaded = false
      cachedVision = nil
      isVisionLoaded = false
    }

    init(
      configuration: Inkling2SmallConfiguration,
      weightsStreaming: DeviceCapability.WeightsStreaming?
    ) {
      self.configuration = configuration
      requestedWeightsStreaming = weightsStreaming
    }
  }

  // Copies share model storage. Graphs and conversation caches stay on the generation queue.
  private let storage: Storage
  /// The requested tier, or nil for automatic. An explicit `.disabled` disables streaming; otherwise
  /// each weights load resolves the tier it uses from this ceiling and available memory.
  public let weightsStreaming: DeviceCapability.WeightsStreaming?
  public let chunkedPrefillMaxLength: Int
  public let compilePrefillHeadroom: Int

  public init(
    filePath: String, configuration: Inkling2SmallConfiguration = .inkling2Small,
    chunkedPrefillMaxLength: Int, compilePrefillHeadroom: Int = 64 * 1_024,
    weightsStreaming: DeviceCapability.WeightsStreaming? = nil
  ) {
    precondition(chunkedPrefillMaxLength > 0)
    precondition(compilePrefillHeadroom > chunkedPrefillMaxLength)
    precondition(compilePrefillHeadroom <= Self.maximumContextLength)
    precondition(configuration.layers == configuration.expertResidentSlots.count)
    self.filePath = filePath
    self.configuration = configuration
    storage = Storage(configuration: configuration, weightsStreaming: weightsStreaming)
    self.weightsStreaming = weightsStreaming
    self.chunkedPrefillMaxLength = chunkedPrefillMaxLength
    self.compilePrefillHeadroom = compilePrefillHeadroom
  }
}

extension Inkling2SmallTextGenerator {
  /// Drops only shared model weights, waiting for an active decode to return.
  /// Safe from a tool worker; graph-owned conversation caches stay with the agent.
  public func unload() { storage.reset() }

  /// At the requested or automatic tier. A load settles on that tier or a smaller one.
  public var residentWeightsSize: UInt64 {
    (weightsStreaming ?? DeviceCapability.weightsStreaming).residentSizeForInkling2Small
  }

  /// Rows a sliding-window cache holds: its window and a page of rows, so the window moves back
  /// to the start only once a page.
  private var slidingCacheCapacity: Int {
    configuration.slidingWindow - 1 + max(chunkedPrefillMaxLength, 128)
  }

  /// Placeholder tokens (`<|unused_200054|>`) an image takes in the prompt, from its file's size.
  public static func imageTokenCount(filePath: String) -> Int? {
    Inkling2SmallImage.grid(filePath: filePath).map { $0.height * $0.width }
  }

  /// Image embeddings `[tokenCount, hiddenSize]`, loading the vision tower from the same store on
  /// the first image. Nil when the image or the tower cannot load.
  private func encodeImage(graph: DynamicGraph, image: Inkling2SmallImage)
    -> DynamicGraph.Tensor<Float16>?
  {
    guard let patches = image.patches() else { return nil }
    let interpolation = Inkling2SmallVisionPositionInterpolation(
      grid: image.grid, of: Float16.self)
    let inputs: [DynamicGraph.AnyTensor] = [
      graph.variable(Tensor<Float16>(from: patches).toGPU(0)),
      graph.variable(interpolation.indices.toGPU(0)),
      graph.variable(interpolation.weights.toGPU(0)),
      graph.variable(
        Inkling2SmallVisionRotaryEmbedding(grid: image.grid, of: Float16.self).toGPU(0)),
    ]
    let vision = storage.vision
    if !storage.isVisionLoaded {
      vision.compile(image.grid, inputs: inputs)
      let result = try? graph.openStore(filePath, flags: .readOnly) { store in
        try store.read(
          "vision_model", model: vision, strict: true,
          codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)])
      }
      guard let result, (try? result.get()) != nil else { return nil }
      storage.isVisionLoaded = true
    }
    // Outputs belong to the model and are reused by its next call.
    return vision(image.grid, inputs: inputs[0], Array(inputs.dropFirst()))[0]
      .as(of: Float16.self).copied()
  }

  /// Pause retains one pending prediction; abort returns only evaluated tokens. A context that ends
  /// in end of sentence, such as a pending one a pause returned, is evaluated and generates nothing.
  /// `embedSpans` place images, files in `projectPath`'s EmbedsFileStore, over their placeholder
  /// rows of `contextTokens`; an image that cannot load keeps its placeholder rows.
  public mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool = true, kvCache: inout KVCache,
    contextTokens: [Int32], embedSpans: [EmbedSpan] = [], projectPath: String? = nil,
    continuationHandler: (Int, Int, [Int32], DeepSeekGenerationStatistics) ->
      DeepSeekGenerationContinuationState
  ) -> [Int32] {
    os_unfair_lock_lock(&storage.lock)
    defer { os_unfair_lock_unlock(&storage.lock) }
    let originalFlags = DynamicGraph.flags
    DynamicGraph.flags.insert(.disableMFAAttentionSpecializingC)
    defer { DynamicGraph.flags = originalFlags }
    let tokenLength = tokens.shape[0]
    recentInteractionStatistics.append(DeepSeekGenerationStatistics())
    if recentInteractionStatistics.count > Self.recentStatisticsLimit {
      recentInteractionStatistics.removeFirst()
    }
    let interactionStatisticsIndex = recentInteractionStatistics.count - 1
    guard continuationHandler(0, tokenLength, [], statistics) == .continue else { return [] }
    guard tokenLength > 0 else { return [] }
    let totalPrefillLength = tokenOffset + tokenLength
    guard totalPrefillLength <= Self.maximumContextLength,
      contextTokens.count == totalPrefillLength
    else { return [] }
    if kvCache.layers.isEmpty {
      guard tokenOffset == 0 else { return [] }
    } else if kvCache.tokenLength != tokenOffset {
      return []
    }
    let window = configuration.slidingWindow - 1
    let slidingCapacity = slidingCacheCapacity
    let initialCacheTokenLength = min(totalPrefillLength + 1, Self.maximumContextLength)
    var cacheCapacity = min(
      Self.maximumContextLength,
      (initialCacheTokenLength + self.compilePrefillHeadroom - 1) / self.compilePrefillHeadroom
        * self.compilePrefillHeadroom)
    Self.resizeCaches(
      graph: graph, kvCache: &kvCache, cacheCapacity: cacheCapacity,
      slidingCapacity: slidingCapacity, configuration: configuration)
    let emptyTokens = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Int32.self)
    let emptyInjected = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Float16.self)

    // Inputs after the tokens: the image rows that follow them and the tokens after those, the
    // full-attention log scales, then per layer its caches bound from their first row through this
    // chunk's rows and its convolution rows.
    func modelInputs(
      injected: DynamicGraph.Tensor<Float16>, postTokens: DynamicGraph.Tensor<Int32>,
      cachedTokenLength: Int, tokenLength: Int, logScale: DynamicGraph.Tensor<Float16>
    )
      -> [DynamicGraph.AnyTensor]
    {
      var inputs: [DynamicGraph.AnyTensor] = [injected, postTokens, logScale]
      let kvDim = configuration.keyValueDim
      for (layerIndex, layer) in kvCache.layers.enumerated() {
        let isFull = configuration.isFullAttentionLayer(layerIndex)
        let rows = (isFull ? cachedTokenLength : kvCache.slidingTokenLength) + tokenLength
        let capacity = layer.keys.shape[1]
        for cache in [layer.keys, layer.values] {
          inputs.append(
            cache.reshaped(
              .NHWC(1, rows, configuration.keyValueHeads, configuration.headDim),
              strides: [capacity * kvDim, kvDim, configuration.headDim, 1]))
        }
        inputs += layer.convolutionRows
      }
      return inputs
    }
    // Uploaded before it becomes a variable: on a stream, a transfer inside the graph would
    // read the CPU tensor after it is gone.
    func logScale(cachedTokenLength: Int, tokenLength: Int) -> DynamicGraph.Tensor<Float16> {
      graph.variable(
        Inkling2SmallLogScale(
          Float16.self, cachedTokenLength: cachedTokenLength, tokenLength: tokenLength,
          configuration: configuration
        ).toGPU(0))
    }
    // Moves a full sliding-window cache's window back to its start.
    func makeRoom(for count: Int) {
      guard kvCache.slidingTokenLength + count > slidingCapacity else { return }
      let slidingRows = kvCache.slidingTokenLength
      for layerIndex in kvCache.layers.indices
      where !configuration.isFullAttentionLayer(layerIndex) {
        for var cache in [kvCache.layers[layerIndex].keys, kvCache.layers[layerIndex].values] {
          let kept = cache[
            0..<1, (slidingRows - window)..<slidingRows, 0..<configuration.keyValueHeads,
            0..<configuration.headDim
          ].copied()
          cache[0..<1, 0..<window, 0..<configuration.keyValueHeads, 0..<configuration.headDim] =
            kept
        }
      }
      kvCache.slidingTokenLength = window
    }
    // After a step, its next convolution rows become the current ones.
    func advance(by count: Int) {
      kvCache.tokenLength += count
      kvCache.slidingTokenLength += count
      for layerIndex in kvCache.layers.indices {
        let rows = kvCache.layers[layerIndex].convolutionRows
        kvCache.layers[layerIndex].convolutionRows = Array(rows[4...] + rows[..<4])
      }
    }

    // Compile the largest prefill chunk with full cache visibility for the current capacity, so
    // later chunks and decode steps reuse what it reserves.
    func compilePrefillHeadroom(cacheCapacity: Int, isEager: Bool = true) {
      let count = min(chunkedPrefillMaxLength, cacheCapacity)
      let cached = cacheCapacity - count
      let sliding = min(slidingCapacity, cacheCapacity) - count
      let slidingTokenLength = kvCache.slidingTokenLength
      kvCache.slidingTokenLength = sliding
      defer { kvCache.slidingTokenLength = slidingTokenLength }
      storage.decoder.compile(
        (cached: cached, sliding: sliding, count: count),
        inputs: [
          graph.variable(
            Tensor<Int32>(
              Array(repeating: 0, count: count), kind: .CPU, format: .NHWC, shape: [count]
            )
            .toGPU(0))
        ]
          + modelInputs(
            injected: emptyInjected, postTokens: emptyTokens, cachedTokenLength: cached,
            tokenLength: count,
            logScale: logScale(cachedTokenLength: cached, tokenLength: count)),
        isEager: isEager)
    }

    if !storage.decoderIsLoaded {
      compilePrefillHeadroom(cacheCapacity: cacheCapacity, isEager: false)
      let streamingConfiguration = storage.configuration
      // Streamed expert banks stay out of the pinned whole-file mapping.
      DynamicGraph.setWholeFileMappingSizeLimit(
        Inkling2SmallResidentMappingSize(
          checkpoint: filePath, configuration: streamingConfiguration))
      let result = try? graph.openStore(filePath, flags: .readOnly) { store in
        try store.read(
          "text_model", model: storage.decoder, strict: true,
          codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)]
        ) { name, _, _, _ in
          // Streaming layers read their expert banks on demand; MoEWeightStreaming loads experts
          // from the file.
          guard name.contains(".mlp.experts"),
            let layer = name.components(separatedBy: "layers.").last?.components(separatedBy: ".")
              .first.flatMap(Int.init), streamingConfiguration.isStreamingLayer(layer)
          else { return .continue(name) }
          return .continue(
            name
              .replacingOccurrences(
                of: ".mlp.experts.streaming_gate-0-0]", with: ".mlp.experts-0-0]"
              )
              .replacingOccurrences(
                of: ".mlp.experts.streaming_up-0-0]", with: ".mlp.experts-0-1]"),
            codec: [.jit, .externalOnDemand, .i8x])
        }
      }
      DynamicGraph.setWholeFileMappingSizeLimit(0)
      guard let result, (try? result.get()) != nil else { return [] }
      // Keep whole-file weights pinned across interactions; model destruction releases them.
      storage.decoder.pinMemory = true
      storage.decoderIsLoaded = true
    }
    compilePrefillHeadroom(cacheCapacity: cacheCapacity)

    // The last chunk's logits pick the first generated token.
    func sample(_ logits: DynamicGraph.Tensor<Float16>, thinking: Bool)
      -> DynamicGraph.Tensor<Int32>
    {
      if deterministic && !thinking {
        return Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
      }
      let scale: Float = deterministic || thinking ? 1 : 0.7
      // min-p is 0.01 for thinking and 0.05 for creative answer sampling.
      let minPLogitRange: Float = thinking ? 4.605_170_2 : 2.097_012_5
      let zmax = logits.reduced(.max, axis: [1])
      logits.fill(-Float.infinity, if: logits < (zmax - minPLogitRange))
      return Functional.gumbelArgmax(logits, axis: 1, scale: scale).reshaped(
        format: .NHWC, shape: [1])
    }
    // Images encode when a chunk first reaches them. One that cannot keeps its placeholder rows.
    var encodedImages = [[UInt8]: DynamicGraph.Tensor<Float16>]()
    var unavailableImages = Set<[UInt8]>()
    func encodeImages(overlapping range: Range<Int>) {
      for span in embedSpans
      where Int(span.start) < range.upperBound
        && Int(span.end) > range.lowerBound && encodedImages[span.digest] == nil
        && !unavailableImages.contains(span.digest)
      {
        if span.kind == .image, span.digest.count == 32, let projectPath {
          let path = EmbedsFileStore(projectPath: projectPath).filePath(for: Data(span.digest))
          if let image = Inkling2SmallImage(filePath: path) {
            if Array(image.digest) != span.digest {
              print("Warning: Inkling 2 Small image digest mismatch at \(path).")
            }
            if image.tokenCount == span.length {
              encodedImages[span.digest] = encodeImage(graph: graph, image: image)
            } else {
              print(
                "Warning: Inkling 2 Small image token count changed from \(span.length) to \(image.tokenCount) at \(path)."
              )
            }
          }
        }
        if encodedImages[span.digest] == nil {
          print(
            "Warning: Inkling 2 Small image at token \(span.start) is unavailable; using image placeholder tokens."
          )
          unavailableImages.insert(span.digest)
        }
      }
    }
    // A chunk with image rows does not fit what the headroom compile reserved, so it compiles for
    // its own shapes, which a text chunk or decode at a longer cache then outgrows and compiles
    // again; decode compiled at every step (about 4x slower). Compile the headroom once more, at
    // the first text-only chunk after image chunks or at the end of prefill, after the queued reads
    // of the image chunk finish, as GLM5_3TextGenerator does.
    var shouldCompilePrefillHeadroom = false

    var prefillTokenCPU: DynamicGraph.Tensor<Int32>?
    var prefillChunkStart = 0
    let initialPrefillDurationSoFar =
      recentInteractionStatistics[interactionStatisticsIndex].prefillDurationSoFar
    let prefillStartTime = CACurrentMediaTime()
    while prefillChunkStart < tokenLength {
      let start = prefillChunkStart
      let position = tokenOffset + start
      var end = position + min(chunkedPrefillMaxLength, tokenLength - start)
      encodeImages(overlapping: position..<end)
      // A chunk holds at most one image, with text rows before and after it, the order
      // Inkling2SmallCausalLM takes, so it ends where the next image starts. Unavailable images
      // stay text rows.
      let images = embedSpans.filter {
        Int($0.start) < end && Int($0.end) > position && encodedImages[$0.digest] != nil
      }.sorted { $0.start < $1.start }
      if images.count > 1 { end = Int(images[1].start) }
      var textEnd = end
      var postStart = end
      var injected = emptyInjected
      if let span = images.first, let embeddings = encodedImages[span.digest] {
        textEnd = max(position, Int(span.start))
        postStart = min(end, Int(span.end))
        injected = embeddings.reshaped(
          .WC(postStart - textEnd, configuration.hiddenSize),
          offset: [textEnd - Int(span.start), 0], strides: [configuration.hiddenSize, 1]
        ).copied()
      }
      if images.isEmpty && shouldCompilePrefillHeadroom {
        graph.joined()
        compilePrefillHeadroom(cacheCapacity: cacheCapacity)
        shouldCompilePrefillHeadroom = false
      }
      let length = end - position
      makeRoom(for: length)
      let flags = DynamicGraph.flags
      if length < chunkedPrefillMaxLength {
        DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)
      }
      let textTokens =
        textEnd > position
        ? tokens.reshaped(
          format: .NHWC, shape: [textEnd - position], offset: [start], strides: [1]
        ).copied() : emptyTokens
      let postTokens =
        postStart < end
        ? tokens.reshaped(
          format: .NHWC, shape: [end - postStart], offset: [postStart - tokenOffset],
          strides: [1]
        ).copied() : emptyTokens
      let prefillOutputs = storage.decoder(
        (cached: position, sliding: kvCache.slidingTokenLength, count: length),
        inputs: textTokens,
        modelInputs(
          injected: injected, postTokens: postTokens, cachedTokenLength: position,
          tokenLength: length,
          logScale: logScale(cachedTokenLength: position, tokenLength: length)))
      DynamicGraph.flags = flags
      if !images.isEmpty {
        shouldCompilePrefillHeadroom = true
      }
      advance(by: length)
      if start + length == tokenLength {
        prefillTokenCPU = sample(
          prefillOutputs[0].as(of: Float16.self), thinking: thinkingBudget > 0
        ).toCPU()
        if shouldCompilePrefillHeadroom {
          graph.joined()
          compilePrefillHeadroom(cacheCapacity: cacheCapacity)
          shouldCompilePrefillHeadroom = false
        }
      }
      prefillChunkStart += length
      recentInteractionStatistics[interactionStatisticsIndex].prefillDurationSoFar =
        Float(CACurrentMediaTime() - prefillStartTime) + initialPrefillDurationSoFar
      recentInteractionStatistics[interactionStatisticsIndex].prefillTokensSoFar += length
      switch continuationHandler(prefillChunkStart, tokenLength, [], statistics) {
      case .continue:
        break
      case .pause:
        if let prefillTokenCPU {
          return [prefillTokenCPU[0]]
        }
        return []
      case .abort:
        return []
      }
    }
    // A pause can return a pending end of sentence. After evaluating it, the turn is done.
    if let last = contextTokens.last, Self.eosTokenIds.contains(last) {
      graph.joined()
      return []
    }
    guard let prefillTokenCPU else { return [] }
    let firstToken = prefillTokenCPU[0]
    guard !Self.eosTokenIds.contains(firstToken) else { return [firstToken] }
    var generated = [firstToken]
    recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
    var nextTokenGPU = prefillTokenCPU.toGPU()
    let decodeTokenCapacity = max(0, Self.maximumContextLength - totalPrefillLength)
    guard decodeTokenCapacity > 0 else { return generated }
    // Every decode step's log scale through the current capacity, uploaded once: an upload waits
    // for the GPU to finish the step before it, which would undo the overlap.
    var decodeLogScaleStart = kvCache.tokenLength
    var decodeLogScales = logScale(
      cachedTokenLength: decodeLogScaleStart, tokenLength: cacheCapacity - decodeLogScaleStart)
    let queueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = queueWatermark * 16
    defer { DynamicGraph.queueWatermark = queueWatermark }
    var shouldAppendPendingToken = true
    var shouldStopAfterSampling = false
    var thinkingEnded = firstToken == Self.endThinkToken
    var decodeIndex = 0
    let initialTokenGenerationDurationSoFar =
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar
    let tokenGenerationStartTime = CACurrentMediaTime()
    defer {
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
    }
    while decodeIndex < decodeTokenCapacity {
      if thinkingBudget > 0 && !thinkingEnded && decodeIndex == thinkingBudget {
        nextTokenGPU = graph.variable(
          Tensor<Int32>([Self.endThinkToken], kind: .CPU, format: .NHWC, shape: [1]).toGPU(0))
        thinkingEnded = true
      }
      if kvCache.tokenLength + 1 > cacheCapacity {
        cacheCapacity = min(
          cacheCapacity + self.compilePrefillHeadroom, Self.maximumContextLength)
        Self.resizeCaches(
          graph: graph, kvCache: &kvCache, cacheCapacity: cacheCapacity,
          slidingCapacity: slidingCapacity, configuration: configuration)
        decodeLogScaleStart = kvCache.tokenLength
        decodeLogScales = logScale(
          cachedTokenLength: decodeLogScaleStart, tokenLength: cacheCapacity - decodeLogScaleStart)
        compilePrefillHeadroom(cacheCapacity: cacheCapacity)
      }
      makeRoom(for: 1)
      let oldDecodedTokenCPU = nextTokenGPU.toCPU()
      let decodeOutputs = storage.decoder(
        (cached: kvCache.tokenLength, sliding: kvCache.slidingTokenLength, count: 1),
        inputs: nextTokenGPU,
        modelInputs(
          injected: emptyInjected, postTokens: emptyTokens, cachedTokenLength: kvCache.tokenLength,
          tokenLength: 1,
          logScale: decodeLogScales.reshaped(
            format: .NHWC, shape: [1, 1], offset: [kvCache.tokenLength - decodeLogScaleStart, 0],
            strides: [1, 1]
          ).copied()))
      let logits = decodeOutputs[0].as(of: Float16.self)
      advance(by: 1)
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
      if decodeIndex > 0 {
        let decodedToken = oldDecodedTokenCPU[0]
        generated.append(decodedToken)
        recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
        if decodedToken == Self.endThinkToken {
          thinkingEnded = true
        }
        if Self.eosTokenIds.contains(decodedToken) {
          shouldAppendPendingToken = false
          break
        }
        switch continuationHandler(
          kvCache.tokenLength, kvCache.tokenLength, generated, statistics)
        {
        case .continue:
          break
        case .pause:
          shouldStopAfterSampling = true
        case .abort:
          shouldAppendPendingToken = false
        }
        if !shouldAppendPendingToken {
          break
        }
      }
      nextTokenGPU = sample(logits, thinking: thinkingBudget > 0 && !thinkingEnded)
      decodeIndex += 1
      if shouldStopAfterSampling {
        break
      }
    }
    if shouldAppendPendingToken {
      let lastTokenCPU = nextTokenGPU.toCPU()
      generated.append(lastTokenCPU[0])
      recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
    } else {
      graph.joined()
    }
    return generated
  }

  /// Full-attention caches hold `cacheCapacity` rows and grow by copying; sliding-window caches and
  /// convolution rows keep their size.
  private static func resizeCaches(
    graph: DynamicGraph, kvCache: inout KVCache, cacheCapacity: Int, slidingCapacity: Int,
    configuration: Inkling2SmallConfiguration
  ) {
    let kernel = configuration.convolutionKernel
    let shape = { (rows: Int) in
      TensorShapeFormat.NHWC(1, rows, configuration.keyValueHeads, configuration.headDim)
    }
    guard !kvCache.layers.isEmpty else {
      graph.garbageCollect()
      kvCache.layers = (0..<configuration.layers).map { layerIndex in
        let rows =
          configuration.isFullAttentionLayer(layerIndex) ? cacheCapacity : slidingCapacity
        let keys = graph.variable(.GPU(0), shape(rows), of: Float16.self)
        let values = graph.variable(.GPU(0), shape(rows), of: Float16.self)
        keys.full(0)
        values.full(0)
        var convolutionRows = [DynamicGraph.AnyTensor]()
        for _ in 0..<2 {
          for _ in 0..<2 {
            let rows = graph.variable(
              .GPU(0), .NHWC(1, kernel - 1, 1, configuration.keyValueDim), of: Float16.self)
            rows.full(0)
            convolutionRows.append(rows)
          }
          for _ in 0..<2 {
            let rows = graph.variable(
              .GPU(0), .NHWC(1, kernel - 1, 1, configuration.hiddenSize), of: Float.self)
            rows.full(0)
            convolutionRows.append(rows)
          }
        }
        return KVCache.Layer(keys: keys, values: values, convolutionRows: convolutionRows)
      }
      return
    }
    let fullLayer = (0..<configuration.layers).first { configuration.isFullAttentionLayer($0) }!
    let existingCapacity = kvCache.layers[fullLayer].keys.shape[1]
    guard existingCapacity < cacheCapacity else { return }
    graph.joined()
    for layerIndex in kvCache.layers.indices where configuration.isFullAttentionLayer(layerIndex) {
      var keys = graph.variable(.GPU(0), shape(cacheCapacity), of: Float16.self)
      var values = graph.variable(.GPU(0), shape(cacheCapacity), of: Float16.self)
      keys.full(0)
      values.full(0)
      let rows = 0..<existingCapacity
      keys[0..<1, rows, 0..<configuration.keyValueHeads, 0..<configuration.headDim] =
        kvCache.layers[layerIndex].keys
      values[0..<1, rows, 0..<configuration.keyValueHeads, 0..<configuration.headDim] =
        kvCache.layers[layerIndex].values
      kvCache.layers[layerIndex].keys = keys
      kvCache.layers[layerIndex].values = values
    }
    graph.garbageCollect()
  }
}
