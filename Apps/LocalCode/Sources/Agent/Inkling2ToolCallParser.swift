import Foundation

/// Reads Inkling 2's output, decoded with its special tokens as text: a sequence of messages, each
/// `<|message_model|>HEADER<|content_KIND|>BODY<|end_message|>`, where a header may be left out.
/// Text messages (`<|content_text|>`, and `<|content_tool_error|>` and `<|content_invoke_tool_text|>`,
/// which the official response parser reads as content too) make up the visible text; thinking
/// messages are left out. A tool call is a message whose header names the tool and whose body is
/// `{"name":NAME,"args":{...}}` after `<|content_invoke_tool_json|>`. The chat template writes the
/// same name in both. When the model's differ, the header's wins: Inkling 2 Mini has written a
/// `bash_wait` header over a body naming `bash`, with `bash_wait`'s arguments. The official response
/// parser reads only the body's, which names a call without a header. String arguments are
/// reported as strings and other values as their JSON text. A message ends only at
/// `<|end_message|>`, so a literal one inside an argument ends the call early.
public struct Inkling2ToolCallParser {
  static let modelMessageStart = "<|message_model|>"
  static let endMessage = "<|end_message|>"
  static let thinkingContent = "<|content_thinking|>"
  static let invokeToolJSONContent = "<|content_invoke_tool_json|>"
  static let textContents = [
    "<|content_text|>", "<|content_tool_error|>", "<|content_invoke_tool_text|>",
  ]
  private static let markers =
    [modelMessageStart, endMessage, thinkingContent, invokeToolJSONContent] + textContents
  private static let longestMarkerLength = markers.map(\.count).max()!

  private enum State {
    case outside
    case header
    case text
    case thinking
    case toolCall
  }

  private var state = State.outside
  private var buffer = ""
  private var header = ""
  private var body = ""
  private var nextToolCallId: Int32 = 0

  /// The visible text so far: the bodies of text messages, and anything outside a message.
  public private(set) var text = ""
  public private(set) var toolCalls: [ToolCall] = []
  public private(set) var incompleteToolCall: ToolCall?
  public var hasIncompleteToolCall: Bool { state == .toolCall }

  public init() {}

  public mutating func append(_ data: String) {
    guard !data.isEmpty else { return }
    buffer += data
    while let (range, marker) = Self.firstMarker(in: buffer) {
      consume(String(buffer[..<range.lowerBound]))
      buffer.removeSubrange(buffer.startIndex..<range.upperBound)
      transition(on: marker)
    }
    // Keep only a suffix that could still become a marker.
    var kept = ""
    for length in stride(from: min(buffer.count, Self.longestMarkerLength - 1), through: 1, by: -1)
    where Self.markers.contains(where: { $0.hasPrefix(buffer.suffix(length)) }) {
      kept = String(buffer.suffix(length))
      break
    }
    consume(String(buffer.dropLast(kept.count)))
    buffer = kept
    updateIncompleteToolCall()
  }

  /// Ends the output: a held partial marker is text, and a header that never got a content marker
  /// was text too. A call still being written stays incomplete.
  public mutating func finish() {
    let remaining = buffer
    buffer = ""
    consume(remaining)
    if state == .header {
      text += header
      header = ""
      state = .outside
    }
    updateIncompleteToolCall()
  }

  private mutating func consume(_ string: String) {
    guard !string.isEmpty else { return }
    switch state {
    case .outside, .text:
      text += string
    case .header:
      header += string
    case .thinking:
      break
    case .toolCall:
      body += string
    }
  }

