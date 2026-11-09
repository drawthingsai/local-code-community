import Foundation
import XCTest

private func body(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: object)
}

/// The same conversation in Responses' terms, which the other protocols have to come down to.
private func responsesToolRound() throws -> ResponsesRequest {
  try ResponsesRequest(
    body: body([
      "instructions": "Be brief.",
      "input": [
        ["role": "user", "content": "Weather?"],
        ["type": "reasoning", "content": [["type": "reasoning_text", "text": "Look it up."]]],
        ["type": "message", "role": "assistant", "content": "Checking."],
        [
          "type": "function_call", "call_id": "c1", "name": "weather",
          "arguments": #"{"city":"Oslo","days":2}"#,
        ],
        ["type": "function_call", "call_id": "c2", "name": "time", "arguments": "{}"],
        ["type": "function_call_output", "call_id": "c2", "output": "Noon"],
        ["type": "function_call_output", "call_id": "c1", "output": "Rain"],
        ["role": "user", "content": "Thanks."],
        ["role": "assistant", "content": "Welcome."],
      ],
      "tools": [
        ["type": "function", "name": "weather", "parameters": ["type": "object"]],
        ["type": "function", "name": "time"],
      ],
    ]))
}

final class MessagesRequestTests: XCTestCase {
  private func request(_ object: [String: Any]) throws -> ResponsesRequest {
    try WireProtocol.anthropicMessages.request(body: body(object))
  }

  func testContentBlocksBuildTheSameConversationAsResponses() throws {
    let request = try request([
      "system": [["type": "text", "text": "Be brief.", "cache_control": ["type": "ephemeral"]]],
      "max_tokens": 64,
      "stream": true,
      "messages": [
        ["role": "user", "content": "Weather?"],
        [
          "role": "assistant",
          "content": [
            ["type": "thinking", "thinking": "Look it up.", "signature": "s"],
            ["type": "text", "text": "Checking."],
            [
              "type": "tool_use", "id": "c1", "name": "weather",
              "input": ["city": "Oslo", "days": 2],
            ],
            ["type": "tool_use", "id": "c2", "name": "time", "input": [String: Any]()],
          ],
        ],
        [
          "role": "user",
          "content": [
            ["type": "tool_result", "tool_use_id": "c2", "content": "Noon"],
            [
              "type": "tool_result", "tool_use_id": "c1",
              "content": [["type": "text", "text": "Rain"]],
            ],
            ["type": "text", "text": "Thanks."],
          ],
        ],
        ["role": "assistant", "content": "Welcome."],
      ],
      "tools": [
        ["name": "weather", "input_schema": ["type": "object"]],
        ["name": "time"],
        ["type": "web_search_20260209", "name": "web_search"],
      ],
    ])
    let expected = try responsesToolRound()
    XCTAssertEqual(request.transcript, expected.transcript)
    XCTAssertEqual(request.instructions, expected.instructions)
    XCTAssertEqual(request.tools.map(\.schemaLine), expected.tools.map(\.schemaLine))
    XCTAssertEqual(request.maximumOutputTokens, 64)
    XCTAssertTrue(request.isStreaming)
  }

  func testLaterSystemMessagesStayInPlace() throws {
    let request = try request([
      "system": "A",
      "messages": [
        ["role": "user", "content": "B"],
        ["role": "system", "content": "C"],
      ],
    ])
    XCTAssertEqual(request.instructions, "A")
    XCTAssertEqual(request.transcript, [.user("B\n\nC")])
  }

  func testToolChoiceNoneDropsTheTools() throws {
    let request = try request([
      "messages": [["role": "user", "content": "x"]],
      "tools": [["name": "f"]],
      "tool_choice": ["type": "none"],
    ])
    XCTAssertTrue(request.tools.isEmpty)
  }

