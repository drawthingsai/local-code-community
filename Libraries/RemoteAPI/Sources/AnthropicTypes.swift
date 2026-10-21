import Foundation

struct AnthropicRequest: Encodable {
  struct OutputConfig: Encodable {
    var effort: RemoteReasoningEffort
  }

  struct ToolChoice: Encodable {
    var type = "auto"
  }

  var model: String
  var maxTokens: Int
  var system: AnthropicSystemPrompt?
  var messages: [AnthropicMessage]
  var tools: [AnthropicTool]?
  var toolChoice: ToolChoice?
  var outputConfig: OutputConfig?
  var stream = true

  init(
    model: String, maxTokens: Int, transcript: [RemoteTranscriptEntry],
    remoteTools: [RemoteFunctionTool], currentModel: RemoteModelIdentity, usesOAuth: Bool,
    reasoningEffort: RemoteReasoningEffort?
  ) throws {
    self.model = model
    self.maxTokens = maxTokens
    let systemMessages = transcript.compactMap { entry -> String? in
      guard entry.role == .system else { return nil }
      return entry.text
    }
    let systemText = systemMessages.joined(separator: "\n\n")
    if usesOAuth {
      var blocks = [
        AnthropicSystemPrompt.Block(
          text: "You are Claude Code, Anthropic's official CLI for Claude.")
      ]
      if !systemText.isEmpty {
        blocks.append(AnthropicSystemPrompt.Block(text: systemText))
      }
      system = .blocks(blocks)
    } else {
      system = systemText.isEmpty ? nil : .text(systemText)
    }
    messages = try AnthropicMessage.convert(
      transcript.filter { $0.role != .system }, currentModel: currentModel,
      usesOAuth: usesOAuth)
    if remoteTools.isEmpty {
      tools = nil
      toolChoice = nil
    } else {
      tools = remoteTools.map { AnthropicTool($0, usesOAuth: usesOAuth) }
      toolChoice = ToolChoice()
    }
    outputConfig = reasoningEffort.map(OutputConfig.init)
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case maxTokens = "max_tokens"
    case system
    case messages
    case tools
    case toolChoice = "tool_choice"
    case outputConfig = "output_config"
    case stream
  }
}

enum AnthropicSystemPrompt: Encodable {
  struct Block: Encodable {
    var type = "text"
    var text: String
  }

  case text(String)
  case blocks([Block])

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .text(let text): try container.encode(text)
    case .blocks(let blocks): try container.encode(blocks)
    }
  }
}

enum AnthropicToolName {
  private static let canonical = Dictionary(
    uniqueKeysWithValues: [
      "Read", "Write", "Edit", "Bash", "WebFetch", "WebSearch",
    ].map { ($0.lowercased(), $0) })

  static func providerName(_ name: String, usesOAuth: Bool) -> String {
    guard usesOAuth else { return name }
    return canonical[name.lowercased()] ?? name
  }
}

struct AnthropicTool: Encodable {
  var name: String
  var description: String
  var inputSchema: RemoteJSONValue

  init(_ tool: RemoteFunctionTool, usesOAuth: Bool) {
    name = AnthropicToolName.providerName(tool.name, usesOAuth: usesOAuth)
    description = tool.description
    inputSchema = tool.parameters
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case inputSchema = "input_schema"
  }
}

struct AnthropicMessage: Encodable {
  enum Role: String, Encodable {
    case user
    case assistant
  }

  var role: Role
  var content: [AnthropicContentBlock]

  static func convert(
    _ transcript: [RemoteTranscriptEntry], currentModel: RemoteModelIdentity, usesOAuth: Bool
  ) throws -> [AnthropicMessage] {
    var converted = [AnthropicMessage]()
    var pendingToolResults = [AnthropicContentBlock]()
    for entry in transcript {
      if entry.role == .toolResult {
        guard !entry.toolResults.isEmpty else {
          throw RemoteChatError.malformedStream(
            "a tool transcript entry has no tool result")
        }
        pendingToolResults += entry.toolResults.map {
          .toolResult(id: $0.toolCallID, content: $0.content, isError: $0.isError)
        }
        continue
      }
      if !pendingToolResults.isEmpty {
        converted.append(AnthropicMessage(role: .user, content: pendingToolResults))
        pendingToolResults = []
      }
      switch entry.role {
      case .user:
        converted.append(
          AnthropicMessage(role: .user, content: [.text(entry.text ?? "")]))
      case .assistant:
        var content = [AnthropicContentBlock]()
        for block in entry.content {
          switch block {
          case .text(let text):
            guard !text.isEmpty else { continue }
            content.append(.text(text))
          case .thinking(let thinking) where entry.source == currentModel:
            if let data = thinking.redactedData, !data.isEmpty {
              content.append(.redactedThinking(data: data))
            } else if let signature = thinking.signature, !signature.isEmpty {
              content.append(.thinking(text: thinking.text ?? "", signature: signature))
            }
          case .toolCall(let call):
            guard let data = call.arguments.data(using: .utf8) else {
              throw RemoteChatError.malformedStream(
                "Claude tool arguments must be valid UTF-8 JSON")
            }
            let input = try JSONDecoder().decode(RemoteJSONValue.self, from: data)
            guard case .object = input else {
              throw RemoteChatError.malformedStream(
                "Claude tool arguments must be a valid JSON object")
            }
            content.append(
              .toolUse(
                id: call.id, name: AnthropicToolName.providerName(call.name, usesOAuth: usesOAuth),
                input: input))
          case .thinking, .toolResult, .image:
            break
          }
        }
        if !content.isEmpty {
          converted.append(AnthropicMessage(role: .assistant, content: content))
        }
      case .system, .toolResult:
        break
      }
    }
    if !pendingToolResults.isEmpty {
      converted.append(AnthropicMessage(role: .user, content: pendingToolResults))
    }
    return converted
  }
}

enum AnthropicContentBlock: Encodable {
  case text(String)
  case thinking(text: String, signature: String)
  case redactedThinking(data: String)
  case toolUse(id: String, name: String, input: RemoteJSONValue)
  case toolResult(id: String, content: String, isError: Bool)

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case thinking
    case signature
    case data
    case id
    case name
    case input
    case toolUseID = "tool_use_id"
    case content
    case isError = "is_error"
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .thinking(let text, let signature):
      try container.encode("thinking", forKey: .type)
      try container.encode(text, forKey: .thinking)
      try container.encode(signature, forKey: .signature)
    case .redactedThinking(let data):
      try container.encode("redacted_thinking", forKey: .type)
      try container.encode(data, forKey: .data)
    case .toolUse(let id, let name, let input):
      try container.encode("tool_use", forKey: .type)
      try container.encode(id, forKey: .id)
      try container.encode(name, forKey: .name)
      try container.encode(input, forKey: .input)
    case .toolResult(let id, let content, let isError):
      try container.encode("tool_result", forKey: .type)
      try container.encode(id, forKey: .toolUseID)
      try container.encode(content, forKey: .content)
      if isError {
        try container.encode(true, forKey: .isError)
      }
    }
  }
}
