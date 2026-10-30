import BashToolContext
import Combine
import CryptoKit
import DeviceLink
import Dflat
import Foundation
import GRPC
import Localization
import ModelZoo
import ProjectHistoryManager
import QuartzCore
import RemoteAPI
import SQLiteDflat
import UIKit
import UniformTypeIdentifiers

/// A project as the Threads backend works in it: its folder, its database and its history.
struct ThreadsProject {
  let url: URL
  let workspace: SQLiteWorkspace
  let history: ProjectHistoryManager
}

/// What a Mac keeps to serve its threads: the projects other devices work in, each watched
/// thread's subscriptions, and each thread's running turn. Main queue only.
final class ThreadsBackendState {
  /// By canonical project path. A project stays open here while a device watches one of its
  /// threads; the open project and the agent scheduler share these databases.
  var projects = [String: ThreadsProject]()
  var watches = [ThreadRef: ThreadWatch]()
  /// Each thread's turn until its completion has run, by turn ID.
  var runningTurns = [ThreadRef: String]()
  /// Threads whose messages wait in their queues for another of the Mac's models, which it loads
  /// once nothing runs on the one it has, by model file.
  var waitingForModel = [ThreadRef: String]()
  /// By project path as the drawer lists it.
  var projectIDs = [String: String]()
  var cancellables = Set<AnyCancellable>()
}

/// A watched thread's subscriptions to its project's database, and what was sent from them.
final class ThreadWatch {
  /// Canonical, as the kept projects are keyed.
  let projectPath: String
  /// As the Mac opened it, which tool subtitles are relative to.
  let projectURL: URL
  let workspace: SQLiteWorkspace
  var subscriptions = [Workspace.Subscription]()
  /// The thread's saved nodes, oldest first, so only later ones go out, or the ones after a
  /// node that was replaced.
  var nodeDatetimes: [Int64]
  /// The thread's model as last sent, so a move to another one goes out.
  var model: String?

  init(
    projectPath: String, projectURL: URL, workspace: SQLiteWorkspace, nodeDatetimes: [Int64],
    model: String?
  ) {
    self.projectPath = projectPath
    self.projectURL = projectURL
    self.workspace = workspace
    self.nodeDatetimes = nodeDatetimes
    self.model = model
  }
}

/// What a thread runs on, on the Mac: one of its downloaded models, or a model of a cloud provider
/// set up on it.
private enum ThreadRunModel: Equatable {
  case local(file: String)
  case cloud(RemoteProvider, model: String)
}

/// A Mac's projects and threads for the Threads service (see RemoteAccessServices.md): the
/// drawer's list, each thread's history and queue, and its turns, sent from another device the way
/// the Mac's composer sends them.
extension ChatWorkflow: ThreadsBackend {
  /// Tells the hub what changes: the drawer's list, and the threads devices watch.
  func startServingThreads() {
    dispatchPrecondition(condition: .onQueue(.main))
    let hub = deviceLink.threadsHub
    hub.backend = self
    deviceLink.inferenceHub.backend = self
    settingsWorkflow.listedProjectThreads.dropFirst().receive(on: DispatchQueue.main).sink { _ in
      hub.projectsDidChange()
    }.store(in: &threadsBackendState.cancellables)
    // At once, so a thread's subscriptions start from the history its first watcher was sent.
    hub.watchedThreads.sink { [weak self] watched in
      self?.watch(watched)
    }.store(in: &threadsBackendState.cancellables)
  }

  // MARK: - Projects

  /// The hex of the first 16 bytes of SHA-256 over the project's resolved path.
  private func threadsProjectID(forPath path: String) -> String {
    if let id = threadsBackendState.projectIDs[path] { return id }
    let id = SHA256.hash(data: Data(AgentScheduler.canonicalProjectPath(path).utf8)).prefix(16).map
    {
      String(format: "%02x", $0)
    }.joined()
    threadsBackendState.projectIDs[path] = id
    return id
  }

  private func projectPath(forID id: String) -> String? {
    settingsWorkflow.projects.first { threadsProjectID(forPath: $0.path) == id }?.path
  }

  /// The project's database as the Mac uses it: the open project's, a running agent's, one kept
  /// for devices, or one opened now, created for a project with no threads yet.
  private func threadsProject(forID id: String) -> ThreadsProject? {
    guard let path = projectPath(forID: id) else { return nil }
    let canonicalPath = AgentScheduler.canonicalProjectPath(path)
    if let projectURL, AgentScheduler.canonicalProjectPath(projectURL.path) == canonicalPath,
      let projectWorkspace, let projectHistoryManager
    {
      return ThreadsProject(
        url: projectURL, workspace: projectWorkspace, history: projectHistoryManager)
    }
    if let project = threadsBackendState.projects[canonicalPath] { return project }
    let url = URL(fileURLWithPath: path, isDirectory: true)
    let retiringScheduler = retiringAgentSchedulers.first {
      $0.residentProjectWorkspace(projectPath: canonicalPath) != nil
    }
    retiringScheduler?.keepProjectWorkspace(projectPath: canonicalPath)
    guard
      let workspace = agentScheduler.residentProjectWorkspace(projectPath: canonicalPath)
        ?? retiringScheduler?.residentProjectWorkspace(projectPath: canonicalPath)
        ?? Self.projectMetadataURL(creatingIn: url).map({
          SQLiteWorkspace(filePath: $0.path, fileProtectionLevel: .noProtection)
        })
    else { return nil }
    let project = ThreadsProject(
      url: url, workspace: workspace, history: ProjectHistoryManager(project: workspace))
    threadsBackendState.projects[canonicalPath] = project
    return project
  }

