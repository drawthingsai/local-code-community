import AppleUtilities
import BashToolContext
import HTML2VideoCommand
import HyperFramesCommand
import Localization
import NNC
import UIKit
import UserNotifications
import ios_system

#if canImport(DrawThingsCLICommand)
  import DrawThingsCLICommand
#endif

#if canImport(LeanCommand)
  import LeanCommand
#endif
#if canImport(Z3Command)
  import Z3Command
#endif

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  static func main() {
    _ = UIApplicationMain(
      CommandLine.argc, CommandLine.unsafeArgv, NSStringFromClass(Application.self),
      NSStringFromClass(AppDelegate.self))
  }

  var workflow: Workflow? { sceneDelegate?.workflow }

  #if targetEnvironment(macCatalyst) && DIRECT_DISTRIBUTION
    private var softwareUpdater: SoftwareUpdater?
  #endif

  /// The chat window's. Browser windows are scenes too; the chat's is the one with a
  /// SceneDelegate.
  private var sceneDelegate: SceneDelegate? {
    return UIApplication.shared.connectedScenes.lazy.compactMap {
      $0.delegate as? SceneDelegate
    }.first
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    numPythonInterpreters = 1
    if let preloadURL = Bundle.main.url(
      forResource: "virtual-node-child-preload", withExtension: "cjs",
      subdirectory: "NodeMobile/Runtime")
    {
      preloadURL.withUnsafeFileSystemRepresentation { path in
        if let path {
          setenv("NODE_MOBILE_VIRTUAL_NODE_PRELOAD", path, 1)
        }
      }
    }
    if let libraryURL = FileManager.default.urls(
      for: .libraryDirectory, in: .userDomainMask
    ).first {
      do {
        let commands = try NodeMobileCommandResources.prepare(in: libraryURL)
        if ios_setNodeCommandPaths(commands.npm.path, commands.npx.path) == 0 {
          print("Unable to configure bundled npm and npx command paths.")
        }
      } catch {
        print("Unable to prepare bundled npm and npx commands: %@", error.localizedDescription)
      }
    }
    initializeEnvironment()
    if ios_registerCommand("hyperframes", hyperframes_main) == 0 {
      print("Unable to register the HyperFrames command.")
    }
    if ios_registerCommand("html2video", html2video_main) == 0 {
      print("Unable to register the html2video command.")
    }
    if ios_registerCommand("permit", permit_main) == 0 {
      print("Unable to register the permit command.")
    }
    if ios_registerCommand("web-browse-cli", web_browse_main) == 0 {
      print("Unable to register the browser command.")
    }
    if ios_registerCommand("calendar", calendar_main) == 0 {
      print("Unable to register the calendar command.")
    }
    if ios_registerCommand("imessage", imessage_main) == 0 {
      print("Unable to register the imessage command.")
    }
    if ios_registerCommand("mail", mail_main) == 0 {
      print("Unable to register the mail command.")
    }
    if ios_registerCommand("notes", notes_main) == 0 {
      print("Unable to register the notes command.")
    }
    if ios_registerCommand("photos", photos_main) == 0 {
      print("Unable to register the photos command.")
    }
    #if canImport(DrawThingsCLICommand)
      if ios_registerCommand("draw-things-cli", draw_things_main) == 0 {
        print("Unable to register the Draw Things CLI command.")
      }
    #endif
    #if canImport(Z3Command)
      if ios_registerCommand("z3", z3_main) == 0 {
        print("Unable to register the Z3 command.")
      }
    #endif
    #if canImport(LeanCommand)
      if ios_registerCommand("lean", lean_main) == 0
        || ios_registerCommand("check_lean", check_lean_main) == 0
      {
        print("Unable to register the Lean commands.")
      }
    #endif
    #if targetEnvironment(macCatalyst)
      UnifiedBrowserWindowWorkflow.discardRestoredSessions(in: application)
      #if DIRECT_DISTRIBUTION
        softwareUpdater = SoftwareUpdater()
        // The main menu may already be built without "Check for updates...".
        UIMenuSystem.main.setNeedsRebuild()
      #endif
    #endif
    return true
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    DispatchQueue.main.async {
      completionHandler(self.workflow?.notificationPresentationOptions(for: notification) ?? [])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    DispatchQueue.main.async {
      // Cold-launch responses are also delivered in the scene connection options.
      self.workflow?.handle(notificationResponse: response)
      completionHandler()
    }
  }

  func applicationWillTerminate(_ application: UIApplication) {
    sceneDelegate?.applicationWillTerminate()
    // The process exits next. GPU work still in flight can be waiting on CPU threads that die with
    // it, which would keep the process from finishing exit and freeing its memory.
    DynamicGraph.abort()
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    workflow?.handle(url: url) ?? false
  }

  override func buildMenu(with builder: UIMenuBuilder) {
    guard UIDevice.current.userInterfaceIdiom != .phone else { return }
    // Browser windows need multiple scenes, but there is one chat window.
    builder.remove(menu: .newScene)
    ChatViewControllerForiPad.buildMainMenu(
      with: builder,
      isBotModeEnabled: (workflow as? ChatWorkflow)?.workspace.dictionary["bot_mode", Bool.self]
        == true)
    #if targetEnvironment(macCatalyst) && DIRECT_DISTRIBUTION
      if softwareUpdater != nil {
        builder.insertSibling(
          UIMenu(
            title: "", options: .displayInline,
            children: [
              UICommand(
                title: LocalizedString.forKey("check_for_updates_dot"),
                action: #selector(checkForUpdatesAction(_:)))
            ]), afterMenu: .about)
      }
    #endif
  }

  #if targetEnvironment(macCatalyst) && DIRECT_DISTRIBUTION
    @objc private func checkForUpdatesAction(_ sender: UICommand) {
      softwareUpdater?.checkForUpdates()
    }

    override func validate(_ command: UICommand) {
      super.validate(command)
      if command.action == #selector(checkForUpdatesAction(_:)) {
        command.attributes = softwareUpdater?.canCheckForUpdates == true ? [] : .disabled
      }
    }
  #endif

  func application(
    _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    #if targetEnvironment(macCatalyst)
      if let configuration = UnifiedBrowserWindowWorkflow.sceneConfiguration(
        for: connectingSceneSession, options: options)
      {
        return configuration
      }
    #endif
    let configuration = UISceneConfiguration(
      name: "Default Configuration", sessionRole: connectingSceneSession.role)
    configuration.sceneClass = WindowScene.self
    return configuration
  }

  func application(
    _ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>
  ) {
  }
}
