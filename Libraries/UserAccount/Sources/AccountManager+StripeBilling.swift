// Stripe Checkout is for Developer ID builds (`--config=direct`) only. App Store builds buy
// through StoreKit and must not carry an external purchase path.
#if DIRECT_DISTRIBUTION
import Foundation

extension AccountManager {
  public enum StripeSubscriptionSKU: String {
    case plusMonthly = "plus_monthly"
    case maxMonthly = "max_monthly"
  }

  private static let stripePurchaseEndpoint: URL = endpoint.appendingPathComponent(
    "/billing/stripe/purchase")

  private struct StripePurchaseRequest: Codable {
    let kind: String
    let sku: String

    init(kind: String = "subscription", sku: String) {
      self.kind = kind
      self.sku = sku
    }
  }

  private struct StripePurchaseResponse: Codable {
    let id: String
    let url: String
  }

  public func createStripeSubscriptionPurchaseURL(
    sku: StripeSubscriptionSKU,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    fetchShortTermToken { [weak self] result in
      guard let self else {
        completion(.failure(AccountError.network("account manager missing")))
        return
      }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let shortTermToken):
        var request = URLRequest(url: Self.stripePurchaseEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        guard let body = try? JSONEncoder().encode(
          StripePurchaseRequest(sku: sku.rawValue))
        else {
          completion(.failure(JSONError.encoding))
          return
        }
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
          guard let self else { return }
          if let error = error {
            completion(.failure(error))
            return
          }
          guard let httpResponse = response as? HTTPURLResponse else {
            completion(.failure(AccountError.network("invalid http response")))
            return
          }
          guard httpResponse.statusCode == 200 else {
            self.logger.error("Failed with status code: \(httpResponse.statusCode)")
            completion(
              .failure(AccountError.network("failed with status code: \(httpResponse.statusCode)")))
            return
          }
          guard let data = data,
            let purchaseResponse = try? JSONDecoder().decode(
              StripePurchaseResponse.self, from: data),
            let purchaseURL = URL(string: purchaseResponse.url)
          else {
            completion(.failure(JSONError.decoding))
            return
          }
          completion(.success(purchaseURL))
        }
        task.resume()
      }
    }
  }

  public func createStripePlusPurchaseURL(
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    createStripeSubscriptionPurchaseURL(sku: .plusMonthly, completion: completion)
  }
}

extension AccountManager {
  /// Stripe credit for the shared PAYG balance that Draw Things and Local Code spend.
  public enum StripePaygCreditSKU: String, CaseIterable {
    case paygCredit10 = "payg_credit_10"
    case paygCredit50 = "payg_credit_50"
    case paygCredit100 = "payg_credit_100"

    /// The credit the purchase adds to the balance.
    public var microUsd: Int64 {
      switch self {
      case .paygCredit10: 10_000_000
      case .paygCredit50: 50_000_000
      case .paygCredit100: 100_000_000
      }
    }
  }

  /// Creates a Stripe Checkout session that adds credit to the shared PAYG balance. Stripe's
  /// webhook credits the balance once the payment succeeds.
  public func createStripePaygCreditPurchaseURL(
    sku: StripePaygCreditSKU,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    fetchShortTermToken { [weak self] result in
      guard let self else {
        completion(.failure(AccountError.network("account manager missing")))
        return
      }
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let shortTermToken):
        var request = URLRequest(url: Self.stripePurchaseEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        guard let body = try? JSONEncoder().encode(
          StripePurchaseRequest(kind: "payg_credit", sku: sku.rawValue))
        else {
          completion(.failure(JSONError.encoding))
          return
        }
        request.httpBody = body

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
          guard let self else { return }
          if let error = error {
            completion(.failure(error))
            return
          }
          guard let httpResponse = response as? HTTPURLResponse else {
            completion(.failure(AccountError.network("invalid http response")))
            return
          }
          guard httpResponse.statusCode == 200 else {
            self.logger.error("Failed with status code: \(httpResponse.statusCode)")
            completion(
              .failure(AccountError.network("failed with status code: \(httpResponse.statusCode)")))
            return
          }
          guard let data = data,
            let purchaseResponse = try? JSONDecoder().decode(
              StripePurchaseResponse.self, from: data),
            let purchaseURL = URL(string: purchaseResponse.url)
          else {
            completion(.failure(JSONError.decoding))
            return
          }
          completion(.success(purchaseURL))
        }
        task.resume()
      }
    }
  }
}
#endif
