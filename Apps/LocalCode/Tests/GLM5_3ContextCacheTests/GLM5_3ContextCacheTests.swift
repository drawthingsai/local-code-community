import Foundation
import LLM
import NNC
import XCTest

final class GLM5_3ContextCacheTests: XCTestCase {
  private let modelPath = "/models/glm5_3-test.ckpt"
  private var configuration: GLM5_3ModelConfiguration {
    var config = GLM5_3ModelConfiguration.glm5_3Flash
    config.layers = 4
    config.keyValueLowRank = 2
    config.indexerHeadDim = 1
    config.linearHeads = 1
    config.linearHeadDim = 2
    return config
  }

  private func makeCache(_ graph: DynamicGraph, length: Int, value: Float)
    -> GLM5_3TextGenerator.KVCache
  {
    var cache = GLM5_3TextGenerator.KVCache()
    GLM5_3TextGenerator.resizeCaches(
      graph: graph, kvCache: &cache, capacity: 20_480, configuration: configuration)
    for layer in cache.layers {
      layer.latent?.full(value)
      layer.indexer?.full(value + 1)
      layer.pooled?.full(value + 2)
      for state in layer.convStates { state.full(value + 3) }
      for state in layer.recurrentStates { state.full(Float(value) + 4) }
    }
    cache.tokenLength = length
    return cache
  }

