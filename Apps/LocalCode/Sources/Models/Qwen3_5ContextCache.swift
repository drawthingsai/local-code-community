import Diffusion
import Foundation
import LLM
import NNC
import ProjectHistoryManager

struct Qwen3_5LinearCacheOverride {
  var cacheCursor: Int
  var convState: DynamicGraph.Tensor<FloatType>
  var recurrentState: DynamicGraph.Tensor<Float>
}

public final class Qwen3_5ContextCache: ContextCache {
  public let checkpointStride: Int

  private let storePath: String?
  // Model Speed restores without saving, so checkpoint writes stay out of its timings.
  private let isReadOnly: Bool
  private let maximumRestoredTokenLength: Int
  /// How many tokens the latest restore brought back, or nil before any restore.
  public private(set) var restoredTokenLength: Int?

  public init(projectPath: String?, checkpointStride: Int) {
    self.checkpointStride = checkpointStride
    storePath = contextCacheStorePath(projectPath: projectPath)
    isReadOnly = false
    maximumRestoredTokenLength = .max
  }

  public init(
    storePath: String, checkpointStride: Int, isReadOnly: Bool, maximumRestoredTokenLength: Int
  ) {
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
    graph: DynamicGraph, tokens: [Int32],
    configuration: Qwen3_5ModelConfiguration, isMTPEnabled: Bool,
    kvCache: inout [DynamicGraph.AnyTensor], draftCache: inout [DynamicGraph.AnyTensor],
    hasher: inout ContextCachePrefixHasher, ropeDelta: inout Int, embeddingSpans: [EmbedSpan] = []
  ) -> Int {
    restoredTokenLength = 0
    guard let storePath = storePath else { return 0 }
    guard FileManager.default.fileExists(atPath: storePath) else { return 0 }
    let result = graph.openStore(storePath, flags: .readOnly) { store -> Int in
      guard tokens.count > checkpointStride else { return 0 }
      let lastCheckpointLength =
        (min(tokens.count - 1, maximumRestoredTokenLength) / checkpointStride) * checkpointStride
      var restoredTokenLength = 0
      var checkpointHash: String?
      var restoredHasher = hasher
      for segmentEnd in stride(
        from: checkpointStride, through: lastCheckpointLength, by: checkpointStride)
      {
        var segmentHasher = restoredHasher
        let segmentHash: String = segmentHasher.hash(
          tokens: tokens, to: segmentEnd, embeddingSpans: embeddingSpans)
        let segmentStart = max(0, segmentEnd - checkpointStride)
        let segmentLength = segmentEnd - segmentStart
        var notFound = false
        var cacheCursor = 0
        var kvStates: [(cacheCursor: Int, key: Tensor<FloatType>, value: Tensor<FloatType>)] = []
        for layerIndex in 0..<configuration.layers {
          if !configuration.isLinearAttentionLayer(layerIndex) {
            let shape = [
              1, segmentLength, configuration.keyValueHeads, configuration.attentionHeadDim,
            ]
            guard
              let keyStored = store.read("\(segmentHash)/kv/\(layerIndex)/k", kind: .CPU),
              Array(keyStored.shape) == shape,
              let valueStored = store.read("\(segmentHash)/kv/\(layerIndex)/v", kind: .CPU),
              Array(valueStored.shape) == shape
            else {
              notFound = true
              break
            }
            kvStates.append(
              (
                cacheCursor: cacheCursor, key: Tensor<FloatType>(from: keyStored),
                value: Tensor<FloatType>(from: valueStored)
              ))
          }
          cacheCursor += 2
        }
        if notFound { break }
        let draftKey: Tensor<BFloat16>?
        let draftValue: Tensor<BFloat16>?
        if isMTPEnabled {
          let draftLength = segmentLength
          let draftShape = [
            1, draftLength, configuration.keyValueHeads, configuration.attentionHeadDim,
          ]
          guard
            let draftKeyStored = store.read("\(segmentHash)/draft/k", kind: .CPU),
            Array(draftKeyStored.shape) == draftShape,
            let draftValueStored = store.read("\(segmentHash)/draft/v", kind: .CPU),
            Array(draftValueStored.shape) == draftShape
          else {
            notFound = true
            break
          }
          draftKey = Tensor<BFloat16>(from: draftKeyStored)
          draftValue = Tensor<BFloat16>(from: draftValueStored)
        } else {
          draftKey = nil
          draftValue = nil
        }
        if notFound { break }
        for kvState in kvStates {
          let keyGPU = graph.variable(kvState.key.toGPU(0))
          let valueGPU = graph.variable(kvState.value.toGPU(0))
          var keyCache = kvCache[kvState.cacheCursor].as(of: FloatType.self)
          var valueCache = kvCache[kvState.cacheCursor + 1].as(of: FloatType.self)
          keyCache[
            0..<1, segmentStart..<segmentStart + segmentLength,
            0..<configuration.keyValueHeads, 0..<configuration.attentionHeadDim
          ] = keyGPU
          valueCache[
            0..<1, segmentStart..<segmentStart + segmentLength,
            0..<configuration.keyValueHeads, 0..<configuration.attentionHeadDim
          ] = valueGPU
        }
        if let draftKey = draftKey, let draftValue = draftValue {
          let draftLength = segmentLength
          let draftKeyGPU = graph.variable(draftKey.toGPU(0))
          let draftValueGPU = graph.variable(draftValue.toGPU(0))
          var draftKeyCache = draftCache[0].as(of: BFloat16.self)
          var draftValueCache = draftCache[1].as(of: BFloat16.self)
          draftKeyCache[
            0..<1, segmentStart..<segmentStart + draftLength, 0..<configuration.keyValueHeads,
            0..<configuration.attentionHeadDim
          ] = draftKeyGPU
          draftValueCache[
            0..<1, segmentStart..<segmentStart + draftLength, 0..<configuration.keyValueHeads,
            0..<configuration.attentionHeadDim
          ] = draftValueGPU
        }
        restoredTokenLength = segmentEnd
        checkpointHash = segmentHash
        restoredHasher = segmentHasher
      }
      guard restoredTokenLength > 0, let checkpointHash = checkpointHash else { return 0 }
      let restoredRopeDelta: Int
      if let stored = store.read("\(checkpointHash)/rope_delta", kind: .CPU),
        stored.dataType == .Int32, Array(stored.shape) == [1]
      {
        restoredRopeDelta = Int(Tensor<Int32>(stored)[0])
      } else if embeddingSpans.contains(where: { $0.start < restoredTokenLength }) {
        return 0
      } else {
        // Legacy text-only checkpoints have no rotary offset.
        restoredRopeDelta = 0
      }
      var linearStates = [
        (
          cacheCursor: Int, convState: Tensor<FloatType>, recurrentState: Tensor<Float>
        )
      ]()
      var cacheCursor = 0
      for layerIndex in 0..<configuration.layers {
        if configuration.isLinearAttentionLayer(layerIndex) {
          let convShape = [
            1, configuration.linearConvKernel - 1, 1, configuration.linearConvDim,
          ]
          let recurrentShape = [
            1, configuration.linearNumValueHeads, configuration.linearValueHeadDim,
            configuration.linearKeyHeadDim,
          ]
          guard
            let convStored = store.read("\(checkpointHash)/linear/\(layerIndex)/conv", kind: .CPU),
            Array(convStored.shape) == convShape,
            let recurrentStored = store.read(
              "\(checkpointHash)/linear/\(layerIndex)/recurrent", kind: .CPU),
            Array(recurrentStored.shape) == recurrentShape
          else {
            return 0
          }
          linearStates.append(
            (
              cacheCursor: cacheCursor, convState: Tensor<FloatType>(from: convStored),
              recurrentState: Tensor<Float>(from: recurrentStored)
            ))
        }
        cacheCursor += 2
      }
      let draftLastHidden: Tensor<BFloat16>?
      if isMTPEnabled {
        let lastHiddenShape = [1, configuration.hiddenSize]
        guard
          let lastHiddenStored = store.read("\(checkpointHash)/draft/last_hidden", kind: .CPU),
          Array(lastHiddenStored.shape) == lastHiddenShape
        else {
          return 0
        }
        draftLastHidden = Tensor<BFloat16>(from: lastHiddenStored)
      } else {
        draftLastHidden = nil
      }
      for linearState in linearStates {
        var convStateCache = kvCache[linearState.cacheCursor].as(of: FloatType.self)
        var recurrentStateCache = kvCache[linearState.cacheCursor + 1].as(of: Float.self)
        convStateCache[
          0..<1, 0..<configuration.linearConvKernel - 1, 0..<1,
          0..<configuration.linearConvDim
        ] = graph.variable(linearState.convState.toGPU(0))
        recurrentStateCache[
          0..<1, 0..<configuration.linearNumValueHeads, 0..<configuration.linearValueHeadDim,
          0..<configuration.linearKeyHeadDim
        ] = graph.variable(linearState.recurrentState.toGPU(0))
      }
      if let draftLastHidden = draftLastHidden {
        var lastHiddenCache = draftCache[2].as(of: BFloat16.self)
        lastHiddenCache[0..<1, 0..<configuration.hiddenSize] = graph.variable(
          draftLastHidden.toGPU(0))
      }
      ropeDelta = restoredRopeDelta
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
    configuration: Qwen3_5ModelConfiguration, isMTPEnabled: Bool,
    kvCache: [DynamicGraph.AnyTensor], draftCache: [DynamicGraph.AnyTensor],
    hasher: inout ContextCachePrefixHasher,
    linearOverrides: [Qwen3_5LinearCacheOverride]? = nil,
    draftLastHiddenOverride: DynamicGraph.Tensor<BFloat16>? = nil,
    ropeDelta: Int = 0, embeddingSpans: [EmbedSpan] = []
  ) {
    guard !isReadOnly, let storePath = storePath else { return }
    guard checkpointLength > 0, checkpointLength % checkpointStride == 0,
      checkpointLength <= tokens.count
    else {
      return
    }
    let checkpointHash: String = hasher.hash(
      tokens: tokens, to: checkpointLength, embeddingSpans: embeddingSpans)
    _ = graph.openStore(storePath, flags: []) { store in
      store.withTransaction {
        store.write(
          "\(checkpointHash)/rope_delta", tensor: Tensor<Int32>([Int32(ropeDelta)], .CPU, .C(1)))
        write(
          store: store, checkpointHash: checkpointHash, checkpointLength: checkpointLength,
          configuration: configuration, isMTPEnabled: isMTPEnabled, kvCache: kvCache,
          draftCache: draftCache, linearOverrides: linearOverrides,
          draftLastHiddenOverride: draftLastHiddenOverride)
      }
    }
  }

  private func write(
    store: DynamicGraph.Store, checkpointHash: String, checkpointLength: Int,
    configuration: Qwen3_5ModelConfiguration, isMTPEnabled: Bool,
    kvCache: [DynamicGraph.AnyTensor], draftCache: [DynamicGraph.AnyTensor],
    linearOverrides: [Qwen3_5LinearCacheOverride]?,
    draftLastHiddenOverride: DynamicGraph.Tensor<BFloat16>?
  ) {
    let segmentStart = max(0, checkpointLength - checkpointStride)
    let segmentLength = checkpointLength - segmentStart
    var overrideByCursor = [Int: Qwen3_5LinearCacheOverride]()
    if let linearOverrides = linearOverrides {
      for linearOverride in linearOverrides {
        overrideByCursor[linearOverride.cacheCursor] = linearOverride
      }
    }
    var cacheCursor = 0
    for layerIndex in 0..<configuration.layers {
      if configuration.isLinearAttentionLayer(layerIndex) {
        if let linearOverride = overrideByCursor[cacheCursor] {
          store.write(
            "\(checkpointHash)/linear/\(layerIndex)/conv",
            tensor: linearOverride.convState.rawValue.toCPU())
          store.write(
            "\(checkpointHash)/linear/\(layerIndex)/recurrent",
            tensor: linearOverride.recurrentState.rawValue.toCPU())
        } else {
          store.write(
            "\(checkpointHash)/linear/\(layerIndex)/conv",
            tensor: kvCache[cacheCursor].as(of: FloatType.self).rawValue.toCPU())
          store.write(
            "\(checkpointHash)/linear/\(layerIndex)/recurrent",
            tensor: kvCache[cacheCursor + 1].as(of: Float.self).rawValue.toCPU())
        }
      } else {
        let key = kvCache[cacheCursor].as(of: FloatType.self).reshaped(
          .NHWC(1, segmentLength, configuration.keyValueHeads, configuration.attentionHeadDim),
          offset: [0, segmentStart, 0, 0],
          strides: [
            kvCache[cacheCursor].as(of: FloatType.self).shape[1] * configuration.keyValueHeads
              * configuration.attentionHeadDim,
            configuration.keyValueHeads * configuration.attentionHeadDim,
            configuration.attentionHeadDim, 1,
          ]
        ).copied()
        let value = kvCache[cacheCursor + 1].as(of: FloatType.self).reshaped(
          .NHWC(1, segmentLength, configuration.keyValueHeads, configuration.attentionHeadDim),
          offset: [0, segmentStart, 0, 0],
          strides: [
            kvCache[cacheCursor + 1].as(of: FloatType.self).shape[1]
              * configuration.keyValueHeads * configuration.attentionHeadDim,
            configuration.keyValueHeads * configuration.attentionHeadDim,
            configuration.attentionHeadDim, 1,
          ]
        ).copied()
        store.write("\(checkpointHash)/kv/\(layerIndex)/k", tensor: key.rawValue.toCPU())
        store.write("\(checkpointHash)/kv/\(layerIndex)/v", tensor: value.rawValue.toCPU())
      }
      cacheCursor += 2
    }
    if isMTPEnabled {
      let draftLength = segmentLength
      let draftKey = draftCache[0].as(of: BFloat16.self).reshaped(
        .NHWC(1, draftLength, configuration.keyValueHeads, configuration.attentionHeadDim),
        offset: [0, segmentStart, 0, 0],
        strides: [
          draftCache[0].as(of: BFloat16.self).shape[1] * configuration.keyValueHeads
            * configuration.attentionHeadDim,
          configuration.keyValueHeads * configuration.attentionHeadDim,
          configuration.attentionHeadDim, 1,
        ]
      ).copied()
      let draftValue = draftCache[1].as(of: BFloat16.self).reshaped(
        .NHWC(1, draftLength, configuration.keyValueHeads, configuration.attentionHeadDim),
        offset: [0, segmentStart, 0, 0],
        strides: [
          draftCache[1].as(of: BFloat16.self).shape[1] * configuration.keyValueHeads
            * configuration.attentionHeadDim,
          configuration.keyValueHeads * configuration.attentionHeadDim,
          configuration.attentionHeadDim, 1,
        ]
      ).copied()
      store.write("\(checkpointHash)/draft/k", tensor: draftKey.rawValue.toCPU())
      store.write("\(checkpointHash)/draft/v", tensor: draftValue.rawValue.toCPU())
      if let draftLastHiddenOverride = draftLastHiddenOverride {
        store.write(
          "\(checkpointHash)/draft/last_hidden", tensor: draftLastHiddenOverride.rawValue.toCPU())
      } else {
        store.write(
          "\(checkpointHash)/draft/last_hidden",
          tensor: draftCache[2].as(of: BFloat16.self).rawValue.toCPU())
      }
    }
  }
}
