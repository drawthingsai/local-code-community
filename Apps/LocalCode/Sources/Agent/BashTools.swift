import Atomics
import BashToolContext
import Combine
import Darwin
import Foundation
import Localization
import ProjectHistoryManager
import QuartzCore
import ios_system
import os.lock
import zlib

private func makeBashOperationQueue(
  _ name: String, maxConcurrentOperationCount: Int = 1
) -> OperationQueue {
  let queue = OperationQueue()
  queue.name = "com.liuliu.local-code.tools.bash.\(name)"
  queue.maxConcurrentOperationCount = maxConcurrentOperationCount
  return queue
}

private let threadSafeOperationQueue = makeBashOperationQueue(
  "thread-safe", maxConcurrentOperationCount: 10)
private let oshOperationQueue = makeBashOperationQueue(
  "osh", maxConcurrentOperationCount: 4)
private let bashOperationQueue = makeBashOperationQueue("exclusive.bash")
private let pythonOperationQueue = makeBashOperationQueue("exclusive.python")
private let nodeOperationQueue = makeBashOperationQueue("exclusive.node")
private let curlOperationQueue = makeBashOperationQueue("exclusive.curl")
private let img2txtOperationQueue = makeBashOperationQueue("exclusive.img2txt")
private let openSSHOperationQueue = makeBashOperationQueue("exclusive.openssh")
private let ffmpegOperationQueue = makeBashOperationQueue("exclusive.ffmpeg")
private let libreOfficeOperationQueue = makeBashOperationQueue("exclusive.libreoffice")
private let drawThingsOperationQueue = makeBashOperationQueue("exclusive.draw-things")

private func commandOperationQueue(for command: ShellCommand) -> OperationQueue {
  let exclusiveOrThreadSafe = command.arguments[0].withCString {
    ios_commandIsExclusiveOrThreadSafe($0)
  }
  switch exclusiveOrThreadSafe {
  case IOS_COMMAND_ISOLATION_THREAD_SAFE:
    return threadSafeOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_BASH:
    return bashOperationQueue
  case IOS_COMMAND_ISOLATION_OSH:
    return oshOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_PYTHON:
    return pythonOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_NODE:
    return nodeOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_CURL:
    return curlOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_IMG2TXT:
    return img2txtOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_OPENSSH:
    return openSSHOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_FFMPEG:
    return ffmpegOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_LIBREOFFICE:
    return libreOfficeOperationQueue
  case IOS_COMMAND_ISOLATION_EXCLUSIVE_DRAW_THINGS:
    return drawThingsOperationQueue
  default:
    return bashOperationQueue
  }
}

private func renderTerminalOutput(_ text: String) -> String {
  let scalars = Array(stripANSIEscapeSequences(from: text).unicodeScalars)
  var outputLines = [String]()
  var currentLine = [Unicode.Scalar]()
  var column = 0
  let space = Unicode.Scalar(32)!
  var index = 0

  while index < scalars.count {
    let scalar = scalars[index]
    switch scalar.value {
    case 10:
      outputLines.append(String(String.UnicodeScalarView(currentLine)))
      currentLine.removeAll(keepingCapacity: true)
      column = 0
      index += 1
    case 13:
      if index + 1 < scalars.count, scalars[index + 1].value == 10 {
        outputLines.append(String(String.UnicodeScalarView(currentLine)))
        currentLine.removeAll(keepingCapacity: true)
        column = 0
        index += 2
      } else {
        currentLine.removeAll(keepingCapacity: true)
        column = 0
        index += 1
      }
    case 8:
      if column > 0 {
        column -= 1
      }
      index += 1
    case 0, 7:
      index += 1
    default:
      if scalar.value < 32, scalar.value != 9 {
        index += 1
        continue
      }
      while currentLine.count < column {
        currentLine.append(space)
      }
      if column < currentLine.count {
        currentLine[column] = scalar
      } else {
        currentLine.append(scalar)
      }
      column += 1
      index += 1
    }
  }

  if !currentLine.isEmpty {
    outputLines.append(String(String.UnicodeScalarView(currentLine)))
  }

  return outputLines.joined(separator: "\n")
}

private func stripANSIEscapeSequences(from text: String) -> String {
  let scalars = Array(text.unicodeScalars)
  var output = String.UnicodeScalarView()
  var index = 0

  while index < scalars.count {
    let scalar = scalars[index]
    guard scalar.value == 0x1b else {
      output.append(scalar)
      index += 1
      continue
    }

    index += 1
    guard index < scalars.count else {
      break
    }

    let introducer = scalars[index].value
    switch introducer {
    case 0x5b:
      index += 1
      while index < scalars.count {
        let value = scalars[index].value
        index += 1
        if value >= 0x40 && value <= 0x7e {
          break
        }
      }
    case 0x5d:
      index += 1
      while index < scalars.count {
        let value = scalars[index].value
        if value == 0x07 {
          index += 1
          break
        }
        if value == 0x1b, index + 1 < scalars.count, scalars[index + 1].value == 0x5c {
          index += 2
          break
        }
        index += 1
      }
    default:
      index += 1
    }
  }

  return String(output)
}

