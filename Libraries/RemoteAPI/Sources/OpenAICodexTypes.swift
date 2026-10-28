import Foundation

struct OpenAIResponsesRequest: Encodable {
  struct Reasoning: Encodable {
    var context = "all_turns"
    var effort: RemoteReasoningEffort?
  }

  var model: String
  var instructions: String
  var input: [OpenAIResponsesInputItem]
  var tools: [OpenAIResponsesTool]?
  var toolChoice: String?
  var parallelToolCalls: Bool?
  var maxOutputTokens: Int?
  var store = false
  var stream = true
  var include = ["reasoning.encrypted_content"]
  var reasoning: Reasoning

  init(
    model: String, transcript: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    currentModel: RemoteModelIdentity, maximumOutputTokens: Int?,
    reasoningEffort: RemoteReasoningEffort?
  ) {
    self.model = model
    instructions = transcript.filter { $0.role == .system }.compactMap(\.text)
      .joined(separator: "\n\n")
    input = OpenAIResponsesInputItem.convert(
      transcript.filter { $0.role != .system }, currentModel: currentModel)
    self.tools = tools.isEmpty ? nil : tools.map(OpenAIResponsesTool.init)
    toolChoice = tools.isEmpty ? nil : "auto"
    parallelToolCalls = tools.isEmpty ? nil : false
    maxOutputTokens = maximumOutputTokens
    reasoning = Reasoning(effort: reasoningEffort)
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case instructions
    case input
    case tools
    case toolChoice = "tool_choice"
    case parallelToolCalls = "parallel_tool_calls"
    case maxOutputTokens = "max_output_tokens"
    case store
    case stream
    case include
    case reasoning
  }
}

struct OpenAIResponsesTool: Encodable {
  var type = "function"
  var name: String
  var description: String
  var parameters: RemoteJSONValue
  var strict = false

  init(_ tool: RemoteFunctionTool) {
    name = tool.name
    description = tool.description
    parameters = tool.parameters
  }
}

enum OpenAIResponsesInputItem: Encodable {
  struct Content: Encodable {
    var type: String
    var text: String?
    var imageURL: String?

    private enum CodingKeys: String, CodingKey {
      case type
      case text
      case imageURL = "image_url"
    }
  }

  case message(id: String?, role: String, content: [Content], status: String?)
  case providerItem(RemoteJSONValue)
  case functionCall(id: String?, callID: String, name: String, arguments: String)
  case functionCallOutput(callID: String, output: String)

  static func convert(
    _ transcript: [RemoteTranscriptEntry], currentModel: RemoteModelIdentity
  ) -> [OpenAIResponsesInputItem] {
    var items = [OpenAIResponsesInputItem]()
    var pendingImages = [OpenAIResponsesInputItem]()
    for (entryIndex, entry) in transcript.enumerated() {
      // Function call outputs carry text only, so a tool's images follow its batch of outputs
      // as a user message, as OpenAI-compatible requests do.
      if entry.role != .toolResult {
        items += pendingImages
        pendingImages.removeAll()
      }
      switch entry.role {
      case .user:
        let text = entry.text ?? ""
        items.append(
          .message(
            id: nil, role: "user",
            content: (text.isEmpty && !entry.images.isEmpty
              ? [] : [.init(type: "input_text", text: text)]) + entry.images.map(Content.init),
            status: nil))
      case .assistant:
        if entry.source == currentModel, let outputItems = entry.providerOutputItems,
          !outputItems.isEmpty
        {
          items += outputItems.map(OpenAIResponsesInputItem.providerItem)
          continue
        }
        var textIndex = 0
        for block in entry.content {
          switch block {
          case .thinking(let thinking):
            guard entry.source == currentModel else { continue }
            items += (thinking.providerMetadata ?? []).compactMap { item in
              item.objectString(for: "type") == "reasoning" ? .providerItem(item) : nil
            }
          case .text(let text):
            guard !text.isEmpty else { continue }
            let id = "msg_localcode_\(entryIndex)_\(textIndex)"
            textIndex += 1
            items.append(
              .message(
                id: id, role: "assistant",
                content: [.init(type: "output_text", text: text)], status: "completed"))
          case .toolCall(let call):
            let itemID =
              entry.source == currentModel
              ? call.providerMetadata?.first?.objectString(for: "item_id") : nil
            items.append(
              .functionCall(
                id: itemID, callID: call.id, name: call.name, arguments: call.arguments))
          case .toolResult, .image:
            break
          }
        }
      case .toolResult:
        for result in entry.toolResults {
          items.append(.functionCallOutput(callID: result.toolCallID, output: result.content))
          if !result.images.isEmpty {
            pendingImages.append(
              .message(
                id: nil, role: "user",
                content: [
                  .init(
                    type: "input_text",
                    text:
                      "Images returned by tool \(result.toolName) (call_id: \(result.toolCallID)):")
                ] + result.images.map(Content.init), status: nil))
          }
        }
      case .system:
        break
      }
    }
    return items + pendingImages
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case id
    case role
    case content
    case status
    case callID = "call_id"
    case name
    case arguments
    case output
  }

  func encode(to encoder: Encoder) throws {
    switch self {
    case .providerItem(let item):
      try item.encode(to: encoder)
    case .message(let id, let role, let content, let status):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("message", forKey: .type)
      try container.encodeIfPresent(id, forKey: .id)
      try container.encode(role, forKey: .role)
      try container.encode(content, forKey: .content)
      try container.encodeIfPresent(status, forKey: .status)
    case .functionCall(let id, let callID, let name, let arguments):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("function_call", forKey: .type)
      try container.encodeIfPresent(id, forKey: .id)
      try container.encode(callID, forKey: .callID)
      try container.encode(name, forKey: .name)
      try container.encode(arguments, forKey: .arguments)
    case .functionCallOutput(let callID, let output):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("function_call_output", forKey: .type)
      try container.encode(callID, forKey: .callID)
      try container.encode(output, forKey: .output)
    }
  }
}

extension OpenAIResponsesInputItem.Content {
  init(_ image: RemoteImage) {
    self.init(type: "input_image", imageURL: image.dataURL)
  }
}

extension RemoteJSONValue {
  func objectString(for key: String) -> String? {
    guard case .object(let object) = self, case .string(let value) = object[key] else {
      return nil
    }
    return value
  }
}
