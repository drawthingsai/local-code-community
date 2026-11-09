import Atomics
import Foundation
import Network

struct StreamingHTTPRequest {
  let method: String
  let path: String
  /// Names are lowercased.
  let headers: [String: String]
  let body: Data
}

protocol StreamingHTTPServerDelegate: AnyObject {
  /// Arrives on the main queue.
  func streamingHTTPServer(
    _ server: StreamingHTTPServer, didChange state: StreamingHTTPServer.State)
  /// Arrives on the main queue.
  func streamingHTTPServer(
    _ server: StreamingHTTPServer, didReceive request: StreamingHTTPRequest,
    on connection: StreamingHTTPConnection)
}

/// One request per connection, with responses that can stream. Network.framework is enough for
/// this, so serving takes no new dependency. It knows nothing about the Responses
/// API, so another transport could replace it behind `ResponsesTransport`.
final class StreamingHTTPServer {
  enum State: Equatable {
    case starting
    case ready
    case addressInUse
    case failed(String)
    case stopped
  }

  private static let maximumHeaderSize = 64 * 1_024
  private static let maximumBodySize = 64 * 1_024 * 1_024

  weak var delegate: StreamingHTTPServerDelegate?
  /// 127.0.0.1 for this Mac only, or 0.0.0.0 for every connection.
  let host: String
  let port: UInt16
  private let queue = DispatchQueue(label: "com.liuliu.local-code.serve-http")
  private var listener: NWListener?
  // Accessed only on `queue`.
  private var connections = [ObjectIdentifier: StreamingHTTPConnection]()

  init(host: String, port: UInt16) {
    self.host = host
    self.port = port
  }

  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard listener == nil else { return }
    report(.starting)
    do {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
      parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
      let listener = try NWListener(using: parameters)
      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.report(.ready)
        case .failed(.posix(.EADDRINUSE)):
          self.report(.addressInUse)
        case .failed(let error):
          self.report(.failed(error.localizedDescription))
        default:
          break
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        self?.accept(connection)
      }
      self.listener = listener
      listener.start(queue: queue)
    } catch {
      report(.failed(error.localizedDescription))
    }
  }

  func stop() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let listener else { return }
    self.listener = nil
    listener.stateUpdateHandler = nil
    listener.newConnectionHandler = nil
    listener.cancel()
    queue.async { [self] in
      for connection in connections.values { connection.cancel() }
    }
    report(.stopped)
  }

  private func report(_ state: State) {
    // Kept alive to report, as being stopped is often the last thing that happens to a server.
    DispatchQueue.main.async { [self] in
      delegate?.streamingHTTPServer(self, didChange: state)
    }
  }

  private func accept(_ nwConnection: NWConnection) {
    let connection = StreamingHTTPConnection(connection: nwConnection, queue: queue)
    connections[ObjectIdentifier(connection)] = connection
    connection.onClosed = { [weak self] connection in
      self?.connections.removeValue(forKey: ObjectIdentifier(connection))
    }
    connection.start()
    receiveRequest(on: connection, buffer: Data())
  }

  private func receiveRequest(on connection: StreamingHTTPConnection, buffer: Data) {
    connection.receive { [weak self] data, isComplete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      guard error == nil else {
        connection.cancel()
        return
      }
      if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
        self.process(
          headerData: buffer[..<headerRange.lowerBound],
          bodyPrefix: buffer[headerRange.upperBound...], on: connection)
      } else if isComplete {
        connection.cancel()
      } else if buffer.count > Self.maximumHeaderSize {
        connection.respond(status: 431, contentType: "text/plain", body: Data())
      } else {
        self.receiveRequest(on: connection, buffer: buffer)
      }
    }
  }

  private func process(headerData: Data, bodyPrefix: Data, on connection: StreamingHTTPConnection) {
    guard let head = String(data: headerData, encoding: .utf8) else {
      connection.respond(status: 400, contentType: "text/plain", body: Data())
      return
    }
    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ")
    guard requestLine.count == 3 else {
      connection.respond(status: 400, contentType: "text/plain", body: Data())
      return
    }
    var headers = [String: String]()
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      headers[line[..<colon].lowercased()] =
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    // Anything on this Mac can reach 127.0.0.1, including web pages. Refuse them: a page through
    // its Origin, and a rebound domain through its Host. Open to every connection, any host is
    // already welcome, so only pages are refused.
    guard host != "127.0.0.1" || Self.isLoopback(authority: headers["host"]),
      headers["origin"].map({ Self.isLoopback(origin: $0) }) ?? true
    else {
      connection.respond(status: 403, contentType: "text/plain", body: Data())
      return
    }
    guard headers["transfer-encoding"] == nil else {
      connection.respond(status: 411, contentType: "text/plain", body: Data())
      return
    }
    let contentLength = Int(headers["content-length"] ?? "0") ?? -1
    guard contentLength >= 0, contentLength <= Self.maximumBodySize else {
      connection.respond(status: 413, contentType: "text/plain", body: Data())
      return
    }
    if headers["expect"]?.lowercased() == "100-continue" {
      connection.sendContinue()
    }
    let path = String(requestLine[1].prefix { $0 != "?" })
    receiveBody(
      remaining: contentLength - bodyPrefix.count, body: Data(bodyPrefix), on: connection
    ) { [weak self] body in
      guard let self else { return }
      let request = StreamingHTTPRequest(
        method: String(requestLine[0]), path: path, headers: headers, body: body)
      // A connection closing from here on cancels what the request started.
      connection.watchForDisconnect()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.delegate?.streamingHTTPServer(self, didReceive: request, on: connection)
      }
    }
  }

  private func receiveBody(
    remaining: Int, body: Data, on connection: StreamingHTTPConnection,
    completion: @escaping (Data) -> Void
  ) {
    guard remaining > 0 else {
      completion(body)
      return
    }
    connection.receive { [weak self] data, isComplete, error in
      guard error == nil, !isComplete || data != nil else {
        connection.cancel()
        return
      }
      var body = body
      if let data { body.append(data) }
      self?.receiveBody(
        remaining: remaining - (data?.count ?? 0), body: body, on: connection,
        completion: completion)
    }
  }

  static func isLoopback(authority: String?) -> Bool {
    guard var host = authority?.lowercased() else { return false }
    if host.hasPrefix("[") {
      return host == "[::1]" || host.hasPrefix("[::1]:")
    }
    if let colon = host.firstIndex(of: ":") {
      host = String(host[..<colon])
    }
    return host == "127.0.0.1" || host == "localhost"
  }

  static func isLoopback(origin: String) -> Bool {
    guard let components = URLComponents(string: origin), let host = components.host else {
      return false
    }
    // URLComponents keeps an IPv6 host's brackets on some OS versions and not on others.
    return isLoopback(authority: host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)
  }
}

