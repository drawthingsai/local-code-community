import DataModels
import Foundation
import LLM
import NNC
import ProjectHistoryManager
import QuartzCore
import Tokenizer
import os.lock

public struct Inkling2MiniTextGenerator {
  public static let estimatedKVCacheSize: UInt64 = 4 * 1_024 * 1_024 * 1_024

  public struct KVCache {
    // One for each layer application: a looped layer has its own caches and convolution rows in
    // every pass.
    struct Layer {
      var keys: DynamicGraph.Tensor<Float16>
      var values: DynamicGraph.Tensor<Float16>
      // Key and value convolution rows in FP16, post-attention and post-MLP ones in FP32; then
      // the buffers their next values go to. With a drafter, each holds the rows after every token
      // a verify evaluates.
      var convolutionRows: [DynamicGraph.AnyTensor]
    }

    public internal(set) var tokenLength = 0
    // Rows of the sliding-window caches, which move their window back to the start when full.
    var slidingTokenLength = 0
    var layers = [Layer]()
    /// An image that could not load left its placeholder rows here, so checkpoints would store rows
    /// that do not match the image their hash names.
    var hasPaddedImages = false
    // Where the convolution rows start in their buffers: after a verify, the rows after its last
    // kept token.
    var convolutionOffset = 0
    // DSpark: each drafter layer's key and value caches. A layer that sees every position keeps a
    // row per position; a window layer's row is the position minus `draftLocalStart`, and it
    // starts with windowRows rows of zeros before the first position the drafter sees.
    var draftKeys = [DynamicGraph.Tensor<Float16>]()
    var draftValues = [DynamicGraph.Tensor<Float16>]()
    var draftLocalStart = 0
    // The target features of the rows from `draftMainStart` the drafter has not written: at most a
    // block's rows, the first `draftMainKept` committed and the rest evaluated by a verify that did
    // not keep them. Never written in place.
    var draftMainFeatures: DynamicGraph.Tensor<Float16>?
    var draftMainKept = 0
    var draftMainStart = 0
    // Zeros [blockSize, global rows] that open a draft's view of the layers that see every position.
    var draftOpenPrefix: DynamicGraph.Tensor<Float16>?

    public init() {}

    // Sliding-window caches and convolution rows move in place; full-attention caches only append.
    public func snapshot() -> KVCache {
      var snapshot = self
      let configuration = Inkling2MiniConfiguration.inkling2Mini
      for index in layers.indices {
        if !configuration.isFullAttention(application: index) {
          snapshot.layers[index].keys = layers[index].keys.copied()
          snapshot.layers[index].values = layers[index].values.copied()
        }
        // Each group of four: key and value rows in FP16, post-attention and post-MLP in FP32.
        snapshot.layers[index].convolutionRows = layers[index].convolutionRows.enumerated().map {
          $0 % 4 < 2 ? $1.as(of: Float16.self).copied() : $1.as(of: Float.self).copied()
        }
      }
      // The drafter's window layers move their rows back too; its other layers only append.
      let draft = Inkling2SmallDSparkConfiguration.inkling2Mini
      for layer in draftKeys.indices where draft.isLocal(layer) {
        snapshot.draftKeys[layer] = draftKeys[layer].copied()
        snapshot.draftValues[layer] = draftValues[layer].copied()
      }
      return snapshot
    }
  }

  // <|end_message|> closes the thinking message.
  private static let endThinkToken: Int32 = 200_010
  // <|content_thinking|> right after <|message_model|> makes a model message the thinking one.
  private static let thinkingContentToken: Int32 = 200_008
  // <|content_model_end_sampling|> ends the model's turn.
  private static let eosTokenIds = Set<Int32>([200_006, 199_999])
  private static let maximumContextLength = 1_024 * 1_024
  private static let recentStatisticsLimit = 3
  /// Inkling 2 Mini shares Inkling 2 Mini's tokenizer and special tokens.
  public static var unsafeTokenizer: TiktokenTokenizer {
    Inkling2SmallTextGenerator.unsafeTokenizer
  }

  public static var safeTokenizer: TiktokenTokenizer { Inkling2SmallTextGenerator.safeTokenizer }

  public let filePath: String
  private let configuration: Inkling2MiniConfiguration
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
  /// The last decode's DSpark rounds and the drafts they kept.
  public private(set) var lastDraftAcceptance = (rounds: 0, kept: 0)
  // Keep this storage model-only: no DynamicGraph, graph tensors, or closures
  // capturing them. Reset may release it on the command thread after decode.
  private final class Storage {
    // Serialize reset with decoding across every value copy of the generator.
    var lock = os_unfair_lock()
    private let configuration: Inkling2MiniConfiguration
    private let drafterFile: String?
    /// A load with the DSpark drafter, settled when the decoder builds: every call also outputs the
    /// drafter's target features of its rows.
    private(set) var isDrafting = false
    var decoderIsLoaded = false
    private var cachedDecoder:
      ModelBuilder<(cached: Int, sliding: Int, count: Int, logits: Int, convolutionOffset: Int)>?
    // A call with more than one logit row verifies drafts: its convolutions keep the rows after
    // each of its tokens, so a shorter accepted prefix can pick its own, from which the next call
    // reads at `convolutionOffset`.
    var decoder:
      ModelBuilder<(cached: Int, sliding: Int, count: Int, logits: Int, convolutionOffset: Int)>
    {
      if let cachedDecoder { return cachedDecoder }
      isDrafting = drafterFile.map { FileManager.default.fileExists(atPath: $0) } ?? false
      let configuration = self.configuration
      let featureLayers =
        isDrafting ? Inkling2SmallDSparkConfiguration.inkling2Mini.targetLayers : []
      let decoder = ModelBuilder {
        (
          shape: (cached: Int, sliding: Int, count: Int, logits: Int, convolutionOffset: Int), _
        ) in
        Inkling2MiniCausalLM(
          Float16.self, tokenLength: shape.count, cachedTokenLength: shape.cached,
          cachedSlidingTokenLength: shape.sliding, logitTokenLength: shape.logits,
          draftFeatureLayers: featureLayers, convolutionCheckpoints: shape.logits - 1,
          convolutionOffset: shape.convolutionOffset, configuration: configuration)
      }
      decoder.maxConcurrency = .limit(4)
      cachedDecoder = decoder
      return decoder
    }
    var drafterIsLoaded = false
    private var cachedDrafter:
      ModelBuilder<(mainRows: Int, globalRow: Int, localOffset: Int, temperature: Float)>?
    var drafter: ModelBuilder<(mainRows: Int, globalRow: Int, localOffset: Int, temperature: Float)>
    {
      if let cachedDrafter { return cachedDrafter }
      let drafter = ModelBuilder {
        (shape: (mainRows: Int, globalRow: Int, localOffset: Int, temperature: Float), _) in
        Inkling2SmallDSpark(
          Float16.self, mainRows: shape.mainRows, globalRow: shape.globalRow,
          localOffset: shape.localOffset, temperature: shape.temperature, draft: .inkling2Mini)
      }
      cachedDrafter = drafter
      return drafter
    }
    private var cachedDraftContext: ModelBuilder<(rows: Int, globalRow: Int, localRow: Int)>?
    var draftContext: ModelBuilder<(rows: Int, globalRow: Int, localRow: Int)> {
      if let cachedDraftContext { return cachedDraftContext }
      let context = ModelBuilder { (shape: (rows: Int, globalRow: Int, localRow: Int), _) in
        Inkling2SmallDSparkContext(
          Float16.self, rows: shape.rows, globalRow: shape.globalRow, localRow: shape.localRow,
          draft: .inkling2Mini)
      }
      cachedDraftContext = context
      return context
    }
    var isVisionLoaded = false
    private var cachedVision: ModelBuilder<(height: Int, width: Int)>?
    // The vision tower's graph depends on the image's token grid.
    var vision: ModelBuilder<(height: Int, width: Int)> {
      if let cachedVision { return cachedVision }
      let vision = ModelBuilder { (grid: (height: Int, width: Int), _) in
        Inkling2SmallVisionTransformer(Float16.self, grid: grid, configuration: .inkling2Mini)
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
      cachedDrafter = nil
      cachedDraftContext = nil
      drafterIsLoaded = false
    }

    init(configuration: Inkling2MiniConfiguration, drafterFile: String?) {
      self.configuration = configuration
      self.drafterFile = drafterFile
    }
  }

