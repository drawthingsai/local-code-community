import Foundation

/// Parses GLM-5.3 tool calls, `<tool_call>name<arg_key>key</arg_key><arg_value>value</arg_value>
/// ...</tool_call>`, as vLLM's glm47 parser does: whitespace between tags is ignored, the name and
/// keys are trimmed, and values are kept exactly as written. Every value is reported as a string,
/// as the chat template writes strings raw and other types as JSON text.
public struct GLM5_3ToolCallParser {
  public static let toolCallStart = "<tool_call>"
  public static let toolCallEnd = "</tool_call>"
  static let argumentKeyStart = "<arg_key>"
  static let argumentKeyEnd = "</arg_key>"
  static let argumentValueStart = "<arg_value>"
  static let argumentValueEnd = "</arg_value>"
  public static let toolCallSpecialTokens: [Int32: String] = [
    154_843: toolCallStart,
    154_844: toolCallEnd,
    154_847: argumentKeyStart,
    154_848: argumentKeyEnd,
    154_849: argumentValueStart,
    154_850: argumentValueEnd,
  ]

  private var buffer = ""
  private var nextToolCallId: Int32 = 0

  public private(set) var toolCalls: [ToolCall] = []
  public private(set) var incompleteToolCall: ToolCall?
  public private(set) var hasIncompleteToolCall = false

  public init() {}

  public mutating func append(_ data: String) {
    guard !data.isEmpty else { return }
    buffer += data
    while let startRange = buffer.range(of: Self.toolCallStart) {
      if startRange.lowerBound > buffer.startIndex {
        buffer.removeSubrange(buffer.startIndex..<startRange.lowerBound)
      }
      guard let block = Self.toolCallBlock(buffer[...]) else { break }
      if let request = block.request {
        toolCalls.append(ToolCall(id: nextToolCallId, raw: block.raw, request: request))
        nextToolCallId += 1
      }
      buffer.removeSubrange(buffer.startIndex..<block.endIndex)
    }
    if !buffer.hasPrefix(Self.toolCallStart) {
      // Keep only a suffix that could still become the start of a call.
      var kept = ""
      for length in stride(
        from: min(buffer.count, Self.toolCallStart.count - 1), through: 1, by: -1)
      where buffer.hasSuffix(Self.toolCallStart.prefix(length)) {
        kept = String(buffer.suffix(length))
        break
      }
      buffer = kept
    }
    hasIncompleteToolCall = buffer.hasPrefix(Self.toolCallStart)
    incompleteToolCall =
      hasIncompleteToolCall ? Self.incompleteToolCall(buffer[...], id: nextToolCallId) : nil
  }

  /// Removes each complete call and any call still being written.
  public static func removeToolCalls(_ string: String) -> String {
    var output = ""
    var index = string.startIndex
    while let startRange = string[index...].range(of: toolCallStart) {
      output += string[index..<startRange.lowerBound]
      guard let block = toolCallBlock(string[startRange.lowerBound...]) else {
        index = string.endIndex
        break
      }
      index = block.endIndex
    }
    output += string[index...]
    ToolCallParser.removeTrailingPartialDelimiter(
      &output, toolCallStart: toolCallStart, toolCallEnd: toolCallEnd)
    return output
  }

