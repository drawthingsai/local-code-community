import Combine
import Foundation

/// What the agents are doing, across every scheduler: reading while they take in a prompt, a
/// compaction or tool output, thinking while they generate. The Dock tile shows it.
enum AgentActivity: Int, Comparable {
  case idle
  case reading
  case thinking

  static func < (lhs: AgentActivity, rhs: AgentActivity) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// The busiest activity of any scheduler: thinking over reading over idle. Each change sends the
  /// whole value, from the thread that made it, so subscribers receive on their own queue.
  static let current = CurrentValueSubject<AgentActivity, Never>(.idle)
  private static var lock = os_unfair_lock()
  private static var activities = [ObjectIdentifier: AgentActivity]()

  /// Records what `scheduler` is doing now. Sends under the lock, so changes from different
  /// schedulers publish in order and the last value sent is current.
  static func set(_ activity: AgentActivity, for scheduler: ObjectIdentifier) {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    activities[scheduler] = activity == .idle ? nil : activity
    let combined = activities.values.max() ?? .idle
    if combined != current.value {
      current.send(combined)
    }
  }
}
