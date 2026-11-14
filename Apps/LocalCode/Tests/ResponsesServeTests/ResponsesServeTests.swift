import Foundation
import Network
import ProjectHistoryManager
import XCTest

/// A PNG of one pixel.
let testImageBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
let testImage = Data(base64Encoded: testImageBase64)!

final class RecordingTransport: ResponsesTransport {
  var isDisconnected = false
  var status: Int?
  var body: Data?
  var didBeginEventStream = false
  var didClose = false
  var events = [(name: String?, object: [String: Any])]()
  /// Every event's data as text, for the ones that aren't JSON.
  var eventData = [String]()

  func respond(status: Int, contentType: String, body: Data) {
    self.status = status
    self.body = body
  }
  func beginEventStream() { didBeginEventStream = true }
  func sendEvent(name: String?, data: Data) {
    eventData.append(String(decoding: data, as: UTF8.self))
    events.append((name, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]))
  }
  func sendKeepAlive() {}
  func close() { didClose = true }
}

final class ResponsesRequestTests: XCTestCase {
  private func request(_ object: [String: Any]) throws -> ResponsesRequest {
    try ResponsesRequest(body: JSONSerialization.data(withJSONObject: object))
  }

  func testStringInputIsOneUserTurn() throws {
    let request = try request(["model": "any", "input": "Hello", "instructions": "Be brief."])
    XCTAssertEqual(request.transcript, [.user("Hello")])
    XCTAssertEqual(request.instructions, "Be brief.")
    XCTAssertFalse(request.isStreaming)
  }

  func testLeadingSystemMessagesJoinInstructionsAndLaterOnesStayInPlace() throws {
    let request = try request([
      "instructions": "A",
      "input": [
        ["role": "developer", "content": "B"],
        ["role": "user", "content": [["type": "input_text", "text": "C"]]],
        ["role": "assistant", "content": [["type": "output_text", "text": "D"]]],
        ["role": "system", "content": "E"],
      ],
    ])
    XCTAssertEqual(request.instructions, "A\n\nB")
    XCTAssertEqual(
      request.transcript,
      [.user("C"), .assistant(text: "D", thinking: "", toolCalls: []), .user("E")])
  }

  func testToolRoundTripBuildsOneAssistantTurnAndOneResultTurn() throws {
    let request = try request([
      "input": [
        ["role": "user", "content": "Weather?"],
        [
          "type": "reasoning", "summary": [Any](),
          "encrypted_content": Data("Check it.\n".utf8).base64EncodedString(),
        ],
        ["type": "message", "role": "assistant", "content": "Looking."],
        [
          "type": "function_call", "call_id": "c1", "name": "weather",
          "arguments": #"{"city":"Oslo","days":2}"#,
        ],
        ["type": "function_call", "call_id": "c2", "name": "time", "arguments": "{}"],
        ["type": "function_call_output", "call_id": "c1", "output": "Rain"],
        [
          "type": "function_call_output", "call_id": "c2",
          "output": [["type": "input_text", "text": "Noon"]],
        ],
      ]
    ])
    XCTAssertEqual(
      request.transcript,
      [
        .user("Weather?"),
        .assistant(
          text: "Looking.", thinking: "Check it.",
          toolCalls: [
            AgentTranscriptToolCall(
              function: "weather",
              parameters: [
                "city": .init(string: true, value: "Oslo"),
                "days": .init(string: false, value: "2"),
              ]),
            AgentTranscriptToolCall(function: "time", parameters: [:]),
          ]),
        .toolResults([
          AgentTranscriptToolResult(content: "Rain", isError: false),
          AgentTranscriptToolResult(content: "Noon", isError: false),
        ]),
      ])
  }

  func testToolOutputsGoWhereTheirCallsAre() throws {
    func call(_ id: String, _ name: String) -> [String: Any] {
      ["type": "function_call", "call_id": id, "name": name, "arguments": "{}"]
    }
    func output(_ id: String, _ text: String) -> [String: Any] {
      ["type": "function_call_output", "call_id": id, "output": text]
    }
    let request = try request([
      "input": [
        ["role": "user", "content": "Plan the day."],
        call("c1", "weather"), call("c2", "time"), call("c3", "date"),
        output("c3", "Monday"), output("c1", "Rain"), output("c2", "Noon"),
        call("c4", "traffic"), output("c4", "Clear"),
      ]
    ])
    XCTAssertEqual(
      request.transcript,
      [
        .user("Plan the day."),
        .assistant(
          text: "", thinking: "",
          toolCalls: ["weather", "time", "date"].map {
            AgentTranscriptToolCall(function: $0, parameters: [:])
          }),
        .toolResults(
          ["Rain", "Noon", "Monday"].map { AgentTranscriptToolResult(content: $0, isError: false) }
        ),
        .assistant(
          text: "", thinking: "",
          toolCalls: [AgentTranscriptToolCall(function: "traffic", parameters: [:])]),
        .toolResults([AgentTranscriptToolResult(content: "Clear", isError: false)]),
      ])
  }