/// Writes are safe from any queue. The body of a stream ends when the connection closes, so a
/// streaming response needs neither a length nor chunking.
final class StreamingHTTPConnection {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let disconnected = ManagedAtomic(false)
  // Accessed only on `queue`.
  fileprivate var onClosed: ((StreamingHTTPConnection) -> Void)?

  fileprivate init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  var isDisconnected: Bool { disconnected.load(ordering: .acquiring) }

  fileprivate func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .failed, .cancelled:
        self.disconnected.store(true, ordering: .releasing)
        self.connection.stateUpdateHandler = nil
        self.onClosed?(self)
        self.onClosed = nil
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  fileprivate func receive(completion: @escaping (Data?, Bool, NWError?) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) {
      data, _, isComplete, error in
      completion(data, isComplete, error)
    }
  }

  fileprivate func watchForDisconnect() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
      [weak self] _, _, isComplete, error in
      guard let self else { return }
      if isComplete || error != nil {
        self.disconnected.store(true, ordering: .releasing)
        self.connection.cancel()
      } else {
        self.watchForDisconnect()
      }
    }
  }

  fileprivate func sendContinue() {
    connection.send(
      content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
  }

  fileprivate func cancel() {
    disconnected.store(true, ordering: .releasing)
    connection.cancel()
  }

  /// Sends a whole response and closes.
  func respond(status: Int, contentType: String, body: Data) {
    var data = Self.head(
      status: status, contentType: contentType, extraHeader: "Content-Length: \(body.count)\r\n")
    data.append(body)
    connection.send(content: data, completion: .contentProcessed { _ in })
    close()
  }

  func beginEventStream() {
    connection.send(
      content: Self.head(status: 200, contentType: "text/event-stream", extraHeader: ""),
      completion: .contentProcessed { _ in })
  }

  func sendEvent(name: String?, data: Data) {
    var event = Data((name.map { "event: \($0)\n" } ?? "").utf8)
    event.append(Data("data: ".utf8))
    event.append(data)
    event.append(Data("\n\n".utf8))
    connection.send(content: event, completion: .contentProcessed { _ in })
  }

  func sendKeepAlive() {
    connection.send(content: Data(": waiting\n\n".utf8), completion: .contentProcessed { _ in })
  }

  /// Closes after everything sent so far has gone out.
  func close() {
    connection.send(
      content: nil, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { [connection] _ in connection.cancel() })
  }

  private static func head(status: Int, contentType: String, extraHeader: String) -> Data {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 400: reason = "Bad Request"
    case 403: reason = "Forbidden"
    case 404: reason = "Not Found"
    case 405: reason = "Method Not Allowed"
    case 411: reason = "Length Required"
    case 413: reason = "Content Too Large"
    case 429: reason = "Too Many Requests"
    case 431: reason = "Request Header Fields Too Large"
    case 503: reason = "Service Unavailable"
    default: reason = "Internal Server Error"
    }
    return Data(
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extraHeader)\r\n"
        .utf8)
  }
}
