import Foundation

/// Where a response goes. `StreamingHTTPConnection` is the real one.
protocol ResponsesTransport: AnyObject {
  var isDisconnected: Bool { get }
  func respond(status: Int, contentType: String, body: Data)
  func beginEventStream()
  /// An event without a name is only its data, as Chat Completions sends them.
  func sendEvent(name: String?, data: Data)
  func sendKeepAlive()
  func close()
}

extension StreamingHTTPConnection: ResponsesTransport {}

/// Input tokens include the cached ones, and output tokens the reasoning ones.
struct ResponseUsage: Equatable {
  var inputTokens: Int
  var cachedInputTokens: Int
  var outputTokens: Int
  var reasoningTokens: Int
}

/// Writes one response in a wire protocol's terms, from what the model produces in order.
protocol ResponseWriter: AnyObject {
  /// On arrival, so a stream starts however long the queue is. Later errors go in the stream.
  func start()
  /// Once the conversation is tokenized and the model is about to take it.
  func startTurn(inputTokens: Int, cachedInputTokens: Int)
  func appendReasoning(_ delta: String)
  func appendText(_ delta: String)
  func appendFunctionCall(name: String, arguments: String)
  /// `incompleteReason` is nil when the model got to finish.
  func finish(usage: ResponseUsage, incompleteReason: String?)
  func fail(status: Int, type: String, code: String, message: String)
  /// For a client that left, which is told nothing.
  func abandon()
}

/// Builds one response in order: thinking, then text, then function calls. A streaming request
/// gets each step as its event; any other gets the finished object at the end.
final class ResponsesResponseWriter: ResponseWriter {
  private enum OpenItem {
    case reasoning(id: String, text: String)
    case message(id: String, text: String)
  }

  private let transport: ResponsesTransport
  private let isStreaming: Bool
  private let model: String
  private let identifier = "resp_" + ResponsesResponseWriter.randomIdentifier()
  private let createdAt = Int(Date().timeIntervalSince1970)
  private var sequenceNumber = 0
  private var didStart = false
  private var didFinish = false
  private var output = [[String: Any]]()
  private var openItem: OpenItem?

  init(transport: ResponsesTransport, isStreaming: Bool, model: String) {
    self.transport = transport
    self.isStreaming = isStreaming
    self.model = model
  }

  /// Serving errors get their own status only until a stream starts.
  func start() {
    guard !didStart else { return }
    didStart = true
    guard isStreaming else { return }
    transport.beginEventStream()
    emit("response.created", ["response": responseObject(status: "in_progress")])
    emit("response.in_progress", ["response": responseObject(status: "in_progress")])
  }

  func startTurn(inputTokens: Int, cachedInputTokens: Int) {
    start()
  }

  func appendReasoning(_ delta: String) {
    guard !delta.isEmpty else { return }
    let id: String
    let text: String
    if case .reasoning(let openID, let openText)? = openItem {
      (id, text) = (openID, openText)
    } else {
      closeOpenItem()
      id = "rs_" + Self.randomIdentifier()
      text = ""
      emit(
        "response.output_item.added",
        [
          "output_index": output.count,
          "item": reasoningObject(id: id, text: "", status: "in_progress"),
        ])
    }
    openItem = .reasoning(id: id, text: text + delta)
    emit(
      "response.reasoning_text.delta",
      ["item_id": id, "output_index": output.count, "content_index": 0, "delta": delta])
  }

  func appendText(_ delta: String) {
    guard !delta.isEmpty else { return }
    let id: String
    let text: String
    if case .message(let openID, let openText)? = openItem {
      (id, text) = (openID, openText)
    } else {
      closeOpenItem()
      id = "msg_" + Self.randomIdentifier()
      text = ""
      emit(
        "response.output_item.added",
        [
          "output_index": output.count,
          "item": messageObject(id: id, text: nil, status: "in_progress"),
        ])
      emit(
        "response.content_part.added",
        [
          "item_id": id, "output_index": output.count, "content_index": 0,
          "part": ["type": "output_text", "text": "", "annotations": [Any]()],
        ])
    }
    openItem = .message(id: id, text: text + delta)
    emit(
      "response.output_text.delta",
      [
        "item_id": id, "output_index": output.count, "content_index": 0, "delta": delta,
        "logprobs": [Any](),
      ])
  }

