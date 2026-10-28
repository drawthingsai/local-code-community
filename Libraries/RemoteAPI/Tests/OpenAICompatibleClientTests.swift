import Foundation
import XCTest

@testable import RemoteAPI

final class OpenAICompatibleClientTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.handler = nil
    super.tearDown()
  }

  func testOpenAIRequiresSignInAndKeepsCompatibleAPIIndependent() throws {
    let openAI = try RemoteProviderEndpoint(provider: .openAI, model: "gpt-codex")
    XCTAssertThrowsError(
      try openAI.makeChatProvider(
        authorization: RemoteAPIKeyAuthorization(apiKey: "key"), maximumOutputTokens: 8_192))
    XCTAssertThrowsError(
      try RemoteProviderAccountEndpoint(
        provider: .openAI, baseURL: URL(string: "https://custom.example/v1")))
    XCTAssertTrue(
      try openAI.makeChatProvider(
        authorization: TestAuthorization(
          RemoteRequestAuthorization(kind: .oauth, token: "token", accountID: "account")),
        maximumOutputTokens: 8_192) is OpenAIResponsesClient)

    let compatible = try RemoteProviderEndpoint(
      provider: .openAICompatible, baseURL: URL(string: "https://custom.example/v1"),
      model: "custom-model")
    XCTAssertTrue(
      try compatible.makeChatProvider(
        authorization: RemoteAPIKeyAuthorization(apiKey: "key"),
        maximumOutputTokens: 8_192) is OpenAICompatibleClient)
    let officialAPI = try RemoteProviderEndpoint(provider: .openAICompatible, model: "gpt-codex")
    XCTAssertThrowsError(
      try officialAPI.makeChatProvider(
        authorization: TestAuthorization(
          RemoteRequestAuthorization(kind: .oauth, token: "token", accountID: "account")),
        maximumOutputTokens: 8_192))
    XCTAssertNotEqual(openAI.provider, compatible.provider)
  }

  func testOpenAIUsesResponsesAndPreservesReasoningAcrossAllTurns() throws {
    let expectation = expectation(description: "completion")
    let configuration = try OpenAICompatibleConfiguration(
      baseURL: XCTUnwrap(URL(string: "https://api.openai.com")), model: "test-model")
    let endpoint = try RemoteProviderEndpoint(provider: .openAICompatible, model: "test-model")
    XCTAssertTrue(
      try endpoint.makeChatProvider(
        authorization: RemoteAPIKeyAuthorization(apiKey: "secret-key"),
        maximumOutputTokens: 8_192) is OpenAIResponsesClient)
    let client = OpenAIResponsesClient(
      configuration: configuration,
      authorization: RemoteAPIKeyAuthorization(apiKey: "secret-key"),
      sessionConfiguration: mockSessionConfiguration(), reasoningEffort: .max)
    let previousReasoning = RemoteJSONValue.object([
      "type": .string("reasoning"), "id": .string("rs_previous"),
      "summary": .array([]), "encrypted_content": .string("encrypted-previous"),
    ])
    let tool = RemoteFunctionTool(
      name: "read", description: "Read a file",
      parameters: .object(["type": .string("object")]))
    XCTAssertEqual(
      try JSONDecoder().decode(RemoteFunctionTool.self, from: JSONEncoder().encode(tool)), tool)
    MockURLProtocol.handler = { request, protocolClient in
      XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
      let data = try XCTUnwrap(requestBody(request))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, "test-model")
      XCTAssertEqual(body["stream"] as? Bool, true)
      XCTAssertEqual(body["store"] as? Bool, false)
      XCTAssertEqual(body["max_output_tokens"] as? Int, 8_192)
      XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
      XCTAssertEqual(
        (body["reasoning"] as? [String: Any])?["context"] as? String, "all_turns")
      XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "max")
      let input = try XCTUnwrap(body["input"] as? [[String: Any]])
      XCTAssertEqual(
        input.compactMap { $0["type"] as? String }, ["reasoning", "message", "message"])
      XCTAssertEqual(input.first?["id"] as? String, "rs_previous")
      let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
      XCTAssertEqual(tools.first?["name"] as? String, "read")
      XCTAssertNil(tools.first?["function"])
      XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "secret-key"))
      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            """
            data: {"type":"response.output_item.done","item":{"type":"reasoning","id":"rs_new","summary":[],"encrypted_content":"encrypted-new"}}

            data: {"type":"response.output_text.delta","delta":"Hi"}

            data: {"type":"response.completed","response":{"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}

            """.utf8)
        ])
    }
    var streamedText = ""
    _ = client.streamChat(
      messages: [
        .assistant(
          "Earlier",
          thinking: RemoteThinking(providerMetadata: [previousReasoning]),
          source: client.modelIdentity),
        .user("Hello"),
      ], tools: [tool],
      progress: { streamedText = $0.text },
      completion: { result in
        XCTAssertEqual(try? result.get().text, "Hi")
        XCTAssertEqual(streamedText, "Hi")
        expectation.fulfill()
      })
    wait(for: [expectation], timeout: 2)
  }

  func testHTTPFailureRedactsKeyAndCancellationCompletesOnce() throws {
    let failure = expectation(description: "failure")
    let configuration = try OpenAICompatibleConfiguration(
      baseURL: XCTUnwrap(URL(string: "https://example.com/v1")), model: "test-model")
    let client = OpenAICompatibleClient(
      configuration: configuration,
      authorization: RemoteAPIKeyAuthorization(apiKey: "secret-key"),
      sessionConfiguration: mockSessionConfiguration(), reasoningEffort: .low)
    MockURLProtocol.handler = { request, protocolClient in
      let data = try XCTUnwrap(requestBody(request))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(body["max_tokens"] as? Int, 8_192)
      XCTAssertNil(body["max_completion_tokens"])
      XCTAssertNil(body["stream_options"])
      XCTAssertEqual(body["reasoning_effort"] as? String, "low")
      XCTAssertNil(body["reasoning"])
      protocolClient.respond(
        status: 401,
        chunks: [Data("{\"error\":{\"message\":\"secret-key rejected\"}}".utf8)])
    }
    _ = client.streamChat(messages: [.user("Hello")], tools: [], progress: { _ in }) { result in
      guard case .failure(.provider(let status, let message)) = result else {
        XCTFail("Expected provider error")
        failure.fulfill()
        return
      }
      XCTAssertEqual(status, 401)
      XCTAssertFalse(message.contains("secret-key"))
      failure.fulfill()
    }
    wait(for: [failure], timeout: 2)

    let cancellation = expectation(description: "cancellation")
    let requestStarted = expectation(description: "request started")
    MockURLProtocol.handler = { _, _ in
      requestStarted.fulfill()
    }
    var completionCount = 0
    let request = client.streamChat(
      messages: [.user("Hello")], tools: [], progress: { _ in }
    ) { result in
      completionCount += 1
      XCTAssertEqual(result, .failure(.cancelled))
      cancellation.fulfill()
    }
    wait(for: [requestStarted], timeout: 2)
    request.cancel()
    wait(for: [cancellation], timeout: 2)
    XCTAssertEqual(completionCount, 1)
  }

  func testCompatibleServersReceiveValidEffortAndEffortInstructions() throws {
    func body(
      _ messages: [OpenAICompatibleMessage], effort: RemoteReasoningEffort?,
      usesOpenRouterReasoning: Bool = false
    ) throws -> [String: Any] {
      let request = OpenAICompatibleRequest(
        model: "qwen3.5:9b", messages: messages, tools: [], includeUsage: false,
        maximumOutputTokens: 512, usesMaxCompletionTokens: false, reasoningEffort: effort,
        usesOpenRouterReasoning: usesOpenRouterReasoning)
      return try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }
    let conversation = [
      OpenAICompatibleMessage(role: .system, content: "System"),
      OpenAICompatibleMessage(role: .user, content: "Hello"),
    ]
    for (effort, wireEffort, instruction) in [
      (RemoteReasoningEffort.low, "low", "Reasoning effort is set to low."),
      (.medium, "medium", nil),
      (.high, "high", "Reasoning effort is set to high."),
      (.max, "high", "Reasoning effort is set to max."),
    ] {
      let request = try body(conversation, effort: effort)
      XCTAssertEqual(request["reasoning_effort"] as? String, wireEffort)
      let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.count, 2)
      let system = try XCTUnwrap(messages[0]["content"] as? String)
      if let instruction {
        XCTAssertTrue(system.hasPrefix("System\n\n" + instruction), system)
      } else {
        XCTAssertEqual(system, "System")
      }
      XCTAssertEqual(messages[1]["content"] as? String, "Hello")
    }
    let withoutSystem = try XCTUnwrap(
      body([OpenAICompatibleMessage(role: .user, content: "Hello")], effort: .low)["messages"]
        as? [[String: Any]])
    XCTAssertEqual(withoutSystem.compactMap { $0["role"] as? String }, ["system", "user"])
    let noEffort = try body(conversation, effort: nil)
    XCTAssertNil(noEffort["reasoning_effort"])
    XCTAssertEqual((noEffort["messages"] as? [[String: Any]])?.first?["content"] as? String, "System")
    let openRouter = try body(conversation, effort: .max, usesOpenRouterReasoning: true)
    XCTAssertNil(openRouter["reasoning_effort"])
    XCTAssertEqual((openRouter["reasoning"] as? [String: Any])?["effort"] as? String, "max")
    XCTAssertEqual(
      (openRouter["messages"] as? [[String: Any]])?.first?["content"] as? String, "System")
  }

  func testLocalCodeUsesOpenRouterReasoningAndAdaptsOutputBudgetToAvailableCredits() throws {
    let expectation = expectation(description: "adapted completion")
    let configuration = try OpenAICompatibleConfiguration(
      baseURL: XCTUnwrap(URL(string: "https://router.example.com/v1/openrouter")),
      model: "openai/gpt-4o", maximumOutputTokens: 4_000)
    let client = OpenAICompatibleClient(
      configuration: configuration, authorization: RemoteAPIKeyAuthorization(apiKey: "key"),
      sessionConfiguration: mockSessionConfiguration(),
      modelIdentity: RemoteModelIdentity(
        provider: RemoteProvider.localCode.rawValue, model: "openai/gpt-4o"),
      reasoningEffort: .medium, usesOpenRouterReasoning: true)
    var requestCount = 0
    MockURLProtocol.handler = { request, protocolClient in
      requestCount += 1
      let data = try XCTUnwrap(requestBody(request))
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["assistant", "user"])
      XCTAssertNotNil(messages.first?["reasoning_details"])
      let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
      XCTAssertEqual(reasoning["exclude"] as? Bool, false)
      XCTAssertEqual(reasoning["effort"] as? String, "medium")
      XCTAssertNil(body["reasoning_effort"])
      if requestCount == 1 {
        XCTAssertEqual(body["max_tokens"] as? Int, 4_000)
        protocolClient.respond(
          status: 402,
          chunks: [
            Data(
              #"{"error":{"message":"You requested 4000 tokens, but can only afford 2750."}}"#
                .utf8)
          ])
      } else {
        XCTAssertEqual(body["max_tokens"] as? Int, 2_750)
        protocolClient.respond(
          status: 200,
          chunks: [
            Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"}}]}\n\n".utf8),
            Data(
              "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
                .utf8),
            Data("data: [DONE]\n\n".utf8),
          ])
      }
    }
    _ = client.streamChat(
      messages: [
        .assistant(
          "Earlier",
          thinking: RemoteThinking(
            providerMetadata: [
              .object([
                "type": .string("reasoning.encrypted"),
                "data": .string("encrypted-previous"),
                "id": .string("reasoning-previous"),
                "format": .string("openai-responses-v1"),
                "index": .number(0),
              ])
            ]),
          source: RemoteModelIdentity(
            provider: RemoteProvider.localCode.rawValue, model: "openai/gpt-4o")),
        .assistant(""),
        .assistant(
          nil, thinking: RemoteThinking(text: "Reasoning from another model must not be replayed."),
          source: RemoteModelIdentity(provider: "other", model: "other-model")),
        .user("Hello"),
      ], tools: [], progress: { _ in }
    ) {
      XCTAssertEqual(try? $0.get().text, "OK")
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
    XCTAssertEqual(requestCount, 2)
  }

  func testAdaptsOutputBudgetToStatedMaximumTokens() throws {
    let configuration = try OpenAICompatibleConfiguration(
      baseURL: XCTUnwrap(URL(string: "https://api.example.com/v1")), model: "m",
      maximumOutputTokens: 32_768)
    let client = OpenAICompatibleClient(
      configuration: configuration, authorization: RemoteAPIKeyAuthorization(apiKey: "key"),
      sessionConfiguration: mockSessionConfiguration())
    for (message, adapted) in [
      (
        "max_tokens is too large: 32768. This model supports at most 16384 completion tokens, whereas you provided 32768.",
        16_384
      ),
      ("Invalid max_tokens value, the valid range of max_tokens is [1, 8192]", 8_192),
      (
        "`max_tokens` must be less than or equal to `32768`, the maximum value for `max_tokens` is less than the `context_window` for this model",
        nil
      ),
      ("`max_completion_tokens` must be less than or equal to `4096`", 4_096),
      ("temperature must be less than or equal to 2", nil),
    ] as [(String, Int?)] {
      var maximumTokens = [Int]()
      MockURLProtocol.handler = { request, protocolClient in
        let body = try XCTUnwrap(
          JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
        maximumTokens.append(try XCTUnwrap(body["max_tokens"] as? Int))
        if maximumTokens.count == 1 {
          let error = try JSONSerialization.data(withJSONObject: ["error": ["message": message]])
          protocolClient.respond(status: 400, chunks: [error])
        } else {
          protocolClient.respond(
            status: 200,
            chunks: [
              Data(
                "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                  .utf8)
            ])
        }
      }
      let done = expectation(description: message)
      _ = client.streamChat(messages: [.user("Hello")], tools: [], progress: { _ in }) {
        XCTAssertEqual(try? $0.get().text, adapted == nil ? nil : "OK", message)
        done.fulfill()
      }
      wait(for: [done], timeout: 2)
      // The stated limit is retried only when it is below what was requested.
      XCTAssertEqual(maximumTokens, [32_768] + (adapted.map { [$0] } ?? []), message)
    }
  }

  func testStreamProgressIncludesReasoningBeforeText() throws {
    let configuration = try OpenAICompatibleConfiguration(
      baseURL: XCTUnwrap(URL(string: "http://localhost:11434/v1")), model: "qwen3.5:9b")
    let client = OpenAICompatibleClient(
      configuration: configuration, authorization: RemoteUnauthenticatedAuthorization(),
      sessionConfiguration: mockSessionConfiguration())
    MockURLProtocol.handler = { _, protocolClient in
      protocolClient.respond(
        status: 200,
        chunks: [
          "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning\":\"Check \"}}]}",
          "{\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"7 × 143.\"}}]}",
          "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"No.\"},\"finish_reason\":\"stop\"}]}",
        ].map { Data("data: \($0)\n\n".utf8) } + [Data("data: [DONE]\n\n".utf8)])
    }
    var snapshots = [RemoteStreamProgress]()
    let done = expectation(description: "reasoning stream")
    _ = client.streamChat(
      messages: [.user("Is 1001 prime?")], tools: [], progress: { snapshots.append($0) }
    ) { result in
      XCTAssertEqual(try? result.get().content.remoteThinkingText, "Check 7 × 143.")
      XCTAssertEqual(try? result.get().text, "No.")
      done.fulfill()
    }
    wait(for: [done], timeout: 2)

    XCTAssertEqual(snapshots.map(\.content.remoteThinkingText), ["Check ", "Check 7 × 143.", "Check 7 × 143."])
    XCTAssertEqual(snapshots.map(\.text), ["", "", "No."])
  }

  func testRejectsStreamThatEndsWithoutFinishReason() throws {
    let expectation = expectation(description: "incomplete stream")
    let configuration = try OpenAICompatibleConfiguration(
      baseURL: XCTUnwrap(URL(string: "https://openrouter.ai/api/v1")), model: "test-model")
    let client = OpenAICompatibleClient(
      configuration: configuration,
      authorization: RemoteAPIKeyAuthorization(apiKey: "key"),
      sessionConfiguration: mockSessionConfiguration())
    MockURLProtocol.handler = { _, protocolClient in
      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n"
              .utf8)
        ])
    }
    _ = client.streamChat(messages: [.user("Hello")], tools: [], progress: { _ in }) { result in
      guard case .failure(.malformedStream(let message)) = result else {
        XCTFail("Expected an incomplete-stream failure")
        expectation.fulfill()
        return
      }
      XCTAssertTrue(message.contains("finish_reason"))
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2)
  }

  func testRejectsInsecureConfigurationAndOversizedRequest() throws {
    XCTAssertThrowsError(
      try OpenAICompatibleConfiguration(baseURL: URL(string: "http://example.com")!, model: "m"))
    let expectation = expectation(description: "request limit")
    let configuration = try OpenAICompatibleConfiguration(
      baseURL: XCTUnwrap(URL(string: "https://example.com/v1")), model: "test-model",
      maximumRequestBytes: 10)
    let client = OpenAICompatibleClient(
      configuration: configuration, authorization: RemoteAPIKeyAuthorization(apiKey: "key"),
      sessionConfiguration: mockSessionConfiguration())
    _ = client.streamChat(messages: [.user("Hello")], tools: [], progress: { _ in }) { result in
      XCTAssertEqual(result, .failure(.requestTooLarge(maximumBytes: 10)))
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
  }
}
