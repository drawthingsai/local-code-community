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
  // Decode pool slots of sparse layers 3 through 44, calibrated for
  // glm_5.3_flash_i2x_lgain_trailer.ckpt. See Debug/GLM5_3ResidentSlots.md for the fit and
  // validation. The other text weights, pinned with the embedding, take 9.79 GiB, so 8 GiB keeps
  // only the routing width. 72 GiB loads every weight, as it does for DeepSeek V4, so it is
  // picked only where the whole checkpoint fits.
  var expertResidentSlotsForGLM5_3: [Int] {
    switch self {
    case ._8GiB:
      return Array(repeating: 8, count: 42)
    case ._16GiB:
      return [
        12, 8, 8, 16, 20, 20, 24, 20, 20, 24, 24, 24, 24, 24,
        28, 28, 28, 28, 28, 24, 24, 28, 24, 24, 24, 24, 24, 20,
        20, 24, 24, 24, 20, 24, 24, 24, 24, 24, 24, 24, 24, 24,
      ]
    case ._24GiB:
      return [
        52, 44, 44, 52, 52, 52, 52, 52, 52, 44, 52, 44, 52, 52,
        52, 52, 52, 52, 52, 64, 52, 52, 52, 52, 56, 52, 64, 52,
        52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 56, 52, 52, 52,
      ]
    case ._32GiB:
      return [
        132, 132, 124, 112, 92, 92, 92, 104, 84, 64, 72, 64, 72, 72,
        72, 64, 64, 72, 72, 76, 72, 72, 76, 76, 84, 72, 84, 84,
        76, 84, 72, 72, 72, 72, 76, 72, 76, 72, 84, 72, 84, 84,
      ]
    case ._40GiB:
      return [
        172, 172, 164, 164, 124, 132, 124, 132, 116, 92, 92, 92, 92, 96,
        92, 84, 84, 92, 92, 104, 96, 96, 104, 104, 104, 104, 112, 116,
        112, 112, 96, 104, 104, 104, 112, 104, 112, 104, 104, 104, 112, 112,
      ]
    case ._48GiB:
      return [
        204, 204, 204, 192, 152, 164, 160, 164, 144, 116, 124, 116, 120, 124,
        120, 104, 104, 112, 120, 124, 124, 124, 128, 128, 128, 132, 140, 148,
        140, 148, 128, 132, 140, 140, 144, 132, 140, 140, 140, 136, 144, 148,
      ]
    case ._56GiB:
      return [
        228, 240, 240, 220, 180, 188, 188, 200, 176, 152, 152, 144, 148, 156,
        148, 128, 128, 132, 144, 148, 152, 148, 156, 156, 156, 160, 168, 180,
        176, 180, 156, 160, 168, 176, 176, 168, 176, 168, 168, 168, 172, 180,
      ]
    case ._64GiB:
      return [
        268, 276, 276, 260, 208, 220, 220, 228, 204, 180, 180, 176, 180, 180,
        172, 148, 156, 160, 172, 176, 180, 180, 180, 180, 180, 188, 196, 208,
        200, 208, 188, 188, 200, 208, 208, 196, 200, 200, 200, 200, 200, 208,
      ]
    case ._72GiB, .disabled:
      return Array(repeating: 288, count: 42)
    }
  }

  // What the weights hold at this tier.
  var residentSizeForGLM5_3: UInt64 {
    switch self {
    case ._8GiB:
      // The other text weights and 8 experts of 6.65625 MiB per layer.
      return 10_511_165_304 + 42 * 8 * 6_979_584
    case ._16GiB, ._24GiB, ._32GiB, ._40GiB, ._48GiB, ._56GiB, ._64GiB:
      return UInt64(rawValue) * 1_024 * 1_024 * 1_024
    case ._72GiB, .disabled:
      return 96_066_945_024  // The whole glm_5.3_flash_i2x_lgain_trailer.ckpt, about 89.47 GiB.
    }
  }

  // Treat this tier as a ceiling: pick the largest tier at or below it whose resident weights fit
  // in 75% of available memory, falling back to the smallest tier when none fits.
  func residentTierForGLM5_3(availableMemory: UInt64) -> Self {
    let budget = availableMemory / 4 * 3
    // allCases ascends by resident size, ending with .disabled, which loads every weight.
    let ceiling = Self.allCases.firstIndex(of: self)!
    return Self.allCases[...ceiling].last { $0.residentSizeForGLM5_3 <= budget } ?? ._8GiB
  }

  // An explicit .disabled always loads every weight. Otherwise the requested tier, or the automatic
  // one when nil, is a ceiling for what fits in the memory available now.
  static func residentTierForGLM5_3(requested: Self?) -> Self {
    guard requested != .disabled else { return .disabled }
    return (requested ?? DeviceCapability.weightsStreaming).residentTierForGLM5_3(
      availableMemory: DeviceCapability.availableMemory)
  }
}

