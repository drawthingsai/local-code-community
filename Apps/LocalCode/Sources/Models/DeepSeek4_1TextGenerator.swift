import BinaryResources
import Darwin
import DataModels
import Dispatch
import Foundation
import LLM
import NNC
import ProjectHistoryManager
import QuartzCore
import Tokenizer
import os.lock

extension DeviceCapability.WeightsStreaming {
  // Calibrated for deepseek_4.1_flash_0910_i2xxs_w2q2k_trailer.ckpt.
  // See Debug/DeepSeek4_1ResidentSlots.md for the fit and validation.
  var expertResidentSlotsForDeepSeek4_1: [Int] {
    switch self {
    case ._8GiB, ._16GiB:
      return [
        6, 6, 18, 23, 15, 19, 20, 20, 20, 19,
        20, 21, 22, 18, 20, 14, 21, 21, 21, 12,
        20, 21, 21, 23, 20, 18, 19, 20, 20, 22,
        19, 18, 22, 21, 22, 24, 20, 17, 16, 12,
      ]
    case ._24GiB:
      return [
        61, 37, 47, 45, 38, 37, 32, 34, 38, 41,
        34, 36, 39, 40, 42, 54, 39, 36, 40, 55,
        35, 41, 38, 47, 36, 29, 32, 34, 34, 36,
        35, 38, 42, 42, 45, 46, 44, 49, 47, 52,
      ]
    case ._32GiB:
      return [
        103, 91, 69, 61, 77, 60, 44, 53, 53, 54,
        51, 55, 59, 74, 69, 78, 63, 58, 53, 100,
        52, 56, 54, 73, 46, 49, 40, 48, 42, 55,
        46, 48, 58, 61, 61, 68, 71, 82, 85, 83,
      ]
    case ._40GiB:
      return [
        153, 113, 93, 79, 95, 85, 61, 75, 77, 71,
        75, 73, 81, 95, 80, 109, 73, 80, 84, 132,
        72, 79, 78, 106, 56, 54, 57, 82, 62, 72,
        68, 64, 66, 70, 99, 73, 93, 95, 124, 124,
      ]
    case ._48GiB:
      return [
        190, 153, 105, 113, 118, 103, 73, 84, 97, 95,
        104, 83, 116, 134, 96, 148, 84, 103, 96, 166,
        78, 88, 92, 129, 73, 66, 69, 107, 69, 91,
        92, 88, 90, 101, 103, 117, 112, 130, 151, 147,
      ]
    case ._56GiB:
      return [
        200, 191, 143, 127, 144, 130, 103, 110, 113, 118,
        110, 109, 130, 151, 117, 152, 99, 133, 114, 183,
        107, 110, 104, 156, 84, 90, 86, 122, 83, 117,
        105, 111, 125, 121, 126, 137, 150, 168, 176, 175,
      ]
    case ._64GiB:
      return [
        234, 211, 172, 157, 181, 144, 115, 121, 113, 120,
        127, 120, 154, 179, 131, 201, 116, 164, 141, 199,
        108, 124, 130, 189, 105, 95, 98, 149, 108, 152,
        133, 124, 138, 153, 154, 146, 154, 209, 216, 221,
      ]
    case ._72GiB:
      return [
        384, 384, 384, 384, 384, 142, 113, 120, 113, 120,
        125, 119, 151, 176, 129, 195, 114, 160, 138, 197,
        108, 122, 127, 185, 102, 94, 97, 146, 105, 148,
        130, 122, 136, 149, 151, 145, 153, 204, 211, 215,
      ]
    case .disabled:
      return Array(repeating: 384, count: 40)
    }
  }

  // Treat this tier as a ceiling: pick the largest tier at or below it whose resident weights
  // fit in 72% of available memory, falling back to the smallest tier when none fits.
  func residentTierForDeepSeek4_1(availableMemory: UInt64) -> Self {
    let budget = availableMemory / 25 * 18
    // allCases ascends by resident size, ending with .disabled, which maps the whole checkpoint.
    let ceiling = Self.allCases.firstIndex(of: self)!
    return Self.allCases[...ceiling].last { tier in
      // The 8 GiB tier shares the 16 GiB allocation.
      let size =
        tier == .disabled
        ? 172_970_156_032  // deepseek_4.1_flash_1017_i2x.ckpt, about 161.09 GiB.
        : UInt64(max(16, tier.rawValue)) * 1_024 * 1_024 * 1_024
      return size <= budget
    } ?? ._8GiB
  }

  // An explicit .disabled always loads every weight. Otherwise the requested tier, or the automatic
  // one when nil, is a ceiling for what fits in the memory available now.
  static func residentTierForDeepSeek4_1(requested: Self?) -> Self {
    guard requested != .disabled else { return .disabled }
    return (requested ?? DeviceCapability.weightsStreaming).residentTierForDeepSeek4_1(
      availableMemory: DeviceCapability.availableMemory)
  }
}

/// Loaded model storage is shared by copies. KV and Engram state belong to the
/// caller's session; use the same graph and generator while continuing a session.
public struct DeepSeek4_1TextGenerator: DeepSeekTextGenerator {
  public static let version: LLMVersion = .deepseek_4_1_flash

  public static let estimatedKVCacheSize: UInt64 = 4 * 1_024 * 1_024 * 1_024

  public struct KVCache: DeepSeekKVCache {
    struct Layer {
      var rawKeyValue: DynamicGraph.Tensor<Float16>
      var rawTokenLength = 0
      var compressedKeyValue: DynamicGraph.Tensor<Float16>?
      var compressorInputCache: DynamicGraph.Tensor<Float16>?
      var indexerKeyValue: DynamicGraph.Tensor<Float16>?
    }

    public internal(set) var tokenLength = 0
    var layers = [Layer]()
    var history = [Int32]()
    // Do not persist padded KV under the original images' identities.
    var hasPaddedImages = false
    // Layer-major: six column shards for layer 1, then six for layer 14.
    fileprivate var rowCaches = [DeepSeek4_1EngramCache]()

    public var capacity: Int {
      DeepSeek4_1TextGenerator.cacheCapacity(self, configuration: .deepSeekV4_1Flash)
    }

    public var rawCacheCapacity: Int { layers.first?.rawKeyValue.shape[0] ?? 0 }

    public init() {}

    // Raw windows and compressor inputs are overwritten; global KV only appends rows.
    public func snapshot() -> KVCache {
      var snapshot = self
      for index in layers.indices {
        snapshot.layers[index].rawKeyValue = layers[index].rawKeyValue.copied()
        snapshot.layers[index].compressorInputCache = layers[index].compressorInputCache?.copied()
      }
      return snapshot
    }
  }

  private static let maximumContextLength = 1_024 * 1_024
  private static let cachePageSize = 512
  private static let recentStatisticsLimit = 3

