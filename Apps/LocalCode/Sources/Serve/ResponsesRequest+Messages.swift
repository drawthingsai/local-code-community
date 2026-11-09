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
  }
}