  // Copies share model storage. Graphs and conversation caches stay on the generation queue.
  private let storage: Storage
  public let chunkedPrefillMaxLength: Int
  public let compilePrefillHeadroom: Int
  /// The DSpark drafter store (Inkling2MiniConverter --dspark), which reads this model's
  /// embedding and head. Without it, while it is not downloaded, or while the experts stream at the
  /// 3 GiB plan, a step decodes one token.
  public let drafterFile: String?
  /// Set while this generator decodes when it picked the streaming plan itself, so a prompt chunk
  /// stages one expert bank at a time; nil leaves the watermark as it is.
  private let weightsStreamingWatermarkBytes: Int?

  /// A configuration whose layers stream is used as it is. Otherwise, with nil the experts stream
  /// on devices with 16 GiB of memory or less, `.disabled` keeps every weight resident, and any
  /// other tier streams when the store is larger than it. Streaming that way uses the 3 GiB plan,
  /// prefills at most 1,024 tokens a chunk and decodes without the drafter.
  public init(
    filePath: String, configuration: Inkling2MiniConfiguration = .inkling2Mini,
    chunkedPrefillMaxLength: Int, compilePrefillHeadroom: Int = 64 * 1_024,
    weightsStreaming: DeviceCapability.WeightsStreaming? = nil, drafterFile: String? = nil
  ) {
    precondition(chunkedPrefillMaxLength > 0)
    precondition(compilePrefillHeadroom > chunkedPrefillMaxLength)
    precondition(compilePrefillHeadroom <= Self.maximumContextLength)
    var configuration = configuration
    let isStreaming: Bool
    switch weightsStreaming {
    case .disabled:
      isStreaming = false
    case .none:
      isStreaming = Self.isWeightsStreamingPreferred
    case .some(let tier):
      let storeSize =
        ((try? FileManager.default.attributesOfItem(atPath: filePath))?[.size] as? NSNumber)?
        .uint64Value ?? 0
      isStreaming = storeSize > UInt64(tier.rawValue) * 1_024 * 1_024 * 1_024
    }
    self.filePath = filePath
    self.drafterFile = drafterFile
    self.compilePrefillHeadroom = compilePrefillHeadroom
    if isStreaming, !(0..<configuration.layers).contains(where: configuration.isStreamingLayer) {
      configuration.expertResidentSlots = Self.expertResidentSlotsAt3GiB
      // Measured on 3-bit S with caches for 64K (benchmark-results/inkling2-mini-streaming-20261121):
      // staging one bank at a time keeps a prompt's peak at 7.2 GB with 1,024-token chunks, against
      // 9.3 GB unbounded and 8.3 GB with 2,048-token chunks, at the same prefill speed. Each chunk
      // reads every bank, so prefill gets faster with longer chunks. Drafting gained nothing: a
      // verify streams more experts than its drafts save.
      weightsStreamingWatermarkBytes = 1
      self.chunkedPrefillMaxLength = min(chunkedPrefillMaxLength, 1_024)
      storage = Storage(configuration: configuration, drafterFile: nil)
    } else {
      weightsStreamingWatermarkBytes = nil
      self.chunkedPrefillMaxLength = chunkedPrefillMaxLength
      storage = Storage(configuration: configuration, drafterFile: drafterFile)
    }
    self.configuration = configuration
  }
}

extension Inkling2MiniTextGenerator {
  /// With 16 GiB of memory or less, the experts stream from the store: 13.5 GB (3-bit S) or 16.6 GB
  /// (4-bit S) do not fit beside the system and the caches.
  public static let isWeightsStreamingPreferred =
    ProcessInfo.processInfo.physicalMemory <= 16 * 1_024 * 1_024 * 1_024

  /// 64K tokens where the experts stream, whose caches take 2.4 GB of the memory left; 256K
  /// otherwise.
  public static var contextWindowLength: Int {
    isWeightsStreamingPreferred ? 64 * 1_024 : 256 * 1_024
  }

  // Decode pool slots per layer, fitted for 3-bit S (inkling_2_mini_i3x.ckpt) to fill 3 GiB with its
  // 1.50 GiB of resident weights, allocated to read the fewest bytes per decoded token (373 MiB) on
  // routing traces of the ds4 calibration corpus (benchmark-results/inkling2-mini-streaming-20261121).
  // A looped layer's three passes share its pool. 4-bit S, with larger experts and an FP16
  // embedding, holds 3.82 GiB at the same slots.
  static let expertResidentSlotsAt3GiB = [
    11, 11, 11, 8, 8, 8, 31, 31, 26, 26, 31, 31, 26, 25, 26, 26, 23, 31, 13, 11, 11, 12, 11, 12,
  ]
}

extension Inkling2MiniTextGenerator: TextGenerator {
  public var safeTokenizer: TiktokenTokenizer { Self.safeTokenizer }
}

extension Inkling2MiniTextGenerator {
  /// Drops only shared model weights, waiting for an active decode to return.
  /// Safe from a tool worker; graph-owned conversation caches stay with the agent.
  public func unload() { storage.reset() }

  public var filePaths: [String] { [filePath] + [drafterFile].compactMap { $0 } }

  /// At most 4 GiB while the experts stream at the 3 GiB plan (3.00 GiB with 3-bit S, 3.82 GiB with
  /// 4-bit S); otherwise the store's size, and the drafter's when it is downloaded.
  public var residentWeightsSize: UInt64 {
    guard weightsStreamingWatermarkBytes == nil else { return 4 * 1_024 * 1_024 * 1_024 }
    return [filePath, drafterFile].compactMap { $0 }.reduce(0) {
      $0
        + (((try? FileManager.default.attributesOfItem(atPath: $1))?[.size] as? NSNumber)?
          .uint64Value ?? 0)
    }
  }

