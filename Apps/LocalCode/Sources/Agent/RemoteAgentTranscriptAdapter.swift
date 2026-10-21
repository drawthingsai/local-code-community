import Foundation
import RemoteAPI

enum RemoteAgentTranscriptAdapter {
  enum ConversionError: LocalizedError {
    case unexpectedToolResult
    case missingToolResult(String)
    case duplicateToolResult(String)
    case unknownToolResult(String)

    var errorDescription: String? {
      switch self {
      case .unexpectedToolResult:
        return "The remote transcript contains a tool result without a preceding tool call."
      case .missingToolResult(let identifier):
        return "The remote transcript is missing the result for tool call \(identifier)."
      case .duplicateToolResult(let identifier):
        return "The remote transcript contains more than one result for tool call \(identifier)."
      case .unknownToolResult(let identifier):
        return "The remote transcript contains a result for unknown tool call \(identifier)."
      }
    }
  }

  static func parse(_ entries: [RemoteTranscriptEntry]) throws -> [AgentTranscriptEntry] {
    var transcript = [AgentTranscriptEntry]()
    var index = entries.startIndex
    while index < entries.endIndex {
      let entry = entries[index]
      switch entry.role {
      case .system:
        index += 1
      case .user:
        transcript.append(.user(entry.text ?? ""))
        index += 1
      case .assistant:
        let calls = entry.toolCalls.map { call in
          AgentTranscriptToolCall(
            function: call.name, parameters: parameters(from: call.arguments))
        }
        transcript.append(
          .assistant(
            text: entry.text ?? "", thinking: entry.thinkingText ?? "", toolCalls: calls))
        index += 1
        guard !entry.toolCalls.isEmpty else { continue }
        let callIdentifiers = Set(entry.toolCalls.map(\.id))
        var resultsByIdentifier = [String: AgentTranscriptToolResult]()
        while index < entries.endIndex, entries[index].role == .toolResult {
          for result in entries[index].toolResults {
            guard callIdentifiers.contains(result.toolCallID) else {
              throw ConversionError.unknownToolResult(result.toolCallID)
            }
            guard resultsByIdentifier[result.toolCallID] == nil else {
              throw ConversionError.duplicateToolResult(result.toolCallID)
            }
            resultsByIdentifier[result.toolCallID] = AgentTranscriptToolResult(
              content: result.content, isError: result.isError)
          }
          index += 1
        }
        let orderedResults = try entry.toolCalls.map { call in
          guard let result = resultsByIdentifier[call.id] else {
            throw ConversionError.missingToolResult(call.id)
          }
          return result
        }
        transcript.append(.toolResults(orderedResults))
      case .toolResult:
        throw ConversionError.unexpectedToolResult
      }
    }
    return transcript
  }

  private static func parameters(
    from arguments: String
  ) -> [String: AgentTranscriptToolCall.Parameter] {
    guard let data = arguments.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      return ["arguments": AgentTranscriptToolCall.Parameter(string: true, value: arguments)]
    }
    return dictionary.mapValues { value in
      if let value = value as? String {
        return AgentTranscriptToolCall.Parameter(string: true, value: value)
      }
      if JSONSerialization.isValidJSONObject(["value": value]),
        let data = try? JSONSerialization.data(
          withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
        let value = String(data: data, encoding: .utf8)
      {
        return AgentTranscriptToolCall.Parameter(string: false, value: value)
      }
      return AgentTranscriptToolCall.Parameter(string: true, value: String(describing: value))
    }
  }
}
