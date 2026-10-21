import AuthenticationServices
import CLICloudAuth
import Combine
import Localization
import RemoteAPI
import SQLiteDflat
import Security
import StoreKit
import UIKit
import UserAccount

protocol AccountWorkflowDelegate: AnyObject {
  func accountWorkflowDidDismiss(_ workflow: AccountWorkflow)
  func accountWorkflowDidUpdateHostedProvider(_ workflow: AccountWorkflow)
  func accountWorkflowDidUpdateAccount(_ workflow: AccountWorkflow)
}

final class AccountWorkflow: Workflow {
  struct TopUpResult {
    let didPurchase: Bool
    let continueGeneration: Bool
  }

  private enum ImageGenError: Error, LocalizedError {
    case signInRequired

    var errorDescription: String? {
      switch self {
      case .signInRequired:
        return "Sign in to Local Code before using ImageGen Cloud Compute."
      }
    }
  }

  /// A command-scoped presentation adapter, not an owner of account state.
  private final class ToolAccount: ToolAccountProvider {
    weak var workflow: AccountWorkflow?
    weak var presenter: UIViewController?

    init(workflow: AccountWorkflow, presenter: UIViewController) {
      self.workflow = workflow
      self.presenter = presenter
    }

    func resolveDrawThingsCredential(
      prepareIfNeeded: Bool, completion: @escaping (Result<String?, Error>) -> Void
    ) {
      DispatchQueue.main.async { [weak workflow, weak presenter] in
        guard let workflow, let presenter else {
          completion(.success(nil))
          return
        }
        let apiKey = workflow.savedAPIKey
        guard prepareIfNeeded, apiKey == nil else {
          completion(.success(apiKey))
          return
        }
        workflow.prepareImageGenCloudCompute(from: presenter, sourceView: presenter.view) {
          result in completion(result.map { Optional($0) })
        }
      }
    }
  }

  private struct WebSignInAttempt {
    let provider: AccountManager.SignInProvider
    let nonce: String
  }

  final class ObjCResponder: NSObject {
    weak var workflow: AccountWorkflow?
  }

  final class TransitioningController: NSObject {
    private let sourceView: UIView
    private let placement: AccountAnimatedTransitioning.Placement
    weak var delegate: AccountWorkflow?

    init(sourceView: UIView, placement: AccountAnimatedTransitioning.Placement) {
      self.sourceView = sourceView
      self.placement = placement
    }
  }

  weak var delegate: AccountWorkflowDelegate?
  let viewController = AccountViewController()
  var viewControllable: UIViewController { viewController }

  private let workspace: SQLiteWorkspace
  private let accountManager: AccountManager
  private let client: AccountClient?
  private let objCResponder = ObjCResponder()
  private var transitioningController: TransitioningController?
  private var accountSubscription: AnyCancellable?
  private var localCodeCreditTransactionSubscription: AnyCancellable?
  private var purchaseTask: URLSessionDataTask?
  private var balanceRevision = 0
  private weak var topUpViewController: TopUpViewController?
  private var topUpCompletion: ((TopUpResult) -> Void)?
  private var topUpDidPurchase = false
  private var topUpPurchaseID: UInt64?
  private var purchaseGeneration = 0
  private var activePurchaseID: UInt64?
  private var attemptedPurchaseIDs = Set<UInt64>()
  private var task: URLSessionDataTask?
  // Credential provisioning must not be cancelled by account/balance refreshes.
  private var webAuthenticationSession: ASWebAuthenticationSession?
  private var webSignInAttempt: WebSignInAttempt?
  private var isSignInOnly = false
  private var snapshot: AccountClient.CreditSnapshot?
  private var errorMessage: String?
  private var isBusy = false
  private var operationGeneration = 0
  private var pendingImageGenCloudComputeCompletion: ((Result<String, Error>) -> Void)?

  var isSignedIn: Bool { accountManager.isSignedIn }

  var balance: String? {
    guard isSignedIn else { return nil }
    return snapshot.map { AccountViewController.credit($0.balanceMicroUsd) }
      ?? LocalizedString.forKey("credit_unavailable")
  }

