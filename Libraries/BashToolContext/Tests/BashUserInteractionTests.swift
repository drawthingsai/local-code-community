import XCTest

final class BashUserInteractionTests: XCTestCase {
  func testOngoingAndCompletedInteractionPreserveRemainingBudget() {
    var time: TimeInterval = 100
    let interaction = BashUserInteraction(time: { time })
    let start = time
    time += 12
    let request = interaction.begin(isUserInteraction: true)
    time += 300
    XCTAssertEqual(time - start - interaction.systemInteractionInterval(since: start), 12)
    XCTAssertTrue(interaction.cancel(request))
    time += 8
    let elapsed = time - start - interaction.systemInteractionInterval(since: start)
    XCTAssertEqual(elapsed, 20)
    XCTAssertEqual(60 - elapsed, 40)
  }

  func testSinceClipsIntervalsAndExcludesEarlierInteractions() {
    var time: TimeInterval = 10
    let interaction = BashUserInteraction(time: { time })
    let first = interaction.begin(isUserInteraction: true)
    time = 20
    interaction.cancel(first)
    time = 30
    let second = interaction.begin(isUserInteraction: true)
    time = 40
    XCTAssertEqual(interaction.userInteractionInterval(since: 0), 20)
    XCTAssertEqual(interaction.userInteractionInterval(since: 15), 15)
    XCTAssertEqual(interaction.userInteractionInterval(since: 25), 10)
    XCTAssertEqual(interaction.userInteractionInterval(since: 35), 5)
    XCTAssertEqual(interaction.userInteractionInterval(since: 45), 0)
    time = 50
    interaction.cancel(second)
    time = 60
    XCTAssertEqual(interaction.userInteractionInterval(since: 15), 25)
    XCTAssertEqual(interaction.userInteractionInterval(since: 25), 20)
    XCTAssertEqual(interaction.userInteractionInterval(since: 35), 15)
    XCTAssertEqual(interaction.userInteractionInterval(since: 50), 0)
  }

  func testSystemIntervalIncludesUserTimeWhileSystemWorkDoesNotPauseWorkingTime() {
    var time: TimeInterval = 10
    let interaction = BashUserInteraction(time: { time })
    let user = interaction.begin(isUserInteraction: true)
    time = 20
    XCTAssertEqual(interaction.userInteractionInterval(since: 0), 10)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 0), 10)
    interaction.cancel(user)
    time = 30
    let system = interaction.begin(isUserInteraction: false)
    time = 50
    XCTAssertEqual(interaction.userInteractionInterval(since: 0), 10)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 0), 30)
    XCTAssertEqual(interaction.userInteractionInterval(since: 15), 5)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 15), 25)
    XCTAssertEqual(interaction.userInteractionInterval(since: 35), 0)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 35), 15)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 60), 0)
    interaction.cancel(system)
    time = 70
    XCTAssertEqual(interaction.userInteractionInterval(since: 0), 10)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 0), 30)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 55), 0)
    let nextUser = interaction.begin(isUserInteraction: true)
    time = 80
    interaction.cancel(nextUser)
    XCTAssertEqual(interaction.userInteractionInterval(since: 0), 20)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 0), 40)
    XCTAssertEqual(interaction.userInteractionInterval(since: 65), 10)
    XCTAssertEqual(interaction.systemInteractionInterval(since: 65), 10)
  }

  func testRepeatedAndInvalidCancellationDoesNotCloseAnotherRequest() {
    var time: TimeInterval = 10
    let interaction = BashUserInteraction(time: { time })
    let first = interaction.begin(isUserInteraction: true)
    time = 20
    XCTAssertTrue(interaction.cancel(first))
    time = 30
    let second = interaction.begin(isUserInteraction: true)
    XCTAssertNotEqual(first, second)
    XCTAssertFalse(interaction.cancel(first))
    XCTAssertFalse(interaction.cancel(-1))
    XCTAssertFalse(interaction.cancel(Int64.max))
    time = 40
    XCTAssertEqual(interaction.userInteractionInterval(since: 30), 10)
    XCTAssertTrue(interaction.cancel(second))
    time = 50
    XCTAssertEqual(interaction.userInteractionInterval(since: 30), 10)
  }

  func testNewTurnHasIndependentIntervals() {
    var time: TimeInterval = 10
    let firstTurn = BashUserInteraction(time: { time })
    let request = firstTurn.begin(isUserInteraction: true)
    time = 20
    firstTurn.cancel(request)
    let secondTurn = BashUserInteraction(time: { time })
    let secondRequest = secondTurn.begin(isUserInteraction: true)
    time = 30
    XCTAssertEqual(firstTurn.userInteractionInterval(since: 0), 10)
    XCTAssertEqual(secondTurn.userInteractionInterval(since: 20), 10)
    secondTurn.cancel(secondRequest)
    XCTAssertEqual(secondTurn.userInteractionInterval(since: 0), 10)
  }
}
