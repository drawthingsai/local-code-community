import BashToolContext
import Foundation
import ProjectHistoryManager
import RemoteAPI
import SQLiteDflat
import WebSearch

final class RemoteChatProvider {
  var bashToolContext = BashToolContext()

  struct StatusRequest {
    var identifier: UUID
    var request: RemoteRequestCancellable
  }

  private struct Environment: Equatable {
    var profile: RemoteProviderProfile
    var workspacePath: String
    var webSearchProvider: WebSearchProvider
    var systemPromptContext: RemoteSystemPromptContext
  }

  private struct ProviderKey: Equatable {
    let endpoint: RemoteProviderEndpoint
    let authenticationKind: RemoteAuthenticationKind
    let credentialIdentifier: String
    let fallbackLimits: RemoteModelLimits

    init(_ profile: RemoteProviderProfile) {
      endpoint = profile.endpoint
      authenticationKind = profile.authorization.kind
      credentialIdentifier = profile.credentialIdentifier
      fallbackLimits = profile.fallbackLimits
    }
  }

  private final class Conversation {
    var bashUserInteraction = BashUserInteraction()
    var agent: RemoteAgent?
    var supportsImageInput = false
    var environment: Environment?
    var forceHistoryCheckpoint = false
    var preparationIdentifier: UUID?
    var preparationCompletion: ((Result<Void, Error>) -> Void)?
    var isSending = false
    var didRequestCancellation = false
    var latestProgress: RemoteAgentProgress?
    var metrics: RemoteAgentMetrics?
    var cachedStatus: RemoteAgentStatus?
    var statusRequestIdentifier = 0

    var isActive: Bool {
      isSending || agent?.isRunning == true || latestProgress != nil
    }
  }

  private final class LimitsLoad {
    let key: ProviderKey
    var request: RemoteRequestCancellable?
    var completions = [(Result<RemoteModelLimits, RemoteModelMetadataError>) -> Void]()

    init(key: ProviderKey) {
      self.key = key
    }
  }

  private static let transcriptQueue = DispatchQueue(
    label: "com.liuliu.local-code.remote-chat-transcript", qos: .utility)

  let provider: RemoteProvider
  lazy var openRouterKeyStatusClient = OpenRouterKeyStatusClient(
    baseURL: RemoteProvider.openRouter.defaultBaseURL!)
  var statusRequest: StatusRequest?
  var statusDidChange: ((ProjectThreadIdentifier, RemoteAgentStatus?) -> Void)?
  /// For `.deviceLink`: the Mac's model as a conversation's chat provider, over the device's link.
  var makeMacModelChatProvider:
    (
      (ProjectThreadIdentifier, RemoteProviderProfile, _ maximumOutputTokens: Int) ->
        RemoteChatProviding?
    )?

  private let workspace: SQLiteWorkspace
  private let metadataClient = RemoteModelMetadataClient()
  private var conversations = [ProjectThreadIdentifier: Conversation]()
  private var limitsLoad: LimitsLoad?
  private var cachedLimits: (key: ProviderKey, limits: RemoteModelLimits)?
  private var calibration: (key: ProviderKey, tokenPerByte: Double?, effectiveWindow: Int?)?

  var profile: RemoteProviderProfile? {
    provider.profile(in: workspace)
  }

  var title: String {
    profile?.title ?? provider.title
  }

  init(provider: RemoteProvider, workspace: SQLiteWorkspace) {
    self.provider = provider
    self.workspace = workspace
  }

  deinit {
    statusRequest?.request.cancel()
    unload()
  }