  /// The account's LocalCode key. It authorizes hosted models and, through draw-things-cli,
  /// cloud compute billed to the same balance.
  private var savedAPIKey: String? {
    guard isSignedIn, let client,
      let credential = try? RemoteCredentialStore.readCredential(
        account: client.openAICompatibleBaseURL.absoluteString, provider: .localCode),
      case .apiKey(let key) = credential.value, key.hasPrefix("dk_")
    else { return nil }
    return key
  }

  init(
    workspace: SQLiteWorkspace,
    accountManager: AccountManager,
    client: AccountClient?
  ) {
    self.workspace = workspace
    self.accountManager = accountManager
    self.client = client
    viewController.modalPresentationStyle = .custom
    #if targetEnvironment(macCatalyst)
      viewController.preferredContentSize = CGSize(width: 295, height: 280)
    #else
      viewController.preferredContentSize = CGSize(width: 255, height: 280)
    #endif
    viewController.delegate = self
    objCResponder.workflow = self
    accountSubscription = accountManager.accountValueSubject.receive(on: DispatchQueue.main).sink {
      [weak self] (oldAccount, newAccount) in
      guard let self else { return }
      if newAccount == nil
        || (oldAccount != nil && oldAccount?.appleCredentialId != newAccount?.appleCredentialId)
      {
        self.task?.cancel()
        self.purchaseTask?.cancel()
        self.purchaseGeneration &+= 1
        self.activePurchaseID = nil
        self.attemptedPurchaseIDs.removeAll()
        self.topUpViewController?.dismiss(animated: true)
        self.topUpViewController = nil
        self.topUpCompletion = nil
        self.topUpDidPurchase = false
        self.topUpPurchaseID = nil
        self.workspace.dictionary["localcode_consumption_consent", Bool.self] = nil
        self.webAuthenticationSession?.cancel()
        self.webAuthenticationSession = nil
        self.webSignInAttempt = nil
        self.operationGeneration &+= 1
        self.deleteSavedCredential()
        // Earlier versions saved keys under the workers.dev router URL, including a separate
        // ImageGen key; remove them with the account key.
        let workersDevURL = URL(string: "https://local-code-router.i6629.workers.dev")!
        for path in ["v1/openrouter", "v1/imagegen"] {
          try? RemoteCredentialStore.delete(
            account: workersDevURL.appendingPathComponent(path).absoluteString,
            provider: .localCode)
        }
        // Keep the model preference across sign-out; the next catalog refresh validates it.
        self.workspace.dictionary["localcode_models", [String].self] = nil
        self.snapshot = nil
        self.errorMessage = nil
        self.isBusy = false
        self.updateView()
        self.delegate?.accountWorkflowDidUpdateHostedProvider(self)
        if newAccount != nil { self.refreshAccount(showBusy: false) }
      } else if !self.isBusy {
        // CurrentValueSubject delivers the persisted account on subscription, so this refreshes
        // the hosted-model cache at app startup without hiding the cached account state.
        self.updateView()
        self.refreshAccount(showBusy: false)
      }
    }
    localCodeCreditTransactionSubscription = ProductsManager.shared
      .localCodeTransactions.receive(on: DispatchQueue.main).sink { [weak self] _ in
        self?.deliverPendingPurchases()
      }
    updateView()
  }

  func present(
    from presentingViewController: UIViewController, sourceView: UIView,
    placement: AccountAnimatedTransitioning.Placement = .trailing, isSignInOnly: Bool = false,
    signInProvider: AccountManager.SignInProvider? = nil
  ) {
    guard viewController.presentingViewController == nil else { return }
    self.isSignInOnly = isSignInOnly
    viewController.loadViewIfNeeded()
    if accountManager.isSignedIn, !isBusy {
      refreshAccount(showBusy: false)
    }
    let transitioningController = TransitioningController(
      sourceView: sourceView, placement: placement)
    transitioningController.delegate = self
    self.transitioningController = transitioningController
    viewController.transitioningDelegate = transitioningController
    presentingViewController.present(viewController, animated: true) { [weak self] in
      guard let self else { return }
      self.viewController.presentationController?.delegate = self.objCResponder
      if let signInProvider, !self.accountManager.isSignedIn {
        self.accountViewController(self.viewController, didRequestSignIn: signInProvider)
      }
    }
  }

  func toolAccountProvider(from presenter: UIViewController) -> ToolAccountProvider {
    ToolAccount(workflow: self, presenter: presenter)
  }

