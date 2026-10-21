import BazelTestObservation
import Darwin
import XCTest

@main
enum CLIParityTestMain {
  static func main() {
    let succeeded: Bool
    do {
      try loadTestingLibraries()
      try XCTestRunner.run(())
      try XUnitTestRecorder.shared.writeXML()
      succeeded = XUnitTestRecorder.shared.testCount > 0 && !XUnitTestRecorder.shared.hasFailure
    } catch {
      print("Could not run CLI parity tests: \(error)")
      succeeded = false
    }
    fflush(nil)
    // ios_system interposes exit() and _exit() to terminate a shell thread.
    // _Exit terminates the test process with the actual XCTest result.
    _Exit(succeeded ? 0 : 1)
  }
}
