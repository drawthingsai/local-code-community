import Foundation

extension ResponsesRequest {
  /// A `POST /v1/chat/completions` body. Each message becomes the input items it holds: an
  /// assistant's reasoning, text and tool calls, or a tool message's result.
  init(chatCompletionsBody body: Data) throws {
    let object = try Self.object(from: body)
    if let count = object["n"] as? NSNumber, count.intValue != 1 {
      throw ResponsesRequestError.unsupported(
        parameter: "n", message: "Only one choice is generated.")
    }
    if let format = (object["response_format"] as? [String: Any])?["type"] as? String,
      format != "text"
    {
      throw ResponsesRequestError.unsupported(
        parameter: "response_format", message: "Structured output is not supported.")
    }
    switch object["stop"] {
    case let stop as String where !stop.isEmpty:
      throw ResponsesRequestError.unsupported(
        parameter: "stop", message: "Stop sequences are not supported.")
    case let stop as [Any] where !stop.isEmpty:
      throw ResponsesRequestError.unsupported(
        parameter: "stop", message: "Stop sequences are not supported.")
    default:
      break
    }
    var tools = [Tool]()
    if object["tool_choice"] as? String != "none",
      let definitions = object["tools"] as? [[String: Any]]
    {
      // Custom tools have no local equivalent.
      tools = definitions.compactMap { tool in
        guard tool["type"] as? String == "function",
          let function = tool["function"] as? [String: Any],
          let name = function["name"] as? String
        else { return nil }
        return Tool(
          name: name, description: function["description"] as? String,
          parameters: function["parameters"] as? [String: Any])
      }
    }
    guard let messages = object["messages"] as? [[String: Any]] else {
      throw ResponsesRequestError.invalid("messages must be an array of messages.")
    }
    var items = [[String: Any]]()
    for message in messages {
      let content = message["content"].flatMap { $0 is NSNull ? nil : $0 }
      switch message["role"] as? String {
      case "assistant":
        // There is no standard field for the thinking, so either of the ones in use.
        let reasoning =
          message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? ""
        let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        if !reasoning.isEmpty {
          items.append([
            "type": "reasoning", "content": [["type": "reasoning_text", "text": reasoning]],
          ])
        }
        if let content {
          items.append(["type": "message", "role": "assistant", "content": content])
        } else if reasoning.isEmpty, toolCalls.isEmpty {
          items.append(["type": "message", "role": "assistant", "content": ""])
        }
        for toolCall in toolCalls {
          let function = toolCall["function"] as? [String: Any]
          var item: [String: Any] = [
            "type": "function_call", "arguments": function?["arguments"] as? String ?? "",
          ]
          item["call_id"] = toolCall["id"]
          item["name"] = function?["name"]
          items.append(item)
        }
      case "tool":
        var item: [String: Any] = ["type": "function_call_output", "output": content ?? ""]
        item["call_id"] = message["tool_call_id"]
        items.append(item)
      default:
        // System, developer and user messages are input items as they are.
        var item: [String: Any] = ["type": "message"]
        item["role"] = message["role"]
        item["content"] = content
        items.append(item)
      }
    }
    // A null max_completion_tokens leaves max_tokens in charge, as a missing one does.
    try self.init(
      object: object, instructions: nil, items: items, tools: tools,
      maximumOutputTokensParameter: (object["max_completion_tokens"] ?? NSNull()) is NSNull
        ? "max_tokens" : "max_completion_tokens")
    includesStreamUsage =
      (object["stream_options"] as? [String: Any])?["include_usage"] as? Bool ?? false
  }
}
