import Diffusion
import Foundation
import LLM
import NNC
import XCTest

final class DeepSeek4ContextCacheTests: XCTestCase {
  private let modelPath = "/models/deepseek4-test.ckpt"

  private var configuration: DeepSeek4ModelConfiguration {
    var configuration = DeepSeek4ModelConfiguration.deepSeekV4Flash
    configuration.attentionHeadDim = 2
    configuration.indexerHeadDim = 1
    configuration.hiddenSize = 2
    return configuration
  }

  // Raw rows hold their row index and `value`; compressed, indexer, and compressor rows hold
  // `value`, `value + 1`, and `value + 2`.
  private func makeCache(
    graph: DynamicGraph, checkpoint: Int, value: FloatType = 1, capacity: Int = 16_384
  ) -> DeepSeek4TextGenerator.KVCache {
    let config = configuration
    var cache = DeepSeek4TextGenerator.KVCache()
    cache.tokenLength = checkpoint
    cache.rawTokenLength = 160
    cache.compressorInputLengths = Dictionary(
      uniqueKeysWithValues: config.compressionRatios.map { ($0, 8) })
    cache.layers = (0..<config.layers).map { layerIndex in
      let raw = (0..<160).flatMap { row in [FloatType(row), value] }
      var layer = DeepSeek4TextGenerator.KVCache.Layer(
        rawKeyValue: graph.variable(Tensor<FloatType>(raw, .CPU, .NHWC(1, 160, 1, 2)).toGPU(0)))
      switch config.attentionKind(layerIndex: layerIndex) {
      case .raw:
        break
      case .compressed(let ratio), .indexed(let ratio):
        let rows = capacity / ratio
        layer.compressedKeyValue = graph.variable(
          Tensor<FloatType>(Array(repeating: value, count: rows * 2), .CPU, .WC(rows, 2)).toGPU(0))
        layer.compressorInputCache = graph.variable(
          Tensor<FloatType>(Array(repeating: value + 2, count: 16), .CPU, .WC(8, 2)).toGPU(0))
        if case .indexed = config.attentionKind(layerIndex: layerIndex) {
          layer.indexerKeyValue = graph.variable(
            Tensor<Float16>(
              Array(repeating: Float16(value + 1), count: rows), .CPU, .WC(rows, 1)
            ).toGPU(0))
        }
      }
      return layer
    }
    return cache
  }

