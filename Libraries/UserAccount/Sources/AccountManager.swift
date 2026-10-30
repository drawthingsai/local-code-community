import Atomics
import AuthenticationServices
import Combine
import CryptoKit
import DeviceAttestation
import Dflat
import Foundation
import Localization
import Logging

#if canImport(UIKit)
  import UIKit
#endif

extension AccountManager {
  public enum AccountError: Error, Equatable, LocalizedError {
    case message(String)
    case token(String)
    case network(String)
    case subscriptionVerificationFailed
    case deviceAttestationNotSupported

    public var errorDescription: String? {
      switch self {
      case .message(let message), .token(let message), .network(let message):
        return message
      case .subscriptionVerificationFailed:
        return LocalizedString.forKey("lora_upload_subscription_verification_error_message")
      case .deviceAttestationNotSupported:
        return "Device attestation is not supported."
      }
    }
  }

  public enum JSONError: Error, LocalizedError {
    case encoding
    case decoding

    public var errorDescription: String? {
      switch self {
      case .encoding:
        return "Could not encode request data."
      case .decoding:
        return "Could not decode response data."
      }
    }
  }

  // Responses
  struct RegistrationResponse: Codable {
    enum VerificationStatus: Int, Codable {
      case verifiedNew
      case verifiedExisting
      case notVerified
    }
    var verified: VerificationStatus
    var accessToken: String
    var refreshToken: String
  }

  struct RefreshResponse: Codable {
    var accessToken: String
    var refreshToken: String?
  }

  struct RefreshRequest: Codable {
    var refreshLongTermToken: Bool

    enum CodingKeys: String, CodingKey {
      case refreshLongTermToken = "refresh_long_term_token"
    }
  }

  struct AuthenticationResponse: Codable {
    var gRPCToken: String  // signed token with nonce in the payload
  }

  struct OverrideAccountResponse: Codable {
    enum PlanType: String, Codable {
      case free
      case community
      case plus
      case max
    }
    var subscriptionStatus: PlanType
  }

  public struct GetSignedURLResponse: Codable {
    public struct File: Codable {
      public var file: String  // local lora file property
      public var key: String  // file key name in bucket
      public var size: Int64  // size of the file
    }

    public struct StorageLimitExceedPayload: Codable {
      public var freeSpace: Int64  // bytes
      public var files: [File]
    }

    public struct SignedURLsPayload: Codable {
      public struct FileInfo: Codable {
        public var sha256: String
        public var url: String
      }
      public var urls: [String: FileInfo]  // lora file property mapped to signed upload url string
    }

    public enum DataPayload: Codable {
      case storageLimitExceeded(StorageLimitExceedPayload)
      case signedUrls(SignedURLsPayload)
      case alreadyExists([String: String])
    }
    struct JSONDataPayload: Codable {
      public var storageLimitExceeded: StorageLimitExceedPayload?
      public var signedUrls: SignedURLsPayload?
      public var alreadyExists: [String: String]?
      public var dataPayload: DataPayload {
        if let storageLimitExceeded {
          return .storageLimitExceeded(storageLimitExceeded)
        } else if let signedUrls {
          return .signedUrls(signedUrls)
        } else {
          return .alreadyExists(alreadyExists ?? [:])
        }
      }
    }
    var code: UInt
    var data: JSONDataPayload
  }

  // Requests
  public struct AuthenticationRequest: Codable {
    var blob: String
    var fromBridge: Bool
    var attestationSupported: Bool
    var assertionPayload: AssertionPayload?
    var originalTransactionId: String?
    var isSandbox: Bool
    var consumableType: String?
    var amount: Double?
  }

  public struct GenerationPayload: Codable {
    var blob: String
    var consumableType: String?
    var amount: Double?

    public init(blob: String, consumableType: String?, amount: Double?) {
      self.blob = blob
      self.consumableType = consumableType
      self.amount = amount
    }
  }

  public struct LoRAFileMetadata: Codable {
    public var file: String  // lora file
    public var sha256: String  // file checksum
    public var size: Int64  // file size
    public init(file: String, sha256: String, size: Int64) {
      self.file = file
      self.sha256 = sha256
      self.size = size
    }
  }
}

// This should be an actor in future iteration once we start to allow async / await.
public final class AccountManager {
  public enum Product: String {
    case localCode = "local_code"
    case drawThings = "draw_things"
  }

