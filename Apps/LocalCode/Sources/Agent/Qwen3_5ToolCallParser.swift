import Foundation

public struct Qwen3_5ToolCallParser {
  public struct Result: Sendable {
    public var toolCalls: [ToolCall]
    public var incompleteToolCall: ToolCall?
    public var hasIncompleteToolCall: Bool
  }

  public static let toolCallStart = "<tool_call>"
  public static let toolCallEnd = "</tool_call>"
  public static let toolCallSpecialTokens: [Int32: String] = [
    248_058: toolCallStart,
    248_059: toolCallEnd,
  ]

  private var buffer = ""
  private var nextToolCallId: Int32 = 0

  public private(set) var toolCalls: [ToolCall] = []
  public private(set) var incompleteToolCall: ToolCall?
  public private(set) var hasIncompleteToolCall = false

  @discardableResult
  public mutating func append(_ data: String) -> Result {
    guard !data.isEmpty else {
      return Result(
        toolCalls: [], incompleteToolCall: incompleteToolCall,
        hasIncompleteToolCall: hasIncompleteToolCall)
    }
    buffer += data

    var emitted = [ToolCall]()
    while true {
      guard let parsed = nextCompleteToolCallBlock() else {
        trimLeadingTextBeforePotentialToolCall()
        hasIncompleteToolCall = buffer.hasPrefix(Self.toolCallStart)
        if hasIncompleteToolCall {
          var parser = Parser(buffer)
          incompleteToolCall = parser.parseIncompleteToolCall(nextToolCallId: nextToolCallId)
        } else {
          incompleteToolCall = nil
        }
        return Result(
          toolCalls: emitted, incompleteToolCall: incompleteToolCall,
          hasIncompleteToolCall: hasIncompleteToolCall)
      }
      toolCalls.append(contentsOf: parsed)
      emitted.append(contentsOf: parsed)
    }
  }

  /// Removes each block up to where `append(_:)` ends it, so an end tag inside a parameter value
  /// does not leak the rest of the block.
  public static func removeToolCalls(_ string: String) -> String {
    var output = ""
    var nextToolCallId: Int32 = 0
    var index = string.startIndex
    while let startRange = string[index...].range(of: toolCallStart) {
      output += String(string[index..<startRange.lowerBound])
      guard
        let block = toolCallBlock(
          string[startRange.lowerBound...], nextToolCallId: &nextToolCallId)
      else {
        index = string.endIndex
        break
      }
      index = block.endIndex
    }
    output += String(string[index...])
    ToolCallParser.removeTrailingPartialDelimiter(
      &output, toolCallStart: toolCallStart, toolCallEnd: toolCallEnd)
    return output
  }

  public mutating func reset() {
    buffer = ""
    nextToolCallId = 0
    toolCalls.removeAll(keepingCapacity: true)
    incompleteToolCall = nil
    hasIncompleteToolCall = false
  }

  private mutating func nextCompleteToolCallBlock() -> [ToolCall]? {
    guard let startRange = buffer.range(of: Self.toolCallStart) else {
      return nil
    }
    if startRange.lowerBound > buffer.startIndex {
      buffer.removeSubrange(buffer.startIndex..<startRange.lowerBound)
    }
    guard let block = Self.toolCallBlock(buffer[...], nextToolCallId: &nextToolCallId) else {
      return nil
    }
    buffer.removeSubrange(buffer.startIndex..<block.endIndex)
    return block.toolCalls
  }

  // An end tag between a function's start and end tags belongs to a parameter value, so the block
  // ends at the first end tag outside its functions. A block that does not parse to there ends at
  // its first end tag, as before. Returns nil while the block is incomplete.
  private static func toolCallBlock(
    _ text: Substring, nextToolCallId: inout Int32
  ) -> (endIndex: String.Index, toolCalls: [ToolCall])? {
    var index = text.index(text.startIndex, offsetBy: toolCallStart.count)
    var blockEnd: String.Index?
    while let endRange = text[index...].range(of: toolCallEnd) {
      guard
        let functionRange = text[index..<endRange.lowerBound].range(of: Parser.functionStart)
      else {
        blockEnd = endRange.upperBound
        break
      }
      guard
        let functionEndRange = text[functionRange.upperBound...].range(of: Parser.functionEnd)
      else {
        // Without a function end tag, the end tag can only be part of a value still streaming in
        // an open parameter. Once the parameters close, more text cannot make the block parse.
        let arguments = text[functionRange.upperBound..<endRange.lowerBound]
        if let parameterRange = arguments.range(of: Parser.parameterStart, options: .backwards),
          arguments[parameterRange.upperBound...].range(of: Parser.parameterEnd) == nil
        {
          return nil
        }
        blockEnd = endRange.upperBound
        break
      }
      index = functionEndRange.upperBound
    }
    guard let blockEnd else { return nil }
    var parser = Parser(String(text[..<blockEnd]))
    if let parsed = try? parser.parseToolCallBlock(nextToolCallId: &nextToolCallId) {
      return (blockEnd, parsed)
    }
    return (text.range(of: toolCallEnd)?.upperBound ?? blockEnd, [])
  }

