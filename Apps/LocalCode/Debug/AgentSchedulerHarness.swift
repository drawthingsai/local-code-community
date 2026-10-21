import BashToolContext
import Dflat
import Foundation
import NNC
import ProjectHistoryManager
import SQLiteDflat
import Tokenizer
import WebSearch

private enum HarnessError: LocalizedError {
  case invalidArgument(String)
  case missingFile(String)
  case timeout(String)
  case invariant(String)

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let argument): return "Invalid argument: \(argument)"
    case .missingFile(let path): return "File does not exist: \(path)"
    case .timeout(let scenario): return "Timed out while running \(scenario)."
    case .invariant(let message): return "Harness invariant failed: \(message)"
    }
  }
}

private enum Scenario: String {
  case hotPreempt = "hot-preempt"
  case cappedHot = "capped-hot"
  case fifo
  case foregroundToolWait = "foreground-tool-wait"
  case backgroundToolWait = "background-tool-wait"
  case stop
  case completionReasons = "completion-reasons"
  case generatorReuse = "generator-reuse"
  case residentRestore = "resident-restore"
  case queuedContinuation = "queued-continuation"
  case hibernate
  case hibernateToolWait = "hibernate-tool-wait"
  case coldResumePrime = "cold-resume-prime"
  case coldResumeFinish = "cold-resume-finish"
  case suspensionStore = "suspension-store"
  case temporary
  case memory
  case all
}

private struct Options {
  var modelPath = ""
  var projectPath: String?
  var workspacePath: String?
  var scenario = Scenario.hotPreempt
  var pauseAfterTokens = 8
  var stopAfterTokens = 48
  var thinkingBudget = 0
  var timeout: TimeInterval = 600
  var printProgress = false
  var disableMFAAppleNeuralEngine = false

  static func parse() throws -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      func value() throws -> String {
        guard !arguments.isEmpty else { throw HarnessError.invalidArgument(argument) }
        return arguments.removeFirst()
      }
      func positiveInteger() throws -> Int {
        guard let result = Int(try value()), result > 0 else {
          throw HarnessError.invalidArgument(argument)
        }
        return result
      }
      switch argument {
      case "--model-path": options.modelPath = try value()
      case "--project-path": options.projectPath = try value()
      case "--workspace-path": options.workspacePath = try value()
      case "--scenario":
        let rawValue = try value()
        guard let scenario = Scenario(rawValue: rawValue) else {
          throw HarnessError.invalidArgument(argument)
        }
        options.scenario = scenario
      case "--pause-after-tokens": options.pauseAfterTokens = try positiveInteger()
      case "--stop-after-tokens": options.stopAfterTokens = try positiveInteger()
      case "--thinking-budget":
        guard let result = Int(try value()), result >= 0 else {
          throw HarnessError.invalidArgument(argument)
        }
        options.thinkingBudget = result
      case "--timeout":
        guard let result = TimeInterval(try value()), result > 0 else {
          throw HarnessError.invalidArgument(argument)
        }
        options.timeout = result
      case "--print-progress": options.printProgress = true
      case "--disable-mfa-apple-neural-engine":
        options.disableMFAAppleNeuralEngine = true
      default: throw HarnessError.invalidArgument(argument)
      }
    }
    guard
      !options.modelPath.isEmpty || options.scenario == .completionReasons
        || options.scenario == .generatorReuse
    else {
      throw HarnessError.invalidArgument("--model-path is required")
    }
    options.modelPath = (options.modelPath as NSString).expandingTildeInPath
    options.projectPath = options.projectPath.map {
      ($0 as NSString).expandingTildeInPath
    }
    options.workspacePath = options.workspacePath.map {
      ($0 as NSString).expandingTildeInPath
    }
    return options
  }
}

private final class EventRecorder {
  private let lock = NSLock()
  private var sequence = 0
  private var events = [String]()
  private let printProgress: Bool

  init(printProgress: Bool) {
    self.printProgress = printProgress
  }

