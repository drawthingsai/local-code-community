import Foundation

struct OpenAIResponsesStreamAccumulator {
  private struct CompletedOutputItem {
    var outputIndex: Int?
    var value: RemoteJSONValue
  }

  private var text = ""
  private var reasoningText = ""
  private var reasoningItems = [RemoteJSONValue]()
  private var completedOutputItems = [CompletedOutputItem]()
  private var toolCalls = [RemoteToolCall]()
  private var usage: RemoteUsage?
  private var didComplete = false

  mutating func append(_ payload: String) throws -> (
    progress: RemoteStreamProgress?, didComplete: Bool
  ) {
    guard let data = payload.data(using: .utf8),
      let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = event["type"] as? String
    else {
      throw RemoteChatError.malformedStream(
        "invalid OpenAI Responses event near \(String(payload.prefix(256)))")
    }

    var changed = false
    switch type {
    case "response.output_item.added":
      if let item = event["item"] as? [String: Any],
        let itemType = item["type"] as? String
      {
        changed = ["reasoning", "message", "function_call"].contains(itemType)
      }
    case "response.output_text.delta":
      if let delta = event["delta"] as? String {
        text += delta
        changed = !delta.isEmpty
      }
    case "response.reasoning_summary_text.delta":
      if let delta = event["delta"] as? String {
        reasoningText += delta
        changed = !delta.isEmpty
      }
    case "response.output_item.done":
      guard let item = event["item"] as? [String: Any], let itemType = item["type"] as? String
      else { break }
      let value = try remoteJSONValue(item)
      completedOutputItems.append(
        CompletedOutputItem(outputIndex: Self.integer(event["output_index"]), value: value))
      switch itemType {
      case "reasoning":
        reasoningItems.append(value)
        let summary = (item["summary"] as? [[String: Any]])?.compactMap {
          $0["text"] as? String
        }.joined(separator: "\n\n")
        if let summary, !summary.isEmpty { reasoningText = summary }
      case "function_call":
        guard let callID = item["call_id"] as? String, let name = item["name"] as? String,
          let arguments = item["arguments"] as? String
        else {
          throw RemoteChatError.malformedStream(
            "OpenAI returned an incomplete function call")
        }
        let metadata: [RemoteJSONValue]?
        if let itemID = item["id"] as? String {
          metadata = [.object(["item_id": .string(itemID)])]
        } else {
          metadata = nil
        }
        toolCalls.append(
          RemoteToolCall(
            id: callID, name: name, arguments: arguments, providerMetadata: metadata))
        changed = true
      default:
        break
      }
    case "response.completed":
      guard let response = event["response"] as? [String: Any] else {
        throw RemoteChatError.malformedStream(
          "OpenAI response.completed omitted its response")
      }
      if let value = response["usage"] as? [String: Any] {
        usage = RemoteUsage(
          promptTokens: Self.integer(value["input_tokens"]),
          completionTokens: Self.integer(value["output_tokens"]),
          totalTokens: Self.integer(value["total_tokens"]))
      }
      if let output = response["output"] as? [Any] {
        completedOutputItems = try output.enumerated().map { index, item in
          CompletedOutputItem(outputIndex: index, value: try remoteJSONValue(item))
        }
      }
      didComplete = true
    case "response.failed":
      let response = event["response"] as? [String: Any]
      let error = response?["error"] as? [String: Any]
      throw RemoteChatError.providerStream(
        error?["message"] as? String ?? "OpenAI reported a failed response.")
    case "response.incomplete":
      let response = event["response"] as? [String: Any]
      let details = response?["incomplete_details"] as? [String: Any]
      throw RemoteChatError.incompleteResponse(
        details?["reason"] as? String ?? "unknown")
    case "error":
      let error = event["error"] as? [String: Any]
      throw RemoteChatError.providerStream(
        error?["message"] as? String ?? event["message"] as? String
          ?? "OpenAI reported a streaming error.")
    default:
      break
    }
    return (changed ? progress : nil, didComplete)
  }

  var completion: RemoteCompletion {
    RemoteCompletion(
      content: content, usage: usage, stopReason: toolCalls.isEmpty ? "stop" : "tool_use",
      providerOutputItems: outputItems.isEmpty ? nil : outputItems)
  }

  private var progress: RemoteStreamProgress {
    RemoteStreamProgress(content: content)
  }

  private var content: [RemoteContentBlock] {
    var content = [RemoteContentBlock]()
    if !reasoningItems.isEmpty || !reasoningText.isEmpty {
      content.append(
        .thinking(
          RemoteThinking(
            text: reasoningText.isEmpty ? nil : reasoningText,
            providerMetadata: reasoningItems.isEmpty ? nil : reasoningItems)))
    }
    if !text.isEmpty { content.append(.text(text)) }
    content += toolCalls.map(RemoteContentBlock.toolCall)
    return content
  }

  private var outputItems: [RemoteJSONValue] {
    let indexedItems = completedOutputItems.compactMap(\.outputIndex)
    guard indexedItems.count == completedOutputItems.count,
      Set(indexedItems).count == completedOutputItems.count
    else {
      return completedOutputItems.map(\.value)
    }
    return completedOutputItems.sorted { $0.outputIndex! < $1.outputIndex! }.map(\.value)
  }

  private func remoteJSONValue(_ object: Any) throws -> RemoteJSONValue {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(RemoteJSONValue.self, from: data)
  }

  private static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
  }
}