  /// Lets go of projects no device watches a thread in, closing those nothing else has open.
  func closeUnwatchedProjects() {
    let state = threadsBackendState
    let watchedPaths = Set(state.watches.values.map(\.projectPath))
    for (path, project) in state.projects where !watchedPaths.contains(path) {
      // A retiring scheduler still uses it, and was asked to leave it open: it closes here once
      // that scheduler is done.
      guard
        !retiringAgentSchedulers.contains(where: {
          $0.residentProjectWorkspace(projectPath: path) === project.workspace
        })
      else { continue }
      state.projects[path] = nil
      guard project.workspace !== projectWorkspace,
        agentScheduler.residentProjectWorkspace(projectPath: path) !== project.workspace
      else { continue }
      project.workspace.shutdown(flags: [])
    }
  }

  private func isOnScreen(_ ref: ThreadRef) -> Bool {
    guard let projectURL, projectHistoryManager?.threadId == ref.threadID else { return false }
    return threadsProjectID(forPath: projectURL.path) == ref.projectID
  }

  // MARK: - ThreadsBackend

  func projects() -> [ProjectSummary] {
    let threads = Dictionary(
      grouping: settingsWorkflow.projectThreads.filter {
        $0.threadId >= 0
      }, by: \.projectPath)
    return settingsWorkflow.projects.map { project in
      let id = threadsProjectID(forPath: project.path)
      return ProjectSummary.with {
        $0.id = id
        $0.title = project.title
        $0.threads = (threads[project.path] ?? []).sorted { $0.updatedAt > $1.updatedAt }
          .prefix(20).map { thread in
            Self.summary(
              thread,
              ref: ThreadRef.with {
                $0.projectID = id
                $0.threadID = thread.threadId
              })
          }
      }
    }
  }

  func thread(_ ref: ThreadRef) -> ThreadSummary? {
    guard let path = projectPath(forID: ref.projectID) else { return nil }
    // The drawer's row knows whether a turn is running.
    if let listed = settingsWorkflow.projectThreads.first(where: {
      $0.threadId == ref.threadID && $0.projectPath == path
    }) {
      return Self.summary(listed, ref: ref)
    }
    guard let project = threadsProject(forID: ref.projectID),
      let thread = project.history.thread(id: ref.threadID)
    else { return nil }
    return ThreadSummary.with {
      $0.ref = ref
      $0.title = thread.title ?? ""
      $0.updatedAtMs = thread.updatedAt
      $0.lastMessage = thread.lastMessage ?? ""
      if threadsBackendState.runningTurns[ref] != nil {
        $0.status = .inProgress
      } else if thread.hasIncompleteResponse {
        $0.status = .incomplete
      } else {
        $0.status = thread.hasUnreadResponse ? .new : .idle
      }
    }
  }

  private static func summary(_ thread: ProjectController.Thread, ref: ThreadRef) -> ThreadSummary {
    ThreadSummary.with {
      $0.ref = ref
      $0.title = thread.title ?? ""
      $0.updatedAtMs = thread.updatedAt
      $0.lastMessage = thread.lastMessage ?? ""
      switch thread.status {
      case .idle: $0.status = .idle
      case .inProgress: $0.status = .inProgress
      case .incomplete: $0.status = .incomplete
      case .new: $0.status = .new
      }
    }
  }

  func history(of ref: ThreadRef) -> [HistoryMessage] {
    guard let project = threadsProject(forID: ref.projectID) else { return [] }
    return historyMessages(
      project.history.history(threadId: ref.threadID),
      model: project.history.thread(id: ref.threadID)?.model, projectPath: project.url.path)
  }

  /// Saved nodes as the Mac shows them: an answer's tool subtitles, then "---", then the answer.
  private func historyMessages(_ nodes: [ProjectHistoryNode], model: String?, projectPath: String)
    -> [HistoryMessage]
  {
    let nodes = nodes.filter { $0.role != .memory }
    let (safeTokenizer, toolCallSpecialTokens) = Self.tokenizers(forModel: model)
    let messages = Self.historyMessages(
      from: nodes, safeTokenizer: safeTokenizer, toolCallSpecialTokens: toolCallSpecialTokens,
      projectPath: projectPath, workspacePath: settingsWorkflow.workspaceFolderURL.path)
    return zip(nodes, messages).map { node, message in
      HistoryMessage.with {
        $0.datetimeMs = node.datetime
        switch message {
        case .user(let text, _):
          $0.role = .user
          $0.text = text
        case .assistant(let text, _, let duration):
          $0.role = .assistant
          $0.text = text
          $0.durationSeconds = duration
        }
      }
    }
  }

  func models() -> ModelList {
    ModelList.with {
      $0.providers =
        [
          ModelProvider.with {
            $0.models = LLMZoo.builtinSpecifications.filter { LLMZoo.isModelDownloaded($0) }.map {
              threadModel(.local(file: $0.file))
            }
            $0.selectedModelID = selectedLLM ?? ""
          }
        ]
        + RemoteProvider.allCases.filter { $0.account(in: workspace) != nil }.map { provider in
          ModelProvider.with {
            $0.id = provider.rawValue
            $0.title = provider.title
            $0.models = provider.cachedModels(in: workspace).map {
              threadModel(.cloud(provider, model: $0))
            }
            $0.selectedModelID = provider.model(in: workspace) ?? ""
          }
        }
      if let model = composerRunModel() { $0.defaultModel = threadModel(model) }
    }
  }

  func model(of ref: ThreadRef) -> ThreadModel? {
    guard let project = threadsProject(forID: ref.projectID) else { return nil }
    return threadModel(identifier: project.history.thread(id: ref.threadID)?.model)
  }

  /// A thread's saved model as devices see it; nil for one the Mac doesn't know.
  private func threadModel(identifier: String?) -> ThreadModel? {
    guard let identifier else { return nil }
    if let remote = parseRemoteThreadModelIdentifier(identifier) {
      return threadModel(.cloud(remote.provider, model: remote.model))
    }
    guard LLMZoo.specificationForModel(identifier) != nil else { return nil }
    return threadModel(.local(file: identifier))
  }

