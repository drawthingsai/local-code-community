import Foundation
import XCTest

@testable import RemoteAPI

final class RemoteEndpointTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.handler = nil
    super.tearDown()
  }

  func testHTTPIsRestrictedToExplicitCompatibleLocalEndpoints() throws {
    for host in [
      "localhost", "LOCALHOST", "localhost.", "llm.local", "llm.local.",
      "127.0.0.1", "127.0.1.2", "10.0.0.2", "172.16.0.1", "172.31.255.254",
      "192.168.1.10", "[::1]", "[fd12:3456::1]",
    ] {
      let url = try XCTUnwrap(URL(string: "http://\(host):1234/v1/"))
      let endpoint = try RemoteProviderEndpoint(
        provider: .openAICompatible, baseURL: url, model: "m")
      XCTAssertEqual(endpoint.baseURL.scheme, "http")
      XCTAssertEqual(endpoint.baseURL.port, 1234)
      for provider in [RemoteProvider.openAI, .openRouter, .anthropic, .localCode] {
        XCTAssertThrowsError(try RemoteProviderAccountEndpoint(provider: provider, baseURL: url))
      }
      XCTAssertThrowsError(try AnthropicConfiguration(model: "m", baseURL: url))
    }
    for host in [
      "example.com", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1",
      "0.0.0.0", "169.254.169.254", "localhost.example.com", "llm.local.example.com",
      "[::]", "[2001:4860::1]", "[::ffff:8.8.8.8]", "2130706433", "127.1",
    ] {
      XCTAssertThrowsError(
        try OpenAICompatibleConfiguration(
          baseURL: XCTUnwrap(URL(string: "http://\(host)/v1")), model: "m"), host)
    }
  }

  func testInvalidEndpointsCannotHideCredentialsOrOverrideRequests() throws {
    for value in [
      "https://user:secret@example.com/v1", "http://localhost@evil.example/v1",
      "https://example.com/v1?api_key=secret", "https://example.com/v1#fragment",
      "file:///v1", "ftp://localhost/v1", "https://example.com:0/v1",
      "https://example.com:65536/v1",
    ] {
      XCTAssertThrowsError(
        try RemoteProviderAccountEndpoint(
          provider: .openAICompatible, baseURL: XCTUnwrap(URL(string: value))), value)
    }
  }

  func testCompatibleRequestPathsPreserveCustomPrefixesAndCredentialIdentity() throws {
    for (base, expected) in [
      ("https://example.com", "https://example.com/chat/completions"),
      ("http://localhost:11434/", "http://localhost:11434/chat/completions"),
      ("https://example.com/v1/", "https://example.com/v1/chat/completions"),
      ("https://example.com/chat/completions", "https://example.com/chat/completions"),
      ("https://example.com/models", "https://example.com/chat/completions"),
      (
        "https://example.com/proxy%2Ftenant/v1/chat/completions",
        "https://example.com/proxy%2Ftenant/v1/chat/completions"
      ),
      ("https://example.com/proxy/api/v2", "https://example.com/proxy/api/v2/chat/completions"),
      (
        "https://example.com/proxy/v1/chat/completions/",
        "https://example.com/proxy/v1/chat/completions"
      ),
      ("https://example.com/v1/models", "https://example.com/v1/chat/completions"),
      ("https://example.com/v1/responses", "https://example.com/v1/chat/completions"),
      ("https://api.openai.com", "https://api.openai.com/v1/chat/completions"),
    ] {
      let url = try XCTUnwrap(URL(string: base))
      let account = try RemoteProviderAccountEndpoint(provider: .openAICompatible, baseURL: url)
      let configuration = try OpenAICompatibleConfiguration(baseURL: url, model: "m")
      XCTAssertEqual(configuration.endpointURL.absoluteString, expected)
      XCTAssertEqual(account.baseURL, configuration.baseURL)
    }
    // Existing Keychain accounts are keyed by the saved base URL, not the derived API path.
    XCTAssertEqual(
      try RemoteProviderAccountEndpoint(
        provider: .openAICompatible, baseURL: URL(string: "https://example.com")!
      ).baseURL.absoluteString,
      "https://example.com")
  }

  func testBothRequestDelegatesRestrictRedirectsToSameOrigin() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let stream = RemoteStreamingRequest(
      redactedSecret: "key", maximumEventBytes: 1024, maximumErrorBytes: 1024,
      progress: { _ in }, completion: { _ in }, handleEvent: { _ in .none },
      handleEnd: { throw RemoteChatError.emptyResponse })
    for (scheme, url, allowed) in [
      ("https", "https://example.com/v1/models/", true),
      ("https", "https://EXAMPLE.com:443/v1/models/", true),
      ("https", "http://example.com/v1/models", false),
      ("https", "https://other.example/v1/models", false),
      ("https", "https://example.com:8443/v1/models", false),
      ("https", "https://user:pass@example.com/v1/models", false),
      ("https", "file:///tmp/models", false),
      ("http", "https://example.com/v1/models", false),
    ] {
      let source = URL(string: "\(scheme)://example.com/v1/models")!
      let task = session.dataTask(with: source)
      let response = HTTPURLResponse(
        url: source, statusCode: 307, httpVersion: nil, headerFields: nil)!
      let request = URLRequest(url: URL(string: url)!)
      RemoteSessionDelegate().urlSession(
        session, task: task, willPerformHTTPRedirection: response, newRequest: request
      ) { XCTAssertEqual($0 != nil, allowed, url) }
      stream.urlSession(
        session, task: task, willPerformHTTPRedirection: response, newRequest: request
      ) { XCTAssertEqual($0 != nil, allowed, url) }
    }
    XCTAssertFalse(
      RemoteEndpointURL.permitsRedirect(
        from: URL(string: "http://localhost:1234/v1")!, to: URL(string: "http://localhost:5678/v1")!
      ))
  }

  func testEmptyAuthenticatedCredentialsNeverStartARequest() {
    for kind in [RemoteAuthenticationKind.apiKey, .oauth] {
      let done = expectation(description: "empty credential rejected")
      _ = RemoteAuthorizedRequest(
        authorization: EmptyAuthorization(kind: kind),
        failure: { error in
          guard case .authentication = error as? RemoteChatError else {
            XCTFail("Expected an authentication failure, got \(error)")
            done.fulfill()
            return
          }
          done.fulfill()
        },
        start: { _ in
          XCTFail("An empty authenticated credential must not send an anonymous request")
          return CompletedRemoteRequest.shared
        })
      wait(for: [done], timeout: 2)
    }
  }

  func testUnauthenticatedLocalChatOmitsAuthorizationAndStreamsSuccessfully() throws {
    let endpoint = try RemoteProviderEndpoint(
      provider: .openAICompatible, baseURL: URL(string: "http://localhost:1234")!, model: "m")
    let client = try endpoint.makeChatProvider(
      authorization: RemoteUnauthenticatedAuthorization(), maximumOutputTokens: 1024,
      sessionConfiguration: mockSessionConfiguration())
    MockURLProtocol.handler = { request, urlProtocol in
      XCTAssertEqual(request.url?.absoluteString, "http://localhost:1234/chat/completions")
      XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
      urlProtocol.respond(
        status: 200,
        chunks: [
          Data(
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
              .utf8)
        ])
    }
    let done = expectation(description: "chat")
    _ = client.streamChat(messages: [.user("Hello")], tools: [], progress: { _ in }) {
      XCTAssertEqual(try? $0.get().text, "OK")
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }
}

private struct EmptyAuthorization: RemoteAuthorizationProviding {
  let kind: RemoteAuthenticationKind
  func authorization() async throws -> RemoteRequestAuthorization {
    .init(kind: kind, token: " ")
  }
}