  // api endpoints
  static let endpoint: URL = URL(string: "https://api.drawthings.ai")!
  private static let signInEndpoint: URL = endpoint.appendingPathComponent("/signin")
  private static let refreshEndpoint: URL = endpoint.appendingPathComponent("/refresh")
  static let authenticateEndpoint: URL = endpoint.appendingPathComponent("/authenticate")
  private static let deleteAccountEndpoint: URL = endpoint.appendingPathComponent(
    "/product_account/delete")
  private static let retrieveSubscriptionStatusEndpoint: URL = endpoint.appendingPathComponent(
    "/retrieve_subscription_status")
  private static let getSignedURLsEndpoint: URL = endpoint.appendingPathComponent(
    "/get_byom_urls")
  private static let deleteFilesEndpoint: URL = endpoint.appendingPathComponent(
    "/delete_uploaded_files")
  let logger = Logger(label: "com.draw-things.account-manager")
  var workspace: Workspace
  public let product: Product
  public let accountValueSubject: CurrentValueSubject<(old: Account?, new: Account?), Never>
  public let balanceValueSubject:
    CurrentValueSubject<(old: LocalConsumableMetadata?, new: LocalConsumableMetadata?), Never>
  public let useBoostIfPossibleValueSubject: CurrentValueSubject<Bool, Never>
  public let sessionExpiredSubject: PassthroughSubject<Void, Never>
  public var account: Account? {
    return accountLock.sync { internalAccount }
  }
  public var consumableMetadata: LocalConsumableMetadata? {
    return consumableMetadataLock.sync { internalConsumableMetadata }
  }
  public var useBoostIfPossible: Bool {
    get { internalUseBoostIfPossible.load(ordering: .acquiring) }
    set {
      internalUseBoostIfPossible.store(newValue, ordering: .releasing)
      useBoostIfPossibleValueSubject.send(newValue)
    }
  }
  private var internalAccount: Account?
  private var internalConsumableMetadata: LocalConsumableMetadata?
  private var internalUseBoostIfPossible: ManagedAtomic<Bool>
  private let accountLock: DispatchQueue  // Protect access to account.
  private let consumableMetadataLock: DispatchQueue  // Protect access to account.
  private var accountSubscription: Workspace.Subscription? = nil
  private var balanceSubscription: Workspace.Subscription? = nil
  private var productStatusSubscription: AnyCancellable? = nil
  private var consumableSubscription: AnyCancellable? = nil

  public init(workspace: Workspace, product: Product = .drawThings) {
    let accounts = workspace.fetch(for: Account.self).where(Account.id == 0, limit: .limit(1))
    let balanceMetadata = workspace.fetch(for: LocalConsumableMetadata.self).where(
      LocalConsumableMetadata.id == 0, limit: .limit(1))
    internalAccount = accounts.first
    internalConsumableMetadata = balanceMetadata.first
    accountLock = DispatchQueue(label: "com.draw-things.account-manager.account")
    consumableMetadataLock = DispatchQueue(
      label: "com.draw-things.account-manager.consumableMetadataLock")
    accountValueSubject = CurrentValueSubject((internalAccount, internalAccount))
    balanceValueSubject = CurrentValueSubject(
      (internalConsumableMetadata, internalConsumableMetadata))
    useBoostIfPossibleValueSubject = CurrentValueSubject(false)
    sessionExpiredSubject = PassthroughSubject()
    internalUseBoostIfPossible = ManagedAtomic(false)
    self.workspace = workspace
    self.product = product
    productStatusSubscription = ProductsManager.shared.$subscriptionStatus.receive(on: accountLock)
      .sink(
        receiveValue: { [weak self] status in
          guard let self = self, let internalAccount = self.internalAccount else { return }
          switch status {
          case .purchased(_, let originalTransactionId):
            // StoreKit confirmed an active local subscription; persist it for account plan resolution.
            self.workspace.performChanges([Account.self]) { transactionContext in
              if let changeRequest = AccountChangeRequest.changeRequest(internalAccount) {
                changeRequest.isSubscribedIap = true
                changeRequest.originalTransactionId = String(originalTransactionId)
                transactionContext.try(submit: changeRequest)
              }
            }
          case .none:
            // StoreKit replay completed with no active local subscription; clear stale IAP state.
            if internalAccount.isSubscribedIap {
              self.workspace.performChanges([Account.self]) { transactionContext in
                if let changeRequest = AccountChangeRequest.changeRequest(internalAccount) {
                  changeRequest.isSubscribedIap = false
                  changeRequest.originalTransactionId = nil
                  transactionContext.try(submit: changeRequest)
                }
              }
            }
          case .unresolved:
            // Launch/configuration has not replayed entitlements yet; keep persisted IAP state.
            break
          case .failed(_), .pending:
            // Purchase-flow states are transient and do not prove an upgrade or downgrade.
            break
          }
        })
    consumableSubscription = ProductsManager.shared.$consumableTransactionUpdate.receive(
      on: consumableMetadataLock
    )
    .sink(
      receiveValue: { [weak self] transaction in
        guard let self = self, let transaction else { return }
        self.recordPurchaseConsumable(
          transaction, hasConsent: internalConsumableMetadata?.hasConsent ?? false,
          completion: nil)
      })
    accountSubscription = workspace.subscribe(fetchedResult: accounts) { [weak self] newAccounts in
      guard let self = self else { return }
      let (oldAccount, newAccount) = self.accountLock.sync {
        let oldAccount = self.internalAccount
        self.internalAccount = newAccounts.first
        return (oldAccount, newAccounts.first)
      }
      if oldAccount != newAccount {
        self.accountValueSubject.send((oldAccount, newAccount))
      }
    }
    balanceSubscription = workspace.subscribe(fetchedResult: balanceMetadata) {
      [weak self] newBalance in
      guard let self = self else { return }
      let (oldBalance, newBalance) = self.consumableMetadataLock.sync {
        let oldBalance = self.internalConsumableMetadata
        self.internalConsumableMetadata = newBalance.first
        return (oldBalance, newBalance.first)
      }
      self.balanceValueSubject.send((oldBalance, newBalance))
    }

    // change plan to community if identity token exist email may not be present for every request
    retrieveOverrideAccount()
  }