  func prepare(
    _ id: ProjectThreadIdentifier, profile: RemoteProviderProfile, workspacePath: String,
    webSearchProvider: WebSearchProvider, state: RemoteAgentState,
    forceHistoryCheckpoint: Bool, forSending: Bool = false,
    completion: @escaping (Result<Void, Error>) -> Void = { _ in }
  ) {
    let projectURL = URL(fileURLWithPath: id.projectPath, isDirectory: true)
    let environment = Environment(
      profile: profile,
      workspacePath: URL(fileURLWithPath: workspacePath).standardizedFileURL.path,
      webSearchProvider: webSearchProvider,
      systemPromptContext: RemoteSystemPromptContext(
        runtime: .currentApp,
        skillCatalog: SkillCatalog.find(
          roots: SkillCatalog.roots(
            builtInSkillsURL: Resources.resourceURL?.appendingPathComponent("Skills"),
            projectURL: projectURL, workspaceURL: URL(fileURLWithPath: workspacePath))),
        projectContext: ProjectContext.load(projectURL: projectURL),
        environmentContext: EnvironmentContext(
          model: profile.model, provider: provider.rawValue,
          pythonLibraryURL: Bundle.main.resourceURL?.appendingPathComponent(
            "Library", isDirectory: true)),
        memoryContext: (workspace.dictionary["is_memory_enabled", Bool.self] ?? true)
          ? MemoryContext.load(projectPath: id.projectPath) : .empty))
    let conversation = conversations[id] ?? Conversation()
    conversations[id] = conversation
    if let agent = conversation.agent, conversation.environment == environment,
      agent.isRunning || conversation.latestProgress != nil
        || agent.state.transcript == state.transcript
    {
      conversation.forceHistoryCheckpoint =
        conversation.forceHistoryCheckpoint || forceHistoryCheckpoint
      conversation.isSending = conversation.isSending || forSending
      refreshStatus(for: id, conversation: conversation)
      completion(.success(()))
      return
    }
    guard conversation.agent?.isRunning != true && conversation.latestProgress == nil else {
      completion(.failure(RemoteChatError.alreadyRunning))
      return
    }
    cancelPreparation(conversation)
    if let agent = conversation.agent, let previousEnvironment = conversation.environment {
      captureCalibration(from: agent, profile: previousEnvironment.profile)
    }
    discardAgent(for: id, conversation: conversation)

    let identifier = UUID()
    conversation.preparationIdentifier = identifier
    conversation.preparationCompletion = completion
    conversation.isSending = forSending
    loadLimits(profile: profile) { [weak self, weak conversation] result in
      guard let self, let conversation,
        self.conversations[id] === conversation,
        conversation.preparationIdentifier == identifier
      else { return }
      conversation.preparationIdentifier = nil
      conversation.preparationCompletion = nil
      switch result {
      case .success(let limits):
        do {
          try self.createAgent(
            for: id, conversation: conversation, environment: environment, state: state,
            limits: limits, forceHistoryCheckpoint: forceHistoryCheckpoint)
          completion(.success(()))
        } catch {
          conversation.isSending = false
          completion(.failure(error))
        }
      case .failure(let error):
        conversation.isSending = false
        self.refreshStatus(for: id, conversation: conversation)
        completion(.failure(error))
      }
    }
  }

  /// Images go to providers that accept them; the prompt still links them for the others.
  func send(
    _ prompt: String, images: [RemoteImage] = [], in id: ProjectThreadIdentifier,
    bashUserInteraction: BashUserInteraction,
    progress: @escaping (RemoteAgentProgress) -> Void,
    completion: @escaping (
      Result<RemoteAgentCompletion, RemoteChatError>,
      Result<(plaintext: String, compacted: Bool), Error>,
      _ wasCancelled: Bool
    ) -> Void
  ) {
    guard let conversation = conversations[id], let agent = conversation.agent,
      let environment = conversation.environment
    else {
      conversations[id]?.isSending = false
      completion(.failure(.sessionUnavailable), .failure(RemoteChatError.sessionUnavailable), false)
      return
    }
    conversation.bashUserInteraction = bashUserInteraction
    let transcript = agent.state.transcript
    let forceHistoryCheckpoint = conversation.forceHistoryCheckpoint
    conversation.isSending = true
    conversation.didRequestCancellation = false
    conversation.metrics = nil
    conversation.latestProgress = RemoteAgentProgress(
      text: "", streamingToolCalls: [], tools: [])
    agent.send(
      environment.systemPromptContext.skillCatalog.prompt(for: prompt),
      images: conversation.supportsImageInput ? images : [],
      progress: { [weak self, weak conversation, weak agent] value in
        DispatchQueue.main.async {
          guard let self, let conversation, let agent,
            self.conversations[id] === conversation, conversation.agent === agent
          else { return }
          conversation.latestProgress = value
          conversation.metrics = value.metrics
          progress(value)
        }
      },
      completion: { [weak self, weak conversation, weak agent] result in
        guard let agent else { return }
        Self.transcriptQueue.async {
          let transcriptLog = Result {
            let remainsIncremental =
              !forceHistoryCheckpoint && agent.state.transcript.starts(with: transcript)
            let entries =
              remainsIncremental
              ? Array(agent.state.transcript.dropFirst(transcript.count))
              : agent.state.transcript
            return (
              plaintext: try RemoteTranscriptCodec.encode(entries),
              compacted: !remainsIncremental
            )
          }
          DispatchQueue.main.async {
            guard let self, let conversation,
              self.conversations[id] === conversation, conversation.agent === agent
            else { return }
            conversation.latestProgress = nil
            conversation.isSending = false
            if case .success(let value) = result {
              conversation.metrics = value.metrics
            }
            if case .success = transcriptLog {
              conversation.forceHistoryCheckpoint = false
            }
            self.captureCalibration(from: agent, profile: conversation.environment?.profile)
            self.refreshStatus(for: id, conversation: conversation)
            // Stop may arrive after generation finishes while transcript encoding is still running.
            completion(result, transcriptLog, conversation.didRequestCancellation)
          }
        }
      })
  }

