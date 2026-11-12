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
  // Decode pool slots of sparse layers 3 through 44, calibrated for glm_5.3_flash_i4x.ckpt (IQ3_XXS
  // gate / up, Q4_K down: 11.53125 MiB an expert). See Debug/GLM5_3ResidentSlots.md for the fit and
  // validation. The other text weights, pinned with the embedding, take 9.20 GiB, so 8 GiB keeps
  // only the routing width.
  var expertResidentSlotsForGLM5_3: [Int] {
    switch self {
    case ._8GiB:
      return Array(repeating: 8, count: 42)
    case ._16GiB:
      return [
        8, 8, 8, 8, 16, 12, 12, 8, 12, 16, 16, 16, 16, 16,
        16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 12, 12,
        16, 12, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 12, 12,
      ]
    case ._24GiB:
      return [
        20, 20, 20, 24, 28, 28, 32, 28, 32, 32, 32, 32, 32, 32,
        36, 36, 32, 36, 36, 36, 32, 36, 32, 32, 36, 32, 36, 32,
        28, 32, 32, 32, 28, 28, 32, 32, 32, 32, 36, 32, 32, 32,
      ]
    case ._32GiB:
      return [
        40, 36, 40, 44, 44, 44, 44, 52, 52, 44, 44, 44, 44, 52,
        52, 44, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52, 52,
        44, 52, 52, 52, 44, 44, 44, 44, 52, 52, 52, 44, 52, 52,
      ]
    case ._40GiB:
      return [
        92, 84, 72, 92, 72, 72, 72, 72, 64, 52, 52, 52, 52, 64,
        64, 52, 52, 64, 64, 64, 64, 64, 64, 64, 64, 64, 72, 72,
        64, 64, 64, 64, 56, 52, 64, 52, 64, 64, 64, 64, 72, 72,
      ]
    case ._48GiB:
      return [
        132, 132, 112, 124, 92, 92, 92, 104, 84, 64, 72, 64, 72, 72,
        72, 64, 64, 72, 72, 76, 72, 72, 84, 76, 84, 76, 84, 84,
        76, 84, 72, 72, 72, 72, 72, 72, 84, 72, 84, 84, 84, 84,
      ]
    case ._56GiB:
      return [
        152, 152, 152, 144, 112, 112, 112, 124, 104, 76, 84, 84, 84, 92,
        84, 72, 72, 84, 84, 92, 92, 92, 92, 92, 92, 92, 104, 104,
        92, 104, 84, 92, 92, 92, 92, 92, 96, 92, 96, 92, 104, 104,
      ]
    case ._64GiB:
      return [
        172, 172, 172, 164, 124, 132, 132, 144, 124, 92, 92, 92, 96, 104,
        104, 84, 92, 92, 96, 104, 104, 104, 112, 108, 112, 112, 120, 124,
        116, 124, 104, 104, 112, 112, 112, 108, 116, 112, 112, 112, 116, 124,
      ]
    case ._72GiB:
      return [
        192, 196, 192, 184, 144, 152, 152, 156, 136, 112, 112, 112, 112, 120,
        112, 96, 104, 108, 112, 116, 116, 120, 124, 124, 124, 124, 136, 140,
        136, 140, 120, 124, 128, 132, 132, 128, 132, 132, 132, 132, 136, 144,
      ]
    case .disabled:
      return Array(repeating: 288, count: 42)
    }
  }

  // What the weights hold at this tier, with the DFlash2 drafter when it loads.
  func residentSizeForGLM5_3(draft: Bool) -> UInt64 {
    let weightsSize: UInt64
    switch self {
    case ._8GiB:
      // The other text weights and 8 experts of 11.53125 MiB per layer.
      weightsSize = 9_877_086_584 + 42 * 8 * 12_091_392
    case ._16GiB, ._24GiB, ._32GiB, ._40GiB, ._48GiB, ._56GiB, ._64GiB, ._72GiB:
      weightsSize = UInt64(rawValue) * 1_024 * 1_024 * 1_024
    case .disabled:
      weightsSize = 157_265_297_408  // The whole glm_5.3_flash_i4x.ckpt, about 146.47 GiB.
    }
    // The drafter loads whole at every tier.
    let drafterSize: UInt64 =
      draft
      ? 1_058_441_216  // glm_5.3_flash_dflash2_q5k_trailer.ckpt, 0.99 GiB.
      : 0
    return weightsSize + drafterSize
  }

  // Treat this tier as a ceiling: pick the largest tier at or below it whose resident weights, with
  // the DFlash2 drafter when it loads, fit in 75% of available memory, falling back to the smallest
  // tier when none fits.
  func residentTierForGLM5_3(availableMemory: UInt64, draft: Bool) -> Self {
    let budget = availableMemory / 4 * 3
    // allCases ascends by resident size, ending with .disabled, which loads every weight.
    let ceiling = Self.allCases.firstIndex(of: self)!
    return Self.allCases[...ceiling].last { $0.residentSizeForGLM5_3(draft: draft) <= budget }
      ?? ._8GiB
  }

  // An explicit .disabled always loads every weight. Otherwise the requested tier, or the automatic
  // one when nil, is a ceiling for what fits in the memory available now.
  static func residentTierForGLM5_3(requested: Self?, draft: Bool) -> Self {
    guard requested != .disabled else { return .disabled }
    return (requested ?? DeviceCapability.weightsStreaming).residentTierForGLM5_3(
      availableMemory: DeviceCapability.availableMemory, draft: draft)
  }
}

/// Loaded model storage is shared by copies. KV and drafter state belong to the caller's session;
/// use the same graph and generator while continuing a session.
public struct GLM5_3TextGenerator: TextGenerator {
  public static let version: LLMVersion = .glm_5_3_flash
  // About 192K tokens of latent, indexer and pooled rows over 11 attention layers, plus the KDA
  // states.
  public static let estimatedKVCacheSize: UInt64 = 4 * 1_024 * 1_024 * 1_024
  static let maximumContextLength = 192 * 1_024

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

  /// A temperature and a min-p over the tempered distribution, applied as a window below the
  /// largest logit.
  public struct Sampling: Equatable {
    public let temperature: Float
    public let minP: Float
    let window: Float

