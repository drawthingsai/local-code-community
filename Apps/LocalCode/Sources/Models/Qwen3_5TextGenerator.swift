import BinaryResources
import DataModels
import Diffusion
import Foundation
import LLM
import ModelZoo
import NNC
import ProjectHistoryManager
import QuartzCore
import SFMT
import Tokenizer
import os.lock

public struct Qwen3_5TextGenerator {
  public static let estimatedKVCacheSize: UInt64 = 7 * 1_024 * 1_024 * 1_024

  public enum ContinuationState {
    case `continue`
    case pause
    case abort
  }

  public struct Statistics: Sendable {
    public var ropeDelta: Int = 0
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
      ropeDelta: Int = 0,
      tokenGeneratedSoFar: Int = 0
    ) {
      self.ropeDelta = ropeDelta
      self.prefillDurationSoFar = prefillDurationSoFar
      self.prefillTokensSoFar = prefillTokensSoFar
      self.tokenGenerationDurationSoFar = tokenGenerationDurationSoFar
      self.tokenGeneratedSoFar = tokenGeneratedSoFar
    }
  }

  private static let imagePad: Int32 = 248_056
  private static let eosTokenIds = Set<Int32>([248_046, 248_044])
  private static let recentStatisticsLimit = 3
  private static let maximumContextLength = 256 * 1_024
  private static let specialTokens: [String: Int32] = [
    "<|endoftext|>": 248_044,
    "<|im_start|>": 248_045,
    "<|im_end|>": 248_046,
    "<|object_ref_start|>": 248_047,
    "<|object_ref_end|>": 248_048,
    "<|box_start|>": 248_049,
    "<|box_end|>": 248_050,
    "<|quad_start|>": 248_051,
    "<|quad_end|>": 248_052,
    "<|vision_start|>": 248_053,
    "<|vision_end|>": 248_054,
    "<|vision_pad|>": 248_055,
    "<|image_pad|>": 248_056,
    "<|video_pad|>": 248_057,
    "<tool_call>": 248_058,
    "</tool_call>": 248_059,
    "<|fim_prefix|>": 248_060,
    "<|fim_middle|>": 248_061,
    "<|fim_suffix|>": 248_062,
    "<|fim_pad|>": 248_063,
    "<|repo_name|>": 248_064,
    "<|file_sep|>": 248_065,
    "<tool_response>": 248_066,
    "</tool_response>": 248_067,
    "<think>": 248_068,
    "</think>": 248_069,
    "<|audio_start|>": 248_070,
    "<|audio_end|>": 248_071,
    "<tts_pad>": 248_072,
    "<tts_text_bos>": 248_073,
    "<tts_text_eod>": 248_074,
    "<tts_text_bos_single>": 248_075,
    "<|audio_pad|>": 248_076,
  ]

  static let unsafeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_qwen3_5_json,
    merges: BinaryResources.merges_qwen3_5_txt,
    specialTokens: specialTokens, unknownToken: "<|endoftext|>",
    startToken: "<|endoftext|>", endToken: "<|im_end|>", pretokenizer: .qwen3_5)

  static let safeTokenizer = TiktokenTokenizer(
    vocabulary: BinaryResources.vocab_qwen3_5_json,
    merges: BinaryResources.merges_qwen3_5_txt,
    specialTokens: ["<|endoftext|>": 248_044], unknownToken: "<|endoftext|>",
    startToken: "<|endoftext|>", endToken: "<|endoftext|>", pretokenizer: .qwen3_5)

  public var ropeDelta = 0
  // Like ropeDelta, this belongs to the session's KV state.
  var hasPaddedImages = false
  public let filePath: String
  private let configuration: Qwen3_5ModelConfiguration
  private let tieEmbedding: Bool
  public var visionConfiguration: Qwen3_5VisionConfiguration {
    switch configuration.hiddenSize {
    case 5_120: return .qwen3_5_27B
    case 4_096: return .qwen3_5_9B
    default: return .qwen3_5_4B
    }
  }
  public var statistics: Statistics {
    guard !recentInteractionStatistics.isEmpty else { return Statistics() }
    var prefillDurationSoFar: Float = 0
    var prefillTokensSoFar = 0
    var tokenGenerationDurationSoFar: Float = 0
    var tokenGeneratedSoFar = 0
    for interactionStatistics in recentInteractionStatistics {
      prefillDurationSoFar += interactionStatistics.prefillDurationSoFar
      prefillTokensSoFar += interactionStatistics.prefillTokensSoFar
      tokenGenerationDurationSoFar += interactionStatistics.tokenGenerationDurationSoFar
      tokenGeneratedSoFar += interactionStatistics.tokenGeneratedSoFar
    }
    let count = Float(recentInteractionStatistics.count)
    return Statistics(
      prefillDurationSoFar: prefillDurationSoFar / count,
      prefillTokensSoFar: Int((Float(prefillTokensSoFar) / count).rounded()),
      tokenGenerationDurationSoFar: tokenGenerationDurationSoFar / count, ropeDelta: ropeDelta,
      tokenGeneratedSoFar: Int((Float(tokenGeneratedSoFar) / count).rounded()))
  }
  /// The latest decode on its own; `statistics` averages the recent ones.
  public var lastInteractionStatistics: Statistics {
    recentInteractionStatistics.last ?? Statistics()
  }
  private var recentInteractionStatistics = [Statistics]()
  // Keep this storage model-only: no DynamicGraph, graph tensors, or closures
  // capturing them. Reset may release it on the command thread after decode.
  private final class Storage {
    // Tools may start before the decoder continuation returns. Reset waits for
    // that decode to finish; subsequent decoding can immediately reload.
    var lock = os_unfair_lock()
    private let configuration: Qwen3_5ModelConfiguration
    private let tieEmbedding: Bool
    var decoderIsLoaded: Bool = false
    var isMTPEnabled: Bool = false
    private var cachedDecoder:
      ModelBuilder<
        (
          cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int,
          linearStateCheckpointCount: Int
        )
      >?
    var decoder:
      ModelBuilder<
        (
          cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int,
          linearStateCheckpointCount: Int
        )
      >
    {
      if let cachedDecoder { return cachedDecoder }
      let configuration = self.configuration
      let tieEmbedding = self.tieEmbedding
      let isMTPEnabled = self.isMTPEnabled
      let decoder:
        ModelBuilder<
          (
            cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int,
            linearStateCheckpointCount: Int
          )
        > =
          ModelBuilder {
            (
              tokenLengths: (
                cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int,
                linearStateCheckpointCount: Int
              ), _
            ) in
            Qwen3_5CausalLM(
              FloatType.self, tokenLength: tokenLengths.tokenLength,
              cachedTokenLength: tokenLengths.cachedTokenLength, configuration: configuration,
              includeLogits: true, outputCacheStates: true, outputFinalHiddenState: isMTPEnabled,
              tieEmbedding: tieEmbedding,
              lastNumberOfTokens: tokenLengths.lastNumberOfTokens,
              linearStateCheckpointCount: tokenLengths.linearStateCheckpointCount)
          }
      decoder.maxConcurrency = .limit(4)
      cachedDecoder = decoder
      return decoder
    }
    var vitIsLoaded = false
    var visionPositionEmbedding: Tensor<Float>?
    private var cachedVit: ModelBuilder<[(t: Int, h: Int, w: Int)]>?
    var vit: ModelBuilder<[(t: Int, h: Int, w: Int)]> {
      if let cachedVit { return cachedVit }
      let visionConfiguration: Qwen3_5VisionConfiguration
      switch configuration.hiddenSize {
      case 5_120: visionConfiguration = .qwen3_5_27B
      case 4_096: visionConfiguration = .qwen3_5_9B
      default: visionConfiguration = .qwen3_5_4B
      }
      let vit = ModelBuilder<[(t: Int, h: Int, w: Int)]> { grids, _ in
        Qwen3_5VisionTransformer(Float.self, gridThw: grids, configuration: visionConfiguration)
      }
      vit.maxConcurrency = .limit(4)
      cachedVit = vit
      return vit
    }
    private var cachedDrafter:
      ModelBuilder<(cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int)>?
    var drafter: ModelBuilder<(cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int)> {
      if let cachedDrafter { return cachedDrafter }
      let configuration = self.configuration
      let tieEmbedding = self.tieEmbedding
      let drafter:
        ModelBuilder<(cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int)> =
          ModelBuilder {
            (
              tokenLengths: (
                cachedTokenLength: Int, tokenLength: Int, lastNumberOfTokens: Int
              ), _
            ) in
            Qwen3_5MTP(
              BFloat16.self, FloatType.self, configuration: configuration, batchSize: 1,
              tokenLength: tokenLengths.tokenLength,
              cachedTokenLength: tokenLengths.cachedTokenLength,
              lastNumberOfTokens: tokenLengths.lastNumberOfTokens,
              tieEmbedding: tieEmbedding)
          }
      drafter.maxConcurrency = .limit(4)
      cachedDrafter = drafter
      return drafter
    }

    func reset() {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      cachedVit = nil
      vitIsLoaded = false
      visionPositionEmbedding = nil
      cachedDecoder = nil
      decoderIsLoaded = false
      cachedDrafter = nil
      isMTPEnabled = false
    }

    init(configuration: Qwen3_5ModelConfiguration, tieEmbedding: Bool) {
      self.configuration = configuration
      self.tieEmbedding = tieEmbedding
    }
  }

  // Copies share model storage. Graphs and conversation caches stay on the generation queue.
  private let storage: Storage
  private let maxDraftLength = 2
  public let chunkedPrefillMaxLength: Int
  public init(
    filePath: String, configuration: Qwen3_5ModelConfiguration, tieEmbedding: Bool,
    chunkedPrefillMaxLength: Int
  ) {
    self.filePath = filePath
    self.configuration = configuration
    self.tieEmbedding = tieEmbedding
    storage = Storage(configuration: configuration, tieEmbedding: tieEmbedding)
    self.chunkedPrefillMaxLength = chunkedPrefillMaxLength
  }
}

extension Qwen3_5TextGenerator {
  /// Drops only shared model weights, waiting for an active decode to return.
  /// Safe from a tool worker; graph-owned conversation caches stay with the agent.
  public func unload() { storage.reset() }

