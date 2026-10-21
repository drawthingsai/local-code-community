import ExceptionCatcher
import Foundation
import XCTest

final class Fixture: NSObject {}

final class ExceptionCatcherTests: XCTestCase {
  func testCatch() throws {
    XCTAssertThrowsError(
      try ExceptionCatcher.catch {
        let fixture = Fixture()
        fixture.value(forKey: "nope")
      }
    )

    let fixtureString = "🦄"
    let result = try ExceptionCatcher.catch { fixtureString }
    XCTAssertEqual(result, fixtureString)
  }
}
