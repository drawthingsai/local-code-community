import Foundation

/// Builds one assistant message, whose thinking, text and tool calls each have a field of their own.
/// A streaming request gets chunks of their deltas; any other gets the finished object at the end.
final class ChatCompletionsResponseWriter: ResponseWriter {
  private let transport: ResponsesTransport
  private let isStreaming: Bool
  private let includesUsage: Bool
  private let model: String
  private let identifier = "chatcmpl-" + ChatCompletionsResponseWriter.randomIdentifier()
  private let createdAt = Int(Date().timeIntervalSince1970)
  private var didStart = false
  private var didStartTurn = false
  private var didFinish = false
  private var reasoning = ""
  private var text = ""
  private var toolCalls = [[String: Any]]()

  init(transport: ResponsesTransport, isStreaming: Bool, includesUsage: Bool, model: String) {
    self.transport = transport
    self.isStreaming = isStreaming
    self.includesUsage = includesUsage
    self.model = model
  }

  func start() {
    guard !didStart else { return }
    didStart = true
    guard isStreaming else { return }
    transport.beginEventStream()
  }

  func startTurn(inputTokens: Int, cachedInputTokens: Int) {
    start()
    guard !didStartTurn else { return }
    didStartTurn = true
    emit(["role": "assistant", "content": ""])
  }

  /// In `reasoning_content`, the field most clients read the thinking from.
  func appendReasoning(_ delta: String) {
    guard !delta.isEmpty else { return }
    reasoning += delta
    emit(["reasoning_content": delta])
  }

  func appendText(_ delta: String) {
    guard !delta.isEmpty else { return }
    text += delta
    emit(["content": delta])
  }

  func appendFunctionCall(name: String, arguments: String) {
    let toolCall: [String: Any] = [
      "id": "call_" + Self.randomIdentifier(), "type": "function",
      "function": ["name": name, "arguments": arguments],
    ]
    var delta = toolCall
    delta["index"] = toolCalls.count
    toolCalls.append(toolCall)
    emit(["tool_calls": [delta]])
  }

  func finish(usage: ResponseUsage, incompleteReason: String?) {
    guard !didFinish else { return }
    didFinish = true
    let finishReason =
      incompleteReason != nil ? "length" : toolCalls.isEmpty ? "stop" : "tool_calls"
    let usageObject: [String: Any] = [
      "prompt_tokens": usage.inputTokens,
      "prompt_tokens_details": ["cached_tokens": usage.cachedInputTokens],
      "completion_tokens": usage.outputTokens,
      "completion_tokens_details": ["reasoning_tokens": usage.reasoningTokens],
      "total_tokens": usage.inputTokens + usage.outputTokens,
    ]
    if isStreaming {
      emit([String: Any](), finishReason: finishReason)
      if includesUsage {
        send(chunk(choices: [], usage: usageObject))
      }
      transport.sendEvent(name: nil, data: Data("[DONE]".utf8))
      transport.close()
      return
    }
    var message: [String: Any] = [
      "role": "assistant", "content": text.isEmpty && !toolCalls.isEmpty ? NSNull() as Any : text,
    ]
    if !reasoning.isEmpty {
      message["reasoning_content"] = reasoning
    }
    if !toolCalls.isEmpty {
      message["tool_calls"] = toolCalls
    }
    let completion: [String: Any] = [
      "id": identifier, "object": "chat.completion", "created": createdAt, "model": model,
      "choices": [
        ["index": 0, "message": message, "finish_reason": finishReason, "logprobs": NSNull()]
      ],
      "usage": usageObject,
    ]
    transport.respond(
      status: 200, contentType: "application/json", body: Self.data(completion) ?? Data())
  }

  /// Its errors look like Responses'.
  func fail(status: Int, type: String, code: String, message: String) {
    guard !didFinish else { return }
    didFinish = true
    let body = ResponsesResponseWriter.errorBody(type: type, code: code, message: message)
    if isStreaming, didStart {
      transport.sendEvent(name: nil, data: body)
      transport.close()
    } else {
      transport.respond(status: status, contentType: "application/json", body: body)
    }
  }

  func abandon() {
    guard !didFinish else { return }
    didFinish = true
    transport.close()
  }

  private func emit(_ delta: [String: Any], finishReason: String? = nil) {
    guard isStreaming else { return }
    send(
      chunk(
        choices: [
          [
            "index": 0, "delta": delta, "finish_reason": finishReason.map { $0 as Any } ?? NSNull(),
            "logprobs": NSNull(),
          ]
        ], usage: nil))
  }

  private func chunk(choices: [[String: Any]], usage: [String: Any]?) -> [String: Any] {
    [
      "id": identifier, "object": "chat.completion.chunk", "created": createdAt, "model": model,
      "choices": choices, "usage": usage.map { $0 as Any } ?? NSNull(),
    ]
  }

  private func send(_ chunk: [String: Any]) {
    guard let data = Self.data(chunk) else { return }
    transport.sendEvent(name: nil, data: data)
  }
}
