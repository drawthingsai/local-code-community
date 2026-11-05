import Atomics
import Combine
import Dflat
import Foundation
import ModelZoo
import NNC
import SQLiteDflat

/// Everything anyone shows about serving.
struct ServeState: Equatable {
  enum Listener: Equatable {
    case off
    case starting
    case listening
    case portInUse
    case failed(String)
  }

  enum ActivePhase: Equatable {
    /// Behind the chat, or the agent's other turns, in the scheduler.
    case waiting
    case prefilling(finished: Int, total: Int)
    case generating(tokens: Int, tokensPerSecond: Float)
  }

  var isEnabled = false
  var port = ServeController.defaultPort
  /// The file of the model being served.
  var model: String?
  var listener = Listener.off
  var activePhase: ActivePhase?
  var queuedRequestCount = 0
  var metrics = ServeMetrics()
  /// Bytes on disk, or nil before anything is there.
  var contextCacheSize: Int64?
}

protocol ServeControllerDelegate: AnyObject {
  /// The scheduler serving turns go through, activated if nothing has done that yet.
  func serveController(_ controller: ServeController, schedulerFor model: String) -> AgentScheduler?
  /// Makes room on the generation queue for `model` and hands over its text generator.
  func serveController(_ controller: ServeController, textGeneratorToRun model: String)
    -> (any TextGenerator)?
  /// The folder whose .localc holds the context cache.
  func serveControllerContextCacheProjectPath(_ controller: ServeController) -> String
}

/// Takes requests off the listener and gives each conversation an agent of its own. The models can't
/// batch, so the agents take turns on the generation queue. Not tied to any view: it exists, and
/// serves, wherever the rail is, for as long as the toggle stays on.
final class ServeController {
  /// One above Ollama's 11434, so the two can serve on one Mac.
  static let defaultPort = 11_435

  static func baseURL(port: Int) -> String {
    "http://127.0.0.1:\(port)/v1"
  }

  static func port(workspace: SQLiteWorkspace) -> Int {
    workspace.dictionary["serve_port", Int.self] ?? defaultPort
  }

  /// 127.0.0.1 for this Mac only, unless 0.0.0.0 is picked to allow every connection.
  static func ip(workspace: SQLiteWorkspace) -> String {
    workspace.dictionary["serve_ip", String.self] ?? "127.0.0.1"
  }

  /// The chat's model until one is picked for serving.
  /// The chat's Thinking Budget, with its default and limit.
  private static func thinkingBudget(workspace: SQLiteWorkspace) -> Int {
    min(max(workspace.dictionary["thinking_budget", Int.self] ?? 131_072, 0), 256 * 1024)
  }

  static func model(workspace: SQLiteWorkspace) -> String? {
    workspace.dictionary["serve_model", String.self]
      ?? workspace.dictionary["llm_model", String.self]
  }
  /// Serving is for a Mac that stays on, not for a device in someone's hand.
  static let isAvailable =
    ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
  /// How long a request runs before the next one gets a go. On a 27B model, 1 second cost at most a
  /// few percent over 2 and halved the longest stall a client saw.
  static let defaultTimeSlice: TimeInterval = 1

  /// The most agents kept, running or idle, each with a KV cache. A fixed number rather than a share
  /// of the scheduler's hot limit, as serving while chatting is the exception.
  private static let maximumAgents = 8
  private static let maximumQueuedRequests = 128
  private static let keepAliveInterval: TimeInterval = 15
  /// A turn's thread as the scheduler knows it. Serving has no threads, and no project to clash
  /// with one.
  private static let schedulerThreadId: Int64 = -2

  private struct PendingRequest {
    let identifier = UUID()
    let request: ResponsesRequest
    let connection: StreamingHTTPConnection
    let writer: ResponsesResponseWriter
    let arrivalDate: Date
    /// As it was on arrival, since the prompt opens the model's thinking only when it's above 0.
    let thinkingBudget: Int
    /// The model `baseTokens` are for. Nil until the tokenizer is done with it.
    var tokenized: (model: String, baseTokens: [Int32])?
  }

  private struct ActiveTurn {
    let agent: ResponsesAgent
    let pendingRequest: PendingRequest
    let didContinueEarlierTurn: Bool
    /// The scheduler running the turn.
    var scheduler: AgentScheduler
    var phase = ServeState.ActivePhase.waiting
    var timing: ServeRequestTiming
    /// What it has generated so far, already added to the metrics.
    var generatedTokens = 0
    var retainedTokens = [Int32]()
  }