  private func threadModel(_ model: ThreadRunModel) -> ThreadModel {
    ThreadModel.with {
      switch model {
      case .local(let file):
        $0.modelID = file
        $0.name = LLMZoo.humanReadableNameForModel(file)
        $0.contextWindowTokens = UInt32(Self.inferenceContextWindow(forModel: file))
      case .cloud(let provider, let model):
        $0.provider = provider.rawValue
        $0.modelID = model
        $0.name = provider.modelDisplayName(model, in: workspace)
      }
    }
  }

  /// `model` when it can run here: downloaded, or on a cloud provider set up on the Mac.
  private func runModel(_ model: ThreadModel) -> ThreadRunModel? {
    guard !model.provider.isEmpty else {
      guard let specification = LLMZoo.specificationForModel(model.modelID),
        LLMZoo.isModelDownloaded(specification)
      else { return nil }
      return .local(file: model.modelID)
    }
    guard let provider = RemoteProvider(rawValue: model.provider), !model.modelID.isEmpty,
      provider.account(in: workspace) != nil
    else { return nil }
    return .cloud(provider, model: model.modelID)
  }

  /// What the Mac's composer runs on, which a new thread runs on unless a device picks another.
  private func composerRunModel() -> ThreadRunModel? {
    if case .some(.remote(let remoteChatProvider)) = codeAgentWrapper {
      let provider = remoteChatProvider.provider
      guard provider.account(in: workspace) != nil, let model = provider.model(in: workspace)
      else { return nil }
      return .cloud(provider, model: model)
    }
    guard let file = selectedLLM, let specification = LLMZoo.specificationForModel(file),
      LLMZoo.isModelDownloaded(specification)
    else { return nil }
    return .local(file: file)
  }

  /// Puts the Mac's composer on `model`, as picking it there does, so the thread open on the Mac
  /// runs on it; the status to answer with when it can't now.
  private func moveComposer(to model: ThreadRunModel) -> GRPCStatus? {
    guard model != composerRunModel() else { return nil }
    guard chatInputController.sendState == .idle else {
      return GRPCStatus(
        code: .failedPrecondition,
        message: "This Mac is answering in this thread. Change the model once it's done.")
    }
    switch model {
    case .local(let file):
      selectLocalModel(file: file)
    case .cloud(let provider, let model):
      selectCloudModel(model, provider: provider)
    }
    return nil
  }

  /// Whether the Mac would have to load `file` while its loaded model is still running something.
  func waitsForModel(_ file: String) -> Bool {
    guard let loaded = agentScheduler.file, loaded != file else { return false }
    return !agentScheduler.isIdle
  }

  func queue(of ref: ThreadRef) -> [QueuedMessage] {
    guard let project = threadsProject(forID: ref.projectID) else { return [] }
    return project.workspace.fetch(for: ProjectQueuedItem.self).where(
      ProjectQueuedItem.threadId == ref.threadID,
      orderBy: [ProjectQueuedItem.datetime.ascending]
    ).map { item in
      QueuedMessage.with {
        $0.datetimeMs = item.datetime
        $0.text = item.text ?? ""
      }
    }
  }

  func send(_ request: SendMessageRequest) -> Result<SendMessageResponse, GRPCStatus> {
    let ref: ThreadRef?
    let projectID: String
    switch request.to {
    case .thread(let thread)?:
      ref = thread
      projectID = thread.projectID
    case .projectID(let id)?:
      ref = nil
      projectID = id
    case nil:
      return .failure(GRPCStatus(code: .invalidArgument, message: "Send to a thread or a project."))
    }
    guard let project = threadsProject(forID: projectID) else {
      return .failure(GRPCStatus(code: .notFound, message: "That project is gone."))
    }
    let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !request.attachments.isEmpty else {
      return .failure(GRPCStatus(code: .invalidArgument, message: "The message is empty."))
    }
    if let ref {
      guard project.history.thread(id: ref.threadID) != nil else {
        return .failure(GRPCStatus(code: .notFound, message: "That thread is gone."))
      }
    }
    // The device's pick, which the thread moves to as on the Mac's composer; otherwise the thread's
    // own model, or the Mac's selection for a new thread.
    let model: ThreadRunModel
    if request.hasModel {
      guard let requested = runModel(request.model) else {
        return .failure(
          GRPCStatus(code: .notFound, message: "That model isn't available on this Mac."))
      }
      model = requested
    } else if let ref,
      let own = threadModel(identifier: project.history.thread(id: ref.threadID)?.model).flatMap(
        runModel)
    {
      model = own
    } else if let selected = composerRunModel() {
      model = selected
    } else {
      return .failure(
        GRPCStatus(code: .failedPrecondition, message: "This Mac has no model selected."))
    }
    var prompt = text
    var imagePaths = [String]()
    if !request.attachments.isEmpty {
      do {
        let paths = try Self.copyAttachments(request.attachments, into: project.url)
        prompt = ChatAttachment.emitSections(prompt, paths: paths)
        // Models also see attached images directly; other files stay links.
        imagePaths = paths.filter {
          UTType(filenameExtension: ($0 as NSString).pathExtension)?.conforms(to: .image) == true
        }
      } catch {
        return .failure(
          GRPCStatus(code: .internalError, message: "The Mac couldn't save the files."))
      }
    }
    if let ref, isOnScreen(ref) {
      if let status = moveComposer(to: model) { return .failure(status) }
      return sendOnScreen(prompt, imagePaths: imagePaths, steer: request.steer, to: ref)
    }
    switch model {
    case .local(let file):
      guard let ref else {
        return startThread(prompt, imagePaths: imagePaths, file: file, in: project)
      }
      return sendInBackground(
        prompt, imagePaths: imagePaths, steer: request.steer, to: ref, file: file, in: project)
    case .cloud(let provider, let model):
      return sendOnCloud(
        prompt, imagePaths: imagePaths, steer: request.steer, to: ref, provider: provider,
        model: model, in: project)
    }
  }