  func record(_ event: String) {
    lock.lock()
    sequence += 1
    let line = String(format: "[%03d] %@", sequence, event)
    events.append(line)
    lock.unlock()
    if printProgress {
      print(line)
      fflush(stdout)
    }
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

private struct ExpectedResult: Codable {
  var outputTokens: [Int32]
  var logTokens: [Int32]
}

private final class ResultBox {
  var result: CodeAgentResult?
}

private final class SchedulerStateObserver: AgentSchedulerDelegate {
  private let threadId: Int64
  private(set) var didHibernate = false
  private(set) var isActive = false
  private(set) var inactiveNotificationCount = 0

  init(threadId: Int64) {
    self.threadId = threadId
  }

  func agentScheduler(
    _ scheduler: AgentScheduler,
    didActiveThreadsChange activeThreads: [(
      projectPath: String, threadId: Int64, state: AgentScheduler.State
    )]
  ) {
    isActive = activeThreads.contains { $0.threadId == threadId }
    if !isActive {
      inactiveNotificationCount += 1
    }
    didHibernate =
      didHibernate
      || activeThreads.contains {
        $0.threadId == threadId && $0.state == .hibernated
      }
  }
}

@main
private struct AgentSchedulerHarness {
  private static let longPrompt =
    "Write the integers from 1 through 120, one integer per line. Do not skip any integer."
  private static let shortPrompt = "Reply with exactly the word OK and nothing else."
  private static let toolPrompt =
    "You must use the bash tool exactly once to run "
    + "`/bin/sleep 2; /usr/bin/printf scheduler-tool-ok`. "
    + "After the tool returns, reply with exactly scheduler-tool-ok."

  static func main() throws {
    let options = try Options.parse()
    if options.scenario == .completionReasons {
      try runCompletionReasons()
      print("PASS scenario=completion-reasons")
      return
    }
    if options.scenario == .generatorReuse {
      try runGeneratorReuse()
      print("PASS scenario=generator-reuse")
      return
    }
    guard FileManager.default.fileExists(atPath: options.modelPath) else {
      throw HarnessError.missingFile(options.modelPath)
    }
    let oldFlags = DynamicGraph.flags
    if options.disableMFAAppleNeuralEngine {
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    }
    let oldQueueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = 128
    defer {
      DynamicGraph.flags = oldFlags
      DynamicGraph.queueWatermark = oldQueueWatermark
    }

    let temporaryProject: URL?
    let projectURL: URL
    if let projectPath = options.projectPath {
      temporaryProject = nil
      projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    } else {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "agent-scheduler-harness-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      temporaryProject = url
      projectURL = url
    }
    defer {
      if let temporaryProject {
        try? FileManager.default.removeItem(at: temporaryProject)
      }
    }
    let metadataURL = projectURL.appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("metadata.sqlite3", isDirectory: false)
    try FileManager.default.createDirectory(
      at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let projectWorkspace = SQLiteWorkspace(
      filePath: metadataURL.path, fileProtectionLevel: .noProtection)
    defer { projectWorkspace.shutdown(flags: []) }

    let recorder = EventRecorder(printProgress: options.printProgress)
    if options.scenario == .suspensionStore {
      try runSuspensionStore(projectURL: projectURL, recorder: recorder)
      print("PASS scenario=\(options.scenario.rawValue)")
      return
    }

    let textGenerator = DeepSeek4TextGenerator(
      filePath: options.modelPath, chunkedPrefillMaxLength: 4_096)
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let streamContext = StreamContext(.GPU(0))
    func makeAgent() -> DeepSeek4CodeAgent<DeepSeek4TextGenerator> {
      let agent = DeepSeek4CodeAgent(
        textGenerator: textGenerator, graph: graph, streamContext: streamContext,
        unsafeTokenizer: DeepSeek4TextGenerator.unsafeTokenizer,
        safeTokenizer: DeepSeek4TextGenerator.safeTokenizer,
        systemPromptTemplate: systemPromptForDeepSeek4,
        memoryContext: options.scenario == .memory
          ? MemoryContext.load(projectPath: projectURL.path) : .empty)
      agent.thinkingBudget = Int32(options.thinkingBudget)
      agent.deterministic = true
      return agent
    }

    let workspacePath = options.workspacePath ?? projectURL.path
    switch options.scenario {
    case .completionReasons, .generatorReuse:
      preconditionFailure("Handled before loading a model")
    case .memory:
      try runMemory(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .temporary:
      try runTemporary(
        options: options, projectURL: projectURL, workspacePath: workspacePath,
        agent: makeAgent(), recorder: recorder)
    case .hotPreempt:
      try runHotPreempt(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .cappedHot:
      try runHotPreempt(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder,
        maximumHotCodeAgentCount: 1, expectHibernation: true,
        keepCompletedForeground: true)
      try runFIFO(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder,
        maximumHotCodeAgentCount: 1)
      try runFIFO(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder,
        maximumHotCodeAgentCount: 1)
    case .fifo:
      try runFIFO(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .foregroundToolWait:
      try runToolWait(
        backgroundYield: false, options: options, projectURL: projectURL,
        projectWorkspace: projectWorkspace, workspacePath: workspacePath,
        makeAgent: makeAgent, recorder: recorder)
    case .backgroundToolWait:
      try runToolWait(
        backgroundYield: true, options: options, projectURL: projectURL,
        projectWorkspace: projectWorkspace, workspacePath: workspacePath,
        makeAgent: makeAgent, recorder: recorder)
    case .stop:
      try runStop(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .residentRestore:
      try runResidentRestore(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .queuedContinuation:
      try runQueuedContinuation(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .hibernate, .coldResumePrime:
      try runHibernatePrime(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder,
        saveBaseline: options.scenario == .coldResumePrime)
    case .hibernateToolWait:
      try runHibernateToolWait(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .coldResumeFinish:
      try runColdResumeFinish(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    case .suspensionStore:
      preconditionFailure("suspension-store is handled before loading the model")
    case .all:
      try runHotPreempt(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
      try runHotPreempt(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder,
        maximumHotCodeAgentCount: 1, expectHibernation: true)
      try runFIFO(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
      try runStop(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
      try runResidentRestore(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
      try runQueuedContinuation(
        options: options, projectURL: projectURL, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, makeAgent: makeAgent, recorder: recorder)
    }
    print("PASS scenario=\(options.scenario.rawValue)")
  }

  private static func runMemory(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder
  ) throws {
    _ = try ProjectMemory.update(
      projectPath: projectURL.path, target: .memory, action: "append",
      content: "The project code is cobalt.", oldText: nil)
    let agent = makeAgent()
    let answer = agent.ask(
      "What is the project code? Reply with only the code.", imagePaths: [], isMemoryEnabled: true,
      threadId: 902,
      projectPath: projectURL.path, workspacePath: workspacePath, webSearchProvider: .disabled
    ) { _, _ in .continue }
    guard answer.output.lowercased().contains("cobalt") else {
      throw HarnessError.invariant("loaded memory was not used: \(answer.output)")
    }
    recorder.record("loaded project memory in the system prompt")
    _ = agent.ask(
      "For future work on this project, I prefer synchronous Swift utility functions. Acknowledge with OK. Do not update memory yet.",
      imagePaths: [], isMemoryEnabled: true, threadId: 902, projectPath: projectURL.path,
      workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { _, _ in .continue }
    let boundary = agent.statistics.contextUsedTokens
    let scheduler = AgentScheduler(queue: DispatchQueue(label: "agent-scheduler-harness.memory"))
    scheduler.setForeground(agent)
    let completed = DispatchSemaphore(value: 0)
    var review: CodeAgentResult?
    scheduler.ask(
      agent, threadId: 902, ProjectMemory.reviewPrompt, isMemoryEnabled: true, temporary: true,
      allowedTools: [.memory], projectPath: projectURL.path, projectWorkspace: projectWorkspace,
      workspacePath: workspacePath, webSearchProvider: .disabled
    ) { event, _ in
      if case .compact = event { preconditionFailure("Memory review compacted") }
    } completion: { result, _ in
      review = result
      completed.signal()
    }
    try wait(completed, timeout: options.timeout, scenario: "memory review")
    guard let review, !review.toolCallHistory.isEmpty,
      review.toolCallHistory.allSatisfy({ $0.request.function == "memory" }),
      agent.statistics.contextUsedTokens == boundary, agent.suspendedResult == nil,
      !scheduler.hasActiveTurn(agent),
      DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096).loadSuspension(
        threadId: 902) == nil
    else { throw HarnessError.invariant("review did not complete with restored context") }
    let userFile = try ProjectMemory.fileURL(projectPath: projectURL.path, target: .user)
    let user = try String(contentsOf: userFile, encoding: .utf8)
    guard user.lowercased().contains("swift"), user.lowercased().contains("sync") else {
      throw HarnessError.invariant(
        "review did not save the user preference: \(user); answer=\(review.output)")
    }
    recorder.record("review saved USER.md and restored context; feedback=\(review.output)")
    let cancelled = DispatchSemaphore(value: 0)
    var didStop = false
    scheduler.ask(
      agent, threadId: 902, ProjectMemory.reviewPrompt, isMemoryEnabled: true, temporary: true,
      allowedTools: [.memory], projectPath: projectURL.path, projectWorkspace: projectWorkspace,
      workspacePath: workspacePath, webSearchProvider: .disabled
    ) { event, _ in
      if case .prefill = event, !didStop {
        didStop = true
        onMainQueue { scheduler.stop(agent) }
      }
    } completion: { _, _ in
      cancelled.signal()
    }
    try wait(cancelled, timeout: options.timeout, scenario: "memory review cancellation")
    guard didStop, agent.statistics.contextUsedTokens == boundary,
      agent.suspendedResult == nil, !scheduler.hasActiveTurn(agent)
    else { throw HarnessError.invariant("cancelled review did not restore the active agent") }
    recorder.record("scheduler cancellation restored the agent without a suspension")
    let hibernated = DispatchSemaphore(value: 0)
    var didRequestHibernation = false
    var didCompleteReview = false
    var hibernationResult: Result<Void, Swift.Error>?
    scheduler.ask(
      agent, threadId: 902, ProjectMemory.reviewPrompt, isMemoryEnabled: true, temporary: true,
      allowedTools: [.memory], projectPath: projectURL.path, projectWorkspace: projectWorkspace,
      workspacePath: workspacePath, webSearchProvider: .disabled
    ) { event, _ in
      if case .prefill = event, !didRequestHibernation {
        didRequestHibernation = true
        scheduler.hibernateAll { result in
          hibernationResult = result
          hibernated.signal()
        }
      }
    } completion: { _, _ in
      didCompleteReview = true
    }
    try wait(hibernated, timeout: options.timeout, scenario: "memory review hibernation")
    try hibernationResult?.get()
    guard didRequestHibernation, didCompleteReview,
      agent.statistics.contextUsedTokens == boundary, agent.suspendedResult == nil,
      !scheduler.hasActiveTurn(agent),
      DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096).loadSuspension(
        threadId: 902) == nil
    else { throw HarnessError.invariant("hibernation did not cancel and restore memory review") }
    recorder.record("hibernation cancelled review without saving a temporary suspension")
    let normal = agent.ask(
      "What is the project code? Reply with only the code.", imagePaths: [], isMemoryEnabled: true,
      threadId: 902,
      projectPath: projectURL.path, workspacePath: workspacePath, webSearchProvider: .disabled
    ) { _, _ in .continue }
    guard normal.output.lowercased().contains("cobalt") else {
      throw HarnessError.invariant("normal continuation lost original memory: \(normal.output)")
    }
    recorder.record("normal conversation continued with saved memory retained on disk")
  }

  private static func runTemporary(
    options: Options, projectURL: URL, workspacePath: String,
    agent: any CodeAgent, recorder: EventRecorder
  ) throws {
    let deadline = Date(timeIntervalSinceNow: options.timeout)
    let cache = DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096)
    let threadId: Int64 = 901
    func progress(_ progress: CodeAgentProgress, _ statistics: CodeAgentStatistics)
      -> ContinuationState
    {
      if Date() > deadline { return .abort }
      if case .compact = progress {
        preconditionFailure("Temporary asks must not compact")
      }
      return .checkpoint
    }
    func ask(_ prompt: String, temporary: Bool) -> CodeAgentResult {
      agent.ask(
        prompt, imagePaths: [], isMemoryEnabled: false, temporary: temporary, allowedTools: nil,
        threadId: threadId,
        projectPath: projectURL.path,
        workspacePath: workspacePath, webSearchProvider: .disabled, progress: progress)
    }
    var boundary = agent.statistics.contextUsedTokens
    func checkRestored(_ result: CodeAgentResult) throws {
      guard Date() <= deadline else { throw HarnessError.timeout("temporary") }
      guard !result.compacted, agent.suspendedResult == nil,
        agent.statistics.contextUsedTokens == boundary,
        cache.loadSuspension(threadId: threadId) == nil
      else { throw HarnessError.invariant("temporary ask retained context or a checkpoint") }
    }

    var pausedForTools = false
    var toolResult = agent.ask(
      toolPrompt, imagePaths: [], isMemoryEnabled: false, temporary: true, allowedTools: nil,
      threadId: threadId,
      projectPath: projectURL.path,
      workspacePath: workspacePath, webSearchProvider: .disabled
    ) { event, statistics in
      if case .toolsWait = event {
        pausedForTools = true
        return .pause
      }
      return progress(event, statistics)
    }
    if agent.suspendedResult != nil {
      toolResult = agent.resume(progress: progress)
    }
    try checkRestored(toolResult)
    guard pausedForTools, !toolResult.toolCallHistory.isEmpty, !toolResult.logTokens.isEmpty else {
      throw HarnessError.invariant(
        "temporary tool round failed: paused=\(pausedForTools), "
          + "tools=\(toolResult.toolCallHistory), output=\(toolResult.output)")
    }
    recorder.record("temporary tool round restored context")

    let initial = ask(
      "Remember the project code is cobalt. Reply with exactly OK.", temporary: false)
    guard !initial.logTokens.isEmpty else {
      throw HarnessError.invariant("initial ask did not finish")
    }
    boundary = agent.statistics.contextUsedTokens

    let query = "What is the project code? Reply with only the code."
    let expected = ask(query, temporary: true)
    try checkRestored(expected)
    guard !expected.outputTokens.isEmpty, !expected.logTokens.isEmpty else {
      throw HarnessError.invariant("empty temporary answer or result log")
    }
    recorder.record("temporary completion restored context; answer=\(expected.output)")

    // Cross raw-window/compressor boundaries, then pause and abort after resuming.
    var didPause = false
    let partial = agent.ask(
      String(repeating: "Temporary filler. ", count: 300) + longPrompt,
      imagePaths: [], isMemoryEnabled: false, temporary: true, allowedTools: nil,
      threadId: threadId,
      projectPath: projectURL.path,
      workspacePath: workspacePath, webSearchProvider: .disabled
    ) { event, statistics in
      if case .prefill(_, let completed, _) = event, completed > 0 {
        didPause = true
        return .pause
      }
      return progress(event, statistics)
    }
    guard didPause, agent.suspendedResult != nil,
      cache.loadSuspension(threadId: threadId) == nil
    else {
      throw HarnessError.invariant(
        "temporary pause failed: paused=\(didPause), suspended=\(agent.suspendedResult != nil), "
          + "checkpoint=\(cache.loadSuspension(threadId: threadId) != nil), output=\(partial.output)"
      )
    }
    let stopped = agent.resume { _, _ in .abort }
    try checkRestored(stopped)
    recorder.record("temporary pause/resume/abort restored context")
    let afterStop = ask(query, temporary: true)
    try checkRestored(afterStop)
    guard afterStop.outputTokens == expected.outputTokens else {
      throw HarnessError.invariant("answer after stop changed: \(afterStop.output)")
    }

    _ = agent.ask(
      longPrompt, imagePaths: [], isMemoryEnabled: false, temporary: true, allowedTools: nil,
      threadId: threadId,
      projectPath: projectURL.path,
      workspacePath: workspacePath, webSearchProvider: .disabled
    ) { event, statistics in
      if case .prefill(_, let completed, _) = event, completed > 0 { return .pause }
      return progress(event, statistics)
    }
    guard agent.suspendedResult != nil else {
      throw HarnessError.invariant("missing temporary suspension")
    }
    try agent.hibernate(threadId: threadId)
    try checkRestored(.empty)
    recorder.record("temporary hibernation discarded suspension")

    var prefillLength = 0
    let actual = agent.ask(
      query, imagePaths: [], isMemoryEnabled: false, temporary: false, allowedTools: nil,
      threadId: threadId,
      projectPath: projectURL.path,
      workspacePath: workspacePath, webSearchProvider: .disabled
    ) { event, statistics in
      if case .prefill(_, _, let length) = event { prefillLength = max(prefillLength, length) }
      return progress(event, statistics)
    }
    guard actual.outputTokens == expected.outputTokens, actual.logTokens == expected.logTokens,
      prefillLength > 0, prefillLength < boundary
    else {
      throw HarnessError.invariant("normal continuation changed or rebuilt the original prefix")
    }
    recorder.record("normal continuation matched baseline and reused prefix KV")
  }

  private static func runSuspensionStore(projectURL: URL, recorder: EventRecorder) throws {
    let firstThreadId: Int64 = 801
    let secondThreadId: Int64 = 802
    let payload = Data([0, 1, 2, 127, 128, 254, 255])
    let cache = DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096)
    cache.saveSuspension(payload, threadId: firstThreadId)
    cache.saveSuspension(payload, threadId: secondThreadId)
    guard cache.loadSuspension(threadId: firstThreadId) == payload,
      cache.loadSuspension(threadId: secondThreadId) == payload
    else { throw HarnessError.invariant("UInt8 suspension payload did not round-trip") }

    guard let storePath = contextCacheStorePath(projectPath: projectURL.path) else {
      throw HarnessError.invariant("context-cache store path is unavailable")
    }
    let storedAsUInt8 = DynamicGraph().openStore(storePath, flags: .readOnly) { store in
      store.read("suspension/\(firstThreadId)/state", kind: .CPU)?.dataType == .UInt8
        && store.read("suspension/\(secondThreadId)/state", kind: .CPU)?.dataType == .UInt8
    }
    guard case .success(true) = storedAsUInt8 else {
      throw HarnessError.invariant("suspension payload was not stored as UInt8")
    }
    recorder.record("UInt8 suspension payload round-tripped")

    cache.removeSuspension(threadId: firstThreadId)
    guard cache.loadSuspension(threadId: firstThreadId) == nil,
      cache.loadSuspension(threadId: secondThreadId) == payload
    else { throw HarnessError.invariant("suspension removal affected the wrong key") }
    cache.removeSuspension(threadId: secondThreadId)
    guard cache.loadSuspension(threadId: secondThreadId) == nil else {
      throw HarnessError.invariant("suspension record was not removed")
    }
    recorder.record("suspension records removed")
  }

  private static func runHotPreempt(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder, maximumHotCodeAgentCount: Int = Int.max,
    expectHibernation: Bool = false, keepCompletedForeground: Bool = false
  ) throws {
    let generationQueue = DispatchQueue(label: "agent-scheduler-harness.hot-preempt")
    let baseline: CodeAgentResult?
    if expectHibernation {
      baseline = nil
    } else {
      let baselineAgent = makeAgent()
      baseline = try runBoundedAsk(
        on: generationQueue, timeout: options.timeout, scenario: "hot-preempt baseline"
      ) {
        gracefullyBoundedAsk(
          baselineAgent, prompt: longPrompt, stopAfterTokens: options.stopAfterTokens,
          projectPath: nil, workspacePath: workspacePath)
      }
    }

    let scheduler = AgentScheduler(
      queue: generationQueue, maximumHotCodeAgentCount: maximumHotCodeAgentCount)
    let stateObserver = SchedulerStateObserver(threadId: 101)
    scheduler.delegate = stateObserver
    let first = makeAgent()
    let second = makeAgent()
    let completed = DispatchSemaphore(value: 0)
    var didPreempt = false
    var didCompleteSecond = false
    var didRequestFirstStop = false
    var scheduledResult: CodeAgentResult?
    scheduler.setForeground(first)
    scheduler.ask(
      first, threadId: 101, longPrompt, isMemoryEnabled: false, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { progress, _ in
      recorder.record("agent=A progress=\(progress.description)")
      guard case .generate(let result) = progress else { return }
      if !didPreempt && result.outputTokens.count >= options.pauseAfterTokens {
        didPreempt = true
        let hasResidentResources = onMainQueue {
          scheduler.residentCodeAgent(projectPath: projectURL.path + "/./", threadId: 101)
            === first
            && scheduler.residentProjectWorkspace(projectPath: projectURL.path + "/./")
              === projectWorkspace
        }
        guard hasResidentResources else { return }
        onMainQueue {
          scheduler.ask(
            second, threadId: 102, shortPrompt, isMemoryEnabled: false,
            projectPath: projectURL.path,
            projectWorkspace: projectWorkspace, workspacePath: workspacePath,
            webSearchProvider: .disabled,
            progress: { progress, _ in
              recorder.record("agent=B progress=\(progress.description)")
            },
            completion: { _, _ in
              didCompleteSecond = true
              recorder.record("agent=B completion")
              onMainQueue {
                scheduler.markAsCompleted(second)
                if !keepCompletedForeground {
                  scheduler.setForeground(first)
                }
              }
            })
          scheduler.setForeground(second)
        }
      } else if didCompleteSecond && !didRequestFirstStop
        && result.outputTokens.count >= options.stopAfterTokens
      {
        didRequestFirstStop = true
        onMainQueue {
          scheduler.stop(first)
        }
      }
    } completion: { result, _ in
      scheduledResult = result
      recorder.record("agent=A completion")
      completed.signal()
    }
    try wait(completed, timeout: options.timeout, scenario: "hot-preempt")
    guard didPreempt else { throw HarnessError.invariant("A was never preempted") }
    guard didCompleteSecond else { throw HarnessError.invariant("B did not complete") }
    if expectHibernation && !stateObserver.didHibernate {
      throw HarnessError.invariant("A was not hibernated before B ran")
    }
    guard let scheduledResult else { throw HarnessError.invariant("A has no result") }
    if let baseline {
      guard scheduledResult.outputTokens == baseline.outputTokens,
        scheduledResult.logTokens == baseline.logTokens
      else {
        throw HarnessError.invariant("pause/resume tokens differ from uninterrupted baseline")
      }
    } else {
      guard !scheduledResult.outputTokens.isEmpty else {
        throw HarnessError.invariant("cold-resumed A produced no output")
      }
      guard
        DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096).loadSuspension(
          threadId: 101) == nil
      else { throw HarnessError.invariant("completed cold suspension was not removed") }
    }
  }

  private static func runFIFO(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder, maximumHotCodeAgentCount: Int = Int.max
  ) throws {
    let queue = DispatchQueue(label: "agent-scheduler-harness.fifo")
    let scheduler = AgentScheduler(
      queue: queue, maximumHotCodeAgentCount: maximumHotCodeAgentCount)
    let agents = [
      makeAgent(), makeAgent(), makeAgent(),
    ]
    let completed = DispatchSemaphore(value: 0)
    var order = [Int]()
    for index in agents.indices {
      scheduler.ask(
        agents[index], threadId: Int64(200 + index), shortPrompt,
        isMemoryEnabled: false, projectPath: projectURL.path, projectWorkspace: projectWorkspace,
        workspacePath: workspacePath, webSearchProvider: .disabled,
        progress: { _, _ in },
        completion: { _, _ in
          order.append(index)
          recorder.record("agent=\(index) completion")
          onMainQueue {
            scheduler.markAsCompleted(agents[index])
          }
          if order.count == agents.count { completed.signal() }
        })
    }
    try wait(completed, timeout: options.timeout, scenario: "fifo")
    guard order == [0, 1, 2] else {
      throw HarnessError.invariant("FIFO completion order was \(order)")
    }
  }

  private static func runToolWait(
    backgroundYield: Bool, options: Options, projectURL: URL,
    projectWorkspace: SQLiteWorkspace, workspacePath: String,
    makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>, recorder: EventRecorder
  ) throws {
    let queue = DispatchQueue(label: "agent-scheduler-harness.tool-wait")
    let scheduler = AgentScheduler(queue: queue)
    let first = makeAgent()
    let second = makeAgent()
    let completed = DispatchSemaphore(value: 0)
    var sawToolsWait = false
    var didEnqueueSecond = false
    var completionOrder = [String]()
    var didStopFirst = false
    scheduler.setForeground(first)
    scheduler.ask(
      first, threadId: 301, toolPrompt, isMemoryEnabled: false, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { progress, _ in
      recorder.record("agent=A progress=\(progress.description)")
      if case .toolsWait = progress, !didEnqueueSecond {
        sawToolsWait = true
        didEnqueueSecond = true
        onMainQueue {
          scheduler.ask(
            second, threadId: 302, shortPrompt, isMemoryEnabled: false,
            projectPath: projectURL.path,
            projectWorkspace: projectWorkspace, workspacePath: workspacePath,
            webSearchProvider: .disabled, progress: { _, _ in },
            completion: { _, _ in
              completionOrder.append("B")
              recorder.record("agent=B completion")
              onMainQueue {
                if backgroundYield { scheduler.setForeground(first) }
              }
              if completionOrder.count == 2 { completed.signal() }
            })
          if backgroundYield { scheduler.setForeground(second) }
        }
      }
      if case .generate(let result) = progress, !result.toolCallHistory.isEmpty,
        result.outputTokens.count >= 8, !didStopFirst
      {
        didStopFirst = true
        onMainQueue {
          scheduler.stop(first)
        }
      }
    } completion: { _, _ in
      completionOrder.append("A")
      recorder.record("agent=A completion")
      onMainQueue {
        if !backgroundYield { scheduler.setForeground(second) }
      }
      if completionOrder.count == 2 { completed.signal() }
    }
    try wait(
      completed, timeout: options.timeout,
      scenario: backgroundYield ? "background-tool-wait" : "foreground-tool-wait")
    guard sawToolsWait else {
      throw HarnessError.invariant("the real model did not produce a tool call")
    }
    let expected = backgroundYield ? ["B", "A"] : ["A", "B"]
    guard completionOrder == expected else {
      throw HarnessError.invariant("tool-wait completion order was \(completionOrder)")
    }
  }

  private static func runGeneratorReuse() throws {
    final class Generator: TextGenerator {
      static var estimatedKVCacheSize: UInt64 { 1 }
      var safeTokenizer: TiktokenTokenizer { fatalError("No tokenization in this scenario") }
      let filePath: String
      let onRelease: () -> Void

      init(filePath: String, onRelease: @escaping () -> Void = {}) {
        self.filePath = filePath
        self.onRelease = onRelease
      }

      deinit { onRelease() }
      func unload() {}
    }

    let queue = DispatchQueue(label: "agent-scheduler-harness.generator-reuse")
    let proceed = DispatchSemaphore(value: 0)
    let hibernated = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    queue.async { proceed.wait() }
    defer { proceed.signal() }
    var retiringScheduler: AgentScheduler? = AgentScheduler(queue: queue)
    var successorScheduler: AgentScheduler? = AgentScheduler(queue: queue)
    weak var originalGenerator: Generator?
    do {
      let generatorA = Generator(filePath: "/generator-reuse/model-a.ckpt") {
        dispatchPrecondition(condition: .onQueue(queue))
        released.signal()
      }
      originalGenerator = generatorA
      retiringScheduler?.set(
        filePath: generatorA.filePath, estimatedKVCacheSize: Generator.estimatedKVCacheSize)
      retiringScheduler?.textGenerator = generatorA
      // An empty scheduler can still be configured again with its original API.
      retiringScheduler?.set(
        filePath: generatorA.filePath, estimatedKVCacheSize: Generator.estimatedKVCacheSize)
    }
    guard originalGenerator != nil else {
      throw HarnessError.invariant("scheduler did not retain the generator")
    }
    // Borrow the generator while retirement is queued but hibernation has not completed.
    retiringScheduler?.hibernateAll { _ in hibernated.signal() }
    do {
      guard let reused = retiringScheduler?.textGenerator,
        reused as? Generator === originalGenerator
      else {
        throw HarnessError.invariant("lost storage during scheduler retirement")
      }
      successorScheduler?.set(
        filePath: reused.filePath, estimatedKVCacheSize: Generator.estimatedKVCacheSize)
      successorScheduler?.textGenerator = reused
    }
    proceed.signal()
    try wait(hibernated, timeout: 10, scenario: "generator retirement")
    guard retiringScheduler?.textGenerator as? Generator === originalGenerator else {
      throw HarnessError.invariant("hibernation discarded the reusable generator")
    }
    retiringScheduler = nil
    guard originalGenerator != nil,
      successorScheduler?.textGenerator as? Generator === originalGenerator
    else { throw HarnessError.invariant("successor did not retain shared storage") }
    successorScheduler = nil
    try wait(released, timeout: 10, scenario: "generator release on generation queue")
    guard originalGenerator == nil else {
      throw HarnessError.invariant("retired generator leaked")
    }
  }

  // Exercise scheduler completion without loading a model or using a GPU. In particular, a
  // stopped turn can return a nonempty response and lose foreground status before completion.
  private static func runCompletionReasons() throws {
    final class Agent: CodeAgent {
      let bashUserInteraction = BashUserInteraction()
      var thinkingBudget: Int32 = 0
      var deterministic = true
      var statistics = CodeAgentStatistics()
      var suspendedResult: CodeAgentResult? { nil }
      var lastAskWasTemporary = false
      var continuation: ContinuationState?
      var hibernateCount = 0
      var unloadCount = 0
      var toolCallStart = ""
      var toolCallEnd = ""
      var toolCallSpecialTokens = [Int32: String]()

      func ask(
        _ prompt: String, imagePaths: [String] = [], isMemoryEnabled: Bool, temporary: Bool,
        allowedTools: Set<ToolsRegistry.Tool>?, threadId: Int64,
        projectPath: String?, workspacePath: String?, webSearchProvider: WebSearchProvider,
        progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
      ) -> CodeAgentResult {
        lastAskWasTemporary = temporary
        return resume(progress: progress)
      }

      func resume(
        progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
      ) -> CodeAgentResult {
        var result = CodeAgentResult.empty
        result.output = "A response, possibly interrupted"
        continuation = progress(.generate(result), statistics)
        return result
      }

      func hibernate(threadId: Int64) throws { hibernateCount += 1 }
      func unloadCaches() { unloadCount += 1 }
      func restoreSuspension(threadId: Int64, projectPath: String) throws -> Bool { false }
      func canStopImmediately(with result: CodeAgentResult) -> Bool { true }
      func isCapReachedForStopping(
        from resultAtStop: CodeAgentResult, to result: CodeAgentResult
      ) -> Bool { true }
    }

    let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "scheduler-completion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let workspace = SQLiteWorkspace(
      filePath: projectURL.appendingPathComponent("test.sqlite3").path,
      fileProtectionLevel: .noProtection)
    defer {
      workspace.shutdown(flags: [])
      try? FileManager.default.removeItem(at: projectURL)
    }
    let queue = DispatchQueue(label: "agent-scheduler-harness.completion-reasons")
    let scheduler = AgentScheduler(queue: queue)
    let agent = Agent()
    let stateObserver = SchedulerStateObserver(threadId: 1)
    scheduler.delegate = stateObserver
    for shouldStop in [false, true, false] {
      var receivedReason: AgentScheduler.CompletionReason?
      var receivedNonemptyResult = false
      var completionCount = 0
      let completed = DispatchSemaphore(value: 0)
      scheduler.setForeground(agent)
      scheduler.ask(
        agent, threadId: 1, "Test", isMemoryEnabled: false, projectPath: projectURL.path,
        projectWorkspace: workspace, workspacePath: projectURL.path,
        webSearchProvider: .disabled,
        progress: { _, _ in
          if shouldStop {
            onMainQueue {
              scheduler.stop(agent)
              scheduler.setForeground(nil)
            }
          }
        },
        completion: { result, reason in
          receivedReason = reason
          receivedNonemptyResult = !result.isEmpty
          completionCount += 1
          completed.signal()
        })
      try wait(completed, timeout: 10, scenario: "completion-reasons")
      guard completionCount == 1, receivedNonemptyResult,
        receivedReason == (shouldStop ? .stopped : .finished)
      else {
        throw HarnessError.invariant("Incorrect completion reason for shouldStop=\(shouldStop)")
      }
      // Drain already-enqueued main-queue notifications while completion remains unacknowledged.
      // A finished turn must allow continuation without exposing stale persisted thread flags.
      let notificationsDelivered = DispatchSemaphore(value: 0)
      DispatchQueue.main.async { notificationsDelivered.signal() }
      try wait(notificationsDelivered, timeout: 10, scenario: "completion notifications")
      guard !scheduler.isIdle, !scheduler.hasActiveTurn(agent), stateObserver.isActive,
        stateObserver.inactiveNotificationCount == 0
      else {
        throw HarnessError.invariant("Thread became inactive before completion was acknowledged")
      }
      let cleanupAttempted = DispatchSemaphore(value: 0)
      queue.async {
        scheduler.unloadIdleCaches()
        cleanupAttempted.signal()
      }
      try wait(cleanupAttempted, timeout: 10, scenario: "busy cache retention")
      guard agent.unloadCount == 0 else {
        throw HarnessError.invariant("Unloaded caches before queued continuation was resolved")
      }
    }
    scheduler.markAsCompleted(agent)
    try waitOnMainQueue(timeout: 10, scenario: "completion acknowledgement") {
      !stateObserver.isActive
    }
    guard stateObserver.inactiveNotificationCount == 1 else {
      throw HarnessError.invariant("Queued continuations exposed an intermediate inactive state")
    }
    guard scheduler.isIdle else {
      throw HarnessError.invariant("Acknowledged completion did not become idle")
    }
    let unloaded = DispatchSemaphore(value: 0)
    queue.async {
      scheduler.unloadIdleCaches()
      unloaded.signal()
    }
    try wait(unloaded, timeout: 10, scenario: "idle cache unloading")
    guard agent.unloadCount == 1,
      scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: 1) === agent,
      scheduler.residentProjectWorkspace(projectPath: projectURL.path) === workspace
    else {
      throw HarnessError.invariant("Idle cleanup did not preserve resident conversation resources")
    }
    // Opening a queued background review must not show the preceding user turn's progress.
    guard scheduler.latestProgress(projectPath: projectURL.path, threadId: 1) != nil else {
      throw HarnessError.invariant("Missing progress from the completed user turn")
    }
    let backgroundCompleted = DispatchSemaphore(value: 0)
    var backgroundReason: AgentScheduler.CompletionReason?
    queue.suspend()
    scheduler.setForeground(nil)
    scheduler.ask(
      agent, threadId: 1, ProjectMemory.reviewPrompt, isMemoryEnabled: true, temporary: true,
      allowedTools: [.memory], projectPath: projectURL.path, projectWorkspace: workspace,
      workspacePath: projectURL.path, webSearchProvider: .disabled,
      progress: { _, _ in },
      completion: { _, reason in
        backgroundReason = reason
        backgroundCompleted.signal()
      })
    let hadStaleProgress =
      scheduler.latestProgress(projectPath: projectURL.path, threadId: 1) != nil
    queue.resume()
    try wait(backgroundCompleted, timeout: 10, scenario: "background temporary review")
    guard !hadStaleProgress, backgroundReason == .finished, agent.lastAskWasTemporary,
      !scheduler.isForeground(agent), !scheduler.hasActiveTurn(agent)
    else {
      throw HarnessError.invariant("Background review reused stale progress or failed to finish")
    }
    scheduler.setForeground(agent)

    let hibernated = DispatchSemaphore(value: 0)
    var receivedReason: AgentScheduler.CompletionReason?
    var completionCount = 0
    var hibernationResult: Result<Void, Swift.Error>?
    scheduler.ask(
      agent, threadId: 1, "Temporary", isMemoryEnabled: false, temporary: true,
      projectPath: projectURL.path,
      projectWorkspace: workspace, workspacePath: projectURL.path,
      webSearchProvider: .disabled,
      progress: { _, _ in
        scheduler.hibernateAll { result in
          hibernationResult = result
          hibernated.signal()
        }
      },
      completion: { _, reason in
        receivedReason = reason
        completionCount += 1
      })
    try wait(hibernated, timeout: 10, scenario: "temporary hibernation completion")
    try hibernationResult?.get()
    guard agent.lastAskWasTemporary, agent.continuation == .abort, agent.hibernateCount == 0,
      completionCount == 1, receivedReason == .stopped, !scheduler.hasActiveTurn(agent),
      scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: 1) == nil
    else {
      throw HarnessError.invariant("Temporary hibernation did not cancel and release the turn")
    }
  }

  private static func runStop(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder
  ) throws {
    let queue = DispatchQueue(label: "agent-scheduler-harness.stop")
    let scheduler = AgentScheduler(queue: queue)
    let agent = makeAgent()
    let completed = DispatchSemaphore(value: 0)
    var completionCount = 0
    var completionReason: AgentScheduler.CompletionReason?
    var resultAtRequest: CodeAgentResult?
    scheduler.setForeground(agent)
    scheduler.ask(
      agent, threadId: 401, longPrompt, isMemoryEnabled: false, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { progress, _ in
      guard case .generate(let result) = progress else { return }
      if resultAtRequest == nil && result.outputTokens.count >= options.pauseAfterTokens {
        resultAtRequest = result
        recorder.record("agent=A stop-request")
        onMainQueue {
          scheduler.stop(agent)
        }
      }
    } completion: { result, reason in
      completionReason = reason
      completionCount += 1
      recorder.record("agent=A completion")
      if let resultAtRequest {
        let additional =
          result.outputTokens.count + result.thinkTokens.count
          - resultAtRequest.outputTokens.count - resultAtRequest.thinkTokens.count
        if additional > 61 {
          recorder.record("agent=A excessive-grace=\(additional)")
        }
      }
      completed.signal()
    }
    try wait(completed, timeout: options.timeout, scenario: "stop")
    guard completionReason == .stopped else {
      throw HarnessError.invariant("Stop was reported as a normal completion")
    }
    guard completionCount == 1 else {
      throw HarnessError.invariant("Stop completed \(completionCount) times")
    }
  }

  private static func runResidentRestore(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder
  ) throws {
    let queue = DispatchQueue(label: "agent-scheduler-harness.resident")
    let scheduler = AgentScheduler(queue: queue)
    let agent = makeAgent()
    let completed = DispatchSemaphore(value: 0)
    scheduler.setForeground(agent)
    scheduler.ask(
      agent, threadId: 501, shortPrompt, isMemoryEnabled: false, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled, progress: { _, _ in },
      completion: { _, _ in completed.signal() })
    try wait(completed, timeout: options.timeout, scenario: "resident-restore")
    guard
      scheduler.residentCodeAgent(projectPath: projectURL.path + "/./", threadId: 501)
        === agent
    else { throw HarnessError.invariant("resident CodeAgent identity changed") }
    guard
      scheduler.residentProjectWorkspace(projectPath: projectURL.path + "/./")
        === projectWorkspace
    else { throw HarnessError.invariant("resident Workspace identity changed") }
    scheduler.markAsCompleted(agent)
    guard scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: 501) === agent else {
      throw HarnessError.invariant("completed foreground CodeAgent was released")
    }
    scheduler.setForeground(nil)
    guard scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: 501) == nil else {
      throw HarnessError.invariant("completed background CodeAgent remains resident")
    }
    guard scheduler.residentProjectWorkspace(projectPath: projectURL.path) === projectWorkspace
    else { throw HarnessError.invariant("completed CodeAgent release lost its Workspace") }
    recorder.record("resident identity-ok")
  }

  private static func runQueuedContinuation(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder
  ) throws {
    let queue = DispatchQueue(label: "agent-scheduler-harness.queued-continuation")
    let scheduler = AgentScheduler(queue: queue)
    let agent = makeAgent()
    let projectHistoryManager = ProjectHistoryManager(project: projectWorkspace)
    let tokenizer = DeepSeek4TextGenerator.safeTokenizer
    func tokenize(_ text: String) -> [Int32] {
      let (_, tokens, _, _, _) = tokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil,
        addSpecialTokens: false)
      return tokens
    }
    let thread = projectHistoryManager.createThread(
      title: shortPrompt, model: URL(fileURLWithPath: options.modelPath).lastPathComponent,
      userTokens: tokenize(shortPrompt), textEdits: 0, textLineage: 0)
    defer { _ = projectHistoryManager.deleteThread(id: thread.id) }

    let queuedTexts = [
      "Reply with exactly the word QUEUED and nothing else.",
      "Do not use any tools.",
    ]
    let queuedPrompt = queuedTexts.joined(separator: "\n\n")
    let queuedPromptTokens = tokenize(queuedPrompt)
    let queuedDatetime = Int64(Date().timeIntervalSince1970 * 1_000)
    projectWorkspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      for (index, text) in queuedTexts.enumerated() {
        transactionContext.try(
          submit: ProjectQueuedItemChangeRequest.upsertRequest(
            ProjectQueuedItem(
              threadId: thread.id, datetime: queuedDatetime + Int64(index), text: text)))
      }
    }

    var completionCount = 0
    var didFinish = false
    var failure: HarnessError?
    var schedule: ((String) -> Void)!
    schedule = { prompt in
      scheduler.ask(
        agent, threadId: thread.id, prompt, isMemoryEnabled: false, projectPath: projectURL.path,
        projectWorkspace: projectWorkspace, workspacePath: workspacePath,
        webSearchProvider: .disabled, progress: { _, _ in }
      ) { result, reason in
        DispatchQueue.main.async {
          guard reason == .finished else {
            failure = .invariant("queued continuation reported a stop")
            didFinish = true
            return
          }
          guard failure == nil else { return }
          guard !result.isEmpty else {
            failure = .invariant("queued continuation produced an empty result")
            didFinish = true
            return
          }
          guard
            projectHistoryManager.appendAssistant(
              threadId: thread.id, logTokens: result.logTokens,
              tokens: result.outputTokens, toolCalls: [], compacted: result.compacted) != nil
          else {
            failure = .invariant("queued continuation could not persist the assistant")
            didFinish = true
            return
          }
          completionCount += 1
          recorder.record("queued turn completion=\(completionCount)")
          guard completionCount == 1 else {
            guard
              scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: thread.id)
                === agent
            else {
              failure = .invariant("queued continuation changed CodeAgent identity")
              didFinish = true
              return
            }
            scheduler.markAsCompleted(agent)
            didFinish = true
            return
          }

          let queuedItems = Array(
            projectWorkspace.fetch(for: ProjectQueuedItem.self).where(
              ProjectQueuedItem.threadId == thread.id,
              orderBy: [ProjectQueuedItem.datetime.ascending]))
          let nextPrompt = queuedItems.compactMap(\.text).joined(separator: "\n\n")
          guard nextPrompt == queuedPrompt,
            projectHistoryManager.appendUser(
              threadId: thread.id, tokens: queuedPromptTokens, textEdits: -1,
              textLineage: -1) != nil
          else {
            failure = .invariant("queued prompt was not persisted in FIFO order")
            didFinish = true
            return
          }
          projectWorkspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
            for queuedItem in queuedItems {
              guard let request = ProjectQueuedItemChangeRequest.deletionRequest(queuedItem) else {
                continue
              }
              transactionContext.try(submit: request)
            }
          }
          schedule(nextPrompt)
          scheduler.setForeground(nil)
        }
      }
    }

    scheduler.setForeground(agent)
    schedule(shortPrompt)
    try waitOnMainQueue(timeout: options.timeout, scenario: "queued-continuation") {
      didFinish
    }
    if let failure { throw failure }

    let history = projectHistoryManager.history(threadId: thread.id)
    guard completionCount == 2,
      history.count == 4,
      history.map(\.role) == [.user, .assistant, .user, .assistant],
      history[2].tokens == queuedPromptTokens,
      history[2].plaintext == nil
    else {
      throw HarnessError.invariant("queued continuation history is inconsistent")
    }
    guard
      projectWorkspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == thread.id
      ).isEmpty
    else { throw HarnessError.invariant("queued items were not deleted") }
    guard scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: thread.id) == nil
    else { throw HarnessError.invariant("completed background CodeAgent remains resident") }
    guard scheduler.residentProjectWorkspace(projectPath: projectURL.path) === projectWorkspace
    else { throw HarnessError.invariant("completed background release lost its Workspace") }
    recorder.record("queued continuation persisted and resubmitted")
  }

  private static func runHibernatePrime(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder,
    saveBaseline: Bool
  ) throws {
    if saveBaseline {
      let queue = DispatchQueue(label: "agent-scheduler-harness.hibernate-baseline")
      let baselineAgent = makeAgent()
      let baseline = try runBoundedAsk(
        on: queue, timeout: options.timeout, scenario: "cold-resume baseline"
      ) {
        gracefullyBoundedAsk(
          baselineAgent, prompt: longPrompt, stopAfterTokens: options.stopAfterTokens,
          projectPath: nil, workspacePath: workspacePath)
      }
      let expected = ExpectedResult(
        outputTokens: baseline.outputTokens, logTokens: baseline.logTokens)
      try JSONEncoder().encode(expected).write(to: expectedResultURL(projectURL))
    }

    let queue = DispatchQueue(label: "agent-scheduler-harness.hibernate")
    let scheduler = AgentScheduler(queue: queue)
    let agent = makeAgent()
    let queuedAgent = makeAgent()
    let completed = DispatchSemaphore(value: 0)
    var requested = false
    var hibernateResult: Result<Void, Swift.Error>?
    scheduler.setForeground(agent)
    scheduler.ask(
      agent, threadId: 601, longPrompt, isMemoryEnabled: false, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { progress, _ in
      guard case .generate(let result) = progress, !requested,
        result.outputTokens.count >= options.pauseAfterTokens
      else { return }
      requested = true
      scheduler.hibernateAll { result in
        hibernateResult = result
        completed.signal()
      }
    } completion: { _, _ in
      recorder.record("unexpected turn completion before hibernate")
    }
    scheduler.ask(
      queuedAgent, threadId: 602, shortPrompt, isMemoryEnabled: false, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled, progress: { _, _ in },
      completion: { _, _ in
        recorder.record("unexpected queued-turn completion before hibernate")
      })
    try wait(completed, timeout: options.timeout, scenario: "hibernate")
    guard case .success = hibernateResult else {
      throw HarnessError.invariant("hibernateAll failed: \(String(describing: hibernateResult))")
    }
    guard scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: 601) == nil else {
      throw HarnessError.invariant("hibernated agent remains resident")
    }
    guard scheduler.residentCodeAgent(projectPath: projectURL.path, threadId: 602) == nil else {
      throw HarnessError.invariant("hibernated queued agent remains resident")
    }
    guard
      DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096).loadSuspension(
        threadId: 601) != nil
    else { throw HarnessError.invariant("suspension record was not written") }
    guard
      DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096).loadSuspension(
        threadId: 602) != nil
    else { throw HarnessError.invariant("queued suspension record was not written") }
    recorder.record("hibernate persisted")
  }

  private static func runColdResumeFinish(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder
  ) throws {
    let expectedURL = expectedResultURL(projectURL)
    guard FileManager.default.fileExists(atPath: expectedURL.path) else {
      throw HarnessError.missingFile(expectedURL.path)
    }
    let expected = try JSONDecoder().decode(
      ExpectedResult.self, from: Data(contentsOf: expectedURL))
    let queue = DispatchQueue(label: "agent-scheduler-harness.cold-resume")
    let scheduler = AgentScheduler(queue: queue)
    let agent = makeAgent()
    guard try agent.restoreSuspension(threadId: 601, projectPath: projectURL.path) else {
      throw HarnessError.invariant("no restorable suspension exists")
    }
    let completed = DispatchSemaphore(value: 0)
    var didRequestStop = false
    var resumedResult: CodeAgentResult?
    scheduler.setForeground(agent)
    scheduler.resume(
      agent, threadId: 601, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { progress, _ in
      guard case .generate(let result) = progress, !didRequestStop,
        result.outputTokens.count >= options.stopAfterTokens
      else { return }
      didRequestStop = true
      onMainQueue {
        scheduler.stop(agent)
      }
    } completion: { result, _ in
      resumedResult = result
      completed.signal()
    }
    try wait(completed, timeout: options.timeout, scenario: "cold-resume-finish")
    guard let resumedResult, resumedResult.outputTokens == expected.outputTokens,
      resumedResult.logTokens == expected.logTokens
    else { throw HarnessError.invariant("cold-resumed tokens differ from baseline") }
    guard
      DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096).loadSuspension(
        threadId: 601) == nil
    else { throw HarnessError.invariant("completed suspension record was not removed") }
    recorder.record("cold-resume token-match")
  }

  private static func runHibernateToolWait(
    options: Options, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    workspacePath: String, makeAgent: () -> DeepSeek4CodeAgent<DeepSeek4TextGenerator>,
    recorder: EventRecorder
  ) throws {
    let queue = DispatchQueue(label: "agent-scheduler-harness.hibernate-tool-wait")
    let scheduler = AgentScheduler(queue: queue)
    let agent = makeAgent()
    let completed = DispatchSemaphore(value: 0)
    var sawToolsWait = false
    var hibernateResult: Result<Void, Swift.Error>?
    scheduler.setForeground(agent)
    scheduler.ask(
      agent, threadId: 701, toolPrompt, isMemoryEnabled: false, projectPath: projectURL.path,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { progress, _ in
      guard case .toolsWait = progress, !sawToolsWait else { return }
      sawToolsWait = true
      recorder.record("agent=A hibernate-at-toolsWait")
      scheduler.hibernateAll { result in
        hibernateResult = result
        completed.signal()
      }
    } completion: { _, _ in
      recorder.record("unexpected turn completion before tool-wait hibernate")
    }
    try wait(completed, timeout: options.timeout, scenario: "hibernate-tool-wait")
    guard sawToolsWait else {
      throw HarnessError.invariant("the real model did not reach toolsWait")
    }
    guard case .success = hibernateResult else {
      throw HarnessError.invariant(
        "tool-wait hibernate failed: \(String(describing: hibernateResult))")
    }
    guard
      DeepSeek4ContextCache(projectPath: projectURL.path, checkpointStride: 4_096).loadSuspension(
        threadId: 701) != nil
    else { throw HarnessError.invariant("tool-wait suspension record was not written") }
    recorder.record("tool-wait hibernate persisted")
  }

  private static func gracefullyBoundedAsk(
    _ agent: DeepSeek4CodeAgent<DeepSeek4TextGenerator>, prompt: String, stopAfterTokens: Int,
    projectPath: String?, workspacePath: String
  ) -> CodeAgentResult {
    var resultAtStop: CodeAgentResult?
    return agent.ask(
      prompt, imagePaths: [], isMemoryEnabled: false, threadId: 0, projectPath: projectPath,
      workspacePath: workspacePath,
      webSearchProvider: .disabled
    ) { progress, _ in
      guard case .generate(let result) = progress else { return .continue }
      let tokenCount = result.thinkTokens.count + result.outputTokens.count
      if let resultAtStop {
        return agent.isCapReachedForStopping(from: resultAtStop, to: result)
          ? .abort : .continue
      }
      guard tokenCount >= stopAfterTokens else { return .continue }
      if agent.canStopImmediately(with: result) { return .abort }
      resultAtStop = result
      return .continue
    }
  }

  private static func wait(
    _ semaphore: DispatchSemaphore, timeout: TimeInterval, scenario: String
  ) throws {
    dispatchPrecondition(condition: .onQueue(.main))
    let deadline = Date(timeIntervalSinceNow: timeout)
    while semaphore.wait(timeout: .now()) != .success {
      guard Date() < deadline else { throw HarnessError.timeout(scenario) }
      _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
  }

  private static func onMainQueue<Result>(_ body: () -> Result) -> Result {
    if Thread.isMainThread {
      return body()
    } else {
      return DispatchQueue.main.sync(execute: body)
    }
  }

  private static func waitOnMainQueue(
    timeout: TimeInterval, scenario: String, until predicate: () -> Bool
  ) throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !predicate() {
      guard Date() < deadline else { throw HarnessError.timeout(scenario) }
      _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
  }

  private static func runBoundedAsk(
    on queue: DispatchQueue, timeout: TimeInterval, scenario: String,
    _ body: @escaping () -> CodeAgentResult
  ) throws -> CodeAgentResult {
    let completed = DispatchSemaphore(value: 0)
    let resultBox = ResultBox()
    queue.async {
      resultBox.result = body()
      completed.signal()
    }
    try wait(completed, timeout: timeout, scenario: scenario)
    guard let result = resultBox.result else {
      throw HarnessError.invariant("\(scenario) completed without a result")
    }
    return result
  }

  private static func expectedResultURL(_ projectURL: URL) -> URL {
    projectURL.appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("agent_scheduler_expected.json", isDirectory: false)
  }
}

extension CodeAgentProgress {
  fileprivate var description: String {
    switch self {
    case .prefill(_, let start, let length): return "prefill(\(start)/\(length))"
    case .generate(let result):
      return "generate(think=\(result.thinkTokens.count),output=\(result.outputTokens.count))"
    case .toolsWait(let result): return "toolsWait(calls=\(result.toolCalls.count))"
    case .compact(_, let start, let length): return "compact(\(start)/\(length))"
    }
  }
}
