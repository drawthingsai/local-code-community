import Foundation
import Network

/// Foreground loopback preview. Node workers finish between requests so serving a
/// page does not occupy NodeMobile's serialized command environment indefinitely.
final class HyperFramesServer {
  private let directory: URL
  private let resources: URL
  private let listener: NWListener
  private var connections = [ObjectIdentifier: NWConnection]()
  private var stopped = false
  var compile: ((String, @escaping (Result<String, Error>) -> Void) -> Void)?

  init(directory: URL, resources: URL, port: UInt16) throws {
    self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    self.resources = resources
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    listener = try NWListener(using: parameters)
  }

  func start(completion: @escaping (Result<String, Error>) -> Void) {
    var reported = false
    listener.stateUpdateHandler = { [weak self] state in
      guard let self, !reported else { return }
      switch state {
      case .ready:
        reported = true
        completion(.success("http://127.0.0.1:\(self.listener.port!.rawValue)/"))
      case .failed(let error):
        reported = true
        completion(.failure(error))
      default: break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      self.connections[ObjectIdentifier(connection)] = connection
      connection.start(queue: .main)
      self.receive(connection, data: Data())
    }
    listener.start(queue: .main)
  }

  func stop() {
    stopped = true
    listener.cancel()
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
  }

  private func receive(_ connection: NWConnection, data: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
      [weak self] chunk, _, ended, error in
      guard let self, !self.stopped else { return }
      var data = data
      if let chunk { data.append(chunk) }
      if let range = data.range(of: Data("\r\n\r\n".utf8)),
        let request = String(data: data[..<range.lowerBound], encoding: .utf8)
      {
        self.respond(connection, request: request)
      } else if ended || error != nil || data.count > 32768 {
        self.send(connection, status: "400 Bad Request", type: "text/plain", data: Data())
      } else {
        self.receive(connection, data: data)
      }
    }
  }

  private func respond(_ connection: NWConnection, request: String) {
    let lines = request.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ")
    guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD" else {
      send(connection, status: "405 Method Not Allowed", type: "text/plain", data: Data())
      return
    }
    let head = parts[0] == "HEAD"
    let encoded = String(
      parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
    guard let decoded = encoded.removingPercentEncoding, decoded.hasPrefix("/"),
      !decoded.contains("\0")
    else {
      send(connection, status: "400 Bad Request", type: "text/plain", data: Data())
      return
    }
    let relative = decoded == "/" ? "index.html" : String(decoded.dropFirst())
    let file = directory.appendingPathComponent(relative).standardizedFileURL
      .resolvingSymlinksInPath()
    guard file.path.hasPrefix(directory.path + "/"),
      !file.lastPathComponent.hasPrefix(".hyperframes-inspect-")
    else {
      send(connection, status: "403 Forbidden", type: "text/plain", data: Data())
      return
    }
    if file.pathExtension.lowercased() == "html", let compile {
      compile(relative) { [weak self] result in
        guard let self, !self.stopped else { return }
        switch result {
        case .success(let html):
          self.send(
            connection, status: "200 OK", type: "text/html; charset=utf-8", data: Data(html.utf8),
            head: head)
        case .failure(let error):
          self.send(
            connection, status: "500 Internal Server Error", type: "text/plain",
            data: Data(error.localizedDescription.utf8), head: head)
        }
      }
      return
    }
    do {
      var target = file
      if !FileManager.default.fileExists(atPath: target.path),
        ["hyperframes-player.global.js", "hyperframes-slideshow.global.js"].contains(
          target.lastPathComponent)
      {
        target = resources.appendingPathComponent(target.lastPathComponent)
      }
      let data = try Data(contentsOf: target, options: .mappedIfSafe)
      let types = [
        "js": "text/javascript", "css": "text/css", "json": "application/json", "png": "image/png",
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "svg": "image/svg+xml",
        "woff2": "font/woff2", "woff": "font/woff", "mp4": "video/mp4", "mov": "video/quicktime",
        "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4",
      ]
      let type = types[target.pathExtension.lowercased()] ?? "application/octet-stream"
      if let rangeHeader = lines.first(where: { $0.lowercased().hasPrefix("range: bytes=") }) {
        let value = rangeHeader.dropFirst("range: bytes=".count).trimmingCharacters(
          in: .whitespaces)
        let limits = value.split(separator: "-", omittingEmptySubsequences: false)
        guard limits.count == 2, let start = Int(limits[0]), start >= 0, start < data.count,
          let end = limits[1].isEmpty ? data.count - 1 : Int(limits[1]), end >= start
        else {
          send(
            connection, status: "416 Range Not Satisfiable", type: type, data: Data(),
            headers: "Content-Range: bytes */\(data.count)\r\n")
          return
        }
        let last = min(end, data.count - 1)
        send(
          connection, status: "206 Partial Content", type: type,
          data: data.subdata(in: start..<(last + 1)), head: head,
          headers: "Content-Range: bytes \(start)-\(last)/\(data.count)\r\n")
      } else {
        send(connection, status: "200 OK", type: type, data: data, head: head)
      }
    } catch {
      send(connection, status: "404 Not Found", type: "text/plain", data: Data(), head: head)
    }
  }

  private func send(
    _ connection: NWConnection, status: String, type: String, data: Data, head: Bool = false,
    headers: String = ""
  ) {
    var response = Data(
      "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\nConnection: close\r\n\(headers)\r\n"
        .utf8)
    if !head { response.append(data) }
    connection.send(
      content: response,
      completion: .contentProcessed { [weak self] _ in
        connection.cancel()
        self?.connections.removeValue(forKey: ObjectIdentifier(connection))
      })
  }
}