  func isActive(_ id: ProjectThreadIdentifier) -> Bool {
    conversations[id]?.isActive == true
  }

  func latestProgress(for id: ProjectThreadIdentifier) -> RemoteAgentProgress? {
    conversations[id]?.latestProgress
  }

  func bashUserInteraction(for id: ProjectThreadIdentifier) -> BashUserInteraction? {
    conversations[id]?.bashUserInteraction
  }

  func status(for id: ProjectThreadIdentifier) -> RemoteAgentStatus? {
    conversations[id]?.cachedStatus
  }

  func metrics(for id: ProjectThreadIdentifier) -> RemoteAgentMetrics? {
    conversations[id]?.metrics
  }

  func hasActiveConversations(projectPath: String? = nil) -> Bool {
    conversations.contains { id, conversation in
      (projectPath == nil || id.projectPath == projectPath)
        && conversation.isActive
    }
  }

  func cancel(_ id: ProjectThreadIdentifier) {
    guard let conversation = conversations[id] else { return }
    conversation.didRequestCancellation = true
    if conversation.preparationIdentifier != nil {
      cancelPreparation(conversation)
      refreshStatus(for: id, conversation: conversation)
    } else {
      conversation.agent?.cancel()
    }
  }

  func removeConversations(projectPath: String) {
    for id in conversations.keys.filter({ $0.projectPath == projectPath }) {
      remove(id)
    }
  }

  func remove(_ id: ProjectThreadIdentifier) {
    guard let conversation = conversations[id] else { return }
    cancelPreparation(conversation)
    discardAgent(for: id, conversation: conversation)
    conversations[id] = nil
  }

  func unload() {
    cancelLimitsLoad()
    for id in Array(conversations.keys) {
      remove(id)
    }
    cachedLimits = nil
    calibration = nil
  }

