//
//  FindHighlightRestoreTests.swift
//  MarkdownEngineTests
//
//  Created by Luca Chen on 31.07.26.
//
//  Find paints with `.backgroundColor`, and so do extension spans, code fences
//  and table cells. Clearing find's highlights used to remove the attribute
//  document-wide, which erased their block until something else restyled.
//

import AppKit
import SwiftUI
import Testing

@testable import MarkdownEngine

/// `==text==` painted as an inverted block, like the Nodes app registers.
private struct InvertingHighlight: MarkdownExtension {
  var id: String { HighlightExtension.identifier }
  var inline: InlineSyntax? { InlineSyntax(open: "==", close: "==") }
  func contentAttributes(theme: MarkdownEditorTheme) -> [NSAttributedString.Key: Any] {
    [.backgroundColor: NSColor.white, .foregroundColor: NSColor.black]
  }
  func html(childrenHTML: String) -> String { "<mark>\(childrenHTML)</mark>" }
}

@MainActor
@Suite("Find highlights give the block back when they clear")
struct FindHighlightRestoreTests {

  // "plain ==marked== tail": content `marked` is {8, 6}, `tail` is {17, 4}.
  private static let text = "plain ==marked== tail"
  private static let blockContent = NSRange(location: 8, length: 6)

  private func makeEditor(_ text: String) -> (NativeTextViewCoordinator, NativeTextView) {
    _ = NSApplication.shared
    let coordinator = NativeTextViewCoordinator(
      text: .constant(text), fontName: "SF Pro", fontSize: 16,
      isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
    )
    coordinator.configuration.extensions = [InvertingHighlight()]
    let tv = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    tv.isEditable = true
    tv.delegate = coordinator
    // The find path scrolls the current match into view; give it a real
    // scroll view so it takes the TextKit 2 route instead of the TextKit 1
    // fallback, which has no layout manager to route through here.
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    scrollView.documentView = tv
    coordinator.textView = tv
    coordinator.rebuildTextStorageAndStyle(tv, from: text)
    coordinator.lastSyncedText = text
    coordinator.lastComputedStorage = text
    coordinator.previousDisplayLength = (text as NSString).length
    return (coordinator, tv)
  }

  private func background(_ tv: NativeTextView, at location: Int) -> NSColor? {
    tv.textStorage?.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
  }

  private func find(_ query: String, _ coordinator: NativeTextViewCoordinator) {
    coordinator.handleFindQuery(
      Notification(
        name: Notification.Name("findQuery"),
        object: nil,
        userInfo: ["query": query, "currentIndex": 0]
      ))
  }

  private func done(_ coordinator: NativeTextViewCoordinator) {
    coordinator.handleFindClearHighlights(
      Notification(name: Notification.Name("findClearHighlights"), object: nil)
    )
  }

  @Test("searching the highlighted word and dismissing leaves the block painted")
  func blockReturnsAfterClearingItsOwnMatch() {
    let (coordinator, tv) = makeEditor(Self.text)
    #expect(background(tv, at: Self.blockContent.location) == NSColor.white)

    find("marked", coordinator)
    #expect(background(tv, at: Self.blockContent.location) != NSColor.white)

    done(coordinator)
    // No click, no selection change: the block is back on its own.
    #expect(background(tv, at: Self.blockContent.location) == NSColor.white)
  }

  @Test("a match somewhere else never touches the block")
  func blockSurvivesAMatchElsewhere() {
    let (coordinator, tv) = makeEditor(Self.text)

    find("tail", coordinator)
    #expect(background(tv, at: Self.blockContent.location) == NSColor.white)

    done(coordinator)
    #expect(background(tv, at: Self.blockContent.location) == NSColor.white)
    #expect(background(tv, at: 17) == nil)
  }

  @Test("re-running the query drops the previous highlight instead of stacking")
  func repeatedQueriesLeaveNoResidue() {
    let (coordinator, tv) = makeEditor(Self.text)

    find("marked", coordinator)
    find("tail", coordinator)

    #expect(background(tv, at: Self.blockContent.location) == NSColor.white)
    #expect(background(tv, at: 17) != nil)
  }
}
