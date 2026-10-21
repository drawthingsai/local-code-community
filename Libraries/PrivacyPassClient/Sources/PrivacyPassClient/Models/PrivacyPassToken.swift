import Foundation

/// Represents the final `Token` object sent for verification.
public struct PrivacyPassToken: Codable, Equatable {
  public let authInput: AuthenticatorInput
  public let authenticator: Data  // This is the `unblindedSignature`

  public init(authInput: AuthenticatorInput, authenticator: Data) {
    self.authInput = authInput
    self.authenticator = authenticator
  }

  /// Serializes the entire token into a single Data object.
  public func serialize() -> Data {
    var data = authInput.serialize()
    data.append(authenticator)
    return data
  }
}