  func stopTurn(in ref: ThreadRef) -> GRPCStatus {
    // Its messages stay queued; nothing ran yet.
    threadsBackendState.waitingForModel[ref] = nil
    if isOnScreen(ref) {
      chatInputControllerDidTapStop(chatInputController)
    } else if let project = threadsProject(forID: ref.projectID) {
      if let codeAgent = agentScheduler.residentCodeAgent(
        projectPath: project.url.path, threadId: ref.threadID)
      {
        agentScheduler.stop(codeAgent)
      } else if let model = project.history.thread(id: ref.threadID)?.model,
        let remote = parseRemoteThreadModelIdentifier(model)
      {
        remoteChatProvider(for: remote.provider).cancel(
          ProjectThreadIdentifier(projectURL: project.url, threadId: ref.threadID))
      }
    }
    return .ok
  }

  func removeQueuedMessage(in ref: ThreadRef, datetime: Int64) -> GRPCStatus {
    guard let project = threadsProject(forID: ref.projectID) else {
      return GRPCStatus(code: .notFound, message: "That project is gone.")
    }
    let items = project.workspace.fetch(for: ProjectQueuedItem.self).where(
      ProjectQueuedItem.threadId == ref.threadID && ProjectQueuedItem.datetime == datetime)
    project.workspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      for item in items {
        guard let deletion = ProjectQueuedItemChangeRequest.deletionRequest(item) else { continue }
        transactionContext.try(submit: deletion)
      }
    }
    return .ok
  }

  /// Only a file the thread made: one attached to its messages, or one its write and edit tool
  /// calls wrote.
  func file(_ path: String, in ref: ThreadRef) -> Result<URL, GRPCStatus> {
    guard let project = threadsProject(forID: ref.projectID),
      let thread = project.history.thread(id: ref.threadID)
    else { return .failure(GRPCStatus(code: .notFound, message: "That thread is gone.")) }
    let safeTokenizer = Self.tokenizers(forModel: thread.model).0
    var madePaths = Set<String>()
    for node in project.history.history(threadId: ref.threadID) {
      var paths = [String]()
      switch node.role {
      case .user:
        let text = node.plaintext ?? safeTokenizer.decode(node.tokens)
        paths = node.imagePaths + ChatAttachment.parseSections(text).paths
      case .assistant:
        paths = node.toolCalls.compactMap { toolCall in
          guard
            toolCall.function == ToolsRegistry.Tool.write.rawValue
              || toolCall.function == ToolsRegistry.Tool.edit.rawValue
          else { return nil }
          return toolCall.parameters.first { $0.name == "path" }?.value
        }
      case .memory:
        break
      }
      madePaths.formUnion(paths.compactMap { ThreadFiles.normalized($0, in: project.url) })
    }
    guard let url = ThreadFiles.resolve(path, inProject: project.url, madePaths: madePaths) else {
      return .failure(
        GRPCStatus(code: .invalidArgument, message: "This thread didn't make that file."))
    }
    return .success(url)
  }

  func markRead(_ ref: ThreadRef) {
    guard let project = threadsProject(forID: ref.projectID),
      project.history.setThreadHasUnreadResponse(id: ref.threadID, hasUnreadResponse: false),
      let thread = project.history.thread(id: ref.threadID)
    else { return }
    settingsWorkflow.setInactiveProjectThread(thread, projectPath: project.url.path)
  }

  // MARK: - Sending

  /// The thread open on the Mac goes through its composer, so the Mac shows the turn as its own.
  private func sendOnScreen(_ prompt: String, imagePaths: [String], steer: Bool, to ref: ThreadRef)
    -> Result<SendMessageResponse, GRPCStatus>
  {
    let isBusy = chatInputController.sendState != .idle || hasIncompleteResponseToContinue()
    var prompt = prompt
    var imagePaths = imagePaths
    // The Mac moves a thread's unanswered message back into its composer, and its next send
    // replaces it. Devices still show that message as sent, so it goes with theirs, as a stopped
    // message goes with what was queued behind it.
    if !isBusy, let restoredUserNode, restoredUserNode.threadId == ref.threadID,
      let projectHistoryManager,
      let node = projectHistoryManager.history(threadId: ref.threadID).last(where: {
        $0.datetime == restoredUserNode.datetime
      })
    {
      let restored =
        node.plaintext
        ?? Self.tokenizers(forModel: projectHistoryManager.thread(id: ref.threadID)?.model).0
        .decode(node.tokens)
      if textHistoryManager.currentPositiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        == ChatAttachment.parseSections(restored).text.trimmingCharacters(
          in: .whitespacesAndNewlines)
      {
        setTextToEmpty()
      }
      prompt = restored + "\n\n" + prompt
      imagePaths = node.imagePaths + imagePaths
    }
    didTapSend(prompt, imagePaths: imagePaths) { [weak self] queuedItem in
      guard steer else { return }
      self?.steer(queuedItem, in: ref)
    }
    // Queued behind the running turn, or started.
    guard isBusy || chatInputController.sendState != .idle else {
      return .failure(GRPCStatus(code: .unavailable, message: "The Mac couldn't start the turn."))
    }
    return .success(SendMessageResponse.with { $0.thread = ref })
  }

  /// A thread not open on the Mac: queued behind what's running in it, or started on its own.
  private func sendInBackground(
    _ prompt: String, imagePaths: [String], steer: Bool, to ref: ThreadRef, file: String,
    in project: ThreadsProject
  ) -> Result<SendMessageResponse, GRPCStatus> {
    let waits = waitsForModel(file)
    if !waits { agentSchedulerActivation(for: file) }
    let resident =
      waits
      ? nil
      : agentScheduler.residentCodeAgent(projectPath: project.url.path, threadId: ref.threadID)
    if waits || isBusyInBackground(ref, resident: resident) {
      let lastDatetime =
        project.workspace.fetch(for: ProjectQueuedItem.self).where(
          ProjectQueuedItem.threadId == ref.threadID,
          orderBy: [ProjectQueuedItem.datetime.descending]
        ).first?.datetime ?? -1
      let queuedItem = ProjectQueuedItem(
        threadId: ref.threadID,
        datetime: max(Int64(Date().timeIntervalSince1970 * 1_000), lastDatetime + 1),
        text: prompt, imagePaths: imagePaths)
      project.workspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
        transactionContext.try(submit: ProjectQueuedItemChangeRequest.upsertRequest(queuedItem))
      } completionHandler: { [weak self] success in
        guard success else { return }
        DispatchQueue.main.async {
          self?.backgroundMessageWasQueued(queuedItem, in: ref, steer: steer, file: file)
        }
      }
      return .success(SendMessageResponse.with { $0.thread = ref })
    }
    guard
      let codeAgent = resident
        ?? backgroundCodeAgent(file: file, threadId: ref.threadID, in: project)
    else {
      return .failure(GRPCStatus(code: .unavailable, message: "The Mac couldn't load its model."))
    }
    let (_, userTokens, _, _, _) = Self.tokenizers(forModel: file).0.tokenize(
      text: prompt, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false)
    guard
      project.history.appendUser(
        threadId: ref.threadID, tokens: userTokens, textEdits: -1, textLineage: -1,
        imagePaths: imagePaths, lastMessage: prompt) != nil
    else {
      return .failure(
        GRPCStatus(code: .internalError, message: "The Mac couldn't save the message."))
    }
    startBackgroundTurn(
      codeAgent, prompt: prompt, imagePaths: imagePaths, ref: ref, file: file, in: project)
    return .success(SendMessageResponse.with { $0.thread = ref })
  }

  /// A new thread in the project, titled by its first line as on the Mac.
  private func startThread(
    _ prompt: String, imagePaths: [String], file: String, in project: ThreadsProject
  ) -> Result<SendMessageResponse, GRPCStatus> {
    // A thread waits in its queue for its model; a new one has no queue yet.
    guard !waitsForModel(file) else {
      return .failure(
        GRPCStatus(
          code: .unavailable,
          message: "This Mac is answering on another of its models. Send again once it's done."))
    }
    agentSchedulerActivation(for: file)
    // The agent first, with no history yet, so a model that can't load leaves no thread behind.
    guard let codeAgent = backgroundCodeAgent(file: file, threadId: -1, in: project) else {
      return .failure(GRPCStatus(code: .unavailable, message: "The Mac couldn't load its model."))
    }
    let (_, userTokens, _, _, _) = Self.tokenizers(forModel: file).0.tokenize(
      text: prompt, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false)
    let thread = project.history.createThread(
      title: Self.threadTitle(prompt), model: file, userTokens: userTokens, textEdits: -1,
      textLineage: -1, imagePaths: imagePaths, lastMessage: prompt)
    settingsWorkflow.addInactiveProjectThread(thread, projectPath: project.url.path)
    let ref = ThreadRef.with {
      $0.projectID = threadsProjectID(forPath: project.url.path)
      $0.threadID = thread.id
    }
    startBackgroundTurn(
      codeAgent, prompt: prompt, imagePaths: imagePaths, ref: ref, file: file, in: project)
    return .success(SendMessageResponse.with { $0.thread = ref })
  }

  /// A turn runs, or one ended and its completion, which sends the queue next, hasn't run yet.
  private func isBusyInBackground(_ ref: ThreadRef, resident: (any CodeAgent)?) -> Bool {
    guard threadsBackendState.runningTurns[ref] == nil else { return true }
    guard let resident else { return false }
    return agentScheduler.hasActiveTurn(resident)
      || activeMemoryReviews.contains(ObjectIdentifier(resident))
  }

  /// Once a background thread's message is saved in its queue: steers with it, or sends the queue
  /// on `file` when the turn it waited for ended meanwhile.
  private func backgroundMessageWasQueued(
    _ queuedItem: ProjectQueuedItem, in ref: ThreadRef, steer: Bool, file: String
  ) {
    // The open thread's queue observer sends it.
    guard !isOnScreen(ref) else {
      if steer { steerQueuedItem(queuedItem) }
      return
    }
    guard let project = threadsProject(forID: ref.projectID) else { return }
    let resident =
      agentScheduler.file == file
      ? agentScheduler.residentCodeAgent(projectPath: project.url.path, threadId: ref.threadID)
      : nil
    if isBusyInBackground(ref, resident: resident) {
      if steer { self.steer(queuedItem, in: ref) }
      return
    }
    sendQueue(of: ref, on: file, in: project)
  }

  /// Sends the thread's queue as its next turn on `file`, which the Mac loads if nothing runs on
  /// its loaded model; otherwise the thread waits for it.
  private func sendQueue(of ref: ThreadRef, on file: String, in project: ThreadsProject) {
    guard !waitsForModel(file) else {
      threadsBackendState.waitingForModel[ref] = file
      return
    }
    threadsBackendState.waitingForModel[ref] = nil
    agentSchedulerActivation(for: file)
    guard
      let codeAgent = agentScheduler.residentCodeAgent(
        projectPath: project.url.path, threadId: ref.threadID)
        ?? backgroundCodeAgent(file: file, threadId: ref.threadID, in: project)
    else { return }
    _ = continueBackgroundQueuedItems(
      codeAgent: codeAgent, safeTokenizer: Self.tokenizers(forModel: file).0,
      threadId: ref.threadID, projectURL: project.url, projectWorkspace: project.workspace,
      projectHistoryManager: project.history)
  }

  /// Once nothing runs on the Mac's loaded model, the threads waiting for another one get it.
  func startThreadsWaitingForModel() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let file = threadsBackendState.waitingForModel.values.first, agentScheduler.isIdle
    else { return }
    for (ref, waitingFile) in threadsBackendState.waitingForModel where waitingFile == file {
      guard let project = threadsProject(forID: ref.projectID) else {
        threadsBackendState.waitingForModel[ref] = nil
        continue
      }
      sendQueue(of: ref, on: file, in: project)
    }
  }

  // MARK: - Cloud models

  /// A message to a thread on a cloud provider set up on the Mac, outside the Mac's composer:
  /// queued behind the thread's running turn, or a turn started on `model`, which the thread moves
  /// to first as on the Mac's composer. A new thread when `ref` is nil.
  private func sendOnCloud(
    _ prompt: String, imagePaths: [String], steer: Bool, to ref: ThreadRef?,
    provider: RemoteProvider, model: String, in project: ThreadsProject
  ) -> Result<SendMessageResponse, GRPCStatus> {
    // The Mac's own first use of a cloud model asks to share project data with it.
    guard workspace.dictionary["remote_api_disclosure_acknowledged", Bool.self] == true else {
      return .failure(
        GRPCStatus(
          code: .failedPrecondition, message: "Use a cloud model on this Mac once first."))
    }
    guard let profile = provider.profile(in: workspace, model: model) else {
      return .failure(
        GRPCStatus(
          code: .failedPrecondition, message: "\(provider.title) isn't set up on this Mac."))
    }
    let remoteChatProvider = remoteChatProvider(for: provider)
    let threadModel = remoteThreadModelIdentifier(provider: provider, model: model)
    let threadRef: ThreadRef
    if let ref {
      let conversationID = ProjectThreadIdentifier(projectURL: project.url, threadId: ref.threadID)
      if remoteChatProvider.isActive(conversationID)
        || threadsBackendState.runningTurns[ref] != nil
      {
        let queuedItem = ProjectQueuedItem(
          threadId: ref.threadID,
          datetime: max(
            Int64(Date().timeIntervalSince1970 * 1_000),
            (queue(of: ref).last?.datetimeMs ?? -1) + 1),
          text: prompt, imagePaths: imagePaths)
        project.workspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
          transactionContext.try(submit: ProjectQueuedItemChangeRequest.upsertRequest(queuedItem))
        }
        // The stopped turn's completion sends the queue.
        if steer { remoteChatProvider.cancel(conversationID) }
        return .success(SendMessageResponse.with { $0.thread = ref })
      }
      guard moveThread(ref.threadID, toRemoteModel: threadModel, in: project.history),
        project.history.appendUser(
          threadId: ref.threadID, tokens: [], textEdits: -1, textLineage: -1, plaintext: prompt)
          != nil
      else {
        return .failure(
          GRPCStatus(code: .internalError, message: "The Mac couldn't save the message."))
      }
      threadRef = ref
    } else {
      let thread = project.history.createThread(
        title: Self.threadTitle(prompt), model: threadModel, userTokens: [], textEdits: -1,
        textLineage: -1, plaintext: prompt)
      settingsWorkflow.addInactiveProjectThread(thread, projectPath: project.url.path)
      threadRef = ThreadRef.with {
        $0.projectID = threadsProjectID(forPath: project.url.path)
        $0.threadID = thread.id
      }
    }
    startCloudTurn(
      prompt, imagePaths: imagePaths, ref: threadRef, profile: profile,
      remoteChatProvider: remoteChatProvider, threadModel: threadModel, in: project)
    return .success(SendMessageResponse.with { $0.thread = threadRef })
  }

  /// Runs a cloud model's turn for the thread's last message, reported to the devices watching,
  /// then sends what queued meanwhile.
  private func startCloudTurn(
    _ prompt: String, imagePaths: [String], ref: ThreadRef, profile: RemoteProviderProfile,
    remoteChatProvider: RemoteChatProvider, threadModel: String, in project: ThreadsProject
  ) {
    let conversationID = ProjectThreadIdentifier(projectURL: project.url, threadId: ref.threadID)
    let conversation = ProjectRemoteConversation.load(
      history: project.history.history(threadId: ref.threadID), model: threadModel)
    // An image that cannot be read stays a link in the prompt, which tools can still open.
    let accessed = project.url.startAccessingSecurityScopedResource()
    let images = imagePaths.compactMap {
      try? RemoteImage(attachmentContentsOf: project.url.appendingPathComponent($0))
    }
    if accessed { project.url.stopAccessingSecurityScopedResource() }
    let bashUserInteraction = BashUserInteraction()
    let startTime = CACurrentMediaTime()
    let threadsTurn = threadsTurnReporter(projectURL: project.url, threadId: ref.threadID)
    remoteChatProvider.bashToolContext = bashToolContext
    remoteChatProvider.prepare(
      conversationID, profile: profile, workspacePath: settingsWorkflow.workspaceFolderURL.path,
      webSearchProvider: configuredWebSearchProvider, state: conversation.state,
      forceHistoryCheckpoint: conversation.forceCheckpoint, forSending: true
    ) { [weak self] preparation in
      guard self != nil, case .success = preparation else {
        threadsTurn?.finish(.failed, error: "The Mac couldn't start the turn.")
        return
      }
      remoteChatProvider.send(
        prompt, images: images, in: conversationID, bashUserInteraction: bashUserInteraction,
        progress: { progress in threadsTurn?.report(progress) },
        completion: { [weak self] result, historyResult, wasCancelled in
          guard let self else { return }
          let (text, response, log) = Self.remoteAssistantMessage(result, history: historyResult)
          let duration =
            CACurrentMediaTime() - startTime
            - bashUserInteraction.userInteractionInterval(since: startTime)
          guard
            let node = project.history.appendAssistant(
              threadId: ref.threadID, logTokens: [], tokens: [], toolCalls: [], plaintext: text,
              logPlaintext: log?.plaintext, duration: duration, compacted: log?.compacted ?? false,
              lastMessage: response)
          else {
            threadsTurn?.finish(.failed, error: "The Mac couldn't save the answer.")
            return
          }
          threadsTurn?.finish(
            result: result, wasCancelled: wasCancelled, messageDatetime: node.datetime)
          if case .success = result, !wasCancelled {
            self.notifyThreadCompletion(
              projectURL: project.url, threadId: ref.threadID,
              projectHistoryManager: project.history, duration: duration)
          }
          self.sendCloudQueue(of: ref, in: project)
        })
    }
  }

  /// A cloud thread's queued messages go out together as its next turn, as a queue does on the Mac.
  private func sendCloudQueue(of ref: ThreadRef, in project: ThreadsProject) {
    let items = Array(
      project.workspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == ref.threadID,
        orderBy: [ProjectQueuedItem.datetime.ascending]))
    guard !items.isEmpty, let model = project.history.thread(id: ref.threadID)?.model,
      let remote = parseRemoteThreadModelIdentifier(model),
      case .success = sendOnCloud(
        items.compactMap(\.text).joined(separator: "\n\n"), imagePaths: items.flatMap(\.imagePaths),
        steer: false, to: ref, provider: remote.provider, model: remote.model, in: project)
    else { return }
    project.workspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      for item in items {
        guard let deletion = ProjectQueuedItemChangeRequest.deletionRequest(item) else { continue }
        transactionContext.try(submit: deletion)
      }
    }
  }

  /// Stops the thread's turn so the item goes out at once, with any others steered, as steering
  /// does on the Mac.
  private func steer(_ queuedItem: ProjectQueuedItem, in ref: ThreadRef) {
    guard !isOnScreen(ref) else {
      steerQueuedItem(queuedItem)
      return
    }
    guard let project = threadsProject(forID: ref.projectID),
      let resident = agentScheduler.residentCodeAgent(
        projectPath: project.url.path, threadId: ref.threadID)
    else { return }
    steeringQueuedItems[
      ProjectThreadIdentifier(projectURL: project.url, threadId: ref.threadID), default: []
    ].append(queuedItem)
    agentScheduler.stop(resident)
  }

  /// An agent for the thread on the Mac's model, which the thread moves to as on the Mac's
  /// composer, so another device's message continues it on the model that device shows.
  private func backgroundCodeAgent(file: String, threadId: Int64, in project: ThreadsProject)
    -> (any CodeAgent)?
  {
    guard threadId < 0 || moveThread(threadId, toLocalModel: file, in: project.history) else {
      return nil
    }
    let (prefixTokens, prefixEmbedSpans) = project.history.context(threadId: threadId)
    guard
      case .local(let textGenerator, let codeAgent?) = codeAgentWrapper(
        model: file, prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
        history: project.history.history(threadId: threadId), fromSuspension: false,
        project: (
          url: project.url, context: ProjectContext.load(projectURL: project.url),
          skillCatalog: skillCatalog(for: project.url)
        ))
    else { return nil }
    if agentScheduler.textGenerator == nil {
      agentScheduler.textGenerator = textGenerator
    }
    return codeAgent
  }

  private func startBackgroundTurn(
    _ codeAgent: any CodeAgent, prompt: String, imagePaths: [String], ref: ThreadRef,
    file: String, in project: ThreadsProject
  ) {
    scheduleLocalTurn(
      codeAgent: codeAgent, safeTokenizer: Self.tokenizers(forModel: file).0,
      prompt: skillCatalog(for: project.url).prompt(for: prompt), imagePaths: imagePaths,
      threadId: ref.threadID,
      projectURL: project.url, projectWorkspace: project.workspace,
      projectHistoryManager: project.history, startTime: CACurrentMediaTime())
  }

  /// The skills a project's agent sees: built in, the project's, and the workspace's.
  private func skillCatalog(for projectURL: URL) -> SkillCatalog {
    SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: Bundle.main.resourceURL?.appendingPathComponent(
          "Skills", isDirectory: true),
        projectURL: projectURL, workspaceURL: settingsWorkflow.workspaceFolderURL))
  }

  /// Saves another device's files in the project, as the composer copies dropped ones.
  private static func copyAttachments(_ attachments: [FileAttachment], into directory: URL) throws
    -> [String]
  {
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    let staged = try attachments.enumerated().map { index, attachment -> ChatAttachment in
      let name = (attachment.name as NSString).lastPathComponent
      // Each in its own folder, so two files with one name both arrive.
      let folder = staging.appendingPathComponent("\(index)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent(
        name.isEmpty || name == "." || name == ".." ? "attachment" : name)
      try attachment.data.write(to: url)
      return ChatAttachment(url: url, sourceURL: nil)
    }
    return try ChatAttachment.copy(staged, into: directory)
  }

  // MARK: - Watching

  /// Subscribes to the thread row and queue of every watched thread, and has their turns report
  /// progress off screen.
  private func watch(_ watched: Set<ThreadRef>) {
    dispatchPrecondition(condition: .onQueue(.main))
    let state = threadsBackendState
    for (ref, watch) in state.watches where !watched.contains(ref) {
      watch.subscriptions.forEach { $0.cancel() }
      state.watches[ref] = nil
    }
    var reporting = [(projectPath: String, threadId: Int64)]()
    for ref in watched {
      guard let project = threadsProject(forID: ref.projectID) else { continue }
      reporting.append((project.url.path, ref.threadID))
      if let watch = state.watches[ref], watch.workspace === project.workspace { continue }
      state.watches[ref]?.subscriptions.forEach { $0.cancel() }
      let canonicalPath = AgentScheduler.canonicalProjectPath(project.url.path)
      // Kept open while watched, whoever opened it.
      state.projects[canonicalPath] = project
      // Saved ones only: a node not saved yet goes out once its save changes the thread's row.
      let watch = ThreadWatch(
        projectPath: canonicalPath, projectURL: project.url, workspace: project.workspace,
        nodeDatetimes: project.workspace.fetch(for: ProjectHistoryNode.self).where(
          ProjectHistoryNode.threadId == ref.threadID,
          orderBy: [ProjectHistoryNode.datetime.ascending]
        ).map(\.datetime), model: project.history.thread(id: ref.threadID)?.model)
      let threadRows = project.workspace.fetch(for: ProjectThread.self).where(
        ProjectThread.id == ref.threadID)
      let queuedItems = project.workspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == ref.threadID)
      watch.subscriptions = [
        project.workspace.subscribe(fetchedResult: threadRows) { [weak self] threadRows in
          let isDeleted = threadRows.isEmpty
          let model = threadRows.first?.model
          DispatchQueue.main.async {
            self?.threadRowDidChange(ref, isDeleted: isDeleted, model: model)
          }
        },
        project.workspace.subscribe(fetchedResult: queuedItems) { [weak self] _ in
          DispatchQueue.main.async {
            guard let self, self.threadsBackendState.watches[ref] != nil else { return }
            self.deviceLink.threadsHub.queueDidChange(in: ref)
          }
        },
      ]
      state.watches[ref] = watch
    }
    closeUnwatchedProjects()
    agentScheduler.setBackgroundProgressThreads(reporting)
  }

  /// Every message saved updates the thread's row, so its new nodes go out from here. Nodes are
  /// only added, except that sending a draft the Mac restored replaces its user node with a new
  /// one; then the messages after the newest node still there replace the rest.
  private func threadRowDidChange(_ ref: ThreadRef, isDeleted: Bool, model: String?) {
    guard let watch = threadsBackendState.watches[ref] else { return }
    guard !isDeleted else {
      deviceLink.threadsHub.threadWasDeleted(ref)
      return
    }
    if model != watch.model {
      watch.model = model
      if let threadModel = threadModel(identifier: model) {
        deviceLink.threadsHub.thread(ref, didMoveTo: threadModel)
      }
    }
    let newest = watch.nodeDatetimes.last ?? 0
    let nodes = Array(
      watch.workspace.fetch(for: ProjectHistoryNode.self).where(
        ProjectHistoryNode.threadId == ref.threadID && ProjectHistoryNode.datetime >= newest,
        orderBy: [ProjectHistoryNode.datetime.ascending]))
    if watch.nodeDatetimes.isEmpty || nodes.first?.datetime == newest {
      let added = Array(nodes.drop { $0.datetime == newest })
      watch.nodeDatetimes += added.map(\.datetime)
      for message in historyMessages(added, model: model, projectPath: watch.projectURL.path) {
        deviceLink.threadsHub.thread(ref, didAppend: message)
      }
    } else {
      let nodes = Array(
        watch.workspace.fetch(for: ProjectHistoryNode.self).where(
          ProjectHistoryNode.threadId == ref.threadID,
          orderBy: [ProjectHistoryNode.datetime.ascending]))
      let kept = zip(watch.nodeDatetimes, nodes).prefix { $0.0 == $0.1.datetime }.count
      watch.nodeDatetimes = nodes.map(\.datetime)
      deviceLink.threadsHub.thread(
        ref, didReplaceMessagesAfter: kept > 0 ? nodes[kept - 1].datetime : 0,
        with: historyMessages(
          Array(nodes[kept...]), model: model, projectPath: watch.projectURL.path))
    }
  }

  // MARK: - Turns

  /// A retiring scheduler suspends its turns without completing them; they end as stopped, and
  /// their threads show as incomplete.
  func endRunningThreadsTurns() {
    dispatchPrecondition(condition: .onQueue(.main))
    let stopped = TurnEvent.OneOf_Event.finished(TurnFinished.with { $0.outcome = .stopped })
    for (ref, turnID) in threadsBackendState.runningTurns {
      deviceLink.threadsHub.turn(turnID, in: ref, emit: stopped)
    }
    threadsBackendState.runningTurns.removeAll()
  }

  /// Starts reporting one of the thread's turns to the hub, a cloud model's without `codeAgent`;
  /// nil where the device doesn't serve.
  func threadsTurnReporter(projectURL: URL, threadId: Int64, codeAgent: (any CodeAgent)? = nil)
    -> TurnReporter?
  {
    dispatchPrecondition(condition: .onQueue(.main))
    guard DeviceLinkService.canServe else { return nil }
    let ref = ThreadRef.with {
      $0.projectID = threadsProjectID(forPath: projectURL.path)
      $0.threadID = threadId
    }
    let turnID = UUID().uuidString
    let hub = deviceLink.threadsHub
    hub.turnDidStart(turnID, in: ref)
    threadsBackendState.runningTurns[ref] = turnID
    return TurnReporter(
      projectPath: projectURL.path, workspacePath: settingsWorkflow.workspaceFolderURL.path,
      toolCallStart: codeAgent?.toolCallStart ?? "", toolCallEnd: codeAgent?.toolCallEnd ?? "",
      emit: { event in
        DispatchQueue.main.async { hub.turn(turnID, in: ref, emit: event) }
      },
      finished: { [weak self] event in
        hub.turn(turnID, in: ref, emit: event)
        guard let self, self.threadsBackendState.runningTurns[ref] == turnID else { return }
        self.threadsBackendState.runningTurns[ref] = nil
      })
  }
}

extension ChatWorkflow: DeviceLinkServiceDelegate {
  func deviceLinkService(
    _ service: DeviceLinkService, didSeeWaitingDevice deviceID: String, named name: String
  ) {
    let alertController = UIAlertController(
      title: String(format: LocalizedString.forKey("device_link_allow_device_title"), name),
      message: LocalizedString.forKey("device_link_allow_device_detail"), preferredStyle: .alert)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("device_link_allow_device"), style: .default) {
        _ in service.allow(deviceID)
      })
    alertController.addAction(
      UIAlertAction(
        title: LocalizedString.forKey("device_link_deny_device"), style: .destructive
      ) { _ in service.disconnect(deviceID) })
    // Still waiting: Activities lists it with Allow.
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("not_now"), style: .cancel))
    presentedViewController.present(alertController, animated: true)
  }
}