  public static let unsafeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_deepseek4_json,
    merges: BinaryResources.merges_deepseek4_txt,
    specialTokens: DeepSeek4_1ModelConfiguration.specialTokens,
    unknownToken: "<｜▁pad▁｜>", startToken: "<｜begin▁of▁sentence｜>",
    endToken: "<｜end▁of▁sentence｜>", pretokenizer: .joyAI)
  public static let safeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_deepseek4_json,
    merges: BinaryResources.merges_deepseek4_txt,
    specialTokens: ["<｜begin▁of▁sentence｜>": 0, "<｜end▁of▁sentence｜>": 1, "<｜▁pad▁｜>": 2],
    unknownToken: "<｜▁pad▁｜>", startToken: "<｜begin▁of▁sentence｜>",
    endToken: "<｜end▁of▁sentence｜>", pretokenizer: .joyAI)

  private static let tokenMap: [Int32] = {
    let vocabularyMap = try! JSONDecoder().decode(
      [String: Int32].self, from: BinaryResources.vocab_deepseek4_json)
    let map = DeepSeek4_1EngramTokenMap(
      vocabularyMap: vocabularyMap,
      specialTokens: DeepSeek4_1ModelConfiguration.specialTokens)
    precondition(
      Set(map).count
        == DeepSeek4_1EngramConfiguration.deepSeekV4_1Flash.compressedVocabularySize)
    return map
  }()
  private var residentMappingSize: Int {
    switch storage.weightsStreaming {
    case ._8GiB, ._16GiB, ._24GiB, ._32GiB, ._40GiB, ._48GiB, ._56GiB, ._64GiB:
      return 9_813_229_568  // Fixed weights only.
    case ._72GiB:
      return 28_644_343_808  // Fixed weights and expert banks for layers 0–4.
    case .disabled:
      return 0  // Map the whole checkpoint.
    }
  }
  // A shard owns four disjoint hash columns and 2,730 decoded rows. Keep the
  // aggregate budget near 8 MiB of FP16 row data per table, independent of sharding.
  public static let engramReadersPerTable = 6
  public static let engramCacheRowsPerTable = 16_384 / engramReadersPerTable * engramReadersPerTable

  private final class Storage {
    var lock = os_unfair_lock()
    let requestedWeightsStreaming: DeviceCapability.WeightsStreaming?
    // Expert residency is resolved whenever the decoder is built, so each weights load sees
    // the memory available at that moment.
    private(set) var configuration: DeepSeek4_1ModelConfiguration
    private(set) var weightsStreaming: DeviceCapability.WeightsStreaming
    var decoderIsLoaded = false
    var engramReader: DeepSeek4_1EngramReader<Float16>?
    var vitIsLoaded = false
    var imageMarkers = [DynamicGraph.Tensor<Float16>]()
    var routingBiases = [(key: String, bias: Model.Parameters)]()
    var textRoutingBiases = [Tensor<Float>]()
    var visualRoutingBiases = [Tensor<Float>]()
    var usesVisualRouting = false
    private var cachedVit: ModelBuilder<(height: Int, width: Int)>?
    private var cachedDecoder:
      ModelBuilder<
        (
          cachedTokenLength: Int, cachedRawTokenLengths: [Int], tokenLength: Int,
          boundedReplayTokens: Int?
        )
      >?

    var decoder:
      ModelBuilder<
        (
          cachedTokenLength: Int, cachedRawTokenLengths: [Int], tokenLength: Int,
          boundedReplayTokens: Int?
        )
      >
    {
      if let cachedDecoder { return cachedDecoder }
      weightsStreaming = DeviceCapability.WeightsStreaming.residentTierForDeepSeek4_1(
        requested: requestedWeightsStreaming)
      configuration.expertResidentSlots = weightsStreaming.expertResidentSlotsForDeepSeek4_1
      let config = configuration
      let decoder = ModelBuilder<
        (
          cachedTokenLength: Int, cachedRawTokenLengths: [Int], tokenLength: Int,
          boundedReplayTokens: Int?
        )
      > { [unowned self] lengths, _ in
        let (model, biases) = DeepSeek4_1CausalLM(
          Float16.self, tokenLength: lengths.tokenLength,
          cachedTokenLength: lengths.cachedTokenLength,
          cachedRawTokenLengths: lengths.cachedRawTokenLengths,
          boundedReplayTokens: lengths.boundedReplayTokens,
          configuration: config)
        // Absorption preserves the original parameters and frees later model constructions.
        if self.routingBiases.isEmpty { self.routingBiases = biases }
        return model
      }
      decoder.maxConcurrency = .limit(4)
      cachedDecoder = decoder
      return decoder
    }

    var vit: ModelBuilder<(height: Int, width: Int)> {
      if let cachedVit { return cachedVit }
      let vit = ModelBuilder<(height: Int, width: Int)> { grid, _ in
        DeepSeek4_1VisionTransformer(grid: grid)
      }
      vit.maxConcurrency = .limit(4)
      cachedVit = vit
      return vit
    }

    init(
      configuration: DeepSeek4_1ModelConfiguration,
      weightsStreaming: DeviceCapability.WeightsStreaming?
    ) {
      self.configuration = configuration
      requestedWeightsStreaming = weightsStreaming
      self.weightsStreaming = weightsStreaming ?? DeviceCapability.weightsStreaming
    }

    func reset() {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      cachedDecoder = nil
      decoderIsLoaded = false
      engramReader = nil
      cachedVit = nil
      vitIsLoaded = false
      imageMarkers.removeAll()
      routingBiases.removeAll()
      textRoutingBiases.removeAll()
      visualRoutingBiases.removeAll()
      usesVisualRouting = false
    }
  }

  public let filePath: String
  public let engramFilePath: String
  public let chunkedPrefillMaxLength: Int
  public let compilePrefillHeadroom: Int
  /// The requested tier, or nil for automatic. An explicit `.disabled` disables streaming; otherwise
  /// each weights load resolves the tier it uses from this ceiling and available memory.
  public let weightsStreaming: DeviceCapability.WeightsStreaming?
  // "SWA Bounded Replay" in the paper. The final 128 positions may cross modality boundaries.
  public let boundedReplay: Bool
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
  private let configuration: DeepSeek4_1ModelConfiguration
  private let storage: Storage

  public init(
    filePath: String, engramFilePath: String, chunkedPrefillMaxLength: Int = 4096,
    compilePrefillHeadroom: Int = 64 * 1_024,
    weightsStreaming: DeviceCapability.WeightsStreaming? = nil,
    boundedReplay: Bool = true
  ) {
    precondition(chunkedPrefillMaxLength >= 2)
    precondition(compilePrefillHeadroom >= Self.cachePageSize)
    precondition(compilePrefillHeadroom.isMultiple(of: Self.cachePageSize))
    precondition(compilePrefillHeadroom <= Self.maximumContextLength)
    let configuration = DeepSeek4_1ModelConfiguration.deepSeekV4_1Flash
    precondition(
      configuration.layers
        == DeviceCapability.weightsStreaming.expertResidentSlotsForDeepSeek4_1.count)
    precondition(configuration.expertCount == 384)
    self.configuration = configuration
    self.filePath = filePath
    self.engramFilePath = engramFilePath
    self.chunkedPrefillMaxLength = chunkedPrefillMaxLength
    self.compilePrefillHeadroom = compilePrefillHeadroom
    self.weightsStreaming = weightsStreaming
    self.boundedReplay = boundedReplay
    self.storage = Storage(configuration: configuration, weightsStreaming: weightsStreaming)
  }
}

