import Combine
import Features
import Logging
import StoreKit

public enum PurchaseError: Error {
  case unverifiedTransaction
  case genericFailure
  case exeptionInPurchase
  case userCancelled
  case pending
  case unfinishedTransaction(Transaction)
}
public class ProductsManager {
  public static let plusSubscriptionIdentifier = "com.drawthings.subscriptions.monthly.plus"
  public static let maxSubscriptionIdentifier = "com.drawthings.subscriptions.monthly.max"
  static let subscriptionIdentifiers = [plusSubscriptionIdentifier, maxSubscriptionIdentifier]
  public static let boostIdentifiers = [
    "com.drawthings.boost.0.99",
    "com.drawthings.boost.4.99",
    "com.drawthings.boost.19.99",
  ]
  public static let cashIdentifiers = [
    "com.drawthings.dollabillz.0.99",
    "com.drawthings.dollabillz.4.99",
    "com.drawthings.dollabillz.19.99",
  ]
  public static let localCodeCredits: [(id: String, microUsd: Int64)] = [
    ("com.liuliu.localcode.credit.9.99", 9_990_000),
    ("com.liuliu.localcode.credit.19.99", 19_990_000),
    ("com.liuliu.localcode.credit.99.99", 99_990_000),
  ]
  public static let localCodeCreditIdentifiers = localCodeCredits.map(\.id)
  public static let consumableIdentifiers = boostIdentifiers + cashIdentifiers
  private static let allConsumableIdentifiers = consumableIdentifiers + localCodeCreditIdentifiers
  private let logger = Logger(label: "com.draw-things.products-manager")

  public static let shared = ProductsManager()

  public enum PurchaseStatus {
    // StoreKit current entitlements have not been replayed for this launch/configuration yet.
    case unresolved
    // StoreKit replay completed and found no active local subscription entitlement.
    case none
    // A purchase or restore request failed; this is not an authoritative entitlement state.
    case failed(Error)
    // StoreKit is waiting for purchase approval and will send a transaction update if it completes.
    case pending
    // StoreKit reported an active local subscription identifier and its original transaction id.
    case purchased(subscriptionIdentifier: String, originalTransactionId: UInt64)
  }

  public enum SubscriptionTier {
    case community
    case plus
    case maxEdition
  }

  private let statusLock: DispatchQueue  // synchronize status updates
  @Published public private(set) var subscriptionStatus: PurchaseStatus = .unresolved
  @Published public private(set) var renewalInfo: Product.SubscriptionInfo.RenewalInfo?
  @Published public private(set) var consumableTransactionUpdate: Transaction?
  public let localCodeTransactions = CurrentValueSubject<[Transaction], Never>([])
  private var transactionListener: Task<Void, Never>? = nil
  // We use too much async / await inside a class (as opposed to actor), it is hard to reason about the updates. Just lock every mutable properties.
  private let subscriptionsLock: DispatchQueue
  // available subs
  private var subscriptions: [Product] = []
  private let consumablesLock: DispatchQueue
  private var consumables: [String: Product] = [:]
  public var boostProducts: [Product] {
    consumablesLock.sync { Self.boostIdentifiers.compactMap { consumables[$0] } }
  }
  public var cashProducts: [Product] {
    consumablesLock.sync { Self.cashIdentifiers.compactMap { consumables[$0] } }
  }
  public var localCodeCreditProducts: [Product] {
    consumablesLock.sync { Self.localCodeCreditIdentifiers.compactMap { consumables[$0] } }
  }
  private let expirationDatesLock: DispatchQueue  // synchronize expiration dates updates
  private var expirationDates: [String: Date] = [:]
  public var isPro: Bool {
    // is pro if any subscription exists and is not expired
    return expirationDatesLock.sync {
      expirationDates.values.contains { $0 > Date() }
    }
  }

  private func product(for identifier: String) -> Product? {
    subscriptionsLock.sync { subscriptions.first(where: { $0.id == identifier }) }
  }

  public var currentPurchaseStatus: PurchaseStatus {
    statusLock.sync { subscriptionStatus }
  }

  public var currentSubscriptionTier: SubscriptionTier {
    statusLock.sync {
      guard case .purchased(let subscriptionIdentifier, _) = subscriptionStatus else {
        return .community
      }
      switch subscriptionIdentifier {
      case Self.maxSubscriptionIdentifier:
        return .maxEdition
      case Self.plusSubscriptionIdentifier:
        return .plus
      default:
        return .community
      }
    }
  }