  /// The call starting at `text`, which begins with the start tag, or nil while it is incomplete.
  /// A malformed call ends at its first end tag and has no request.
  private static func toolCallBlock(_ text: Substring) -> (
    endIndex: String.Index, raw: String, request: ToolCall.Request?
  )? {
    guard let end = text.range(of: toolCallEnd) else { return nil }
    let raw = String(text[..<end.upperBound])
    let body = text[text.index(text.startIndex, offsetBy: toolCallStart.count)..<end.lowerBound]
    var scanner = Scanner(body)
    let nameEnd = scanner.firstOf([argumentKeyStart]) ?? body.endIndex
    let name = body[..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    scanner.index = nameEnd
    guard !name.isEmpty, !name.contains("<"), !name.contains(">") else {
      return (end.upperBound, raw, nil)
    }
    var parameters = [String: ToolCall.Request.Parameter]()
    while true {
      scanner.skipWhitespace()
      if scanner.isAtEnd {
        return (end.upperBound, raw, ToolCall.Request(function: name, parameters: parameters))
      }
      guard scanner.consume(argumentKeyStart), let keyEnd = scanner.find(argumentKeyEnd) else {
        return (end.upperBound, raw, nil)
      }
      let key = body[scanner.index..<keyEnd.lowerBound].trimmingCharacters(
        in: .whitespacesAndNewlines)
      scanner.index = keyEnd.upperBound
      scanner.skipWhitespace()
      guard !key.isEmpty, scanner.consume(argumentValueStart),
        let valueEnd = scanner.find(argumentValueEnd)
      else { return (end.upperBound, raw, nil) }
      parameters[key] = ToolCall.Request.Parameter(
        string: true, value: String(body[scanner.index..<valueEnd.lowerBound]))
      scanner.index = valueEnd.upperBound
    }
  }

  /// What a call still being written has so far, once its name is complete.
  private static func incompleteToolCall(_ text: Substring, id: Int32) -> ToolCall? {
    var scanner = Scanner(text)
    scanner.index = text.index(text.startIndex, offsetBy: toolCallStart.count)
    let nameStart = scanner.index
    guard let nameEnd = scanner.firstOf([argumentKeyStart]) else { return nil }
    let name = text[nameStart..<nameEnd].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.contains("<"), !name.contains(">") else { return nil }
    scanner.index = nameEnd
    var parameters = [String: ToolCall.Request.Parameter]()
    while true {
      scanner.skipWhitespace()
      guard scanner.consume(argumentKeyStart),
        let keyEnd = scanner.find(argumentKeyEnd)
      else { break }
      let key = text[scanner.index..<keyEnd.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      scanner.index = keyEnd.upperBound
      scanner.skipWhitespace()
      guard !key.isEmpty, scanner.consume(argumentValueStart) else { break }
      guard let valueEnd = scanner.find(argumentValueEnd) else {
        // Read the open value as if it closed here, without a closing tag still streaming in. A
        // value that has not started is left out, so its line shows once it does.
        var value = String(text[scanner.index...])
        for length in stride(
          from: min(value.count, argumentValueEnd.count - 1), through: 1, by: -1)
        where value.hasSuffix(argumentValueEnd.prefix(length)) {
          value.removeLast(length)
          break
        }
        if !value.isEmpty {
          parameters[key] = ToolCall.Request.Parameter(string: true, value: value)
        }
        break
      }
      parameters[key] = ToolCall.Request.Parameter(
        string: true, value: String(text[scanner.index..<valueEnd.lowerBound]))
      scanner.index = valueEnd.upperBound
    }
    return ToolCall(
      id: id, raw: String(text),
      request: ToolCall.Request(function: name, parameters: parameters))
  }

  private struct Scanner {
    let text: Substring
    var index: String.Index

    init(_ text: Substring) {
      self.text = text
      index = text.startIndex
    }

    var isAtEnd: Bool { index >= text.endIndex }

    mutating func skipWhitespace() {
      while index < text.endIndex, text[index].isWhitespace {
        index = text.index(after: index)
      }
    }

    mutating func consume(_ literal: String) -> Bool {
      guard text[index...].hasPrefix(literal) else { return false }
      index = text.index(index, offsetBy: literal.count)
      return true
    }

    func find(_ literal: String) -> Range<String.Index>? {
      text[index...].range(of: literal)
    }

    /// Where the earliest of `literals` starts.
    func firstOf(_ literals: [String]) -> String.Index? {
      literals.compactMap { text[index...].range(of: $0)?.lowerBound }.min()
    }
  }
}
