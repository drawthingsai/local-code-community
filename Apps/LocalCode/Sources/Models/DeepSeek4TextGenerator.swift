import BinaryResources
import DataModels
import Diffusion
import Foundation
import LLM
import NNC
import ProjectHistoryManager
import QuartzCore
import Tokenizer
import os.lock

extension DeviceCapability.WeightsStreaming {
  fileprivate var expertResidentSlotsForDeepSeek4: [Int] {
    switch self {
    case ._8GiB:
      return [
        6, 6, 6, 10, 12, 12, 12, 12, 12, 7, 12, 12, 12, 12, 12, 12, 12, 12, 6, 11, 6, 6, 6,
        12, 12, 6, 12, 6, 6, 12, 6, 6, 12, 12, 12, 6, 12, 6, 6, 6, 6, 6, 6,
      ]
    case ._16GiB:
      return [
        12, 12, 12, 27, 33, 37, 35, 38, 42, 28, 39, 39, 40, 40, 37, 44, 40, 42, 41, 39, 44,
        43, 46, 45, 45, 46, 38, 44, 37, 43, 43, 47, 42, 28, 44, 45, 42, 32, 29, 26, 30, 30, 31,
      ]
    case ._24GiB:
      return [
        101, 109, 137, 68, 65, 53, 58, 59, 64, 68, 69, 58, 55, 57, 52, 61, 65, 60, 63, 83,
        70, 61, 63, 62, 56, 49, 54, 56, 53, 54, 56, 67, 53, 54, 61, 76, 50, 54, 49, 65, 47,
        53, 58,
      ]
    case ._32GiB:
      return [
        110, 92, 116, 92, 84, 92, 70, 87, 79, 95, 95, 84, 76, 87, 97, 97, 93, 92, 91, 95,
        102, 99, 91, 97, 93, 108, 90, 100, 97, 89, 101, 99, 94, 93, 94, 94, 88, 82, 67, 88,
        70, 84, 71,
      ]
    case ._40GiB:
      return [
        256, 256, 256, 139, 106, 104, 100, 102, 108, 118, 121, 104, 93, 103, 90, 106, 104, 119,
        98, 137, 116, 121, 116, 101, 89, 101, 87, 111, 111, 99, 94, 123, 106, 107, 97, 136,
        97, 97, 90, 117, 89, 108, 107,
      ]
    case ._48GiB, ._56GiB, ._64GiB:
      return [
        256, 256, 256, 144, 131, 124, 119, 124, 125, 135, 149, 139, 120, 136, 139, 144, 143,
        144, 137, 137, 134, 145, 143, 136, 134, 143, 123, 152, 138, 139, 143, 151, 138, 132,
        140, 150, 132, 129, 132, 151, 116, 128, 128,
      ]
    case ._72GiB, .disabled:
      return Array(repeating: 256, count: 43)
    }
  }

  // Treat this tier as a ceiling: pick the largest tier at or below it whose resident weights
  // fit in 72% of available memory, falling back to the smallest tier when none fits.
  func residentTierForDeepSeek4(availableMemory: UInt64) -> Self {
    let budget = availableMemory / 25 * 18
    // allCases ascends by resident size, ending with .disabled.
    let ceiling = Self.allCases.firstIndex(of: self)!
    return Self.allCases[...ceiling].last { tier in
      let size: UInt64
      switch tier {
      case ._8GiB, ._16GiB, ._24GiB, ._32GiB, ._40GiB, ._48GiB:
        size = UInt64(tier.rawValue) * 1_024 * 1_024 * 1_024
      case ._56GiB, ._64GiB:
        size = 48 * 1_024 * 1_024 * 1_024
      case ._72GiB, .disabled:
        size = 89_414_598_656  // The whole deepseek_4_flash_0731_i2x.ckpt, about 83.27 GiB.
      }
      return size <= budget
    } ?? ._8GiB
  }

  // An explicit .disabled always loads every weight. Otherwise the requested tier, or the automatic
  // one when nil, is a ceiling for what fits in the memory available now.
  static func residentTierForDeepSeek4(requested: Self?) -> Self {
    guard requested != .disabled else { return .disabled }
    return (requested ?? DeviceCapability.weightsStreaming).residentTierForDeepSeek4(
      availableMemory: DeviceCapability.availableMemory)
  }
}

public struct DeepSeek4TextGenerator: DeepSeekTextGenerator {
  public static let version: LLMVersion = .deepseek_4_flash

  public static let estimatedKVCacheSize: UInt64 = 4 * 1_024 * 1_024 * 1_024

  public struct KVCache: DeepSeekKVCache {
    struct Layer {
      var rawKeyValue: DynamicGraph.AnyTensor
      var compressedKeyValue: DynamicGraph.AnyTensor?
      var compressorInputCache: DynamicGraph.AnyTensor?
      var indexerKeyValue: DynamicGraph.AnyTensor?
    }

    var tokenLength = 0
    var rawTokenLength = 0
    var compressorInputLengths = [Int: Int]()
    var layers = [Layer]()

    public init() {}

    // Raw windows and compressor inputs move in place; compressed/indexer KV only append rows.
    public func snapshot() -> KVCache {
      var snapshot = self
      for index in layers.indices {
        snapshot.layers[index].rawKeyValue = layers[index].rawKeyValue.as(of: FloatType.self)
          .copied()
        snapshot.layers[index].compressorInputCache =
          layers[index].compressorInputCache?.as(of: FloatType.self).copied()
      }
      return snapshot
    }
  }

  private static let endThinkToken: Int32 = 128_822
  private static let eosTokenIds = Set<Int32>([1])
  private static let maximumContextLength = 1_024 * 1_024
  private static let cachePageSize = 512
  private static let rawCacheCapacity = cachePageSize + 128
  private static let compressorInputCacheCapacity = rawCacheCapacity
  private static let recentStatisticsLimit = 3
  private static let specialTokens: [String: Int32] = [
    "<｜begin▁of▁sentence｜>": 0,
    "<｜end▁of▁sentence｜>": 1,
    "<｜▁pad▁｜>": 2,
    "<｜fim▁hole｜>": 128_800,
    "<｜fim▁begin｜>": 128_801,
    "<｜fim▁end｜>": 128_802,
    "<｜User｜>": 128_803,
    "<｜Assistant｜>": 128_804,
    "<|EOT|>": 128_805,
    "<｜tool▁calls▁begin｜>": 128_806,
    "<｜tool▁calls▁end｜>": 128_807,
    "<｜tool▁call▁begin｜>": 128_808,
    "<｜tool▁call▁end｜>": 128_809,
    "<｜tool▁outputs▁begin｜>": 128_810,
    "<｜tool▁outputs▁end｜>": 128_811,
    "<｜tool▁output▁begin｜>": 128_812,
    "<｜tool▁output▁end｜>": 128_813,
    "<｜tool▁sep｜>": 128_814,
    "<｜begin▁of▁repo▁name｜>": 128_815,
    "<｜end▁of▁repo▁name｜>": 128_816,
    "<｜begin▁of▁file▁name｜>": 128_817,
    "<｜end▁of▁file▁name｜>": 128_818,
    "<｜begin▁of▁file｜>": 128_819,
    "<｜end▁of▁file｜>": 128_820,
    "<think>": 128_821,
    "</think>": 128_822,
    "<｜place▁holder▁for▁copy｜>": 128_823,
    "<｜place▁holder▁for▁pointer▁replace｜>": 128_824,
    "｜DSML｜": 128_825,
    "<｜begin▁sys｜>": 128_826,
    "<｜end▁sys｜>": 128_827,
    "<｜latest_reminder｜>": 128_828,
    "<｜action｜>": 128_829,
    "<｜query｜>": 128_830,
    "<｜authority｜>": 128_831,
    "<｜domain｜>": 128_832,
    "<｜task｜>": 128_833,
    "<｜political｜>": 128_834,
    "<｜entity｜>": 128_835,
    "<｜title｜>": 128_836,
    "<｜safety｜>": 128_837,
    "<｜answer｜>": 128_838,
    "<｜search｜>": 128_839,
    "<dsml:": 128_840,
    "</dsml:": 128_841,
    "<｜search▁begin｜>": 128_842,
    "<｜search▁end｜>": 128_843,
    "<｜extracted_url｜>": 128_844,
    "<｜read_url｜>": 128_845,
    "<｜end_of_query｜>": 128_846,
    "<｜rl_image_pad｜>": 129_262,
    "<｜rl_image_start｜>": 129_263,
    "<｜image2｜>": 129_264,
    "<｜/table>｜": 129_265,
    "<｜table｜>": 129_266,
    "<｜/td｜>": 129_267,
    "<｜td｜>": 129_268,
    "<｜/tr｜>": 129_269,
    "<｜tr｜>": 129_270,
    "<｜/polygon｜>": 129_271,
    "<｜polygon｜>": 129_272,
    "<｜/point｜>": 129_273,
    "<｜point｜>": 129_274,
    "<｜/box｜>": 129_275,
    "<｜box｜>": 129_276,
    "<｜/ref｜>": 129_277,
    "<｜ref｜>": 129_278,
    "<｜image｜>": 129_279,
  ]