  func testTextAfterACallReplaysWithTheCallsOutput() throws {
    let transport = RecordingTransport()
    let writer = ResponsesResponseWriter(transport: transport, isStreaming: true, model: "m")
    writer.start()
    writer.appendText("Looking.")
    writer.appendFunctionCall(name: "weather", arguments: "{}")
    writer.appendText("Back soon.")
    writer.finish(
      usage: .init(inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, reasoningTokens: 0),
      incompleteReason: nil)
    let response = transport.events.last!.object["response"] as! [String: Any]
    let output = response["output"] as! [[String: Any]]
    XCTAssertEqual(output.map { $0["type"] as? String }, ["message", "function_call", "message"])
    let request = try request([
      "input": [["role": "user", "content": "Weather?"]] + output + [
        ["type": "function_call_output", "call_id": output[1]["call_id"]!, "output": "Rain"]
      ]
    ])
    XCTAssertEqual(
      request.transcript,
      [
        .user("Weather?"),
        .assistant(
          text: "Looking.", thinking: "",
          toolCalls: [AgentTranscriptToolCall(function: "weather", parameters: [:])]),
        .assistant(text: "Back soon.", thinking: "", toolCalls: []),
        .toolResults([AgentTranscriptToolResult(content: "Rain", isError: false)]),
      ])
  }

  func testToolOutputsThatCannotBeMatchedAreRefused() {
    let user: [String: Any] = ["role": "user", "content": "Go."]
    let call: [String: Any] = [
      "type": "function_call", "call_id": "c1", "name": "weather", "arguments": "{}",
    ]
    let output: [String: Any] = ["type": "function_call_output", "call_id": "c1", "output": "Rain"]
    var unknown = output
    unknown["call_id"] = "c9"
    var unnamed = output
    unnamed["call_id"] = nil
    var callWithoutId = call
    callWithoutId["call_id"] = nil
    let cases: [[[String: Any]]] = [
      [user, call, unknown],
      [user, call, unnamed],
      [user, call, output, output],
      [user, call, output, user, output],
      [user, call, user],
      [user, call],
      [user, callWithoutId, output],
    ]
    for input in cases {
      XCTAssertThrowsError(try request(["input": input])) { error in
        guard case ResponsesRequestError.invalid = error else { return XCTFail("\(error)") }
      }
    }
  }

  func testReasoningEffortSetsTheThinking() throws {
    let unset = try request(["input": "x"])
    XCTAssertNil(unset.thinking)
    XCTAssertNil(unset.reasoningEffort)
    XCTAssertNil(try request(["input": "x", "reasoning": ["effort": NSNull()]]).thinking)
    let efforts: [(String, CodeAgentReasoningEffort)] = [
      ("minimal", .low), ("low", .low), ("medium", .medium), ("high", .high), ("xhigh", .max),
      ("max", .max),
    ]
    for (effort, expected) in efforts {
      let request = try request(["input": "x", "reasoning": ["effort": effort, "summary": "auto"]])
      XCTAssertEqual(request.thinking, .enabled(budget: nil))
      XCTAssertEqual(request.reasoningEffort, expected)
    }
    let none = try request(["input": "x", "reasoning": ["effort": "none"]])
    XCTAssertEqual(none.thinking, .disabled)
    XCTAssertNil(none.reasoningEffort)
    for value: Any in ["extreme", 3] {
      XCTAssertThrowsError(try request(["input": "x", "reasoning": ["effort": value]])) { error in
        guard case ResponsesRequestError.invalid = error else { return XCTFail("\(error)") }
      }
    }
  }

  func testLastConfigurationUpdateSetsTheEffortAndLeavesTheConversation() throws {
    let request = try request([
      "reasoning": ["effort": "medium"],
      "input": [
        ["type": "configuration_update", "reasoning": ["effort": "low"]],
        ["role": "user", "content": "A"],
        ["role": "assistant", "content": "B"],
        ["type": "configuration_update", "reasoning": ["effort": "xhigh"]],
        ["role": "user", "content": "C"],
      ],
    ])
    XCTAssertEqual(request.reasoningEffort, .max)
    XCTAssertEqual(request.thinking, .enabled(budget: nil))
    XCTAssertEqual(
      request.transcript,
      [.user("A"), .assistant(text: "B", thinking: "", toolCalls: []), .user("C")])
    let off = try self.request([
      "reasoning": ["effort": "high"],
      "input": [
        ["role": "user", "content": "A"],
        ["type": "configuration_update", "reasoning": ["effort": "none"]],
      ],
    ])
    XCTAssertEqual(off.thinking, .disabled)
  }