  /// Signs in or provisions the account key from the account panel, then completes with it.
  private func prepareImageGenCloudCompute(
    from presentingViewController: UIViewController,
    sourceView: UIView,
    completion: @escaping (Result<String, Error>) -> Void
  ) {
    guard client != nil else {
      completion(
        .failure(
          AccountManager.AccountError.message(
            "The LocalCode Router URL is not configured.")))
      return
    }
    if let pendingCompletion = pendingImageGenCloudComputeCompletion {
      pendingCompletion(.failure(ImageGenError.signInRequired))
    }
    pendingImageGenCloudComputeCompletion = completion
    present(from: presentingViewController, sourceView: sourceView)
  }

  func handle(url: URL) -> Bool {
    handle(url: url, fromWebAuthenticationSession: false)
  }

  func presentTopUp(
    from presentingViewController: UIViewController, completion: ((TopUpResult) -> Void)? = nil
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isSignedIn, client != nil, topUpViewController == nil,
      presentingViewController.viewIfLoaded?.window != nil
    else { return }
    var presenter = presentingViewController
    while let presented = presenter.presentedViewController { presenter = presented }
    let storeProducts = Dictionary(
      uniqueKeysWithValues: ProductsManager.shared.localCodeCreditProducts.map { ($0.id, $0) })
    let products = ProductsManager.localCodeCredits.map { product in
      TopUpViewController.Product(
        id: product.id, amount: AccountViewController.credit(product.microUsd),
        displayPrice: storeProducts[product.id]?.displayPrice)
    }
    let topUpViewController = TopUpViewController(
      balance: balance ?? "—", products: products,
      hasConsent: workspace.dictionary["localcode_consumption_consent", Bool.self] ?? false,
      showsContinueGeneration: completion != nil)
    topUpCompletion = completion
    topUpDidPurchase = false
    topUpPurchaseID = nil
    topUpViewController.delegate = self
    topUpViewController.modalPresentationStyle = .formSheet
    self.topUpViewController = topUpViewController
    presenter.present(topUpViewController, animated: true)
    topUpViewController.presentationController?.delegate = objCResponder
    attemptedPurchaseIDs.removeAll()
    deliverPendingPurchases()
    refreshBalance()
  }

