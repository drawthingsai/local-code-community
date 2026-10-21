import Foundation

struct OpenAICompatibleToolCall: Encodable {
  struct Function: Encodable {
    var name: String
    var arguments: String
  }

  var id: String
  var type = "function"
  var function: Function

  init(_ call: RemoteToolCall) {
    id = call.id
    function = Function(name: call.name, arguments: call.arguments)
  }
}

struct OpenAICompatibleMessage: Encodable {
  enum Role: String, Encodable {
    case system
    case user
    case assistant
    case tool
  }

  var role: Role
  var content: String?
  var images: [RemoteImage] = []
  var toolCalls: [OpenAICompatibleToolCall]?
  var toolCallID: String?
  var reasoningContent: String?
  var reasoningDetails: [RemoteJSONValue]?

  static func convert(
    _ entries: [RemoteTranscriptEntry], currentModel: RemoteModelIdentity,
    supportsReasoningFields: Bool
  ) -> [OpenAICompatibleMessage] {
    var messages = [OpenAICompatibleMessage]()
    var pendingImages = [OpenAICompatibleMessage]()
    for entry in entries {
      // Keep every tool response adjacent to its assistant tool calls. OpenRouter's
      // portable image format is a user message, appended after the tool results.
      if entry.role != .toolResult {
        messages += pendingImages
        pendingImages.removeAll()
      }
      switch entry.role {
      case .system:
        messages.append(OpenAICompatibleMessage(role: .system, content: entry.text ?? ""))
      case .user:
        messages.append(
          OpenAICompatibleMessage(role: .user, content: entry.text ?? "", images: entry.images))
      case .assistant:
        let mayReplayThinking = supportsReasoningFields && entry.source == currentModel
        let candidateMetadata =
          mayReplayThinking
          ? entry.thinking.flatMap { $0.providerMetadata ?? [] }
          : []
        let metadata =
          candidateMetadata.allSatisfy(\.isValidOpenRouterReasoningDetail)
          ? candidateMetadata : []
        let message = OpenAICompatibleMessage(
          role: .assistant, content: entry.text,
          toolCalls: entry.toolCalls.isEmpty
            ? nil : entry.toolCalls.map(OpenAICompatibleToolCall.init),
          reasoningContent: metadata.isEmpty && mayReplayThinking ? entry.thinkingText : nil,
          reasoningDetails: metadata.isEmpty ? nil : metadata)
        guard
          message.content != nil || message.toolCalls != nil
            || message.reasoningContent != nil || message.reasoningDetails != nil
        else { continue }
        messages.append(message)
      case .toolResult:
        for result in entry.toolResults {
          messages.append(
            OpenAICompatibleMessage(
              role: .tool, content: result.content, toolCallID: result.toolCallID))
          if !result.images.isEmpty {
            pendingImages.append(
              OpenAICompatibleMessage(
                role: .user,
                content:
                  "Images returned by tool \(result.toolName) (tool_call_id: \(result.toolCallID)):",
                images: result.images))
          }
        }
      }
    }
    return messages + pendingImages
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(role, forKey: .role)
    if images.isEmpty {
      try container.encodeIfPresent(content, forKey: .content)
    } else {
      var parts: [RemoteJSONValue] = []
      if let content, !content.isEmpty {
        parts.append(.object(["type": .string("text"), "text": .string(content)]))
      }
      parts += images.map {
        .object(["type": .string("image_url"), "image_url": .object(["url": .string($0.dataURL)])])
      }
      try container.encode(parts, forKey: .content)
    }
    try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    try container.encodeIfPresent(reasoningDetails, forKey: .reasoningDetails)
  }

  private enum CodingKeys: String, CodingKey {
    case role
    case content
    case toolCalls = "tool_calls"
    case toolCallID = "tool_call_id"
    case reasoningContent = "reasoning_content"
    case reasoningDetails = "reasoning_details"
  }
}

struct OpenAICompatibleRequest: Encodable {
  struct Reasoning: Encodable {
    var exclude = false
    var effort: RemoteReasoningEffort?
  }

  struct StreamOptions: Encodable {
    var includeUsage = true

    private enum CodingKeys: String, CodingKey {
      case includeUsage = "include_usage"
    }
  }

  var model: String
  var messages: [OpenAICompatibleMessage]
  var tools: [RemoteFunctionTool]?
  var toolChoice: String?
  var stream = true
  var streamOptions: StreamOptions?
  var maxTokens: Int?
  var maxCompletionTokens: Int?
  var reasoning: Reasoning?
  var reasoningEffort: RemoteReasoningEffort?

  init(
    model: String, messages: [OpenAICompatibleMessage], tools: [RemoteFunctionTool],
    includeUsage: Bool, maximumOutputTokens: Int, usesMaxCompletionTokens: Bool,
    reasoningEffort: RemoteReasoningEffort?, usesOpenRouterReasoning: Bool
  ) {
    self.model = model
    self.messages = messages
    self.tools = tools.isEmpty ? nil : tools
    toolChoice = tools.isEmpty ? nil : "auto"
    streamOptions = includeUsage ? StreamOptions() : nil
    reasoning = usesOpenRouterReasoning ? Reasoning(effort: reasoningEffort) : nil
    self.reasoningEffort = usesOpenRouterReasoning ? nil : reasoningEffort
    if usesMaxCompletionTokens {
      maxTokens = nil
      maxCompletionTokens = maximumOutputTokens
    } else {
      maxTokens = maximumOutputTokens
      maxCompletionTokens = nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case messages
    case tools
    case toolChoice = "tool_choice"
    case stream
    case streamOptions = "stream_options"
    case maxTokens = "max_tokens"
    case maxCompletionTokens = "max_completion_tokens"
    case reasoning
    case reasoningEffort = "reasoning_effort"
  }
}