  func testImagesKeepTheirPlaceInTheText() throws {
    let image: [String: Any] = [
      "type": "input_image", "image_url": "data:image/png;base64," + testImageBase64,
    ]
    let request = try request([
      "input": [
        [
          "role": "user",
          "content": [
            ["type": "input_text", "text": "A"], ["type": "input_text", "text": "B"], image,
            ["type": "input_text", "text": "C"],
          ],
        ],
        ["role": "user", "content": [image, ["type": "input_text", "text": "Dé"], image]],
        ["type": "function_call", "call_id": "c1", "name": "view", "arguments": "{}"],
        [
          "type": "function_call_output", "call_id": "c1",
          "output": [["type": "input_text", "text": "Seen"], image],
        ],
      ]
    ])
    XCTAssertEqual(
      request.transcript,
      [
        .user(
          "A\nBC\n\nDé",
          images: [
            AgentTranscriptImage(offset: 3, data: testImage),
            AgentTranscriptImage(offset: 6, data: testImage),
            AgentTranscriptImage(offset: 9, data: testImage),
          ]),
        .assistant(
          text: "", thinking: "",
          toolCalls: [AgentTranscriptToolCall(function: "view", parameters: [:])]),
        .toolResults([
          AgentTranscriptToolResult(
            content: "Seen", isError: false,
            images: [AgentTranscriptImage(offset: 4, data: testImage)])
        ]),
      ])
    XCTAssertTrue(request.hasImages)
    XCTAssertFalse(try self.request(["input": "x"]).hasImages)
    guard case .user(let text, let images) = request.transcript[0] else { return XCTFail() }
    XCTAssertEqual(
      AgentTranscriptImage.segments(of: text, images: images), ["A\nB", "C\n\n", "Dé", ""])
    XCTAssertEqual(AgentTranscriptImage.segments(of: text, images: []), [text])
  }

  func testImagesThatCannotBeReadAreRefused() {
    func content(_ part: [String: Any], role: String = "user") -> [String: Any] {
      ["input": [["role": role, "content": [part]]]]
    }
    let unsupported: [[String: Any]] = [
      content(["type": "input_image", "image_url": "https://example.com/a.png"]),
      content(["type": "input_image", "file_id": "file_1"]),
      content(
        ["type": "input_image", "image_url": "data:image/png;base64," + testImageBase64],
        role: "assistant"),
      content(
        ["type": "input_image", "image_url": "data:image/png;base64," + testImageBase64],
        role: "system"),
    ]
    for object in unsupported {
      XCTAssertThrowsError(try request(object)) { error in
        guard case ResponsesRequestError.unsupported("input", _) = error else {
          return XCTFail("\(error)")
        }
      }
    }
    let invalid: [[String: Any]] = [
      content(["type": "input_image", "image_url": "data:image/png;base64,!!!"]),
      content(["type": "input_image", "image_url": "data:image/png;base64,bm90IGFuIGltYWdl"]),
    ]
    for object in invalid {
      XCTAssertThrowsError(try request(object)) { error in
        guard case ResponsesRequestError.invalid = error else { return XCTFail("\(error)") }
      }
    }
  }

  func testOutputLimitIsAWholeNumberAboveZero() throws {
    XCTAssertEqual(try request(["input": "x", "max_output_tokens": 64]).maximumOutputTokens, 64)
    XCTAssertEqual(try request(["input": "x", "max_output_tokens": 64.0]).maximumOutputTokens, 64)
    XCTAssertNil(try request(["input": "x", "max_output_tokens": NSNull()]).maximumOutputTokens)
    for value: Any in [-1, 0, 3.5, "64", 1e30] {
      XCTAssertThrowsError(try request(["input": "x", "max_output_tokens": value])) { error in
        guard case ResponsesRequestError.invalid = error else { return XCTFail("\(error)") }
      }
    }
  }

  func testWhatTheServerCannotDoIsRefused() {
    let cases: [([String: Any], String)] = [
      (["input": "x", "previous_response_id": "resp_1"], "previous_response_id"),
      (["input": "x", "conversation": "conv_1"], "conversation"),
      (["input": "x", "text": ["format": ["type": "json_object"]]], "text.format"),
      (
        ["input": [["role": "user", "content": [["type": "input_image", "image_url": "x"]]]]],
        "input"
      ),
    ]
    for (object, parameter) in cases {
      XCTAssertThrowsError(try request(object)) { error in
        guard case ResponsesRequestError.unsupported(let actual, _) = error else {
          return XCTFail("\(error)")
        }
        XCTAssertEqual(actual, parameter)
      }
    }
  }