  private func encodeImage(graph: DynamicGraph, image: Qwen3_5Image)
    -> DynamicGraph.Tensor<FloatType>?
  {
    guard let patches = image.patches() else { return nil }
    let grids = [image.grid]
    let visionConfiguration = self.visionConfiguration
    if storage.visionPositionEmbedding == nil {
      let weight = graph.variable(
        .CPU, .WC(visionConfiguration.positionEmbeddings, visionConfiguration.hiddenSize),
        of: Float.self)
      let result = graph.openStore(
        filePath, flags: .readOnly, externalStore: TensorData.externalStore(filePath: filePath)
      ) { store in
        store.read("model.visual.pos_embed.weight", variable: weight, codec: .externalData)
      }
      guard case .success(true) = result else { return nil }
      storage.visionPositionEmbedding = weight.rawValue
    }
    guard let weight = storage.visionPositionEmbedding else { return nil }
    let inputs: [DynamicGraph.AnyTensor] = [
      graph.variable(patches.toGPU(0)),
      graph.variable(
        Qwen3_5VisionPositionEmbedding(
          weight: weight, gridThw: grids, configuration: visionConfiguration, of: Float.self
        ).toGPU(0)),
      graph.variable(
        Qwen3_5VisionRotaryEmbedding(
          gridThw: grids, configuration: visionConfiguration, of: FloatType.self
        ).toGPU(0)),
      graph.variable(Qwen3_5VisionSequenceOffsets(gridThw: grids).offsets.toGPU(0)),
    ]
    let vit = storage.vit
    if !storage.vitIsLoaded {
      vit.compile(grids, inputs: inputs)
      do {
        try graph.openStore(
          filePath, flags: .readOnly, externalStore: TensorData.externalStore(filePath: filePath)
        ) { store in
          try store.read(
            "vision_model", model: vit, strict: true,
            codec: [.jit, .i8x, .ezm7, .externalData])
        }.get()
      } catch { return nil }
      storage.vitIsLoaded = true
    }
    return DynamicGraph.Tensor<FloatType>(
      from:
        vit(grids, inputs: inputs[0], Array(inputs.dropFirst()))[0].as(of: Float.self))
  }