  public var isSignedIn: Bool {
    return account != nil
  }
}

extension AccountManager {
  private static let longTermTokenRefreshThreshold: TimeInterval = 60 * 24 * 60 * 60

  private static func unwrapTokenIfValid(_ token: String) -> String? {
    guard let payload = decode(jwtToken: token), let exp = payload["exp"] as? TimeInterval,
      Date().timeIntervalSince1970 < exp
    else {
      return nil
    }
    return token
  }

  @discardableResult
  public func signIn(
    with token: String, userIdentifier: String?,
    completion: @escaping (Result<Account, Error>) -> Void
  ) -> URLSessionDataTask? {
    signIn(
      with: token, userIdentifier: userIdentifier,
      provider: Self.inferredSignInProvider(for: token), completion: completion)
  }

  @discardableResult
  func signIn(
    with token: String, userIdentifier: String?, provider: SignInProvider,
    completion: @escaping (Result<Account, Error>) -> Void
  ) -> URLSessionDataTask? {
    let tokenPayload = Self.decode(jwtToken: token)
    guard let userIdentifierParameter = userIdentifier ?? tokenPayload?["sub"] as? String else {
      completion(.failure(AccountError.message("Invalid sign-in token.")))
      return nil
    }
    var accountBuilder = AccountBuilder(from: Account(id: 0))
    // change plan to community if identity token exist email may not be present for every request
    accountBuilder.isSubscribedIap = false
    logger.info("User ID: \(userIdentifier.debugDescription)")

    var request = URLRequest(url: Self.signInEndpoint)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    // Define the data to send
    struct SignInRequest: Codable {
      var type: String
      var intent: String
      struct Credential: Codable {
        var id: String
        var token: String
      }
      var credentials: Credential
    }
    let signInRequest = SignInRequest(
      type: provider.rawValue,
      intent: product.rawValue,
      credentials: SignInRequest.Credential(
        id: userIdentifierParameter, token: token))

    guard let body = try? JSONEncoder().encode(signInRequest) else {
      completion(.failure(JSONError.encoding))
      return nil
    }
    request.httpBody = body

    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }
      if let error = error {
        completion(.failure(error))
        return
      }
      guard let httpResponse = response as? HTTPURLResponse else {
        completion(.failure(AccountError.network("invalide http response")))
        return
      }
      guard httpResponse.statusCode == 200 else {
        logger.error("Failed with status code: \(httpResponse.statusCode)")
        completion(
          .failure(AccountError.network("failed with status code: \(httpResponse.statusCode)")))
        return
      }
      guard let data = data,
        let registrationResponse = try? JSONDecoder().decode(
          RegistrationResponse.self, from: data)
      else {
        logger.error("no data or invalid data")
        completion(.failure(AccountError.message("invalid response data")))
        return
      }
      logger.info("Verification successful")
      accountBuilder.shortTermToken = registrationResponse.accessToken
      accountBuilder.appleCredentialId = userIdentifierParameter
      let account = accountBuilder.build()
      self.workspace.performChanges([Account.self]) { transactionContext in
        let upsertRequest = AccountChangeRequest.upsertRequest(account)
        transactionContext.try(submit: upsertRequest)
      } completionHandler: { _ in
        completion(.success(account))
      }
      self.longTermToken = registrationResponse.refreshToken
    }
    task.resume()
    return task
  }

  @discardableResult
  public func signIn(
    with appleIDCredential: ASAuthorizationAppleIDCredential,
    completion: @escaping (Result<Account, Error>) -> Void
  ) -> URLSessionDataTask? {  // accessToken refreshToken
    let userIdentifier = appleIDCredential.user
    guard let identityToken = appleIDCredential.identityToken,
      let tokenString = String(data: identityToken, encoding: .utf8)
    else {
      completion(.failure(AccountError.message("Invalid sign-in credentials.")))
      return nil
    }
    return signIn(
      with: tokenString, userIdentifier: userIdentifier, completion: completion)
  }

  private var longTermToken: String? {
    get { workspace.dictionary[Self.longTermTokenKey, String.self] }
    set {
      var workspace = workspace
      workspace.dictionary[Self.longTermTokenKey, String.self] = newValue
    }
  }

  private func expireCurrentUserSession() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.signOut()
      self.sessionExpiredSubject.send(())
    }
  }

  @discardableResult
  public func fetchShortTermToken(completion: @escaping (Result<String, Error>) -> Void)
    -> URLSessionDataTask?
  {
    guard let account = internalAccount else {
      completion(.failure(AccountError.token("no account")))
      return nil
    }
    if let shortTermToken = (account.shortTermToken.flatMap { Self.unwrapTokenIfValid($0) }) {
      // Return this token.
      completion(.success(shortTermToken))
      return nil
    }
    let now = Date().timeIntervalSince1970
    guard let longTermToken = longTermToken,
      let longTermTokenPayload = Self.decode(jwtToken: longTermToken),
      let longTermTokenExpiration = longTermTokenPayload["exp"] as? TimeInterval,
      now < longTermTokenExpiration
    else {
      expireCurrentUserSession()
      completion(.failure(AccountError.token("current user session expired")))
      return nil
    }
    let refreshLongTermToken =
      longTermTokenExpiration - now < Self.longTermTokenRefreshThreshold
    var request = URLRequest(url: Self.refreshEndpoint)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.addValue(longTermToken, forHTTPHeaderField: "Authorization")
    if refreshLongTermToken {
      guard
        let body = try? JSONEncoder().encode(
          RefreshRequest(refreshLongTermToken: true))
      else {
        completion(.failure(JSONError.encoding))
        return nil
      }
      request.httpBody = body
    }

    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }
      if let error = error {
        logger.error("Error: \(error.localizedDescription)")
        completion(.failure(error))
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        completion(.failure(AccountError.network("invalid HTTP response")))
        return
      }
      if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
        self.expireCurrentUserSession()
        completion(.failure(AccountError.token("current user session expired")))
        return
      }
      guard httpResponse.statusCode == 200 else {
        logger.error("Failed with status code: \(httpResponse.statusCode)")
        completion(
          .failure(AccountError.network("failed with status code \(httpResponse.statusCode)")))
        return
      }
      guard let data = data,
        let refreshResponse = try? JSONDecoder().decode(
          RefreshResponse.self, from: data)
      else {
        completion(.failure(JSONError.decoding))
        return
      }
      let shortTermToken = refreshResponse.accessToken
      if let refreshToken = refreshResponse.refreshToken {
        self.longTermToken = refreshToken
      }
      self.workspace.performChanges([Account.self]) { transactionContext in
        guard let changeRequest = AccountChangeRequest.changeRequest(account) else { return }
        changeRequest.shortTermToken = shortTermToken
        transactionContext.try(submit: changeRequest)
      }
      completion(.success(shortTermToken))
    }
    task.resume()
    return task
  }

  // Sync method but with cancellation.
  func authenticate(
    group: DispatchGroup, fromBridge: Bool, blob: GenerationPayload, attestationSupported: Bool,
    assertionPayload: AssertionPayload?, cancellation: (@escaping () -> Void) -> Void
  ) -> Result<String, Error> {
    let originalTransactionId =
      account?.hasPaidPlan == true ? account?.originalTransactionId : nil
    group.enter()
    var shortTermTokenResult: Result<String, Error>? = nil
    let task = fetchShortTermToken { result in
      shortTermTokenResult = result
      group.leave()
    }
    if let task = task {
      cancellation {
        task.cancel()
      }
    }
    group.wait()
    guard let shortTermTokenResult else {
      return .failure(AccountError.token("short term token not available"))
    }
    switch shortTermTokenResult {
    case .failure(let error):
      return .failure(error)
    case .success(let shortTermToken):
      guard let _ = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
        self.logger.error(APIError.userIdMissing.message)
        return .failure(APIError.userIdMissing)
      }
      var request = URLRequest(url: Self.authenticateEndpoint)
      request.httpMethod = "POST"
      request.addValue("application/json", forHTTPHeaderField: "Content-Type")
      request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
      let requestBody = AuthenticationRequest(
        blob: blob.blob, fromBridge: fromBridge,
        attestationSupported: attestationSupported,
        assertionPayload: assertionPayload,
        originalTransactionId: originalTransactionId, isSandbox: false,
        consumableType: blob.consumableType,
        amount: blob.amount)
      guard let body = try? JSONEncoder().encode(requestBody) else {
        logger.error("invalid blob")
        return .failure(JSONError.encoding)
      }
      request.httpBody = body
      return continueAuthenticateRequest(group: group, request: request, cancellation: cancellation)
    }
  }

  func continueAuthenticateRequest(
    group: DispatchGroup, request: URLRequest, cancellation: (@escaping () -> Void) -> Void
  ) -> Result<String, Error> {
    group.enter()
    var result: Result<String, Error>? = nil
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }
      if let error = error {
        self.logger.error("Error: \(error.localizedDescription)")
        result = .failure(error)
        group.leave()
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        result = .failure(AccountError.network("invalid response"))
        group.leave()
        return
      }
      guard httpResponse.statusCode == 200 else {
        self.logger.error("Failed with status code: \(httpResponse.statusCode)")
        result = .failure(
          AccountError.network("failed with status code: \(httpResponse.statusCode)"))
        group.leave()
        return
      }
      guard let data = data,
        let authenticationResponse = try? JSONDecoder().decode(
          AuthenticationResponse.self, from: data)
      else {
        result = .failure(JSONError.decoding)
        group.leave()
        return
      }
      result = .success(authenticationResponse.gRPCToken)
      self.logger.debug(
        "Authentication successful with token: \(authenticationResponse.gRPCToken)")
      group.leave()
    }
    cancellation {
      task.cancel()
    }
    task.resume()
    group.wait()
    return result ?? .failure(AccountError.network("Didn't return the result."))
  }

  private func retrieveAccountPlanStatus(completion: @escaping (Result<PlanType, Error>) -> Void) {
    guard account != nil else {
      completion(.failure(AccountError.token("no account")))
      return
    }
    fetchShortTermToken { [weak self] shortTermTokenResult in
      guard let self else { return }
      switch shortTermTokenResult {
      case .success(let shortTermToken):
        var request = URLRequest(url: Self.retrieveSubscriptionStatusEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
          guard let self else { return }
          if let error = error {
            self.logger.error("Error: \(error.localizedDescription)")
            completion(.failure(error))
            return
          }
          guard let httpResponse = response as? HTTPURLResponse else {
            completion(.failure(AccountError.network("invalid response")))
            return
          }
          guard httpResponse.statusCode == 200 else {
            self.logger.error("Failed with status code: \(httpResponse.statusCode)")
            completion(
              .failure(AccountError.network("failed with status code: \(httpResponse.statusCode)")))
            return
          }
          guard let data = data,
            let overrideAccountResponse = try? JSONDecoder().decode(
              OverrideAccountResponse.self, from: data)
          else {
            completion(.failure(JSONError.decoding))
            return
          }
          completion(.success(overrideAccountResponse.subscriptionStatus.accountPlanType))
        }
        task.resume()
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  public func retrieveOverrideAccount(completion: ((Result<Bool, Error>) -> Void)? = nil) {
    guard account != nil else {
      completion?(.failure(AccountError.token("no account")))
      return
    }
    retrieveAccountPlanStatus { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        completion?(.failure(error))
      case .success(let serverPlan):
        guard let account = self.account else {
          completion?(.success(serverPlan.isPaidPlan))
          return
        }
        let desiredServerSubscriptionPlan: PlanType =
          serverPlan.isPaidPlan ? serverPlan : .community
        let shouldUpdateServerSubscription =
          account.isSubscribedOnServer != serverPlan.isPaidPlan
          || account.serverSubscriptionPlan != desiredServerSubscriptionPlan
        // StoreKit `.none` is the only authoritative signal for clearing stale local IAP.
        let shouldClearLocalSubscription: Bool
        switch ProductsManager.shared.currentPurchaseStatus {
        case .none:
          shouldClearLocalSubscription = !serverPlan.isPaidPlan && account.isSubscribedIap
        case .unresolved, .failed(_), .pending, .purchased(_, _):
          shouldClearLocalSubscription = false
        }
        guard shouldUpdateServerSubscription || shouldClearLocalSubscription else {
          completion?(.success(serverPlan.isPaidPlan))
          return
        }
        self.workspace.performChanges([Account.self]) { transactionContext in
          if let changeRequest = AccountChangeRequest.changeRequest(account) {
            if shouldUpdateServerSubscription {
              changeRequest.isSubscribedOnServer = serverPlan.isPaidPlan
              changeRequest.serverSubscriptionPlan = desiredServerSubscriptionPlan
            }
            if shouldClearLocalSubscription {
              changeRequest.isSubscribedIap = false
              changeRequest.originalTransactionId = nil
            }
            transactionContext.try(submit: changeRequest)
          }
        } completionHandler: { [weak self] _ in
          guard let self else { return }
          self.logger.debug("Account override: \(serverPlan)")
          completion?(.success(serverPlan.isPaidPlan))
        }
      }
    }
  }

  public func signOut() {
    let account = accountLock.sync {
      let account = internalAccount
      internalAccount = nil
      return account
    }
    longTermToken = nil
    guard let account else { return }
    accountValueSubject.send((account, nil))
    workspace.performChanges([Account.self]) { transactionContext in
      // delete the account in the workspace
      guard let deletionRequest = AccountChangeRequest.deletionRequest(account) else { return }
      transactionContext.try(submit: deletionRequest)
    } completionHandler: { [weak self] success in
      if !success {
        self?.logger.error("Could not persist account cleanup; the user remains signed out.")
      }
    }
  }

  public func deleteAccount() {
    fetchShortTermToken { [weak self] shortTermTokenResult in
      guard let self else { return }
      switch shortTermTokenResult {
      case .failure(let error):
        self.logger.error("Error: \(error.localizedDescription)")
      case .success(let shortTermToken):
        var request = URLRequest(url: Self.deleteAccountEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(["product": self.product.rawValue])
        let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
          guard let self else { return }
          if let error = error {
            self.logger.error("Error: \(error.localizedDescription)")
            return
          }

          guard let httpResponse = response as? HTTPURLResponse else {
            return
          }
          guard httpResponse.statusCode == 200 else {
            self.logger.error("Failed with status code: \(httpResponse.statusCode)")
            return
          }
          DispatchQueue.main.async {
            self.signOut()
          }
        }
        task.resume()
      }
    }
  }

  public func getSignedURLs(
    LoRAs: [LoRAFileMetadata],
    completion: @escaping (Result<GetSignedURLResponse.DataPayload, Error>) -> Void
  ) {
    let originalTransactionId =
      account?.hasPaidPlan == true ? account?.originalTransactionId : nil
    fetchShortTermToken { [weak self] shortTermTokenResult in
      guard let self else { return }
      switch shortTermTokenResult {
      case .success(let shortTermToken):
        var request = URLRequest(url: Self.getSignedURLsEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        struct GetSignedURLRequest: Codable {
          var files: [LoRAFileMetadata]
          var clientImposedLimit: Int?
          var originalTransactionId: String?
          var isSandbox: Bool = false
        }
        let getSignedURLs = GetSignedURLRequest(
          files: LoRAs, originalTransactionId: originalTransactionId)
        self.logger.info("get upload url parameters: \(getSignedURLs)")
        guard let jsonData = try? JSONEncoder().encode(getSignedURLs) else {
          completion(.failure(JSONError.encoding))
          return
        }
        request.httpBody = jsonData
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
          guard let self else { return }
          if let error = error {
            self.logger.error("Error: \(error.localizedDescription)")
            completion(.failure(error))
            return
          }
          guard let httpResponse = response as? HTTPURLResponse else {
            completion(.failure(AccountError.network("Network failure")))
            return
          }
          guard httpResponse.statusCode == 200 else {
            self.logger.error("Failed with status code: \(httpResponse.statusCode)")
            if httpResponse.statusCode == 403 {
              completion(.failure(AccountError.subscriptionVerificationFailed))
              return
            }
            completion(
              .failure(AccountError.network("Failed with status code: \(httpResponse.statusCode)")))
            return
          }
          guard let data = data,
            let getSignedURLResponse = try? JSONDecoder().decode(
              GetSignedURLResponse.self, from: data)
          else {
            self.logger.error("Upload URLs result not decoded properly")
            completion(.failure(JSONError.decoding))
            return
          }
          completion(.success(getSignedURLResponse.data.dataPayload))
        }
        task.resume()
      default:
        return
      }
    }
  }

  public func deleteFiles(
    fileKeys: [String], completion: @escaping (Result<(), Error>) -> Void
  ) {
    fetchShortTermToken { [weak self] shortTermTokenResult in
      guard let self else { return }
      switch shortTermTokenResult {
      case .success(let shortTermToken):
        var request = URLRequest(url: Self.deleteFilesEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(shortTermToken, forHTTPHeaderField: "Authorization")
        struct DeleteFilesRequest: Codable {
          var keys: [String]
        }
        let deleteFilesRequest = DeleteFilesRequest(keys: fileKeys)
        self.logger.info("get upload url parameters: \(deleteFilesRequest)")
        guard let jsonData = try? JSONEncoder().encode(deleteFilesRequest) else {
          completion(.failure(JSONError.encoding))
          return
        }
        request.httpBody = jsonData
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
          guard let self else { return }
          if let error = error {
            self.logger.error("Error: \(error.localizedDescription)")
            completion(.failure(error))
            return
          }
          guard let httpResponse = response as? HTTPURLResponse else {
            completion(.failure(AccountError.network("Network failure")))
            return
          }
          guard httpResponse.statusCode == 200 else {
            self.logger.error("Failed with status code: \(httpResponse.statusCode)")
            completion(
              .failure(AccountError.network("Failed with status code: \(httpResponse.statusCode)")))
            return
          }
          completion(.success(()))
        }
        task.resume()
      default:
        return
      }
    }
  }
}

extension AccountManager {
  static let longTermTokenKey: String = "LONG_TERM_ACCCESS_TOKEN_DRAW_THINGS"

  public static func generateStableUUID(from string: String, namespace: UUID = .dns) -> UUID {
    // 1. Get the bytes of the namespace and the input string.
    let namespaceBytes = uuid_t(namespace.uuid)
    guard let stringData = string.data(using: .utf8) else {
      // This should realistically never fail for valid IDs.
      fatalError("Could not convert string to UTF-8 data.")
    }

    // 2. Concatenate the namespace and string data.
    var combinedData = Data(bytes: [namespaceBytes], count: 16)
    combinedData.append(stringData)

    // 3. Compute the SHA-1 hash.
    let hash = Insecure.SHA1.hash(data: combinedData)

    // 4. Convert the hash digest to an array of bytes.
    var hashBytes = [UInt8]()
    hash.withUnsafeBytes { ptr in
      hashBytes = Array(ptr)
    }

    // 5. Set the UUID version bits (to 5).
    hashBytes[6] = (hashBytes[6] & 0x0F) | 0x50

    // 6. Set the UUID variant bits (to "10x").
    hashBytes[8] = (hashBytes[8] & 0x3F) | 0x80

    // 7. Create the UUID from the first 16 bytes of the modified hash.
    let uuidTuple = (
      hashBytes[0], hashBytes[1], hashBytes[2], hashBytes[3],
      hashBytes[4], hashBytes[5], hashBytes[6], hashBytes[7],
      hashBytes[8], hashBytes[9], hashBytes[10], hashBytes[11],
      hashBytes[12], hashBytes[13], hashBytes[14], hashBytes[15]
    )
    return UUID(uuid: uuidTuple)
  }

  static func decode(jwtToken jwt: String) -> [String: Any]? {
    // Split the JWT into its components
    let segments = jwt.components(separatedBy: ".")
    guard segments.count > 1 else { return nil }

    // Decode the payload
    let payloadSegment = segments[1]
    guard let payloadData = base64UrlDecode(payloadSegment) else { return nil }

    // Convert payload data to JSON dictionary
    let json = try? JSONSerialization.jsonObject(with: payloadData, options: [])
    return json as? [String: Any]
  }

  private static func base64UrlDecode(_ base64Url: String) -> Data? {
    var base64 =
      base64Url
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")

    // Add padding if necessary
    while base64.count % 4 != 0 {
      base64 += "="
    }

    return Data(base64Encoded: base64)
  }
}

extension AccountManager.OverrideAccountResponse.PlanType {
  fileprivate var accountPlanType: UserAccount.PlanType {
    switch self {
    case .max:
      return .maxEdition
    case .plus:
      return .plus
    case .free, .community:
      return .community
    }
  }
}

extension PlanType {
  fileprivate var isPaidPlan: Bool {
    switch self {
    case .plus, .maxEdition:
      return true
    case .free, .community:
      return false
    }
  }

  fileprivate var tierRank: Int {
    switch self {
    case .free, .community:
      return 0
    case .plus:
      return 1
    case .maxEdition:
      return 2
    }
  }
}

extension Account {
  // Returns the best plan from StoreKit and the server.
  // If StoreKit has not resolved yet, keep the saved local IAP state.
  // Before 2026-06-08, server-paid accounts did not save a plan type, so treat them as Plus.
  static func resolvedPlan(
    localPurchaseStatus: ProductsManager.PurchaseStatus, isSubscribedIap: Bool,
    serverSubscriptionPlan: PlanType, isSubscribedOnServer: Bool
  ) -> PlanType {
    let localPlan: PlanType
    switch localPurchaseStatus {
    case .purchased(let subscriptionIdentifier, _):
      switch subscriptionIdentifier {
      case ProductsManager.maxSubscriptionIdentifier:
        localPlan = .maxEdition
      case ProductsManager.plusSubscriptionIdentifier:
        localPlan = .plus
      default:
        localPlan = .community
      }
    case .unresolved, .failed(_), .pending:
      localPlan = isSubscribedIap ? .plus : .community
    case .none:
      localPlan = .community
    }
    let effectiveServerPlan: PlanType
    switch serverSubscriptionPlan {
    case .maxEdition:
      effectiveServerPlan = .maxEdition
    case .plus:
      effectiveServerPlan = .plus
    case .community:
      effectiveServerPlan = .community
    case .free:
      effectiveServerPlan = isSubscribedOnServer ? .plus : .community
    }
    return localPlan.tierRank >= effectiveServerPlan.tierRank ? localPlan : effectiveServerPlan
  }

  public var hasPaidPlan: Bool {
    switch planWithOverride {
    case .plus, .maxEdition:
      true
    default:
      false
    }
  }

  public var planWithOverride: PlanType {
    Self.resolvedPlan(
      localPurchaseStatus: ProductsManager.shared.currentPurchaseStatus,
      isSubscribedIap: isSubscribedIap,
      serverSubscriptionPlan: serverSubscriptionPlan, isSubscribedOnServer: isSubscribedOnServer)
  }
}

extension AccountManager {
  #if DIRECT_DISTRIBUTION
    private func startStripeSubscriptionPurchase(
      sku: StripeSubscriptionSKU, completion: @escaping () -> Void
    ) {
      createStripeSubscriptionPurchaseURL(sku: sku) { [weak self] result in
        switch result {
        case .failure(let error):
          self?.logger.error("\(error.localizedDescription)")
        case .success(let purchaseURL):
          #if canImport(UIKit)
            DispatchQueue.main.async {
              UIApplication.shared.open(purchaseURL, options: [:], completionHandler: nil)
            }
          #else
            self?.logger.error("Stripe purchase URL cannot be opened without UIKit")
          #endif
        }
        completion()
      }
    }
  #endif

  public func purchasePlus(completion: @escaping () -> Void) {
    fetchShortTermToken { [weak self] result in
      guard let self else {
        completion()
        return
      }
      switch result {
      case .success(let shortTermToken):
        guard let id = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
          self.logger.error(APIError.userIdMissing.message)
          completion()
          return
        }
        ProductsManager.shared.purchasePlus(
          appAccountToken: Self.generateStableUUID(from: id),
          completionHandler: completion)
      case .failure(let error):
        self.logger.error("\(error.localizedDescription)")
        completion()
      }
    }
  }

  public func purchaseMax(completion: @escaping () -> Void) {
    fetchShortTermToken { [weak self] result in
      guard let self else {
        completion()
        return
      }
      switch result {
      case .success(let shortTermToken):
        guard let id = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
          self.logger.error(APIError.userIdMissing.message)
          completion()
          return
        }
        ProductsManager.shared.purchaseMax(
          appAccountToken: Self.generateStableUUID(from: id),
          completionHandler: completion)
      case .failure(let error):
        self.logger.error("\(error.localizedDescription)")
        completion()
      }
    }
  }

  public func recordConsent() {
    workspace.performChanges([LocalConsumableMetadata.self]) { transactionContext in
      if let changeRequest = LocalConsumableMetadataChangeRequest.changeRequest(
        LocalConsumableMetadata(id: 0))
      {
        changeRequest.hasConsent = true
        transactionContext.try(submit: changeRequest)
      } else {
        let creationRequest = LocalConsumableMetadataChangeRequest.creationRequest()
        creationRequest.id = 0
        creationRequest.hasConsent = true
        transactionContext.try(submit: creationRequest)
      }
    }
  }

  func updateBalance(_ metadata: ConsumableMetadata) {
    let boostBalance = metadata.balance[UsageAction.CurrencyType.boost.rawValue]?
      .consumableBalance
    let cashBalance = metadata.balance[UsageAction.CurrencyType.dollar.rawValue]?
      .consumableBalance
    workspace.performChanges([LocalConsumableMetadata.self]) { transactionContext in
      if let changeRequest = LocalConsumableMetadataChangeRequest.changeRequest(
        LocalConsumableMetadata(id: 0))
      {
        changeRequest.boostBalance = boostBalance
        changeRequest.cashBalance = cashBalance
        transactionContext.try(submit: changeRequest)
      } else {
        let creationRequest = LocalConsumableMetadataChangeRequest.creationRequest()
        creationRequest.id = 0
        creationRequest.boostBalance = boostBalance
        creationRequest.cashBalance = cashBalance
        transactionContext.try(submit: creationRequest)
      }
    }
  }

  public func restorePurchases() {
    ProductsManager.shared.restorePurchases { [weak self] sub, originalTransactionId in
      guard let self else { return }
      //      self.fetchShortTermToken { [weak self] shortTermTokenResult in
      //        guard let self else { return }
      //        switch shortTermTokenResult {
      //        case .success(let shortTermToken):
      //          guard let id = Self.decode(jwtToken: shortTermToken)?["id"] as? String else {
      //            self.logger.error(APIError.userIdMissing.message)
      //            return
      //          }
      //          let body = RestorePurchaseRequestBody(
      //            appAccountToken: Self.generateStableUUID(from: id).uuidString.lowercased(),
      //            originalTransactionId: originalTransactionId, isSandbox: true)
      //          let encoder = JSONEncoder()
      //          guard let jsonData = try? encoder.encode(body) else {
      //            self.logger.log(level: .error, "encoding error")
      //            return
      //          }
      //
      //          var request = URLRequest(url: Self.restorePurchaseEndpoint)
      //          request.httpMethod = "POST"
      //          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      //          request.addValue(shortTermToken, forHTTPHeaderField: "authorization")
      //          request.httpBody = jsonData
      //
      //          let task = URLSession.shared.dataTask(with: request) { data, response, error in
      //            if let error = error {
      //              self.logger.log(level: .error, "\(error.localizedDescription)")
      //              return
      //            }
      //            guard let http = response as? HTTPURLResponse else {
      //              self.logger.log(level: .error, "bad response")
      //              return
      //            }
      //            guard (200...299).contains(http.statusCode), let data = data else {
      //              self.logger.log(level: .error, "bad response \(http.statusCode)")
      //              return
      //            }
      //
      //            let decoder = JSONDecoder()
      //            do {
      //              let metadata = try decoder.decode(ConsumableMetadata.self, from: data)
      //              //            self.workspace.performChanges([LocalConsumptionMetadata.self]) { transactionContext in
      //              //              if let changeRequest = AccountChangeRequest.changeRequest(account) {
      //              //                changeRequest.isSubscribedOnServer = true
      //              //                transactionContext.try(submit: changeRequest)
      //              //              }
      //              //            } completionHandler: { [weak self] _ in
      //              //              guard let self else { return }
      //              //              self.logger.debug(
      //              //                "Account override: \(String(describing: overrideAccountResponse.subscriptionStatus))"
      //              //              )
      //              //            }
      //
      //              //            completion(.success(metadata))
      //            } catch {
      //              self.logger.log(level: .error, "response decoding error")
      //            }
      //          }
      //          task.resume()
      //        default:
      //          return
      //        }
      //      }
    }
  }
}

extension UUID {
  // https://www.iana.org/assignments/uuid/uuid.xhtml
  public static let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
  public static let url = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!
  public static let oid = UUID(uuidString: "6ba7b812-9dad-11d1-80b4-00c04fd430c8")!
  public static let x500 = UUID(uuidString: "6ba7b814-9dad-11d1-80b4-00c04fd430c8")!
}
