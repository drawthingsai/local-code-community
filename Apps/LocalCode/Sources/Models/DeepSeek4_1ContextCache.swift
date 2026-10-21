import Foundation
import LLM
import NNC
import ProjectHistoryManager

public final class DeepSeek4_1ContextCache: DeepSeekContextCache {
  private struct LayerState {
    var rawKeyValue: Tensor<Float16>?
    var compressedKeyValue: Tensor<Float16>?
    var indexerKeyValue: Tensor<Float16>?
  }

  // Global KV is stored in fixed slices, which both compressor ratios divide, so there is no
  // compressor carry to save and any checkpoint stride reads and writes the same slices.
  static let checkpointStorageStride = 4_096
  // How often the generator saves a resumable local snapshot, a multiple of
  // `checkpointStorageStride`.
  public let checkpointStride: Int
  private let storePath: String?
  // Model Speed restores without saving, so checkpoint writes stay out of its timings.
  private let isReadOnly: Bool
  private let maximumRestoredTokenLength: Int
  public private(set) var restoredTokenLength: Int?

  public init(projectPath: String?, checkpointStride: Int) {
    precondition(
      checkpointStride > 0 && checkpointStride.isMultiple(of: Self.checkpointStorageStride))
    self.checkpointStride = checkpointStride
    storePath = contextCacheStorePath(projectPath: projectPath)
    isReadOnly = false
    maximumRestoredTokenLength = .max
  }

  public init(
    storePath: String, checkpointStride: Int, isReadOnly: Bool, maximumRestoredTokenLength: Int
  ) {
    precondition(
      checkpointStride > 0 && checkpointStride.isMultiple(of: Self.checkpointStorageStride))
    self.checkpointStride = checkpointStride
    self.storePath = storePath
    self.isReadOnly = isReadOnly
    self.maximumRestoredTokenLength = maximumRestoredTokenLength
  }

  static func history(tokens: [Int32], to end: Int, embeddingSpans: [EmbedSpan], count: Int)
    -> [Int32]
  {
    let image = embeddingSpans.last { $0.kind == .image && $0.start < end }
    if let image, image.end >= end { return [] }
    let start = max(max(0, end - count), Int(image?.end ?? 0))
    return Array(tokens[start..<end])
  }

  func restore(
    graph: DynamicGraph, tokens: [Int32], configuration: DeepSeek4_1ModelConfiguration,
    boundedReplay: Bool, kvCache: inout DeepSeek4_1TextGenerator.KVCache,
    hasher: inout ContextCachePrefixHasher, embeddingSpans: [EmbedSpan] = []
  ) -> Int {
    restoredTokenLength = 0
    guard let storePath, FileManager.default.fileExists(atPath: storePath),
      tokens.count > Self.checkpointStorageStride
    else { return 0 }
    let mode = boundedReplay ? "boundedReplay" : "full"
    let result = graph.openStore(storePath, flags: .readOnly) { store -> Int in
      let lastSegmentEnd =
        (min(tokens.count - 1, maximumRestoredTokenLength) / Self.checkpointStorageStride)
        * Self.checkpointStorageStride
      var restoredTokenLength = 0
      var segmentHasher = hasher
      for segmentEnd in stride(
        from: Self.checkpointStorageStride, through: lastSegmentEnd,
        by: Self.checkpointStorageStride)
      {
        let segmentHash: String = segmentHasher.hash(
          tokens: tokens, to: segmentEnd, embeddingSpans: embeddingSpans)
        let key = "\(segmentHash)/deepseek4_1/\(mode)"
        var states = [LayerState](repeating: LayerState(), count: configuration.layers)
        var complete = true
        // Global/index slices are mandatory and contiguous, independently of local snapshots.
        for layer in configuration.kvSourceLayers {
          let ratio = configuration.compressionRatios[layer]
          precondition(Self.checkpointStorageStride.isMultiple(of: ratio))
          let rows = Self.checkpointStorageStride / ratio
          guard let global = store.read("\(key)/compressed/\(layer)/kv", kind: .CPU),
            global.dataType == .Float16,
            Array(global.shape) == [rows, configuration.attentionHeadDim],
            let indexer = store.read("\(key)/indexer/\(layer)/kv", kind: .CPU),
            indexer.dataType == .Float16,
            Array(indexer.shape) == [rows, configuration.indexerHeadDim]
          else {
            complete = false
            break
          }
          states[layer].compressedKeyValue = Tensor<Float16>(global)
          states[layer].indexerKeyValue = Tensor<Float16>(indexer)
        }
        guard complete else { break }
        for layer in configuration.kvSourceLayers {
          let ratio = configuration.compressionRatios[layer]
          let start = (segmentEnd - Self.checkpointStorageStride) / ratio
          let end = segmentEnd / ratio
          var global = kvCache.layers[layer].compressedKeyValue!
          var indexer = kvCache.layers[layer].indexerKeyValue!
          global[start..<end, 0..<configuration.attentionHeadDim] = graph.variable(
            states[layer].compressedKeyValue!.toGPU(0))
          indexer[start..<end, 0..<configuration.indexerHeadDim] = graph.variable(
            states[layer].indexerKeyValue!.toGPU(0))
        }
        // Slices between snapshots, such as inside an image or a longer prefill chunk, have no
        // resumable local snapshot.
        guard let storedLengths = store.read("\(key)/raw_lengths", kind: .CPU),
          storedLengths.dataType == .Int32, Array(storedLengths.shape) == [configuration.layers]
        else { continue }
        let lengths = Tensor<Int32>(storedLengths)
        let rawLengths = (0..<configuration.layers).map { Int(lengths[$0]) }
        guard
          rawLengths.enumerated().allSatisfy({ layer, length in
            if !boundedReplay || layer < configuration.candidateSourceLayer {
              return length == configuration.rawWindow
            }
            return (0...configuration.rawWindow).contains(length)
          })
        else { continue }
        if boundedReplay, rawLengths[configuration.candidateSourceLayer...].contains(0),
          tokens.count - segmentEnd < configuration.rawWindow
        {
          continue
        }
        for layer in 0..<configuration.layers where rawLengths[layer] > 0 {
          guard let raw = store.read("\(key)/raw/\(layer)/kv", kind: .CPU),
            raw.dataType == .Float16,
            Array(raw.shape) == [rawLengths[layer], configuration.attentionHeadDim]
          else {
            complete = false
            break
          }
          states[layer].rawKeyValue = Tensor<Float16>(raw)
        }
        guard complete else { continue }
        for layer in 0..<configuration.layers {
          if let raw = states[layer].rawKeyValue {
            var destination = kvCache.layers[layer].rawKeyValue
            destination[0..<rawLengths[layer], 0..<configuration.attentionHeadDim] = graph.variable(
              raw.toGPU(0))
          }
          kvCache.layers[layer].rawTokenLength = rawLengths[layer]
        }
        restoredTokenLength = segmentEnd
        hasher = segmentHasher
      }
      guard restoredTokenLength > 0 else { return 0 }
      kvCache.tokenLength = restoredTokenLength
      kvCache.history = Self.history(
        tokens: tokens, to: restoredTokenLength,
        embeddingSpans: embeddingSpans, count: configuration.engram.maxNgramSize - 1)
      return restoredTokenLength
    }
    switch result {
    case .success(let restoredLength):
      restoredTokenLength = restoredLength
      return restoredLength
    case .failure: return 0
    }
  }

