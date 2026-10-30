import Dispatch
import Foundation
import SQLiteDflat
import WebSearch
import os.lock

protocol AgentSchedulerDelegate: AnyObject {
  func agentScheduler(
    _ scheduler: AgentScheduler,
    didActiveThreadsChange activeThreads: [(
      projectPath: String, threadId: Int64, state: AgentScheduler.State
    )])
}

final class AgentScheduler {
  enum CompletionReason {
    case finished
    case stopped
  }

  enum State: Equatable {
    case active
    case hibernated
  }

  // UI-facing methods are main-queue-only; `hibernateAll` and `isIdle` also support `queue`.
  // Cache cleanup, progress, and completion callbacks run on `queue`.
  private final class ProjectResources {
    let projectPath: String
    let projectWorkspace: SQLiteWorkspace
    var securityScopedProjectURL: URL?
    var shouldShutdownProjectWorkspace = true

    init(projectPath: String, projectWorkspace: SQLiteWorkspace) {
      self.projectPath = projectPath
      self.projectWorkspace = projectWorkspace
    }
  }

  private final class Entry {
    let codeAgent: any CodeAgent
    let identifier: ObjectIdentifier
    let threadId: Int64
    let projectResources: ProjectResources

    var projectPath: String { projectResources.projectPath }
    var projectWorkspace: SQLiteWorkspace { projectResources.projectWorkspace }

    var turn: Turn?
    var isWaitingForTools = false
    var mayBlockForTools = false
    var latestProgress: CodeAgentProgress?
    var latestStatistics = CodeAgentStatistics()
    var hasSuspendedTurn = false
    var isCompleted = false
    var isHot: Bool
    var state = State.active
    var shouldHibernate = false

    init(
      codeAgent: any CodeAgent, threadId: Int64, projectResources: ProjectResources,
      isHot: Bool
    ) {
      self.codeAgent = codeAgent
      identifier = ObjectIdentifier(codeAgent)
      self.threadId = threadId
      self.projectResources = projectResources
      self.isHot = isHot
    }
  }

  private struct Turn {
    var prompt: String?
    var imagePaths: [String]
    let isMemoryEnabled: Bool
    let temporary: Bool
    let allowedTools: Set<ToolsRegistry.Tool>?
    let projectPath: String?
    let workspacePath: String?
    let webSearchProvider: WebSearchProvider
    let progress: (CodeAgentProgress, CodeAgentStatistics) -> Void
    let completion: (CodeAgentResult, CompletionReason) -> Void
    var resultAtStop: CodeAgentResult?
    var didRequestPause = false
  }

  private struct PendingTurn {
    let identifier: ObjectIdentifier
    let turn: Turn
  }

  private let queue: DispatchQueue
  // Accessed only on the main queue.
  weak var delegate: AgentSchedulerDelegate?
  private(set) var file: String?
  // Retain the selected generator when its first turn is scheduled.
  var textGenerator: (any TextGenerator)?

  // Accessed from the main queue and `queue`; protected by `lock`.
  private var lock = os_unfair_lock()
  private var entries = [ObjectIdentifier: Entry]()
  private var projectResources = [ProjectResources]()
  private var pendingTurns = [PendingTurn]()
  private var activeTurnIdentifiers = Set<ObjectIdentifier>()
  private var foregroundIdentifier: ObjectIdentifier?
  private var stopRequests = Set<ObjectIdentifier>()
  private var isHibernateRequested = false
  /// Threads whose turns report progress while they're in the background, as the threads another
  /// device watches; by canonical project path and thread ID.
  private var backgroundProgressThreads = Set<String>()
  private var hibernateCompletions = [(Result<Void, Swift.Error>) -> Void]()
  private var maximumHotCodeAgentCount: Int

  // Accessed only on `queue`.
  private var fifo = [Entry]()
  private var isInvokingAgent = false

  init(
    queue: DispatchQueue, maximumHotCodeAgentCount: Int = Int.max
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    precondition(maximumHotCodeAgentCount > 0)
    self.queue = queue
    self.maximumHotCodeAgentCount = maximumHotCodeAgentCount
  }

  deinit {
    let textGenerator = textGenerator
    // Let the current stack unwind before releasing model storage on the generation queue.
    DispatchQueue.main.async { [queue] in
      queue.async {
        withExtendedLifetime(textGenerator) {}
      }
    }
  }

