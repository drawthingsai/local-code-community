import Foundation

public enum RemoteAuthenticationKind: Equatable, Sendable {
  case unauthenticated
  case apiKey
  case oauth
}

public struct RemoteUnauthenticatedAuthorization: RemoteAuthorizationProviding {
  public let kind = RemoteAuthenticationKind.unauthenticated

  public init() {}

  public func authorization() async throws -> RemoteRequestAuthorization {
    RemoteRequestAuthorization(kind: .unauthenticated, token: "")
  }
}

public struct RemoteOAuthCredential: Codable, Equatable, Sendable {
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Date
  public let accountID: String?
}

public struct RemoteRequestAuthorization: Equatable, Sendable {
  public let kind: RemoteAuthenticationKind
  public let token: String
  public let accountID: String?

  public init(kind: RemoteAuthenticationKind, token: String, accountID: String? = nil) {
    self.kind = kind
    self.token = token
    self.accountID = accountID
  }
}

public protocol RemoteAuthorizationProviding: Sendable {
  var kind: RemoteAuthenticationKind { get }
  func authorization() async throws -> RemoteRequestAuthorization
}

public struct RemoteAPIKeyAuthorization: RemoteAuthorizationProviding {
  public let kind = RemoteAuthenticationKind.apiKey
  private let apiKey: String

  public init(apiKey: String) {
    self.apiKey = apiKey
  }

  public func authorization() async throws -> RemoteRequestAuthorization {
    RemoteRequestAuthorization(kind: .apiKey, token: apiKey)
  }
}

enum RemoteAuthorizationHeaders {
  static func applyBearer(_ authorization: RemoteRequestAuthorization, to request: inout URLRequest)
  {
    request.setValue(
      authorization.kind == .unauthenticated
        ? nil : "Bearer \(authorization.token)", forHTTPHeaderField: "Authorization")
  }

  static func applyOpenAICodex(
    _ authorization: RemoteRequestAuthorization, to request: inout URLRequest
  ) {
    applyBearer(authorization, to: &request)
    request.setValue(authorization.accountID, forHTTPHeaderField: "chatgpt-account-id")
    request.setValue("local-code", forHTTPHeaderField: "originator")
    request.setValue("Local Code", forHTTPHeaderField: "User-Agent")
  }

  static func applyAnthropic(
    _ authorization: RemoteRequestAuthorization, to request: inout URLRequest
  ) {
    if authorization.kind == .oauth {
      applyBearer(authorization, to: &request)
      request.setValue(
        "claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
      request.setValue("claude-cli/2.1.75", forHTTPHeaderField: "user-agent")
      request.setValue("cli", forHTTPHeaderField: "x-app")
    } else {
      request.setValue(authorization.token, forHTTPHeaderField: "x-api-key")
    }
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
  }
}

final class RemoteAuthorizedRequest: RemoteRequestCancellable, @unchecked Sendable {
  typealias Start = (RemoteRequestAuthorization) -> RemoteRequestCancellable

  private let lock = NSLock()
  private var authorizationTask: Task<Void, Never>?
  private var request: RemoteRequestCancellable?
  private var isCancelled = false

  init(
    authorization: any RemoteAuthorizationProviding,
    failure: @escaping (Error) -> Void, start: @escaping Start
  ) {
    authorizationTask = Task { [self] in
      do {
        let value = try await authorization.authorization()
        guard !Task.isCancelled else { throw CancellationError() }
        guard value.kind == authorization.kind,
          value.kind == .unauthenticated
            || !value.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          throw RemoteChatError.authentication(
            "The credential is empty or its authentication kind changed.")
        }
        install(start(value))
      } catch {
        failure(Task.isCancelled ? CancellationError() : error)
      }
    }
  }

  func cancel() {
    let authorizationTask: Task<Void, Never>?
    let request: RemoteRequestCancellable?
    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      return
    }
    isCancelled = true
    authorizationTask = self.authorizationTask
    self.authorizationTask = nil
    request = self.request
    self.request = nil
    lock.unlock()
    authorizationTask?.cancel()
    request?.cancel()
  }

  private func install(_ request: RemoteRequestCancellable) {
    lock.lock()
    authorizationTask = nil
    if isCancelled {
      lock.unlock()
      request.cancel()
      return
    }
    self.request = request
    lock.unlock()
  }
}