  func testWhatTheServerCannotDoIsRefused() {
    let messages = [["role": "user", "content": "x"]]
    let cases: [([String: Any], String)] = [
      (["messages": messages, "thread": ["id": "t"]], "thread"),
      (
        ["messages": messages, "output_config": ["format": ["type": "json_schema"]]],
        "output_config.format"
      ),
      (["messages": messages, "stop_sequences": ["END"]], "stop_sequences"),
      (
        [
          "messages": [
            ["role": "user", "content": [["type": "image", "source": ["type": "base64"]]]]
          ]
        ], "input"
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
    XCTAssertThrowsError(try request(["messages": messages, "max_tokens": 0]))
  }
}

final class ChatCompletionsRequestTests: XCTestCase {
  private func request(_ object: [String: Any]) throws -> ResponsesRequest {
    try WireProtocol.openAIChatCompletions.request(body: body(object))
  }

  func testMessagesBuildTheSameConversationAsResponses() throws {
    let request = try request([
      "messages": [
        ["role": "system", "content": "Be brief."],
        ["role": "user", "content": [["type": "text", "text": "Weather?"]]],
        [
          "role": "assistant", "content": "Checking.", "reasoning_content": "Look it up.",
          "tool_calls": [
            [
              "id": "c1", "type": "function",
              "function": ["name": "weather", "arguments": #"{"city":"Oslo","days":2}"#],
            ],
            ["id": "c2", "type": "function", "function": ["name": "time", "arguments": "{}"]],
          ],
        ],
        ["role": "tool", "tool_call_id": "c2", "content": "Noon"],
        ["role": "tool", "tool_call_id": "c1", "content": "Rain"],
        ["role": "user", "content": "Thanks."],
        ["role": "assistant", "content": "Welcome."],
      ],
      "tools": [
        ["type": "function", "function": ["name": "weather", "parameters": ["type": "object"]]],
        ["type": "function", "function": ["name": "time"]],
        ["type": "custom", "custom": ["name": "grammar"]],
      ],
      "max_completion_tokens": 64,
      "stream": true,
      "stream_options": ["include_usage": true],
    ])
    let expected = try responsesToolRound()
    XCTAssertEqual(request.transcript, expected.transcript)
    XCTAssertEqual(request.instructions, expected.instructions)
    XCTAssertEqual(request.tools.map(\.schemaLine), expected.tools.map(\.schemaLine))
    XCTAssertEqual(request.maximumOutputTokens, 64)
    XCTAssertTrue(request.isStreaming)
    XCTAssertTrue(request.includesStreamUsage)
  }

  func testCallsWithoutContentAndTheOlderLimit() throws {
    let request = try request([
      "messages": [
        ["role": "user", "content": "Time?"],
        [
          "role": "assistant", "content": NSNull(), "reasoning": "Ask.",
          "tool_calls": [
            ["id": "c1", "type": "function", "function": ["name": "time", "arguments": "{}"]]
          ],
        ],
        ["role": "tool", "tool_call_id": "c1", "content": "Noon"],
      ],
      "max_tokens": 32,
    ])
    XCTAssertEqual(
      request.transcript,
      [
        .user("Time?"),
        .assistant(
          text: "", thinking: "Ask.",
          toolCalls: [AgentTranscriptToolCall(function: "time", parameters: [:])]),
        .toolResults([AgentTranscriptToolResult(content: "Noon", isError: false)]),
      ])
    XCTAssertEqual(request.maximumOutputTokens, 32)
    XCTAssertFalse(request.includesStreamUsage)
  }

  func testNullNewerLimitLeavesTheOlderOne() throws {
    let request = try request([
      "messages": [["role": "user", "content": "Hi"]],
      "max_completion_tokens": NSNull(), "max_tokens": 32,
    ])
    XCTAssertEqual(request.maximumOutputTokens, 32)
  }

  func testWhatTheServerCannotDoIsRefused() {
    let messages = [["role": "user", "content": "x"]]
    let cases: [([String: Any], String)] = [
      (["messages": messages, "n": 2], "n"),
      (["messages": messages, "response_format": ["type": "json_object"]], "response_format"),
      (["messages": messages, "stop": ["END"]], "stop"),
      (["messages": messages, "stop": "END"], "stop"),
    ]
    for (object, parameter) in cases {
      XCTAssertThrowsError(try request(object)) { error in
        guard case ResponsesRequestError.unsupported(let actual, _) = error else {
          return XCTFail("\(error)")
        }
        XCTAssertEqual(actual, parameter)
      }
    }
    XCTAssertNoThrow(try request(["messages": messages, "n": 1, "stop": NSNull()]))
    XCTAssertThrowsError(try request(["messages": [["role": "tool", "content": "Rain"]]]))
  }
}

final class MessagesResponseWriterTests: XCTestCase {
  private let usage = ResponseUsage(
    inputTokens: 10, cachedInputTokens: 4, outputTokens: 5, reasoningTokens: 2)

  func testStreamingEventsComeInOrderWithBlocksThatAddUp() {
    let transport = RecordingTransport()
    let writer = MessagesResponseWriter(transport: transport, isStreaming: true, model: "m")
    writer.start()
    XCTAssertTrue(transport.didBeginEventStream)
    XCTAssertTrue(transport.events.isEmpty)
    writer.startTurn(inputTokens: 10, cachedInputTokens: 4)
    writer.appendReasoning("Th")
    writer.appendReasoning("ink")
    writer.appendText("He")
    writer.appendText("llo")
    writer.appendFunctionCall(name: "f", arguments: #"{"a":1}"#)
    writer.finish(usage: usage, incompleteReason: nil)

    XCTAssertTrue(transport.didClose)
    XCTAssertNil(transport.status)
    XCTAssertEqual(
      transport.events.map(\.name),
      [
        "message_start",
        "content_block_start", "content_block_delta", "content_block_delta",
        "content_block_delta", "content_block_stop",
        "content_block_start", "content_block_delta", "content_block_delta", "content_block_stop",
        "content_block_start", "content_block_delta", "content_block_stop",
        "message_delta", "message_stop",
      ])
    XCTAssertEqual(
      transport.events.map { $0.object["type"] as? String }, transport.events.map(\.name))
    let startUsage =
      (transport.events[0].object["message"] as! [String: Any])["usage"] as! [String: Any]
    XCTAssertEqual(startUsage["input_tokens"] as? Int, 6)
    XCTAssertEqual(startUsage["cache_read_input_tokens"] as? Int, 4)
    let blockTypes = transport.events.filter { $0.name == "content_block_start" }.map {
      ($0.object["content_block"] as! [String: Any])["type"] as? String
    }
    XCTAssertEqual(blockTypes, ["thinking", "text", "tool_use"])
    let deltas = transport.events.filter { $0.name == "content_block_delta" }.map {
      $0.object["delta"] as! [String: Any]
    }
    XCTAssertEqual(
      deltas.map { $0["type"] as? String },
      [
        "thinking_delta", "thinking_delta", "signature_delta", "text_delta", "text_delta",
        "input_json_delta",
      ])
    XCTAssertEqual(
      Data(base64Encoded: deltas[2]["signature"] as! String), Data("Think".utf8))
    XCTAssertEqual(deltas[5]["partial_json"] as? String, #"{"a":1}"#)
    let messageDelta = transport.events[13].object
    XCTAssertEqual(
      (messageDelta["delta"] as! [String: Any])["stop_reason"] as? String, "tool_use")
    XCTAssertEqual((messageDelta["usage"] as! [String: Any])["output_tokens"] as? Int, 5)
  }

  func testNonStreamingGetsOneMessage() throws {
    let transport = RecordingTransport()
    let writer = MessagesResponseWriter(transport: transport, isStreaming: false, model: "m")
    writer.start()
    writer.startTurn(inputTokens: 10, cachedInputTokens: 4)
    writer.appendReasoning("Think")
    writer.appendText("Hello")
    writer.appendFunctionCall(name: "f", arguments: #"{"a":1}"#)
    writer.finish(usage: usage, incompleteReason: "max_output_tokens")

    XCTAssertTrue(transport.events.isEmpty)
    XCTAssertEqual(transport.status, 200)
    let message = try JSONSerialization.jsonObject(with: transport.body!) as! [String: Any]
    XCTAssertEqual(message["type"] as? String, "message")
    XCTAssertEqual(message["stop_reason"] as? String, "max_tokens")
    let content = message["content"] as! [[String: Any]]
    XCTAssertEqual(content.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
    XCTAssertEqual(content[0]["thinking"] as? String, "Think")
    XCTAssertEqual(content[1]["text"] as? String, "Hello")
    XCTAssertEqual((content[2]["input"] as? [String: Any])?["a"] as? Int, 1)
    let usage = message["usage"] as! [String: Any]
    XCTAssertEqual(usage["input_tokens"] as? Int, 6)
    XCTAssertEqual(usage["cache_read_input_tokens"] as? Int, 4)
    XCTAssertEqual(usage["output_tokens"] as? Int, 5)
  }

  func testFailureUsesTheStatusUntilAStreamStarted() throws {
    let plain = RecordingTransport()
    MessagesResponseWriter(transport: plain, isStreaming: true, model: "m").fail(
      status: 503, type: "server_error", code: "model_not_available", message: "Not ready")
    XCTAssertEqual(plain.status, 503)
    let object = try JSONSerialization.jsonObject(with: plain.body!) as! [String: Any]
    XCTAssertEqual(object["type"] as? String, "error")
    XCTAssertEqual((object["error"] as! [String: Any])["type"] as? String, "api_error")

    let streaming = RecordingTransport()
    let writer = MessagesResponseWriter(transport: streaming, isStreaming: true, model: "m")
    writer.start()
    writer.fail(status: 400, type: "invalid_request_error", code: "c", message: "Long")
    XCTAssertNil(streaming.status)
    XCTAssertEqual(streaming.events.last?.name, "error")
    XCTAssertEqual(
      (streaming.events.last?.object["error"] as? [String: Any])?["type"] as? String,
      "invalid_request_error")
    XCTAssertTrue(streaming.didClose)
  }
}

final class ChatCompletionsResponseWriterTests: XCTestCase {
  private let usage = ResponseUsage(
    inputTokens: 10, cachedInputTokens: 4, outputTokens: 5, reasoningTokens: 2)

  func testStreamingChunksEndWithUsageAndDone() {
    let transport = RecordingTransport()
    let writer = ChatCompletionsResponseWriter(
      transport: transport, isStreaming: true, includesUsage: true, model: "m")
    writer.start()
    writer.startTurn(inputTokens: 10, cachedInputTokens: 4)
    writer.appendReasoning("Think")
    writer.appendText("He")
    writer.appendText("llo")
    writer.appendFunctionCall(name: "f", arguments: "{}")
    writer.appendFunctionCall(name: "g", arguments: "{}")
    writer.finish(usage: usage, incompleteReason: nil)

    XCTAssertTrue(transport.didBeginEventStream)
    XCTAssertTrue(transport.didClose)
    XCTAssertEqual(transport.events.map(\.name), Array(repeating: nil, count: 9))
    XCTAssertEqual(transport.eventData.last, "[DONE]")
    let chunks = transport.events.dropLast().map(\.object)
    XCTAssertTrue(chunks.allSatisfy { $0["object"] as? String == "chat.completion.chunk" })
    let deltas = chunks.prefix(7).map {
      (($0["choices"] as! [[String: Any]])[0])["delta"] as! [String: Any]
    }
    XCTAssertEqual(deltas[0]["role"] as? String, "assistant")
    XCTAssertEqual(deltas[1]["reasoning_content"] as? String, "Think")
    XCTAssertEqual(
      deltas.compactMap { $0["content"] as? String }.joined(), "Hello")
    let toolCalls = deltas.compactMap { ($0["tool_calls"] as? [[String: Any]])?.first }
    XCTAssertEqual(toolCalls.map { $0["index"] as? Int }, [0, 1])
    let finish = (chunks[6]["choices"] as! [[String: Any]])[0]
    XCTAssertEqual(finish["finish_reason"] as? String, "tool_calls")
    XCTAssertEqual((chunks[7]["choices"] as! [Any]).count, 0)
    let usageObject = chunks[7]["usage"] as! [String: Any]
    XCTAssertEqual(usageObject["prompt_tokens"] as? Int, 10)
    XCTAssertEqual(
      (usageObject["prompt_tokens_details"] as! [String: Any])["cached_tokens"] as? Int, 4)
  }

  func testStreamingLeavesUsageOutUnlessAsked() {
    let transport = RecordingTransport()
    let writer = ChatCompletionsResponseWriter(
      transport: transport, isStreaming: true, includesUsage: false, model: "m")
    writer.start()
    writer.startTurn(inputTokens: 10, cachedInputTokens: 4)
    writer.appendText("Hello")
    writer.finish(usage: usage, incompleteReason: "max_output_tokens")
    XCTAssertEqual(transport.events.count, 4)
    let finish = (transport.events[2].object["choices"] as! [[String: Any]])[0]
    XCTAssertEqual(finish["finish_reason"] as? String, "length")
    XCTAssertEqual(transport.eventData.last, "[DONE]")
  }

  func testNonStreamingGetsOneCompletion() throws {
    let transport = RecordingTransport()
    let writer = ChatCompletionsResponseWriter(
      transport: transport, isStreaming: false, includesUsage: false, model: "m")
    writer.start()
    writer.startTurn(inputTokens: 10, cachedInputTokens: 4)
    writer.appendReasoning("Think")
    writer.appendFunctionCall(name: "f", arguments: #"{"a":1}"#)
    writer.finish(usage: usage, incompleteReason: nil)

    XCTAssertTrue(transport.events.isEmpty)
    XCTAssertEqual(transport.status, 200)
    let completion = try JSONSerialization.jsonObject(with: transport.body!) as! [String: Any]
    XCTAssertEqual(completion["object"] as? String, "chat.completion")
    let choice = (completion["choices"] as! [[String: Any]])[0]
    XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
    let message = choice["message"] as! [String: Any]
    XCTAssertTrue(message["content"] is NSNull)
    XCTAssertEqual(message["reasoning_content"] as? String, "Think")
    let function =
      ((message["tool_calls"] as! [[String: Any]])[0])["function"] as! [String: Any]
    XCTAssertEqual(function["arguments"] as? String, #"{"a":1}"#)
  }

  func testFailureMidStreamIsAnErrorChunk() {
    let transport = RecordingTransport()
    let writer = ChatCompletionsResponseWriter(
      transport: transport, isStreaming: true, includesUsage: false, model: "m")
    writer.start()
    writer.fail(status: 400, type: "invalid_request_error", code: "c", message: "Long")
    XCTAssertNil(transport.status)
    XCTAssertNil(transport.events.last?.name)
    XCTAssertEqual(
      (transport.events.last?.object["error"] as? [String: Any])?["code"] as? String, "c")
    XCTAssertTrue(transport.didClose)
  }
}

final class WireProtocolTests: XCTestCase {
  func testEachEndpointHasItsProtocol() {
    XCTAssertEqual(WireProtocol(path: "/v1/responses"), .openAIResponses)
    XCTAssertEqual(WireProtocol(path: "/v1/messages"), .anthropicMessages)
    XCTAssertEqual(WireProtocol(path: "/v1/chat/completions"), .openAIChatCompletions)
    XCTAssertNil(WireProtocol(path: "/v1/completions"))
    XCTAssertEqual(WireProtocol(headers: ["anthropic-version": "2023-06-01"]), .anthropicMessages)
    XCTAssertEqual(WireProtocol(headers: [:]), .openAIResponses)
  }

  func testModelsListServesEveryProtocolsClients() {
    let models = WireProtocol.modelsObject(model: "a")
    XCTAssertEqual(models["object"] as? String, "list")
    XCTAssertEqual(models["first_id"] as? String, "a")
    XCTAssertEqual(models["has_more"] as? Bool, false)
    let model = (models["data"] as! [[String: Any]])[0]
    XCTAssertEqual(model["id"] as? String, "a")
    XCTAssertEqual(model["object"] as? String, "model")
    XCTAssertEqual(model["type"] as? String, "model")
    XCTAssertNotNil(model["created"] as? Int)
    XCTAssertNotNil(model["created_at"] as? String)
    XCTAssertTrue(WireProtocol.modelsObject(model: nil)["first_id"] is NSNull)
  }
}
