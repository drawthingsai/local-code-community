import Foundation
import QuartzCore

/// Records non-overlapping user and system interactions within one agent turn.
public final class BashUserInteraction: Equatable {
  public typealias Request = Int64

  private let lock = NSLock()
  private let time: () -> TimeInterval
  private var intervals = [(begin: TimeInterval, end: TimeInterval?, isUserInteraction: Bool)]()

  public init(time: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
    self.time = time
  }

  public func begin(isUserInteraction: Bool) -> Request {
    lock.lock()
    defer { lock.unlock() }
    precondition(intervals.isEmpty || intervals.last?.end != nil)
    let request = Request(intervals.count)
    intervals.append((begin: time(), end: nil, isUserInteraction: isUserInteraction))
    return request
  }

  /// Closes an interaction after completion, cancellation, or failure.
  /// Returns false if the request has already ended or does not exist.
  @discardableResult public func cancel(_ request: Request) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard request >= 0, request < Int64(intervals.count),
      intervals[Int(request)].end == nil
    else { return false }
    intervals[Int(request)].end = time()
    return true
  }

  /// Time waiting for the user, excluded from the turn's working duration.
  public func userInteractionInterval(since startTime: TimeInterval) -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    let now = time()
    return intervals.reduce(0) { duration, interval in
      guard interval.isUserInteraction else { return duration }
      return duration + max(0, (interval.end ?? now) - max(interval.begin, startTime))
    }
  }

  /// All interaction time, including user interactions, excluded from Bash timeouts and waits.
  public func systemInteractionInterval(since startTime: TimeInterval) -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    let now = time()
    return intervals.reduce(0) { duration, interval in
      duration + max(0, (interval.end ?? now) - max(interval.begin, startTime))
    }
  }

  public static func == (lhs: BashUserInteraction, rhs: BashUserInteraction) -> Bool {
    lhs === rhs
  }
}
