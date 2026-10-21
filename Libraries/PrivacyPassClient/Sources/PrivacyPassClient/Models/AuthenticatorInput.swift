import Foundation
import _CryptoExtras

// MARK: - AuthenticatorInput

/// Placeholder for the TokenTypeEntry which defines the parameters for a given token type.
public struct TokenTypeEntry: Sendable {
  let value: UInt16
  let name: String
  let Nk: Int
  let Nid: Int
  let publicVerifiable: Bool
  let publicMetadata: Bool
  let privateMetadata: Bool

  public static let blindRsa2048: TokenTypeEntry = .init(
    value: 0x0002,
    name: "Blind RSA (2048)",
    Nk: 256,
    Nid: 32,
    publicVerifiable: true,
    publicMetadata: false,
    privateMetadata: false
  )
}

/// A Swift representation of the IETF Privacy Pass AuthenticatorInput structure.
/// See: https://datatracker.ietf.org/doc/html/draft-ietf-privacypass-auth-scheme-14#name-token-verification
///
/// struct {
///     uint16_t token_type;
///     uint8_t nonce[32];
///     uint8_t challenge_digest[32];
///     uint8_t token_key_id[Nid];
/// } AuthenticatorInput;
public struct AuthenticatorInput: Codable, Equatable {
  public enum AuthenticatorInputError: Error {
    case tokenTypeMismatch
    case invalidNonceSize
    case invalidChallengeSize
    case invalidTokenKeyIdSize
    case dataTooShort(expected: Int, actual: Int)
  }

  public static let NONCE_LENGTH = 32
  public static let CHALLENGE_LENGTH = 32

  public let tokenType: UInt16
  public let nonce: Data
  public let challengeDigest: Data
  public let tokenKeyId: Data

  /// Creates a new AuthenticatorInput instance with validation.
  public init(tokenTypeEntry: TokenTypeEntry, nonce: Data, challengeDigest: Data, tokenKeyId: Data)
    throws
  {
    guard nonce.count == Self.NONCE_LENGTH else {
      throw AuthenticatorInputError.invalidNonceSize
    }
    guard challengeDigest.count == Self.CHALLENGE_LENGTH else {
      throw AuthenticatorInputError.invalidChallengeSize
    }
    guard tokenKeyId.count == tokenTypeEntry.Nid else {
      throw AuthenticatorInputError.invalidTokenKeyIdSize
    }

    self.tokenType = tokenTypeEntry.value
    self.nonce = nonce
    self.challengeDigest = challengeDigest
    self.tokenKeyId = tokenKeyId
  }

  /// Deserializes a `Data` object into an `AuthenticatorInput` instance and returns the bytes read.
  ///
  /// - Returns: A tuple containing the new `AuthenticatorInput` and the number of bytes consumed.
  /// - Throws: `AuthenticatorInputError` if the data is malformed or too short.
  public static func deserialize(from data: Data, using tokenTypeEntry: TokenTypeEntry) throws -> (
    input: AuthenticatorInput, bytesRead: Int
  ) {
    var offset = 0

    // Helper to safely read a chunk of data
    func read(count: Int) throws -> Data {
      guard data.count >= offset + count else {
        throw AuthenticatorInputError.dataTooShort(expected: offset + count, actual: data.count)
      }
      let subdata = data.subdata(in: offset..<(offset + count))
      offset += count
      return subdata
    }

    // Helper to read a fixed-width integer (in big-endian format)
    func readInteger<T: FixedWidthInteger>() throws -> T {
      let size = MemoryLayout<T>.size
      let data = try read(count: size)
      return data.toInteger()
    }

    let nonce = try read(count: Self.NONCE_LENGTH)
    let challengeDigest = try read(count: Self.CHALLENGE_LENGTH)
    let tokenKeyId = try read(count: tokenTypeEntry.Nid)

    let authInput = try AuthenticatorInput(
      tokenTypeEntry: tokenTypeEntry,
      nonce: nonce,
      challengeDigest: challengeDigest,
      tokenKeyId: tokenKeyId
    )

    return (input: authInput, bytesRead: offset)
  }

  /// Serializes the instance into a `Data` object for transmission.
  public func serialize() -> Data {
    var output = Data()
    output.appendInteger(self.tokenType)
    output.append(self.nonce)
    output.append(self.challengeDigest)
    output.append(self.tokenKeyId)
    return output
  }
}