  private init() {
    statusLock = DispatchQueue(label: "ProductsManager.status")
    subscriptionsLock = DispatchQueue(label: "ProductsManager.subscriptions")
    consumablesLock = DispatchQueue(label: "ProductsManager.consumables")
    expirationDatesLock = DispatchQueue(label: "ProductsManager.expirationDates")
    transactionListener = newTransactionListenerTask()
  }

  deinit {
    transactionListener?.cancel()
  }

  private func newTransactionListenerTask() -> Task<Void, Never> {
    Task { [weak self] in
      for await result in Transaction.updates {
        guard let self else { return }
        guard let transaction = verify(result) else {
          // ignore unverified transactions
          continue
        }
        guard ProductsManager.subscriptionIdentifiers.contains(transaction.productID) else {
          if Self.localCodeCreditIdentifiers.contains(transaction.productID) {
            self.recordLocalCodeTransaction(transaction)
          } else if Self.consumableIdentifiers.contains(transaction.productID) {
            self.statusLock.sync {
              // Finish consumables only after the owning account backend confirms receipt.
              self.consumableTransactionUpdate = transaction
            }
          }
          continue
        }
        await self.updateAutorenewableStatuses()
        await transaction.finish()
      }
    }
  }

  private func fetchAllProducts() async throws {
    let products = try await Product.products(
      for: Self.subscriptionIdentifiers + Self.allConsumableIdentifiers)
    for product in products {
      switch product.type {
      case .autoRenewable:
        subscriptionsLock.sync {
          subscriptions.append(product)
          subscriptions.sort {
            Self.subscriptionIdentifiers.firstIndex(of: $0.id) ?? Int.max
              < Self.subscriptionIdentifiers.firstIndex(of: $1.id) ?? Int.max
          }
        }
      case .consumable:
        consumablesLock.sync { consumables[product.id] = product }
      default:
        // no other types of products we support currently
        logger.debug("Unknown product with identifier \(product.id)")
      }
    }
  }

  private func updateAutorenewableStatuses() async {
    var activeExpirationDates = [String: Date]()
    var activeSubscriptionIdentifier: String?
    var activeSubscriptionOriginalId: UInt64?
    let now = Date()
    for await result in Transaction.currentEntitlements {
      guard let transaction = verify(result) else { continue }
      switch transaction.productType {
      case .autoRenewable:
        guard Self.subscriptionIdentifiers.contains(transaction.productID) else { continue }
        guard let expirationDate = transaction.expirationDate, expirationDate > now else {
          continue
        }
        let sub = subscriptionsLock.sync {
          subscriptions.first(where: { $0.id == transaction.productID })
        }
        if let status = try? await sub?.subscription?.status.first,
          let autoRenewStatus = verify(status.renewalInfo), renewalInfo != autoRenewStatus
        {
          logger.debug("Auto Renewal status changed to \(autoRenewStatus.willAutoRenew)")
          renewalInfo = autoRenewStatus
        }
        activeExpirationDates[transaction.productID] = expirationDate
        // Max wins over Plus if both entitlements are active, regardless of replay order.
        if transaction.productID == Self.maxSubscriptionIdentifier
          || activeSubscriptionIdentifier == nil
        {
          activeSubscriptionIdentifier = transaction.productID
          activeSubscriptionOriginalId = transaction.originalID
        }
      default:
        break
      }
    }
    expirationDatesLock.sync {
      for identifier in Self.subscriptionIdentifiers {
        expirationDates[identifier] = nil
      }
      for (identifier, expirationDate) in activeExpirationDates {
        expirationDates[identifier] = expirationDate
      }
    }
    let purchaseStatus: PurchaseStatus
    if let activeSubscriptionIdentifier, let activeSubscriptionOriginalId {
      purchaseStatus = .purchased(
        subscriptionIdentifier: activeSubscriptionIdentifier,
        originalTransactionId: activeSubscriptionOriginalId)
    } else {
      purchaseStatus = .none
    }
    statusLock.sync {
      subscriptionStatus = purchaseStatus
    }
  }

