import Foundation

/// Builds one message of content blocks in order: thinking, text and tool use, each a block of its
/// own. A streaming request gets each step as its event; any other gets the finished object.
final class MessagesResponseWriter: ResponseWriter {
  private enum OpenBlock {
    case thinking(String)
    case text(String)
  }

  private let transport: ResponsesTransport
  private let isStreaming: Bool
  private let model: String
  private let identifier = "msg_" + MessagesResponseWriter.randomIdentifier()
  private var didStart = false
  private var didStartMessage = false
  private var didFinish = false
  private var content = [[String: Any]]()
  private var openBlock: OpenBlock?
  private var hasToolUse = false

  init(transport: ResponsesTransport, isStreaming: Bool, model: String) {
    self.transport = transport
    self.isStreaming = isStreaming
    self.model = model
  }

  func start() {
    guard !didStart else { return }
    didStart = true
    guard isStreaming else { return }
    transport.beginEventStream()
  }

  /// `message_start` waits for the token counts, as clients read the prompt's size from it alone.
  func startTurn(inputTokens: Int, cachedInputTokens: Int) {
    start()
    guard !didStartMessage else { return }
    didStartMessage = true
    emit(
      "message_start",
      [
        "message": messageObject(
          stopReason: nil,
          usage: Self.usageObject(
            inputTokens: inputTokens, cachedInputTokens: cachedInputTokens, outputTokens: 0))
      ])
  }

  func appendReasoning(_ delta: String) {
    guard !delta.isEmpty else { return }
    if case .thinking(let text)? = openBlock {
      openBlock = .thinking(text + delta)
    } else {
      startBlock(["type": "thinking", "thinking": "", "signature": ""])
      openBlock = .thinking(delta)
    }
    emit(
      "content_block_delta",
      ["index": content.count, "delta": ["type": "thinking_delta", "thinking": delta]])
  }

  func appendText(_ delta: String) {
    guard !delta.isEmpty else { return }
    if case .text(let text)? = openBlock {
      openBlock = .text(text + delta)
    } else {
      startBlock(["type": "text", "text": ""])
      openBlock = .text(delta)
    }
    emit(
      "content_block_delta",
      ["index": content.count, "delta": ["type": "text_delta", "text": delta]])
  }

  func appendFunctionCall(name: String, arguments: String) {
    let id = "toolu_" + Self.randomIdentifier()
    startBlock(["type": "tool_use", "id": id, "name": name, "input": [String: Any]()])
    emit(
      "content_block_delta",
      ["index": content.count, "delta": ["type": "input_json_delta", "partial_json": arguments]])
    emit("content_block_stop", ["index": content.count])
    let input =
      (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [String: Any]()
    content.append(["type": "tool_use", "id": id, "name": name, "input": input])
    hasToolUse = true
  }

  func finish(usage: ResponseUsage, incompleteReason: String?) {
    guard !didFinish else { return }
    startTurn(inputTokens: usage.inputTokens, cachedInputTokens: usage.cachedInputTokens)
    didFinish = true
    closeOpenBlock()
    let stopReason: String
    switch incompleteReason {
    case nil:
      stopReason = hasToolUse ? "tool_use" : "end_turn"
    case "max_context_length":
      stopReason = "model_context_window_exceeded"
    default:
      stopReason = "max_tokens"
    }
    let usageObject = Self.usageObject(
      inputTokens: usage.inputTokens, cachedInputTokens: usage.cachedInputTokens,
      outputTokens: usage.outputTokens)
    if isStreaming {
      emit(
        "message_delta",
        ["delta": ["stop_reason": stopReason, "stop_sequence": NSNull()], "usage": usageObject])
      emit("message_stop", [:])
      transport.close()
    } else {
      transport.respond(
        status: 200, contentType: "application/json",
        body: Self.data(messageObject(stopReason: stopReason, usage: usageObject)) ?? Data())
    }
  }

  func fail(status: Int, type: String, code: String, message: String) {
    guard !didFinish else { return }
    didFinish = true
    if isStreaming, didStart {
      emit(
        "error", ["error": ["type": Self.errorType(type: type, code: code), "message": message]])
      transport.close()
    } else {
      transport.respond(
        status: status, contentType: "application/json",
        body: Self.errorBody(type: type, code: code, message: message))
    }
  }

  func abandon() {
    guard !didFinish else { return }
    didFinish = true
    transport.close()
  }

  static func errorBody(type: String, code: String, message: String) -> Data {
    Self.data([
      "type": "error",
      "error": ["type": Self.errorType(type: type, code: code), "message": message],
    ]) ?? Data()
  }

  /// Anthropic's names for the errors the server has, which it names as OpenAI does.
  private static func errorType(type: String, code: String) -> String {
    if code == "not_found" { return "not_found_error" }
    return type == "server_error" ? "api_error" : type
  }

  /// Anthropic counts cached tokens apart from the input tokens, where OpenAI counts them among.
  private static func usageObject(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int)
    -> [String: Any]
  {
    [
      "input_tokens": inputTokens - cachedInputTokens, "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": cachedInputTokens, "output_tokens": outputTokens,
    ]
  }

  private func startBlock(_ block: [String: Any]) {
    closeOpenBlock()
    emit("content_block_start", ["index": content.count, "content_block": block])
  }

  /// The local models have nothing to sign. The signature holds the thinking, for a client that
  /// replays only that.
  private func closeOpenBlock() {
    switch openBlock {
    case .thinking(let text):
      let signature = Data(text.utf8).base64EncodedString()
      emit(
        "content_block_delta",
        ["index": content.count, "delta": ["type": "signature_delta", "signature": signature]])
      emit("content_block_stop", ["index": content.count])
      content.append(["type": "thinking", "thinking": text, "signature": signature])
    case .text(let text):
      emit("content_block_stop", ["index": content.count])
      content.append(["type": "text", "text": text])
    case nil:
      break
    }
    openBlock = nil
  }

  private func messageObject(stopReason: String?, usage: [String: Any]) -> [String: Any] {
    [
      "id": identifier, "type": "message", "role": "assistant", "model": model,
      "content": content, "stop_reason": stopReason.map { $0 as Any } ?? NSNull(),
      "stop_sequence": NSNull(), "usage": usage,
    ]
  }

  private func emit(_ name: String, _ fields: [String: Any]) {
    guard isStreaming else { return }
    var event = fields
    event["type"] = name
    guard let data = Self.data(event) else { return }
    transport.sendEvent(name: name, data: data)
  }
}
