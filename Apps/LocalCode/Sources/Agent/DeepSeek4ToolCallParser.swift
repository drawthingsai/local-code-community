import Foundation
import LLM

public struct DeepSeek4ToolCallParser {
  public struct Result: Sendable {
    public var toolCalls: [ToolCall]
    public var incompleteToolCall: ToolCall?
    public var hasIncompleteToolCall: Bool
    public var didCompleteToolCallBlock: Bool
  }

  public struct Format {
    public let toolCallStart: String
    public let toolCallEnd: String
    let invokeStart: String
    let invokeEnd: String
    let parameterStart: String
    let parameterEnd: String
    let escapedParameterEnd: String

    public init(version: LLMVersion) {
      switch version {
      case .deepseek_4_flash:
        toolCallStart = "<｜DSML｜tool_calls>"
        toolCallEnd = "</｜DSML｜tool_calls>"
        invokeStart = "<｜DSML｜invoke"
        invokeEnd = "</｜DSML｜invoke>"
        parameterStart = "<｜DSML｜parameter"
        parameterEnd = "</｜DSML｜parameter>"
      case .deepseek_4_1_flash:
        toolCallStart = "<｜DSML｜ calls>"
        toolCallEnd = "</｜DSML｜ calls>"
        invokeStart = "<｜DSML｜ invoke"
        invokeEnd = "</｜DSML｜ invoke>"
        parameterStart = "<｜DSML｜ parameter"
        parameterEnd = "</｜DSML｜ parameter>"
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
        fatalError("DeepSeek tool-call format requires a DeepSeek model version")
      }
      escapedParameterEnd = "&lt;" + parameterEnd.dropFirst()
    }
  }

  public static let toolCallSpecialTokens: [Int32: String] = [128_825: "｜DSML｜"]

  private let format: Format

  public init(format: Format) {
    self.format = format
  }

  private var buffer = ""

  public private(set) var toolCalls = [ToolCall]()
  public private(set) var incompleteToolCall: ToolCall?
  public private(set) var hasIncompleteToolCall = false
  public private(set) var didCompleteToolCallBlock = false

  @discardableResult
  public mutating func append(_ data: String) -> Result {
    guard !didCompleteToolCallBlock else { return result }
    guard !data.isEmpty else { return result }
    buffer += data

    guard let startRange = buffer.range(of: format.toolCallStart) else {
      trimLeadingTextBeforePotentialToolCall()
      toolCalls.removeAll(keepingCapacity: true)
      incompleteToolCall = nil
      hasIncompleteToolCall = false
      return result
    }
    if startRange.lowerBound > buffer.startIndex {
      buffer.removeSubrange(buffer.startIndex..<startRange.lowerBound)
    }

    guard let normalizedStartRange = buffer.range(of: format.toolCallStart) else { return result }
    var endSearchIndex = normalizedStartRange.upperBound
    while let endRange = buffer[endSearchIndex...].range(of: format.toolCallEnd) {
      let block = String(buffer[buffer.startIndex..<endRange.upperBound])
      var parser = Parser(
        block, format: format)
      var nextToolCallId: Int32 = 0
      if let parsed = try? parser.parseToolCallBlock(nextToolCallId: &nextToolCallId) {
        toolCalls = parsed
        incompleteToolCall = nil
        hasIncompleteToolCall = false
        didCompleteToolCallBlock = true
        return result
      }
      endSearchIndex = endRange.upperBound
    }

    hasIncompleteToolCall = true
    var parser = Parser(
      buffer, format: format)
    let partial = parser.parsePartialToolCallBlock()
    toolCalls = partial.toolCalls
    incompleteToolCall = partial.incompleteToolCall
    return result
  }

  public mutating func reset() {
    buffer = ""
    toolCalls.removeAll(keepingCapacity: true)
    incompleteToolCall = nil
    hasIncompleteToolCall = false
    didCompleteToolCallBlock = false
  }