private let inlineFilePrefix = Array("1337;File=".utf8)

private enum CapturedOutput {
  case text(ArraySlice<UInt8>)
  /// The body of an iTerm2 inline file sequence after `1337;File=`: `<arguments>:<base64>`.
  case inlineFile(ArraySlice<UInt8>)
}

/// The BEL or ST ending an OSC sequence. A trailing ESC may begin an ST not yet written.
private func oscTerminator(in bytes: [UInt8], from start: Int) -> Range<Int>? {
  var index = start
  while index < bytes.count {
    if bytes[index] == 0x07 {
      return index..<(index + 1)
    }
    if bytes[index] == 0x1b, index + 1 < bytes.count, bytes[index + 1] == 0x5c {
      return index..<(index + 2)
    }
    index += 1
  }
  return nil
}

/// Splits captured bytes at iTerm2 inline file sequences (`ESC ] 1337;File=` ended by BEL or ST),
/// leaving other escape sequences to terminal rendering. Until the command finishes, a sequence
/// that may become an inline file is left unconsumed for the next read.
private func splitInlineFiles(_ bytes: [UInt8], isFinished: Bool) -> (
  output: [CapturedOutput], consumedCount: Int
) {
  var output = [CapturedOutput]()
  var textStart = 0
  var index = 0
  while let escape = bytes[index...].firstIndex(of: 0x1b) {
    guard escape + 1 < bytes.count else {
      guard !isFinished else { break }
      output.append(.text(bytes[textStart..<escape]))
      return (output, escape)
    }
    let bodyStart = escape + 2
    let prefixLength = min(inlineFilePrefix.count, bytes.count - bodyStart)
    guard bytes[escape + 1] == 0x5d,
      bytes[bodyStart..<(bodyStart + prefixLength)].elementsEqual(
        inlineFilePrefix.prefix(prefixLength))
    else {
      index = escape + 1
      continue
    }
    // A terminator after a partial prefix is impossible: the partial prefix ends the bytes.
    guard let terminator = oscTerminator(in: bytes, from: bodyStart + prefixLength) else {
      guard !isFinished else { break }
      output.append(.text(bytes[textStart..<escape]))
      return (output, escape)
    }
    output.append(.text(bytes[textStart..<escape]))
    output.append(.inlineFile(bytes[(bodyStart + prefixLength)..<terminator.lowerBound]))
    textStart = terminator.upperBound
    index = textStart
  }
  output.append(.text(bytes[textStart...]))
  return (output, bytes.count)
}

/// The PNG an inline file sequence displays, or nil unless it has `inline=1` and a complete PNG.
private func inlinePNG(_ body: ArraySlice<UInt8>) -> Data? {
  guard let colon = body.firstIndex(of: UInt8(ascii: ":")) else { return nil }
  let isInline = body[..<colon].split(separator: UInt8(ascii: ";")).contains {
    $0.elementsEqual("inline=1".utf8)
  }
  guard isInline, let png = Data(base64Encoded: Data(body[(colon + 1)...])), isCompletePNG(png)
  else { return nil }
  return png
}

/// Whether every chunk from IHDR through IEND is intact. ImageIO still decodes a PNG that is
/// truncated or corrupted midway, so check each chunk's CRC instead.
private func isCompletePNG(_ data: Data) -> Bool {
  data.withUnsafeBytes { bytes in
    guard let base = bytes.baseAddress,
      bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    else { return false }
    func bigEndian(at offset: Int) -> Int {
      bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
    }
    // A chunk is its data length, type, data, and the CRC of its type and data.
    var offset = 8
    while offset + 12 <= bytes.count {
      let length = bigEndian(at: offset)
      let end = offset + 12 + length
      guard end <= bytes.count,
        Int(crc32(0, (base + offset + 4).assumingMemoryBound(to: Bytef.self), uInt(4 + length)))
          == bigEndian(at: end - 4)
      else { return false }
      let type = bytes[(offset + 4)..<(offset + 8)]
      guard offset > 8 || type.elementsEqual("IHDR".utf8) else { return false }
      offset = end
      if type.elementsEqual("IEND".utf8) {
        return offset == bytes.count
      }
    }
    return false
  }
}

