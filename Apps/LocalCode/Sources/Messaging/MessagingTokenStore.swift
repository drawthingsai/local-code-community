import Foundation
import Security

/// Bot tokens, in the keychain, one per platform: saving one replaces the one before.
enum MessagingTokenStore {
  enum Error: Swift.Error, LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
      switch self {
      case .unexpectedStatus(let status):
        return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
      }
    }
  }

  static func token(for platform: MessagingPlatform) -> String? {
    var query = baseQuery(platform)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func setToken(_ token: String, for platform: MessagingPlatform) throws {
    let query = baseQuery(platform)
    let attributes: [String: Any] = [
      kSecValueData as String: Data(token.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else { throw Error.unexpectedStatus(updateStatus) }
    let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw Error.unexpectedStatus(addStatus) }
  }

  private static func baseQuery(_ platform: MessagingPlatform) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.liuliu.local-code.messaging-token",
      kSecAttrAccount as String: platform.rawValue,
    ]
  }
}
