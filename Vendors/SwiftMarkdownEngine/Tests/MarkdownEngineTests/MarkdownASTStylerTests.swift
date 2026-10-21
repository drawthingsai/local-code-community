//
//  MarkdownASTStylerTests.swift
//  MarkdownEngineTests
//
//  Phase 2.5b — the AST styler composes nested/combined inline styles instead
//  of overwriting them (the flat 18-pass styler's flaw).
//

import AppKit
import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Phase 2.5b — AST styler font composition")
struct MarkdownASTStylerTests {

  private let base: CGFloat = 14
  private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

  private struct DedentAwareHighlighter: SyntaxHighlighter {
    func codeFont(size: CGFloat) -> NSFont {
      NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func backgroundColor() -> NSColor { .clear }

    func highlight(code: String, language: String?) -> NSAttributedString? {
      guard code == "alpha\nbeta\n" else { return nil }
      let result = NSMutableAttributedString(string: code)
      result.addAttribute(
        .foregroundColor,
        value: NSColor.systemRed,
        range: (code as NSString).range(of: "beta")
      )
      return result
    }

    var appearanceDidChangeNotification: Notification.Name? { nil }
  }

  /// Effective font at `pos`: the last styled range covering it that sets `.font`.
  private func font(in attrs: [StyledRange], at pos: Int) -> NSFont? {
    var result: NSFont?
    for (range, a) in attrs where NSLocationInRange(pos, range) {
      if let f = a[.font] as? NSFont { result = f }
    }
    return result
  }

  /// Per-keystroke perf: scoping a restyle to the edited paragraph must produce
  /// the EXACT same attributes within that paragraph as a full-document style.
  /// This is the safety net for the `scopedRanges` fast path — it can't diverge
  /// from the full rebuild (no glitch).
  @MainActor
  @Test("scoped styling == full styling, clipped to the edited paragraph")
  func scopedMatchesFullForEditedParagraph() {
    _ = NSApplication.shared
    let text = "plain one\n\n**bold** in two `code`\n\n- item *x*\n\nhttps://example.com"
    let ns = text as NSString
    let para = ns.paragraphRange(for: NSRange(location: 13, length: 0))  // the `**bold**…` line
    func keys(_ scoped: [NSRange]?) -> String {
      let r = MarkdownASTStyler.styleAttributes(
        text: text, fontName: fontName, fontSize: base, scopedRanges: scoped
      ).filter { NSIntersectionRange($0.range, para).length > 0 }
      return styleKeySnapshot(r)
    }
    #expect(keys([para]) == keys(nil))
  }

  @Test("bold inside a heading stays heading-size and consistent (fixes # **n*o*des**)")
  func headingBoldComposesToHeadingSize() {
    let attrs = MarkdownASTStyler.styleAttributes(
      text: "# **n*o*des**", fontName: fontName, fontSize: base)
    // "# **n*o*des**": n=4, o=6, d=8
    let n = font(in: attrs, at: 4)
    let o = font(in: attrs, at: 6)
    let d = font(in: attrs, at: 8)

    // The fix: every emphasized char is the SAME (heading) size — not "o" big, "n/des" small.
    #expect(n?.pointSize == o?.pointSize)
    #expect(n?.pointSize == d?.pointSize)
    #expect((n?.pointSize ?? 0) > base)  // heading-size, not base

    // Correct composed traits.
    #expect(n?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(d?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(o?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
  }

  @Test("inline code inherits heading size and bold emphasis")
  func inlineCodeInHeadingInheritsFontContext() throws {
    let text = "# 2. Result equals the mathematical `floor((a + b) / 2)` with no wrap"
    let ns = text as NSString
    let codeRange = ns.range(of: "floor((a + b) / 2)")
    var configuration = MarkdownEditorConfiguration.default
    configuration.inlineCode.fontSizeScale = 1
    configuration.codeBlock.fontSizeScale = 0.5

    let attrs = MarkdownASTStyler.styleAttributes(
      text: text,
      fontName: fontName,
      fontSize: base,
      configuration: configuration
    )
    let codeFont = try #require(font(in: attrs, at: codeRange.location))
    let expectedSize = base * configuration.headings.fontMultiplier(for: 1)

    #expect(codeFont.pointSize == expectedSize)
    #expect(codeFont.fontDescriptor.symbolicTraits.contains(.bold))
    #expect(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
  }

