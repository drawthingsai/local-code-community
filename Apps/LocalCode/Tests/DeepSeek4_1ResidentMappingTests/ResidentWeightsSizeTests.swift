import DataModels
import Foundation
import XCTest

final class ResidentWeightsSizeTests: XCTestCase {
  private static let gibibyte: UInt64 = 1_024 * 1_024 * 1_024
  private static let deepSeek4Checkpoint: UInt64 = 89_414_598_656
  private static let deepSeek4_1Checkpoint: UInt64 = 172_970_156_032
  private static let deepSeek4_1Drafter: UInt64 = 7_370_686_464
  private var drafterPath = ""

  override func setUpWithError() throws {
    drafterPath = NSTemporaryDirectory() + "resident-weights-\(UUID().uuidString).ckpt"
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(atPath: drafterPath)
  }

  private func deepSeek4_1(
    _ weightsStreaming: DeviceCapability.WeightsStreaming?, drafterExists: Bool
  ) -> DeepSeek4_1TextGenerator {
    if drafterExists {
      XCTAssertTrue(FileManager.default.createFile(atPath: drafterPath, contents: Data()))
    }
    return DeepSeek4_1TextGenerator(
      filePath: "/missing/deepseek_4.1.ckpt", engramFilePath: "/missing/deepseek_4.1.engram",
      weightsStreaming: weightsStreaming, drafterFile: drafterPath)
  }

  private func deepSeek4(_ weightsStreaming: DeviceCapability.WeightsStreaming?)
    -> DeepSeek4TextGenerator
  {
    DeepSeek4TextGenerator(
      filePath: "/missing/deepseek_4.ckpt", chunkedPrefillMaxLength: 4096,
      weightsStreaming: weightsStreaming)
  }

  func testDeepSeek4_1StreamingTierHoldsItsTier() {
    XCTAssertEqual(
      deepSeek4_1(._48GiB, drafterExists: false).residentWeightsSize, 48 * Self.gibibyte)
    // The 8 GiB tier shares the 16 GiB allocation.
    XCTAssertEqual(
      deepSeek4_1(._8GiB, drafterExists: false).residentWeightsSize, 16 * Self.gibibyte)
  }

  func testDeepSeek4_1CountsTheDrafterAboveSixteenGiB() {
    XCTAssertEqual(
      deepSeek4_1(._72GiB, drafterExists: true).residentWeightsSize,
      72 * Self.gibibyte + Self.deepSeek4_1Drafter)
    XCTAssertEqual(
      deepSeek4_1(._24GiB, drafterExists: true).residentWeightsSize,
      24 * Self.gibibyte + Self.deepSeek4_1Drafter)
  }

  func testDeepSeek4_1SmallTiersDecodeWithoutTheDrafter() {
    XCTAssertEqual(
      deepSeek4_1(._16GiB, drafterExists: true).residentWeightsSize, 16 * Self.gibibyte)
    XCTAssertEqual(
      deepSeek4_1(._8GiB, drafterExists: true).residentWeightsSize, 16 * Self.gibibyte)
  }

  func testDeepSeek4_1DisabledHoldsTheWholeCheckpoint() {
    XCTAssertEqual(
      deepSeek4_1(.disabled, drafterExists: false).residentWeightsSize,
      Self.deepSeek4_1Checkpoint)
    XCTAssertEqual(
      deepSeek4_1(.disabled, drafterExists: true).residentWeightsSize,
      Self.deepSeek4_1Checkpoint + Self.deepSeek4_1Drafter)
  }

  func testDeepSeek4TierHoldsWhatItsSelectionBudgets() {
    XCTAssertEqual(deepSeek4(._40GiB).residentWeightsSize, 40 * Self.gibibyte)
    XCTAssertEqual(deepSeek4(._56GiB).residentWeightsSize, 48 * Self.gibibyte)
    XCTAssertEqual(deepSeek4(._64GiB).residentWeightsSize, 48 * Self.gibibyte)
    XCTAssertEqual(deepSeek4(._72GiB).residentWeightsSize, Self.deepSeek4Checkpoint)
    XCTAssertEqual(deepSeek4(.disabled).residentWeightsSize, Self.deepSeek4Checkpoint)
  }

  func testAutomaticSizesTheAutomaticTier() {
    let automatic = DeviceCapability.weightsStreaming
    XCTAssertEqual(
      deepSeek4_1(nil, drafterExists: true).residentWeightsSize,
      deepSeek4_1(automatic, drafterExists: true).residentWeightsSize)
    XCTAssertEqual(deepSeek4(nil).residentWeightsSize, deepSeek4(automatic).residentWeightsSize)
  }

  func testTierSelectionKeepsItsChoices() {
    let gibibyte = Self.gibibyte
    XCTAssertEqual(
      DeviceCapability.WeightsStreaming._72GiB.residentTierForDeepSeek4_1(
        availableMemory: 110 * gibibyte, draft: true), ._72GiB)
    XCTAssertEqual(
      DeviceCapability.WeightsStreaming._72GiB.residentTierForDeepSeek4_1(
        availableMemory: 100 * gibibyte, draft: true), ._64GiB)
    XCTAssertEqual(
      DeviceCapability.WeightsStreaming._72GiB.residentTierForDeepSeek4_1(
        availableMemory: 100 * gibibyte, draft: false), ._72GiB)
    XCTAssertEqual(
      DeviceCapability.WeightsStreaming._72GiB.residentTierForDeepSeek4_1(
        availableMemory: 8 * gibibyte, draft: false), ._8GiB)
    XCTAssertEqual(
      DeviceCapability.WeightsStreaming._72GiB.residentTierForDeepSeek4(
        availableMemory: 110 * gibibyte), ._64GiB)
    XCTAssertEqual(
      DeviceCapability.WeightsStreaming.disabled.residentTierForDeepSeek4(
        availableMemory: 130 * gibibyte), .disabled)
    XCTAssertEqual(
      DeviceCapability.WeightsStreaming._32GiB.residentTierForDeepSeek4(
        availableMemory: 30 * gibibyte), ._16GiB)
  }
}
