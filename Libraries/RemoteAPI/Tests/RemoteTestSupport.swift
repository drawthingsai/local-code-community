import Foundation
import RemoteAPI

final class MockURLProtocol: URLProtocol {
  typealias Handler = (URLRequest, MockURLProtocol) throws -> Void
  static var handler: Handler?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      try Self.handler?(request, self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}

  func respond(status: Int, chunks: [Data]) {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in chunks {
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }
}

func mockSessionConfiguration() -> URLSessionConfiguration {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [MockURLProtocol.self]
  return configuration
}

func requestBody(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var body = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    guard count > 0 else { break }
    body.append(contentsOf: buffer.prefix(count))
  }
  return body
}

struct TestAuthorization: RemoteAuthorizationProviding {
  let value: RemoteRequestAuthorization
  var kind: RemoteAuthenticationKind { value.kind }

  init(_ value: RemoteRequestAuthorization) {
    self.value = value
  }

  func authorization() async throws -> RemoteRequestAuthorization { value }
}
