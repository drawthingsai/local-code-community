import Foundation
import Localization

final class AccountClient {
  struct CreditSnapshot: Codable, Equatable {
    let balanceMicroUsd: Int64
    let reservedMicroUsd: Int64
    let availableMicroUsd: Int64
    let lifetimeSettledMicroUsd: Int64
    let unit: String
  }

  struct HostedModel: Codable, Equatable {
    let id: String
    let name: String?
  }

  struct APIKeyResponse: Decodable {
    let apiKey: String
  }

  enum ClientError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case decoding
    case missingDefaultAPIKey

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        return LocalizedString.forKey("cloud_compute_invalid_response")
      case .httpStatus(let status, let message):
        return LocalizedString.format(key: "cloud_compute_http_error", status, message)
      case .decoding:
        return LocalizedString.forKey("cloud_compute_decoding_failed")
      case .missingDefaultAPIKey:
        return LocalizedString.forKey("cloud_compute_missing_default_api_key")
      }
    }
  }

  private struct APIKeyListResponse: Decodable {
    let defaultKey: APIKeyResponse?
  }

  private struct ModelListResponse: Decodable {
    let data: [HostedModel]
  }

  let baseURL: URL
  private let session: URLSession

  init(baseURL: URL, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
  }

  var openAICompatibleBaseURL: URL {
    baseURL.appendingPathComponent("v1/openrouter", isDirectory: false)
  }

  @discardableResult
  func provisionDefaultAPIKey(
    accessToken: String,
    completion: @escaping (Result<String, Error>) -> Void
  ) -> URLSessionDataTask {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/account/api-keys"))
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    return perform(request, response: APIKeyListResponse.self) { [weak self] result in
      switch result {
      case .success(let response):
        if let apiKey = response.defaultKey?.apiKey, apiKey.hasPrefix("dk_") {
          completion(.success(apiKey))
          return
        }
        guard let self else { return }
        var createRequest = URLRequest(
          url: self.baseURL.appendingPathComponent("v1/account/api-keys"))
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try? JSONSerialization.data(withJSONObject: ["name": "Default"])
        self.perform(createRequest, response: APIKeyResponse.self) { creationResult in
          switch creationResult {
          case .success(let response) where response.apiKey.hasPrefix("dk_"):
            completion(.success(response.apiKey))
          case .success:
            completion(.failure(ClientError.missingDefaultAPIKey))
          case .failure(let error):
            completion(.failure(error))
          }
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  @discardableResult
  func fetchCreditSnapshot(
    apiKey: String,
    completion: @escaping (Result<CreditSnapshot, Error>) -> Void
  ) -> URLSessionDataTask {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/account"))
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return perform(request, response: CreditSnapshot.self, completion: completion)
  }

  @discardableResult
  func fetchHostedModels(
    apiKey: String,
    completion: @escaping (Result<[HostedModel], Error>) -> Void
  ) -> URLSessionDataTask {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    return perform(request, response: ModelListResponse.self) { result in
      completion(result.map(\.data))
    }
  }

  @discardableResult
  func deleteLocalCodeAccount(
    accessToken: String,
    completion: @escaping (Result<Void, Error>) -> Void
  ) -> URLSessionDataTask {
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/account"))
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    return performData(request) { result in completion(result.map { _ in () }) }
  }

  @discardableResult
  func deliverPurchase(
    transactionId: UInt64,
    isSandbox: Bool,
    customerConsented: Bool,
    accessToken: String,
    completion: @escaping (Result<CreditSnapshot, Error>) -> Void
  ) -> URLSessionDataTask {
    struct PurchaseDelivery: Encodable {
      let transactionId: String
      let environment: String
      let customerConsented: Bool
    }
    var request = URLRequest(url: baseURL.appendingPathComponent("v1/account/purchases"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(
      PurchaseDelivery(
        transactionId: String(transactionId),
        environment: isSandbox ? "Sandbox" : "Production",
        customerConsented: customerConsented))
    return perform(request, response: CreditSnapshot.self, completion: completion)
  }

  @discardableResult
  private func perform<Response: Decodable>(
    _ request: URLRequest,
    response: Response.Type,
    completion: @escaping (Result<Response, Error>) -> Void
  ) -> URLSessionDataTask {
    performData(request) { result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let data):
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
          completion(.failure(ClientError.decoding))
          return
        }
        completion(.success(value))
      }
    }
  }

  @discardableResult
  private func performData(
    _ request: URLRequest,
    completion: @escaping (Result<Data, Error>) -> Void
  ) -> URLSessionDataTask {
    let task = session.dataTask(with: request) { data, response, error in
      if let error {
        completion(.failure(error))
        return
      }
      guard let response = response as? HTTPURLResponse else {
        completion(.failure(ClientError.invalidResponse))
        return
      }
      guard (200...299).contains(response.statusCode) else {
        let root = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let message =
          (root?["message"] as? String
          ?? (root?["error"] as? [String: Any])?["message"] as? String
          ?? LocalizedString.forKey("request_failed")).replacingOccurrences(
            of: #"dk_[A-Za-z0-9_-]+"#, with: "<redacted>", options: .regularExpression)
        completion(.failure(ClientError.httpStatus(response.statusCode, message)))
        return
      }
      completion(.success(data ?? Data()))
    }
    task.resume()
    return task
  }
}

enum AccountRouterConfiguration {
  // api.drawthings.ai routes /code/v1/* to the router; workers.dev is blocked in mainland China.
  static let baseURL = URL(string: "https://api.drawthings.ai/code")!

  static func appleWebSignInURL(bundle: Bundle = .main) -> URL? {
    let configured =
      bundle.object(forInfoDictionaryKey: "LocalCodeAppleWebSignInURL") as? String
    if let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      let url = URL(string: value),
      url.scheme?.lowercased() == "https"
    {
      return url
    }
    return URL(string: "https://api.drawthings.ai/auth/apple/localcode/login")
  }
}