/// Loaded model storage is shared by copies. KV caches belong to the caller's session; use the
/// same graph and generator while continuing a session.
public struct GLM5_3TextGenerator: TextGenerator {
  public static let version: LLMVersion = .glm_5_3_flash
  // About 256K tokens of latent, indexer and pooled rows over 11 attention layers, plus the KDA
  // states.
  public static let estimatedKVCacheSize: UInt64 = 5 * 1_024 * 1_024 * 1_024
  static let maximumContextLength = 256 * 1_024

  static let endOfTextToken: Int32 = 154_820
  static let systemToken: Int32 = 154_826
  static let userToken: Int32 = 154_827
  static let assistantToken: Int32 = 154_828
  static let observationToken: Int32 = 154_829
  static let thinkStartToken: Int32 = 154_841
  static let thinkEndToken: Int32 = 154_842
  static let toolCallStartToken: Int32 = 154_843
  static let imageStartToken: Int32 = 154_830
  static let imageEndToken: Int32 = 154_831
  /// One `<|image|>` per merged image token; its rows take the vision tower's embeddings.
  static let imageToken: Int32 = 154_854
  /// generation_config.json: the model ends a turn with the role that comes next.
  static let stopTokens: Set<Int32> = [endOfTextToken, userToken, observationToken]

  public enum ContinuationState {
    case `continue`
    case pause
    case abort
  }

  public struct Statistics: Sendable {
    public var prefillDurationSoFar: Float = 0
    public var prefillTokensSoFar = 0
    public var tokenGenerationDurationSoFar: Float = 0
    public var tokenGeneratedSoFar = 0

    public var prefillTokensPerSecond: Float {
      guard prefillDurationSoFar > 0 else { return 0 }
      return Float(prefillTokensSoFar) / prefillDurationSoFar
    }

    public var tokenGeneratedPerSecond: Float {
      guard tokenGenerationDurationSoFar > 0 else { return 0 }
      return Float(tokenGeneratedSoFar) / tokenGenerationDurationSoFar
    }

    public init() {}
  }

  /// Attention layers keep append-only latent and indexer rows and the indexer's 4-token pools.
  /// KDA layers keep their convolution and recurrent states, the current pair first and then the
  /// pair a call writes (a graph cannot write the buffers it reads).
  public struct KVCache {
    struct Layer {
      var latent: DynamicGraph.Tensor<Float16>?
      var indexer: DynamicGraph.Tensor<Float16>?
      var pooled: DynamicGraph.Tensor<Float16>?
      var convStates = [DynamicGraph.Tensor<Float16>]()
      var recurrentStates = [DynamicGraph.Tensor<Float>]()
    }
    var layers = [Layer]()
    /// How many tokens it holds, which is where the next decode continues from.
    public internal(set) var tokenLength = 0
    /// An unavailable image kept its placeholder rows, so checkpoints would not match its digest.
    var hasPaddedImages = false

    public init() {}

    var isEmpty: Bool { layers.isEmpty }
    var capacity: Int { layers.lazy.compactMap(\.latent).first?.shape[1] ?? 0 }

    /// KDA states are rewritten every call, so the current pair is copied. The other pair is
    /// written before it is read, and attention rows past `tokenLength` are never read back, so
    /// they stay shared.
    public func snapshot() -> KVCache {
      var cache = self
      for index in cache.layers.indices where !cache.layers[index].convStates.isEmpty {
        cache.layers[index].convStates[0] = cache.layers[index].convStates[0].copied()
        cache.layers[index].recurrentStates[0] = cache.layers[index].recurrentStates[0].copied()
      }
      return cache
    }
  }