  func testCheckpointsShareSlicesAndRestoreLatestSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let graph = DynamicGraph()
    let tokens = (0..<16_385).map(Int32.init)
    var hasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    for (length, stride, value) in [(4096, 4096, Float(1)), (8192, 8192, 2), (16384, 8192, 3)] {
      GLM5_3ContextCache(projectPath: directory.path, checkpointStride: stride).save(
        graph: graph, tokens: tokens, checkpointLength: length, configuration: configuration,
        kvCache: makeCache(graph, length: length, value: value), hasher: &hasher)
    }
    let context = GLM5_3ContextCache(projectPath: directory.path, checkpointStride: 4096)
    for (count, expected, value) in [
      (16385, 16384, Float(3)), (14000, 8192, 2), (8192, 4096, 1), (4096, 0, -5),
    ] {
      var cache = makeCache(graph, length: 0, value: -5)
      var restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
      XCTAssertEqual(
        context.restore(
          graph: graph, tokens: Array(tokens.prefix(count)), configuration: configuration,
          kvCache: &cache, hasher: &restoredHasher), expected)
      graph.joined()
      XCTAssertEqual(cache.tokenLength, expected)
      XCTAssertEqual(restoredHasher.hashedTokenCount, expected)
      XCTAssertEqual(context.restoredTokenLength, expected)
      XCTAssertEqual(cache.layers[0].recurrentStates[0].toCPU().rawValue[0, 0, 0, 0], value + 4)
      XCTAssertEqual(cache.layers[0].convStates[0].toCPU().rawValue[0, 0, 0, 0], Float16(value + 3))
      if expected > 0 {
        let latent = cache.layers[3].latent!.toCPU().rawValue
        XCTAssertEqual(latent[0, 4095, 0, 0], 1)
        if expected >= 8192 { XCTAssertEqual(latent[0, 8191, 0, 0], 2) }
        XCTAssertEqual(
          cache.layers[3].indexer!.toCPU().rawValue[0, expected - 1, 0, 0], Float16(value + 1))
        XCTAssertEqual(
          cache.layers[3].pooled!.toCPU().rawValue[expected / 4 - 1, 0], Float16(value + 2))
      }
    }
    // An interrupted snapshot without its completion marker must not be restored.
    var keyHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    let hash: String = keyHasher.hash(tokens: tokens, to: 16_384)
    _ = graph.openStore(contextCacheStorePath(projectPath: directory.path)!, flags: []) { store in
      store.remove("\(hash)/glm5_3/snapshot")
    }
    var cache = makeCache(graph, length: 0, value: -5)
    var restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    XCTAssertEqual(
      context.restore(
        graph: graph, tokens: tokens, configuration: configuration,
        kvCache: &cache, hasher: &restoredHasher), 8192)
    XCTAssertEqual(cache.layers[0].recurrentStates[0].toCPU().rawValue[0, 0, 0, 0], 6)
  }

  func testSnapshotCopiesRecurrentStateAndCacheGrowthPreservesRows() {
    let graph = DynamicGraph()
    var cache = makeCache(graph, length: 4096, value: 7)
    let snapshot = cache.snapshot()
    cache.layers[0].convStates[0].full(100)
    cache.layers[0].recurrentStates[0].full(100)
    GLM5_3TextGenerator.resizeCaches(
      graph: graph, kvCache: &cache, capacity: 24_576, configuration: configuration)
    graph.joined()
    XCTAssertEqual(snapshot.layers[0].convStates[0].toCPU().rawValue[0, 0, 0, 0], 10)
    XCTAssertEqual(snapshot.layers[0].recurrentStates[0].toCPU().rawValue[0, 0, 0, 0], 11)
    XCTAssertEqual(cache.layers[3].latent!.toCPU().rawValue[0, 4095, 0, 0], 7)
    XCTAssertEqual(cache.capacity, 24576)
    XCTAssertEqual(cache.tokenLength, 4096)
  }

  func testDrafterStateRoundTripAndIsolation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let contextCache = GLM5_3ContextCache(projectPath: directory.path, checkpointStride: 4096)
    let graph = DynamicGraph()
    let tokens = (0..<8_193).map(Int32.init)
    let draft = GLM5_3DFlash2Configuration.glm5_3Flash
    let window = draft.windowRows - 1
    let cacheRows = window + 20
    let keyValueWidth = draft.keyValueWidth
    let width = draft.targetLayers.count * configuration.hiddenSize
    // Row r of a layer's caches holds r % 1,024, the layer, and 0 for keys or 1 for values.
    func draftCaches(kind: Float16) -> [DynamicGraph.Tensor<Float16>] {
      (0..<draft.layers).map { layer in
        var values = [Float16](repeating: 0, count: cacheRows * keyValueWidth)
        for row in 0..<cacheRows {
          values[row * keyValueWidth] = Float16(row % 1_024)
          values[row * keyValueWidth + 1] = Float16(layer)
          values[row * keyValueWidth + 2] = kind
        }
        return graph.variable(Tensor<Float16>(values, .CPU, .WC(cacheRows, keyValueWidth)).toGPU(0))
      }
    }
    let targets = graph.variable(
      Tensor<Float>((0..<(3 * width)).map(Float.init), .CPU, .WC(3, width)).toGPU(0))
    var hasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    // The window before the target rows sits 10 rows into the caches.
    var first = makeCache(graph, length: 4_096, value: 1)
    first.draftKeys = draftCaches(kind: 0)
    first.draftValues = draftCaches(kind: 1)
    first.draftCacheOrigin = 4_093 - window - 10
    first.draftData = (targets, 3, 4_093)
    first.draftHistoryStart = 1_000
    contextCache.save(
      graph: graph, tokens: tokens, checkpointLength: 4_096, configuration: configuration,
      kvCache: first, hasher: &hasher)
    // Draft data that stops short of the checkpoint is not saved.
    var second = makeCache(graph, length: 8_192, value: 2)
    second.draftKeys = draftCaches(kind: 0)
    second.draftValues = draftCaches(kind: 1)
    second.draftData = (targets, 3, 8_000)
    contextCache.save(
      graph: graph, tokens: tokens, checkpointLength: 8_192, configuration: configuration,
      kvCache: second, hasher: &hasher)
    // Only a session that allocated drafter caches restores the drafter's state.
    for (count, drafting, restoresDrafter) in [
      (4_097, true, true), (4_097, false, false), (8_193, true, false),
    ] {
      var restored = makeCache(graph, length: 0, value: -5)
      if drafting {
        let empty = { () -> [DynamicGraph.Tensor<Float16>] in
          (0..<draft.layers).map { _ in
            graph.variable(
              Tensor<Float16>(
                Array(repeating: -1, count: cacheRows * keyValueWidth), .CPU,
                .WC(cacheRows, keyValueWidth)
              ).toGPU(0))
          }
        }
        restored.draftKeys = empty()
        restored.draftValues = empty()
      }
      var restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
      XCTAssertEqual(
        contextCache.restore(
          graph: graph, tokens: Array(tokens.prefix(count)), configuration: configuration,
          kvCache: &restored, hasher: &restoredHasher), count - 1)
      guard restoresDrafter else {
        XCTAssertNil(restored.draftData)
        continue
      }
      let draftData = try XCTUnwrap(restored.draftData)
      XCTAssertEqual(draftData.rows, 3)
      XCTAssertEqual(draftData.first, 4_093)
      XCTAssertEqual(restored.draftCacheOrigin, 4_093 - window)
      XCTAssertEqual(restored.draftHistoryStart, 1_000)
      XCTAssertEqual(draftData.targets.toCPU().rawValue[2, width - 1], Float(3 * width - 1))
      for (layer, (keys, values)) in zip(restored.draftKeys, restored.draftValues).enumerated() {
        let keyRows = keys.toCPU().rawValue
        let valueRows = values.toCPU().rawValue
        XCTAssertEqual(keyRows[0, 0], 10)
        XCTAssertEqual(keyRows[window - 1, 0], Float16((window - 1 + 10) % 1_024))
        XCTAssertEqual(keyRows[window - 1, 1], Float16(layer))
        XCTAssertEqual(keyRows[0, 2], 0)
        XCTAssertEqual(valueRows[0, 2], 1)
        XCTAssertEqual(keyRows[window, 0], -1)
      }
    }
  }

  func testSuspensionsAreIsolatedByThread() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = GLM5_3ContextCache(projectPath: directory.path, checkpointStride: 4096)
    cache.saveSuspension(Data([1, 2]), threadId: 1)
    cache.saveSuspension(Data([3]), threadId: 2)
    XCTAssertEqual(cache.loadSuspension(threadId: 1), Data([1, 2]))
    cache.removeSuspension(threadId: 1)
    XCTAssertNil(cache.loadSuspension(threadId: 1))
    XCTAssertEqual(cache.loadSuspension(threadId: 2), Data([3]))
  }
}
