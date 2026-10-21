import UIKit

/// The URLs the app hands to the system: web pages, mail, and files. Agents run scripts that can
/// message UIKit directly, and other schemes install apps (itms-services:) or run other apps'
/// actions (shortcuts:, app links), so `Application` and `WindowScene` refuse them.
enum ExternalURLPolicy {
  static func allows(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return ["http", "https", "mailto", "file"].contains(scheme)
  }
}

/// Opens only URLs that `ExternalURLPolicy` allows.
final class Application: UIApplication {
  override func open(
    _ url: URL, options: [UIApplication.OpenExternalURLOptionsKey: Any] = [:],
    completionHandler completion: (@MainActor @Sendable (Bool) -> Void)? = nil
  ) {
    guard ExternalURLPolicy.allows(url) else {
      // UIKit calls the completion handler on the main queue, after open returns.
      DispatchQueue.main.async { completion?(false) }
      return
    }
    super.open(url, options: options, completionHandler: completion)
  }

  // Deprecated, but still opens URLs before iOS 18.
  @available(iOS, deprecated: 10.0)
  override func openURL(_ url: URL) -> Bool {
    ExternalURLPolicy.allows(url) && super.openURL(url)
  }
}

/// Opens only URLs that `ExternalURLPolicy` allows; a scene opens URLs without going through
/// `Application`.
final class WindowScene: UIWindowScene {
  override func open(
    _ url: URL, options: UIScene.OpenExternalURLOptions?,
    completionHandler completion: ((Bool) -> Void)? = nil
  ) {
    guard ExternalURLPolicy.allows(url) else {
      DispatchQueue.main.async { completion?(false) }
      return
    }
    super.open(url, options: options, completionHandler: completion)
  }
}
