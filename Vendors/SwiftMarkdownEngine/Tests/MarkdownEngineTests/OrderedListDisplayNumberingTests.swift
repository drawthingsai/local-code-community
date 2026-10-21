//
//  OrderedListDisplayNumberingTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 30.07.26.
//
//  Ordered items are numbered by POSITION and painted over the source digits.
//  Two things the styler alone cannot get right, and that a styler-only test
//  would happily hide:
//  * the block array a SCOPED restyle sees is not the document — the text
//    between two scoped regions is missing, so a run can look continuous when
//    prose actually ended it;
//  * the overlay is caret-aware, so the coordinator has to restyle when the
//    caret crosses a marker — no other signal covers ordered markers.
//

import AppKit
import Foundation
import Testing

@testable import MarkdownEngine

@MainActor
@Suite("Ordered list display numbering")
struct OrderedListDisplayNumberingTests {

  private let fontSize: CGFloat = 14
  private var fontName: String { NSFont.systemFont(ofSize: 14).fontName }

  /// `(markerLocation, paintedMarker)` for every overlaid ordered marker.
  /// Absent = the item paints its own literal digits (styler emits the
  /// overlay only when the display number differs from the source).
  private func overlays(_ attrs: [StyledRange]) -> [(loc: Int, text: String)] {
    attrs.compactMap { entry in
      (entry.1[.orderedMarker] as? String).map { (entry.0.location, $0) }
    }
    .sorted { $0.0 < $1.0 }
  }

  private func overlays(in tv: NSTextView) -> [(loc: Int, text: String)] {
    guard let storage = tv.textStorage else { return [] }
    var out: [(Int, String)] = []
    storage.enumerateAttribute(.orderedMarker, in: NSRange(location: 0, length: storage.length)) {
      value, range, _ in
      if let text = value as? String { out.append((range.location, text)) }
    }
    return out.sorted { $0.0 < $1.0 }
  }

  private func style(_ text: String, caret: Int = -1, scoped: [NSRange]? = nil) -> [StyledRange] {
    MarkdownASTStyler.styleAttributes(
      text: text, fontName: fontName, fontSize: fontSize,
      caretLocation: caret, scopedRanges: scoped
    )
  }

