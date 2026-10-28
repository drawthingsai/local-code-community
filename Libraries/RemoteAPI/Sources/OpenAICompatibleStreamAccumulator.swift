import Foundation

struct OpenAICompatibleStreamAccumulator {
  private struct PartialToolCall {
    var id = ""
    var name = ""
    var arguments = ""
  }

  private var text = ""
  private var reasoning = ""
  private var reasoningDetails = [RemoteJSONValue]()
  private var toolCallsByIndex = [Int: PartialToolCall]()
  private var stopReason: String?
  private(set) var usage: RemoteUsage?

  mutating func append(_ payload: String) throws -> RemoteStreamProgress? {
    guard let data = payload.data(using: .utf8) else {
      throw RemoteChatError.malformedStream("event data is not valid UTF-8")
    }
    let record: StreamRecord
    do {
      record = try JSONDecoder().decode(StreamRecord.self, from: data)
    } catch {
      let detail = String(payload.prefix(256))
      throw RemoteChatError.malformedStream("invalid JSON near \(detail)")
    }
    if let providerError = record.error {
      if let statusCode = providerError.statusCode {
        throw RemoteChatError.provider(
          statusCode: statusCode, message: providerError.message)
      }
      throw RemoteChatError.providerStream(providerError.message)
    }
    if let usage = record.usage {
      self.usage = usage
    }
    var changed = false
    for choice in record.choices ?? [] where choice.index == 0 {
      if let finishReason = choice.finishReason {
        stopReason = finishReason
      }
      if let content = choice.delta.content {
        text += content
        changed = changed || !content.isEmpty
      }
      if let delta = choice.delta.reasoning ?? choice.delta.reasoningContent {
        reasoning += delta
        changed = changed || !delta.isEmpty
      }
      if let details = choice.delta.reasoningDetails, !details.isEmpty {
        appendReasoningDetails(details)
        changed = true
      }
      for toolDelta in choice.delta.toolCalls ?? [] {
        var partial = toolCallsByIndex[toolDelta.index] ?? PartialToolCall()
        if let id = toolDelta.id {
          partial.id += id
        }
        if let function = toolDelta.function {
          if let name = function.name {
            partial.name += name
          }
          if let arguments = function.arguments {
            partial.arguments += arguments.text
          }
        }
        toolCallsByIndex[toolDelta.index] = partial
        changed = true
      }
    }
    return changed ? progress : nil
  }

  private mutating func appendReasoningDetails(_ details: [RemoteJSONValue]) {
    for detail in details {
      guard case .object(var incoming) = detail else {
        reasoningDetails.append(detail)
        continue
      }
      if incoming["id"] == nil {
        incoming["id"] = .null
      }
      let normalized = RemoteJSONValue.object(incoming)
      guard normalized.isValidOpenRouterReasoningDetail,
        case .number(let index)? = incoming["index"],
        let existingIndex = reasoningDetails.firstIndex(where: { detail in
          guard case .object(let existing) = detail,
            existing["index"] == .number(index), existing["type"] == incoming["type"],
            existing["format"] == incoming["format"]
          else { return false }
          return existing["id"] == incoming["id"] || existing["id"] == .null
            || incoming["id"] == .null
        }),
        case .object(var existing) = reasoningDetails[existingIndex]
      else {
        reasoningDetails.append(normalized)
        continue
      }
      let contentKey: String
      switch incoming["type"] {
      case .string("reasoning.summary")?: contentKey = "summary"
      case .string("reasoning.encrypted")?: contentKey = "data"
      case .string("reasoning.text")?: contentKey = "text"
      default:
        reasoningDetails.append(normalized)
        continue
      }
      guard case .string(let existingContent)? = existing[contentKey],
        case .string(let incomingContent)? = incoming[contentKey]
      else {
        reasoningDetails.append(normalized)
        continue
      }
      existing[contentKey] = .string(existingContent + incomingContent)
      if existing["id"] == .null, incoming["id"] != .null {
        existing["id"] = incoming["id"]
      }
      if let signature = incoming["signature"], signature != .null {
        existing["signature"] = signature
      }
      reasoningDetails[existingIndex] = .object(existing)
    }
  }

  var progress: RemoteStreamProgress {
    RemoteStreamProgress(content: completion.content)
  }

  var didFinish: Bool { stopReason != nil }

  var completion: RemoteCompletion {
    RemoteCompletion(
      text: text, toolCalls: toolCalls, usage: usage,
      thinking: thinking, stopReason: stopReason)
  }

  private var thinking: RemoteThinking? {
    guard !reasoning.isEmpty || !reasoningDetails.isEmpty else { return nil }
    return RemoteThinking(
      text: reasoning.isEmpty ? nil : reasoning,
      providerMetadata: reasoningDetails.isEmpty ? nil : reasoningDetails)
  }

  private var toolCalls: [RemoteToolCall] {
    toolCallsByIndex.keys.sorted().compactMap { index in
      guard let partial = toolCallsByIndex[index] else { return nil }
      return RemoteToolCall(
        id: partial.id, name: partial.name, arguments: partial.arguments)
    }
  }
}

private struct StreamRecord: Decodable {
  struct ProviderError: Decodable {
    var message: String
    var statusCode: Int?

    private enum CodingKeys: String, CodingKey {
      case message
      case statusCode = "status_code"
      case code
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      message = (try? container.decode(String.self, forKey: .message)) ?? "Unknown provider error"
      statusCode = try? container.decode(Int.self, forKey: .statusCode)
      if statusCode == nil {
        statusCode = try? container.decode(Int.self, forKey: .code)
      }
    }
  }

  struct Choice: Decodable {
    struct Delta: Decodable {
      struct ToolCallDelta: Decodable {
        struct FunctionDelta: Decodable {
          var name: String?
          var arguments: ArgumentFragment?
        }

        var index: Int
        var id: String?
        var function: FunctionDelta?
      }

      var content: String?
      var reasoning: String?
      var reasoningContent: String?
      var reasoningDetails: [RemoteJSONValue]?
      var toolCalls: [ToolCallDelta]?

      private enum CodingKeys: String, CodingKey {
        case content
        case reasoning
        case reasoningContent = "reasoning_content"
        case reasoningDetails = "reasoning_details"
        case toolCalls = "tool_calls"
      }
    }

    var index: Int
    var delta: Delta
    var finishReason: String?

    private enum CodingKeys: String, CodingKey {
      case index
      case delta
      case finishReason = "finish_reason"
    }
  }

  var choices: [Choice]?
  var usage: RemoteUsage?
  var error: ProviderError?
}

private struct ArgumentFragment: Decodable {
  var text: String

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self) {
      text = string
      return
    }
    let value = try container.decode(RemoteJSONValue.self)
    guard let text = value.compactJSONString else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid arguments")
    }
    self.text = text
  }
}
