//
//  BacktickCensusTests.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 07.07.26.
//

import Foundation
import Testing

@testable import MarkdownEngine

@Suite("Backtick census")
struct BacktickCensusTests {

  @Test func matchesComponentsSemantics() {
    let samples = [
      "", "`", "``", "```", "````", "`````", "``````",
      "a```b```c",
      "x\n```swift\nlet a = 1\n```\ny",
      "inline `code` only",
      "```````",
    ]
    for sample in samples {
      let expected = sample.components(separatedBy: "```").count - 1
      #expect(
        MarkdownDetection.tripleBacktickCount(in: sample as NSString) == expected,
        "mismatch for \(sample.debugDescription)")
    }
  }

  @Test func fenceShapesSeparatePairingChanges() {
    func shapes(_ text: String) -> [MarkdownDetection.FenceShape] {
      let ns = text as NSString
      return MarkdownDetection.fenceShapes(in: ns, lines: NSRange(location: 0, length: ns.length))
    }
    let base = shapes("```\na\n````\n")
    #expect(shapes("plain\ntext\n").isEmpty)
    #expect(shapes("````\na\n````\n") != base)
    #expect(shapes("```\na\n````sh\n") != base)
    #expect(shapes("  ```\na\n````\n") != base)
    #expect(shapes("````\na\n```\n") != base)
    #expect(shapes("```\nb\n````\r\n") == base)
  }

  /// An edit's two `editedLines` windows must cover the same lines: the text
  /// outside them matches, so the fences outside them do too. Checked for
  /// every single-character edit, including line breaks that split a fence
  /// line, join it onto the line above, or split or join a CRLF.
  @Test func editedLinesCoverTheSameLinesBeforeAndAfterAnEdit() {
    let text = "intro\n```swift\r\nlet a = 1\r\n```\r\n\n  ````\n```\r````\ntail ```"
    let ns = text as NSString
    var edits: [(range: NSRange, insert: String)] = []
    for location in 0...ns.length {
      for insert in ["`", "s", " ", "\n", "\r"] {
        edits.append((NSRange(location: location, length: 0), insert))
      }
      if location < ns.length { edits.append((NSRange(location: location, length: 1), "")) }
    }
    for edit in edits {
      let edited = NSMutableString(string: text)
      edited.replaceCharacters(in: edit.range, with: edit.insert)
      let newRange = NSRange(
        location: edit.range.location, length: (edit.insert as NSString).length)
      let oldWindow = MarkdownDetection.editedLines(in: ns, around: edit.range)
      let newWindow = MarkdownDetection.editedLines(in: edited, around: newRange)
      let label = "replacing \(edit.range) with \(edit.insert.debugDescription)"

      #expect(
        ns.substring(to: oldWindow.location) == edited.substring(to: newWindow.location), "\(label)"
      )
      #expect(
        ns.substring(from: NSMaxRange(oldWindow)) == edited.substring(from: NSMaxRange(newWindow)),
        "\(label)")
      let prefix = MarkdownDetection.fenceShapes(
        in: ns, lines: NSRange(location: 0, length: oldWindow.location))
      let suffix = MarkdownDetection.fenceShapes(
        in: ns,
        lines: NSRange(location: NSMaxRange(oldWindow), length: ns.length - NSMaxRange(oldWindow)))
      #expect(
        prefix + MarkdownDetection.fenceShapes(in: edited, lines: newWindow) + suffix
          == MarkdownDetection.fenceShapes(
            in: edited, lines: NSRange(location: 0, length: edited.length)),
        "\(label)")
    }
  }
}