  private mutating func trimLeadingTextBeforePotentialToolCall() {
    guard !buffer.isEmpty else { return }
    let maximumPrefixLength = min(buffer.count, format.toolCallStart.count - 1)
    guard maximumPrefixLength > 0 else {
      buffer = ""
      return
    }
    for length in stride(from: maximumPrefixLength, through: 1, by: -1) {
      let prefix = String(format.toolCallStart.prefix(length))
      if buffer.hasSuffix(prefix) {
        buffer = prefix
        return
      }
    }
    buffer = ""
  }

  private var result: Result {
    Result(
      toolCalls: toolCalls, incompleteToolCall: incompleteToolCall,
      hasIncompleteToolCall: hasIncompleteToolCall,
      didCompleteToolCallBlock: didCompleteToolCallBlock)
  }
}

extension ToolCallParser {
  public static func parse(
    _ string: String, format: DeepSeek4ToolCallParser.Format
  ) -> [ToolCall] {
    let toolCallStart = format.toolCallStart
    let toolCallEnd = format.toolCallEnd
    var toolCalls = [ToolCall]()
    var nextToolCallId: Int32 = 0
    var index = string.startIndex
    while let startRange = string[index...].range(of: toolCallStart) {
      var firstEndIndex: String.Index?
      var endSearchIndex = startRange.upperBound
      var didParseBlock = false
      while let endRange = string[endSearchIndex...].range(of: toolCallEnd) {
        firstEndIndex = firstEndIndex ?? endRange.upperBound
        let block = String(string[startRange.lowerBound..<endRange.upperBound])
        var parser = DeepSeek4ToolCallParser.Parser(
          block, format: format)
        var nextId = nextToolCallId
        if let parsed = try? parser.parseToolCallBlock(nextToolCallId: &nextId) {
          toolCalls.append(contentsOf: parsed)
          nextToolCallId = nextId
          index = endRange.upperBound
          didParseBlock = true
          break
        }
        endSearchIndex = endRange.upperBound
      }
      if didParseBlock { continue }
      guard let firstEndIndex else { break }
      index = firstEndIndex
    }
    return toolCalls
  }
}

extension DeepSeek4ToolCallParser {
  fileprivate enum ParseError: Error {
    case expected(String)
    case emptyName
    case duplicateParameter(String)
    case missingToolCall
    case trailingContent
  }

