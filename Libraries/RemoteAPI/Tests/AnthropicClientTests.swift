import Foundation
import XCTest

@testable import RemoteAPI

final class AnthropicClientTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.handler = nil
    super.tearDown()
  }

  func testTranslatesToolHistoryAndStreamsToolUse() throws {
    let expectation = expectation(description: "completion")
    let configuration = try AnthropicConfiguration(model: "test-claude")
    let client = AnthropicClient(
      configuration: configuration,
      authorization: RemoteAPIKeyAuthorization(apiKey: "anthropic-key"),
      sessionConfiguration: mockSessionConfiguration(), reasoningEffort: .max)
    let calls = [
      RemoteToolCall(id: "call-a", name: "read", arguments: #"{"path":"a"}"#),
      RemoteToolCall(id: "call-b", name: "datetime", arguments: "{}"),
    ]
    let tool = RemoteFunctionTool(
      name: "read", description: "Read a file",
      parameters: .object([
        "type": .string("object"),
        "properties": .object(["path": .object(["type": .string("string")])]),
      ]))

    MockURLProtocol.handler = { request, protocolClient in
      XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      let data = try XCTUnwrap(requestBody(request))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let system = try XCTUnwrap(body["system"] as? [[String: Any]])
      XCTAssertEqual(system.compactMap { $0["text"] as? String }, ["System"])
      XCTAssertEqual(
        (system.last?["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
      XCTAssertEqual((body["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
      XCTAssertEqual(
        (body["output_config"] as? [String: Any])?["effort"] as? String, "max")
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
      let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
      XCTAssertEqual(
        assistant.compactMap { $0["type"] as? String },
        ["thinking", "text", "tool_use", "tool_use"])
      XCTAssertEqual(assistant[0]["thinking"] as? String, "")
      XCTAssertEqual(assistant[0]["signature"] as? String, "prior-signature")
      let results = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
      XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["call-a", "call-b"])
      XCTAssertEqual(results[1]["is_error"] as? Bool, true)
      XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "anthropic-key"))

      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            """
            data: {"type":"message_start","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":5}}}

            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Need the file."}}

            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"new-signature"}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

            data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Checking"}}

            data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"read","input":{}}}

            data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"README.md\\"}"}}

            data: {"type":"content_block_stop","index":2}

            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}

            data: {"type":"message_stop"}

            """.utf8)
        ])
    }
    _ = client.streamChat(
      messages: [
        .system("System"),
        .assistant(
          nil, thinking: RemoteThinking(text: "Reasoning from another model must not be replayed."),
          source: RemoteModelIdentity(provider: "other", model: "other-model")),
        .user("Read"),
        .assistant(
          "Working", thinking: RemoteThinking(signature: "prior-signature"),
          toolCalls: calls, source: client.modelIdentity),
        .toolResult(
          "contents", toolCallID: "call-a", toolName: "read", isError: false),
        .toolResult(
          "failed", toolCallID: "call-b", toolName: "datetime", isError: true),
      ], tools: [tool], progress: { _ in }
    ) { result in
      switch result {
      case .success(let completion):
        XCTAssertEqual(completion.text, "Checking")
        XCTAssertEqual(completion.content.remoteThinking.first?.text, "Need the file.")
        XCTAssertEqual(completion.content.remoteThinking.first?.signature, "new-signature")
        XCTAssertEqual(completion.toolCalls.first?.id, "toolu_1")
        XCTAssertEqual(completion.toolCalls.first?.arguments, #"{"path":"README.md"}"#)
        XCTAssertEqual(completion.usage?.totalTokens, 17)
        XCTAssertEqual(completion.stopReason, "tool_use")
      case .failure(let error):
        XCTFail("Unexpected Claude stream error: \(error)")
      }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
  }

  func testReplaysToolArgumentsWithTheSameBytesEveryRequest() throws {
    // Every request decodes the stored arguments into a new dictionary, whose key order can
    // differ from the previous one's. The encoded request must not differ, or the prompt cache
    // misses from the first replayed tool call on.
    let model = RemoteModelIdentity(provider: "anthropic", model: "test-claude")
    let call = RemoteToolCall(
      id: "call-a", name: "bash",
      arguments:
        #"{"command":"ls","description":"List files","timeout":"30","workdir":"tmp","background":false}"#
    )
    let transcript: [RemoteTranscriptEntry] = [
      .system("System"), .user("List the files"),
      .assistant(toolCalls: [call], source: model),
      .toolResult("README.md", toolCallID: "call-a", toolName: "bash", isError: false),
    ]
    let bodies = try Set(
      (0..<50).map { _ in
        try RemoteRequestBody.encode(
          AnthropicRequest(
            model: "test-claude", maxTokens: 512, transcript: transcript, remoteTools: [],
            currentModel: model, usesOAuth: false, reasoningEffort: nil))
      })
    XCTAssertEqual(bodies.count, 1)
    let text = try XCTUnwrap(bodies.first.flatMap { String(data: $0, encoding: .utf8) })
    XCTAssertTrue(
      text.contains(
        #""input":{"background":false,"command":"ls","description":"List files","timeout":"30","workdir":"tmp"}"#
      ), text)
  }

  func testRejectsMalformedToolArgumentsAndIncompleteStream() throws {
    var accumulator = AnthropicStreamAccumulator()
    _ = try accumulator.append(
      #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu","name":"read","input":{}}}"#
    )
    _ = try accumulator.append(
      #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}}"#
    )
    XCTAssertThrowsError(
      try accumulator.append(#"{"type":"content_block_stop","index":0}"#))

    let expectation = expectation(description: "incomplete stream")
    let configuration = try AnthropicConfiguration(model: "test-claude")
    let client = AnthropicClient(
      configuration: configuration, authorization: RemoteAPIKeyAuthorization(apiKey: "key"),
      sessionConfiguration: mockSessionConfiguration())
    MockURLProtocol.handler = { _, protocolClient in
      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"partial\"}}\n\n"
              .utf8)
        ])
    }
    _ = client.streamChat(messages: [.user("Hello")], tools: [], progress: { _ in }) { result in
      guard case .failure(.malformedStream(let message)) = result else {
        XCTFail("Expected malformed stream")
        expectation.fulfill()
        return
      }
      XCTAssertTrue(message.contains("message_stop"))
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
  }

  func testPreservesStatuslessStreamErrors() throws {
    var accumulator = AnthropicStreamAccumulator()
    XCTAssertThrowsError(
      try accumulator.append(
        #"{"type":"error","error":{"type":"unknown_error","message":"stream failed"}}"#)
    ) { error in
      XCTAssertEqual(error as? RemoteChatError, .providerStream("stream failed"))
    }
  }

  func testOAuthUsesClaudeCodeIdentityAndPreservesLocalToolNames() throws {
    let expectation = expectation(description: "OAuth completion")
    let client = AnthropicClient(
      configuration: try AnthropicConfiguration(model: "claude-test"),
      authorization: TestAuthorization(
        RemoteRequestAuthorization(kind: .oauth, token: "oauth-token")),
      sessionConfiguration: mockSessionConfiguration())
    let tool = RemoteFunctionTool(
      name: "read", description: "Read a file",
      parameters: .object(["type": .string("object")]))

    MockURLProtocol.handler = { request, protocolClient in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
      XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "anthropic-beta"),
        "claude-code-20250219,oauth-2025-04-20")
      let data = try XCTUnwrap(requestBody(request))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let system = try XCTUnwrap(body["system"] as? [[String: Any]])
      XCTAssertEqual(
        system.first?["text"] as? String,
        "You are Claude Code, Anthropic's official CLI for Claude.")
      XCTAssertEqual(system.last?["text"] as? String, "Local Code system")
      XCTAssertNil(system.first?["cache_control"])
      XCTAssertNotNil(system.last?["cache_control"])
      let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
      XCTAssertEqual(tools.first?["name"] as? String, "Read")

      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            """
            data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}}

            data: {"type":"content_block_stop","index":0}

            data: {"type":"message_stop"}

            """.utf8)
        ])
    }
    _ = client.streamChat(
      messages: [.system("Local Code system"), .user("Read")], tools: [tool], progress: { _ in }
    ) { result in
      switch result {
      case .success(let completion):
        XCTAssertEqual(completion.toolCalls.first?.name, "read")
      case .failure(let error):
        XCTFail("Unexpected Claude OAuth error: \(error)")
      }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
  }
}
