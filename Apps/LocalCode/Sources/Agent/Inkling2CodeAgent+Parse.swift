import Foundation

extension Inkling2CodeAgent {
  private struct Message {
    var role: Int32
    var header: [Int32]
    var content: Int32
    var body: [Int32]
    /// The message's tokens as they are in the log.
    var tokens: [Int32]
  }

  /// The log's messages, each `ROLE HEADER CONTENT BODY <|end_message|>`, and where the model's
  /// turns end. A content marker without a role is the model's.
  private static func messages(in tokens: [Int32]) -> [(message: Message?, endsTurn: Bool)] {
    var result = [(message: Message?, endsTurn: Bool)]()
    var index = tokens.startIndex
    while index < tokens.endIndex {
      let start = index
      let token = tokens[index]
      if token == endOfTurnToken || token == endOfTextToken {
        result.append((nil, true))
        index += 1
        continue
      }
      let role: Int32
      if roleTokens.contains(token) {
        role = token
        index += 1
      } else if contentTokens.contains(token) {
        role = modelMessageToken
      } else {
        index += 1
        continue
      }
      guard
        let contentIndex = tokens[index...].firstIndex(where: {
          contentTokens.contains($0) || roleTokens.contains($0) || stopTokens.contains($0)
            || $0 == endMessageToken
        }), contentTokens.contains(tokens[contentIndex])
      else { continue }
      let header = Array(tokens[index..<contentIndex])
      let bodyEnd =
        tokens[(contentIndex + 1)...].firstIndex(where: {
          $0 == endMessageToken || roleTokens.contains($0) || stopTokens.contains($0)
        }) ?? tokens.endIndex
      index =
        bodyEnd < tokens.endIndex && tokens[bodyEnd] == endMessageToken ? bodyEnd + 1 : bodyEnd
      result.append(
        (
          Message(
            role: role, header: header, content: tokens[contentIndex],
            body: Array(tokens[(contentIndex + 1)..<bodyEnd]), tokens: Array(tokens[start..<index])),
          false
        ))
    }
    return result
  }

  static func parse(_ tokens: [Int32]) -> [AgentTranscriptEntry] {
    var transcript = [AgentTranscriptEntry]()
    var userTexts = [String]()
    var modelTokens = [Int32]()
    var toolMessages = [Message]()
    var lastToolCalls = [AgentTranscriptToolCall]()

    func flushUser() {
      guard !userTexts.isEmpty else { return }
      transcript.append(.user(userTexts.joined(separator: "\n")))
      userTexts = []
    }
    func flushModel() {
      guard !modelTokens.isEmpty else { return }
      // As the agent reads a generation: thinking first, then the visible text and calls.
      let split = Inkling2ThinkingSplitter.split(modelTokens)
      var parser = Inkling2ToolCallParser()
      parser.append(decoded(split.output))
      parser.finish()
      let calls = parser.toolCalls.map { call in
        AgentTranscriptToolCall(
          function: call.request.function,
          parameters: call.request.parameters.mapValues {
            AgentTranscriptToolCall.Parameter(string: $0.string, value: $0.value)
          })
      }
      transcript.append(
        .assistant(
          text: parser.text.trimmingCharacters(in: .whitespacesAndNewlines),
          thinking: decoded(split.thinking), toolCalls: calls))
      lastToolCalls = calls
      modelTokens = []
    }
    func flushTools() {
      guard !toolMessages.isEmpty else { return }
      transcript.append(.toolResults(toolResults(toolMessages, calls: lastToolCalls)))
      toolMessages = []
    }

    for (message, endsTurn) in messages(in: tokens) {
      guard let message else {
        if endsTurn { flushModel() }
        continue
      }
      switch message.role {
      case userMessageToken:
        flushModel()
        flushTools()
        guard message.content != imageContentToken else { continue }
        var text = decoded(message.body)
        if text.hasPrefix("<system-reminder>\n"), let end = text.range(of: "</system-reminder>\n") {
          text = String(text[end.upperBound...])
          guard !text.isEmpty else { continue }
        }
        userTexts.append(text)
      case modelMessageToken:
        flushUser()
        flushTools()
        modelTokens += message.tokens
      case toolMessageToken:
        flushUser()
        flushModel()
        toolMessages.append(message)
      default:
        break
      }
    }
    flushUser()
    flushModel()
    flushTools()
    return transcript
  }