  weak var delegate: ServeControllerDelegate?
  /// Accessed on the main queue, with a full value on every change.
  let state = CurrentValueSubject<ServeState, Never>(ServeState())

  private let queue: DispatchQueue
  private let graph: DynamicGraph
  private let streamContext: StreamContext
  private let timeSlice: TimeInterval
  private let tokenizationQueue = DispatchQueue(
    label: "serve.tokenization", qos: .userInitiated)
  private var server: StreamingHTTPServer?
  /// Everything accepted and not yet given to an agent, in order of arrival.
  private var pendingRequests = [PendingRequest]()
  private var activeTurns = [ObjectIdentifier: ActiveTurn]()
  /// What the agents read on the generation queue to tell if anything else wants to run.
  private let activeTurnCount = ManagedAtomic(0)
  private var idleAgentPool = ResponsesAgentPool<ResponsesAgent>()
  private var agentModel: String?
  /// The generator for `agentModel`, asked for once per model. Every agent's adapter copies it,
  /// and copies share its weights, so a conversation never loads them again.
  private(set) var textGenerator: (any TextGenerator)?
  /// Tokenizes for `agentModel`. It holds no KV cache, so it costs nothing to keep.
  private var tokenizingAdapter: (any ResponsesModelAdapter)?
  private var keepAliveTimer: Timer?
  private var sampleTimer: Timer?
  private var modelSubscription: Workspace.Subscription?
  private var chatModelSubscription: Workspace.Subscription?
  private var ipSubscription: Workspace.Subscription?
  private var portSubscription: Workspace.Subscription?
  private var thinkingBudget: Int
  private var thinkingBudgetSubscription: Workspace.Subscription?

  /// Serves from the start, as it only exists while "serve_responses_enabled" is on.
  init(
    queue: DispatchQueue, graph: DynamicGraph, streamContext: StreamContext,
    workspace: SQLiteWorkspace, timeSlice: TimeInterval = ServeController.defaultTimeSlice
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    self.queue = queue
    self.graph = graph
    self.streamContext = streamContext
    self.timeSlice = timeSlice
    thinkingBudget = Self.thinkingBudget(workspace: workspace)
    var newState = state.value
    newState.isEnabled = true
    newState.model = Self.model(workspace: workspace)
    state.send(newState)
    // A request in progress finishes on the model it started on.
    let updateModel = { [weak self, weak workspace] in
      DispatchQueue.main.async {
        guard let self, let workspace else { return }
        self.updateState { $0.model = Self.model(workspace: workspace) }
      }
    }
    modelSubscription = workspace.dictionary.subscribe("serve_model", of: String.self) { _ in
      updateModel()
    }
    chatModelSubscription = workspace.dictionary.subscribe("llm_model", of: String.self) { _ in
      updateModel()
    }
    startServer(ip: Self.ip(workspace: workspace), port: Self.port(workspace: workspace))
    // Another address or port means another listener, which ends the requests on the old one.
    let updateListener = { [weak self, weak workspace] in
      DispatchQueue.main.async {
        guard let self, let workspace else { return }
        let ip = Self.ip(workspace: workspace)
        let port = Self.port(workspace: workspace)
        guard ip != self.server?.host || port != self.state.value.port else { return }
        self.startServer(ip: ip, port: port)
      }
    }
    ipSubscription = workspace.dictionary.subscribe("serve_ip", of: String.self) { _ in
      updateListener()
    }
    portSubscription = workspace.dictionary.subscribe("serve_port", of: Int.self) { _ in
      updateListener()
    }
    thinkingBudgetSubscription = workspace.dictionary.subscribe("thinking_budget", of: Int.self) {
      [weak self, weak workspace] _ in
      DispatchQueue.main.async {
        guard let self, let workspace else { return }
        self.thinkingBudget = Self.thinkingBudget(workspace: workspace)
      }
    }
    updateContextCacheSize()
    // Comments keep a stream that hasn't produced anything for a while looking alive, as one
    // waiting behind the chat or prefilling a long conversation can be for minutes.
    let timer = Timer(timeInterval: Self.keepAliveInterval, repeats: true) { [weak self] _ in
      self?.sendKeepAlives()
    }
    RunLoop.main.add(timer, forMode: .common)
    keepAliveTimer = timer
    takeSample()
    let sampleTimer = Timer(timeInterval: ServeMetrics.sampleInterval, repeats: true) {
      [weak self] _ in
      self?.takeSample()
    }
    RunLoop.main.add(sampleTimer, forMode: .common)
    self.sampleTimer = sampleTimer
  }

