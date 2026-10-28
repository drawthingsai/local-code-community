import ArgumentParser
import Darwin
import Dispatch
import Foundation
import LocalCodeCLI
import NNC

// ios_system interposes exit(), so terminate with _Exit after saving the run.
@_cdecl("main")
func localCodeCLIMain(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  // Outside an agent run, which handles SIGINT and SIGTERM itself, a kill takes the default
  // action. Abort first: GPU work can be waiting on CPU threads that die with the process.
  for number in [SIGINT, SIGTERM, SIGHUP] {
    signal(number) { number in
      DynamicGraph.abort()
      signal(number, SIG_DFL)
      raise(number)
    }
  }
  let arguments = (1..<Int(argc)).compactMap { index in
    argv?[index].map { String(cString: $0) }
  }
  let status: Int32
  do {
    var command = try LocalCodeCLI.parseAsRoot(arguments)
    let result = CLIProcessResult()
    Task {
      do {
        if var asyncCommand = command as? AsyncParsableCommand {
          try await asyncCommand.run()
        } else {
          try command.run()
        }
      } catch {
        result.error = error
      }
      result.semaphore.signal()
    }
    // Browser-backed web search needs the main run loop, including its timeout
    // callbacks. Both synchronous local agents and asynchronous remote agents
    // run off the main thread while their tools are in flight.
    while result.semaphore.wait(timeout: .now() + 0.01) != .success {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    if let error = result.error {
      throw error
    }
    status = 0
  } catch {
    let message = LocalCodeCLI.fullMessage(for: error)
    let exitCode = LocalCodeCLI.exitCode(for: error)
    if !message.isEmpty {
      let output =
        exitCode.rawValue == 0 ? FileHandle.standardOutput : FileHandle.standardError
      output.write(Data("\(message)\n".utf8))
    }
    status = exitCode.rawValue
  }
  // Embedded jobs can still be unwinding after cancellation or a background
  // tool turn. Normal exit destroys shared C++ runtime state under those threads.
  // Results are already persisted; flush the CLI streams before process teardown.
  fflush(stdout)
  fflush(stderr)
  // Same for work still in flight here: _Exit kills the CPU threads it may be waiting on.
  DynamicGraph.abort()
  _Exit(status)
}

private final class CLIProcessResult: @unchecked Sendable {
  let semaphore = DispatchSemaphore(value: 0)
  var error: Error?
}