  fileprivate struct Parser {
    private let format: Format

    private let text: String
    private var index: String.Index

    init(_ text: String, format: Format) {
      self.format = format
      self.text = text
      index = text.startIndex
    }

    mutating func parseToolCallBlock(nextToolCallId: inout Int32) throws -> [ToolCall] {
      try consume(format.toolCallStart)
      consumeWhitespace()
      var toolCalls = [ToolCall]()
      while !isAtEnd, !peek(format.toolCallEnd) {
        toolCalls.append(try parseInvocation(nextToolCallId: &nextToolCallId))
        consumeWhitespace()
      }
      guard !toolCalls.isEmpty else { throw ParseError.missingToolCall }
      try consume(format.toolCallEnd)
      consumeWhitespace()
      guard isAtEnd else { throw ParseError.trailingContent }
      return toolCalls
    }

    mutating func parsePartialToolCallBlock() -> (
      toolCalls: [ToolCall], incompleteToolCall: ToolCall?
    ) {
      guard (try? consume(format.toolCallStart)) != nil else { return ([], nil) }
      consumeWhitespace()
      var toolCalls = [ToolCall]()
      var nextToolCallId: Int32 = 0
      while !isAtEnd, !peek(format.toolCallEnd) {
        var completeParser = self
        var nextId = nextToolCallId
        guard
          let toolCall = try? completeParser.parseInvocation(nextToolCallId: &nextId)
        else {
          return (
            toolCalls,
            parseIncompleteInvocation(nextToolCallId: nextToolCallId)
          )
        }
        self = completeParser
        nextToolCallId = nextId
        toolCalls.append(toolCall)
        consumeWhitespace()
      }
      return (toolCalls, nil)
    }

    private mutating func parseIncompleteInvocation(nextToolCallId: Int32) -> ToolCall? {
      let rawStart = index
      guard (try? consume(format.invokeStart)) != nil,
        let function = try? parseAttribute(named: "name"), !function.isEmpty,
        (try? consumeTagEnd()) != nil
      else { return nil }
      consumeWhitespace()

      var parameters = [String: ToolCall.Request.Parameter]()
      while !isAtEnd, !peek(format.invokeEnd), !peek(format.toolCallEnd) {
        guard (try? consume(format.parameterStart)) != nil,
          let name = try? parseAttribute(named: "name"), !name.isEmpty,
          let isString = try? parseBooleanAttribute(named: "string"),
          (try? consumeTagEnd()) != nil
        else { break }
        let valueStart = index
        guard let endRange = text[index...].range(of: format.parameterEnd) else {
          var value = String(text[valueStart...])
          let maximumTrailingMatchLength = min(value.count, format.parameterEnd.count - 1)
          if maximumTrailingMatchLength > 0 {
            for length in stride(from: maximumTrailingMatchLength, through: 1, by: -1) {
              if value.hasSuffix(format.parameterEnd.prefix(length)) {
                value.removeLast(length)
                break
              }
            }
          }
          // Leave out a value that has not started, as for a tag still streaming: an empty number
          // or boolean fails validation, and the chat would drop the call's line until it starts.
          if !value.isEmpty {
            parameters[name] = ToolCall.Request.Parameter(
              string: isString, value: value)
          }
          break
        }
        parameters[name] = ToolCall.Request.Parameter(
          string: isString,
          value: String(text[valueStart..<endRange.lowerBound])
            .replacingOccurrences(
              of: format.escapedParameterEnd, with: format.parameterEnd))
        index = endRange.upperBound
        consumeWhitespace()
      }
      return ToolCall(
        id: nextToolCallId, raw: String(text[rawStart...]),
        request: ToolCall.Request(function: function, parameters: parameters))
    }

    private mutating func parseInvocation(nextToolCallId: inout Int32) throws -> ToolCall {
      let rawStart = index
      try consume(format.invokeStart)
      let function = try parseAttribute(named: "name")
      guard !function.isEmpty else { throw ParseError.emptyName }
      try consumeTagEnd()
      consumeWhitespace()

      var parameters = [String: ToolCall.Request.Parameter]()
      while !isAtEnd, !peek(format.invokeEnd) {
        let (name, parameter) = try parseParameter()
        guard parameters[name] == nil else { throw ParseError.duplicateParameter(name) }
        parameters[name] = parameter
        consumeWhitespace()
      }
      try consume(format.invokeEnd)
      let raw = String(text[rawStart..<index])
      let id = nextToolCallId
      nextToolCallId += 1
      return ToolCall(
        id: id, raw: raw,
        request: ToolCall.Request(function: function, parameters: parameters))
    }

    private mutating func parseParameter() throws -> (String, ToolCall.Request.Parameter) {
      try consume(format.parameterStart)
      let name = try parseAttribute(named: "name")
      guard !name.isEmpty else { throw ParseError.emptyName }
      let isString = try parseBooleanAttribute(named: "string")
      try consumeTagEnd()
      guard let endRange = text[index...].range(of: format.parameterEnd) else {
        throw ParseError.expected(format.parameterEnd)
      }
      let value = String(text[index..<endRange.lowerBound])
        .replacingOccurrences(
          of: format.escapedParameterEnd, with: format.parameterEnd)
      index = endRange.upperBound
      return (
        name,
        ToolCall.Request.Parameter(string: isString, value: value)
      )
    }

    private mutating func parseBooleanAttribute(named name: String) throws -> Bool {
      switch try parseAttribute(named: name) {
      case "true":
        return true
      case "false":
        return false
      default:
        throw ParseError.expected("true or false")
      }
    }

    private mutating func parseAttribute(named name: String) throws -> String {
      consumeWhitespace()
      try consume("\(name)=\"")
      guard let endQuote = text[index...].firstIndex(of: "\"") else {
        throw ParseError.expected("\"")
      }
      let value = String(text[index..<endQuote])
      index = text.index(after: endQuote)
      return value
    }

    private mutating func consumeTagEnd() throws {
      consumeWhitespace()
      try consume(">")
    }

    private mutating func consume(_ literal: String) throws {
      guard peek(literal) else { throw ParseError.expected(literal) }
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