  func save(
    graph: DynamicGraph, tokens: [Int32], checkpointLength: Int,
    configuration: DeepSeek4_1ModelConfiguration, boundedReplay: Bool,
    kvCache: DeepSeek4_1TextGenerator.KVCache, hasher: inout ContextCachePrefixHasher,
    embeddingSpans: [EmbedSpan] = []
  ) {
    guard !isReadOnly, let storePath, checkpointLength > 0,
      checkpointLength.isMultiple(of: Self.checkpointStorageStride),
      checkpointLength <= tokens.count,
      checkpointLength == kvCache.tokenLength
    else { return }
    precondition(hasher.hashedTokenCount.isMultiple(of: Self.checkpointStorageStride))
    graph.joined()
    var nextHasher = hasher
    let firstStorageEnd = nextHasher.hashedTokenCount + Self.checkpointStorageStride
    let mode = boundedReplay ? "boundedReplay" : "full"
    let result = graph.openStore(storePath, flags: []) { store in
      let existing = Set(store.keys)
      store.withTransaction {
        // Fill every deferred fixed-size slice before publishing the current local snapshot.
        for end in stride(
          from: firstStorageEnd, through: checkpointLength, by: Self.checkpointStorageStride)
        {
          let hash: String = nextHasher.hash(
            tokens: tokens, to: end, embeddingSpans: embeddingSpans)
          let key = "\(hash)/deepseek4_1/\(mode)"
          for layerIndex in configuration.kvSourceLayers {
            let layer = kvCache.layers[layerIndex]
            let ratio = configuration.compressionRatios[layerIndex]
            precondition(Self.checkpointStorageStride.isMultiple(of: ratio))
            let start = (end - Self.checkpointStorageStride) / ratio
            let rows = Self.checkpointStorageStride / ratio
            for (name, tensor, width) in [
              ("compressed", layer.compressedKeyValue!, configuration.attentionHeadDim),
              ("indexer", layer.indexerKeyValue!, configuration.indexerHeadDim),
            ] {
              let tensorKey = "\(key)/\(name)/\(layerIndex)/kv"
              if existing.contains(tensorKey) { continue }
              let slice = tensor.reshaped(
                .WC(rows, width), offset: [start, 0], strides: [width, 1]
              ).toCPU()
              graph.joined()
              store.write(tensorKey, tensor: slice.rawValue)
            }
          }
        }
        let hash: String = nextHasher.hash(
          tokens: tokens, to: checkpointLength, embeddingSpans: embeddingSpans)
        let key = "\(hash)/deepseek4_1/\(mode)"
        let rawLengths = kvCache.layers.map { min($0.rawTokenLength, configuration.rawWindow) }
        store.write(
          "\(key)/raw_lengths",
          tensor: Tensor<Int32>(rawLengths.map(Int32.init), .CPU, .C(configuration.layers)))
        for (layerIndex, layer) in kvCache.layers.enumerated() {
          let length = rawLengths[layerIndex]
          if length > 0 {
            let raw = layer.rawKeyValue.reshaped(
              .WC(length, configuration.attentionHeadDim),
              offset: [layer.rawTokenLength - length, 0],
              strides: [configuration.attentionHeadDim, 1]
            ).toCPU()
            graph.joined()
            store.write("\(key)/raw/\(layerIndex)/kv", tensor: raw.rawValue)
          } else {
            store.remove("\(key)/raw/\(layerIndex)/kv")
          }
        }
      }
    }
    if case .success = result { hasher = nextHasher }
  }
}