  private mutating func transition(on marker: String) {
    switch (state, marker) {
    case (.outside, Self.modelMessageStart), (.header, Self.modelMessageStart):
      // A header without content was not a message.
      if state == .header { text += header }
      header = ""
      state = .header
    case (.outside, _), (.header, _):
      if marker == Self.endMessage {
        if state == .header { text += header }
        header = ""
        state = .outside
      } else if marker == Self.thinkingContent {
        state = .thinking
      } else if marker == Self.invokeToolJSONContent {
        body = ""
        state = .toolCall
      } else {
        state = .text
      }
    case (.toolCall, Self.endMessage):
      let raw =
        Self.modelMessageStart + header + Self.invokeToolJSONContent + body + Self.endMessage
      if let request = Self.request(header: header, body: body, isComplete: true) {
        toolCalls.append(ToolCall(id: nextToolCallId, raw: raw, request: request))
        nextToolCallId += 1
      }
      header = ""
      body = ""
      state = .outside
    case (.toolCall, _):
      body += marker
    case (_, Self.endMessage):
      header = ""
      state = .outside
    case (.text, _):
      text += marker
    case (.thinking, _):
      break
    }
  }

  private mutating func updateIncompleteToolCall() {
    guard state == .toolCall else {
      incompleteToolCall = nil
      return
    }
    incompleteToolCall = Self.request(header: header, body: body + buffer, isComplete: false).map {
      ToolCall(
        id: nextToolCallId,
        raw: Self.modelMessageStart + header + Self.invokeToolJSONContent + body + buffer,
        request: $0)
    }
  }

  /// The earliest marker in `text`.
  private static func firstMarker(in text: String) -> (Range<String.Index>, String)? {
    var searchStart = text.startIndex
    while let start = text[searchStart...].range(of: "<|")?.lowerBound {
      for marker in markers where text[start...].hasPrefix(marker) {
        return (start..<text.index(start, offsetBy: marker.count), marker)
      }
      searchStart = text.index(after: start)
    }
    return nil
  }

