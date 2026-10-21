import BazelTestObservation
import Darwin
import XCTest

@main
enum AppleUtilitiesTestMain {
  static func main() {
    let succeeded: Bool
    do {
      try loadTestingLibraries()
      try XCTestRunner.run(())
      try XUnitTestRecorder.shared.writeXML()
      succeeded = XUnitTestRecorder.shared.testCount > 0 && !XUnitTestRecorder.shared.hasFailure
    } catch {
      print("Could not run AppleUtilities tests: \(error)")
      succeeded = false
    }
    fflush(nil)
    // Like BashUserInteractionTests, bypass ios_system's shell-thread exit() override.
    _Exit(succeeded ? 0 : 1)
  }
}