  deinit {
    keepAliveTimer?.invalidate()
    sampleTimer?.invalidate()
    // Closing the connections ends the turns in progress at their next token, and each turn
    // still tells its scheduler it's done.
    server?.stop()
    for pendingRequest in pendingRequests {
      pendingRequest.connection.close()
    }
    let agents = idleAgentPool.agents + activeTurns.values.map(\.agent)
    queue.async { withExtendedLifetime(agents) {} }
  }

  private func startServer(ip: String, port: Int) {
    server?.stop()
    updateState { $0.port = port }
    let server = StreamingHTTPServer(
      host: ip, port: UInt16(exactly: port) ?? UInt16(Self.defaultPort))
    server.delegate = self
    self.server = server
    server.start()
  }

  /// `retired` stopped running turns: everything suspended in it has been handed back. A serving
  /// turn has a client waiting, so it carries on in the scheduler that took over.
  func scheduler(_ retired: AgentScheduler, didRetireInFavorOf current: AgentScheduler) {
    dispatchPrecondition(condition: .onQueue(.main))
    for identifier in activeTurns.keys where activeTurns[identifier]?.scheduler === retired {
      guard let agent = activeTurns[identifier]?.agent else { continue }
      activeTurns[identifier]?.scheduler = current
      current.resumeDetached(agent, threadId: Self.schedulerThreadId) {
        [weak self, weak current, weak agent] _, _ in
        DispatchQueue.main.async {
          guard let agent else { return }
          current?.markAsCompleted(agent)
          self?.turnDidComplete(agent)
        }
      }
    }
  }

  /// What the idle timer also has to unload, since a finished turn leaves the scheduler.
  var idleAgents: [ResponsesAgent] {
    dispatchPrecondition(condition: .onQueue(.main))
    return idleAgentPool.agents
  }

  /// The idle timer unloaded these, so there's nothing left for a request to continue.
  func remove(idleAgents: [ResponsesAgent]) {
    dispatchPrecondition(condition: .onQueue(.main))
    idleAgentPool.remove(idleAgents)
    release(idleAgents)
  }

  /// Their caches and weights go back on the queue that used them.
  private func release(_ agents: [ResponsesAgent]) {
    guard !agents.isEmpty else { return }
    queue.async {
      for agent in agents { agent.unloadCaches() }
    }
  }

  private func sendKeepAlives() {
    for pendingRequest in pendingRequests where pendingRequest.request.isStreaming {
      pendingRequest.connection.sendKeepAlive()
    }
    for activeTurn in activeTurns.values where activeTurn.pendingRequest.request.isStreaming {
      if case .generating = activeTurn.phase { continue }
      activeTurn.pendingRequest.connection.sendKeepAlive()
    }
  }

  /// The page shows one request for now: the one on the model, or else any that's waiting.
  private func updateActiveState() {
    let phases = activeTurns.values.map(\.phase)
    let runningPhase = phases.first { $0 != .waiting }
    updateState {
      $0.activePhase = runningPhase ?? phases.first
      $0.queuedRequestCount = pendingRequests.count + max(0, activeTurns.count - 1)
    }
  }

  private func updateState(_ update: (inout ServeState) -> Void) {
    var newState = state.value
    update(&newState)
    guard newState != state.value else { return }
    state.send(newState)
  }

  private func updateContextCacheSize() {
    guard let projectPath = delegate?.serveControllerContextCacheProjectPath(self),
      let storePath = contextCacheStorePath(projectPath: projectPath)
    else { return }
    let sizes = ["", "-wal", "-shm"].compactMap {
      (try? FileManager.default.attributesOfItem(atPath: storePath + $0)[.size]) as? Int64
    }
    updateState { $0.contextCacheSize = sizes.isEmpty ? nil : sizes.reduce(0, +) }
  }

  private func takeSample() {
    if !activeTurns.isEmpty {
      updateContextCacheSize()
    }
    let memoryBytes = Self.residentMemory()
    updateState {
      let contextCacheBytes = $0.contextCacheSize ?? 0
      $0.metrics.sample(
        at: Date(), memoryBytes: memoryBytes, contextCacheBytes: contextCacheBytes)
    }
  }