  private mutating func trimLeadingTextBeforePotentialToolCall() {
    guard !buffer.isEmpty else { return }
    if let startRange = buffer.range(of: Self.toolCallStart) {
      if startRange.lowerBound > buffer.startIndex {
        buffer.removeSubrange(buffer.startIndex..<startRange.lowerBound)
      }
      return
    }

    let marker = Self.toolCallStart
    let maxPrefixLength = min(buffer.count, marker.count - 1)
    guard maxPrefixLength > 0 else {
      buffer = ""
      return
    }
    for length in stride(from: maxPrefixLength, through: 1, by: -1) {
      let prefix = String(marker.prefix(length))
      if buffer.hasSuffix(prefix) {
        buffer = prefix
        return
      }
    }
    buffer = ""
  }
}

extension Qwen3_5ToolCallParser {
  fileprivate enum ParseError: Error {
    case missingToolCallStart
    case missingToolCallEnd
    case missingFunctionStart
    case missingFunctionEnd
    case missingParameterStart
    case missingParameterEnd
    case missingFunctionNameTerminator
    case missingParameterNameTerminator
    case emptyFunctionName
    case emptyParameterName
    case invalidFunctionName(String)
    case invalidParameterName(String)
    case missingFunction
    case unexpectedTrailingContent
  }

