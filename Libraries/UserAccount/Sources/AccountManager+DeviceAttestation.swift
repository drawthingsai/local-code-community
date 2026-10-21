import Crypto
import DeviceAttestation
import DeviceCheck
import Foundation

// MARK: - DeviceAttestationService

extension AccountManager {

  private static let attestationChallengeEndpoint: URL = endpoint.appendingPathComponent(
    "/get_challenge")
  private static let verifyAttestationEndpoint: URL = endpoint.appendingPathComponent(
    "/verify_attestation")
  private static let verifyAssertionEndpoint: URL = endpoint.appendingPathComponent(
    "/verify_assertion")
  static let attestedKeyId = "ATTESTED_KEY_ID"

  private func requestAssertion(
    clientDataHash: Data, attestedKeyId: String,
    completion: @escaping (Result<AssertionPayload, Error>) -> Void
  ) {
    DCAppAttestService.shared.generateAssertion(attestedKeyId, clientDataHash: clientDataHash) {
      assertion, error in
      if let error = error {
        completion(.failure(error))
        return
      }
      guard let assertion = assertion else {
        completion(.failure(AccountError.network("No assertion data received.")))
        return
      }

      let payload = AssertionPayload(
        assertion: assertion.base64EncodedString(),
        keyId: attestedKeyId
      )
      completion(.success(payload))
    }
  }

  func requestAssertion(
    for clientHashData: Data, completion: @escaping (Result<AssertionPayload, Error>) -> Void
  ) {
    let clientDataHash = Data(SHA256.hash(data: clientHashData))
    guard let keyId = workspace.dictionary[Self.attestedKeyId, String.self] else {
      // if no key was previously generated request device attestation verification
      verifyAttestation { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let keyId):
          // continue assertion
          self.requestAssertion(
            clientDataHash: clientDataHash, attestedKeyId: keyId, completion: completion)
          self.logger.info("Device successfully attested! KeyId saved.")
        case .failure(let error):
          completion(.failure(error))
          self.logger.info("Device attestation failed. \(error.localizedDescription)")
        }
      }
      return
    }
    requestAssertion(clientDataHash: clientDataHash, attestedKeyId: keyId, completion: completion)
  }

  func verifyAttestation(completion: @escaping (Result<String, Error>) -> Void) {
    guard DCAppAttestService.shared.isSupported else {
      completion(.failure(AccountError.deviceAttestationNotSupported))
      return
    }

    fetchShortTermToken { [weak self] shortTermTokenResult in
      guard let self = self else { return }
      switch shortTermTokenResult {
      case .failure(let failure):
        completion(.failure(failure))
        return
      case .success(let shortTermToken):
        self.getChallenge(token: shortTermToken) { challengeResult in
          switch challengeResult {
          case .failure(let failure):
            completion(.failure(failure))
            return
          case .success(let challenge):
            self.generateKey { keyIdResult in
              switch keyIdResult {
              case .failure(let failure):
                completion(.failure(failure))
                return
              case .success(let keyId):
                self.attestKey(keyId: keyId, challenge: challenge) { attestationResult in
                  switch attestationResult {
                  case .failure(let failure):
                    completion(.failure(failure))
                    return
                  case .success(let attestationObject):
                    let requestBody = AttestationRequest(
                      attestation: attestationObject, keyId: keyId, challenge: challenge)
                    do {
                      let data = try JSONEncoder().encode(requestBody)
                      self.makeAuthenticatedRequest(
                        url: Self.verifyAttestationEndpoint, method: "POST", token: shortTermToken,
                        body: data
                      ) { result in
                        guard let _ = try? result.get() else {
                          if case .failure(let error) = result { completion(.failure(error)) }
                          return
                        }
                        self.workspace.dictionary[Self.attestedKeyId] = keyId
                        completion(.success(keyId))
                      }
                    } catch {
                      completion(.failure(JSONError.encoding))
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  private func makeAuthenticatedRequest(
    url: URL, method: String, token: String, body: Data?,
    completion: @escaping (Result<Data, Error>) -> Void
  ) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(token, forHTTPHeaderField: "Authorization")
    request.httpBody = body

    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        completion(.failure(AccountError.network(error.localizedDescription)))
        return
      }

      guard let httpResponse = response as? HTTPURLResponse,
        (200...299).contains(httpResponse.statusCode)
      else {
        completion(
          .failure(AccountError.network("Invalid server response. \(response.debugDescription)")))
        return
      }

      guard let data = data else {
        completion(.failure(AccountError.network("No data received.")))
        return
      }

      completion(.success(data))
    }.resume()
  }

  private func getChallenge(token: String, completion: @escaping (Result<String, Error>) -> Void) {
    makeAuthenticatedRequest(
      url: Self.attestationChallengeEndpoint, method: "POST", token: token, body: nil
    ) { result in
      completion(
        result.flatMap { data in
          do {
            let challengeResponse = try JSONDecoder().decode(ChallengeResponse.self, from: data)
            return .success(challengeResponse.challenge)
          } catch {
            return .failure(JSONError.decoding)
          }
        })
    }
  }

  private func generateKey(completion: @escaping (Result<String, Error>) -> Void) {
    DCAppAttestService.shared.generateKey { keyId, error in
      if let error = error {
        completion(.failure(error))
        return
      }
      guard let keyId = keyId else {
        completion(.failure(AccountError.message("Could not generate keyId.")))
        return
      }
      completion(.success(keyId))
    }
  }

  private func attestKey(
    keyId: String, challenge: String, completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard let challengeData = challenge.data(using: .utf8) else {
      completion(.failure(AccountError.message("Could not convert challenge to data.")))
      return
    }
    let hash = Data(SHA256.hash(data: challengeData))

    DCAppAttestService.shared.attestKey(keyId, clientDataHash: hash) { attestation, error in
      if let error = error {
        completion(.failure(error))
        return
      }
      guard let attestation = attestation else {
        completion(.failure(AccountError.network("No attestation data received.")))
        return
      }
      completion(.success(attestation.base64EncodedString()))
    }
  }
}