  func testCheckpointStridesShareSlices() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let graph = DynamicGraph()
    let tokens = (0..<16_385).map(Int32.init)
    var hasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    // A 4,096-token stride snapshots its slice, as every checkpoint did before, then an 8,192-token
    // stride continues the same prefix and snapshots only at multiples of 8,192.
    DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 4_096).save(
      graph: graph, tokens: tokens, checkpointLength: 4_096, configuration: configuration,
      kvCache: makeCache(graph: graph, checkpoint: 4_096), hasher: &hasher)
    let contextCache = DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 8_192)
    for (checkpoint, value) in [(8_192, FloatType(2)), (16_384, 3)] {
      contextCache.save(
        graph: graph, tokens: tokens, checkpointLength: checkpoint, configuration: configuration,
        kvCache: makeCache(graph: graph, checkpoint: checkpoint, value: value), hasher: &hasher)
    }

    var restored = makeCache(graph: graph, checkpoint: 0, value: -1)
    var restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    XCTAssertEqual(
      contextCache.restore(
        graph: graph, tokens: tokens, configuration: configuration, kvCache: &restored,
        hasher: &restoredHasher), 16_384)
    graph.joined()
    XCTAssertEqual(restored.tokenLength, 16_384)
    XCTAssertEqual(restored.rawTokenLength, 128)
    XCTAssertEqual(restored.compressorInputLengths[4], 4)
    XCTAssertEqual(restored.compressorInputLengths[128], 0)
    XCTAssertEqual(restoredHasher.hashedTokenCount, 16_384)
    for (layerIndex, layer) in restored.layers.enumerated() {
      let raw = layer.rawKeyValue.as(of: FloatType.self).toCPU().rawValue
      XCTAssertEqual(raw[0, 0, 0, 0], 32)
      XCTAssertEqual(raw[0, 127, 0, 0], 159)
      XCTAssertEqual(raw[0, 0, 0, 1], 3)
      switch configuration.attentionKind(layerIndex: layerIndex) {
      case .raw:
        continue
      case .compressed(let ratio), .indexed(let ratio):
        let global = layer.compressedKeyValue!.as(of: FloatType.self).toCPU().rawValue
        XCTAssertEqual(global[4_096 / ratio - 1, 1], 1)
        XCTAssertEqual(global[8_192 / ratio - 1, 1], 2)
        // This slice has no snapshot of its own.
        XCTAssertEqual(global[12_288 / ratio - 1, 1], 3)
        XCTAssertEqual(global[16_384 / ratio - 1, 1], 3)
        let compressor = layer.compressorInputCache!.as(of: FloatType.self).toCPU().rawValue
        XCTAssertEqual(compressor[0, 0], ratio == 4 ? 5 : 1)
        if case .indexed = configuration.attentionKind(layerIndex: layerIndex) {
          let indexer = layer.indexerKeyValue!.as(of: Float16.self).toCPU().rawValue
          XCTAssertEqual(indexer[4_096 / ratio - 1, 0], 2)
          XCTAssertEqual(indexer[16_384 / ratio - 1, 0], 4)
        }
      }
    }
    // Shorter prompts resume at the latest snapshot, past slices that have none.
    for (count, expected) in [(14_000, 8_192), (6_000, 4_096)] {
      restored = makeCache(graph: graph, checkpoint: 0, value: -1)
      restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
      XCTAssertEqual(
        contextCache.restore(
          graph: graph, tokens: Array(tokens.prefix(count)), configuration: configuration,
          kvCache: &restored, hasher: &restoredHasher), expected)
    }
  }

  func testFreshHasherKeepsStoredSlices() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let graph = DynamicGraph()
    let tokens = (0..<12_289).map(Int32.init)
    let contextCache = DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 4_096)
    var hasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    contextCache.save(
      graph: graph, tokens: tokens, checkpointLength: 4_096, configuration: configuration,
      kvCache: makeCache(graph: graph, checkpoint: 4_096), hasher: &hasher)
    // A warm continuation saves with a fresh hasher. It keeps the stored slice and fills the
    // missing one before its snapshot.
    var continuationHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    contextCache.save(
      graph: graph, tokens: tokens, checkpointLength: 12_288, configuration: configuration,
      kvCache: makeCache(graph: graph, checkpoint: 12_288, value: 3), hasher: &continuationHasher)

    var restored = makeCache(graph: graph, checkpoint: 0, value: -1)
    var restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    XCTAssertEqual(
      contextCache.restore(
        graph: graph, tokens: tokens, configuration: configuration, kvCache: &restored,
        hasher: &restoredHasher), 12_288)
    graph.joined()
    for (layerIndex, layer) in restored.layers.enumerated() {
      switch configuration.attentionKind(layerIndex: layerIndex) {
      case .raw:
        continue
      case .compressed(let ratio), .indexed(let ratio):
        let global = layer.compressedKeyValue!.as(of: FloatType.self).toCPU().rawValue
        XCTAssertEqual(global[4_096 / ratio - 1, 1], 1)
        XCTAssertEqual(global[8_192 / ratio - 1, 1], 3)
        XCTAssertEqual(global[12_288 / ratio - 1, 1], 3)
      }
    }
  }

  func testMissingSliceStopsRestore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let graph = DynamicGraph()
    let tokens = (0..<12_289).map(Int32.init)
    let contextCache = DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 4_096)
    var hasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    for checkpoint in [4_096, 8_192, 12_288] {
      contextCache.save(
        graph: graph, tokens: tokens, checkpointLength: checkpoint, configuration: configuration,
        kvCache: makeCache(graph: graph, checkpoint: checkpoint), hasher: &hasher)
    }
    // Later snapshots can't be reached without every slice before them.
    let layerIndex = try XCTUnwrap(
      (0..<configuration.layers).first {
        configuration.attentionKind(layerIndex: $0) != .raw
      })
    var segmentHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    let hash: String = segmentHasher.hash(tokens: tokens, to: 8_192)
    _ = graph.openStore(contextCacheStorePath(projectPath: directory.path)!, flags: []) { store in
      store.remove("\(hash)/deepseek4/compressed/\(layerIndex)/kv")
    }
    var restored = makeCache(graph: graph, checkpoint: 0, value: -1)
    var restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    XCTAssertEqual(
      contextCache.restore(
        graph: graph, tokens: tokens, configuration: configuration, kvCache: &restored,
        hasher: &restoredHasher), 4_096)
  }
}
