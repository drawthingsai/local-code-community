import Foundation
import ImageIO

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

  /// What a request says about thinking. The chat's settings say the rest.
  enum Thinking: Equatable {
    case disabled
    /// Up to the client's budget, if it gave one.
    case enabled(budget: Int?)
  }

  var instructions = ""
  var transcript = [AgentTranscriptEntry]()
  var tools = [Tool]()
  var isStreaming = false
  /// Nil leaves it to the chat's Thinking Budget.
  var thinking: Thinking?
  /// Nil leaves it to the chat's Reasoning Effort.
  var reasoningEffort: CodeAgentReasoningEffort?
  var maximumOutputTokens: Int?
  /// `temperature: 0` asks for the most likely token when the model is not thinking.
  var isDeterministic = false
  /// Chat Completions' `stream_options.include_usage`, as its stream has usage only when asked.
  var includesStreamUsage = false

  /// Not every model can read them, and which one serves isn't known while the body is read.
  var hasImages: Bool {
    transcript.contains {
      switch $0 {
      case .user(_, let images):
        return !images.isEmpty
      case .toolResults(let results):
        return results.contains { !$0.images.isEmpty }
      case .assistant:
        return false
      }
    }
  }

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
    // A configuration_update item sets the effort from where it is on, so that changing it leaves
    // the input before it as it was. The effort is in the system prompt here, so the last one is
    // the one that counts.
    let configurationUpdates = items.filter { $0["type"] as? String == "configuration_update" }
    try self.init(
      object: object, instructions: object["instructions"] as? String,
      items: items.filter { $0["type"] as? String != "configuration_update" }, tools: tools,
      maximumOutputTokensParameter: "max_output_tokens")
    try setOpenAIReasoningEffort(
      (object["reasoning"] as? [String: Any])?["effort"], parameter: "reasoning.effort")
    for update in configurationUpdates {
      try setOpenAIReasoningEffort(
        (update["reasoning"] as? [String: Any])?["effort"],
        parameter: "configuration_update.reasoning.effort")
    }
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

  /// OpenAI's efforts go from `none`, which turns the thinking off, to `xhigh`. Some clients send
  /// `max` for a model they don't know.
  mutating func setOpenAIReasoningEffort(_ value: Any?, parameter: String) throws {
    guard let value, !(value is NSNull) else { return }
    switch value as? String {
    case "none":
      thinking = .disabled
      reasoningEffort = nil
      return
    case "minimal", "low":
      reasoningEffort = .low
    case "medium":
      reasoningEffort = .medium
    case "high":
      reasoningEffort = .high
    case "xhigh", "max":
      reasoningEffort = .max
    default:
      throw ResponsesRequestError.invalid(
        "\(parameter) must be none, minimal, low, medium, high or xhigh.")
    }
    thinking = .enabled(budget: nil)
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
    // Joins the user message before it, with its images still where they are in its own text.
    func appendUserMessage(_ text: String, _ images: [AgentTranscriptImage]) {
      guard case .user(let previous, let previousImages)? = transcript.last else {
        transcript.append(.user(text, images: images))
        return
      }
      let offset = previous.utf8.count + 2
      transcript[transcript.count - 1] = .user(
        previous + "\n\n" + text,
        images: previousImages
          + images.map { AgentTranscriptImage(offset: $0.offset + offset, data: $0.data) })
    }
    for item in items {
      switch item["type"] as? String ?? "message" {
      case "message":
        let (text, images) = try messageContent(item["content"])
        // The models' templates have images in what the user sends and in what a tool returns.
        if item["role"] as? String != "user", !images.isEmpty {
          throw ResponsesRequestError.unsupported(
            parameter: "input", message: "Images are only supported in user messages.")
        }
        // A system message with nothing in it, such as a Messages change of effort with empty text
        // for its content, is no part of the conversation, even between a call and its output.
        if ["system", "developer"].contains(item["role"] as? String), text.isEmpty {
          continue
        }
        // Qwen can write text after its calls, so the response holds a message after them, ahead
        // of their outputs. Only once the outputs are in does the next one start a new round.
        if item["role"] as? String != "assistant" {
          try endToolCalls()
        } else if case .toolResults? = transcript.last {
          try endToolCalls()
        }
        if item["role"] as? String != "assistant" {
          endThinkingOnlyTurn()
        }
        switch item["role"] as? String {
        case "system", "developer":
          // Only leading ones can join the system prompt. Moving a later one up would change the
          // prefix of everything before it, and so lose the context cache.
          if transcript.isEmpty {
            systemMessages.append(text)
          } else {
            appendUserMessage(text, [])
          }
        case "user":
          appendUserMessage(text, images)
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
        let (content, images) = try messageContent(item["output"])
        let result = AgentTranscriptToolResult(content: content, isError: false, images: images)
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

  /// A message's or a function call output's parts as one text, with the images among them. Text
  /// parts that follow one another are a line each. An image is between the parts around it as
  /// they are, since how an image and text join is up to the model's template.
  private static func messageContent(_ content: Any?) throws
    -> (text: String, images: [AgentTranscriptImage])
  {
    if let text = content as? String { return (text, []) }
    guard let parts = content as? [[String: Any]] else {
      throw ResponsesRequestError.invalid("A message has no content.")
    }
    var text = ""
    var images = [AgentTranscriptImage]()
    var followsText = false
    for part in parts {
      let partText: String
      switch part["type"] as? String {
      case "input_text", "output_text", "text":
        partText = part["text"] as? String ?? ""
      case "refusal":
        partText = part["refusal"] as? String ?? ""
      case "input_image", "image_url", "image":
        images.append(AgentTranscriptImage(offset: text.utf8.count, data: try imageData(part)))
        followsText = false
        continue
      case let type:
        throw ResponsesRequestError.unsupported(
          parameter: "input", message: "Content of type \(type ?? "unknown") is not supported.")
      }
      text += (followsText ? "\n" : "") + partText
      followsText = true
    }
    return (text, images)
  }

  /// The encoded file of an image part, whichever wire protocol the part is in: Responses'
  /// `input_image`, Chat Completions' `image_url` or Messages' `image`.
  private static func imageData(_ part: [String: Any]) throws -> Data {
    var base64: String?
    var url: String?
    switch part["image_url"] {
    case let value as String:
      url = value
    case let value as [String: Any]:
      url = value["url"] as? String
    default:
      let source = part["source"] as? [String: Any]
      base64 = source?["data"] as? String
      url = source?["url"] as? String
    }
    // A data URL holds the same base64 after its comma.
    if let url, url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
      url[..<comma].hasSuffix(";base64")
    {
      base64 = String(url[url.index(after: comma)...])
    }
    guard let base64 else {
      // Nothing is downloaded on a client's word, and no files are stored for it to refer to.
      throw ResponsesRequestError.unsupported(
        parameter: "input",
        message:
          "An image has to be sent as base64 data. Image URLs and file ids are not supported."
      )
    }
    guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else {
      throw ResponsesRequestError.invalid("An image is not base64 data of an image file.")
    }
    return data
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