    public init(temperature: Float, minP: Float) {
      self.temperature = temperature
      self.minP = minP
      window = temperature * log(1 / minP)
    }

    static let thinking = Sampling(temperature: 1, minP: 0.01)
    /// Output in the deterministic work attitude. Greedy output falls into enumeration loops in
    /// long agent contexts that sampling at this temperature avoids.
    public static let deterministic = Sampling(temperature: 0.7, minP: 0.05)
    /// Output in the creative work attitude.
    public static let creative = Sampling(temperature: 0.9, minP: 0.02)
  }

  public struct Statistics: Sendable {
    public var prefillDurationSoFar: Float = 0
    public var prefillTokensSoFar = 0
    public var tokenGenerationDurationSoFar: Float = 0
    public var tokenGeneratedSoFar = 0
    /// Forward passes of the decode loop: one a token without the drafter, one a verify with it.
    public var decodeStepsSoFar = 0

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
  /// pair a call writes (a graph cannot write the buffers it reads). A verify writes its rows' states
  /// to the histories instead, so it can keep any prefix of them.
  public struct KVCache {
    struct Layer {
      var latent: DynamicGraph.Tensor<Float16>?
      var indexer: DynamicGraph.Tensor<Float16>?
      var pooled: DynamicGraph.Tensor<Float16>?
      var convStates = [DynamicGraph.Tensor<Float16>]()
      var recurrentStates = [DynamicGraph.Tensor<Float>]()
      var convHistory: DynamicGraph.Tensor<Float16>?
      var recurrentHistory: DynamicGraph.Tensor<Float>?
    }
    var layers = [Layer]()
    /// How many tokens it holds, which is where the next decode continues from.
    public internal(set) var tokenLength = 0
    /// An unavailable image kept its placeholder rows, so checkpoints would not match its digest.
    var hasPaddedImages = false
    // The DFlash2 drafter's state: each layer's keys and values, position p at row
    // p - draftCacheOrigin; the target rows of positions [first, first + rows), whose keys and values
    // the next draft writes; and the first position the caches hold, before which drafts see nothing.
    var draftKeys = [DynamicGraph.Tensor<Float16>]()
    var draftValues = [DynamicGraph.Tensor<Float16>]()
    var draftCacheOrigin = 0
    var draftData: (targets: DynamicGraph.Tensor<Float>, rows: Int, first: Int)?
    var draftHistoryStart = 0

    public init() {}

    var isEmpty: Bool { layers.isEmpty }
    var capacity: Int { layers.lazy.compactMap(\.latent).first?.shape[1] ?? 0 }

