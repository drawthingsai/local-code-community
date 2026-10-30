import Dispatch
import Localization
import RemoteAPI
import SafariServices
import UIKit

enum RemoteOAuthLogin {
  private static var openAILogin: OpenAIOAuthLogin?
  private static var anthropicLogin: AnthropicOAuthLogin?

  static func present(
    provider: RemoteProvider, on viewController: UIViewController,
    completion: @escaping (Result<RemoteOAuthCredential, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch provider {
    case .openAI:
      presentOpenAI(on: viewController, completion: completion)
    case .anthropic:
      presentAnthropic(on: viewController, completion: completion)
    case .localCode, .openRouter, .openAICompatible, .deviceLink:
      completion(.failure(RemoteOAuthError.invalidAuthorizationResponse))
    }
  }

  private static func presentOpenAI(
    on viewController: UIViewController,
    completion: @escaping (Result<RemoteOAuthCredential, Error>) -> Void
  ) {
    guard openAILogin == nil else { return }
    let login = OpenAIOAuthLogin(viewController: viewController)
    openAILogin = login
    login.start { result in
      openAILogin = nil
      if let result { completion(result) }
    }
  }

  private static func presentAnthropic(
    on viewController: UIViewController,
    completion: @escaping (Result<RemoteOAuthCredential, Error>) -> Void
  ) {
    do {
      guard anthropicLogin == nil else { return }
      let login = try AnthropicOAuthLogin(viewController: viewController)
      anthropicLogin = login
      login.start { result in
        anthropicLogin = nil
        if let result { completion(result) }
      }
    } catch {
      completion(.failure(error))
    }
  }
}

private var shouldOpenOAuthInSystemBrowser: Bool {
  #if targetEnvironment(macCatalyst)
    return true
  #else
    return ProcessInfo.processInfo.isiOSAppOnMac
  #endif
}

private final class OpenAIOAuthLogin: NSObject, SFSafariViewControllerDelegate {
  private let viewController: UIViewController
  private var alert: UIAlertController?
  private var browser: SFSafariViewController?
  private var task: Task<Void, Never>?
  private var completion: ((Result<RemoteOAuthCredential, Error>?) -> Void)?

  init(viewController: UIViewController) {
    self.viewController = viewController
  }

  func start(completion: @escaping (Result<RemoteOAuthCredential, Error>?) -> Void) {
    self.completion = completion
    task = Task { @MainActor [weak self] in
      do {
        let authorization = try await RemoteOAuth.requestOpenAIDeviceAuthorization()
        try Task.checkCancellation()
        guard let self, self.completion != nil else { return }
        self.task = nil
        self.presentCode(authorization)
      } catch is CancellationError {
        self?.finish(nil)
      } catch {
        self?.finish(.failure(error))
      }
    }
  }

  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    guard completion != nil else { return }
    browser = nil
    controller.dismiss(animated: true) {
      self.finish(nil)
    }
  }

  private func presentCode(_ authorization: OpenAIDeviceAuthorization) {
    UIPasteboard.general.string = authorization.userCode
    let alert = UIAlertController(
      title: LocalizedString.forKey("remote_oauth_openai_title"),
      message: LocalizedString.format(
        key: "remote_oauth_device_message", authorization.userCode),
      preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: LocalizedString.forKey("continue"), style: .default) {
        [weak self, weak alert] _ in
        guard let self else { return }
        self.alert = nil
        alert?.dismiss(animated: true) {
          self.presentBrowser(authorization)
        }
      })
    alert.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel) { [weak self] _ in
        self?.finish(nil)
      })
    self.alert = alert
    viewController.present(alert, animated: true)
  }

  private func presentBrowser(_ authorization: OpenAIDeviceAuthorization) {
    guard completion != nil, browser == nil else { return }
    if shouldOpenOAuthInSystemBrowser {
      UIApplication.shared.open(authorization.verificationURL) { [weak self] opened in
        guard !opened else { return }
        self?.finish(
          .failure(
            RemoteOAuthError.authorizationFailed(
              LocalizedString.forKey("could_not_open_browser"))))
      }
    } else {
      let browser = SFSafariViewController(url: authorization.verificationURL)
      browser.delegate = self
      self.browser = browser
      viewController.present(browser, animated: true)
    }
    task = Task { @MainActor [weak self] in
      do {
        let credential = try await RemoteOAuth.completeOpenAIDeviceAuthorization(authorization)
        try Task.checkCancellation()
        self?.finish(.success(credential))
      } catch is CancellationError {
        self?.finish(nil)
      } catch {
        self?.finish(.failure(error))
      }
    }
  }

  private func finish(_ result: Result<RemoteOAuthCredential, Error>?) {
    guard let completion else { return }
    self.completion = nil
    task?.cancel()
    task = nil
    if let browser {
      self.browser = nil
      browser.dismiss(animated: true) {
        completion(result)
      }
    } else if let alert {
      self.alert = nil
      alert.dismiss(animated: true) {
        completion(result)
      }
    } else {
      completion(result)
    }
  }
}

