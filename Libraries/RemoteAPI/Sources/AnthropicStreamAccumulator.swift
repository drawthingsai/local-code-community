import Foundation

struct AnthropicStreamAccumulator {
  private struct PartialBlock {
    enum Kind {
      case text
      case thinking
      case redactedThinking
      case toolUse
      case ignored
    }

    var kind: Kind
    var text = ""
    var id = ""
    var name = ""
    var signature = ""
    var redactedData = ""
    var initialInput: RemoteJSONValue?
    var argumentFragments = ""
  }

  private var blocks = [Int: PartialBlock]()
  private let toolNames: [String: String]
  private var promptTokens: Int?
  private var completionTokens: Int?
  private var stopReason: String?

  init(toolNames: [String: String] = [:]) {
    self.toolNames = toolNames
  }

  mutating func append(_ payload: String) throws -> (
    progress: RemoteStreamProgress?, didComplete: Bool
  ) {
    guard let data = payload.data(using: .utf8) else {
      throw RemoteChatError.malformedStream("event data is not valid UTF-8")
    }
    let record: AnthropicStreamRecord
    do {
      record = try JSONDecoder().decode(AnthropicStreamRecord.self, from: data)
    } catch {
      throw RemoteChatError.malformedStream(
        "invalid Claude event JSON near \(String(payload.prefix(256)))")
    }
    if record.type == "error", let error = record.error {
      if let statusCode = Self.statusCode(for: error.type) {
        throw RemoteChatError.provider(
          statusCode: statusCode, message: error.message)
      }
      throw RemoteChatError.providerStream(error.message)
    }

    var changed = false
    switch record.type {
    case "message_start":
      if let usage = record.message?.usage,
        usage.inputTokens != nil || usage.cacheCreationInputTokens != nil
          || usage.cacheReadInputTokens != nil
      {
        promptTokens =
          (usage.inputTokens ?? 0) + (usage.cacheCreationInputTokens ?? 0)
          + (usage.cacheReadInputTokens ?? 0)
      }
    case "content_block_start":
      guard let index = record.index, let contentBlock = record.contentBlock else {
        throw RemoteChatError.malformedStream(
          "Claude content_block_start is missing its index or content block")
      }
      switch contentBlock.type {
      case "text":
        blocks[index] = PartialBlock(kind: .text, text: contentBlock.text ?? "")
        changed = contentBlock.text?.isEmpty == false
      case "thinking":
        blocks[index] = PartialBlock(kind: .thinking, text: contentBlock.thinking ?? "")
        changed = contentBlock.thinking?.isEmpty == false
      case "redacted_thinking":
        blocks[index] = PartialBlock(
          kind: .redactedThinking, redactedData: contentBlock.data ?? "")
        changed = contentBlock.data?.isEmpty == false
      case "tool_use":
        guard let id = contentBlock.id, let name = contentBlock.name else {
          throw RemoteChatError.malformedStream(
            "Claude tool_use block is missing its ID or name")
        }
        blocks[index] = PartialBlock(
          kind: .toolUse, id: id, name: toolNames[name.lowercased()] ?? name,
          initialInput: contentBlock.input)
        changed = true
      default:
        blocks[index] = PartialBlock(kind: .ignored)
      }
    case "content_block_delta":
      guard let index = record.index, let delta = record.delta else {
        throw RemoteChatError.malformedStream(
          "Claude content_block_delta is missing its index or delta")
      }
      switch delta.type {
      case "text_delta":
        guard var block = blocks[index], block.kind == .text else {
          throw RemoteChatError.malformedStream(
            "Claude sent text for an unknown content block")
        }
        block.text += delta.text ?? ""
        blocks[index] = block
        changed = delta.text?.isEmpty == false
      case "input_json_delta":
        guard var block = blocks[index], block.kind == .toolUse else {
          throw RemoteChatError.malformedStream(
            "Claude sent tool input for an unknown content block")
        }
        block.argumentFragments += delta.partialJSON ?? ""
        blocks[index] = block
        changed = delta.partialJSON?.isEmpty == false
      case "thinking_delta":
        guard var block = blocks[index], block.kind == .thinking else {
          throw RemoteChatError.malformedStream(
            "Claude sent thinking for an unknown content block")
        }
        block.text += delta.thinking ?? ""
        blocks[index] = block
        changed = delta.thinking?.isEmpty == false
      case "signature_delta":
        guard var block = blocks[index], block.kind == .thinking else {
          throw RemoteChatError.malformedStream(
            "Claude sent a signature for an unknown content block")
        }
        block.signature += delta.signature ?? ""
        blocks[index] = block
      default:
        break
      }
    case "content_block_stop":
      guard let index = record.index, let block = blocks[index] else {
        throw RemoteChatError.malformedStream(
          "Claude stopped an unknown content block")
      }
      if block.kind == .toolUse {
        _ = try arguments(for: block)
      }
    case "message_delta":
      if let reason = record.delta?.stopReason {
        stopReason = reason
      }
      if let outputTokens = record.usage?.outputTokens {
        completionTokens = outputTokens
      }
    case "message_stop":
      for block in blocks.values where block.kind == .toolUse {
        _ = try arguments(for: block)
      }
      return (changed ? progress : nil, true)
    default:
      break
    }
    return (changed ? progress : nil, false)
  }