  func testNullStateFieldsAndToolChoiceNone() throws {
    let request = try request([
      "input": "x", "previous_response_id": NSNull(), "conversation": NSNull(),
      "tool_choice": "none",
      "tools": [["type": "function", "name": "f"]],
    ])
    XCTAssertTrue(request.tools.isEmpty)
  }

  func testHostedToolsAreDroppedAndFunctionsKept() throws {
    let request = try request([
      "input": "x",
      "tools": [["type": "web_search"], ["type": "function", "name": "f"]],
    ])
    XCTAssertEqual(request.tools.map(\.name), ["f"])
  }

  func testToolSchemaLineIsStableAcrossKeyOrder() throws {
    let first = try request([
      "input": "x",
      "tools": [
        [
          "type": "function", "name": "f", "description": "D",
          "parameters": ["type": "object", "properties": ["a": ["type": "string"]]],
        ]
      ],
    ])
    XCTAssertEqual(
      first.tools[0].schemaLine,
      #"{"function":{"description":"D","name":"f","parameters":{"properties":{"a":{"type":"string"}},"type":"object"}},"type":"function"}"#
    )
  }

  func testArgumentsFollowTheToolSchema() throws {
    let request = try request([
      "input": "x",
      "tools": [
        [
          "type": "function", "name": "f",
          "parameters": [
            "type": "object",
            "properties": [
              "code": ["type": "string"], "count": ["type": "integer"],
              "items": ["type": "array"],
            ],
          ],
        ]
      ],
    ])
    let toolCall = ToolCall(
      id: 0,
      request: ToolCall.Request(
        function: "f",
        parameters: [
          "code": .init(string: true, value: "42"),
          "count": .init(string: true, value: "42"),
          "items": .init(string: true, value: "[1,2]"),
          "unknown": .init(string: true, value: "7"),
        ]))
    XCTAssertEqual(
      request.arguments(of: toolCall),
      #"{"code":"42","count":42,"items":[1,2],"unknown":"7"}"#)
  }

  func testNullableStringsFollowTheModelsMarking() throws {
    let request = try request([
      "input": "x",
      "tools": [
        [
          "type": "function", "name": "f",
          "parameters": [
            "type": "object",
            "properties": [
              "note": ["type": ["string", "null"]], "title": ["type": ["string", "null"]],
              "label": ["type": "string"],
            ],
          ],
        ]
      ],
    ])
    let toolCall = ToolCall(
      id: 0,
      request: ToolCall.Request(
        function: "f",
        parameters: [
          "note": .init(string: false, value: "null"),
          "title": .init(string: true, value: "null"),
          "label": .init(string: false, value: "null"),
        ]))
    XCTAssertEqual(
      request.arguments(of: toolCall), #"{"label":"null","note":null,"title":"null"}"#)
  }
}

final class ResponsesResponseWriterTests: XCTestCase {
  private let usage = ResponseUsage(
    inputTokens: 10, cachedInputTokens: 4, outputTokens: 5, reasoningTokens: 2)

  func testStreamingEventsComeInOrderWithDeltasThatAddUp() {
    let transport = RecordingTransport()
    let writer = ResponsesResponseWriter(transport: transport, isStreaming: true, model: "m")
    writer.start()
    writer.appendReasoning("Th")
    writer.appendReasoning("ink")
    writer.appendText("He")
    writer.appendText("llo")
    writer.appendFunctionCall(name: "f", arguments: "{}")
    writer.finish(usage: usage, incompleteReason: nil)

    XCTAssertTrue(transport.didBeginEventStream)
    XCTAssertTrue(transport.didClose)
    XCTAssertNil(transport.status)
    XCTAssertEqual(
      transport.events.map(\.name),
      [
        "response.created", "response.in_progress",
        "response.output_item.added", "response.reasoning_text.delta",
        "response.reasoning_text.delta", "response.reasoning_text.done",
        "response.output_item.done",
        "response.output_item.added", "response.content_part.added",
        "response.output_text.delta", "response.output_text.delta", "response.output_text.done",
        "response.content_part.done", "response.output_item.done",
        "response.output_item.added", "response.function_call_arguments.delta",
        "response.function_call_arguments.done", "response.output_item.done",
        "response.completed",
      ])
    XCTAssertEqual(
      transport.events.map { $0.object["sequence_number"] as? Int },
      Array(0..<transport.events.count).map { $0 })
    let response = transport.events.last!.object["response"] as! [String: Any]
    XCTAssertEqual(response["status"] as? String, "completed")
    let output = response["output"] as! [[String: Any]]
    XCTAssertEqual(output.map { $0["type"] as? String }, ["reasoning", "message", "function_call"])
    XCTAssertEqual(
      ((output[1]["content"] as! [[String: Any]])[0])["text"] as? String, "Hello")
    XCTAssertEqual(
      Data(base64Encoded: output[0]["encrypted_content"] as! String),
      Data("Think".utf8))
    let usageObject = response["usage"] as! [String: Any]
    XCTAssertEqual(usageObject["total_tokens"] as? Int, 15)
    XCTAssertEqual(
      (usageObject["input_tokens_details"] as! [String: Any])["cached_tokens"] as? Int, 4)
  }

  func testNonStreamingGetsOneObject() throws {
    let transport = RecordingTransport()
    let writer = ResponsesResponseWriter(transport: transport, isStreaming: false, model: "m")
    writer.start()
    writer.appendText("Hello")
    writer.finish(usage: usage, incompleteReason: "max_output_tokens")

    XCTAssertTrue(transport.events.isEmpty)
    XCTAssertEqual(transport.status, 200)
    let response =
      try JSONSerialization.jsonObject(with: transport.body!) as! [String: Any]
    XCTAssertEqual(response["status"] as? String, "incomplete")
    XCTAssertEqual(
      (response["incomplete_details"] as! [String: Any])["reason"] as? String,
      "max_output_tokens")
  }

  func testFailureUsesTheStatusUntilAStreamStarted() throws {
    let plain = RecordingTransport()
    ResponsesResponseWriter(transport: plain, isStreaming: true, model: "m").fail(
      status: 400, type: "invalid_request_error", code: "context_length_exceeded", message: "Long")
    XCTAssertEqual(plain.status, 400)
    let error =
      (try JSONSerialization.jsonObject(with: plain.body!) as! [String: Any])["error"]
      as! [String: Any]
    XCTAssertEqual(error["code"] as? String, "context_length_exceeded")

    let streaming = RecordingTransport()
    let writer = ResponsesResponseWriter(transport: streaming, isStreaming: true, model: "m")
    writer.start()
    writer.fail(status: 400, type: "invalid_request_error", code: "c", message: "Long")
    XCTAssertNil(streaming.status)
    XCTAssertEqual(streaming.events.last?.name, "response.failed")
    XCTAssertTrue(streaming.didClose)
  }
}

final class StreamingHTTPServerTests: XCTestCase {
  private final class Delegate: StreamingHTTPServerDelegate {
    let ready: XCTestExpectation
    var onRequest: ((StreamingHTTPRequest, StreamingHTTPConnection) -> Void)?
    init(ready: XCTestExpectation) { self.ready = ready }
    func streamingHTTPServer(
      _ server: StreamingHTTPServer, didChange state: StreamingHTTPServer.State
    ) {
      if state == .ready { ready.fulfill() }
    }
    func streamingHTTPServer(
      _ server: StreamingHTTPServer, didReceive request: StreamingHTTPRequest,
      on connection: StreamingHTTPConnection
    ) {
      onRequest?(request, connection)
    }
  }

  private var server: StreamingHTTPServer!
  private var delegate: Delegate!
  private let port: UInt16 = 11_463

  override func setUp() {
    let ready = expectation(description: "ready")
    delegate = Delegate(ready: ready)
    server = StreamingHTTPServer(host: "127.0.0.1", port: port)
    server.delegate = delegate
    server.start()
    wait(for: [ready], timeout: 5)
  }

  override func tearDown() {
    server.stop()
    server = nil
    delegate = nil
  }

  private func send(_ request: URLRequest) -> (status: Int, body: Data) {
    let done = expectation(description: "response")
    var result = (status: 0, body: Data())
    URLSession.shared.dataTask(with: request) { data, response, _ in
      result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
      done.fulfill()
    }.resume()
    wait(for: [done], timeout: 10)
    return result
  }

  private var url: URL { URL(string: "http://127.0.0.1:\(port)/v1/responses?beta=1")! }

  /// The status line answering a raw request, which can carry a Host that URLSession won't send.
  private func statusLine(ofRaw request: String, port: UInt16) -> String {
    let done = expectation(description: "raw response")
    var statusLine = ""
    let connection = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: .global())
    connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, _, _ in
      statusLine =
        String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first
        ?? ""
      connection.cancel()
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return statusLine
  }

  func testBodyArrivesWholeAcrossReads() {
    // Several times the size of one read.
    let body = Data(repeating: 97, count: 2 * 1_024 * 1_024)
    var received: StreamingHTTPRequest?
    delegate.onRequest = { request, connection in
      received = request
      connection.respond(status: 200, contentType: "application/json", body: Data("{}".utf8))
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    let response = send(request)
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.body, Data("{}".utf8))
    XCTAssertEqual(received?.method, "POST")
    XCTAssertEqual(received?.path, "/v1/responses")
    XCTAssertEqual(received?.body, body)
  }

  func testEventStreamEndsWhenTheConnectionCloses() {
    delegate.onRequest = { _, connection in
      connection.beginEventStream()
      connection.sendEvent(name: "a", data: Data("1".utf8))
      connection.sendKeepAlive()
      connection.sendEvent(name: "b", data: Data("2".utf8))
      connection.close()
    }
    let response = send(URLRequest(url: url))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(
      String(decoding: response.body, as: UTF8.self),
      "event: a\ndata: 1\n\n: waiting\n\nevent: b\ndata: 2\n\n")
  }

  func testWebPagesAreRefused() {
    delegate.onRequest = { _, _ in XCTFail("A page's request got through") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("https://example.com", forHTTPHeaderField: "Origin")
    XCTAssertEqual(send(request).status, 403)
  }

  func testReboundHostsAreRefused() {
    delegate.onRequest = { _, _ in XCTFail("A rebound host's request got through") }
    XCTAssertEqual(
      statusLine(
        ofRaw: "GET /v1/models HTTP/1.1\r\nHost: rebound.example:\(port)\r\n\r\n", port: port),
      "HTTP/1.1 403 Forbidden")
  }

  func testEveryHostIsWelcomeOnAllConnections() {
    let port: UInt16 = 11_464
    let ready = expectation(description: "ready")
    let delegate = Delegate(ready: ready)
    let server = StreamingHTTPServer(host: "0.0.0.0", port: port)
    server.delegate = delegate
    server.start()
    defer { server.stop() }
    wait(for: [ready], timeout: 5)
    delegate.onRequest = { _, connection in
      connection.respond(status: 200, contentType: "application/json", body: Data("{}".utf8))
    }
    XCTAssertEqual(
      statusLine(
        ofRaw: "GET /v1/models HTTP/1.1\r\nHost: 192.168.1.20:\(port)\r\n\r\n", port: port),
      "HTTP/1.1 200 OK")
    // Pages are still refused, wherever the server is reached.
    delegate.onRequest = { _, _ in XCTFail("A page's request got through") }
    XCTAssertEqual(
      statusLine(
        ofRaw:
          "GET /v1/models HTTP/1.1\r\nHost: 192.168.1.20:\(port)\r\nOrigin: https://example.com\r\n\r\n",
        port: port),
      "HTTP/1.1 403 Forbidden")
  }

  func testLoopbackNames() {
    for authority in [
      "127.0.0.1", "127.0.0.1:11435", "localhost:1", "LOCALHOST", "[::1]:8", "[::1]",
    ] {
      XCTAssertTrue(StreamingHTTPServer.isLoopback(authority: authority), authority)
    }
    for authority in [
      nil, "example.com", "127.0.0.1.example.com:1", "[::2]:8", "localhost.evil", "[::1].evil",
    ] {
      XCTAssertFalse(StreamingHTTPServer.isLoopback(authority: authority), authority ?? "nil")
    }
    XCTAssertTrue(StreamingHTTPServer.isLoopback(origin: "http://localhost:3000"))
    XCTAssertTrue(StreamingHTTPServer.isLoopback(origin: "http://[::1]:3000"))
    XCTAssertFalse(StreamingHTTPServer.isLoopback(origin: "https://evil.example"))
    XCTAssertFalse(StreamingHTTPServer.isLoopback(origin: "null"))
  }
}

final class ServeMetricsTests: XCTestCase {
  private let start = Date(timeIntervalSinceReferenceDate: 0)

  private func request(
    status: String = "completed", input: Int = 100, cached: Int = 0, firstTokenAfter: TimeInterval?
  ) -> ServeMetrics.Request {
    var timing = ServeRequestTiming(startDate: start)
    if let firstTokenAfter {
      timing.enter(.generating, at: start.addingTimeInterval(firstTokenAfter))
    }
    return ServeMetrics.Request(
      date: start, status: status, inputTokens: input, cachedInputTokens: cached, outputTokens: 10,
      timing: timing, prefillTokensPerSecond: 0, generationTokensPerSecond: 0)
  }

  func testSamplesRateTheTokensSinceTheLastSample() {
    var metrics = ServeMetrics()
    metrics.sample(at: start, memoryBytes: 1, contextCacheBytes: 2)
    XCTAssertEqual(metrics.samples.last?.generationTokensPerSecond, 0)
    metrics.addGeneratedTokens(10)
    metrics.addGeneratedTokens(-5)
    metrics.addGeneratedTokens(10)
    metrics.sample(at: start.addingTimeInterval(2), memoryBytes: 1, contextCacheBytes: 2)
    XCTAssertEqual(metrics.samples.last?.generationTokensPerSecond, 10)
    // Waiting behind the chat shows as a dip, not as the speed before it.
    metrics.sample(at: start.addingTimeInterval(4), memoryBytes: 1, contextCacheBytes: 2)
    XCTAssertEqual(metrics.samples.last?.generationTokensPerSecond, 0)
  }

  func testSamplesLeaveTheWindow() {
    var metrics = ServeMetrics()
    metrics.sample(at: start, memoryBytes: 1, contextCacheBytes: 2)
    metrics.sample(at: start.addingTimeInterval(200), memoryBytes: 1, contextCacheBytes: 2)
    metrics.sample(
      at: start.addingTimeInterval(ServeMetrics.sampleWindow + 1), memoryBytes: 1,
      contextCacheBytes: 2)
    XCTAssertEqual(metrics.samples.count, 2)
    XCTAssertEqual(metrics.samples.first?.date, start.addingTimeInterval(200))
  }

  func testRequestsCountUpAndTotalsOutliveTheWindow() {
    var metrics = ServeMetrics()
    for _ in 0..<(ServeMetrics.requestWindow + 5) {
      metrics.add(request(firstTokenAfter: 1))
    }
    metrics.add(request(status: "failed", firstTokenAfter: nil))
    XCTAssertEqual(metrics.requests.count, ServeMetrics.requestWindow)
    XCTAssertEqual(metrics.requests.last?.id, ServeMetrics.requestWindow + 6)
    XCTAssertEqual(metrics.requestCount, ServeMetrics.requestWindow + 6)
    XCTAssertEqual(metrics.failedRequestCount, 1)
    XCTAssertEqual(metrics.outputTokens, (ServeMetrics.requestWindow + 6) * 10)
  }

  func testCacheReuseAndMedianTimeToFirstToken() {
    var metrics = ServeMetrics()
    XCTAssertNil(metrics.cacheReuse)
    XCTAssertNil(metrics.medianTimeToFirstToken)
    metrics.add(request(input: 100, cached: 0, firstTokenAfter: 10))
    metrics.add(request(input: 300, cached: 300, firstTokenAfter: 2))
    // One that never generated doesn't pull the median down.
    metrics.add(request(status: "failed", input: 0, firstTokenAfter: nil))
    XCTAssertEqual(metrics.cacheReuse, 0.75)
    XCTAssertEqual(metrics.medianTimeToFirstToken, 6)
    metrics.add(request(firstTokenAfter: 3))
    XCTAssertEqual(metrics.medianTimeToFirstToken, 3)
  }

  func testTimingSplitsARequestByPhase() {
    var timing = ServeRequestTiming(startDate: start)
    timing.enter(.prefilling, at: start.addingTimeInterval(2))
    timing.enter(.generating, at: start.addingTimeInterval(5))
    // Paused behind the chat, then back.
    timing.enter(.waiting, at: start.addingTimeInterval(9))
    timing.enter(.generating, at: start.addingTimeInterval(10))
    timing.enter(.waiting, at: start.addingTimeInterval(11))
    XCTAssertEqual(timing.waitingSeconds, 3)
    XCTAssertEqual(timing.prefillSeconds, 3)
    XCTAssertEqual(timing.generationSeconds, 5)
    XCTAssertEqual(timing.timeToFirstToken, 5)
  }
}

final class ResponsesAgentPoolTests: XCTestCase {
  private final class Agent {}

  func testContinuationHasToBeLonger() {
    var pool = ResponsesAgentPool<Agent>()
    let agent = Agent()
    pool.add(agent, prompt: ResponsesPrompt(tokens: [1, 2, 3]), wasReused: false)
    XCTAssertNil(pool.takeAgent(continuing: ResponsesPrompt(tokens: [1, 2, 3])))
    XCTAssertNil(pool.takeAgent(continuing: ResponsesPrompt(tokens: [1, 2])))
    XCTAssertNil(pool.takeAgent(continuing: ResponsesPrompt(tokens: [1, 2, 4, 5])))
    XCTAssertTrue(pool.takeAgent(continuing: ResponsesPrompt(tokens: [1, 2, 3, 4])) === agent)
    XCTAssertEqual(pool.count, 0)
  }

  func testTakesTheLongestContinuation() {
    var pool = ResponsesAgentPool<Agent>()
    let short = Agent()
    let long = Agent()
    pool.add(short, prompt: ResponsesPrompt(tokens: [1, 2]), wasReused: true)
    pool.add(long, prompt: ResponsesPrompt(tokens: [1, 2, 3]), wasReused: false)
    XCTAssertTrue(pool.takeAgent(continuing: ResponsesPrompt(tokens: [1, 2, 3, 4])) === long)
    XCTAssertTrue(pool.takeAgent(continuing: ResponsesPrompt(tokens: [1, 2, 3, 4])) === short)
  }

  func testSameTokensWithAnotherImageAreAnotherConversation() {
    func prompt(_ tokens: [Int32], image digest: UInt8) -> ResponsesPrompt {
      ResponsesPrompt(
        tokens: tokens,
        embedSpans: [EmbedSpan(start: 1, length: 2, digest: [digest], kind: .image)])
    }
    var pool = ResponsesAgentPool<Agent>()
    let agent = Agent()
    pool.add(agent, prompt: prompt([1, 9, 9, 2], image: 1), wasReused: false)
    XCTAssertNil(pool.takeAgent(continuing: prompt([1, 9, 9, 2, 3], image: 2)))
    XCTAssertNil(pool.takeAgent(continuing: ResponsesPrompt(tokens: [1, 9, 9, 2, 3])))
    XCTAssertTrue(pool.takeAgent(continuing: prompt([1, 9, 9, 2, 3], image: 1)) === agent)
  }

  func testPrefixKeepsTheImagesWholeWithinIt() {
    let prompt = ResponsesPrompt(
      tokens: [1, 9, 9, 2, 9, 9, 3],
      embedSpans: [
        EmbedSpan(start: 1, length: 2, digest: [1], kind: .image),
        EmbedSpan(start: 4, length: 2, digest: [2], kind: .image),
      ])
    XCTAssertEqual(
      prompt.prefix(5),
      ResponsesPrompt(
        tokens: [1, 9, 9, 2, 9],
        embedSpans: [EmbedSpan(start: 1, length: 2, digest: [1], kind: .image)]))
    XCTAssertEqual(prompt.prefix(6).embedSpans.count, 2)
  }

  func testExpiresWhatWasNeverReusedFirst() {
    var pool = ResponsesAgentPool<Agent>()
    let firstReused = Agent()
    let secondReused = Agent()
    let firstOnce = Agent()
    let secondOnce = Agent()
    pool.add(firstReused, prompt: ResponsesPrompt(tokens: [1]), wasReused: true)
    pool.add(firstOnce, prompt: ResponsesPrompt(tokens: [2]), wasReused: false)
    pool.add(secondReused, prompt: ResponsesPrompt(tokens: [3]), wasReused: true)
    pool.add(secondOnce, prompt: ResponsesPrompt(tokens: [4]), wasReused: false)
    XCTAssertTrue(pool.expire() === firstOnce)
    XCTAssertTrue(pool.expire() === secondOnce)
    XCTAssertTrue(pool.expire() === firstReused)
    XCTAssertTrue(pool.expire() === secondReused)
    XCTAssertNil(pool.expire())
  }

  func testRemovesListedAgents() {
    var pool = ResponsesAgentPool<Agent>()
    let kept = Agent()
    let removed = Agent()
    pool.add(kept, prompt: ResponsesPrompt(tokens: [1]), wasReused: true)
    pool.add(removed, prompt: ResponsesPrompt(tokens: [2]), wasReused: false)
    pool.remove([removed])
    XCTAssertEqual(pool.count, 1)
    XCTAssertTrue(pool.agents.first === kept)
  }
}

final class ResponsesThinkingOnlyTurnTests: XCTestCase {
  private func transcript(_ items: [[String: Any]]) throws -> [AgentTranscriptEntry] {
    let body = try JSONSerialization.data(withJSONObject: ["input": items])
    return try ResponsesRequest(body: body).transcript
  }

  private let reasoning: [String: Any] = [
    "type": "reasoning", "content": [["type": "reasoning_text", "text": "Thinking."]],
  ]

  func testKeepsTheTurnBetweenUserMessages() throws {
    let entries = try transcript([
      ["role": "user", "content": "One"], reasoning, ["role": "user", "content": "Two"],
    ])
    XCTAssertEqual(entries.count, 3)
    guard case .assistant(let text, let thinking, let toolCalls) = entries[1] else {
      return XCTFail("Expected the turn that only thought, got \(entries[1])")
    }
    XCTAssertEqual(text, "")
    XCTAssertEqual(thinking, "Thinking.")
    XCTAssertTrue(toolCalls.isEmpty)
  }

  func testThinkingStillJoinsTheMessageAfterIt() throws {
    let entries = try transcript([
      ["role": "user", "content": "One"], reasoning,
      ["role": "assistant", "content": "Answer"],
    ])
    XCTAssertEqual(entries.count, 2)
    guard case .assistant(let text, let thinking, _) = entries[1] else {
      return XCTFail("Expected an assistant turn, got \(entries[1])")
    }
    XCTAssertEqual(text, "Answer")
    XCTAssertEqual(thinking, "Thinking.")
  }
}
