import Components
import Localization
import SnapKit
import Style
import UIKit
import WebKit

#if targetEnvironment(macCatalyst)
  import ExceptionCatcher
#endif

protocol UnifiedBrowserWindowWorkflowDelegate: AnyObject {
  /// The window closed, from the person or from `close`, and the web view is out of it again.
  func unifiedBrowserWindowWorkflowDidClose(_ workflow: UnifiedBrowserWindowWorkflow)
}

/// Shows one tab's web view: in a window of its own on Mac, with the rim glow where its shadow
/// would be, or in a sheet on iPhone and iPad. Presenting takes the web view out of wherever it
/// was; once the window closes the delegate gets it back.
final class UnifiedBrowserWindowWorkflow: Workflow {
  weak var delegate: UnifiedBrowserWindowWorkflowDelegate?
  var viewControllable: UIViewController { viewController }
  let webView: WKWebView
  private(set) var isOpen = false
  private var titleObservation: NSKeyValueObservation?

  #if targetEnvironment(macCatalyst)
    static let activityType = "com.liuliu.local-code.browser-window"
    static let sceneConfigurationName = "Browser Window"
    /// Windows asked for a scene, by the identifier their activity carries.
    private static var requests = [String: UnifiedBrowserWindowWorkflow]()
    /// In AppKit points.
    private static let defaultSize = CGSize(width: 880, height: 680)

    private let identifier = UUID().uuidString
    private let viewController: BrowserWindowViewController
    private weak var windowScene: UIWindowScene?
    /// Completions waiting for the scene to connect.
    private var presentations = [(Result<Void, Error>) -> Void]()
    private var requestingFrame: CGRect?
    private var glowController: RimGlowWindowController?
    private var titlebarController: BrowserTitlebarController?
  #else
    private let viewController: BrowserViewController
    private var navigationController: UINavigationController?
    private let responder = ObjCResponder()

    private final class ObjCResponder: NSObject, UIAdaptivePresentationControllerDelegate {
      weak var workflow: UnifiedBrowserWindowWorkflow?

