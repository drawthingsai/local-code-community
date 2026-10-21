import Foundation

enum RemoteStreamAction {
  case none
  case progress(RemoteStreamProgress)
  case complete(RemoteCompletion)
}

final class CompletedRemoteRequest: RemoteRequestCancellable {
  static let shared = CompletedRemoteRequest()

  private init() {}

  func cancel() {}
}

final class RemoteStreamingRequest: RemoteSessionDelegate, URLSessionDataDelegate,
  RemoteRequestCancellable
{
  typealias EventHandler = (RemoteSSEParser.Event) throws -> RemoteStreamAction
  typealias EndHandler = () throws -> RemoteCompletion

  private let lock = NSLock()
  private let redactedSecret: String
  private let maximumErrorBytes: Int
  private let progress: (RemoteStreamProgress) -> Void
  private let completion: (Result<RemoteCompletion, RemoteChatError>) -> Void
  private let handleEvent: EventHandler
  private let handleEnd: EndHandler
  private var parser: RemoteSSEParser
  private var errorBody = Data()
  private var statusCode: Int?
  private var didFinish = false
  private weak var task: URLSessionTask?
  private var session: URLSession?

  init(
    redactedSecret: String, maximumEventBytes: Int, maximumErrorBytes: Int,
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void,
    handleEvent: @escaping EventHandler, handleEnd: @escaping EndHandler
  ) {
    self.redactedSecret = redactedSecret
    self.maximumErrorBytes = maximumErrorBytes
    self.progress = progress
    self.completion = completion
    self.handleEvent = handleEvent
    self.handleEnd = handleEnd
    parser = RemoteSSEParser(maximumEventBytes: maximumEventBytes)
  }

  func start(_ request: URLRequest, configuration: URLSessionConfiguration) {
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    let task = session.dataTask(with: request)
    self.session = session
    self.task = task
    task.resume()
  }

  func cancel() {
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    statusCode = (response as? HTTPURLResponse)?.statusCode
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard !isFinished else { return }
    guard let statusCode, (200...299).contains(statusCode) else {
      errorBody.append(data.prefix(max(0, maximumErrorBytes - errorBody.count)))
      return
    }
    do {
      if try consume(parser.append(data)) {
        dataTask.cancel()
      }
    } catch let error as RemoteChatError {
      finish(.failure(redacted(error)))
      dataTask.cancel()
    } catch {
      finish(.failure(.malformedStream("unexpected stream error")))
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard !isFinished else { return }
    if let error {
      let error = error as NSError
      finish(
        .failure(
          error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
            ? .cancelled : .network(redact(error.localizedDescription))))
      return
    }
    guard let statusCode else {
      finish(.failure(.network("The provider returned no HTTP response.")))
      return
    }
    guard (200...299).contains(statusCode) else {
      var message =
        String(data: errorBody, encoding: .utf8) ?? "No error details were provided."
      if let object = try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any],
        let error = object["error"] as? [String: Any],
        let providerMessage = error["message"] as? String
      {
        message = providerMessage
      }
      finish(
        .failure(
          .provider(
            statusCode: statusCode, message: redact(String(message.prefix(1_024))))))
      return
    }
    do {
      guard try !consume(parser.finish()) else { return }
      finish(.success(try handleEnd()))
    } catch let error as RemoteChatError {
      finish(.failure(redacted(error)))
    } catch {
      finish(.failure(.malformedStream("unexpected end of stream")))
    }
  }

  private var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didFinish
  }

  private func consume(_ events: [RemoteSSEParser.Event]) throws -> Bool {
    for event in events {
      switch try handleEvent(event) {
      case .none:
        break
      case .progress(let update):
        progress(update)
      case .complete(let result):
        finish(.success(result))
        return true
      }
    }
    return false
  }

  private func redacted(_ error: RemoteChatError) -> RemoteChatError {
    switch error {
    case .malformedStream(let message):
      return .malformedStream(redact(message))
    case .provider(let statusCode, let message):
      return .provider(statusCode: statusCode, message: redact(message))
    case .providerStream(let message):
      return .providerStream(redact(message))
    case .network(let message):
      return .network(redact(message))
    default:
      return error
    }
  }

  private func redact(_ value: String) -> String {
    redactedSecret.isEmpty
      ? value : value.replacingOccurrences(of: redactedSecret, with: "[REDACTED]")
  }

  private func finish(_ result: Result<RemoteCompletion, RemoteChatError>) {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didFinish = true
    lock.unlock()
    completion(result)
    session?.finishTasksAndInvalidate()
    session = nil
  }
}
