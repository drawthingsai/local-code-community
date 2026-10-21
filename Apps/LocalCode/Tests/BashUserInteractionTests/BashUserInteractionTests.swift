import BashToolContext
import Darwin
import Foundation
import ProjectHistoryManager
import QuartzCore
import XCTest
import ios_system
import os.lock

// Native macOS maps No Protection to class C; iOS/Catalyst use class D.
#if os(macOS) && !targetEnvironment(macCatalyst)
  private let temporaryFileProtection = FileProtectionType.completeUntilFirstUserAuthentication
#else
  private let temporaryFileProtection = FileProtectionType.none
#endif

private enum InteractionTestError: Error {
  case cancelled
}

extension ToolResponse {
  fileprivate var text: String {
    content.compactMap { part -> String? in
      guard case .text(let text) = part else { return nil }
      return text
    }.joined(separator: "\n")
  }
}

private let testPNG = Data(
  base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAADhlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAAqACAAQAAAABAAAAAqADAAQAAAABAAAAAgAAAADO0J6QAAAAEklEQVQIHWNggIH/DAxAxMAAAA0FAf95yzEvAAAAAElFTkSuQmCC"
)!

private func inlineImageSequence(
  _ png: Data, arguments: String = "inline=1", terminator: String = "\u{1b}\\"
) -> String {
  "\u{1b}]1337;File=\(arguments):\(png.base64EncodedString())\(terminator)"
}

/// `ordered` writes accepted and rejected inline images between text. Other modes stop at the
/// named part of an inline image until the host resumes them, then finish it.
private func inlineImageTestCommand(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  guard let argv, argc == 2 else { return 1 }
  let mode = String(cString: argv[1]!)
  if mode == "ordered" {
    var corrupted = testPNG
    corrupted[corrupted.count / 2] ^= 0xff
    let output =
      "before\n" + inlineImageSequence(testPNG, terminator: "\u{7}") + "middle\n"
      + inlineImageSequence(testPNG) + inlineImageSequence(testPNG, arguments: "inline=0")
      + inlineImageSequence(corrupted) + inlineImageSequence(testPNG.dropLast(12)) + "after\n"
    fputs(output, ios_stdout())
    return 0
  }
  let output = Array(("before\n" + inlineImageSequence(testPNG) + "\nafter\n").utf8)
  let splits = [
    "header": "before\n\u{1b}]1337;Fi".utf8.count,
    "payload": "before\n\u{1b}]1337;File=inline=1:iVBOR".utf8.count,
    "terminator": output.count - "\\\nafter\n".utf8.count,
  ]
  guard let split = splits[mode], let context = BashToolContext.current,
    let resume = context.resloveDrawThingsModelsDirectory
  else { return 1 }
  fwrite(output, 1, split, ios_stdout())
  fflush(ios_stdout())
  let condition = NSCondition()
  var resumed = false
  resume(nil, context.bashUserInteraction) { _ in
    condition.lock()
    resumed = true
    condition.broadcast()
    condition.unlock()
  }
  let cancellation = ios_getCommandCancellationContext()
  condition.lock()
  while !resumed && ios_commandCancellationRequested(cancellation) == 0 {
    condition.wait(until: Date().addingTimeInterval(0.1))
  }
  condition.unlock()
  output.withUnsafeBufferPointer {
    _ = fwrite($0.baseAddress! + split, 1, output.count - split, ios_stdout())
  }
  return 0
}

private func interactionTestCommand(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  var previous: Int32 = 0
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous)
  defer { pthread_setcancelstate(previous, nil) }
  guard let argv, argc == 3,
    let context = BashToolContext.current,
    let resolve = context.resloveDrawThingsModelsDirectory
  else { return 1 }
  if String(cString: argv[0]!) == "capture_test" {
    fputs("captured before wait\n", ios_stdout())
    fflush(ios_stdout())
  }
  let cancellation = ios_getCommandCancellationContext()
  func work(milliseconds: Int) {
    let deadline = CACurrentMediaTime() + Double(milliseconds) / 1000
    while CACurrentMediaTime() < deadline
      && ios_commandCancellationRequested(cancellation) == 0
    {
      usleep(10_000)
    }
  }
  work(milliseconds: Int(String(cString: argv[1]!))!)
  let condition = NSCondition()
  var completed = false
  var cancelled = false
  resolve(nil, context.bashUserInteraction) { result in
    condition.lock()
    if case .failure = result { cancelled = true }
    completed = true
    condition.broadcast()
    condition.unlock()
  }
  condition.lock()
  while !completed && ios_commandCancellationRequested(cancellation) == 0 {
    condition.wait(until: Date().addingTimeInterval(0.1))
  }
  condition.unlock()
  if cancelled { return 1 }
  work(milliseconds: Int(String(cString: argv[2]!))!)
  return ios_commandCancellationRequested(cancellation) == 0 ? 0 : 130
}

private func runtimeFailureTestCommand(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  return -1
}

private func captureWriteFailureTestCommand(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  let readOnly = open("/dev/null", O_RDONLY)
  guard readOnly >= 0 else { return 1 }
  defer { _ = close(readOnly) }
  // Keep a valid descriptor for the owner's fclose, but make writes fail.
  guard Darwin.dup2(readOnly, fileno(ios_stdout())) >= 0 else { return 1 }
  _ = fputs("output that cannot be written", ios_stdout())
  return 0
}

private func descriptorDuplicateTestCommand(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  for _ in 0..<2 {
    if ios_dup2(fileno(ios_stdout()), STDOUT_FILENO) < 0 { return 1 }
  }
  return 0
}