  /// Checkpoints land on whole prefill chunks: the chunk length rounded down to a multiple of
  /// 4,096 tokens, and at least 4,096, so they share the context cache's fixed slices.
  public var checkpointStride: Int {
    max(Inkling2MiniContextCache.checkpointStorageStride, chunkedPrefillMaxLength / 4_096 * 4_096)
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
        // Read, not mapped, as Inkling 2 Mini's: the tower is a small part of the file.
        try store.read(
          "vision_model", model: vision, strict: true, codec: [.jit, .i8x, .ezm7, .externalData])
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
  /// rows of `contextTokens`; an image that cannot load keeps its placeholder rows. An empty
  /// `kvCache` restores what `contextCache` holds of the context, and checkpoints save to it.
  public mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool = true, kvCache: inout KVCache,
    contextTokens: [Int32], contextCache: Inkling2MiniContextCache,
    embedSpans: [EmbedSpan] = [], projectPath: String? = nil,
    continuationHandler: (Int, Int, [Int32], DeepSeekGenerationStatistics) ->
      DeepSeekGenerationContinuationState
  ) -> [Int32] {
    os_unfair_lock_lock(&storage.lock)
    defer { os_unfair_lock_unlock(&storage.lock) }
    let originalFlags = DynamicGraph.flags
    DynamicGraph.flags.insert(.disableMFAAttentionSpecializingC)
    defer { DynamicGraph.flags = originalFlags }
    let originalWeightsStreamingWatermarkBytes = DynamicGraph.weightsStreamingWatermarkBytes
    if let weightsStreamingWatermarkBytes {
      DynamicGraph.weightsStreamingWatermarkBytes = weightsStreamingWatermarkBytes
    }
    defer { DynamicGraph.weightsStreamingWatermarkBytes = originalWeightsStreamingWatermarkBytes }
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
    let shouldRestore = kvCache.layers.isEmpty
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
    var hasher = ContextCachePrefixHasher(modelFilePath: filePath)
    let restoredTokenLength =
      shouldRestore
      ? contextCache.restore(
        graph: graph, tokens: contextTokens, configuration: configuration, kvCache: &kvCache,
        hasher: &hasher, embeddingSpans: embedSpans) : 0
    let checkpointStride = contextCache.checkpointStride
    // Saves the snapshot when the cache reaches a checkpoint. During decode, the context so far is
    // `contextTokens` and `generated`, once the fed token is appended to it.
    func saveCheckpoint(generated: [Int32] = []) {
      guard !kvCache.hasPaddedImages, kvCache.tokenLength.isMultiple(of: checkpointStride),
        contextTokens.count + generated.count >= kvCache.tokenLength
      else { return }
      contextCache.save(
        graph: graph, tokens: contextTokens + generated, checkpointLength: kvCache.tokenLength,
        configuration: configuration, kvCache: kvCache, hasher: &hasher,
        embeddingSpans: embedSpans)
    }
    let emptyTokens = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Int32.self)
    let emptyInjected = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Float16.self)
    let draft = Inkling2SmallDSparkConfiguration.inkling2Mini
    // Building the decoder settles whether this load drafts.
    let decoder = storage.decoder
    let isDrafting = storage.isDrafting
    // A window layer holds windowRows zero or kept rows, then at most a prefill chunk, or a
    // draft's main rows, and the block after them.
    let draftLocalRows =
      2 * draft.windowRows + max(chunkedPrefillMaxLength, draft.blockSize) + draft.blockSize
    if isDrafting {
      Self.resizeDraftCaches(
        graph: graph, kvCache: &kvCache, globalRows: cacheCapacity + draft.blockSize,
        localRows: draftLocalRows, configuration: configuration)
    } else {
      // A session continued from a load that drafted keeps no drafter state into this one.
      kvCache.draftKeys = []
      kvCache.draftValues = []
      kvCache.draftMainFeatures = nil
      kvCache.draftOpenPrefix = nil
    }
    // Tensor.toGPU waits for the GPU, so copies to it run on the stream instead, from CPU tensors
    // kept here until the join after them.
    var tensorsToGPU = [DynamicGraph.AnyTensor]()
    // The drafter's rotary rows, built when a draft would run past them.
    var rotaryStart = 0
    var rotary: DynamicGraph.Tensor<Float16>?
    func draftRotary(rows: Int, firstPosition: Int) -> DynamicGraph.Tensor<Float16> {
      if rotary.map({
        firstPosition < rotaryStart || firstPosition + rows > rotaryStart + $0.shape[0]
      }) ?? true {
        rotaryStart = firstPosition
        let rotarySource = graph.variable(
          Inkling2SmallDSparkRotaryEmbedding(
            rows: max(8_192, rows), firstPosition: firstPosition, draft: draft, of: Float16.self))
        tensorsToGPU.append(rotarySource)
        rotary = rotarySource.toGPU(0)
      }
      return rotary![
        (firstPosition - rotaryStart)..<(firstPosition - rotaryStart + rows), 0..<draft.headDim
      ].copied()
    }
    // A graph builds again only when its input shapes change, so a new place in the caches, or a
    // new temperature, compiles the drafter's graphs explicitly.
    var drafterKey: (mainRows: Int, globalRow: Int, localOffset: Int, temperature: Float)?
    var draftContextKey: (rows: Int, globalRow: Int, localRow: Int)?
    // The drafter's min-p windows (in logits) while thinking and for answers; a greedy draft takes
    // either.
    let minPWindows = (isDrafting ? [4.605_170_2, 2.097_012_5] : []).map { (window: Float) in
      graph.variable(Tensor<Float>([window], kind: .CPU, format: .NHWC, shape: [1, 1]).toGPU(0))
    }
    // Draft masks by [main rows, kept rows, closed window rows]; past the first windowRows
    // positions only the first two vary.
    var draftMasks = [[Int]: DynamicGraph.Tensor<Float16>]()
    // Before a window layer writes through `end`, moves its windowRows positions before `first`
    // back to its start when the rows would run past its end.
    func makeDraftRoom(through end: Int, keepingFrom first: Int) {
      guard end - kvCache.draftLocalStart > draftLocalRows else { return }
      let from = first - draft.windowRows - kvCache.draftLocalStart
      let width = draft.keyValueWidth
      for layer in 0..<draft.layers where draft.isLocal(layer) {
        for var cache in [kvCache.draftKeys[layer], kvCache.draftValues[layer]] {
          let kept = cache[from..<(from + draft.windowRows), 0..<width].copied()
          cache[0..<draft.windowRows, 0..<width] = kept
        }
      }
      kvCache.draftLocalStart = first - draft.windowRows
    }
    // The drafter's keys and values of `rows` committed positions from their target features.
    func writeDraftContext(features: DynamicGraph.Tensor<Float16>, rows: Int, firstPosition: Int) {
      makeDraftRoom(through: firstPosition + rows, keepingFrom: firstPosition)
      let key = (
        rows: rows, globalRow: firstPosition, localRow: firstPosition - kvCache.draftLocalStart
      )
      let inputs: [DynamicGraph.AnyTensor] =
        [features, draftRotary(rows: rows, firstPosition: firstPosition)]
        + Self.draftCacheInputs(kvCache)
      if draftContextKey.map({ $0 != key }) ?? true {
        draftContextKey = key
        storage.draftContext.compile(key, inputs: inputs)
      }
      _ = storage.draftContext(key, inputs: inputs[0], Array(inputs.dropFirst()))
    }

