import Foundation
import Localization
import RemoteAPI
import Security

struct RemoteStoredCredential: Equatable {
  enum Value: Equatable {
    case unauthenticated
    case apiKey(String)
    case oauth(RemoteOAuthCredential)
  }

  var identifier: String
  var value: Value

  var kind: RemoteAuthenticationKind {
    switch value {
    case .unauthenticated: return .unauthenticated
    case .apiKey: return .apiKey
    case .oauth: return .oauth
    }
  }
}

// Resolve the user's save intent before reading credentials. A replacement key can repair
// a corrupt record; a blank field must preserve read errors instead of becoming anonymous.
enum RemoteCredentialUpdate: Equatable {
  case apiKey(String)
  case unchanged
  case unauthenticated
  case keyRequired

  static func resolve(
    key: String, provider: RemoteProvider,
    existing: @autoclosure () throws -> RemoteStoredCredential?
  ) throws -> Self {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if !key.isEmpty { return .apiKey(key) }
    if try existing() != nil { return .unchanged }
    return provider == .openAICompatible ? .unauthenticated : .keyRequired
  }
}

enum RemoteCredentialStore {
  static let didChangeNotification = Notification.Name("LocalCodeRemoteCredentialsDidChange")
  #if os(macOS)
    // Embedded commands change process-wide HOME. Keep the original Keychain
    // reference so later token refreshes do not look inside the project directory.
    private static let defaultKeychain: Result<SecKeychain, Error> = Result {
      var keychain: SecKeychain?
      let status = SecKeychainCopyDefault(&keychain)
      guard status == errSecSuccess, let keychain else {
        throw KeychainError.unexpectedStatus(status)
      }
      return keychain
    }
  #endif

  static func prepareForEmbeddedCommands() {
    #if os(macOS)
      _ = defaultKeychain
    #endif
  }

  enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
      switch self {
      case .unexpectedStatus(let status):
        return LocalizedString.format(key: "keychain_operation_failed", status)
      case .invalidData:
        return LocalizedString.forKey("remote_credential_unreadable")
      }
    }
  }

  private struct Record: Codable {
    var version: Int
    var identifier: String
    var apiKey: String?
    var oauth: RemoteOAuthCredential?
    var unauthenticated: Bool? = nil
  }

  static func readCredential(account: String, provider: RemoteProvider) throws
    -> RemoteStoredCredential?
  {
    guard let data = try readData(account: account, provider: provider) else { return nil }
    return try decodeCredential(data, provider: provider)
  }

  static func decodeCredential(_ data: Data, provider: RemoteProvider) throws
    -> RemoteStoredCredential
  {
    guard let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1
    else {
      throw KeychainError.invalidData
    }
    if record.unauthenticated == true {
      guard provider == .openAICompatible, record.apiKey == nil, record.oauth == nil else {
        throw KeychainError.invalidData
      }
      return RemoteStoredCredential(identifier: record.identifier, value: .unauthenticated)
    }
    if let apiKey = record.apiKey, !apiKey.isEmpty, record.oauth == nil {
      return RemoteStoredCredential(identifier: record.identifier, value: .apiKey(apiKey))
    }
    if let oauth = record.oauth, record.apiKey == nil {
      return RemoteStoredCredential(identifier: record.identifier, value: .oauth(oauth))
    }
    throw KeychainError.invalidData
  }

  static func upsertAPIKey(_ apiKey: String, account: String, provider: RemoteProvider) throws {
    try upsert(
      Record(
        version: 1, identifier: UUID().uuidString, apiKey: apiKey, oauth: nil),
      account: account, provider: provider)
  }

  static func upsertUnauthenticated(account: String) throws {
    try upsert(
      Record(
        version: 1, identifier: UUID().uuidString, apiKey: nil, oauth: nil,
        unauthenticated: true),
      account: account, provider: .openAICompatible)
  }

  static func upsertOAuth(
    _ oauth: RemoteOAuthCredential, identifier: String = UUID().uuidString, account: String,
    provider: RemoteProvider
  ) throws {
    try upsert(
      Record(
        version: 1, identifier: identifier, apiKey: nil, oauth: oauth),
      account: account, provider: provider)
  }

  static func delete(account: String, provider: RemoteProvider) throws {
    let status = SecItemDelete(try baseQuery(account: account, provider: provider) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(status)
    }
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  private static func readData(account: String, provider: RemoteProvider) throws -> Data? {
    var query = try baseQuery(account: account, provider: provider)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    guard let data = result as? Data else { throw KeychainError.invalidData }
    return data
  }

  private static func upsert(_ record: Record, account: String, provider: RemoteProvider) throws {
    let data = try JSONEncoder().encode(record)
    let query = try baseQuery(account: account, provider: provider)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError.unexpectedStatus(updateStatus)
    }
    var insert = query
    #if os(macOS)
      insert.removeValue(forKey: kSecMatchSearchList as String)
      insert[kSecUseKeychain as String] = try defaultKeychain.get()
    #endif
    for (key, value) in attributes { insert[key] = value }
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  private static func baseQuery(account: String, provider: RemoteProvider) throws -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.liuliu.local-code.remote-credential.\(provider.rawValue)",
      kSecAttrAccount as String: account,
    ]
    #if os(macOS)
      query[kSecMatchSearchList as String] = [try defaultKeychain.get()]
    #endif
    return query
  }
}

