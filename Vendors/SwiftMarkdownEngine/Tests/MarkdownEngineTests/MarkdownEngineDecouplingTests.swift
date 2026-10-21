//
//  MarkdownEngineDecouplingTests.swift
//  MarkdownEngineTests
//
//  Smoke tests guarding the engine's decoupling boundary. Each test
//  exercises a protocol-default-implementation path so we catch
//  regressions where engine code accidentally re-introduces a
//  dependency on a concrete app type or singleton.
//

import AppKit
import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Markdown engine decoupling")
struct MarkdownEngineDecouplingTests {

  // MARK: NoOp services stay inert

  @Test func noOpResolverReturnsNil() {
    let resolver = NoOpWikiLinkResolver()
    #expect(
      resolver.resolve(displayName: "Anything", range: NSRange(location: 0, length: 8)) == nil)
  }

  @Test func noOpImageProviderReturnsNil() {
    let provider = NoOpEmbeddedImageProvider()
    let request = EmbeddedImageRequest(name: "nope")
    #expect(provider.image(for: request) == nil)
  }

  @Test func defaultLinkResolverHandlesWebAndAngleBracketDestinations() {
    let resolver = DefaultMarkdownLinkResolver()
    #expect(resolver.url(for: "example.com") == URL(string: "https://example.com"))
    #expect(
      resolver.url(for: normalizedMarkdownLinkDestination("<file:///tmp/example%20file>"))
        == URL(string: "file:///tmp/example%20file"))
  }

  @Test func noOpLatexRendererReturnsNil() {
    let renderer = NoOpLatexRenderer()
    let result = renderer.render(latex: "x^2", fontSize: 14, theme: .default)
    #expect(result == nil)
  }

  @Test func plainTextSyntaxHighlighterReturnsNoHighlighting() {
    let highlighter = PlainTextSyntaxHighlighter()
    #expect(highlighter.highlight(code: "let x = 1", language: "swift") == nil)
    #expect(highlighter.appearanceDidChangeNotification == nil)
  }

  // MARK: WikiLinkService roundtrip

  @Test func wikiLinkRoundtripsThroughDisplayAndStorage() {
    let storage = "Before [[Apple|11111111-2222-3333-4444-555555555555]] after"
    let display = WikiLinkService.makeDisplayState(from: storage)
    #expect(display.display == "Before [[Apple]] after")
    #expect(display.metadata.count == 1)
    let firstID = display.metadata.values.first?.id
    #expect(firstID == "11111111-2222-3333-4444-555555555555")
  }

  @Test func wikiLinkServiceLeavesPlainTextUntouched() {
    let storage = "no links here"
    let display = WikiLinkService.makeDisplayState(from: storage)
    #expect(display.display == storage)
    #expect(display.metadata.isEmpty)
  }

  // MARK: Tokenizer remains pure

  @Test func tokenizerParsesBoldEmphasisAndCode() {
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: "**bold** *italic* `code`")
    let kinds = tokens.map(\.kind)
    #expect(kinds.contains(.bold))
    #expect(kinds.contains(.italic))
    #expect(kinds.contains(.inlineCode))
  }

  @Test func tokenizerParsesStrikethrough() {
    let registry = ExtensionRegistry(extensions: [StrikethroughExtension()])
    let tokens = MarkdownTokenizer.parseTokensViaAST(
      in: "before ~~deleted~~ after", registry: registry)
    let strike = tokens.first {
      $0.kind == .extensionSpan(StrikethroughExtension.identifier)
    }
    #expect(strike != nil)
    #expect(strike?.markerRanges.count == 2)
    #expect(strike?.markerRanges.first?.length == 2)
    #expect(strike?.markerRanges.last?.length == 2)
  }

  @Test func tokenizerDoesNotMatchTripleTilde() {
    let registry = ExtensionRegistry(extensions: [StrikethroughExtension()])
    let tokens = MarkdownTokenizer.parseTokensViaAST(
      in: "~~~not strikethrough~~~", registry: registry)
    #expect(
      !tokens.contains {
        $0.kind == .extensionSpan(StrikethroughExtension.identifier)
      })
  }

  @Test func activeTokenDetectionUsesSelectionRangeIntersection() {
    let text = "aa **bold** zz"
    let tokens = MarkdownTokenizer.parseTokensViaAST(in: text)
    guard let boldIndex = tokens.firstIndex(where: { $0.kind == .bold }) else {
      Issue.record("Expected bold token")
      return
    }
    let active = MarkdownDetection.computeActiveTokenIndices(
      selectionRange: NSRange(location: 0, length: 5),
      tokens: tokens,
      in: text as NSString
    )
    #expect(active.contains(boldIndex))
  }

  // MARK: Default services container is fully wired with no-ops

  @Test func defaultServicesAreAllNoOps() {
    let services = MarkdownEditorServices.default
    #expect(services.wikiLinks is NoOpWikiLinkResolver)
    #expect(services.links is DefaultMarkdownLinkResolver)
    #expect(services.images is NoOpEmbeddedImageProvider)
    #expect(services.syntaxHighlighter is PlainTextSyntaxHighlighter)
    #expect(services.latex is NoOpLatexRenderer)
  }

  @Test func defaultBusHasNoNotificationNames() {
    let bus = MarkdownEditorBus.default
    #expect(bus.applyBoldRequest == nil)
    #expect(bus.applyItalicRequest == nil)
    #expect(bus.applyHeadingRequest == nil)
    #expect(bus.selectionBoldDidChange == nil)
    #expect(bus.selectionItalicDidChange == nil)
    #expect(bus.findScrollToRange == nil)
    #expect(bus.findClearHighlights == nil)
  }

  // MARK: Bullet markers render via styling, never by mutating storage

  /// Locations whose styled attributes carry `.bulletMarker` (i.e. the raw
  /// marker char is hidden and a `•` will be drawn there).
  private func bulletMarkerLocations(_ text: String, caret: Int) -> Set<Int> {
    let ranges = MarkdownStyler.styleAttributes(
      text: text,
      fontName: NSFont.systemFont(ofSize: 14).fontName,
      fontSize: 14,
      caretLocation: caret,
      activeTokenIndices: [],
      configuration: .default
    )
    var locations: Set<Int> = []
    for (range, attrs) in ranges where attrs[.bulletMarker] != nil {
      locations.insert(range.location)
    }
    return locations
  }

  @Test func dashBulletMarkerIsHiddenAndTagged() {
    // Caret off the marker line → the `-` at index 0 is tagged for a `•`.
    let text = "- 你好"
    #expect(bulletMarkerLocations(text, caret: (text as NSString).length).contains(0))
  }

  @Test func starAndPlusMarkersAreAlsoTagged() {
    // `* a\n+ b` — markers at index 0 and 4 both render as bullets.
    let text = "* a\n+ b"
    let locations = bulletMarkerLocations(text, caret: (text as NSString).length)
    #expect(locations.contains(0))
    #expect(locations.contains(4))
  }

  @Test func caretInsideMarkerSyntaxRevealsRawMarker() {
    // Caret between `-` and its space → marker revealed, not tagged.
    #expect(!bulletMarkerLocations("- item", caret: 1).contains(0))
  }

  @Test func taskCheckboxLineIsNotBulletTagged() {
    // `- [ ]` is owned by the checkbox styler, not the bullet styler.
    #expect(!bulletMarkerLocations("- [ ] todo", caret: 99).contains(0))
  }

  @Test func bulletInsideFencedCodeBlockIsNotTagged() {
    // The `-` at index 4 is inside ``` … ``` and stays plain text.
    #expect(!bulletMarkerLocations("```\n- x\n```", caret: 99).contains(4))
  }

  @Test func thematicBreakIsNotBulletTagged() {
    // `---` has no space after the first `-`, so it is never a bullet.
    #expect(bulletMarkerLocations("before\n---\nafter", caret: 99).isEmpty)
  }

  // MARK: Styler runs end-to-end with defaults

  @Test func stylerProducesAttributesWithDefaultServices() {
    let text = "# Heading\n\n**bold** and `code`"
    let ranges = MarkdownStyler.styleAttributes(
      text: text,
      fontName: NSFont.systemFont(ofSize: 14).fontName,
      fontSize: 14,
      caretLocation: 0,
      activeTokenIndices: [],
      configuration: .default
    )
    #expect(!ranges.isEmpty)
  }
}