  private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
    _ = NSApplication.shared
    let coordinator = NativeTextViewCoordinator(
      text: .constant(text), fontName: "SF Pro", fontSize: 16,
      isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
    )
    let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    tv.isEditable = true
    tv.delegate = coordinator
    coordinator.textView = tv
    coordinator.rebuildTextStorageAndStyle(tv, from: text)
    coordinator.lastSyncedText = text
    coordinator.lastComputedStorage = text
    coordinator.previousDisplayLength = (text as NSString).length
    return (coordinator, tv)
  }

  // MARK: Scope

  /// A two-region scope (caret paragraph + previous-caret paragraph — what
  /// every click builds) drops the prose between the lists from the block
  /// array. The count must not flow across that hole.
  @Test("prose between two lists still ends the run when the scope skips it")
  func disjointScopeDoesNotCarryTheCountIntoTheNextList() {
    let text = "1. one\n2. two\n\nProse paragraph here.\n\n1. alpha\n2. beta\n"
    let ns = text as NSString
    let alpha = ns.range(of: "1. alpha")
    let scoped = [
      ns.paragraphRange(for: NSRange(location: 0, length: 0)),
      ns.paragraphRange(for: alpha),
    ]

    let painted = overlays(style(text, scoped: scoped))
      .filter { NSLocationInRange($0.loc, ns.paragraphRange(for: alpha)) }

    // `1. alpha` is item 1 of its own list: display == literal, nothing to
    // paint. Before the fix it inherited the upper list's count and painted "3.".
    #expect(painted.isEmpty)
    #expect(overlays(style(text)).isEmpty)  // and the full pass agrees
  }

  /// The counterpart: a blank line is loose-list spacing, not a terminator,
  /// so a scope that only sees the tail must still continue the run above it.
  @Test("scoped tail of a blank-split list keeps counting")
  func scopedTailOfBlankSplitListStillContinues() {
    let text = "1. one\n\n1. two\n"
    let ns = text as NSString
    let tail = ns.range(of: "1. two")

    let painted = overlays(style(text, scoped: [ns.paragraphRange(for: tail)]))

    #expect(painted.map(\.text) == ["2."])
    #expect(painted.first?.loc == tail.location)
  }

  /// The seed scans BACKWARD from the item's marker — which for an indented
  /// item still sits inside its own line, so it used to count that item and
  /// every nested list rendered one too high with no gesture at all.
  @Test("a nested ordered list starts at its own number")
  func nestedListDoesNotCountItself() {
    #expect(overlays(style("- outer\n  1. a\n  2. b")).isEmpty)
    #expect(overlays(style("- outer\n\t1. a\n\t2. b")).isEmpty)
    #expect(overlays(style("  1. alpha")).isEmpty)
    #expect(overlays(style("1. top\n  1. nested\n  2. nested")).isEmpty)
  }

  /// A hole of blank lines between two scoped blocks is loose-list spacing,
  /// so the count carries; a hole holding another item re-seeds from the
  /// source and lands on the same number. Both must agree with a full pass.
  @Test("a scope with holes counts through a loose list")
  func scopeWithHolesCountsThroughLooseList() {
    let text = "1. one\n\n1. two\n\n1. three\n"
    let ns = text as NSString
    let scoped = [
      ns.paragraphRange(for: NSRange(location: 0, length: 0)),
      ns.paragraphRange(for: ns.range(of: "1. three")),
    ]

    let painted = overlays(style(text, scoped: scoped))

    #expect(painted.map(\.text) == ["3."])
    #expect(overlays(style(text)).map(\.text) == ["2.", "3."])  // full pass agrees
  }

  // MARK: Caret

  /// The caret parked at the line start is where every whole-line delete and
  /// line-join leaves it — treating that as "editing the digits" is what made
  /// a 1./2./3. list read 1./1. after deleting item 2.
  @Test("caret at the line start keeps the display number")
  func caretAtTheLineStartKeepsTheDisplayNumber() {
    let painted = overlays(style("1. a\n1. b", caret: 5))

    #expect(painted.map(\.text) == ["2."])
    #expect(painted.first?.loc == 5)
  }

  @Test("caret on the digits reveals the raw marker")
  func caretOnTheDigitsRevealsTheRawMarker() {
    #expect(overlays(style("1. a\n1. b", caret: 6)).isEmpty)  // between `1` and `.`
    #expect(overlays(style("1. a\n1. b", caret: 7)).isEmpty)  // the space after `1.`
    #expect(overlays(style("1. a\n1. b", caret: 8)).count == 1)  // content: overlay is back
  }

  // MARK: Coordinator wiring

  /// The load-bearing half: the styler's reveal is caret-dependent, so a
  /// caret move across the marker has to trigger a restyle. Nothing else
  /// signals it (markers aren't tokens, the bullet regex has no digits).
  @Test("caret leaving the marker restyles the line")
  func caretLeavingTheMarkerRestylesTheLine() {
    let (_, tv) = makeEditor("1. a\n1. b")

    tv.setSelectedRange(NSRange(location: 6, length: 0))  // inside the digits
    #expect(overlays(in: tv).isEmpty)

    tv.setSelectedRange(NSRange(location: 2, length: 0))  // away, onto line 1
    #expect(overlays(in: tv).map(\.text) == ["2."])
  }

  /// A content keystroke shifts no number, so it keeps the default paragraph
  /// scope instead of restyling the whole list block — the numbers below it
  /// must survive that narrower pass untouched.
  @Test("typing inside an item leaves the run's numbers alone")
  func contentEditKeepsTheNumbers() {
    let (_, tv) = makeEditor("1. a\n1. b\n1. c")
    #expect(overlays(in: tv).map(\.text) == ["2.", "3."])

    tv.insertText("x", replacementRange: NSRange(location: 9, length: 0))  // end of item 2's content

    #expect(tv.string == "1. a\n1. bx\n1. c")
    #expect(overlays(in: tv).map(\.text) == ["2.", "3."])
  }

  /// End-to-end repro of the shipped-looking bug: delete the middle item and
  /// the survivor must renumber instead of showing its stale literal.
  @Test("deleting an item renumbers the survivor")
  func deletingAnItemRenumbersTheSurvivor() {
    let (_, tv) = makeEditor("1. a\n1. b\n1. c")
    #expect(overlays(in: tv).map(\.text) == ["2.", "3."])

    tv.insertText("", replacementRange: NSRange(location: 5, length: 5))  // remove "1. b\n"

    #expect(tv.string == "1. a\n1. c")
    #expect(overlays(in: tv).map(\.text) == ["2."])
  }
}
