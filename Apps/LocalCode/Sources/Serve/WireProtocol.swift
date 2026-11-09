import Foundation

/// The APIs the server speaks, each at an endpoint of its own with its own request, response and
/// errors. They all come down to the same conversation, so they share the agents and the context
/// cache, and a conversation could even move from one to another.
enum WireProtocol: CaseIterable {
  case openAIResponses
  case anthropicMessages
  case openAIChatCompletions

  var path: String {
    switch self {
    case .openAIResponses: return "/v1/responses"
    case .anthropicMessages: return "/v1/messages"
    case .openAIChatCompletions: return "/v1/chat/completions"
    }
  }

  init?(path: String) {
    guard let wireProtocol = Self.allCases.first(where: { $0.path == path }) else { return nil }
    self = wireProtocol
  }

  /// Whose errors a request to no endpoint gets. Anthropic's clients send `anthropic-version` with
  /// every request, and OpenAI's don't.
  init(headers: [String: String]) {
    self = headers["anthropic-version"] == nil ? .openAIResponses : .anthropicMessages
  }

  /// One list for every API's clients, with the fields of both OpenAI's and Anthropic's. Each
  /// ignores the other's.
  static func modelsObject(model: String?) -> [String: Any] {
    let models =
      model.map {
        [
          [
            "id": $0, "object": "model", "created": 0, "owned_by": "local", "type": "model",
            "display_name": $0, "created_at": "1970-01-01T00:00:00Z",
          ] as [String: Any]
        ]
      } ?? []
    return [
      "object": "list", "data": models, "has_more": false,
      "first_id": model.map { $0 as Any } ?? NSNull(),
      "last_id": model.map { $0 as Any } ?? NSNull(),
    ]
  }

  func request(body: Data) throws -> ResponsesRequest {
    switch self {
    case .openAIResponses: return try ResponsesRequest(body: body)
    case .anthropicMessages: return try ResponsesRequest(messagesBody: body)
    case .openAIChatCompletions: return try ResponsesRequest(chatCompletionsBody: body)
    }
  }

  func makeWriter(transport: ResponsesTransport, request: ResponsesRequest, model: String)
    -> any ResponseWriter
  {
    switch self {
    case .openAIResponses:
      return ResponsesResponseWriter(
        transport: transport, isStreaming: request.isStreaming, model: model)
    case .anthropicMessages:
      return MessagesResponseWriter(
        transport: transport, isStreaming: request.isStreaming, model: model)
    case .openAIChatCompletions:
      return ChatCompletionsResponseWriter(
        transport: transport, isStreaming: request.isStreaming,
        includesUsage: request.includesStreamUsage, model: model)
    }
  }

  func errorBody(type: String, code: String, message: String, parameter: String? = nil) -> Data {
    switch self {
    case .openAIResponses, .openAIChatCompletions:
      return ResponsesResponseWriter.errorBody(
        type: type, code: code, message: message, parameter: parameter)
    case .anthropicMessages:
      return MessagesResponseWriter.errorBody(type: type, code: code, message: message)
    }
  }
}
