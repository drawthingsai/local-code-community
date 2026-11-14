import Foundation

extension DeepSeek4CodeAgent {
  private static var transcriptEndOfSentenceToken: Int32 { 1 }
  private static var transcriptUserToken: Int32 { 128_803 }
  private static var transcriptAssistantToken: Int32 { 128_804 }
  private static var transcriptThinkStartToken: Int32 { 128_821 }
  private static var transcriptThinkEndToken: Int32 { 128_822 }
  private static var transcriptSpecialTokens: [Int32: String] { [128_825: "｜DSML｜"] }

  static func parse(_ tokens: [Int32]) -> [AgentTranscriptEntry] {
    var transcript = [AgentTranscriptEntry]()
    for messageSegment in messageSegments(in: tokens) {
      guard let userStart = messageSegment.firstIndex(of: transcriptUserToken) else { continue }
      let userBodyStart = messageSegment.index(after: userStart)
      guard
        let assistantStart = messageSegment[userBodyStart...].firstIndex(
          of: transcriptAssistantToken)
      else { continue }

      let userText = removingStringBlocks(
        from: decoded(Array(messageSegment[userBodyStart..<assistantStart])),
        start: "\n\n<system-reminder>", end: "</system-reminder>")
      let expectsToolResults: Bool
      if case .assistant(_, _, let toolCalls)? = transcript.last {
        expectsToolResults = !toolCalls.isEmpty
      } else {
        expectsToolResults = false
      }
      let resultBlocks = stringBlocks(
        in: userText, start: "<tool_result>", end: "</tool_result>")
      let textWithoutResults = removingStringBlocks(
        from: userText, start: "<tool_result>", end: "</tool_result>"
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      if expectsToolResults, !resultBlocks.isEmpty && textWithoutResults.isEmpty {
        transcript.append(
          .toolResults(
            resultBlocks.map {
              let content = $0.replacingOccurrences(
                of: "&lt;/tool_result>", with: "</tool_result>")
              return AgentTranscriptToolResult(
                content: content, isError: isErrorContent(content))
            }))
      } else {
        transcript.append(.user(userText))
      }

      let assistantBodyStart = messageSegment.index(after: assistantStart)
      let assistantEnd =
        messageSegment[assistantBodyStart...].firstIndex(of: transcriptEndOfSentenceToken)
        ?? messageSegment.endIndex
      var assistantTokens = Array(messageSegment[assistantBodyStart..<assistantEnd])
      var thinking = ""
      if assistantTokens.first == transcriptThinkStartToken {
        assistantTokens.removeFirst()
        if let thinkEnd = assistantTokens.firstIndex(of: transcriptThinkEndToken) {
          thinking = decoded(Array(assistantTokens[..<thinkEnd]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
          assistantTokens = Array(assistantTokens[assistantTokens.index(after: thinkEnd)...])
        } else {
          thinking = decoded(assistantTokens).trimmingCharacters(in: .whitespacesAndNewlines)
          assistantTokens.removeAll(keepingCapacity: false)
        }
      } else if assistantTokens.first == transcriptThinkEndToken {
        assistantTokens.removeFirst()
      }
      let output = decoded(assistantTokens)
      let format = toolCallFormat
      let toolCalls = ToolCallParser.parse(
        output, format: format
      ).map { toolCall in
        AgentTranscriptToolCall(
          function: toolCall.request.function,
          parameters: toolCall.request.parameters.mapValues {
            AgentTranscriptToolCall.Parameter(string: $0.string, value: $0.value)
          })
      }
      let text = ToolCallParser.removeToolCalls(
        output, format: format
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      transcript.append(.assistant(text: text, thinking: thinking, toolCalls: toolCalls))
    }
    return transcript
  }

  /// `imageTokens` gives the tokens for an image that starts at the given offset in the result.
  /// Without it the images are left out, as the chat's transcripts have none.
  static func parse(
    _ transcript: [AgentTranscriptEntry],
    imageTokens: (AgentTranscriptImage, Int) -> [Int32] = { _, _ in [] }
  ) -> [Int32] {
    let format = toolCallFormat
    var tokens = [Int32]()
    // The official encoding joins a message's text and image blocks with "\n\n", which is
    // tokenized with the text next to it.
    func appendContent(_ segments: [String], _ images: [AgentTranscriptImage]) {
      var hasBlock = false
      for (index, segment) in segments.enumerated() {
        let isBeforeImage = index < images.count
        if !segment.isEmpty {
          tokens += safeTokens((hasBlock ? "\n\n" : "") + segment + (isBeforeImage ? "\n\n" : ""))
        } else if isBeforeImage, hasBlock {
          tokens += safeTokens("\n\n")
        }
        hasBlock = hasBlock || !segment.isEmpty
        if isBeforeImage {
          tokens += imageTokens(images[index], tokens.count)
          hasBlock = true
        }
      }
    }
    for entry in transcript {
      switch entry {
      case .user(let text, let images):
        tokens.append(transcriptUserToken)
        appendContent(AgentTranscriptImage.segments(of: text, images: images), images)
      case .assistant(let text, let thinking, let toolCalls):
        tokens.append(transcriptAssistantToken)
        if thinking.isEmpty {
          tokens.append(transcriptThinkEndToken)
        } else {
          tokens.append(transcriptThinkStartToken)
          tokens += safeTokens(thinking)
          tokens.append(transcriptThinkEndToken)
        }
        tokens += safeTokens(text)
        if !toolCalls.isEmpty {
          tokens += safeTokens("\n\n")
          tokens += unsafeTokens(format.toolCallStart + "\n")
          for toolCall in toolCalls {
            tokens += unsafeTokens(format.invokeStart + " name=\"")
            tokens += safeTokens(toolCall.function)
            tokens += unsafeTokens("\">\n")
            for (name, parameter) in toolCall.parameters.sorted(by: { $0.key < $1.key }) {
              tokens += unsafeTokens(format.parameterStart + " name=\"")
              tokens += safeTokens(name)
              tokens += unsafeTokens("\" string=\"\(parameter.string ? "true" : "false")\">")
              tokens += safeTokens(
                parameter.value.replacingOccurrences(
                  of: format.parameterEnd, with: format.escapedParameterEnd))
              tokens += unsafeTokens(format.parameterEnd + "\n")
            }
            tokens += unsafeTokens(format.invokeEnd + "\n")
          }
          tokens += unsafeTokens(format.toolCallEnd)
        }
        tokens.append(transcriptEndOfSentenceToken)
      case .toolResults(let results):
        tokens.append(transcriptUserToken)
        for (index, result) in results.enumerated() {
          if index > 0 {
            tokens += safeTokens("\n\n")
          }
          tokens += safeTokens("<tool_result>")
          appendContent(
            AgentTranscriptImage.segments(of: result.content, images: result.images).map {
              $0.replacingOccurrences(of: "</tool_result>", with: "&lt;/tool_result>")
            }, result.images)
          tokens += safeTokens("</tool_result>")
        }
      }
    }
    return tokens
  }

  private static func stringBlocks(
    in text: String, start: String, end: String
  ) -> [String] {
    var blocks = [String]()
    var cursor = text.startIndex
    while cursor < text.endIndex,
      let startRange = text[cursor...].range(of: start),
      let endRange = text[startRange.upperBound...].range(of: end)
    {
      blocks.append(String(text[startRange.upperBound..<endRange.lowerBound]))
      cursor = endRange.upperBound
    }
    return blocks
  }

  private static func removingStringBlocks(
    from text: String, start: String, end: String
  ) -> String {
    var result = ""
    var cursor = text.startIndex
    while cursor < text.endIndex, let startRange = text[cursor...].range(of: start) {
      result += text[cursor..<startRange.lowerBound]
      guard let endRange = text[startRange.upperBound...].range(of: end) else { return result }
      cursor = endRange.upperBound
    }
    result += text[cursor...]
    return result
  }

  private static func isErrorContent(_ content: String) -> Bool {
    guard let data = content.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return object["error"] != nil
  }

  private static func decoded(_ tokens: [Int32]) -> String {
    Generator.unsafeTokenizer.decode(
      tokens, specialTokens: transcriptSpecialTokens)
  }

  private static func safeTokens(_ text: String) -> [Int32] {
    let (_, tokens, _, _, _) = Generator.safeTokenizer.tokenize(
      text: text, truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    return tokens
  }

  private static func unsafeTokens(_ text: String) -> [Int32] {
    let (_, tokens, _, _, _) = Generator.unsafeTokenizer.tokenize(
      text: text, truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    return tokens
  }
}