  /// A call from its header and body. An incomplete body is read as if it closed where it stops,
  /// so arguments show while they stream in.
  private static func request(header: String, body: String, isComplete: Bool) -> ToolCall.Request? {
    let object: [String: Any]?
    if isComplete {
      object = jsonObject(body)
    } else {
      object = partialJSONObject(body)
    }
    var name = header.trimmingCharacters(in: .whitespacesAndNewlines)
    if !isValidName(name) {
      name = (object?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    guard isValidName(name) else { return nil }
    guard let object else {
      // A complete call must be JSON; one still streaming may not have reached its arguments.
      return isComplete ? nil : ToolCall.Request(function: name, parameters: [:])
    }
    let arguments = object["args"] as? [String: Any] ?? object["arguments"] as? [String: Any]
    if isComplete, arguments == nil, object["args"] != nil || object["arguments"] != nil {
      return nil
    }
    var parameters = [String: ToolCall.Request.Parameter]()
    for (key, value) in arguments ?? [:] {
      if let string = value as? String {
        parameters[key] = ToolCall.Request.Parameter(string: true, value: string)
      } else {
        parameters[key] = ToolCall.Request.Parameter(string: false, value: json(value))
      }
    }
    return ToolCall.Request(function: name, parameters: parameters)
  }

  private static func isValidName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("<") && !name.contains(">")
  }

  private static func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// Reads a body cut off while streaming as the object written so far. The body closes where it
  /// stops inside a string argument or a number, and otherwise after its last whole value: a key
  /// still being written, or one whose value has not started, is left out, as the other parsers
  /// leave out a parameter until its value starts. An argument then only grows, and none drops out
  /// once it shows. Text after the object, such as an end marker still streaming in, is ignored.
  private static func partialJSONObject(_ text: String) -> [String: Any]? {
    enum Expectation {
      case value
      case key
      case colon
      case separator
    }
    let scalars = text.unicodeScalars
    let whitespace = " \t\n\r".unicodeScalars
    var expectation = Expectation.value
    // The closing bracket of each open object and array, innermost last.
    var closers = ""
    // Where the body last could close, and the brackets open there.
    var closable = (end: scalars.startIndex, closers: closers)
    var index = scalars.startIndex
    scan: while index < scalars.endIndex {
      let scalar = scalars[index]
      let next = scalars.index(after: index)
      guard !whitespace.contains(scalar) else {
        index = next
        continue
      }
      switch (expectation, scalar) {
      case (.value, "{"), (.value, "["):
        closers.append(scalar == "{" ? "}" : "]")
        expectation = scalar == "{" ? .key : .value
        index = next
        closable = (index, closers)
      case (.separator, "}"), (.separator, "]"), (.key, "}"), (.value, "]"):
        guard closers.last == Character(scalar) else { break scan }
        closers.removeLast()
        index = next
        guard !closers.isEmpty else { return jsonObject(String(scalars[..<index])) }
        expectation = .separator
        closable = (index, closers)
      case (.separator, ","):
        expectation = closers.last == "}" ? .key : .value
        index = next
      case (.colon, ":"):
        expectation = .value
        index = next
      case (.value, "\""), (.key, "\""):
        // The end of the string's last whole character or escape sequence.
        var contentEnd = next
        var isClosed = false
        var cursor = next
        while cursor < scalars.endIndex, !isClosed {
          if scalars[cursor] == "\"" {
            isClosed = true
            continue
          }
          var end = scalars.index(after: cursor)
          if scalars[cursor] == "\\" {
            // An escape sequence cut short cannot be read, and neither can a high surrogate
            // before its low surrogate arrives.
            guard end < scalars.endIndex else { break }
            if scalars[end] == "u" {
              guard let codeEnd = scalars.index(end, offsetBy: 5, limitedBy: scalars.endIndex)
              else { break }
              let code = UInt32(String(scalars[scalars.index(after: end)..<codeEnd]), radix: 16)
              if let code, (0xD800...0xDBFF).contains(code),
                scalars.index(codeEnd, offsetBy: 6, limitedBy: scalars.endIndex) == nil,
                "\\u".unicodeScalars.starts(with: scalars[codeEnd...].prefix(2))
              {
                break
              }
              end = codeEnd
            } else {
              end = scalars.index(after: end)
            }
          }
          cursor = end
          contentEnd = end
        }
        guard isClosed else {
          // A string argument closes where it stops, once it has content. The name, directly in
          // the body, counts only when whole.
          guard expectation == .value, closers.count > 1, contentEnd > next else { break scan }
          return jsonObject(String(scalars[..<contentEnd]) + "\"" + String(closers.reversed()))
        }
        index = scalars.index(after: cursor)
        if expectation == .key {
          expectation = .colon
        } else {
          expectation = .separator
          closable = (index, closers)
        }
      case (.value, _):
        // A number, true, false or null.
        var end = index
        while end < scalars.endIndex, !",}]".unicodeScalars.contains(scalars[end]),
          !whitespace.contains(scalars[end])
        {
          end = scalars.index(after: end)
        }
        if end == scalars.endIndex, !["true", "false", "null"].contains(String(scalars[index...])) {
          // A number cut off reads up to its last digit. Other text is not a value yet.
          while end > index, !("0"..."9").contains(scalars[scalars.index(before: end)]) {
            end = scalars.index(before: end)
          }
          guard end > index else { break scan }
        }
        index = end
        expectation = .separator
        closable = (index, closers)
      default:
        break scan
      }
    }
    return jsonObject(String(scalars[..<closable.end]) + String(closable.closers.reversed()))
  }

  /// JSON text as Python's `json.dumps(value, sort_keys=True, separators=(",", ":"),
  /// ensure_ascii=False)` writes it, which the chat template's `tojson` calls.
  static func json(_ value: Any) -> String {
    switch value {
    case let string as String:
      return jsonString(string)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? "true" : "false"
      }
      if CFNumberIsFloatType(number) {
        let double = number.doubleValue
        guard !double.isNaN else { return "NaN" }
        guard double.isFinite else { return double > 0 ? "Infinity" : "-Infinity" }
        return "\(double)"
      }
      return number.stringValue
    case let array as [Any]:
      return "[" + array.map(json).joined(separator: ",") + "]"
    case let object as [String: Any]:
      return "{"
        + object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        .map { jsonString($0) + ":" + json(object[$0]!) }.joined(separator: ",") + "}"
    case is NSNull:
      return "null"
    default:
      return "null"
    }
  }

  private static func jsonString(_ string: String) -> String {
    var result = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      case "\u{08}": result += "\\b"
      case "\u{0C}": result += "\\f"
      default:
        if scalar.value < 0x20 {
          result += String(format: "\\u%04x", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result + "\""
  }
}
