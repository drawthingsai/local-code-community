import Foundation
import ModelZoo
import ProjectHistoryManager
import RemoteAPI

enum RemoteConversationCodec {
  enum ConversionError: LocalizedError {
    case unsupportedModel(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedModel(let model):
        return "The conversation cannot be converted for unsupported on-device model \(model)."
      }
    }
  }

  static func remoteMessages(
    from history: [ProjectHistoryNode], model: String,
    parseLogTokens: ([Int32]) -> [AgentTranscriptEntry]
  ) throws -> [RemoteTranscriptEntry] {
    try validate(model: model)
    let source = RemoteModelIdentity(provider: "local", model: model)
    var messages = [RemoteTranscriptEntry]()
    for node in history {
      switch node.role {
      case .memory:
        continue
      case .user:
        messages.append(.user(node.plaintext ?? decodedVisibleText(node.tokens, model: model)))
      case .assistant:
        let visible =
          node.plaintext
          ?? decodedVisibleAssistantText(node.tokens, model: model)
        if !node.logTokens.isEmpty {
          var decodedMessages = remoteMessages(
            from: parseLogTokens(node.logTokens), model: model,
            idPrefix: "local-\(node.threadId)-\(node.datetime)")
          if decodedMessages.first?.role == .user, messages.last?.role == .user {
            decodedMessages.removeFirst()
          }
          if let finalAssistantIndex = decodedMessages.lastIndex(where: {
            $0.role == .assistant && $0.toolCalls.isEmpty
          }) {
            if !visible.isEmpty {
              decodedMessages[finalAssistantIndex] = decodedMessages[finalAssistantIndex]
                .replacingText(with: visible)
            }
          } else if !visible.isEmpty {
            decodedMessages.append(.assistant(visible, source: source))
          }
          if !decodedMessages.isEmpty {
            messages += decodedMessages
            continue
          }
        }

        let calls = node.toolCalls.map { toolCall in
          AgentTranscriptToolCall(
            function: toolCall.function ?? "",
            parameters: Dictionary(
              uniqueKeysWithValues: toolCall.parameters.compactMap { parameter in
                guard let name = parameter.name, let value = parameter.value else { return nil }
                return (
                  name, AgentTranscriptToolCall.Parameter(string: true, value: value)
                )
              }))
        }.filter { !$0.function.isEmpty }
        if !calls.isEmpty {
          messages += remoteMessages(
            from: [
              .assistant(text: "", thinking: "", toolCalls: calls),
              .toolResults(
                calls.map { _ in
                  AgentTranscriptToolResult(
                    content:
                      "[The corresponding on-device tool result could not be decoded during model switching.]",
                    isError: true)
                }),
            ], model: model, idPrefix: "local-\(node.threadId)-\(node.datetime)")
        }
        if !visible.isEmpty || !calls.isEmpty {
          messages.append(
            .assistant(
              visible.isEmpty
                ? "[The on-device assistant completed without visible text.]" : visible,
              source: source))
        }
      }
    }
    return messages
  }

  static func remoteMessages(
    from transcript: [AgentTranscriptEntry], model: String, idPrefix: String
  ) -> [RemoteTranscriptEntry] {
    let source = RemoteModelIdentity(provider: "local", model: model)
    var messages = [RemoteTranscriptEntry]()
    var pendingCalls = [RemoteToolCall]()
    var nextCallIdentifier = 0
    for entry in transcript {
      switch entry {
      case .user(let text):
        if !pendingCalls.isEmpty {
          appendMissingResults(for: pendingCalls, to: &messages)
          pendingCalls.removeAll(keepingCapacity: true)
        }
        messages.append(.user(text))
      case .assistant(let text, let thinking, let toolCalls):
        if !pendingCalls.isEmpty {
          appendMissingResults(for: pendingCalls, to: &messages)
          pendingCalls.removeAll(keepingCapacity: true)
        }
        let calls = toolCalls.map { call in
          defer { nextCallIdentifier += 1 }
          return RemoteToolCall(
            id: "\(idPrefix)-\(nextCallIdentifier)", name: call.function,
            arguments: encodedArguments(call.parameters))
        }
        messages.append(
          .assistant(
            text.isEmpty ? nil : text,
            thinking: thinking.isEmpty ? nil : RemoteThinking(text: thinking),
            toolCalls: calls, source: source))
        pendingCalls = calls
      case .toolResults(let results):
        guard !pendingCalls.isEmpty else { continue }
        for (index, call) in pendingCalls.enumerated() {
          let result =
            index < results.count
            ? results[index]
            : AgentTranscriptToolResult(
              content:
                "[The corresponding on-device tool result could not be decoded during model switching.]",
              isError: true)
          messages.append(
            .toolResult(
              result.content, toolCallID: call.id, toolName: call.name,
              isError: result.isError))
        }
        pendingCalls.removeAll(keepingCapacity: true)
      }
    }
    if !pendingCalls.isEmpty {
      appendMissingResults(for: pendingCalls, to: &messages)
    }
    return messages
  }

  private static func validate(model: String) throws {
    guard LLMZoo.specificationForModel(model) != nil else {
      throw ConversionError.unsupportedModel(model)
    }
  }

  private static func decodedVisibleText(_ tokens: [Int32], model: String) -> String {
    guard let specification = LLMZoo.specificationForModel(model) else { return "" }
    switch specification.version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      return Qwen3_5TextGenerator.safeTokenizer.decode(tokens)
    case .deepseek_4_flash:
      return DeepSeek4TextGenerator.safeTokenizer.decode(tokens)
    case .deepseek_4_1_flash:
      return DeepSeek4_1TextGenerator.safeTokenizer.decode(tokens)
    }
  }

  private static func decodedVisibleAssistantText(_ tokens: [Int32], model: String) -> String {
    guard let specification = LLMZoo.specificationForModel(model) else { return "" }
    let decoded: String
    switch specification.version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      decoded = Qwen3_5TextGenerator.safeTokenizer.decode(
        tokens, specialTokens: Qwen3_5ToolCallParser.toolCallSpecialTokens)
    case .deepseek_4_flash:
      decoded = DeepSeek4TextGenerator.safeTokenizer.decode(
        tokens, specialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens)
    case .deepseek_4_1_flash:
      decoded = DeepSeek4_1TextGenerator.safeTokenizer.decode(
        tokens, specialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens)
    }
    return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func encodedArguments(
    _ parameters: [String: AgentTranscriptToolCall.Parameter]
  ) -> String {
    var object = [String: Any]()
    for (name, parameter) in parameters {
      if parameter.string {
        object[name] = parameter.value
      } else if let data = parameter.value.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      {
        object[name] = value
      } else {
        object[name] = parameter.value
      }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let arguments = String(data: data, encoding: .utf8)
    else { return "{}" }
    return arguments
  }

  private static func appendMissingResults(
    for calls: [RemoteToolCall], to messages: inout [RemoteTranscriptEntry]
  ) {
    for call in calls {
      messages.append(
        .toolResult(
          "[The corresponding on-device tool result could not be decoded during model switching.]",
          toolCallID: call.id, toolName: call.name, isError: true))
    }
  }
}
