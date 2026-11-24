import Dispatch
import Foundation
import os.lock

enum ModelIdleTimeout: Int, CaseIterable {
  case tenSeconds = 10
  case oneMinute = 60
  case fiveMinutes = 300
  case tenMinutes = 600
  case never = 0

  static let `default` = Self.fiveMinutes

  var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
}

/// Main-queue policy shared by warmup and all local turns. The owner handles model teardown.
final class ModelIdleTimer {
  /// Cancellation and starting cleanup can race across the main and generation queues.
  final class UnloadRequest {
    private enum State { case pending, started, cancelled }
    private var lock = os_unfair_lock()
    private var state = State.pending
    /// A memory warning asked for it, rather than the timeout.
    let isMemoryWarning: Bool

    init(isMemoryWarning: Bool) {
      self.isMemoryWarning = isMemoryWarning
    }

    func begin() -> Bool {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      guard state == .pending else { return false }
      state = .started
      return true
    }

    @discardableResult
    fileprivate func cancelIfPending() -> Bool {
      os_unfair_lock_lock(&lock)
      defer { os_unfair_lock_unlock(&lock) }
      guard state != .started else { return false }
      state = .cancelled
      return true
    }
  }

  private let unload: (UnloadRequest) -> Void
  private var idleSince: DispatchTime?
  private var unloadRequest: UnloadRequest?
  private var workItem: DispatchWorkItem?

  var interval: TimeInterval? {
    didSet {
      dispatchPrecondition(condition: .onQueue(.main))
      guard interval != oldValue else { return }
      schedule()
    }
  }

  init(interval: TimeInterval?, unload: @escaping (UnloadRequest) -> Void) {
    self.interval = interval
    self.unload = unload
  }

  deinit {
    workItem?.cancel()
    unloadRequest?.cancelIfPending()
  }

  func setIdle(_ isIdle: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    if isIdle {
      guard idleSince == nil else { return }
      idleSince = .now()
    } else {
      idleSince = nil
      unloadRequest?.cancelIfPending()
      unloadRequest = nil
    }
    schedule()
  }

  /// Unloads now if idle, whatever the timeout, as a memory warning asks. An unload already
  /// requested stands, and so does one already done until the next period of activity.
  func unloadIfIdle() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard idleSince != nil, unloadRequest == nil else { return }
    workItem?.cancel()
    workItem = nil
    let request = UnloadRequest(isMemoryWarning: true)
    unloadRequest = request
    unload(request)
  }

  private func schedule() {
    workItem?.cancel()
    workItem = nil
    // A setting change cancels even a request already handed to the generation queue. Once
    // cleanup has actually started, retain that state until the next period of activity.
    if let unloadRequest, !unloadRequest.cancelIfPending() { return }
    unloadRequest = nil
    guard let idleSince, let interval else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.workItem = nil
      let request = UnloadRequest(isMemoryWarning: false)
      self.unloadRequest = request
      self.unload(request)
    }
    self.workItem = workItem
    // Changing the setting uses time already spent idle, rather than restarting the countdown.
    DispatchQueue.main.asyncAfter(deadline: idleSince + interval, execute: workItem)
  }
}