  func set(filePath: String, estimatedKVCacheSize: UInt64) {
    dispatchPrecondition(condition: .onQueue(.main))
    precondition(estimatedKVCacheSize > 0)
    os_unfair_lock_lock(&lock)
    precondition(entries.isEmpty && pendingTurns.isEmpty && activeTurnIdentifiers.isEmpty)
    file = URL(fileURLWithPath: filePath).lastPathComponent
    if maximumHotCodeAgentCount == Int.max {
      let modelFileSize =
        (try? URL(fileURLWithPath: filePath).resourceValues(
          forKeys: [.fileSizeKey]))?.fileSize ?? 0
      let physicalMemory = ProcessInfo.processInfo.physicalMemory
      let availableMemory =
        physicalMemory > UInt64(modelFileSize) ? physicalMemory - UInt64(modelFileSize) : 0
      maximumHotCodeAgentCount = max(
        1, Int(availableMemory / estimatedKVCacheSize) - 2)
    }
    os_unfair_lock_unlock(&lock)
  }

  func ask(
    _ codeAgent: any CodeAgent, threadId: Int64, _ prompt: String,
    imagePaths: [String] = [], isMemoryEnabled: Bool,
    temporary: Bool = false, allowedTools: Set<ToolsRegistry.Tool>? = nil,
    projectPath: String, projectWorkspace: SQLiteWorkspace, workspacePath: String?,
    webSearchProvider: WebSearchProvider,
    progress: @escaping (CodeAgentProgress, CodeAgentStatistics) -> Void,
    completion: @escaping (CodeAgentResult, CompletionReason) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    submit(
      codeAgent, threadId: threadId, prompt: prompt, imagePaths: imagePaths,
      isMemoryEnabled: isMemoryEnabled,
      temporary: temporary,
      allowedTools: allowedTools, projectPath: projectPath,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: webSearchProvider, progress: progress, completion: completion)
  }

  func resume(
    _ codeAgent: any CodeAgent, threadId: Int64, projectPath: String,
    projectWorkspace: SQLiteWorkspace, workspacePath: String?,
    webSearchProvider: WebSearchProvider,
    progress: @escaping (CodeAgentProgress, CodeAgentStatistics) -> Void,
    completion: @escaping (CodeAgentResult, CompletionReason) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    submit(
      codeAgent, threadId: threadId, prompt: nil, projectPath: projectPath,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath,
      webSearchProvider: webSearchProvider, progress: progress, completion: completion)
  }

  private func submit(
    _ codeAgent: any CodeAgent, threadId: Int64, prompt: String?, imagePaths: [String] = [],
    isMemoryEnabled: Bool = false,
    temporary: Bool = false, allowedTools: Set<ToolsRegistry.Tool>? = nil,
    projectPath: String,
    projectWorkspace: SQLiteWorkspace, workspacePath: String?,
    webSearchProvider: WebSearchProvider,
    progress: @escaping (CodeAgentProgress, CodeAgentStatistics) -> Void,
    completion: @escaping (CodeAgentResult, CompletionReason) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let canonicalProjectPath = Self.canonicalProjectPath(projectPath)
    let identifier = ObjectIdentifier(codeAgent)
    os_unfair_lock_lock(&lock)
    precondition(!isHibernateRequested, "Cannot submit a turn to a retiring AgentScheduler")
    let entry: Entry
    if let existing = entries[identifier] {
      precondition(existing.codeAgent === codeAgent)
      precondition(existing.threadId == threadId)
      precondition(existing.projectPath == canonicalProjectPath)
      precondition(existing.projectWorkspace === projectWorkspace)
      entry = existing
    } else {
      let projectResources: ProjectResources
      if let existing = self.projectResources.first(where: {
        $0.projectPath == canonicalProjectPath
      }) {
        precondition(existing.projectWorkspace === projectWorkspace)
        projectResources = existing
      } else {
        projectResources = ProjectResources(
          projectPath: canonicalProjectPath, projectWorkspace: projectWorkspace)
        self.projectResources.append(projectResources)
      }
      let isHot =
        foregroundIdentifier == identifier
        || entries.values.lazy.filter(\.isHot).count < maximumHotCodeAgentCount
      entry = Entry(
        codeAgent: codeAgent, threadId: threadId, projectResources: projectResources,
        isHot: isHot)
      entries[identifier] = entry
    }
    entry.isCompleted = false
    if prompt != nil {
      entry.latestProgress = nil
    }
    precondition(!activeTurnIdentifiers.contains(identifier))
    activeTurnIdentifiers.insert(identifier)
    pendingTurns.append(
      PendingTurn(
        identifier: identifier,
        turn: Turn(
          prompt: prompt, imagePaths: imagePaths, isMemoryEnabled: isMemoryEnabled,
          temporary: temporary,
          allowedTools: allowedTools,
          projectPath: projectPath, workspacePath: workspacePath,
          webSearchProvider: webSearchProvider, progress: progress, completion: completion)))
    notifyActiveThreadsDidChangeWhileLocked()
    os_unfair_lock_unlock(&lock)
    queue.async { [self] in
      acceptPendingTurnsAndRun()
    }
  }