    /// KDA states and the drafter's caches are rewritten, so they are copied, and so are the
    /// drafter's target rows. The other KDA pair and the histories are written before they are read,
    /// and attention rows past `tokenLength` are never read back, so they stay shared.
    public func snapshot() -> KVCache {
      var cache = self
      for index in cache.layers.indices where !cache.layers[index].convStates.isEmpty {
        cache.layers[index].convStates[0] = cache.layers[index].convStates[0].copied()
        cache.layers[index].recurrentStates[0] = cache.layers[index].recurrentStates[0].copied()
      }
      cache.draftKeys = draftKeys.map { $0.copied() }
      cache.draftValues = draftValues.map { $0.copied() }
      cache.draftData = draftData.map { ($0.targets.copied(), $0.rows, $0.first) }
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
    let drafterFile: String?
    let draftRows: Int?
    // Expert residency is resolved whenever the model is built, so each weights load sees the
    // memory available then.
    private(set) var configuration = GLM5_3ModelConfiguration.glm5_3Flash
    // Whether this load drafts, decided with its tier: the drafter's file has to be there, and the
    // tier left beside it has to be above 16 GiB.
    private(set) var usesDrafter = false
    // The drafter's shape, also decided with the tier. Its block is the most rows a step verifies,
    // the pending token and its drafts, so it drafts nothing a step could not keep.
    private(set) var draft = GLM5_3DFlash2Configuration.glm5_3Flash
    private(set) var weightsStreaming = DeviceCapability.WeightsStreaming.disabled
    private var cachedModel: ModelBuilder<(cached: Int, count: Int, logits: Int, targets: Int)>?
    private var cachedDrafter:
      ModelBuilder<(mainRows: Int, temperature: Float, historyOffset: Int)>?

    init(
      requestedWeightsStreaming: DeviceCapability.WeightsStreaming?, drafterFile: String?,
      draftRows: Int?
    ) {
      self.requestedWeightsStreaming = requestedWeightsStreaming
      self.drafterFile = drafterFile
      self.draftRows = draftRows
    }

    /// Whether any layer streams its expert banks.
    var isStreaming: Bool {
      configuration.expertResidentSlots.contains { $0 < configuration.expertCount }
    }

    // One whole-model graph for every chunk and decode step, keyed by the logit rows (more than one
    // is a verify, which keeps the KDA states after each row) and the drafter's target rows.
    var model: ModelBuilder<(cached: Int, count: Int, logits: Int, targets: Int)> {
      if let cachedModel { return cachedModel }
      usesDrafter = drafterFile.map { FileManager.default.fileExists(atPath: $0) } ?? false
      var tier = DeviceCapability.WeightsStreaming.residentTierForGLM5_3(
        requested: requestedWeightsStreaming, draft: usesDrafter)
      if usesDrafter, tier != .disabled, tier.rawValue <= 16 {
        usesDrafter = false
        tier = DeviceCapability.WeightsStreaming.residentTierForGLM5_3(
          requested: requestedWeightsStreaming, draft: false)
      }
      weightsStreaming = tier
      configuration.expertResidentSlots = tier.expertResidentSlotsForGLM5_3
      // Under weights streaming a step verifies at most 4 rows: every row adds its pool misses, so
      // rows past that gain little. A block holds at least the pending token and one draft.
      draft.blockSize = max(
        2, draftRows ?? (isStreaming ? 4 : GLM5_3DFlash2Configuration.glm5_3Flash.blockSize))
      let configuration = configuration
      let targetLayers = usesDrafter ? GLM5_3DFlash2Configuration.glm5_3Flash.targetLayers : []
      let model = ModelBuilder {
        (shape: (cached: Int, count: Int, logits: Int, targets: Int), _) in
        GLM5_3CausalLM(
          Float16.self, tokenLength: shape.count, cachedTokenLength: shape.cached,
          logitTokenLength: shape.logits, targetLayers: shape.targets > 0 ? targetLayers : [],
          targetTokenLength: shape.targets, stateCheckpointCount: shape.logits - 1,
          configuration: configuration)
      }
      model.maxConcurrency = .limit(4)
      cachedModel = model
      return model
    }

    /// The DFlash2 drafter, keyed by its main rows, its sampling temperature, and where its view
    /// starts in each layer's caches; temperature 0 drafts greedily.
    var drafter: ModelBuilder<(mainRows: Int, temperature: Float, historyOffset: Int)> {
      if let cachedDrafter { return cachedDrafter }
      let configuration = configuration
      let draft = draft
      let drafter = ModelBuilder {
        (key: (mainRows: Int, temperature: Float, historyOffset: Int), _) in
        GLM5_3DFlash2(
          Float16.self, mainRows: key.mainRows, temperature: key.temperature,
          historyOffset: key.historyOffset, configuration: configuration, draft: draft)
      }
      drafter.maxConcurrency = .limit(4)
      cachedDrafter = drafter
      return drafter
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
      cachedDrafter = nil
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
  /// The DFlash2 drafter's store. With it, each decode step drafts a block and verifies a prefix
  /// of it, greedy or sampled. A load drafts only when the file exists and the weights tier it
  /// leaves is above 16 GiB; otherwise it decodes without it.
  public let drafterFile: String?
  /// Verify this many rows every step (1 + drafts). When nil, steps choose their rows, at most 4
  /// under weights streaming. The drafter fills only as many rows as a step can verify.
  public let draftRows: Int?
  private static let recentStatisticsLimit = 3
  private var recentInteractionStatistics = [Statistics]()

  public init(
    filePath: String, chunkedPrefillMaxLength: Int,
    weightsStreaming: DeviceCapability.WeightsStreaming? = nil, drafterFile: String? = nil,
    draftRows: Int? = nil
  ) {
    precondition(
      draftRows.map { (1...GLM5_3DFlash2Configuration.glm5_3Flash.blockSize).contains($0) } ?? true)
    self.filePath = filePath
    self.chunkedPrefillMaxLength = chunkedPrefillMaxLength
    self.weightsStreaming = weightsStreaming
    self.drafterFile = drafterFile
    self.draftRows = draftRows
    storage = Storage(
      requestedWeightsStreaming: weightsStreaming, drafterFile: drafterFile, draftRows: draftRows)
  }

  public var filePaths: [String] { [filePath] + [drafterFile].compactMap { $0 } }

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
    for interaction in recentInteractionStatistics {
      statistics.decodeStepsSoFar += interaction.decodeStepsSoFar
    }
    statistics.prefillTokensSoFar = Int((Float(statistics.prefillTokensSoFar) / count).rounded())
    statistics.tokenGeneratedSoFar = Int(
      (Float(statistics.tokenGeneratedSoFar) / count).rounded())
    statistics.decodeStepsSoFar = Int((Float(statistics.decodeStepsSoFar) / count).rounded())
    return statistics
  }

  /// The latest decode on its own; `statistics` averages the recent ones.
  public var lastInteractionStatistics: Statistics {
    recentInteractionStatistics.last ?? Statistics()
  }

  /// At the requested or automatic tier, with the drafter when that tier drafts. A load settles on
  /// that tier or a smaller one.
  public var residentWeightsSize: UInt64 {
    let tier = weightsStreaming ?? DeviceCapability.weightsStreaming
    // As when the model is built: a tier at or below 16 GiB decodes without the drafter.
    let draft =
      (drafterFile.map { FileManager.default.fileExists(atPath: $0) } ?? false)
      && (tier == .disabled || tier.rawValue > 16)
    return tier.residentSizeForGLM5_3(draft: draft)
  }

  /// The tier the loaded weights use, or nil before they load.
  public var residentWeightsStreaming: DeviceCapability.WeightsStreaming? {
    os_unfair_lock_lock(&storage.lock)
    defer { os_unfair_lock_unlock(&storage.lock) }
    return storage.isLoaded ? storage.weightsStreaming : nil
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
  /// tokens so far. Thinking samples at T = 1 with min-p 0.01; the output after it samples with
  /// `outputSampling`, or decodes greedily without it.
  public mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, outputSampling: Sampling?, kvCache: inout KVCache,
    contextTokens: [Int32],
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
    // Building the model picks this load's tier, and with it whether the load drafts and the
    // drafter's block.
    let model = storage.model
    let drafting = storage.usesDrafter
    let draft = storage.draft
    // The window of positions a block attends to before its anchor.
    let window = draft.windowRows - 1
    // A step verifies the pending token and at most the drafted block.
    let maxDraftRows = draftRows ?? draft.blockSize
    // Each layer's drafter keys and values, which the drafter binds whole.
    let draftCacheRows = 2 * draft.windowRows + 4_096
    let shouldRestore = kvCache.isEmpty
    var capacity = Self.cacheCapacity(for: totalLength + 1)
    Self.resizeCaches(
      graph: graph, kvCache: &kvCache, capacity: capacity, configuration: configuration)
    if !drafting {
      // A session continued from a load that drafted keeps no drafter state into this one.
      kvCache.draftKeys = []
      kvCache.draftValues = []
      kvCache.draftData = nil
    } else if kvCache.draftKeys.isEmpty {
      // Once a draft's view would run past the end, its window moves to the front, and the rows past
      // two windows keep that copy clear of itself. Zeros keep the keys the masks close finite.
      let caches = { () -> [DynamicGraph.Tensor<Float16>] in
        (0..<draft.layers).map { _ in
          let cache = graph.variable(
            .GPU(0), .WC(draftCacheRows, draft.keyValueWidth), of: Float16.self)
          cache.full(0)
          return cache
        }
      }
      kvCache.draftKeys = caches()
      kvCache.draftValues = caches()
      kvCache.draftData = nil
    }
    // A verify keeps the KDA states after each of its rows, at most `maxDraftRows` of them. A load
    // that never verifies more than one row keeps none.
    let historyRows = drafting && maxDraftRows > 1 ? maxDraftRows : 0
    for index in kvCache.layers.indices where !kvCache.layers[index].convStates.isEmpty {
      guard historyRows > 0 else {
        kvCache.layers[index].convHistory = nil
        kvCache.layers[index].recurrentHistory = nil
        continue
      }
      guard
        kvCache.layers[index].recurrentHistory?.shape[1]
          != historyRows * configuration.linearHeads
      else { continue }
      kvCache.layers[index].convHistory = graph.variable(
        .GPU(0),
        .NHWC(
          1, configuration.linearConvKernel - 1 + historyRows - 1, 1, configuration.linearConvDim),
        of: Float16.self)
      kvCache.layers[index].recurrentHistory = graph.variable(
        .GPU(0),
        .NHWC(
          1, historyRows * configuration.linearHeads, configuration.linearHeadDim,
          configuration.linearHeadDim), of: Float.self)
    }
    // The drafter's target rows go out as copies: the model's outputs are reused by its next call.
    defer {
      if let draftData = kvCache.draftData {
        kvCache.draftData = (draftData.targets.copied(), draftData.rows, draftData.first)
      }
    }
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
    // length, so the tensor arena is reserved once per capacity. A drafting load also reserves a
    // verify's logits and checkpoints and the seed's target rows: an arena a later shape outgrows is
    // rebuilt from scratch.
    func compilePrefill(isEager: Bool) {
      let chunk = min(chunkedPrefillMaxLength, capacity - 1)
      let logits = drafting ? min(maxDraftRows, chunk) : 1
      model.compile(
        (
          cached: capacity - chunk, count: chunk, logits: logits,
          targets: drafting ? min(window, chunk) : 0
        ),
        inputs: [tokenInput(Array(repeating: 0, count: chunk)), emptyInjected, emptyTokens]
          + Self.cacheInputs(kvCache, cached: capacity - chunk, count: chunk, logits: logits),
        isEager: isEager)
    }
    func compileDecode() {
      model.compile(
        (cached: capacity - 1, count: 1, logits: 1, targets: 0),
        inputs: [tokenInput([0]), emptyInjected, emptyTokens]
          + Self.cacheInputs(kvCache, cached: capacity - 1, count: 1), isEager: true)
    }
    // A drafting load verifies instead: its longest step at the end of the cache, so no later step
    // outgrows the arena, which would rebuild it from scratch.
    func compileVerify() {
      let rows = maxDraftRows
      model.compile(
        (cached: capacity - rows, count: rows, logits: rows, targets: rows),
        inputs: [tokenInput(Array(repeating: 0, count: rows)), emptyInjected, emptyTokens]
          + Self.cacheInputs(kvCache, cached: capacity - rows, count: rows, logits: rows),
        isEager: true)
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
      if drafting, let drafterFile = storage.drafterFile {
        let drafter = storage.drafter
        // At a full window of seed rows, the most a draft takes, so the read below sees every
        // parameter and the tensor arena is reserved once.
        drafter.compile(
          (mainRows: window, temperature: 0, historyOffset: 0),
          inputs: [
            graph.variable(
              .GPU(0), .WC(window, draft.targetLayers.count * configuration.hiddenSize),
              of: Float.self),
            graph.variable(.GPU(0), .WC(window, draft.headDim), of: Float16.self),
            graph.variable(.GPU(0), format: .NHWC, shape: [draft.blockSize], of: Int32.self),
            graph.variable(.GPU(0), .WC(draft.blockSize, draft.headDim), of: Float16.self),
            graph.variable(
              .GPU(0), .NHWC(1, 1, draft.blockSize, 2 * window + draft.blockSize),
              of: Float16.self),
          ] + Self.draftCacheInputs(kvCache))
        let result = try? graph.openStore(drafterFile, flags: .readOnly) { store in
          try store.read(
            "text_model", model: drafter, codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)]
          ) { name, _, _, _ in
            // The drafter reads the trunk's embedding and head, shared below.
            name.hasSuffix("[t-embed_tokens-0-0]") || name.hasSuffix("[t-lm_head-0-0]")
              ? .fail : .continue(name)
          }
        }
        guard let result, (try? result.get()) != nil else { return [] }
        // Only these two: the drafter's layers and norm have the trunk's names too.
        drafter.parameters.share(from: model.parameters) { name, _ in
          name.contains("t-embed_tokens-0-0") || name.contains("t-lm_head-0-0")
            ? .continue(name) : .fail
        }
        drafter.pinMemory = true
      }
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
      guard let sampling = thinkingEnded ? outputSampling : Sampling.thinking else {
        return Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
      }
      let maximum = logits.reduced(.max, axis: [1])
      logits.fill(-Float.infinity, if: logits < (maximum - sampling.window))
      return Functional.gumbelArgmax(logits, axis: 1, scale: sampling.temperature).reshaped(
        format: .NHWC, shape: [1])
    }
    // Out of thinking budget, the next token closes thinking.
    func forcingThinkingEnd(_ token: DynamicGraph.Tensor<Int32>) -> DynamicGraph.Tensor<Int32> {
      guard !thinkingEnded, thinkingTokenCount >= thinkingBudget else { return token }
      return tokenInput([Self.thinkEndToken])
    }