private final class BashJob {
  enum State {
    case pending
    case running
    case stopping
    case stopped
    case completed
  }

  let id: Int
  let command: String
  let projectPath: String
  let workspacePath: String
  let parsedResult: ShellCommandParsingResult
  let sessionName: UnsafeMutablePointer<CChar>
  let stdoutURL: URL
  let stderrURL: URL
  let timeout: TimeInterval?
  let isImageSupported: Bool
  /// The chat that started the job; the execution context is released once the job runs.
  let projectURL: URL?
  let threadId: Int64?

  private var executionContext: BashToolContext?
  private let bashUserInteraction: BashUserInteraction
  private let condition = NSCondition()
  private var outputLock = os_unfair_lock()
  private var state: State = .pending
  private var exitCode: Int32?
  private var stdoutOffset: UInt64 = 0
  private var stderrOffset: UInt64 = 0
  private var stopReason: String?
  private var streamsOpened = false

  init?(
    id: Int, command: String, projectPath: String, workspacePath: String,
    timeout: TimeInterval?, isImageSupported: Bool, context: BashToolContext
  ) {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalCodeBash", isDirectory: true)
    bashUserInteraction = context.bashUserInteraction
    executionContext = context
    projectURL = context.projectURL
    threadId = context.threadId
    self.id = id
    self.command = command
    self.projectPath = projectPath
    self.workspacePath = workspacePath
    let parsed = ShellCommandParser.parse(command)
    let commands: [ShellCommand]
    switch parsed {
    case .direct(let command): commands = [command]
    case .directSequence(let sequence): commands = sequence
    case .requiresShell: commands = []
    }
    // The direct argv path only supports registered ios_system commands. Let OSH
    // resolve its own builtins (such as printf, test and false) and scripts.
    parsedResult =
      commands.allSatisfy({ command in
        command.arguments[0].withCString { ios_executable($0) != 0 }
      }) ? parsed : .requiresShell
    self.timeout = timeout
    self.isImageSupported = isImageSupported
    // Job IDs are process-local; concurrent CLI hosts share the temporary directory.
    stdoutURL = temporaryDirectory.appendingPathComponent("job-\(getpid())-\(id)-stdout.txt")
    stderrURL = temporaryDirectory.appendingPathComponent("job-\(getpid())-\(id)-stderr.txt")
    guard let sessionName = strdup("localcode-bash-\(id)") else { return nil }
    self.sessionName = sessionName
  }

  deinit {
    free(sessionName)
    try? FileManager.default.removeItem(at: stdoutURL)
    try? FileManager.default.removeItem(at: stderrURL)
  }

  var isTerminal: Bool {
    condition.lock()
    let terminal = state == .completed || state == .stopped
    condition.unlock()
    return terminal
  }