private final class AnthropicOAuthLogin: NSObject, SFSafariViewControllerDelegate {
  private let viewController: UIViewController
  private let authorization: RemoteOAuthAuthorization
  private let server: RemoteOAuthLoopbackServer
  private var browser: SFSafariViewController?
  private var manualAlert: UIAlertController?
  private var exchangeTask: Task<Void, Never>?
  private var completion: ((Result<RemoteOAuthCredential, Error>?) -> Void)?
  private var isExchanging = false

  init(viewController: UIViewController) throws {
    let authorization = try RemoteOAuth.anthropicAuthorization()
    self.viewController = viewController
    self.authorization = authorization
    server = try RemoteOAuthLoopbackServer(
      callbackURL: authorization.callbackURL, expectedState: authorization.state)
    super.init()
  }

  func start(completion: @escaping (Result<RemoteOAuthCredential, Error>?) -> Void) {
    self.completion = completion
    server.start(
      ready: { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success:
            self?.presentBrowser()
          case .failure(let error):
            self?.finish(.failure(error))
          }
        }
      },
      callback: { [weak self] result in
        DispatchQueue.main.async {
          guard let self else { return }
          switch result {
          case .success(let input):
            self.exchange(input)
          case .failure(let error):
            self.finish(.failure(error))
          }
        }
      })
  }

  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    guard completion != nil else { return }
    browser = nil
    guard !isExchanging else { return }
    server.cancel()
    controller.dismiss(animated: true) {
      self.presentManualEntry()
    }
  }

  private func presentBrowser() {
    guard completion != nil, browser == nil else { return }
    if shouldOpenOAuthInSystemBrowser {
      UIApplication.shared.open(authorization.url) { [weak self] opened in
        guard !opened else { return }
        self?.finish(
          .failure(
            RemoteOAuthError.authorizationFailed(
              LocalizedString.forKey("could_not_open_browser"))))
      }
    } else {
      let browser = SFSafariViewController(url: authorization.url)
      browser.delegate = self
      self.browser = browser
      viewController.present(browser, animated: true)
    }
  }

  private func presentManualEntry() {
    guard completion != nil, !isExchanging else { return }
    let alert = UIAlertController(
      title: LocalizedString.forKey("remote_oauth_anthropic_title"),
      message: LocalizedString.forKey("remote_oauth_anthropic_message"),
      preferredStyle: .alert)
    alert.addTextField {
      $0.placeholder = LocalizedString.forKey("remote_oauth_code_placeholder")
      $0.autocapitalizationType = .none
      $0.autocorrectionType = .no
    }
    alert.addAction(
      UIAlertAction(title: LocalizedString.forKey("continue"), style: .default) {
        [weak self, weak alert] _ in
        guard let input = alert?.textFields?.first?.text,
          !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        self?.exchange(input)
      })
    alert.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel) { [weak self] _ in
        self?.finish(nil)
      })
    manualAlert = alert
    viewController.present(alert, animated: true)
  }

  private func exchange(_ input: String) {
    guard completion != nil, !isExchanging else { return }
    isExchanging = true
    server.cancel()
    exchangeTask = Task { @MainActor in
      do {
        let credential = try await RemoteOAuth.exchangeAnthropicCode(
          input, authorization: authorization)
        try Task.checkCancellation()
        finish(.success(credential))
      } catch is CancellationError {
      } catch {
        finish(.failure(error))
      }
    }
  }

  private func finish(_ result: Result<RemoteOAuthCredential, Error>?) {
    guard let completion else { return }
    self.completion = nil
    server.cancel()
    exchangeTask?.cancel()
    if let browser {
      self.browser = nil
      browser.dismiss(animated: true) {
        completion(result)
      }
    } else if let manualAlert {
      self.manualAlert = nil
      manualAlert.dismiss(animated: true) {
        completion(result)
      }
    } else {
      completion(result)
    }
  }
}
