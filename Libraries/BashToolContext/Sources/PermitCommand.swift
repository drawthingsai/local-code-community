import Darwin
import Foundation
import ios_system

/// ios_system's synchronous command boundary; the host owns picker presentation and cancellation.
public func permit_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  var previous: Int32 = 0
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous)
  defer { pthread_setcancelstate(previous, nil) }
  return autoreleasepool {
    let output = ios_stdout() ?? stdout
    let errorOutput = ios_stderr() ?? stderr
    guard let argv, argc > 0 else { return 2 }
    var arguments = (1..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
    if arguments == ["--help"] || arguments == ["-h"] {
      fputs(
        "Usage: permit <directory>\nRequest folder access.\n",
        output)
      return 0
    }
    let literalPath = arguments.first == "--"
    if literalPath { arguments.removeFirst() }
    guard arguments.count == 1, !arguments[0].isEmpty,
      literalPath || !arguments[0].hasPrefix("-")
    else {
      fputs("Usage: permit <directory>\n", errorOutput)
      return 2
    }
    guard let context = BashToolContext.current, let permitDirectory = context.permitDirectory
    else {
      fputs(
        "permit: folder permission requests are only available in the Local Code app.\n",
        errorOutput)
      return 1
    }
    let cancellation = ios_getCommandCancellationContext()
    let isCancelled = { ios_commandCancellationRequested(cancellation) != 0 }
    guard !isCancelled() else { return 130 }
    let directory =
      ios_getenv("PWD").map { String(cString: $0) }
      ?? FileManager.default.currentDirectoryPath
    var path = arguments[0]
    if path == "~" || path.hasPrefix("~/") {
      path = (ios_getenv("HOME").map { String(cString: $0) } ?? directory) + path.dropFirst()
    }
    let requested = URL(
      fileURLWithPath: path, isDirectory: true,
      relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
    ).standardizedFileURL
    // Waiting here is necessary because ios_system commands return an exit status synchronously.
    let group = DispatchGroup()
    var result: Result<URL, Error>?
    group.enter()
    permitDirectory(requested, context.bashUserInteraction, isCancelled) {
      result = $0
      group.leave()
    }
    group.wait()
    guard !isCancelled() else { return 130 }
    switch result {
    case .success(let url):
      fputs("Permitted: \(url.standardizedFileURL.resolvingSymlinksInPath().path)\n", output)
      return 0
    case .failure(let error):
      fputs("permit: \(error.localizedDescription)\n", errorOutput)
      return 1
    case nil:
      return 1
    }
  }
}