    // Inputs after the tokens: the image rows that follow them and the tokens after those, the
    // full-attention log scales, then per layer application its caches bound from their first row
    // through this chunk's rows, its convolution rows, and the buffers their next rows go to, which
    // a verify of `verifyRows` rows fills with the rows after each of its tokens.
    func modelInputs(
      injected: DynamicGraph.Tensor<Float16>, postTokens: DynamicGraph.Tensor<Int32>,
      cachedTokenLength: Int, tokenLength: Int, logScale: DynamicGraph.Tensor<Float16>,
      verifyRows: Int = 0
    )
      -> [DynamicGraph.AnyTensor]
    {
      var inputs: [DynamicGraph.AnyTensor] = [injected, postTokens, logScale]
      let kvDim = configuration.keyValueDim
      for (layerIndex, layer) in kvCache.layers.enumerated() {
        let isFull = configuration.isFullAttention(application: layerIndex)
        let rows = (isFull ? cachedTokenLength : kvCache.slidingTokenLength) + tokenLength
        let capacity = layer.keys.shape[1]
        for cache in [layer.keys, layer.values] {
          inputs.append(
            cache.reshaped(
              .NHWC(1, rows, configuration.keyValueHeads, configuration.headDim),
              strides: [capacity * kvDim, kvDim, configuration.headDim, 1]))
        }
        // The current rows bind whole, so a new offset never outgrows the tensor arena; the graph
        // reads them `convolutionOffset` rows in.
        inputs += Array(layer.convolutionRows[..<4])
        for (index, buffer) in layer.convolutionRows.enumerated() where index >= 4 {
          let dim = index % 4 < 2 ? kvDim : configuration.hiddenSize
          let bound = configuration.convolutionKernel - 1 + max(0, verifyRows - 1)
          inputs.append(
            index % 4 < 2
              ? buffer.as(of: Float16.self).reshaped(.NHWC(1, bound, 1, dim))
              : buffer.as(of: Float.self).reshaped(.NHWC(1, bound, 1, dim)))
        }
      }
      return inputs
    }
    // Uploaded before it becomes a variable: on a stream, a transfer inside the graph would
    // read the CPU tensor after it is gone.
    func logScale(cachedTokenLength: Int, tokenLength: Int) -> DynamicGraph.Tensor<Float16> {
      graph.variable(
        Inkling2MiniLogScale(
          Float16.self, cachedTokenLength: cachedTokenLength, tokenLength: tokenLength,
          configuration: configuration
        ).toGPU(0))
    }
    // Moves a full sliding-window cache's window back to its start.
    func makeRoom(for count: Int) {
      guard kvCache.slidingTokenLength + count > slidingCapacity else { return }
      let slidingRows = kvCache.slidingTokenLength
      for layerIndex in kvCache.layers.indices
      where !configuration.isFullAttention(application: layerIndex) {
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
    // After a call keeps `count` rows, its next convolution rows become the current ones; a
    // verify's start at the rows after the last kept token.
    func advance(by count: Int, convolutionOffset: Int = 0) {
      kvCache.tokenLength += count
      kvCache.slidingTokenLength += count
      kvCache.convolutionOffset = convolutionOffset
      for layerIndex in kvCache.layers.indices {
        let rows = kvCache.layers[layerIndex].convolutionRows
        kvCache.layers[layerIndex].convolutionRows = Array(rows[4...] + rows[..<4])
      }
    }

    // Compile the largest prefill chunk with full cache visibility for the current capacity, so
    // later chunks and decode steps reuse what it reserves. A drafting load also reserves a
    // verify's logit rows and convolution rows: a call that outgrows the reservation plans its
    // own, which later calls outgrow again.
    func compilePrefillHeadroom(cacheCapacity: Int, isEager: Bool = true) {
      let count = min(chunkedPrefillMaxLength, cacheCapacity)
      let cached = cacheCapacity - count
      let sliding = min(slidingCapacity, cacheCapacity) - count
      let slidingTokenLength = kvCache.slidingTokenLength
      kvCache.slidingTokenLength = sliding
      defer { kvCache.slidingTokenLength = slidingTokenLength }
      let logits = isDrafting ? min(draft.blockSize, count) : 1
      decoder.compile(
        (
          cached: cached, sliding: sliding, count: count, logits: logits,
          convolutionOffset: kvCache.convolutionOffset
        ),
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
            logScale: logScale(cachedTokenLength: cached, tokenLength: count),
            verifyRows: isDrafting ? logits : 0),
        isEager: isEager)
    }
    // The same for the drafter: the most main rows, at the end of its caches. Those rows are written
    // again before any draft reads them.
    func compileDraftHeadroom(isEager: Bool = true) {
      let block = draft.blockSize
      let width = draft.targetLayers.count * configuration.hiddenSize
      let globalRow = kvCache.draftKeys[draft.layers / 2].shape[0] - 2 * block
      let standIns: [DynamicGraph.AnyTensor] = [
        graph.variable(.GPU(0), .WC(block, width), of: Float16.self),
        graph.variable(.GPU(0), .WC(1, width), of: Float16.self),
        graph.variable(.GPU(0), .WC(block, draft.headDim), of: Float16.self),
        graph.variable(.GPU(0), format: .NHWC, shape: [1], of: Int32.self),
        graph.variable(.GPU(0), .WC(block, draft.headDim), of: Float16.self),
        graph.variable(
          .GPU(0), .NHWC(1, 1, block, draft.windowRows + 2 * block), of: Float16.self),
      ]
      for standIn in standIns {
        if let standIn = standIn as? DynamicGraph.Tensor<Float16> {
          standIn.full(0)
        } else if let standIn = standIn as? DynamicGraph.Tensor<Int32> {
          standIn.full(0)
        }
      }
      let key = (
        mainRows: block, globalRow: globalRow,
        localOffset: draftLocalRows - draft.windowRows - 2 * block, temperature: Float(0)
      )
      drafterKey = key
      storage.drafter.compile(
        key,
        inputs: standIns + [
          kvCache.draftOpenPrefix!.reshaped(format: .NHWC, shape: [1, 1, block, globalRow]),
          minPWindows[1],
        ] + Self.draftCacheInputs(kvCache), isEager: isEager)
    }

    if !storage.decoderIsLoaded {
      compilePrefillHeadroom(cacheCapacity: cacheCapacity, isEager: false)
      let streamingConfiguration = configuration
      // Streamed expert banks stay out of the pinned whole-file mapping.
      DynamicGraph.setWholeFileMappingSizeLimit(
        Inkling2MiniResidentMappingSize(
          checkpoint: filePath, configuration: streamingConfiguration))
      let result = try? graph.openStore(filePath, flags: .readOnly) { store in
        try store.read(
          "text_model", model: decoder, strict: true,
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
      decoder.pinMemory = true
      storage.decoderIsLoaded = true
    }
    if isDrafting, let drafterFile, !storage.drafterIsLoaded {
      compileDraftHeadroom(isEager: false)
      let drafterResult = try? graph.openStore(drafterFile, flags: .readOnly) { store in
        try store.read(
          "text_model", model: storage.drafter,
          codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)]
        ) {
          name, _, _, _ in
          // The drafter reads this model's embedding and head, shared below.
          name.hasSuffix("[t-embed_tokens-0-0]") || name.hasSuffix("[t-lm_head-0-0]")
            ? .fail : .continue(name)
        }
      }
      guard let drafterResult, (try? drafterResult.get()) != nil else { return [] }
      storage.drafter.parameters.share(from: decoder.parameters) { name, _ in
        name.contains("t-embed_tokens-0-0") || name.contains("t-lm_head-0-0")
          ? .continue(name) : .fail
      }
      storage.draftContext.compile(
        (rows: 1, globalRow: 0, localRow: draft.windowRows),
        inputs: [
          graph.variable(
            .GPU(0), .WC(1, draft.targetLayers.count * configuration.hiddenSize),
            of: Float16.self),
          graph.variable(.GPU(0), .WC(1, draft.headDim), of: Float16.self),
        ] + Self.draftCacheInputs(kvCache), isEager: false)
      draftContextKey = (rows: 1, globalRow: 0, localRow: draft.windowRows)
      let contextResult = try? graph.openStore(drafterFile, flags: .readOnly) { store in
        try store.read(
          "text_model", model: storage.draftContext, strict: true,
          codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)])
      }
      guard let contextResult, (try? contextResult.get()) != nil else { return [] }
      storage.drafter.pinMemory = true
      storage.draftContext.pinMemory = true
      storage.drafterIsLoaded = true
    }
    compilePrefillHeadroom(cacheCapacity: cacheCapacity)
    if isDrafting {
      compileDraftHeadroom()
    }

    var thinkingPhase = Inkling2SmallTextGenerator.ThinkingPhase(
      budget: thinkingBudget, contextTokens: contextTokens)
    let endThinkingTokenCPU = graph.variable(
      Tensor<Int32>([Self.endThinkToken], kind: .CPU, format: .NHWC, shape: [1]))
    // Uploaded the first time a reply can't think.
    var thinkingExclusion: DynamicGraph.Tensor<Float16>?
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
              print("Warning: Inkling 2 Mini image digest mismatch at \(path).")
            }
            if image.tokenCount == span.length {
              encodedImages[span.digest] = encodeImage(graph: graph, image: image)
            } else {
              print(
                "Warning: Inkling 2 Mini image token count changed from \(span.length) to \(image.tokenCount) at \(path)."
              )
            }
          }
        }
        if encodedImages[span.digest] == nil {
          print(
            "Warning: Inkling 2 Mini image at token \(span.start) is unavailable; using image placeholder tokens."
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
    // Positions a previous call committed after the drafter's last write.
    if let mainFeatures = kvCache.draftMainFeatures {
      let kept = kvCache.draftMainKept
      writeDraftContext(
        features: mainFeatures[0..<kept, 0..<mainFeatures.shape[1]].copied(), rows: kept,
        firstPosition: kvCache.draftMainStart)
      kvCache.draftMainFeatures = nil
    }

    var prefillTokenCPU: DynamicGraph.Tensor<Int32>?
    // A restore needs an empty cache, so the context starts at 0 and one token stays to prefill.
    var prefillChunkStart = restoredTokenLength
    // With the context restored and the weights loaded, before the timed prefill.
    guard continuationHandler(prefillChunkStart, tokenLength, [], statistics) == .continue else {
      return []
    }
    let initialPrefillDurationSoFar =
      recentInteractionStatistics[interactionStatisticsIndex].prefillDurationSoFar
    let prefillStartTime = CACurrentMediaTime()
    while prefillChunkStart < tokenLength {
      let start = prefillChunkStart
      let position = tokenOffset + start
      // A chunk never crosses a checkpoint.
      let nextCheckpoint = (position / checkpointStride + 1) * checkpointStride
      var end =
        position + min(chunkedPrefillMaxLength, tokenLength - start, nextCheckpoint - position)
      encodeImages(overlapping: position..<end)
      // A chunk holds at most one image, with text rows before and after it, the order
      // Inkling2MiniCausalLM takes, so it ends where the next image starts. Unavailable images
      // stay text rows.
      let images = embedSpans.filter {
        Int($0.start) < end && Int($0.end) > position && encodedImages[$0.digest] != nil
      }.sorted { $0.start < $1.start }
      if images.count > 1 { end = Int(images[1].start) }
      if embedSpans.contains(where: {
        Int($0.start) < end && Int($0.end) > position && unavailableImages.contains($0.digest)
      }) {
        kvCache.hasPaddedImages = true
      }
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
      let prefillOutputs = decoder(
        (
          cached: position, sliding: kvCache.slidingTokenLength, count: length, logits: 1,
          convolutionOffset: kvCache.convolutionOffset
        ),
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
      saveCheckpoint()
      if isDrafting {
        // The drafter's target features of the chunk's rows come last.
        let features = prefillOutputs[prefillOutputs.count - 1].as(of: Float16.self)
        writeDraftContext(features: features, rows: length, firstPosition: position)
        if start + length == tokenLength {
          // The first draft rewrites the last position from its target features.
          let width = features.shape[1]
          kvCache.draftMainFeatures = features.reshaped(
            .WC(1, width), offset: [length - 1, 0], strides: [width, 1]
          ).copied()
          kvCache.draftMainKept = 1
          kvCache.draftMainStart = position + length - 1
        }
      }
      if start + length == tokenLength {
        if thinkingPhase.shouldEndThinking {
          prefillTokenCPU = endThinkingTokenCPU
        } else {
          // The last chunk's logits pick the first generated token, under the sampling mode of the
          // phase that has read every token before it.
          let logits = prefillOutputs[0].as(of: Float16.self)
          if thinkingPhase.excludesThinking {
            let exclusion =
              thinkingExclusion
              ?? graph.variable(
                Tensor<Float16>([-Float16.infinity], kind: .CPU, format: .NHWC, shape: [1, 1])
                  .toGPU(0))
            thinkingExclusion = exclusion
            let token = Int(Self.thinkingContentToken)
            var excluded = logits
            excluded[0..<1, token..<(token + 1)] = exclusion
          }
          if let sampling = Self.sampling(phase: thinkingPhase, deterministic: deterministic) {
            logits.fill(
              -Float.infinity, if: logits < (logits.reduced(.max, axis: [1]) - sampling.window))
            prefillTokenCPU = Functional.gumbelArgmax(
              logits, axis: 1, scale: sampling.temperature
            ).reshaped(format: .NHWC, shape: [1]).toCPU()
          } else {
            prefillTokenCPU = Functional.argmax(logits, axis: 1).reshaped(
              format: .NHWC, shape: [1]
            ).toCPU()
          }
        }
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
    thinkingPhase.append(firstToken)
    var decodeIndex = 0
    let initialTokenGenerationDurationSoFar =
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar
    let tokenGenerationStartTime = CACurrentMediaTime()
    defer {
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
    }
    // A step feeds the pending token and, when the drafter drafted a block after it, the drafts
    // expected to pay in the same call, and keeps the drafts the target reproduces: greedily, or by
    // speculative sampling against the drafter's own distribution, where draft d stays with
    // probability min(1, p(d) / q(d)) and the first rejected one samples max(0, p - q) instead. A
    // step without drafts feeds its pick to the next step from the GPU, and reads the token it fed
    // once its call is queued, so the GPU never waits on the CPU.
    let block = draft.blockSize
    // Under weights streaming a step verifies at most 4 rows, as Inkling 2 Small's: every row adds
    // its pool misses, so rows past that gain little.
    let verifyRowLimit =
      configuration.expertResidentSlots.contains { $0 < configuration.expertCount } ? 4 : block
    let vocabulary = configuration.unpaddedVocabularySize
    // Wall milliseconds of a verify by its rows and of a draft, from measured priors (M5 Ultra,
    // inkling_2_mini_i3x_imatrix_gu_lgain_trailer.ckpt: a serial step takes about 11.7).
    var verifyMilliseconds: [Double] = [0, 12, 14, 16, 18, 21, 23, 25, 26]
    var draftMilliseconds = 6.0
    var compileMilliseconds = 4.0
    var lastVerifyRows = verifyRowLimit
    // Stand-ins for a verify's tokens, and a draft's anchor and mask, to build their graphs ahead
    // with.
    let verifyStandIn = graph.variable(.GPU(0), format: .NHWC, shape: [block], of: Int32.self)
    let maskStandIn = graph.variable(
      .GPU(0), .NHWC(1, 1, block, draft.windowRows + 2 * block), of: Float16.self)
    // A drafted position's top probability is not calibrated, so, as GLM5_3TextGenerator does,
    // acceptance is learned by tenths of it online: a draft's chance to be kept given that every
    // draft before it was. Counts decay so the estimate follows the text.
    var binKept = [Double](repeating: 0, count: 10)
    var binSeen = [Double](repeating: 0, count: 10)
    // Drafting parks while it falls behind serial steps: once drafted rounds, on decaying averages,
    // take longer per token than a parked step, the next parkedStretch steps run serial, still
    // writing the drafter's context, and the last hands its pick to a drafted round that probes
    // whether drafting has recovered. The averages start in drafting's favor, so the slow first
    // rounds that build graphs don't park a reply. Parking reads only the rounds before, so whether a
    // draft is verified still never depends on its value.
    let parkedStretch = 32
    var roundTokens = 6.0
    var roundMilliseconds = 24.0
    // A parked step's wall milliseconds, from the last stretch; the prior is a serial step's.
    var parkedMilliseconds = 12.0
    var parkedSteps = 0
    var parkedSince = 0.0
    // The pending token when a step knows it on the CPU: the first one, a forced end of thinking,
    // each pick of a step that drafted and did not park, and a parked stretch's last.
    var pendingCPU: Int32? = firstToken
    lastDraftAcceptance = (rounds: 0, kept: 0)
    while decodeIndex < decodeTokenCapacity {
      let stepStart = CACurrentMediaTime()
      // The pending token follows every token the phase has read; the first is already read.
      if decodeIndex > 0, thinkingPhase.shouldEndThinking {
        nextTokenGPU = endThinkingTokenCPU.toGPU(0)
        pendingCPU = Self.endThinkToken
      }
      if kvCache.tokenLength + (isDrafting ? block : 1) > cacheCapacity
        && cacheCapacity < Self.maximumContextLength
      {
        cacheCapacity = min(
          cacheCapacity + self.compilePrefillHeadroom, Self.maximumContextLength)
        Self.resizeCaches(
          graph: graph, kvCache: &kvCache, cacheCapacity: cacheCapacity,
          slidingCapacity: slidingCapacity, configuration: configuration)
        if isDrafting {
          Self.resizeDraftCaches(
            graph: graph, kvCache: &kvCache, globalRows: cacheCapacity + block,
            localRows: draftLocalRows, configuration: configuration)
        }
        decodeLogScaleStart = kvCache.tokenLength
        decodeLogScales = logScale(
          cachedTokenLength: decodeLogScaleStart, tokenLength: cacheCapacity - decodeLogScaleStart)
        compilePrefillHeadroom(cacheCapacity: cacheCapacity)
        if isDrafting {
          compileDraftHeadroom()
        }
      }
      let position = kvCache.tokenLength
      makeRoom(for: isDrafting ? block : 1)
      let pendingRead = pendingCPU == nil ? nextTokenGPU.toCPU() : nil
      // The phase once the pending token is read decides the sampling mode of every row the step
      // feeds, which the drafter drafts with too. The first pending token is in it already.
      var phase = thinkingPhase
      if decodeIndex > 0, let pendingCPU {
        phase.append(pendingCPU)
      }
      var rows = 1
      // The drafted tokens on the GPU and the CPU, the logits they were drawn from, the tenth of each
      // one's top probability, and how many of them the step verifies.
      var drafted:
        (
          tokens: DynamicGraph.Tensor<Int32>, cpu: DynamicGraph.Tensor<Int32>,
          logits: DynamicGraph.Tensor<Float>, bins: [Int], verified: Int
        )?
      var preparedRows: Int?
      // The drafter drafts a block from the pending token on the CPU, after the rows the last call
      // fed: the rows a verify evaluated, or the last prefill row. The block takes the position of
      // the first row the verify did not keep. View column c of a window layer holds position
      // mainStart - windowRows + c; the mask closes the main rows the verify did not keep and the
      // positions before the windowRows ones before the block. The end of sequence is fed alone.
      if let mainFeatures = kvCache.draftMainFeatures, let pending = pendingCPU,
        !Self.eosTokenIds.contains(pending)
      {
        let mainStart = kvCache.draftMainStart
        let mainRows = mainFeatures.shape[0]
        let mainKept = kvCache.draftMainKept
        let width = mainFeatures.shape[1]
        makeDraftRoom(through: mainStart + mainRows + block, keepingFrom: mainStart)
        let localOffset = mainStart - kvCache.draftLocalStart - draft.windowRows
        let viewRows = draft.windowRows + mainRows + block
        let closed = max(mainKept, draft.windowRows - mainStart)
        let maskKey = [mainRows, mainKept, closed]
        let mask: DynamicGraph.Tensor<Float16>
        if let cachedMask = draftMasks[maskKey] {
          mask = cachedMask
        } else {
          var values = [Float16](repeating: 0, count: block * viewRows)
          for row in 0..<block {
            for column in Array(0..<closed)
              + Array((draft.windowRows + mainKept)..<(draft.windowRows + mainRows))
            {
              values[row * viewRows + column] = -Float16.infinity
            }
          }
          let maskSource = graph.variable(
            Tensor(values, kind: .CPU, format: .NHWC, shape: [1, 1, block, viewRows]))
          tensorsToGPU.append(maskSource)
          mask = maskSource.toGPU(0)
          if closed == mainKept { draftMasks[maskKey] = mask }
        }
        let draftInputs: [DynamicGraph.AnyTensor] =
          [
            mainFeatures, mainFeatures[(mainKept - 1)..<mainKept, 0..<width].copied(),
            draftRotary(rows: mainRows, firstPosition: mainStart), nextTokenGPU,
            draftRotary(rows: block, firstPosition: position), mask,
            kvCache.draftOpenPrefix!.reshaped(format: .NHWC, shape: [1, 1, block, mainStart]),
            minPWindows[phase.isEnded ? 1 : 0],
          ] + Self.draftCacheInputs(kvCache)
        let draftStart = CACurrentMediaTime()
        // The last call built this draft's graph, unless the draft is the first or its mode
        // changed.
        let key = (
          mainRows: mainRows, globalRow: mainStart, localOffset: localOffset,
          temperature: Self.sampling(phase: phase, deterministic: deterministic)?.temperature ?? 0
        )
        if drafterKey.map({ $0 != key }) ?? true {
          drafterKey = key
          storage.drafter.compile(key, inputs: draftInputs)
        }
        // The layer that sees every position attends a longer view each draft, so its masked
        // attention reads the key length instead of compiling a kernel for each.
        let flags = DynamicGraph.flags
        DynamicGraph.flags.insert(.disableMFAAttentionSpecializingC)
        let draftOutputs = storage.drafter(
          key, inputs: draftInputs[0], Array(draftInputs.dropFirst()))
        DynamicGraph.flags = flags
        let draftTokens = draftOutputs[0].as(of: Int32.self)
        let draftsCPU = draftTokens.toCPU()
        let partitions = draftOutputs[2].as(of: Float.self).toCPU()
        // A step never crosses a context-cache checkpoint, so the cache lands on each one.
        let nextCheckpoint = (position / checkpointStride + 1) * checkpointStride
        let maximumRows = min(
          verifyRowLimit, decodeTokenCapacity - decodeIndex, cacheCapacity - position,
          nextCheckpoint - position)
        // While the draft runs, build the verify at the rows the last one took: a verify of the
        // same rows then runs without building its graph.
        if lastVerifyRows <= maximumRows {
          decoder.compile(
            (
              cached: position, sliding: kvCache.slidingTokenLength, count: lastVerifyRows,
              logits: lastVerifyRows, convolutionOffset: kvCache.convolutionOffset
            ),
            inputs: [verifyStandIn.reshaped(format: .NHWC, shape: [lastVerifyRows])]
              + modelInputs(
                injected: emptyInjected, postTokens: emptyTokens, cachedTokenLength: position,
                tokenLength: lastVerifyRows,
                logScale: decodeLogScales.reshaped(
                  format: .NHWC, shape: [lastVerifyRows, 1],
                  offset: [position - decodeLogScaleStart, 0], strides: [1, 1]),
                verifyRows: lastVerifyRows))
          preparedRows = lastVerifyRows
        }
        withExtendedLifetime(tensorsToGPU) { partitions.joined() }
        tensorsToGPU = []
        draftMilliseconds =
          0.8 * draftMilliseconds
          + 0.2 * min(1000 * (CACurrentMediaTime() - draftStart), 2 * draftMilliseconds)
        // A position's top probability is 1 / its partition.
        let bins = (0..<draft.proposals).map {
          min(9, max(0, Int(10 / Double(partitions[$0, 0]))))
        }
        // Verify the pending token and the drafts that maximize the expected tokens per
        // millisecond. A draft is kept only if every one before it is, so E(rows) = 1 + the sum of
        // the running products of their chances. Rows are added one draft at a time, each on its
        // own chance, from its position's top probability, which depends only on the drafts before
        // it: whether a draft is verified never depends on its value, as exact sampling needs.
        // Later drafts are taken to be as likely as the one being added.
        func milliseconds(_ rows: Int) -> Double {
          verifyMilliseconds[rows] + draftMilliseconds
            + (preparedRows == rows ? 0 : compileMilliseconds)
        }
        var expected = 1.0
        var prefix = 1.0
        var rate = expected / milliseconds(1)
        if maximumRows > 1 {
          for candidate in 2...maximumRows {
            let bin = bins[candidate - 2]
            let probability = (binKept[bin] + 4 * (Double(bin) + 0.5) / 10) / (binSeen[bin] + 4)
            var projectedExpected = expected
            var projectedPrefix = prefix
            var projectedRate = 0.0
            for length in candidate...maximumRows {
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
        // One sampling mode a step: the step feeds drafts only while they leave the phase as it is.
        // A draft that opens or ends thinking, opens a model message, or spends the thinking budget
        // is the last one the step verifies, at its last row under the step's mode, like any draft,
        // and the next step feeds it, as DeepSeek4_1TextGenerator does a drafted end of thinking.
        // Whether a draft is verified then still never depends on its value.
        var verified = rows - 1
        var unchanged = phase
        for index in 0..<(rows - 1) {
          var next = unchanged
          next.append(draftsCPU[index])
          guard next.isEnded == unchanged.isEnded, next.isThinking == unchanged.isThinking,
            !next.excludesThinking, !next.shouldEndThinking
          else {
            rows = index + 1
            verified = rows
            break
          }
          unchanged = next
        }
        if phase.shouldEndThinking {
          // The budget ends thinking right after the pending token, which the next step forces.
          rows = 1
          verified = 0
        }
        drafted = (draftTokens, draftsCPU, draftOutputs[1].as(of: Float.self), bins, verified)
      } else if let mainFeatures = kvCache.draftMainFeatures {
        // No draft writes the main rows' keys and values, so the kept ones go in now.
        let kept = kvCache.draftMainKept
        writeDraftContext(
          features: mainFeatures[0..<kept, 0..<mainFeatures.shape[1]].copied(), rows: kept,
          firstPosition: kvCache.draftMainStart)
      }

      let drafts = rows - 1
      var tokens = nextTokenGPU
      if let drafted, drafts > 0 {
        tokens = graph.variable(.GPU(0), format: .NHWC, shape: [rows], of: Int32.self)
        tokens[0..<1] = nextTokenGPU
        tokens[1..<rows] = drafted.tokens[0..<drafts]
      }
      let key = (
        cached: position, sliding: kvCache.slidingTokenLength, count: rows, logits: rows,
        convolutionOffset: kvCache.convolutionOffset
      )
      let inputs = modelInputs(
        injected: emptyInjected, postTokens: emptyTokens, cachedTokenLength: position,
        tokenLength: rows,
        logScale: decodeLogScales.reshaped(
          format: .NHWC, shape: [rows, 1], offset: [position - decodeLogScaleStart, 0],
          strides: [1, 1]
        ).copied(), verifyRows: rows)
      if drafted != nil {
        if preparedRows != rows {
          let compileStart = CACurrentMediaTime()
          decoder.compile(key, inputs: [tokens] + inputs)
          compileMilliseconds =
            0.8 * compileMilliseconds
            + 0.2 * min(1000 * (CACurrentMediaTime() - compileStart), 2 * compileMilliseconds)
        }
        lastVerifyRows = rows
      }
      let callStart = CACurrentMediaTime()
      let outputs = decoder(key, inputs: tokens, inputs)
      let logits = outputs[0].as(of: Float16.self)
      // The drafter's target features of the rows fed, which come last.
      let features = isDrafting ? outputs[outputs.count - 1].as(of: Float16.self) : nil
      let pending = pendingCPU ?? pendingRead![0]
      if decodeIndex > 0, pendingCPU == nil {
        phase.append(pending)
      }
      let sampling = Self.sampling(phase: phase, deterministic: deterministic)
      if drafted != nil, let features {
        // While the call runs, make room for the next draft and build its graph: its main rows are
        // this call's, whatever it keeps.
        makeDraftRoom(through: position + rows + block, keepingFrom: position)
        let nextKey = (
          mainRows: rows, globalRow: position,
          localOffset: position - kvCache.draftLocalStart - draft.windowRows,
          temperature: sampling?.temperature ?? 0
        )
        if drafterKey.map({ $0 != nextKey }) ?? true {
          drafterKey = nextKey
          storage.drafter.compile(
            nextKey,
            inputs: [
              features,
              features[(rows - 1)..<rows, 0..<features.shape[1]].copied(),
              draftRotary(rows: rows, firstPosition: position),
              verifyStandIn.reshaped(format: .NHWC, shape: [1]),
              draftRotary(rows: block, firstPosition: position),
              maskStandIn.reshaped(.NHWC(1, 1, block, draft.windowRows + rows + block)),
              kvCache.draftOpenPrefix!.reshaped(format: .NHWC, shape: [1, 1, block, position]),
              minPWindows[phase.isEnded ? 1 : 0],
            ] + Self.draftCacheInputs(kvCache))
        }
      }
      if phase.excludesThinking {
        // A model message the pending token opens can't be the thinking one.
        if thinkingExclusion == nil {
          let exclusionSource = graph.variable(
            Tensor<Float16>([-Float16.infinity], kind: .CPU, format: .NHWC, shape: [1, 1]))
          tensorsToGPU.append(exclusionSource)
          thinkingExclusion = exclusionSource.toGPU(0)
        }
        let token = Int(Self.thinkingContentToken)
        var excluded = logits
        excluded[0..<1, token..<(token + 1)] = thinkingExclusion!
      }
      // The target's pick at each row: greedily every row's; or sampled, the verified drafts by
      // speculative sampling through the first rejected one, then, when they all stay and the last
      // row verifies none, its own sample.
      var picks = [Int32]()
      var isRejected = false
      let selected: DynamicGraph.Tensor<Int32>
      if let sampling {
        let target = DynamicGraph.Tensor<Float>(from: logits)
        target.fill(
          -Float.infinity, if: target < (target.reduced(.max, axis: [1]) - sampling.window))
        selected = Functional.gumbelArgmax(
          target.reshaped(.WC(1, vocabulary), offset: [drafts, 0], strides: [vocabulary, 1]),
          axis: 1, scale: sampling.temperature)
        if let drafted, drafted.verified > 0 {
          let verified = drafted.verified
          // softmax(logits / temperature) by rows, from exponentials and their sums: the softmax
          // command takes tens of milliseconds over rows this long.
          func probabilities(_ logits: DynamicGraph.Tensor<Float>) -> DynamicGraph.Tensor<Float> {
            let scaled = logits * (1 / sampling.temperature)
            let centered: DynamicGraph.Tensor<Float> = scaled - scaled.reduced(.max, axis: [1])
            let partitions = Functional.exp(centered).reduced(.sum, axis: [1])
            return Functional.exp(centered - Functional.log(partitions))
          }
          let p = probabilities(
            target.reshaped(.WC(verified, vocabulary), offset: [0, 0], strides: [vocabulary, 1]))
          let biased = drafted.logits.reshaped(
            .WC(verified, vocabulary), offset: [0, 0], strides: [vocabulary, 1]
          ).copied()
          biased.fill(
            -Float.infinity, if: biased < (biased.reduced(.max, axis: [1]) - sampling.window))
          let q = probabilities(biased)
          let indexSource = graph.variable(
            Tensor<Int32>(
              (0..<verified).map { Int32($0 * vocabulary) + drafted.cpu[$0] }, kind: .CPU,
              format: .NHWC, shape: [verified]))
          tensorsToGPU.append(indexSource)
          let index = indexSource.toGPU(0)
          let pDraft = Functional.indexSelect(
            input: p.reshaped(.WC(verified * vocabulary, 1)), index: index
          ).toCPU()
          let qDraft = Functional.indexSelect(
            input: q.reshaped(.WC(verified * vocabulary, 1)), index: index
          ).toCPU()
          let uniform = graph.variable(.GPU(0), format: .NHWC, shape: [verified], of: Float.self)
          uniform.rand(0...1)
          let uniformCPU = uniform.toCPU()
          let residual: DynamicGraph.Tensor<Float> = Functional.log(Functional.ReLU(p - q))
          let correction = Functional.gumbelArgmax(residual, axis: 1).toCPU()
          correction.joined()
          for row in 0..<verified {
            // Where p(d) > q(d) the draft always stays.
            if uniformCPU[row] * qDraft[row, 0] < pDraft[row, 0] {
              picks.append(drafted.cpu[row])
            } else {
              picks.append(correction[row, 0])
              isRejected = true
              break
            }
          }
        }
      } else {
        selected = Functional.argmax(logits, axis: 1)
      }
      // The fed drafts the step keeps, of the verified ones that stay.
      var kept = 0
      if let drafted {
        let selectedCPU = selected.toCPU()
        withExtendedLifetime(tensorsToGPU) { selectedCPU.joined() }
        tensorsToGPU = []
        if sampling == nil {
          picks = (0..<rows).map { selectedCPU[$0, 0] }
        } else if !isRejected && drafted.verified == drafts {
          picks.append(selectedCPU[0, 0])
        }
        // Samples are capped so a spike cannot price a length out for good.
        verifyMilliseconds[rows] =
          0.8 * verifyMilliseconds[rows]
          + 0.2 * min(1000 * (CACurrentMediaTime() - callStart), 2 * verifyMilliseconds[rows])
        var stayed = 0
        while stayed < drafted.verified && drafted.cpu[stayed] == picks[stayed] {
          stayed += 1
        }
        kept = min(stayed, drafts)
        for index in binKept.indices {
          binKept[index] *= 0.995
          binSeen[index] *= 0.995
        }
        for index in 0..<min(stayed + 1, drafted.verified) {
          binSeen[drafted.bins[index]] += 1
          if index < stayed { binKept[drafted.bins[index]] += 1 }
        }
      } else {
        nextTokenGPU = selected.reshaped(format: .NHWC, shape: [1])
      }

      // Keep the fed tokens through the last kept draft one at a time, through the end of sequence
      // or the one the caller stops at.
      var commitCount = 0
      for token in [pending] + (drafted.map { drafted in (0..<kept).map { drafted.cpu[$0] } } ?? [])
      {
        commitCount += 1
        // The first pending token is in generated already.
        guard decodeIndex + commitCount > 1 else { continue }
        generated.append(token)
        recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
        thinkingPhase.append(token)
        if Self.eosTokenIds.contains(token) {
          shouldAppendPendingToken = false
          break
        }
        recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
          Float(CACurrentMediaTime() - tokenGenerationStartTime)
          + initialTokenGenerationDurationSoFar
        switch continuationHandler(
          position + commitCount, position + commitCount, generated, statistics)
        {
        case .continue:
          break
        case .pause:
          shouldStopAfterSampling = true
        case .abort:
          shouldAppendPendingToken = false
        }
        if !shouldAppendPendingToken || shouldStopAfterSampling {
          break
        }
      }
      if drafted != nil {
        lastDraftAcceptance.rounds += 1
        lastDraftAcceptance.kept += commitCount - 1
      }
      // The committed rows, the convolution rows after the last of them, which the next call reads
      // where this one wrote them, and the fed rows' target features for the next draft.
      advance(by: commitCount, convolutionOffset: commitCount - 1)
      if let features {
        kvCache.draftMainFeatures = features
        kvCache.draftMainKept = commitCount
        kvCache.draftMainStart = position
      }
      saveCheckpoint(generated: generated)
      decodeIndex += commitCount
      guard shouldAppendPendingToken else { break }
      if drafted != nil {
        let tokenSource = graph.variable(
          Tensor<Int32>([picks[commitCount - 1]], kind: .CPU, format: .NHWC, shape: [1]))
        tensorsToGPU.append(tokenSource)
        nextTokenGPU = tokenSource.toGPU(0)
        roundTokens = 0.875 * roundTokens + 0.125 * Double(commitCount)
        roundMilliseconds =
          0.875 * roundMilliseconds + 0.125 * 1000 * (CACurrentMediaTime() - stepStart)
        if roundTokens * parkedMilliseconds < roundMilliseconds {
          // Park: serial steps take the pick from the GPU.
          pendingCPU = nil
          parkedSteps = 0
          parkedSince = CACurrentMediaTime()
        } else {
          // The next draft starts from this step's last pick, on the CPU.
          pendingCPU = picks[commitCount - 1]
        }
      } else if isDrafting, parkedSteps == parkedStretch - 1 {
        // The stretch's last step reads its pick, so the next step probes with a draft.
        pendingCPU = nextTokenGPU.toCPU()[0]
        parkedMilliseconds = 1000 * (CACurrentMediaTime() - parkedSince) / Double(parkedStretch)
      } else {
        parkedSteps += 1
        pendingCPU = nil
      }
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

  /// Each drafter layer's key and value caches, bound whole.
  static func draftCacheInputs(_ kvCache: KVCache) -> [DynamicGraph.AnyTensor] {
    zip(kvCache.draftKeys, kvCache.draftValues).flatMap { [$0, $1] as [DynamicGraph.AnyTensor] }
  }

  /// The sampling mode once `phase` has read the pending token: nil for an answer decoded greedily,
  /// else the temperature and the min-p window in logits: min-p 0.01 at temperature 1 while thinking,
  /// and 0.05 at 0.7 for an answer sampled creatively.
  private static func sampling(phase: Inkling2SmallTextGenerator.ThinkingPhase, deterministic: Bool)
    -> (
      temperature: Float, window: Float
    )?
  {
    let thinking = !phase.isEnded
    guard !deterministic || thinking else { return nil }
    return (deterministic || thinking ? 1 : 0.7, thinking ? 4.605_170_2 : 2.097_012_5)
  }

  /// The drafter's caches: `globalRows` rows for the layers that see every position, grown by
  /// copying, with the zeros that open their views; `localRows` for the window layers, whose first
  /// windowRows rows are zeros before position 0; and room in each target layer's convolution rows
  /// for the rows after every token of a verify of blockSize rows.
  private static func resizeDraftCaches(
    graph: DynamicGraph, kvCache: inout KVCache, globalRows: Int, localRows: Int,
    configuration: Inkling2MiniConfiguration
  ) {
    let draft = Inkling2SmallDSparkConfiguration.inkling2Mini
    let width = draft.keyValueWidth
    if (kvCache.draftOpenPrefix?.shape[1] ?? 0) < globalRows {
      let openPrefix = graph.variable(.GPU(0), .WC(draft.blockSize, globalRows), of: Float16.self)
      openPrefix.full(0)
      kvCache.draftOpenPrefix = openPrefix
    }
    guard !kvCache.draftKeys.isEmpty else {
      // The drafter starts at the cache's end: 0, or a restored context, or one decoded before the
      // drafter loaded, whose positions it has no keys or values for (zeros).
      kvCache.draftLocalStart = kvCache.tokenLength - draft.windowRows
      for layer in 0..<draft.layers {
        for _ in 0..<2 {
          let cache = graph.variable(
            .GPU(0), .WC(draft.isLocal(layer) ? localRows : globalRows, width), of: Float16.self)
          cache.full(0)
          if kvCache.draftKeys.count == layer {
            kvCache.draftKeys.append(cache)
          } else {
            kvCache.draftValues.append(cache)
          }
        }
      }
      let kernel = configuration.convolutionKernel
      let rows = kernel - 1 + draft.blockSize - 1
      for index in kvCache.layers.indices {
        kvCache.layers[index].convolutionRows = kvCache.layers[index].convolutionRows.enumerated()
          .map { buffer, existing in
            // A load that drafted grew these before; a session continued from it through loads that
            // did not keeps them, with the rows at convolutionOffset.
            guard existing.shape[1] < rows else { return existing }
            let dim = buffer % 4 < 2 ? configuration.keyValueDim : configuration.hiddenSize
            if buffer % 4 < 2 {
              var grown = graph.variable(.GPU(0), .NHWC(1, rows, 1, dim), of: Float16.self)
              grown.full(0)
              grown[0..<1, 0..<(kernel - 1), 0..<1, 0..<dim] = existing.as(of: Float16.self)
              return grown
            }
            var grown = graph.variable(.GPU(0), .NHWC(1, rows, 1, dim), of: Float.self)
            grown.full(0)
            grown[0..<1, 0..<(kernel - 1), 0..<1, 0..<dim] = existing.as(of: Float.self)
            return grown
          }
      }
      return
    }
    for layer in 0..<draft.layers where !draft.isLocal(layer) {
      let existing = kvCache.draftKeys[layer].shape[0]
      guard existing < globalRows else { continue }
      graph.joined()
      var keys = graph.variable(.GPU(0), .WC(globalRows, width), of: Float16.self)
      var values = graph.variable(.GPU(0), .WC(globalRows, width), of: Float16.self)
      keys.full(0)
      values.full(0)
      keys[0..<existing, 0..<width] = kvCache.draftKeys[layer]
      values[0..<existing, 0..<width] = kvCache.draftValues[layer]
      kvCache.draftKeys[layer] = keys
      kvCache.draftValues[layer] = values
    }
  }

  /// Full-attention caches hold `cacheCapacity` rows and grow by copying; sliding-window caches and
  /// convolution rows keep their size.
  static func resizeCaches(
    graph: DynamicGraph, kvCache: inout KVCache, cacheCapacity: Int, slidingCapacity: Int,
    configuration: Inkling2MiniConfiguration
  ) {
    let kernel = configuration.convolutionKernel
    let shape = { (rows: Int) in
      TensorShapeFormat.NHWC(1, rows, configuration.keyValueHeads, configuration.headDim)
    }
    guard !kvCache.layers.isEmpty else {
      graph.garbageCollect()
      kvCache.layers = (0..<configuration.layerApplications).map { layerIndex in
        let rows =
          configuration.isFullAttention(application: layerIndex) ? cacheCapacity : slidingCapacity
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
    let fullLayer = (0..<configuration.layerApplications).first {
      configuration.isFullAttention(application: $0)
    }!
    let existingCapacity = kvCache.layers[fullLayer].keys.shape[1]
    guard existingCapacity < cacheCapacity else { return }
    graph.joined()
    for layerIndex in kvCache.layers.indices
    where configuration.isFullAttention(application: layerIndex) {
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
