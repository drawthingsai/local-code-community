import Crypto
import Foundation
import PrivacyPassClient
import _CryptoExtras

@main
struct Main {
  static func main() async {
    // For local testing, we can run a self-contained flow that reads keys from files.
    // runLocalClientFlow()

    // To run against a live server, uncomment the line below.
    await runRemoteClientFlow(numberOfTokens: 10)
  }
}

/// Runs a self-contained, local Privacy Pass flow for testing purposes.
/// This function emulates the client, issuer, and verifier.
func runLocalClientFlow() {
  print("🚀 Starting Privacy Pass Client Flow (Local Emulation)...")

  do {
    // 1. [Setup] Load local private key and derive the public key.
    print("1. Loading local private key...")
    let privateKey = try loadPrivateKey(from: "test_private_key.pem")
    let publicKey = privateKey.publicKey
    print("✅ Private key loaded and public key derived.")

    // 2. [Client] Create a message to be signed. In a real flow, the nonce
    // and challenge digest would come from a server challenge.
    print("\n2. Creating a dummy message (AuthenticatorInput)...")
    let keyID = Data(getRandomBytes(count: 32))
    let authInput = try AuthenticatorInput(
      tokenTypeEntry: .blindRsa2048,
      nonce: getRandomBytes(count: 32),
      challengeDigest: getRandomBytes(count: 32),
      tokenKeyId: keyID
    )
    let message = authInput.serialize()
    print("✅ Dummy message created.")

    // 3. [Client] Prepare and blind the message.
    print("\n3. Blinding the message...")
    let preparedMessage = publicKey.prepare(message)
    let blindingResult = try publicKey.blind(preparedMessage)
    print("✅ Message blinded.")

    // 4. [Issuer] Emulate the issuer signing the blinded message.
    print("\n4. Emulating issuer signing...")
    let blindSignature = try privateKey.blindSignature(for: blindingResult.blindedMessage)
    print("✅ Blind signature created by issuer (emulated).")

    // 5. [Client] Finalize the token by unblinding the signature.
    print("\n5. Finalizing token (unblinding signature)...")
    let unblindedSignature = try publicKey.finalize(
      blindSignature,
      for: preparedMessage,
      blindingInverse: blindingResult.inverse
    )
    print("✅ Token finalized.")

    // 6. [Verifier] Verify the unblided signature.
    print("\n6. Verifying the final signature...")
    if publicKey.isValidSignature(unblindedSignature, for: preparedMessage) {
      print("✅ Signature is valid!")
    } else {
      print("❌ Signature is invalid!")
    }

  } catch {
    print("\n❌ An error occurred during the local client flow: \(error)")
  }
}

/// Helper function to load a private key from a file.
func loadPrivateKey(from fileName: String) throws -> _RSA.BlindSigning.PrivateKey<SHA384> {
  // This path is relative to the execution directory. When running with `swift run`
  // from the package root, the path should point into the Sources/main directory.
  let keyFileURL = URL(fileURLWithPath: "Sources/main/\(fileName)")

  guard let keyPEM = try? String(contentsOf: keyFileURL, encoding: .utf8) else {
    throw NSError(
      domain: "main", code: 2,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Could not read private key file at '\(keyFileURL.path)'. Make sure the file exists and the executable is run from the package root directory."
      ])
  }

  return try _RSA.BlindSigning.PrivateKey(
    pemRepresentation: keyPEM, parameters: .RSABSSA_SHA384_PSS_Deterministic)
}

// --- Remote Flow (for reference and testing against a live server) ---

