import Foundation

extension Qwen3_5CodeAgent {
  private static let imStartToken: Int32 = 248_045
  private static let imEndToken: Int32 = 248_046
  private static let toolCallStartToken: Int32 = 248_058
  private static let toolCallEndToken: Int32 = 248_059
  private static let toolResponseStartToken: Int32 = 248_066
  private static let toolResponseEndToken: Int32 = 248_067
  private static let thinkStartToken: Int32 = 248_068
  private static let thinkEndToken: Int32 = 248_069
  private static let transcriptSpecialTokens: [Int32: String] = [
    imStartToken: "<|im_start|>",
    imEndToken: "<|im_end|>",
    toolCallStartToken: "<tool_call>",
    toolCallEndToken: "</tool_call>",
    toolResponseStartToken: "<tool_response>",
    toolResponseEndToken: "</tool_response>",
    thinkStartToken: "<think>",
    thinkEndToken: "</think>",
  ]

  static func parse(_ tokens: [Int32]) -> [AgentTranscriptEntry] {
    var transcript = [AgentTranscriptEntry]()
    for messageSegment in messageSegments(in: tokens) {
      guard messageSegment.first == imStartToken else { continue }
      let messageStart = messageSegment.index(after: messageSegment.startIndex)
      let messageEnd =
        messageSegment[messageStart...].firstIndex(of: imEndToken)
        ?? messageSegment.endIndex
      let messageTokens = Array(messageSegment[messageStart..<messageEnd])
      var role: String?
      var segmentTokens = [Int32]()
      for candidate in ["system", "user", "assistant"] {
        let prefix = unsafeTokens("\(candidate)\n")
        if messageTokens.starts(with: prefix) {
          role = candidate
          segmentTokens = Array(messageTokens.dropFirst(prefix.count))
          break
        }
      }
      guard let role else { continue }
      switch role {
      case "user":
        let expectsToolResults: Bool
        if case .assistant(_, _, let toolCalls)? = transcript.last {
          expectsToolResults = !toolCalls.isEmpty
        } else {
          expectsToolResults = false
        }
        let resultBlocks = tokenBlocks(
          in: segmentTokens, startToken: toolResponseStartToken,
          endToken: toolResponseEndToken)
        if expectsToolResults, !resultBlocks.isEmpty {
          transcript.append(
            .toolResults(
              resultBlocks.map {
                let content = decoded($0).trimmingCharacters(in: .whitespacesAndNewlines)
                return AgentTranscriptToolResult(
                  content: content, isError: isErrorContent(content))
              }))
        }
        let text = decoded(
          expectsToolResults
            ? removingTokenBlocks(
              from: segmentTokens, startToken: toolResponseStartToken,
              endToken: toolResponseEndToken)
            : segmentTokens
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || !expectsToolResults || resultBlocks.isEmpty {
          transcript.append(.user(text))
        }
      case "assistant":
        let thinking =
          tokenBlocks(
            in: segmentTokens, startToken: thinkStartToken, endToken: thinkEndToken
          ).first.map(decoded)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let withoutThinking = removingTokenBlocks(
          from: segmentTokens, startToken: thinkStartToken, endToken: thinkEndToken)
        let text = decoded(
          removingTokenBlocks(
            from: withoutThinking, startToken: toolCallStartToken,
            endToken: toolCallEndToken)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let toolCalls = tokenBlocks(
          in: withoutThinking, startToken: toolCallStartToken,
          endToken: toolCallEndToken
        ).flatMap { block -> [AgentTranscriptToolCall] in
          var parser = Qwen3_5ToolCallParser()
          return parser.append("<tool_call>\n\(decoded(block))\n</tool_call>").toolCalls.map {
            toolCall in
            AgentTranscriptToolCall(
              function: toolCall.request.function,
              parameters: toolCall.request.parameters.mapValues {
                AgentTranscriptToolCall.Parameter(string: $0.string, value: $0.value)
              })
          }
        }
        transcript.append(
          .assistant(text: text, thinking: thinking, toolCalls: toolCalls))
      default:
        continue
      }
    }
    return transcript
  }

  static func parse(_ transcript: [AgentTranscriptEntry]) -> [Int32] {
    var tokens = [Int32]()
    for entry in transcript {
      switch entry {
      case .user(let text):
        tokens += unsafeTokens("<|im_start|>user\n")
        tokens += safeTokens(text)
        tokens += unsafeTokens("<|im_end|>\n")
      case .assistant(let text, let thinking, let toolCalls):
        tokens += unsafeTokens("<|im_start|>assistant\n<think>\n")
        tokens += safeTokens(thinking)
        tokens += unsafeTokens("\n</think>\n\n")
        tokens += safeTokens(text)
        if !toolCalls.isEmpty {
          tokens += unsafeTokens("\n<tool_call>\n")
          for toolCall in toolCalls {
            tokens += unsafeTokens("<function=")
            tokens += safeTokens(toolCall.function)
            tokens += unsafeTokens(">\n")
            for (name, parameter) in toolCall.parameters.sorted(by: { $0.key < $1.key }) {
              tokens += unsafeTokens("<parameter=")
              tokens += safeTokens(name)
              tokens += unsafeTokens(">")
              tokens += safeTokens(parameter.value)
              tokens += unsafeTokens("</parameter>\n")
            }
            tokens += unsafeTokens("</function>\n")
          }
          tokens += unsafeTokens("</tool_call>\n")
        }
        tokens += unsafeTokens("<|im_end|>\n")
      case .toolResults(let results):
        tokens += unsafeTokens("<|im_start|>user\n")
        for result in results {
          tokens += unsafeTokens("<tool_response>\n")
          tokens += safeTokens(result.content)
          tokens += unsafeTokens("\n</tool_response>\n")
        }
        tokens += unsafeTokens("<|im_end|>\n")
      }
    }
    return tokens
  }

  private static func tokenBlocks(
    in tokens: [Int32], startToken: Int32, endToken: Int32
  ) -> [[Int32]] {
    var blocks = [[Int32]]()
    var cursor = tokens.startIndex
    while cursor < tokens.endIndex {
      guard let start = tokens[cursor...].firstIndex(of: startToken) else { break }
      let bodyStart = tokens.index(after: start)
      guard let end = tokens[bodyStart...].firstIndex(of: endToken) else { break }
      blocks.append(Array(tokens[bodyStart..<end]))
      cursor = tokens.index(after: end)
    }
    return blocks
  }

  private static func removingTokenBlocks(
    from tokens: [Int32], startToken: Int32, endToken: Int32
  ) -> [Int32] {
    var result = [Int32]()
    var cursor = tokens.startIndex
    while cursor < tokens.endIndex {
      guard let start = tokens[cursor...].firstIndex(of: startToken) else {
        result += tokens[cursor...]
        break
      }
      let bodyStart = tokens.index(after: start)
      guard let end = tokens[bodyStart...].firstIndex(of: endToken) else {
        result += tokens[cursor..<start]
        break
      }
      result += tokens[cursor..<start]
      cursor = tokens.index(after: end)
    }
    return result
  }

  private static func isErrorContent(_ content: String) -> Bool {
    guard let data = content.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return object["error"] != nil
  }

  private static func decoded(_ tokens: [Int32]) -> String {
    Qwen3_5TextGenerator.unsafeTokenizer.decode(
      tokens, specialTokens: transcriptSpecialTokens)
  }

  private static func safeTokens(_ text: String) -> [Int32] {
    let (_, tokens, _, _, _) = Qwen3_5TextGenerator.safeTokenizer.tokenize(
      text: text, truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    return tokens
  }

  private static func unsafeTokens(_ text: String) -> [Int32] {
    let (_, tokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: text, truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    return tokens
  }
}