  private func handle(url: URL, fromWebAuthenticationSession: Bool) -> Bool {
    let scheme = url.scheme?.lowercased()
    let path = url.path.lowercased()
    let provider: AccountManager.SignInProvider
    if scheme == "localcode" && path == "/signin/google" {
      provider = .google
    } else if scheme == "localcode" && path == "/signin/apple" {
      provider = .apple
    } else {
      return false
    }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let callbackNonces = components?.queryItems?.filter { $0.name == "nonce" } ?? []
    guard let attempt = webSignInAttempt, attempt.provider == provider,
      callbackNonces.count == 1, let callbackNonce = callbackNonces[0].value,
      callbackNonce == attempt.nonce
    else {
      if fromWebAuthenticationSession {
        webSignInAttempt = nil
        webAuthenticationSession = nil
        finishWithError(
          AccountManager.AccountError.message(
            LocalizedString.forKey("sign_in_callback_mismatch")))
      }
      return true
    }
    webSignInAttempt = nil
    webAuthenticationSession?.cancel()
    webAuthenticationSession = nil
    if let error = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
      ?? components?.queryItems?.first(where: { $0.name == "error" })?.value
    {
      finishWithError(AccountManager.AccountError.message(error))
      return true
    }
    guard let token = components?.queryItems?.first(where: { $0.name == "token" })?.value,
      !token.isEmpty
    else {
      let providerName = provider == .google ? "Google" : "Apple"
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.format(key: "sign_in_no_token", providerName)))
      return true
    }
    beginBusy(
      LocalizedString.format(key: "finishing_sign_in", provider == .google ? "Google" : "Apple"))
    let generation = operationGeneration
    let completion: (Result<Account, Error>) -> Void = { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.operationGeneration == generation else { return }
        switch result {
        case .success:
          self.provisionCredential()
        case .failure(let error):
          self.finishWithError(error)
        }
      }
    }
    if provider == .google {
      task = accountManager.signIn(withGoogleIdentityToken: token, completion: completion)
    } else {
      task = accountManager.signIn(with: token, userIdentifier: nil, completion: completion)
    }
    return true
  }

  private func refreshAccount(showBusy: Bool = true) {
    guard accountManager.isSignedIn else {
      isBusy = false
      updateView()
      return
    }
    if showBusy {
      beginBusy(LocalizedString.forKey("refreshing_cloud_compute"))
    } else {
      task?.cancel()
      operationGeneration &+= 1
      errorMessage = nil
      isBusy = true
    }
    guard let client else {
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.forKey("local_code_router_url_not_configured")))
      return
    }
    do {
      let credential = try RemoteCredentialStore.readCredential(
        account: client.openAICompatibleBaseURL.absoluteString, provider: .localCode)
      if case .apiKey(let apiKey) = credential?.value {
        loadSnapshot(apiKey: apiKey, canReprovision: true, refreshModels: true)
      } else {
        provisionCredential()
      }
    } catch RemoteCredentialStore.KeychainError.invalidData {
      reprovisionCredential()
    } catch {
      finishWithError(error)
    }
  }

  private func provisionCredential() {
    guard let client else {
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.forKey("local_code_router_url_not_configured")))
      return
    }
    let generation = operationGeneration
    task = accountManager.fetchShortTermToken { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.operationGeneration == generation else { return }
        switch result {
        case .failure(let error):
          self.finishWithError(error)
        case .success(let accessToken):
          self.task = client.provisionDefaultAPIKey(accessToken: accessToken) {
            [weak self] result in
            DispatchQueue.main.async {
              guard let self, self.operationGeneration == generation else { return }
              switch result {
              case .failure(let error):
                self.finishWithError(error)
              case .success(let apiKey):
                self.persistCredentialAndLoadAccount(apiKey: apiKey)
              }
            }
          }
        }
      }
    }
  }

  private func persistCredentialAndLoadAccount(apiKey: String) {
    guard let client else { return }
    do {
      try RemoteCredentialStore.upsertAPIKey(
        apiKey, account: client.openAICompatibleBaseURL.absoluteString, provider: .localCode)
    } catch {
      finishWithError(error)
      return
    }
    loadSnapshot(apiKey: apiKey, canReprovision: false, refreshModels: true)
    resumePendingImageGenCloudCompute()
  }

  private func loadHostedModels(apiKey: String, canReprovision: Bool) {
    guard let client else { return }
    let generation = operationGeneration
    task = client.fetchHostedModels(apiKey: apiKey) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.operationGeneration == generation else { return }
        switch result {
        case .failure(let error):
          if canReprovision && self.shouldReprovision(after: error) {
            self.reprovisionCredential()
            return
          }
          self.finishWithError(error)
        case .success(let models):
          var seenModelIDs = Set<String>()
          var modelNames = [String: String]()
          let modelIDs = models.compactMap { model -> String? in
            let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seenModelIDs.insert(modelID).inserted else { return nil }
            if let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            {
              modelNames[modelID] = name
            }
            return modelID
          }
          self.workspace.dictionary["localcode_model_names", [String: String].self] = modelNames
          self.workspace.dictionary["localcode_models", [String].self] = modelIDs
          guard let firstModel = modelIDs.first else {
            self.workspace.dictionary["localcode_model", String.self] = nil
            self.delegate?.accountWorkflowDidUpdateHostedProvider(self)
            self.finishWithError(
              AccountManager.AccountError.message(
                LocalizedString.forKey("no_cloud_compute_models_enabled")))
            return
          }
          let currentModel = self.workspace.dictionary["localcode_model", String.self]
          if currentModel.map({ !modelIDs.contains($0) }) ?? true {
            self.workspace.dictionary["localcode_model", String.self] = firstModel
          }
          self.delegate?.accountWorkflowDidUpdateHostedProvider(self)
          self.isBusy = false
          self.updateView()
        }
      }
    }
  }

  func refreshBalance() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard isSignedIn, !isBusy, let client,
      let credential = try? RemoteCredentialStore.readCredential(
        account: client.openAICompatibleBaseURL.absoluteString, provider: .localCode),
      case .apiKey(let apiKey) = credential.value
    else { return }
    task?.cancel()
    operationGeneration &+= 1
    loadSnapshot(apiKey: apiKey, canReprovision: false)
  }

  private func loadSnapshot(apiKey: String, canReprovision: Bool, refreshModels: Bool = false) {
    guard let client else { return }
    let generation = operationGeneration
    let balanceRevision = self.balanceRevision
    task = client.fetchCreditSnapshot(apiKey: apiKey) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.operationGeneration == generation else { return }
        switch result {
        case .success(let snapshot):
          self.isBusy = false
          // A refresh begun before purchase delivery must not overwrite the credited balance.
          if self.balanceRevision == balanceRevision { self.snapshot = snapshot }
          self.errorMessage = nil
          self.attemptedPurchaseIDs.removeAll()
          self.deliverPendingPurchases()
        case .failure(let error):
          if canReprovision && self.shouldReprovision(after: error) {
            self.reprovisionCredential()
            return
          }
          self.finishWithError(error)
          return
        }
        self.updateView()
        // Balance and unfinished purchases must not depend on OpenRouter's
        // model catalog being available. Refresh the catalog afterwards.
        if refreshModels {
          self.loadHostedModels(apiKey: apiKey, canReprovision: canReprovision)
        }
      }
    }
  }

  private func shouldReprovision(after error: Error) -> Bool {
    guard let error = error as? AccountClient.ClientError,
      case .httpStatus(let status, _) = error
    else { return false }
    return status == 401 || status == 403
  }

  private func reprovisionCredential() {
    deleteSavedCredential()
    provisionCredential()
  }

  private func deleteSavedCredential() {
    if let client {
      try? RemoteCredentialStore.delete(
        account: client.openAICompatibleBaseURL.absoluteString, provider: .localCode)
    }
  }

  private func beginBusy(_ message: String) {
    task?.cancel()
    operationGeneration &+= 1
    errorMessage = nil
    isBusy = true
    viewController.state = .busy(message: message)
  }

  private func resumePendingImageGenCloudCompute() {
    guard let completion = pendingImageGenCloudComputeCompletion, let apiKey = savedAPIKey else {
      return
    }
    pendingImageGenCloudComputeCompletion = nil
    if viewController.presentingViewController != nil {
      viewController.dismiss(animated: true) {
        self.didDismiss()
        completion(.success(apiKey))
      }
    } else {
      completion(.success(apiKey))
    }
  }

  private func startWebSignIn(
    at url: URL, provider: AccountManager.SignInProvider
  ) {
    guard webAuthenticationSession == nil else { return }
    webSignInAttempt = nil
    let providerName = provider == .apple ? "Apple" : "Google"
    var nonceBytes = [UInt8](repeating: 0, count: 32)
    guard
      SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess
    else {
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.format(key: "could_not_securely_start_sign_in", providerName)))
      return
    }
    let nonce = nonceBytes.map { String(format: "%02x", $0) }.joined()
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.format(key: "could_not_open_sign_in", providerName)))
      return
    }
    components.queryItems =
      (components.queryItems ?? []).filter { $0.name != "nonce" }
      + [URLQueryItem(name: "nonce", value: nonce)]
    guard let signInURL = components.url else {
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.format(key: "could_not_open_sign_in", providerName)))
      return
    }
    webSignInAttempt = WebSignInAttempt(provider: provider, nonce: nonce)
    let session = ASWebAuthenticationSession(url: signInURL, callbackURLScheme: "localcode") {
      [weak self] callbackURL, error in
      DispatchQueue.main.async {
        guard let self, self.webSignInAttempt?.nonce == nonce else { return }
        self.webAuthenticationSession = nil
        if let callbackURL {
          if !self.handle(url: callbackURL, fromWebAuthenticationSession: true) {
            self.webSignInAttempt = nil
            self.finishWithError(
              AccountManager.AccountError.message(
                LocalizedString.format(key: "sign_in_invalid_callback", providerName)))
          }
          return
        }
        self.webSignInAttempt = nil
        if let authenticationError = error as? ASWebAuthenticationSessionError,
          authenticationError.code == .canceledLogin
        {
          self.isBusy = false
          self.updateView()
          return
        }
        self.finishWithError(
          error
            ?? AccountManager.AccountError.message(
              LocalizedString.format(key: "could_not_complete_sign_in", providerName)))
      }
    }
    session.presentationContextProvider = objCResponder
    webAuthenticationSession = session
    guard session.start() else {
      webAuthenticationSession = nil
      webSignInAttempt = nil
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.format(key: "could_not_open_sign_in", providerName)))
      return
    }
  }

  private func finishWithError(_ error: Error) {
    isBusy = false
    errorMessage = error.localizedDescription
    updateView()
  }

  private func updateView() {
    if isBusy { return }
    if isSignInOnly && accountManager.isSignedIn && errorMessage == nil {
      viewController.state = .busy(message: "Loading Cloud Compute…")
    } else if accountManager.isSignedIn {
      var apiKey: String?
      if let client,
        let credential = try? RemoteCredentialStore.readCredential(
          account: client.openAICompatibleBaseURL.absoluteString, provider: .localCode),
        case .apiKey(let storedAPIKey) = credential.value
      {
        apiKey = storedAPIKey
      }
      viewController.state = .signedIn(
        snapshot: snapshot,
        accountID: accountManager.account?.appleCredentialId, apiKey: apiKey, error: errorMessage)
    } else {
      viewController.state = .signedOut(error: errorMessage)
    }
    topUpViewController?.balance = balance ?? "—"
    topUpViewController?.canContinueGeneration =
      isSignedIn && (snapshot?.availableMicroUsd ?? 0) > 0
    delegate?.accountWorkflowDidUpdateAccount(self)
  }

  fileprivate func didDismiss() {
    isSignInOnly = false
    // Closing the panel before the account key exists cancels the waiting generation.
    if savedAPIKey == nil, let completion = pendingImageGenCloudComputeCompletion {
      pendingImageGenCloudComputeCompletion = nil
      completion(.failure(ImageGenError.signInRequired))
    }
    delegate?.accountWorkflowDidDismiss(self)
  }

  fileprivate func authorizationController(
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
      finishWithError(
        AccountManager.AccountError.message(
          LocalizedString.forKey("apple_sign_in_no_credential")))
      return
    }
    beginBusy(LocalizedString.format(key: "finishing_sign_in", "Apple"))
    let generation = operationGeneration
    task = accountManager.signIn(with: credential) { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.operationGeneration == generation else { return }
        switch result {
        case .success:
          self.provisionCredential()
        case .failure(let error):
          self.finishWithError(error)
        }
      }
    }
  }

  fileprivate func authorizationController(didCompleteWithError error: Error) {
    if let authorizationError = error as? ASAuthorizationError,
      authorizationError.code == .unknown || authorizationError.code == .notHandled,
      let fallbackURL = AccountRouterConfiguration.appleWebSignInURL()
    {
      startWebSignIn(at: fallbackURL, provider: .apple)
      return
    }
    finishWithError(error)
  }
}

