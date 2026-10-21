import Foundation

public struct OpenRouterKeyStatus: Equatable, Sendable, Decodable {
  public let isFreeTier: Bool?
  public let limit: Double?
  public let limitRemaining: Double?
  public let limitReset: String?
  public let usage: Double?
  public let usageDaily: Double?

  private enum CodingKeys: String, CodingKey {
    case isFreeTier = "is_free_tier"
    case limit
    case limitRemaining = "limit_remaining"
    case limitReset = "limit_reset"
    case usage
    case usageDaily = "usage_daily"
  }
}

public final class OpenRouterKeyStatusClient {
  private struct Response: Decodable {
    var data: OpenRouterKeyStatus
  }

  private let baseURL: URL
  private let session: URLSession

  public init(
    baseURL: URL, sessionConfiguration: URLSessionConfiguration = .ephemeral
  ) {
    self.baseURL = baseURL
    session = URLSession(configuration: sessionConfiguration)
  }

  @discardableResult
  public func fetch(
    authorization: any RemoteAuthorizationProviding,
    completion: @escaping (Result<OpenRouterKeyStatus, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    RemoteAuthorizedRequest(
      authorization: authorization,
      failure: { error in
        completion(
          .failure(
            error is CancellationError
              ? .cancelled : .authentication(error.localizedDescription)))
      }
    ) { [baseURL, session] authorization in
      var request = URLRequest(url: baseURL.appendingPathComponent("key"))
      request.cachePolicy = .reloadIgnoringLocalCacheData
      request.timeoutInterval = 15
      RemoteAuthorizationHeaders.applyBearer(authorization, to: &request)
      let task = session.dataTask(with: request) { data, response, error in
        if let error {
          if (error as? URLError)?.code == .cancelled {
            completion(.failure(.cancelled))
          } else {
            completion(.failure(.network(error.localizedDescription)))
          }
          return
        }
        guard let response = response as? HTTPURLResponse else {
          completion(.failure(.network("The provider returned no HTTP response.")))
          return
        }
        guard (200...299).contains(response.statusCode) else {
          completion(
            .failure(
              .provider(
                statusCode: response.statusCode,
                message: "The OpenRouter status request failed.")))
          return
        }
        guard let data,
          let key = try? JSONDecoder().decode(Response.self, from: data).data
        else {
          completion(.failure(.malformedStream("invalid OpenRouter status response")))
          return
        }
        completion(.success(key))
      }
      task.resume()
      return task
    }
  }
}
