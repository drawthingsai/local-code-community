import AppKit
import Darwin
import Foundation
import HyperFramesCLILib

@main
struct Main {
  static func main() {
    var cancelled = false
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { cancelled = true }
      source.resume()
      return source
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let directory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    // WebKit needs a running main loop even for a command-line export.
    DispatchQueue.main.async {
      HyperFramesCLI.start(
        arguments: Array(CommandLine.arguments.dropFirst()),
        directory: directory, cancellationRequested: { cancelled },
        write: { text, isError in
          fputs(text, isError ? stderr : stdout)
          fflush(isError ? stderr : stdout)
        }, completion: { status in exit(status) })
    }
    withExtendedLifetime(signals) { NSApp.run() }
  }
}