extension AccountWorkflow: AccountViewControllerDelegate {
  func accountViewController(_ viewController: AccountViewController, didRequestCopy value: String)
  {
    UIPasteboard.general.string = value
  }

  func accountViewController(
    _ viewController: AccountViewController,
    didRequestSignIn provider: AccountManager.SignInProvider
  ) {
    if accountManager.isSignedIn {
      refreshAccount()
      return
    }
    switch provider {
    case .apple:
      webSignInAttempt = nil
      webAuthenticationSession?.cancel()
      webAuthenticationSession = nil
      let request = ASAuthorizationAppleIDProvider().createRequest()
      request.requestedScopes = [.email]
      let controller = ASAuthorizationController(authorizationRequests: [request])
      controller.delegate = objCResponder
      controller.presentationContextProvider = objCResponder
      controller.performRequests()
    case .google:
      startWebSignIn(at: accountManager.localCodeGoogleSignInURL(), provider: .google)
    }
  }

  func accountViewControllerDidRequestSignOut(
    _ viewController: AccountViewController
  ) {
    accountManager.signOut()
  }

  func accountViewControllerDidRequestTopUp(_ viewController: AccountViewController) {
    presentTopUp(from: viewController)
  }

  func accountViewControllerDidRequestDeleteAccount(
    _ viewController: AccountViewController
  ) {
    let alert = UIAlertController(
      title: LocalizedString.forKey("confirm_delete_account"),
      message: LocalizedString.forKey("confirm_delete_local_code_account_description"),
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    alert.addAction(
      UIAlertAction(
        title: LocalizedString.forKey("delete_account"), style: .destructive
      ) { [weak self] _ in
        guard let self else { return }
        guard let client else {
          finishWithError(
            AccountManager.AccountError.message(
              LocalizedString.forKey("local_code_router_url_not_configured")))
          return
        }
        beginBusy(LocalizedString.forKey("deleting_local_code_account"))
        let generation = operationGeneration
        task = accountManager.fetchShortTermToken { [weak self] result in
          DispatchQueue.main.async {
            guard let self, self.operationGeneration == generation else { return }
            switch result {
            case .failure(let error):
              self.finishWithError(error)
            case .success(let token):
              self.task = client.deleteLocalCodeAccount(accessToken: token) { [weak self] result in
                DispatchQueue.main.async {
                  guard let self, self.operationGeneration == generation else { return }
                  switch result {
                  case .failure(let error):
                    self.finishWithError(error)
                  case .success:
                    self.accountManager.signOut()
                  }
                }
              }
            }
          }
        }
      })
    viewController.present(alert, animated: true)
  }
}

extension AccountWorkflow: TopUpViewControllerDelegate {
  func topUpViewControllerDidClose(_ viewController: TopUpViewController) {
    completeTopUp(viewController, continueGeneration: false)
    refreshBalance()
  }

