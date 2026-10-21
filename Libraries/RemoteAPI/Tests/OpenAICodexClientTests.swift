import Foundation
import XCTest

@testable import RemoteAPI

final class OpenAICodexClientTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.handler = nil
    super.tearDown()
  }

  func testStreamsNeutralContentAndReplaysProviderMetadata() throws {
    let expectation = expectation(description: "Codex completion")
    let client = OpenAIResponsesClient(
      codexModel: "gpt-codex-test",
      authorization: TestAuthorization(
        RemoteRequestAuthorization(
          kind: .oauth, token: "oauth-token", accountID: "account-1")),
      sessionConfiguration: mockSessionConfiguration(), reasoningEffort: .high)
    let previousReasoning = RemoteJSONValue.object([
      "type": .string("reasoning"), "id": .string("rs_previous"),
      "summary": .array([]), "encrypted_content": .string("encrypted-previous"),
    ])
    let previousCall = RemoteToolCall(
      id: "call_previous", name: "read", arguments: #"{"path":"README.md"}"#,
      providerMetadata: [.object(["item_id": .string("fc_previous")])])
    let previousMessage = RemoteJSONValue.object([
      "type": .string("message"), "id": .string("msg_previous"),
      "role": .string("assistant"), "status": .string("completed"),
      "phase": .string("final_answer"),
      "content": .array([
        .object(["type": .string("output_text"), "text": .string("Checking")])
      ]),
    ])
    let previousFunctionCall = RemoteJSONValue.object([
      "type": .string("function_call"), "id": .string("fc_previous"),
      "call_id": .string("call_previous"), "name": .string("read"),
      "arguments": .string(#"{"path":"README.md"}"#), "status": .string("completed"),
    ])
    let tool = RemoteFunctionTool(
      name: "read", description: "Read a file",
      parameters: .object(["type": .string("object")]))

    MockURLProtocol.handler = { request, protocolClient in
      XCTAssertEqual(
        request.url?.absoluteString, "https://chatgpt.com/backend-api/codex/responses")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "account-1")
      XCTAssertEqual(request.value(forHTTPHeaderField: "originator"), "local-code")
      let data = try XCTUnwrap(requestBody(request))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(body["instructions"] as? String, "System")
      XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
      XCTAssertEqual(body["store"] as? Bool, false)
      XCTAssertEqual(
        (body["reasoning"] as? [String: Any])?["context"] as? String, "all_turns")
      XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
      let input = try XCTUnwrap(body["input"] as? [[String: Any]])
      XCTAssertEqual(
        input.compactMap { $0["type"] as? String },
        ["message", "reasoning", "message", "function_call", "function_call_output"])
      XCTAssertEqual(input[1]["id"] as? String, "rs_previous")
      XCTAssertEqual(input[2]["id"] as? String, "msg_previous")
      XCTAssertEqual(input[2]["phase"] as? String, "final_answer")
      XCTAssertEqual(input[2]["status"] as? String, "completed")
      XCTAssertEqual(input[3]["id"] as? String, "fc_previous")
      XCTAssertEqual(input[3]["call_id"] as? String, "call_previous")
      let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
      XCTAssertEqual(tools.first?["name"] as? String, "read")
      XCTAssertNil(tools.first?["function"])

      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            """
            data: {"type":"response.output_item.done","output_index":0,"item":{"type":"reasoning","id":"rs_new","summary":[{"type":"summary_text","text":"Inspect first."}],"encrypted_content":"encrypted-new"}}

            data: {"type":"response.output_text.delta","delta":"I will inspect it."}

            data: {"type":"response.output_item.done","output_index":2,"item":{"type":"function_call","id":"fc_new","call_id":"call_new","name":"read","arguments":"{\\"path\\":\\"Package.swift\\"}","status":"completed"}}

            data: {"type":"response.output_item.done","output_index":1,"item":{"type":"message","id":"msg_new","role":"assistant","status":"completed","phase":"final_answer","content":[{"type":"output_text","text":"I will inspect it."}]}}

            data: {"type":"response.completed","response":{"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}

            """.utf8)
        ])
    }

    _ = client.streamChat(
      messages: [
        .system("System"), .assistant(""), .user("Continue"),
        RemoteTranscriptEntry(
          role: .assistant,
          content: [
            .thinking(RemoteThinking(providerMetadata: [previousReasoning])), .text("Checking"),
            .toolCall(previousCall),
          ], source: client.modelIdentity,
          providerOutputItems: [previousReasoning, previousMessage, previousFunctionCall]),
        .toolResult(
          "file contents", toolCallID: "call_previous", toolName: "read", isError: false),
      ], tools: [tool], progress: { _ in }
    ) { result in
      switch result {
      case .success(let completion):
        XCTAssertEqual(completion.text, "I will inspect it.")
        XCTAssertEqual(completion.content.remoteThinking.first?.text, "Inspect first.")
        XCTAssertNil(completion.content.remoteThinking.first?.redactedData)
        XCTAssertEqual(
          completion.content.remoteThinking.first?.providerMetadata?.first?.objectString(
            for: "id"), "rs_new")
        XCTAssertEqual(
          completion.content.remoteThinking.first?.providerMetadata?.first?.objectString(
            for: "encrypted_content"), "encrypted-new")
        XCTAssertEqual(completion.toolCalls.first?.id, "call_new")
        XCTAssertEqual(
          completion.toolCalls.first?.providerMetadata?.first?.objectString(for: "item_id"),
          "fc_new")
        XCTAssertEqual(
          completion.providerOutputItems?.compactMap { $0.objectString(for: "id") },
          ["rs_new", "msg_new", "fc_new"])
        XCTAssertEqual(
          completion.providerOutputItems?[1].objectString(for: "phase"), "final_answer")
        XCTAssertEqual(
          completion.providerOutputItems?[2].objectString(for: "status"), "completed")
        XCTAssertEqual(completion.usage?.totalTokens, 15)
      case .failure(let error):
        XCTFail("Unexpected Codex stream error: \(error)")
      }
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
  }
}