  @Test("nested emphasis in a paragraph composes bold+italic")
  func paragraphNestedEmphasis() {
    let attrs = MarkdownASTStyler.styleAttributes(
      text: "**a *b* c**", fontName: fontName, fontSize: base)
    // "**a *b* c**": a=2, b=5, c=8
    let a = font(in: attrs, at: 2)
    let b = font(in: attrs, at: 5)
    #expect(a?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    #expect(a?.fontDescriptor.symbolicTraits.contains(.italic) == false)
    #expect(b?.fontDescriptor.symbolicTraits.contains([.bold, .italic]) == true)
  }

  @Test("bare URL inside bold excludes Markdown markers and keeps the bold font")
  func autoLinkInsideBold() {
    let text = "**https://example.com**"
    let expectedRange = (text as NSString).range(of: "https://example.com")
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base)
    let links = attrs.compactMap { entry -> (NSRange, URL)? in
      guard let url = entry.attributes[.link] as? URL else { return nil }
      return (entry.range, url)
    }

    #expect(links.count == 1)
    #expect(links.first?.0 == expectedRange)
    #expect(links.first?.1 == URL(string: "https://example.com"))
    #expect(
      font(in: attrs, at: expectedRange.location)?.fontDescriptor.symbolicTraits.contains(.bold)
        == true)
  }

  @Test("automatic link detection can be disabled without disabling explicit links")
  func automaticLinkDetectionCanBeDisabled() {
    let text = "https://bare.example [explicit](https://explicit.example)"
    var configuration = MarkdownEditorConfiguration.default
    configuration.link.automaticLinkDetectionEnabled = false
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, configuration: configuration)
    let linkedURLs = attrs.compactMap { $0.attributes[.link] as? URL }

    #expect(!linkedURLs.contains(URL(string: "https://bare.example")!))
    #expect(linkedURLs.contains(URL(string: "https://explicit.example")!))
  }

  private struct DetectedLinkFilter: MarkdownLinkResolver {
    func url(for destination: String) -> URL? { URL(string: destination) }
    func url(forDetected url: URL) -> URL? { url.scheme == "https" ? url : nil }
  }

  @Test("the link resolver decides which detected URLs become links")
  func detectedLinksUseResolver() {
    let text = "https://bare.example itms-services://?action=download-manifest"
    let detected = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base
    ).compactMap { $0.attributes[.link] as? URL }
    var configuration = MarkdownEditorConfiguration.default
    configuration.services.links = DetectedLinkFilter()
    let linkedURLs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, configuration: configuration
    ).compactMap { $0.attributes[.link] as? URL }

    #expect(detected.count == 2)
    #expect(linkedURLs == [URL(string: "https://bare.example")!])
  }

  @Test("bare URLs compose with fenced and inline code styling")
  func autoLinkInsideCode() {
    for (text, urlString) in [
      ("```\nhttps://fenced.example\n```", "https://fenced.example"),
      ("`https://inline.example`", "https://inline.example"),
      (
        "**BashStatus**: 5\n**Ran**: `cd sudoku && node server.js`\n**Ran**: `curl -s -o /dev/null -w \"%{http_code}\" http://localhost:8080/`",
        "http://localhost:8080/"
      ),
    ] {
      let expectedRange = (text as NSString).range(of: urlString)
      let attrs = MarkdownASTStyler.styleAttributes(
        text: text, fontName: fontName, fontSize: base)
      #expect(
        attrs.contains {
          $0.range == expectedRange && ($0.attributes[.link] as? URL) == URL(string: urlString)
        })
      #expect(
        font(in: attrs, at: expectedRange.location)?.fontDescriptor.symbolicTraits.contains(
          .monoSpace) == true)
    }
  }

  @Test("inactive explicit link destination collapses without a visible whitespace run")
  func explicitLinkDestinationCollapses() {
    let text = "[label](https://example.com)"
    let hiddenRange = (text as NSString).range(of: "(https://example.com)")
    let configuration = MarkdownEditorConfiguration.default
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, configuration: configuration)
    let linkRanges = attrs.compactMap { entry in
      entry.attributes[.link] == nil ? nil : entry.range
    }

    #expect(linkRanges == [(text as NSString).range(of: "label")])
    #expect(
      attrs.contains { entry in
        entry.range == hiddenRange
          && (entry.attributes[.font] as? NSFont)?.pointSize
            == configuration.markers.hiddenMarkerFontSize
          && (entry.attributes[.kern] as? CGFloat)
            == -configuration.markers.hiddenMarkerFontSize
          && (entry.attributes[.foregroundColor] as? NSColor) == .clear
      })
  }

  /// Code is not prose: fenced blocks and inline `code` spans must carry
  /// `.spellingState: 0` so the system spell-checker leaves them alone,
  /// matching the existing convention that links / wiki-links / LaTeX / tables
  /// already follow.
  @Test("code blocks and inline code receive .spellingState: 0; prose does not")
  func codeRegionsSuppressSpellCheck() {
    let text = "prose word\n\n```\nfencedcd notaword\n```\n\nplain `inlnecode` tail"
    let attrs = MarkdownASTStyler.styleAttributes(text: text, fontName: fontName, fontSize: base)
    let ns = text as NSString
    let fencedContent = ns.range(of: "fencedcd notaword")
    let inlineSpan = ns.range(of: "`inlnecode`")
    let prose = ns.range(of: "prose word")

    // Pull every `.spellingState` value from styled ranges that intersect `r`.
    func spellingStates(intersecting r: NSRange) -> [Int] {
      attrs.compactMap { entry -> Int? in
        guard NSIntersectionRange(entry.range, r).length > 0 else { return nil }
        return entry.attributes[.spellingState] as? Int
      }
    }

    #expect(spellingStates(intersecting: fencedContent).contains(0))
    #expect(spellingStates(intersecting: inlineSpan).contains(0))
    #expect(spellingStates(intersecting: prose).isEmpty)
  }

  @Test(
    "indented code is normalized for highlighting and source indentation collapses when inactive")
  func indentedCodeHighlightingUsesNormalizedContent() {
    let text = "   ```\n   alpha\n   beta\n   ```"
    let ns = text as NSString
    let configuration = MarkdownEditorConfiguration(
      services: MarkdownEditorServices(syntaxHighlighter: DedentAwareHighlighter())
    )
    let inactive = MarkdownASTStyler.styleAttributes(
      text: text,
      fontName: fontName,
      fontSize: base,
      configuration: configuration
    )
    let beta = ns.range(of: "beta")

    #expect(color(in: inactive, at: beta.location) == .systemRed)
    for position in [7, 8, 9, 16, 17, 18] {
      #expect(isHiddenMarkerFont(in: inactive, at: position, configuration: configuration))
    }

    let active = MarkdownASTStyler.styleAttributes(
      text: text,
      fontName: fontName,
      fontSize: base,
      caretLocation: beta.location,
      configuration: configuration
    )
    for position in [7, 8, 9, 16, 17, 18] {
      #expect(!isHiddenMarkerFont(in: active, at: position, configuration: configuration))
    }
  }

  /// Effective color at `pos`: the last styled range covering it that sets `.foregroundColor`.
  private func color(in attrs: [StyledRange], at pos: Int) -> NSColor? {
    var result: NSColor?
    for (range, a) in attrs where NSLocationInRange(pos, range) {
      if let c = a[.foregroundColor] as? NSColor { result = c }
    }
    return result
  }

  /// Whether the last `.font` attribute covering `pos` is the hidden marker font.
  private func isHiddenMarkerFont(
    in attrs: [StyledRange], at pos: Int, configuration: MarkdownEditorConfiguration = .default
  ) -> Bool {
    let hiddenSize = configuration.markers.hiddenMarkerFontSize
    let hiddenFont = NSFont(name: fontName, size: hiddenSize) ?? .systemFont(ofSize: hiddenSize)
    var result: NSFont?
    for (range, a) in attrs where NSLocationInRange(pos, range) {
      if let f = a[.font] as? NSFont { result = f }
    }
    return result?.pointSize == hiddenFont.pointSize
  }

  @Test("highlight == markers use mutedText while the caret is inside")
  func highlightMarkersAreMutedWhenActive() {
    let text = "==text=="
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, caretLocation: 4,
      configuration: .init(extensions: [HighlightExtension(), StrikethroughExtension()])
    )
    #expect(color(in: attrs, at: 0) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 1) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 6) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 7) == MarkdownEditorTheme.default.mutedText)
  }

  @Test("bold ** markers use mutedText while the caret is inside")
  func boldMarkersAreMutedWhenActive() {
    let text = "**bold**"
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, caretLocation: 4, configuration: .default
    )
    #expect(color(in: attrs, at: 0) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 1) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 6) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 7) == MarkdownEditorTheme.default.mutedText)
  }

  @Test("italic * marker uses mutedText while the caret is inside")
  func italicMarkerIsMutedWhenActive() {
    let text = "*italic*"
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, caretLocation: 4, configuration: .default
    )
    #expect(color(in: attrs, at: 0) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 7) == MarkdownEditorTheme.default.mutedText)
  }

  @Test("strikethrough ~~ markers use mutedText while the caret is inside")
  func strikethroughMarkersAreMutedWhenActive() {
    let text = "~~strike~~"
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, caretLocation: 5,
      configuration: .init(extensions: [StrikethroughExtension()])
    )
    #expect(color(in: attrs, at: 0) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 1) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 8) == MarkdownEditorTheme.default.mutedText)
    #expect(color(in: attrs, at: 9) == MarkdownEditorTheme.default.mutedText)
  }

  @Test("inline markers shrink instead of taking muted color when the caret is outside")
  func inactiveMarkersShrinkInsteadOfColored() {
    let text = "a ==text== b **bold** c ~~strike~~ d *italic* e"
    let attrs = MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, caretLocation: 0,
      configuration: .init(extensions: [HighlightExtension(), StrikethroughExtension()])
    )
    for pos in [2, 3, 8, 9, 13, 14, 19, 20, 24, 25, 32, 33, 37, 44] {
      #expect(isHiddenMarkerFont(in: attrs, at: pos), "marker at \(pos) should be shrunk")
    }
  }
}

