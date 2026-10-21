//
//  MarkdownStyler+OrderedMarkers.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 30.07.26.
//
//  Caret-crossing helper for `1.` / `1)` ordered markers. The number the editor
//  SHOWS is positional (`MarkdownASTStyler`), and the raw source digits are
//  revealed while the caret edits them — so the coordinator needs to know when
//  the caret crosses that boundary, exactly like it already does for bullets,
//  task checkboxes and thematic breaks. Rendering itself lives in the AST
//  styler; this file only answers membership.
//

import AppKit
import Foundation

extension MarkdownStyler {

  /// Indented ordered marker at line start, excluding task items — the AST
  /// styler never overlays those, so their digits are always literal.
  static let orderedListRegex: NSRegularExpression = try! NSRegularExpression(
    pattern: #"^([ \t]*)(\d+[.)])([ \t]+)(?!\[[ xX]\])"#,
    options: [.anchorsMatchLines]
  )

  // MARK: Ordered Marker Membership

  /// True while the caret sits ON the digits — inside `syntax`, but never at
  /// its first offset. That one offset is excluded on purpose: every
  /// whole-line delete and line-join parks the caret exactly there, and
  /// counting it as "editing the digits" left the surviving item showing its
  /// stale literal (a 1./2./3. list read 1./1. after deleting item 2).
  static func caretRevealsOrderedMarker(caret: Int, syntax: NSRange) -> Bool {
    caret > syntax.location && caret < NSMaxRange(syntax)
  }

  /// `<digits><.|)><spaces>` range on `location`'s line while the caret
  /// reveals it, else `nil`. Paired with ``caretRevealsOrderedMarker`` so the
  /// coordinator's crossing signal and the styler's reveal cannot disagree.
  static func orderedSyntaxRange(at location: Int, in text: String) -> NSRange? {
    let nsText = text as NSString
    let safeLoc = max(0, min(location, nsText.length))
    let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
    let line = nsText.substring(with: lineRange)
    guard
      let match = orderedListRegex.firstMatch(
        in: line,
        options: [],
        range: NSRange(location: 0, length: line.utf16.count)
      )
    else { return nil }
    let markerLineRange = match.range(at: 2)
    let spacerLineRange = match.range(at: 3)
    guard markerLineRange.location != NSNotFound,
      spacerLineRange.location != NSNotFound
    else { return nil }
    let syntaxStart = lineRange.location + markerLineRange.location
    let syntaxEnd = lineRange.location + spacerLineRange.location + spacerLineRange.length
    let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
    return caretRevealsOrderedMarker(caret: safeLoc, syntax: syntaxRange) ? syntaxRange : nil
  }
}
