import AppKit
import MarkdownEngineCodeBlocks
import XCTest

final class CodeFontTests: XCTestCase {
  func testFallbackPreservesFontAndSizeAcrossRepeatedRequests() throws {
    let expected = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
    let bridge = HighlighterSwiftBridge(
      autoSwitchAppearance: false,
      preferredFontNames: ["MissingMarkdownTestFont", "Menlo-Regular"])
    for size: CGFloat in [14, 18, 14, 18] {
      let font = bridge.codeFont(size: size)
      XCTAssertEqual(font.fontName, expected.fontName)
      XCTAssertEqual(font.pointSize, size)
    }
    bridge.clearCache()
    XCTAssertEqual(bridge.codeFont(size: 14).fontName, expected.fontName)
  }

  func testFontPreferencesRemainIndependentBetweenBridges() throws {
    let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
    let courier = try XCTUnwrap(NSFont(name: "Courier", size: 14))
    let first = HighlighterSwiftBridge(
      autoSwitchAppearance: false, preferredFontNames: ["Menlo-Regular", "Courier"])
    let second = HighlighterSwiftBridge(
      autoSwitchAppearance: false, preferredFontNames: ["Courier", "Menlo-Regular"])
    for _ in 0..<2 {
      XCTAssertEqual(first.codeFont(size: 14).fontName, menlo.fontName)
      XCTAssertEqual(second.codeFont(size: 14).fontName, courier.fontName)
    }
  }

  func testMissingFontsKeepSystemMonospaceFallback() {
    let bridge = HighlighterSwiftBridge(
      autoSwitchAppearance: false, preferredFontNames: ["MissingMarkdownTestFont"])
    for size: CGFloat in [12, 20, 12] {
      let expected = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
      let font = bridge.codeFont(size: size)
      XCTAssertEqual(font.fontName, expected.fontName)
      XCTAssertEqual(font.pointSize, expected.pointSize)
    }
  }
}
