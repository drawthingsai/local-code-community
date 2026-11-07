import Foundation

extension GLM5_3CodeAgent {
  static func parse(_ tokens: [Int32]) -> [AgentTranscriptEntry] {
    var transcript = [AgentTranscriptEntry]()
    // <|endoftext|> is not a role: a generated one ends an assistant turn, as DeepSeek's end of
    // sentence does.
    let roles: Set<Int32> = [154_826, 154_827, 154_828, 154_829]
    var cursor = 0
    while cursor < tokens.count {
      // A per-turn history node may start with user text: the preceding node already
      // retained the generated <|user|> stop token. Full conversation logs include it.
      let implicitUser = cursor == 0 && !roles.contains(tokens[cursor])
      let role: Int32 = implicitUser ? 154_827 : tokens[cursor]
      guard roles.contains(role) else {
        cursor += 1
        continue
      }
      let start = implicitUser ? cursor : cursor + 1
      let end = tokens[start...].firstIndex(where: { roles.contains($0) }) ?? tokens.endIndex
      let body = Array(tokens[start..<end])
      cursor = end
      switch role {
      case 154_827:
        // A final <|user|> is the model's stop token, not an empty user message.
        guard !body.isEmpty else { continue }
        var text = decoded(body)
        if text.hasPrefix("<system-reminder>\n"), let end = text.range(of: "</system-reminder>\n") {
          text = String(text[end.upperBound...])
        }
        transcript.append(.user(text))
      case 154_828:
        var outputTokens = Array(body.prefix { $0 != 154_820 })
        var thinking = ""
        if outputTokens.first == 154_841 {
          outputTokens.removeFirst()
          let thinkEnd = outputTokens.firstIndex(of: 154_842)
          let toolStart = outputTokens.firstIndex(of: 154_843)
          if let boundary = [thinkEnd, toolStart].compactMap({ $0 }).min() {
            thinking = decoded(Array(outputTokens[..<boundary]))
            outputTokens = outputTokens[boundary...].filter { $0 != 154_842 }
          } else {
            thinking = decoded(outputTokens)
            outputTokens = []
          }
        }
        let output = decoded(outputTokens)
        var parser = GLM5_3ToolCallParser()
        parser.append(output)
        let calls = parser.toolCalls.map { call in
          AgentTranscriptToolCall(
            function: call.request.function,
            parameters: call.request.parameters.mapValues {
              AgentTranscriptToolCall.Parameter(string: $0.string, value: $0.value)
            })
        }
        transcript.append(
          .assistant(
            text: GLM5_3ToolCallParser.removeToolCalls(output).trimmingCharacters(
              in: .whitespacesAndNewlines),
            thinking: thinking, toolCalls: calls))
      case 154_829:
        var results = [AgentTranscriptToolResult]()
        var resultStart: Int?
        for index in body.indices {
          if body[index] == 154_845 {
            resultStart = index + 1
          } else if body[index] == 154_846, let start = resultStart {
            let content = decoded(Array(body[start..<index]))
            let object = content.data(using: .utf8).flatMap {
              (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            results.append(
              AgentTranscriptToolResult(content: content, isError: object?["error"] != nil))
            resultStart = nil
          }
        }
        if !results.isEmpty { transcript.append(.toolResults(results)) }
      default:
        break
      }
    }
    return transcript
  }

  /// Canonical template rendering for imported history. Active generations retain their raw
  /// tokens so that normal continuation never rewrites the recurrent attention prefix.
  static func parse(_ transcript: [AgentTranscriptEntry]) -> [Int32] {
    var tokens = [Int32]()
    var previousWasToolResults = false
    for entry in transcript {
      switch entry {
      case .user(let text):
        tokens.append(154_827)
        tokens += safeTokens(text)
        previousWasToolResults = false
      case .assistant(let text, let thinking, let calls):
        tokens += [154_828, 154_841]
        tokens += safeTokens(thinking)
        tokens.append(154_842)
        tokens += safeTokens(text.trimmingCharacters(in: .whitespacesAndNewlines))
        for call in calls {
          tokens.append(154_843)
          tokens += safeTokens(call.function)
          for (key, parameter) in call.parameters.sorted(by: { $0.key < $1.key }) {
            tokens.append(154_847)
            tokens += safeTokens(key)
            tokens += [154_848, 154_849]
            tokens += safeTokens(parameter.value)
            tokens.append(154_850)
          }
          tokens.append(154_844)
        }
        previousWasToolResults = false
      case .toolResults(let results):
        if !previousWasToolResults { tokens.append(154_829) }
        for result in results {
          tokens.append(154_845)
          tokens += safeTokens(result.content)
          tokens.append(154_846)
        }
        previousWasToolResults = true
      }
    }
    return tokens
  }

  // A transcript cannot carry images, so their tokens stay out of its text; labels remain.
  private static func decoded(_ tokens: [Int32]) -> String {
    let imageTokens: Set<Int32> = [154_830, 154_831, 154_854]
    return GLM5_3TextGenerator.unsafeTokenizer.decode(tokens.filter { !imageTokens.contains($0) })
  }

  private static func safeTokens(_ text: String) -> [Int32] {
    GLM5_3TextGenerator.safeTokenizer.tokenize(text: text, addSpecialTokens: false).0
  }
}