  func topUpViewControllerDidContinueGeneration(
    _ viewController: TopUpViewController
  ) {
    guard topUpViewController === viewController, isSignedIn,
      activePurchaseID == nil, (snapshot?.availableMicroUsd ?? 0) > 0,
      topUpCompletion != nil
    else { return }
    completeTopUp(viewController, continueGeneration: true)
  }

  func topUpViewController(
    _ viewController: TopUpViewController, didChangeConsent hasConsent: Bool
  ) {
    workspace.dictionary["localcode_consumption_consent", Bool.self] = hasConsent
  }

  func topUpViewController(
    _ viewController: TopUpViewController, didRequestPurchase productID: String,
    hasConsent: Bool
  ) {
    workspace.dictionary["localcode_consumption_consent", Bool.self] = hasConsent
    viewController.purchaseStatus = .purchasing(productID)
    let generation = purchaseGeneration
    accountManager.purchaseLocalCodeCredit(productId: productID) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        // StoreKit may finish after sign-out. Keep it pending for its owning account.
        if case .success(let transaction) = result {
          if self.purchaseGeneration == generation, self.topUpViewController === viewController {
            self.topUpPurchaseID = transaction.id
          }
          self.workspace.dictionary["localcode_purchase_consent_\(transaction.id)", Bool.self] =
            hasConsent
          ProductsManager.shared.recordLocalCodeTransaction(transaction)
        }
        guard self.purchaseGeneration == generation else { return }
        switch result {
        case .success(let transaction):
          self.attemptedPurchaseIDs.remove(transaction.id)
          self.deliverPendingPurchases()
        case .failure(let error):
          if let purchaseError = error as? PurchaseError,
            case .userCancelled = purchaseError
          {
            viewController.purchaseStatus = .ready
          } else if let purchaseError = error as? PurchaseError,
            case .pending = purchaseError
          {
            viewController.purchaseStatus = .pending
          } else if error is PurchaseError {
            viewController.purchaseStatus = .error(
              LocalizedString.forKey("purchase_failure_message"))
          } else {
            viewController.purchaseStatus = .error(error.localizedDescription)
          }
        }
      }
    }
  }
}

