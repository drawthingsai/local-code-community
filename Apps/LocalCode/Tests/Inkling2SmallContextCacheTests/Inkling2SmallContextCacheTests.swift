import Foundation
import LLM
import NNC
import XCTest

final class Inkling2SmallContextCacheTests: XCTestCase {
  private let modelPath = "/models/inkling_2_small-test.ckpt"
  private let slidingCapacity = 32
  private var configuration: Inkling2SmallConfiguration {
    var configuration = Inkling2SmallConfiguration.inkling2Small
    configuration.layers = 6
    configuration.keyValueHeads = 1
    configuration.headDim = 2
    configuration.hiddenSize = 4
    configuration.slidingWindow = 8
    return configuration
  }

  // Full-attention keys hold `value` and values `value + 0.5`. Row r of a sliding-window cache
  // holds r + 100 * value in its keys and its values hold `value + 0.5`, with 20 rows in use.
  // Convolution row buffer i holds value + i.
  private func makeCache(_ graph: DynamicGraph, length: Int, value: Float)
    -> Inkling2SmallTextGenerator.KVCache
  {
    var cache = Inkling2SmallTextGenerator.KVCache()
    Inkling2SmallTextGenerator.resizeCaches(
      graph: graph, kvCache: &cache, cacheCapacity: 20_480, slidingCapacity: slidingCapacity,
      configuration: configuration)
    for (index, layer) in cache.layers.enumerated() {
      layer.values.full(value + 0.5)
      if configuration.isFullAttentionLayer(index) {
        layer.keys.full(value)
      } else {
        var keys = layer.keys
        let rows = (0..<slidingCapacity).flatMap {
          [Float16](repeating: Float16(Float($0) + 100 * value), count: 2)
        }
        keys[0..<1, 0..<slidingCapacity, 0..<1, 0..<2] = graph.variable(
          Tensor<Float16>(rows, .CPU, .NHWC(1, slidingCapacity, 1, 2)).toGPU(0))
      }
      for (bufferIndex, rows) in layer.convolutionRows.enumerated() {
        if bufferIndex % 4 < 2 {
          rows.as(of: Float16.self).full(value + Float(bufferIndex))
        } else {
          rows.as(of: Float.self).full(value + Float(bufferIndex))
        }
      }
    }
    cache.tokenLength = length
    cache.slidingTokenLength = 20
    return cache
  }

  func testCheckpointsShareSlicesAndRestoreLatestSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let graph = DynamicGraph()
    let tokens = (0..<16_385).map(Int32.init)
    var hasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    for (length, stride, value) in [(4096, 4096, Float(1)), (8192, 8192, 2), (16384, 8192, 3)] {
      Inkling2SmallContextCache(projectPath: directory.path, checkpointStride: stride).save(
        graph: graph, tokens: tokens, checkpointLength: length, configuration: configuration,
        kvCache: makeCache(graph, length: length, value: value), hasher: &hasher)
    }
    XCTAssertEqual(hasher.hashedTokenCount, 16_384)
    let context = Inkling2SmallContextCache(projectPath: directory.path, checkpointStride: 4096)
    func restore(_ count: Int) -> (length: Int, cache: Inkling2SmallTextGenerator.KVCache) {
      var cache = makeCache(graph, length: 0, value: -5)
      var restoredHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
      let length = context.restore(
        graph: graph, tokens: Array(tokens.prefix(count)), configuration: configuration,
        kvCache: &cache, hasher: &restoredHasher)
      graph.joined()
      XCTAssertEqual(restoredHasher.hashedTokenCount, length)
      XCTAssertEqual(context.restoredTokenLength, length)
      return (length, cache)
    }
    for (count, expected, value) in [
      (16385, 16384, Float(3)), (14000, 8192, 2), (8192, 4096, 1), (4096, 0, -5),
    ] {
      let (length, cache) = restore(count)
      XCTAssertEqual(length, expected)
      XCTAssertEqual(cache.tokenLength, expected)
      XCTAssertEqual(cache.slidingTokenLength, expected > 0 ? 7 : 20)
      // The window was the 7 rows before the 20th, and it restores to the start.
      let window = cache.layers[0].keys.toCPU().rawValue
      XCTAssertEqual(window[0, 0, 0, 0], Float16(expected > 0 ? 13 + 100 * value : -500))
      XCTAssertEqual(window[0, 6, 0, 1], Float16(expected > 0 ? 19 + 100 * value : -494))
      XCTAssertEqual(window[0, 7, 0, 0], -493)
      XCTAssertEqual(cache.layers[4].values.toCPU().rawValue[0, 3, 0, 0], Float16(value + 0.5))
      XCTAssertEqual(
        cache.layers[2].convolutionRows[1].as(of: Float16.self).toCPU().rawValue[0, 2, 0, 0],
        Float16(value + 1))
      XCTAssertEqual(
        cache.layers[2].convolutionRows[3].as(of: Float.self).toCPU().rawValue[0, 2, 0, 3],
        value + 3)
      // The buffers the next rows go to are not part of a snapshot.
      XCTAssertEqual(
        cache.layers[2].convolutionRows[4].as(of: Float16.self).toCPU().rawValue[0, 0, 0, 0],
        -1)
      if expected > 0 {
        let keys = cache.layers[5].keys.toCPU().rawValue
        XCTAssertEqual(keys[0, 4095, 0, 0], 1)
        if expected >= 8192 { XCTAssertEqual(keys[0, 8191, 0, 1], 2) }
        XCTAssertEqual(keys[0, expected - 1, 0, 0], Float16(value))
        XCTAssertEqual(
          cache.layers[5].values.toCPU().rawValue[0, expected - 1, 0, 0], Float16(value + 0.5))
      }
    }
    // A snapshot without its completion marker, or missing a state, is not restored.
    var keyHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    let latest: String = keyHasher.hash(tokens: tokens, to: 16_384)
    let storePath = try XCTUnwrap(contextCacheStorePath(projectPath: directory.path))
    _ = graph.openStore(storePath, flags: []) { store in
      store.remove("\(latest)/inkling2_small/snapshot")
    }
    XCTAssertEqual(restore(16385).length, 8192)
    keyHasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    let previous: String = keyHasher.hash(tokens: tokens, to: 8192)
    _ = graph.openStore(storePath, flags: []) { store in
      store.remove("\(previous)/inkling2_small/window/values/3")
    }
    let (length, cache) = restore(16385)
    XCTAssertEqual(length, 0)
    XCTAssertEqual(cache.tokenLength, 0)
    XCTAssertEqual(cache.slidingTokenLength, 20)
  }

  func testSaveNeedsTheCheckpointAndAFullWindow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let graph = DynamicGraph()
    let tokens = (0..<8_193).map(Int32.init)
    let context = Inkling2SmallContextCache(projectPath: directory.path, checkpointStride: 4096)
    var hasher = ContextCachePrefixHasher(modelFilePath: modelPath)
    var cache = makeCache(graph, length: 4100, value: 1)
    context.save(
      graph: graph, tokens: tokens, checkpointLength: 4096, configuration: configuration,
      kvCache: cache, hasher: &hasher)
    cache = makeCache(graph, length: 4096, value: 1)
    cache.slidingTokenLength = 6
    context.save(
      graph: graph, tokens: tokens, checkpointLength: 4096, configuration: configuration,
      kvCache: cache, hasher: &hasher)
    XCTAssertEqual(hasher.hashedTokenCount, 0)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(".localc/context_cache.sqlite3").path))
  }
}