  private func purchaseSubscription(_ product: Product, appAccountToken: UUID) async throws
    -> UInt64?
  {
    let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])

    switch result {
    case .success(let result):
      guard let verificationResult = verify(result) else {
        return nil
      }
      await updateAutorenewableStatuses()
      await verificationResult.finish()
      return verificationResult.originalID
    case .userCancelled:
      break
    case .pending:
      // There is no need to manage in your UI pending In-app purchases for the 24-hour period. While it's recommended at time of purchases, once the customer navigates away and back to the In-app purchase buy button, they are safe to re-request if they so wish. Any duplicate Ask to Buy requests are consolidated and only resets the 24-hour timer. Once approved, only 1 purchase is completed.
      // https://forums.developer.apple.com/forums/thread/706277
      // If a pending purchase succeeds, StoreKit delivers the resulting Transaction in the transaction updates.
      statusLock.sync { subscriptionStatus = .pending }
    @unknown default:
      fatalError()
    }

    return nil
  }

  private func verify<T>(_ result: VerificationResult<T>) -> T? {
    guard case .verified(let transaction) = result else {
      // Ignore unverified transactions. default experience
      logger.debug("unverified transactions")
      return nil
    }
    return transaction
  }
}

extension ProductsManager {
  // public apis
  public func configure() {
    // Unfinished LocalCode purchases must be redelivered after a crash or an
    // offline launch, even when product discovery is temporarily unavailable.
    Task.detached { [weak self] in
      guard let self else { return }
      for await result in Transaction.unfinished {
        if let transaction = verify(result),
          Self.localCodeCreditIdentifiers.contains(transaction.productID)
        {
          recordLocalCodeTransaction(transaction)
        }
      }
    }
    Task.detached { [weak self] in
      try await self?.fetchAllProducts()
      await self?.updateAutorenewableStatuses()
    }
  }

  public func refreshProducts() {
    Task.detached { [weak self] in
      await self?.updateAutorenewableStatuses()
    }
  }

  // whenever a product is purchased we should always let the server know about the original transaction id
  public func purchasePlus(appAccountToken: UUID, completionHandler: @escaping () -> Void) {
    guard let product = product(for: Self.plusSubscriptionIdentifier) else {
      completionHandler()
      return
    }
    Task.detached { [weak self] in
      guard let self else {
        completionHandler()
        return
      }
      do {
        if let originalTransactionId = try await self.purchaseSubscription(
          product, appAccountToken: appAccountToken)
        {
          statusLock.sync {
            self.subscriptionStatus = .purchased(
              subscriptionIdentifier: Self.plusSubscriptionIdentifier,
              originalTransactionId: originalTransactionId)
          }
        }
      } catch {
        statusLock.sync { self.subscriptionStatus = .failed(error) }
      }
      completionHandler()
    }
  }

  public func purchaseMax(appAccountToken: UUID, completionHandler: @escaping () -> Void) {
    guard let product = product(for: Self.maxSubscriptionIdentifier) else {
      completionHandler()
      return
    }
    Task.detached { [weak self] in
      guard let self else {
        completionHandler()
        return
      }
      do {
        if let originalTransactionId = try await self.purchaseSubscription(
          product, appAccountToken: appAccountToken)
        {
          statusLock.sync {
            self.subscriptionStatus = .purchased(
              subscriptionIdentifier: Self.maxSubscriptionIdentifier,
              originalTransactionId: originalTransactionId)
          }
        }
      } catch {
        statusLock.sync { self.subscriptionStatus = .failed(error) }
      }
      completionHandler()
    }
  }

  public func restorePurchases(restoredSubscriptionHandler: @escaping (String, UInt64) -> Void) {
    Task.detached { [weak self] in
      guard let self else { return }
      do {
        try await AppStore.sync()
        await updateAutorenewableStatuses()
        statusLock.sync {
          switch self.subscriptionStatus {
          case .purchased(let subscriptionIdentifier, let originalTransactionId):
            restoredSubscriptionHandler(subscriptionIdentifier, originalTransactionId)
          default:
            break
          }
        }
      } catch {
        statusLock.sync { self.subscriptionStatus = .failed(error) }
      }
    }
  }

  public func getIntroductoryOfferDiscount() -> String? {
    guard let product = product(for: Self.plusSubscriptionIdentifier),
      let introductoryOfferPrice = product.subscription?.introductoryOffer?.price
    else { return nil }
    return ((product.price - introductoryOfferPrice) / product.price).formatted(
      .percent.precision(.fractionLength(0)))
  }

  public func getDTPlusPrice() -> String? {
    guard let product = product(for: Self.plusSubscriptionIdentifier)
    else { return nil }
    return product.displayPrice
  }

