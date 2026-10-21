import CryptoKit
import Foundation

public enum RemoteOAuthError: Error, LocalizedError, Equatable {
  case authorizationFailed(String)
  case invalidAuthorizationResponse
  case invalidTokenResponse
  case missingAccountID
  case requestFailed(Int, String)
  case timedOut

  public var errorDescription: String? {
    switch self {
    case .authorizationFailed(let message):
      return "OAuth authorization failed. \(message)"
    case .invalidAuthorizationResponse:
      return "The OAuth authorization response was invalid."
    case .invalidTokenResponse:
      return "The OAuth token endpoint returned an invalid response."
    case .missingAccountID:
      return "The OpenAI access token did not identify a ChatGPT account."
    case .requestFailed(let statusCode, let message):
      return "OAuth request failed with HTTP \(statusCode). \(message)"
    case .timedOut:
      return "OAuth authorization timed out."
    }
  }
}

public struct RemoteOAuthAuthorization: Equatable, Sendable {
  public let url: URL
  public let callbackURL: URL
  public let verifier: String
  public let state: String
}

public struct OpenAIDeviceAuthorization: Equatable, Sendable {
  public let verificationURL: URL
  public let userCode: String
  public let deviceAuthorizationID: String
  public let interval: TimeInterval
}

public enum RemoteOAuth {
  private static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  private static let openAIBaseURL = URL(string: "https://auth.openai.com")!
  private static let anthropicClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  private static let anthropicAuthorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
  private static let anthropicTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
  private static let anthropicCallbackURL = URL(string: "http://localhost:53692/callback")!

  public static func requestOpenAIDeviceAuthorization(
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> OpenAIDeviceAuthorization {
    let data = try await postJSON(
      ["client_id": openAIClientID],
      to: openAIBaseURL.appendingPathComponent("api/accounts/deviceauth/usercode"),
      session: session)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let deviceAuthorizationID = object["device_auth_id"] as? String,
      let userCode = object["user_code"] as? String,
      let interval = number(object["interval"]),
      let verificationURL = URL(string: "https://auth.openai.com/codex/device")
    else { throw RemoteOAuthError.invalidAuthorizationResponse }
    return OpenAIDeviceAuthorization(
      verificationURL: verificationURL, userCode: userCode,
      deviceAuthorizationID: deviceAuthorizationID, interval: min(max(1, interval), 60))
  }

  public static func completeOpenAIDeviceAuthorization(
    _ authorization: OpenAIDeviceAuthorization,
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> RemoteOAuthCredential {
    let deadline = Date().addingTimeInterval(15 * 60)
    let url = openAIBaseURL.appendingPathComponent("api/accounts/deviceauth/token")
    var interval = authorization.interval
    while Date() < deadline {
      try Task.checkCancellation()
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: [
        "device_auth_id": authorization.deviceAuthorizationID,
        "user_code": authorization.userCode,
      ])
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw RemoteOAuthError.invalidAuthorizationResponse
      }
      if (200...299).contains(response.statusCode) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let code = object["authorization_code"] as? String,
          let verifier = object["code_verifier"] as? String
        else { throw RemoteOAuthError.invalidAuthorizationResponse }
        return try await exchangeOpenAICode(
          code: code, verifier: verifier,
          redirectURI: "https://auth.openai.com/deviceauth/callback", session: session)
      }
      if response.statusCode != 403 && response.statusCode != 404 {
        let error = oauthErrorMessage(data)
        if error == "slow_down" {
          interval = min(interval + 5, 60)
        } else if error != "deviceauth_authorization_pending" {
          throw RemoteOAuthError.requestFailed(response.statusCode, error)
        }
      }
      try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    throw RemoteOAuthError.timedOut
  }

