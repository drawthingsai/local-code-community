import Foundation

struct MarkdownTaskCheckboxMatch {
  let markerRange: NSRange
  let spacerRange: NSRange
  let checkboxRange: NSRange
  let isChecked: Bool
}

enum MarkdownTaskCheckboxParser {
  static let taskListRegex: NSRegularExpression = try! NSRegularExpression(
    pattern: #"^([ \t]*)([-•]|\d+\.)([ \t]+)(\[[ xX]\])(?=[ \t])"#,
    options: [.anchorsMatchLines]
  )

  static func matches(in text: String, range: NSRange) -> [MarkdownTaskCheckboxMatch] {
    let nsText = text as NSString
    return taskListRegex.matches(in: text, options: [], range: range).compactMap { match in
      let markerRange = match.range(at: 2)
      let spacerRange = match.range(at: 3)
      let checkboxRange = match.range(at: 4)
      guard checkboxRange.location != NSNotFound else { return nil }
      let checkboxText = nsText.substring(with: checkboxRange)
      let isChecked = checkboxText.range(of: "[x]", options: [.caseInsensitive]) != nil
      return MarkdownTaskCheckboxMatch(
        markerRange: markerRange,
        spacerRange: spacerRange,
        checkboxRange: checkboxRange,
        isChecked: isChecked
      )
    }
  }

  static func syntaxRange(at location: Int, in text: String) -> NSRange? {
    let nsText = text as NSString
    let safeLoc = max(0, min(location, nsText.length))
    let lineRange = nsText.lineRange(for: NSRange(location: safeLoc, length: 0))
    let line = nsText.substring(with: lineRange)
    let match = taskListRegex.firstMatch(
      in: line,
      options: [],
      range: NSRange(location: 0, length: line.utf16.count)
    )
    guard let match else { return nil }
    let markerLineRange = match.range(at: 2)
    let checkboxLineRange = match.range(at: 4)
    guard markerLineRange.location != NSNotFound,
      checkboxLineRange.location != NSNotFound
    else { return nil }
    let syntaxStart = lineRange.location + markerLineRange.location
    let syntaxEnd = lineRange.location + checkboxLineRange.location + checkboxLineRange.length
    let syntaxRange = NSRange(location: syntaxStart, length: syntaxEnd - syntaxStart)
    if NSLocationInRange(location, syntaxRange) || location == syntaxEnd {
      return syntaxRange
    }
    return nil
  }
}
