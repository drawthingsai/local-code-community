/// Markdown code spans and fenced blocks around text that may contain backticks of its own.
/// CommonMark closes a span on a backtick run as long as its opener, and a block on a bare run at
/// least as long, so a delimiter longer than the text's longest run keeps the text intact.
enum MarkdownCode {
  static func block(_ code: String) -> String {
    let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: code) + 1))
    return "\(fence)\n\(code)\n\(fence)"
  }

  static func inline(_ code: String) -> String {
    let delimiter = String(repeating: "`", count: longestBacktickRun(in: code) + 1)
    // Parsers strip one space from each side, which keeps an edge backtick off the delimiter.
    let padded = code.hasPrefix("`") || code.hasSuffix("`") ? " \(code) " : code
    return "\(delimiter)\(padded)\(delimiter)"
  }

  private static func longestBacktickRun(in text: String) -> Int {
    var longest = 0
    var run = 0
    for character in text.utf8 {
      if character == UInt8(ascii: "`") {
        run += 1
        longest = max(longest, run)
      } else {
        run = 0
      }
    }
    return longest
  }
}
