import Foundation
import XCTest

final class AccountClientTests: XCTestCase {
  private var session: URLSession!
  private var client: AccountClient!

  override func setUp() {
    super.setUp()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AccountURLProtocol.self]
    session = URLSession(configuration: configuration)
    client = AccountClient(baseURL: URL(string: "https://router.test")!, session: session)
  }

  override func tearDown() {
    AccountURLProtocol.handler = nil
    session.invalidateAndCancel()
    session = nil
    client = nil
    super.tearDown()
  }

  func testReturnsExistingDefaultKeyWithoutCreatingAnother() {
    var methods = [String]()
    AccountURLProtocol.handler = { request in
      methods.append(request.httpMethod ?? "GET")
      XCTAssertEqual(request.url?.path, "/v1/account/api-keys")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
      return .json(#"{"defaultKey":{"apiKey":"dk_existing"}}"#)
    }
    let expectation = expectation(description: "provision")

    client.provisionDefaultAPIKey(accessToken: "account-token") { result in
      XCTAssertEqual(try? result.get(), "dk_existing")
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertEqual(methods, ["GET"])
  }

  func testCreatesDefaultKeyOnlyWhenBackendHasNone() {
    var requests = [URLRequest]()
    AccountURLProtocol.handler = { request in
      requests.append(request)
      if request.httpMethod == "POST" {
        return .json(#"{"apiKey":"dk_created"}"#)
      }
      return .json(#"{"defaultKey":null}"#)
    }
    let expectation = expectation(description: "provision")

    client.provisionDefaultAPIKey(accessToken: "account-token") { result in
      XCTAssertEqual(try? result.get(), "dk_created")
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 1)
    XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Content-Type"), "application/json")
  }

  func testFetchesTypedCreditSnapshotAndHostedModels() {
    AccountURLProtocol.handler = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer dk_key")
      if request.url?.path == "/v1/models" {
        return .json(
          #"{"data":[{"id":"qwen/qwen3.8-27b","name":"Qwen 3.8 27B"},{"id":"qwen/qwen3.8-27b:free","name":"Qwen 3.8 27B (Free)"},{"id":"vendor/model"}]}"#
        )
      }
      return .json(
        #"{"balanceMicroUsd":1000,"reservedMicroUsd":250,"availableMicroUsd":750,"lifetimeSettledMicroUsd":50,"unit":"micro_usd"}"#
      )
    }
    let snapshotExpectation = expectation(description: "snapshot")
    let modelsExpectation = expectation(description: "models")

    client.fetchCreditSnapshot(apiKey: "dk_key") { result in
      XCTAssertEqual(
        try? result.get(),
        AccountClient.CreditSnapshot(
          balanceMicroUsd: 1000, reservedMicroUsd: 250, availableMicroUsd: 750,
          lifetimeSettledMicroUsd: 50, unit: "micro_usd"))
      snapshotExpectation.fulfill()
    }
    client.fetchHostedModels(apiKey: "dk_key") { result in
      XCTAssertEqual(
        try? result.get(),
        [
          .init(id: "qwen/qwen3.8-27b", name: "Qwen 3.8 27B"),
          .init(id: "qwen/qwen3.8-27b:free", name: "Qwen 3.8 27B (Free)"),
          .init(id: "vendor/model", name: nil),
        ])
      modelsExpectation.fulfill()
    }

    wait(for: [snapshotExpectation, modelsExpectation], timeout: 1)
    XCTAssertEqual(
      client.openAICompatibleBaseURL.absoluteString, "https://router.test/v1/openrouter")
  }

  func testSerializesPurchaseIdentityEnvironmentAndConsentAndDecodesBalance() {
    for isSandbox in [false, true] {
      let balance: Int64 = isSandbox ? 0 : 35_650_000
      let reserved: Int64 = isSandbox ? 0 : 1_000_000
      AccountURLProtocol.handler = { request in
        XCTAssertEqual(request.url?.host, "router.test")
        XCTAssertEqual(request.url?.path, "/v1/account/purchases")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
        let body = try AccountURLProtocol.body(of: request)
        XCTAssertEqual(body["transactionId"] as? String, String(UInt64.max))
        XCTAssertEqual(body["environment"] as? String, isSandbox ? "Sandbox" : "Production")
        XCTAssertEqual(body["customerConsented"] as? Bool, !isSandbox)
        XCTAssertNil(body["amount"])
        return .json(
          #"{"balanceMicroUsd":\#(balance),"reservedMicroUsd":\#(reserved),"availableMicroUsd":\#(balance - reserved),"lifetimeSettledMicroUsd":0,"unit":"micro_usd"}"#
        )
      }
      let done = expectation(description: "purchase delivery")
      client.deliverPurchase(
        transactionId: .max, isSandbox: isSandbox, customerConsented: !isSandbox,
        accessToken: "account-token"
      ) { result in
        XCTAssertEqual(try? result.get().balanceMicroUsd, balance)
        XCTAssertEqual(try? result.get().availableMicroUsd, balance - reserved)
        done.fulfill()
      }
      wait(for: [done], timeout: 1)
    }
  }

  func testReportsHTTPAndDecodingErrorsWithoutRevealingCredentials() {
    let cases: [(AccountURLProtocol.Response, AccountClient.ClientError)] = [
      (
        .json(#"{"error":{"message":"Rejected dk_leakedSecret123."}}"#, status: 402),
        .httpStatus(402, "Rejected <redacted>.")
      ),
      (
        .json(#"{"message":"Rejected dk_imagegen_account"}"#, status: 401),
        .httpStatus(401, "Rejected <redacted>")
      ),
      (.json(#"{"ok":true}"#), .decoding),
    ]
    for (response, error) in cases {
      AccountURLProtocol.handler = { request in
        XCTAssertEqual(request.url?.path, "/v1/account/purchases")
        return response
      }
      let done = expectation(description: "purchase failure")
      client.deliverPurchase(
        transactionId: 123, isSandbox: false, customerConsented: false, accessToken: "account-token"
      ) { result in
        XCTAssertEqual(result.failure as? AccountClient.ClientError, error)
        XCTAssertFalse(result.failure?.localizedDescription.contains("dk_") ?? true)
        done.fulfill()
      }
      wait(for: [done], timeout: 1)
    }
  }
}

private final class AccountURLProtocol: URLProtocol {
  struct Response {
    let status: Int
    let headers: [String: String]
    let data: Data

    static func json(_ body: String, status: Int = 200) -> Response {
      Response(
        status: status, headers: ["Content-Type": "application/json"], data: Data(body.utf8))
    }
  }

  static var handler: ((URLRequest) throws -> Response)?

  static func body(of request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 1024)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(contentsOf: buffer.prefix(count))
      }
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    do {
      let response = try handler(request)
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
          headerFields: response.headers)!,
        cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: response.data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

extension Result {
  fileprivate var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