  /// What this app holds in RAM, chat included: its footprint, which has the KV caches but not the
  /// weights, and the pages it has mapped from files, which are the weights. The resident size alone
  /// leaves out the KV caches, as Metal holds them.
  private static func residentMemory() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Int64(info.phys_footprint) + Int64(info.external) : 0
  }

  private func respond(
    _ connection: StreamingHTTPConnection, status: Int, type: String, code: String, message: String,
    parameter: String? = nil
  ) {
    connection.respond(
      status: status, contentType: "application/json",
      body: ResponsesResponseWriter.errorBody(
        type: type, code: code, message: message, parameter: parameter))
  }

  private func handleModels(on connection: StreamingHTTPConnection) {
    let models = state.value.model.map {
      [["id": $0, "object": "model", "created": 0, "owned_by": "local"] as [String: Any]]
    }
    let body: [String: Any] = ["object": "list", "data": models ?? []]
    connection.respond(
      status: 200, contentType: "application/json",
      body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
  }

  private func handleResponses(
    _ httpRequest: StreamingHTTPRequest, on connection: StreamingHTTPConnection
  ) {
    let request: ResponsesRequest
    do {
      request = try ResponsesRequest(body: httpRequest.body)
    } catch ResponsesRequestError.unsupported(let parameter, let message) {
      respond(
        connection, status: 400, type: "invalid_request_error", code: "unsupported_parameter",
        message: message, parameter: parameter)
      return
    } catch ResponsesRequestError.invalid(let message) {
      respond(
        connection, status: 400, type: "invalid_request_error", code: "invalid_request",
        message: message)
      return
    } catch {
      respond(
        connection, status: 400, type: "invalid_request_error", code: "invalid_request",
        message: "\(error)")
      return
    }
    guard let model = state.value.model else {
      respond(
        connection, status: 503, type: "server_error", code: "model_not_available",
        message: "No model is selected to serve.")
      return
    }
    // Those who left while waiting shouldn't keep others out.
    pendingRequests.removeAll { $0.connection.isDisconnected }
    guard pendingRequests.count < Self.maximumQueuedRequests else {
      respond(
        connection, status: 429, type: "rate_limit_error", code: "too_many_requests",
        message:
          "\(Self.maximumQueuedRequests) requests are already waiting. Try again once they finish."
      )
      return
    }
    let writer = ResponsesResponseWriter(
      transport: connection, isStreaming: request.isStreaming, model: model)
    // A stream's status and first events go out now, so a client can tell it was accepted however
    // long the queue is. Later errors arrive as response.failed.
    writer.start()
    let pendingRequest = PendingRequest(
      request: request, connection: connection, writer: writer, arrivalDate: Date(),
      thinkingBudget: thinkingBudget)
    pendingRequests.append(pendingRequest)
    updateActiveState()
    tokenize(pendingRequest, for: model)
  }

  /// Off the generation queue, as a long conversation takes up to a few seconds and the chat might be
  /// waiting. An agent is only chosen once the tokens are known, since they're what chooses it.
  private func tokenize(_ pendingRequest: PendingRequest, for model: String) {
    guard let adapter = tokenizingAdapter(for: model) else {
      pendingRequests.removeAll { $0.identifier == pendingRequest.identifier }
      pendingRequest.writer.fail(
        status: 503, type: "server_error", code: "model_not_available",
        message: "The model selected to serve is not ready. Check that it is fully downloaded.")
      updateActiveState()
      startNextRequests()
      return
    }
    tokenizationQueue.async { [weak self] in
      let baseTokens = adapter.promptTokens(
        for: pendingRequest.request, isThinking: pendingRequest.thinkingBudget > 0)
      DispatchQueue.main.async {
        guard let self,
          let index = self.pendingRequests.firstIndex(where: {
            $0.identifier == pendingRequest.identifier
          })
        else { return }
        self.pendingRequests[index].tokenized = (model, baseTokens)
        self.startNextRequests()
      }
    }
  }

  private func startNextRequests() {
    dispatchPrecondition(condition: .onQueue(.main))
    // Those who left while waiting their turn.
    pendingRequests.removeAll { $0.connection.isDisconnected }
    while let pendingRequest = pendingRequests.first, let tokenized = pendingRequest.tokenized {
      guard let model = state.value.model,
        let scheduler = delegate?.serveController(self, schedulerFor: model)
      else {
        pendingRequests.removeFirst()
        pendingRequest.writer.fail(
          status: 503, type: "server_error", code: "model_not_available",
          message: "No model is selected to serve.")
        continue
      }
      // The serving model changed while it waited, and its tokens may be of no use to this one.
      guard tokenized.model == model else {
        pendingRequests[0].tokenized = nil
        tokenize(pendingRequests[0], for: model)
        return
      }
      // A turn that ends as its time slice runs out only comes back once the scheduler gets round
      // to it again, which a quick follow-up can beat. Its agent holds this conversation, so wait.
      let isFollowingUnreturnedTurn = activeTurns.values.contains {
        !$0.retainedTokens.isEmpty && $0.retainedTokens.count < tokenized.baseTokens.count
          && tokenized.baseTokens.starts(with: $0.retainedTokens)
      }
      guard !isFollowingUnreturnedTurn else { break }
      // A model folder change while it was tokenized can move the model's files. Checking again
      // releases the idle agents still at the old paths, so none of them is reused.
      guard tokenizingAdapter(for: model) != nil else {
        pendingRequests.removeFirst()
        pendingRequest.writer.fail(
          status: 503, type: "server_error", code: "model_not_available",
          message: "The model selected to serve is not ready. Check that it is fully downloaded.")
        continue
      }
      let reusedAgent = idleAgentPool.takeAgent(continuing: tokenized.baseTokens)
      if reusedAgent == nil {
        // With every agent running it waits for a turn to end. Otherwise a new agent takes the
        // place of an idle one once there are as many as are kept.
        guard activeTurns.count < Self.maximumAgents else { break }
        if activeTurns.count + idleAgentPool.count >= Self.maximumAgents,
          let expired = idleAgentPool.expire()
        {
          release([expired])
        }
      }
      guard let agent = reusedAgent ?? makeAgent(for: model) else {
        pendingRequests.removeFirst()
        pendingRequest.writer.fail(
          status: 503, type: "server_error", code: "model_not_available",
          message: "The model selected to serve is not ready. Check that it is fully downloaded.")
        continue
      }
      pendingRequests.removeFirst()
      agent.nextRequest = ResponsesAgent.Request(
        request: pendingRequest.request, baseTokens: tokenized.baseTokens,
        thinkingBudget: pendingRequest.thinkingBudget,
        writer: pendingRequest.writer, transport: pendingRequest.connection)
      activeTurns[ObjectIdentifier(agent)] = ActiveTurn(
        agent: agent, pendingRequest: pendingRequest, didContinueEarlierTurn: reusedAgent != nil,
        scheduler: scheduler, timing: ServeRequestTiming(startDate: pendingRequest.arrivalDate))
      activeTurnCount.store(activeTurns.count, ordering: .relaxed)
      scheduler.askDetached(agent, threadId: Self.schedulerThreadId) {
        [weak self, weak scheduler, weak agent] _, _ in
        DispatchQueue.main.async {
          guard let agent else { return }
          // Even once serving is off, as the scheduler holds on to the agent until then.
          scheduler?.markAsCompleted(agent)
          self?.turnDidComplete(agent)
        }
      }
    }
    updateActiveState()
  }

  private func turnDidComplete(_ agent: ResponsesAgent) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let activeTurn = activeTurns.removeValue(forKey: ObjectIdentifier(agent)) else { return }
    activeTurnCount.store(activeTurns.count, ordering: .relaxed)
    // A turn on the previous model has nothing to offer the next request.
    if !activeTurn.retainedTokens.isEmpty, agent.adapter.filePath == tokenizingAdapter?.filePath {
      idleAgentPool.add(
        agent, tokens: activeTurn.retainedTokens, wasReused: activeTurn.didContinueEarlierTurn)
    } else {
      release([agent])
    }
    updateContextCacheSize()
    updateActiveState()
    startNextRequests()
  }

  private func tokenizingAdapter(for model: String) -> (any ResponsesModelAdapter)? {
    // A model folder change can move the model's files, which then need a generator at their new
    // paths.
    if let tokenizingAdapter, agentModel == model,
      textGenerator?.filePaths.allSatisfy(LLMZoo.isFilePathForModelDownloaded) == true
    {
      return tokenizingAdapter
    }
    guard let delegate,
      let textGenerator = delegate.serveController(self, textGeneratorToRun: model),
      let adapter = responsesModelAdapter(
        for: textGenerator,
        projectPath: delegate.serveControllerContextCacheProjectPath(self))
    else { return nil }
    // The idle agents hold KV caches of the model that's no longer served.
    release(idleAgentPool.removeAll())
    self.textGenerator = textGenerator
    tokenizingAdapter = adapter
    agentModel = model
    return adapter
  }

  private func makeAgent(for model: String) -> ResponsesAgent? {
    guard let delegate, tokenizingAdapter(for: model) != nil, let textGenerator,
      let adapter = responsesModelAdapter(
        for: textGenerator,
        projectPath: delegate.serveControllerContextCacheProjectPath(self))
    else { return nil }
    let agent = ResponsesAgent(
      adapter: adapter, graph: graph, streamContext: streamContext, timeSlice: timeSlice,
      activeTurnCount: activeTurnCount)
    agent.delegate = self
    return agent
  }
}