  func start() {
    let startTime = CACurrentMediaTime()
    switch parsedResult {
    case .direct(let command):
      commandOperationQueue(for: command).addOperation { [weak self] in
        guard let self = self else { return }
        self.run()
      }
    case .directSequence:
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else { return }
        self.run()
      }
    case .requiresShell:
      oshOperationQueue.addOperation { [weak self] in
        guard let self = self else { return }
        self.run()
      }
    }
    if let timeout = timeout {
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
        [weak self] in
        self?.checkTimeout(startTime: startTime, timeout: timeout)
      }
    }
  }

  private func checkTimeout(startTime: TimeInterval, timeout: TimeInterval) {
    guard !isTerminal else { return }
    let elapsed = CACurrentMediaTime() - startTime
    let remaining =
      timeout - elapsed + bashUserInteraction.systemInteractionInterval(since: startTime)
    if remaining <= 0 {
      stop(reason: "Timed out after \(timeout) seconds.")
      return
    }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + remaining) {
      [weak self] in
      self?.checkTimeout(startTime: startTime, timeout: timeout)
    }
  }

  func wait(timeout: TimeInterval) {
    let startTime = CACurrentMediaTime()
    condition.lock()
    while state != .completed && state != .stopped {
      let elapsed = CACurrentMediaTime() - startTime
      let remaining =
        timeout - elapsed + bashUserInteraction.systemInteractionInterval(since: startTime)
      guard remaining > 0 else { break }
      condition.wait(until: Date().addingTimeInterval(remaining))
    }
    condition.unlock()
  }

  func stop(reason: String = "Stopped.") {
    condition.lock()
    switch state {
    case .completed, .stopped:
      condition.unlock()
      return
    case .pending:
      state = .stopped
      executionContext = nil
      stopReason = reason
      condition.broadcast()
      condition.unlock()
      BashJobRegistry.publishRunningJobs()
      return
    case .running, .stopping:
      state = .stopping
      stopReason = reason
      condition.unlock()
    }
    ios_switchSession(UnsafeRawPointer(sessionName))
    ios_kill()
  }

  func response(consumeOutput: Bool = true) -> ToolResponse {
    let snapshot = snapshot(consumeOutput: consumeOutput)
    var content = [ToolResponse.Content]()
    var output = [
      "job=\(id)",
      "status=\(snapshot.status)",
    ]
    if let exitCode = snapshot.exitCode {
      output.append("exit=\(exitCode)")
    }
    if let stopReason = snapshot.stopReason {
      output.append(stopReason)
    }
    // Images stay in emission order within each stream.
    for (name, parts) in [("stdout", snapshot.stdout), ("stderr", snapshot.stderr)]
    where !parts.isEmpty {
      output.append("\(name):")
      for part in parts {
        if case .text(let text) = part {
          output.append(text)
        } else {
          if !output.isEmpty {
            content.append(.text(output.joined(separator: "\n")))
          }
          content.append(part)
          output.removeAll()
        }
      }
    }
    func text(_ parts: [ToolResponse.Content]) -> String {
      parts.compactMap { part -> String? in
        guard case .text(let text) = part else { return nil }
        return text
      }.joined(separator: "\n")
    }
    // stderr may arrive before the exit status, or from an error caught by the shell.
    var diagnostics = text(snapshot.stderr)
    if let exitCode = snapshot.exitCode, exitCode != 0 {
      diagnostics += "\n" + text(snapshot.stdout)
    }
    let aliases = ["/home", "/tmp", "/app_bundle"].filter { alias in
      // Match an absolute alias, not /private/tmp, ./tmp, or /homepage.
      diagnostics.range(
        of: #"(?<![\p{L}\p{N}_./~$-])\#(alias)(?=/|[^\p{L}\p{N}_.-]|$)"#,
        options: .regularExpression) != nil
    }
    if !aliases.isEmpty {
      let resolver = LocalPathResolver(projectPath: projectPath, workspacePath: workspacePath)
      let mappings = aliases.compactMap { alias -> String? in
        guard let path = resolver.resolve(alias)?.url.path else { return nil }
        return "\(alias) -> \(path)"
      }
      output.append(
        """
        Path hint: These are virtual directory aliases. Use their physical paths instead:
        \(mappings.joined(separator: "\n"))
        """)
    }
    if !output.isEmpty {
      content.append(.text(output.joined(separator: "\n")))
    }
    return ToolResponse(content)
  }

  private func run() {
    condition.lock()
    if state == .stopped {
      condition.unlock()
      return
    }
    state = .running
    condition.broadcast()
    condition.unlock()
    defer { executionContext = nil }

    // Prepare capture at execution time: queued jobs may outlive temporary files.
    var captureSetupPath = stdoutURL.deletingLastPathComponent().path
    do {
      let directory = stdoutURL.deletingLastPathComponent()
      // Avoid inheriting Complete Protection: capture must remain usable while locked.
      let attributes: [FileAttributeKey: Any] = [
        .protectionKey: FileProtectionType.none
      ]
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: attributes)
      // createDirectory does not update the protection of an existing directory.
      try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
      for url in [stdoutURL, stderrURL] {
        captureSetupPath = url.path
        // Set protection at creation and atomically replace stale protected files.
        try Data().write(to: url, options: [.atomic, .noFileProtection])
      }
    } catch {
      finish(
        exitCode: -1, stopped: false,
        error: "Unable to prepare command capture at \(captureSetupPath): \(error)")
      return
    }

    // BashTool has no interactive input channel. Give commands EOF instead of
    // inheriting the app or debugger stdin, which can keep virtual Node children alive.
    let openedStdinFile = fopen("/dev/null", "r")
    let stdinError = errno
    let openedStdoutFile = fopen(stdoutURL.path, "a+")
    let stdoutError = errno
    let openedStderrFile = fopen(stderrURL.path, "a+")
    let stderrError = errno
    guard
      let stdinFile = openedStdinFile,
      let stdoutFile = openedStdoutFile,
      let stderrFile = openedStderrFile
    else {
      if let openedStdinFile {
        fclose(openedStdinFile)
      }
      if let openedStdoutFile {
        fclose(openedStdoutFile)
      }
      if let openedStderrFile {
        fclose(openedStderrFile)
      }
      let failure =
        openedStdinFile == nil
        ? ("/dev/null", stdinError)
        : openedStdoutFile == nil ? (stdoutURL.path, stdoutError) : (stderrURL.path, stderrError)
      finish(
        exitCode: -1, stopped: false,
        error:
          "Unable to open command stream at \(failure.0): \(String(cString: strerror(failure.1)))")
      return
    }
    defer {
      fclose(stdinFile)
      fclose(stdoutFile)
      fclose(stderrFile)
    }
    setbuf(stdoutFile, nil)
    setbuf(stderrFile, nil)
    condition.lock()
    streamsOpened = true
    condition.unlock()

    let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
    let projectLocalCodeURL = projectURL.appendingPathComponent(".localc", isDirectory: true)
    let fileManager = FileManager.default
    guard
      let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).last,
      let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).last
    else {
      finish(exitCode: -1, stopped: false, error: "Unable to resolve app system paths.")
      return
    }
    do {
      try fileManager.createDirectory(at: projectLocalCodeURL, withIntermediateDirectories: true)
    } catch {
      finish(
        exitCode: -1, stopped: false,
        error: "Unable to prepare project system paths: \(error.localizedDescription)")
      return
    }
    // This session runs only this job. A stop requested once the job is running,
    // even while its capture is still being prepared here, must stop every
    // command it starts, so the session is opened to keep the request instead
    // of letting the first command clear it.
    ios_openSession(UnsafeRawPointer(sessionName))
    ios_setStreams(stdinFile, stdoutFile, stderrFile)
    let previousContext = BashToolContext.current
    BashToolContext.current = executionContext
    defer { BashToolContext.current = previousContext }
    defer {
      ios_setStreams(stdin, stdout, stderr)
      ios_closeSession(UnsafeRawPointer(sessionName))
    }

    guard
      ios_setSystemPaths(
        projectLocalCodeURL, libraryURL, cachesURL, workspaceURL, projectURL,
        Resources.appBundleURL) != 0
    else {
      finish(exitCode: -1, stopped: false, error: "Unable to configure ios_system paths.")
      return
    }

    ios_setDirectoryURL(projectURL)
    _ = workspacePath.withCString {
      ios_setenv("NODE_MOBILE_VIRTUAL_NODE_ROOTS", $0, 1)
    }
    // Shell arguments and interpreters do not resolve the /app_bundle alias, so
    // bundled skill scripts need the real resource path.
    _ = Resources.appBundleURL.path.withCString {
      ios_setenv("APP_BUNDLE", $0, 1)
    }

    let status: Int32
    switch parsedResult {
    case .direct(let parsedCommand):
      status = runParsedCommand(
        parsedCommand, stdin: stdinFile, stdout: stdoutFile, stderr: stderrFile)
    case .directSequence(let parsedCommands):
      var sequenceStatus: Int32 = 0
      for parsedCommand in parsedCommands {
        let statusStorage = ManagedAtomic<Int32>(1)
        let operation = BlockOperation { [self] in
          condition.lock()
          let shouldRun = state == .running
          condition.unlock()
          guard shouldRun else {
            statusStorage.store(130, ordering: .releasing)
            return
          }
          ios_switchSession(UnsafeRawPointer(sessionName))
          ios_setStreams(stdinFile, stdoutFile, stderrFile)
          let previousContext = BashToolContext.current
          BashToolContext.current = executionContext
          defer { BashToolContext.current = previousContext }
          statusStorage.store(
            runParsedCommand(
              parsedCommand, stdin: stdinFile, stdout: stdoutFile, stderr: stderrFile),
            ordering: .releasing)
        }
        commandOperationQueue(for: parsedCommand).addOperation(operation)
        operation.waitUntilFinished()
        sequenceStatus = statusStorage.load(ordering: .acquiring)
        if sequenceStatus != 0 {
          break
        }
      }
      status = sequenceStatus
    case .requiresShell:
      status = command.withCString { ios_system_osh($0) }
    }
    for (name, stream) in [("stdout", stdoutFile), ("stderr", stderrFile)] {
      if fflush(stream) != 0 {
        let failure = errno
        print("Bash job \(id): flush \(name) failed: \(String(cString: strerror(failure)))")
      } else if ferror(stream) != 0 {
        // Unbuffered writes can fail before this final flush. errno at this
        // point belongs to a later operation, so do not misattribute it.
        print("Bash job \(id): \(name) capture write failed")
      }
    }

    condition.lock()
    let wasStopping = state == .stopping
    condition.unlock()
    finish(exitCode: status, stopped: wasStopping, error: nil)
  }

  private func runParsedCommand(
    _ command: ShellCommand, stdin: UnsafeMutablePointer<FILE>,
    stdout: UnsafeMutablePointer<FILE>, stderr: UnsafeMutablePointer<FILE>
  ) -> Int32 {
    let pathResolver = LocalPathResolver(projectPath: projectPath, workspacePath: workspacePath)
    let currentDirectoryPath =
      ios_getLogicalPWD(UnsafeRawPointer(sessionName)) as String? ?? projectPath
    var commandStdin = stdin
    var commandStdout = stdout
    var commandStderr = stderr
    var openedStreams = [UnsafeMutablePointer<FILE>]()
    defer {
      ios_setStreams(stdin, stdout, stderr)
      for stream in openedStreams {
        fclose(stream)
      }
    }

    for redirection in command.redirections {
      let path: String
      let mode: String
      switch redirection {
      case .input(let inputPath):
        path = inputPath
        mode = "r"
      case .output(let outputPath, let append):
        path = outputPath
        mode = append ? "a" : "w"
      case .error(let errorPath, let append):
        path = errorPath
        mode = append ? "a" : "w"
      case .errorToOutput:
        commandStderr = commandStdout
        continue
      }

      let resolvedPath: String
      if path == "/dev/null" {
        resolvedPath = path
      } else {
        let resolutionPath: String
        if path.hasPrefix("/") || path.lowercased().hasPrefix("file://") {
          resolutionPath = path
        } else {
          resolutionPath =
            URL(
              fileURLWithPath: currentDirectoryPath, isDirectory: true
            ).appendingPathComponent(path).path
        }
        guard let localPath = pathResolver.resolve(resolutionPath)?.url.path else {
          writeBashError(
            "redirection is outside the local workspace: \(path)", to: commandStderr)
          return 1
        }
        resolvedPath = localPath
      }
      guard let stream = fopen(resolvedPath, mode) else {
        writeBashError(
          "unable to open \(path): \(String(cString: strerror(errno)))", to: commandStderr)
        return 1
      }
      setbuf(stream, nil)
      openedStreams.append(stream)
      switch redirection {
      case .input:
        commandStdin = stream
      case .output:
        commandStdout = stream
      case .error:
        commandStderr = stream
      case .errorToOutput:
        break
      }
    }

    let allocatedArguments = command.arguments.map { strdup($0) }
    guard allocatedArguments.allSatisfy({ $0 != nil }) else {
      for argument in allocatedArguments {
        free(argument)
      }
      writeBashError("unable to allocate command arguments", to: commandStderr)
      return 1
    }
    defer {
      for argument in allocatedArguments {
        free(argument)
      }
    }
    var arguments = allocatedArguments.map { argument in
      argument.map { UnsafePointer<CChar>($0) }
    }
    arguments.append(nil)
    ios_setStreams(commandStdin, commandStdout, commandStderr)
    return arguments.withUnsafeBufferPointer { buffer in
      ios_system(Int32(command.arguments.count), buffer.baseAddress)
    }
  }

  private func writeBashError(_ message: String, to stream: UnsafeMutablePointer<FILE>) {
    _ = ("Error: \(message)\n").withCString { text in
      fputs(text, stream)
    }
  }

  private func finish(exitCode: Int32, stopped: Bool, error: String?) {
    if let error { print("Bash job \(id): \(error)") }
    condition.lock()
    self.exitCode = exitCode
    if stopped {
      state = .stopped
      if stopReason == nil {
        stopReason = "Stopped."
      }
    } else {
      state = .completed
    }
    condition.broadcast()
    condition.unlock()
    BashJobRegistry.publishRunningJobs()
  }

  private func snapshot(consumeOutput: Bool) -> (
    status: String, exitCode: Int32?, stopReason: String?, stdout: [ToolResponse.Content],
    stderr: [ToolResponse.Content]
  ) {
    // Serialize consumption without holding the state lock during file I/O:
    // polling must not prevent stopping or finishing the command.
    os_unfair_lock_lock(&outputLock)
    defer { os_unfair_lock_unlock(&outputLock) }
    condition.lock()
    let state = self.state
    let exitCode = self.exitCode
    let stopReason = self.stopReason
    let stdoutStart = stdoutOffset
    let stderrStart = stderrOffset
    let streamsOpened = self.streamsOpened
    condition.unlock()

    // Captures are complete once the command finishes; until then a sequence may be partial.
    let isFinished = state == .completed || state == .stopped
    let stdout =
      streamsOpened
      ? readOutput(from: stdoutURL, offset: stdoutStart, isFinished: isFinished)
      : (content: [], nextOffset: stdoutStart)
    let stderr =
      streamsOpened
      ? readOutput(from: stderrURL, offset: stderrStart, isFinished: isFinished)
      : (content: [], nextOffset: stderrStart)

    if consumeOutput {
      condition.lock()
      stdoutOffset = stdout.nextOffset
      stderrOffset = stderr.nextOffset
      condition.unlock()
    }

    let status: String
    switch state {
    case .pending:
      status = "pending"
    case .running:
      status = "running"
    case .stopping:
      status = "stopping"
    case .stopped:
      status = "stopped"
    case .completed:
      status = "completed"
    }
    return (
      status: status, exitCode: exitCode, stopReason: stopReason,
      stdout: stdout.content, stderr: stderr.content
    )
  }

  /// Renders the capture after the offset as a terminal would show it. Inline images are stored
  /// for a model that supports images; otherwise they are stripped like other escape sequences.
  private func readOutput(from url: URL, offset: UInt64, isFinished: Bool) -> (
    content: [ToolResponse.Content], nextOffset: UInt64
  ) {
    let start: UInt64
    let data: Data
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let length = try handle.seekToEnd()
      if length < offset { print("Bash job \(id): capture truncated at \(url.path)") }
      start = length < offset ? 0 : offset
      try handle.seek(toOffset: start)
      // Read only the size observed above, rather than chasing a busy writer.
      data = try handle.read(upToCount: Int(length - start)) ?? Data()
    } catch {
      // Preserve the offset so a later status call can retry failed reads.
      print("Bash job \(id): read capture at \(url.path) failed: \(error)")
      return ([], offset)
    }
    let split = splitInlineFiles([UInt8](data), isFinished: isFinished)
    var content = [ToolResponse.Content]()
    // Text around a stripped image renders together, as it did before images were supported.
    var text = ""
    for output in split.output {
      switch output {
      case .text(let bytes):
        text += String(decoding: bytes, as: UTF8.self)
      case .inlineFile(let body):
        guard isImageSupported, let png = inlinePNG(body),
          let digest = try? EmbedsFileStore(projectPath: projectPath).insert(data: png)
        else { continue }
        let rendered = renderTerminalOutput(text)
        if !rendered.isEmpty {
          content.append(.text(rendered))
        }
        content.append(.imageDigest(digest))
        text = ""
      }
    }
    let rendered = renderTerminalOutput(text)
    if !rendered.isEmpty {
      content.append(.text(rendered))
    }
    return (content, start + UInt64(split.consumedCount))
  }
}