  func setForeground(_ codeAgent: (any CodeAgent)?) {
    dispatchPrecondition(condition: .onQueue(.main))
    os_unfair_lock_lock(&lock)
    let previousForegroundIdentifier = foregroundIdentifier
    foregroundIdentifier = codeAgent.map(ObjectIdentifier.init)
    if previousForegroundIdentifier != foregroundIdentifier,
      let previousForegroundIdentifier,
      let previousEntry = entries[previousForegroundIdentifier], previousEntry.isCompleted
    {
      releaseCompletedEntry(previousEntry)
    }
    os_unfair_lock_unlock(&lock)
    queue.async { [weak self] in
      self?.acceptPendingTurnsAndRun()
    }
  }

  func markAsCompleted(_ codeAgent: any CodeAgent) {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = ObjectIdentifier(codeAgent)
    os_unfair_lock_lock(&lock)
    guard let entry = entries[identifier], entry.codeAgent === codeAgent else {
      os_unfair_lock_unlock(&lock)
      return
    }
    precondition(!activeTurnIdentifiers.contains(identifier))
    entry.isCompleted = true
    let toReleaseEntry = foregroundIdentifier != identifier
    if toReleaseEntry {
      releaseCompletedEntry(entry)
    }
    notifyActiveThreadsDidChangeWhileLocked()
    os_unfair_lock_unlock(&lock)
    if toReleaseEntry {
      queue.async { [weak self] in
        self?.acceptPendingTurnsAndRun()
      }
    }
  }

  func adoptSecurityScopedProjectAccess(
    for codeAgent: any CodeAgent, projectURL: URL, didStartAccessing: Bool
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard didStartAccessing else { return }
    let identifier = ObjectIdentifier(codeAgent)
    os_unfair_lock_lock(&lock)
    guard let entry = entries[identifier] else {
      os_unfair_lock_unlock(&lock)
      preconditionFailure("AgentScheduler must own the agent before adopting project access")
    }
    if entry.projectResources.securityScopedProjectURL != nil {
      os_unfair_lock_unlock(&lock)
      projectURL.stopAccessingSecurityScopedResource()
      return
    }
    entry.projectResources.securityScopedProjectURL = projectURL
    os_unfair_lock_unlock(&lock)
  }

  func stop(_ codeAgent: any CodeAgent) {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = ObjectIdentifier(codeAgent)
    os_unfair_lock_lock(&lock)
    // Also a background turn with one in progress, such as another device's.
    if foregroundIdentifier == identifier || activeTurnIdentifiers.contains(identifier) {
      stopRequests.insert(identifier)
    }
    os_unfair_lock_unlock(&lock)
  }

  /// Turns in these threads report progress even in the background, as for threads another device
  /// watches; the set replaces the last one.
  func setBackgroundProgressThreads(_ threads: [(projectPath: String, threadId: Int64)]) {
    dispatchPrecondition(condition: .onQueue(.main))
    let keys = Set(
      threads.map {
        Self.threadKey(
          projectPath: Self.canonicalProjectPath($0.projectPath), threadId: $0.threadId)
      })
    os_unfair_lock_lock(&lock)
    backgroundProgressThreads = keys
    os_unfair_lock_unlock(&lock)
  }

