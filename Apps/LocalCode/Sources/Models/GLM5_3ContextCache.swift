import Foundation
import LLM
import NNC
import ProjectHistoryManager

/// Attention layers store their latent, indexer and pooled rows in fixed 4,096-token slices, which
/// every checkpoint stride shares. KDA states cannot be rewound, so each checkpoint also stores a
/// snapshot of them, and a restore resumes at the latest checkpoint that has one.
public final class GLM5_3ContextCache: ContextCache {
  // A multiple of the indexer's 4-token pools, so each slice holds whole pools.
  static let checkpointStorageStride = 4_096
  /// How often the generator saves a KDA snapshot, a multiple of `checkpointStorageStride`.
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

  func restore(
    graph: DynamicGraph, tokens: [Int32], configuration: GLM5_3ModelConfiguration,
    kvCache: inout GLM5_3TextGenerator.KVCache, hasher: inout ContextCachePrefixHasher,
    embeddingSpans: [EmbedSpan] = []
  ) -> Int {
    restoredTokenLength = 0
    let stride = Self.checkpointStorageStride
    guard let storePath, FileManager.default.fileExists(atPath: storePath),
      tokens.count > stride, kvCache.capacity >= tokens.count
    else { return 0 }
    let rank = configuration.keyValueLowRank
    let indexerWidth = 2 * configuration.indexerHeadDim
    let poolWidth = configuration.indexerHeadDim
    let poolRows = stride / configuration.indexerPool
    let attentionLayers = (0..<configuration.layers).filter {
      !configuration.isLinearAttentionLayer($0)
    }
    let result = graph.openStore(storePath, flags: .readOnly) { store -> Int in
      // At least one token stays to prefill, for the logits of the next.
      let lastSegmentEnd =
        (min(tokens.count - 1, maximumRestoredTokenLength) / stride) * stride
      var segmentHasher = hasher
      var snapshot: (end: Int, key: String, hasher: ContextCachePrefixHasher)?
      for segmentEnd in Swift.stride(from: stride, through: lastSegmentEnd, by: stride) {
        let hash: String = segmentHasher.hash(
          tokens: tokens, to: segmentEnd, embeddingSpans: embeddingSpans)
        let key = "\(hash)/glm5_3"
        var slices = [
          (latent: Tensor<Float16>, indexer: Tensor<Float16>, pooled: Tensor<Float16>)
        ]()
        for layer in attentionLayers {
          guard let latent = store.read("\(key)/latent/\(layer)", kind: .CPU),
            latent.dataType == .Float16, Array(latent.shape) == [1, stride, 1, rank],
            let indexer = store.read("\(key)/indexer/\(layer)", kind: .CPU),
            indexer.dataType == .Float16, Array(indexer.shape) == [1, stride, 1, indexerWidth],
            let pooled = store.read("\(key)/pooled/\(layer)", kind: .CPU),
            pooled.dataType == .Float16, Array(pooled.shape) == [poolRows, poolWidth]
          else { break }
          slices.append(
            (Tensor<Float16>(latent), Tensor<Float16>(indexer), Tensor<Float16>(pooled)))
        }
        guard slices.count == attentionLayers.count else { break }
        let start = segmentEnd - stride
        for (layer, slice) in zip(attentionLayers, slices) {
          var latent = kvCache.layers[layer].latent!
          latent[0..<1, start..<segmentEnd, 0..<1, 0..<rank] = graph.variable(
            slice.latent.toGPU(0))
          var indexer = kvCache.layers[layer].indexer!
          indexer[0..<1, start..<segmentEnd, 0..<1, 0..<indexerWidth] = graph.variable(
            slice.indexer.toGPU(0))
          var pooled = kvCache.layers[layer].pooled!
          pooled[
            (start / configuration.indexerPool)..<(segmentEnd / configuration.indexerPool),
            0..<poolWidth] = graph.variable(slice.pooled.toGPU(0))
        }
        if let marker = store.read("\(key)/snapshot", kind: .CPU), marker.dataType == .Int32,
          Array(marker.shape) == [1], Tensor<Int32>(marker)[0] == Int32(segmentEnd)
        {
          snapshot = (segmentEnd, key, segmentHasher)
        }
      }
      guard let snapshot else { return 0 }
      let convShape = [1, configuration.linearConvKernel - 1, 1, configuration.linearConvDim]
      let recurrentShape = [
        1, configuration.linearHeads, configuration.linearHeadDim, configuration.linearHeadDim,
      ]
      var states = [(layer: Int, conv: Tensor<Float16>, recurrent: Tensor<Float>)]()
      for layer in 0..<configuration.layers where configuration.isLinearAttentionLayer(layer) {
        guard let conv = store.read("\(snapshot.key)/conv/\(layer)", kind: .CPU),
          conv.dataType == .Float16, Array(conv.shape) == convShape,
          let recurrent = store.read("\(snapshot.key)/recurrent/\(layer)", kind: .CPU),
          recurrent.dataType == .Float32, Array(recurrent.shape) == recurrentShape
        else { return 0 }
        states.append((layer, Tensor<Float16>(conv), Tensor<Float>(recurrent)))
      }
      for state in states {
        kvCache.layers[state.layer].convStates[0][
          0..<1, 0..<convShape[1], 0..<1, 0..<convShape[3]] = graph.variable(state.conv.toGPU(0))
        kvCache.layers[state.layer].recurrentStates[0][
          0..<1, 0..<recurrentShape[1], 0..<recurrentShape[2], 0..<recurrentShape[3]] =
          graph.variable(state.recurrent.toGPU(0))
      }
      // The drafter's state saved with this snapshot, restored into allocated drafter caches only
      // when every part is present.
      kvCache.draftData = nil
      if !kvCache.draftKeys.isEmpty {
        let draft = GLM5_3DFlash2Configuration.glm5_3Flash
        let window = draft.windowRows - 1
        let width = draft.targetLayers.count * configuration.hiddenSize
        let keys = kvCache.draftKeys.indices.compactMap {
          store.read("\(snapshot.key)/dflash2/keys/\($0)", kind: .CPU)
        }
        let values = kvCache.draftValues.indices.compactMap {
          store.read("\(snapshot.key)/dflash2/values/\($0)", kind: .CPU)
        }
        if let targets = store.read("\(snapshot.key)/dflash2/targets", kind: .CPU),
          targets.dataType == .Float32, (1...draft.blockSize).contains(targets.shape[0]),
          Array(targets.shape) == [targets.shape[0], width],
          let historyStart = store.read("\(snapshot.key)/dflash2/history", kind: .CPU),
          historyStart.dataType == .Int32, Array(historyStart.shape) == [1],
          keys.count == kvCache.draftKeys.count, values.count == kvCache.draftValues.count,
          (keys + values).allSatisfy({
            $0.dataType == .Float16 && Array($0.shape) == [window, draft.keyValueWidth]
          })
        {
          let rows = targets.shape[0]
          for (layer, (keys, values)) in zip(keys, values).enumerated() {
            var keyCache = kvCache.draftKeys[layer]
            keyCache[0..<window, 0..<draft.keyValueWidth] = graph.variable(
              Tensor<Float16>(keys).toGPU(0))
            var valueCache = kvCache.draftValues[layer]
            valueCache[0..<window, 0..<draft.keyValueWidth] = graph.variable(
              Tensor<Float16>(values).toGPU(0))
          }
          kvCache.draftCacheOrigin = snapshot.end - rows - window
          kvCache.draftData = (
            graph.variable(Tensor<Float>(targets).toGPU(0)), rows, snapshot.end - rows
          )
          kvCache.draftHistoryStart = Int(Tensor<Int32>(historyStart)[0])
        }
      }
      kvCache.tokenLength = snapshot.end
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

  /// Saves every slice up to `checkpointLength` not saved yet, then the KDA snapshot there.
  func save(
    graph: DynamicGraph, tokens: [Int32], checkpointLength: Int,
    configuration: GLM5_3ModelConfiguration, kvCache: GLM5_3TextGenerator.KVCache,
    hasher: inout ContextCachePrefixHasher, embeddingSpans: [EmbedSpan] = []
  ) {
    let stride = Self.checkpointStorageStride
    guard !isReadOnly, let storePath, checkpointLength > 0,
      checkpointLength.isMultiple(of: stride), checkpointLength <= tokens.count,
      checkpointLength == kvCache.tokenLength,
      hasher.hashedTokenCount.isMultiple(of: stride),
      hasher.hashedTokenCount <= checkpointLength
    else { return }
    let rank = configuration.keyValueLowRank
    let indexerWidth = 2 * configuration.indexerHeadDim
    let poolWidth = configuration.indexerHeadDim
    let capacity = kvCache.capacity
    graph.joined()
    var nextHasher = hasher
    let firstSliceEnd = nextHasher.hashedTokenCount + stride
    let result = graph.openStore(storePath, flags: []) { store in
      let existing = Set(store.keys)
      store.withTransaction {
        for end in Swift.stride(from: firstSliceEnd, through: checkpointLength, by: stride) {
          let hash: String = nextHasher.hash(
            tokens: tokens, to: end, embeddingSpans: embeddingSpans)
          let key = "\(hash)/glm5_3"
          let start = end - stride
          for (layerIndex, layer) in kvCache.layers.enumerated() {
            guard let latent = layer.latent, let indexer = layer.indexer,
              let pooled = layer.pooled
            else { continue }
            for (name, tensor, width) in [
              ("latent", latent, rank), ("indexer", indexer, indexerWidth),
            ] {
              let tensorKey = "\(key)/\(name)/\(layerIndex)"
              guard !existing.contains(tensorKey) else { continue }
              let slice = tensor.reshaped(
                .NHWC(1, stride, 1, width), offset: [0, start, 0, 0],
                strides: [capacity * width, width, width, 1]
              ).toCPU()
              graph.joined()
              store.write(tensorKey, tensor: slice.rawValue)
            }
            let pooledKey = "\(key)/pooled/\(layerIndex)"
            if !existing.contains(pooledKey) {
              let rows = stride / configuration.indexerPool
              let slice = pooled.reshaped(
                .WC(rows, poolWidth), offset: [start / configuration.indexerPool, 0],
                strides: [poolWidth, 1]
              ).toCPU()
              graph.joined()
              store.write(pooledKey, tensor: slice.rawValue)
            }
          }
        }
        let hash: String = nextHasher.hash(
          tokens: tokens, to: checkpointLength, embeddingSpans: embeddingSpans)
        let key = "\(hash)/glm5_3"
        for (layerIndex, layer) in kvCache.layers.enumerated() where !layer.convStates.isEmpty {
          let conv = layer.convStates[0].toCPU()
          let recurrent = layer.recurrentStates[0].toCPU()
          graph.joined()
          store.write("\(key)/conv/\(layerIndex)", tensor: conv.rawValue)
          store.write("\(key)/recurrent/\(layerIndex)", tensor: recurrent.rawValue)
        }
        // The drafter's state when a verify's committed rows reach the checkpoint: each layer's keys
        // and values of the window before those rows, the rows, and where its history starts.
        let draft = GLM5_3DFlash2Configuration.glm5_3Flash
        if let draftData = kvCache.draftData, draftData.first + draftData.rows == checkpointLength,
          draftData.rows <= draft.blockSize, !kvCache.draftKeys.isEmpty
        {
          let window = draft.windowRows - 1
          let width = draft.keyValueWidth
          let base = draftData.first - window - kvCache.draftCacheOrigin
          for (layerIndex, (keys, values)) in zip(kvCache.draftKeys, kvCache.draftValues)
            .enumerated()
          {
            for (name, cache) in [("keys", keys), ("values", values)] {
              let rows = cache.reshaped(
                .WC(window, width), offset: [base, 0], strides: [width, 1]
              )
              .toCPU()
              graph.joined()
              store.write("\(key)/dflash2/\(name)/\(layerIndex)", tensor: rows.rawValue)
            }
          }
          let targetWidth = draftData.targets.shape[1]
          let targets = draftData.targets.reshaped(
            .WC(draftData.rows, targetWidth), offset: [0, 0], strides: [targetWidth, 1]
          ).toCPU()
          graph.joined()
          store.write("\(key)/dflash2/targets", tensor: targets.rawValue)
          store.write(
            "\(key)/dflash2/history",
            tensor: Tensor<Int32>([Int32(kvCache.draftHistoryStart)], .CPU, .C(1)))
        }
        // Written last: a snapshot counts only once all of its states are in.
        store.write(
          "\(key)/snapshot", tensor: Tensor<Int32>([Int32(checkpointLength)], .CPU, .C(1)))
      }
    }
    if case .success = result { hasher = nextHasher }
  }
}
