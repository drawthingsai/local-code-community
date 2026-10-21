import ArgumentParser
import Darwin
import Foundation
import ios_system

public func calendar_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  appleUtilityMain(CalendarCommand.self, argc, argv)
}

public func mail_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  appleUtilityMain(MailCommand.self, argc, argv)
}

public func notes_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  appleUtilityMain(NotesCommand.self, argc, argv)
}

public func photos_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  appleUtilityMain(PhotosCommand.self, argc, argv)
}

public func imessage_main(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  appleUtilityMain(IMessageCommand.self, argc, argv)
}

/// A command that does the work and returns its result, which is printed as JSON.
protocol AppleUtilitySubcommand: ParsableCommand {
  func result() throws -> any Encodable
}

enum AppleUtilityError: LocalizedError {
  case cancelled
  case unavailable

  var errorDescription: String? {
    switch self {
    case .cancelled: return "Command cancelled."
    case .unavailable: return "This command is only available in Local Code."
    }
  }
}

/// Resolves a path argument against the session's current folder, expanding ~.
func fileURL(_ path: String, isDirectory: Bool = false) -> URL {
  let directory =
    ios_getenv("PWD").map { String(cString: $0) } ?? FileManager.default.currentDirectoryPath
  var path = path
  if path == "~" || path.hasPrefix("~/") {
    path = (ios_getenv("HOME").map { String(cString: $0) } ?? directory) + path.dropFirst()
  }
  return URL(
    fileURLWithPath: path, isDirectory: isDirectory,
    relativeTo: URL(fileURLWithPath: directory, isDirectory: true)
  ).standardizedFileURL
}

/// Adds -1, -2, and so on to a name that is taken.
func availableURL(_ directory: URL, name: String, extension pathExtension: String) -> URL {
  var url = directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
  var number = 1
  while FileManager.default.fileExists(atPath: url.path) {
    url = directory.appendingPathComponent("\(name)-\(number)").appendingPathExtension(
      pathExtension)
    number += 1
  }
  return url
}

/// Call on the command thread.
func checkCancellation() throws {
  guard ios_commandCancellationRequested(ios_getCommandCancellationContext()) == 0 else {
    throw AppleUtilityError.cancelled
  }
}

private func appleUtilityMain(
  _ root: ParsableCommand.Type, _ argc: Int32,
  _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  // Unwind Swift objects before Darwin is allowed to cancel this thread. Commands poll the
  // session cancellation context instead.
  var previous: Int32 = 0
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous)
  defer { pthread_setcancelstate(previous, nil) }
  return autoreleasepool {
    guard let argv, argc > 0 else { return 1 }
    let arguments = (1..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
    let cancellation = ios_getCommandCancellationContext()
    return runCommand(
      root, arguments: arguments, output: ios_stdout() ?? stdout,
      errorOutput: ios_stderr() ?? stderr,
      isCancelled: { ios_commandCancellationRequested(cancellation) != 0 })
  }
}

/// Returns the exit status instead of calling ArgumentParser's `exit`, which would terminate
/// the host app.
func runCommand(
  _ root: ParsableCommand.Type, arguments: [String], output: UnsafeMutablePointer<FILE>,
  errorOutput: UnsafeMutablePointer<FILE>, isCancelled: () -> Bool
) -> Int32 {
  let subcommand: AppleUtilitySubcommand
  do {
    var command = try root.parseAsRoot(arguments)
    guard let parsed = command as? AppleUtilitySubcommand else {
      // Help and command groups, such as `calendar events`, throw `CleanExit` with usage.
      try command.run()
      return 0
    }
    subcommand = parsed
  } catch {
    let status = root.exitCode(for: error).rawValue
    fputs(root.fullMessage(for: error) + "\n", status == 0 ? output : errorOutput)
    return status
  }
  guard !isCancelled() else { return 130 }
  do {
    let result = try jsonEncoder().encode(subcommand.result())
    fputs(String(decoding: result, as: UTF8.self) + "\n", output)
    return 0
  } catch {
    if isCancelled() { return 130 }
    fputs(
      "\(root.configuration.commandName ?? ""): \(error.localizedDescription)\n", errorOutput)
    return 1
  }
}

func jsonEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  encoder.keyEncodingStrategy = .convertToSnakeCase
  let formatter = ISO8601DateFormatter()
  formatter.timeZone = .current
  encoder.dateEncodingStrategy = .custom { date, encoder in
    var container = encoder.singleValueContainer()
    try container.encode(formatter.string(from: date))
  }
  return encoder
}

struct Pagination: ParsableArguments {
  @Option(help: "Maximum number of results.") var limit = 50
  @Option(help: "Results to skip. Pass next_offset from the previous page.") var offset = 0

  func validate() throws {
    guard limit > 0 else { throw ValidationError("--limit must be at least 1.") }
    guard offset >= 0 else { throw ValidationError("--offset must not be negative.") }
  }
}

/// Parses ISO 8601. A date-time without a time zone, or a bare date, is in local time.
func parseDate(_ value: String) throws -> Date {
  let formatter = ISO8601DateFormatter()
  for options: ISO8601DateFormatter.Options in [
    [.withInternetDateTime, .withFractionalSeconds], .withInternetDateTime,
  ] {
    formatter.formatOptions = options
    if let date = formatter.date(from: value) { return date }
  }
  let localFormatter = DateFormatter()
  localFormatter.locale = Locale(identifier: "en_US_POSIX")
  for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
    localFormatter.dateFormat = format
    if let date = localFormatter.date(from: value) { return date }
  }
  throw ValidationError(
    "Expected an ISO 8601 date, such as 2026-10-03, 2026-10-03T19:00, or 2026-10-03T19:00:00-04:00."
  )
}
