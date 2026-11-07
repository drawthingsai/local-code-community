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

  /// The page an address the person typed names. A bare host is a web address; local servers
  /// default to http, like web-browse-cli.
  fileprivate static func url(forAddress address: String) -> URL? {
    let text = address.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1")
    return URL(string: text.contains("://") ? text : (isLocal ? "http://" : "https://") + text)
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

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      // A tab the person opened starts blank, waiting for an address.
      if webView.url == nil {
        addressField.becomeFirstResponder()
      }
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
      if let url = UnifiedBrowserWindowWorkflow.url(forAddress: textField.text ?? "") {
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
  /// or interact with, under the page's title. Like Safari on iPhone, the address floats in glass
  /// over the page's bottom, centered between back and a down arrow back to the chat, and
  /// shrinks to the page's domain as the person scrolls down, following their finger, then
  /// grows back as they scroll up. Editing the address lifts it above the keyboard beside
  /// Cancel; Go opens the page.
  final class BrowserViewController: UIViewController {
    private static let addressHeight: CGFloat = 48
    private static let collapsedAddressHeight: CGFloat = 32
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 8
    /// How far the page scrolls while the address collapses or expands.
    private static let collapseDistance: CGFloat = 44
    private static let collapsedDomainScale: CGFloat = 13.0 / 16.0
    private static let domainPadding: CGFloat = 14
    private static let reloadSize: CGFloat = 36

    weak var delegate: BrowserViewControllerDelegate?
    private let webView: WKWebView
    private var observations = [NSKeyValueObservation]()
    /// 0 shows back and the full address, 1 only the domain.
    private var collapseProgress: CGFloat = 0
    private var lastContentOffsetY: CGFloat = 0
    /// Where a scroll that stops halfway settles: the way it last moved.
    private var settlesCollapsed = false
    private var addressLeadingConstraint: Constraint?
    private var addressWidthConstraint: Constraint?
    private var addressHeightConstraint: Constraint?
    /// Above the home indicator, yielding to `addressAboveKeyboardConstraint` while editing.
    private var addressBottomConstraint: Constraint?
    /// Active while the address is edited; the keyboard for a field on the page covers it.
    private var addressAboveKeyboardConstraint: Constraint?
    /// Leaves room for reload on either side of the domain.
    private var domainMaximumWidthConstraint: Constraint?

    private lazy var backButton: UIButton = {
      var configuration = Self.barButtonConfiguration()
      configuration.image = UIImage(
        systemName: "chevron.left",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
      let button = UIButton(configuration: configuration)
      button.isEnabled = false
      button.accessibilityLabel = LocalizedString.forKey("back")
      button.addAction(UIAction { [weak self] _ in self?.webView.goBack() }, for: .touchUpInside)
      return button
    }()

    /// Across the address from back, so the address sits centered between them.
    private lazy var closeButton: UIButton = {
      var configuration = Self.barButtonConfiguration()
      configuration.image = UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
      let button = UIButton(configuration: configuration)
      button.accessibilityLabel = LocalizedString.forKey("close")
      button.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          self.delegate?.browserViewControllerDidTapDone(self)
        }, for: .touchUpInside)
      return button
    }()

    private lazy var addressBarView: UIVisualEffectView = {
      let view: UIVisualEffectView
      if #available(iOS 26.0, *) {
        view = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        view.cornerConfiguration = .capsule()
      } else {
        view = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
        view.clipsToBounds = true
      }
      view.addGestureRecognizer(
        UITapGestureRecognizer(target: self, action: #selector(didTapAddress)))
      return view
    }()

    /// The host and port while not editing, like Safari.
    private lazy var domainLabel: UILabel = {
      let label = UILabel(frame: .zero)
      label.font = .systemFont(ofSize: 16)
      label.textColor = .label
      label.textAlignment = .center
      label.lineBreakMode = .byTruncatingTail
      return label
    }()

    private lazy var reloadButton: UIButton = {
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(
        systemName: "arrow.clockwise",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
      configuration.baseForegroundColor = .label
      let button = UIButton(configuration: configuration)
      button.accessibilityLabel = LocalizedString.forKey("reload")
      button.addAction(UIAction { [weak self] _ in self?.webView.reload() }, for: .touchUpInside)
      return button
    }()

    /// Shown only while editing, over the domain.
    private lazy var addressField: UITextField = {
      let textField = UITextField(frame: .zero)
      textField.font = .systemFont(ofSize: 16)
      textField.keyboardType = .URL
      textField.returnKeyType = .go
      textField.autocapitalizationType = .none
      textField.autocorrectionType = .no
      textField.clearButtonMode = .whileEditing
      textField.alpha = 0
      textField.delegate = self
      return textField
    }()

    private lazy var cancelButton: UIButton = {
      var configuration = Self.barButtonConfiguration()
      configuration.title = LocalizedString.forKey("cancel")
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 16, bottom: 0, trailing: 16)
      let button = UIButton(configuration: configuration)
      button.alpha = 0
      button.addAction(
        UIAction { [weak self] _ in self?.addressField.resignFirstResponder() },
        for: .touchUpInside)
      return button
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
      view.addSubview(backButton)
      view.addSubview(closeButton)
      view.addSubview(addressBarView)
      view.addSubview(cancelButton)
      addressBarView.contentView.addSubview(domainLabel)
      addressBarView.contentView.addSubview(reloadButton)
      addressBarView.contentView.addSubview(addressField)
      setContentScrollView(webView.scrollView)
      webView.scrollView.delegate = self
      // The page runs under the address, and can scroll its end above it.
      webView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      webView.scrollView.contentInset.bottom = Self.addressHeight + Self.spacing
      // `updateAddressLayout` sets the constants.
      addressBarView.snp.makeConstraints { make in
        addressLeadingConstraint = make.leading.equalTo(view.safeAreaLayoutGuide).constraint
        addressWidthConstraint = make.width.equalTo(0).constraint
        addressHeightConstraint = make.height.equalTo(Self.addressHeight).constraint
        addressBottomConstraint =
          make.bottom.equalTo(view.safeAreaLayoutGuide).priority(.high).constraint
        addressAboveKeyboardConstraint =
          make.bottom.equalTo(view.keyboardLayoutGuide.snp.top).offset(-Self.spacing).constraint
      }
      addressAboveKeyboardConstraint?.deactivate()
      backButton.snp.makeConstraints { make in
        make.leading.equalTo(view.safeAreaLayoutGuide).offset(Self.margin)
        make.centerY.equalTo(addressBarView)
        make.size.equalTo(Self.addressHeight)
      }
      closeButton.snp.makeConstraints { make in
        make.trailing.equalTo(view.safeAreaLayoutGuide).offset(-Self.margin)
        make.centerY.equalTo(addressBarView)
        make.size.equalTo(Self.addressHeight)
      }
      cancelButton.snp.makeConstraints { make in
        make.trailing.equalTo(view.safeAreaLayoutGuide).offset(-Self.margin)
        make.centerY.equalTo(addressBarView)
        make.height.equalTo(Self.addressHeight)
      }
      domainLabel.snp.makeConstraints { make in
        make.center.equalToSuperview()
        domainMaximumWidthConstraint = make.width.lessThanOrEqualTo(0).constraint
      }
      reloadButton.snp.makeConstraints { make in
        make.trailing.equalToSuperview().offset(-6)
        make.centerY.equalToSuperview()
        make.size.equalTo(Self.reloadSize)
      }
      addressField.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.leading.trailing.equalToSuperview().inset(Self.domainPadding)
      }
      observations = [
        webView.observe(\.url, options: [.initial]) { [weak self] _, _ in
          self?.updateAddress()
          self?.setCollapseProgress(0, animated: true)
        },
        webView.observe(\.canGoBack, options: [.initial]) { [weak self] webView, _ in
          self?.backButton.isEnabled = webView.canGoBack
        },
      ]
    }

    override func viewWillLayoutSubviews() {
      super.viewWillLayoutSubviews()
      updateAddressLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      // A tab the person opened starts blank, waiting for an address.
      if webView.url == nil {
        addressField.becomeFirstResponder()
      }
    }

    /// Glass where the system has it.
    private static func barButtonConfiguration() -> UIButton.Configuration {
      var configuration: UIButton.Configuration
      if #available(iOS 26.0, *) {
        configuration = .glass()
      } else {
        configuration = .gray()
        configuration.cornerStyle = .capsule
      }
      configuration.baseForegroundColor = .label
      return configuration
    }

    private func updateAddress() {
      if let url = webView.url {
        domainLabel.text =
          url.host.map { host in url.port.map { "\(host):\($0)" } ?? host } ?? url.absoluteString
      } else {
        domainLabel.text = nil
      }
      view.setNeedsLayout()
    }

    /// Places the address for `collapseProgress`, centered between back and close, or across
    /// the bottom beside Cancel while editing, every part moving in step: the capsule narrows to
    /// the domain, the domain shrinks, and back, close and reload fade.
    private func updateAddressLayout() {
      let isEditing = addressField.isEditing
      let progress = isEditing ? 0 : collapseProgress
      func mix(_ expanded: CGFloat, _ collapsed: CGFloat) -> CGFloat {
        expanded + (collapsed - expanded) * progress
      }
      let width = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
      let besideButton = Self.margin + Self.addressHeight + Self.spacing
      let fullWidth = width - 2 * besideButton
      let domainMaximumWidth = max(0, fullWidth - 2 * (Self.reloadSize + 6))
      domainMaximumWidthConstraint?.update(offset: domainMaximumWidth)
      let collapsedWidth =
        min(domainLabel.intrinsicContentSize.width, domainMaximumWidth)
        * Self.collapsedDomainScale + 2 * Self.domainPadding
      let height = mix(Self.addressHeight, Self.collapsedAddressHeight)
      if isEditing {
        addressLeadingConstraint?.update(offset: Self.margin)
        addressWidthConstraint?.update(
          offset: width - 2 * Self.margin - Self.spacing
            - cancelButton.intrinsicContentSize.width)
      } else {
        let addressWidth = mix(fullWidth, collapsedWidth)
        addressLeadingConstraint?.update(offset: (width - addressWidth) / 2)
        addressWidthConstraint?.update(offset: addressWidth)
      }
      addressHeightConstraint?.update(offset: height)
      // Down toward the home indicator once collapsed.
      addressBottomConstraint?.update(offset: mix(-Self.spacing, Self.spacing))
      if #unavailable(iOS 26.0) {
        addressBarView.layer.cornerRadius = height / 2
      }
      let domainScale = mix(1, Self.collapsedDomainScale)
      domainLabel.transform = CGAffineTransform(scaleX: domainScale, y: domainScale)
      domainLabel.alpha = isEditing ? 0 : 1
      addressField.alpha = isEditing ? 1 : 0
      // Back, close and reload are gone by halfway.
      let controlsAlpha = isEditing ? 0 : max(0, 1 - 2 * progress)
      reloadButton.alpha = controlsAlpha
      backButton.alpha = controlsAlpha
      closeButton.alpha = controlsAlpha
      let buttonScale = mix(1, 0.5)
      backButton.transform = CGAffineTransform(scaleX: buttonScale, y: buttonScale)
      closeButton.transform = backButton.transform
      cancelButton.alpha = isEditing ? 1 : 0
    }

    private func setCollapseProgress(_ progress: CGFloat, animated: Bool = false) {
      guard progress != collapseProgress, !addressField.isEditing else { return }
      collapseProgress = progress
      guard animated else {
        updateAddressLayout()
        view.layoutIfNeeded()
        return
      }
      UIView.animate(
        withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.updateAddressLayout()
        self.view.layoutIfNeeded()
      }
    }

    /// Animates the editing layout in or out with the keyboard.
    private func animateEditingLayout() {
      UIView.animate(withDuration: 0.25) {
        self.updateAddressLayout()
        self.view.layoutIfNeeded()
      }
    }

    /// A tap on the domain alone brings the address back first, as in Safari.
    @objc private func didTapAddress() {
      if collapseProgress > 0 {
        setCollapseProgress(0, animated: true)
      } else {
        addressField.becomeFirstResponder()
      }
    }
  }

  extension BrowserViewController: UIScrollViewDelegate {
    // The address collapses as far as the person scrolls down, and comes back as far as they
    // scroll up, pull past the end, or reach the top.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      let offsetY = scrollView.contentOffset.y
      defer { lastContentOffsetY = offsetY }
      guard scrollView.isTracking || scrollView.isDecelerating else { return }
      let top = -scrollView.adjustedContentInset.top
      guard offsetY > top else {
        setCollapseProgress(0)
        return
      }
      let end = max(
        top,
        scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
          - scrollView.bounds.height)
      var delta = offsetY - lastContentOffsetY
      if offsetY > end {
        delta = -abs(delta)
      }
      guard delta != 0 else { return }
      settlesCollapsed = delta > 0
      setCollapseProgress(min(max(collapseProgress + delta / Self.collapseDistance, 0), 1))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate {
        settleCollapse()
      }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      settleCollapse()
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
      setCollapseProgress(0, animated: true)
    }

    /// Finishes a collapse the person stopped scrolling in the middle of.
    private func settleCollapse() {
      guard collapseProgress > 0, collapseProgress < 1 else { return }
      setCollapseProgress(settlesCollapsed ? 1 : 0, animated: true)
    }
  }

  extension BrowserViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
      collapseProgress = 0
      textField.text = webView.url?.absoluteString
      textField.selectAll(nil)
      addressAboveKeyboardConstraint?.activate()
      animateEditingLayout()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
      addressAboveKeyboardConstraint?.deactivate()
      animateEditingLayout()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      if let url = UnifiedBrowserWindowWorkflow.url(forAddress: textField.text ?? "") {
        webView.load(URLRequest(url: url))
      }
      textField.resignFirstResponder()
      return true
    }
  }
#endif
