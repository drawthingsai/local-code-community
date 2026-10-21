import Dflat
import Foundation
import Logging
import StoreKit

extension AccountManager {
  public var appAccountToken: UUID? {
    guard let token = account?.shortTermToken,
      let id = Self.decode(jwtToken: token)?["id"] as? String
    else { return nil }
    return Self.generateStableUUID(from: id)
  }

  public func purchaseLocalCodeCredit(
    productId: String,
    completion: @escaping (Result<Transaction, Error>) -> Void
  ) {
    guard ProductsManager.localCodeCreditIdentifiers.contains(productId) else {
      completion(.failure(PurchaseError.genericFailure))
      return
    }
    fetchShortTermToken { [weak self] result in
      switch result {
      case .failure(let error):
        completion(.failure(error))
      case .success(let shortTermToken):
        guard let id = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
          completion(.failure(APIError.userIdMissing))
          return
        }
        let token = Self.generateStableUUID(from: id)
        guard self?.appAccountToken == token else {
          completion(
            .failure(AccountError.token("The purchase account changed. Please try again.")))
          return
        }
        ProductsManager.shared.purchaseConsumable(
          productId, appAccountToken: token
        ) { result in
          switch result {
          case .success(let transaction), .failure(.unfinishedTransaction(let transaction)):
            completion(.success(transaction))
          case .failure(let error):
            completion(.failure(error))
          }
        }
      }
    }
  }

  // request
  public enum UsageActionType: String, Codable {
    case purchase = "purchase"
    case start = "start"
    case swap = "swap"
    case get = "get"
  }

  public struct UsageAction: Codable {
    public enum CurrencyType: String, Codable {
      case boost
      case dollar
    }
    public struct TransferFundsPayload: Codable {
      public let amount: String
      public let fromType: CurrencyType
    }
    public struct PurchasePayload: Codable {
      public let transactionId: UInt64
      public let originalTransactionId: UInt64
      public let productId: String
      public let hasConsent: Bool
      public let isSandbox: Bool
    }

    public let type: UsageActionType
    public let appAccountToken: String
    public let purchasePayload: PurchasePayload?
    public let transferFundsPayload: TransferFundsPayload?
  }

  public struct ManageConsumableRequestBody: Codable {
    public let action: UsageAction
  }

  public struct RestorePurchaseRequestBody: Codable {
    var appAccountToken: String
    var originalTransactionId: UInt64
    var isSandbox: Bool = false
  }

  // response
  public struct ConsumableMetadata: Codable {
    public let balance: [String: Balance]
    public let accountInfo: ConsumableAccountInfo
    public let inProgressUsages: [String: InProgressUsage]
  }

  public struct InProgressUsage: Codable {
    public let generationId: String
    public let type: String
    public let amount: Double
  }

  public struct Balance: Codable {
    public let balance: Double
    public let inProgressBalance: Double
    public let lifetimeUsage: Double

    var consumableBalance: ConsumableBalance {
      ConsumableBalance(balance: balance, inProgressBalance: inProgressBalance)
    }
  }

  public struct ConsumableAccountInfo: Codable {
    public let firstPurchaseDate: String?  // date of the first purchase, consumption request expects a range value for accountTenure
    public let lifetimeDollarsPurchased: Double  // actual dollars purchased, consumption request expects a range value
    public let lifetimeDollarsRefunded: Double  // actual dollars refunded, consumption request expects a range value
    public let customerConsented: Bool  // recorded at the first time of purchase
  }

  public struct ConsumableUsage: Codable {
    public let transactionId: UInt64
    public let originalTransactionId: UInt64
    public let productId: String

  }

  public enum APIError: Error {
    case userIdMissing
    case encodingError
    case badResponse(statusCode: Int, data: Data?)
    case decodingError(Error)

    var message: Logger.Message {
      switch self {
      case .userIdMissing:
        return "User ID is missing, this should never happen"
      case .badResponse(let statusCode, let data):
        return
          "Bad response status code: \(statusCode), data: \(String(data: data ?? Data(), encoding: .utf8) ?? "nil")"
      case .decodingError(let error):
        return "Decoding error: \(error)"
      case .encodingError:
        return "Encoding error"
      }
    }
  }

  private static let manageConsumableBalanceEndpoint: URL = endpoint.appendingPathComponent(
    "/manage_consumable_balance")
  static let restorePurchaseEndpoint: URL = endpoint.appendingPathComponent(
    "/restore_purchase")

  // endpoints handlers
  public func purchaseConsumable(
    productId: String, hasConsent: Bool, completion: ((Result<Void, Error>) -> Void)?
  ) {
    fetchShortTermToken { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let shortTermToken):
        guard let id = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
          self.logger.error(AccountManager.APIError.userIdMissing.message)
          return
        }
        ProductsManager.shared.purchaseConsumable(
          productId, appAccountToken: Self.generateStableUUID(from: id)
        ) { [weak self] result in
          guard let self else { return }
          switch result {
          case .success(let transaction):
            self.recordPurchaseConsumable(
              transaction, hasConsent: hasConsent, completion: completion)
          case .failure(let error):
            switch error {
            case .unfinishedTransaction(let transaction):
              self.recordPurchaseConsumable(
                transaction, hasConsent: hasConsent, completion: completion)
            default:
              completion?(.failure(error))
            }
          }
        }
      default:
        return
      }
    }
  }
  func recordPurchaseConsumable(
    _ transaction: Transaction, hasConsent: Bool, completion: ((Result<Void, Error>) -> Void)?
  ) {
    fetchShortTermToken { [weak self] shortTermTokenResult in
      guard let self else { return }
      switch shortTermTokenResult {
      case .success(let shortTermToken):
        guard let id = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
          self.logger.error(APIError.userIdMissing.message)
          completion?(.failure(APIError.userIdMissing))
          return
        }
        let isSandbox: Bool
        if #available(iOS 16.0, *) {
          isSandbox = transaction.environment == AppStore.Environment.sandbox
        } else {
          isSandbox = false
        }
        let action = UsageAction(
          type: .purchase,
          appAccountToken: Self.generateStableUUID(from: id).uuidString.lowercased(),
          purchasePayload: UsageAction.PurchasePayload(
            transactionId: transaction.id, originalTransactionId: transaction.originalID,
            productId: transaction.productID, hasConsent: hasConsent, isSandbox: isSandbox),
          transferFundsPayload: nil)
        let body = ManageConsumableRequestBody(action: action)

        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(body) else {
          self.logger.error(APIError.encodingError.message)
          completion?(.failure(APIError.encodingError))
          return
        }

        var request = URLRequest(url: Self.manageConsumableBalanceEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
          if let error = error {
            self.logger.error("\(error)")
            completion?(.failure(PurchaseError.unfinishedTransaction(transaction)))
            return
          }
          guard let http = response as? HTTPURLResponse else {
            self.logger.error(APIError.badResponse(statusCode: -1, data: data).message)
            completion?(.failure(PurchaseError.unfinishedTransaction(transaction)))
            return
          }
          guard (200...299).contains(http.statusCode), let data = data else {
            self.logger.error(APIError.badResponse(statusCode: http.statusCode, data: data).message)
            completion?(.failure(PurchaseError.unfinishedTransaction(transaction)))
            return
          }
          let decoder = JSONDecoder()
          do {
            let metadata = try decoder.decode(ConsumableMetadata.self, from: data)
            self.updateBalance(metadata)
            completion?(.success(()))
            ProductsManager.shared.finishTransaction(transaction)
          } catch {
            self.logger.error(APIError.decodingError(error).message)
            completion?(.failure(PurchaseError.unfinishedTransaction(transaction)))
          }
        }
        task.resume()
      default:
        return
      }
    }
  }

  public func retrieveConsumableBalances() {
    guard account?.hasPaidPlan == true else { return }
    fetchShortTermToken { [weak self] shortTermTokenResult in
      guard let self else { return }
      switch shortTermTokenResult {
      case .success(let shortTermToken):
        guard let id = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
          self.logger.error(APIError.userIdMissing.message)
          return
        }
        let action = UsageAction(
          type: .get,
          appAccountToken: Self.generateStableUUID(from: id).uuidString.lowercased(),
          purchasePayload: nil, transferFundsPayload: nil)
        let body = ManageConsumableRequestBody(action: action)

        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(body) else {
          self.logger.log(level: .error, "encoding error")
          return
        }

        var request = URLRequest(url: Self.manageConsumableBalanceEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
          if let error = error {
            self.logger.log(level: .error, "\(error.localizedDescription)")
            return
          }
          guard let http = response as? HTTPURLResponse else {
            self.logger.log(level: .error, "bad response")
            return
          }
          guard (200...299).contains(http.statusCode), let data = data else {
            self.logger.log(level: .error, "bad response")
            return
          }

          let decoder = JSONDecoder()
          do {
            let metadata = try decoder.decode(ConsumableMetadata.self, from: data)
            self.updateBalance(metadata)
          } catch {
            self.logger.log(level: .error, "response decoding error")
          }
        }
        task.resume()
      default:
        return
      }
    }
  }
}