actor RemoteCredentialAuthorizer: RemoteAuthorizationProviding {
  enum AuthorizationError: LocalizedError {
    case unavailable
    case changed
    case unsupported

    var errorDescription: String? {
      switch self {
      case .unavailable:
        return LocalizedString.forKey("remote_credential_unavailable")
      case .changed:
        return LocalizedString.forKey("remote_credential_changed")
      case .unsupported:
        return LocalizedString.forKey("remote_credential_unsupported")
      }
    }
  }

  nonisolated let kind: RemoteAuthenticationKind
  nonisolated let identifier: String

  private let provider: RemoteProvider
  private let account: String
  private let session: URLSession
  private var refreshTask: Task<RemoteOAuthCredential, Swift.Error>?

  init(
    provider: RemoteProvider, account: String, credential: RemoteStoredCredential,
    session: URLSession = URLSession(configuration: .ephemeral)
  ) {
    self.provider = provider
    self.account = account
    self.session = session
    kind = credential.kind
    identifier = credential.identifier
  }

  func authorization() async throws -> RemoteRequestAuthorization {
    guard
      let credential = try RemoteCredentialStore.readCredential(
        account: account, provider: provider)
    else { throw AuthorizationError.unavailable }
    guard credential.identifier == identifier, credential.kind == kind else {
      throw AuthorizationError.changed
    }
    switch credential.value {
    case .unauthenticated:
      return RemoteRequestAuthorization(kind: .unauthenticated, token: "")
    case .apiKey(let apiKey):
      return RemoteRequestAuthorization(kind: .apiKey, token: apiKey)
    case .oauth(let oauth):
      let current: RemoteOAuthCredential
      if oauth.expiresAt.timeIntervalSinceNow > 5 * 60 {
        current = oauth
      } else {
        current = try await refresh(oauth)
      }
      return RemoteRequestAuthorization(
        kind: .oauth, token: current.accessToken, accountID: current.accountID)
    }
  }

  private func refresh(_ credential: RemoteOAuthCredential) async throws
    -> RemoteOAuthCredential
  {
    if let refreshTask { return try await refreshTask.value }
    let provider = self.provider
    let identifier = self.identifier
    let account = self.account
    let session = self.session
    let refreshTask = Task<RemoteOAuthCredential, Swift.Error> {
      let refreshed: RemoteOAuthCredential
      switch provider {
      case .openAI:
        refreshed = try await RemoteOAuth.refreshOpenAI(credential, session: session)
      case .anthropic:
        refreshed = try await RemoteOAuth.refreshAnthropic(credential, session: session)
      case .localCode, .openRouter, .openAICompatible, .deviceLink:
        throw AuthorizationError.unsupported
      }
      guard
        let latest = try RemoteCredentialStore.readCredential(
          account: account, provider: provider),
        latest.identifier == identifier, latest.kind == .oauth,
        case .oauth(let latestOAuth) = latest.value
      else { throw AuthorizationError.changed }
      if latestOAuth != credential {
        return latestOAuth
      }
      try RemoteCredentialStore.upsertOAuth(
        refreshed, identifier: identifier, account: account, provider: provider)
      return refreshed
    }
    self.refreshTask = refreshTask
    do {
      let refreshed = try await refreshTask.value
      self.refreshTask = nil
      return refreshed
    } catch {
      self.refreshTask = nil
      throw error
    }
  }
}