  /// Leaves the project's database open when this scheduler retires, for an owner that keeps
  /// using it.
  func keepProjectWorkspace(projectPath: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    let canonicalProjectPath = Self.canonicalProjectPath(projectPath)
    os_unfair_lock_lock(&lock)
    projectResources.first { $0.projectPath == canonicalProjectPath }?
      .shouldShutdownProjectWorkspace = false
    os_unfair_lock_unlock(&lock)
  }

  private static func threadKey(projectPath: String, threadId: Int64) -> String {
    "\(projectPath)\n\(threadId)"
  }

  func residentCodeAgent(projectPath: String, threadId: Int64) -> (any CodeAgent)? {
    dispatchPrecondition(condition: .onQueue(.main))
    let canonicalProjectPath = Self.canonicalProjectPath(projectPath)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return entries.values.first {
      $0.projectPath == canonicalProjectPath && $0.threadId == threadId
    }?.codeAgent
  }

  func residentProjectWorkspace(projectPath: String) -> SQLiteWorkspace? {
    dispatchPrecondition(condition: .onQueue(.main))
    let canonicalProjectPath = Self.canonicalProjectPath(projectPath)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return projectResources.first { $0.projectPath == canonicalProjectPath }?.projectWorkspace
  }

  func relinquishProjectResources(projectPath: String) -> (
    projectWorkspace: SQLiteWorkspace?, hadSecurityScopedAccess: Bool
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let canonicalProjectPath = Self.canonicalProjectPath(projectPath)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    guard
      let projectResources = projectResources.first(where: {
        $0.projectPath == canonicalProjectPath
      })
    else { return (nil, false) }
    projectResources.shouldShutdownProjectWorkspace = false
    let hadSecurityScopedAccess = projectResources.securityScopedProjectURL != nil
    projectResources.securityScopedProjectURL = nil
    return (projectResources.projectWorkspace, hadSecurityScopedAccess)
  }