extension ServeController: StreamingHTTPServerDelegate {
  func streamingHTTPServer(
    _ server: StreamingHTTPServer, didChange state: StreamingHTTPServer.State
  ) {
    guard server === self.server || state == .stopped else { return }
    updateState {
      switch state {
      case .starting: $0.listener = .starting
      case .ready: $0.listener = .listening
      case .addressInUse: $0.listener = .portInUse
      case .failed(let message): $0.listener = .failed(message)
      case .stopped: $0.listener = .off
      }
    }
  }

  func streamingHTTPServer(
    _ server: StreamingHTTPServer, didReceive request: StreamingHTTPRequest,
    on connection: StreamingHTTPConnection
  ) {
    switch (request.method, request.path) {
    case ("GET", "/v1/models"):
      handleModels(on: connection)
    case ("POST", "/v1/responses"):
      handleResponses(request, on: connection)
    case (_, "/v1/models"), (_, "/v1/responses"):
      respond(
        connection, status: 405, type: "invalid_request_error", code: "method_not_allowed",
        message: "\(request.method) is not allowed here.")
    default:
      respond(
        connection, status: 404, type: "invalid_request_error", code: "not_found",
        message: "This server only has /v1/responses and /v1/models.")
    }
  }
}

extension ServeController: ResponsesAgentDelegate {
  func responsesAgent(_ agent: ResponsesAgent, didUpdate progress: ResponsesAgent.Progress) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let identifier = ObjectIdentifier(agent)
      guard var activeTurn = self.activeTurns[identifier] else { return }
      let date = Date()
      switch progress {
      case .preparing:
        activeTurn.timing.enter(.prefilling, at: date)
        activeTurn.phase = .prefilling(finished: 0, total: 0)
      case .prefilling(let finished, let total):
        activeTurn.timing.enter(.prefilling, at: date)
        activeTurn.phase = .prefilling(finished: finished, total: total)
      case .generating(let tokens, let tokensPerSecond):
        activeTurn.timing.enter(.generating, at: date)
        activeTurn.phase = .generating(tokens: tokens, tokensPerSecond: tokensPerSecond)
        let newTokens = max(0, tokens - activeTurn.generatedTokens)
        activeTurn.generatedTokens += newTokens
        self.updateState { $0.metrics.addGeneratedTokens(newTokens) }
      case .paused:
        activeTurn.timing.enter(.waiting, at: date)
        activeTurn.phase = .waiting
      }
      self.activeTurns[identifier] = activeTurn
      self.updateActiveState()
    }
  }

  func responsesAgent(_ agent: ResponsesAgent, didFinish summary: ResponsesAgent.Summary) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let identifier = ObjectIdentifier(agent)
      guard var activeTurn = self.activeTurns[identifier] else { return }
      let date = Date()
      // Closes whichever phase it ended in.
      activeTurn.timing.enter(.waiting, at: date)
      activeTurn.retainedTokens = summary.retainedTokens
      self.activeTurns[identifier] = activeTurn
      self.updateState {
        $0.metrics.addGeneratedTokens(summary.usage.outputTokens - activeTurn.generatedTokens)
        $0.metrics.add(
          ServeMetrics.Request(
            date: date, status: summary.status, inputTokens: summary.usage.inputTokens,
            cachedInputTokens: summary.usage.cachedInputTokens,
            outputTokens: summary.usage.outputTokens, timing: activeTurn.timing,
            prefillTokensPerSecond: Double(summary.prefillTokensPerSecond),
            generationTokensPerSecond: Double(summary.generationTokensPerSecond)))
      }
    }
  }
}