      func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        workflow?.didClose()
      }
    }
  #endif

  init(webView: WKWebView) {
    self.webView = webView
    #if targetEnvironment(macCatalyst)
      viewController = BrowserWindowViewController(webView: webView)
    #else
      viewController = BrowserViewController(webView: webView)
      viewController.delegate = self
      responder.workflow = self
    #endif
  }

  /// Opens the window, or brings it to the front when it is already open. On iPhone and iPad
  /// the sheet comes from `presenter`, which must not be presenting anything else.
  func present(
    from presenter: UIViewController?, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    #if targetEnvironment(macCatalyst)
      if let windowScene {
        UIApplication.shared.requestSceneSessionActivation(
          windowScene.session, userActivity: nil, options: nil)
        completion(.success(()))
        return
      }
      presentations.append(completion)
      guard presentations.count == 1 else { return }
      Self.requests[identifier] = self
      let requestingScene = presenter?.viewIfLoaded?.window?.windowScene
      requestingFrame = requestingScene?.effectiveGeometry.systemFrame
      let activity = NSUserActivity(activityType: Self.activityType)
      activity.userInfo = ["id": identifier]
      let options = UIScene.ActivationRequestOptions()
      options.requestingScene = requestingScene
      UIApplication.shared.requestSceneSessionActivation(
        nil, userActivity: activity, options: options
      ) { [weak self] error in
        guard let self else { return }
        Self.requests[self.identifier] = nil
        self.finishPresenting(.failure(error))
      }
    #else
      guard navigationController == nil else {
        completion(.success(()))
        return
      }
      guard let presenter, presenter.viewIfLoaded?.window != nil,
        presenter.presentedViewController == nil
      else {
        completion(
          .failure(BrowserError.unavailable("The chat cannot present the browser right now.")))
        return
      }
      let navigationController = UINavigationController(rootViewController: viewController)
      navigationController.modalPresentationStyle = .formSheet
      navigationController.preferredContentSize = BrowserTab.viewport.size
      navigationController.presentationController?.delegate = responder
      self.navigationController = navigationController
      isOpen = true
      observeTitle { [weak viewController] in viewController?.title = $0 }
      presenter.present(navigationController, animated: true) { completion(.success(())) }
    #endif
  }

  /// Closes the window; the delegate hears about it once the web view is out.
  func close(animated: Bool = true, completion: (() -> Void)? = nil) {
    #if targetEnvironment(macCatalyst)
      if let windowScene {
        // The scene disconnects next, which finishes closing.
        UIApplication.shared.requestSceneSessionDestruction(
          windowScene.session, options: nil)
      } else if !presentations.isEmpty {
        // The web view never left its owner, so there is nothing to give back.
        Self.requests[identifier] = nil
        finishPresenting(.failure(BrowserError.cancelled))
      }
      completion?()
    #else
      guard let navigationController else {
        completion?()
        return
      }
      navigationController.dismiss(animated: animated) { [weak self] in
        self?.didClose()
        completion?()
      }
    #endif
  }

  private func observeTitle(_ update: @escaping (String?) -> Void) {
    titleObservation = webView.observe(\.title, options: [.initial]) { webView, _ in
      update(webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.host)
    }
  }

  private func didClose() {
    guard isOpen else { return }
    isOpen = false
    titleObservation = nil
    webView.removeFromSuperview()
    #if targetEnvironment(macCatalyst)
      glowController?.detach()
      glowController = nil
      titlebarController?.detach()
      titlebarController = nil
      windowScene = nil
    #else
      navigationController?.setViewControllers([], animated: false)
      navigationController = nil
    #endif
    delegate?.unifiedBrowserWindowWorkflowDidClose(self)
  }

  #if targetEnvironment(macCatalyst)
    /// The browser scene for a new session, or nil for any other session.
    static func sceneConfiguration(
      for session: UISceneSession, options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration? {
      guard options.userActivities.contains(where: { $0.activityType == activityType }) else {
        return nil
      }
      let configuration = UISceneConfiguration(
        name: sceneConfigurationName, sessionRole: session.role)
      configuration.delegateClass = BrowserWindowSceneDelegate.self
      configuration.sceneClass = WindowScene.self
      return configuration
    }

    /// macOS restores scene sessions from the last run, but tabs do not outlive the app.
    static func discardRestoredSessions(in application: UIApplication) {
      for session in application.openSessions
      where session.configuration.name == sceneConfigurationName {
        application.requestSceneSessionDestruction(session, options: nil)
      }
    }

    fileprivate static func request(for options: UIScene.ConnectionOptions)
      -> UnifiedBrowserWindowWorkflow?
    {
      guard
        let identifier = options.userActivities.lazy.compactMap({
          $0.activityType == activityType ? $0.userInfo?["id"] as? String : nil
        }).first
      else { return nil }
      return requests.removeValue(forKey: identifier)
    }

    fileprivate func connect(to windowScene: UIWindowScene) -> UIWindow {
      self.windowScene = windowScene
      isOpen = true
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = viewController
      windowScene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 400)
      if let titlebar = windowScene.titlebar {
        titlebar.titleVisibility = .hidden
        titlebar.toolbar = nil
      }
      // The title still names the window in the Window menu and Mission Control.
      observeTitle { [weak windowScene] in windowScene?.title = $0 }
      window.makeKeyAndVisible()
      let size = Self.defaultSize
      if let requestingFrame {
        windowScene.requestGeometryUpdate(
          .Mac(
            systemFrame: CGRect(
              x: requestingFrame.midX - size.width / 2 + 40, y: requestingFrame.minY + 60,
              width: size.width, height: size.height)))
      }
      let glowController = RimGlowWindowController(window: window)
      glowController.attach()
      self.glowController = glowController
      let titlebarController = BrowserTitlebarController(
        window: window, rowHeight: BrowserWindowViewController.toolbarHeight)
      titlebarController.attach()
      self.titlebarController = titlebarController
      finishPresenting(.success(()))
      return window
    }

    fileprivate func disconnect() {
      didClose()
    }

    private func finishPresenting(_ result: Result<Void, Error>) {
      let presentations = presentations
      self.presentations.removeAll()
      presentations.forEach { $0(result) }
    }
  #endif
}