enum BashJobRegistry {
  /// A job that has not finished yet, as Activities lists it.
  struct RunningJob {
    let id: Int
    let command: String
    let projectURL: URL?
    let threadId: Int64?
  }

  /// Jobs that are queued, running, or stopping, in the order they started. Each change sends
  /// the whole list, from the thread that made it, so subscribers receive on their own queue.
  static let runningJobs = CurrentValueSubject<[RunningJob], Never>([])
  private static var lock = os_unfair_lock()
  private static var nextJobID = 1
  private static var jobs = [Int: BashJob]()

  fileprivate static func create(
    command: String, projectPath: String?, workspacePath: String?, timeout: TimeInterval?,
    isImageSupported: Bool, context: BashToolContext
  ) -> BashJob? {
    guard let projectPath = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !projectPath.isEmpty,
      let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !workspacePath.isEmpty
    else {
      return nil
    }
    os_unfair_lock_lock(&lock)
    let id = nextJobID
    nextJobID += 1
    os_unfair_lock_unlock(&lock)
    guard
      let job = BashJob(
        id: id, command: command, projectPath: projectPath, workspacePath: workspacePath,
        timeout: timeout, isImageSupported: isImageSupported, context: context)
    else {
      return nil
    }
    os_unfair_lock_lock(&lock)
    jobs[id] = job
    if jobs.count > 32 {
      let completedIDs = jobs.keys.sorted().filter { jobs[$0]?.isTerminal == true }
      for id in completedIDs.prefix(jobs.count - 32) {
        jobs[id] = nil
      }
    }
    os_unfair_lock_unlock(&lock)
    publishRunningJobs()
    return job
  }

