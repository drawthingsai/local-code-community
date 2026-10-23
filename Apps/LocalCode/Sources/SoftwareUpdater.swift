#if targetEnvironment(macCatalyst) && DIRECT_DISTRIBUTION
  import Foundation

  /// The part of Sparkle's `SPUStandardUpdaterController` that the app calls. The Catalyst binary
  /// cannot link the AppKit-only Sparkle.framework, so the release script embeds it in Developer
  /// ID builds and the app reaches it through the Objective-C runtime.
  @objc private protocol StandardUpdaterController {
    init(updaterDelegate: AnyObject?, userDriverDelegate: AnyObject?)
    func checkForUpdates(_ sender: Any?)
  }

  final class SoftwareUpdater {
    private let controller: StandardUpdaterController

    /// Starts Sparkle, or returns nil when Sparkle.framework is not in the bundle, as in a plain
    /// Bazel build that has not gone through the release script.
    init?() {
      guard
        let frameworkURL = Bundle.main.privateFrameworksURL?.appendingPathComponent(
          "Sparkle.framework"), FileManager.default.fileExists(atPath: frameworkURL.path),
        let framework = Bundle(url: frameworkURL)
      else { return nil }
      do {
        try framework.loadAndReturnError()
      } catch {
        print("Unable to load Sparkle: \(error)")
        return nil
      }
      guard let controllerClass = NSClassFromString("SPUStandardUpdaterController") else {
        return nil
      }
      controller = unsafeBitCast(controllerClass, to: StandardUpdaterController.Type.self).init(
        updaterDelegate: nil, userDriverDelegate: nil)
    }

    var canCheckForUpdates: Bool {
      (controller as? NSObject)?.value(forKeyPath: "updater.canCheckForUpdates") as? Bool ?? false
    }

    func checkForUpdates() {
      controller.checkForUpdates(nil)
    }
  }
#endif