extension AccountWorkflow {
  private func completeTopUp(
    _ viewController: TopUpViewController, continueGeneration: Bool
  ) {
    guard topUpViewController === viewController else { return }
    let completion = topUpCompletion
    let result = TopUpResult(
      didPurchase: topUpDidPurchase, continueGeneration: continueGeneration)
    topUpCompletion = nil
    topUpDidPurchase = false
    topUpPurchaseID = nil
    topUpViewController = nil
    if viewController.presentingViewController != nil {
      viewController.dismiss(animated: true) { completion?(result) }
    } else {
      completion?(result)
    }
  }

  private func deliverPendingPurchases() {
    guard activePurchaseID == nil, isSignedIn, let client,
      let accountToken = accountManager.appAccountToken,
      let transaction = ProductsManager.shared.localCodeTransactions.value.first(where: {
        $0.appAccountToken == accountToken && !attemptedPurchaseIDs.contains($0.id)
      })
    else { return }
    activePurchaseID = transaction.id
    attemptedPurchaseIDs.insert(transaction.id)
    let generation = purchaseGeneration
    topUpViewController?.purchaseStatus = .purchasing(transaction.productID)
    purchaseTask = accountManager.fetchShortTermToken { [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.purchaseGeneration == generation else { return }
        guard self.accountManager.appAccountToken == accountToken else {
          self.activePurchaseID = nil
          self.deliverPendingPurchases()
          return
        }
        switch result {
        case .failure(let error):
          self.activePurchaseID = nil
          self.topUpViewController?.purchaseStatus = .error(error.localizedDescription)
          self.deliverPendingPurchases()
        case .success(let accessToken):
          let isSandbox: Bool
          if #available(iOS 16.0, *) {
            isSandbox = transaction.environment == AppStore.Environment.sandbox
          } else {
            isSandbox = Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
          }
          self.purchaseTask = client.deliverPurchase(
            transactionId: transaction.id,
            isSandbox: isSandbox,
            customerConsented: self.workspace.dictionary[
              "localcode_purchase_consent_\(transaction.id)", Bool.self]
              ?? self.workspace.dictionary["localcode_consumption_consent", Bool.self] ?? false,
            accessToken: accessToken
          ) { [weak self] result in
            DispatchQueue.main.async {
              guard let self, self.purchaseGeneration == generation else { return }
              self.activePurchaseID = nil
              self.purchaseTask = nil
              guard self.accountManager.appAccountToken == accountToken else {
                self.deliverPendingPurchases()
                return
              }
              switch result {
              case .failure(let error):
                self.topUpViewController?.purchaseStatus = .error(error.localizedDescription)
              case .success(let snapshot):
                self.snapshot = snapshot
                // Only acknowledge a purchase made in this sheet, not replayed deliveries.
                if self.topUpPurchaseID == transaction.id {
                  self.topUpDidPurchase = true
                  self.topUpPurchaseID = nil
                }
                self.balanceRevision &+= 1
                self.workspace.dictionary[
                  "localcode_purchase_consent_\(transaction.id)", Bool.self] = nil
                ProductsManager.shared.finishTransaction(transaction)
                self.topUpViewController?.balance = AccountViewController.credit(
                  snapshot.balanceMicroUsd)
                self.topUpViewController?.purchaseStatus = .succeeded(transaction.productID)
                self.updateView()
              }
              self.deliverPendingPurchases()
            }
          }
        }
      }
    }
  }
}