    // Give the next draft the target rows of positions [first, first + rows). Rows right after the
    // draft data extend it to at most a window; any others start the drafter's history over at
    // them, and drafts see nothing before it.
    func extendDraftData(_ targets: DynamicGraph.Tensor<Float>, rows: Int, first: Int) {
      if let draftData = kvCache.draftData, draftData.first + draftData.rows == first {
        let kept = min(draftData.rows, window - rows)
        guard kept > 0 else {
          kvCache.draftData = (targets, rows, first)
          return
        }
        let width = targets.shape[1]
        kvCache.draftData = (
          Functional.concat(
            axis: 0,
            draftData.targets.reshaped(
              .WC(kept, width), offset: [draftData.rows - kept, 0], strides: [width, 1]),
            targets.reshaped(.WC(rows, width), offset: [0, 0], strides: [width, 1])),
          kept + rows, first - kept
        )
      } else {
        kvCache.draftData = (targets, rows, first)
        kvCache.draftHistoryStart = first
        kvCache.draftCacheOrigin = first - window
      }
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

    // A drafting load gives the drafter the target rows of the window before the pending token.
    let firstTarget = max(0, totalLength - window)
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
      // A rebuilt graph keeps its outputs, so a drafting load always outputs target rows.
      let targetRows = drafting ? end - max(position, firstTarget) : 0
      let outputs = model(
        (cached: position, count: length, logits: 1, targets: drafting ? max(1, targetRows) : 0),
        inputs: textTokens,
        [injected, postTokens] + Self.cacheInputs(kvCache, cached: position, count: length))
      DynamicGraph.flags = flags
      Self.keepStates(&kvCache)
      if targetRows > 0 {
        extendDraftData(
          outputs[1].as(of: Float.self).copied(), rows: targetRows, first: end - targetRows)
      }
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

    let queueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = queueWatermark * 16
    defer { DynamicGraph.queueWatermark = queueWatermark }
    var generated = [Int32]()
    var runningContextTokens = contextTokens
    let decodeStartTime = CACurrentMediaTime()
    let initialDecodeDuration =
      recentInteractionStatistics[statisticsIndex].tokenGenerationDurationSoFar
    defer {
      recentInteractionStatistics[statisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - decodeStartTime) + initialDecodeDuration
    }
    if drafting {
      // As in DeepSeek4_1TextGenerator, each step drafts a block after the pending token, then
      // verifies the pending token and a prefix of the block in one forward and keeps the drafts the
      // trunk's own picks reproduce. The draft reads the last verify's target rows and writes their
      // keys and values; the verify at the length the last step took compiles while it runs, and the
      // next draft's graph while the verify runs. Sampled rows run speculative sampling against the
      // candidate distribution q each draft was drawn from: draft i stays with probability
      // min(1, p(d) / q(d)), and the first rejected row samples max(0, p - q) instead.
      let drafter = storage.drafter
      let block = draft.blockSize
      let vocabularySize = configuration.vocabularySize
      compileVerify()
      let pendingCPU = pendingToken.toCPU()
      pendingCPU.joined()
      var nextToken = pendingCPU[0]
      // Attention masks by [main rows, first open view row, committed rows]. Within a window of the
      // drafter's history start every step opens a new first row, so only the rest are kept.
      var draftMasks = [[Int]: DynamicGraph.Tensor<Float16>]()
      let maskTokens = Array(repeating: draft.maskTokenID, count: draft.proposals)
      // Tensor.toGPU waits for the GPU; these copies run on the stream instead, and their CPU
      // sources live until the next join.
      var uploads = [DynamicGraph.AnyTensor]()
      func upload<E: TensorNumeric>(_ tensor: Tensor<E>) -> DynamicGraph.Tensor<E> {
        let source = graph.variable(tensor)
        uploads.append(source)
        return source.toGPU(0)
      }
      // The drafter's rotary rows, built when a draft would run past them.
      var rotaryStart = 0
      var rotary: DynamicGraph.Tensor<Float16>?
      func rotaryRows(first: Int, count: Int) -> DynamicGraph.Tensor<Float16> {
        if rotary.map({ first < rotaryStart || first + count > rotaryStart + $0.shape[0] }) ?? true
        {
          rotaryStart = first
          rotary = upload(
            GLM5_3DFlash2RotaryEmbedding(
              rows: max(8_192, count), firstPosition: first, draft: draft, of: Float16.self))
        }
        return rotary![(first - rotaryStart)..<(first - rotaryStart + count), 0..<draft.headDim]
          .copied()
      }
      // Where a view of `mainRows` from `first` starts in the drafter's caches, moving the window
      // before `first` to the front when the view would run past the end.
      func draftViewBase(first: Int, mainRows: Int) -> Int {
        let base = first - window - kvCache.draftCacheOrigin
        guard base + window + mainRows + block > draftCacheRows else { return base }
        for var cache in kvCache.draftKeys + kvCache.draftValues {
          cache[0..<window, 0..<draft.keyValueWidth] =
            cache[base..<(base + window), 0..<draft.keyValueWidth]
        }
        kvCache.draftCacheOrigin += base
        return 0
      }
      // Wall milliseconds of a verify by rows, from its call to its picks, from a linear prior; of a
      // draft, from its call to its candidates; and of compiling a verify, which a draft overlaps
      // only at the length it prepares. Every 16th step verifies another length, in turn, so no
      // estimate goes stale while the policy holds one length.
      var verifyEstimates = (0...maxDraftRows).map { 18 + 5 * Double(max(0, $0 - 1)) }
      var draftMilliseconds = 4.0
      var compileMilliseconds = 3.0
      // The selector's peak probability is not calibrated, so acceptance is learned by bins of it
      // online: a draft's chance to be kept given that every draft before it was. Counts decay so
      // the estimate follows the text.
      var binKept = [Double](repeating: 0, count: 10)
      var binSeen = [Double](repeating: 0, count: 10)
      func keepProbability(_ confidence: Float) -> Double {
        let bin = min(9, max(0, Int(confidence * 10)))
        return (binKept[bin] + 4 * (Double(bin) + 0.5) / 10) / (binSeen[bin] + 4)
      }
      var steps = 0
      var probe = 0
      // The rows the last step verified, which the next step's draft prepares.
      var lastRows: Int?
      // Only main rows change the drafter's input shapes, so a new temperature or a view moved along
      // the caches compiles it explicitly.
      var drafterKey: (mainRows: Int, temperature: Float, historyOffset: Int)?
      // Stand-ins for a verify's tokens, and for a draft's rotary rows and mask, to compile them
      // ahead with.
      let standInTokens = graph.variable(.GPU(0), format: .NHWC, shape: [block], of: Int32.self)
      let standInRotary = graph.variable(.GPU(0), .WC(block, draft.headDim), of: Float16.self)
      let standInMask = graph.variable(
        .GPU(0), .NHWC(1, 1, block, window + 2 * block), of: Float16.self)
      while kvCache.tokenLength < Self.maximumContextLength {
        var result: [Int32]?
        autoreleasepool {
          let position = kvCache.tokenLength
          // The fed token decides the sampling mode: thinking samples, and the output after it
          // samples with `outputSampling` or, without it, decodes greedily.
          let thinking =
            !thinkingEnded && nextToken != Self.thinkEndToken
            && nextToken != Self.toolCallStartToken
          let sampling = thinking ? Sampling.thinking : outputSampling
          let temperature = sampling?.temperature ?? 0
          // A step never crosses a context-cache checkpoint.
          let nextCheckpoint = (position / checkpointStride + 1) * checkpointStride
          var rows = 1
          // The drafts the step verifies, their confidences, and the candidates each was drawn from.
          var draftTokens = [Int32]()
          var draftConfidence = [Float]()
          var candidates: (scores: DynamicGraph.Tensor<Float>, ids: DynamicGraph.Tensor<Int32>)?
          var prepared: Int?
          var drafted = false
          // A stop token is fed alone, with nothing drafted after it.
          if let draftData = kvCache.draftData, !Self.stopTokens.contains(nextToken) {
            drafted = true
            let draftStart = CACurrentMediaTime()
            // View row r holds position first - window + r: the block attends to itself and to
            // the window ending at the last committed row, none before the drafter's history.
            let mainRows = draftData.targets.shape[0]
            let viewRows = window + mainRows + block
            let base = draftViewBase(first: draftData.first, mainRows: mainRows)
            let open = max(draftData.rows, window - draftData.first + kvCache.draftHistoryStart)
            let maskKey = [mainRows, open, draftData.rows]
            let mask: DynamicGraph.Tensor<Float16>
            if let cachedMask = draftMasks[maskKey] {
              mask = cachedMask
            } else {
              var values = [Float16](repeating: 0, count: block * viewRows)
              for row in 0..<block {
                for column in Array(0..<open)
                  + Array((window + draftData.rows)..<(window + mainRows))
                {
                  values[row * viewRows + column] = -Float16.greatestFiniteMagnitude
                }
              }
              mask = upload(
                Tensor(values, kind: .CPU, format: .NHWC, shape: [1, 1, block, viewRows]))
              if open == draftData.rows { draftMasks[maskKey] = mask }
            }
            let draftInputs: [DynamicGraph.AnyTensor] =
              [
                draftData.targets, rotaryRows(first: draftData.first, count: mainRows),
                upload(
                  Tensor<Int32>([nextToken] + maskTokens, kind: .CPU, format: .NHWC, shape: [block])
                ), rotaryRows(first: position, count: block), mask,
              ] + Self.draftCacheInputs(kvCache)
            // The last verify built the graph for this draft, unless it is the first.
            if drafterKey.map({ $0 != (mainRows, temperature, base) }) ?? true {
              drafterKey = (mainRows, temperature, base)
              drafter.compile(drafterKey!, inputs: draftInputs)
            }
            let draftOutputs = drafter(
              drafterKey!, inputs: draftInputs[0], Array(draftInputs.dropFirst()))
            // A probe verifies another length than the last, in turn. Only a prepared verify counts
            // toward the estimates, so the probe's length is the one prepared.
            var probeRows: Int?
            if draftRows == nil {
              steps += 1
              if steps.isMultiple(of: 16) {
                let others = (1...maxDraftRows).filter { $0 != lastRows }
                probeRows = others[probe % others.count]
                probe += 1
              }
            }
            // Prepare this step's verify while the draft runs, at the length the last step
            // verified or the probe's.
            if let aheadRows = probeRows ?? lastRows, position + aheadRows <= capacity {
              model.compile(
                (cached: position, count: aheadRows, logits: aheadRows, targets: aheadRows),
                inputs: [
                  standInTokens.reshaped(format: .NHWC, shape: [aheadRows]), emptyInjected,
                  emptyTokens,
                ]
                  + Self.cacheInputs(kvCache, cached: position, count: aheadRows, logits: aheadRows)
              )
              prepared = aheadRows
            }
            let draftTokenCPU = draftOutputs[0].as(of: Int32.self).toCPU()
            let confidence = draftOutputs[1].as(of: Float.self).toCPU()
            if sampling != nil {
              candidates = (
                draftOutputs[2].as(of: Float.self).toCPU(),
                draftOutputs[3].as(of: Int32.self).toCPU()
              )
            }
            confidence.joined()
            uploads = []
            draftMilliseconds =
              0.8 * draftMilliseconds
              + 0.2
              * min(1000 * (CACurrentMediaTime() - draftStart), 2 * draftMilliseconds)
            if let draftRows {
              rows = draftRows
            } else if let probeRows {
              rows = probeRows
            } else {
              // Maximize expected tokens per millisecond; a draft is kept only if every one before
              // it is. Rows are added one draft at a time, each on its own chance, which reads only
              // the drafts before it: whether a draft is verified never depends on its value, as
              // exact sampling needs. Later drafts are taken to be as likely as the one being added.
              func milliseconds(_ length: Int) -> Double {
                verifyEstimates[length] + draftMilliseconds
                  + (prepared == length ? 0 : compileMilliseconds)
              }
              var expected = 1.0
              var prefix = 1.0
              var rate = expected / milliseconds(1)
              for candidate in 2...maxDraftRows {
                let probability = keepProbability(confidence[candidate - 2, 0])
                var projectedExpected = expected
                var projectedPrefix = prefix
                var projectedRate = 0.0
                for length in candidate...maxDraftRows {
                  projectedPrefix *= probability
                  projectedExpected += projectedPrefix
                  projectedRate = max(projectedRate, projectedExpected / milliseconds(length))
                }
                guard projectedRate > rate else { break }
                prefix *= probability
                expected += prefix
                rows = candidate
                rate = expected / milliseconds(candidate)
              }
            }
            rows = max(
              1,
              min(rows, nextCheckpoint - position, Self.maximumContextLength - position))
            // The step stops where the thinking budget forces its end.
            if thinking { rows = min(rows, max(1, thinkingBudget - thinkingTokenCount)) }
            draftTokens = (0..<(rows - 1)).map { draftTokenCPU[$0] }
            if thinking,
              let end = draftTokens.firstIndex(where: {
                $0 == Self.thinkEndToken || $0 == Self.toolCallStartToken
              })
            {
              // One sampling mode per step: its last row verifies a drafted end of thinking like any
              // draft, and the next step feeds it.
              rows = end + 1
              draftTokens = Array(draftTokens.prefix(end + 1))
            }
            draftConfidence = draftTokens.indices.map { confidence[$0, 0] }
          }
          if position + rows > capacity {
            graph.joined()
            capacity = Self.cacheCapacity(for: position + rows)
            Self.resizeCaches(
              graph: graph, kvCache: &kvCache, capacity: capacity, configuration: configuration)
            compileVerify()
            prepared = nil
          }
          let ids = [nextToken] + draftTokens.prefix(rows - 1)
          let tokenTensor = upload(
            Tensor<Int32>(ids, kind: .CPU, format: .NHWC, shape: [rows]))
          let verifyKey = (cached: position, count: rows, logits: rows, targets: rows)
          let verifyInputs = Self.cacheInputs(kvCache, cached: position, count: rows, logits: rows)
          if prepared != rows {
            let compileStart = CACurrentMediaTime()
            model.compile(
              verifyKey, inputs: [tokenTensor, emptyInjected, emptyTokens] + verifyInputs)
            compileMilliseconds =
              0.8 * compileMilliseconds
              + 0.2
              * min(1000 * (CACurrentMediaTime() - compileStart), 2 * compileMilliseconds)
          }
          let verifyStart = CACurrentMediaTime()
          let outputs = model(
            verifyKey, inputs: tokenTensor, [emptyInjected, emptyTokens] + verifyInputs)
          let logits = outputs[0].as(of: Float16.self)
          let targets = outputs[1].as(of: Float.self)
          if drafted {
            // While the verify runs, make room for the next draft and build its graph: its view
            // starts a window before this verify's first row, whatever the verify keeps.
            let nextBase = draftViewBase(first: position, mainRows: rows)
            if drafterKey.map({ $0 != (rows, temperature, nextBase) }) ?? true {
              drafterKey = (rows, temperature, nextBase)
              drafter.compile(
                drafterKey!,
                inputs: [
                  targets, standInRotary.reshaped(.WC(rows, draft.headDim)), standInTokens,
                  standInRotary,
                  standInMask.reshaped(.NHWC(1, 1, block, window + rows + block)),
                ] + Self.draftCacheInputs(kvCache))
            }
          }
          var picks = [Int32]()
          if let sampling {
            let maximum = logits.reduced(.max, axis: [1])
            logits.fill(-Float.infinity, if: logits < (maximum - sampling.window))
            var acceptance:
              (
                target: DynamicGraph.Tensor<Float>, uniform: DynamicGraph.Tensor<Float>,
                correction: DynamicGraph.Tensor<Int32>
              )?
            // q(d) of each draft, softmax(score / temperature) over its candidates.
            var drawn = [Float]()
            if !draftTokens.isEmpty, let candidates {
              let drafts = draftTokens.count
              let count = draft.selectorCandidates
              // q over the vocabulary as flat indices and values, zero off the candidates.
              var candidateIndices = [Int32]()
              var candidateProbabilities = [Float]()
              for index in 0..<drafts {
                let tempered = (0..<count).map {
                  candidates.scores[index, $0] / sampling.temperature
                }
                let peak = tempered.max()!
                let weights = tempered.map { exp($0 - peak) }
                let total = weights.reduce(0, +)
                drawn.append(1)
                for candidate in 0..<count {
                  let id = candidates.ids[index, candidate]
                  let isToken = (0..<Int32(vocabularySize)).contains(id)
                  candidateIndices.append(Int32(index * vocabularySize) + (isToken ? id : 0))
                  candidateProbabilities.append(isToken ? weights[candidate] / total : 0)
                  if id == draftTokens[index] { drawn[index] = weights[candidate] / total }
                }
              }
              let p = Functional.softmax(
                DynamicGraph.Tensor<Float>(from: logits).reshaped(
                  .WC(drafts, vocabularySize), offset: [0, 0], strides: [vocabularySize, 1])
                  * (1 / sampling.temperature))
              let index = upload(
                Tensor<Int32>(
                  (0..<drafts).map { Int32($0 * vocabularySize) + draftTokens[$0] }, kind: .CPU,
                  format: .NHWC, shape: [drafts]))
              let q = Functional.scatterAdd(
                count: drafts * vocabularySize,
                input: upload(
                  Tensor<Float>(
                    candidateProbabilities, kind: .CPU, format: .NHWC, shape: [drafts * count, 1])),
                index: upload(
                  Tensor<Int32>(
                    candidateIndices, kind: .CPU, format: .NHWC, shape: [drafts * count]))
              ).reshaped(.WC(drafts, vocabularySize))
              let uniform = graph.variable(.GPU(0), format: .NHWC, shape: [drafts], of: Float.self)
              uniform.rand(0...1)
              // Each row's residual sample, max(0, p - q), for the first rejected row, drawn in
              // this step's submission so the one join below covers it.
              let residual: DynamicGraph.Tensor<Float> = Functional.log(Functional.ReLU(p - q))
              acceptance = (
                Functional.indexSelect(
                  input: p.reshaped(.WC(drafts * vocabularySize, 1)), index: index
                ).toCPU(), uniform.toCPU(), Functional.gumbelArgmax(residual, axis: 1).toCPU()
              )
            }
            // The bonus token after the last row, should every draft stay.
            let bonus = Functional.gumbelArgmax(
              logits.reshaped(
                .WC(1, vocabularySize), offset: [rows - 1, 0], strides: [vocabularySize, 1]),
              axis: 1, scale: sampling.temperature
            ).reshaped(format: .NHWC, shape: [1]).toCPU()
            bonus.joined()
            uploads = []
            if let acceptance {
              // Picks reproduce the kept drafts, then the corrected or bonus token after them.
              for index in draftTokens.indices {
                // A residual sample of the draft itself means p(d) > q(d), so the draft stays;
                // only rounding can reject it then. An out-of-range sample keeps it as well.
                let corrected = acceptance.correction[index, 0]
                if acceptance.uniform[index] * drawn[index] < acceptance.target[index, 0]
                  || corrected == draftTokens[index]
                  || !(0..<Int32(vocabularySize)).contains(corrected)
                {
                  picks.append(draftTokens[index])
                } else {
                  picks.append(corrected)
                  break
                }
              }
            }
            if picks.count == rows - 1 { picks.append(bonus[0]) }
          } else {
            let selected = Functional.argmax(logits, axis: 1).reshaped(
              format: .NHWC, shape: [rows]
            ).toCPU()
            selected.joined()
            uploads = []
            picks = (0..<rows).map { selected[$0] }
          }
          // Up to the picks, so the caller's time below stays out of the estimate.
          let verifyMilliseconds = 1000 * (CACurrentMediaTime() - verifyStart)
          var kept = 0
          while kept < rows - 1 && draftTokens[kept] == picks[kept] { kept += 1 }
          // Keep the advanced tokens one at a time, through a stop token or the one the caller
          // stops at.
          var commitCount = 0
          var stop: ContinuationState?
          for token in ids.prefix(kept + 1) {
            commitCount += 1
            generated.append(token)
            runningContextTokens.append(token)
            if token == Self.thinkEndToken || token == Self.toolCallStartToken {
              thinkingEnded = true
            } else if !thinkingEnded {
              thinkingTokenCount += 1
            }
            recentInteractionStatistics[statisticsIndex].tokenGeneratedSoFar += 1
            recentInteractionStatistics[statisticsIndex].tokenGenerationDurationSoFar =
              Float(CACurrentMediaTime() - decodeStartTime) + initialDecodeDuration
            if Self.stopTokens.contains(token) {
              stop = .abort
              break
            }
            let handled = continuationHandler(
              position + commitCount, position + commitCount, generated, statistics)
            if handled != .continue {
              stop = handled
              break
            }
          }
          Self.keepStates(&kvCache, rows: rows, droppedRows: rows - commitCount)
          kvCache.tokenLength = position + commitCount
          if drafted {
            kvCache.draftData = (targets, commitCount, position)
          } else {
            // No draft wrote the pending rows' keys, so these follow them.
            extendDraftData(targets, rows: commitCount, first: position)
          }
          if !kvCache.hasPaddedImages, kvCache.tokenLength.isMultiple(of: checkpointStride) {
            contextCache.save(
              graph: graph, tokens: runningContextTokens, checkpointLength: kvCache.tokenLength,
              configuration: configuration, kvCache: kvCache, hasher: &hasher,
              embeddingSpans: embedSpans)
          }
          recentInteractionStatistics[statisticsIndex].decodeStepsSoFar += 1
          if prepared == rows {
            // Samples are capped so a spike cannot price a length out for good.
            verifyEstimates[rows] =
              0.8 * verifyEstimates[rows] + 0.2 * min(verifyMilliseconds, 2 * verifyEstimates[rows])
          }
          lastRows = rows
          if drafted {
            for index in binKept.indices {
              binKept[index] *= 0.995
              binSeen[index] *= 0.995
            }
            for index in draftConfidence.indices where index <= kept {
              let bin = min(9, max(0, Int(draftConfidence[index] * 10)))
              binSeen[bin] += 1
              if index < kept { binKept[bin] += 1 }
            }
          }
          nextToken = picks[commitCount - 1]
          if !thinkingEnded, thinkingTokenCount >= thinkingBudget {
            nextToken = Self.thinkEndToken
          }
          switch stop {
          case .pause:
            result = generated + [nextToken]
          case .abort:
            graph.joined()
            result = generated
          case .continue, nil:
            break
          }
        }
        if let result { return result }
      }
      // The context is full: the last prediction stays pending.
      return generated + [nextToken]
    }

    // Pipelined: the token sampled last step feeds this one while the CPU reads it back, so
    // building the next step overlaps the GPU running the current one.
    compileDecode()
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
        (cached: position, count: 1, logits: 1, targets: 0), inputs: pendingToken,
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
      recentInteractionStatistics[statisticsIndex].decodeStepsSoFar += 1
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
  /// More than one logit row is a verify, which writes its rows' states to the histories.
  static func cacheInputs(_ kvCache: KVCache, cached: Int, count: Int, logits: Int = 1)
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
      if logits > 1, let convHistory = layer.convHistory,
        let recurrentHistory = layer.recurrentHistory
      {
        return [layer.convStates[0], layer.recurrentStates[0], convHistory, recurrentHistory]
      }
      return [
        layer.convStates[0], layer.recurrentStates[0], layer.convStates[1],
        layer.recurrentStates[1],
      ]
    }
  }

