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
