import Foundation
import NNC
import SQLite3
import XCTest

final class DeepSeek4_1ResidentMappingTests: XCTestCase {
  private static let externalType: Int64 = 0x1000_0000 << 32
  private static let pageSize = Int(vm_page_size)
  private var checkpointPath = ""

  override func setUpWithError() throws {
    checkpointPath = NSTemporaryDirectory() + "resident-mapping-\(UUID().uuidString).ckpt"
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: checkpointPath)
  }

  private func prunedCounts(_ counts: [Int?]) -> [Int] {
    DynamicGraph().openStore(checkpointPath) { store in
      for (layer, count) in counts.enumerated() {
        guard let count else { continue }
        store.write(
          "__text_model__[t-layers.\(layer).ffn.gate.bias-0-0]",
          tensor: Tensor<Float>(.CPU, .C(count)))
      }
    }
    return DeepSeek4_1TextGenerator.prunedExpertCounts(
      checkpoint: checkpointPath, layers: 3, routedExperts: 6, maximum: 384)
  }

  func testPrunedExpertCountsComeFromGateBiasShapes() throws {
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.prunedExpertCounts(
        checkpoint: checkpointPath + ".missing", layers: 3, routedExperts: 6, maximum: 384), [])
    XCTAssertEqual(prunedCounts([384, 384, 384]), [])
  }

  func testPrunedExpertCountsReadEachLayer() throws {
    XCTAssertEqual(prunedCounts([240, 6, 384]), [240, 6, 384])
  }

  func testPrunedExpertCountsIgnoreStoresWithoutEveryGateBias() throws {
    XCTAssertEqual(prunedCounts([228, nil, 228]), [])
  }

  func testPrunedLayersBelowTheirSlotsMapWhole() throws {
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath, expertResidentSlots: [228, 120], expertCounts: [228, 120]), 0)
  }

  private func blob(_ words: [UInt64]) -> Data {
    words.withUnsafeBytes { Data($0) }
  }

  private func makeCheckpoint(
    trailerOffset: Int32, tensors: [(name: String, type: Int64, data: Data)]
  ) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(checkpointPath, &database), SQLITE_OK)
    defer { sqlite3_close(database) }
    XCTAssertEqual(
      sqlite3_exec(
        database,
        "CREATE TABLE tensors (name TEXT, type INTEGER, format INTEGER, datatype INTEGER, dim BLOB, data BLOB); PRAGMA user_version = \(trailerOffset);",
        nil, nil, nil), SQLITE_OK)
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        database, "INSERT INTO tensors (name, type, data) VALUES (?1, ?2, ?3)", -1, &statement,
        nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
    for tensor in tensors {
      sqlite3_reset(statement)
      sqlite3_bind_text(statement, 1, tensor.name, -1, transient)
      sqlite3_bind_int64(statement, 2, tensor.type)
      _ = tensor.data.withUnsafeBytes {
        sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(tensor.data.count), transient)
      }
      XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
  }

  private func makeLayeredCheckpoint(trailerOffset: Int32) throws {
    try makeCheckpoint(
      trailerOffset: trailerOffset,
      tensors: [
        ("__text_model__[t-embed-0-0]", Self.externalType, blob([0, UInt64(Self.pageSize)])),
        // Small enough to live inside SQLite, where its bytes are no position.
        ("__text_model__[t-layers.0.attn.q_norm-0-0]", 0, Data(repeating: 0xff, count: 16)),
        (
          "__text_model__[t-layers.1.ffn.shared_experts-0-0]", Self.externalType,
          blob([UInt64(Self.pageSize), UInt64(Self.pageSize)])
        ),
        (
          "__text_model__[t-layers.0.ffn.experts-0-0]", Self.externalType,
          blob([UInt64(2 * Self.pageSize), UInt64(Self.pageSize)])
        ),
        (
          "__text_model__[t-layers.0.ffn.experts.w2-0-0]", Self.externalType,
          blob([UInt64(3 * Self.pageSize), UInt64(Self.pageSize)])
        ),
        (
          "__text_model__[t-layers.1.ffn.experts-0-0]", Self.externalType,
          blob([UInt64(4 * Self.pageSize), UInt64(Self.pageSize)])
        ),
        (
          "__vision_model__[t-aligner.w1-0-0]", Self.externalType,
          blob([UInt64(5 * Self.pageSize), UInt64(Self.pageSize)])
        ),
      ])
  }

  func testEndsAfterFixedWeightsWhenEveryLayerStreams() throws {
    try makeLayeredCheckpoint(trailerOffset: Int32(Self.pageSize))
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath, expertResidentSlots: [100, 100], expertCounts: [384, 384]),
      3 * Self.pageSize)
  }

  func testEndsAfterTheLastFullLayerAndCountsTheTrailer() throws {
    try makeLayeredCheckpoint(trailerOffset: Int32(Self.pageSize))
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath, expertResidentSlots: [384, 100], expertCounts: [384, 384]),
      5 * Self.pageSize)
  }

  func testMapsEverythingWhenNoLayerStreams() throws {
    try makeLayeredCheckpoint(trailerOffset: Int32(Self.pageSize))
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath, expertResidentSlots: [384, 384], expertCounts: [384, 384]), 0)
  }

  func testAStoreWithoutATrailerCountsFromZero() throws {
    try makeLayeredCheckpoint(trailerOffset: 0)
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath, expertResidentSlots: [100, 100], expertCounts: [384, 384]),
      2 * Self.pageSize)
  }

  func testRoundsATensorEndingMidPageUpToItsPage() throws {
    let trailerOffset = Self.pageSize
    try makeCheckpoint(
      trailerOffset: Int32(trailerOffset),
      tensors: [
        (
          "__text_model__[t-embed-0-0]", Self.externalType,
          blob([0, UInt64(Self.pageSize + 1)])
        )
      ])
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.endOfExternalTensors(inCheckpoint: checkpointPath) { _ in true },
      2 * Self.pageSize + 1)
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath, expertResidentSlots: [100], expertCounts: [384]),
      3 * Self.pageSize)
  }

  func testReadsTheOffsetPastABlockSize() throws {
    try makeCheckpoint(
      trailerOffset: 100,
      tensors: [("__text_model__[t-embed-0-0]", Self.externalType, blob([4_096, 200, 300]))])
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.endOfExternalTensors(inCheckpoint: checkpointPath) { _ in true },
      100 + 200 + 300)
  }

  func testAnUnknownLayoutOrAMissingFileMapsNothingWhole() throws {
    try makeCheckpoint(
      trailerOffset: 100,
      tensors: [("__text_model__[t-embed-0-0]", Self.externalType, Data(repeating: 0, count: 8))])
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath, expertResidentSlots: [100], expertCounts: [384]), 1)
    XCTAssertEqual(
      DeepSeek4_1TextGenerator.residentMappingSize(
        filePath: checkpointPath + ".missing", expertResidentSlots: [100], expertCounts: [384]), 1)
  }
}