func runRemoteClientFlow(numberOfTokens: UInt) async {
  print("🚀 Starting Privacy Pass Client Flow...")

  guard let challengeURL = URL(string: "http://localhost:8787/test_challenge"),
    let issueURL = URL(string: "http://localhost:8787/test_issue_privacy_pass"),
    let verifyURL = URL(string: "http://localhost:8787/test_verify_privacy_pass")
  else {
    print("❌ Invalid URL(s) configured.")
    return
  }

  do {
    // 1. Request a challenge using the completion-block function.
    print("1. Requesting challenge from \(challengeURL)...")

    // We wrap the old function to make it await-able.
    let challengeResponse: PrivacyPassChallengeResponse = try await withCheckedThrowingContinuation
    { continuation in
      PrivacyPassClient.requestPrivacyPassChallenge(from: challengeURL, count: numberOfTokens) {
        result in
        // Inside the completion handler, we use the continuation
        // to resume the async function.
        switch result {
        case .success(let response):
          continuation.resume(returning: response)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
    print("✅ Got challenge response.")

    // 2. Create blinded token requests. (The rest of the code remains the same)
    print("\n2. Creating blinded token requests...")
    let (requestsWithAuth, publicKey) = try PrivacyPassClient.createTokenRequests(
      publicKeyPem: challengeResponse.key,
      keyID: challengeResponse.keyID,
      challenges: challengeResponse.metadataList
    ).get()
    print("✅ Blinded token requests created.")

    // 3. Issue tokens.
    print("\n3. Issuing tokens from \(issueURL)...")
    let tokenRequests = requestsWithAuth.map { $0.0 }
    let tokenResponses = try await issueToken(url: issueURL, requests: tokenRequests)
    print("✅ Received blind signatures from issuer.")

    guard tokenResponses.count == requestsWithAuth.count else {
      print("❌ Mismatch between number of requests sent and responses received.")
      return
    }

    // 4. Finalize tokens.
    print("\n4. Finalizing tokens...")
    let authenticators = requestsWithAuth.map { $0.1 }
    let responsesWithAuth = Array(zip(tokenResponses, authenticators))
    let finalizedTokens = try PrivacyPassClient.finalizeTokens(
      publicKey: publicKey, responses: responsesWithAuth
    ).get()
    print("✅ Tokens finalized successfully.")

    // 5. Verify all finalized tokens concurrently.
    print("\n5. Verifying all finalized tokens in parallel...")
    await withThrowingTaskGroup(of: Void.self) { group in
      for (index, token) in finalizedTokens.enumerated() {
        group.addTask {
          print("   Verifying token \(index + 1)...")
          try await verifyToken(url: verifyURL, token: token)
          print("   ✅ Token \(index + 1) verified successfully!")
        }
      }
    }
    print("✅ All tokens verified successfully!")

  } catch {
    print("\n❌ An error occurred during the client flow: \(error)")
  }
}

/// Makes a network request to the issuer to get a blind signature for multiple tokens.
func issueToken(url: URL, requests: [TokenRequest]) async throws -> [TokenResponse] {
  let jsonData = try JSONEncoder().encode(["blindMessages": requests.map { $0.blindMessage }])
  var urlRequest = URLRequest(url: url)
  urlRequest.httpMethod = "POST"
  urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
  urlRequest.httpBody = jsonData

  let (data, response) = try await URLSession.shared.data(for: urlRequest)

  guard let httpResponse = response as? HTTPURLResponse,
    (200...299).contains(httpResponse.statusCode)
  else {
    let body = String(data: data, encoding: .utf8) ?? ""
    print("Server returned error: \(body)")
    throw PrivacyPassClientError.serverError(
      statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
  }

  // Decode the JSON response from the server.
  let issueResponse = try JSONDecoder().decode(IssueResponse.self, from: data)

  // Decode each base64-encoded signature from the response.
  let tokenResponses = try issueResponse.tokenResponses.map { b64Signature -> TokenResponse in
    guard let signatureData = Data(base64Encoded: b64Signature) else {
      throw NSError(
        domain: "main", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Failed to decode base64 signature from server."])
    }
    return TokenResponse(blindSignature: signatureData)
  }

  return tokenResponses
}

/// Sends the final token to the server for verification.
func verifyToken(url: URL, token: PrivacyPassToken) async throws {
  let serializedToken = token.serialize()
  let base64EncodedToken = serializedToken.base64EncodedString()
  let authHeaderValue = "PrivateToken token=\(base64EncodedToken)"

  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.setValue(authHeaderValue, forHTTPHeaderField: "Authorization")

  let (data, response) = try await URLSession.shared.data(for: request)

  guard let httpResponse = response as? HTTPURLResponse,
    (200...299).contains(httpResponse.statusCode)
  else {
    let body = String(data: data, encoding: .utf8) ?? ""
    print("Server verification failed with body: \(body)")
    throw PrivacyPassClientError.serverError(
      statusCode: (response as? HTTPURLResponse)?.statusCode ?? 500)
  }

  print("✅ Server verification response: \(String(data: data, encoding: .utf8) ?? "")")
}

/// Helper to generate random bytes.
private func getRandomBytes(count: Int) -> Data {
  var bytes = [UInt8](repeating: 0, count: count)
  let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  if status == errSecSuccess {
    return Data(bytes)
  }
  // Fallback for environments where SecRandomCopyBytes might fail.
  return Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
}
