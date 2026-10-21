import ExceptionCatcher
import SQLiteDflat
import Style
import UIKit
import UserAccount
import UserNotifications

protocol Workflow: AnyObject {
  var viewControllable: UIViewController { get }
  func applicationWillTerminate()
  func sceneDidBecomeActive()
  func handle(url: URL) -> Bool
  func handle(notificationResponse: UNNotificationResponse)
  func notificationPresentationOptions(for notification: UNNotification)
    -> UNNotificationPresentationOptions
}

extension Workflow {
  func applicationWillTerminate() {}
  func sceneDidBecomeActive() {}
  func handle(url: URL) -> Bool { false }
  func handle(notificationResponse: UNNotificationResponse) {}
  func notificationPresentationOptions(for notification: UNNotification)
    -> UNNotificationPresentationOptions
  { [] }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  /// The chat window. Its workflow owns the app's workspace, so there is only one, even though
  /// browser windows make the app support multiple scenes.
  private static weak var current: SceneDelegate?
  var workflow: Workflow? = nil
  var window: UIWindow? = nil
  private var isTerminated = false
  #if targetEnvironment(macCatalyst)
    private var windowBackgroundView: NSObject?
  #endif

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    if let current = Self.current, current !== self {
      UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
      return
    }
    Self.current = self