  public static let unsafeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_deepseek4_json,
    merges: BinaryResources.merges_deepseek4_txt,
    specialTokens: specialTokens, unknownToken: "<｜▁pad▁｜>",
    startToken: "<｜begin▁of▁sentence｜>", endToken: "<｜end▁of▁sentence｜>",
    pretokenizer: .joyAI)

  public static let safeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_deepseek4_json,
    merges: BinaryResources.merges_deepseek4_txt,
    specialTokens: [
      "<｜begin▁of▁sentence｜>": 0,
      "<｜end▁of▁sentence｜>": 1,
      "<｜▁pad▁｜>": 2,
    ], unknownToken: "<｜▁pad▁｜>", startToken: "<｜begin▁of▁sentence｜>",
    endToken: "<｜end▁of▁sentence｜>", pretokenizer: .joyAI)

  public let filePath: String
  private let configuration: DeepSeek4ModelConfiguration
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
    private(set) var configuration: DeepSeek4ModelConfiguration
    var decoderIsLoaded = false
    private var cachedDecoder:
      ModelBuilder<
        (
          cachedTokenLength: Int, cachedRawTokenLength: Int,
          cachedCompressorInputLengths: [Int: Int], tokenLength: Int
        )
      >?
    var decoder:
      ModelBuilder<
        (
          cachedTokenLength: Int, cachedRawTokenLength: Int,
          cachedCompressorInputLengths: [Int: Int], tokenLength: Int
        )
      >
    {
      if let cachedDecoder { return cachedDecoder }
      let weightsStreaming = DeviceCapability.WeightsStreaming.residentTierForDeepSeek4(
        requested: requestedWeightsStreaming)
      // Disabled keeps every layer fully resident, including prefill warmup's subset of layers.
      configuration.expertResidentSlots =
        weightsStreaming == .disabled
        ? Array(repeating: configuration.expertCount, count: configuration.layers)
        : weightsStreaming.expertResidentSlotsForDeepSeek4
      let configuration = self.configuration
      let decoder:
        ModelBuilder<
          (
            cachedTokenLength: Int, cachedRawTokenLength: Int,
            cachedCompressorInputLengths: [Int: Int], tokenLength: Int
          )
        > = ModelBuilder { tokenLengths, _ in
          DeepSeek4CausalLM(
            FloatType.self, tokenLength: tokenLengths.tokenLength,
            cachedTokenLength: tokenLengths.cachedTokenLength,
            cachedRawTokenLength: tokenLengths.cachedRawTokenLength,
            cachedCompressorInputLengths: tokenLengths.cachedCompressorInputLengths,
            configuration: configuration)
        }
      decoder.maxConcurrency = .limit(4)
      cachedDecoder = decoder
      return decoder
    }

    func reset() {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      cachedDecoder = nil
      decoderIsLoaded = false
    }

    init(
      configuration: DeepSeek4ModelConfiguration,
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

  // Start with a fresh decoder and statistics. Warmup only runs where the model fits, so it
  // keeps every expert resident.
  private init(prefillWarmup generator: Self, layers: [Int]) {
    var configuration = generator.configuration
    configuration.layers = layers.count
    configuration.layerAttentionKinds = layers.map {
      generator.configuration.layerAttentionKinds[$0]
    }
    configuration.layerRouterKinds = layers.map { generator.configuration.layerRouterKinds[$0] }
    configuration.expertResidentSlots = Array(
      repeating: configuration.expertCount, count: layers.count)
    self.configuration = configuration
    storage = Storage(configuration: configuration, weightsStreaming: .disabled)
    filePath = generator.filePath
    weightsStreaming = .disabled
    chunkedPrefillMaxLength = generator.chunkedPrefillMaxLength
    compilePrefillHeadroom = generator.compilePrefillHeadroom
  }

  public init(
    filePath: String, configuration: DeepSeek4ModelConfiguration = .deepSeekV4Flash,
    chunkedPrefillMaxLength: Int, compilePrefillHeadroom: Int = 64 * 1_024,
    weightsStreaming: DeviceCapability.WeightsStreaming? = nil
  ) {
    precondition(chunkedPrefillMaxLength > (configuration.compressionRatios.max() ?? 1))
    precondition(compilePrefillHeadroom >= Self.cachePageSize)
    precondition(compilePrefillHeadroom.isMultiple(of: Self.cachePageSize))
    precondition(compilePrefillHeadroom <= Self.maximumContextLength)
    precondition(
      configuration.layers
        == DeviceCapability.weightsStreaming.expertResidentSlotsForDeepSeek4.count)
    precondition(configuration.expertCount == 256)
    self.filePath = filePath
    self.configuration = configuration
    storage = Storage(configuration: configuration, weightsStreaming: weightsStreaming)
    self.weightsStreaming = weightsStreaming
    self.chunkedPrefillMaxLength = chunkedPrefillMaxLength
    self.compilePrefillHeadroom = compilePrefillHeadroom
  }
}

extension DeepSeek4TextGenerator {
  /// Drops only shared model weights, waiting for an active decode to return.
  /// Safe from a tool worker; graph-owned conversation caches stay with the agent.
  public func unload() { storage.reset() }