private func descriptorPipeFailureTestCommand(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  for mode in ["r", "w"] {
    if let stream = ios_popen("descriptor_test_missing_command", mode) { fclose(stream) }
  }
  return 0
}

private func descriptorAliasTestCommand(
  _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32 {
  guard ios_dup2(fileno(ios_stdout()), STDOUT_FILENO) >= 0,
    ios_dup2(STDOUT_FILENO, STDERR_FILENO) >= 0,
    ios_dup2(fileno(ios_stdout()), STDOUT_FILENO) >= 0
  else { return 1 }
  let arguments = [strdup("echo"), strdup("alias-output")]
  defer { arguments.forEach { free($0) } }
  var pointers = arguments.map { $0.map { UnsafePointer($0) } }
  pointers.append(nil)
  return pointers.withUnsafeBufferPointer { ios_system(2, $0.baseAddress) }
}

final class BashUserInteractionTests: XCTestCase {
  private static let register: Void = {
    initializeEnvironment()
    precondition(
      ios_registerCommand("descriptor_duplicate_test", descriptorDuplicateTestCommand) != 0)
    precondition(ios_registerCommand("descriptor_alias_test", descriptorAliasTestCommand) != 0)
    precondition(
      ios_registerCommand("descriptor_pipe_failure_test", descriptorPipeFailureTestCommand) != 0)
    precondition(ios_registerCommand("interaction_test", interactionTestCommand) != 0)
    precondition(ios_registerCommand("inline_image_test", inlineImageTestCommand) != 0)
    precondition(ios_registerCommand("capture_test", interactionTestCommand) != 0)
    precondition(ios_registerCommand("runtime_failure_test", runtimeFailureTestCommand) != 0)
    precondition(
      ios_registerCommand("capture_write_failure_test", captureWriteFailureTestCommand) != 0)
    precondition(ios_registerCommand("draw-things-cli", interactionTestCommand) != 0)
    precondition(ios_registerCommand("permit", permit_main) != 0)
  }()

  private var directory: URL!
  // ios_system's worker threads retain their working directory through test
  // runner shutdown. Let Bazel remove this temporary directory with its sandbox.
  private static let testDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)

  override func setUpWithError() throws {
    _ = Self.register
    directory = Self.testDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func testInlineImagesReturnInEmissionOrder() throws {
    let finished = expectation(description: "Inline images")
    var response: ToolResponse?
    BashTool(
      command: "inline_image_test ordered", timeout: 10, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(isImageSupported: true) {
      response = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    let content = try XCTUnwrap(response).content
    // Images that are not inline, corrupted, or truncated are stripped.
    guard content.count == 5, case .text(let before) = content[0],
      case .imageDigest(let first) = content[1], case .text(let middle) = content[2],
      case .imageDigest(let second) = content[3], case .text(let after) = content[4]
    else { return XCTFail("Unexpected content: \(content)") }
    XCTAssertTrue(before.hasSuffix("exit=0\nstdout:\nbefore"), before)
    XCTAssertEqual(middle, "middle")
    XCTAssertEqual(after, "after")
    XCTAssertEqual(first, second)
    XCTAssertEqual(
      try Data(
        contentsOf: URL(
          fileURLWithPath: EmbedsFileStore(projectPath: directory.path).filePath(for: first))),
      testPNG)
  }

  func testInlineImagesAreStrippedWithoutImageSupport() throws {
    let finished = expectation(description: "Stripped inline images")
    var response: ToolResponse?
    BashTool(
      command: "inline_image_test ordered", timeout: 10, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke {
      response = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    let content = try XCTUnwrap(response).content
    guard content.count == 1, case .text(let text) = content[0] else {
      return XCTFail("Unexpected content: \(content)")
    }
    XCTAssertTrue(text.hasSuffix("stdout:\nbefore\nmiddle\nafter"), text)
  }

  func testInlineImageSplitAcrossPollsReturnsOnce() throws {
    for mode in ["header", "payload", "terminator"] {
      let paused = expectation(description: "\(mode) is partially written")
      let started = expectation(description: "\(mode) initial response")
      var resume: ((Result<URL, Error>) -> Void)?
      var responses = [ToolResponse]()
      BashTool(
        command: "inline_image_test \(mode)", timeout: 10, refresh: 0,
        projectPath: directory.path, workspacePath: directory.path
      ).invoke(
        context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
          resume = completion
          paused.fulfill()
        }),
        isImageSupported: true
      ) {
        responses.append($0)
        started.fulfill()
      }
      wait(for: [paused, started], timeout: 5)
      let id = try XCTUnwrap(
        responses[0].text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) })
      let polled = expectation(description: "\(mode) partial poll")
      BashStatusTool(jobID: id).invoke {
        responses.append($0)
        polled.fulfill()
      }
      wait(for: [polled], timeout: 5)
      resume?(.success(directory))
      let finished = expectation(description: "\(mode) finishes")
      BashWaitTool(jobID: id, refresh: 10).invoke {
        responses.append($0)
        finished.fulfill()
      }
      wait(for: [finished], timeout: 10)
      XCTAssertEqual(responses[0].content.count + responses[1].content.count, 2, mode)
      let text = responses.map(\.text).joined(separator: "\n")
      XCTAssertTrue(text.contains("before"), text)
      XCTAssertTrue(text.contains("after"), text)
      XCTAssertFalse(text.contains("1337") || text.contains("iVBOR"), text)
      let images = responses.flatMap(\.content).filter {
        if case .imageDigest = $0 { return true }
        return false
      }
      XCTAssertEqual(images.count, 1, mode)
      XCTAssertTrue(responses[2].content.contains(where: { $0 == images.first }), mode)
    }
  }

  func testRepeatedNativeRedirectionDoesNotLeakDescriptors() {
    verifyDescriptorCount(command: "descriptor_duplicate_test")
  }

  func testRepeatedFailedPipesDoNotLeakDescriptors() {
    verifyDescriptorCount(command: "descriptor_pipe_failure_test", expectedExit: nil)
  }

  func testPendingRedirectionAliasesSurviveReplacementWithoutLeaking() {
    verifyDescriptorCount(command: "descriptor_alias_test")
  }

  func testRepeatedShellAndNativePipelinesDoNotLeakDescriptors() {
    for command in [
      "echo hello | cat",
      "awk 'BEGIN { print \"native\" | \"cat\"; close(\"cat\") }'",
      "awk 'BEGIN { \"echo native\" | getline x; close(\"echo native\"); print x }'",
    ] {
      verifyDescriptorCount(command: command, iterations: 50)
    }
  }

  private func verifyDescriptorCount(command: String, expectedExit: Int? = 0, iterations: Int = 20)
  {
    let before = (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    for _ in 0..<iterations {
      let finished = expectation(description: command)
      BashTool(
        command: command, timeout: 5, refresh: 10,
        projectPath: directory.path, workspacePath: directory.path
      ).invoke { response in
        if let expectedExit {
          XCTAssertTrue(response.text.contains("exit=\(expectedExit)"), response.text)
        } else {
          XCTAssertTrue(response.text.contains("command not found"), response.text)
          XCTAssertTrue(response.text.contains("status=completed"), response.text)
        }
        if command == "descriptor_alias_test" {
          XCTAssertTrue(response.text.contains("alias-output"), response.text)
        }
        finished.fulfill()
      }
      wait(for: [finished], timeout: 10)
    }
    let after = (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    // Completion can precede the final job's three stream closes.
    XCTAssertLessThanOrEqual(after, before + 3, "Descriptor leak after \(command)")
  }

  func testCommandStreamFailureCompletesWithoutExecuting() throws {
    let active = expectation(description: "Exclusive command holds its queue")
    let activeFinished = expectation(description: "Exclusive command finishes")
    var release: ((Result<URL, Error>) -> Void)?
    let first = BashTool(
      command: "draw-things-cli 0 0", timeout: 10, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path)
    first.invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        release = completion
        active.fulfill()
      })
    ) { _ in activeFinished.fulfill() }
    wait(for: [active], timeout: 5)
    defer { release?(.success(directory)) }

    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LocalCodeBash", isDirectory: true)
    let queued = expectation(description: "Second command is queued")
    var jobID: Int?
    let second = BashTool(
      command: "draw-things-cli 0 0", timeout: 10, refresh: 0,
      projectPath: directory.path, workspacePath: directory.path)
    second.invoke(context: BashToolContext()) { response in
      XCTAssertTrue(response.text.contains("status=pending"), response.text)
      jobID = response.text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) }
      queued.fulfill()
    }
    wait(for: [queued], timeout: 5)
    let id = try XCTUnwrap(jobID)
    // Only replace this queued job's files. Directories make both stream setup
    // and the old file-backed error-reporting path fail without exhausting FDs.
    let streams = ["stdout", "stderr"].map {
      temporaryDirectory.appendingPathComponent("job-\(getpid())-\(id)-\($0).txt")
    }
    defer { streams.forEach { try? FileManager.default.removeItem(at: $0) } }
    for stream in streams {
      try? FileManager.default.removeItem(at: stream)
      try FileManager.default.createDirectory(at: stream, withIntermediateDirectories: false)
    }
    release?(.success(directory))
    release = nil
    let finished = expectation(description: "Command fails during capture setup")
    BashWaitTool(jobID: id, refresh: 10).invoke { response in
      XCTAssertTrue(response.text.contains("exit=-1"), response.text)
      finished.fulfill()
    }
    wait(for: [activeFinished, finished], timeout: 10)
  }

  func testCaptureReplacesStaleProtectionBeforeExecutingCommand() throws {
    let active = expectation(description: "First command holds the queue")
    let firstFinished = expectation(description: "First command finishes")
    var release: ((Result<URL, Error>) -> Void)?
    BashTool(
      command: "capture_test 0 0", timeout: 10, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        release = completion
        active.fulfill()
      })
    ) { _ in firstFinished.fulfill() }
    wait(for: [active], timeout: 5)
    defer { release?(.success(directory)) }

    let queued = expectation(description: "Second command is queued")
    var jobID: Int?
    var executions = 0
    var executionLock = os_unfair_lock()
    BashTool(
      command: "capture_test 0 0", timeout: 10, refresh: 0,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { [directory] _, _, completion in
        os_unfair_lock_lock(&executionLock)
        executions += 1
        os_unfair_lock_unlock(&executionLock)
        completion(.success(directory!))
      })
    ) { response in
      XCTAssertTrue(response.text.contains("status=pending"), response.text)
      jobID = response.text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) }
      queued.fulfill()
    }
    wait(for: [queued], timeout: 5)
    let id = try XCTUnwrap(jobID)
    // Class B allows creation while locked, but prevents reopening after close.
    let streams = ["stdout", "stderr"].map {
      FileManager.default.temporaryDirectory.appendingPathComponent(
        "LocalCodeBash/job-\(getpid())-\(id)-\($0).txt")
    }
    defer {
      for stream in streams {
        try? FileManager.default.removeItem(at: stream)
      }
    }
    for stream in streams {
      try Data("stale capture".utf8).write(
        to: stream, options: [.atomic, .completeFileProtectionUnlessOpen])
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: stream.path)[.protectionKey]
          as? FileProtectionType,
        .completeUnlessOpen)
    }
    release?(.success(directory))
    release = nil
    let finished = expectation(description: "Capture is readable with the new protection policy")
    BashWaitTool(jobID: id, refresh: 10).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertTrue(response.text.contains("captured before wait"), response.text)
      finished.fulfill()
    }
    wait(for: [firstFinished, finished], timeout: 10)
    os_unfair_lock_lock(&executionLock)
    let executionCount = executions
    os_unfair_lock_unlock(&executionLock)
    XCTAssertEqual(executionCount, 1)
    XCTAssertEqual(try String(contentsOf: streams[0], encoding: .utf8), "captured before wait\n")
    for stream in streams {
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: stream.path)[.protectionKey]
          as? FileProtectionType,
        temporaryFileProtection)
    }
  }

  func testDeletedCaptureDoesNotPreventNextCommand() throws {
    let active = expectation(description: "Command waits while capture is removed")
    let started = expectation(description: "Initial response")
    var release: ((Result<URL, Error>) -> Void)?
    var jobID: Int?
    BashTool(
      command: "capture_test 0 0", timeout: 10, refresh: 0,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        release = completion
        active.fulfill()
      })
    ) { response in
      jobID = response.text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) }
      started.fulfill()
    }
    wait(for: [active, started], timeout: 5)
    defer { release?(.success(directory)) }
    let id = try XCTUnwrap(jobID)
    let capture = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LocalCodeBash/job-\(getpid())-\(id)-stdout.txt")
    for stream in ["stdout", "stderr"] {
      let url = capture.deletingLastPathComponent().appendingPathComponent(
        "job-\(getpid())-\(id)-\(stream).txt")
      XCTAssertEqual(
        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
          as? FileProtectionType,
        temporaryFileProtection)
    }
    try FileManager.default.removeItem(at: capture)
    release?(.success(directory))
    release = nil
    let finished = expectation(description: "Command finishes with missing capture")
    BashWaitTool(jobID: id, refresh: 10).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    let recovered = expectation(description: "Subsequent command runs")
    BashTool(
      command: "echo recovered", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertTrue(response.text.contains("recovered"), response.text)
      recovered.fulfill()
    }
    wait(for: [recovered], timeout: 10)
  }

  func testInvalidSystemDirectoryFailsAndRecovers() throws {
    let project = directory.appendingPathComponent(UUID().uuidString)
    let metadata = project.appendingPathComponent(".localc")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let obstruction = metadata.appendingPathComponent("node")
    try Data("not a directory".utf8).write(to: obstruction)
    for command in ["true", "echo hello", "pwd; ls"] {
      let failed = expectation(description: command)
      BashTool(
        command: command, timeout: 5, refresh: 10,
        projectPath: project.path, workspacePath: project.path
      ).invoke { response in
        XCTAssertTrue(response.text.contains("exit=-1"), response.text)
        failed.fulfill()
      }
      wait(for: [failed], timeout: 10)
    }
    try FileManager.default.removeItem(at: obstruction)
    let recovered = expectation(description: "Shell recovers after repairing directory")
    BashTool(
      command: "echo recovered", timeout: 5, refresh: 10,
      projectPath: project.path, workspacePath: project.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertTrue(response.text.contains("recovered"), response.text)
      recovered.fulfill()
    }
    wait(for: [recovered], timeout: 10)
  }

  func testInitializationRaisesLowDescriptorLimit() throws {
    var savedLimit = rlimit()
    XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &savedLimit), 0)
    guard savedLimit.rlim_max >= 4096 else { throw XCTSkip("Host hard limit is below 4096") }
    var constrained = savedLimit
    constrained.rlim_cur = 256
    XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &constrained), 0)
    var descriptors = [Int32]()
    defer {
      descriptors.forEach { _ = close($0) }
      _ = setrlimit(RLIMIT_NOFILE, &savedLimit)
    }
    while true {
      let descriptor = open("/dev/null", O_RDONLY)
      if descriptor < 0 { break }
      descriptors.append(descriptor)
    }
    XCTAssertEqual(errno, EMFILE)
    initializeEnvironment()
    let finished = expectation(description: "Bash runs with the initialized descriptor limit")
    BashTool(
      command: "echo recovered", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertTrue(response.text.contains("recovered"), response.text)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    var actual = rlimit()
    XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &actual), 0)
    XCTAssertEqual(actual.rlim_cur, 4096)
    XCTAssertEqual(actual.rlim_max, savedLimit.rlim_max)
    // Raising the limit must preserve caller-owned descriptors.
    XCTAssertTrue(descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 })
  }

  func testDescriptorExhaustionFailsAndRecovers() throws {
    // Warm up command dispatch before constraining only this test process.
    let warm = expectation(description: "Warm command dispatch")
    BashTool(
      command: "true", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      warm.fulfill()
    }
    wait(for: [warm], timeout: 10)
    var savedLimit = rlimit()
    XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &savedLimit), 0)
    var constrained = savedLimit
    constrained.rlim_cur = min(4096, savedLimit.rlim_max)
    XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &constrained), 0)
    var descriptors = [Int32]()
    defer {
      descriptors.forEach { _ = close($0) }
      _ = setrlimit(RLIMIT_NOFILE, &savedLimit)
    }
    while true {
      let descriptor = open("/dev/null", O_RDONLY)
      if descriptor < 0 { break }
      descriptors.append(descriptor)
    }
    XCTAssertEqual(errno, EMFILE)
    for command in ["true", "echo hello", "pwd; ls"] {
      let failed = expectation(description: command)
      BashTool(
        command: command, timeout: 5, refresh: 10,
        projectPath: directory.path, workspacePath: directory.path
      ).invoke { response in
        XCTAssertTrue(response.text.contains("exit=-1"), response.text)
        failed.fulfill()
      }
      wait(for: [failed], timeout: 10)
    }
    descriptors.forEach { _ = close($0) }
    descriptors.removeAll()
    XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &savedLimit), 0)
    let recovered = expectation(description: "Shell recovers when resources return")
    BashTool(
      command: "echo recovered", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertTrue(response.text.contains("recovered"), response.text)
      recovered.fulfill()
    }
    wait(for: [recovered], timeout: 10)
  }

  func testSystemPathsRecreatePurgedCachesAndRejectObstruction() throws {
    let root = directory.appendingPathComponent(UUID().uuidString)
    let caches = root.appendingPathComponent("Caches")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try XCTUnwrap(strdup(UUID().uuidString))
    defer {
      ios_setStreams(stdin, stdout, stderr)
      ios_closeSession(UnsafeRawPointer(session))
      free(session)
    }
    ios_switchSession(UnsafeRawPointer(session))
    ios_setStreams(stdin, stdout, stderr)
    let temporary = caches.appendingPathComponent("tmp")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.complete], ofItemAtPath: temporary.path)
    XCTAssertEqual(ios_setSystemPaths(root, root, caches, root, root, root), 1)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: temporary.path)[.protectionKey]
        as? FileProtectionType,
      temporaryFileProtection)
    let probe = temporary.appendingPathComponent("background.txt")
    try Data("background temporary file".utf8).write(to: probe)
    XCTAssertEqual(try String(contentsOf: probe, encoding: .utf8), "background temporary file")
    try FileManager.default.removeItem(at: caches)
    XCTAssertEqual(ios_setSystemPaths(root, root, caches, root, root, root), 1)
    try FileManager.default.removeItem(at: caches)
    try Data("preserve this file".utf8).write(to: caches)
    XCTAssertEqual(ios_setSystemPaths(root, root, caches, root, root, root), 0)
    XCTAssertEqual(try String(contentsOf: caches, encoding: .utf8), "preserve this file")
  }

  func testSystemPathsKeepOnlyBundleVersionPythonCache() throws {
    let root = directory.appendingPathComponent(UUID().uuidString)
    let caches = root.appendingPathComponent("Caches")
    let pythonCache = root.appendingPathComponent("__pycache__")
    let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let version = bundleVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    let current = pythonCache.appendingPathComponent("\(version)/current.pyc")
    let previous = pythonCache.appendingPathComponent("0.0.0-previous/previous.pyc")
    let unversioned = pythonCache.appendingPathComponent("private/var/unversioned.pyc")
    for file in [current, previous, unversioned] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: file)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try XCTUnwrap(strdup(UUID().uuidString))
    defer {
      ios_setStreams(stdin, stdout, stderr)
      ios_closeSession(UnsafeRawPointer(session))
      free(session)
    }
    ios_switchSession(UnsafeRawPointer(session))
    ios_setStreams(stdin, stdout, stderr)
    XCTAssertEqual(ios_setSystemPaths(root, root, caches, root, root, root), 1)
    XCTAssertEqual(
      String(cString: try XCTUnwrap(getenv("PYTHONPYCACHEPREFIX"))),
      pythonCache.appendingPathComponent(version).path)
    // A "dev" cache cannot be tied to the sources that wrote it, so it never survives.
    XCTAssertEqual(FileManager.default.fileExists(atPath: current.path), version != "dev")
    XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: unversioned.path))
  }

  func testTruncatedCaptureResetsOffset() throws {
    let active = expectation(description: "Command waits")
    let started = expectation(description: "Initial response")
    var release: ((Result<URL, Error>) -> Void)?
    var jobID: Int?
    var initial = ""
    BashTool(
      command: "capture_test 0 0", timeout: 10, refresh: 0,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        release = completion
        active.fulfill()
      })
    ) { response in
      initial = response.text
      jobID = response.text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) }
      started.fulfill()
    }
    wait(for: [active, started], timeout: 5)
    defer { release?(.success(directory)) }
    let id = try XCTUnwrap(jobID)
    BashStatusTool(jobID: id).invoke { response in
      XCTAssertTrue(
        (initial + response.text).contains("captured before wait"), initial + response.text)
    }
    let capture = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LocalCodeBash/job-\(getpid())-\(id)-stdout.txt")
    let handle = try FileHandle(forWritingTo: capture)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("new\n".utf8))
    try handle.close()
    release?(.success(directory))
    release = nil
    let finished = expectation(description: "New output after truncation is visible")
    BashWaitTool(jobID: id, refresh: 10).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertTrue(response.text.contains("stdout:\nnew"), response.text)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
  }

  func testCaptureReadFailureRetriesWithoutLosingOrDuplicatingOutput() throws {
    let active = expectation(description: "Command waits")
    let started = expectation(description: "Initial response")
    var release: ((Result<URL, Error>) -> Void)?
    var jobID: Int?
    BashTool(
      command: "capture_test 0 0", timeout: 20, refresh: 0,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        release = completion
        active.fulfill()
      })
    ) { response in
      jobID = response.text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) }
      started.fulfill()
    }
    wait(for: [active, started], timeout: 5)
    defer { release?(.success(directory)) }
    let id = try XCTUnwrap(jobID)
    BashStatusTool(jobID: id).invoke { _ in }
    let capture = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LocalCodeBash/job-\(getpid())-\(id)-stdout.txt")
    let handle = try FileHandle(forWritingTo: capture)
    _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data("read-after-recovery\n".utf8))
    try handle.close()
    XCTAssertEqual(chmod(capture.path, 0), 0)
    defer { _ = chmod(capture.path, 0o600) }
    BashStatusTool(jobID: id).invoke { response in
      XCTAssertFalse(response.text.contains("read-after-recovery"), response.text)
    }
    XCTAssertEqual(chmod(capture.path, 0o600), 0)
    let polls = (0..<16).map { expectation(description: "Concurrent poll \($0)") }
    var lock = os_unfair_lock()
    var responses = [String]()
    for poll in polls {
      DispatchQueue.global().async {
        BashStatusTool(jobID: id).invoke { response in
          os_unfair_lock_lock(&lock)
          responses.append(response.text)
          os_unfair_lock_unlock(&lock)
          poll.fulfill()
        }
      }
    }
    wait(for: polls, timeout: 5)
    XCTAssertEqual(
      responses.filter { $0.contains("read-after-recovery") }.count, 1,
      responses.joined(separator: "\n"))
    release?(.success(directory))
    release = nil
    let finished = expectation(description: "Command finishes")
    BashWaitTool(jobID: id, refresh: 10).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertFalse(response.text.contains("read-after-recovery"), response.text)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
  }

  func testCaptureWriteFailureDoesNotPoisonNextCommand() {
    let finished = expectation(description: "Command finishes despite capture write failure")
    BashTool(
      command: "capture_write_failure_test", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    let recovered = expectation(description: "The next command has independent capture")
    BashTool(
      command: "echo recovered", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      XCTAssertTrue(response.text.contains("recovered"), response.text)
      recovered.fulfill()
    }
    wait(for: [recovered], timeout: 10)
  }

  func testNativeRuntimeFailureDoesNotPoisonNextCommand() {
    let failed = expectation(description: "Native runtime failure is reported")
    BashTool(
      command: "runtime_failure_test", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=-1"), response.text)
      failed.fulfill()
    }
    wait(for: [failed], timeout: 10)
    let recovered = expectation(description: "Next command has its own exit status")
    BashTool(
      command: "true", timeout: 5, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      recovered.fulfill()
    }
    wait(for: [recovered], timeout: 10)
  }

  func testGitLFSCommandsAreAvailableInEmbeddedShell() {
    for command in ["git lfs version", "git-lfs version", "/usr/bin/git-lfs version"] {
      let finished = expectation(description: command)
      let tool = BashTool(
        command: command, timeout: 5, refresh: 10,
        projectPath: directory.path, workspacePath: directory.path)
      tool.invoke(context: BashToolContext()) { response in
        XCTAssertTrue(response.text.contains("exit=0"), response.text)
        XCTAssertTrue(response.text.contains("git-lfs (ios_system native client)"), response.text)
        finished.fulfill()
      }
      wait(for: [finished], timeout: 10)
    }
  }

  func testDrawThingsHasItsOwnExclusiveQueue() {
    let active = expectation(description: "Draw Things command started")
    let unrelatedFinished = expectation(description: "General exclusive command finished")
    let activeFinished = expectation(description: "Draw Things command finished")
    let queuedStarted = expectation(description: "Second Draw Things command started")
    let queuedFinished = expectation(description: "Second Draw Things command finished")
    var lock = os_unfair_lock()
    var release: ((Result<URL, Error>) -> Void)?
    var hasReleased = false
    let first = BashTool(
      command: "draw-things-cli 0 0", timeout: 10, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path)
    first.invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        os_unfair_lock_lock(&lock)
        release = completion
        os_unfair_lock_unlock(&lock)
        active.fulfill()
      })
    ) { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      activeFinished.fulfill()
    }
    wait(for: [active], timeout: 5)
    let second = BashTool(
      command: "/usr/bin/draw-things-cli 0 0", timeout: 10, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path)
    second.invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        os_unfair_lock_lock(&lock)
        XCTAssertTrue(hasReleased, "Draw Things invocations must remain exclusive")
        os_unfair_lock_unlock(&lock)
        queuedStarted.fulfill()
        completion(.success(self.directory))
      })
    ) { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      queuedFinished.fulfill()
    }
    let unrelated = BashTool(
      command: "interaction_test 0 0", timeout: 2, refresh: 10,
      projectPath: directory.path, workspacePath: directory.path)
    unrelated.invoke(
      context: BashToolContext(resloveDrawThingsModelsDirectory: { _, _, completion in
        completion(.success(self.directory))
      })
    ) { response in
      XCTAssertTrue(response.text.contains("exit=0"), response.text)
      unrelatedFinished.fulfill()
    }
    wait(for: [unrelatedFinished], timeout: 5)
    os_unfair_lock_lock(&lock)
    hasReleased = true
    let completion = release
    os_unfair_lock_unlock(&lock)
    completion?(.success(directory))
    wait(for: [activeFinished, queuedStarted, queuedFinished], timeout: 5)
  }

  func testUserAndSystemInteractionsOutlastTimeoutAndRefresh() throws {
    for isUserInteraction in [true, false] {
      let presented = expectation(description: "Picker presented")
      let finished = expectation(description: "Bash finished")
      var request: BashUserInteraction.Request?
      var selection: ((Result<URL, Error>) -> Void)?
      let context = BashToolContext(resloveDrawThingsModelsDirectory: {
        _, interaction, completion in
        request = interaction.begin(isUserInteraction: isUserInteraction)
        selection = completion
        presented.fulfill()
      })
      // Leave room for command startup and the 150 ms of simulated work;
      // the 800 ms picker interval must still outlast both budgets.
      let tool = BashTool(
        command: "interaction_test 100 50", timeout: 0.5, refresh: 0.5,
        projectPath: directory.path, workspacePath: directory.path)
      tool.invoke(context: context) { response in
        XCTAssertTrue(response.text.contains("status=completed"), response.text)
        XCTAssertTrue(response.text.contains("exit=0"), response.text)
        XCTAssertFalse(response.text.contains("Timed out"), response.text)
        finished.fulfill()
      }
      wait(for: [presented], timeout: 5)
      let startTime = CACurrentMediaTime()
      Thread.sleep(forTimeInterval: 0.8)
      XCTAssertEqual(
        CACurrentMediaTime() - startTime
          - context.bashUserInteraction.systemInteractionInterval(since: startTime), 0,
        accuracy: 0.01)
      let elapsed = CACurrentMediaTime() - startTime
      XCTAssertEqual(
        context.bashUserInteraction.userInteractionInterval(since: startTime),
        isUserInteraction ? elapsed : 0, accuracy: 0.01)
      XCTAssertTrue(context.bashUserInteraction.cancel(try XCTUnwrap(request)))
      selection?(.success(directory))
      wait(for: [finished], timeout: 5)
    }
  }

  func testTimeoutResumesWithRemainingBudget() throws {
    for isUserInteraction in [true, false] {
      let presented = expectation(description: "Picker presented")
      let finished = expectation(description: "Bash timed out after selection")
      var request: BashUserInteraction.Request?
      var selection: ((Result<URL, Error>) -> Void)?
      let context = BashToolContext(resloveDrawThingsModelsDirectory: {
        _, interaction, completion in
        request = interaction.begin(isUserInteraction: isUserInteraction)
        selection = completion
        presented.fulfill()
      })
      // 250ms before the picker leaves 550ms, less than the 700ms after selection.
      let tool = BashTool(
        command: "interaction_test 250 700", timeout: 0.8, refresh: 5,
        projectPath: directory.path, workspacePath: directory.path)
      tool.invoke(context: context) { response in
        XCTAssertTrue(response.text.contains("Timed out after 0.8 seconds."), response.text)
        XCTAssertTrue(response.text.contains("status=stopped"), response.text)
        finished.fulfill()
      }
      wait(for: [presented], timeout: 5)
      Thread.sleep(forTimeInterval: 1)
      XCTAssertTrue(context.bashUserInteraction.cancel(try XCTUnwrap(request)))
      selection?(.success(directory))
      wait(for: [finished], timeout: 5)
    }
  }

  func testWaitStartsDuringPickerAndFinishesOnUserCancellation() throws {
    let presented = expectation(description: "Picker presented")
    let started = expectation(description: "Job identifier returned")
    let finished = expectation(description: "Wait completes after picker cancellation")
    var jobID: Int?
    var request: BashUserInteraction.Request?
    var selection: ((Result<URL, Error>) -> Void)?
    let context = BashToolContext(resloveDrawThingsModelsDirectory: { _, interaction, completion in
      request = interaction.begin(isUserInteraction: true)
      selection = completion
      presented.fulfill()
    })
    let tool = BashTool(
      command: "interaction_test 250 1000", timeout: 2, refresh: 0,
      projectPath: directory.path, workspacePath: directory.path)
    tool.invoke(context: context) { response in
      jobID = response.text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) }
      started.fulfill()
    }
    wait(for: [started, presented], timeout: 5)
    BashWaitTool(jobID: try XCTUnwrap(jobID), refresh: 0.1).invoke { response in
      XCTAssertTrue(response.text.contains("status=completed"), response.text)
      XCTAssertTrue(response.text.contains("exit=1"), response.text)
      finished.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.4)
    XCTAssertTrue(context.bashUserInteraction.cancel(try XCTUnwrap(request)))
    selection?(.failure(InteractionTestError.cancelled))
    wait(for: [finished], timeout: 5)
  }

  func testEarlierInteractionsDoNotExtendNewJobTimeout() throws {
    var recordedTime: TimeInterval? = CACurrentMediaTime() - 20
    let interaction = BashUserInteraction(time: { recordedTime ?? CACurrentMediaTime() })
    let request = interaction.begin(isUserInteraction: true)
    recordedTime! += 10
    interaction.cancel(request)
    recordedTime = nil
    let finished = expectation(description: "New Bash job times out without inheriting old waits")
    let context = BashToolContext(
      resloveDrawThingsModelsDirectory: { _, _, completion in
        completion(.success(self.directory))
      }, bashUserInteraction: interaction)
    let tool = BashTool(
      command: "interaction_test 0 2000", timeout: 0.2, refresh: 5,
      projectPath: directory.path, workspacePath: directory.path)
    tool.invoke(context: context) { response in
      XCTAssertTrue(response.text.contains("Timed out after 0.2 seconds."), response.text)
      XCTAssertTrue(response.text.contains("status=stopped"), response.text)
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
  }

  func testPermitHelpAndInvalidArgumentsDoNotPresentPicker() {
    let context = BashToolContext(permitDirectory: { _, _, _, completion in
      XCTFail("Help and invalid arguments must not present a picker")
      completion(.failure(InteractionTestError.cancelled))
    })
    XCTAssertTrue(runPermit("permit --help", context: context).contains("exit=0"))
    for command in ["permit", "permit first second", "permit ''", "permit --invalid"] {
      let response = runPermit(command, context: context)
      XCTAssertTrue(response.contains("exit=2"), response)
      XCTAssertTrue(response.contains("Usage: permit"), response)
    }
    let unavailable = runPermit("permit .", context: BashToolContext())
    XCTAssertTrue(unavailable.contains("exit=1"), unavailable)
    XCTAssertTrue(unavailable.contains("only available in the Local Code app"), unavailable)
  }

  func testPermitResolvesShellPathsAndPreservesHostCapabilitiesAcrossTurns() throws {
    var requested = [URL]()
    var permitted = [URL]()
    let context = BashToolContext(
      permitDirectory: { url, _, _, completion in
        requested.append(url)
        permitted.append(url)
        completion(.success(url))
      }, permittedDirectoryURLs: { permitted })
    let interaction = BashUserInteraction()
    let turn = context.with(bashUserInteraction: interaction)
    XCTAssertTrue(turn.bashUserInteraction === interaction)
    XCTAssertTrue(turn.permittedDirectoryURLs().isEmpty)
    for (command, suffix) in [
      ("permit 'Folder With Spaces'", "Folder With Spaces"),
      ("permit -- '-folder'", "-folder"),
      ("permit '~/nested'", "nested"),
      ("mkdir -p child; cd child; permit '../selected'", "selected"),
    ] {
      let target = directory.appendingPathComponent(suffix, isDirectory: true)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      let response = runPermit(command, context: turn)
      let expected = target.standardizedFileURL.resolvingSymlinksInPath()
      XCTAssertEqual(requested.last?.resolvingSymlinksInPath().path, expected.path)
      XCTAssertTrue(response.contains("Permitted: \(expected.path)"), response)
      XCTAssertTrue(response.contains("exit=0"), response)
    }
    XCTAssertEqual(turn.permittedDirectoryURLs().count, 4)
  }

  func testPermitWaitExcludesUserTimeAndUserCancellationResumesBash() throws {
    for accept in [true, false] {
      let presented = expectation(description: "Permission picker presented")
      let finished = expectation(description: "Permission command finished")
      var request: BashUserInteraction.Request?
      var selection: ((Result<URL, Error>) -> Void)?
      let context = BashToolContext(permitDirectory: { _, interaction, _, completion in
        request = interaction.begin(isUserInteraction: true)
        selection = completion
        presented.fulfill()
      })
      BashTool(
        command: "permit .", timeout: 0.3, refresh: 0.1,
        projectPath: directory.path, workspacePath: directory.path
      ).invoke(context: context) { response in
        XCTAssertTrue(response.text.contains("status=completed"), response.text)
        XCTAssertTrue(response.text.contains(accept ? "exit=0" : "exit=1"), response.text)
        XCTAssertFalse(response.text.contains("Timed out"), response.text)
        finished.fulfill()
      }
      wait(for: [presented], timeout: 5)
      Thread.sleep(forTimeInterval: 0.6)
      XCTAssertTrue(context.bashUserInteraction.cancel(try XCTUnwrap(request)))
      selection?(accept ? .success(directory) : .failure(InteractionTestError.cancelled))
      wait(for: [finished], timeout: 5)
    }
  }

  func testStoppingPermitNotifiesHostAndWaitsForPickerCleanup() throws {
    let presented = expectation(description: "Permission picker presented")
    let started = expectation(description: "Bash job started")
    let stopped = expectation(description: "Bash stopped")
    var jobID: Int?
    var isCancelled: (() -> Bool)?
    var request: BashUserInteraction.Request?
    var selection: ((Result<URL, Error>) -> Void)?
    let context = BashToolContext(permitDirectory: { _, interaction, cancelled, completion in
      request = interaction.begin(isUserInteraction: true)
      isCancelled = cancelled
      selection = completion
      presented.fulfill()
    })
    BashTool(
      command: "permit .", timeout: 2, refresh: 0,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(context: context) { response in
      jobID = response.text.split(separator: "\n").first.flatMap { Int($0.dropFirst(4)) }
      started.fulfill()
    }
    wait(for: [started, presented], timeout: 5)
    BashStopTool(jobID: try XCTUnwrap(jobID)).invoke { response in
      XCTAssertTrue(response.text.contains("status=stopped"), response.text)
      stopped.fulfill()
    }
    XCTAssertTrue(try XCTUnwrap(isCancelled)())
    XCTAssertTrue(context.bashUserInteraction.cancel(try XCTUnwrap(request)))
    selection?(.failure(InteractionTestError.cancelled))
    wait(for: [stopped], timeout: 5)
  }

  private func runPermit(_ command: String, context: BashToolContext) -> String {
    let finished = expectation(description: command)
    var result = ""
    BashTool(
      command: command, timeout: 5, refresh: 5,
      projectPath: directory.path, workspacePath: directory.path
    ).invoke(context: context) { response in
      result = response.text
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    return result
  }
}
