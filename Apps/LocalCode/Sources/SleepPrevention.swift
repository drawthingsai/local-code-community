import Foundation
import UIKit

/// How much the device stays awake while agents work or models download. Persisted by raw value.
enum SleepPrevention: Int {
  case disabled = 0
  case system = 1
  case systemAndDisplay = 2

  #if targetEnvironment(macCatalyst)
    static let `default` = Self.system
    static let options: [Self] = [.disabled, .system, .systemAndDisplay]
  #else
    // iOS suspends the app once the screen locks, so staying awake means keeping the screen on.
    static let `default` = Self.systemAndDisplay
    static let options: [Self] = [.disabled, .systemAndDisplay]
  #endif

  /// Keeps the device awake until the returned assertion is released, or returns nil when
  /// disabled. Each owner holds its own assertion, so one releasing never ends another's.
  func assertion(reason: String) -> Assertion? {
    guard self != .disabled else { return nil }
    return Assertion(self, reason: reason)
  }

  /// Main queue only.
  final class Assertion {
    #if targetEnvironment(macCatalyst)
      private let activity: NSObjectProtocol
    #else
      // UIApplication has a single idle timer flag, so count its holders.
      private static var count = 0
    #endif

    fileprivate init(_ prevention: SleepPrevention, reason: String) {
      dispatchPrecondition(condition: .onQueue(.main))
      #if targetEnvironment(macCatalyst)
        // UIApplication.isIdleTimerDisabled creates no power assertion on Mac. `.userInitiated`
        // already prevents idle system sleep.
        activity = ProcessInfo.processInfo.beginActivity(
          options: prevention == .systemAndDisplay
            ? [.userInitiated, .idleDisplaySleepDisabled] : .userInitiated,
          reason: reason)
      #else
        Self.count += 1
        UIApplication.shared.isIdleTimerDisabled = true
      #endif
    }

    deinit {
      dispatchPrecondition(condition: .onQueue(.main))
      #if targetEnvironment(macCatalyst)
        ProcessInfo.processInfo.endActivity(activity)
      #else
        Self.count -= 1
        if Self.count == 0 {
          UIApplication.shared.isIdleTimerDisabled = false
        }
      #endif
    }
  }
}