    let window = KeyboardShortcutWindow(windowScene: windowScene)
    let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    var applicationSupportURL = urls.first!
    #if LOCALCODE_CATALYST_ASAN
      // Keep the diagnostics build away from the shipping app's Dflat database. Debug Dflat
      // deliberately asserts when a persisted dictionary key was written with an older type.
      applicationSupportURL = applicationSupportURL.appendingPathComponent(
        "LocalCodeCatalystASan", isDirectory: true)
    #endif
    try? FileManager.default.createDirectory(
      at: applicationSupportURL, withIntermediateDirectories: true)
    let configURL = applicationSupportURL.appendingPathComponent("config.sqlite3")
    let workspace = SQLiteWorkspace(filePath: configURL.path, fileProtectionLevel: .noProtection)
    ProductsManager.shared.configure()
    let accountManager = AccountManager(workspace: workspace, product: .localCode)
    let accountClient = AccountClient(baseURL: AccountRouterConfiguration.baseURL)
    let workflow = ChatWorkflow(
      userInterfaceIdiom: UIDevice.current.userInterfaceIdiom, workspace: workspace,
      accountManager: accountManager, accountClient: accountClient)
    window.shortcutActionHandler = { [weak workflow] action in
      workflow?.handleKeyboardShortcut(action)
    }
    window.rootViewController = workflow.viewControllable
    self.window = window
    self.workflow = workflow
    #if targetEnvironment(macCatalyst)
      if #available(macCatalyst 26, *) {
        window.backgroundColor = .primaryBackground
        workflow.viewControllable.view.backgroundColor = .clear
        workflow.viewControllable.view.isOpaque = false
      }
    #endif
    window.makeKeyAndVisible()
    if let response = connectionOptions.notificationResponse {
      workflow.handle(notificationResponse: response)
    }
    workflow.sceneDidBecomeActive()
    for context in connectionOptions.urlContexts {
      if workflow.handle(url: context.url) { break }
    }
    for activity in connectionOptions.userActivities
    where
      activity.activityType == NSUserActivityTypeBrowsingWeb
    {
      if let url = activity.webpageURL, workflow.handle(url: url) { break }
    }

    #if targetEnvironment(macCatalyst)
      windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1024, height: 640)
      if let titlebar = windowScene.titlebar {
        titlebar.titleVisibility = .hidden
        titlebar.toolbar = nil
      }
      // Use the explicit movable title-bar views instead of making the whole native title bar drag.
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
        self?.setWindowVisualEffectAndMovable(false)
      }
    #endif
  }

  func setWindowVisualEffectAndMovable(_ movable: Bool) {
    guard let window, let nsWindow = nsWindow(from: window) as? NSObject else { return }
    try? ExceptionCatcher.catch {
      nsWindow.setValue(movable, forKey: "movable")
    }
    #if targetEnvironment(macCatalyst)
      if #available(macCatalyst 26, *),
        setWindowVisualEffect(in: nsWindow)
      {
        // Reuse the existing periodic native-window update once Catalyst's host is ready.
        window.backgroundColor = .clear
        window.isOpaque = false
      }
    #endif
  }

  #if targetEnvironment(macCatalyst)
    private func setWindowVisualEffect(in nativeWindow: NSObject) -> Bool {
      return
        (try? ExceptionCatcher.catch { () -> Bool in
          guard
            let contentView = nativeWindow.value(forKey: "contentView") as? NSObject,
            let containerView = contentView.value(forKey: "superview") as? NSObject,
            let contentFrame = contentView.value(forKey: "frame") as? NSValue,
            let effectClass = NSClassFromString("NSVisualEffectView") as? NSObject.Type
          else { return false }

          if let windowBackgroundView {
            if windowBackgroundView.value(forKey: "superview") as? NSObject === containerView {
              windowBackgroundView.setValue(contentFrame, forKey: "frame")
              return true
            }
          }

          let effect: NSObject
          if let windowBackgroundView {
            effect = windowBackgroundView
          } else {
            effect = effectClass.init()
            // AppKit enum values: .sidebar, .behindWindow, .followsWindowActiveState.
            effect.setValue(7, forKey: "material")
            effect.setValue(0, forKey: "blendingMode")
            effect.setValue(0, forKey: "state")
            // NSView.AutoresizingMask: width + height, tracking the full native window.
            effect.setValue(18, forKey: "autoresizingMask")
          }
          effect.setValue(contentFrame, forKey: "frame")

          let addSubview = NSSelectorFromString("addSubview:positioned:relativeTo:")
          guard containerView.responds(to: addSubview) else { return false }
          typealias AddSubview =
            @convention(c) (AnyObject, Selector, AnyObject, Int, AnyObject?) -> Void
          let insert = unsafeBitCast(containerView.method(for: addSubview), to: AddSubview.self)
          // The window owns the material below its UIKit host; existing UIKit backgrounds tint it.
          // Reinsert the same effect if Catalyst replaces its container.
          insert(containerView, addSubview, effect, -1, contentView)
          windowBackgroundView = effect
          return true
        }) ?? false
    }
  #endif

  private func nsWindow(from window: UIWindow) -> AnyObject? {
    #if targetEnvironment(macCatalyst)
      return try? ExceptionCatcher.catch {
        guard
          let nsWindows = NSClassFromString("NSApplication")?.value(
            forKeyPath: "sharedApplication.windows") as? [NSObject]
        else { return nil }
        for nsWindow in nsWindows {
          // Plain AppKit windows, browser rim glows among them, throw when asked for UIKit
          // windows.
          guard nsWindow.responds(to: NSSelectorFromString("uiWindows")) else { continue }
          let uiWindows = nsWindow.value(forKeyPath: "uiWindows") as? [UIWindow] ?? []
          if uiWindows.contains(window) { return nsWindow }
        }
        return nil
      }
    #else
      return nil
    #endif
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    workflow?.sceneDidBecomeActive()
  }

  #if targetEnvironment(macCatalyst)
    func sceneDidDisconnect(_ scene: UIScene) {
      // Supporting multiple scenes keeps the app running after its last window closes, or with
      // only browser windows left. Closing the chat window quits instead, as Quit does.
      guard Self.current === self, !isTerminated else { return }
      applicationWillTerminate()
      (NSClassFromString("NSApplication")?.value(forKey: "sharedApplication") as? NSObject)?
        .perform(NSSelectorFromString("terminate:"), with: nil)
    }
  #endif

  /// Tells the workflow once: on Mac, closing the chat window gets here before Quit does.
  func applicationWillTerminate() {
    guard !isTerminated else { return }
    isTerminated = true
    workflow?.applicationWillTerminate()
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      if workflow?.handle(url: context.url) == true { return }
    }
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else { return }
    _ = workflow?.handle(url: url)
  }
}