  public func getDTMaxPrice() -> String? {
    guard let product = product(for: Self.maxSubscriptionIdentifier)
    else { return nil }
    return product.displayPrice
  }

  public func getExpirationDate(for subscriptionIdentifier: String? = nil) -> Date? {
    let identifier =
      subscriptionIdentifier
      ?? {
        switch currentSubscriptionTier {
        case .plus:
          Self.plusSubscriptionIdentifier
        case .maxEdition:
          Self.maxSubscriptionIdentifier
        case .community:
          Self.plusSubscriptionIdentifier
        }
      }()
    return expirationDatesLock.sync {
      expirationDates[identifier]
    }
  }

  public func getDTPlusIntroductoryPrice() -> String? {
    guard let product = product(for: Self.plusSubscriptionIdentifier),
      let introductoryOfferPrice = product.subscription?.introductoryOffer?.displayPrice
    else { return "" }
    return introductoryOfferPrice
  }
}

// consumables
extension ProductsManager {
  public func purchaseConsumable(
    _ productId: String, appAccountToken: UUID,
    completionHandler: @escaping ((Result<Transaction, PurchaseError>) -> Void)
  ) {
    guard Self.allConsumableIdentifiers.contains(productId) else {
      completionHandler(.failure(PurchaseError.genericFailure))
      return
    }
    Task.detached { [weak self] in
      guard let self else {
        completionHandler(.failure(PurchaseError.genericFailure))
        return
      }
      // make sure the unfinished transactions do not include the current purchase
      for await unfinished in Transaction.unfinished {
        if let verifiedUnfinishedTransaction = verify(unfinished),
          verifiedUnfinishedTransaction.productID == productId,
          !Self.localCodeCreditIdentifiers.contains(productId)
            || verifiedUnfinishedTransaction.appAccountToken == appAccountToken
        {
          completionHandler(
            .failure(PurchaseError.unfinishedTransaction(verifiedUnfinishedTransaction)))
          return
        }
      }
      do {
        // Product discovery can still be in flight at launch, or have failed while offline.
        var product = consumablesLock.sync { self.consumables[productId] }
        if product == nil && Self.localCodeCreditIdentifiers.contains(productId) {
          product = try await Product.products(for: [productId]).first
          if let product, product.type == .consumable {
            consumablesLock.sync { self.consumables[productId] = product }
          }
        }
        guard let product, product.type == .consumable else {
          if Self.localCodeCreditIdentifiers.contains(productId) {
            completionHandler(.failure(PurchaseError.genericFailure))
          }
          return
        }
        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
        switch result {
        case .success(let transaction):
          guard let verifiedTransaction = verify(transaction) else {
            completionHandler(.failure(PurchaseError.unverifiedTransaction))
            return
          }
          completionHandler(.success(verifiedTransaction))
          print("purchase succeeded \(verifiedTransaction.id), \(verifiedTransaction.originalID)")
        case .userCancelled:
          // user canceled no error no op
          completionHandler(.failure(PurchaseError.userCancelled))
          break
        case .pending:
          if Self.localCodeCreditIdentifiers.contains(productId) {
            completionHandler(.failure(PurchaseError.pending))
          }
        // There is no need to manage in your UI pending In-app purchases for the 24-hour period. While it's recommended at time of purchases, once the customer navigates away and back to the In-app purchase buy button, they are safe to re-request if they so wish. Any duplicate Ask to Buy requests are consolidated and only resets the 24-hour timer. Once approved, only 1 purchase is completed.
        // https://forums.developer.apple.com/forums/thread/706277
        // If a pending purchase succeeds, StoreKit delivers the resulting Transaction in the transaction updates.
        @unknown default:
          fatalError()
        }
      } catch {
        completionHandler(.failure(PurchaseError.exeptionInPurchase))
      }
    }
  }

  public func finishTransaction(_ transaction: Transaction) {
    if Self.localCodeCreditIdentifiers.contains(transaction.productID) {
      statusLock.sync {
        localCodeTransactions.value.removeAll { $0.id == transaction.id }
      }
    }
    Task.detached {
      await transaction.finish()
    }
  }

  public func recordLocalCodeTransaction(_ transaction: Transaction) {
    guard Self.localCodeCreditIdentifiers.contains(transaction.productID) else { return }
    statusLock.sync {
      var transactions = localCodeTransactions.value
      if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
        transactions[index] = transaction
      } else {
        transactions.append(transaction)
      }
      localCodeTransactions.send(transactions)
    }
  }
}