extension DeepSeek4_1TextGenerator {
  public func unload() { storage.reset() }

  /// The tier the loaded weights use, or nil before they load.
  public var residentWeightsStreaming: DeviceCapability.WeightsStreaming? {
    os_unfair_lock_lock(&storage.lock)
    defer { os_unfair_lock_unlock(&storage.lock) }
    return storage.decoderIsLoaded ? storage.weightsStreaming : nil
  }

  public static var isImageSupported: Bool { true }

  public static func imageTokenCount(filePath: String) -> Int? {
    DeepSeek4_1Image(filePath: filePath)?.tokenCount
  }

  @discardableResult
  private func switchRoutingBiases(graph: DynamicGraph, visual: Bool) -> Bool {
    guard storage.usesVisualRouting != visual else { return true }
    graph.joined()
    if visual && storage.visualRoutingBiases.isEmpty {
      let result = graph.openStore(filePath, flags: .readOnly) {
        store
          -> [Tensor<Float>]? in
        var biases = [Tensor<Float>]()
        for (key, _) in storage.routingBiases {
          guard let bias = store.read(key, kind: .CPU, codec: .externalData) else { return nil }
          biases.append(Tensor<Float>(bias).toGPU(0))
        }
        return biases
      }
      guard let biases = try? result.get() else { return false }
      storage.textRoutingBiases = storage.routingBiases.map { $0.bias.copied(Float.self) }
      storage.visualRoutingBiases = biases
    }
    let bank = visual ? storage.visualRoutingBiases : storage.textRoutingBiases
    for (routing, bias) in zip(storage.routingBiases, bank) { routing.bias.copy(from: bias) }
    graph.joined()
    storage.usesVisualRouting = visual
    return true
  }

  private func encodeImage(graph: DynamicGraph, image: DeepSeek4_1Image)
    -> DynamicGraph.Tensor<Float16>?
  {
    let patches = image.patches()
    let inputs: [DynamicGraph.AnyTensor] = [
      graph.variable(patches.tensor.toGPU(0)),
      graph.variable(
        DeepSeek4_1VisionRotaryEmbedding(grid: patches.grid, of: Float16.self).toGPU(0)),
    ]
    let vit = storage.vit
    if !storage.vitIsLoaded {
      vit.compile(patches.grid, inputs: inputs)
      if storage.imageMarkers.isEmpty {
        storage.imageMarkers = [
          graph.variable(.CPU, .WC(1, configuration.hiddenSize), of: Float16.self),
          graph.variable(.CPU, .WC(1, configuration.hiddenSize), of: Float16.self),
          graph.variable(.CPU, .WC(1, configuration.hiddenSize), of: Float16.self),
        ]
      }
      let markers = storage.imageMarkers
      do {
        let result = try graph.openStore(filePath, flags: .readOnly) { store in
          guard store.read("image_start", variable: markers[0], codec: .externalData),
            store.read("image_newline", variable: markers[1], codec: .externalData),
            store.read("image_end", variable: markers[2], codec: .externalData)
          else { return false }
          try store.read("vision_model", model: vit, strict: true, codec: .externalData)
          return true
        }
        guard try result.get() else { return nil }
      } catch { return nil }
      storage.vitIsLoaded = true
    }
    let features = vit(patches.grid, inputs: inputs[0], Array(inputs.dropFirst()))[0].as(
      of: Float16.self
    ).toCPU()
    graph.joined()
    let merge = DeepSeek4_1VisionConfiguration.deepSeekV4_1Flash.spatialMergeSize
    let height = (patches.grid.height + merge - 1) / merge
    let width = (patches.grid.width + merge - 1) / merge
    let hidden = configuration.hiddenSize
    // Tensor range copies only assert their bounds, so release builds would read past features.
    guard features.shape == [height * width, hidden],
      image.tokenCount == DeepSeek4_1VisionTokenCount(grid: patches.grid)
    else {
      print(
        "Warning: DeepSeek 4.1 vision features \(features.shape) do not match grid \(patches.grid)."
      )
      return nil
    }
    var embeddings = Tensor<Float16>(.CPU, .WC(image.tokenCount, hidden))
    embeddings[0..<1, 0..<hidden] = storage.imageMarkers[0].rawValue
    for row in 0..<height {
      let offset = 1 + row * (width + 1)
      embeddings[offset..<(offset + width), 0..<hidden] =
        features.rawValue[(row * width)..<((row + 1) * width), 0..<hidden]
      embeddings[(offset + width)..<(offset + width + 1), 0..<hidden] =
        storage.imageMarkers[1].rawValue
    }
    embeddings[(image.tokenCount - 1)..<image.tokenCount, 0..<hidden] =
      storage.imageMarkers[2].rawValue
    return graph.variable(embeddings.toGPU(0))
  }

