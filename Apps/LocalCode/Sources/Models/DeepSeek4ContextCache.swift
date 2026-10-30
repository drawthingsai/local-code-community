import Diffusion
import Foundation
import LLM
import NNC

public final class DeepSeek4ContextCache: DeepSeekContextCache {
  private struct LayerSegment {
    var layerIndex: Int
    var compressionRatio: Int
    var compressedKeyValue: Tensor<FloatType>
    var indexerKeyValue: Tensor<Float16>?
  }

  private struct LayerSnapshot {
    var layerIndex: Int
    var rawKeyValue: Tensor<FloatType>
    var compressorInput: Tensor<FloatType>?
  }

  // Compressed and indexer KV is stored in fixed segments that land on every compressor boundary,
  // so any checkpoint stride reads and writes the same segments. At these boundaries, ratio-4 keeps
  // one four-token source window and ratio-128 has no carry state.
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
      let tensor = Tensor<UInt8>(stored)
      return tensor.withUnsafeBytes { Data($0) }
    }
    guard case .success(let data) = result else { return nil }
    return data
  }

  func removeSuspension(threadId: Int64) {
    guard let storePath else { return }
    removeContextCacheSuspension(storePath: storePath, threadId: threadId)
  }

  func restore(
    graph: DynamicGraph, tokens: [Int32], configuration: DeepSeek4ModelConfiguration,
    kvCache: inout DeepSeek4TextGenerator.KVCache,
    hasher: inout ContextCachePrefixHasher
  ) -> Int {
    restoredTokenLength = 0
    guard let storePath, FileManager.default.fileExists(atPath: storePath) else { return 0 }
    precondition(
      configuration.compressionRatios.allSatisfy {
        Self.checkpointStorageStride.isMultiple(of: $0)
      })
    let result = graph.openStore(storePath, flags: .readOnly) { store -> Int in
      guard tokens.count > Self.checkpointStorageStride else { return 0 }
      let lastSegmentEnd =
        (min(tokens.count - 1, maximumRestoredTokenLength) / Self.checkpointStorageStride)
        * Self.checkpointStorageStride
      var restoredTokenLength = 0
      var restoredHasher = hasher
      var segmentHasher = hasher
      for segmentEnd in stride(
        from: Self.checkpointStorageStride, through: lastSegmentEnd,
        by: Self.checkpointStorageStride)
      {
        let segmentHash: String = segmentHasher.hash(tokens: tokens, to: segmentEnd)
        let segmentStart = segmentEnd - Self.checkpointStorageStride
        // Compressed and indexer segments are mandatory and contiguous, independently of snapshots.
        var layerSegments = [LayerSegment]()
        var isComplete = true
        segmentLoop: for layerIndex in 0..<configuration.layers {
          let compressionRatio: Int
          switch configuration.attentionKind(layerIndex: layerIndex) {
          case .raw:
            continue segmentLoop
          case .compressed(let ratio), .indexed(let ratio):
            compressionRatio = ratio
          }
          let segmentRowCount = Self.checkpointStorageStride / compressionRatio
          guard
            let compressedStored = store.read(
              "\(segmentHash)/deepseek4/compressed/\(layerIndex)/kv", kind: .CPU),
            Array(compressedStored.shape) == [segmentRowCount, configuration.attentionHeadDim]
          else {
            isComplete = false
            break segmentLoop
          }
          var indexerKeyValue: Tensor<Float16>? = nil
          if case .indexed = configuration.attentionKind(layerIndex: layerIndex) {
            guard
              let indexerStored = store.read(
                "\(segmentHash)/deepseek4/indexer/\(layerIndex)/kv", kind: .CPU),
              Array(indexerStored.shape) == [segmentRowCount, configuration.indexerHeadDim]
            else {
              isComplete = false
              break segmentLoop
            }
            indexerKeyValue = Tensor<Float16>(from: indexerStored)
          }
          layerSegments.append(
            LayerSegment(
              layerIndex: layerIndex, compressionRatio: compressionRatio,
              compressedKeyValue: Tensor<FloatType>(from: compressedStored),
              indexerKeyValue: indexerKeyValue))
        }
        guard isComplete else { break }
        for layerSegment in layerSegments {
          let layerIndex = layerSegment.layerIndex
          let segmentRowStart = segmentStart / layerSegment.compressionRatio
          let segmentRowEnd = segmentEnd / layerSegment.compressionRatio
          var compressedKeyValue = kvCache.layers[layerIndex].compressedKeyValue!.as(
            of: FloatType.self)
          compressedKeyValue[
            segmentRowStart..<segmentRowEnd, 0..<configuration.attentionHeadDim
          ] = graph.variable(layerSegment.compressedKeyValue.toGPU(0))
          if let indexerKeyValue = layerSegment.indexerKeyValue {
            var indexerCache = kvCache.layers[layerIndex].indexerKeyValue!.as(of: Float16.self)
            indexerCache[
              segmentRowStart..<segmentRowEnd, 0..<configuration.indexerHeadDim
            ] = graph.variable(indexerKeyValue.toGPU(0))
          }
        }

        // Segments between snapshots, inside a longer prefill chunk, have no resumable snapshot.
        let rawStateLength = min(segmentEnd, configuration.rawWindow)
        var layerSnapshots = [LayerSnapshot]()
        layerSnapshots.reserveCapacity(configuration.layers)
        snapshotLoop: for layerIndex in 0..<configuration.layers {
          guard
            let rawStored = store.read(
              "\(segmentHash)/deepseek4/raw/\(layerIndex)/kv", kind: .CPU),
            Array(rawStored.shape) == [1, rawStateLength, 1, configuration.attentionHeadDim]
          else {
            isComplete = false
            break snapshotLoop
          }
          var compressorInput: Tensor<FloatType>? = nil
          switch configuration.attentionKind(layerIndex: layerIndex) {
          case .raw:
            break
          case .compressed(let ratio), .indexed(let ratio):
            let plan = DeepSeek4CompressionPlan(
              cachedTokenLength: segmentEnd, tokenLength: 1, compressionRatio: ratio)
            if plan.stateCount > 0 {
              guard
                let compressorStored = store.read(
                  "\(segmentHash)/deepseek4/compressor/\(layerIndex)/input", kind: .CPU),
                Array(compressorStored.shape) == [plan.stateCount, configuration.hiddenSize]
              else {
                isComplete = false
                break snapshotLoop
              }
              compressorInput = Tensor<FloatType>(from: compressorStored)
            }
          }
          layerSnapshots.append(
            LayerSnapshot(
              layerIndex: layerIndex, rawKeyValue: Tensor<FloatType>(from: rawStored),
              compressorInput: compressorInput))
        }
        guard isComplete else { continue }
        for layerSnapshot in layerSnapshots {
          let layerIndex = layerSnapshot.layerIndex
          var rawKeyValue = kvCache.layers[layerIndex].rawKeyValue.as(of: FloatType.self)
          rawKeyValue[
            0..<1, 0..<rawStateLength, 0..<1, 0..<configuration.attentionHeadDim
          ] = graph.variable(layerSnapshot.rawKeyValue.toGPU(0))
          if let compressorInput = layerSnapshot.compressorInput {
            var compressorInputCache = kvCache.layers[layerIndex].compressorInputCache!.as(
              of: FloatType.self)
            compressorInputCache[
              0..<compressorInput.shape[0], 0..<configuration.hiddenSize
            ] = graph.variable(compressorInput.toGPU(0))
          }
        }
        restoredTokenLength = segmentEnd
        restoredHasher = segmentHasher
      }
      guard restoredTokenLength > 0 else { return 0 }
      kvCache.tokenLength = restoredTokenLength
      kvCache.rawTokenLength = min(restoredTokenLength, configuration.rawWindow)
      kvCache.compressorInputLengths = Dictionary(
        uniqueKeysWithValues: configuration.compressionRatios.map { compressionRatio in
          let plan = DeepSeek4CompressionPlan(
            cachedTokenLength: restoredTokenLength, tokenLength: 1,
            compressionRatio: compressionRatio)
          return (compressionRatio, plan.stateCount)
        })
      hasher = restoredHasher
      return restoredTokenLength
    }
    switch result {
    case .success(let restoredLength):
      restoredTokenLength = restoredLength
      return restoredLength
    case .failure:
      return 0
    }
  }

  func save(
    graph: DynamicGraph, tokens: [Int32], checkpointLength: Int,
    configuration: DeepSeek4ModelConfiguration,
    kvCache: DeepSeek4TextGenerator.KVCache,
    hasher: inout ContextCachePrefixHasher
  ) {
    guard !isReadOnly, let storePath else { return }
    guard checkpointLength > hasher.hashedTokenCount,
      checkpointLength.isMultiple(of: Self.checkpointStorageStride),
      checkpointLength <= tokens.count, checkpointLength == kvCache.tokenLength
    else {
      return
    }
    precondition(hasher.hashedTokenCount.isMultiple(of: Self.checkpointStorageStride))
    precondition(
      configuration.compressionRatios.allSatisfy {
        Self.checkpointStorageStride.isMultiple(of: $0)
      })
    // Ensure all cache mutations have completed before copying tensors to CPU.
    graph.joined()
    var nextHasher = hasher
    let firstStorageEnd = nextHasher.hashedTokenCount + Self.checkpointStorageStride
    let result = graph.openStore(storePath, flags: []) { store in
      // A continuation's hasher starts from the first segment, so segments already stored are
      // skipped.
      let existing = Set(store.keys)
      store.withTransaction {
        // Fill every segment since the last save or restore before writing the snapshot.
        for end in stride(
          from: firstStorageEnd, through: checkpointLength, by: Self.checkpointStorageStride)
        {
          let hash: String = nextHasher.hash(tokens: tokens, to: end)
          let segmentStart = end - Self.checkpointStorageStride
          for layerIndex in 0..<configuration.layers {
            let compressionRatio: Int
            switch configuration.attentionKind(layerIndex: layerIndex) {
            case .raw:
              continue
            case .compressed(let ratio), .indexed(let ratio):
              compressionRatio = ratio
            }
            let layer = kvCache.layers[layerIndex]
            let segmentRowStart = segmentStart / compressionRatio
            let segmentRowCount = Self.checkpointStorageStride / compressionRatio
            let compressedKey = "\(hash)/deepseek4/compressed/\(layerIndex)/kv"
            if !existing.contains(compressedKey) {
              let compressedKeyValue = layer.compressedKeyValue!.as(of: FloatType.self).reshaped(
                .WC(segmentRowCount, configuration.attentionHeadDim),
                offset: [segmentRowStart, 0],
                strides: [configuration.attentionHeadDim, 1]
              ).copied()
              store.write(compressedKey, tensor: compressedKeyValue.rawValue.toCPU())
            }
            let indexerKey = "\(hash)/deepseek4/indexer/\(layerIndex)/kv"
            if case .indexed = configuration.attentionKind(layerIndex: layerIndex),
              !existing.contains(indexerKey)
            {
              let indexerKeyValue = layer.indexerKeyValue!.as(of: Float16.self).reshaped(
                .WC(segmentRowCount, configuration.indexerHeadDim),
                offset: [segmentRowStart, 0],
                strides: [configuration.indexerHeadDim, 1]
              ).copied()
              store.write(indexerKey, tensor: indexerKeyValue.rawValue.toCPU())
            }
          }
        }

        let checkpointHash: String = nextHasher.hash(tokens: tokens, to: checkpointLength)
        let rawStateLength = min(checkpointLength, configuration.rawWindow)
        precondition(kvCache.rawTokenLength >= rawStateLength)
        let rawStateOffset = kvCache.rawTokenLength - rawStateLength
        for layerIndex in 0..<configuration.layers {
          let layer = kvCache.layers[layerIndex]
          let rawKeyValue = layer.rawKeyValue.as(of: FloatType.self)
          let rawState = rawKeyValue.reshaped(
            .NHWC(1, rawStateLength, 1, configuration.attentionHeadDim),
            offset: [0, rawStateOffset, 0, 0],
            strides: [
              rawKeyValue.shape[1] * configuration.attentionHeadDim,
              configuration.attentionHeadDim, configuration.attentionHeadDim, 1,
            ]
          ).copied()
          store.write(
            "\(checkpointHash)/deepseek4/raw/\(layerIndex)/kv",
            tensor: rawState.rawValue.toCPU())

          switch configuration.attentionKind(layerIndex: layerIndex) {
          case .raw:
            continue
          case .compressed(let compressionRatio), .indexed(let compressionRatio):
            let plan = DeepSeek4CompressionPlan(
              cachedTokenLength: checkpointLength, tokenLength: 1,
              compressionRatio: compressionRatio)
            guard plan.stateCount > 0 else { continue }
            let compressorInputLength = kvCache.compressorInputLengths[compressionRatio]!
            precondition(compressorInputLength >= plan.stateCount)
            let compressorInput = layer.compressorInputCache!.as(of: FloatType.self).reshaped(
              .WC(plan.stateCount, configuration.hiddenSize),
              offset: [compressorInputLength - plan.stateCount, 0],
              strides: [configuration.hiddenSize, 1]
            ).copied()
            store.write(
              "\(checkpointHash)/deepseek4/compressor/\(layerIndex)/input",
              tensor: compressorInput.rawValue.toCPU())
          }
        }
      }
    }
    if case .success = result { hasher = nextHasher }
  }
}
