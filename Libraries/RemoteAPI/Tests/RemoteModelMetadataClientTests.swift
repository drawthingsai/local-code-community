import Foundation
import XCTest

@testable import RemoteAPI

final class RemoteModelMetadataClientTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.handler = nil
    super.tearDown()
  }

  func testCompatibleDiscoveryAndStandardMetadataWithoutAuthentication() throws {
    for (base, prefix) in [
      ("http://localhost:1234", ""),
      ("https://gateway.example", ""),
      ("https://gateway.example/v1/chat/completions/", "/v1"),
    ] {
      let endpoint = try RemoteProviderEndpoint(
        provider: .openAICompatible, baseURL: URL(string: base)!, model: "custom-chat")
      MockURLProtocol.handler = { request, urlProtocol in
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.path, "\(prefix)/models")
        urlProtocol.respond(status: 200, chunks: [Data(#"{"data":[{"id":"custom-chat"}]}"#.utf8)])
      }
      let models = expectation(description: "models")
      _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetchModels(
        endpoint: endpoint, authorization: RemoteUnauthenticatedAuthorization()
      ) {
        XCTAssertEqual(try? $0.get(), ["custom-chat"])
        models.fulfill()
      }
      wait(for: [models], timeout: 2)
      MockURLProtocol.handler = { request, urlProtocol in
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.url?.path, "\(prefix)/models/custom-chat")
        urlProtocol.respond(
          status: 200,
          chunks: [
            Data(
              #"{"id":"custom-chat","object":"model","created":1686935002,"owned_by":"local"}"#.utf8
            )
          ])
      }
      let limits = expectation(description: "fallback limits")
      _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
        endpoint: endpoint, authorization: RemoteUnauthenticatedAuthorization()
      ) {
        XCTAssertEqual(try? $0.get(), .openAICompatibleFallback)
        limits.fulfill()
      }
      wait(for: [limits], timeout: 2)
    }
  }

  func testCompatibleFallbackOnlyForMissingMetadataRoutes() throws {
    let fallback = RemoteModelLimits(contextWindowTokens: 16_384, maximumOutputTokens: 4_096)
    for status in [301, 302, 307, 400, 401, 403, 404, 405, 429, 500, 501, 503] {
      MockURLProtocol.handler = { _, urlProtocol in
        urlProtocol.respond(
          status: status, chunks: [Data(#"{"error":{"message":"secret-key error"}}"#.utf8)])
      }
      let done = expectation(description: "status \(status)")
      _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
        endpoint: try RemoteProviderEndpoint(
          provider: .openAICompatible, baseURL: URL(string: "https://gateway.example/v1")!,
          model: "m"),
        authorization: RemoteAPIKeyAuthorization(apiKey: "secret-key"), fallbackLimits: fallback
      ) {
        if [404, 405, 501].contains(status) {
          XCTAssertEqual(try? $0.get(), fallback)
        } else {
          XCTAssertEqual($0, .failure(.httpStatus(status, "[REDACTED] error")))
        }
        done.fulfill()
      }
      wait(for: [done], timeout: 2)
    }
    let done = expectation(description: "other providers still require metadata")
    MockURLProtocol.handler = { _, urlProtocol in
      urlProtocol.respond(status: 404, chunks: [])
    }
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
      endpoint: try RemoteProviderEndpoint(provider: .anthropic, model: "m"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "key")
    ) {
      XCTAssertEqual($0, .failure(.httpStatus(404, "Request failed.")))
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }

  func testMetadataDoesNotFollowCrossHostRedirect() throws {
    var requestedHosts = [String]()
    MockURLProtocol.handler = { request, urlProtocol in
      requestedHosts.append(request.url?.host ?? "")
      let redirect = HTTPURLResponse(
        url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
        headerFields: ["Location": "https://attacker.example/v1/models/m"])!
      urlProtocol.client?.urlProtocol(
        urlProtocol,
        wasRedirectedTo: URLRequest(url: URL(string: "https://attacker.example/v1/models/m")!),
        redirectResponse: redirect)
      // When the task delegate rejects the redirect, the redirect response is the final one.
      urlProtocol.client?.urlProtocol(
        urlProtocol, didReceive: redirect, cacheStoragePolicy: .notAllowed)
      urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }
    let done = expectation(description: "redirect rejected")
    var result: Result<RemoteModelLimits, RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
      endpoint: try RemoteProviderEndpoint(
        provider: .openAICompatible, baseURL: URL(string: "https://gateway.example/v1")!,
        model: "m"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "key")
    ) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 2)

    XCTAssertEqual(requestedHosts, ["gateway.example"])
    XCTAssertEqual(result, .failure(.httpStatus(302, "Request failed.")))
  }

  func testCompatibleFallbackPreservesPublishedLimitsAndRejectsMalformedMetadata() throws {
    let fallback = RemoteModelLimits(contextWindowTokens: 16_384, maximumOutputTokens: 4_096)
    let cases: [(String, RemoteModelLimits?)] = [
      (
        #"{"id":"m","context_length":32768,"max_tokens":8192}"#,
        RemoteModelLimits(contextWindowTokens: 32_768, maximumOutputTokens: 8_192)
      ),
      (
        #"{"id":"m","context_length":4096}"#,
        RemoteModelLimits(contextWindowTokens: 4_096, maximumOutputTokens: 4_096)
      ),
      (
        #"{"id":"m","max_tokens":1024}"#,
        RemoteModelLimits(contextWindowTokens: 16_384, maximumOutputTokens: 1_024)
      ),
      (
        #"{"context_length":32768,"max_tokens":8192}"#,
        RemoteModelLimits(contextWindowTokens: 32_768, maximumOutputTokens: 8_192)
      ),
      (#"{}"#, fallback),
      (#"{"id":"m"}"#, fallback),
      (#"{"id":"another-model"}"#, fallback),
      (
        #"{"id":"another-model","context_length":131072,"max_tokens":32768}"#,
        RemoteModelLimits(contextWindowTokens: 131_072, maximumOutputTokens: 32_768)
      ),
      (#"{"id":"canonical-model","context_length":2048}"#, nil),
      (
        #"{"max_tokens":1024}"#,
        RemoteModelLimits(contextWindowTokens: 16_384, maximumOutputTokens: 1_024)
      ),
      (#"[]"#, nil),
      (#"{"id":"m","error":{"message":"invalid"}}"#, nil),
      (#"{"error":{"message":"invalid"}}"#, nil),
      ("<html>Sign in</html>", nil),
    ]
    for (body, expected) in cases {
      MockURLProtocol.handler = { _, urlProtocol in
        urlProtocol.respond(status: 200, chunks: [Data(body.utf8)])
      }
      let done = expectation(description: "metadata \(body)")
      _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
        endpoint: try RemoteProviderEndpoint(provider: .openAICompatible, model: "m"),
        authorization: RemoteUnauthenticatedAuthorization(), fallbackLimits: fallback
      ) {
        if let expected {
          XCTAssertEqual(try? $0.get(), expected)
          if expected.contextWindowTokens == 4_096, let limits = try? $0.get() {
            let configuration = RemoteAgentConfiguration(
              contextWindowTokens: limits.contextWindowTokens,
              reservedOutputTokens: limits.maximumOutputTokens)
            XCTAssertEqual(configuration.reservedOutputTokens, 1_365)
          }
        } else {
          XCTAssertEqual($0, .failure(.limitsUnavailable))
        }
        done.fulfill()
      }
      wait(for: [done], timeout: 2)
    }
  }

  func testOpenRouterLoadsModelLimitsFromSingleModelEndpoint() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://openrouter.ai/api/v1/model/vendor/model:free")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
      urlProtocol.respond(
        status: 200,
        chunks: [
          Data(
            #"{"data":{"context_length":262144,"top_provider":{"context_length":131072,"max_completion_tokens":32768}}}"#
              .utf8)
        ])
    }
    let expectation = expectation(description: "metadata")
    var result: Result<RemoteModelLimits, RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
      endpoint: try RemoteProviderEndpoint(
        provider: .openRouter, model: "vendor/model:free"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(
      try result?.get(),
      RemoteModelLimits(contextWindowTokens: 131_072, maximumOutputTokens: 32_768))
  }

  func testLocalCodeUsesRouterModelMetadataWithBearerCredential() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://router.test/v1/openrouter/model/vendor/model")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dk_key")
      urlProtocol.respond(
        status: 200,
        chunks: [
          Data(
            #"{"data":{"context_length":131072,"top_provider":{"max_completion_tokens":16384}}}"#
              .utf8)
        ])
    }
    let expectation = expectation(description: "LocalCode metadata")
    var result: Result<RemoteModelLimits, RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
      endpoint: try RemoteProviderEndpoint(
        provider: .localCode,
        baseURL: URL(string: "https://router.test/v1/openrouter")!,
        model: "vendor/model"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "dk_key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(
      try result?.get(),
      RemoteModelLimits(contextWindowTokens: 131_072, maximumOutputTokens: 16_384))
  }

  func testAnthropicLoadsPublishedInputAndOutputLimits() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://api.anthropic.com/v1/models/claude-sonnet-4-5")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      urlProtocol.respond(
        status: 200,
        chunks: [
          Data(#"{"max_input_tokens":200000,"max_tokens":64000}"#.utf8)
        ])
    }
    let expectation = expectation(description: "metadata")
    var result: Result<RemoteModelLimits, RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
      endpoint: try RemoteProviderEndpoint(provider: .anthropic, model: "claude-sonnet-4-5"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(
      try result?.get(),
      RemoteModelLimits(contextWindowTokens: 200_000, maximumOutputTokens: 64_000))
  }

  func testChatGPTOAuthLoadsCodexModelLimits() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "account")
      urlProtocol.respond(
        status: 200,
        chunks: [
          Data(
            #"{"models":[{"slug":"gpt-codex","context_window":200000,"effective_context_window_percent":95}]}"#
              .utf8)
        ])
    }
    let expectation = expectation(description: "OAuth metadata")
    var result: Result<RemoteModelLimits, RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetch(
      endpoint: try RemoteProviderEndpoint(
        provider: .openAI, model: "gpt-codex"),
      authorization: TestAuthorization(
        RemoteRequestAuthorization(kind: .oauth, token: "token", accountID: "account"))
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(
      try result?.get(),
      RemoteModelLimits(contextWindowTokens: 200_000, maximumOutputTokens: 10_000))
  }

  func testOpenRouterListsTrimmedDeduplicatedModels() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
      urlProtocol.respond(
        status: 200,
        chunks: [
          Data(
            #"{"data":[{"id":" vendor/model "},{"id":"other/model"},{"id":"vendor/model"},{"id":"  "}]}"#
              .utf8)
        ])
    }
    let expectation = expectation(description: "OpenRouter models")
    var result: Result<[String], RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetchModels(
      endpoint: try RemoteProviderEndpoint(provider: .openRouter, model: "vendor/model"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(try result?.get(), ["vendor/model", "other/model"])
  }

  func testLocalCodeListsModelsThroughManagedRouter() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://router.test/v1/openrouter/models")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dk_key")
      urlProtocol.respond(
        status: 200, chunks: [Data(#"{"data":[{"id":"vendor/model"}]}"#.utf8)])
    }
    let expectation = expectation(description: "LocalCode models")
    var result: Result<[String], RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetchModels(
      endpoint: try RemoteProviderEndpoint(
        provider: .localCode,
        baseURL: URL(string: "https://router.test/v1/openrouter")!,
        model: "vendor/model"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "dk_key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(try result?.get(), ["vendor/model"])
  }

  func testOpenAICompatibleListsModelsFromCustomEndpointWithoutSelectedModel() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(request.url?.absoluteString, "https://gateway.example/v1/models")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
      urlProtocol.respond(
        status: 200,
        chunks: [Data(#"{"data":[{"id":"custom-chat"},{"id":"custom-reasoning"}]}"#.utf8)])
    }
    let expectation = expectation(description: "OpenAI-compatible models")
    var result: Result<[String], RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetchModels(
      accountEndpoint: try RemoteProviderAccountEndpoint(
        provider: .openAICompatible,
        baseURL: URL(string: "https://gateway.example/v1")!),
      authorization: RemoteAPIKeyAuthorization(apiKey: "key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(try result?.get(), ["custom-chat", "custom-reasoning"])
  }

  func testChatGPTOAuthListsCodexModelsWithoutSelectedModel() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(
        request.url?.absoluteString,
        "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "chatgpt-account-id"), "account")
      urlProtocol.respond(
        status: 200,
        chunks: [
          Data(
            #"{"models":[{"slug":"gpt-codex"},{"model":"gpt-codex-mini"},{"slug":" gpt-codex "}]}"#
              .utf8)
        ])
    }
    let expectation = expectation(description: "OAuth models")
    var result: Result<[String], RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetchModels(
      accountEndpoint: try RemoteProviderAccountEndpoint(provider: .openAI),
      authorization: TestAuthorization(
        RemoteRequestAuthorization(kind: .oauth, token: "token", accountID: "account"))
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(try result?.get(), ["gpt-codex", "gpt-codex-mini"])
  }

  func testAnthropicListsEveryPageWithoutSelectedModel() throws {
    MockURLProtocol.handler = { request, urlProtocol in
      let components = URLComponents(
        url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
      XCTAssertEqual(components?.scheme, "https")
      XCTAssertEqual(components?.host, "api.anthropic.com")
      XCTAssertEqual(components?.path, "/v1/models")
      XCTAssertEqual(
        components?.queryItems?.first(where: { $0.name == "limit" })?.value, "1000")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
      XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
      if components?.queryItems?.first(where: { $0.name == "after_id" })?.value == nil {
        urlProtocol.respond(
          status: 200,
          chunks: [
            Data(
              #"{"data":[{"id":"claude-one"},{"id":" claude-two "}],"has_more":true,"last_id":"page-one"}"#
                .utf8)
          ])
      } else {
        XCTAssertEqual(
          components?.queryItems?.first(where: { $0.name == "after_id" })?.value,
          "page-one")
        urlProtocol.respond(
          status: 200,
          chunks: [
            Data(
              #"{"data":[{"id":"claude-two"},{"id":"claude-three"}],"has_more":false,"last_id":"page-two"}"#
                .utf8)
          ])
      }
    }
    let expectation = expectation(description: "Anthropic models")
    var result: Result<[String], RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetchModels(
      accountEndpoint: try RemoteProviderAccountEndpoint(provider: .anthropic),
      authorization: RemoteAPIKeyAuthorization(apiKey: "key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(try result?.get(), ["claude-one", "claude-two", "claude-three"])
  }

  func testModelListHTTPErrorRedactsCredential() throws {
    MockURLProtocol.handler = { _, urlProtocol in
      urlProtocol.respond(
        status: 401,
        chunks: [Data(#"{"error":{"message":"key secret-key was rejected"}}"#.utf8)])
    }
    let expectation = expectation(description: "redacted error")
    var result: Result<[String], RemoteModelMetadataError>?
    _ = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration()).fetchModels(
      endpoint: try RemoteProviderEndpoint(provider: .openRouter, model: "vendor/model"),
      authorization: RemoteAPIKeyAuthorization(apiKey: "secret-key")
    ) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(
      result, .failure(.httpStatus(401, "key [REDACTED] was rejected")))
  }

  func testCancellingModelListCompletesOnce() throws {
    MockURLProtocol.handler = { _, _ in }
    let expectation = expectation(description: "cancelled")
    var results = [Result<[String], RemoteModelMetadataError>]()
    let request = RemoteModelMetadataClient(sessionConfiguration: mockSessionConfiguration())
      .fetchModels(
        endpoint: try RemoteProviderEndpoint(provider: .openRouter, model: "vendor/model"),
        authorization: RemoteAPIKeyAuthorization(apiKey: "key")
      ) {
        results.append($0)
        expectation.fulfill()
      }
    request.cancel()
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(results, [.failure(.cancelled)])
  }
}