  fileprivate struct Parser {
    private static let toolCallStart = "<tool_call>"
    private static let toolCallEnd = "</tool_call>"
    static let functionStart = "<function="
    static let functionEnd = "</function>"
    static let parameterStart = "<parameter="
    static let parameterEnd = "</parameter>"

    private let text: String
    private var index: String.Index

    init(_ text: String) {
      self.text = text
      self.index = text.startIndex
    }

    mutating func parseToolCallBlock(nextToolCallId: inout Int32) throws -> [ToolCall] {
      try consume(Self.toolCallStart, error: .missingToolCallStart)
      consumeWhitespace()

      var calls = [ToolCall]()
      while !isAtEnd, !peek(Self.toolCallEnd) {
        let call = try parseFunction(nextToolCallId: &nextToolCallId)
        calls.append(call)
        consumeWhitespace()
      }
      guard !calls.isEmpty else {
        throw ParseError.missingFunction
      }
      try consume(Self.toolCallEnd, error: .missingToolCallEnd)
      consumeWhitespace()
      guard isAtEnd else {
        throw ParseError.unexpectedTrailingContent
      }
      return calls
    }

    mutating func parseIncompleteToolCall(nextToolCallId: Int32) -> ToolCall? {
      guard peek(Self.toolCallStart) else { return nil }
      index = text.index(index, offsetBy: Self.toolCallStart.count)
      consumeWhitespace()

      let rawStart = index
      guard peek(Self.functionStart) else { return nil }
      index = text.index(index, offsetBy: Self.functionStart.count)
      guard
        let function = try? parseName(
          terminatedBy: ">",
          missingTerminatorError: .missingFunctionNameTerminator,
          emptyNameError: .emptyFunctionName,
          invalidNameError: ParseError.invalidFunctionName)
      else {
        return nil
      }
      consumeWhitespace()

      var parameters = [String: ToolCall.Request.Parameter]()
      while !isAtEnd, !peek(Self.functionEnd) {
        guard peek(Self.parameterStart) else { break }
        index = text.index(index, offsetBy: Self.parameterStart.count)
        guard
          let name = try? parseName(
            terminatedBy: ">",
            missingTerminatorError: .missingParameterNameTerminator,
            emptyNameError: .emptyParameterName,
            invalidNameError: ParseError.invalidParameterName)
        else {
          break
        }
        guard let endRange = text[index...].range(of: Self.parameterEnd) else {
          // Read the open value as if it closed here, so a streaming closing tag never shows in it.
          // Leave out a value that has not started, as for a name still streaming: an empty number
          // or boolean fails validation, and the chat would drop the call's line until it starts.
          var value = String(text[index...])
          let maximumTrailingMatchLength = min(value.count, Self.parameterEnd.count - 1)
          if maximumTrailingMatchLength > 0 {
            for length in stride(from: maximumTrailingMatchLength, through: 1, by: -1) {
              if value.hasSuffix(Self.parameterEnd.prefix(length)) {
                value.removeLast(length)
                break
              }
            }
          }
          value = Self.unframedParameterValue(value[...], hasClosingTag: true)
          if !value.isEmpty {
            parameters[name] = ToolCall.Request.Parameter(string: true, value: value)
          }
          break
        }
        parameters[name] = ToolCall.Request.Parameter(
          string: true,
          value: Self.unframedParameterValue(
            text[index..<endRange.lowerBound], hasClosingTag: true))
        index = endRange.upperBound
        consumeWhitespace()
      }

      return ToolCall(
        id: nextToolCallId, raw: String(text[rawStart...]),
        request: ToolCall.Request(function: function, parameters: parameters))
    }

    private mutating func parseFunction(nextToolCallId: inout Int32) throws -> ToolCall {
      let rawStart = index
      try consume(Self.functionStart, error: .missingFunctionStart)
      let function = try parseName(
        terminatedBy: ">",
        missingTerminatorError: .missingFunctionNameTerminator,
        emptyNameError: .emptyFunctionName,
        invalidNameError: ParseError.invalidFunctionName)
      consumeWhitespace()

      var parameters = [String: ToolCall.Request.Parameter]()
      while !isAtEnd, !peek(Self.functionEnd) {
        let (name, parameter) = try parseParameter()
        parameters[name] = parameter
        consumeWhitespace()
      }
      try consume(Self.functionEnd, error: .missingFunctionEnd)
      let raw = String(text[rawStart..<index])
      let id = nextToolCallId
      nextToolCallId += 1
      return ToolCall(
        id: id, raw: raw,
        request: ToolCall.Request(function: function, parameters: parameters))
    }

    private mutating func parseParameter() throws -> (String, ToolCall.Request.Parameter) {
      try consume(Self.parameterStart, error: .missingParameterStart)
      let name = try parseName(
        terminatedBy: ">",
        missingTerminatorError: .missingParameterNameTerminator,
        emptyNameError: .emptyParameterName,
        invalidNameError: ParseError.invalidParameterName)
      guard let endRange = text[index...].range(of: Self.parameterEnd) else {
        throw ParseError.missingParameterEnd
      }
      let value = Self.unframedParameterValue(
        text[index..<endRange.lowerBound], hasClosingTag: true)
      index = endRange.upperBound
      return (name, ToolCall.Request.Parameter(string: true, value: value))
    }

    private mutating func parseName(
      terminatedBy terminator: String, missingTerminatorError: ParseError,
      emptyNameError: ParseError, invalidNameError: (String) -> ParseError
    ) throws -> String {
      guard let range = text[index...].range(of: terminator) else {
        throw missingTerminatorError
      }
      let rawName = String(text[index..<range.lowerBound])
      index = range.upperBound
      let name = Self.normalizedName(rawName)
      guard !name.isEmpty else {
        throw emptyNameError
      }
      guard !name.contains("<") && !name.contains(">") else {
        throw invalidNameError(name)
      }
      return name
    }

    private static func normalizedName(_ value: String) -> String {
      var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if name.count >= 2,
        let first = name.first, let last = name.last,
        (first == "\"" && last == "\"") || (first == "'" && last == "'")
      {
        name.removeFirst()
        name.removeLast()
      }
      return name
    }

    private static func unframedParameterValue(
      _ rawValue: Substring, hasClosingTag: Bool
    ) -> String {
      var value = String(rawValue)
      if value.hasPrefix("\r\n") {
        value.removeSubrange(
          value.startIndex..<value.index(value.startIndex, offsetBy: "\r\n".count))
      } else if value.hasPrefix("\n") {
        value.removeFirst()
      }
      guard hasClosingTag else { return value }
      if value.hasSuffix("\r\n") {
        let boundaryStart = value.index(value.endIndex, offsetBy: -"\r\n".count)
        value.removeSubrange(boundaryStart..<value.endIndex)
      } else if value.hasSuffix("\n") {
        value.removeLast()
      }
      return value
    }

    private mutating func consume(_ literal: String, error: ParseError) throws {
      guard peek(literal) else {
        throw error
      }
      index = text.index(index, offsetBy: literal.count)
    }

    private func peek(_ literal: String) -> Bool {
      text[index...].hasPrefix(literal)
    }

    private mutating func consumeWhitespace() {
      while !isAtEnd, text[index].isWhitespace {
        index = text.index(after: index)
      }
    }

    private var isAtEnd: Bool {
      index >= text.endIndex
    }
  }
}
