import Foundation

struct AgentTranscriptToolCall: Equatable, Sendable {
  struct Parameter: Equatable, Sendable {
    var string: Bool
    var value: String
  }

  var function: String
  var parameters: [String: Parameter]
}

struct AgentTranscriptToolResult: Equatable, Sendable {
  var content: String
  var isError: Bool
}

enum AgentTranscriptEntry: Equatable, Sendable {
  case user(String)
  case assistant(
    text: String, thinking: String, toolCalls: [AgentTranscriptToolCall]
  )
  case toolResults([AgentTranscriptToolResult])
}
