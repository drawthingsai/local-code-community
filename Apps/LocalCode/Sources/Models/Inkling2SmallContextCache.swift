import Foundation
import LLM
import NNC
import ProjectHistoryManager

/// Full-attention layers store their key and value rows in fixed 4,096-token slices, which every
/// checkpoint stride shares. Sliding-window caches and convolution rows cannot be rewound, so each
/// checkpoint also stores a snapshot of them: the last `slidingWindow - 1` rows of every
/// sliding-window layer, and every layer's convolution rows. A restore resumes at the latest
/// checkpoint that has one.
public final class Inkling2SmallContextCache: ContextCache {
  static let checkpointStorageStride = 4_096
  /// How often the generator saves a snapshot, a multiple of `checkpointStorageStride`.
  public let checkpointStride: Int
  private let storePath: String?
  // Model Speed restores without saving, so checkpoint writes stay out of its timings.
  private let isReadOnly: Bool
  private let maximumRestoredTokenLength: Int
  /// How many tokens the latest restore brought back, or nil before any restore.
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

  func saveSuspension(_ data: Data, threadId: Int64) {
    guard let storePath else { return }
    var tensor = Tensor<UInt8>(.CPU, .C(data.count))
    tensor.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { destination.copyMemory(from: $0) }
    }
    DynamicGraph().openStore(storePath, flags: []) { store in
      store.withTransaction {
        store.write("suspension/\(threadId)/state", tensor: tensor)
      }
    }
  }

  func loadSuspension(threadId: Int64) -> Data? {
    guard let storePath, FileManager.default.fileExists(atPath: storePath) else { return nil }
    let result = DynamicGraph().openStore(storePath, flags: .readOnly) { store -> Data? in
      guard let stored = store.read("suspension/\(threadId)/state", kind: .CPU) else {
        return nil
      }
      return Tensor<UInt8>(stored).withUnsafeBytes { Data($0) }
    }
    guard case .success(let data) = result else { return nil }
    return data
  }

  func removeSuspension(threadId: Int64) {
    guard let storePath else { return }
    removeContextCacheSuspension(storePath: storePath, threadId: threadId)
  }

  /// Restores into caches `resizeCaches` allocated empty, which must hold `tokens`.
  func restore(
    graph: DynamicGraph, tokens: [Int32], configuration: Inkling2SmallConfiguration,
    kvCache: inout Inkling2SmallTextGenerator.KVCache, hasher: inout ContextCachePrefixHasher,
    embeddingSpans: [EmbedSpan] = []
  ) -> Int {
    restoredTokenLength = 0
    let stride = Self.checkpointStorageStride
    let window = configuration.slidingWindow - 1
    let kvHeads = configuration.keyValueHeads
    let headDim = configuration.headDim
    let fullLayers = (0..<configuration.layers).filter { configuration.isFullAttentionLayer($0) }
    guard let storePath, FileManager.default.fileExists(atPath: storePath),
      tokens.count > stride, kvCache.layers.count == configuration.layers,
      let fullLayer = fullLayers.first, kvCache.layers[fullLayer].keys.shape[1] >= tokens.count
    else { return 0 }
    let result = graph.openStore(storePath, flags: .readOnly) { store -> Int in
      // At least one token stays to prefill, for the logits of the next.
      let lastSegmentEnd = min(tokens.count - 1, maximumRestoredTokenLength) / stride * stride
      var segmentHasher = hasher
      var snapshot: (end: Int, key: String, hasher: ContextCachePrefixHasher)?
      for segmentEnd in Swift.stride(from: stride, through: lastSegmentEnd, by: stride) {
        let hash: String = segmentHasher.hash(
          tokens: tokens, to: segmentEnd, embeddingSpans: embeddingSpans)
        let key = "\(hash)/inkling2_small"
        var slices = [(keys: Tensor<Float16>, values: Tensor<Float16>)]()
        for layer in fullLayers {
          guard let keys = store.read("\(key)/keys/\(layer)", kind: .CPU),
            keys.dataType == .Float16, Array(keys.shape) == [1, stride, kvHeads, headDim],
            let values = store.read("\(key)/values/\(layer)", kind: .CPU),
            values.dataType == .Float16, Array(values.shape) == [1, stride, kvHeads, headDim]
          else { break }
          slices.append((Tensor<Float16>(keys), Tensor<Float16>(values)))
        }
        guard slices.count == fullLayers.count else { break }
        let rows = (segmentEnd - stride)..<segmentEnd
        for (layer, slice) in zip(fullLayers, slices) {
          var keys = kvCache.layers[layer].keys
          keys[0..<1, rows, 0..<kvHeads, 0..<headDim] = graph.variable(slice.keys.toGPU(0))
          var values = kvCache.layers[layer].values
          values[0..<1, rows, 0..<kvHeads, 0..<headDim] = graph.variable(slice.values.toGPU(0))
        }
        if let marker = store.read("\(key)/snapshot", kind: .CPU), marker.dataType == .Int32,
          Array(marker.shape) == [1], Tensor<Int32>(marker)[0] == Int32(segmentEnd)
        {
          snapshot = (segmentEnd, key, segmentHasher)
        }
      }
      guard let snapshot else { return 0 }
      // Read every state before writing any, so a snapshot missing one changes nothing.
      var windows = [(layer: Int, keys: Tensor<Float16>, values: Tensor<Float16>)]()
      var convolutions = [(layer: Int, rows: [AnyTensor])]()
      let convolutionRows = configuration.convolutionKernel - 1
      for layer in 0..<configuration.layers {
        if !configuration.isFullAttentionLayer(layer) {
          guard let keys = store.read("\(snapshot.key)/window/keys/\(layer)", kind: .CPU),
            keys.dataType == .Float16, Array(keys.shape) == [1, window, kvHeads, headDim],
            let values = store.read("\(snapshot.key)/window/values/\(layer)", kind: .CPU),
            values.dataType == .Float16, Array(values.shape) == [1, window, kvHeads, headDim]
          else { return 0 }
          windows.append((layer, Tensor<Float16>(keys), Tensor<Float16>(values)))
        }
        var rows = [AnyTensor]()
        // Key and value rows in FP16, post-attention and post-MLP rows in FP32.
        for index in 0..<4 {
          let width = index < 2 ? configuration.keyValueDim : configuration.hiddenSize
          guard
            let stored = store.read("\(snapshot.key)/convolution/\(layer)/\(index)", kind: .CPU),
            stored.dataType == (index < 2 ? .Float16 : .Float32),
            Array(stored.shape) == [1, convolutionRows, 1, width]
          else { return 0 }
          rows.append(stored)
        }
        convolutions.append((layer, rows))
      }
      for window in windows {
        var keys = kvCache.layers[window.layer].keys
        keys[0..<1, 0..<window.keys.shape[1], 0..<kvHeads, 0..<headDim] = graph.variable(
          window.keys.toGPU(0))
        var values = kvCache.layers[window.layer].values
        values[0..<1, 0..<window.values.shape[1], 0..<kvHeads, 0..<headDim] = graph.variable(
          window.values.toGPU(0))
      }
      for convolution in convolutions {
        for (index, stored) in convolution.rows.enumerated() {
          let current = kvCache.layers[convolution.layer].convolutionRows[index]
          let width = stored.shape[3]
          if index < 2 {
            var rows = current.as(of: Float16.self)
            rows[0..<1, 0..<convolutionRows, 0..<1, 0..<width] = graph.variable(
              Tensor<Float16>(stored).toGPU(0))
          } else {
            var rows = current.as(of: Float.self)
            rows[0..<1, 0..<convolutionRows, 0..<1, 0..<width] = graph.variable(
              Tensor<Float>(stored).toGPU(0))
          }
        }
      }
      kvCache.tokenLength = snapshot.end
      kvCache.slidingTokenLength = window
      hasher = snapshot.hasher
      return snapshot.end
    }
    switch result {
    case .success(let restoredLength):
      restoredTokenLength = restoredLength
      return restoredLength
    case .failure:
      return 0
    }
  }

  /// Saves every slice up to `checkpointLength` not saved yet, then the snapshot there.
  func save(
    graph: DynamicGraph, tokens: [Int32], checkpointLength: Int,
    configuration: Inkling2SmallConfiguration, kvCache: Inkling2SmallTextGenerator.KVCache,
    hasher: inout ContextCachePrefixHasher, embeddingSpans: [EmbedSpan] = []
  ) {
    let stride = Self.checkpointStorageStride
    let window = configuration.slidingWindow - 1
    guard !isReadOnly, let storePath, checkpointLength > 0, checkpointLength.isMultiple(of: stride),
      checkpointLength <= tokens.count, checkpointLength == kvCache.tokenLength,
      kvCache.slidingTokenLength >= window, kvCache.layers.count == configuration.layers,
      hasher.hashedTokenCount.isMultiple(of: stride),
      hasher.hashedTokenCount <= checkpointLength
    else { return }
    let kvHeads = configuration.keyValueHeads
    let headDim = configuration.headDim
    let kvDim = configuration.keyValueDim
    graph.joined()
    var nextHasher = hasher
    let firstSliceEnd = nextHasher.hashedTokenCount + stride
    let result = graph.openStore(storePath, flags: []) { store in
      let existing = Set(store.keys)
      store.withTransaction {
        for end in Swift.stride(from: firstSliceEnd, through: checkpointLength, by: stride) {
          let hash: String = nextHasher.hash(
            tokens: tokens, to: end, embeddingSpans: embeddingSpans)
          let key = "\(hash)/inkling2_small"
          for (layerIndex, layer) in kvCache.layers.enumerated()
          where configuration.isFullAttentionLayer(layerIndex) {
            for (name, cache) in [("keys", layer.keys), ("values", layer.values)] {
              let tensorKey = "\(key)/\(name)/\(layerIndex)"
              guard !existing.contains(tensorKey) else { continue }
              let slice = cache.reshaped(
                .NHWC(1, stride, kvHeads, headDim), offset: [0, end - stride, 0, 0],
                strides: [cache.shape[1] * kvDim, kvDim, headDim, 1]
              ).toCPU()
              graph.joined()
              store.write(tensorKey, tensor: slice.rawValue)
            }
          }
        }
        let hash: String = nextHasher.hash(
          tokens: tokens, to: checkpointLength, embeddingSpans: embeddingSpans)
        let key = "\(hash)/inkling2_small"
        for (layerIndex, layer) in kvCache.layers.enumerated() {
          if !configuration.isFullAttentionLayer(layerIndex) {
            // The window ends at the cache's last row, which may have moved back to the start.
            for (name, cache) in [("keys", layer.keys), ("values", layer.values)] {
              let rows = cache.reshaped(
                .NHWC(1, window, kvHeads, headDim),
                offset: [0, kvCache.slidingTokenLength - window, 0, 0],
                strides: [cache.shape[1] * kvDim, kvDim, headDim, 1]
              ).toCPU()
              graph.joined()
              store.write("\(key)/window/\(name)/\(layerIndex)", tensor: rows.rawValue)
            }
          }
          // The current rows lead; the buffers their next values go to follow.
          for (index, rows) in layer.convolutionRows.prefix(4).enumerated() {
            let stored: AnyTensor =
              index < 2
              ? rows.as(of: Float16.self).toCPU().rawValue
              : rows.as(of: Float.self).toCPU().rawValue
            graph.joined()
            store.write("\(key)/convolution/\(layerIndex)/\(index)", tensor: stored)
          }
        }
        // Written last: a snapshot counts only once all of its states are in.
        store.write(
          "\(key)/snapshot", tensor: Tensor<Int32>([Int32(checkpointLength)], .CPU, .C(1)))
      }
    }
    if case .success = result { hasher = nextHasher }
  }
}
