import Foundation
import RemoteAPI
import XCTest

final class RemoteCredentialStoreTests: XCTestCase {
  func testDecodesLegacyAPIKeyAndOAuthRecordsWithoutUnauthenticatedFlag() throws {
    let keyData = Data(#"{"version":1,"identifier":"key-record","apiKey":"old-api-key"}"#.utf8)
    XCTAssertEqual(
      try RemoteCredentialStore.decodeCredential(keyData, provider: .openAICompatible),
      RemoteStoredCredential(identifier: "key-record", value: .apiKey("old-api-key")))
    let oauthData = Data(
      #"{"version":1,"identifier":"oauth-record","oauth":{"accessToken":"old-token","refreshToken":"refresh-token","expiresAt":3600,"accountID":"account"}}"#
        .utf8)
    let stored = try RemoteCredentialStore.decodeCredential(oauthData, provider: .openAI)
    XCTAssertEqual(stored.identifier, "oauth-record")
    XCTAssertEqual(stored.kind, .oauth)
    guard case .oauth(let oauth) = stored.value else {
      return XCTFail("Expected the original OAuth credential")
    }
    XCTAssertEqual(oauth.accessToken, "old-token")
    XCTAssertEqual(oauth.refreshToken, "refresh-token")
    XCTAssertEqual(oauth.expiresAt, Date(timeIntervalSinceReferenceDate: 3600))
    XCTAssertEqual(oauth.accountID, "account")
  }

  func testDecodesExplicitUnauthenticatedRecordOnlyForCompatibleProvider() throws {
    let data = Data(#"{"version":1,"identifier":"anonymous-record","unauthenticated":true}"#.utf8)
    XCTAssertEqual(
      try RemoteCredentialStore.decodeCredential(data, provider: .openAICompatible),
      RemoteStoredCredential(identifier: "anonymous-record", value: .unauthenticated))
    for provider in RemoteProvider.allCases where provider != .openAICompatible {
      XCTAssertThrowsError(try RemoteCredentialStore.decodeCredential(data, provider: provider)) {
        error in
        guard case RemoteCredentialStore.KeychainError.invalidData = error else {
          return XCTFail("Expected invalid credential data")
        }
      }
    }
  }

  func testRejectsInvalidAndAmbiguousPersistedUnauthenticatedRecords() {
    for json in [
      #"{"version":1,"identifier":"x","unauthenticated":true,"apiKey":"key"}"#,
      #"{"version":1,"identifier":"x","unauthenticated":true,"apiKey":""}"#,
      #"{"version":1,"identifier":"x","unauthenticated":true,"oauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":3600}}"#,
      #"{"version":1,"identifier":"x","unauthenticated":false}"#,
      #"{"version":1,"identifier":"x","unauthenticated":"true"}"#,
      #"{"version":1,"identifier":"x"}"#,
      #"{"version":2,"identifier":"x","unauthenticated":true}"#,
      "not JSON",
    ] {
      XCTAssertThrowsError(
        try RemoteCredentialStore.decodeCredential(Data(json.utf8), provider: .openAICompatible),
        json
      ) { error in
        guard case RemoteCredentialStore.KeychainError.invalidData = error else {
          return XCTFail("Expected invalid credential data")
        }
      }
    }
  }

  func testReplacementKeyDoesNotReadAnUnreadableRecord() throws {
    for provider in [RemoteProvider.openAICompatible, .anthropic, .openRouter] {
      func unreadable() throws -> RemoteStoredCredential? {
        XCTFail("A replacement key must not depend on reading the previous record")
        throw RemoteCredentialStore.KeychainError.invalidData
      }
      XCTAssertEqual(
        try RemoteCredentialUpdate.resolve(
          key: " new-key ", provider: provider, existing: unreadable()),
        .apiKey("new-key"))
    }
  }

  func testBlankKeyPreservesReadFailuresAndOnlyAllowsExplicitAnonymousAccounts() throws {
    func unreadable() throws -> RemoteStoredCredential? {
      throw RemoteCredentialStore.KeychainError.invalidData
    }
    for provider in [RemoteProvider.openAICompatible, .anthropic, .openRouter] {
      XCTAssertThrowsError(
        try RemoteCredentialUpdate.resolve(key: "", provider: provider, existing: unreadable()))
      XCTAssertEqual(
        try RemoteCredentialUpdate.resolve(key: "", provider: provider, existing: nil),
        provider == .openAICompatible ? .unauthenticated : .keyRequired)
      XCTAssertEqual(
        try RemoteCredentialUpdate.resolve(
          key: "", provider: provider,
          existing: RemoteStoredCredential(identifier: "existing", value: .apiKey("secret"))),
        .unchanged)
    }
  }
}
