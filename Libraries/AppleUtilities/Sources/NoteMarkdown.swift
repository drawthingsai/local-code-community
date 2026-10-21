import Foundation

/// Converts a note to Markdown, following the Obsidian Importer: headings, lists, checklists,
/// block quotes, code blocks, bold, italic, strikethrough and links. Underline, color, font and
/// alignment have no Markdown, so only their text is kept.
enum NoteMarkdown {
  typealias Note = NoteDocument.Note
  typealias AttributeRun = NoteDocument.AttributeRun

  private typealias Fragment = (run: AttributeRun, text: String)

  /// Shift-Return inserts U+2028 instead of ending the paragraph.
  private static let softReturn: Character = "\u{2028}"

  private enum Block {
    case none
    case code
    case list
  }

  /// `attachment` returns the Markdown for an attachment, such as a link to its file or a table.
  static func markdown(
    _ note: Note, isTableCell: Bool = false,
    attachment: (NoteDocument.AttachmentInfo) -> String
  ) -> String {
    var fragments = self.fragments(note)
    omitHeadingBold(&fragments)
    var block = Block.none
    var listNumbers = [Int: Int]()
    var markdown = ""
    for (index, fragment) in fragments.enumerated() {
      let run = fragment.run
      let isLineStart = index == 0 || fragments[index - 1].text.contains("\n")
      markdown += transition(&block, to: run)
      var text = fragment.text
      if text.contains(softReturn) {
        text = expandSoftReturns(text, run: run, isInCode: block == .code, after: markdown)
      }
      if let info = run.attachment, text.contains(where: { !$0.isWhitespace }) {
        let rendered = attachment(info)
        markdown +=
          isLineStart && !isBlock(info)
          ? paragraph(rendered, run: run, block: block, listNumbers: &listNumbers) : rendered
      } else if block == .code || text.allSatisfy(\.isWhitespace) {
        markdown += text
      } else {
        let inline = inline(text, run: run)
        markdown +=
          isLineStart
          ? paragraph(inline, run: run, block: block, listNumbers: &listNumbers) : inline
      }
    }
    if block == .code { markdown += "```\n" }
    markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    if isTableCell {
      // A newline or pipe would end the cell.
      return markdown.replacingOccurrences(of: "|", with: "\\|")
        .replacingOccurrences(of: "\n", with: "<br>")
    }
    return collapseBlankLines(markdown)
  }

  /// A table whose first row is its header.
  static func table(_ rows: [[String]]) -> String {
    guard let header = rows.first else { return "" }
    var lines = rows.map { "| " + $0.joined(separator: " | ") + " |" }
    lines.insert("|" + String(repeating: " --- |", count: header.count), at: 1)
    return "\n" + lines.joined(separator: "\n") + "\n\n"
  }

  /// Splits the text into runs of one style, then splits those at line breaks and at leading
  /// and trailing whitespace, so that no formatting crosses a line or ends in a space.
  private static func fragments(_ note: Note) -> [Fragment] {
    let utf16 = Array(note.text.utf16)
    var runs = note.runs
    let covered = runs.reduce(0) { $0 + max(0, $1.length) }
    if covered < utf16.count {
      runs.append(AttributeRun(length: utf16.count - covered))
    }
    var fragments = [Fragment]()
    var start = 0
    var index = 0
    while index < runs.count {
      let run = runs[index]
      var end = start
      repeat {
        end += max(0, runs[index].length)
        index += 1
      } while index < runs.count && runs[index].hasSameStyle(as: run)
      let lower = min(start, utf16.count)
      let text = String(decoding: utf16[lower..<min(max(end, lower), utf16.count)], as: UTF16.self)
      start = end
      fragments += split(text).map { (run, $0) }
    }
    return fragments
  }

  /// Whitespace at either end, and whitespace around a line break, become their own pieces.
  private static func split(_ text: String) -> [String] {
    let characters = Array(text)
    var pieces = [String]()
    var current = ""
    var index = 0
    while index < characters.count {
      guard characters[index].isWhitespace else {
        current.append(characters[index])
        index += 1
        continue
      }
      var end = index
      while end < characters.count, characters[end].isWhitespace { end += 1 }
      let whitespace = String(characters[index..<end])
      if index == 0 || end == characters.count || whitespace.contains("\n") {
        if !current.isEmpty { pieces.append(current) }
        current = ""
        pieces.append(whitespace)
      } else {
        current += whitespace
      }
      index = end
    }
    if !current.isEmpty { pieces.append(current) }
    return pieces
  }