  fileprivate static func job(id: Int) -> BashJob? {
    os_unfair_lock_lock(&lock)
    let job = jobs[id]
    os_unfair_lock_unlock(&lock)
    return job
  }

  /// Sends the list under the lock so that changes on different threads publish in order and the
  /// last list sent is always current.
  fileprivate static func publishRunningJobs() {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    runningJobs.send(
      jobs.keys.sorted().compactMap { jobs[$0] }.filter { !$0.isTerminal }.map {
        RunningJob(
          id: $0.id, command: $0.command, projectURL: $0.projectURL, threadId: $0.threadId)
      })
  }

  /// Stops a job for the user; the agent sees why when it next checks the job.
  static func stop(id: Int) {
    job(id: id)?.stop(reason: "Stopped by the user.")
  }
}

public struct BashTool {
  public var command: String
  public var timeout: TimeInterval?
  public var refresh: TimeInterval
  public var projectPath: String?
  public var workspacePath: String?

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_bash_now")
    case .past:
      title = LocalizedString.forKey("tool_bash_past")
    }
    let lines = command.components(separatedBy: .newlines)
    if lines.count <= 1 {
      return "**\(title)**: \(MarkdownCode.inline(command))"
    } else {
      return "**\(title)**: \n\(MarkdownCode.block(command))"
    }
  }

  public static func parse(
    _ request: ToolCall.Request, projectPath: String?, workspacePath: String?
  ) -> BashTool? {
    guard let commandParameter = request.parameters["command"] else { return nil }
    let command = commandParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return nil }
    let timeout: TimeInterval?
    if let parameter = request.parameters["timeout_sec"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Double(value), parsed > 0 else { return nil }
      timeout = parsed
    } else {
      timeout = nil
    }
    let refresh: TimeInterval
    if let parameter = request.parameters["refresh_sec"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Double(value), parsed >= 0 else { return nil }
      refresh = parsed
    } else {
      refresh = 1
    }
    return BashTool(
      command: command, timeout: timeout, refresh: refresh, projectPath: projectPath,
      workspacePath: workspacePath)
  }

  /// Returns iTerm2 inline PNGs the command writes when `isImageSupported`, including those from
  /// later status, wait, and stop calls on its job; otherwise strips them.
  public func invoke(
    context: BashToolContext = .init(), isImageSupported: Bool = false,
    completion: @escaping (ToolResponse) -> Void
  ) {
    guard
      let job = BashJobRegistry.create(
        command: command, projectPath: projectPath, workspacePath: workspacePath, timeout: timeout,
        isImageSupported: isImageSupported, context: context)
    else {
      completion(ToolResponse(text: "Error: No project is selected."))
      return
    }
    job.start()
    DispatchQueue.global(qos: .utility).async {
      job.wait(timeout: refresh)
      completion(job.response())
    }
  }
}