  /// Each drafter layer's key and value caches, bound whole.
  static func draftCacheInputs(_ kvCache: KVCache) -> [DynamicGraph.AnyTensor] {
    zip(kvCache.draftKeys, kvCache.draftValues).flatMap { [$0, $1] as [DynamicGraph.AnyTensor] }
  }

  /// After a call with `rows` logit rows, makes the states after all of them but the last
  /// `droppedRows` current.
  private static func keepStates(_ kvCache: inout KVCache, rows: Int = 1, droppedRows: Int = 0) {
    let configuration = GLM5_3ModelConfiguration.glm5_3Flash
    let convRows = configuration.linearConvKernel - 1
    let convDim = configuration.linearConvDim
    let heads = configuration.linearHeads
    let headDim = configuration.linearHeadDim
    let checkpoints = rows - 1
    for index in kvCache.layers.indices where !kvCache.layers[index].convStates.isEmpty {
      guard checkpoints > 0, let conv = kvCache.layers[index].convHistory,
        let recurrent = kvCache.layers[index].recurrentHistory
      else {
        kvCache.layers[index].convStates.swapAt(0, 1)
        kvCache.layers[index].recurrentStates.swapAt(0, 1)
        continue
      }
      // The convolution history ends with the rows after the last token, one row later per
      // checkpoint; the recurrent history starts with the state after every row. Histories and
      // states are separate buffers, so each assignment copies the view directly.
      kvCache.layers[index].convStates[0][0..<1, 0..<convRows, 0..<1, 0..<convDim] =
        conv.reshaped(
          .NHWC(1, convRows, 1, convDim), offset: [0, checkpoints - droppedRows, 0, 0],
          strides: [conv.shape[1] * convDim, convDim, convDim, 1])
      kvCache.layers[index].recurrentStates[0][0..<1, 0..<heads, 0..<headDim, 0..<headDim] =
        recurrent.reshaped(
          .NHWC(1, heads, headDim, headDim), offset: [0, droppedRows * heads, 0, 0],
          strides: [recurrent.shape[1] * headDim * headDim, headDim * headDim, headDim, 1])
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
