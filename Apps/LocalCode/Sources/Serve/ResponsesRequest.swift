import Foundation

enum ResponsesRequestError: Error, Equatable {
  case invalid(String)
  case unsupported(parameter: String, message: String)
}

/// A `POST /v1/responses` body, reduced to what the local models can do with it. The other wire
/// protocols' bodies come down to Responses' input items too, which hold all they can say.
struct ResponsesRequest {
  struct Tool {
    let name: String
    let description: String?
    let parameters: [String: Any]?

    /// One line in the shape the models' tool schemas use. Keys are sorted so the same tools
    /// always produce the same tokens, which keeps the context cache's prefix valid.
    var schemaLine: String { Self.line(["type": "function", "function": function]) }

    /// The function alone, the way GLM's chat template lists a tool.
    var functionSchemaLine: String { Self.line(function) }

    private var function: [String: Any] {
      var function: [String: Any] = ["name": name]
      if let description { function["description"] = description }
      if let parameters { function["parameters"] = parameters }
      return function
    }

    private static func line(_ object: [String: Any]) -> String {
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
      else { return "" }
      return String(decoding: data, as: UTF8.self)
    }
  }

  var instructions = ""
  var transcript = [AgentTranscriptEntry]()
  var tools = [Tool]()
  var isStreaming = false
  var maximumOutputTokens: Int?
  /// `temperature: 0` asks for the most likely token when the model is not thinking.
  var isDeterministic = false
  /// Chat Completions' `stream_options.include_usage`, as its stream has usage only when asked.
  var includesStreamUsage = false

  init(body: Data) throws {
    let object = try Self.object(from: body)
    // The model keeps no response, so a follow-up has to send the whole conversation again.
    if !(object["previous_response_id"] is NSNull), object["previous_response_id"] != nil {
      throw ResponsesRequestError.unsupported(
        parameter: "previous_response_id",
        message: "Responses are not stored. Send the full conversation in input.")
    }
    if !(object["conversation"] is NSNull), object["conversation"] != nil {
      throw ResponsesRequestError.unsupported(
        parameter: "conversation", message: "Conversations are not stored.")
    }
    if let format = (object["text"] as? [String: Any])?["format"] as? [String: Any],
      let type = format["type"] as? String, type != "text"
    {
      throw ResponsesRequestError.unsupported(
        parameter: "text.format", message: "Structured output is not supported.")
    }
    var tools = [Tool]()
    if object["tool_choice"] as? String != "none",
      let definitions = object["tools"] as? [[String: Any]]
    {
      // Hosted and custom tools have no local equivalent. A client that offers them alongside
      // functions should still work with the functions.
      tools = definitions.compactMap { tool in
        guard tool["type"] as? String == "function", let name = tool["name"] as? String else {
          return nil
        }
        return Tool(
          name: name, description: tool["description"] as? String,
          parameters: tool["parameters"] as? [String: Any])
      }
    }
    let items: [[String: Any]]
    switch object["input"] {
    case let input as String:
      items = [["type": "message", "role": "user", "content": input]]
    case let input as [[String: Any]]:
      items = input
    default:
      throw ResponsesRequestError.invalid("input must be a string or an array of items.")
    }
    try self.init(
      object: object, instructions: object["instructions"] as? String, items: items, tools: tools,
      maximumOutputTokensParameter: "max_output_tokens")
  }

  /// What every wire protocol's body has in common, once its conversation is in input items.
  init(
    object: [String: Any], instructions: String?, items: [[String: Any]], tools: [Tool],
    maximumOutputTokensParameter: String
  ) throws {
    isStreaming = object["stream"] as? Bool ?? false
    if let value = object[maximumOutputTokensParameter], !(value is NSNull) {
      guard let number = value as? NSNumber, let count = Int(exactly: number.doubleValue), count > 0
      else {
        throw ResponsesRequestError.invalid(
          "\(maximumOutputTokensParameter) must be a whole number above 0.")
      }
      maximumOutputTokens = count
    }
    isDeterministic = (object["temperature"] as? NSNumber)?.doubleValue == 0
    self.tools = tools
    var systemMessages = [String]()
    if let instructions, !instructions.isEmpty {
      systemMessages.append(instructions)
    }
    transcript = try Self.transcript(from: items, systemMessages: &systemMessages)
    guard !transcript.isEmpty else {
      throw ResponsesRequestError.invalid("The request holds no conversation.")
    }
    self.instructions = systemMessages.joined(separator: "\n\n")
  }