  private func createAgent(
    for id: ProjectThreadIdentifier, conversation: Conversation, environment: Environment,
    state: RemoteAgentState, limits: RemoteModelLimits, forceHistoryCheckpoint: Bool
  ) throws {
    var state = state
    let key = ProviderKey(environment.profile)
    if calibration?.key == key {
      state.tokenPerByte = calibration?.tokenPerByte
      state.effectiveContextWindowTokens = calibration?.effectiveWindow
    }
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: limits.contextWindowTokens,
      reservedOutputTokens: limits.maximumOutputTokens,
      compactionThreshold: environment.profile.compactionThreshold)
    let provider: RemoteChatProviding
    if environment.profile.endpoint.provider == .deviceLink {
      guard
        let macModelProvider = makeMacModelChatProvider?(
          id, environment.profile, configuration.reservedOutputTokens)
      else { throw RemoteChatError.sessionUnavailable }
      provider = macModelProvider
    } else {
      provider = try environment.profile.endpoint.makeChatProvider(
        authorization: environment.profile.authorization,
        maximumOutputTokens: configuration.reservedOutputTokens,
        reasoningEffort: environment.profile.reasoningEffort)
    }
    let bridge = RemoteToolsBridge(
      projectPath: id.projectPath, workspacePath: environment.workspacePath,
      webSearchProvider: environment.webSearchProvider,
      supportsImageInput: provider.supportsImageInput,
      bashToolContext: bashToolContext.with(
        projectURL: URL(fileURLWithPath: id.projectPath, isDirectory: true), threadId: id.threadId))
    let systemPromptTemplate = SystemPromptTemplate.load(
      projectURL: URL(fileURLWithPath: id.projectPath, isDirectory: true),
      model: environment.profile.model, template: remoteSystemPromptTemplate)
    let agent = RemoteAgent(
      provider: provider,
      systemPrompt: environment.systemPromptContext.render(systemPromptTemplate),
      tools: bridge.tools,
      configuration: configuration, state: state,
      stateDidChange: { [weak self, weak conversation] in
        DispatchQueue.main.async {
          guard let self, let conversation,
            self.conversations[id] === conversation,
            let agent = conversation.agent
          else { return }
          self.captureCalibration(from: agent, profile: environment.profile)
          self.refreshStatus(for: id, conversation: conversation)
        }
      }
    ) { [weak conversation] call, progress, completion in
      guard let conversation else { return nil }
      return bridge.execute(
        call, bashUserInteraction: conversation.bashUserInteraction, progress: progress,
        completion: completion)
    }
    conversation.agent = agent
    conversation.supportsImageInput = provider.supportsImageInput
    conversation.environment = environment
    conversation.forceHistoryCheckpoint = forceHistoryCheckpoint
    captureCalibration(from: agent, profile: environment.profile)
    refreshStatus(for: id, conversation: conversation)
  }

  private func loadLimits(
    profile: RemoteProviderProfile,
    completion: @escaping (Result<RemoteModelLimits, RemoteModelMetadataError>) -> Void
  ) {
    // A Mac's model has the limits of its agent there.
    if profile.endpoint.provider == .deviceLink {
      completion(.success(profile.fallbackLimits))
      return
    }
    let key = ProviderKey(profile)
    if cachedLimits?.key == key, let limits = cachedLimits?.limits {
      completion(.success(limits))
      return
    }
    if let limitsLoad, limitsLoad.key == key {
      limitsLoad.completions.append(completion)
      return
    }
    cancelLimitsLoad()
    let load = LimitsLoad(key: key)
    load.completions = [completion]
    limitsLoad = load
    load.request = metadataClient.fetch(
      endpoint: profile.endpoint, authorization: profile.authorization,
      fallbackLimits: profile.fallbackLimits
    ) { [weak self, weak load] result in
      DispatchQueue.main.async {
        guard let self, let load, self.limitsLoad === load else { return }
        self.limitsLoad = nil
        if case .success(let limits) = result {
          self.cachedLimits = (key, limits)
        }
        let completions = load.completions
        load.completions.removeAll()
        completions.forEach { $0(result) }
      }
    }
  }

  private func cancelLimitsLoad() {
    guard let load = limitsLoad else { return }
    limitsLoad = nil
    load.request?.cancel()
    let completions = load.completions
    load.completions.removeAll()
    completions.forEach { $0(.failure(.cancelled)) }
  }

  private func cancelPreparation(_ conversation: Conversation) {
    guard conversation.preparationIdentifier != nil else { return }
    conversation.preparationIdentifier = nil
    conversation.isSending = false
    let completion = conversation.preparationCompletion
    conversation.preparationCompletion = nil
    completion?(.failure(RemoteModelMetadataError.cancelled))
  }

  private func discardAgent(for id: ProjectThreadIdentifier, conversation: Conversation) {
    let agent = conversation.agent
    conversation.agent = nil
    conversation.environment = nil
    conversation.forceHistoryCheckpoint = false
    conversation.isSending = false
    conversation.latestProgress = nil
    conversation.metrics = nil
    conversation.statusRequestIdentifier += 1
    conversation.cachedStatus = nil
    statusDidChange?(id, nil)
    agent?.cancel()
  }

  private func captureCalibration(from agent: RemoteAgent, profile: RemoteProviderProfile?) {
    guard let profile else { return }
    let state = agent.state
    calibration = (
      ProviderKey(profile), state.tokenPerByte, state.effectiveContextWindowTokens
    )
  }

  private func refreshStatus(for id: ProjectThreadIdentifier, conversation: Conversation) {
    conversation.statusRequestIdentifier += 1
    let identifier = conversation.statusRequestIdentifier
    guard let agent = conversation.agent else {
      conversation.cachedStatus = nil
      statusDidChange?(id, nil)
      return
    }
    agent.status { [weak self, weak conversation, weak agent] status in
      DispatchQueue.main.async {
        guard let self, let conversation, let agent,
          self.conversations[id] === conversation, conversation.agent === agent,
          conversation.statusRequestIdentifier == identifier
        else { return }
        conversation.cachedStatus = status
        self.statusDidChange?(id, status)
      }
    }
  }
}