  func isForeground(_ codeAgent: any CodeAgent) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = ObjectIdentifier(codeAgent)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return foregroundIdentifier == identifier
  }

  func hasActiveTurn(_ codeAgent: any CodeAgent) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = ObjectIdentifier(codeAgent)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return activeTurnIdentifiers.contains(identifier)
  }

  /// A stop requested in the foreground holds until the turn ends, in the background too.
  func isStopping(_ codeAgent: any CodeAgent) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = ObjectIdentifier(codeAgent)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return stopRequests.contains(identifier)
  }

  // Safe on the main and generation queues. Completion processing may submit a queued turn or
  // memory review, so a turn remains busy until markAsCompleted acknowledges it.
  var isIdle: Bool {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return !isHibernateRequested && pendingTurns.isEmpty && activeTurnIdentifiers.isEmpty
      && entries.values.allSatisfy(\.isCompleted)
  }

  func unloadIdleCaches() {
    dispatchPrecondition(condition: .onQueue(queue))
    precondition(!isInvokingAgent)
    guard isIdle else { return }
    os_unfair_lock_lock(&lock)
    let agents = entries.values.filter { $0.isCompleted }.map(\.codeAgent)
    os_unfair_lock_unlock(&lock)
    // New submissions can arrive on main after this snapshot, but their inference is serialized
    // behind this cleanup on queue. Keep entries and project resources available for reuse.
    for agent in agents { agent.unloadCaches() }
  }

  func latestProgress(
    projectPath: String, threadId: Int64
  ) -> (CodeAgentProgress, CodeAgentStatistics)? {
    dispatchPrecondition(condition: .onQueue(.main))
    let canonicalProjectPath = Self.canonicalProjectPath(projectPath)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    guard
      let entry = entries.values.first(where: {
        $0.projectPath == canonicalProjectPath && $0.threadId == threadId
      }),
      let progress = entry.latestProgress
    else { return nil }
    return (progress, entry.latestStatistics)
  }

  func hibernateAll(completion: @escaping (Result<Void, Swift.Error>) -> Void) {
    os_unfair_lock_lock(&lock)
    hibernateCompletions.append(completion)
    if isHibernateRequested {
      os_unfair_lock_unlock(&lock)
      return
    }
    isHibernateRequested = true
    os_unfair_lock_unlock(&lock)
    queue.async { [self] in
      acceptPendingTurnsAndRun()
    }
  }

  private func acceptPendingTurnsAndRun() {
    dispatchPrecondition(condition: .onQueue(queue))
    acceptPendingTurns()
    guard !isInvokingAgent else { return }
    if isHibernateRequestedWithLock {
      continueHibernation()
      return
    }
    runNext()
  }

  private func acceptPendingTurns() {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    let pendingTurns = self.pendingTurns
    self.pendingTurns.removeAll(keepingCapacity: true)
    os_unfair_lock_unlock(&lock)
    for pending in pendingTurns {
      os_unfair_lock_lock(&lock)
      let entry = entries[pending.identifier]
      os_unfair_lock_unlock(&lock)
      guard let entry else { continue }
      precondition(entry.turn == nil)
      entry.turn = pending.turn
      entry.isWaitingForTools = false
      entry.mayBlockForTools = false
      if !fifo.contains(where: { $0 === entry }) {
        fifo.append(entry)
      }
    }
  }

  private func runNext() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isInvokingAgent else { return }
    fifo.removeAll { $0.turn == nil }
    let isHibernating = isHibernateRequestedWithLock
    let entryToHibernate = isHibernating ? nil : rebalanceHotEntries()
    if !isHibernating && entryToHibernate == nil
      && hotEntryCountWithLock > hotEntryLimitWithLock
    {
      return
    }
    let candidateIndices = fifo.indices.filter {
      isHibernating
        ? !fifo[$0].hasSuspendedTurn || fifo[$0].turn?.temporary == true
        : isHotWithLock(fifo[$0])
    }
    guard let firstCandidateIndex = candidateIndices.first else { return }

    let foregroundIdentifier = foregroundIdentifierWithLock
    let index: Int
    if let entryToHibernate,
      let hibernateIndex = candidateIndices.first(where: {
        fifo[$0] === entryToHibernate
      })
    {
      index = hibernateIndex
    } else if let foregroundIdentifier,
      let foregroundIndex = candidateIndices.first(where: {
        fifo[$0].identifier == foregroundIdentifier
      })
    {
      index = foregroundIndex
    } else {
      index = firstCandidateIndex
    }
    let entry = fifo.remove(at: index)
    if isHibernating && !isHotWithLock(entry) {
      setHotWithLock(true, for: entry)
    }
    if entry.isWaitingForTools,
      fifo.allSatisfy({ !isHotWithLock($0) || $0.isWaitingForTools || $0.turn == nil })
    {
      entry.mayBlockForTools = true
    }
    guard var turn = entry.turn else {
      queue.async { [weak self] in self?.runNext() }
      return
    }
    let codeAgent = entry.codeAgent

    entry.hasSuspendedTurn = false
    isInvokingAgent = true
    let result: CodeAgentResult
    var reason = CompletionReason.finished
    let callback: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState = {
      [weak self, weak entry] progress, statistics in
      guard let self, let entry else { return .abort }
      os_unfair_lock_lock(&self.lock)
      entry.latestProgress = progress
      entry.latestStatistics = statistics
      let foregroundIdentifier = self.foregroundIdentifier
      let isWatched = self.backgroundProgressThreads.contains(
        Self.threadKey(projectPath: entry.projectPath, threadId: entry.threadId))
      os_unfair_lock_unlock(&self.lock)
      if foregroundIdentifier == entry.identifier || isWatched {
        turn.progress(progress, statistics)
      }

      if turn.temporary, self.isHibernateRequestedWithLock || entry.shouldHibernate {
        reason = .stopped
        return .abort
      }

      if self.isHibernateRequestedWithLock {
        turn.didRequestPause = true
        return .pause
      }

      if entry.shouldHibernate {
        turn.didRequestPause = true
        return .pause
      }

      os_unfair_lock_lock(&self.lock)
      let foregroundAfterProgress = self.foregroundIdentifier
      let shouldStop = self.stopRequests.contains(entry.identifier)
      let foregroundHasTurn =
        foregroundAfterProgress.map {
          self.activeTurnIdentifiers.contains($0)
        } ?? false
      let hasOtherHotPendingTurn = self.entries.values.contains {
        $0.identifier != entry.identifier && $0.isHot
          && self.activeTurnIdentifiers.contains($0.identifier)
      }
      os_unfair_lock_unlock(&self.lock)

      if shouldStop {
        switch progress {
        case .prefill, .compact:
          return .abort
        case .toolsWait:
          return .abort
        case .generate(let result):
          if let resultAtStop = turn.resultAtStop {
            if codeAgent.isCapReachedForStopping(from: resultAtStop, to: result) {
              return .abort
            }
          } else if codeAgent.canStopImmediately(with: result) {
            return .abort
          } else {
            turn.resultAtStop = result
          }
        }
      }

      if let foregroundAfterProgress, foregroundAfterProgress != entry.identifier,
        foregroundHasTurn
      {
        turn.didRequestPause = true
        return .pause
      }

      switch progress {
      case .toolsWait:
        entry.isWaitingForTools = true
        if foregroundAfterProgress == entry.identifier || entry.mayBlockForTools {
          entry.mayBlockForTools = false
          return .continue
        }
        if hasOtherHotPendingTurn {
          turn.didRequestPause = true
          return .pause
        }
      case .prefill, .generate, .compact:
        entry.isWaitingForTools = false
        entry.mayBlockForTools = false
      }
      if case .generate = progress, statistics.contextUsedTokens > 0,
        statistics.contextUsedTokens.isMultiple(of: 4_096)
      {
        return .checkpoint
      }
      return .continue
    }

    if let prompt = turn.prompt {
      result = codeAgent.ask(
        prompt, imagePaths: turn.imagePaths, isMemoryEnabled: turn.isMemoryEnabled,
        temporary: turn.temporary,
        allowedTools: turn.allowedTools,
        threadId: entry.threadId, projectPath: turn.projectPath,
        workspacePath: turn.workspacePath,
        webSearchProvider: turn.webSearchProvider, progress: callback)
    } else {
      result = codeAgent.resume(progress: callback)
    }
    isInvokingAgent = false

    if turn.didRequestPause {
      turn.prompt = nil
      turn.didRequestPause = false
      entry.turn = turn
      entry.hasSuspendedTurn = true
      if !fifo.contains(where: { $0 === entry }) {
        fifo.append(entry)
      }
      if entry.shouldHibernate {
        _ = hibernate(entry)
      }
    } else {
      entry.turn = nil
      entry.shouldHibernate = false
      entry.hasSuspendedTurn = false
      entry.isWaitingForTools = false
      entry.mayBlockForTools = false
      os_unfair_lock_lock(&lock)
      if stopRequests.remove(entry.identifier) != nil { reason = .stopped }
      activeTurnIdentifiers.remove(entry.identifier)
      os_unfair_lock_unlock(&lock)
      turn.completion(result, reason)
    }

    if isHibernateRequestedWithLock {
      continueHibernation()
    } else {
      queue.async { [weak self] in
        self?.acceptPendingTurnsAndRun()
      }
    }
  }

  private func continueHibernation() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isInvokingAgent else { return }
    acceptPendingTurns()
    // Temporary asks cannot be persisted. Resume suspended ones to cancel and complete them.
    if fifo.contains(where: {
      $0.turn != nil && (!$0.hasSuspendedTurn || $0.turn?.temporary == true)
    }) {
      runNext()
    } else {
      hibernateResidents()
    }
  }

  private func hibernateResidents() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isInvokingAgent else { return }
    var firstError: Swift.Error?
    os_unfair_lock_lock(&lock)
    let residentEntries = entries.values.map { ($0, $0.isHot) }
    let projectResources = self.projectResources
    os_unfair_lock_unlock(&lock)
    for (entry, isHot) in residentEntries {
      guard isHot, entry.turn != nil, entry.hasSuspendedTurn else { continue }
      do {
        try entry.codeAgent.hibernate(threadId: entry.threadId)
      } catch {
        if firstError == nil {
          firstError = error
        }
      }
    }
    os_unfair_lock_lock(&lock)
    for resources in projectResources {
      resources.securityScopedProjectURL?.stopAccessingSecurityScopedResource()
      resources.securityScopedProjectURL = nil
      if resources.shouldShutdownProjectWorkspace {
        resources.projectWorkspace.shutdown(flags: [])
      }
    }
    fifo.removeAll()
    entries.removeAll()
    self.projectResources.removeAll()
    pendingTurns.removeAll()
    activeTurnIdentifiers.removeAll()
    notifyActiveThreadsDidChangeWhileLocked()
    stopRequests.removeAll()
    foregroundIdentifier = nil
    isHibernateRequested = false
    let completions = hibernateCompletions
    hibernateCompletions.removeAll()
    os_unfair_lock_unlock(&lock)
    if let firstError {
      for completion in completions {
        completion(.failure(firstError))
      }
    } else {
      for completion in completions {
        completion(.success(()))
      }
    }
  }

  private var foregroundIdentifierWithLock: ObjectIdentifier? {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return foregroundIdentifier
  }

  private var isHibernateRequestedWithLock: Bool {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return isHibernateRequested
  }

  static func canonicalProjectPath(_ projectPath: String) -> String {
    URL(fileURLWithPath: projectPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func releaseCompletedEntry(_ entry: Entry) {
    dispatchPrecondition(condition: .onQueue(.main))
    precondition(entry.isCompleted)
    precondition(foregroundIdentifier != entry.identifier)
    entries.removeValue(forKey: entry.identifier)
    // Let the current main-queue stack unwind before transferring the final release.
    DispatchQueue.main.async { [queue, entry] in
      queue.async {
        withExtendedLifetime(entry) {}
      }
    }
  }

  private func rebalanceHotEntries() -> Entry? {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    if let foregroundIdentifier {
      let foregroundEntry = entries[foregroundIdentifier]
      if let foregroundEntry {
        let didChangeState = foregroundEntry.state != .active
        foregroundEntry.isHot = true
        foregroundEntry.state = .active
        if didChangeState {
          notifyActiveThreadsDidChangeWhileLocked()
        }
      }
    }
    os_unfair_lock_unlock(&lock)

    while hotEntryCountWithLock > hotEntryLimitWithLock {
      guard
        let entry = fifo.reversed().first(where: {
          $0.identifier != foregroundIdentifierWithLock && isHotWithLock($0)
        })
      else { break }
      if entry.hasSuspendedTurn, entry.turn?.temporary != true {
        guard hibernate(entry) else { break }
      } else {
        entry.shouldHibernate = true
        return entry
      }
    }

    while hotEntryCountWithLock < hotEntryLimitWithLock,
      let entry = fifo.first(where: { !isHotWithLock($0) })
    {
      setHotWithLock(true, for: entry)
    }
    return nil
  }

  private func hibernate(_ entry: Entry) -> Bool {
    dispatchPrecondition(condition: .onQueue(queue))
    precondition(entry.hasSuspendedTurn)
    do {
      try entry.codeAgent.hibernate(threadId: entry.threadId)
    } catch {
      entry.shouldHibernate = false
      return false
    }
    entry.shouldHibernate = false
    setHotWithLock(false, for: entry)
    return true
  }

  private var hotEntryCountWithLock: Int {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return entries.values.lazy.filter(\.isHot).count
  }

  private var hotEntryLimitWithLock: Int {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    guard maximumHotCodeAgentCount < Int.max,
      let foregroundIdentifier,
      entries[foregroundIdentifier]?.isHot == true,
      !activeTurnIdentifiers.contains(foregroundIdentifier)
    else { return maximumHotCodeAgentCount }
    return maximumHotCodeAgentCount + 1
  }

  private func isHotWithLock(_ entry: Entry) -> Bool {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return entry.isHot
  }

  private func setHotWithLock(_ isHot: Bool, for entry: Entry) {
    dispatchPrecondition(condition: .onQueue(queue))
    os_unfair_lock_lock(&lock)
    if entries[entry.identifier] === entry {
      let state: State = isHot ? .active : .hibernated
      let didChangeState = entry.state != state
      entry.isHot = isHot
      entry.state = state
      if didChangeState {
        notifyActiveThreadsDidChangeWhileLocked()
      }
    }
    os_unfair_lock_unlock(&lock)
  }

  private func notifyActiveThreadsDidChangeWhileLocked() {
    let activeThreads: [(projectPath: String, threadId: Int64, state: State)] =
      entries.values.compactMap { entry in
        // Completion handling saves the response and may enqueue another turn. Keep the thread
        // visibly active until the caller acknowledges completion with `markAsCompleted`.
        guard !entry.isCompleted else { return nil }
        return (
          projectPath: entry.projectPath, threadId: entry.threadId, state: entry.state
        )
      }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.delegate?.agentScheduler(self, didActiveThreadsChange: activeThreads)
    }
  }
}