  /// Groups tool messages into results, one message per part, each named after its call. A
  /// different name starts the next result, and so does text after text, as the agent joins
  /// adjacent text parts. Text after an image of the same tool is the same result's next part,
  /// such as a PDF's next page, unless the next call is to that tool too.
  private static func toolResults(
    _ messages: [Message], calls: [AgentTranscriptToolCall]
  ) -> [AgentTranscriptToolResult] {
    var results = [AgentTranscriptToolResult]()
    var texts = [String]()
    func flush() {
      let content = texts.joined()
      let object = content.data(using: .utf8).flatMap {
        (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
      }
      results.append(AgentTranscriptToolResult(content: content, isError: object?["error"] != nil))
      texts = []
    }
    for (index, message) in messages.enumerated() {
      if index > 0 {
        let previous = messages[index - 1]
        let startsResult: Bool
        if message.header != previous.header {
          startsResult = true
        } else if message.content == imageContentToken {
          startsResult = false
        } else if previous.content != imageContentToken || calls.isEmpty {
          startsResult = true
        } else {
          let next = results.count + 1
          startsResult = next < calls.count && calls[next].function == decoded(message.header)
        }
        if startsResult {
          flush()
        }
      }
      guard message.content != imageContentToken else { continue }
      texts.append(decoded(message.body))
    }
    if !messages.isEmpty { flush() }
    return results
  }

  /// Canonical template rendering for imported history. Active generations retain their raw
  /// tokens.
  ///
  /// `imageTokens` gives the placeholder tokens for an image that starts at the given offset in the
  /// result. Without it the images are left out, as the chat's transcripts have none.
  static func parse(
    _ transcript: [AgentTranscriptEntry],
    imageTokens: (AgentTranscriptImage, Int) -> [Int32] = { _, _ in [] }
  ) -> [Int32] {
    var tokens = [Int32]()
    // The template renders each part of a message as a message of its own.
    func appendContent(
      role: Int32, header: [Int32], _ text: String, _ images: [AgentTranscriptImage]
    ) {
      let start = tokens.count
      let segments = AgentTranscriptImage.segments(of: text, images: images)
      for (image, segment) in zip(images, segments) {
        if !segment.isEmpty {
          tokens += message(role, header: header, safeTokens(segment))
        }
        let placeholderStart = tokens.count + 1 + header.count + 1
        let placeholders = imageTokens(image, placeholderStart)
        guard !placeholders.isEmpty else { continue }
        tokens += [role] + header + [imageContentToken] + placeholders + [endMessageToken]
      }
      if !segments[images.count].isEmpty || tokens.count == start {
        tokens += message(role, header: header, safeTokens(segments[images.count]))
      }
    }
    var lastToolCalls = [AgentTranscriptToolCall]()
    for entry in transcript {
      switch entry {
      case .user(let text, let images):
        appendContent(role: userMessageToken, header: [], text, images)
      case .assistant(let text, let thinking, let calls):
        if !thinking.isEmpty {
          tokens +=
            [modelMessageToken, thinkingContentToken] + safeTokens(thinking)
            + [endMessageToken]
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || (calls.isEmpty && thinking.isEmpty) {
          tokens += message(modelMessageToken, safeTokens(text))
        }
        for call in calls {
          var arguments = [String: Any]()
          for (key, parameter) in call.parameters {
            if parameter.string {
              arguments[key] = parameter.value
            } else {
              arguments[key] =
                parameter.value.data(using: .utf8).flatMap {
                  try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed)
                } ?? parameter.value
            }
          }
          let body =
            "{\"name\":" + Inkling2ToolCallParser.json(call.function) + ",\"args\":"
            + Inkling2ToolCallParser.json(arguments) + "}"
          tokens +=
            [modelMessageToken] + safeTokens(call.function) + [invokeToolJSONContentToken]
            + safeTokens(body) + [endMessageToken]
        }
        tokens.append(endOfTurnToken)
        lastToolCalls = calls
      case .toolResults(let results):
        for (index, result) in results.enumerated() {
          let name = index < lastToolCalls.count ? lastToolCalls[index].function : ""
          appendContent(
            role: toolMessageToken, header: safeTokens(name), result.content, result.images)
        }
      }
    }
    return tokens
  }

  // A transcript cannot carry images, so their tokens stay out of its text; labels remain.
  private static func decoded(_ tokens: [Int32]) -> String {
    Inkling2SmallTextGenerator.unsafeTokenizer.decode(tokens.filter { $0 != imageToken })
  }

  private static func safeTokens(_ text: String) -> [Int32] {
    Inkling2SmallTextGenerator.safeTokenizer.tokenize(text: text, addSpecialTokens: false).0
  }
}
