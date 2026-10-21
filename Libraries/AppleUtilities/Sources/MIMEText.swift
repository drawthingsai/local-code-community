import Foundation

/// Reads the text of an RFC 5322 message: its text parts that are not attachments, preferring
/// plain text over HTML among alternatives.
enum MIMEText {
  static func text(of message: [UInt8]) -> String? {
    text(of: message[...], depth: 0)
  }

  private static func text(of part: ArraySlice<UInt8>, depth: Int) -> String? {
    // Real messages nest a few levels; this bounds recursion on malformed ones.
    guard depth < 16 else { return nil }
    let (headers, body) = split(part)
    guard parameters(headers["content-disposition"]).value != "attachment" else { return nil }
    let contentType = parameters(headers["content-type"])
    let type = contentType.value.isEmpty ? "text/plain" : contentType.value
    if type.hasPrefix("multipart/") {
      guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty else {
        return nil
      }
      let parts = parts(of: body, boundary: boundary)
      guard type == "multipart/alternative" else {
        let texts = parts.compactMap { text(of: $0, depth: depth + 1) }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
      }
      // Alternatives are in increasing order of preference, but plain text reads better than
      // text converted from HTML.
      var preferred: String? = nil
      for alternative in parts {
        guard let text = text(of: alternative, depth: depth + 1) else { continue }
        if parameters(split(alternative).headers["content-type"]).value == "text/plain" {
          return text
        }
        preferred = text
      }
      return preferred
    }
    guard type == "text/plain" || type == "text/html" else { return nil }
    let bytes = decodeTransferEncoding(body, headers["content-transfer-encoding"])
    var content = decodeCharset(bytes, contentType.parameters["charset"])
    content =
      type == "text/html"
      ? htmlText(content) : content.replacingOccurrences(of: "\r\n", with: "\n")
    content = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return content.isEmpty ? nil : content
  }

