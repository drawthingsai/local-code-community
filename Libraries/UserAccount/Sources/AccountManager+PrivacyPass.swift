import AuthenticationServices
import Combine
import DeviceAttestation
import Dflat
import Foundation
import Logging
import PrivacyPassClient

public struct PrivcyPassMetadata: Codable, Equatable {
  public let tokens: [PrivacyPassToken]
  public let expiration: TimeInterval

  public init(tokens: [PrivacyPassToken], expiration: TimeInterval) {
    self.tokens = tokens
    self.expiration = expiration
  }
}

extension AccountManager {
  private static let requestChallengeEndpoint: URL = endpoint.appendingPathComponent(
    "/request_privacy_pass_challenge")
  private static let issuePrivacyPassEndpoint: URL = endpoint.appendingPathComponent(
    "/issue_privacy_pass")

  // challenge request
  /// Asynchronously requests a Privacy Pass challenge, returning the result via a completion handler on the main thread.
  private func requestPrivacyPassChallenge(
    group: DispatchGroup, count: UInt = 1, authToken: String,
    cancellation: (@escaping () -> Void) -> Void
  ) -> Result<PrivacyPassChallengeResponse, Error> {
    var request = URLRequest(url: Self.requestChallengeEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.addValue(authToken, forHTTPHeaderField: "Authorization")

    let originalTransactionId =
      account?.hasPaidPlan == true ? account?.originalTransactionId : nil
    struct PrivacyPassChallengeRequest: Codable {
      var count: UInt
      var originalTransactionId: String?
    }
    let requestBody = PrivacyPassChallengeRequest(
      count: count, originalTransactionId: originalTransactionId)
    do {
      request.httpBody = try JSONEncoder().encode(requestBody)
    } catch {
      return .failure(error)
    }
    var result: Result<PrivacyPassChallengeResponse, Error>? = nil
    group.enter()
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      defer { group.leave() }
      do {
        if let error = error {
          throw error
        }

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
          let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
          throw AccountError.network("failed with status code: \(statusCode)")
        }

        guard let data = data else {
          throw AccountError.network("no data")
        }

        let decoder = JSONDecoder()
        let challengeResponse = try decoder.decode(PrivacyPassChallengeResponse.self, from: data)
        result = .success(challengeResponse)
      } catch {
        result = .failure(error)
      }
    }
    cancellation {
      task.cancel()
    }
    task.resume()
    group.wait()
    return result ?? .failure(AccountError.network("Didn't return the result."))
  }

  enum PrivacyPassResponseError: Error {
    case signatureEncodingError
  }
  // issue request
  private func issuePrivacyPass(
    group: DispatchGroup, requests: [TokenRequest], authToken: String, blob: String,
    attestationSupported: Bool,
    assertionPayload: AssertionPayload?,
    cancellation: (@escaping () -> Void) -> Void
  ) -> Result<[TokenResponse], Error> {
    struct IssuePrivacyPassRequest: Codable {
      var blindMessages: [String]
      var blob: String
      var attestationSupported: Bool
      var assertionPayload: AssertionPayload?
      var originalTransactionId: String?
    }
    let originalTransactionId =
      account?.hasPaidPlan == true ? account?.originalTransactionId : nil
    let jsonData: Data
    do {
      let requestBody = IssuePrivacyPassRequest(
        blindMessages: requests.map { $0.blindMessage }, blob: blob,
        attestationSupported: attestationSupported,
        assertionPayload: assertionPayload, originalTransactionId: originalTransactionId)
      jsonData = try JSONEncoder().encode(requestBody)
    } catch {
      return .failure(error)
    }
    var request = URLRequest(url: Self.issuePrivacyPassEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.addValue(authToken, forHTTPHeaderField: "Authorization")
    request.httpBody = jsonData
    group.enter()
    var result: Result<[TokenResponse], Error>? = nil
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      defer { group.leave() }
      guard let self else { return }
      do {
        if let error = error {
          self.logger.error("Error: \(error.localizedDescription)")
          throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
          throw AccountError.network("invalid response")
        }
        guard httpResponse.statusCode == 200 else {
          self.logger.error("Failed with status code: \(httpResponse.statusCode)")
          throw AccountError.network("failed with status code: \(httpResponse.statusCode)")
        }
        // Decode the JSON response from the server.
        guard let data = data else {
          throw AccountError.network("no data")
        }
        let issueResponse = try JSONDecoder().decode(IssueResponse.self, from: data)

        // Decode each base64-encoded signature from the response.
        let tokenResponses = try issueResponse.tokenResponses.map { b64Signature -> TokenResponse in
          guard let signatureData = Data(base64Encoded: b64Signature) else {
            throw PrivacyPassResponseError.signatureEncodingError
          }
          return TokenResponse(blindSignature: signatureData)
        }
        result = .success(tokenResponses)
      } catch {
        result = .failure(error)
      }
    }
    cancellation {
      task.cancel()
    }
    task.resume()
    group.wait()
    return result ?? .failure(AccountError.network("Didn't return the result."))
  }

  private func fetchPrivacyPassesFromRemote(
    group: DispatchGroup, count: UInt, base64Blob: String, attestationSupported: Bool,
    assertionPayload: AssertionPayload?, cancellation: (@escaping () -> Void) -> Void
  ) -> Result<
    [(PrivacyPassToken, Date)], Error
  > {
    // request challenges
    var shortTermTokenResult: Result<String, Error>?
    group.enter()
    let task = fetchShortTermToken {
      shortTermTokenResult = $0
      group.leave()
    }
    if let task = task {
      cancellation {
        task.cancel()
      }
    }
    group.wait()
    guard let shortTermTokenResult = shortTermTokenResult else {
      return .failure(AccountError.token("failure to fetch token"))
    }
    switch shortTermTokenResult {
    case .failure(let error):
      return .failure(error)
    case .success(let shortTermToken):
      do {
        let challengeResponse = try requestPrivacyPassChallenge(
          group: group, count: count, authToken: shortTermToken, cancellation: cancellation
        ).get()
        let (requestsWithAuth, publicKey) = try PrivacyPassClient.createTokenRequests(
          publicKeyPem: challengeResponse.key,
          keyID: challengeResponse.keyID,
          challenges: challengeResponse.metadataList
        ).get()
        let tokenResponses = try issuePrivacyPass(
          group: group, requests: requestsWithAuth.map { $0.0 }, authToken: shortTermToken,
          blob: base64Blob,
          attestationSupported: attestationSupported, assertionPayload: assertionPayload,
          cancellation: cancellation
        ).get()
        let authenticators = requestsWithAuth.map { $0.1 }
        // finalize issuance result into tokens
        let tokens = try PrivacyPassClient.finalizeTokens(
          publicKey: publicKey, responses: Array(zip(tokenResponses, authenticators))
        ).get()
        return .success(
          zip(tokens, challengeResponse.metadataList).map {
            return ($0, Date(timeIntervalSince1970: $1.expireAt / 1_000))
          })
      } catch {
        return .failure(error)
      }
    }
  }
  // verify privacy pass token step
  public func authenticate(
    fromBridge: Bool,
    isPrivacyPassEnabled: Bool, blob: GenerationPayload, clientHashData: Data,
    cancellation: (@escaping () -> Void) -> Void
  )
    -> Result<String, Error>
  {
    var workspace = workspace
    let group = DispatchGroup()
    // get assertion
    group.enter()
    // assume attestation is supported on all devices draw things are on
    var attestationSupported = true
    var assertionPayload: AssertionPayload? = nil
    requestAssertion(
      for: clientHashData,
      completion: { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let payload):
          assertionPayload = payload
          self.logger.info("Device assertion obtained! \(payload)")
        case .failure(let error):
          if let error = error as? AccountError, error == .deviceAttestationNotSupported {
            attestationSupported = false
          }
          self.logger.info("Device assertion failed. \(error.localizedDescription)")
        }
        group.leave()
      })
    group.wait()
    guard isPrivacyPassEnabled else {
      // If it is explicitly turned off privacy pass, no need for this property.
      workspace.dictionary["last_request_uses_privacy_pass", Bool.self] = nil
      return authenticate(
        group: group, fromBridge: fromBridge, blob: blob,
        attestationSupported: attestationSupported, assertionPayload: assertionPayload,
        cancellation: cancellation)
    }
    do {
      let now = UInt64(Date().timeIntervalSince1970.rounded(.down))
      let serializedPrivacyTokens = workspace.fetch(for: PrivacyPass.self).where(
        PrivacyPass.expirationDate > now + 3600 + 1800 /* 1.5 hour */,
        orderBy: [PrivacyPass.expirationDate.ascending])
      let authHeaderValue: String
      if serializedPrivacyTokens.isEmpty {
        let privacyPassTokens = try fetchPrivacyPassesFromRemote(
          group: group, count: 5, base64Blob: blob.blob, attestationSupported: attestationSupported,
          assertionPayload: assertionPayload, cancellation: cancellation
        ).get()
        guard !privacyPassTokens.isEmpty else {
          // Privacy pass fetch failed, mark it as failed.
          workspace.dictionary["last_request_uses_privacy_pass", Bool.self] = false
          return authenticate(
            group: group, fromBridge: fromBridge, blob: blob,
            attestationSupported: attestationSupported, assertionPayload: assertionPayload,
            cancellation: cancellation)
        }
        authHeaderValue =
          "PrivateToken token=\(privacyPassTokens[0].0.serialize().base64EncodedString())"
        workspace.performChanges([PrivacyPass.self]) {
          let deletedPrivacyTokens = workspace.fetch(for: PrivacyPass.self).where(
            PrivacyPass.expirationDate <= now)
          for privacyPassToken in privacyPassTokens.dropFirst() {
            let creationRequest = PrivacyPassChangeRequest.creationRequest()
            creationRequest.expirationDate =
              UInt64(privacyPassToken.1.timeIntervalSince1970.rounded(.down)) /* A day */
            creationRequest.token = [UInt8](privacyPassToken.0.serialize())
            creationRequest.id = Int64.random(in: Int64.min...Int64.max)
            $0.try(submit: creationRequest)
          }
          for deletedPrivacyToken in deletedPrivacyTokens {
            guard
              let deletionRequest = PrivacyPassChangeRequest.deletionRequest(deletedPrivacyToken)
            else { continue }
            $0.try(submit: deletionRequest)
          }
        }
      } else {
        authHeaderValue =
          "PrivateToken token=\(Data(serializedPrivacyTokens[0].token).base64EncodedString())"
        workspace.performChanges([PrivacyPass.self]) {
          guard
            let deletionRequest = PrivacyPassChangeRequest.deletionRequest(
              serializedPrivacyTokens[0])
          else { return }
          $0.try(submit: deletionRequest)
        }
      }
      var request = URLRequest(url: Self.authenticateEndpoint)
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(authHeaderValue, forHTTPHeaderField: "Authorization")
      struct PrivateAuthenticationRequest: Codable {
        var blob: String
      }
      request.httpMethod = "POST"
      let requestBody = PrivateAuthenticationRequest(blob: blob.blob)
      guard let body = try? JSONEncoder().encode(requestBody) else {
        logger.error("invalid blob")
        return .failure(JSONError.encoding)
      }
      request.httpBody = body
      workspace.dictionary["last_request_uses_privacy_pass", Bool.self] = true
      return continueAuthenticateRequest(group: group, request: request, cancellation: cancellation)
    } catch {
      // Privacy pass fetch failed, mark it as failed.
      workspace.dictionary["last_request_uses_privacy_pass", Bool.self] = false
      return authenticate(
        group: group, fromBridge: fromBridge, blob: blob,
        attestationSupported: attestationSupported, assertionPayload: assertionPayload,
        cancellation: cancellation)
    }
  }
}