  static func object(from body: Data) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw ResponsesRequestError.invalid("The request body is not a JSON object.")
    }
    return object
  }

  /// Decodes a function call's arguments the way its tool's schema describes them.
  func arguments(of toolCall: ToolCall) -> String {
    let tool = tools.first { $0.name == toolCall.request.function }
    let properties = tool?.parameters?["properties"] as? [String: Any]
    var arguments = [String: Any]()
    for (name, parameter) in toolCall.request.parameters {
      let schema = properties?[name] as? [String: Any]
      let types: [String]
      switch schema?["type"] {
      case let type as String: types = [type]
      case let type as [String]: types = type
      default: types = []
      }
      // A schema of only a string settles it. Without one, or with a string among other types like
      // `["string", "null"]`, the parameter's own marking says whether it holds JSON text.
      if types == ["string"] || ((types.isEmpty || types.contains("string")) && parameter.string) {
        arguments[name] = parameter.value
      } else {
        arguments[name] =
          (try? JSONSerialization.jsonObject(
            with: Data(parameter.value.utf8), options: .fragmentsAllowed))
          ?? parameter.value
      }
    }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private static func transcript(
    from items: [[String: Any]], systemMessages: inout [String]
  ) throws -> [AgentTranscriptEntry] {
    var transcript = [AgentTranscriptEntry]()
    var pendingThinking = ""
    // A turn with nothing but thinking still happened. Without it the two user messages around it
    // would merge, and its thinking would move to the next turn.
    func endThinkingOnlyTurn() {
      guard !pendingThinking.isEmpty else { return }
      transcript.append(.assistant(text: "", thinking: pendingThinking, toolCalls: []))
      pendingThinking = ""
    }
    // The model reads results in the order of its calls, as neither says which call it is. Each
    // output goes where its call is, so the calls' outputs can come in any order.
    var callIds = [String]()
    var answeredCallIds = Set<String>()
    // Whose call each result in the latest .toolResults answers.
    var resultCallIndices = [Int]()
    // Every call has to have its output before the conversation moves on.
    func endToolCalls() throws {
      if let callId = callIds.first(where: { !answeredCallIds.contains($0) }) {
        throw ResponsesRequestError.invalid("No function_call_output has call_id \(callId).")
      }
      callIds = []
      answeredCallIds = []
      resultCallIndices = []
    }
    for item in items {
      switch item["type"] as? String ?? "message" {
      case "message":
        // Qwen can write text after its calls, so the response holds a message after them, ahead
        // of their outputs. Only once the outputs are in does the next one start a new round.
        if item["role"] as? String != "assistant" {
          try endToolCalls()
        } else if case .toolResults? = transcript.last {
          try endToolCalls()
        }
        let text = try messageText(item["content"])
        if item["role"] as? String != "assistant" {
          endThinkingOnlyTurn()
        }
        switch item["role"] as? String {
        case "system", "developer":
          // Only leading ones can join the system prompt. Moving a later one up would change the
          // prefix of everything before it, and so lose the context cache.
          if transcript.isEmpty {
            systemMessages.append(text)
          } else if case .user(let previous)? = transcript.last {
            transcript[transcript.count - 1] = .user(previous + "\n\n" + text)
          } else {
            transcript.append(.user(text))
          }
        case "user":
          if case .user(let previous)? = transcript.last {
            transcript[transcript.count - 1] = .user(previous + "\n\n" + text)
          } else {
            transcript.append(.user(text))
          }
        case "assistant":
          if case .assistant(let previous, let thinking, let toolCalls)? = transcript.last,
            toolCalls.isEmpty, pendingThinking.isEmpty
          {
            transcript[transcript.count - 1] = .assistant(
              text: previous + "\n\n" + text, thinking: thinking, toolCalls: [])
          } else {
            transcript.append(.assistant(text: text, thinking: pendingThinking, toolCalls: []))
            pendingThinking = ""
          }
        default:
          throw ResponsesRequestError.invalid("A message has no known role.")
        }
      case "reasoning":
        // The transcript renderers add the whitespace around thinking back themselves.
        pendingThinking += thinkingText(item).trimmingCharacters(in: .whitespacesAndNewlines)
      case "function_call":
        guard let name = item["name"] as? String else {
          throw ResponsesRequestError.invalid("A function_call has no name.")
        }
        guard let callId = item["call_id"] as? String else {
          throw ResponsesRequestError.invalid("A function_call has no call_id.")
        }
        if case .toolResults? = transcript.last {
          try endToolCalls()
        }
        callIds.append(callId)
        let toolCall = AgentTranscriptToolCall(
          function: name, parameters: try parameters(item["arguments"] as? String))
        if case .assistant(let text, let thinking, let toolCalls)? = transcript.last,
          pendingThinking.isEmpty
        {
          transcript[transcript.count - 1] = .assistant(
            text: text, thinking: thinking, toolCalls: toolCalls + [toolCall])
        } else {
          transcript.append(.assistant(text: "", thinking: pendingThinking, toolCalls: [toolCall]))
          pendingThinking = ""
        }
      case "function_call_output":
        guard let callId = item["call_id"] as? String,
          let callIndex = callIds.firstIndex(of: callId)
        else {
          throw ResponsesRequestError.invalid(
            "A function_call_output has a call_id no function_call before it has.")
        }
        guard answeredCallIds.insert(callId).inserted else {
          throw ResponsesRequestError.invalid(
            "More than one function_call_output has call_id \(callId).")
        }
        endThinkingOnlyTurn()
        let result = AgentTranscriptToolResult(
          content: try outputText(item["output"]), isError: false)
        if case .toolResults(var results)? = transcript.last {
          let position = resultCallIndices.firstIndex { $0 > callIndex } ?? results.count
          results.insert(result, at: position)
          resultCallIndices.insert(callIndex, at: position)
          transcript[transcript.count - 1] = .toolResults(results)
        } else {
          transcript.append(.toolResults([result]))
          resultCallIndices = [callIndex]
        }
      case let type:
        throw ResponsesRequestError.unsupported(
          parameter: "input", message: "Input items of type \(type) are not supported.")
      }
    }
    try endToolCalls()
    endThinkingOnlyTurn()
    return transcript
  }

  private static func messageText(_ content: Any?) throws -> String {
    if let text = content as? String { return text }
    guard let parts = content as? [[String: Any]] else {
      throw ResponsesRequestError.invalid("A message has no content.")
    }
    return try parts.map { part in
      switch part["type"] as? String {
      case "input_text", "output_text", "text":
        return part["text"] as? String ?? ""
      case "refusal":
        return part["refusal"] as? String ?? ""
      case let type:
        throw ResponsesRequestError.unsupported(
          parameter: "input", message: "Content of type \(type ?? "unknown") is not supported.")
      }
    }.joined(separator: "\n")
  }

  private static func outputText(_ output: Any?) throws -> String {
    if let text = output as? String { return text }
    return try messageText(output)
  }

  /// Reads the thinking back from wherever the client kept it. Replaying it is what lets the
  /// conversation keep its context cache past this assistant turn.
  private static func thinkingText(_ item: [String: Any]) -> String {
    if let content = item["content"] as? [[String: Any]] {
      let text = content.compactMap { $0["text"] as? String }.joined()
      if !text.isEmpty { return text }
    }
    if let encrypted = item["encrypted_content"] as? String,
      let data = Data(base64Encoded: encrypted), let text = String(data: data, encoding: .utf8)
    {
      return text
    }
    return ((item["summary"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
      .joined(separator: "\n\n")
  }

  private static func parameters(_ arguments: String?) throws
    -> [String: AgentTranscriptToolCall.Parameter]
  {
    guard let arguments, !arguments.isEmpty else { return [:] }
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8))
        as? [String: Any]
    else {
      throw ResponsesRequestError.invalid("A function_call's arguments are not a JSON object.")
    }
    return object.mapValues { value in
      if let string = value as? String {
        return AgentTranscriptToolCall.Parameter(string: true, value: string)
      }
      let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
      return AgentTranscriptToolCall.Parameter(
        string: false, value: data.map { String(decoding: $0, as: UTF8.self) } ?? "null")
    }
  }
}