  /// Splits a part at its first empty line into unfolded headers, keyed by lowercase name, and
  /// its body. Only the first of repeated headers is kept.
  static func split(_ bytes: ArraySlice<UInt8>) -> (
    headers: [String: String], body: ArraySlice<UInt8>
  ) {
    var headers = [String: String]()
    var current: String? = nil
    var lineStart = bytes.startIndex
    while lineStart < bytes.endIndex {
      let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.endIndex
      let next = min(lineEnd + 1, bytes.endIndex)
      var line = bytes[lineStart..<lineEnd]
      if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
      guard let first = line.first else { return (headers, bytes[next...]) }
      let text = String(decoding: line, as: UTF8.self)
      if first == UInt8(ascii: " ") || first == UInt8(ascii: "\t") {
        if let current {
          headers[current, default: ""] += " " + text.trimmingCharacters(in: .whitespaces)
        }
      } else if let colon = text.firstIndex(of: ":") {
        let name = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        current = headers[name] == nil ? name : nil
        if current != nil {
          headers[name] = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
      } else {
        current = nil
      }
      lineStart = next
    }
    return (headers, bytes[bytes.endIndex...])
  }

  /// Parses a header such as `text/plain; charset="utf-8"` into its lowercase value and its
  /// parameters, keyed by lowercase name and unquoted.
  static func parameters(_ header: String?) -> (value: String, parameters: [String: String]) {
    guard let header else { return ("", [:]) }
    var fields = [String]()
    var field = ""
    var isQuoted = false
    var isEscaped = false
    for character in header {
      if isEscaped {
        field.append(character)
        isEscaped = false
      } else if isQuoted && character == "\\" {
        isEscaped = true
      } else if character == "\"" {
        isQuoted.toggle()
      } else if character == ";" && !isQuoted {
        fields.append(field)
        field = ""
      } else {
        field.append(character)
      }
    }
    fields.append(field)
    var parameters = [String: String]()
    for field in fields.dropFirst() {
      guard let equals = field.firstIndex(of: "=") else { continue }
      let name = field[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
      parameters[name] = field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }
    return (fields[0].trimmingCharacters(in: .whitespaces).lowercased(), parameters)
  }

  /// The parts between boundary lines. The line break before each boundary line belongs to it,
  /// and a missing closing boundary ends the last part at the end of the body.
  static func parts(of body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
    let delimiter = Array("--\(boundary)".utf8)
    var parts = [ArraySlice<UInt8>]()
    var partStart: Int? = nil
    var lineStart = body.startIndex
    while lineStart < body.endIndex {
      let lineEnd = body[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? body.endIndex
      let line = body[lineStart..<lineEnd]
      lineStart = lineEnd + 1
      guard line.starts(with: delimiter) else { continue }
      var rest = line.dropFirst(delimiter.count)
      let isClosing = rest.starts(with: Array("--".utf8))
      if isClosing { rest = rest.dropFirst(2) }
      guard rest.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == 13 })
      else { continue }
      if let partStart {
        var partEnd = line.startIndex
        if partEnd > partStart, body[partEnd - 1] == UInt8(ascii: "\n") { partEnd -= 1 }
        if partEnd > partStart, body[partEnd - 1] == UInt8(ascii: "\r") { partEnd -= 1 }
        parts.append(body[partStart..<partEnd])
      }
      if isClosing { return parts }
      partStart = min(lineEnd + 1, body.endIndex)
    }
    if let partStart, partStart < body.endIndex { parts.append(body[partStart...]) }
    return parts
  }

  static func decodeTransferEncoding(_ body: ArraySlice<UInt8>, _ encoding: String?) -> [UInt8] {
    switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
    case "base64":
      // Skip line breaks and anything else outside the alphabet, then repad.
      var characters = body.filter {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0)
          || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
          || $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "/")
      }
      if characters.count % 4 == 1 { characters.removeLast() }
      characters += Array(repeating: UInt8(ascii: "="), count: (4 - characters.count % 4) % 4)
      return Data(base64Encoded: Data(characters)).map { Array($0) } ?? []
    case "quoted-printable":
      var bytes = [UInt8]()
      bytes.reserveCapacity(body.count)
      var index = body.startIndex
      while index < body.endIndex {
        let byte = body[index]
        index += 1
        guard byte == UInt8(ascii: "=") else {
          bytes.append(byte)
          continue
        }
        if index + 1 < body.endIndex, let high = hexValue(body[index]),
          let low = hexValue(body[index + 1])
        {
          bytes.append(high << 4 | low)
          index += 2
          continue
        }
        // A soft line break, possibly after trailing whitespace, joins lines.
        var end = index
        while end < body.endIndex, body[end] == UInt8(ascii: " ") || body[end] == 9 { end += 1 }
        if end < body.endIndex, body[end] == 13 { end += 1 }
        if end < body.endIndex, body[end] == UInt8(ascii: "\n") {
          index = end + 1
        } else if end == body.endIndex {
          index = end
        } else {
          bytes.append(byte)
        }
      }
      return bytes
    default:
      return Array(body)
    }
  }

  /// Decodes with the declared character set, then UTF-8, then Latin-1, which never fails.
  static func decodeCharset(_ bytes: [UInt8], _ charset: String?) -> String {
    var encodings = [String.Encoding]()
    switch charset?.lowercased() {
    // Messages labeled with these often contain characters only in GB 18030, their superset.
    case "gb2312", "gbk", "x-gbk", "euc-cn", "gb18030":
      encodings.append(
        String.Encoding(
          rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
    // Messages labeled Latin-1 often use Windows-1252 punctuation, as browsers assume.
    case "iso-8859-1", "latin1":
      encodings.append(.windowsCP1252)
    case let name?:
      let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
      if encoding != kCFStringEncodingInvalidId {
        encodings.append(
          String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
      }
    case nil:
      break
    }
    for encoding in encodings + [.utf8] {
      if let text = String(bytes: bytes, encoding: encoding) { return text }
    }
    return String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
  }

  /// Renders HTML as plain text: tags become line breaks or nothing, whitespace collapses as in
  /// a browser, and scripts, styles and titles are dropped.
  static func htmlText(_ html: String) -> String {
    let scalars = Array(html.unicodeScalars)
    var output = String.UnicodeScalarView()
    var isSpacePending = false

    func append(_ scalar: Unicode.Scalar) {
      if isSpacePending, let last = output.last, last != "\n" { output.append(" ") }
      isSpacePending = false
      output.append(scalar)
    }
    func breakLine(blank: Bool) {
      isSpacePending = false
      while output.last == " " { output.removeLast() }
      guard !output.isEmpty else { return }
      var trailing = output.reversed().prefix { $0 == "\n" }.count
      while trailing < (blank ? 2 : 1) {
        output.append("\n")
        trailing += 1
      }
    }

    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      // As in browsers, only a letter, /, ! or ? after < starts a tag.
      guard scalar == "<", index + 1 < scalars.count,
        case let next = scalars[index + 1],
        next.isASCII && (next.properties.isAlphabetic || "/!?".unicodeScalars.contains(next))
      else {
        index += 1
        if scalar == "&", let entity = entity(scalars, at: index - 1) {
          index += entity.length - 1
          for scalar in entity.text.unicodeScalars {
            if scalar == " " || scalar == "\u{A0}" {
              isSpacePending = true
            } else {
              append(scalar)
            }
          }
        } else if scalar.properties.isWhitespace {
          isSpacePending = true
        } else if !invisible.contains(scalar) {
          append(scalar)
        }
        continue
      }
      if scalars[index...].starts(with: "<!--".unicodeScalars) {
        index = firstIndex(of: "-->", in: scalars, from: index + 4).map { $0 + 3 } ?? scalars.count
        continue
      }
      // Finds the end of the tag, skipping quoted attribute values.
      var end = index + 1
      var quote: Unicode.Scalar? = nil
      while end < scalars.count {
        if let open = quote {
          if scalars[end] == open { quote = nil }
        } else if scalars[end] == "\"" || scalars[end] == "'" {
          quote = scalars[end]
        } else if scalars[end] == ">" {
          break
        }
        end += 1
      }
      guard end < scalars.count else {
        append(scalar)
        index += 1
        continue
      }
      let tag = scalars[(index + 1)..<end]
      index = end + 1
      let isClosing = tag.first == "/"
      let name = String(
        String.UnicodeScalarView(
          tag.drop { $0 == "/" }.prefix { CharacterSet.alphanumerics.contains($0) })
      ).lowercased()
      switch name {
      case "script", "style", "title":
        // Their content is not markup, so skip to the closing tag.
        guard !isClosing, tag.last != "/" else { break }
        index =
          firstIndex(of: "</\(name)", in: scalars, from: index)
          .flatMap { scalars[$0...].firstIndex(of: ">") }.map { $0 + 1 } ?? scalars.count
      case "br":
        breakLine(blank: false)
      case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "hr", "table", "ul", "ol":
        breakLine(blank: true)
      case "div", "tr", "dl", "dt", "dd", "pre", "section", "article", "header", "footer",
        "center", "form":
        breakLine(blank: false)
      case "li":
        breakLine(blank: false)
        if !isClosing {
          append("-")
          isSpacePending = true
        }
      case "td", "th":
        isSpacePending = true
      default:
        break
      }
    }
    return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Zero-width characters that newsletters use to pad their previews.
  private static let invisible: Set<Unicode.Scalar> = [
    "\u{AD}", "\u{34F}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
  ]

  private static let entities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ensp": " ",
    "emsp": " ", "thinsp": " ", "zwnj": "", "zwj": "", "shy": "", "copy": "©", "reg": "®",
    "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
    "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•", "middot": "·",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "times": "×",
    "divide": "÷",
  ]

  /// Decodes the character reference at `index`, such as &amp; or &#x1F44B;, returning its text
  /// and length. Unknown names are left as text.
  private static func entity(_ scalars: [Unicode.Scalar], at index: Int) -> (
    text: String, length: Int
  )? {
    var end = index + 1
    while end < scalars.count, end - index <= 32, scalars[end] != ";" { end += 1 }
    guard end < scalars.count, scalars[end] == ";", end > index + 1 else { return nil }
    let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
    let length = end - index + 1
    guard name.first == "#" else {
      return entities[name.lowercased()].map { ($0, length) }
    }
    let digits = name.dropFirst()
    let value =
      digits.first == "x" || digits.first == "X"
      ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
    guard let value else { return nil }
    return (String(Unicode.Scalar(value) ?? "\u{FFFD}"), length)
  }

  /// Where `pattern` next occurs at or after `start`, ignoring the case of ASCII letters.
  private static func firstIndex(of pattern: String, in scalars: [Unicode.Scalar], from start: Int)
    -> Int?
  {
    let pattern = Array(pattern.lowercased().unicodeScalars)
    guard scalars.count >= pattern.count, start <= scalars.count - pattern.count else {
      return nil
    }
    for index in start...(scalars.count - pattern.count) {
      let matches = zip(scalars[index...], pattern).allSatisfy { scalar, character in
        let value = (65...90).contains(scalar.value) ? scalar.value + 32 : scalar.value
        return value == character.value
      }
      if matches { return index }
    }
    return nil
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    default: return nil
    }
  }
}
