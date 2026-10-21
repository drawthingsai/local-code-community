import Foundation
import Network

public final class RemoteOAuthLoopbackServer: @unchecked Sendable {
  private static let maximumRequestSize = 64 * 1024

  private let callbackURL: URL
  private let expectedState: String
  private let listener: NWListener
  private let queue = DispatchQueue(label: "com.liuliu.local-code.oauth-loopback")
  private var readyHandler: ((Result<Void, Error>) -> Void)?
  private var callbackHandler: ((Result<String, Error>) -> Void)?
  private var started = false
  private var ready = false
  private var finished = false

  public init(callbackURL: URL, expectedState: String) throws {
    guard callbackURL.scheme == "http", callbackURL.host?.lowercased() == "localhost",
      let portNumber = callbackURL.port, let rawPort = UInt16(exactly: portNumber),
      let port = NWEndpoint.Port(rawValue: rawPort)
    else { throw RemoteOAuthError.invalidAuthorizationResponse }
    self.callbackURL = callbackURL
    self.expectedState = expectedState
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
    listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { [weak self] state in
      self?.didUpdate(state)
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
  }

  public func start(
    ready: @escaping (Result<Void, Error>) -> Void,
    callback: @escaping (Result<String, Error>) -> Void
  ) {
    queue.async {
      guard !self.finished else { return }
      guard !self.started else {
        ready(.failure(RemoteOAuthError.invalidAuthorizationResponse))
        return
      }
      self.started = true
      self.readyHandler = ready
      self.callbackHandler = callback
      self.listener.start(queue: self.queue)
    }
  }

  public func cancel() {
    queue.async {
      guard !self.finished else { return }
      self.finished = true
      self.readyHandler = nil
      self.callbackHandler = nil
      self.listener.cancel()
    }
  }

  private func didUpdate(_ state: NWListener.State) {
    guard !finished else { return }
    switch state {
    case .ready:
      ready = true
      let handler = readyHandler
      readyHandler = nil
      handler?(.success(()))
    case .failed(let error):
      if ready {
        finish(.failure(error))
      } else {
        finished = true
        let handler = readyHandler
        readyHandler = nil
        callbackHandler = nil
        listener.cancel()
        handler?(.failure(error))
      }
    default:
      break
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    receiveRequest(on: connection, accumulatedData: Data())
  }

  private func receiveRequest(on connection: NWConnection, accumulatedData: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
      [weak self] data, _, complete, error in
      guard let self else { return }
      if error != nil {
        connection.cancel()
        return
      }
      var requestData = accumulatedData
      if let data { requestData.append(data) }
      if requestData.range(of: Data("\r\n\r\n".utf8)) != nil
        || requestData.range(of: Data("\n\n".utf8)) != nil
      {
        self.process(requestData, on: connection)
      } else if complete || requestData.count >= Self.maximumRequestSize {
        self.respond(status: "400 Bad Request", body: "Invalid OAuth callback.", on: connection)
      } else {
        self.receiveRequest(on: connection, accumulatedData: requestData)
      }
    }
  }

  private func process(_ requestData: Data, on connection: NWConnection) {
    guard !finished, let request = String(data: requestData, encoding: .utf8),
      let requestLine = request.components(separatedBy: .newlines).first
    else {
      respond(status: "400 Bad Request", body: "Invalid OAuth callback.", on: connection)
      return
    }
    let requestParts = requestLine.split(separator: " ", maxSplits: 2)
    guard requestParts.count == 3, requestParts[0] == "GET",
      let components = URLComponents(string: "http://localhost\(requestParts[1])")
    else {
      respond(status: "400 Bad Request", body: "Invalid OAuth callback.", on: connection)
      return
    }
    guard components.path == callbackURL.path else {
      respond(status: "404 Not Found", body: "Not found.", on: connection)
      return
    }
    let state = components.queryItems?.first(where: { $0.name == "state" })?.value
    guard state == expectedState else {
      respond(status: "400 Bad Request", body: "Invalid OAuth state.", on: connection) {
        self.finish(.failure(RemoteOAuthError.invalidAuthorizationResponse))
      }
      return
    }
    if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
      let description =
        components.queryItems?.first(where: { $0.name == "error_description" })?.value ?? error
      respond(status: "400 Bad Request", body: "Claude authorization failed.", on: connection) {
        self.finish(.failure(RemoteOAuthError.authorizationFailed(description)))
      }
      return
    }
    guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
      !code.isEmpty
    else {
      respond(status: "400 Bad Request", body: "Missing authorization code.", on: connection) {
        self.finish(.failure(RemoteOAuthError.invalidAuthorizationResponse))
      }
      return
    }
    var callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    callbackComponents?.queryItems = components.queryItems
    guard let callback = callbackComponents?.url?.absoluteString else {
      respond(status: "400 Bad Request", body: "Invalid OAuth callback.", on: connection) {
        self.finish(.failure(RemoteOAuthError.invalidAuthorizationResponse))
      }
      return
    }
    respond(
      status: "200 OK",
      body: "Claude authorization received. You can return to Local Code.", on: connection
    ) {
      self.finish(.success(callback))
    }
  }

  private func respond(
    status: String, body: String, on connection: NWConnection, completion: (() -> Void)? = nil
  ) {
    let bodyData = Data(body.utf8)
    var response = Data(
      """
      HTTP/1.1 \(status)\r
      Content-Type: text/plain; charset=utf-8\r
      Content-Length: \(bodyData.count)\r
      Cache-Control: no-store\r
      Connection: close\r
      \r

      """.utf8)
    response.append(bodyData)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        connection.cancel()
        completion?()
      })
  }

  private func finish(_ result: Result<String, Error>) {
    guard !finished else { return }
    finished = true
    let handler = callbackHandler
    readyHandler = nil
    callbackHandler = nil
    listener.cancel()
    handler?(result)
  }
}
