import Darwin
import Dispatch
import Foundation
import HTML2VideoCLILib
import ios_system

public func html2video_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  dispatchPrecondition(condition: .notOnQueue(.main))
  // ios_system owns a synchronous command thread. Keep the async-to-sync bridge here,
  // outside the exporter, and defer pthread cancellation until WebKit has unwound.
  var previous: Int32 = 0
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous)
  defer { pthread_setcancelstate(previous, nil) }
  guard let argv, argc > 0 else { return 1 }
  let output = ios_stdout() ?? stdout
  let errorOutput = ios_stderr() ?? stderr
  let arguments = (1..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
  let directory =
    ios_getenv("PWD").map { String(cString: $0) } ?? FileManager.default.currentDirectoryPath
  let home = ios_getenv("HOME").map { String(cString: $0) } ?? directory
  let aliases = ["/app_bundle"].map { alias -> (String, String) in
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = ios_resolveDirectoryAlias(alias, &buffer, buffer.count)
    return (alias, resolved > 0 ? String(cString: buffer) : alias)
  }
  let cancellation = ios_getCommandCancellationContext()
  let group = DispatchGroup()
  var status: Int32 = 1
  group.enter()
  DispatchQueue.main.async {
    HTML2VideoCLI.start(
      arguments: arguments,
      resolvePath: { value in
        var value = value
        if value == "~" || value.hasPrefix("~/") { value = home + value.dropFirst() }
        for (alias, target) in aliases where value == alias || value.hasPrefix(alias + "/") {
          value = target + value.dropFirst(alias.count)
          break
        }
        return URL(
          fileURLWithPath: value, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
        ).standardizedFileURL
      }, cancellationRequested: { ios_commandCancellationRequested(cancellation) != 0 },
      write: { text, isError in
        let stream = isError ? errorOutput : output
        fputs(text, stream)
        fflush(stream)
      },
      completion: { result in
        status = result
        group.leave()
      })
  }
  group.wait()
  return status
}