#if targetEnvironment(macCatalyst)
  /// Connects a browser window's scene to the `UnifiedBrowserWindowWorkflow` that asked for it. A
  /// scene restored from an earlier run, or whose request was withdrawn, has nothing to show.
  final class BrowserWindowSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var workflow: UnifiedBrowserWindowWorkflow?

    func scene(
      _ scene: UIScene, willConnectTo session: UISceneSession,
      options connectionOptions: UIScene.ConnectionOptions
    ) {
      guard let windowScene = scene as? UIWindowScene,
        let workflow = UnifiedBrowserWindowWorkflow.request(for: connectionOptions)
      else {
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        return
      }
      self.workflow = workflow
      window = workflow.connect(to: windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
      workflow?.disconnect()
      workflow = nil
      window = nil
    }
  }

  /// Moves the traffic lights to the middle of the toolbar row, the way Electron's
  /// trafficLightPosition does: the title bar container grows to the row's height and the
  /// buttons are centered in it. AppKit lays the title bar out again on resizes and key changes,
  /// so it is repeated after each, and every second besides, like the chat window's movable
  /// fix, for layouts no notification marks and for a window not sized yet when it attaches.
  final class BrowserTitlebarController {
    private weak var window: UIWindow?
    /// In UIKit points.
    private let rowHeight: CGFloat
    private var hostWindow: NSObject?
    private var observers = [NSObjectProtocol]()
    private var isAttached = false
    private var missedAttempts = 0

    init(window: UIWindow, rowHeight: CGFloat) {
      self.window = window
      self.rowHeight = rowHeight
    }

    func attach() {
      guard !isAttached else { return }
      isAttached = true
      centerTrafficLightsPeriodically()
    }

    func detach() {
      isAttached = false
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
      hostWindow = nil
    }

    /// Tries every 50 milliseconds until the window is on screen and sized, for two seconds at
    /// most, then every second until detached.
    private func centerTrafficLightsPeriodically() {
      guard isAttached, let window else { return }
      if hostWindow == nil, let host = window.hostingNSWindow {
        hostWindow = host
        for name in [
          "NSWindowDidResizeNotification", "NSWindowDidEndLiveResizeNotification",
          "NSWindowDidBecomeKeyNotification", "NSWindowDidResignKeyNotification",
          "NSWindowDidExitFullScreenNotification",
        ] {
          observers.append(
            NotificationCenter.default.addObserver(
              forName: Notification.Name(name), object: host, queue: .main
            ) { [weak self] _ in
              self?.centerTrafficLights()
            })
        }
      }
      let isCentered = centerTrafficLights()
      if !isCentered {
        missedAttempts += 1
      }
      let delay: DispatchTimeInterval =
        !isCentered && missedAttempts < 40 ? .milliseconds(50) : .seconds(1)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.centerTrafficLightsPeriodically()
      }
    }

    /// Whether the buttons are in the middle of the row now.
    @discardableResult
    private func centerTrafficLights() -> Bool {
      guard let hostWindow, let window, window.bounds.width > 0 else { return false }
      let selector = NSSelectorFromString("standardWindowButton:")
      typealias ButtonGetter = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<AnyObject>?
      let getter = unsafeBitCast(hostWindow.method(for: selector), to: ButtonGetter.self)
      let buttons = (0..<3).compactMap {
        getter(hostWindow, selector, $0)?.takeUnretainedValue() as? NSObject
      }
      guard let close = buttons.first,
        let titlebarView = close.value(forKey: "superview") as? NSObject,
        let container = titlebarView.value(forKey: "superview") as? NSObject
      else { return false }
      let hostFrame = Self.frame(of: hostWindow)
      // UIKit points are smaller than AppKit's for the iPad idiom on Mac (77%).
      let height = (rowHeight * hostFrame.width / window.bounds.width).rounded()
      return
        (try? ExceptionCatcher.catch { () -> Bool in
          var containerFrame = Self.frame(of: container)
          containerFrame.size.height = height
          containerFrame.origin.y = hostFrame.height - height
          Self.setFrame(containerFrame, of: container)
          var titlebarFrame = Self.frame(of: titlebarView)
          titlebarFrame.size.height = height
          titlebarFrame.origin.y = 0
          Self.setFrame(titlebarFrame, of: titlebarView)
          for button in buttons {
            var frame = Self.frame(of: button)
            frame.origin.y = ((height - frame.height) / 2).rounded()
            Self.setFrame(frame, of: button)
          }
          return true
        }) ?? false
    }

    private static func frame(of object: NSObject) -> CGRect {
      (object.value(forKey: "frame") as? NSValue)?.cgRectValue ?? .zero
    }

    /// Leaves a view that is already in place alone, so the periodic pass costs no layout.
    private static func setFrame(_ frame: CGRect, of object: NSObject) {
      guard frame != Self.frame(of: object) else { return }
      object.setValue(NSValue(cgRect: frame), forKey: "frame")
    }
  }

  /// A browser window's content: the traffic lights, back and forward, the address, and the page.
  final class BrowserWindowViewController: UIViewController {
    static let toolbarHeight: CGFloat = 52
    /// The traffic lights end 69 AppKit points in, about 90 UIKit points.
    private static let trafficLightsWidth: CGFloat = 100
    private static let addressMinimumWidth: CGFloat = 360
    private static let addressHeight: CGFloat = 32

    private let webView: WKWebView
    private var observations = [NSKeyValueObservation]()

    private lazy var toolbarView: UIView = {
      let view = UIView(frame: .zero)
      view.backgroundColor = .secondaryBackground
      let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragWindow(_:)))
      drag.minimumPressDuration = 0
      drag.delegate = self
      view.addGestureRecognizer(drag)
      let zoom = UITapGestureRecognizer(target: self, action: #selector(zoomWindow))
      zoom.numberOfTapsRequired = 2
      zoom.delegate = self
      view.addGestureRecognizer(zoom)
      return view
    }()

    private lazy var separatorView: UIView = {
      let view = UIView(frame: .zero)
      view.backgroundColor = .separator
      return view
    }()

    private lazy var backButton: UIButton = {
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(
        systemName: "chevron.left",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
      configuration.baseForegroundColor = .secondaryLabel
      let button = UIButton(configuration: configuration)
      button.isEnabled = false
      button.accessibilityLabel = LocalizedString.forKey("back")
      button.addAction(UIAction { [weak self] _ in self?.webView.goBack() }, for: .touchUpInside)
      return button
    }()

    private lazy var forwardButton: UIButton = {
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(
        systemName: "chevron.right",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
      configuration.baseForegroundColor = .secondaryLabel
      let button = UIButton(configuration: configuration)
      button.isEnabled = false
      button.accessibilityLabel = LocalizedString.forKey("forward")
      button.addAction(
        UIAction { [weak self] _ in self?.webView.goForward() }, for: .touchUpInside)
      return button
    }()

    private lazy var reloadButton: UIButton = {
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(
        systemName: "arrow.clockwise",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
      configuration.baseForegroundColor = .secondaryLabel
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 8, bottom: 0, trailing: 10)
      let button = UIButton(configuration: configuration)
      button.accessibilityLabel = LocalizedString.forKey("reload")
      button.addAction(UIAction { [weak self] _ in self?.webView.reload() }, for: .touchUpInside)
      return button
    }()

    private lazy var addressField: UITextField = {
      let textField = UITextField(frame: .zero)
      textField.backgroundColor = .tertiarySystemFill
      textField.layer.cornerRadius = Self.addressHeight / 2
      textField.textAlignment = .center
      // About 12.3 points on screen at the iPad idiom's 77% on Mac.
      textField.font = .systemFont(ofSize: 16)
      textField.keyboardType = .URL
      textField.returnKeyType = .go
      textField.autocapitalizationType = .none
      textField.autocorrectionType = .no
      // Balances the reload button so the address stays centered.
      textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
      textField.leftViewMode = .always
      textField.rightView = reloadButton
      textField.rightViewMode = .always
      textField.delegate = self
      textField.addAction(
        UIAction { [weak textField] _ in textField?.invalidateIntrinsicContentSize() },
        for: .editingChanged)
      return textField
    }()

    init(webView: WKWebView) {
      self.webView = webView
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .systemBackground
      view.addSubview(webView)
      view.addSubview(toolbarView)
      view.addSubview(separatorView)
      toolbarView.addSubview(backButton)
      toolbarView.addSubview(forwardButton)
      toolbarView.addSubview(addressField)
      toolbarView.snp.makeConstraints { make in
        make.top.leading.trailing.equalToSuperview()
        make.height.equalTo(Self.toolbarHeight)
      }
      separatorView.snp.makeConstraints { make in
        make.top.equalTo(toolbarView.snp.bottom)
        make.leading.trailing.equalToSuperview()
        make.height.equalTo(0.5)
      }
      backButton.snp.makeConstraints { make in
        make.leading.equalToSuperview().offset(Self.trafficLightsWidth)
        make.centerY.equalToSuperview()
        make.size.equalTo(32)
      }
      forwardButton.snp.makeConstraints { make in
        make.leading.equalTo(backButton.snp.trailing)
        make.centerY.equalToSuperview()
        make.size.equalTo(32)
      }
      // Hugs the address, at least 360 points, and widens as it grows, off center when it
      // must, up to 12 points after the forward button and, on the right, as far from the
      // window's edge as from the row's top and bottom. Centering yields to the text's
      // compression resistance (750).
      addressField.snp.makeConstraints { make in
        make.centerX.equalToSuperview().priority(500)
        make.centerY.equalToSuperview()
        make.height.equalTo(Self.addressHeight)
        make.width.greaterThanOrEqualTo(Self.addressMinimumWidth).priority(999)
        make.leading.greaterThanOrEqualTo(forwardButton.snp.trailing).offset(12)
        make.trailing.lessThanOrEqualToSuperview().offset(
          -(Self.toolbarHeight - Self.addressHeight) / 2)
      }
      webView.snp.makeConstraints { make in
        make.top.equalTo(separatorView.snp.bottom)
        make.leading.trailing.bottom.equalToSuperview()
      }
      observations = [
        webView.observe(\.url, options: [.initial]) { [weak self] _, _ in
          self?.updateAddress()
        },
        webView.observe(\.canGoBack, options: [.initial]) { [weak self] webView, _ in
          self?.backButton.isEnabled = webView.canGoBack
        },
        webView.observe(\.canGoForward, options: [.initial]) { [weak self] webView, _ in
          self?.forwardButton.isEnabled = webView.canGoForward
        },
      ]
    }

    /// The host and port while not editing, like Safari.
    private func updateAddress() {
      guard !addressField.isEditing else { return }
      if let url = webView.url {
        addressField.text =
          url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
      } else {
        addressField.text = nil
      }
      addressField.invalidateIntrinsicContentSize()
    }

    @objc private func dragWindow(_ recognizer: UILongPressGestureRecognizer) {
      guard recognizer.state == .began else { return }
      performMacCatalystWindowDrag()
    }

    @objc private func zoomWindow() {
      performMacCatalystZoom()
    }
  }

  extension BrowserWindowViewController: UIGestureRecognizerDelegate {
    // Only the row's empty space moves the window; its controls keep their clicks.
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
      touch.view === toolbarView
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }

  extension BrowserWindowViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
      textField.text = webView.url?.absoluteString
      textField.invalidateIntrinsicContentSize()
      textField.selectAll(nil)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
      updateAddress()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      let text = (textField.text ?? "").trimmingCharacters(in: .whitespaces)
      // A bare host is a web address; local servers default to http, like web-browse-cli.
      let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1")
      if let url = URL(
        string: text.contains("://") ? text : (isLocal ? "http://" : "https://") + text)
      {
        webView.load(URLRequest(url: url))
      }
      textField.resignFirstResponder()
      return true
    }
  }
#else
  extension UnifiedBrowserWindowWorkflow: BrowserViewControllerDelegate {
    func browserViewControllerDidTapDone(_ viewController: BrowserViewController) {
      close()
    }
  }

  protocol BrowserViewControllerDelegate: AnyObject {
    func browserViewControllerDidTapDone(_ viewController: BrowserViewController)
  }

  /// A browser sheet's content: the live tab that commands drive, which the person can inspect
  /// or interact with.
  final class BrowserViewController: UIViewController {
    weak var delegate: BrowserViewControllerDelegate?
    private let webView: WKWebView

    private lazy var doneButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(didTapDone))

    init(webView: WKWebView) {
      self.webView = webView
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .systemBackground
      navigationItem.rightBarButtonItem = doneButtonItem
      view.addSubview(webView)
      webView.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
    }

    @objc private func didTapDone() {
      delegate?.browserViewControllerDidTapDone(self)
    }
  }
#endif