extension AccountWorkflow.TransitioningController: UIViewControllerTransitioningDelegate {
  func animationController(
    forPresented presented: UIViewController,
    presenting: UIViewController,
    source: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    AccountAnimatedTransitioning(
      duration: 0.4, transition: .easeIn, sourceView: sourceView, placement: placement)
  }

  func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning?
  {
    AccountAnimatedTransitioning(
      duration: 0.4, transition: .easeOut, sourceView: sourceView, placement: placement)
  }

  func presentationController(
    forPresented presented: UIViewController,
    presenting: UIViewController?,
    source: UIViewController
  ) -> UIPresentationController? {
    let presentationController = AccountPresentationController(
      presentedViewController: presented, presenting: presenting)
    presentationController.presentationDelegate = self
    return presentationController
  }
}

extension AccountWorkflow.TransitioningController: AccountPresentationControllerDelegate {
  func didDismissPresentedController() {
    delegate?.didDismiss()
  }
}

extension AccountWorkflow.ObjCResponder: ASAuthorizationControllerDelegate,
  ASAuthorizationControllerPresentationContextProviding,
  ASWebAuthenticationPresentationContextProviding,
  UIPopoverPresentationControllerDelegate
{
  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    workflow?.authorizationController(didCompleteWithAuthorization: authorization)
  }

  func authorizationController(
    controller: ASAuthorizationController,
    didCompleteWithError error: Error
  ) {
    workflow?.authorizationController(didCompleteWithError: error)
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    workflow?.viewController.view.window ?? UIWindow()
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    workflow?.viewController.view.window ?? UIWindow()
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    if let topUpViewController = presentationController.presentedViewController
      as? TopUpViewController
    {
      workflow?.completeTopUp(topUpViewController, continueGeneration: false)
    } else {
      workflow?.didDismiss()
    }
  }

  func adaptivePresentationStyle(
    for controller: UIPresentationController,
    traitCollection: UITraitCollection
  ) -> UIModalPresentationStyle {
    .none
  }
}
