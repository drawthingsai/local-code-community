import Localization
import SnapKit
import UIKit
import WebKit

/// Hosts the existing search web view so verification uses the same cookies and navigation.
final class WebSearchChallengeViewController: UIViewController {
  private let webView: WKWebView
  private let cancel: () -> Void

  init(webView: WKWebView, cancel: @escaping () -> Void) {
    self.webView = webView
    self.cancel = cancel
    super.init(nibName: nil, bundle: nil)
    title = LocalizedString.forKey("web_search_verification_title")
    isModalInPresentation = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    view.addSubview(webView)
    webView.snp.makeConstraints { make in
      make.edges.equalTo(view.safeAreaLayoutGuide)
    }
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: LocalizedString.forKey("cancel"), style: .plain, target: self,
      action: #selector(didTapCancel))
    navigationItem.prompt = LocalizedString.forKey("web_search_verification_prompt")
  }

  @objc private func didTapCancel() { cancel() }

  static func present(webView: WKWebView, cancel: @escaping () -> Void) -> (() -> Void)? {
    guard
      let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first(where: {
          // The chat's scene, not a browser window's.
          $0.activationState == .foregroundActive && $0.delegate is SceneDelegate
        }),
      var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
    else { return nil }
    while let presented = presenter.presentedViewController { presenter = presented }
    guard !presenter.isBeingDismissed, presenter.viewIfLoaded?.window != nil else { return nil }
    let controller = WebSearchChallengeViewController(webView: webView, cancel: cancel)
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .formSheet
    navigation.isModalInPresentation = true
    navigation.preferredContentSize = CGSize(width: 800, height: 700)
    presenter.present(navigation, animated: true)
    return { [weak navigation, weak webView] in
      webView?.removeFromSuperview()
      navigation?.dismiss(animated: true)
    }
  }
}