  var completion: RemoteCompletion {
    RemoteCompletion(content: content, usage: usage, stopReason: stopReason)
  }

  private var progress: RemoteStreamProgress {
    RemoteStreamProgress(content: content)
  }

  private var content: [RemoteContentBlock] {
    blocks.keys.sorted().compactMap { index in
      guard let block = blocks[index] else { return nil }
      switch block.kind {
      case .text:
        return .text(block.text)
      case .thinking:
        return .thinking(
          RemoteThinking(
            text: block.text.isEmpty ? nil : block.text,
            signature: block.signature.isEmpty ? nil : block.signature))
      case .redactedThinking:
        return .thinking(RemoteThinking(redactedData: block.redactedData))
      case .toolUse:
        return .toolCall(
          RemoteToolCall(id: block.id, name: block.name, arguments: serializedArguments(for: block))
        )
      case .ignored:
        return nil
      }
    }
  }

  private var usage: RemoteUsage? {
    guard promptTokens != nil || completionTokens != nil else { return nil }
    let totalTokens: Int?
    if let promptTokens, let completionTokens {
      totalTokens = promptTokens + completionTokens
    } else {
      totalTokens = nil
    }
    return RemoteUsage(
      promptTokens: promptTokens, completionTokens: completionTokens, totalTokens: totalTokens)
  }

  private func arguments(for block: PartialBlock) throws -> String {
    let arguments = serializedArguments(for: block)
    guard let data = arguments.data(using: .utf8),
      case .object = try JSONDecoder().decode(RemoteJSONValue.self, from: data)
    else {
      throw RemoteChatError.malformedStream(
        "Claude tool arguments are not a complete JSON object")
    }
    return arguments
  }

  private func serializedArguments(for block: PartialBlock) -> String {
    block.argumentFragments.isEmpty
      ? block.initialInput?.compactJSONString ?? "{}" : block.argumentFragments
  }

  private static func statusCode(for errorType: String) -> Int? {
    switch errorType {
    case "invalid_request_error":
      return 400
    case "authentication_error":
      return 401
    case "billing_error":
      return 402
    case "permission_error":
      return 403
    case "not_found_error":
      return 404
    case "rate_limit_error":
      return 429
    case "api_error":
      return 500
    case "timeout_error":
      return 504
    case "overloaded_error":
      return 529
    default:
      return nil
    }
  }
}

private struct AnthropicStreamRecord: Decodable {
  struct ContentBlock: Decodable {
    var type: String
    var text: String?
    var thinking: String?
    var data: String?
    var id: String?
    var name: String?
    var input: RemoteJSONValue?
  }

  struct Delta: Decodable {
    var type: String?
    var text: String?
    var thinking: String?
    var signature: String?
    var partialJSON: String?
    var stopReason: String?

    private enum CodingKeys: String, CodingKey {
      case type
      case text
      case thinking
      case signature
      case partialJSON = "partial_json"
      case stopReason = "stop_reason"
    }
  }

  struct Usage: Decodable {
    var inputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
    var outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case cacheCreationInputTokens = "cache_creation_input_tokens"
      case cacheReadInputTokens = "cache_read_input_tokens"
      case outputTokens = "output_tokens"
    }
  }

  struct Message: Decodable {
    var usage: Usage?
  }

  struct ProviderError: Decodable {
    var type: String
    var message: String
  }

  var type: String
  var index: Int?
  var contentBlock: ContentBlock?
  var delta: Delta?
  var usage: Usage?
  var message: Message?
  var error: ProviderError?

  private enum CodingKeys: String, CodingKey {
    case type
    case index
    case contentBlock = "content_block"
    case delta
    case usage
    case message
    case error
  }
}