  func appendFunctionCall(name: String, arguments: String) {
    closeOpenItem()
    let id = "fc_" + Self.randomIdentifier()
    let callID = "call_" + Self.randomIdentifier()
    let index = output.count
    var item: [String: Any] = [
      "type": "function_call", "id": id, "call_id": callID, "name": name, "arguments": "",
      "status": "in_progress",
    ]
    emit("response.output_item.added", ["output_index": index, "item": item])
    emit(
      "response.function_call_arguments.delta",
      ["item_id": id, "output_index": index, "delta": arguments])
    emit(
      "response.function_call_arguments.done",
      ["item_id": id, "output_index": index, "name": name, "arguments": arguments])
    item["arguments"] = arguments
    item["status"] = "completed"
    output.append(item)
    emit("response.output_item.done", ["output_index": index, "item": item])
  }

  func finish(usage: ResponseUsage, incompleteReason: String?) {
    guard !didFinish else { return }
    didFinish = true
    closeOpenItem()
    var response = responseObject(status: incompleteReason == nil ? "completed" : "incomplete")
    response["usage"] = [
      "input_tokens": usage.inputTokens,
      "input_tokens_details": ["cached_tokens": usage.cachedInputTokens],
      "output_tokens": usage.outputTokens,
      "output_tokens_details": ["reasoning_tokens": usage.reasoningTokens],
      "total_tokens": usage.inputTokens + usage.outputTokens,
    ]
    if let incompleteReason {
      response["incomplete_details"] = ["reason": incompleteReason]
    }
    if isStreaming {
      emit(
        incompleteReason == nil ? "response.completed" : "response.incomplete",
        ["response": response])
      transport.close()
    } else if let data = Self.data(response) {
      transport.respond(status: 200, contentType: "application/json", body: data)
    }
  }

  func fail(status: Int, type: String, code: String, message: String) {
    guard !didFinish else { return }
    didFinish = true
    if isStreaming, didStart {
      var response = responseObject(status: "failed")
      response["error"] = ["code": code, "message": message]
      emit("response.failed", ["response": response])
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

  static func errorBody(type: String, code: String, message: String, parameter: String? = nil)
    -> Data
  {
    var error: [String: Any] = ["type": type, "code": code, "message": message]
    error["param"] = parameter ?? NSNull()
    return data(["error": error]) ?? Data()
  }

  private func closeOpenItem() {
    let index = output.count
    switch openItem {
    case .reasoning(let id, let text):
      emit(
        "response.reasoning_text.done",
        ["item_id": id, "output_index": index, "content_index": 0, "text": text])
      let item = reasoningObject(id: id, text: text, status: "completed")
      output.append(item)
      emit("response.output_item.done", ["output_index": index, "item": item])
    case .message(let id, let text):
      emit(
        "response.output_text.done",
        [
          "item_id": id, "output_index": index, "content_index": 0, "text": text,
          "logprobs": [Any](),
        ])
      emit(
        "response.content_part.done",
        [
          "item_id": id, "output_index": index, "content_index": 0,
          "part": ["type": "output_text", "text": text, "annotations": [Any]()],
        ])
      let item = messageObject(id: id, text: text, status: "completed")
      output.append(item)
      emit("response.output_item.done", ["output_index": index, "item": item])
    case nil:
      break
    }
    openItem = nil
  }

  private func emit(_ name: String, _ fields: [String: Any]) {
    guard isStreaming else { return }
    var event = fields
    event["type"] = name
    event["sequence_number"] = sequenceNumber
    sequenceNumber += 1
    guard let data = Self.data(event) else { return }
    transport.sendEvent(name: name, data: data)
  }

  private func responseObject(status: String) -> [String: Any] {
    [
      "id": identifier, "object": "response", "created_at": createdAt, "status": status,
      "model": model, "output": output, "error": NSNull(), "incomplete_details": NSNull(),
      "parallel_tool_calls": true, "tool_choice": "auto", "tools": [Any](),
      "metadata": [String: Any](), "store": false, "usage": NSNull(),
    ]
  }

  /// The local models have nothing to keep secret. `encrypted_content` holds the thinking so that
  /// a client that replays only this field still sends the model back what it wrote.
  private func reasoningObject(id: String, text: String, status: String) -> [String: Any] {
    var content = [Any]()
    if !text.isEmpty {
      content.append(["type": "reasoning_text", "text": text])
    }
    return [
      "type": "reasoning", "id": id, "status": status, "summary": [Any](), "content": content,
      "encrypted_content": Data(text.utf8).base64EncodedString(),
    ]
  }

  private func messageObject(id: String, text: String?, status: String) -> [String: Any] {
    var content = [Any]()
    if let text {
      content.append(["type": "output_text", "text": text, "annotations": [Any]()])
    }
    return [
      "type": "message", "id": id, "role": "assistant", "status": status, "content": content,
    ]
  }

}

extension ResponseWriter {
  static func data(_ object: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
  }

  static func randomIdentifier() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}