/// A hidden task item shares the BULLET list's left geometry (GitHub/Obsidian):
/// the `[ ] ` chars collapse to the hidden-marker font (~zero advance) so task
/// content starts at the same x as bullet content, and the hanging indent
/// measures only `- `. While the caret edits the syntax, the raw chars show at
/// full advance and the indent uses the full `- [ ] ` width.
@Suite("Task checkbox geometry — collapsed [ ] shares bullet indent")
struct TaskCheckboxGeometryStylerTests {

  private let base: CGFloat = 14
  private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }
  private var baseFont: NSFont { NSFont(name: fontName, size: base) ?? .systemFont(ofSize: base) }
  private var hiddenSize: CGFloat {
    MarkdownEditorConfiguration.default.markers.hiddenMarkerFontSize
  }
  private var indentPerLevel: CGFloat { MarkdownEditorConfiguration.default.lists.indentPerLevel }

  /// Same measurement call the styler uses for the hanging indent.
  private func width(_ s: String) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: baseFont]).width
  }

  /// Effective font at `pos`: the last styled range covering it that sets `.font`.
  private func font(in attrs: [StyledRange], at pos: Int) -> NSFont? {
    var result: NSFont?
    for (range, a) in attrs where NSLocationInRange(pos, range) {
      if let f = a[.font] as? NSFont { result = f }
    }
    return result
  }

  /// Effective headIndent at `pos`: the last styled range covering it that sets `.paragraphStyle`.
  private func headIndent(in attrs: [StyledRange], at pos: Int) -> CGFloat? {
    var result: CGFloat?
    for (range, a) in attrs where NSLocationInRange(pos, range) {
      if let ps = a[.paragraphStyle] as? NSParagraphStyle { result = ps.headIndent }
    }
    return result
  }

  private func style(_ text: String, caret: Int = -1) -> [StyledRange] {
    MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: base, caretLocation: caret)
  }

  @Test("hidden task: [ ] collapses to the hidden font and indent equals a bullet's")
  func hiddenTaskSharesBulletIndent() {
    // "- [ ] task": marker 0..1, spacer 1..2, box 2..5, gap 5..6, content 6...
    let attrs = style("- [ ] task")

    // The box chars carry the collapse font (~zero advance, house pattern).
    for pos in 2...4 {
      #expect(
        font(in: attrs, at: pos)?.pointSize == hiddenSize, "box char at \(pos) should collapse")
    }
    // The space after the box collapses too.
    #expect(font(in: attrs, at: 5)?.pointSize == hiddenSize)
    // Marker + spacer keep full advance (the drawn square's slot): no collapse font.
    #expect(font(in: attrs, at: 0)?.pointSize != hiddenSize)
    #expect(font(in: attrs, at: 1)?.pointSize != hiddenSize)

    // Hanging indent measures only "- " — identical to a bullet item.
    let taskIndent = headIndent(in: attrs, at: 0)
    let expected = indentPerLevel + width("- ")
    #expect(taskIndent != nil)
    #expect(abs((taskIndent ?? -1) - expected) < 0.01)

    let bulletIndent = headIndent(in: style("- task"), at: 0)
    #expect(taskIndent == bulletIndent)

    // [x] hits the identical collapse branch as [ ].
    #expect(headIndent(in: style("- [x] task"), at: 0) == taskIndent)
  }

  @Test("revealed task (caret in syntax): no collapse, indent uses the full raw width")
  func revealedTaskKeepsFullSyntaxWidth() {
    let attrs = style("- [ ] task", caret: 3)

    // No collapse font on the box while the raw syntax shows.
    for pos in 2...5 {
      let f = font(in: attrs, at: pos)
      #expect(
        f == nil || f!.pointSize != hiddenSize,
        "box char at \(pos) must not collapse while revealed")
    }
    // Wrapped lines align with the visible "- [ ] ".
    let expected = indentPerLevel + width("- [ ] ")
    let revealedIndent = headIndent(in: attrs, at: 0)
    #expect(revealedIndent != nil)
    #expect(abs((revealedIndent ?? -1) - expected) < 0.01)
  }

}

/// Canonical, order-independent string of styled ranges so two style runs can be
/// compared for equality.
private func styleKeySnapshot(_ ranges: [StyledRange]) -> String {
  let lines =
    ranges
    .map { entry -> (NSRange, [String]) in
      (entry.range, entry.attributes.keys.map(\.rawValue).sorted())
    }
    .sorted { a, b in
      if a.0.location != b.0.location { return a.0.location < b.0.location }
      if a.0.length != b.0.length { return a.0.length < b.0.length }
      return a.1.joined(separator: ",") < b.1.joined(separator: ",")
    }
    .map { "@\(fmt($0.0)) keys=[\($0.1.joined(separator: ","))]" }
  return lines.isEmpty ? "(no styled ranges)" : lines.joined(separator: "\n")
}

private func fmt(_ r: NSRange) -> String {
  r.location == NSNotFound ? "∅" : "\(r.location)+\(r.length)"
}
