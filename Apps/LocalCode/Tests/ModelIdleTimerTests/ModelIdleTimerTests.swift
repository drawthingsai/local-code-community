import Dispatch
import XCTest

final class ModelIdleTimerTests: XCTestCase {
  func testUnloadOnceUntilNextActivity() {
    let unloaded = expectation(description: "unloaded")
    var count = 0
    let timer = ModelIdleTimer(interval: 0.02) { request in
      XCTAssertTrue(request.begin())
      count += 1
      unloaded.fulfill()
    }
    timer.setIdle(true)
    // Repeated state notifications must neither restart the countdown nor unload twice.
    timer.setIdle(true)
    wait(for: [unloaded], timeout: 2)
    timer.interval = 0.01
    timer.setIdle(true)
    drainMainQueue(for: 0.08)
    XCTAssertEqual(count, 1)
  }

  func testActivityCancelsCountdownAndCompletionStartsAnother() {
    let unloaded = expectation(description: "unloaded after activity")
    var count = 0
    let timer = ModelIdleTimer(interval: 0.02) { request in
      XCTAssertTrue(request.begin())
      count += 1
      unloaded.fulfill()
    }
    timer.setIdle(true)
    timer.setIdle(false)
    drainMainQueue(for: 0.08)
    XCTAssertEqual(count, 0)
    timer.setIdle(true)
    wait(for: [unloaded], timeout: 2)
    XCTAssertEqual(count, 1)
  }

  func testNeverCancelsPendingUnloadAndRetainsIdleStart() {
    let unloaded = expectation(description: "unloaded after enabling")
    var count = 0
    let timer = ModelIdleTimer(interval: 0.02) { request in
      XCTAssertTrue(request.begin())
      count += 1
      unloaded.fulfill()
    }
    timer.setIdle(true)
    timer.interval = nil
    drainMainQueue(for: 0.08)
    XCTAssertEqual(count, 0)
    timer.interval = 0.01
    // The original idle deadline has passed, so unloading is enqueued immediately.
    let deadlineChecked = expectation(description: "deadline checked")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
      XCTAssertEqual(count, 1)
      deadlineChecked.fulfill()
    }
    wait(for: [unloaded, deadlineChecked], timeout: 2)
  }

  func testIncreasingTimeoutCancelsOldDeadline() {
    let unloaded = expectation(description: "unloaded at new deadline")
    var count = 0
    let timer = ModelIdleTimer(interval: 0.02) { request in
      XCTAssertTrue(request.begin())
      count += 1
      unloaded.fulfill()
    }
    timer.setIdle(true)
    timer.interval = 0.3
    drainMainQueue(for: 0.08)
    XCTAssertEqual(count, 0)
    wait(for: [unloaded], timeout: 2)
  }

  func testWarmupOrTurnAfterUnloadingCanUnloadAgain() {
    var count = 0
    let first = expectation(description: "first idle")
    let second = expectation(description: "second idle")
    let timer = ModelIdleTimer(interval: 0.02) { request in
      XCTAssertTrue(request.begin())
      count += 1
      if count == 1 { first.fulfill() } else { second.fulfill() }
    }
    timer.setIdle(true)
    wait(for: [first], timeout: 2)
    timer.setIdle(false)
    timer.setIdle(true)
    wait(for: [second], timeout: 2)
    XCTAssertEqual(count, 2)
  }

  func testNeverCancelsUnloadAlreadyQueuedForGeneration() {
    checkQueuedUnloadCancellation(replacementInterval: nil)
  }

  func testIncreasingTimeoutCancelsQueuedUnloadAndSchedulesReplacement() {
    checkQueuedUnloadCancellation(replacementInterval: 0.3)
  }

  func testActivityCancelsRequestAfterTimerFires() {
    let queued = expectation(description: "unload request queued")
    var request: ModelIdleTimer.UnloadRequest?
    let timer = ModelIdleTimer(interval: 0.01) {
      request = $0
      queued.fulfill()
    }
    timer.setIdle(true)
    wait(for: [queued], timeout: 2)
    timer.setIdle(false)
    XCTAssertEqual(request?.begin(), false)
  }

  private func checkQueuedUnloadCancellation(replacementInterval: TimeInterval?) {
    let queue = DispatchQueue(label: "model-idle-timer-test.generate")
    queue.suspend()
    let queued = expectation(description: "first request queued")
    let cancelled = expectation(description: "queued request cancelled")
    let replacement = expectation(description: "replacement unload")
    replacement.isInverted = replacementInterval == nil
    var requestCount = 0
    let timer = ModelIdleTimer(interval: 0.01) { request in
      requestCount += 1
      let isFirst = requestCount == 1
      queue.async {
        let didBegin = request.begin()
        DispatchQueue.main.async {
          if isFirst {
            XCTAssertFalse(didBegin, "A stale queued request must not unload models")
            cancelled.fulfill()
          } else {
            XCTAssertTrue(didBegin)
            replacement.fulfill()
          }
        }
      }
      if isFirst { queued.fulfill() }
    }
    timer.setIdle(true)
    wait(for: [queued], timeout: 2)
    // The timer has fired, but cleanup cannot begin until the generation queue is resumed.
    timer.interval = replacementInterval
    queue.resume()
    wait(for: [cancelled], timeout: 2)
    wait(for: [replacement], timeout: replacementInterval == nil ? 0.08 : 2)
    withExtendedLifetime(timer) {}
  }

  private func drainMainQueue(for interval: TimeInterval) {
    let drained = expectation(description: "main queue drained")
    DispatchQueue.main.asyncAfter(deadline: .now() + interval) { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }
}
