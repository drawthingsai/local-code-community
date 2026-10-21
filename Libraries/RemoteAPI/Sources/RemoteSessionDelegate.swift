import Foundation

// Shared redirect policy; URLSession still performs default TLS certificate validation.
class RemoteSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let source = task.originalRequest?.url, let destination = request.url,
      RemoteEndpointURL.permitsRedirect(from: source, to: destination)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
