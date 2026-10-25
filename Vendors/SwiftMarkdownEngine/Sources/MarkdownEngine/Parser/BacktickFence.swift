//
//  BacktickFence.swift
//  MarkdownEngine
//

import Foundation

/// Shared handling for the CommonMark rules on backtick fences.
/// A fence may be indented by up to three spaces; tabs and four-space
/// indentation remain ordinary text. When an opening fence is indented, its
/// indentation also controls how much leading space is removed from each code
/// line for rendering while the source ranges stay unchanged. A fence is a run
/// of three or more backticks, and a block closes only on a run at least as
/// long as its opener with nothing but whitespace after it, so a longer fence
/// can wrap content that contains ``` lines of its own.
enum BacktickFence {

  private static let backtick: unichar = 0x60
  private static let space: unichar = 0x20
  private static let tab: unichar = 0x09
  private static let lf: unichar = 0x0A
  private static let cr: unichar = 0x0D

  struct Match: Equatable {
    /// Absolute UTF-16 location of the first backtick.
    let markerLocation: Int
    /// Literal spaces before the backticks (`0...3`).
    let indentation: Int
    /// Backticks in the fence run (`3...`).
    let length: Int
    /// Whether anything other than whitespace follows the run, such as a language.
    let hasInfoString: Bool

    /// Whether this line closes a block opened by `opening`.
    func closes(_ opening: Match) -> Bool {
      !hasInfoString && length >= opening.length
    }
  }

  /// Dedented code plus the information needed to apply normalized ranges
  /// back to the source-preserving editor buffer.
  struct ContentProjection {
    let text: String
    let removedIndentRanges: [NSRange]

    private let sourceSegments: [(normalizedRange: NSRange, sourceRange: NSRange)]

    fileprivate init(
      text: String,
      removedIndentRanges: [NSRange],
      sourceSegments: [(normalizedRange: NSRange, sourceRange: NSRange)]
    ) {
      self.text = text
      self.removedIndentRanges = removedIndentRanges
      self.sourceSegments = sourceSegments
    }

    /// Maps a UTF-16 range in ``text`` to one or more absolute source ranges.
    /// A range is split wherever per-line indentation was removed.
    func sourceRanges(for normalizedRange: NSRange) -> [NSRange] {
      guard normalizedRange.location >= 0, normalizedRange.length > 0,
        NSMaxRange(normalizedRange) <= (text as NSString).length
      else { return [] }

      var result: [NSRange] = []
      for segment in sourceSegments {
        let intersection = NSIntersectionRange(normalizedRange, segment.normalizedRange)
        guard intersection.length > 0 else { continue }
        let sourceRange = NSRange(
          location: segment.sourceRange.location
            + intersection.location - segment.normalizedRange.location,
          length: intersection.length
        )
        if let last = result.last, NSMaxRange(last) == sourceRange.location {
          result[result.count - 1].length += sourceRange.length
        } else {
          result.append(sourceRange)
        }
      }
      return result
    }
  }

  /// Fence match in a standalone line string.
  static func match(in line: String) -> Match? {
    let ns = line as NSString
    return match(in: ns, lineRange: NSRange(location: 0, length: ns.length))
  }

  /// Fence match at the beginning of an absolute source line range.
  static func match(in text: NSString, lineRange: NSRange) -> Match? {
    guard lineRange.location >= 0, NSMaxRange(lineRange) <= text.length else { return nil }

    let lineEnd = NSMaxRange(lineRange)
    var marker = lineRange.location
    while marker < lineEnd, text.character(at: marker) == space {
      guard marker - lineRange.location < 3 else { return nil }
      marker += 1
    }

    var markerEnd = marker
    while markerEnd < lineEnd, text.character(at: markerEnd) == backtick { markerEnd += 1 }
    guard markerEnd - marker >= 3 else { return nil }

    // Line ranges may include the terminator, which is not an info string.
    var infoStart = markerEnd
    while infoStart < lineEnd {
      let character = text.character(at: infoStart)
      guard character == space || character == tab || character == lf || character == cr
      else { break }
      infoStart += 1
    }
    return Match(
      markerLocation: marker,
      indentation: marker - lineRange.location,
      length: markerEnd - marker,
      hasInfoString: infoStart < lineEnd
    )
  }

  /// CommonMark code content for a parser-produced fenced-code token.
  static func contentProjection(forCodeBlock token: MarkdownToken, in text: NSString)
    -> ContentProjection
  {
    let openingIndentation: Int
    if let openingRange = token.markerRanges.first,
      let opening = match(in: text, lineRange: openingRange)
    {
      openingIndentation = opening.indentation
    } else {
      openingIndentation = 0
    }
    return contentProjection(
      in: text,
      sourceRange: token.contentRange,
      openingIndentation: openingIndentation
    )
  }

  /// Removes up to `openingIndentation` literal spaces from every physical
  /// line while retaining absolute UTF-16 source mappings for the remainder.
  static func contentProjection(
    in text: NSString,
    sourceRange: NSRange,
    openingIndentation: Int
  ) -> ContentProjection {
    precondition(sourceRange.location >= 0 && NSMaxRange(sourceRange) <= text.length)
    precondition((0...3).contains(openingIndentation))

    let sourceEnd = NSMaxRange(sourceRange)
    let normalized = NSMutableString()
    var removedIndentRanges: [NSRange] = []
    var sourceSegments: [(normalizedRange: NSRange, sourceRange: NSRange)] = []
    var lineStart = sourceRange.location

    while lineStart < sourceEnd {
      var lineContentEnd = lineStart
      while lineContentEnd < sourceEnd {
        let character = text.character(at: lineContentEnd)
        if character == 0x0A || character == 0x0D { break }
        lineContentEnd += 1
      }

      var nextLineStart = lineContentEnd
      if nextLineStart < sourceEnd, text.character(at: nextLineStart) == 0x0D {
        nextLineStart += 1
      }
      if nextLineStart < sourceEnd, text.character(at: nextLineStart) == 0x0A {
        nextLineStart += 1
      }

      var projectedLineStart = lineStart
      while projectedLineStart < lineContentEnd,
        projectedLineStart - lineStart < openingIndentation,
        text.character(at: projectedLineStart) == space
      {
        projectedLineStart += 1
      }
      if projectedLineStart > lineStart {
        removedIndentRanges.append(
          NSRange(location: lineStart, length: projectedLineStart - lineStart))
      }

      let sourceSegment = NSRange(
        location: projectedLineStart,
        length: nextLineStart - projectedLineStart
      )
      if sourceSegment.length > 0 {
        let normalizedRange = NSRange(location: normalized.length, length: sourceSegment.length)
        normalized.append(text.substring(with: sourceSegment))
        sourceSegments.append((normalizedRange, sourceSegment))
      }
      lineStart = nextLineStart
    }

    return ContentProjection(
      text: normalized as String,
      removedIndentRanges: removedIndentRanges,
      sourceSegments: sourceSegments
    )
  }
}
