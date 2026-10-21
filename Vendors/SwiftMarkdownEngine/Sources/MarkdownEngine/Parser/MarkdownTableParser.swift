import Foundation

enum MarkdownTableAlignment {
  case left
  case center
  case right
}

struct MarkdownTable {
  let header: [String]
  let alignments: [MarkdownTableAlignment]
  let rows: [[String]]
}

enum MarkdownTableParser {
  static func parse(_ source: String) -> MarkdownTable? {
    let rawLines = source.components(separatedBy: CharacterSet.newlines)
    let lines = rawLines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return nil }

    let header = parseRow(lines[0])
    let alignments = parseAlignments(lines[1])
    guard !header.isEmpty, !alignments.isEmpty else { return nil }

    let columnCount = max(header.count, alignments.count)
    let bodyLines = Array(lines.dropFirst(2))

    func pad<T>(_ array: [T], to count: Int, with fill: T) -> [T] {
      if array.count == count { return array }
      if array.count > count { return Array(array.prefix(count)) }
      return array + Array(repeating: fill, count: count - array.count)
    }

    let paddedHeader = pad(header, to: columnCount, with: "")
    let paddedAlign = pad(alignments, to: columnCount, with: .left)
    let rows = bodyLines.map { pad(parseRow($0), to: columnCount, with: "") }

    return MarkdownTable(header: paddedHeader, alignments: paddedAlign, rows: rows)
  }

  static func stableContentHash(for source: String) -> Int {
    var hasher = Hasher()
    hasher.combine("table-overlay-v1")
    hasher.combine(source)
    return hasher.finalize()
  }

  static func stableSourceID(for source: String, occurrenceIndex: Int) -> Int {
    var hasher = Hasher()
    hasher.combine("table-overlay-v2")
    hasher.combine(source)
    hasher.combine(occurrenceIndex)
    return hasher.finalize()
  }

  private static func parseRow(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    return s.split(separator: "|", omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
  }

  private static func parseAlignments(_ line: String) -> [MarkdownTableAlignment] {
    let cells = parseRow(line)
    return cells.map { cell in
      let trimmed = cell.trimmingCharacters(in: .whitespaces)
      let leading = trimmed.hasPrefix(":")
      let trailing = trimmed.hasSuffix(":")
      switch (leading, trailing) {
      case (true, true): return .center
      case (false, true): return .right
      default: return .left
      }
    }
  }
}
