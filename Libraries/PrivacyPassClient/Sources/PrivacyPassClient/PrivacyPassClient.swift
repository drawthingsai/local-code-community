import Crypto
import Foundation
import _CryptoExtras

// Assuming you are using a library that extends CryptoKit for blind signatures.
// You might need to import the specific library you're using, e.g., import CryptoKit_Blind_Signature;

/// Represents a token response containing a blind signature.
/// This struct is the Swift equivalent of the provided TypeScript class.

/// The `PrivacyPassClient` class provides a high-level API for the Privacy Pass issuance protocol.
/// It handles the cryptographic operations and network requests required to obtain and finalize tokens.
public final class PrivacyPassClient {
  public struct TokenAuthenticator {
    let authenticatorInput: AuthenticatorInput
    let preparedMessage: _RSA.BlindSigning.PreparedMessage
    let inverse: _RSA.BlindSigning.BlindingInverse
  }

  /// Creates blinded token requests to be sent to the issuer.
  /// This function fetches the public key, prepares and blinds the messages,
  /// and returns the requests along with the necessary authenticators for finalization.
  /// - Parameters:
  ///   - publicKeyURL: The URL from which to fetch the issuer's public key.
  ///   - numberOfRequests: The number of tokens to request.
  /// - Returns: A `Result` containing an array of `(TokenRequest, TokenAuthenticator)` tuples and the issuer's public key, or an `Error`.
  public static func createTokenRequests(
    publicKeyPem: String, keyID: [UInt8], challenges: [PrivacyPassMetadata]
  ) -> Result<
    ([(TokenRequest, TokenAuthenticator)], _RSA.BlindSigning.PublicKey<SHA384>), Error
  > {
    do {
      let publicKey = try _RSA.BlindSigning.PublicKey(
        pemRepresentation: publicKeyPem, parameters: .RSABSSA_SHA384_PSS_Deterministic)
      var requests: [(TokenRequest, TokenAuthenticator)] = []
      for metadata in challenges {
        guard let nonce = Data(base64Encoded: metadata.nonce),
          let challengeDigest = Data(base64Encoded: metadata.challenge)
        else {
          continue
        }
        let message = try AuthenticatorInput(
          tokenTypeEntry: .blindRsa2048,
          //TODO: maybe this nonce and challenge digest has to come from server as well
          nonce: nonce,
          challengeDigest: challengeDigest,
          tokenKeyId: Data(keyID))  // public key id calculated on server
        let preparedMessage = publicKey.prepare(message.serialize())
        // [Client] Blind the message to send to the server and get its blinding inverse.
        let blindingResult = try publicKey.blind(preparedMessage)
        let tokenRequest = TokenRequest(
          blindMessage: blindingResult.blindedMessage.base64EncodedString())
        requests.append(
          (
            tokenRequest,
            TokenAuthenticator(
              authenticatorInput: message, preparedMessage: preparedMessage,
              inverse: blindingResult.inverse)
          ))
      }
      return .success((requests, publicKey))
    } catch {
      return .failure(error)
    }
  }

  /// Finalizes the tokens by unblinding the signatures received from the issuer.
  /// - Parameters:
  ///   - publicKey: The issuer's public key used for the requests.
  ///   - responses: An array of `(TokenResponse, TokenAuthenticator)` tuples containing the server's responses and the client's original authenticators.
  /// - Returns: A `Result` containing an array of finalized `PrivacyPassToken`s, or an `Error`.
  public static func finalizeTokens(
    publicKey: _RSA.BlindSigning.PublicKey<SHA384>, responses: [(TokenResponse, TokenAuthenticator)]
  ) -> Result<[PrivacyPassToken], Error> {
    do {
      var tokens = [PrivacyPassToken]()
      for (response, tokenAuthenticator) in responses {
        let unblindedSignature = try publicKey.finalize(
          _RSA.BlindSigning.BlindSignature(rawRepresentation: response.blindSignature),
          for: tokenAuthenticator.preparedMessage,
          blindingInverse: tokenAuthenticator.inverse
        )
        tokens.append(
          PrivacyPassToken(
            authInput: tokenAuthenticator.authenticatorInput,
            authenticator: unblindedSignature.rawRepresentation))
      }
      return .success(tokens)
    } catch {
      return .failure(error)
    }
  }

  /// Generates a specified number of random bytes.
  /// - Parameter count: The number of random bytes to generate.
  /// - Returns: A `Data` object containing the random bytes.
  static func getRandomBytes(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    if status == errSecSuccess {
      return Data(bytes)
    } else {
      // Fallback for environments where SecRandomCopyBytes might fail.
      return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }
  }
}