  public static func anthropicAuthorization() throws -> RemoteOAuthAuthorization {
    let verifier = randomURLSafeString(byteCount: 32)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    let state = randomURLSafeString(byteCount: 32)
    var components = URLComponents(url: anthropicAuthorizeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "code", value: "true"),
      URLQueryItem(name: "client_id", value: anthropicClientID),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: anthropicCallbackURL.absoluteString),
      URLQueryItem(
        name: "scope",
        value:
          "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
      ),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ]
    guard let url = components.url else { throw RemoteOAuthError.invalidAuthorizationResponse }
    return RemoteOAuthAuthorization(
      url: url, callbackURL: anthropicCallbackURL, verifier: verifier, state: state)
  }

  public static func exchangeAnthropicCode(
    _ input: String, authorization: RemoteOAuthAuthorization,
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> RemoteOAuthCredential {
    let result = authorizationCode(from: input)
    guard let code = result.code, !code.isEmpty,
      result.state == nil || result.state == authorization.state
    else { throw RemoteOAuthError.invalidAuthorizationResponse }
    let data = try await postJSON(
      [
        "grant_type": "authorization_code", "client_id": anthropicClientID, "code": code,
        "state": result.state ?? authorization.state,
        "redirect_uri": authorization.callbackURL.absoluteString,
        "code_verifier": authorization.verifier,
      ], to: anthropicTokenURL, session: session)
    return try credential(from: data, requiresAccountID: false)
  }

  public static func refreshAnthropic(
    _ credential: RemoteOAuthCredential,
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> RemoteOAuthCredential {
    let data = try await postJSON(
      [
        "grant_type": "refresh_token", "client_id": anthropicClientID,
        "refresh_token": credential.refreshToken,
      ], to: anthropicTokenURL, session: session)
    return try self.credential(
      from: data, requiresAccountID: false, fallbackRefreshToken: credential.refreshToken)
  }

  public static func refreshOpenAI(
    _ credential: RemoteOAuthCredential,
    session: URLSession = URLSession(configuration: .ephemeral)
  ) async throws -> RemoteOAuthCredential {
    let data = try await postJSON(
      [
        "grant_type": "refresh_token", "refresh_token": credential.refreshToken,
        "client_id": openAIClientID,
      ], to: openAIBaseURL.appendingPathComponent("oauth/token"), session: session)
    return try self.credential(
      from: data, requiresAccountID: true, fallbackRefreshToken: credential.refreshToken)
  }

  private static func exchangeOpenAICode(
    code: String, verifier: String, redirectURI: String, session: URLSession
  ) async throws -> RemoteOAuthCredential {
    var request = URLRequest(url: openAIBaseURL.appendingPathComponent("oauth/token"))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formData([
      "grant_type": "authorization_code", "client_id": openAIClientID, "code": code,
      "code_verifier": verifier, "redirect_uri": redirectURI,
    ])
    let data = try await responseData(for: request, session: session)
    return try credential(from: data, requiresAccountID: true)
  }

  private static func credential(
    from data: Data, requiresAccountID: Bool, fallbackRefreshToken: String? = nil
  ) throws -> RemoteOAuthCredential {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let accessToken = object["access_token"] as? String,
      let refreshToken = object["refresh_token"] as? String ?? fallbackRefreshToken
    else { throw RemoteOAuthError.invalidTokenResponse }
    let accountID =
      accountID(from: accessToken) ?? (object["id_token"] as? String).flatMap(accountID)
    if requiresAccountID && accountID == nil { throw RemoteOAuthError.missingAccountID }
    let expiresAt: Date
    if let expiresIn = number(object["expires_in"]) {
      expiresAt = Date().addingTimeInterval(expiresIn)
    } else if let expiration = jwtPayload(accessToken)?["exp"] as? NSNumber {
      expiresAt = Date(timeIntervalSince1970: expiration.doubleValue)
    } else {
      throw RemoteOAuthError.invalidTokenResponse
    }
    return RemoteOAuthCredential(
      accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt,
      accountID: accountID)
  }

  private static func accountID(from token: String) -> String? {
    guard let payload = jwtPayload(token),
      let authentication = payload["https://api.openai.com/auth"] as? [String: Any]
    else { return nil }
    return authentication["chatgpt_account_id"] as? String
  }

  private static func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let data = Data(base64URLEncoded: String(parts[1])),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
  }

  private static func authorizationCode(from input: String) -> (code: String?, state: String?) {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if let components = URLComponents(string: value), queryValue("code", in: components) != nil {
      return (queryValue("code", in: components), queryValue("state", in: components))
    }
    if value.contains("#") {
      let parts = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
      return (parts.first.map(String.init), parts.count == 2 ? String(parts[1]) : nil)
    }
    if value.contains("code="), let components = URLComponents(string: "?" + value) {
      return (queryValue("code", in: components), queryValue("state", in: components))
    }
    return (value.isEmpty ? nil : value, nil)
  }

  private static func queryValue(_ name: String, in components: URLComponents) -> String? {
    components.queryItems?.first { $0.name == name }?.value
  }

  private static func postJSON(
    _ object: [String: Any], to url: URL, session: URLSession
  ) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: object)
    return try await responseData(for: request, session: session)
  }

  private static func responseData(for request: URLRequest, session: URLSession) async throws
    -> Data
  {
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw RemoteOAuthError.invalidTokenResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw RemoteOAuthError.requestFailed(response.statusCode, oauthErrorMessage(data))
    }
    return data
  }

  private static func oauthErrorMessage(_ data: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let description = object["error_description"] as? String { return description }
      if let error = object["error"] as? String { return error }
      if let error = object["error"] as? [String: Any] {
        return error["message"] as? String ?? error["code"] as? String ?? "Request failed."
      }
    }
    return String(data: data.prefix(4_096), encoding: .utf8) ?? "Request failed."
  }

  private static func formData(_ values: [String: String]) -> Data {
    var components = URLComponents()
    components.queryItems = values.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    return Data((components.percentEncodedQuery ?? "").utf8)
  }

  private static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  private static func randomURLSafeString(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64URLEncodedString()
  }
}

extension Data {
  fileprivate init?(base64URLEncoded value: String) {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    self.init(base64Encoded: base64)
  }

  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