public struct BashStatusTool {
  public var jobID: Int

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_bash_status_now")
    case .past:
      title = LocalizedString.forKey("tool_bash_status_past")
    }
    return "**\(title)**: \(jobID)"
  }

  public static func parse(_ request: ToolCall.Request) -> BashStatusTool? {
    guard let jobParameter = request.parameters["job"] else { return nil }
    let value = jobParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let jobID = Int(value), jobID > 0 else { return nil }
    return BashStatusTool(jobID: jobID)
  }

  public func invoke(completion: @escaping (ToolResponse) -> Void) {
    guard let job = BashJobRegistry.job(id: jobID) else {
      completion(ToolResponse(text: "Error: Unknown bash job \(jobID)."))
      return
    }
    completion(job.response())
  }
}

public struct BashWaitTool {
  public var jobID: Int
  public var refresh: TimeInterval

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_bash_wait_now")
    case .past:
      title = LocalizedString.forKey("tool_bash_wait_past")
    }
    return "**\(title)**: \(jobID)"
  }

  public static func parse(_ request: ToolCall.Request) -> BashWaitTool? {
    guard let jobParameter = request.parameters["job"] else { return nil }
    let value = jobParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let jobID = Int(value), jobID > 0 else { return nil }
    let refresh: TimeInterval
    if let parameter = request.parameters["refresh_sec"] {
      let value = parameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let parsed = Double(value), parsed >= 0 else { return nil }
      refresh = parsed
    } else {
      refresh = 1
    }
    return BashWaitTool(jobID: jobID, refresh: refresh)
  }

  public func invoke(completion: @escaping (ToolResponse) -> Void) {
    guard let job = BashJobRegistry.job(id: jobID) else {
      completion(ToolResponse(text: "Error: Unknown bash job \(jobID)."))
      return
    }
    DispatchQueue.global(qos: .utility).async {
      job.wait(timeout: refresh)
      completion(job.response())
    }
  }
}

public struct BashStopTool {
  public var jobID: Int

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_bash_stop_now")
    case .past:
      title = LocalizedString.forKey("tool_bash_stop_past")
    }
    return "**\(title)**: \(jobID)"
  }

  public static func parse(_ request: ToolCall.Request) -> BashStopTool? {
    guard let jobParameter = request.parameters["job"] else { return nil }
    let value = jobParameter.value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let jobID = Int(value), jobID > 0 else { return nil }
    return BashStopTool(jobID: jobID)
  }

  public func invoke(completion: @escaping (ToolResponse) -> Void) {
    guard let job = BashJobRegistry.job(id: jobID) else {
      completion(ToolResponse(text: "Error: Unknown bash job \(jobID)."))
      return
    }
    job.stop()
    DispatchQueue.global(qos: .userInitiated).async {
      job.wait(timeout: 1)
      completion(job.response())
    }
  }
}