  /// Attachments add line breaks of their own, so this keeps one blank line at most, except in
  /// code blocks.
  private static func collapseBlankLines(_ markdown: String) -> String {
    var lines = [Substring]()
    var isInCode = false
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("```") { isInCode.toggle() }
      let isBlank = line.allSatisfy(\.isWhitespace)
      if !isInCode, isBlank, lines.last?.allSatisfy(\.isWhitespace) == true { continue }
      lines.append(isBlank && !isInCode ? "" : line)
    }
    return lines.joined(separator: "\n")
  }

  /// Notes makes headings bold, which Markdown headings already are.
  private static func omitHeadingBold(_ fragments: inout [Fragment]) {
    var lineStart = 0
    for lineEnd in 0...fragments.count {
      if lineEnd < fragments.count, !fragments[lineEnd].text.contains("\n") { continue }
      let content = (lineStart..<lineEnd).filter {
        fragments[$0].text.contains { !$0.isWhitespace }
      }
      if let first = content.first, let type = fragments[first].run.style?.type,
        [.title, .heading, .subheading].contains(type),
        content.allSatisfy({
          !fragments[$0].text.contains(softReturn)
            && [.bold, .boldItalic].contains(fragments[$0].run.fontWeight)
        })
      {
        for index in lineStart..<lineEnd {
          switch fragments[index].run.fontWeight {
          case .bold: fragments[index].run.fontWeight = .regular
          case .boldItalic: fragments[index].run.fontWeight = .italic
          default: break
          }
        }
      }
      lineStart = lineEnd + 1
    }
  }

  /// Opens or closes the code block or list that spans paragraphs.
  private static func transition(_ block: inout Block, to run: AttributeRun) -> String {
    let type = run.style?.type ?? .body
    var prefix = ""
    switch block {
    case .list:
      if (run.style?.indent ?? 0) == 0 && !type.isList || run.attachment.map(isBlock) == true {
        block = .none
      }
    case .code:
      if type != .monospaced {
        block = .none
        prefix += "```\n"
      }
    case .none:
      break
    }
    if block == .none {
      if type == .monospaced {
        block = .code
        prefix += "\n```\n"
      } else if type.isList {
        block = .list
      }
    }
    return prefix
  }

  private static func expandSoftReturns(
    _ text: String, run: AttributeRun, isInCode: Bool, after markdown: String
  ) -> String {
    // A list item continues on an indented line.
    var lineBreak = "\n"
    if !isInCode, let style = run.style, style.type.isList {
      lineBreak += String(repeating: "\t", count: style.indent + 1)
    }
    let line =
      markdown.lastIndex(of: "\n").map { markdown[markdown.index(after: $0)...] } ?? markdown[...]
    var isOnLine = line.contains { !$0.isWhitespace }
    var expanded = ""
    for character in text {
      if character == softReturn {
        expanded += isOnLine ? lineBreak : "\n"
        isOnLine = false
      } else {
        expanded.append(character)
        isOnLine = character == "\n" ? false : isOnLine || !character.isWhitespace
      }
    }
    return expanded
  }

  private static func inline(_ text: String, run: AttributeRun) -> String {
    var markdown = text
    switch run.fontWeight {
    case .bold: markdown = "**\(markdown)**"
    case .italic: markdown = "*\(markdown)*"
    case .boldItalic: markdown = "***\(markdown)***"
    case .regular: break
    }
    if run.strikethrough { markdown = "~~\(markdown)~~" }
    if let link = run.link, !link.isEmpty, link != markdown {
      markdown = "[\(markdown)](\(destination(link)))"
    }
    return markdown
  }

  private static func paragraph(
    _ text: String, run: AttributeRun, block: Block, listNumbers: inout [Int: Int]
  ) -> String {
    let style = run.style ?? NoteDocument.ParagraphStyle()
    let indent = String(repeating: "\t", count: style.indent)
    var prelude = style.isBlockQuote ? "> " : ""
    // Each list level counts on its own, and a paragraph ends the lists nested deeper.
    listNumbers = listNumbers.filter {
      $0.key < style.indent || $0.key == style.indent && style.type == .numberedList
    }
    switch style.type {
    case .title: return prelude + "# " + text
    case .heading: return prelude + "## " + text
    case .subheading: return prelude + "### " + text
    case .dottedList, .dashedList: return prelude + indent + "- " + text
    case .numberedList:
      let number = listNumbers[style.indent, default: 0] + 1
      listNumbers[style.indent] = number
      return prelude + indent + "\(number). " + text
    case .checklist:
      return prelude + indent + (style.isChecked == true ? "- [x] " : "- [ ] ") + text
    case .body, .monospaced:
      // A paragraph indented to line up with a list.
      if block == .list { prelude += indent }
      return prelude + text
    }
  }

  /// A link destination that may contain spaces or parentheses.
  static func destination(_ link: String) -> String {
    link.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) ? "<\(link)>" : link
  }

  /// Hashtags, mentions and links to other notes sit in a line; other attachments are blocks.
  private static func isBlock(_ info: NoteDocument.AttachmentInfo) -> Bool {
    !info.type.contains("com.apple.notes.inlinetextattachment")
  }
}