  public mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int, thinkingBudget: Int,
    deterministic: Bool = true, kvCache: inout [DynamicGraph.AnyTensor],
    draftCache: inout [DynamicGraph.AnyTensor],
    contextTokens: [Int32], contextCache: Qwen3_5ContextCache,
    embedSpans: [EmbedSpan] = [], projectPath: String? = nil,
    continuationHandler: (Int, Int, [Int32], Statistics) -> ContinuationState
  ) -> [Int32] {
    os_unfair_lock_lock(&storage.lock)
    defer { os_unfair_lock_unlock(&storage.lock) }
    let originalFlags = DynamicGraph.flags
    DynamicGraph.flags.insert(.disableMFAAttentionSpecializingC)
    defer { DynamicGraph.flags = originalFlags }
    if tokenOffset == 0 {
      ropeDelta = 0
      hasPaddedImages = false
    }
    let tokenLength = tokens.shape[0]
    recentInteractionStatistics.append(Statistics())
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
    if !storage.decoderIsLoaded {
      // Make sure isMTPEnabled is loaded before decoder compile and context-cache restore.
      graph.openStore(
        filePath, flags: .readOnly,
        externalStore: TensorData.externalStore(filePath: filePath)
      ) { store in
        storage.isMTPEnabled = store.keys.contains("__text_model__[t-mtp.fc-0-0]")
      }
    }
    let emptyTokens = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Int32.self)
    let emptyEmbeddings = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: FloatType.self)
    var prefillRotaryLength = 0
    var preparedStart = 0
    var preparedEndRopeDelta = 0
    var prefillRotaryEmbedding = emptyEmbeddings
    var encodedImages =
      [[UInt8]: (embeddings: DynamicGraph.Tensor<FloatType>, grid: (t: Int, h: Int, w: Int))]()
    var imageGrids = [Int64: (t: Int, h: Int, w: Int)]()
    var imageRotary = Qwen3_5ImageRotaryEmbedding<FloatType>(
      configuration: configuration, visionConfiguration: visionConfiguration)
    let initialCacheTokenLength = min(totalPrefillLength + 1, Self.maximumContextLength)
    let cacheCapacity = min(
      Self.maximumContextLength,
      ((initialCacheTokenLength + 4_095) / 4_096) * 4_096)
    let shouldRestoreContextCache =
      kvCache.isEmpty && tokenOffset == 0 && contextTokens.count == tokenLength
    Self.resizeCaches(
      graph: graph, kvCache: &kvCache, cacheCapacity: cacheCapacity, configuration: configuration)
    if storage.isMTPEnabled {
      Self.resizeDraftCache(
        graph: graph, draftCache: &draftCache, cacheCapacity: cacheCapacity + 1,
        configuration: configuration)
    }
    var contextCacheHasher = ContextCachePrefixHasher(modelFilePath: filePath)
    let restoredTokenLength: Int
    if shouldRestoreContextCache {
      restoredTokenLength = contextCache.restore(
        graph: graph, tokens: contextTokens, configuration: configuration,
        isMTPEnabled: storage.isMTPEnabled, kvCache: &kvCache, draftCache: &draftCache,
        hasher: &contextCacheHasher, ropeDelta: &ropeDelta, embeddingSpans: embedSpans)
    } else {
      restoredTokenLength = 0
    }
    let prefillStart = min(restoredTokenLength, max(0, tokenLength - 1))
    let reasoningMinimumPLogitRangeGPU = graph.variable(
      Tensor<FloatType>([2.995_732_3], .CPU, .WC(1, 1)).toGPU(0))
    let answerMinimumPLogitRangeGPU = graph.variable(
      Tensor<FloatType>([2.097_012_5], .CPU, .WC(1, 1)).toGPU(0))

    // First to prefill.
    func prefillChunkLength(start: Int) -> Int {
      var maxChunkLength = min(chunkedPrefillMaxLength, tokenLength - start)
      let upcomingImages = embedSpans.filter { $0.end > tokenOffset + start }
      if upcomingImages.count > 1 {
        maxChunkLength = min(
          maxChunkLength,
          Int(upcomingImages[1].start) - tokenOffset - start - (storage.isMTPEnabled ? 1 : 0))
      }
      guard maxChunkLength > 0 else { return 0 }
      let currentTokenLength = tokenOffset + start
      let nextCheckpointLength =
        ((currentTokenLength / contextCache.checkpointStride) + 1) * contextCache.checkpointStride
      if nextCheckpointLength > currentTokenLength
        && nextCheckpointLength < currentTokenLength + maxChunkLength
      {
        return nextCheckpointLength - currentTokenLength
      }
      return maxChunkLength
    }
    // Prepare both target and draft lookahead before either model mutates its caches.
    func prepareChunk(start: Int, length: Int) {
      let absoluteStart = tokenOffset + start
      let end = absoluteStart + length + (storage.isMTPEnabled ? 1 : 0)
      let spans = embedSpans.filter { $0.start < end && $0.end > absoluteStart }
      for span in spans {
        if encodedImages[span.digest] == nil {
          if span.kind == .image, span.digest.count == 32, let projectPath {
            let path = EmbedsFileStore(projectPath: projectPath).filePath(for: Data(span.digest))
            if let image = Qwen3_5Image(filePath: path, configuration: visionConfiguration) {
              if Array(image.digest) != span.digest {
                print("Warning: Qwen image digest mismatch at \(path).")
              }
              if image.tokenCount == span.length {
                if let embeddings = encodeImage(graph: graph, image: image) {
                  encodedImages[span.digest] = (embeddings, image.grid)
                }
              } else {
                print(
                  "Warning: Qwen image token count changed from \(span.length) to \(image.tokenCount) at \(path)."
                )
              }
            }
          }
        }
        if let image = encodedImages[span.digest], image.embeddings.shape[0] == span.length {
          imageGrids[span.start] = image.grid
        } else {
          print(
            "Warning: Qwen image at token \(span.start) is unavailable; using image placeholder tokens."
          )
          hasPaddedImages = true
        }
      }
      let prepared = imageRotary.embedding(
        start: absoluteStart, length: length, lookahead: storage.isMTPEnabled ? 1 : 0,
        ropeDelta: ropeDelta, spans: spans, imageGrids: imageGrids)
      preparedEndRopeDelta = prepared.ropeDelta
      preparedStart = start
      prefillRotaryLength = end - absoluteStart
      prefillRotaryEmbedding = graph.variable(prepared.tensor.toGPU(0))
    }
    func embeddingInputs(_ ids: DynamicGraph.Tensor<Int32>, start: Int, length: Int)
      -> (
        pre: DynamicGraph.Tensor<Int32>, injected: DynamicGraph.Tensor<FloatType>,
        post: DynamicGraph.Tensor<Int32>
      )
    {
      let position = tokenOffset + start
      guard
        let span = embedSpans.first(where: { $0.start < position + length && $0.end > position }),
        imageGrids[span.start] != nil,
        let image = encodedImages[span.digest]
      else { return (ids, emptyEmbeddings, emptyTokens) }
      let imageStart = max(position, Int(span.start))
      let imageEnd = min(position + length, Int(span.end))
      let preLength = imageStart - position
      let postLength = position + length - imageEnd
      let pre =
        preLength == 0
        ? emptyTokens
        : ids.reshaped(
          format: .NHWC, shape: [preLength], offset: [0], strides: [1]
        ).copied()
      let post =
        postLength == 0
        ? emptyTokens
        : ids.reshaped(
          format: .NHWC, shape: [postLength], offset: [imageEnd - position], strides: [1]
        ).copied()
      let injected = image.embeddings.reshaped(
        .WC(imageEnd - imageStart, configuration.hiddenSize),
        offset: [imageStart - Int(span.start), 0], strides: [configuration.hiddenSize, 1]
      ).copied()
      return (pre, injected, post)
    }
    guard continuationHandler(prefillStart, tokenLength, [], statistics) == .continue else {
      return []
    }
    let firstChunkLength = prefillChunkLength(start: prefillStart)
    guard firstChunkLength > 0 else { return [] }
    prepareChunk(start: prefillStart, length: firstChunkLength)
    func prefillInputs(start: Int, length: Int) -> (
      tokens: DynamicGraph.Tensor<Int32>, injected: DynamicGraph.Tensor<FloatType>,
      postTokens: DynamicGraph.Tensor<Int32>, attentionInputs: [DynamicGraph.AnyTensor],
      cacheInputs: [DynamicGraph.AnyTensor]
    ) {
      let tokens = tokens.reshaped(format: .NHWC, shape: [length], offset: [start], strides: [1])
        .copied()
      let rotary = prefillRotaryEmbedding.reshaped(
        format: .NHWC, shape: [1, length, 1, configuration.attentionHeadDim],
        offset: [0, start - preparedStart, 0, 0],
        strides: [
          prefillRotaryLength * configuration.attentionHeadDim,
          configuration.attentionHeadDim, configuration.attentionHeadDim, 1,
        ])
      let attentionInputs = [rotary.copied()]
      let cacheInputs = Self.cacheInputs(
        kvCache, currentTokenLength: tokenOffset + start + length, configuration: configuration)
      let embedding = embeddingInputs(tokens, start: start, length: length)
      return (embedding.pre, embedding.injected, embedding.post, attentionInputs, cacheInputs)
    }
    func prefillDraftInputs(
      start: Int, length: Int, hidden: DynamicGraph.Tensor<BFloat16>,
      nextToken: DynamicGraph.Tensor<Int32>?
    ) -> (
      tokens: DynamicGraph.Tensor<Int32>, injected: DynamicGraph.Tensor<FloatType>,
      postTokens: DynamicGraph.Tensor<Int32>, hidden: DynamicGraph.Tensor<BFloat16>,
      attentionInputs: [DynamicGraph.AnyTensor], cacheInputs: [DynamicGraph.AnyTensor],
      cachedTokenLength: Int, tokenLength: Int
    ) {
      let prependHidden = start == 0 || (restoredTokenLength > 0 && start == restoredTokenLength)
      let draftStart = prependHidden ? start : start + 1
      let draftTokenLength = prependHidden ? length + 1 : length
      let draftTokens: DynamicGraph.Tensor<Int32>
      if prependHidden {
        if let nextToken = nextToken {
          let prefillTokens = tokens.reshaped(
            format: .NHWC, shape: [length], offset: [start], strides: [1]
          ).copied()
          draftTokens = Functional.concat(axis: 0, prefillTokens, nextToken)
        } else {
          draftTokens = tokens.reshaped(
            format: .NHWC, shape: [draftTokenLength], offset: [start], strides: [1]
          ).copied()
        }
      } else {
        if let nextToken = nextToken {
          if length > 1 {
            let shiftedTokens = tokens.reshaped(
              format: .NHWC, shape: [length - 1], offset: [start + 1], strides: [1]
            ).copied()
            draftTokens = Functional.concat(axis: 0, shiftedTokens, nextToken)
          } else {
            draftTokens = nextToken
          }
        } else {
          draftTokens = tokens.reshaped(
            format: .NHWC, shape: [length], offset: [start + 1], strides: [1]
          ).copied()
        }
      }
      let draftHidden: DynamicGraph.Tensor<BFloat16>
      if prependHidden {
        let previousHidden: DynamicGraph.Tensor<BFloat16>
        if tokenOffset + start == 0 {
          previousHidden = graph.variable(
            Tensor<BFloat16>(
              Array(repeating: BFloat16.zero, count: configuration.hiddenSize),
              .CPU, .NC(1, configuration.hiddenSize)
            ).toGPU(0))
        } else {
          previousHidden = draftCache[2].as(of: BFloat16.self)
        }
        let hiddenRows = hidden.reshaped(
          .NC(length, configuration.hiddenSize), offset: [0, 0],
          strides: [configuration.hiddenSize, 1]
        ).copied()
        draftHidden = Functional.concat(axis: 0, previousHidden, hiddenRows)
      } else {
        draftHidden = hidden.reshaped(
          .NC(length, configuration.hiddenSize), offset: [0, 0],
          strides: [configuration.hiddenSize, 1]
        ).copied()
      }
      let rotary = prefillRotaryEmbedding.reshaped(
        format: .NHWC, shape: [1, draftTokenLength, 1, configuration.attentionHeadDim],
        offset: [0, draftStart - preparedStart, 0, 0],
        strides: [
          prefillRotaryLength * configuration.attentionHeadDim,
          configuration.attentionHeadDim, configuration.attentionHeadDim, 1,
        ])
      let attentionInputs = [rotary.copied()]
      let draftCachedTokenLength = tokenOffset + draftStart
      let cacheInputs = Self.draftCacheInputs(
        draftCache, currentTokenLength: draftCachedTokenLength + draftTokenLength,
        configuration: configuration)
      let embedding = embeddingInputs(draftTokens, start: draftStart, length: draftTokenLength)
      return (
        embedding.pre, embedding.injected, embedding.post, draftHidden, attentionInputs,
        cacheInputs, draftCachedTokenLength,
        draftTokenLength
      )
    }
    var nextTokenGPU = graph.variable(
      Tensor<Int32>([0], kind: .CPU, format: .NHWC, shape: [1]).toGPU(0))
    if storage.isMTPEnabled {
      if !storage.decoderIsLoaded {
        let compileHidden = graph.variable(
          Tensor<BFloat16>(
            Array(repeating: BFloat16.zero, count: firstChunkLength * configuration.hiddenSize),
            .CPU, .NC(firstChunkLength, configuration.hiddenSize)
          ).toGPU(0))
        let firstPrefillDraftInputs = prefillDraftInputs(
          start: prefillStart, length: firstChunkLength, hidden: compileHidden,
          nextToken: nextTokenGPU)
        storage.drafter.compile(
          (
            cachedTokenLength: firstPrefillDraftInputs.cachedTokenLength,
            tokenLength: firstPrefillDraftInputs.tokenLength, lastNumberOfTokens: 1
          ),
          inputs: [
            firstPrefillDraftInputs.tokens, firstPrefillDraftInputs.injected,
            firstPrefillDraftInputs.postTokens, firstPrefillDraftInputs.hidden,
          ]
            + firstPrefillDraftInputs.attentionInputs + firstPrefillDraftInputs.cacheInputs)
      }
    }
    let firstPrefillInputs = prefillInputs(start: prefillStart, length: firstChunkLength)
    let inputs: [DynamicGraph.AnyTensor] =
      [firstPrefillInputs.tokens, firstPrefillInputs.injected, firstPrefillInputs.postTokens]
      + firstPrefillInputs.attentionInputs
      + firstPrefillInputs.cacheInputs
    storage.decoder.compile(
      (
        cachedTokenLength: tokenOffset + prefillStart, tokenLength: firstChunkLength,
        lastNumberOfTokens: 1, linearStateCheckpointCount: 0
      ), inputs: inputs)
    if !storage.decoderIsLoaded {
      graph.openStore(
        filePath, flags: .readOnly,
        externalStore: TensorData.externalStore(filePath: filePath)
      ) { store in
        store.read(
          "text_model", model: storage.decoder,
          codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)])
        if storage.isMTPEnabled {
          store.read(
            "text_model", model: storage.drafter,
            codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)]
          ) { name, _, _, _ in
            // Don't load these, these will be shared from decoder.
            if name.contains("lm_head") || name.contains("model.language_model.embed_tokens") {
              return .fail
            } else {
              return .continue(name)
            }
          }
          storage.drafter.parameters.share(from: storage.decoder.parameters) { name, _ in
            return .continue(name)
          }
          storage.drafter.pinMemory = true
        }
        // Keep whole-file weights pinned across interactions; model destruction releases them.
        storage.decoder.pinMemory = true
        storage.decoderIsLoaded = true
      }
    }
    var prefillTokenCPU: DynamicGraph.Tensor<Int32>?
    var draftSamplingState:
      (
        maskedLogits: DynamicGraph.Tensor<FloatType>,
        logSumExp: DynamicGraph.Tensor<FloatType>, temperature: Float
      )?
    var prefillChunkStart = prefillStart
    let initialPrefillDurationSoFar =
      recentInteractionStatistics[interactionStatisticsIndex].prefillDurationSoFar
    let flags = DynamicGraph.flags
    let prefillStartTime = CACurrentMediaTime()
    while prefillChunkStart < tokenLength {
      let start = prefillChunkStart
      let length = prefillChunkLength(start: start)
      guard length > 0 else { break }
      if start != prefillStart {
        prepareChunk(start: start, length: length)
      }
      if length < chunkedPrefillMaxLength {
        DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)
      }
      let isLast = start + length == tokenLength
      let chunkInputs = prefillInputs(start: start, length: length)
      let prefillOutputs = storage.decoder(
        (
          cachedTokenLength: start + tokenOffset, tokenLength: length,
          lastNumberOfTokens: isLast ? 1 : 0, linearStateCheckpointCount: 0
        ), inputs: chunkInputs.tokens,
        [chunkInputs.injected, chunkInputs.postTokens] + chunkInputs.attentionInputs
          + chunkInputs.cacheInputs)
      Self.updateLinearCaches(
        &kvCache, from: prefillOutputs, outputOffset: storage.isMTPEnabled ? 2 : 1,
        stateCheckpointIndex: 0, tokenLength: length, inputCaches: nil, configuration: configuration
      )
      if storage.isMTPEnabled {
        let prefillHidden = DynamicGraph.Tensor<BFloat16>(
          from: prefillOutputs[0].as(of: FloatType.self))
        let firstTokenCPU: DynamicGraph.Tensor<Int32>?
        if isLast {
          let logits = prefillOutputs[1].as(of: FloatType.self)
          if thinkingBudget > 0 || !deterministic {
            let temperature: Float = thinkingBudget > 0 ? 1 : 0.7
            let minimumPLogitRangeGPU =
              thinkingBudget > 0
              ? reasoningMinimumPLogitRangeGPU : answerMinimumPLogitRangeGPU
            let maximumLogit = logits.reduced(.max, axis: [1])
            logits.fill(-Float.infinity, if: logits < (maximumLogit - minimumPLogitRangeGPU))
            nextTokenGPU = Functional.gumbelArgmax(
              logits, axis: 1, scale: temperature
            ).reshaped(format: .NHWC, shape: [1])
          } else {
            nextTokenGPU = Functional.argmax(logits, axis: 1).reshaped(
              format: .NHWC, shape: [1])
          }
          firstTokenCPU = nextTokenGPU.toCPU()
        } else {
          firstTokenCPU = nil
        }
        let draftInputs = prefillDraftInputs(
          start: start, length: length,
          hidden: prefillHidden, nextToken: isLast ? nextTokenGPU : nil)
        if isLast {
          // ModelBuilder rebuilds only for input-shape changes. A prefill aborted after a
          // non-final chunk of this shape would otherwise leave a graph without logits.
          storage.drafter.compile(
            (
              cachedTokenLength: draftInputs.cachedTokenLength,
              tokenLength: draftInputs.tokenLength, lastNumberOfTokens: 1
            ),
            inputs: [
              draftInputs.tokens, draftInputs.injected, draftInputs.postTokens, draftInputs.hidden,
            ] + draftInputs.attentionInputs + draftInputs.cacheInputs)
        }
        let draftOutputs = storage.drafter(
          (
            cachedTokenLength: draftInputs.cachedTokenLength, tokenLength: draftInputs.tokenLength,
            lastNumberOfTokens: isLast ? 1 : 0
          ), inputs: draftInputs.tokens,
          [draftInputs.injected, draftInputs.postTokens, draftInputs.hidden]
            + draftInputs.attentionInputs + draftInputs.cacheInputs)
        Self.updateDraftLastHidden(
          &draftCache, from: prefillHidden, rowIndex: length - 1, configuration: configuration)
        if isLast {
          let isDraftThinking: Bool
          if let firstTokenCPU = firstTokenCPU {
            isDraftThinking = thinkingBudget > 0 && firstTokenCPU[0] != 248_069
          } else {
            isDraftThinking = false
          }
          let draftLogits = draftOutputs[1].as(of: FloatType.self)
          let draftTokenGPU: DynamicGraph.Tensor<Int32>
          if isDraftThinking || !deterministic {
            let temperature: Float = isDraftThinking ? 1 : 0.7
            let minimumPLogitRangeGPU =
              isDraftThinking ? reasoningMinimumPLogitRangeGPU : answerMinimumPLogitRangeGPU
            let maskedLogits = draftLogits.copied()
            let maximumLogit = maskedLogits.reduced(.max, axis: [1])
            maskedLogits.fill(
              -Float.infinity, if: maskedLogits < (maximumLogit - minimumPLogitRangeGPU))
            let logSumExp = Functional.logSumExp(
              maskedLogits, axis: [1], scale: 1 / temperature)
            draftTokenGPU = Functional.gumbelArgmax(
              maskedLogits, axis: 1, scale: temperature
            ).reshaped(format: .NHWC, shape: [1])
            draftSamplingState = (maskedLogits, logSumExp, temperature)
          } else {
            draftTokenGPU = Functional.argmax(draftLogits, axis: 1).reshaped(
              format: .NHWC, shape: [1])
            draftSamplingState = nil
          }
          prefillTokenCPU = Functional.concat(axis: 0, nextTokenGPU, draftTokenGPU).toCPU()
        }
      } else if isLast {
        let logits = prefillOutputs[0].as(of: FloatType.self)
        if thinkingBudget > 0 || !deterministic {
          let temperature: Float = thinkingBudget > 0 ? 1 : 0.7
          let minimumPLogitRangeGPU =
            thinkingBudget > 0
            ? reasoningMinimumPLogitRangeGPU : answerMinimumPLogitRangeGPU
          let maximumLogit = logits.reduced(.max, axis: [1])
          logits.fill(-Float.infinity, if: logits < (maximumLogit - minimumPLogitRangeGPU))
          prefillTokenCPU = Functional.gumbelArgmax(
            logits, axis: 1, scale: temperature
          ).reshaped(format: .NHWC, shape: [1]).toCPU()
        } else {
          prefillTokenCPU = Functional.argmax(logits, axis: 1).reshaped(
            format: .NHWC, shape: [1]
          ).toCPU()
        }
      }
      ropeDelta = preparedEndRopeDelta
      let checkpointLength = tokenOffset + start + length
      if !hasPaddedImages, checkpointLength % contextCache.checkpointStride == 0 {
        contextCache.save(
          graph: graph, tokens: contextTokens, checkpointLength: checkpointLength,
          configuration: configuration, isMTPEnabled: storage.isMTPEnabled, kvCache: kvCache,
          draftCache: draftCache, hasher: &contextCacheHasher, ropeDelta: ropeDelta,
          embeddingSpans: embedSpans)
      }
      prefillChunkStart += length
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
    guard let prefillTokenCPU = prefillTokenCPU else { return [] }
    let firstToken = prefillTokenCPU[0]
    guard !Self.eosTokenIds.contains(firstToken) else { return [firstToken] }
    var generated = storage.isMTPEnabled ? [Int32]() : [firstToken]
    if !storage.isMTPEnabled {
      recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
    }
    nextTokenGPU = prefillTokenCPU.toGPU()
    let prefilledTokenLength = totalPrefillLength
    let decodeTokenCapacity = max(0, Self.maximumContextLength - prefilledTokenLength)
    guard decodeTokenCapacity > 0 else { return generated }
    let queueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = queueWatermark * 16
    defer { DynamicGraph.queueWatermark = queueWatermark }
    var decodeCacheCapacity = cacheCapacity
    func compileDecode(cacheCapacity: Int) {
      let sequenceLength = storage.isMTPEnabled ? maxDraftLength : 1
      let maxDecodeCachedTokenLength = cacheCapacity - sequenceLength
      let nextCacheInputs = Self.cacheInputs(
        kvCache, currentTokenLength: cacheCapacity, configuration: configuration)
      let nextRotaryEmbedding = Qwen3_5RotaryEmbedding(
        sequenceLength: sequenceLength, cachedTokenLength: maxDecodeCachedTokenLength,
        configuration: configuration, of: FloatType.self)
      let nextRotaryEmbeddingGPU = graph.variable(nextRotaryEmbedding.toGPU(0))
      storage.decoder.compile(
        (
          cachedTokenLength: maxDecodeCachedTokenLength, tokenLength: sequenceLength,
          lastNumberOfTokens: sequenceLength,
          linearStateCheckpointCount: storage.isMTPEnabled ? sequenceLength - 1 : 0
        ),
        inputs: [nextTokenGPU, emptyEmbeddings, emptyTokens, nextRotaryEmbeddingGPU]
          + nextCacheInputs,
        isEager: true)
      if storage.isMTPEnabled {
        let nextDraftCacheInputs = Self.draftCacheInputs(
          draftCache, currentTokenLength: cacheCapacity + 1, configuration: configuration)
        let draftCompileHidden = graph.variable(
          Tensor<BFloat16>(
            Array(repeating: BFloat16.zero, count: sequenceLength * configuration.hiddenSize),
            .CPU, .NC(sequenceLength, configuration.hiddenSize)
          ).toGPU(0))
        storage.drafter.compile(
          (
            cachedTokenLength: maxDecodeCachedTokenLength + 1, tokenLength: sequenceLength,
            lastNumberOfTokens: 1
          ),
          inputs: [
            nextTokenGPU, emptyEmbeddings, emptyTokens, draftCompileHidden, nextRotaryEmbeddingGPU,
          ]
            + nextDraftCacheInputs,
          isEager: true)
      }
    }
    compileDecode(cacheCapacity: decodeCacheCapacity)
    var decodeRotaryStartIndex = 0
    var rotaryEmbeddingForDecode = graph.variable(
      Qwen3_5RotaryEmbedding(
        sequenceLength: min(decodeCacheCapacity - prefilledTokenLength, decodeTokenCapacity)
          + (storage.isMTPEnabled ? 1 : 0),
        cachedTokenLength: prefilledTokenLength + ropeDelta,
        configuration: configuration, of: FloatType.self
      ).toGPU(0))
    var shouldAppendPendingToken = true
    var shouldStopAfterSampling = false
    var thinkingEnded = firstToken == 248_069
    var decodeIndex = 0
    var runningContextTokens = contextTokens
    let initialTokenGenerationDurationSoFar =
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar
    let tokenGenerationStartTime = CACurrentMediaTime()
    var sfmt = SFMT(seed: UInt64(DynamicGraph.random()))
    defer {
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
    }
    while decodeIndex < decodeTokenCapacity {
      let cachedTokenLength = prefilledTokenLength + decodeIndex
      let sequenceLength = storage.isMTPEnabled ? maxDraftLength : 1
      var isThinkingEndedForcedAtVerify = false
      var isThinkingEndedForcedAtDraft = false
      if thinkingBudget > 0 && !thinkingEnded {
        if storage.isMTPEnabled {
          if decodeIndex == thinkingBudget {
            nextTokenGPU = graph.variable(
              Tensor<Int32>(
                [248_069, 271], kind: .CPU, format: .NHWC, shape: [maxDraftLength]
              )
              .toGPU(0))
            isThinkingEndedForcedAtVerify = true
          } else if decodeIndex + 1 == thinkingBudget {
            let currentTokenGPU = nextTokenGPU.reshaped(
              format: .NHWC, shape: [1], offset: [0], strides: [1]
            ).copied()
            let endThinkTokenGPU = graph.variable(
              Tensor<Int32>([248_069], kind: .CPU, format: .NHWC, shape: [1]).toGPU(0))
            nextTokenGPU = Functional.concat(axis: 0, currentTokenGPU, endThinkTokenGPU)
            isThinkingEndedForcedAtDraft = true
          }
        } else if decodeIndex == thinkingBudget {
          // No matter if thinking ended this round or not, we will use end of think token right now.
          nextTokenGPU = graph.variable(
            Tensor<Int32>([248_069], kind: .CPU, format: .NHWC, shape: [1]).toGPU(0))
        }
      }
      if cachedTokenLength + sequenceLength > decodeCacheCapacity {
        decodeCacheCapacity = min(decodeCacheCapacity + 4_096, Self.maximumContextLength)
        let nextRotaryEmbedding = Qwen3_5RotaryEmbedding(
          sequenceLength: min(
            decodeCacheCapacity - cachedTokenLength, decodeTokenCapacity - decodeIndex)
            + (storage.isMTPEnabled ? 1 : 0),
          cachedTokenLength: cachedTokenLength + ropeDelta,
          configuration: configuration, of: FloatType.self
        )
        graph.joined()
        let nextRotaryEmbeddingForDecode = graph.variable(nextRotaryEmbedding.toGPU(0))
        Self.resizeCaches(
          graph: graph, kvCache: &kvCache, cacheCapacity: decodeCacheCapacity,
          configuration: configuration)
        if storage.isMTPEnabled {
          Self.resizeDraftCache(
            graph: graph, draftCache: &draftCache, cacheCapacity: decodeCacheCapacity + 1,
            configuration: configuration)
        }
        compileDecode(cacheCapacity: decodeCacheCapacity)
        decodeRotaryStartIndex = decodeIndex
        rotaryEmbeddingForDecode = nextRotaryEmbeddingForDecode
      }
      let decodeRotaryEmebedding = rotaryEmbeddingForDecode.reshaped(
        format: .NHWC, shape: [1, sequenceLength, 1, configuration.attentionHeadDim],
        offset: [0, decodeIndex - decodeRotaryStartIndex, 0, 0],
        strides: [
          configuration.attentionHeadDim, configuration.attentionHeadDim,
          configuration.attentionHeadDim, 1,
        ]
      ).copied()
      let cacheInputs = Self.cacheInputs(
        kvCache, currentTokenLength: cachedTokenLength + sequenceLength,
        configuration: configuration)
      let oldDecodedTokenCPU = nextTokenGPU.toCPU()
      let decodeOutputs = storage.decoder(
        (
          cachedTokenLength: cachedTokenLength, tokenLength: sequenceLength,
          lastNumberOfTokens: sequenceLength,
          linearStateCheckpointCount: storage.isMTPEnabled ? sequenceLength - 1 : 0
        ), inputs: nextTokenGPU,
        [emptyEmbeddings, emptyTokens, decodeRotaryEmebedding] + cacheInputs)
      let logits = decodeOutputs[storage.isMTPEnabled ? 1 : 0].as(of: FloatType.self)
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
      if storage.isMTPEnabled {
        // Compile the next verify shape while this one runs, assuming the draft is accepted;
        // a rejected draft rebuilds after verification as before.
        let advance = isThinkingEndedForcedAtVerify ? 1 : sequenceLength
        let nextCachedTokenLength = cachedTokenLength + advance
        if decodeIndex + advance < decodeTokenCapacity,
          nextCachedTokenLength + sequenceLength <= decodeCacheCapacity
        {
          storage.decoder.compile(
            (
              cachedTokenLength: nextCachedTokenLength, tokenLength: sequenceLength,
              lastNumberOfTokens: sequenceLength, linearStateCheckpointCount: sequenceLength - 1
            ),
            inputs: [nextTokenGPU, emptyEmbeddings, emptyTokens, decodeRotaryEmebedding]
              + Self.cacheInputs(
                kvCache, currentTokenLength: nextCachedTokenLength + sequenceLength,
                configuration: configuration))
        }
        let vocabularySize = logits.shape[1]
        let firstTargetLogits = logits.reshaped(
          .WC(1, vocabularySize), offset: [0, 0], strides: [vocabularySize, 1]
        )
        let secondTargetLogits = logits.reshaped(
          .WC(1, vocabularySize), offset: [1, 0], strides: [vocabularySize, 1]
        )
        let advanceCount: Int
        let tokenAfterVerifiedBlockGPU: DynamicGraph.Tensor<Int32>
        if isThinkingEndedForcedAtVerify || isThinkingEndedForcedAtDraft {
          advanceCount = isThinkingEndedForcedAtDraft ? maxDraftLength : 1
          let targetLogits = isThinkingEndedForcedAtDraft ? secondTargetLogits : firstTargetLogits
          if !deterministic {
            let maximumLogit = targetLogits.reduced(.max, axis: [1])
            targetLogits.fill(
              -Float.infinity, if: targetLogits < (maximumLogit - answerMinimumPLogitRangeGPU))
            tokenAfterVerifiedBlockGPU = Functional.gumbelArgmax(
              targetLogits, axis: 1, scale: 0.7
            ).reshaped(format: .NHWC, shape: [1])
          } else {
            tokenAfterVerifiedBlockGPU = Functional.argmax(targetLogits, axis: 1).reshaped(
              format: .NHWC, shape: [1])
          }
        } else if let draftSamplingState = draftSamplingState {
          let targetMaskedLogits = firstTargetLogits.copied()
          let minimumPLogitRangeGPU =
            draftSamplingState.temperature == 1
            ? reasoningMinimumPLogitRangeGPU : answerMinimumPLogitRangeGPU
          let maximumLogit = targetMaskedLogits.reduced(.max, axis: [1])
          targetMaskedLogits.fill(
            -Float.infinity, if: targetMaskedLogits < (maximumLogit - minimumPLogitRangeGPU))
          let draftToken = Int(oldDecodedTokenCPU[1])
          let targetLogSumExpGPU = Functional.logSumExp(
            targetMaskedLogits, axis: [1], scale: 1 / draftSamplingState.temperature
          )
          let draftLogSumExpGPU = draftSamplingState.logSumExp
          let targetLogSumExpCPU = targetLogSumExpGPU.toCPU()
          let draftLogSumExpCPU = draftLogSumExpGPU.toCPU()
          let selectedTargetLogitCPU =
            targetMaskedLogits[0..<1, draftToken..<(draftToken + 1)].toCPU()
          let selectedDraftLogitCPU =
            draftSamplingState.maskedLogits[0..<1, draftToken..<(draftToken + 1)].toCPU()
          let targetTokenLogProbability =
            Float(selectedTargetLogitCPU[0, 0]) / draftSamplingState.temperature
            - Float(targetLogSumExpCPU[0, 0])
          let draftTokenLogProbability =
            Float(selectedDraftLogitCPU[0, 0]) / draftSamplingState.temperature
            - Float(draftLogSumExpCPU[0, 0])
          let logAcceptanceRatio = targetTokenLogProbability - draftTokenLogProbability
          let isDraftAccepted: Bool
          if logAcceptanceRatio >= 0 {
            isDraftAccepted = true
          } else {
            let uniform = Float.random(in: 0..<1, using: &sfmt)
            isDraftAccepted =
              log(max(uniform, Float.leastNonzeroMagnitude)) <= logAcceptanceRatio
          }
          if isDraftAccepted {
            advanceCount = maxDraftLength
            let isThinking =
              draftSamplingState.temperature == 1 && oldDecodedTokenCPU[1] != 248_069
            if isThinking || !deterministic {
              let temperature: Float = isThinking ? 1 : 0.7
              let minimumPLogitRangeGPU =
                isThinking ? reasoningMinimumPLogitRangeGPU : answerMinimumPLogitRangeGPU
              let maximumLogit = secondTargetLogits.reduced(.max, axis: [1])
              secondTargetLogits.fill(
                -Float.infinity,
                if: secondTargetLogits < (maximumLogit - minimumPLogitRangeGPU))
              tokenAfterVerifiedBlockGPU = Functional.gumbelArgmax(
                secondTargetLogits, axis: 1, scale: temperature
              ).reshaped(format: .NHWC, shape: [1])
            } else {
              tokenAfterVerifiedBlockGPU = Functional.argmax(
                secondTargetLogits, axis: 1
              ).reshaped(format: .NHWC, shape: [1])
            }
          } else {
            advanceCount = 1
            let targetLogProbabilities =
              targetMaskedLogits / draftSamplingState.temperature - targetLogSumExpGPU
            let draftLogProbabilities =
              draftSamplingState.maskedLogits / draftSamplingState.temperature
              - draftLogSumExpGPU
            let residualProbabilities =
              Functional.exp(targetLogProbabilities) - Functional.exp(draftLogProbabilities)
            residualProbabilities.clamp(0...)
            tokenAfterVerifiedBlockGPU = Functional.gumbelArgmax(
              Functional.log(residualProbabilities), axis: 1, scale: 1
            ).reshaped(format: .NHWC, shape: [1])
          }
        } else {
          let targetTokenGPU = Functional.argmax(firstTargetLogits, axis: 1).reshaped(
            format: .NHWC, shape: [1])
          if targetTokenGPU.toCPU()[0] == oldDecodedTokenCPU[1] {
            advanceCount = maxDraftLength
            tokenAfterVerifiedBlockGPU = Functional.argmax(secondTargetLogits, axis: 1).reshaped(
              format: .NHWC, shape: [1])
          } else {
            advanceCount = 1
            tokenAfterVerifiedBlockGPU = targetTokenGPU
          }
        }
        var commitCount = advanceCount
        for i in 0..<advanceCount {
          if Self.eosTokenIds.contains(oldDecodedTokenCPU[i]) {
            commitCount = i + 1
            shouldAppendPendingToken = false
            break
          }
        }
        let nextCheckpointLength =
          ((cachedTokenLength / contextCache.checkpointStride) + 1) * contextCache.checkpointStride
        let partialCheckpointDelta: Int?
        let partialLinearOverrides: [Qwen3_5LinearCacheOverride]?
        if nextCheckpointLength > cachedTokenLength
          && nextCheckpointLength < cachedTokenLength + commitCount
        {
          let checkpointDelta = nextCheckpointLength - cachedTokenLength
          partialCheckpointDelta = checkpointDelta
          partialLinearOverrides = Self.linearCacheOverrides(
            from: decodeOutputs, outputOffset: 2,
            stateCheckpointIndex: sequenceLength - checkpointDelta, tokenLength: sequenceLength,
            inputCaches: kvCache, configuration: configuration)
        } else {
          partialCheckpointDelta = nil
          partialLinearOverrides = nil
        }
        if commitCount == sequenceLength {
          Self.updateLinearCaches(
            &kvCache, from: decodeOutputs, outputOffset: 2, stateCheckpointIndex: 0,
            tokenLength: sequenceLength, inputCaches: nil, configuration: configuration)
        } else {
          let inputCaches = kvCache
          Self.updateLinearCaches(
            &kvCache, from: decodeOutputs, outputOffset: 2,
            stateCheckpointIndex: sequenceLength - commitCount, tokenLength: sequenceLength,
            inputCaches: inputCaches, configuration: configuration)
        }
        let draftTokens: DynamicGraph.Tensor<Int32>
        if commitCount == sequenceLength {
          let acceptedTokenGPU = graph.variable(
            Tensor<Int32>(
              [oldDecodedTokenCPU[1]], kind: .CPU, format: .NHWC, shape: [1]
            ).toGPU(0))
          draftTokens = Functional.concat(
            axis: 0, acceptedTokenGPU, tokenAfterVerifiedBlockGPU
          )
        } else {
          draftTokens = tokenAfterVerifiedBlockGPU
        }
        let isNextDraftPossiblyThinking =
          thinkingBudget > 0 && !thinkingEnded && oldDecodedTokenCPU[0] != 248_069
          && (advanceCount == 1 || oldDecodedTokenCPU[1] != 248_069)
        let thisTokenGPU = tokenAfterVerifiedBlockGPU
        let thisTokenCPU =
          isNextDraftPossiblyThinking ? thisTokenGPU.toCPU() : nil
        let draftHidden = DynamicGraph.Tensor<BFloat16>(
          from: decodeOutputs[0].as(of: FloatType.self).reshaped(
            .NC(commitCount, configuration.hiddenSize), offset: [0, 0],
            strides: [configuration.hiddenSize, 1]
          ).copied())
        let draftRotaryEmebedding = rotaryEmbeddingForDecode.reshaped(
          format: .NHWC, shape: [1, commitCount, 1, configuration.attentionHeadDim],
          offset: [0, decodeIndex + 1 - decodeRotaryStartIndex, 0, 0],
          strides: [
            configuration.attentionHeadDim, configuration.attentionHeadDim,
            configuration.attentionHeadDim, 1,
          ]
        ).copied()
        let draftCacheInputs = Self.draftCacheInputs(
          draftCache, currentTokenLength: cachedTokenLength + commitCount + 1,
          configuration: configuration)
        let draftOutputs = storage.drafter(
          (
            cachedTokenLength: cachedTokenLength + 1, tokenLength: commitCount,
            lastNumberOfTokens: 1
          ), inputs: draftTokens,
          [emptyEmbeddings, emptyTokens, draftHidden, draftRotaryEmebedding] + draftCacheInputs)
        Self.updateDraftLastHidden(
          &draftCache, from: draftHidden, rowIndex: commitCount - 1, configuration: configuration)
        let isNextDraftThinking =
          thisTokenCPU.map { $0[0] != 248_069 } ?? false
        let draftLogits = draftOutputs[1].as(of: FloatType.self)
        let draftTokenGPU: DynamicGraph.Tensor<Int32>
        if isNextDraftThinking || !deterministic {
          let temperature: Float = isNextDraftThinking ? 1 : 0.7
          let minimumPLogitRangeGPU =
            isNextDraftThinking ? reasoningMinimumPLogitRangeGPU : answerMinimumPLogitRangeGPU
          let maskedLogits = draftLogits.copied()
          let maximumLogit = maskedLogits.reduced(.max, axis: [1])
          maskedLogits.fill(
            -Float.infinity, if: maskedLogits < (maximumLogit - minimumPLogitRangeGPU))
          let logSumExp = Functional.logSumExp(
            maskedLogits, axis: [1], scale: 1 / temperature)
          draftTokenGPU = Functional.gumbelArgmax(
            maskedLogits, axis: 1, scale: temperature
          ).reshaped(format: .NHWC, shape: [1])
          draftSamplingState = (maskedLogits, logSumExp, temperature)
        } else {
          draftTokenGPU = Functional.argmax(draftLogits, axis: 1).reshaped(
            format: .NHWC, shape: [1])
          draftSamplingState = nil
        }
        nextTokenGPU = Functional.concat(axis: 0, thisTokenGPU, draftTokenGPU)
        // This needs to happen after the draft because draft needs to update the internal KV states.
        for i in 0..<commitCount {
          let decodedToken = oldDecodedTokenCPU[i]
          runningContextTokens.append(decodedToken)
          let checkpointLength = runningContextTokens.count
          if !hasPaddedImages, checkpointLength % contextCache.checkpointStride == 0 {
            if let partialCheckpointDelta = partialCheckpointDelta,
              partialCheckpointDelta == i + 1,
              let partialLinearOverrides = partialLinearOverrides
            {
              let draftLastHidden = draftHidden.reshaped(
                .NC(1, configuration.hiddenSize), offset: [i, 0],
                strides: [configuration.hiddenSize, 1]
              ).copied()
              contextCache.save(
                graph: graph, tokens: runningContextTokens, checkpointLength: checkpointLength,
                configuration: configuration, isMTPEnabled: storage.isMTPEnabled, kvCache: kvCache,
                draftCache: draftCache, hasher: &contextCacheHasher,
                linearOverrides: partialLinearOverrides,
                draftLastHiddenOverride: draftLastHidden, ropeDelta: ropeDelta,
                embeddingSpans: embedSpans)
            } else {
              contextCache.save(
                graph: graph, tokens: runningContextTokens, checkpointLength: checkpointLength,
                configuration: configuration, isMTPEnabled: storage.isMTPEnabled, kvCache: kvCache,
                draftCache: draftCache, hasher: &contextCacheHasher, ropeDelta: ropeDelta,
                embeddingSpans: embedSpans)
            }
          }
          generated.append(decodedToken)
          recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
          recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
            Float(CACurrentMediaTime() - tokenGenerationStartTime)
            + initialTokenGenerationDurationSoFar
          if decodedToken == 248_069 {
            thinkingEnded = true
          }
          if Self.eosTokenIds.contains(decodedToken) {
            shouldAppendPendingToken = false
            break
          }
          if shouldStopAfterSampling {
            continue
          }
          switch continuationHandler(
            cachedTokenLength + i + 1, cachedTokenLength + i + 1, generated, statistics)
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
        decodeIndex += commitCount
        if !shouldAppendPendingToken || shouldStopAfterSampling {
          break
        }
      } else {
        let isNextTokenThinking =
          thinkingBudget > 0 && !thinkingEnded && oldDecodedTokenCPU[0] != 248_069
        if isNextTokenThinking || !deterministic {
          let temperature: Float = isNextTokenThinking ? 1 : 0.7
          let minimumPLogitRangeGPU =
            isNextTokenThinking ? reasoningMinimumPLogitRangeGPU : answerMinimumPLogitRangeGPU
          let maximumLogit = logits.reduced(.max, axis: [1])
          logits.fill(-Float.infinity, if: logits < (maximumLogit - minimumPLogitRangeGPU))
          nextTokenGPU = Functional.gumbelArgmax(
            logits, axis: 1, scale: temperature
          ).reshaped(format: .NHWC, shape: [1])
        } else {
          nextTokenGPU = Functional.argmax(logits, axis: 1).reshaped(
            format: .NHWC, shape: [1])
        }
        Self.updateLinearCaches(
          &kvCache, from: decodeOutputs, outputOffset: 1, stateCheckpointIndex: 0,
          tokenLength: sequenceLength, inputCaches: nil, configuration: configuration)
        let decodedToken = oldDecodedTokenCPU[0]
        runningContextTokens.append(decodedToken)
        if !hasPaddedImages, runningContextTokens.count % contextCache.checkpointStride == 0 {
          contextCache.save(
            graph: graph, tokens: runningContextTokens,
            checkpointLength: runningContextTokens.count, configuration: configuration,
            isMTPEnabled: storage.isMTPEnabled, kvCache: kvCache, draftCache: draftCache,
            hasher: &contextCacheHasher)
        }
        if decodeIndex > 0 {
          generated.append(decodedToken)
          recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
          recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
            Float(CACurrentMediaTime() - tokenGenerationStartTime)
            + initialTokenGenerationDurationSoFar
          if decodedToken == 248_069 {
            thinkingEnded = true
          }
          if Self.eosTokenIds.contains(decodedToken) {
            shouldAppendPendingToken = false
            break
          }
          switch continuationHandler(
            cachedTokenLength + 1, cachedTokenLength + 1, generated, statistics)
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
        decodeIndex += 1
        if shouldStopAfterSampling { break }
      }
    }
    if shouldAppendPendingToken {
      let lastTokenCPU = nextTokenGPU.toCPU()
      let decodedToken = lastTokenCPU[0]
      generated.append(decodedToken)
      recentInteractionStatistics[interactionStatisticsIndex].tokenGeneratedSoFar += 1
      recentInteractionStatistics[interactionStatisticsIndex].tokenGenerationDurationSoFar =
        Float(CACurrentMediaTime() - tokenGenerationStartTime)
        + initialTokenGenerationDurationSoFar
    } else {
      graph.joined()
    }
    return generated
  }

  private static func resizeDraftCache(
    graph: DynamicGraph, draftCache: inout [DynamicGraph.AnyTensor],
    cacheCapacity: Int, configuration: Qwen3_5ModelConfiguration
  ) {
    guard cacheCapacity > 0 else { return }
    if draftCache.isEmpty {
      draftCache = makeDraftCache(
        graph: graph, capacity: cacheCapacity, configuration: configuration)
      return
    }
    let existingCacheCapacity = draftCache[0].as(of: BFloat16.self).shape[1]
    guard existingCacheCapacity < cacheCapacity else { return }
    let oldKey = draftCache[0].as(of: BFloat16.self)
    let oldValue = draftCache[1].as(of: BFloat16.self)
    let lastHidden = draftCache[2]
    var newKey = graph.variable(
      Tensor<BFloat16>(
        Array(
          repeating: BFloat16.zero,
          count: cacheCapacity * configuration.keyValueHeads * configuration.attentionHeadDim),
        .CPU,
        .NHWC(1, cacheCapacity, configuration.keyValueHeads, configuration.attentionHeadDim)
      ).toGPU(0))
    var newValue = graph.variable(
      Tensor<BFloat16>(
        Array(
          repeating: BFloat16.zero,
          count: cacheCapacity * configuration.keyValueHeads * configuration.attentionHeadDim),
        .CPU,
        .NHWC(1, cacheCapacity, configuration.keyValueHeads, configuration.attentionHeadDim)
      ).toGPU(0))
    newKey[
      0..<1, 0..<existingCacheCapacity, 0..<configuration.keyValueHeads,
      0..<configuration.attentionHeadDim
    ] = oldKey
    newValue[
      0..<1, 0..<existingCacheCapacity, 0..<configuration.keyValueHeads,
      0..<configuration.attentionHeadDim
    ] = oldValue
    graph.garbageCollect()
    draftCache = [newKey, newValue, lastHidden]
  }

  private static func updateDraftLastHidden(
    _ draftCache: inout [DynamicGraph.AnyTensor], from hidden: DynamicGraph.Tensor<BFloat16>,
    rowIndex: Int, configuration: Qwen3_5ModelConfiguration
  ) {
    precondition(draftCache.count > 2)
    let lastHidden = hidden.reshaped(
      .NC(1, configuration.hiddenSize), offset: [rowIndex, 0],
      strides: [configuration.hiddenSize, 1]
    ).copied()
    var lastHiddenCache = draftCache[2].as(of: BFloat16.self)
    lastHiddenCache[0..<1, 0..<configuration.hiddenSize] = lastHidden
  }

  private static func draftCacheInputs(
    _ draftCache: [DynamicGraph.AnyTensor], currentTokenLength: Int,
    configuration: Qwen3_5ModelConfiguration
  ) -> [DynamicGraph.AnyTensor] {
    precondition(!draftCache.isEmpty)
    let draftCacheCapacity = draftCache[0].as(of: BFloat16.self).shape[1]
    precondition(currentTokenLength <= draftCacheCapacity)
    let rowStride = configuration.keyValueHeads * configuration.attentionHeadDim
    return [
      draftCache[0].as(of: BFloat16.self).reshaped(
        .NHWC(
          1, currentTokenLength, configuration.keyValueHeads,
          configuration.attentionHeadDim),
        offset: [0, 0, 0, 0],
        strides: [
          draftCacheCapacity * rowStride, rowStride, configuration.attentionHeadDim, 1,
        ]),
      draftCache[1].as(of: BFloat16.self).reshaped(
        .NHWC(
          1, currentTokenLength, configuration.keyValueHeads,
          configuration.attentionHeadDim),
        offset: [0, 0, 0, 0],
        strides: [
          draftCacheCapacity * rowStride, rowStride, configuration.attentionHeadDim, 1,
        ]),
    ]
  }

  private static func makeDraftCache(
    graph: DynamicGraph, capacity: Int, configuration: Qwen3_5ModelConfiguration
  ) -> [DynamicGraph.AnyTensor] {
    graph.garbageCollect()
    let elementCount = capacity * configuration.keyValueHeads * configuration.attentionHeadDim
    let key = graph.variable(
      Tensor<BFloat16>(
        Array(repeating: BFloat16.zero, count: elementCount), .CPU,
        .NHWC(1, capacity, configuration.keyValueHeads, configuration.attentionHeadDim)
      ).toGPU(0))
    let value = graph.variable(
      Tensor<BFloat16>(
        Array(repeating: BFloat16.zero, count: elementCount), .CPU,
        .NHWC(1, capacity, configuration.keyValueHeads, configuration.attentionHeadDim)
      ).toGPU(0))
    let lastHidden = graph.variable(
      Tensor<BFloat16>(
        Array(repeating: BFloat16.zero, count: configuration.hiddenSize), .CPU,
        .NC(1, configuration.hiddenSize)
      ).toGPU(0))
    return [key, value, lastHidden]
  }

  private static func makeCaches(
    graph: DynamicGraph, capacity: Int, configuration: Qwen3_5ModelConfiguration
  ) -> [DynamicGraph.AnyTensor] {
    graph.garbageCollect()
    var caches = [DynamicGraph.AnyTensor]()
    for layerIndex in 0..<configuration.layers {
      if configuration.isLinearAttentionLayer(layerIndex) {
        let convState = graph.variable(
          Tensor<FloatType>(
            Array(
              repeating: FloatType.zero,
              count: (configuration.linearConvKernel - 1) * configuration.linearConvDim),
            .CPU,
            .NHWC(1, configuration.linearConvKernel - 1, 1, configuration.linearConvDim)
          ).toGPU(0))
        let recurrentState = graph.variable(
          Tensor<Float>(
            Array(
              repeating: Float.zero,
              count: configuration.linearNumValueHeads * configuration.linearKeyHeadDim
                * configuration.linearValueHeadDim),
            .CPU,
            .NHWC(
              1, configuration.linearNumValueHeads, configuration.linearValueHeadDim,
              configuration.linearKeyHeadDim)
          ).toGPU(0))
        caches.append(contentsOf: [convState, recurrentState])
      } else {
        let k = graph.variable(
          Tensor<FloatType>(
            Array(
              repeating: FloatType.zero,
              count: capacity * configuration.keyValueHeads * configuration.attentionHeadDim),
            .CPU,
            .NHWC(1, capacity, configuration.keyValueHeads, configuration.attentionHeadDim)
          ).toGPU(0))
        let v = graph.variable(
          Tensor<FloatType>(
            Array(
              repeating: FloatType.zero,
              count: capacity * configuration.keyValueHeads * configuration.attentionHeadDim),
            .CPU,
            .NHWC(1, capacity, configuration.keyValueHeads, configuration.attentionHeadDim)
          ).toGPU(0))
        caches.append(contentsOf: [k, v])
      }
    }
    return caches
  }

  // Attention KV is append-only. Only linear state and the draft's last hidden row need copies.
  func cacheSnapshot(kvCache: [DynamicGraph.AnyTensor], draftCache: [DynamicGraph.AnyTensor]) -> (
    kvCache: [DynamicGraph.AnyTensor], draftCache: [DynamicGraph.AnyTensor]
  ) {
    var kvCache = kvCache
    var draftCache = draftCache
    if !kvCache.isEmpty {
      for layerIndex in 0..<configuration.layers
      where configuration.isLinearAttentionLayer(layerIndex) {
        kvCache[layerIndex * 2] = kvCache[layerIndex * 2].as(of: FloatType.self).copied()
        kvCache[layerIndex * 2 + 1] = kvCache[layerIndex * 2 + 1].as(of: Float.self).copied()
      }
    }
    if draftCache.count > 2 {
      draftCache[2] = draftCache[2].as(of: BFloat16.self).copied()
    }
    return (kvCache, draftCache)
  }

  private static func resizeCaches(
    graph: DynamicGraph, kvCache: inout [DynamicGraph.AnyTensor], cacheCapacity: Int,
    configuration: Qwen3_5ModelConfiguration
  ) {
    if kvCache.isEmpty {
      kvCache = makeCaches(graph: graph, capacity: cacheCapacity, configuration: configuration)
      return
    }
    var existingCacheCapacity: Int? = nil
    var cursor = 0
    for layerIndex in 0..<configuration.layers {
      if !configuration.isLinearAttentionLayer(layerIndex) {
        existingCacheCapacity = kvCache[cursor].as(of: FloatType.self).shape[1]
        break
      }
      cursor += 2
    }
    guard let existingCacheCapacity = existingCacheCapacity,
      existingCacheCapacity < cacheCapacity
    else {
      return
    }
    cursor = 0
    for layerIndex in 0..<configuration.layers {
      if !configuration.isLinearAttentionLayer(layerIndex) {
        let oldKey = kvCache[cursor].as(of: FloatType.self)
        let oldValue = kvCache[cursor + 1].as(of: FloatType.self)
        var newKey = graph.variable(
          Tensor<FloatType>(
            Array(
              repeating: FloatType.zero,
              count: cacheCapacity * configuration.keyValueHeads * configuration.attentionHeadDim),
            .CPU,
            .NHWC(1, cacheCapacity, configuration.keyValueHeads, configuration.attentionHeadDim)
          ).toGPU(0))
        var newValue = graph.variable(
          Tensor<FloatType>(
            Array(
              repeating: FloatType.zero,
              count: cacheCapacity * configuration.keyValueHeads * configuration.attentionHeadDim),
            .CPU,
            .NHWC(1, cacheCapacity, configuration.keyValueHeads, configuration.attentionHeadDim)
          ).toGPU(0))
        newKey[
          0..<1, 0..<existingCacheCapacity, 0..<configuration.keyValueHeads,
          0..<configuration.attentionHeadDim
        ] = oldKey
        newValue[
          0..<1, 0..<existingCacheCapacity, 0..<configuration.keyValueHeads,
          0..<configuration.attentionHeadDim
        ] = oldValue
        kvCache[cursor] = newKey
        kvCache[cursor + 1] = newValue
      }
      cursor += 2
    }
    graph.garbageCollect()
  }

  private static func cacheInputs(
    _ caches: [DynamicGraph.AnyTensor], currentTokenLength: Int,
    configuration: Qwen3_5ModelConfiguration
  ) -> [DynamicGraph.AnyTensor] {
    var result = [DynamicGraph.AnyTensor]()
    var cursor = 0
    for layerIndex in 0..<configuration.layers {
      if configuration.isLinearAttentionLayer(layerIndex) {
        result.append(caches[cursor])
        result.append(caches[cursor + 1])
      } else {
        result.append(
          caches[cursor].as(of: FloatType.self).reshaped(
            .NHWC(
              1, currentTokenLength, configuration.keyValueHeads, configuration.attentionHeadDim)))
        result.append(
          caches[cursor + 1].as(of: FloatType.self).reshaped(
            .NHWC(
              1, currentTokenLength, configuration.keyValueHeads, configuration.attentionHeadDim)))
      }
      cursor += 2
    }
    return result
  }

  private static func updateLinearCaches(
    _ caches: inout [DynamicGraph.AnyTensor], from outputs: [DynamicGraph.AnyTensor],
    outputOffset: Int, stateCheckpointIndex: Int, tokenLength: Int,
    inputCaches: [DynamicGraph.AnyTensor]?, configuration: Qwen3_5ModelConfiguration
  ) {
    var cacheCursor = 0
    var outputCursor = outputOffset
    for layerIndex in 0..<configuration.layers {
      if configuration.isLinearAttentionLayer(layerIndex) {
        let convStateHistory = outputs[outputCursor].as(of: FloatType.self)
        let recurrentStateHistory = outputs[outputCursor + 1].as(of: Float.self)
        let convStateLength = configuration.linearConvKernel - 1
        let convState: DynamicGraph.Tensor<FloatType>
        if stateCheckpointIndex == 0 {
          convState = convStateHistory.reshaped(
            .NHWC(1, convStateLength, 1, configuration.linearConvDim),
            offset: [0, 0, 0, 0],
            strides: [
              convStateHistory.shape[1] * configuration.linearConvDim,
              configuration.linearConvDim, configuration.linearConvDim, 1,
            ]
          ).copied()
        } else {
          precondition(tokenLength > stateCheckpointIndex)
          guard let inputCaches = inputCaches else {
            fatalError("Input linear caches are required to reconstruct intermediate conv state.")
          }
          let consumedTokenCount = tokenLength - stateCheckpointIndex
          precondition(consumedTokenCount > 0 && consumedTokenCount <= convStateLength)
          let oldTailCount = convStateLength - consumedTokenCount
          let newHeadOffset = max(0, convStateLength - tokenLength)
          let inputConvState = inputCaches[cacheCursor].as(of: FloatType.self)
          let newHead = convStateHistory.reshaped(
            .NHWC(1, consumedTokenCount, 1, configuration.linearConvDim),
            offset: [0, newHeadOffset, 0, 0],
            strides: [
              convStateHistory.shape[1] * configuration.linearConvDim,
              configuration.linearConvDim, configuration.linearConvDim, 1,
            ])
          if oldTailCount > 0 {
            let oldTail = inputConvState.reshaped(
              .NHWC(1, oldTailCount, 1, configuration.linearConvDim),
              offset: [0, consumedTokenCount, 0, 0],
              strides: [
                inputConvState.shape[1] * configuration.linearConvDim,
                configuration.linearConvDim, configuration.linearConvDim, 1,
              ]
            ).copied()
            convState = Functional.concat(axis: 1, oldTail, newHead).copied()
          } else {
            convState = newHead.copied()
          }
        }
        let recurrentState = recurrentStateHistory.reshaped(
          .NHWC(
            1, configuration.linearNumValueHeads, configuration.linearValueHeadDim,
            configuration.linearKeyHeadDim),
          offset: [0, stateCheckpointIndex * configuration.linearNumValueHeads, 0, 0],
          strides: [
            recurrentStateHistory.shape[1] * configuration.linearValueHeadDim
              * configuration.linearKeyHeadDim,
            configuration.linearValueHeadDim * configuration.linearKeyHeadDim,
            configuration.linearKeyHeadDim, 1,
          ]
        ).copied()
        var convStateCache = caches[cacheCursor].as(of: FloatType.self)
        var recurrentStateCache = caches[cacheCursor + 1].as(of: Float.self)
        convStateCache[
          0..<1, 0..<convStateLength, 0..<1, 0..<configuration.linearConvDim
        ] = convState
        recurrentStateCache[
          0..<1, 0..<configuration.linearNumValueHeads, 0..<configuration.linearValueHeadDim,
          0..<configuration.linearKeyHeadDim
        ] = recurrentState
        outputCursor += 2
      }
      cacheCursor += 2
    }
  }

  private static func linearCacheOverrides(
    from outputs: [DynamicGraph.AnyTensor], outputOffset: Int, stateCheckpointIndex: Int,
    tokenLength: Int, inputCaches: [DynamicGraph.AnyTensor]?,
    configuration: Qwen3_5ModelConfiguration
  ) -> [Qwen3_5LinearCacheOverride] {
    var overrides = [Qwen3_5LinearCacheOverride]()
    var cacheCursor = 0
    var outputCursor = outputOffset
    for layerIndex in 0..<configuration.layers {
      if configuration.isLinearAttentionLayer(layerIndex) {
        let convStateHistory = outputs[outputCursor].as(of: FloatType.self)
        let recurrentStateHistory = outputs[outputCursor + 1].as(of: Float.self)
        let convStateLength = configuration.linearConvKernel - 1
        let convState: DynamicGraph.Tensor<FloatType>
        if stateCheckpointIndex == 0 {
          convState = convStateHistory.reshaped(
            .NHWC(1, convStateLength, 1, configuration.linearConvDim),
            offset: [0, 0, 0, 0],
            strides: [
              convStateHistory.shape[1] * configuration.linearConvDim,
              configuration.linearConvDim, configuration.linearConvDim, 1,
            ]
          ).copied()
        } else {
          precondition(tokenLength > stateCheckpointIndex)
          guard let inputCaches = inputCaches else {
            fatalError("Input linear caches are required to reconstruct intermediate conv state.")
          }
          let consumedTokenCount = tokenLength - stateCheckpointIndex
          precondition(consumedTokenCount > 0 && consumedTokenCount <= convStateLength)
          let oldTailCount = convStateLength - consumedTokenCount
          let newHeadOffset = max(0, convStateLength - tokenLength)
          let inputConvState = inputCaches[cacheCursor].as(of: FloatType.self)
          let newHead = convStateHistory.reshaped(
            .NHWC(1, consumedTokenCount, 1, configuration.linearConvDim),
            offset: [0, newHeadOffset, 0, 0],
            strides: [
              convStateHistory.shape[1] * configuration.linearConvDim,
              configuration.linearConvDim, configuration.linearConvDim, 1,
            ])
          if oldTailCount > 0 {
            let oldTail = inputConvState.reshaped(
              .NHWC(1, oldTailCount, 1, configuration.linearConvDim),
              offset: [0, consumedTokenCount, 0, 0],
              strides: [
                inputConvState.shape[1] * configuration.linearConvDim,
                configuration.linearConvDim, configuration.linearConvDim, 1,
              ]
            ).copied()
            convState = Functional.concat(axis: 1, oldTail, newHead).copied()
          } else {
            convState = newHead.copied()
          }
        }
        let recurrentState = recurrentStateHistory.reshaped(
          .NHWC(
            1, configuration.linearNumValueHeads, configuration.linearValueHeadDim,
            configuration.linearKeyHeadDim),
          offset: [0, stateCheckpointIndex * configuration.linearNumValueHeads, 0, 0],
          strides: [
            recurrentStateHistory.shape[1] * configuration.linearValueHeadDim
              * configuration.linearKeyHeadDim,
            configuration.linearValueHeadDim * configuration.linearKeyHeadDim,
            configuration.linearKeyHeadDim, 1,
          ]
        ).copied()
        overrides.append(
          Qwen3_5LinearCacheOverride(
            cacheCursor: cacheCursor, convState: convState, recurrentState: recurrentState))
        outputCursor += 2
      }
      cacheCursor += 2
    }
    return overrides
  }

  private static func resetLinearCaches(
    _ caches: inout [DynamicGraph.AnyTensor], configuration: Qwen3_5ModelConfiguration
  ) {
    var cursor = 0
    for layerIndex in 0..<configuration.layers {
      if configuration.isLinearAttentionLayer(layerIndex) {
        caches[cursor].as(of: FloatType.self).full(0)
        caches[cursor + 1].as(of: Float.self).full(0)
      }
      cursor += 2
    }
  }

  /// Run a fixed set of representative real-layer prefills on disposable state.
  /// The caller owns the graph, stream, no-grad scope, synchronization, and collection.
  @discardableResult
  public func warmupPrefill(graph: DynamicGraph) -> Bool {
    guard configuration.layers >= configuration.fullAttentionInterval else { return false }
    let originalFlags = DynamicGraph.flags
    DynamicGraph.flags.insert(.disableMFAAttentionSpecializingC)
    defer { DynamicGraph.flags = originalFlags }
    let emptyTokens = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: Int32.self)
    let emptyEmbeddings = graph.variable(.GPU(0), format: .NHWC, shape: [0], of: FloatType.self)
    let tokenLength = 2 * chunkedPrefillMaxLength
    let fullAttentionLayer = configuration.fullAttentionInterval - 1
    var configuration = self.configuration
    configuration.layers = 2
    configuration.fullAttentionInterval = 2
    let model = ModelBuilder { (lengths: (cached: Int, count: Int), _) in
      Qwen3_5CausalLM(
        FloatType.self, tokenLength: lengths.count, cachedTokenLength: lengths.cached,
        configuration: configuration, includeLogits: true, outputCacheStates: true,
        outputFinalHiddenState: true, tieEmbedding: self.tieEmbedding)
    }
    model.maxConcurrency = .limit(4)
    // ModelBuilder rebuilds for input-shape changes, not changes to the Swift context tuple.
    // A separate builder is necessary for the terminal graph at the same chunk shape.
    let terminalModel = ModelBuilder { (lengths: (cached: Int, count: Int), _) in
      Qwen3_5CausalLM(
        FloatType.self, tokenLength: lengths.count, cachedTokenLength: lengths.cached,
        configuration: configuration, includeLogits: true, outputCacheStates: true,
        outputFinalHiddenState: false, tieEmbedding: self.tieEmbedding)
    }
    terminalModel.maxConcurrency = .limit(4)
    let drafter = ModelBuilder { (lengths: (cached: Int, count: Int), _) in
      Qwen3_5MTP(
        BFloat16.self, FloatType.self, configuration: configuration, batchSize: 1,
        tokenLength: lengths.count, cachedTokenLength: lengths.cached,
        lastNumberOfTokens: 1, tieEmbedding: self.tieEmbedding)
    }
    drafter.maxConcurrency = .limit(4)
    // A full-attention layer must produce every hidden row to cover interior layers. Only the
    // final row is projected through the real lm_head, avoiding a chunk x vocabulary allocation.
    var caches = Self.makeCaches(
      graph: graph, capacity: tokenLength, configuration: configuration)
    var draftCaches = [DynamicGraph.AnyTensor]()
    var loaded = false
    var hasMTP = false
    var drafterLoaded = false
    var terminalLoaded = false
    var warmedSamplingWithDynamicM = Set<Bool>()
    // Exercise the same fixed-vocabulary greedy, min-p sampling and readback operations as
    // terminal prefill. Draft sampling additionally retains log-sum-exp for verification.
    func warmupSampling(_ logits: DynamicGraph.Tensor<FloatType>, isDraft: Bool)
      -> DynamicGraph.Tensor<Int32>
    {
      precondition(logits.shape == [1, configuration.vocabularySize])
      let token = Functional.argmax(logits, axis: 1).reshaped(format: .NHWC, shape: [1])
      _ = token.toCPU()[0]
      for (temperature, minPLogitRange): (Float, Float) in [
        (1, 2.995_732_3), (0.7, 2.097_012_5),
      ] {
        let minimumPLogitRangeGPU = graph.variable(
          Tensor<FloatType>([FloatType(minPLogitRange)], .CPU, .WC(1, 1)).toGPU(0))
        let maskedLogits = logits.copied()
        let maximumLogit = maskedLogits.reduced(.max, axis: [1])
        maskedLogits.fill(
          -Float.infinity, if: maskedLogits < (maximumLogit - minimumPLogitRangeGPU))
        if isDraft {
          _ = Functional.logSumExp(maskedLogits, axis: [1], scale: 1 / temperature)
        }
        let sampledToken = Functional.gumbelArgmax(maskedLogits, axis: 1, scale: temperature)
          .reshaped(format: .NHWC, shape: [1]).toCPU()
        _ = sampledToken[0]
      }
      return token
    }
    // Dynamic-M pipelines have separate cache entries. Cover small and ordinary matmuls,
    // plus the initial MTP row crossing the 4,096-row dispatch boundary, without another sweep.
    let passes = [
      (cached: 0, count: chunkedPrefillMaxLength),
      (cached: chunkedPrefillMaxLength, count: chunkedPrefillMaxLength),
      (cached: 0, count: 7),
      (cached: 0, count: 512),
      (cached: 0, count: chunkedPrefillMaxLength - 1),
    ]
    for (cached, count) in passes {
      let isDynamicM = count < chunkedPrefillMaxLength
      if isDynamicM {
        caches = Self.makeCaches(graph: graph, capacity: count, configuration: configuration)
        draftCaches = []
      }
      let tokens = graph.variable(
        Tensor<Int32>((0..<count).map { Int32(1 + (cached + $0) % 255) }).toGPU(0))
      let rotary = graph.variable(
        Qwen3_5RotaryEmbedding(
          sequenceLength: count, cachedTokenLength: cached,
          configuration: configuration, of: FloatType.self
        ).toGPU(0))
      let inputs: [DynamicGraph.AnyTensor] =
        [tokens, emptyEmbeddings, emptyTokens, rotary]
        + Self.cacheInputs(
          caches, currentTokenLength: cached + count, configuration: configuration)
      if !loaded {
        model.compile((cached: cached, count: count), inputs: inputs)
        let result = try? graph.openStore(
          filePath, flags: .readOnly,
          externalStore: TensorData.externalStore(filePath: filePath)
        ) { store in
          hasMTP = store.keys.contains("__text_model__[t-mtp.fc-0-0]")
          // Preserve the production codecs and map the representative full-attention layer to
          // its actual checkpoint index. Strict reads prohibit fallback to initialized weights.
          try store.read(
            "text_model", model: model, strict: true,
            codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)]
          ) { name, _, _, _ in
            .continue(
              name.replacingOccurrences(
                of: "model.language_model.layers.1.",
                with: "model.language_model.layers.\(fullAttentionLayer)."))
          }
        }
        guard case .success? = result else { return false }
        loaded = true
      }
      let flags = DynamicGraph.flags
      defer {
        DynamicGraph.flags = flags
      }
      if count < chunkedPrefillMaxLength {
        DynamicGraph.flags.insert(.disableMFAGEMMSpecializingM)
      }
      let outputs = model(
        (cached: cached, count: count), inputs: tokens, Array(inputs.dropFirst())
      )
      Self.updateLinearCaches(
        &caches, from: outputs, outputOffset: 2, stateCheckpointIndex: 0,
        tokenLength: count, inputCaches: nil, configuration: configuration)
      let logits: DynamicGraph.Tensor<FloatType>
      if hasMTP {
        logits = outputs[1].as(of: FloatType.self)
      } else {
        // Without MTP, the terminal full-attention layer computes only the final query row.
        if !terminalLoaded {
          terminalModel.compile((cached: cached, count: count), inputs: inputs)
          terminalModel.parameters.share(from: model.parameters) { name, _ in .continue(name) }
          terminalLoaded = true
        }
        let terminalOutputs = terminalModel(
          (cached: cached, count: count), inputs: tokens, Array(inputs.dropFirst()))
        logits = terminalOutputs[0].as(of: FloatType.self)
      }
      let nextTokenGPU: DynamicGraph.Tensor<Int32>?
      if !warmedSamplingWithDynamicM.contains(count < chunkedPrefillMaxLength) {
        nextTokenGPU = warmupSampling(logits, isDraft: false)
      } else {
        nextTokenGPU = nil
      }
      if hasMTP {
        if draftCaches.isEmpty {
          draftCaches = Self.makeDraftCache(
            graph: graph, capacity: (isDynamicM ? count : tokenLength) + 1,
            configuration: configuration)
        }
        // Production MTP prepends the initial hidden row: its first chunk has 4,097 (or
        // 2,049) rows. These BF16 projections specialize separately from the main decoder.
        let draftCount = cached == 0 ? count + 1 : count
        let draftStart = cached == 0 ? 0 : cached + 1
        let draftTokens = graph.variable(
          Tensor<Int32>((0..<draftCount).map { Int32(1 + (draftStart + $0) % 255) }).toGPU(0))
        var hidden = DynamicGraph.Tensor<BFloat16>(from: outputs[0].as(of: FloatType.self))
        if cached == 0 {
          hidden = Functional.concat(axis: 0, draftCaches[2].as(of: BFloat16.self), hidden)
        }
        let draftRotary = graph.variable(
          Qwen3_5RotaryEmbedding(
            sequenceLength: draftCount, cachedTokenLength: draftStart,
            configuration: configuration, of: FloatType.self
          ).toGPU(0))
        let draftInputs: [DynamicGraph.AnyTensor] =
          [draftTokens, emptyEmbeddings, emptyTokens, hidden, draftRotary]
          + Self.draftCacheInputs(
            draftCaches, currentTokenLength: draftStart + draftCount,
            configuration: configuration)
        if !drafterLoaded {
          drafter.compile((cached: draftStart, count: draftCount), inputs: draftInputs)
          let result = try? graph.openStore(
            filePath, flags: .readOnly,
            externalStore: TensorData.externalStore(filePath: filePath)
          ) { store in
            try store.read(
              "text_model", model: drafter, strict: true,
              codec: [.jit, .i8x, .ezm7, .externalData(.wholeFile)])
          }
          guard case .success? = result else {
            return false
          }
          drafter.parameters.share(from: model.parameters) { name, _ in .continue(name) }
          drafterLoaded = true
        }
        let draftOutputs = drafter(
          (cached: draftStart, count: draftCount), inputs: draftTokens,
          Array(draftInputs.dropFirst()))
        if let nextTokenGPU {
          let draftTokenGPU = warmupSampling(
            draftOutputs[1].as(of: FloatType.self), isDraft: true)
          let tokensCPU = Functional.concat(axis: 0, nextTokenGPU, draftTokenGPU).toCPU()
          _ = tokensCPU[1]
        }
      }
      warmedSamplingWithDynamicM.insert(count < chunkedPrefillMaxLength)
    }
    return true
  }
}

extension Qwen3_5TextGenerator: TextGenerator {
  public var safeTokenizer: TiktokenTokenizer { Self.safeTokenizer }
}
