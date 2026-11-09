import Foundation

extension ResponsesRequest {
  /// A `POST /v1/messages` body. Its content blocks are Responses' input items under other names,
  /// in the same order, so the conversation follows the same rules.
  init(messagesBody body: Data) throws {
    let object = try Self.object(from: body)
    if !(object["thread"] is NSNull), object["thread"] != nil {
      throw ResponsesRequestError.unsupported(
        parameter: "thread", message: "Threads are not stored. Send the full conversation.")
    }
    if let format = (object["output_config"] as? [String: Any])?["format"], !(format is NSNull) {
      throw ResponsesRequestError.unsupported(
        parameter: "output_config.format", message: "Structured output is not supported.")
    }
    if let stopSequences = object["stop_sequences"] as? [Any], !stopSequences.isEmpty {
      throw ResponsesRequestError.unsupported(
        parameter: "stop_sequences", message: "Stop sequences are not supported.")
    }
    var tools = [Tool]()
    if (object["tool_choice"] as? [String: Any])?["type"] as? String != "none",
      let definitions = object["tools"] as? [[String: Any]]
    {
      // Server tools, and Anthropic's tools that come without a schema, have no local equivalent.
      tools = definitions.compactMap { tool in
        guard tool["type"] as? String ?? "custom" == "custom", let name = tool["name"] as? String
        else { return nil }
        return Tool(
          name: name, description: tool["description"] as? String,
          parameters: tool["input_schema"] as? [String: Any])
      }
    }
    guard let messages = object["messages"] as? [[String: Any]] else {
      throw ResponsesRequestError.invalid("messages must be an array of messages.")
    }
    let thinking: Thinking?
    switch object["thinking"] {
    case nil, is NSNull:
      thinking = nil
    case let value as [String: Any]:
      switch value["type"] as? String {
      case "enabled":
        var budget: Int?
        if let value = value["budget_tokens"], !(value is NSNull) {
          guard let number = value as? NSNumber, let count = Int(exactly: number.doubleValue),
            count > 0
          else {
            throw ResponsesRequestError.invalid(
              "thinking.budget_tokens must be a whole number above 0.")
          }
          budget = count
        }
        thinking = .enabled(budget: budget)
      case "adaptive":
        thinking = .enabled(budget: nil)
      case "disabled", "between_tools":
        thinking = .disabled
      default:
        throw ResponsesRequestError.invalid("thinking.type must be enabled, adaptive or disabled.")
      }
    default:
      throw ResponsesRequestError.invalid("thinking must be an object.")
    }
    var reasoningEffort = try Self.messagesReasoningEffort(
      (object["output_config"] as? [String: Any])?["effort"], parameter: "output_config.effort")
    // A change of effort that waits for the next user turn with new input.
    var pendingReasoningEffort: CodeAgentReasoningEffort?
    var followsNewInput = false
    var items = [[String: Any]]()
    // A leading system message joins the instructions, as `system` does.
    switch object["system"] {
    case let system as String where !system.isEmpty:
      items.append(["type": "message", "role": "system", "content": system])
    case let system as [[String: Any]] where !system.isEmpty:
      items.append(["type": "message", "role": "system", "content": system])
    default:
      break
    }
    for message in messages {
      let blocks: [[String: Any]]
      switch message["content"] {
      case let text as String:
        blocks = [["type": "text", "text": text]]
      case let content as [[String: Any]]:
        blocks = content
      default:
        throw ResponsesRequestError.invalid("A message has no content.")
      }
      // A system message, usually with no content, can change the effort, so that the messages
      // before it stay as they were. Right after a user turn with new input, the change is for the
      // reply to it. Anywhere else it waits for the next such turn, and tool results are not new
      // input, so a change during a tool loop waits for the loop to end. The effort is in the system
      // prompt here, so the one in effect at the end is the one that counts.
      switch message["role"] as? String {
      case "system":
        if let effort = try Self.messagesReasoningEffort(
          (message["output_config"] as? [String: Any])?["effort"],
          parameter: "messages.output_config.effort")
        {
          if followsNewInput {
            reasoningEffort = effort
          } else {
            pendingReasoningEffort = effort
          }
        }
      case "user" where blocks.contains(where: { $0["type"] as? String != "tool_result" }):
        reasoningEffort = pendingReasoningEffort ?? reasoningEffort
        pendingReasoningEffort = nil
        followsNewInput = true
      default:
        followsNewInput = false
      }
      guard message["role"] as? String == "assistant" else {
        // Tool results come first in a user message, and anything after them is a message of its
        // own.
        var parts = [[String: Any]]()
        func appendMessage() {
          guard !parts.isEmpty else { return }
          var item: [String: Any] = ["type": "message", "content": parts]
          item["role"] = message["role"]
          items.append(item)
          parts = []
        }
        for block in blocks {
          guard block["type"] as? String == "tool_result" else {
            parts.append(block)
            continue
          }
          appendMessage()
          var item: [String: Any] = ["type": "function_call_output", "output": ""]
          item["call_id"] = block["tool_use_id"]
          if let content = block["content"], !(content is NSNull) {
            item["output"] = content
          }
          items.append(item)
        }
        appendMessage()
        continue
      }
      for block in blocks {
        switch block["type"] as? String {
        case "thinking":
          items.append([
            "type": "reasoning",
            "content": [["type": "reasoning_text", "text": block["thinking"] as? String ?? ""]],
          ])
        case "redacted_thinking":
          // Never written here, and nothing a local model could read.
          break
        case "tool_use":
          let input = block["input"] ?? [String: Any]()
          let arguments =
            (try? JSONSerialization.data(withJSONObject: input, options: .fragmentsAllowed)).map {
              String(decoding: $0, as: UTF8.self)
            } ?? "{}"
          var item: [String: Any] = ["type": "function_call", "arguments": arguments]
          item["call_id"] = block["id"]
          item["name"] = block["name"]
          items.append(item)
        default:
          items.append(["type": "message", "role": "assistant", "content": [block]])
        }
      }
    }
    try self.init(
      object: object, instructions: nil, items: items, tools: tools,
      maximumOutputTokensParameter: "max_tokens")
    self.thinking = thinking
    self.reasoningEffort = reasoningEffort
  }

  /// Anthropic's efforts go up to `max`, with `xhigh` below it, which the local models don't have.
  private static func messagesReasoningEffort(_ value: Any?, parameter: String) throws
    -> CodeAgentReasoningEffort?
  {
    guard let value, !(value is NSNull) else { return nil }
    switch value as? String {
    case "low":
      return .low
    case "medium":
      return .medium
    case "high":
      return .high
    case "xhigh", "max":
      return .max
    default:
      throw ResponsesRequestError.invalid("\(parameter) must be low, medium, high, xhigh or max.")
    }
  }
}
