//
//  TableCollapsedLayoutTests.swift
//  MarkdownEngineTests
//
//  Inactive rendered tables keep their Markdown source in storage. Every
//  source row after the image anchor therefore still owns a paragraph; keep
//  their aggregate layout height negligible even for long tables.
//

import AppKit
import Testing

@testable import MarkdownEngine

@MainActor
@Suite("Collapsed table source layout")
struct TableCollapsedLayoutTests {

  @Test func longTableRowsHaveNegligibleAggregateHeight() throws {
    _ = NSApplication.shared
    let rowCount = 75
    let body = (0..<(rowCount - 2)).map { "| \($0) | value |" }
    let text = (["| index | value |", "|---|---|"] + body).joined(separator: "\n")
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
    let font = NSFont.systemFont(ofSize: 15)
    let context = MarkdownStyler.StylingContext(
      nsText: text as NSString,
      tokens: tokens,
      codeTokens: [],
      activeTokenIndices: [],
      baseFont: font,
      layoutBridge: nil,
      baseDefaultLineHeight: 18,
      codeBackgroundColor: .windowBackgroundColor,
      latexMarkerFont: font,
      configuration: .default,
      wikiLinkIDProvider: { _ in nil }
    )

    let collapsedStyles = MarkdownStyler.styleTables(context).compactMap {
      $0.attributes[.paragraphStyle] as? NSParagraphStyle
    }.filter {
      $0.maximumLineHeight == MarkdownLayoutMetrics.collapsedSourceLineHeight
    }

    #expect(collapsedStyles.count == rowCount - 1)
    #expect(
      collapsedStyles.reduce(CGFloat.zero) { $0 + $1.maximumLineHeight } < 0.001
    )
  }
}
