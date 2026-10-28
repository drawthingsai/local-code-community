import Foundation

public enum RemoteChatError: Error, Equatable, LocalizedError {
  case invalidBaseURL
  case insecureBaseURL
  case missingModel
  case imageInputUnsupported
  case requestTooLarge(maximumBytes: Int)
  case responseTooLarge(maximumBytes: Int)
  case malformedStream(String)
  case provider(statusCode: Int, message: String)
  case providerStream(String)
  case network(String)
  case cancelled
  case sessionUnavailable
  case alreadyRunning
  case roundLimitReached(maximumRounds: Int)
  case invalidToolArguments(function: String)
  case compactionFailed(String)
  case contextLimitReached
  case emptyResponse
  case incompleteResponse(String)
  case authentication(String)

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      return "Enter a valid remote API base URL."
    case .insecureBaseURL:
      return
        "Use HTTPS, or HTTP with localhost, a .local hostname, or a private network IP address."
    case .imageInputUnsupported:
      return
        "The selected provider does not accept image input."
    case .missingModel:
      return "Enter the model identifier required by the remote provider."
    case .requestTooLarge(let maximumBytes):
      return
        "The remote conversation exceeds the \(maximumBytes)-byte request limit. Reset the remote session and try again."
    case .responseTooLarge(let maximumBytes):
      return "The remote provider response exceeded the \(maximumBytes)-byte safety limit."
    case .malformedStream(let message):
      return "The remote provider returned a malformed stream: \(message)"
    case .provider(let statusCode, let message):
      switch statusCode {
      case 301, 302, 303, 307, 308:
        return
          "The remote endpoint returned HTTP \(statusCode). \(RemoteEndpointURL.redirectPolicyMessage)"
      case 401:
        return "The remote provider rejected the credentials (401). \(message)"
      case 429:
        return "The remote provider quota or rate limit was reached (429). \(message)"
      case 500...599:
        return "The remote provider is unavailable (\(statusCode)). \(message)"
      default:
        return "The remote provider returned HTTP \(statusCode). \(message)"
      }
    case .providerStream(let message):
      return "The remote provider ended the stream with an error. \(message)"
    case .network(let message):
      return "The remote request failed: \(message)"
    case .cancelled:
      return "The remote request was cancelled."
    case .sessionUnavailable:
      return "The remote chat session is not prepared."
    case .alreadyRunning:
      return "A remote request is already running."
    case .roundLimitReached(let maximumRounds):
      return "The remote agent stopped after \(maximumRounds) model/tool rounds."
    case .invalidToolArguments(let function):
      return
        "The remote model could not produce well-formed JSON arguments for \(function) after 2 regeneration attempts."
    case .compactionFailed(let message):
      return "The remote agent could not compact its context without losing history. \(message)"
    case .contextLimitReached:
      return
        "The remote model context is full and no complete conversation segment can be compacted."
    case .emptyResponse:
      return "The remote provider returned neither text nor a tool call."
    case .incompleteResponse(let reason):
      return "The remote provider stopped before completing its response (\(reason))."
    case .authentication(let message):
      return "Remote authentication failed. \(message)"
    }
  }

  var indicatesContextLimit: Bool {
    switch self {
    case .requestTooLarge:
      return true
    case .provider(let statusCode, let message):
      guard statusCode == 400 || statusCode == 413 || statusCode == 422 else { return false }
      return Self.messageIndicatesContextLimit(message)
    case .providerStream(let message):
      return Self.messageIndicatesContextLimit(message)
    default:
      return false
    }
  }

  var isRetryableRequestFailure: Bool {
    switch self {
    case .network, .malformedStream, .providerStream:
      return true
    case .provider(let statusCode, let message):
      if statusCode == 429 {
        let message = message.lowercased()
        return !["quota", "billing", "credit", "insufficient"].contains {
          message.contains($0)
        }
      }
      return statusCode == 408 || statusCode == 409 || statusCode == 425
        || (500...599).contains(statusCode)
    default:
      return false
    }
  }

  private static func messageIndicatesContextLimit(_ message: String) -> Bool {
    let message = message.lowercased()
    return [
      "context length", "context window", "maximum context", "max context",
      "too many tokens", "prompt is too long", "input is too long", "request too large",
    ].contains { message.contains($0) }
  }
}