  private static let specialTokens: [String: Int32] = [
    "<|endoftext|>": 154_820, "[MASK]": 154_821, "[gMASK]": 154_822, "[sMASK]": 154_823,
    "<sop>": 154_824, "<eop>": 154_825, "<|system|>": 154_826, "<|user|>": 154_827,
    "<|assistant|>": 154_828, "<|observation|>": 154_829, "<|begin_of_image|>": 154_830,
    "<|end_of_image|>": 154_831, "<|begin_of_video|>": 154_832, "<|end_of_video|>": 154_833,
    "<|begin_of_audio|>": 154_834, "<|end_of_audio|>": 154_835,
    "<|begin_of_transcription|>": 154_836, "<|end_of_transcription|>": 154_837,
    "<|code_prefix|>": 154_838, "<|code_middle|>": 154_839, "<|code_suffix|>": 154_840,
    "<think>": 154_841, "</think>": 154_842, "<tool_call>": 154_843, "</tool_call>": 154_844,
    "<tool_response>": 154_845, "</tool_response>": 154_846, "<arg_key>": 154_847,
    "</arg_key>": 154_848, "<arg_value>": 154_849, "</arg_value>": 154_850,
    "/nothink": 154_851, "<|begin_of_box|>": 154_852, "<|end_of_box|>": 154_853,
    "<|image|>": 154_854, "<|video|>": 154_855,
  ]

