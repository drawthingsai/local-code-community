//
//  BacktickFenceEditorTests.swift
//  MarkdownEngineTests
//
//  A block closes only on a bare backtick run at least as long as its opener,
//  so an edit can re-pair every fence below it without changing how many ```
//  runs the document has. The editor has to restyle past the edited lines
//  for these, or later lines keep their old code styling until a rebuild.
//

import AppKit
import Foundation
import Testing

@testable import MarkdownEngine

@MainActor
@Suite("Backtick fence editor restyle")
struct BacktickFenceEditorTests {

  /// Two code blocks around a paragraph: `one` and `three` are code, `two` is not.
  private let source = "```\none\n```\n\ntwo\n\n```\nthree\n```"

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

  private func isCode(_ word: String, in tv: NSTextView) -> Bool {
    let location = (tv.string as NSString).range(of: word).location
    let font = tv.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    return font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
  }

  private func expectInitialStyling(_ tv: NSTextView) {
    #expect(isCode("one", in: tv))
    #expect(!isCode("two", in: tv))
    #expect(isCode("three", in: tv))
  }

  @Test("lengthening an opener re-pairs the fences below it")
  func lengtheningOpenerRestylesLaterLines() {
    let (_, tv) = makeEditor(source)
    expectInitialStyling(tv)

    tv.insertText("`", replacementRange: NSRange(location: 0, length: 0))

    #expect(tv.string == "````\none\n```\n\ntwo\n\n```\nthree\n```")
    #expect(isCode("two", in: tv))
    #expect(!isCode("three", in: tv))
  }

  @Test("an info string on a closer stops it closing")
  func infoStringOnCloserRestylesLaterLines() {
    let (_, tv) = makeEditor(source)
    expectInitialStyling(tv)

    tv.insertText("s", replacementRange: NSRange(location: 11, length: 0))

    #expect(tv.string == "```\none\n```s\n\ntwo\n\n```\nthree\n```")
    #expect(isCode("two", in: tv))
    #expect(!isCode("three", in: tv))
  }

  @Test("swapping two fence lengths in one replacement re-pairs the fences below them")
  func swappingFenceLengthsRestylesLaterLines() {
    // The four-backtick opener runs to the last fence, so `one` is code. With
    // the first two lengths swapped, the opener closes on the next line and
    // `one` is not. The fences are the same set either way, just reordered.
    let text = "````\nx\n```\n\none\n\n```\ntwo\n````\n\nend"
    let (_, tv) = makeEditor(text)
    // A caret outside every block keeps the active-token restyle from covering `one`.
    tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    #expect(isCode("one", in: tv))

    tv.insertText(
      "```\nx\n````",
      replacementRange: NSRange(location: 0, length: ("````\nx\n```" as NSString).length))

    #expect(tv.string == "```\nx\n````\n\none\n\n```\ntwo\n````\n\nend")
    #expect(isCode("x", in: tv))
    #expect(!isCode("one", in: tv))
    #expect(isCode("two", in: tv))
  }

  @Test("removing the LF of an opener's CRLF keeps the stored fences in step")
  func removingCRLFLineFeedKeepsFenceShapesCurrent() {
    let text = "```\r\ncode\r\n```\r\n\r\ntext"
    let (coordinator, tv) = makeEditor(text)

    tv.insertText("", replacementRange: NSRange(location: 4, length: 1))

    let edited = tv.string as NSString
    #expect(tv.string == "```\rcode\r\n```\r\n\r\ntext")
    #expect(
      coordinator.previousFenceShapes
        == MarkdownDetection.fenceShapes(
          in: edited, lines: NSRange(location: 0, length: edited.length)))
    #expect(isCode("code", in: tv))
    #expect(!isCode("text", in: tv))
  }

  @Test("joining a closer onto the line above re-pairs the fences below it")
  func joiningCloserRestylesLaterLines() {
    let (_, tv) = makeEditor(source)
    expectInitialStyling(tv)

    tv.insertText("", replacementRange: NSRange(location: 7, length: 1))

    #expect(tv.string == "```\none```\n\ntwo\n\n```\nthree\n```")
    #expect(isCode("two", in: tv))
    #expect(!isCode("three", in: tv))
  }
}