  public mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool = true, kvCache: inout KVCache,
    contextTokens: [Int32], contextCache: DeepSeek4ContextCache,
    embedSpans: [EmbedSpan] = [], projectPath: String? = nil,
    continuationHandler: (Int, Int, [Int32], DeepSeekGenerationStatistics) ->
      DeepSeekGenerationContinuationState
  ) -> [Int32] {
    precondition(embedSpans.isEmpty, "DeepSeek 4 does not support image embeddings")
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
    let cacheWasEmpty = kvCache.layers.isEmpty
    if cacheWasEmpty {
      guard tokenOffset == 0 else { return [] }
      let minimumInitialTokenLength = configuration.compressionRatios.min() ?? 1
      guard tokenLength >= minimumInitialTokenLength else { return [] }
    } else if kvCache.tokenLength != tokenOffset {
      return []
    }
    let initialCacheTokenLength = min(totalPrefillLength + 1, Self.maximumContextLength)
    let cacheCapacity = min(
      Self.maximumContextLength,
      ((initialCacheTokenLength + self.compilePrefillHeadroom - 1)
        / self.compilePrefillHeadroom) * self.compilePrefillHeadroom)
    let workingCacheCapacity = max(
      Self.rawCacheCapacity, chunkedPrefillMaxLength + configuration.rawWindow)
    Self.resizeCaches(
      graph: graph, kvCache: &kvCache, cacheCapacity: cacheCapacity,
      workingCacheCapacity: workingCacheCapacity,
      configuration: configuration)
    var contextCacheHasher = ContextCachePrefixHasher(modelFilePath: filePath)
    let shouldRestoreContextCache =
      cacheWasEmpty && tokenOffset == 0 && contextTokens.count == tokenLength
    let restoredTokenLength =
      shouldRestoreContextCache
      ? contextCache.restore(
        graph: graph, tokens: contextTokens, configuration: configuration,
        kvCache: &kvCache, hasher: &contextCacheHasher)
      : 0
    let prefillStart = min(restoredTokenLength, max(0, tokenLength - 1))
    let usesCompressedRotary = configuration.layerAttentionKinds.contains {
      if case .raw = $0 { return false }
      return true
    }
    let usesIndexerRotary = !configuration.indexerCompressionRatios.isEmpty
    let compressedRotaryAlignment = configuration.compressionRatios.max() ?? 1
    precondition(
      configuration.compressionRatios.allSatisfy {
        compressedRotaryAlignment.isMultiple(of: $0)
      })
    func minimumCompressedRotaryStart(cachedTokenLength: Int) -> Int {
      var start = cachedTokenLength
      for compressionRatio in configuration.compressionRatios {
        let plan = DeepSeek4CompressionPlan(
          cachedTokenLength: cachedTokenLength, tokenLength: 1,
          compressionRatio: compressionRatio)
        start = min(start, plan.compressorOutputTokenOffset)
      }
      return start / compressedRotaryAlignment * compressedRotaryAlignment
    }
    let prefillRawRotaryStart = tokenOffset + prefillStart
    let prefillRawRotaryLength = tokenLength - prefillStart
    let prefillRawRotaryEmbedding = graph.variable(
      Tensor<FloatType>(
        from: DeepSeek4RotaryEmbedding(
          sequenceLength: prefillRawRotaryLength,
          cachedTokenLength: prefillRawRotaryStart,
          compressed: false, configuration: configuration, of: Float.self)
      ).toGPU(0))
    let prefillCompressedRotaryStart = minimumCompressedRotaryStart(
      cachedTokenLength: tokenOffset + prefillStart)
    let prefillCompressedRotaryLength =
      totalPrefillLength - prefillCompressedRotaryStart
    let prefillCompressedRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
    if usesCompressedRotary {
      prefillCompressedRotaryEmbedding = graph.variable(
        Tensor<FloatType>(
          from: DeepSeek4RotaryEmbedding(
            sequenceLength: prefillCompressedRotaryLength,
            cachedTokenLength: prefillCompressedRotaryStart, compressed: true,
            configuration: configuration, of: Float.self)
        ).toGPU(0))
    } else {
      prefillCompressedRotaryEmbedding = nil
    }
    let prefillIndexerRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
    if usesIndexerRotary {
      prefillIndexerRotaryEmbedding = graph.variable(
        Tensor<FloatType>(
          from: DeepSeek4RotaryEmbedding(
            sequenceLength: prefillCompressedRotaryLength,
            cachedTokenLength: prefillCompressedRotaryStart, compressed: true,
            headDim: configuration.indexerHeadDim,
            configuration: configuration, of: Float.self)
        ).toGPU(0))
    } else {
      prefillIndexerRotaryEmbedding = nil
    }
    var allocatedCacheCapacity = Self.cacheCapacity(
      kvCache, configuration: configuration)
    let compressorZeroPad = graph.variable(
      Tensor<FloatType>(
        Array(repeating: FloatType.zero, count: configuration.attentionHeadDim * 4),
        .CPU, .HWC(1, configuration.attentionHeadDim, 4)
      ).toGPU(0))
    let compressorNegInfPad = graph.variable(
      Tensor<FloatType>(
        Array(repeating: FloatType(-1.0e4), count: configuration.attentionHeadDim * 4),
        .CPU, .HWC(1, configuration.attentionHeadDim, 4)
      ).toGPU(0))
    let emptyCompressorZeroPad = graph.variable(
      Tensor<FloatType>([], kind: .CPU, format: .NHWC, shape: [0]).toGPU(0))
    let emptyCompressorNegInfPad = graph.variable(
      Tensor<FloatType>([], kind: .CPU, format: .NHWC, shape: [0]).toGPU(0))
    let indexerCompressorZeroPad = graph.variable(
      Tensor<FloatType>(
        Array(repeating: FloatType.zero, count: configuration.indexerHeadDim * 4),
        .CPU, .HWC(1, configuration.indexerHeadDim, 4)
      ).toGPU(0))
    let indexerCompressorNegInfPad = graph.variable(
      Tensor<FloatType>(
        Array(repeating: FloatType(-1.0e4), count: configuration.indexerHeadDim * 4),
        .CPU, .HWC(1, configuration.indexerHeadDim, 4)
      ).toGPU(0))
    let emptyIndexerCompressorZeroPad = graph.variable(
      Tensor<FloatType>([], kind: .CPU, format: .NHWC, shape: [0]).toGPU(0))
    let emptyIndexerCompressorNegInfPad = graph.variable(
      Tensor<FloatType>([], kind: .CPU, format: .NHWC, shape: [0]).toGPU(0))

    var causalCompressionRatios = [Int]()
    for attentionKind in configuration.layerAttentionKinds {
      guard case .compressed(let compressionRatio) = attentionKind,
        !causalCompressionRatios.contains(compressionRatio)
      else { continue }
      causalCompressionRatios.append(compressionRatio)
    }

    func makeMaximumCompressedIndices(
      cacheCapacity: Int
    ) -> [Int: DynamicGraph.Tensor<Int32>] {
      var indices = [Int: DynamicGraph.Tensor<Int32>]()
      for compressionRatio in causalCompressionRatios {
        let maximumCompressedRows = cacheCapacity / compressionRatio
        var values = [Int32](repeating: -1, count: max(maximumCompressedRows, 1))
        for row in 0..<maximumCompressedRows {
          values[row] = Int32(row)
        }
        indices[compressionRatio] = graph.variable(
          Tensor<Int32>(values, .CPU, .WC(1, values.count)).toGPU(0))
      }
      return indices
    }

    func makePrefillCausalCompressedIndices(
      cachedTokenLength: Int, tokenLength: Int
    ) -> [Int: DynamicGraph.Tensor<Int32>] {
      let totalTokenLength = cachedTokenLength + tokenLength
      var indices = [Int: DynamicGraph.Tensor<Int32>]()
      for compressionRatio in causalCompressionRatios {
        let compressedRows = totalTokenLength / compressionRatio
        let selectedRowCount = max(compressedRows, 1)
        var values = [Int32](repeating: -1, count: tokenLength * selectedRowCount)
        for queryIndex in 0..<tokenLength {
          let visibleRows = min(
            compressedRows, (cachedTokenLength + queryIndex + 1) / compressionRatio)
          for row in 0..<visibleRows {
            values[queryIndex * selectedRowCount + row] = Int32(row)
          }
        }
        indices[compressionRatio] = graph.variable(
          Tensor<Int32>(values, .CPU, .WC(tokenLength, selectedRowCount)).toGPU(0))
      }
      return indices
    }

    var maximumCompressedIndices = makeMaximumCompressedIndices(
      cacheCapacity: allocatedCacheCapacity)

    func modelInputs(
      tokens inputTokens: DynamicGraph.Tensor<Int32>, cachedTokenLength: Int,
      cachedRawTokenLength: Int, cachedCompressorInputLengths: [Int: Int],
      causalCompressedIndices: [Int: DynamicGraph.Tensor<Int32>],
      rawRotaryEmbedding: DynamicGraph.Tensor<FloatType>, rawRotaryStart: Int,
      rawRotaryLength: Int,
      compressedRotaryEmbedding: DynamicGraph.Tensor<FloatType>?,
      indexerRotaryEmbedding: DynamicGraph.Tensor<FloatType>?,
      compressedRotaryStart: Int, compressedRotaryLength: Int,
      forceCompressorPadding: Bool = false
    ) -> [DynamicGraph.AnyTensor] {
      let tokenLength = inputTokens.shape[0]
      let totalTokenLength = cachedTokenLength + tokenLength
      let rawRotary = rawRotaryEmbedding.reshaped(
        format: .NHWC,
        shape: [1, tokenLength, 1, configuration.attentionHeadDim],
        offset: [0, cachedTokenLength - rawRotaryStart, 0, 0],
        strides: [
          rawRotaryLength * configuration.attentionHeadDim,
          configuration.attentionHeadDim, configuration.attentionHeadDim, 1,
        ]
      ).copied()
      var inputs: [DynamicGraph.AnyTensor] = [rawRotary]
      if let compressedRotaryEmbedding {
        let compressedRotary = compressedRotaryEmbedding.reshaped(
          format: .NHWC,
          shape: [1, tokenLength, 1, configuration.attentionHeadDim],
          offset: [0, cachedTokenLength - compressedRotaryStart, 0, 0],
          strides: [
            compressedRotaryLength * configuration.attentionHeadDim,
            configuration.attentionHeadDim, configuration.attentionHeadDim, 1,
          ]
        ).copied()
        inputs.append(compressedRotary)
      }
      if let indexerRotaryEmbedding {
        let indexerRotary = indexerRotaryEmbedding.reshaped(
          format: .NHWC,
          shape: [1, tokenLength, 1, configuration.indexerHeadDim],
          offset: [0, cachedTokenLength - compressedRotaryStart, 0, 0],
          strides: [
            compressedRotaryLength * configuration.indexerHeadDim,
            configuration.indexerHeadDim, configuration.indexerHeadDim, 1,
          ]
        ).copied()
        inputs.append(indexerRotary)
      }
      if configuration.compressionRatios.contains(4) {
        let plan = DeepSeek4CompressionPlan(
          cachedTokenLength: cachedTokenLength, tokenLength: tokenLength,
          compressionRatio: 4)
        let sourceWindowCount = plan.compressorTokenCount / 4
        let paddingWindowCount = plan.emittedRowCount - max(sourceWindowCount - 1, 0)
        precondition(paddingWindowCount == 0 || paddingWindowCount == 1)
        let useCompressorPadding = forceCompressorPadding || paddingWindowCount != 0
        inputs.append(useCompressorPadding ? compressorZeroPad : emptyCompressorZeroPad)
        inputs.append(useCompressorPadding ? compressorNegInfPad : emptyCompressorNegInfPad)
        if configuration.indexerCompressionRatios.contains(4) {
          inputs.append(
            !useCompressorPadding
              ? emptyIndexerCompressorZeroPad : indexerCompressorZeroPad)
          inputs.append(
            !useCompressorPadding
              ? emptyIndexerCompressorNegInfPad : indexerCompressorNegInfPad)
        }
      }
      for compressionRatio in configuration.compressionRatios {
        let plan = DeepSeek4CompressionPlan(
          cachedTokenLength: cachedTokenLength, tokenLength: tokenLength,
          compressionRatio: compressionRatio)
        let compressorRotary =
          plan.emittedRowCount > 0
          ? compressedRotaryEmbedding!
            .reshaped(.WC(compressedRotaryLength, configuration.attentionHeadDim))
            .reshaped(
              .WC(plan.emittedRowCount, configuration.attentionHeadDim),
              offset: [
                (plan.compressorOutputTokenOffset - compressedRotaryStart) / compressionRatio,
                0,
              ],
              strides: [compressionRatio * configuration.attentionHeadDim, 1]
            ).copied()
          : compressedRotaryEmbedding!.reshaped(format: .NHWC, shape: [0])
        inputs.append(compressorRotary)
      }
      for compressionRatio in configuration.indexerCompressionRatios {
        let plan = DeepSeek4CompressionPlan(
          cachedTokenLength: cachedTokenLength, tokenLength: tokenLength,
          compressionRatio: compressionRatio)
        let compressorRotary =
          plan.emittedRowCount > 0
          ? indexerRotaryEmbedding!
            .reshaped(.WC(compressedRotaryLength, configuration.indexerHeadDim))
            .reshaped(
              .WC(plan.emittedRowCount, configuration.indexerHeadDim),
              offset: [
                (plan.compressorOutputTokenOffset - compressedRotaryStart) / compressionRatio,
                0,
              ],
              strides: [compressionRatio * configuration.indexerHeadDim, 1]
            ).copied()
          : indexerRotaryEmbedding!.reshaped(format: .NHWC, shape: [0])
        inputs.append(compressorRotary)
      }
      var appendedCausalCompressionRatios = Set<Int>()
      for (layerIndex, attentionKind) in configuration.layerAttentionKinds.enumerated() {
        if case .compressed(let compressionRatio) = attentionKind,
          appendedCausalCompressionRatios.insert(compressionRatio).inserted
        {
          inputs.append(causalCompressedIndices[compressionRatio]!)
        }

        let layer = kvCache.layers[layerIndex]
        switch attentionKind {
        case .raw:
          inputs.append(
            layer.rawKeyValue.as(of: FloatType.self).reshaped(
              .NHWC(
                1, cachedRawTokenLength + tokenLength, 1,
                configuration.attentionHeadDim)))
        case .compressed(let compressionRatio):
          inputs.append(
            layer.rawKeyValue.as(of: FloatType.self).reshaped(
              .NHWC(
                1, cachedRawTokenLength + tokenLength, 1,
                configuration.attentionHeadDim)))
          let compressedRowCount = totalTokenLength / compressionRatio
          inputs.append(
            compressedRowCount > 0
              ? layer.compressedKeyValue!.as(of: FloatType.self).reshaped(
                .WC(compressedRowCount, configuration.attentionHeadDim))
              : layer.compressedKeyValue!.as(of: FloatType.self).reshaped(
                format: .NHWC, shape: [0]))
          inputs.append(
            layer.compressorInputCache!.as(of: FloatType.self).reshaped(
              .WC(
                cachedCompressorInputLengths[compressionRatio]! + tokenLength,
                configuration.hiddenSize)))
        case .indexed(let compressionRatio):
          inputs.append(
            layer.rawKeyValue.as(of: FloatType.self).reshaped(
              .NHWC(
                1, cachedRawTokenLength + tokenLength, 1,
                configuration.attentionHeadDim)))
          let compressedRowCount = totalTokenLength / compressionRatio
          inputs.append(
            compressedRowCount > 0
              ? layer.compressedKeyValue!.as(of: FloatType.self).reshaped(
                .WC(compressedRowCount, configuration.attentionHeadDim))
              : layer.compressedKeyValue!.as(of: FloatType.self).reshaped(
                format: .NHWC, shape: [0]))
          inputs.append(
            layer.compressorInputCache!.as(of: FloatType.self).reshaped(
              .WC(
                cachedCompressorInputLengths[compressionRatio]! + tokenLength,
                configuration.hiddenSize)))
          inputs.append(
            compressedRowCount > 0
              ? layer.indexerKeyValue!.as(of: Float16.self).reshaped(
                .WC(compressedRowCount, configuration.indexerHeadDim))
              : layer.indexerKeyValue!.as(of: Float16.self).reshaped(
                format: .NHWC, shape: [0]))
        }
      }
      return inputs
    }

    func prefillChunkLength(remainingTokenLength: Int) -> Int {
      let alignmentLength =
        kvCache.tokenLength.isMultiple(of: Self.cachePageSize)
        ? chunkedPrefillMaxLength
        : Self.cachePageSize - kvCache.tokenLength % Self.cachePageSize
      var cacheRemaining = workingCacheCapacity - kvCache.rawTokenLength
      for compressorInputLength in kvCache.compressorInputLengths.values {
        cacheRemaining = min(
          cacheRemaining, workingCacheCapacity - compressorInputLength)
      }
      let nextCheckpointLength =
        ((kvCache.tokenLength / contextCache.checkpointStride) + 1)
        * contextCache.checkpointStride
      let checkpointRemaining = nextCheckpointLength - kvCache.tokenLength
      return min(
        remainingTokenLength,
        min(alignmentLength, min(cacheRemaining, checkpointRemaining)))
    }

    // Compile the maximum prefill shape for the current headroom before generation.
    func compilePrefillHeadroom(cacheCapacity: Int, isEager: Bool = true) {
      let maximumCompressorStateLength = (configuration.compressionRatios.max() ?? 1) - 1
      let compileTokenLength = min(
        chunkedPrefillMaxLength + 1, cacheCapacity - maximumCompressorStateLength)
      precondition(compileTokenLength > 0)
      let compileCachedTokenLength = cacheCapacity - compileTokenLength
      let compileCachedRawTokenLength = min(
        configuration.rawWindow,
        min(compileCachedTokenLength, workingCacheCapacity - compileTokenLength))
      let compileCachedCompressorInputLengths = Dictionary(
        uniqueKeysWithValues: configuration.compressionRatios.map { compressionRatio in
          let plan = DeepSeek4CompressionPlan(
            cachedTokenLength: compileCachedTokenLength,
            tokenLength: compileTokenLength, compressionRatio: compressionRatio)
          return (compressionRatio, plan.stateCount)
        })
      let compileTokens = graph.variable(
        Tensor<Int32>(
          Array(repeating: 0, count: compileTokenLength), kind: .CPU, format: .NHWC,
          shape: [compileTokenLength]
        ).toGPU(0))
      let compileRawRotaryEmbedding = graph.variable(
        Tensor<FloatType>(
          from: DeepSeek4RotaryEmbedding(
            sequenceLength: compileTokenLength,
            cachedTokenLength: compileCachedTokenLength,
            compressed: false, configuration: configuration, of: Float.self)
        ).toGPU(0))
      let compileCompressedRotaryStart = minimumCompressedRotaryStart(
        cachedTokenLength: compileCachedTokenLength)
      let compileCompressedRotaryLength =
        cacheCapacity - compileCompressedRotaryStart
      let compileCompressedRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
      if usesCompressedRotary {
        compileCompressedRotaryEmbedding = graph.variable(
          Tensor<FloatType>(
            from: DeepSeek4RotaryEmbedding(
              sequenceLength: compileCompressedRotaryLength,
              cachedTokenLength: compileCompressedRotaryStart,
              compressed: true, configuration: configuration, of: Float.self)
          ).toGPU(0))
      } else {
        compileCompressedRotaryEmbedding = nil
      }
      let compileIndexerRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
      if usesIndexerRotary {
        compileIndexerRotaryEmbedding = graph.variable(
          Tensor<FloatType>(
            from: DeepSeek4RotaryEmbedding(
              sequenceLength: compileCompressedRotaryLength,
              cachedTokenLength: compileCompressedRotaryStart,
              compressed: true, headDim: configuration.indexerHeadDim,
              configuration: configuration, of: Float.self)
          ).toGPU(0))
      } else {
        compileIndexerRotaryEmbedding = nil
      }
      let compileCausalCompressedIndices = makePrefillCausalCompressedIndices(
        cachedTokenLength: compileCachedTokenLength,
        tokenLength: compileTokenLength)
      let compileInputs = modelInputs(
        tokens: compileTokens, cachedTokenLength: compileCachedTokenLength,
        cachedRawTokenLength: compileCachedRawTokenLength,
        cachedCompressorInputLengths: compileCachedCompressorInputLengths,
        causalCompressedIndices: compileCausalCompressedIndices,
        rawRotaryEmbedding: compileRawRotaryEmbedding,
        rawRotaryStart: compileCachedTokenLength,
        rawRotaryLength: compileTokenLength,
        compressedRotaryEmbedding: compileCompressedRotaryEmbedding,
        indexerRotaryEmbedding: compileIndexerRotaryEmbedding,
        compressedRotaryStart: compileCompressedRotaryStart,
        compressedRotaryLength: compileCompressedRotaryLength,
        forceCompressorPadding: true)
      storage.decoder.compile(
        (
          cachedTokenLength: compileCachedTokenLength,
          cachedRawTokenLength: compileCachedRawTokenLength,
          cachedCompressorInputLengths: compileCachedCompressorInputLengths,
          tokenLength: compileTokenLength
        ),
        inputs: [compileTokens] + compileInputs, isEager: isEager)
    }

    Self.compactCachesIfNeeded(&kvCache, configuration: configuration)
    let firstCachedRawTokenLength = kvCache.rawTokenLength
    let firstChunkLength = prefillChunkLength(
      remainingTokenLength: tokenLength - prefillStart)
    guard firstChunkLength > 0 else { return [] }
    let flags = DynamicGraph.flags
    if firstChunkLength < chunkedPrefillMaxLength {
      DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)
    }
    let firstTokens = tokens.reshaped(
      format: .NHWC, shape: [firstChunkLength], offset: [prefillStart], strides: [1]
    ).copied()
    let firstCausalCompressedIndices = makePrefillCausalCompressedIndices(
      cachedTokenLength: tokenOffset + prefillStart, tokenLength: firstChunkLength)
    let firstInputs = modelInputs(
      tokens: firstTokens, cachedTokenLength: tokenOffset + prefillStart,
      cachedRawTokenLength: firstCachedRawTokenLength,
      cachedCompressorInputLengths: kvCache.compressorInputLengths,
      causalCompressedIndices: firstCausalCompressedIndices,
      rawRotaryEmbedding: prefillRawRotaryEmbedding,
      rawRotaryStart: prefillRawRotaryStart,
      rawRotaryLength: prefillRawRotaryLength,
      compressedRotaryEmbedding: prefillCompressedRotaryEmbedding,
      indexerRotaryEmbedding: prefillIndexerRotaryEmbedding,
      compressedRotaryStart: prefillCompressedRotaryStart,
      compressedRotaryLength: prefillCompressedRotaryLength)
    DynamicGraph.flags = flags
    if !storage.decoderIsLoaded,
      firstChunkLength < (configuration.compressionRatios.max() ?? 1)
    {
      // Make every compressor parameter visible to the initial weight read without eagerly
      // allocating the full headroom graph. The real short prefill is still evaluated unchanged.
      compilePrefillHeadroom(cacheCapacity: allocatedCacheCapacity, isEager: false)
    } else {
      storage.decoder.compile(
        (
          cachedTokenLength: tokenOffset + prefillStart,
          cachedRawTokenLength: firstCachedRawTokenLength,
          cachedCompressorInputLengths: kvCache.compressorInputLengths,
          tokenLength: firstChunkLength
        ),
        inputs: [firstTokens] + firstInputs)
    }
    if !storage.decoderIsLoaded {
      let expertResidentSlots = storage.configuration.expertResidentSlots
      let fullyResidentExpertLayers = Set(
        expertResidentSlots.indices.filter {
          expertResidentSlots[$0] == configuration.expertCount
        })
      let allExpertsFullyResident = fullyResidentExpertLayers.count == configuration.layers
      // Ordinary and shared tensors end within the first 8 GiB. The 40-64 GiB policies also keep
      // routed layers 0, 1, and 2 fully resident; their relocated tensors end within 14 GiB.
      let leadingFullyResidentLayerCount = expertResidentSlots.prefix {
        $0 == configuration.expertCount
      }.count
      let wholeFileMappingSizeLimit =
        allExpertsFullyResident
        ? 0 : (8 + 2 * min(leadingFullyResidentLayerCount, 3)) * 1_024 * 1_024 * 1_024
      DynamicGraph.setWholeFileMappingSizeLimit(wholeFileMappingSizeLimit)
      graph.openStore(filePath, flags: .readOnly) { store in
        let codec: DynamicGraph.Store.Codec = [
          .jit, .i8x(.iq2xs), .i8x(.iq2xxs), .ezm7, .externalData(.wholeFile),
        ]
        store.read(
          "text_model", model: storage.decoder, codec: codec,
          reader: { name, _, _, shape in
            let checkpointName =
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
            guard shape.count == 3, checkpointName.contains(".ffn.experts") else {
              return .continue(checkpointName, codec: codec)
            }
            if allExpertsFullyResident {
              return .continue(name, codec: codec)
            }
            var expertCodec = codec
            expertCodec.subtract([
              .externalData, .externalData(.mmap), .externalData(.wholeFile), .externalOnDemand,
            ])
            expertCodec.insert(.jit)
            let layerIndex = checkpointName.range(of: "layers.").flatMap { range in
              let suffix = checkpointName[range.upperBound...]
              let endIndex = suffix.firstIndex(of: ".") ?? suffix.endIndex
              return Int(suffix[..<endIndex])
            }
            expertCodec.insert(
              layerIndex.map(fullyResidentExpertLayers.contains) == true
                ? .externalData(.wholeFile) : .externalOnDemand)
            return .continue(checkpointName, codec: expertCodec)
          })
        DynamicGraph.setWholeFileMappingSizeLimit(0)
        storage.decoder.pinMemory = true
        storage.decoderIsLoaded = true
      }
    }
    compilePrefillHeadroom(cacheCapacity: allocatedCacheCapacity)

    var prefillTokenCPU: DynamicGraph.Tensor<Int32>?
    var prefillChunkStart = prefillStart
    guard continuationHandler(prefillChunkStart, tokenLength, [], statistics) == .continue else {
      return []
    }
    let initialPrefillDurationSoFar =
      recentInteractionStatistics[interactionStatisticsIndex].prefillDurationSoFar
    let prefillStartTime = CACurrentMediaTime()
    while prefillChunkStart < tokenLength {
      Self.compactCachesIfNeeded(&kvCache, configuration: configuration)
      let start = prefillChunkStart
      let cachedRawTokenLength = kvCache.rawTokenLength
      let length = prefillChunkLength(remainingTokenLength: tokenLength - start)
      guard length > 0 else { return [] }
      if length < chunkedPrefillMaxLength {
        DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)
      }
      let chunkInputs: [DynamicGraph.AnyTensor]
      let chunkTokens: DynamicGraph.Tensor<Int32>
      if start == prefillStart {
        chunkTokens = firstTokens
        chunkInputs = firstInputs
      } else {
        chunkTokens = tokens.reshaped(
          format: .NHWC, shape: [length], offset: [start], strides: [1]
        ).copied()
        let causalCompressedIndices = makePrefillCausalCompressedIndices(
          cachedTokenLength: tokenOffset + start, tokenLength: length)
        chunkInputs = modelInputs(
          tokens: chunkTokens, cachedTokenLength: tokenOffset + start,
          cachedRawTokenLength: cachedRawTokenLength,
          cachedCompressorInputLengths: kvCache.compressorInputLengths,
          causalCompressedIndices: causalCompressedIndices,
          rawRotaryEmbedding: prefillRawRotaryEmbedding,
          rawRotaryStart: prefillRawRotaryStart,
          rawRotaryLength: prefillRawRotaryLength,
          compressedRotaryEmbedding: prefillCompressedRotaryEmbedding,
          indexerRotaryEmbedding: prefillIndexerRotaryEmbedding,
          compressedRotaryStart: prefillCompressedRotaryStart,
          compressedRotaryLength: prefillCompressedRotaryLength)
      }
      let prefillOutputs = storage.decoder(
        (
          cachedTokenLength: tokenOffset + start,
          cachedRawTokenLength: cachedRawTokenLength,
          cachedCompressorInputLengths: kvCache.compressorInputLengths,
          tokenLength: length
        ),
        inputs: chunkTokens, chunkInputs)
      if start + length == tokenLength {
        let logits = prefillOutputs[0].as(of: FloatType.self)
        if deterministic {
          if thinkingBudget > 0 {
            let zmax = logits.reduced(.max, axis: [1])
            // min-p = 0.01: -log(0.01) = 4.6051702 at sampling scale 1.
            logits.fill(-Float.infinity, if: logits < (zmax - 4.605_170_2))
            prefillTokenCPU = Functional.gumbelArgmax(logits, axis: 1, scale: 1).reshaped(
              format: .NHWC, shape: [1]
            ).toCPU()
          } else {
            prefillTokenCPU = Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
              .toCPU()
          }
        } else {
          let scale: Float = thinkingBudget > 0 ? 1 : 0.7
          let minPLogitRange: Float = thinkingBudget > 0 ? 4.605_170_2 : 2.097_012_5
          let zmax = logits.reduced(.max, axis: [1])
          // min-p is 0.01 for thinking and 0.05 for creative answer sampling.
          logits.fill(-Float.infinity, if: logits < (zmax - minPLogitRange))
          prefillTokenCPU = Functional.gumbelArgmax(logits, axis: 1, scale: scale).reshaped(
            format: .NHWC, shape: [1]
          ).toCPU()
        }
      }
      prefillChunkStart += length
      kvCache.tokenLength = tokenOffset + prefillChunkStart
      kvCache.rawTokenLength += length
      for compressionRatio in configuration.compressionRatios {
        kvCache.compressorInputLengths[compressionRatio]! += length
      }
      let checkpointLength = tokenOffset + prefillChunkStart
      if checkpointLength.isMultiple(of: contextCache.checkpointStride) {
        contextCache.save(
          graph: graph, tokens: contextTokens, checkpointLength: checkpointLength,
          configuration: configuration, kvCache: kvCache,
          hasher: &contextCacheHasher)
      }
      recentInteractionStatistics[interactionStatisticsIndex].prefillDurationSoFar =
        Float(CACurrentMediaTime() - prefillStartTime) + initialPrefillDurationSoFar
      recentInteractionStatistics[interactionStatisticsIndex].prefillTokensSoFar += length
      DynamicGraph.flags = flags
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
    guard let prefillTokenCPU else { return [] }
    let firstToken = prefillTokenCPU[0]
    guard !Self.eosTokenIds.contains(firstToken) else { return [firstToken] }
    var generated = [firstToken]
    recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
    var nextTokenGPU = prefillTokenCPU.toGPU()
    let decodeTokenCapacity = max(0, Self.maximumContextLength - totalPrefillLength)
    guard decodeTokenCapacity > 0 else { return generated }
    var decodeRawRotaryStart = kvCache.tokenLength
    var decodeRawRotaryLength = min(
      allocatedCacheCapacity - kvCache.tokenLength, decodeTokenCapacity)
    var decodeRawRotaryEmbedding = graph.variable(
      Tensor<FloatType>(
        from: DeepSeek4RotaryEmbedding(
          sequenceLength: decodeRawRotaryLength,
          cachedTokenLength: decodeRawRotaryStart,
          compressed: false, configuration: configuration, of: Float.self)
      ).toGPU(0))
    var decodeCompressedRotaryStart = minimumCompressedRotaryStart(
      cachedTokenLength: kvCache.tokenLength)
    var decodeCompressedRotaryLength =
      kvCache.tokenLength + decodeRawRotaryLength - decodeCompressedRotaryStart
    var decodeCompressedRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
    if usesCompressedRotary {
      decodeCompressedRotaryEmbedding = graph.variable(
        Tensor<FloatType>(
          from: DeepSeek4RotaryEmbedding(
            sequenceLength: decodeCompressedRotaryLength,
            cachedTokenLength: decodeCompressedRotaryStart, compressed: true,
            configuration: configuration, of: Float.self)
        ).toGPU(0))
    }
    var decodeIndexerRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
    if usesIndexerRotary {
      decodeIndexerRotaryEmbedding = graph.variable(
        Tensor<FloatType>(
          from: DeepSeek4RotaryEmbedding(
            sequenceLength: decodeCompressedRotaryLength,
            cachedTokenLength: decodeCompressedRotaryStart, compressed: true,
            headDim: configuration.indexerHeadDim,
            configuration: configuration, of: Float.self)
        ).toGPU(0))
    }
    let queueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = queueWatermark * 16
    defer { DynamicGraph.queueWatermark = queueWatermark }
    var shouldAppendPendingToken = true
    var shouldStopAfterSampling = false
    var thinkingEnded = firstToken == Self.endThinkToken
    var decodeIndex = 0
    var thisContextTokens = contextTokens
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
      if kvCache.tokenLength + 1 > allocatedCacheCapacity {
        let nextCacheCapacity = min(
          allocatedCacheCapacity + self.compilePrefillHeadroom, Self.maximumContextLength)
        let nextRawRotaryStart = kvCache.tokenLength
        let nextRawRotaryLength = min(
          nextCacheCapacity - kvCache.tokenLength,
          decodeTokenCapacity - decodeIndex)
        let nextRawRotaryEmbedding = graph.variable(
          Tensor<FloatType>(
            from: DeepSeek4RotaryEmbedding(
              sequenceLength: nextRawRotaryLength,
              cachedTokenLength: nextRawRotaryStart, compressed: false,
              configuration: configuration, of: Float.self)
          ).toGPU(0))
        let nextCompressedRotaryStart = minimumCompressedRotaryStart(
          cachedTokenLength: kvCache.tokenLength)
        let nextCompressedRotaryLength =
          kvCache.tokenLength + nextRawRotaryLength - nextCompressedRotaryStart
        let nextCompressedRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
        if usesCompressedRotary {
          nextCompressedRotaryEmbedding = graph.variable(
            Tensor<FloatType>(
              from: DeepSeek4RotaryEmbedding(
                sequenceLength: nextCompressedRotaryLength,
                cachedTokenLength: nextCompressedRotaryStart, compressed: true,
                configuration: configuration, of: Float.self)
            ).toGPU(0))
        } else {
          nextCompressedRotaryEmbedding = nil
        }
        let nextIndexerRotaryEmbedding: DynamicGraph.Tensor<FloatType>?
        if usesIndexerRotary {
          nextIndexerRotaryEmbedding = graph.variable(
            Tensor<FloatType>(
              from: DeepSeek4RotaryEmbedding(
                sequenceLength: nextCompressedRotaryLength,
                cachedTokenLength: nextCompressedRotaryStart, compressed: true,
                headDim: configuration.indexerHeadDim,
                configuration: configuration, of: Float.self)
            ).toGPU(0))
        } else {
          nextIndexerRotaryEmbedding = nil
        }
        Self.resizeCaches(
          graph: graph, kvCache: &kvCache, cacheCapacity: nextCacheCapacity,
          workingCacheCapacity: workingCacheCapacity,
          configuration: configuration)
        allocatedCacheCapacity = Self.cacheCapacity(
          kvCache, configuration: configuration)
        maximumCompressedIndices = makeMaximumCompressedIndices(
          cacheCapacity: allocatedCacheCapacity)
        decodeRawRotaryStart = nextRawRotaryStart
        decodeRawRotaryLength = nextRawRotaryLength
        decodeRawRotaryEmbedding = nextRawRotaryEmbedding
        if let nextCompressedRotaryEmbedding {
          decodeCompressedRotaryStart = nextCompressedRotaryStart
          decodeCompressedRotaryLength = nextCompressedRotaryLength
          decodeCompressedRotaryEmbedding = nextCompressedRotaryEmbedding
        }
        if let nextIndexerRotaryEmbedding {
          decodeIndexerRotaryEmbedding = nextIndexerRotaryEmbedding
        }
        compilePrefillHeadroom(cacheCapacity: allocatedCacheCapacity)
      }
      Self.compactCachesIfNeeded(&kvCache, configuration: configuration)
      let cachedRawTokenLength = kvCache.rawTokenLength
      let oldDecodedTokenCPU = nextTokenGPU.toCPU()
      let decodeInputs = modelInputs(
        tokens: nextTokenGPU, cachedTokenLength: kvCache.tokenLength,
        cachedRawTokenLength: cachedRawTokenLength,
        cachedCompressorInputLengths: kvCache.compressorInputLengths,
        causalCompressedIndices: maximumCompressedIndices,
        rawRotaryEmbedding: decodeRawRotaryEmbedding,
        rawRotaryStart: decodeRawRotaryStart,
        rawRotaryLength: decodeRawRotaryLength,
        compressedRotaryEmbedding: decodeCompressedRotaryEmbedding,
        indexerRotaryEmbedding: decodeIndexerRotaryEmbedding,
        compressedRotaryStart: decodeCompressedRotaryStart,
        compressedRotaryLength: decodeCompressedRotaryLength)
      let decodeOutputs = storage.decoder(
        (
          cachedTokenLength: kvCache.tokenLength,
          cachedRawTokenLength: cachedRawTokenLength,
          cachedCompressorInputLengths: kvCache.compressorInputLengths,
          tokenLength: 1
        ),
        inputs: nextTokenGPU, decodeInputs)
      let logits = decodeOutputs[0].as(of: FloatType.self)
      kvCache.tokenLength += 1
      kvCache.rawTokenLength += 1
      for compressionRatio in configuration.compressionRatios {
        kvCache.compressorInputLengths[compressionRatio]! += 1
      }
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
      if decodeIndex == 0 {
        // At this point, caches might filled, we just need to save the cache if it hits the boundary.
        thisContextTokens.append(firstToken)
        if thisContextTokens.count.isMultiple(of: contextCache.checkpointStride) {
          contextCache.save(
            graph: graph, tokens: thisContextTokens,
            checkpointLength: thisContextTokens.count, configuration: configuration,
            kvCache: kvCache, hasher: &contextCacheHasher)
        }
      } else {
        let decodedToken = oldDecodedTokenCPU[0]
        generated.append(decodedToken)
        thisContextTokens.append(decodedToken)
        if thisContextTokens.count.isMultiple(of: contextCache.checkpointStride) {
          contextCache.save(
            graph: graph, tokens: thisContextTokens,
            checkpointLength: thisContextTokens.count, configuration: configuration,
            kvCache: kvCache, hasher: &contextCacheHasher)
        }
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
          break
        }
        if !shouldAppendPendingToken {
          break
        }
      }
      if deterministic {
        if thinkingBudget > 0 && !thinkingEnded {
          let zmax = logits.reduced(.max, axis: [1])
          // min-p = 0.01: -log(0.01) = 4.6051702 at sampling scale 1.
          logits.fill(-Float.infinity, if: logits < (zmax - 4.605_170_2))
          nextTokenGPU = Functional.gumbelArgmax(logits, axis: 1, scale: 1).reshaped(
            format: .NHWC, shape: [1])
        } else {
          nextTokenGPU = Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
        }
      } else {
        let scale: Float = thinkingBudget > 0 && !thinkingEnded ? 1 : 0.7
        let minPLogitRange: Float =
          thinkingBudget > 0 && !thinkingEnded ? 4.605_170_2 : 2.097_012_5
        let zmax = logits.reduced(.max, axis: [1])
        // min-p is 0.01 for thinking and 0.05 for creative answer sampling.
        logits.fill(-Float.infinity, if: logits < (zmax - minPLogitRange))
        nextTokenGPU = Functional.gumbelArgmax(logits, axis: 1, scale: scale).reshaped(
          format: .NHWC, shape: [1])
      }
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

  private static func makeCaches(
    graph: DynamicGraph, cacheCapacity: Int, workingCacheCapacity: Int,
    configuration: DeepSeek4ModelConfiguration
  ) -> [KVCache.Layer] {
    graph.garbageCollect()
    precondition(cacheCapacity > 0 && workingCacheCapacity >= Self.rawCacheCapacity)
    var layers = [KVCache.Layer]()
    layers.reserveCapacity(configuration.layers)
    for layerIndex in 0..<configuration.layers {
      switch configuration.attentionKind(layerIndex: layerIndex) {
      case .raw:
        let rawKeyValue = graph.variable(
          .GPU(0), .NHWC(1, workingCacheCapacity, 1, configuration.attentionHeadDim),
          of: FloatType.self)
        rawKeyValue.full(0)
        layers.append(
          KVCache.Layer(
            rawKeyValue: rawKeyValue, compressedKeyValue: nil,
            compressorInputCache: nil,
            indexerKeyValue: nil))
      case .compressed(let compressionRatio), .indexed(let compressionRatio):
        let rawKeyValue = graph.variable(
          .GPU(0), .NHWC(1, workingCacheCapacity, 1, configuration.attentionHeadDim),
          of: FloatType.self)
        rawKeyValue.full(0)
        let compressedCapacity = max(cacheCapacity / compressionRatio, 1)
        let compressedKeyValue = graph.variable(
          Tensor<FloatType>(
            Array(
              repeating: FloatType.zero,
              count: compressedCapacity * configuration.attentionHeadDim),
            .CPU, .WC(compressedCapacity, configuration.attentionHeadDim)
          ).toGPU(0))
        let compressorInputCache = graph.variable(
          .GPU(0), .WC(workingCacheCapacity, configuration.hiddenSize),
          of: FloatType.self)
        compressorInputCache.full(0)
        let indexerKeyValue: DynamicGraph.AnyTensor?
        if case .indexed = configuration.attentionKind(layerIndex: layerIndex) {
          indexerKeyValue = graph.variable(
            Tensor<Float16>(
              Array(
                repeating: Float16.zero,
                count: compressedCapacity * configuration.indexerHeadDim),
              .CPU, .WC(compressedCapacity, configuration.indexerHeadDim)
            ).toGPU(0))
        } else {
          indexerKeyValue = nil
        }
        layers.append(
          KVCache.Layer(
            rawKeyValue: rawKeyValue, compressedKeyValue: compressedKeyValue,
            compressorInputCache: compressorInputCache,
            indexerKeyValue: indexerKeyValue))
      }
    }
    return layers
  }

  private static func cacheCapacity(
    _ kvCache: KVCache, configuration: DeepSeek4ModelConfiguration
  ) -> Int {
    for (layerIndex, layer) in kvCache.layers.enumerated() {
      switch configuration.attentionKind(layerIndex: layerIndex) {
      case .raw:
        continue
      case .compressed(let compressionRatio), .indexed(let compressionRatio):
        return layer.compressedKeyValue!.shape[0] * compressionRatio
      }
    }
    return 0
  }

  private static func resizeCaches(
    graph: DynamicGraph, kvCache: inout KVCache, cacheCapacity: Int,
    workingCacheCapacity: Int,
    configuration: DeepSeek4ModelConfiguration
  ) {
    let existingCacheCapacity = Self.cacheCapacity(kvCache, configuration: configuration)
    guard existingCacheCapacity < cacheCapacity else { return }
    if kvCache.layers.isEmpty {
      kvCache.layers = makeCaches(
        graph: graph, cacheCapacity: cacheCapacity,
        workingCacheCapacity: workingCacheCapacity, configuration: configuration)
      kvCache.compressorInputLengths = Dictionary(
        uniqueKeysWithValues: configuration.compressionRatios.map { ($0, 0) })
      return
    }
    graph.joined()
    var layers = [KVCache.Layer]()
    layers.reserveCapacity(kvCache.layers.count)
    for layerIndex in 0..<configuration.layers {
      let oldLayer = kvCache.layers[layerIndex]
      let rawKeyValue = oldLayer.rawKeyValue

      let compressedKeyValue: DynamicGraph.AnyTensor?
      let indexerKeyValue: DynamicGraph.AnyTensor?
      switch configuration.attentionKind(layerIndex: layerIndex) {
      case .raw:
        compressedKeyValue = nil
        indexerKeyValue = nil
      case .compressed(let compressionRatio), .indexed(let compressionRatio):
        let oldCompressedCapacity = oldLayer.compressedKeyValue!.shape[0]
        let compressedCapacity = max(cacheCapacity / compressionRatio, 1)
        var newCompressedKeyValue = graph.variable(
          Tensor<FloatType>(
            Array(
              repeating: FloatType.zero,
              count: compressedCapacity * configuration.attentionHeadDim),
            .CPU, .WC(compressedCapacity, configuration.attentionHeadDim)
          ).toGPU(0))
        newCompressedKeyValue[
          0..<oldCompressedCapacity, 0..<configuration.attentionHeadDim
        ] = oldLayer.compressedKeyValue!.as(of: FloatType.self)
        compressedKeyValue = newCompressedKeyValue
        if case .indexed = configuration.attentionKind(layerIndex: layerIndex) {
          var newIndexerKeyValue = graph.variable(
            Tensor<Float16>(
              Array(
                repeating: Float16.zero,
                count: compressedCapacity * configuration.indexerHeadDim),
              .CPU, .WC(compressedCapacity, configuration.indexerHeadDim)
            ).toGPU(0))
          newIndexerKeyValue[
            0..<oldCompressedCapacity, 0..<configuration.indexerHeadDim
          ] = oldLayer.indexerKeyValue!.as(of: Float16.self)
          indexerKeyValue = newIndexerKeyValue
        } else {
          indexerKeyValue = nil
        }
      }
      layers.append(
        KVCache.Layer(
          rawKeyValue: rawKeyValue, compressedKeyValue: compressedKeyValue,
          compressorInputCache: oldLayer.compressorInputCache,
          indexerKeyValue: indexerKeyValue))
    }
    kvCache.layers = layers
    graph.garbageCollect()
  }

  private static func compactCachesIfNeeded(
    _ kvCache: inout KVCache, configuration: DeepSeek4ModelConfiguration
  ) {
    guard kvCache.tokenLength > 0,
      kvCache.tokenLength.isMultiple(of: Self.cachePageSize),
      kvCache.rawTokenLength > configuration.rawWindow
    else { return }
    precondition(kvCache.rawTokenLength >= configuration.rawWindow)
    var retainedCompressorInputLengths = [Int: Int]()
    for compressionRatio in configuration.compressionRatios {
      let compressedRows = kvCache.tokenLength / compressionRatio
      retainedCompressorInputLengths[compressionRatio] =
        kvCache.tokenLength % compressionRatio
        + (compressionRatio == 4 && compressedRows > 0 ? compressionRatio : 0)
    }
    for index in kvCache.layers.indices {
      let attentionKind = configuration.attentionKind(layerIndex: index)
      var rawKeyValue = kvCache.layers[index].rawKeyValue.as(of: FloatType.self)
      rawKeyValue[
        0..<1, 0..<configuration.rawWindow, 0..<1,
        0..<configuration.attentionHeadDim
      ] = rawKeyValue[
        0..<1,
        (kvCache.rawTokenLength - configuration.rawWindow)..<kvCache.rawTokenLength, 0..<1,
        0..<configuration.attentionHeadDim
      ].copied()
      switch attentionKind {
      case .raw:
        break
      case .compressed(let compressionRatio), .indexed(let compressionRatio):
        let retainedLength = retainedCompressorInputLengths[compressionRatio]!
        guard retainedLength > 0 else { continue }
        let inputLength = kvCache.compressorInputLengths[compressionRatio]!
        var compressorInputCache = kvCache.layers[index].compressorInputCache!.as(
          of: FloatType.self)
        compressorInputCache[0..<retainedLength, 0..<configuration.hiddenSize] =
          compressorInputCache[
            (inputLength - retainedLength)..<inputLength,
            0..<configuration.hiddenSize
          ].copied()
      }
    }
    kvCache.rawTokenLength = configuration.rawWindow
    kvCache.compressorInputLengths = retainedCompressorInputLengths
  }

  /// Reuse production prefill, including real quantized resident weights and compressor state.
  /// The caller owns the graph, stream, no-grad scope, synchronization, and collection.
  /// No prompt-cache files or generation state are shared with the user's session.
  @discardableResult
  public func warmupPrefill(graph: DynamicGraph) -> Bool {
    // Inspect metadata only: gate/up and down use different bank shapes, so codec coverage
    // must be tracked separately for each projection.
    var layerCodecs = [[DynamicGraph.Store.Codec]]()
    graph.openStore(filePath, flags: .readOnly) { store in
      for layer in 0..<self.configuration.layers {
        let codecs = ["ffn.experts-0-0", "ffn.experts-0-1", "ffn.experts.w2-0-0"].compactMap {
          store.codec(for: "__text_model__[t-layers.\(layer).\($0)]")
        }
        guard codecs.count == 3 else { return }
        layerCodecs.append(codecs)
      }
    }
    guard layerCodecs.count == self.configuration.layers else { return false }
    var layers = Array(0..<min(4, self.configuration.layers))
    func coversExperts(_ layer: Int, with representatives: [Int]) -> Bool {
      (0..<3).allSatisfy { projection in
        representatives.contains { layerCodecs[$0][projection] == layerCodecs[layer][projection] }
      }
    }
    for layer in layers.count..<self.configuration.layers {
      guard !coversExperts(layer, with: layers) else { continue }
      // Replace a redundant layer of the same attention/router kind when possible. Otherwise
      // retain an additional real layer rather than silently omitting a checkpoint format.
      if let replacement = layers.indices.reversed().first(where: { index in
        let previous = layers[index]
        guard
          self.configuration.layerAttentionKinds[previous]
            == self.configuration.layerAttentionKinds[layer],
          self.configuration.layerRouterKinds[previous]
            == self.configuration.layerRouterKinds[layer]
        else { return false }
        var candidates = layers
        candidates[index] = layer
        return layers.allSatisfy { coversExperts($0, with: candidates) }
      }) {
        layers[replacement] = layer
      } else {
        layers.append(layer)
      }
    }
    var generator = Self(prefillWarmup: self, layers: layers)
    let configuration = generator.configuration
    // Compile shapes only, never execute these placeholder inputs. This exposes all real
    // parameters for a strict, remapped weight read before entering ordinary decode.
    let count = configuration.compressionRatios.max() ?? 1
    let headDim = configuration.attentionHeadDim
    let indexerDim = configuration.indexerHeadDim
    var inputs: [DynamicGraph.AnyTensor] = [
      graph.variable(.GPU(0), .C(count), of: Int32.self),
      graph.variable(.GPU(0), .NHWC(1, count, 1, headDim), of: FloatType.self),
    ]
    if !configuration.compressionRatios.isEmpty {
      inputs.append(graph.variable(.GPU(0), .NHWC(1, count, 1, headDim), of: FloatType.self))
    }
    if !configuration.indexerCompressionRatios.isEmpty {
      inputs.append(graph.variable(.GPU(0), .NHWC(1, count, 1, indexerDim), of: FloatType.self))
    }
    if configuration.compressionRatios.contains(4) {
      inputs.append(graph.variable(.GPU(0), .HWC(1, headDim, 4), of: FloatType.self))
      inputs.append(graph.variable(.GPU(0), .HWC(1, headDim, 4), of: FloatType.self))
    }
    if configuration.indexerCompressionRatios.contains(4) {
      inputs.append(graph.variable(.GPU(0), .HWC(1, indexerDim, 4), of: FloatType.self))
      inputs.append(graph.variable(.GPU(0), .HWC(1, indexerDim, 4), of: FloatType.self))
    }
    for ratio in configuration.compressionRatios {
      inputs.append(graph.variable(.GPU(0), .WC(count / ratio, headDim), of: FloatType.self))
    }
    for ratio in configuration.indexerCompressionRatios {
      inputs.append(graph.variable(.GPU(0), .WC(count / ratio, indexerDim), of: FloatType.self))
    }
    var causalRatios = Set<Int>()
    for kind in configuration.layerAttentionKinds {
      if case .compressed(let ratio) = kind, causalRatios.insert(ratio).inserted {
        inputs.append(graph.variable(.GPU(0), .WC(count, count / ratio), of: Int32.self))
      }
      inputs.append(graph.variable(.GPU(0), .NHWC(1, count, 1, headDim), of: FloatType.self))
      switch kind {
      case .raw:
        break
      case .compressed(let ratio), .indexed(let ratio):
        inputs.append(graph.variable(.GPU(0), .WC(count / ratio, headDim), of: FloatType.self))
        inputs.append(
          graph.variable(.GPU(0), .WC(count, configuration.hiddenSize), of: FloatType.self))
        if case .indexed = kind {
          inputs.append(
            graph.variable(.GPU(0), .WC(count / ratio, indexerDim), of: Float16.self))
        }
      }
    }
    generator.storage.decoder.compile(
      (
        cachedTokenLength: 0, cachedRawTokenLength: 0,
        cachedCompressorInputLengths: Dictionary(
          uniqueKeysWithValues: configuration.compressionRatios.map { ($0, 0) }),
        tokenLength: count
      ), inputs: inputs)
    // Every expert is resident, so map the whole checkpoint like a fully resident load.
    DynamicGraph.setWholeFileMappingSizeLimit(0)
    let loadResult = try? graph.openStore(filePath, flags: .readOnly) { store in
      let codec: DynamicGraph.Store.Codec = [
        .jit, .i8x(.iq2xs), .i8x(.iq2xxs), .ezm7, .externalData(.wholeFile),
      ]
      try store.read("text_model", model: generator.storage.decoder, strict: true, codec: codec) {
        name, _, _, _ in
        var checkpointName = name
        if let prefix = name.range(of: "layers.") {
          let end = name[prefix.upperBound...].firstIndex(of: ".") ?? name.endIndex
          if let layerIndex = Int(name[prefix.upperBound..<end]) {
            checkpointName.replaceSubrange(
              prefix.upperBound..<end, with: String(layers[layerIndex]))
          }
        }
        return .continue(checkpointName, codec: codec)
      }
    }
    guard case .success? = loadResult else { return false }
    generator.storage.decoderIsLoaded = true

    // The indexer has three prefill tiles: T < 1024, and T >= 1024 with C <= 1024
    // or C > 1024. Cross the large-C threshold with full specialized-M chunks, then
    // split one cached partial chunk to cover both query-size tiles with dynamic M.
    let prefillLength = (4_096 / chunkedPrefillMaxLength + 1) * chunkedPrefillMaxLength
    let smallLength = min(512, chunkedPrefillMaxLength / 4)
    let passes = [
      (cached: 0, count: prefillLength, thinking: 128, deterministic: true),
      (cached: prefillLength, count: smallLength, thinking: 128, deterministic: true),
      (
        cached: prefillLength + smallLength,
        count: chunkedPrefillMaxLength - 1 - smallLength, thinking: 0, deterministic: false
      ),
      // With 2K chunks this is a full chunk followed by a partial chunk. Both chunk
      // sizes reach 1023 compressed rows, covering the smaller-C dynamic-M score tile.
      (cached: 0, count: 4_095, thinking: 0, deterministic: true),
      (
        cached: 0, count: max(7, configuration.compressionRatios.min() ?? 1), thinking: 0,
        deterministic: true
      ),
    ]
    var cache = KVCache()
    let contextCache = DeepSeek4ContextCache(projectPath: nil, checkpointStride: checkpointStride)
    for pass in passes {
      if pass.cached == 0 { cache = KVCache() }
      let contextTokens = (0..<(pass.cached + pass.count)).map { Int32(1 + $0 % 255) }
      let tokens = graph.variable(
        Tensor<Int32>(Array(contextTokens.suffix(pass.count))).toGPU(0))
      let result = generator.decode(
        graph: graph, tokens: tokens, tokenOffset: pass.cached, thinkingBudget: pass.thinking,
        deterministic: pass.deterministic, kvCache: &cache, contextTokens: contextTokens,
        contextCache: contextCache
      ) { start, length, _, _ in start < length ? .continue : .pause }
      guard !result.isEmpty, cache.tokenLength == pass.cached + pass.count else { return false }
    }
    return true
  }
}