  // Every added token, as Hugging Face matches them in raw text.
  public static let unsafeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_glm5_json, merges: BinaryResources.merges_glm5_txt,
    specialTokens: specialTokens, unknownToken: "<|endoftext|>", startToken: "<|endoftext|>",
    endToken: "<|endoftext|>", pretokenizer: .glm5, ignoreMerges: true)

  // User and tool text cannot spell control tokens.
  public static let safeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_glm5_json, merges: BinaryResources.merges_glm5_txt,
    specialTokens: ["<|endoftext|>": 154_820], unknownToken: "<|endoftext|>",
    startToken: "<|endoftext|>", endToken: "<|endoftext|>", pretokenizer: .glm5,
    ignoreMerges: true, splitSpecialTokens: true)

  public var safeTokenizer: TiktokenTokenizer { Self.safeTokenizer }

  // Keep this storage model-only: no DynamicGraph, graph tensors, or closures capturing them.
  private final class Storage {
    // Tools may start before the decoder continuation returns. Reset waits for that decode to
    // finish; subsequent decoding can immediately reload.
    var lock = os_unfair_lock()
    var isLoaded = false
    let requestedWeightsStreaming: DeviceCapability.WeightsStreaming?
    // Expert residency is resolved whenever the model is built, so each weights load sees the
    // memory available then.
    private(set) var configuration = GLM5_3ModelConfiguration.glm5_3Flash
    private var cachedModel: ModelBuilder<(cached: Int, count: Int)>?

    init(requestedWeightsStreaming: DeviceCapability.WeightsStreaming?) {
      self.requestedWeightsStreaming = requestedWeightsStreaming
    }

    // One whole-model graph for every chunk and decode step.
    var model: ModelBuilder<(cached: Int, count: Int)> {
      if let cachedModel { return cachedModel }
      configuration.expertResidentSlots =
        DeviceCapability.WeightsStreaming.residentTierForGLM5_3(
          requested: requestedWeightsStreaming
        ).expertResidentSlotsForGLM5_3
      let configuration = configuration
      let model = ModelBuilder { (shape: (cached: Int, count: Int), _) in
        GLM5_3CausalLM(
          Float16.self, tokenLength: shape.count, cachedTokenLength: shape.cached,
          configuration: configuration)
      }
      model.maxConcurrency = .limit(4)
      cachedModel = model
      return model
    }

    var isVisionLoaded = false
    private var cachedVision: ModelBuilder<(t: Int, h: Int, w: Int)>?

    // Patches arrive block-major and the grid enters only through the rotary table, so one graph
    // per patch count serves every image geometry.
    var vision: ModelBuilder<(t: Int, h: Int, w: Int)> {
      if let cachedVision { return cachedVision }
      let vision = ModelBuilder { (grid: (t: Int, h: Int, w: Int), _) in
        GLM5_3VisionTransformer(Float16.self, gridThw: [grid], configuration: .glm5_3Flash)
      }
      cachedVision = vision
      return vision
    }

    func reset() {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      cachedModel = nil
      isLoaded = false
      cachedVision = nil
      isVisionLoaded = false
    }
  }

  // Copies share model storage. Graphs and conversation caches stay on the generation queue.
  private let storage: Storage
  public let filePath: String
  public let chunkedPrefillMaxLength: Int
  /// The requested tier, or nil for automatic. An explicit `.disabled` disables streaming;
  /// otherwise the tier is a ceiling for what fits in the memory available when the weights load.
  public let weightsStreaming: DeviceCapability.WeightsStreaming?
  private static let recentStatisticsLimit = 3
  private var recentInteractionStatistics = [Statistics]()

  public init(
    filePath: String, chunkedPrefillMaxLength: Int,
    weightsStreaming: DeviceCapability.WeightsStreaming? = nil
  ) {
    self.filePath = filePath
    self.chunkedPrefillMaxLength = chunkedPrefillMaxLength
    self.weightsStreaming = weightsStreaming
    storage = Storage(requestedWeightsStreaming: weightsStreaming)
  }

  /// Checkpoints land on whole prefill chunks: the chunk length rounded down to a multiple of
  /// 4,096 tokens, and at least 4,096, so they share the context cache's fixed slices.
  public var checkpointStride: Int {
    max(GLM5_3ContextCache.checkpointStorageStride, chunkedPrefillMaxLength / 4_096 * 4_096)
  }

  public var statistics: Statistics {
    guard !recentInteractionStatistics.isEmpty else { return Statistics() }
    let count = Float(recentInteractionStatistics.count)
    var statistics = Statistics()
    for interaction in recentInteractionStatistics {
      statistics.prefillDurationSoFar += interaction.prefillDurationSoFar / count
      statistics.prefillTokensSoFar += interaction.prefillTokensSoFar
      statistics.tokenGenerationDurationSoFar += interaction.tokenGenerationDurationSoFar / count
      statistics.tokenGeneratedSoFar += interaction.tokenGeneratedSoFar
    }
    statistics.prefillTokensSoFar = Int((Float(statistics.prefillTokensSoFar) / count).rounded())
    statistics.tokenGeneratedSoFar = Int(
      (Float(statistics.tokenGeneratedSoFar) / count).rounded())
    return statistics
  }

  /// The latest decode on its own; `statistics` averages the recent ones.
  public var lastInteractionStatistics: Statistics {
    recentInteractionStatistics.last ?? Statistics()
  }

  /// At the requested or automatic tier; a load settles on that tier or a smaller one.
  public var residentWeightsSize: UInt64 {
    (weightsStreaming ?? DeviceCapability.weightsStreaming).residentSizeForGLM5_3
  }

  /// Drops only shared model weights, waiting for an active decode to return.
  /// Safe from a tool worker; graph-owned conversation caches stay with the agent.
  public func unload() { storage.reset() }

  /// `<|image|>` placeholders for an image file, or nil when it is not a readable image.
  public static func imageTokenCount(filePath: String) -> Int? {
    GLM5_3Image.grid(filePath: filePath).map { GLM5_3VisionTokenCount(gridThw: $0) }
  }

  /// Image embeddings `[tokenCount, hiddenSize]`, loading the vision tower from the same store on
  /// the first image. Nil when the image or the tower cannot load.
  private func encodeImage(graph: DynamicGraph, image: GLM5_3Image)
    -> DynamicGraph.Tensor<Float16>?
  {
    guard let patches = image.patches() else { return nil }
    let inputs: [DynamicGraph.AnyTensor] = [
      graph.variable(Tensor<Float16>(from: patches).toGPU(0)),
      graph.variable(
        GLM5_3VisionRotaryEmbedding(
          gridThw: [image.grid], configuration: .glm5_3Flash, of: Float16.self
        ).toGPU(0)),
      graph.variable(GLM5_3VisionSequenceOffsets(gridThw: [image.grid]).offsets.toGPU(0)),
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

  /// Prefills `tokens` after the `tokenOffset` tokens `kvCache` holds, then generates until a stop
  /// token, which is evaluated and returned last. Every returned token is in the cache, except the
  /// one pending prediction a pause returns; an abort returns only evaluated tokens. The handler
  /// gets the prefilled count and length during prefill, then the cached length twice and the
  /// tokens so far.
  public mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool, kvCache: inout KVCache, contextTokens: [Int32],
    contextCache: GLM5_3ContextCache, embedSpans: [EmbedSpan] = [], projectPath: String? = nil,
    continuationHandler: (Int, Int, [Int32], Statistics) -> ContinuationState
  ) -> [Int32] {
    os_unfair_lock_lock(&storage.lock)
    defer { os_unfair_lock_unlock(&storage.lock) }
    let originalFlags = DynamicGraph.flags
    DynamicGraph.flags.insert(.disableMFAAttentionSpecializingC)
    defer { DynamicGraph.flags = originalFlags }
    recentInteractionStatistics.append(Statistics())
    if recentInteractionStatistics.count > Self.recentStatisticsLimit {
      recentInteractionStatistics.removeFirst()
    }
    let statisticsIndex = recentInteractionStatistics.count - 1
    let tokenLength = tokens.shape[0]
    guard continuationHandler(0, tokenLength, [], statistics) == .continue else { return [] }
    let totalLength = tokenOffset + tokenLength
    guard tokenLength > 0, totalLength < Self.maximumContextLength,
      contextTokens.count == totalLength,
      kvCache.isEmpty ? tokenOffset == 0 : kvCache.tokenLength == tokenOffset
    else { return [] }
    let configuration = GLM5_3ModelConfiguration.glm5_3Flash
    let model = storage.model
    let shouldRestore = kvCache.isEmpty
    var capacity = Self.cacheCapacity(for: totalLength + 1)
    Self.resizeCaches(
      graph: graph, kvCache: &kvCache, capacity: capacity, configuration: configuration)
    var hasher = ContextCachePrefixHasher(modelFilePath: filePath)
    let restoredTokenLength =
      shouldRestore
      ? contextCache.restore(
        graph: graph, tokens: contextTokens, configuration: configuration, kvCache: &kvCache,
        hasher: &hasher, embeddingSpans: embedSpans) : 0
    let prefillStart = min(restoredTokenLength, tokenLength - 1)
    kvCache.tokenLength = tokenOffset + prefillStart

    // Absent token or image inputs are zero-sized.
    let emptyTokens = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Int32.self)
    let emptyInjected = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Float16.self)
    // Upload before wrapping: a graph-level toGPU under a stream copies asynchronously from a CPU
    // buffer released when this returns.
    func tokenInput(_ values: [Int32]) -> DynamicGraph.Tensor<Int32> {
      graph.variable(
        Tensor<Int32>(values, kind: .CPU, format: .NHWC, shape: [values.count]).toGPU(0))
    }
    let checkpointStride = contextCache.checkpointStride
    func chunkLength(start: Int) -> Int {
      let position = tokenOffset + start
      let nextCheckpoint = (position / checkpointStride + 1) * checkpointStride
      return min(chunkedPrefillMaxLength, tokenLength - start, nextCheckpoint - position)
    }
    // Compile the largest chunk with the whole cache visible, and decode at the largest cached
    // length, so the tensor arena is reserved once per capacity.
    func compilePrefill(isEager: Bool) {
      let chunk = min(chunkedPrefillMaxLength, capacity - 1)
      model.compile(
        (cached: capacity - chunk, count: chunk),
        inputs: [tokenInput(Array(repeating: 0, count: chunk)), emptyInjected, emptyTokens]
          + Self.cacheInputs(kvCache, cached: capacity - chunk, count: chunk), isEager: isEager)
    }
    func compileDecode() {
      model.compile(
        (cached: capacity - 1, count: 1),
        inputs: [tokenInput([0]), emptyInjected, emptyTokens]
          + Self.cacheInputs(kvCache, cached: capacity - 1, count: 1), isEager: true)
    }
    if !storage.isLoaded {
      compilePrefill(isEager: false)
      // Streamed expert banks stay out of the pinned whole-file mapping.
      let streamingConfiguration = storage.configuration
      DynamicGraph.setWholeFileMappingSizeLimit(
        GLM5_3ResidentMappingSize(checkpoint: filePath, configuration: streamingConfiguration))
      defer { DynamicGraph.setWholeFileMappingSizeLimit(0) }
      let result = try? graph.openStore(filePath, flags: .readOnly) { store in
        let codec: DynamicGraph.Store.Codec = [.jit, .i8x, .ezm7, .externalData(.wholeFile)]
        try store.read("text_model", model: model, strict: true, codec: codec) {
          name, _, _, _ in
          // Streaming layers read their expert banks on demand; MoEWeightStreaming loads experts from
          // the file.
          if name.contains(".mlp.experts"),
            let layer = name.components(separatedBy: "layers.").last?.components(separatedBy: ".")
              .first
              .flatMap(Int.init), streamingConfiguration.isStreamingLayer(layer)
          {
            return .continue(
              name
                .replacingOccurrences(
                  of: ".mlp.experts.streaming_gate-0-0]", with: ".mlp.experts-0-0]"
                )
                .replacingOccurrences(
                  of: ".mlp.experts.streaming_up-0-0]", with: ".mlp.experts-0-1]"),
              codec: [.jit, .externalOnDemand, .i8x])
          }
          // The resident sparse layers fuse the shared expert into the routed SwiGLU and down projection.
          return .continue(
            name
              .replacingOccurrences(of: ".mlp.experts-0-2]", with: ".mlp.shared_experts-0-0]")
              .replacingOccurrences(of: ".mlp.experts-0-3]", with: ".mlp.shared_experts-0-1]")
              .replacingOccurrences(
                of: ".mlp.experts.down_proj-0-1]", with: ".mlp.shared_experts.down_proj-0-0]"))
        }
      }
      guard let result, (try? result.get()) != nil else { return [] }
      // Keep whole-file weights pinned across interactions; model destruction releases them.
      model.pinMemory = true
      storage.isLoaded = true
    }
    compilePrefill(isEager: true)
    // With the context restored and the weights loaded, before the timed prefill.
    guard continuationHandler(prefillStart, tokenLength, [], statistics) == .continue else {
      return []
    }

    // The current assistant turn decides whether thinking is still open and how much of the budget
    // it used, so a resumed generation keeps both.
    var thinkingEnded = thinkingBudget <= 0
    var thinkingTokenCount = 0
    if !thinkingEnded, let assistantStart = contextTokens.lastIndex(of: Self.assistantToken) {
      let turn = contextTokens[(assistantStart + 1)...]
      if turn.contains(Self.thinkEndToken) || turn.contains(Self.toolCallStartToken) {
        thinkingEnded = true
      } else if let thinkStart = turn.firstIndex(of: Self.thinkStartToken) {
        thinkingTokenCount = contextTokens.count - thinkStart - 1
      }
    }
    func select(_ logits: DynamicGraph.Tensor<Float16>) -> DynamicGraph.Tensor<Int32> {
      let isThinking = !thinkingEnded
      guard isThinking || !deterministic else {
        return Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
      }
      // Thinking samples at T = 1 with min-p 0.01; sampled answers at T = 0.7 with min-p 0.05.
      let (temperature, window): (Float, Float) = isThinking ? (1, 4.605_170_2) : (0.7, 2.097_012_5)
      let maximum = logits.reduced(.max, axis: [1])
      logits.fill(-Float.infinity, if: logits < (maximum - window))
      return Functional.gumbelArgmax(logits, axis: 1, scale: temperature).reshaped(
        format: .NHWC, shape: [1])
    }
    // Out of thinking budget, the next token closes thinking.
    func forcingThinkingEnd(_ token: DynamicGraph.Tensor<Int32>) -> DynamicGraph.Tensor<Int32> {
      guard !thinkingEnded, thinkingTokenCount >= thinkingBudget else { return token }
      return tokenInput([Self.thinkEndToken])
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
          if let image = GLM5_3Image(filePath: path) {
            if Array(image.digest) != span.digest {
              print("Warning: GLM-5.3 image digest mismatch at \(path).")
            }
            if image.tokenCount == span.length {
              encodedImages[span.digest] = encodeImage(graph: graph, image: image)
            } else {
              print(
                "Warning: GLM-5.3 image token count changed from \(span.length) to \(image.tokenCount) at \(path)."
              )
            }
          }
        }
        if encodedImages[span.digest] == nil {
          print(
            "Warning: GLM-5.3 image at token \(span.start) is unavailable; using image placeholder tokens."
          )
          unavailableImages.insert(span.digest)
        }
      }
    }

    var pendingToken: DynamicGraph.Tensor<Int32>?
    var chunkStart = prefillStart
    let prefillStartTime = CACurrentMediaTime()
    let initialPrefillDuration = recentInteractionStatistics[statisticsIndex].prefillDurationSoFar
    while chunkStart < tokenLength {
      let position = tokenOffset + chunkStart
      var end = position + chunkLength(start: chunkStart)
      encodeImages(overlapping: position..<end)
      // A chunk holds at most one image, with text rows before and after it, the order
      // GLM5_3Embedding takes, so it ends where the next image starts. Unavailable images stay
      // text rows.
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
      if embedSpans.contains(where: {
        Int($0.start) < end && Int($0.end) > position && unavailableImages.contains($0.digest)
      }) {
        kvCache.hasPaddedImages = true
      }
      let length = end - position
      let flags = DynamicGraph.flags
      // Partial chunks would otherwise specialize every GEMM on a new M.
      if length != min(chunkedPrefillMaxLength, capacity - 1) {
        DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)
      }
      let textTokens =
        textEnd > position
        ? tokens.reshaped(
          format: .NHWC, shape: [textEnd - position], offset: [chunkStart], strides: [1]
        ).copied() : emptyTokens
      let postTokens =
        postStart < end
        ? tokens.reshaped(
          format: .NHWC, shape: [end - postStart], offset: [postStart - tokenOffset],
          strides: [1]
        ).copied() : emptyTokens
      let outputs = model(
        (cached: position, count: length), inputs: textTokens,
        [injected, postTokens] + Self.cacheInputs(kvCache, cached: position, count: length))
      DynamicGraph.flags = flags
      Self.keepStates(&kvCache)
      kvCache.tokenLength = position + length
      chunkStart += length
      if chunkStart == tokenLength {
        pendingToken = forcingThinkingEnd(select(outputs[0].as(of: Float16.self)))
      }
      if !kvCache.hasPaddedImages, kvCache.tokenLength.isMultiple(of: checkpointStride) {
        contextCache.save(
          graph: graph, tokens: contextTokens, checkpointLength: kvCache.tokenLength,
          configuration: configuration, kvCache: kvCache, hasher: &hasher,
          embeddingSpans: embedSpans)
      }
      recentInteractionStatistics[statisticsIndex].prefillDurationSoFar =
        Float(CACurrentMediaTime() - prefillStartTime) + initialPrefillDuration
      recentInteractionStatistics[statisticsIndex].prefillTokensSoFar += length
      switch continuationHandler(chunkStart, tokenLength, [], statistics) {
      case .continue:
        break
      case .pause:
        return pendingToken.map { [$0.toCPU()[0]] } ?? []
      case .abort:
        return []
      }
    }
    // A pause can return a pending stop token. After replaying it into KDA, the turn is done.
    if let last = contextTokens.last, Self.stopTokens.contains(last) {
      graph.joined()
      return []
    }
    guard var pendingToken else { return [] }

    // Pipelined: the token sampled last step feeds this one while the CPU reads it back, so
    // building the next step overlaps the GPU running the current one.
    let queueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = queueWatermark * 16
    defer { DynamicGraph.queueWatermark = queueWatermark }
    compileDecode()
    var generated = [Int32]()
    var runningContextTokens = contextTokens
    let decodeStartTime = CACurrentMediaTime()
    let initialDecodeDuration =
      recentInteractionStatistics[statisticsIndex].tokenGenerationDurationSoFar
    defer {
      recentInteractionStatistics[statisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - decodeStartTime) + initialDecodeDuration
    }
    while kvCache.tokenLength < Self.maximumContextLength {
      let position = kvCache.tokenLength
      if position + 1 > capacity {
        graph.joined()
        capacity = Self.cacheCapacity(for: position + 1)
        Self.resizeCaches(
          graph: graph, kvCache: &kvCache, capacity: capacity, configuration: configuration)
        compileDecode()
      }
      let pending = pendingToken.toCPU()
      let outputs = model(
        (cached: position, count: 1), inputs: pendingToken,
        [emptyInjected, emptyTokens] + Self.cacheInputs(kvCache, cached: position, count: 1))
      Self.keepStates(&kvCache)
      kvCache.tokenLength = position + 1
      let token = pending[0]
      if token == Self.thinkEndToken || token == Self.toolCallStartToken {
        thinkingEnded = true
      } else if !thinkingEnded {
        thinkingTokenCount += 1
      }
      pendingToken = forcingThinkingEnd(select(outputs[0].as(of: Float16.self)))
      generated.append(token)
      runningContextTokens.append(token)
      if !kvCache.hasPaddedImages, kvCache.tokenLength.isMultiple(of: checkpointStride) {
        contextCache.save(
          graph: graph, tokens: runningContextTokens, checkpointLength: kvCache.tokenLength,
          configuration: configuration, kvCache: kvCache, hasher: &hasher,
          embeddingSpans: embedSpans)
      }
      recentInteractionStatistics[statisticsIndex].tokenGeneratedSoFar += 1
      recentInteractionStatistics[statisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - decodeStartTime) + initialDecodeDuration
      if Self.stopTokens.contains(token) {
        graph.joined()
        return generated
      }
      switch continuationHandler(kvCache.tokenLength, kvCache.tokenLength, generated, statistics) {
      case .continue:
        break
      case .pause:
        return generated + [pendingToken.toCPU()[0]]
      case .abort:
        graph.joined()
        return generated
      }
    }
    // The context is full: the last prediction stays pending.
    return generated + [pendingToken.toCPU()[0]]
  }

  /// Cache capacity grows in 4,096-row pages.
  private static func cacheCapacity(for tokenLength: Int) -> Int {
    min(maximumContextLength, (tokenLength + 4_095) / 4_096 * 4_096)
  }

  /// KDA states and where their next values go, and exactly the visible latent and indexer rows.
  static func cacheInputs(_ kvCache: KVCache, cached: Int, count: Int)
    -> [DynamicGraph.AnyTensor]
  {
    let configuration = GLM5_3ModelConfiguration.glm5_3Flash
    return kvCache.layers.flatMap { layer -> [DynamicGraph.AnyTensor] in
      if let latent = layer.latent, let indexer = layer.indexer, let pooled = layer.pooled {
        return [
          latent.reshaped(.NHWC(1, cached + count, 1, configuration.keyValueLowRank)),
          indexer.reshaped(.NHWC(1, cached + count, 1, 2 * configuration.indexerHeadDim)),
          pooled,
        ]
      }
      return [
        layer.convStates[0], layer.recurrentStates[0], layer.convStates[1],
        layer.recurrentStates[1],
      ]
    }
  }

  /// After a call, the states it wrote become current.
  private static func keepStates(_ kvCache: inout KVCache) {
    for index in kvCache.layers.indices where !kvCache.layers[index].convStates.isEmpty {
      kvCache.layers[index].convStates.swapAt(0, 1)
      kvCache.layers[index].recurrentStates.swapAt(0, 1)
    }
  }

  /// Allocates empty caches, or grows the attention caches to `capacity`, keeping their rows.
  static func resizeCaches(
    graph: DynamicGraph, kvCache: inout KVCache, capacity: Int,
    configuration: GLM5_3ModelConfiguration
  ) {
    let rank = configuration.keyValueLowRank
    let indexerWidth = 2 * configuration.indexerHeadDim
    let poolWidth = configuration.indexerHeadDim
    let pools = max(1, capacity / configuration.indexerPool)
    if kvCache.isEmpty {
      graph.garbageCollect()
      kvCache.layers = (0..<configuration.layers).map { layerIndex in
        var layer = KVCache.Layer()
        if configuration.isLinearAttentionLayer(layerIndex) {
          layer.convStates = (0..<2).map { _ in
            let state = graph.variable(
              .GPU(0),
              .NHWC(1, configuration.linearConvKernel - 1, 1, configuration.linearConvDim),
              of: Float16.self)
            state.full(0)
            return state
          }
          layer.recurrentStates = (0..<2).map { _ in
            let state = graph.variable(
              .GPU(0),
              .NHWC(
                1, configuration.linearHeads, configuration.linearHeadDim,
                configuration.linearHeadDim), of: Float.self)
            state.full(0)
            return state
          }
        } else {
          layer.latent = graph.variable(.GPU(0), .NHWC(1, capacity, 1, rank), of: Float16.self)
          layer.indexer = graph.variable(
            .GPU(0), .NHWC(1, capacity, 1, indexerWidth), of: Float16.self)
          layer.pooled = graph.variable(.GPU(0), .WC(pools, poolWidth), of: Float16.self)
        }
        return layer
      }
      kvCache.tokenLength = 0
      return
    }
    let existingCapacity = kvCache.capacity
    guard existingCapacity < capacity else { return }
    let existingPools = max(1, existingCapacity / configuration.indexerPool)
    for index in kvCache.layers.indices {
      guard let latent = kvCache.layers[index].latent, let indexer = kvCache.layers[index].indexer,
        let pooled = kvCache.layers[index].pooled
      else { continue }
      var newLatent = graph.variable(.GPU(0), .NHWC(1, capacity, 1, rank), of: Float16.self)
      newLatent[0..<1, 0..<existingCapacity, 0..<1, 0..<rank] = latent
      var newIndexer = graph.variable(
        .GPU(0), .NHWC(1, capacity, 1, indexerWidth), of: Float16.self)
      newIndexer[0..<1, 0..<existingCapacity, 0..<1, 0..<indexerWidth] = indexer
      var newPooled = graph.variable(.GPU(0), .WC(pools, poolWidth), of: Float16.self)
      newPooled[0..<existingPools, 0..<poolWidth] = pooled
      kvCache.layers[index].latent = newLatent
      kvCache.layers[index].indexer = newIndexer
      kvCache.layers[index].pooled = newPooled
    }
    graph.garbageCollect()
  }
}
