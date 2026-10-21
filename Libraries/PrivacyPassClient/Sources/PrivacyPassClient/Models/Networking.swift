import Foundation

// --- Data Structures for Client <-> Server Communication ---
public enum PrivacyPassClientError: Error {
  case publicKeyError
  case networkError(Error)
  case encodingError(Error)
  case decodingError(Error)
  case serverError(statusCode: Int)
}

public struct PrivacyPassMetadata: Codable, Hashable {
  public let challenge: String
  public let nonce: String
  public let expireAt: TimeInterval  // This is in millisecond from server.
}

public struct PrivacyPassChallengeResponse: Codable, Hashable {
  public let key: String
  public let keyID: [UInt8]
  public let metadataList: [PrivacyPassMetadata]
}

/// Represents the JSON body for the request sent to the server.
/// e.g., { "token": "base64_encoded_string" }
public struct TokenRequest: Codable {
  public let blindMessage: String
}

// A struct to decode the JSON response from the issue endpoint
public struct IssueResponse: Codable {
  public let tokenResponses: [String]
}

/// Represents a token response containing a blind signature.
/// This struct is the Swift equivalent of the provided TypeScript class.
public struct TokenResponse {
  /// The raw bytes of the blind signature.
  public let blindSignature: Data

  /// Initializes a new TokenResponse with the given signature data.
  public init(blindSignature: Data) {
    self.blindSignature = blindSignature
  }

  /// Deserializes a byte array (`Data`) into a TokenResponse instance.
  static func deserialize(bytes: Data) -> TokenResponse {
    return TokenResponse(blindSignature: bytes)
  }

  /// Serializes the TokenResponse instance back into a byte array (`Data`).
  func serialize() -> Data {
    return self.blindSignature
  }
}