  /// Decode with the same sampling and pause/abort contract as DeepSeek4TextGenerator.
  /// A pause retains the next prediction; abort retains only evaluated tokens.
  public mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool = true, kvCache: inout KVCache,
    contextTokens: [Int32], contextCache: DeepSeek4_1ContextCache,
    embedSpans: [EmbedSpan] = [], projectPath: String? = nil,
    continuationHandler: (Int, Int, [Int32], DeepSeekGenerationStatistics) ->
      DeepSeekGenerationContinuationState
  ) -> [Int32] {
    os_unfair_lock_lock(&storage.lock)
    defer { os_unfair_lock_unlock(&storage.lock) }
    let tokenLength = tokens.shape[0]
    recentInteractionStatistics.append(DeepSeekGenerationStatistics())
    if recentInteractionStatistics.count > Self.recentStatisticsLimit {
      recentInteractionStatistics.removeFirst()
    }
    let interactionStatisticsIndex = recentInteractionStatistics.count - 1
    guard continuationHandler(0, tokenLength, [], statistics) == .continue else { return [] }
    guard tokenLength > 0, tokenOffset >= 0, tokenOffset == kvCache.tokenLength,
      tokenLength <= Self.maximumContextLength - tokenOffset,
      contextTokens.count == tokenOffset + tokenLength
    else { return [] }
    precondition(contextTokens.allSatisfy { $0 >= 0 && $0 < configuration.vocabularySize })
    defer { graph.joined() }
    let config = configuration
    // Resolve the companion lazily so models can be selected before their downloads finish.
    let engramReader =
      storage.engramReader
      ?? DeepSeek4_1EngramReader<Float16>(filePath: engramFilePath)
    storage.engramReader = engramReader
    let prefillChunk = chunkedPrefillMaxLength
    let boundedReplay = self.boundedReplay
    let cacheWasEmpty = kvCache.layers.isEmpty
    let promptEnd = tokenOffset + tokenLength
    let initialCacheTokenLength = min(promptEnd + 1, Self.maximumContextLength)
    var capacity = max(
      Self.cacheCapacity(kvCache, configuration: config),
      min(
        Self.maximumContextLength,
        ((initialCacheTokenLength + self.compilePrefillHeadroom - 1)
          / self.compilePrefillHeadroom) * self.compilePrefillHeadroom))
    let maximumPrefillLength = prefillChunk + (boundedReplay ? config.rawWindow : 1)
    let workingCacheCapacity = max(
      Self.cachePageSize + config.rawWindow, maximumPrefillLength + config.rawWindow)
    Self.resizeCaches(
      graph: graph, kvCache: &kvCache, cacheCapacity: capacity,
      workingCacheCapacity: workingCacheCapacity, configuration: config)
    var contextCacheHasher = ContextCachePrefixHasher(modelFilePath: filePath)
    let prefillStart =
      cacheWasEmpty && tokenOffset == 0
      ? contextCache.restore(
        graph: graph, tokens: contextTokens, configuration: config,
        boundedReplay: boundedReplay, kvCache: &kvCache, hasher: &contextCacheHasher,
        embeddingSpans: embedSpans)
      : 0
    let startPosition = kvCache.tokenLength
    let oldFlags = DynamicGraph.flags
    DynamicGraph.flags.insert(.disableMFAAttentionSpecializingC)
    defer { DynamicGraph.flags = oldFlags }
    let decoder = storage.decoder
    let emptyTokens = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Int32.self)
    let emptyEmbeddings = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Float16.self)
    var encodedImages = [[UInt8]: DynamicGraph.Tensor<Float16>]()
    let ratios = config.compressionRatios.prefix(config.layers)
    let compressorRatios = Set(ratios.filter { $0 > 0 }).sorted()
    let rotaryAlignment = compressorRatios.max() ?? 1
    func rotaryEmbeddings(cachedTokenLength: Int, tokenLength: Int) -> [DynamicGraph.Tensor<
      Float16
    >] {
      [
        (config.attentionHeadDim, false), (config.attentionHeadDim, true),
        (config.indexerHeadDim, true),
      ]
      .map { headDim, compressed in
        graph.variable(
          DeepSeek4_1RotaryEmbedding(
            sequenceLength: tokenLength, cachedTokenLength: cachedTokenLength,
            compressed: compressed, headDim: headDim, configuration: config, of: Float16.self
          ).toGPU(0)
        ).reshaped(.WC(tokenLength, headDim))
      }
    }
    let prefillRotaryStart = startPosition / rotaryAlignment * rotaryAlignment
    let prefillRotary = rotaryEmbeddings(
      cachedTokenLength: prefillRotaryStart, tokenLength: promptEnd - prefillRotaryStart)
    var initialPre = [Float](repeating: 0, count: maximumPrefillLength * config.hcCount)
    for row in 0..<maximumPrefillLength { initialPre[row * config.hcCount] = 1 }
    let pre = graph.variable(
      Tensor(initialPre, .CPU, .WC(maximumPrefillLength, config.hcCount)).toGPU(0))
    func modelInputs(
      tokenLength count: Int, cachedTokenLength: Int,
      cachedRawTokenLengths: [Int], boundedReplayTokens: Int?,
      engram: [DynamicGraph.Tensor<Float16>], rotary: [DynamicGraph.Tensor<Float16>],
      rotaryStart: Int
    ) -> [DynamicGraph.AnyTensor] {
      let position = cachedTokenLength
      let layerLengths = DeepSeek4_1CausalLMTokenLengths(
        tokenLength: count, boundedReplayTokens: boundedReplayTokens, configuration: config)
      // Append inputs in the same order as DeepSeek4_1Prefix.
      var args: [DynamicGraph.AnyTensor] = [pre.reshaped(.WC(count, config.hcCount)).copied()]
      if ratios.contains(0) {
        args.append(
          rotary[0][
            (position - rotaryStart)..<(position - rotaryStart + count), 0..<config.attentionHeadDim
          ]
          .reshaped(.NHWC(1, count, 1, config.attentionHeadDim)).copied())
      }
      if !compressorRatios.isEmpty {
        for rotary in rotary.dropFirst() {
          let headDim = rotary.shape[1]
          args.append(
            rotary[(position - rotaryStart)..<(position - rotaryStart + count), 0..<headDim]
              .reshaped(.NHWC(1, count, 1, headDim)).copied())
        }
      }
      for ratio in compressorRatios {
        let previousRows = position / ratio
        let emittedRows = (position + count) / ratio - previousRows
        for rotary in rotary.dropFirst() {
          let headDim = rotary.shape[1]
          // As in V4, a chunk that emits no rows gets a zero-sized tensor; a strided slice would
          // run past a table that only covers this chunk.
          args.append(
            emittedRows > 0
              ? rotary.reshaped(
                .WC(emittedRows, headDim), offset: [previousRows - rotaryStart / ratio, 0],
                strides: [ratio * headDim, 1]
              ).copied().reshaped(.NHWC(1, emittedRows, 1, headDim))
              : rotary.reshaped(format: .NHWC, shape: [0]))
        }
      }
      for layer in 0..<config.layers {
        if let index = config.engram.layers.firstIndex(of: layer) {
          args.append(engram[index])
        }
        let rawRows = max(1, cachedRawTokenLengths[layer] + layerLengths[layer])
        // Bind from the backing buffer's base. Sliding-window attention masks
        // older rows while writes append after this layer's cached prefix.
        let cache = kvCache.layers[layer]
        args.append(cache.rawKeyValue.reshaped(.NHWC(1, rawRows, 1, config.attentionHeadDim)))
        if config.kvSourceLayers.contains(layer) {
          let ratio = config.compressionRatios[layer]
          // Keep a valid backing view when no compressed rows are visible yet.
          // The model derives the logical row count from position and count.
          let rows = max(1, (position + count) / ratio)
          args.append(cache.compressedKeyValue![0..<rows, 0..<config.attentionHeadDim])
          args.append(cache.indexerKeyValue![0..<rows, 0..<config.indexerHeadDim])
          let remainder = position % ratio
          args.append(
            cache.compressorInputCache!.reshaped(.WC(remainder + count, config.hiddenSize)))
        }
      }
      return args
    }

    // Compile maximum query/workspace and full cache visibility together. The
    // largest executed chunk is one row smaller, reserving space for a pending
    // compressor group. For 4096-token chunks, bounded replay compiles 4224 rows.
    func compilePrefillHeadroom(cacheCapacity: Int, isEager: Bool = true) {
      let maximumCompressorStateLength = (compressorRatios.max() ?? 1) - 1
      let compileTokenLength = min(
        maximumPrefillLength, cacheCapacity - maximumCompressorStateLength)
      let compileCachedTokenLength = cacheCapacity - compileTokenLength
      let compileReplayTokens = boundedReplay ? min(config.rawWindow, compileTokenLength) : nil
      let compileRawTokenLengths = DeepSeek4_1CausalLMTokenLengths(
        tokenLength: compileTokenLength, boundedReplayTokens: compileReplayTokens,
        configuration: config
      ).prefix(config.layers).map { workingCacheCapacity - $0 }
      precondition(compileTokenLength > 0)
      let compileTokens = graph.variable(
        Tensor<Int32>(
          Array(repeating: 0, count: compileTokenLength), kind: .CPU, format: .NHWC,
          shape: [compileTokenLength]
        ).toGPU(0))
      let compileRotaryStart = compileCachedTokenLength / rotaryAlignment * rotaryAlignment
      let compileRotary = rotaryEmbeddings(
        cachedTokenLength: compileRotaryStart, tokenLength: cacheCapacity - compileRotaryStart)
      let inputs = modelInputs(
        tokenLength: compileTokenLength, cachedTokenLength: compileCachedTokenLength,
        cachedRawTokenLengths: compileRawTokenLengths, boundedReplayTokens: compileReplayTokens,
        engram: config.engram.layers.map { _ in
          graph.variable(
            .GPU(0), .WC(compileTokenLength, config.engram.embeddingSize), of: Float16.self)
        }, rotary: compileRotary, rotaryStart: compileRotaryStart)
      decoder.compile(
        (
          cachedTokenLength: compileCachedTokenLength,
          cachedRawTokenLengths: compileRawTokenLengths, tokenLength: compileTokenLength,
          boundedReplayTokens: compileReplayTokens
        ),
        inputs: [compileTokens, emptyEmbeddings] + inputs, isEager: isEager)
    }
    var generated = [Int32]()
    graph.withNoGrad {
      defer { switchRoutingBiases(graph: graph, visual: false) }
      autoreleasepool {
        // Expose every compressor parameter before the first weight read.
        // Execution binds real Engram rows after headroom compilation.
        if !storage.decoderIsLoaded {
          compilePrefillHeadroom(cacheCapacity: capacity, isEager: false)
          // Use V4's shared mapping and pinning, bounded to this checkpoint's resident prefix.
          DynamicGraph.setWholeFileMappingSizeLimit(residentMappingSize)
          defer { DynamicGraph.setWholeFileMappingSizeLimit(0) }
          let expertResidentSlots = storage.configuration.expertResidentSlots
          do {
            try graph.openStore(filePath, flags: .readOnly) { store in
              let ordinary: DynamicGraph.Store.Codec = [.jit, .externalData(.wholeFile), .i8x]
              try store.read("text_model", model: decoder, strict: true, codec: ordinary) {
                name, _, _, shape in
                let name =
                  name
                  .replacingOccurrences(
                    of: ".ffn.experts.streaming_gate-0-0]", with: ".ffn.experts-0-0]"
                  )
                  .replacingOccurrences(
                    of: ".ffn.experts.streaming_up-0-0]", with: ".ffn.experts-0-1]"
                  )
                  // The resident layers fuse the shared expert into the routed SwiGLU.
                  .replacingOccurrences(of: ".ffn.experts-0-2]", with: ".ffn.shared_experts-0-0]")
                  .replacingOccurrences(of: ".ffn.experts-0-3]", with: ".ffn.shared_experts-0-1]")
                if shape.count == 3 && name.contains(".ffn.experts"),
                  let layer = name.components(separatedBy: "layers.").last?
                    .components(separatedBy: ".").first.flatMap(Int.init),
                  expertResidentSlots[layer] < config.expertCount
                {
                  return .continue(name, codec: [.jit, .externalOnDemand, .i8x])
                }
                return .continue(name, codec: ordinary)
              }
            }
          } catch {
            preconditionFailure("Cannot load DeepSeek 4.1 weights: \(error)")
          }
          decoder.pinMemory = true
          graph.joined()
          storage.decoderIsLoaded = true
        }
        compilePrefillHeadroom(cacheCapacity: capacity)
        graph.joined()
      }
      guard continuationHandler(prefillStart, tokenLength, [], statistics) == .continue else {
        return
      }

      var prefillChunkStart = prefillStart
      let prefillStartTime = CACurrentMediaTime()
      while prefillChunkStart < tokenLength {
        let remaining = tokenLength - prefillChunkStart
        // Unaligned starts fill straight to the next checkpoint; compaction makes room on overflow.
        let alignmentLength = min(
          prefillChunk,
          contextCache.checkpointStride - kvCache.tokenLength % contextCache.checkpointStride)
        let position = kvCache.tokenLength
        let imageIndex = embedSpans.firstIndex { $0.start <= position && position < $0.end }
        let count: Int
        if let imageIndex {
          // Images fit within 1024 positions. Cross page/checkpoint boundaries intact.
          count = min(remaining, Int(embedSpans[imageIndex].end) - position)
        } else {
          let nextImage =
            embedSpans.first { $0.start > position }.map { Int($0.start) } ?? promptEnd
          let ordinary: Int
          if boundedReplay && remaining < maximumPrefillLength {
            // Keep checkpoints before the replay window. Absorb the rest of the
            // tail so replay stays together; strict < reserves the compressor-state row.
            let nextCheckpoint =
              (position / contextCache.checkpointStride + 1) * contextCache.checkpointStride
            ordinary =
              promptEnd - nextCheckpoint >= config.rawWindow
              ? min(remaining, nextCheckpoint - position) : remaining
          } else {
            ordinary = min(alignmentLength, remaining)
          }
          count = min(ordinary, nextImage - position)
        }
        let end = prefillChunkStart + count
        let replayTokens =
          boundedReplay
          ? max(0, position + count - max(position, promptEnd - config.rawWindow)) : nil
        let inputTokens: DynamicGraph.Tensor<Int32>
        let injected: DynamicGraph.Tensor<Float16>
        var visual = false
        if let imageIndex {
          let span = embedSpans[imageIndex]
          if encodedImages[span.digest] == nil {
            if span.kind == .image, span.digest.count == 32, let projectPath {
              let path = EmbedsFileStore(projectPath: projectPath).filePath(for: Data(span.digest))
              if let image = DeepSeek4_1Image(filePath: path) {
                if Array(image.digest) != span.digest {
                  print("Warning: DeepSeek 4.1 image digest mismatch at \(path).")
                }
                if image.tokenCount == span.length {
                  encodedImages[span.digest] = encodeImage(graph: graph, image: image)
                } else {
                  print(
                    "Warning: DeepSeek 4.1 image token count changed from \(span.length) to \(image.tokenCount) at \(path)."
                  )
                }
              }
            }
          }
          if let embeddings = encodedImages[span.digest] {
            visual = true
            inputTokens = emptyTokens
            injected = embeddings.reshaped(
              .WC(count, config.hiddenSize),
              offset: [position - Int(span.start), 0], strides: [config.hiddenSize, 1]
            ).copied()
          } else {
            print(
              "Warning: DeepSeek 4.1 image at token \(span.start) is unavailable; using image placeholder tokens."
            )
            inputTokens = tokens.reshaped(
              format: .NHWC, shape: [count], offset: [prefillChunkStart], strides: [1]
            ).copied()
            injected = emptyEmbeddings
            kvCache.hasPaddedImages = true
          }
        } else {
          inputTokens = tokens.reshaped(
            format: .NHWC, shape: [count], offset: [prefillChunkStart], strides: [1]
          ).copied()
          injected = emptyEmbeddings
        }
        guard switchRoutingBiases(graph: graph, visual: visual) else { return }
        autoreleasepool {
          let flags = DynamicGraph.flags
          if count != prefillChunk {
            DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)
          }
          defer { DynamicGraph.flags = flags }
          let position = kvCache.tokenLength
          let engram: (embeddings: [Tensor<Float16>], history: [Int32])
          if visual {
            engram = (
              config.engram.layers.map { _ in
                Tensor<Float16>(
                  Array(repeating: 0, count: count * config.engram.embeddingSize),
                  .CPU, .WC(count, config.engram.embeddingSize))
              }, []
            )
          } else {
            let ids = Array(contextTokens[(tokenOffset + prefillChunkStart)..<(tokenOffset + end)])
            engram = Self.readEngram(
              tokens: ids, history: kvCache.history,
              rowCaches: &kvCache.rowCaches, reader: engramReader, configuration: config.engram)
          }
          let layerLengths = DeepSeek4_1CausalLMTokenLengths(
            tokenLength: count, boundedReplayTokens: replayTokens, configuration: config)
          // Skipped prompt rows break continuity of the decoder's local KV.
          // Start replay with an empty local window while retaining global KV.
          if let replayTokens, count > replayTokens {
            for layer in config.candidateSourceLayer..<config.layers {
              kvCache.layers[layer].rawTokenLength = 0
            }
          }
          Self.compactCachesIfNeeded(
            &kvCache, tokenLength: count, boundedReplayTokens: replayTokens,
            configuration: config)
          let rawCacheLengths = kvCache.layers.map(\.rawTokenLength)
          let lengths = (
            cachedTokenLength: position, cachedRawTokenLengths: rawCacheLengths,
            tokenLength: count, boundedReplayTokens: replayTokens
          )
          let inputs = modelInputs(
            tokenLength: count, cachedTokenLength: position,
            cachedRawTokenLengths: rawCacheLengths, boundedReplayTokens: replayTokens,
            engram: engram.embeddings.map { graph.variable($0.toGPU(0)) },
            rotary: prefillRotary, rotaryStart: prefillRotaryStart)
          let logits = decoder(lengths, inputs: inputTokens, [injected] + inputs)[0]
            .as(of: Float16.self)
          var token: Int32?
          if end == tokenLength {
            let selected: DynamicGraph.Tensor<Int32>
            if deterministic && thinkingBudget == 0 {
              selected = Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
            } else {
              let scale: Float = thinkingBudget > 0 ? 1 : 0.7
              let minPLogitRange: Float = thinkingBudget > 0 ? 4.605_170_2 : 2.097_012_5
              let zmax = logits.reduced(.max, axis: [1])
              logits.fill(-Float.infinity, if: logits < (zmax - minPLogitRange))
              selected = Functional.gumbelArgmax(logits, axis: 1, scale: scale)
                .reshaped(format: .NHWC, shape: [1])
            }
            let cpu = selected.toCPU()
            graph.joined()
            token = cpu.rawValue[0]
          }
          for layer in 0..<config.layers {
            kvCache.layers[layer].rawTokenLength += layerLengths[layer]
          }
          for layer in config.kvSourceLayers {
            let ratio = config.compressionRatios[layer]
            let rows = position % ratio + count
            let remainder = (position + count) % ratio
            if remainder > 0 {
              var compressor = kvCache.layers[layer].compressorInputCache!
              compressor[0..<remainder, 0..<config.hiddenSize] =
                compressor[(rows - remainder)..<rows, 0..<config.hiddenSize].copied()
            }
          }
          graph.joined()
          kvCache.tokenLength = position + count
          kvCache.history = engram.history
          if !kvCache.hasPaddedImages,
            kvCache.tokenLength.isMultiple(of: contextCache.checkpointStride)
          {
            contextCache.save(
              graph: graph, tokens: contextTokens, checkpointLength: kvCache.tokenLength,
              configuration: config, boundedReplay: boundedReplay, kvCache: kvCache,
              hasher: &contextCacheHasher, embeddingSpans: embedSpans)
          }
          recentInteractionStatistics[interactionStatisticsIndex].prefillDurationSoFar =
            Float(CACurrentMediaTime() - prefillStartTime)
          recentInteractionStatistics[interactionStatisticsIndex].prefillTokensSoFar += count
          if end == tokenLength {
            precondition(token! >= 0 && token! < config.vocabularySize)
            generated.append(token!)
          }
        }
        prefillChunkStart = end
        switch continuationHandler(end, tokenLength, [], statistics) {
        case .continue: break
        case .pause: return
        case .abort:
          generated.removeAll()
          return
        }
      }
      guard let firstToken = generated.first, firstToken != 1 else { return }
      recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
      guard kvCache.tokenLength < Self.maximumContextLength else { return }
      let queueWatermark = DynamicGraph.queueWatermark
      DynamicGraph.queueWatermark = queueWatermark * 16
      defer { DynamicGraph.queueWatermark = queueWatermark }
      let decodeEnd = Self.maximumContextLength
      var nextToken = firstToken
      var thisContextTokens = contextTokens
      var thinkingEnded = firstToken == 128_822
      var decodeIndex = 0
      var shouldAppendPendingToken = true
      var shouldStopAfterSampling = false
      switchRoutingBiases(graph: graph, visual: false)
      if !encodedImages.isEmpty {
        // Image injection changes the embedding input shapes and can replace the
        // arena reserved by the initial text headroom compile. Restore that
        // reservation once before decode so growing candidate pools reuse it.
        compilePrefillHeadroom(cacheCapacity: capacity)
        graph.joined()
      }
      var decodeRotaryStart = kvCache.tokenLength / rotaryAlignment * rotaryAlignment
      var decodeRotary = rotaryEmbeddings(
        cachedTokenLength: decodeRotaryStart,
        tokenLength: min(capacity, decodeEnd) - decodeRotaryStart)
      // Inputs the previous step built for this one, with where its Engram rows sit.
      var nextInputs:
        (cachedRawTokenLengths: [Int], engramIndices: [Int], inputs: [DynamicGraph.AnyTensor])? =
          nil
      let tokenGenerationStartTime = CACurrentMediaTime()
      defer {
        recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
          Float(CACurrentMediaTime() - tokenGenerationStartTime)
      }
      while kvCache.tokenLength < decodeEnd {
        if thinkingBudget > 0 && !thinkingEnded && decodeIndex == thinkingBudget {
          nextToken = 128_822
          thinkingEnded = true
        }
        if kvCache.tokenLength + 1 > capacity {
          capacity = min(capacity + self.compilePrefillHeadroom, Self.maximumContextLength)
          Self.resizeCaches(
            graph: graph, kvCache: &kvCache, cacheCapacity: capacity,
            workingCacheCapacity: workingCacheCapacity, configuration: config)
          compilePrefillHeadroom(cacheCapacity: capacity)
          decodeRotaryStart = kvCache.tokenLength / rotaryAlignment * rotaryAlignment
          decodeRotary = rotaryEmbeddings(
            cachedTokenLength: decodeRotaryStart,
            tokenLength: min(capacity, decodeEnd) - decodeRotaryStart)
        }
        autoreleasepool {
          let position = kvCache.tokenLength
          let ids = [nextToken]
          let engram = Self.readEngram(
            tokens: ids, history: kvCache.history,
            rowCaches: &kvCache.rowCaches, reader: engramReader, configuration: config.engram)
          // Copy inside the stream: a standalone toGPU commits pending work and waits for its blit.
          // The CPU sources must outlive the copies, so they stay alive until this step's join.
          let tokenSource = Tensor<Int32>(ids, kind: .CPU, format: .NHWC, shape: [1])
          let inputTokens = graph.variable(tokenSource).toGPU(0)
          let engramInputs = engram.embeddings.map { graph.variable($0).toGPU(0) }
          let replayTokens = boundedReplay ? 1 : nil
          Self.compactCachesIfNeeded(
            &kvCache, tokenLength: 1, boundedReplayTokens: replayTokens, configuration: config)
          let rawCacheLengths = kvCache.layers.map(\.rawTokenLength)
          let lengths = (
            cachedTokenLength: position, cachedRawTokenLengths: rawCacheLengths,
            tokenLength: 1, boundedReplayTokens: replayTokens
          )
          var inputs: [DynamicGraph.AnyTensor]
          if let modelInputs = nextInputs, modelInputs.cachedRawTokenLengths == rawCacheLengths {
            // Prepared during the previous step with its Engram rows; swap in this step's.
            inputs = modelInputs.inputs
            for (index, engram) in zip(modelInputs.engramIndices, engramInputs) {
              inputs[index] = engram
            }
          } else {
            inputs = modelInputs(
              tokenLength: 1, cachedTokenLength: position,
              cachedRawTokenLengths: rawCacheLengths, boundedReplayTokens: replayTokens,
              engram: engramInputs, rotary: decodeRotary, rotaryStart: decodeRotaryStart)
          }
          nextInputs = nil
          let logits = decoder(
            lengths, inputs: inputTokens, [emptyEmbeddings] + inputs)[0].as(
              of: Float16.self)
          // Sample in the same submission as this step, so one join covers both. The fed token
          // decides the sampling mode, as it did when sampling followed the bookkeeping below.
          let samplingThinkingEnded = thinkingEnded || nextToken == 128_822
          let selected: DynamicGraph.Tensor<Int32>
          if deterministic && (thinkingBudget == 0 || samplingThinkingEnded) {
            selected = Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
          } else {
            let thinking = thinkingBudget > 0 && !samplingThinkingEnded
            let scale: Float = thinking ? 1 : 0.7
            let minPLogitRange: Float = thinking ? 4.605_170_2 : 2.097_012_5
            let zmax = logits.reduced(.max, axis: [1])
            logits.fill(-Float.infinity, if: logits < (zmax - minPLogitRange))
            selected = Functional.gumbelArgmax(logits, axis: 1, scale: scale)
              .reshaped(format: .NHWC, shape: [1])
          }
          let cpu = selected.toCPU()
          for layer in 0..<config.layers {
            kvCache.layers[layer].rawTokenLength += 1
          }
          for layer in config.kvSourceLayers {
            let ratio = config.compressionRatios[layer]
            let rows = position % ratio + 1
            let remainder = (position + 1) % ratio
            if remainder > 0 {
              var compressor = kvCache.layers[layer].compressorInputCache!
              compressor[0..<remainder, 0..<config.hiddenSize] =
                compressor[(rows - remainder)..<rows, 0..<config.hiddenSize].copied()
            }
          }
          // Build and compile the next step's inputs while this step runs on the GPU; its command
          // buffers already hold their buffers. Skip when the next step stops at the
          // end-of-sequence token or the context end, or when resizing or compaction would change
          // its shapes.
          if nextToken != 1, position + 2 <= min(capacity, decodeEnd),
            !(position + 1).isMultiple(of: Self.cachePageSize),
            kvCache.layers.allSatisfy({ $0.rawTokenLength + 1 <= $0.rawKeyValue.shape[0] })
          {
            let nextRawLengths = kvCache.layers.map(\.rawTokenLength)
            let preparedInputs = modelInputs(
              tokenLength: 1, cachedTokenLength: position + 1,
              cachedRawTokenLengths: nextRawLengths, boundedReplayTokens: replayTokens,
              engram: engramInputs, rotary: decodeRotary, rotaryStart: decodeRotaryStart)
            decoder.compile(
              (
                cachedTokenLength: position + 1, cachedRawTokenLengths: nextRawLengths,
                tokenLength: 1, boundedReplayTokens: replayTokens
              ),
              inputs: [inputTokens, emptyEmbeddings] + preparedInputs)
            nextInputs = (
              nextRawLengths,
              engramInputs.map { engram in preparedInputs.firstIndex { $0 === engram }! },
              preparedInputs
            )
          }
          // The sampled token's fast fence signals after every op that reads this step's uploads,
          // so waiting on it releases them without waiting for the whole command buffer.
          withExtendedLifetime((tokenSource, engram.embeddings)) {
            cpu.joined()
          }
          kvCache.tokenLength = position + 1
          kvCache.history = engram.history
          thisContextTokens.append(nextToken)
          if !kvCache.hasPaddedImages,
            kvCache.tokenLength.isMultiple(of: contextCache.checkpointStride)
          {
            graph.joined()
            contextCache.save(
              graph: graph, tokens: thisContextTokens, checkpointLength: kvCache.tokenLength,
              configuration: config, boundedReplay: boundedReplay, kvCache: kvCache,
              hasher: &contextCacheHasher, embeddingSpans: embedSpans)
          }
          recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
            Float(CACurrentMediaTime() - tokenGenerationStartTime)
          if decodeIndex > 0 {
            generated.append(nextToken)
            recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
            if nextToken == 128_822 { thinkingEnded = true }
            if nextToken == 1 {
              shouldAppendPendingToken = false
              return
            }
            switch continuationHandler(
              kvCache.tokenLength, kvCache.tokenLength, generated, statistics)
            {
            case .continue: break
            case .pause: shouldStopAfterSampling = true
            case .abort:
              shouldAppendPendingToken = false
              return
            }
          }
          nextToken = cpu.rawValue[0]
          precondition(nextToken >= 0 && nextToken < config.vocabularySize)
        }
        decodeIndex += 1
        if !shouldAppendPendingToken || shouldStopAfterSampling { break }
      }
      if shouldAppendPendingToken {
        generated.append(nextToken)
        recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
      }
    }
    return generated
  }

  private static func readEngram(
    tokens: [Int32], history: [Int32], rowCaches: inout [DeepSeek4_1EngramCache],
    reader: DeepSeek4_1EngramReader<Float16>, configuration: DeepSeek4_1EngramConfiguration
  ) -> (embeddings: [Tensor<Float16>], history: [Int32]) {
    let hashes = DeepSeek4_1EngramHash(
      tokens: tokens, previousTokens: history, tokenMap: tokenMap, configuration: configuration)
    let count = tokens.count
    let columns = (configuration.maxNgramSize - 1) * configuration.heads
    let columnsPerReader = columns / engramReadersPerTable
    let savedCaches = rowCaches
    var results = [(Tensor<Float16>, DeepSeek4_1EngramCache)?](
      repeating: nil, count: savedCaches.count)
    let resultLock = NSLock()
    // Each worker owns four hash columns and a row cache. Positional reads share
    // one file handle; concurrentPerform completes all reads before assembly.
    DispatchQueue.concurrentPerform(iterations: savedCaches.count) { shard in
      let hashLayer = shard / engramReadersPerTable
      let firstColumn = (shard % engramReadersPerTable) * columnsPerReader
      var rows = [Int32]()
      rows.reserveCapacity(count * columnsPerReader)
      for token in 0..<count {
        for column in firstColumn..<(firstColumn + columnsPerReader) {
          rows.append(hashes.hashes[token, hashLayer, column])
        }
      }
      var cache = savedCaches[shard]
      let embeddings = cache.read(
        reader: reader, layerIndex: configuration.layers[hashLayer], rows: rows)
      resultLock.lock()
      results[shard] = (embeddings, cache)
      resultLock.unlock()
    }
    let embeddings = configuration.layers.indices.map { hashLayer in
      var embedding = Tensor<Float16>(.CPU, .WC(count * columns, configuration.headDim))
      embedding.withUnsafeMutableBytes { destination in
        let rowBytes = configuration.headDim * MemoryLayout<Float16>.stride
        for shard in 0..<engramReadersPerTable {
          let index = hashLayer * engramReadersPerTable + shard
          let (chunk, cache) = results[index]!
          rowCaches[index] = cache
          chunk.withUnsafeBytes { source in
            for token in 0..<count {
              destination.baseAddress!.advanced(
                by: (token * columns + shard * columnsPerReader) * rowBytes
              ).copyMemory(
                from: source.baseAddress!.advanced(by: token * columnsPerReader * rowBytes),
                byteCount: columnsPerReader * rowBytes)
            }
          }
        }
      }
      return embedding.reshaped(.WC(count, configuration.embeddingSize))
    }
    return (embeddings, hashes.history)
  }

  private static func makeCaches(
    graph: DynamicGraph, cacheCapacity: Int, workingCacheCapacity: Int,
    configuration: DeepSeek4_1ModelConfiguration
  ) -> [KVCache.Layer] {
    graph.garbageCollect()
    precondition(cacheCapacity > 0 && workingCacheCapacity > 0)
    return (0..<configuration.layers).map { layerIndex in
      // Copies and graph writes fill every visible row before attention.
      let rawKeyValue = graph.variable(
        .GPU(0), .WC(workingCacheCapacity, configuration.attentionHeadDim), of: Float16.self)
      guard configuration.kvSourceLayers.contains(layerIndex) else {
        return KVCache.Layer(rawKeyValue: rawKeyValue)
      }
      let compressedCapacity = max(cacheCapacity / configuration.compressionRatios[layerIndex], 1)
      return KVCache.Layer(
        rawKeyValue: rawKeyValue,
        compressedKeyValue: graph.variable(
          .GPU(0), .WC(compressedCapacity, configuration.attentionHeadDim), of: Float16.self),
        compressorInputCache: graph.variable(
          .GPU(0), .WC(workingCacheCapacity, configuration.hiddenSize), of: Float16.self),
        indexerKeyValue: graph.variable(
          .GPU(0), .WC(compressedCapacity, configuration.indexerHeadDim), of: Float16.self))
    }
  }

  private static func cacheCapacity(
    _ kvCache: KVCache, configuration: DeepSeek4_1ModelConfiguration
  ) -> Int {
    for (index, layer) in kvCache.layers.enumerated() {
      if let compressed = layer.compressedKeyValue {
        return compressed.shape[0] * configuration.compressionRatios[index]
      }
    }
    return 0
  }

  private static func resizeCaches(
    graph: DynamicGraph, kvCache: inout KVCache, cacheCapacity: Int,
    workingCacheCapacity: Int, configuration: DeepSeek4_1ModelConfiguration
  ) {
    if kvCache.layers.isEmpty {
      kvCache.layers = makeCaches(
        graph: graph, cacheCapacity: cacheCapacity, workingCacheCapacity: workingCacheCapacity,
        configuration: configuration)
      kvCache.rowCaches = Array(
        repeating: DeepSeek4_1EngramCache(
          capacity: engramCacheRowsPerTable / engramReadersPerTable),
        count: configuration.engram.layers.count * engramReadersPerTable)
      return
    }
    let existingCacheCapacity = Self.cacheCapacity(kvCache, configuration: configuration)
    guard existingCacheCapacity < cacheCapacity else { return }
    graph.joined()
    for layerIndex in kvCache.layers.indices {
      var layer = kvCache.layers[layerIndex]
      if let oldCompressed = layer.compressedKeyValue {
        let ratio = configuration.compressionRatios[layerIndex]
        let compressedCapacity = max(cacheCapacity / ratio, 1)
        let retained = kvCache.tokenLength / ratio
        var compressedKeyValue = graph.variable(
          .GPU(0), .WC(compressedCapacity, configuration.attentionHeadDim), of: Float16.self)
        var indexerKeyValue = graph.variable(
          .GPU(0), .WC(compressedCapacity, configuration.indexerHeadDim), of: Float16.self)
        if retained > 0 {
          compressedKeyValue[0..<retained, 0..<configuration.attentionHeadDim] =
            oldCompressed[0..<retained, 0..<configuration.attentionHeadDim]
          indexerKeyValue[0..<retained, 0..<configuration.indexerHeadDim] =
            layer.indexerKeyValue![0..<retained, 0..<configuration.indexerHeadDim]
        }
        layer.compressedKeyValue = compressedKeyValue
        layer.indexerKeyValue = indexerKeyValue
      }
      kvCache.layers[layerIndex] = layer
    }
    graph.garbageCollect()
  }

  private static func compactCachesIfNeeded(
    _ kvCache: inout KVCache, tokenLength: Int, boundedReplayTokens: Int?,
    configuration: DeepSeek4_1ModelConfiguration
  ) {
    let layerTokenLengths = DeepSeek4_1CausalLMTokenLengths(
      tokenLength: tokenLength, boundedReplayTokens: boundedReplayTokens,
      configuration: configuration)
    for layerIndex in kvCache.layers.indices {
      let length = kvCache.layers[layerIndex].rawTokenLength
      var rawKeyValue = kvCache.layers[layerIndex].rawKeyValue
      guard length > configuration.rawWindow,
        kvCache.tokenLength.isMultiple(of: Self.cachePageSize)
          || length + layerTokenLengths[layerIndex] > rawKeyValue.shape[0]
      else { continue }
      let retained = min(length, configuration.rawWindow)
      rawKeyValue[0..<retained, 0..<configuration.attentionHeadDim] = rawKeyValue[
        (length - retained)..<length, 0..<configuration.attentionHeadDim
      ].copied()
      kvCache.layers[layerIndex].rawTokenLength = retained
    }
  }
}
