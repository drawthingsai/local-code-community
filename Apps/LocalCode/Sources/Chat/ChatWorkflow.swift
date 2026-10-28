import BashToolContext
import Components
import DataModels
import Dflat
import Downloader
import ImageGenerator
import LLM
import Localization
import ModelZoo
import NNC
import ProjectHistoryManager
import RemoteAPI
import SQLiteDflat
import Style
import TextHistory
import Tokenizer
import UIKit
import UniformTypeIdentifiers
import UserAccount
import UserNotifications
import WebSearch

final class ChatWorkflow: Workflow {
  enum CodeAgentWrapper {
    case remote(RemoteChatProvider)
    case local(any TextGenerator, (any CodeAgent)?)
  }

  private let queue: DispatchQueue
  // Accessed on the main queue; record warm-up and asks before enqueueing GPU work.
  private static var warmedUpModels = Set<String>()
  let graph: DynamicGraph
  let streamContext: StreamContext
  var agentScheduler: AgentScheduler
  private var retiringAgentSchedulers = [AgentScheduler]()
  private var modelIdleTimer: ModelIdleTimer?
  private var modelIdleTimeoutSubscription: Workspace.Subscription?
  private var sleepPreventionSubscription: Workspace.Subscription?
  private var sleepPrevention = SleepPrevention.default {
    didSet {
      guard sleepPrevention != oldValue else { return }
      // updateModelIdleState takes a new assertion at this level while agents are busy.
      sleepAssertion = nil
      downloadController?.sleepPrevention = sleepPrevention
      updateModelIdleState()
    }
  }
  private var sleepAssertion: SleepPrevention.Assertion?
  private var useAppleNeuralEngineSubscription: Workspace.Subscription?
  private var pendingModelWarmups = 0
  private let userInterfaceIdiom: UIUserInterfaceIdiom
  private let navigationController: UINavigationController
  let viewController: any ChatViewControllable
  let settingsWorkflow: SettingsWorkflow
  let threadNotifications = ThreadNotifications()
  let workspace: SQLiteWorkspace
  private let accountManager: AccountManager
  // The welcome walkthrough, for as long as the welcome thread is open.
  var onboardingWorkflow: OnboardingWorkflow?
  // The Model Speed page, for as long as it covers the chat.
  private var modelSpeedWorkflow: ModelSpeedWorkflow?
  let permittedDirectories: PermittedDirectories
  let projectBarController: ProjectBarController
  let chatInputController: ChatInputController
  private let emptyBannerController: EmptyBannerController
  private var chatBannerController: ChatBannerController?
  // Image generations and image model downloads show only in the chat that ran the command.
  // draw-things-cli runs one at a time, so each has at most one entry.
  private var cliMediaGenerationControllers =
    [ProjectThreadIdentifier: CLIMediaGenerationController]()
  // Each chat's browser keeps its tabs between shell commands until the user closes them from
  // the thread menu or deletes the chat or its project.
  var browserWorkflows = [ProjectThreadIdentifier: BrowserWorkflow]()
  /// Each project's cookies and other website data, shared by its threads' browsers.
  private let browserDataStores = BrowserDataStores()
  private var transientErrorMessages =
    [ProjectThreadIdentifier: ProjectHistoryItem.ActionableMessage]()
  {
    didSet {
      guard let projectURL, let threadId = projectHistoryManager?.threadId else { return }
      let conversationId = ProjectThreadIdentifier(
        projectURL: projectURL, threadId: threadId)
      guard transientErrorMessages[conversationId] !== oldValue[conversationId]
      else { return }
      viewController.setActionableMessage(
        transientErrorMessages[conversationId])
    }
  }
  private var stopMediaGenerationAlertController: UIAlertController?
  let textHistoryManager: TextHistoryManager
  var codeAgentWrapper: CodeAgentWrapper? {
    didSet {
      if let downloadController {
        if case .some(.local(let generator, _)) = codeAgentWrapper,
          downloadController.models.contains(where: {
            $0.file == URL(fileURLWithPath: generator.filePath).lastPathComponent
          })
        {
          // Keep downloading while the selected local model still needs this file.
        } else {
          downloadController.cancel()
        }
      }
      let wrapper = oldValue
      // Let the current main-queue stack unwind before transferring the final release.
      DispatchQueue.main.async { [queue] in
        queue.async {
          withExtendedLifetime(wrapper) {}
        }
      }
      updateModelIdleState()
    }
  }
  var remoteChatProviders = [String: RemoteChatProvider]()
  var skillCatalog = SkillCatalog.empty
  var projectContext = ProjectContext.empty
  private var projectWorkspace: SQLiteWorkspace?
  var projectHistoryManager: ProjectHistoryManager?
  var projectURL: URL?
  var restoredUserNode: (threadId: Int64, datetime: Int64)?
  private var isProjectSecurityScopedResourceAccessing = false
  private var reasoningEffortSubscription: Workspace.Subscription?
  private var botModeSubscription: Workspace.Subscription?
  private var reduceReasoningAnimationSubscription: Workspace.Subscription?
  private var workAttitudeSubscription: Workspace.Subscription?
  private var thinkingBudgetSubscription: Workspace.Subscription? = nil
  private var queuedItemSubscription: Workspace.Subscription?
  private var queuedItemsThreadId: Int64?
  private var activeMemoryReviews = Set<ObjectIdentifier>()
  private(set) var queuedItems = [ProjectQueuedItem]()
  /// Queued items to send on their own once each thread's running turn stops. They outlive a
  /// thread switch, so a steered thread continues in the background.
  private var steeringQueuedItems = [ProjectThreadIdentifier: [ProjectQueuedItem]]()
  var didStopHandler: (() -> Void)?
  var modelsDirectoryPickerResponder: ModelsDirectoryPickerResponder?
  var permitDirectoryPickerResponder: PermitDirectoryPickerResponder?
  var modelSelectWorkflow: ItemSelectWorkflow?
  private lazy var localModelSizeLoader: LocalModelSizeLoader = {
    let loader = LocalModelSizeLoader(workspace: workspace)
    loader.delegate = self
    return loader
  }()
  /// Project rows in the project popover are identified by their paths, thread rows by their
  /// ProjectController.Thread.
  private var projectSelectWorkflow: ItemSelectWorkflow?
  lazy var remoteModelMetadataClient = RemoteModelMetadataClient()
  var remoteModelCatalogRequest: RemoteRequestCancellable?
  private var downloadController: DownloadController<LLMZoo>?
  private var cliDownloadControllers = [ProjectThreadIdentifier: CLIDownloadController]()
  private var finishingDownloadController: EmbeddedDownloadController?
  private var downloadPreviewController: DownloadPreviewController?
  static let partialResultRenderInterval: CFTimeInterval = 1.0 / 25.0
  // Thinking lines kept for display (newlines, not wrapped lines). A restored run shows the last 40;
  // the live think cell drops them in chunks of 40 and shows the bottom 20 wrapped lines.
  static let chainOfThoughtLineLimit = 40
  var lastPartialResultRendered: CFTimeInterval = 0

  /// The live think cell's text: drop whole chunks of lines so the kept text only grows between
  /// drops, which is what the think cell animates.
  static func chainOfThoughtExcerpt(_ thinking: String) -> String {
    let chainOfThought = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
    let chainOfThoughtLines = chainOfThought.components(separatedBy: .newlines)
    let droppedLines =
      max(chainOfThoughtLines.count - chainOfThoughtLineLimit, 0)
      / chainOfThoughtLineLimit * chainOfThoughtLineLimit
    guard droppedLines > 0 else { return chainOfThought }
    // Reopen a code block the cut lands inside with its own fence, or the rest would parse inside
    // out. A block closes only on a bare backtick run at least as long as its opener.
    var openFence: String?
    for line in chainOfThoughtLines.prefix(droppedLines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let fence = trimmed.prefix { $0 == "`" }
      guard fence.count >= 3 else { continue }
      if let opening = openFence {
        if fence.count >= opening.count, fence.count == trimmed.count { openFence = nil }
      } else {
        openFence = String(fence)
      }
    }
    return
      (["..."] + (openFence.map { [$0] } ?? [])
      + chainOfThoughtLines.dropFirst(droppedLines)).joined(separator: "\n")
  }

  var viewControllable: UIViewController {
    navigationController
  }

  var presentedViewController: UIViewController {
    var viewController: UIViewController = viewController
    while let presentedViewController = viewController.presentedViewController {
      if presentedViewController.isBeingDismissed {
        break
      }
      viewController = presentedViewController
    }
    return viewController
  }

  var weightsStreaming: DeviceCapability.WeightsStreaming? {
    workspace.dictionary["weights_streaming", Int.self].flatMap(
      DeviceCapability.WeightsStreaming.init(rawValue:))
  }

  init(
    userInterfaceIdiom: UIUserInterfaceIdiom,
    workspace: SQLiteWorkspace,
    accountManager: AccountManager,
    accountClient: AccountClient?
  ) {
    let queue = DispatchQueue(
      label: "com.liuliu.local-code.generate", qos: .userInteractive)
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    self.queue = queue
    self.graph = graph
    streamContext = StreamContext(.GPU(0))
    agentScheduler = AgentScheduler(queue: queue)
    self.userInterfaceIdiom = userInterfaceIdiom
    self.workspace = workspace
    self.accountManager = accountManager
    let permittedDirectories = PermittedDirectories(workspace: workspace)
    self.permittedDirectories = permittedDirectories
    let initialLLM = workspace.dictionary["llm_model", String.self].flatMap { file in
      LLMZoo.specificationForModel(file).map { _ in file }
    }
    let weightsStreaming =
      workspace.dictionary["weights_streaming", Int.self].flatMap(
        DeviceCapability.WeightsStreaming.init(rawValue:))
    let settingsWorkflow = SettingsWorkflow(
      workspace: workspace, userInterfaceIdiom: userInterfaceIdiom, queue: queue,
      accountManager: accountManager, accountClient: accountClient,
      permittedDirectories: permittedDirectories)
    self.settingsWorkflow = settingsWorkflow
    let skillCatalog = SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: Bundle.main.resourceURL?.appendingPathComponent(
          "Skills", isDirectory: true),
        projectURL: nil, workspaceURL: settingsWorkflow.workspaceFolderURL))
    self.skillCatalog = skillCatalog
    let initialCodeAgentWrapper: CodeAgentWrapper?
    if let value = workspace.dictionary["chat_backend", String.self],
      let provider = RemoteProvider(rawValue: value)
    {
      initialCodeAgentWrapper = .remote(
        RemoteChatProvider(provider: provider, workspace: workspace))
    } else if userInterfaceIdiom != .phone, let initialLLM,
      let specification = LLMZoo.specificationForModel(initialLLM)
    {
      let chunkedPrefillMaxLength = DeviceCapability.chunkedPrefillMaxLength
      let textGenerator: any TextGenerator
      switch specification.version {
      case .qwen_3_5_4b:
        textGenerator = Qwen3_5TextGenerator(
          filePath: LLMZoo.filePathForModelDownloaded(initialLLM),
          configuration: .qwen3_5_4B, tieEmbedding: true,
          chunkedPrefillMaxLength: chunkedPrefillMaxLength)
      case .qwen_3_5_9b:
        textGenerator = Qwen3_5TextGenerator(
          filePath: LLMZoo.filePathForModelDownloaded(initialLLM),
          configuration: .qwen3_5_9B, tieEmbedding: false,
          chunkedPrefillMaxLength: chunkedPrefillMaxLength)
      case .qwen_3_5_27b:
        textGenerator = Qwen3_5TextGenerator(
          filePath: LLMZoo.filePathForModelDownloaded(initialLLM),
          configuration: .qwen3_5_27B, tieEmbedding: false,
          chunkedPrefillMaxLength: chunkedPrefillMaxLength)
      case .deepseek_4_1_flash:
        guard let engram = specification.engram else {
          preconditionFailure("DeepSeek 4.1 requires an Engram companion")
        }
        textGenerator = DeepSeek4_1TextGenerator(
          filePath: LLMZoo.filePathForModelDownloaded(initialLLM),
          engramFilePath: LLMZoo.filePathForModelDownloaded(engram),
          chunkedPrefillMaxLength: chunkedPrefillMaxLength, weightsStreaming: weightsStreaming)
      case .deepseek_4_flash:
        textGenerator = DeepSeek4TextGenerator(
          filePath: LLMZoo.filePathForModelDownloaded(initialLLM),
          chunkedPrefillMaxLength: chunkedPrefillMaxLength,
          weightsStreaming: weightsStreaming)
      }
      initialCodeAgentWrapper = .local(textGenerator, nil)
    } else {
      initialCodeAgentWrapper = nil
    }
    codeAgentWrapper = initialCodeAgentWrapper
    chatInputController = ChatInputController(
      workspace: workspace, userInterfaceIdiom: userInterfaceIdiom)
    let modelName: String?
    let modelImage: UIImage
    switch initialCodeAgentWrapper {
    case .some(.remote(let remoteChatProvider)):
      modelName = remoteChatProvider.title
      modelImage = Self.modelImage(for: remoteChatProvider.provider)
    case .some(.local):
      modelName = initialLLM.map { LLMZoo.humanReadableNameForModel($0) }
      modelImage = Self.modelImage(for: initialLLM)
    case nil:
      modelName = nil
      modelImage = Self.modelImage(for: nil)
    }
    projectBarController = ProjectBarController(userInterfaceIdiom: userInterfaceIdiom)
    emptyBannerController = EmptyBannerController()
    chatInputController.setModel(
      name: modelName ?? LocalizedString.forKey("unspecified"), image: modelImage)
    textHistoryManager = TextHistoryManager(project: workspace, initialPositiveText: "")
    let viewController: any ChatViewControllable
    if userInterfaceIdiom == .phone {
      viewController = ChatViewControllerForiPhone(
        chatInputController: chatInputController,
        projectBarController: projectBarController,
        emptyBannerController: emptyBannerController)
    } else {
      viewController = ChatViewControllerForiPad(
        chatInputController: chatInputController,
        projectBarController: projectBarController,
        emptyBannerController: emptyBannerController,
        settingsViewController: settingsWorkflow.viewControllable)
    }
    self.viewController = viewController
    navigationController = UINavigationController(rootViewController: viewController)
    viewController.delegate = self
    settingsWorkflow.delegate = self
    agentScheduler.delegate = self
    modelIdleTimer = ModelIdleTimer(interval: ModelIdleTimeout.default.interval) {
      [weak self] request in
      self?.unloadIdleModels(request: request)
    }
    modelIdleTimeoutSubscription = workspace.dictionary.subscribe(
      "model_idle_timeout", of: Int.self
    ) { [weak self] value in
      guard let self else { return }
      let rawValue: Int?
      switch value {
      case .deleted: rawValue = nil
      case .initial(let value): rawValue = value
      case .updated(let value): rawValue = value
      }
      self.modelIdleTimer?.interval =
        (rawValue.flatMap(ModelIdleTimeout.init(rawValue:)) ?? .default).interval
      self.updateModelIdleState()
    }
    sleepPreventionSubscription = workspace.dictionary.subscribe("prevent_sleep", of: Int.self) {
      [weak self] value in
      guard let self else { return }
      let rawValue: Int?
      switch value {
      case .deleted: rawValue = nil
      case .initial(let value): rawValue = value
      case .updated(let value): rawValue = value
      }
      self.sleepPrevention = rawValue.flatMap(SleepPrevention.init(rawValue:)) ?? .default
    }
    // Agents read this when they set DynamicGraph.flags for each generation.
    useAppleNeuralEngineSubscription = workspace.dictionary.subscribe(
      "use_mfa_apple_neural_engine_v2", of: Int.self
    ) { value in
      let rawValue: Int?
      switch value {
      case .deleted: rawValue = nil
      case .initial(let value): rawValue = value
      case .updated(let value): rawValue = value
      }
      DeviceCapability.appleNeuralEngineState.store(
        rawValue.flatMap(DeviceCapability.AppleNeuralEngineState.init(rawValue:))
          ?? (DeviceCapability.isMFAAppleNeuralEngineFaster ? .appleNeuralEngineAndGPU : .disabled),
        ordering: .releasing)
    }
    chatInputController.delegate = self
    projectBarController.delegate = self
    if case .some(.remote(let remoteChatProvider)) = initialCodeAgentWrapper {
      registerRemoteChatProvider(remoteChatProvider)
    }
    chatInputController.setText(textHistoryManager.currentPositiveText)
    updateTextHistoryPointers()
    navigationController.isNavigationBarHidden = true
    let projectBookmarkData = workspace.dictionary["project", Data.self]
    if let projectBookmarkData, let projectURL = resolveProjectURL(from: projectBookmarkData) {
      openProject(at: projectURL, threadId: nil)
    }
    if projectWorkspace == nil {
      workspace.dictionary["project", Data.self] = nil
      // A last project that no longer opens, as when its folder moved, leaves the workspace root
      // on a new thread rather than on the root's last thread.
      openProject(
        at: settingsWorkflow.workspaceFolderURL, threadId: projectBookmarkData == nil ? nil : -1)
    }
    // The walkthrough opens by itself only on a workspace that has never been used: it was not
    // completed before, the root project has no threads, and the workspace has no folders.
    if !(workspace.dictionary["onboarding_completed", Bool.self] ?? false) {
      let workspaceFolderURL = settingsWorkflow.workspaceFolderURL
      let isRootProjectOpen =
        projectURL?.standardizedFileURL.resolvingSymlinksInPath()
        == workspaceFolderURL.standardizedFileURL.resolvingSymlinksInPath()
      let folders =
        (try? FileManager.default.contentsOfDirectory(
          at: workspaceFolderURL, includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles])) ?? []
      let hasFolders = folders.contains {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      }
      if isRootProjectOpen, projectHistoryManager?.threads.isEmpty == true, !hasFolders {
        openWelcomeThread(animated: false)
      }
    }
    botModeSubscription = workspace.dictionary.subscribe("bot_mode", of: Bool.self) {
      [weak self] value in
      guard let self else { return }
      let isBotModeEnabled: Bool
      switch value {
      case .deleted:
        isBotModeEnabled = false
      case .initial(let value):
        isBotModeEnabled = value ?? false
      case .updated(let value):
        isBotModeEnabled = value
      }
      self.viewController.isBotModeEnabled = isBotModeEnabled
    }
    reduceReasoningAnimationSubscription = workspace.dictionary.subscribe(
      "reduce_reasoning_animation", of: Bool.self
    ) { [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.viewController.isReduceReasoningAnimationEnabled = false
      case .initial(let value):
        self.viewController.isReduceReasoningAnimationEnabled = value ?? false
      case .updated(let value):
        self.viewController.isReduceReasoningAnimationEnabled = value
      }
    }
    thinkingBudgetSubscription = workspace.dictionary.subscribe(
      "thinking_budget", of: Int.self
    ) { [weak self] value in
      guard let self = self else { return }
      switch value {
      case .deleted:
        self.thinkingBudgetChanged(nil)
      case .initial(let value):
        self.thinkingBudgetChanged(value)
      case .updated(let value):
        self.thinkingBudgetChanged(value)
      }
    }
    reasoningEffortSubscription = workspace.dictionary.subscribe(
      "reasoning_effort", of: ReasoningEffort.self
    ) { [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.reasoningEffortChanged(nil)
      case .initial(let value):
        self.reasoningEffortChanged(value)
      case .updated(let value):
        self.reasoningEffortChanged(value)
      }
    }
    workAttitudeSubscription = workspace.dictionary.subscribe(
      "work_attitude", of: WorkAttitude.self
    ) { [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.didWorkAttitudeChange(nil)
      case .initial(let value):
        self.didWorkAttitudeChange(value)
      case .updated(let value):
        self.didWorkAttitudeChange(value)
      }
    }
    if case .some(.local(_, let codeAgent)) = codeAgentWrapper, let codeAgent {
      let statistics = codeAgent.statistics
      settingsWorkflow.setPrefillTokensPerSecond(
        statistics.prefillTokensPerSecond,
        tokenGeneratedPerSecond: statistics.tokenGeneratedPerSecond)
    }
    setLocalContextUsed()
    configureDynamicGraph()
    // Delay the warmup call.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self = self else { return }
      self.warmupSelectedModel()
    }
  }

  deinit {
    agentScheduler.hibernateAll { _ in }
    stopProjectSecurityScopedResourceAccess()
  }

  func applicationWillTerminate() {
    for controller in cliMediaGenerationControllers.values { controller.cancel() }
    for controller in cliDownloadControllers.values { controller.cancel() }
    downloadController?.cancel()
    textHistoryManager.saveCursor()
    let hibernationGroup = DispatchGroup()
    for scheduler in [agentScheduler] + retiringAgentSchedulers {
      hibernationGroup.enter()
      scheduler.hibernateAll { _ in
        hibernationGroup.leave()
      }
    }
    hibernationGroup.wait()
    stopProjectSecurityScopedResourceAccess()
  }

  func sceneDidBecomeActive() {
    settingsWorkflow.refreshAccountBalance()
    // Calendar and Photos access can change in system Settings while Local Code is in the
    // background.
    settingsWorkflow.refreshProtectedResourcePermissions()
    openPendingNotificationThread()
    // A turn that finished while the app was inactive marked the open thread unread; it is on
    // screen again, so mark it read the way opening it does.
    if let projectURL, let projectHistoryManager, projectHistoryManager.threadId >= 0 {
      let projectPath = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
      if isViewingThread(projectPath: projectPath, threadId: projectHistoryManager.threadId) {
        projectHistoryManager.setThreadHasUnreadResponse(
          id: projectHistoryManager.threadId, hasUnreadResponse: false)
        threadNotifications.clear(
          projectPath: projectPath, threadId: projectHistoryManager.threadId)
      }
    }
  }

  func notificationPresentationOptions(for notification: UNNotification)
    -> UNNotificationPresentationOptions
  {
    let info = notification.request.content.userInfo
    guard let projectPath = info["project_path"] as? String,
      let threadString = info["thread_id"] as? String, let threadId = Int64(threadString),
      !isViewingThread(projectPath: projectPath, threadId: threadId)
    else { return [] }
    return [.banner, .list, .sound]
  }

  func handle(notificationResponse response: UNNotificationResponse) {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let identifier = response.notification.request.content.userInfo["completionIdentifier"]
        as? String,
      identifier != threadNotifications.pendingNotification?.identifier
    else { return }
    threadNotifications.pendingNotification = (response, identifier)
    openPendingNotificationThread()
  }

  func openPendingNotificationThread() {
    guard
      viewControllable.viewIfLoaded?.window?.windowScene?.activationState
        == .foregroundActive,
      let response = threadNotifications.pendingNotification?.response
    else { return }
    let info = response.notification.request.content.userInfo
    guard let projectPath = info["project_path"] as? String,
      let threadString = info["thread_id"] as? String, let threadId = Int64(threadString)
    else {
      threadNotifications.pendingNotification = nil
      return
    }
    let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    let workspaceURL = settingsWorkflow.workspaceFolderURL.standardizedFileURL
      .resolvingSymlinksInPath()
    // Open only existing projects in the current workspace, using its existing folder access.
    guard projectURL.pathComponents.starts(with: workspaceURL.pathComponents),
      FileManager.default.fileExists(
        atPath: projectURL.appendingPathComponent(".localc/metadata.sqlite3").path)
    else {
      threadNotifications.pendingNotification = nil
      return
    }
    let currentPath = self.projectURL?.standardizedFileURL.resolvingSymlinksInPath().path
    // Preserve the existing restriction on leaving a project with active remote conversations.
    // Retry the pending notification when those conversations complete.
    guard
      currentPath == projectURL.path
        || !remoteChatProviders.values.contains(where: {
          $0.hasActiveConversations(projectPath: currentPath)
        })
    else { return }
    openProject(at: projectURL, threadId: threadId)
    threadNotifications.pendingNotification = nil
    threadNotifications.clear(projectPath: projectPath, threadId: threadId)
  }

  func isViewingThread(projectPath: String, threadId: Int64) -> Bool {
    viewControllable.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
      && projectHistoryManager?.threadId == threadId
      && projectURL?.standardizedFileURL.resolvingSymlinksInPath().path == projectPath
  }

  func notifyThreadCompletion(
    projectURL: URL, threadId: Int64, projectHistoryManager: ProjectHistoryManager,
    duration: TimeInterval
  ) {
    let projectPath = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
    guard !isViewingThread(projectPath: projectPath, threadId: threadId),
      let thread = projectHistoryManager.thread(id: threadId)
    else { return }
    if projectHistoryManager.setThreadHasUnreadResponse(id: threadId, hasUnreadResponse: true) {
      if let thread = projectHistoryManager.thread(id: threadId) {
        settingsWorkflow.setInactiveProjectThread(thread, projectPath: projectPath)
      }
    }
    threadNotifications.notify(
      projectURL: projectURL, threadId: threadId, title: thread.title ?? "", duration: duration)
  }

  private func updateTextHistoryPointers() {
    chatInputController.maxTextHistoryPointer = textHistoryManager.maxEdits
    chatInputController.textHistoryPointer = textHistoryManager.currentEdits
  }

  private func thinkingBudgetChanged(_ value: Int?) {
    guard case .some(.local(_, let codeAgent)) = codeAgentWrapper, let codeAgent else { return }
    let thinkingBudget = value ?? 65_536
    codeAgent.thinkingBudget = Int32(min(max(thinkingBudget, 0), 128 * 1024))
  }

  private func reasoningEffortChanged(_ value: ReasoningEffort?) {
    guard case .some(.local(_, let codeAgent)) = codeAgentWrapper, let codeAgent else { return }
    let reasoningEffort = value ?? .high
    switch codeAgent {
    case let codeAgent as Qwen3_5CodeAgent:
      codeAgent.reasoningEffort = .init(reasoningEffort)
    case let codeAgent as DeepSeek4CodeAgent<DeepSeek4TextGenerator>:
      codeAgent.reasoningEffort = .init(reasoningEffort)
    case let codeAgent as DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>:
      codeAgent.reasoningEffort = .init(reasoningEffort)
    default:
      preconditionFailure("Unsupported code agent")
    }
  }

  private func didWorkAttitudeChange(_ value: WorkAttitude?) {
    guard case .some(.local(_, let codeAgent)) = codeAgentWrapper, let codeAgent else { return }
    codeAgent.deterministic = (value ?? .deterministic) == .deterministic
  }

  private func residentProjectWorkspace(projectPath: String) -> SQLiteWorkspace? {
    agentScheduler.residentProjectWorkspace(projectPath: projectPath)
  }

  private func claimRetiringProjectResources(projectPath: String) -> (
    projectWorkspace: SQLiteWorkspace?, hadSecurityScopedAccess: Bool
  ) {
    for scheduler in retiringAgentSchedulers {
      let resources = scheduler.relinquishProjectResources(projectPath: projectPath)
      if resources.projectWorkspace != nil {
        return resources
      }
    }
    return (nil, false)
  }

  private func agentSchedulerActivation(for file: String) {
    guard agentScheduler.file != file else { return }
    guard let specification = LLMZoo.specificationForModel(file) else { return }
    let estimatedKVCacheSize: UInt64
    switch specification.version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      estimatedKVCacheSize = Qwen3_5TextGenerator.estimatedKVCacheSize
    case .deepseek_4_flash:
      estimatedKVCacheSize = DeepSeek4TextGenerator.estimatedKVCacheSize
    case .deepseek_4_1_flash:
      estimatedKVCacheSize = DeepSeek4_1TextGenerator.estimatedKVCacheSize
    }
    if agentScheduler.file != nil {
      let retiringScheduler = agentScheduler
      retiringScheduler.setForeground(nil)
      if let projectURL, let projectWorkspace {
        let resources = retiringScheduler.relinquishProjectResources(
          projectPath: projectURL.path)
        if let residentProjectWorkspace = resources.projectWorkspace {
          precondition(residentProjectWorkspace === projectWorkspace)
        }
        if resources.hadSecurityScopedAccess {
          isProjectSecurityScopedResourceAccessing = true
        }
      }
      retiringAgentSchedulers.append(retiringScheduler)
      retiringScheduler.hibernateAll { [weak self, weak retiringScheduler] _ in
        DispatchQueue.main.async {
          guard let self, let retiringScheduler else { return }
          self.retiringAgentSchedulers.removeAll { $0 === retiringScheduler }
          self.updateModelIdleState()
        }
      }
      agentScheduler = AgentScheduler(queue: queue)
      agentScheduler.delegate = self
      settingsWorkflow.setActiveThreads([])
      // Hibernation suspends the retired turns rather than stopping them, so their steers lapse.
      steeringQueuedItems.removeAll()
      viewController.setSteeringQueuedItems([])
    }
    agentScheduler.set(
      filePath: LLMZoo.filePathForModelDownloaded(file),
      estimatedKVCacheSize: estimatedKVCacheSize)
  }

  private func updateQueuedItems(_ queuedItems: [ProjectQueuedItem], animated: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    self.queuedItems = queuedItems
    viewController.setQueuedItems(
      queuedItems, animated: animated)
    guard let projectURL, let queuedItemsThreadId else { return }
    // A steered item keeps its spinner until it leaves the queue.
    let threadIdentifier = ProjectThreadIdentifier(
      projectURL: projectURL, threadId: queuedItemsThreadId)
    steeringQueuedItems[threadIdentifier]?.removeAll { !queuedItems.contains($0) }
    viewController.setSteeringQueuedItems(steeringQueuedItems[threadIdentifier] ?? [])
  }

  func observeQueuedItems(threadId: Int64) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard queuedItemsThreadId != threadId else { return }
    queuedItemsThreadId = threadId
    queuedItemSubscription?.cancel()
    queuedItemSubscription = nil
    // Only the fetched queue may prune the thread's steered items, so a thread switched back to
    // keeps them.
    guard let projectWorkspace, threadId >= 0 else {
      updateQueuedItems([], animated: false)
      return
    }
    let queuedItems = projectWorkspace.fetch(for: ProjectQueuedItem.self).where(
      ProjectQueuedItem.threadId == threadId,
      orderBy: [ProjectQueuedItem.datetime.ascending])
    updateQueuedItems(Array(queuedItems), animated: false)
    queuedItemSubscription = projectWorkspace.subscribe(fetchedResult: queuedItems) {
      [weak self, weak projectWorkspace] queuedItems in
      DispatchQueue.main.async {
        guard let self, self.projectWorkspace === projectWorkspace,
          self.projectHistoryManager?.threadId == threadId
        else { return }
        let queuedItems = Array(queuedItems)
        self.updateQueuedItems(queuedItems, animated: true)
        if !queuedItems.isEmpty && self.chatInputController.sendState == .idle,
          self.projectHistoryManager?.thread(id: threadId)?.hasIncompleteResponse != true
        {
          self.continueWithQueuedItems()
        }
      }
    }
  }

  static func modelImage(for file: String?) -> UIImage {
    switch file.flatMap({ LLMZoo.specificationForModel($0) })?.version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      return #imageLiteral(resourceName: "qwen-20")
    case .deepseek_4_1_flash, .deepseek_4_flash:
      return #imageLiteral(resourceName: "deepseek-20")
    case nil:
      return #imageLiteral(resourceName: "cube").withRenderingMode(.alwaysTemplate)
    }
  }

  static func modelImage(for provider: RemoteProvider) -> UIImage {
    if provider == .localCode {
      return #imageLiteral(resourceName: "draw-things-app-icon").withRenderingMode(.alwaysOriginal)
    }
    return #imageLiteral(resourceName: "cloud-compute-24").withRenderingMode(.alwaysTemplate)
  }

  /// The local models a model selector lists, marking the ones still to download.
  static func localModelSection(selectedModel: String?, workspace: SQLiteWorkspace)
    -> ItemDisplaySectionModel
  {
    let viewModels: [ItemDisplayCollectionViewCellViewModel] =
      LLMZoo.builtinSpecifications.compactMap { specification in
        let isDownloaded = LLMZoo.isModelDownloaded(specification)
        guard
          specification.file == selectedModel
            || isDownloaded
            || !LLMZoo.isModelDeprecated(specification.file)
        else { return nil }
        let title = NSMutableAttributedString(string: specification.name)
        if !isDownloaded {
          title.append(NSAttributedString(string: " "))
          let configuration = UIImage.SymbolConfiguration(
            pointSize: 13, weight: .regular, scale: .default)
          let attachment = NSTextAttachment()
          attachment.image = UIImage(
            systemName: "icloud.and.arrow.down", withConfiguration: configuration
          )?.withTintColor(.selectorGrayColor)
          title.append(NSAttributedString(attachment: attachment))
        }
        let viewModel = ItemAcronymViewModel(
          itemIdentifier: .identifier(specification.file),
          title: ItemDisplayTitle.attributed(title),
          backgroundColor: .secondaryFill,
          detail: specification.note ?? "",
          caption: LocalModelSizeLoader.downloadSize(of: specification, in: workspace) ?? "",
          thumbnail: .image(Self.modelImage(for: specification.file)),
          isList: true)
        return ItemDisplayCollectionViewCellViewModel.itemAcronymViewModel(viewModel)
      }
    return ItemDisplaySectionModel(identifier: .noSection, items: viewModels)
  }

  func didTapModelSelector(
    sourceView: UIView, permittedArrowDirections: UIPopoverArrowDirection = [.up, .down]
  ) {
    remoteModelCatalogRequest?.cancel()
    remoteModelCatalogRequest = nil
    let selectedRemoteProvider: RemoteProvider?
    let itemSectionModels: [ItemDisplaySectionModel]
    if case .some(.remote(let remoteChatProvider)) = codeAgentWrapper {
      let provider = remoteChatProvider.provider
      selectedRemoteProvider = provider
      itemSectionModels = [
        remoteModelSection(provider: provider, models: provider.cachedModels(in: workspace))
      ]
    } else {
      selectedRemoteProvider = nil
      itemSectionModels = [Self.localModelSection(selectedModel: selectedLLM, workspace: workspace)]
      // Rows show sizes known so far and fill in the rest as the lookups finish.
      localModelSizeLoader.load(
        itemSectionModels.flatMap(\.items).compactMap {
          guard case .identifier(let file as String) = $0.itemIdentifier else { return nil }
          return LLMZoo.specificationForModel(file)
        })
    }
    let modelSelectWorkflow = ItemSelectWorkflow(
      userInterfaceIdiom: sourceView.traitCollection.userInterfaceIdiom, cellHeight: 32,
      minimumLineSpacing: 4, workspace: workspace, isSwitchDisplayed: false,
      isDetailSwitchDisplayed: true)
    self.modelSelectWorkflow = modelSelectWorkflow
    modelSelectWorkflow.delegate = self
    modelSelectWorkflow.updateTitle(title: LocalizedString.forKey("model"))
    modelSelectWorkflow.showsDetails =
      workspace.dictionary["model_selector_shows_details", Bool.self] ?? true
    modelSelectWorkflow.setViewModels(itemSectionModels, flag: nil)
    if let popoverPresentationController = modelSelectWorkflow.viewControllable
      .popoverPresentationController
    {
      popoverPresentationController.sourceView = sourceView
      popoverPresentationController.sourceRect = sourceView.bounds
      popoverPresentationController.permittedArrowDirections = permittedArrowDirections
      popoverPresentationController.popoverLayoutMargins = UIEdgeInsets(
        top: 0, left: 12, bottom: 0, right: 12)
    }
    presentedViewController.present(modelSelectWorkflow.viewControllable, animated: true)
    DispatchQueue.main.async {
      if let identifier = self.remoteChatProviderIdentifier {
        modelSelectWorkflow.selectItem(at: .identifier(identifier))
      } else if let selectedLLM = self.selectedLLM {
        modelSelectWorkflow.selectItem(at: .identifier(selectedLLM))
      }
    }
    if let selectedRemoteProvider {
      populateRemoteModels(
        provider: selectedRemoteProvider, modelSelectWorkflow: modelSelectWorkflow)
    }
  }

  /// Whether a turn, warmup, or download is reading or writing the model's files.
  private func isLocalModelInUse(_ specification: LLMZoo.Specification) -> Bool {
    return pendingModelWarmups > 0
      || ([agentScheduler] + retiringAgentSchedulers).contains {
        $0.file == specification.file && !$0.isIdle
      }
      || downloadController?.models.contains(where: {
        $0.file == specification.file || $0.file == specification.engram
      }) == true
  }

  private func confirmRemovingDownload(
    of specification: LLMZoo.Specification, fileURLs: [URL], workflow: ItemSelectWorkflow
  ) {
    // A checkpoint can keep its tensor data in an external store beside it.
    let removingURLs = fileURLs.flatMap {
      [$0, URL(fileURLWithPath: TensorData.externalStore(filePath: $0.path))]
    }.filter { FileManager.default.fileExists(atPath: $0.path) }
    let fileSize = removingURLs.reduce(0) {
      $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
    let alertController = UIAlertController(
      title: LocalizedString.forKey("remove_download"),
      message: String(
        format: LocalizedString.forKey("remove_download_detail"), specification.name,
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)),
      preferredStyle: .alert)
    let removeAction = UIAlertAction(
      title: LocalizedString.forKey("remove"), style: .destructive
    ) { [weak self] _ in
      // A turn can start on the model while the alert is up. Its row then still shows the model
      // as downloaded.
      guard let self, !self.isLocalModelInUse(specification) else { return }
      // Warm the model up again once it is downloaded again.
      Self.warmedUpModels.remove(LLMZoo.filePathForModelDownloaded(specification.file))
      // Remove the files first, so a turn started before the unload below runs downloads the
      // model again rather than loading files about to go.
      for url in removingURLs {
        try? FileManager.default.removeItem(at: url)
      }
      // Loaded weights and the Engram file handle keep the files' space in use until unloaded.
      let schedulers = ([self.agentScheduler] + self.retiringAgentSchedulers).filter {
        $0.file == specification.file
      }
      var generators = schedulers.compactMap(\.textGenerator)
      var codeAgent: (any CodeAgent)? = nil
      if case .some(.local(let generator, let agent)) = self.codeAgentWrapper,
        URL(fileURLWithPath: generator.filePath).lastPathComponent == specification.file
      {
        generators.append(generator)
        codeAgent = agent
      }
      self.queue.async { [graph = self.graph, streamContext = self.streamContext] in
        autoreleasepool {
          streamContext.joined()
          for scheduler in schedulers { scheduler.unloadIdleCaches() }
          codeAgent?.unloadCaches()
          for generator in generators { generator.unload() }
          graph.garbageCollect()
        }
      }
      guard self.modelSelectWorkflow === workflow else { return }
      workflow.setViewModels(
        [Self.localModelSection(selectedModel: self.selectedLLM, workspace: self.workspace)],
        flag: nil)
    }
    alertController.addAction(removeAction)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    workflow.viewControllable.present(alertController, animated: true)
  }

  func textGenerator(for model: String) -> (any TextGenerator)? {
    dispatchPrecondition(condition: .onQueue(.main))
    // Retiring schedulers can still own loaded storage until hibernation completes.
    var generators = ([agentScheduler] + retiringAgentSchedulers).compactMap(\.textGenerator)
    if case .some(.local(let textGenerator, _)) = codeAgentWrapper {
      generators.append(textGenerator)
    }
    guard let specification = LLMZoo.specificationForModel(model) else { return nil }
    let filePath = LLMZoo.filePathForModelDownloaded(model)
    let modelURL = URL(fileURLWithPath: filePath).standardizedFileURL.resolvingSymlinksInPath()
    if let generator = generators.first(where: {
      URL(fileURLWithPath: $0.filePath).standardizedFileURL.resolvingSymlinksInPath() == modelURL
    }) {
      return generator
    }
    let chunkedPrefillMaxLength = DeviceCapability.chunkedPrefillMaxLength
    switch specification.version {
    case .qwen_3_5_4b:
      return Qwen3_5TextGenerator(
        filePath: filePath, configuration: .qwen3_5_4B, tieEmbedding: true,
        chunkedPrefillMaxLength: chunkedPrefillMaxLength)
    case .qwen_3_5_9b:
      return Qwen3_5TextGenerator(
        filePath: filePath, configuration: .qwen3_5_9B, tieEmbedding: false,
        chunkedPrefillMaxLength: chunkedPrefillMaxLength)
    case .qwen_3_5_27b:
      return Qwen3_5TextGenerator(
        filePath: filePath, configuration: .qwen3_5_27B, tieEmbedding: false,
        chunkedPrefillMaxLength: chunkedPrefillMaxLength)
    case .deepseek_4_1_flash:
      guard let engram = specification.engram else { return nil }
      return DeepSeek4_1TextGenerator(
        filePath: filePath, engramFilePath: LLMZoo.filePathForModelDownloaded(engram),
        chunkedPrefillMaxLength: chunkedPrefillMaxLength, weightsStreaming: weightsStreaming)
    case .deepseek_4_flash:
      return DeepSeek4TextGenerator(
        filePath: filePath, chunkedPrefillMaxLength: chunkedPrefillMaxLength,
        weightsStreaming: weightsStreaming)
    }
  }

  var selectedLLM: String? {
    get {
      guard let file = workspace.dictionary["llm_model", String.self],
        LLMZoo.specificationForModel(file) != nil
      else { return nil }
      return file
    }
    set {
      let oldValue = selectedLLM
      guard let newValue, LLMZoo.specificationForModel(newValue) != nil else { return }
      workspace.dictionary["llm_model", String.self] = newValue
      switch codeAgentWrapper {
      case .some(.remote):
        break
      case .some(.local):
        chatInputController.setModel(
          name: LLMZoo.humanReadableNameForModel(newValue), image: Self.modelImage(for: newValue))
        guard oldValue != newValue else { return }
      case nil:
        chatInputController.setModel(
          name: LLMZoo.humanReadableNameForModel(newValue), image: Self.modelImage(for: newValue))
      }
      guard let textGenerator = textGenerator(for: newValue) else { return }
      codeAgentWrapper = .local(textGenerator, nil)
      settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
      setLocalContextUsed()
    }
  }

  private func setLocalContextUsed() {
    guard case .some(.local(let textGenerator, let existingCodeAgent)) = codeAgentWrapper else {
      return
    }
    let codeAgent: any CodeAgent
    if let existingCodeAgent {
      codeAgent = existingCodeAgent
    } else {
      let file = URL(fileURLWithPath: textGenerator.filePath).lastPathComponent
      var prefixTokens = [Int32]()
      var prefixEmbedSpans = [EmbedSpan]()
      if let projectHistoryManager,
        let thread = projectHistoryManager.thread(id: projectHistoryManager.threadId)
      {
        if let sourceModel = thread.model, sourceModel != file {
          let history = projectHistoryManager.history(threadId: thread.id)
          guard
            let convertedHistory = convertedHistoryForLocalModel(
              history, sourceModel: sourceModel, targetModel: file)
          else {
            settingsWorkflow.setContextUsed(0, contextWindowTokens: 0)
            return
          }
          (prefixTokens, prefixEmbedSpans) = ProjectHistoryManager.context(
            history: convertedHistory)
        } else {
          (prefixTokens, prefixEmbedSpans) = projectHistoryManager.context(threadId: thread.id)
        }
      }
      // Tokenize the same system prompt as generation without activating the scheduler or
      // loading weights. Keep the agent deferred until the user sends a message.
      guard
        case .some(.local(_, let contextCodeAgent)) = codeAgentWrapper(
          model: file, prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
          history: projectHistoryManager.map { $0.history(threadId: $0.threadId) } ?? [],
          fromSuspension: false),
        let contextCodeAgent
      else { return }
      codeAgent = contextCodeAgent
    }
    let statistics = codeAgent.statistics
    settingsWorkflow.setContextUsed(
      statistics.contextUsedTokens, contextWindowTokens: statistics.contextWindowTokens)
  }

  private func selectLocalModel(file: String) {
    guard chatInputController.sendState == .idle else { return }
    guard let specification = LLMZoo.specificationForModel(file) else { return }
    selectedLLM = file
    workspace.dictionary["chat_backend", String.self] = nil
    chatInputController.setModel(
      name: LLMZoo.humanReadableNameForModel(file), image: Self.modelImage(for: file))
    if !LLMZoo.isModelDownloaded(specification) {
      downloadLLMModel(specification) { [weak self] success in
        guard let self, success, self.selectedLLM == file else { return }
        self.warmupSelectedModel()
      }
    } else {
      warmupSelectedModel()
    }
  }

  private func warmupSelectedModel() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard
      workspace.dictionary["prefill_warmup", Bool.self]
        ?? DeviceCapability.isPrefillWarmupPreferred,
      case .local(let generator, _) = codeAgentWrapper,
      FileManager.default.fileExists(atPath: generator.filePath),
      Self.warmedUpModels.insert(generator.filePath).inserted
    else { return }
    let graph = graph
    let streamContext = streamContext
    pendingModelWarmups += 1
    updateModelIdleState()
    queue.async { [weak self] in
      autoreleasepool {
        switch generator {
        case let generator as Qwen3_5TextGenerator:
          Qwen3_5CodeAgent.warmupPrefill(generator, graph: graph, streamContext: streamContext)
        case let generator as DeepSeek4TextGenerator:
          DeepSeek4CodeAgent<DeepSeek4TextGenerator>.warmupPrefill(
            generator, graph: graph, streamContext: streamContext)
        default:
          break
        }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pendingModelWarmups -= 1
        self.updateModelIdleState()
      }
    }
  }

  private func updateModelIdleState() {
    dispatchPrecondition(condition: .onQueue(.main))
    let isAgentIdle = ([agentScheduler] + retiringAgentSchedulers).allSatisfy(\.isIdle)
    modelIdleTimer?.setIdle(pendingModelWarmups == 0 && isAgentIdle)
    // Only turns keep the device awake. Background jobs such as dev servers can run indefinitely.
    if isAgentIdle {
      sleepAssertion = nil
    } else if sleepAssertion == nil {
      sleepAssertion = sleepPrevention.assertion(reason: "Agent task in progress")
    }
  }

  private func unloadIdleModels(request: ModelIdleTimer.UnloadRequest) {
    dispatchPrecondition(condition: .onQueue(.main))
    let schedulers = [agentScheduler] + retiringAgentSchedulers
    // Scheduler notifications are asynchronous. Recheck actual state at the deadline so a newly
    // submitted turn cannot be mistaken for idle while its notification is still pending.
    guard pendingModelWarmups == 0, schedulers.allSatisfy(\.isIdle) else {
      updateModelIdleState()
      return
    }
    let generators = schedulers.compactMap(\.textGenerator)
    let wrapper = codeAgentWrapper
    queue.async { [weak self, graph, streamContext] in
      guard request.begin() else { return }
      guard schedulers.allSatisfy(\.isIdle) else {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.modelIdleTimer?.setIdle(false)
          self.updateModelIdleState()
        }
        return
      }
      autoreleasepool {
        streamContext.joined()
        for scheduler in schedulers { scheduler.unloadIdleCaches() }
        // Warmup and a restored foreground conversation may not belong to a scheduler yet.
        if case .local(let generator, let agent) = wrapper {
          agent?.unloadCaches()
          generator.unload()
        }
        for generator in generators { generator.unload() }
        graph.garbageCollect()
      }
    }
  }

  private func downloadLLMModel(
    _ specification: LLMZoo.Specification, completionHandler: @escaping (Bool) -> Void
  ) {
    if let downloadController,
      downloadController.models.contains(where: {
        $0.file == specification.file || $0.file == specification.engram
      })
    {
      downloadController.addCompletionHandler(completionHandler)
      return
    }
    downloadController?.cancel()
    let embeddedDownloadController = EmbeddedDownloadController(
      viewModel: DownloadItemController.ViewModel(
        image: #imageLiteral(resourceName: "keyboard-money"), title: "", subtitle: "", file: "",
        index: 0, totalDownloads: 0, downloadedBytes: 0, totalBytes: 0, mode: .download))
    let downloadController = DownloadController<LLMZoo>(
      models: ([specification.file] + [specification.engram].compactMap { $0 }).map { file in
        EmbeddedDownloadController.DownloadItem(
          name: specification.name,
          subtitle: LLMZoo.subtitleForModel(specification.file),
          file: file,
          sha256: LLMZoo.fileSHA256ForModelDownloaded(file),
          huggingFaceLink: specification.huggingFaceLink
        )
      },
      embeddedDownloadController: embeddedDownloadController,
      backend: ResumableDownloader.backend(from: workspace),
      sleepPrevention: sleepPrevention
    ) { [weak self, weak embeddedDownloadController] success in
      if let self {
        self.downloadController = nil
        if let embeddedDownloadController {
          self.finishingDownloadController = embeddedDownloadController
          embeddedDownloadController.finish(success: success) {
            [weak self, weak embeddedDownloadController] in
            guard let self, self.finishingDownloadController === embeddedDownloadController else {
              return
            }
            self.finishingDownloadController = nil
            self.updateChatBanner()
          }
        }
        self.updateChatBanner()
      }
      completionHandler(success)
    }
    self.downloadController = downloadController
    downloadController.start()
    guard self.downloadController === downloadController else { return }
    updateChatBanner()
  }

  func handleModelDownloadEvent(_ event: ModelDownloadEvent, projectURL: URL, threadId: Int64) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let identifier = ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)
      switch event {
      case .started(let id, let name, let subtitle, let files, let cancel):
        self.cliDownloadControllers[identifier] = CLIDownloadController(
          id: id, name: name, subtitle: subtitle, files: files, cancel: cancel)
        self.updateChatBanner()
      case .progress(let id, let file, let index, let written, let expected):
        guard let controller = self.cliDownloadControllers[identifier], controller.id == id
        else { return }
        controller.update(file: file, index: index, written: written, expected: expected)
      case .finished(let id):
        guard self.cliDownloadControllers[identifier]?.id == id else { return }
        self.cliDownloadControllers[identifier] = nil
        self.updateChatBanner()
      }
    }
  }

  func handleImageGenerationEvent(_ event: ImageGenerationEvent, projectURL: URL, threadId: Int64) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let identifier = ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)
      switch event {
      case .started(let id, let name, let version, let prompt, let signposts, let cancel):
        self.transientErrorMessages[identifier] = nil
        self.cliMediaGenerationControllers[identifier]?.finish()
        let controller = CLIMediaGenerationController(
          id: id, name: name, version: version, prompt: prompt, signposts: signposts, cancel: cancel
        )
        self.cliMediaGenerationControllers[identifier] = controller
        controller.imagePreviewController.didTapClose = { [weak self, weak controller] in
          guard let self, let controller,
            self.cliMediaGenerationControllers[identifier] === controller,
            self.presentedViewController.presentedViewController == nil
          else { return }
          let alertController = UIAlertController(
            title: LocalizedString.forKey("stop_generation_question"),
            message: LocalizedString.forKey("stop_generation_confirmation"), preferredStyle: .alert)
          alertController.addAction(
            UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel) {
              [weak self] _ in
              self?.stopMediaGenerationAlertController = nil
            })
          alertController.addAction(
            UIAlertAction(title: LocalizedString.forKey("stop_generation"), style: .destructive) {
              [weak self, weak controller] _ in
              guard let self, let controller,
                self.cliMediaGenerationControllers[identifier] === controller
              else {
                return
              }
              self.stopMediaGenerationAlertController = nil
              controller.cancel()
            })
          self.stopMediaGenerationAlertController = alertController
          self.presentedViewController.present(alertController, animated: true)
        }
        self.updateChatBanner()
      case .progress(let id, let signpost, let signposts, let preview):
        guard let controller = self.cliMediaGenerationControllers[identifier], controller.id == id
        else {
          return
        }
        controller.update(signpost: signpost, signposts: signposts, preview: preview)
      case .segmentStarted(let id):
        guard let controller = self.cliMediaGenerationControllers[identifier], controller.id == id
        else {
          return
        }
        controller.beginSegment()
      case .finished(let id, let failure):
        if case .insufficientBalance = failure {
          self.showTopUpAction(
            title: LocalizedString.forKey("insufficient_balance"),
            subtitle: LocalizedString.forKey("insufficient_balance_description"),
            conversation: identifier)
        }
        guard let controller = self.cliMediaGenerationControllers[identifier], controller.id == id
        else {
          return
        }
        self.stopMediaGenerationAlertController?.dismiss(animated: true)
        self.stopMediaGenerationAlertController = nil
        controller.finish()
        self.cliMediaGenerationControllers[identifier] = nil
        self.updateChatBanner()
      }
    }
  }

  func showTopUpAction(
    title: String, subtitle: String, conversation: ProjectThreadIdentifier
  ) {
    let actionMessage = ProjectHistoryItem.ActionableMessage(
      title: title, subtitle: subtitle, ctaText: LocalizedString.forKey("add_funds"),
      messageType: .warning)
    transientErrorMessages[conversation] = actionMessage
    actionMessage.ctaHandler = { [weak self, weak actionMessage] in
      guard let self, let actionMessage,
        self.transientErrorMessages[conversation] === actionMessage,
        let projectURL = self.projectURL, let threadId = self.projectHistoryManager?.threadId,
        ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)
          == conversation
      else { return }
      self.settingsWorkflow.presentAccountTopUp(from: self.presentedViewController) {
        [weak self, weak actionMessage] result in
        guard let self, let actionMessage,
          self.transientErrorMessages[conversation] === actionMessage
        else { return }
        if result.didPurchase {
          let successMessage = ProjectHistoryItem.ActionableMessage(
            title: LocalizedString.forKey("account_balance_topped_up"),
            subtitle: LocalizedString.forKey("ready_to_continue"),
            messageType: .success)
          self.transientErrorMessages[conversation] = successMessage
          DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            [weak self, weak successMessage] in
            guard let self, let successMessage,
              self.transientErrorMessages[conversation] === successMessage
            else { return }
            self.transientErrorMessages[conversation] = nil
            if result.continueGeneration,
              let projectURL = self.projectURL, let threadId = self.projectHistoryManager?.threadId,
              ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)
                == conversation
            {
              self.didTapSend("I've topped up. Retry it now.")
            }
          }
        } else if result.continueGeneration,
          let projectURL = self.projectURL, let threadId = self.projectHistoryManager?.threadId,
          ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)
            == conversation
        {
          self.didTapSend("I've topped up. Retry it now.")
        }
      }
    }
  }

  private func updateChatBanner() {
    let identifier = projectURL.flatMap { projectURL in
      projectHistoryManager.map {
        ProjectThreadIdentifier(projectURL: projectURL, threadId: $0.threadId)
      }
    }
    let nextController =
      identifier.flatMap { cliMediaGenerationControllers[$0] }?.imagePreviewController
      .bannerController
      ?? downloadController?.embeddedDownloadController.bannerController
      ?? identifier.flatMap { cliDownloadControllers[$0] }?.embeddedDownloadController
      .bannerController
      ?? downloadPreviewController?.embeddedDownloadController.bannerController
      ?? finishingDownloadController?.bannerController
    guard let nextController else {
      guard let chatBannerController else { return }
      chatBannerController.setVisible(false, animated: true) { [weak self] in
        guard let self, self.chatBannerController === chatBannerController else { return }
        self.viewController.removeChatBannerView(chatBannerController.view)
        self.chatBannerController = nil
      }
      return
    }
    if chatBannerController !== nextController {
      chatBannerController?.setVisible(false, animated: false)
      chatBannerController = nextController
      viewController.insertChatBannerView(nextController.view)
      viewController.view.layoutIfNeeded()
    }
    nextController.setVisible(true, animated: true)
  }

  /// Also callable from a debugger to replay a fixture without relaunching.
  func previewDownload(_ scenario: DownloadPreviewController.Scenario = .normal) {
    let preview = DownloadPreviewController(scenario: scenario)
    downloadPreviewController = preview
    preview.didClose = { [weak self, weak preview] in
      guard let self, self.downloadPreviewController === preview else { return }
      self.downloadPreviewController = nil
      self.updateChatBanner()
    }
    updateChatBanner()
  }

  private func stopProjectSecurityScopedResourceAccess(refreshVisibleCells: Bool = true) {
    viewController.setActionableMessage(nil)
    unloadRemoteConversations()
    settingsWorkflow.setProjectHistoryManager(nil, project: nil, projectURL: nil)
    queuedItemSubscription?.cancel()
    queuedItemSubscription = nil
    queuedItemsThreadId = nil
    updateQueuedItems([], animated: false)
    let projectPath = projectURL?.path
    let residentProjectWorkspace = projectPath.flatMap {
      self.residentProjectWorkspace(projectPath: $0)
    }
    if projectWorkspace !== residentProjectWorkspace {
      projectWorkspace?.shutdown(flags: [])
    }
    projectWorkspace = nil
    projectHistoryManager = nil
    restoredUserNode = nil
    projectContext = .empty
    if isProjectSecurityScopedResourceAccessing && residentProjectWorkspace == nil {
      projectURL?.stopAccessingSecurityScopedResource()
    }
    projectURL = nil
    projectBarController.projectName = nil
    (viewController as? ChatViewControllerForiPad)?.setProjectDemo(url: nil, isHidden: false)
    viewController.setLocalPathResolver(
      nil, refreshVisibleCells: refreshVisibleCells)
    isProjectSecurityScopedResourceAccessing = false
  }

  private func openProject(at url: URL, threadId: Int64?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let bookmarkData = bookmarkData(for: url) else { return }
    let standardizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
    let currentPath = projectURL?.standardizedFileURL.resolvingSymlinksInPath().path
    if currentPath != standardizedPath,
      remoteChatProviders.values.contains(where: {
        $0.hasActiveConversations(projectPath: currentPath)
      })
    {
      return
    }
    defer {
      let message: ProjectHistoryItem.ActionableMessage?
      if let projectURL, let threadId = projectHistoryManager?.threadId {
        message =
          transientErrorMessages[
            ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)]
      } else {
        message = nil
      }
      viewController.setActionableMessage(message)
      updateChatBanner()
    }
    if case .some(.local) = codeAgentWrapper {
      agentScheduler.setForeground(nil)
      chatInputController.sendState = .idle
    }
    cancelRemoteStatusRequests()
    if currentPath != standardizedPath || projectHistoryManager == nil {
      stopProjectSecurityScopedResourceAccess(refreshVisibleCells: false)
      let activeProjectWorkspace = residentProjectWorkspace(projectPath: standardizedPath)
      let retiringResources:
        (
          projectWorkspace: SQLiteWorkspace?, hadSecurityScopedAccess: Bool
        ) =
          activeProjectWorkspace == nil
          ? claimRetiringProjectResources(projectPath: standardizedPath) : (nil, false)
      let residentProjectWorkspace =
        activeProjectWorkspace ?? retiringResources.projectWorkspace
      let didStartAccessing: Bool
      if activeProjectWorkspace != nil {
        didStartAccessing = false
      } else if retiringResources.hadSecurityScopedAccess {
        didStartAccessing = true
      } else {
        didStartAccessing = url.startAccessingSecurityScopedResource()
      }
      let fileManager = FileManager.default
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        if didStartAccessing {
          url.stopAccessingSecurityScopedResource()
        }
        workspace.dictionary["project", Data.self] = nil
        viewController.setHistory([])
        return
      }
      let metadataDirectoryURL = url.appendingPathComponent(".localc", isDirectory: true)
      guard
        (try? fileManager.createDirectory(
          at: metadataDirectoryURL, withIntermediateDirectories: true)) != nil
      else {
        if didStartAccessing {
          url.stopAccessingSecurityScopedResource()
        }
        workspace.dictionary["project", Data.self] = nil
        viewController.setHistory([])
        return
      }
      let metadataURL = metadataDirectoryURL.appendingPathComponent("metadata.sqlite3")
      if !fileManager.fileExists(atPath: metadataURL.path),
        !fileManager.createFile(atPath: metadataURL.path, contents: nil)
      {
        if didStartAccessing {
          url.stopAccessingSecurityScopedResource()
        }
        workspace.dictionary["project", Data.self] = nil
        viewController.setHistory([])
        return
      }
      self.projectURL = url
      isProjectSecurityScopedResourceAccessing = didStartAccessing
      let localPathResolver = LocalPathResolver(
        projectPath: url.path, workspacePath: settingsWorkflow.workspaceFolderURL.path)
      viewController.setLocalPathResolver(
        localPathResolver, refreshVisibleCells: false)
      let projectWorkspace =
        residentProjectWorkspace
        ?? SQLiteWorkspace(filePath: metadataURL.path, fileProtectionLevel: .noProtection)
      self.projectWorkspace = projectWorkspace
      projectHistoryManager = ProjectHistoryManager(project: projectWorkspace)
    }
    workspace.dictionary["project", Data.self] = bookmarkData
    projectBarController.projectName = ProjectController.displayTitle(
      forProjectPath: url.path, rootProjectPath: settingsWorkflow.workspaceFolderURL.path)
    // A template can ship a demo video. Every thread in the project shows it or the banner, as
    // last chosen there.
    let projectDemoURL = url.appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("project_demo.mp4", isDirectory: false)
    (viewController as? ChatViewControllerForiPad)?.setProjectDemo(
      url: FileManager.default.fileExists(atPath: projectDemoURL.path) ? projectDemoURL : nil,
      isHidden: projectWorkspace?.dictionary["project_demo_hidden", Bool.self] ?? false)
    skillCatalog = SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: Bundle.main.resourceURL?.appendingPathComponent(
          "Skills", isDirectory: true),
        projectURL: url, workspaceURL: settingsWorkflow.workspaceFolderURL))
    projectContext = ProjectContext.load(projectURL: url)
    guard let projectHistoryManager else { return }
    // Opening any thread leaves the welcome thread and the Model Speed page.
    closeWelcomeThread()
    closeModelSpeed(animated: false)
    if let requestedThreadId = threadId,
      requestedThreadId == -1 || projectHistoryManager.thread(id: requestedThreadId) != nil
    {
      projectHistoryManager.threadId = requestedThreadId
    }
    settingsWorkflow.setProjectHistoryManager(
      projectHistoryManager, project: projectWorkspace, projectURL: url)
    if projectHistoryManager.threadId >= 0 {
      projectHistoryManager.setThreadHasUnreadResponse(
        id: projectHistoryManager.threadId, hasUnreadResponse: false)
      if isViewingThread(projectPath: standardizedPath, threadId: projectHistoryManager.threadId) {
        threadNotifications.clear(
          projectPath: standardizedPath, threadId: projectHistoryManager.threadId)
      }
    }
    observeQueuedItems(threadId: projectHistoryManager.threadId)
    var didResolveThreadModel = false
    if projectHistoryManager.threadId >= 0,
      let thread = projectHistoryManager.thread(id: projectHistoryManager.threadId)
    {
      didResolveThreadModel = true
      if let threadModel = thread.model {
        if let remoteModel = parseRemoteThreadModelIdentifier(threadModel) {
          remoteModel.provider.setModel(remoteModel.model, in: workspace)
          let remoteChatProvider = remoteChatProvider(for: remoteModel.provider)
          codeAgentWrapper = .remote(remoteChatProvider)
          workspace.dictionary["chat_backend", String.self] = remoteModel.provider.rawValue
          settingsWorkflow.setRemoteContextStatus(nil)
          chatInputController.setModel(
            name: remoteChatProvider.title,
            image: Self.modelImage(for: remoteChatProvider.provider))
        } else if LLMZoo.specificationForModel(threadModel) != nil {
          selectedLLM = threadModel
          workspace.dictionary["chat_backend", String.self] = nil
          chatInputController.setModel(
            name: LLMZoo.humanReadableNameForModel(threadModel),
            image: Self.modelImage(for: threadModel))
        } else {
          codeAgentWrapper = nil
          workspace.dictionary["chat_backend", String.self] = nil
          settingsWorkflow.setRemoteContextStatus(nil)
          settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
          settingsWorkflow.setContextUsed(0, contextWindowTokens: 0)
          chatInputController.setModel(
            name: LocalizedString.forKey("unspecified"), image: Self.modelImage(for: nil))
        }
      } else {
        codeAgentWrapper = nil
        workspace.dictionary["chat_backend", String.self] = nil
        settingsWorkflow.setRemoteContextStatus(nil)
        settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
        settingsWorkflow.setContextUsed(0, contextWindowTokens: 0)
        chatInputController.setModel(
          name: LocalizedString.forKey("unspecified"), image: Self.modelImage(for: nil))
      }
    }
    if !didResolveThreadModel {
      if let value = workspace.dictionary["chat_backend", String.self],
        let provider = RemoteProvider(rawValue: value)
      {
        let remoteChatProvider = remoteChatProvider(for: provider)
        codeAgentWrapper = .remote(remoteChatProvider)
        settingsWorkflow.setRemoteContextStatus(nil)
        chatInputController.setModel(
          name: remoteChatProvider.title,
          image: Self.modelImage(for: provider))
      } else if let selectedLLM {
        self.selectedLLM = selectedLLM
        chatInputController.setModel(
          name: LLMZoo.humanReadableNameForModel(selectedLLM),
          image: Self.modelImage(for: selectedLLM))
      } else {
        codeAgentWrapper = nil
        settingsWorkflow.setRemoteContextStatus(nil)
        settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
        settingsWorkflow.setContextUsed(0, contextWindowTokens: 0)
        chatInputController.setModel(
          name: LocalizedString.forKey("unspecified"), image: Self.modelImage(for: nil))
      }
    }
    switch codeAgentWrapper {
    case .some(.local):
      chatInputController.sendState = .idle
      restoreSelectedThread()
    case .some(.remote):
      restoreRemoteConversation()
    case nil:
      restoredUserNode = nil
      chatInputController.sendState = .idle
      viewController.setHistory([])
    }
    // A new conversation with an empty input starts from one of the project's suggested prompts,
    // which use MEMORY.md's § separator. A draft the user already has is kept.
    if projectHistoryManager.threadId < 0,
      chatInputController.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = try? ProjectMemory.read(
        url.appendingPathComponent(".localc/first_time_prompts.txt")),
      let prompt = (try? ProjectMemory.parse(data))?.randomElement()
    {
      textHistoryManager.pushChange(
        range: NSRange(location: 0, length: textHistoryManager.currentPositiveText.utf16.count),
        replacementText: prompt, textType: .positiveText)
      textHistoryManager.saveCursor()
      chatInputController.setText(textHistoryManager.currentPositiveText)
      updateTextHistoryPointers()
    }
  }

  private func openWelcomeThread(animated: Bool) {
    // The walkthrough covers a new thread in the open project, which is where it lands when it
    // finishes. Replaying it finds that thread already open.
    if onboardingWorkflow == nil {
      openProject(at: projectURL ?? settingsWorkflow.workspaceFolderURL, threadId: -1)
    }
    let onboardingWorkflow = OnboardingWorkflow(
      workspace: workspace, accountManager: accountManager)
    onboardingWorkflow.delegate = self
    self.onboardingWorkflow = onboardingWorkflow
    settingsWorkflow.isOnboardingSelected = true
    let completionHandler = {
      onboardingWorkflow.viewController.startIntroduction()
    }
    viewController.setOnboardingViewController(
      onboardingWorkflow.viewController, animated: animated, completionHandler: completionHandler)
  }

  private func closeWelcomeThread() {
    guard onboardingWorkflow != nil else { return }
    onboardingWorkflow = nil
    settingsWorkflow.isOnboardingSelected = false
    viewController.setOnboardingViewController(nil, animated: false, completionHandler: nil)
  }

  private func closeModelSpeed(animated: Bool) {
    guard modelSpeedWorkflow != nil else { return }
    modelSpeedWorkflow = nil
    (viewController as? ChatViewControllerForiPad)?.setModelSpeedViewController(
      nil, animated: animated)
  }

  func restoreSelectedThread() {
    restoredUserNode = nil
    guard let projectHistoryManager,
      let projectURL,
      case .some(.local(let textGenerator, _)) = codeAgentWrapper
    else { return }
    let file = URL(fileURLWithPath: textGenerator.filePath).lastPathComponent
    agentScheduler.setForeground(nil)
    let threadId = projectHistoryManager.threadId
    guard threadId >= 0, let thread = projectHistoryManager.thread(id: threadId) else {
      projectHistoryManager.threadId = -1
      codeAgentWrapper = .local(textGenerator, nil)
      viewController.setHistory([])
      chatInputController.sendState = .idle
      settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
      setLocalContextUsed()
      return
    }
    if agentScheduler.file == file,
      let residentCodeAgent = agentScheduler.residentCodeAgent(
        projectPath: projectURL.path, threadId: threadId)
    {
      codeAgentWrapper = .local(textGenerator, residentCodeAgent)
      agentScheduler.setForeground(residentCodeAgent)
      let statistics = residentCodeAgent.statistics
      settingsWorkflow.setPrefillTokensPerSecond(
        statistics.prefillTokensPerSecond,
        tokenGeneratedPerSecond: statistics.tokenGeneratedPerSecond)
      settingsWorkflow.setContextUsed(
        statistics.contextUsedTokens,
        contextWindowTokens: statistics.contextWindowTokens)
      var history = projectHistoryManager.history(threadId: threadId)
      if agentScheduler.hasActiveTurn(residentCodeAgent) {
        viewController.setHistory(historyMessages(from: history))
        viewController.appendAssistant(
          activeMemoryReviews.contains(ObjectIdentifier(residentCodeAgent))
            ? LocalizedString.forKey("reviewing_memory_dot") : "",
          isTransient: true,
          mode: .bringup(
            startTime: CACurrentMediaTime(),
            bashUserInteraction: residentCodeAgent.bashUserInteraction))
        // A turn stopped, or steered, before the switch is still stopping.
        chatInputController.sendState =
          agentScheduler.isStopping(residentCodeAgent) ? .stopping : .sending
        if let (progress, statistics) = agentScheduler.latestProgress(
          projectPath: projectURL.path, threadId: threadId)
        {
          renderLocalProgress(
            progress, startTime: CACurrentMediaTime(),
            bashUserInteraction: residentCodeAgent.bashUserInteraction, statistics: statistics,
            codeAgent: residentCodeAgent, projectPath: projectURL.path)
        }
      } else {
        restoreDraftIfNeeded(from: &history)
        viewController.setHistory(historyMessages(from: history))
        chatInputController.sendState = .idle
      }
      return
    }

    var history = projectHistoryManager.history(threadId: threadId)
    let hasPersistedSuspension: Bool
    switch textGenerator {
    case let textGenerator as Qwen3_5TextGenerator:
      hasPersistedSuspension =
        Qwen3_5ContextCache(
          projectPath: projectURL.path,
          checkpointStride: textGenerator.chunkedPrefillMaxLength
        ).loadSuspension(threadId: threadId) != nil
    case let textGenerator as any DeepSeekTextGenerator:
      hasPersistedSuspension =
        DeepSeek4ContextCache(
          projectPath: projectURL.path, checkpointStride: textGenerator.checkpointStride
        ).loadSuspension(threadId: threadId) != nil
    default:
      preconditionFailure("Unsupported text generator")
    }
    if hasPersistedSuspension {
      var incompleteResponseText = ""
      let (prefixTokens, prefixEmbedSpans) = projectHistoryManager.context(threadId: threadId)
      if let restoredWrapper = codeAgentWrapper(
        model: file, prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
        history: history, fromSuspension: true),
        case .local(_, let restoredCodeAgent) = restoredWrapper,
        let restoredCodeAgent,
        (try? restoredCodeAgent.restoreSuspension(
          threadId: threadId, projectPath: projectURL.path)) == true
      {
        if !thread.hasIncompleteResponse {
          projectHistoryManager.setThreadHasIncompleteResponse(
            id: threadId, hasIncompleteResponse: true)
        }
        codeAgentWrapper = restoredWrapper
        if let suspendedResult = restoredCodeAgent.suspendedResult {
          let workspacePath = settingsWorkflow.workspaceFolderURL.path
          let toolCallHistoryContext = suspendedResult.toolCallHistory.compactMap {
            ToolsRegistry.parse(
              $0.request, projectPath: projectURL.path, workspacePath: workspacePath
            )?.subtitle(for: .past)
          }.joined(separator: "\n")
          if suspendedResult.output.isEmpty {
            var chainOfThought = suspendedResult.think.trimmingCharacters(
              in: .whitespacesAndNewlines)
            let chainOfThoughtLines = chainOfThought.components(separatedBy: .newlines)
            if chainOfThoughtLines.count > Self.chainOfThoughtLineLimit {
              chainOfThought = (["..."] + chainOfThoughtLines.suffix(Self.chainOfThoughtLineLimit))
                .joined(separator: "\n")
            }
            incompleteResponseText =
              [toolCallHistoryContext, chainOfThought].filter { !$0.isEmpty }.joined(
                separator: "\n---\n")
          } else {
            let response = ToolCallParser.removeToolCalls(
              suspendedResult.output, toolCallStart: restoredCodeAgent.toolCallStart,
              toolCallEnd: restoredCodeAgent.toolCallEnd
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            var renderingToolCalls = suspendedResult.toolCalls
            if let incompleteToolCall = suspendedResult.incompleteToolCall {
              renderingToolCalls.append(incompleteToolCall)
            }
            let toolCallContext = renderingToolCalls.compactMap {
              ToolsRegistry.parse(
                $0.request, projectPath: projectURL.path, workspacePath: workspacePath
              )?.subtitle(for: .now)
            }.joined(separator: "\n")
            incompleteResponseText =
              [toolCallHistoryContext, response, toolCallContext].filter { !$0.isEmpty }.joined(
                separator: "\n---\n")
          }
        }
        let statistics = restoredCodeAgent.statistics
        settingsWorkflow.setPrefillTokensPerSecond(
          statistics.prefillTokensPerSecond,
          tokenGeneratedPerSecond: statistics.tokenGeneratedPerSecond)
        settingsWorkflow.setContextUsed(
          statistics.contextUsedTokens,
          contextWindowTokens: statistics.contextWindowTokens)
        viewController.setHistory(
          historyMessages(from: history),
          hasIncompleteResponse: true, incompleteResponseText: incompleteResponseText)
        chatInputController.sendState = .idle
        return
      }
    }
    if thread.hasIncompleteResponse {
      projectHistoryManager.setThreadHasIncompleteResponse(
        id: threadId, hasIncompleteResponse: false)
    }
    codeAgentWrapper = .local(textGenerator, nil)
    settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
    setLocalContextUsed()
    restoreDraftIfNeeded(from: &history)
    viewController.setHistory(historyMessages(from: history))
    chatInputController.sendState = .idle
  }

  func restoreDraftIfNeeded(from history: inout [ProjectHistoryNode]) {
    restoredUserNode = nil
    let queuedItems = self.queuedItems
    var prompts = queuedItems.compactMap(\.text)
    let safeTokenizer: TiktokenTokenizer
    switch codeAgentWrapper {
    case .some(.local(let textGenerator, _)):
      safeTokenizer = textGenerator.safeTokenizer
    case .some(.remote):
      let model =
        history.last.flatMap { projectHistoryManager?.thread(id: $0.threadId)?.model }
        ?? selectedLLM
      switch model.flatMap({ LLMZoo.specificationForModel($0) })?.version {
      case .deepseek_4_flash:
        safeTokenizer = DeepSeek4TextGenerator.safeTokenizer
      case .deepseek_4_1_flash:
        safeTokenizer = DeepSeek4_1TextGenerator.safeTokenizer
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b, nil:
        safeTokenizer = Qwen3_5TextGenerator.safeTokenizer
      }
    case nil:
      return
    }
    if let index = history.lastIndex(where: { $0.role != .memory }),
      case let node = history[index], node.role == .user
    {
      let prompt =
        node.plaintext ?? safeTokenizer.decode(node.tokens)
      prompts.insert(prompt, at: 0)
      if node.textEdits >= 0, node.textLineage >= 0,
        let textEdits = Int(exactly: node.textEdits)
      {
        let _ = textHistoryManager.seek(to: textEdits, lineage: node.textLineage)
      }
      restoredUserNode = (threadId: node.threadId, datetime: node.datetime)
      history.remove(at: index)
    }
    if !prompts.isEmpty {
      // Sent attachments are already in the project; restore their cards from each message.
      let sections = prompts.map(ChatAttachment.parseSections)
      let prompt = sections.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
      let paths = sections.flatMap(\.paths)
      if textHistoryManager.currentPositiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        != prompt
      {
        textHistoryManager.pushChange(
          range: NSRange(
            location: 0, length: textHistoryManager.currentPositiveText.utf16.count),
          replacementText: prompt, textType: .positiveText)
      }
      textHistoryManager.saveCursor()
      chatInputController.setText(textHistoryManager.currentPositiveText)
      if let projectURL {
        chatInputController.addAttachments(
          projectFiles: paths.map { projectURL.appendingPathComponent($0) })
      }
      updateTextHistoryPointers()
    }
    guard !queuedItems.isEmpty, let projectWorkspace else { return }
    projectWorkspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      let deletionRequests = queuedItems.compactMap {
        ProjectQueuedItemChangeRequest.deletionRequest($0)
      }
      for deletionRequest in deletionRequests {
        transactionContext.try(submit: deletionRequest)
      }
    }
  }

  func historyMessages(
    from history: [ProjectHistoryNode]
  ) -> [ChatHistoryMessage] {
    let projectPath = projectURL?.path
    let workspacePath = settingsWorkflow.workspaceFolderURL.path
    let safeTokenizer: TiktokenTokenizer
    let toolCallSpecialTokens: [Int32: String]
    switch codeAgentWrapper {
    case .some(.local(let textGenerator, let codeAgent)):
      safeTokenizer = textGenerator.safeTokenizer
      if let codeAgent {
        toolCallSpecialTokens = codeAgent.toolCallSpecialTokens
      } else if textGenerator is any DeepSeekTextGenerator {
        toolCallSpecialTokens = DeepSeek4ToolCallParser.toolCallSpecialTokens
      } else {
        toolCallSpecialTokens = Qwen3_5ToolCallParser.toolCallSpecialTokens
      }
    case .some(.remote):
      let model =
        history.last.flatMap { projectHistoryManager?.thread(id: $0.threadId)?.model }
        ?? selectedLLM
      switch model.flatMap({ LLMZoo.specificationForModel($0) })?.version {
      case .deepseek_4_flash:
        safeTokenizer = DeepSeek4TextGenerator.safeTokenizer
        toolCallSpecialTokens = DeepSeek4ToolCallParser.toolCallSpecialTokens
      case .deepseek_4_1_flash:
        safeTokenizer = DeepSeek4_1TextGenerator.safeTokenizer
        toolCallSpecialTokens = DeepSeek4ToolCallParser.toolCallSpecialTokens
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b, nil:
        safeTokenizer = Qwen3_5TextGenerator.safeTokenizer
        toolCallSpecialTokens = Qwen3_5ToolCallParser.toolCallSpecialTokens
      }
    case nil:
      return []
    }
    return history.compactMap { node in
      let datetime = Date(timeIntervalSince1970: Double(node.datetime) / 1_000)
      switch node.role {
      case .memory:
        return nil
      case .user:
        return .user(
          node.plaintext ?? safeTokenizer.decode(node.tokens),
          datetime: datetime)
      case .assistant:
        if let plaintext = node.plaintext {
          return .assistant(plaintext, datetime: datetime, duration: node.duration)
        }
        let response = safeTokenizer.decode(
          node.tokens, specialTokens: toolCallSpecialTokens)
        let toolCallContext = node.toolCalls.compactMap { toolCall -> String? in
          guard let function = toolCall.function else { return nil }
          var parameters = [String: ToolCall.Request.Parameter]()
          for parameter in toolCall.parameters {
            guard let name = parameter.name, let value = parameter.value else { continue }
            parameters[name] = ToolCall.Request.Parameter(string: true, value: value)
          }
          let request = ToolCall.Request(function: function, parameters: parameters)
          return ToolsRegistry.parse(
            request, projectPath: projectPath, workspacePath: workspacePath
          )?.subtitle(for: .past)
            ?? "**\(function)**"
        }.joined(separator: "\n")
        return .assistant(
          [
            toolCallContext,
            response.trimmingCharacters(in: .whitespacesAndNewlines),
          ].filter { !$0.isEmpty }.joined(separator: "\n---\n"), datetime: datetime,
          duration: node.duration)
      }
    }
  }

  private func bookmarkData(for projectURL: URL) -> Data? {
    #if targetEnvironment(macCatalyst)
      return try? projectURL.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    #else
      return try? projectURL.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    #endif
  }

  private func resolveProjectURL(from bookmarkData: Data) -> URL? {
    var isStale = false
    guard
      let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale),
      !isStale
    else { return nil }
    return url
  }

  private func selectThread(_ thread: ProjectController.Thread) {
    let openThread: () -> Void = { [weak self] in
      guard let self else { return }
      guard thread.threadId != OnboardingState.threadIdentifier else {
        self.openWelcomeThread(animated: true)
        return
      }
      self.openProject(
        at: URL(fileURLWithPath: thread.projectPath, isDirectory: true),
        threadId: thread.threadId)
    }
    if codeAgentWrapper != nil {
      openThread()
      return
    }
    if chatInputController.sendState == .stopping {
      didStopHandler = openThread
      return
    }
    guard chatInputController.sendState == .idle else {
      let alertController = UIAlertController(
        title: LocalizedString.forKey("switch_thread_during_generation_title"),
        message: LocalizedString.forKey("switch_thread_during_generation_message"),
        preferredStyle: .alert)
      alertController.addAction(
        UIAlertAction(
          title: LocalizedString.forKey("stop_and_switch"), style: .destructive
        ) { [weak self] _ in
          guard let self else { return }
          if self.chatInputController.sendState == .idle {
            openThread()
            return
          }
          self.didStopHandler = openThread
          self.chatInputControllerDidTapStop(self.chatInputController)
        })
      alertController.addAction(
        UIAlertAction(
          title: LocalizedString.forKey("keep_generating"), style: .cancel))
      presentedViewController.present(alertController, animated: true)
      return
    }
    openThread()
  }
}

extension ChatWorkflow: OnboardingWorkflowDelegate {
  func onboardingWorkflow(
    _ workflow: OnboardingWorkflow, didRequestSignIn provider: AccountManager.SignInProvider,
    sourceView: UIView
  ) {
    settingsWorkflow.signInFromOnboarding(
      provider: provider, presentingViewController: workflow.viewController,
      sourceView: sourceView)
  }

  func onboardingWorkflow(
    _ workflow: OnboardingWorkflow, didRequestDownloadOfLocalModel file: String
  ) {
    guard let specification = LLMZoo.specificationForModel(file),
      !LLMZoo.isModelDownloaded(specification)
    else { return }
    // Selecting the model later joins this download instead of starting another.
    downloadLLMModel(specification) { _ in }
  }

  func onboardingWorkflow(_ workflow: OnboardingWorkflow, didSelectLocalModel file: String) {
    selectLocalModel(file: file)
  }

  func onboardingWorkflow(
    _ workflow: OnboardingWorkflow,
    didRequestProjects projects: [(name: String, templateName: String)]
  ) {
    settingsWorkflow.createProjects(projects)
  }

  func onboardingWorkflowDidUpdateRemoteProvider(_ workflow: OnboardingWorkflow) {
    settingsWorkflow.refreshRemoteProviderConfiguration()
  }

  func onboardingWorkflow(
    _ workflow: OnboardingWorkflow, didFinishWith provider: RemoteProvider?
  ) {
    workspace.dictionary["chat_backend", String.self] = provider?.rawValue
    openProject(at: projectURL ?? settingsWorkflow.workspaceFolderURL, threadId: -1)
    chatInputController.focus()
  }
}

extension ChatWorkflow: ModelSpeedWorkflowDelegate {
  func modelSpeedWorkflowDidRequestClose(_ workflow: ModelSpeedWorkflow) {
    // The chat it covered shows again.
    closeModelSpeed(animated: true)
  }

  func modelSpeedWorkflow(_ workflow: ModelSpeedWorkflow, textGeneratorToRun model: String)
    -> (any TextGenerator)?
  {
    guard let textGenerator = textGenerator(for: model) else { return nil }
    let scheduler = agentScheduler
    let chatTextGenerator: (any TextGenerator)?
    if case .some(.local(let generator, _)) = codeAgentWrapper {
      chatTextGenerator = generator
    } else {
      chatTextGenerator = nil
    }
    // Runs after any turn already queued. Idle threads give back their caches, and another
    // model's weights are dropped until the chat's next turn loads them again.
    queue.async {
      guard scheduler.isIdle else { return }
      scheduler.unloadIdleCaches()
      if let chatTextGenerator, chatTextGenerator.filePath != textGenerator.filePath {
        chatTextGenerator.unload()
      }
    }
    return textGenerator
  }
}

extension ChatWorkflow: SettingsWorkflowDelegate {
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, residentProjectWorkspace projectPath: String
  ) -> SQLiteWorkspace? {
    residentProjectWorkspace(projectPath: projectPath)
  }

  func settingsWorkflow(_ workflow: SettingsWorkflow, didSelectProjectAt url: URL) {
    openProject(at: url, threadId: nil)
    dismissSettings()
  }

  func settingsWorkflow(_ workflow: SettingsWorkflow, didCreateProjectAt url: URL) {
    // A new thread being composed moves to the new project. Any other open thread, the welcome
    // thread, or Model Speed stays, and settings stays up either way.
    guard onboardingWorkflow == nil, modelSpeedWorkflow == nil,
      projectHistoryManager?.threadId == -1
    else { return }
    selectThread(ProjectController.Thread(projectPath: url.path, threadId: -1))
  }

  func settingsWorkflow(_ workflow: SettingsWorkflow, didFillProjectAt url: URL) {
    // The project can open before its template lands, as a new thread moves into it on creation.
    // The demo and starter prompt still wait for the project to open again.
    guard let projectURL,
      projectURL.standardizedFileURL.resolvingSymlinksInPath()
        == url.standardizedFileURL.resolvingSymlinksInPath()
    else { return }
    skillCatalog = SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: Bundle.main.resourceURL?.appendingPathComponent(
          "Skills", isDirectory: true),
        projectURL: projectURL, workspaceURL: workflow.workspaceFolderURL))
    projectContext = ProjectContext.load(projectURL: projectURL)
  }

  func settingsWorkflowDidRemoveOpenProject(_ workflow: SettingsWorkflow) {
    // Opens right away, so moving the project to the Trash can then check that it closed.
    // Settings stays up to show the project leave the list.
    openProject(at: workflow.workspaceFolderURL, threadId: -1)
  }

  func settingsWorkflowDidRequestModelSpeed(_ workflow: SettingsWorkflow) {
    // Covers the chat the way the welcome walkthrough does; opening a thread leaves it.
    guard modelSpeedWorkflow == nil,
      let viewController = viewController as? ChatViewControllerForiPad
    else { return }
    closeWelcomeThread()
    let modelSpeedWorkflow = ModelSpeedWorkflow(
      workspace: workspace, model: selectedLLM, queue: queue, graph: graph,
      streamContext: streamContext)
    modelSpeedWorkflow.delegate = self
    modelSpeedWorkflow.start()
    self.modelSpeedWorkflow = modelSpeedWorkflow
    viewController.setModelSpeedViewController(modelSpeedWorkflow.viewController, animated: true)
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didSelectThread thread: ProjectController.Thread
  ) {
    selectThread(thread)
    dismissSettings()
  }

}

extension ChatWorkflow: AgentSchedulerDelegate {
  func agentScheduler(
    _ scheduler: AgentScheduler,
    didActiveThreadsChange activeThreads: [(
      projectPath: String, threadId: Int64, state: AgentScheduler.State
    )]
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    updateModelIdleState()
    guard scheduler === agentScheduler else { return }
    settingsWorkflow.setActiveThreads(
      activeThreads.map { (projectPath: $0.projectPath, threadId: $0.threadId) })
  }
}

extension ChatWorkflow: LocalModelSizeLoaderDelegate {
  func localModelSizeLoaderDidLoadSize(_ loader: LocalModelSizeLoader) {
    guard let modelSelectWorkflow else { return }
    if case .some(.remote) = codeAgentWrapper { return }
    modelSelectWorkflow.setViewModels(
      [Self.localModelSection(selectedModel: selectedLLM, workspace: workspace)], flag: nil)
  }
}

extension ChatWorkflow: ItemSelectWorkflowDelegate {
  func didSelectItem(
    item: ItemViewModel.ItemIdentifier, section: ItemDisplaySectionIdentity,
    workflow: ItemSelectWorkflow
  ) {
    if workflow === projectSelectWorkflow {
      workflow.viewControllable.dismiss(animated: true) { [weak self] in
        guard let self, case .identifier(let identifier) = item else { return }
        if let thread = identifier as? ProjectController.Thread {
          self.selectThread(thread)
          return
        }
        guard let path = identifier as? String else { return }
        // A project without threads opens on a new thread. If we are composing a new thread,
        // keep that state in the newly selected project rather than restoring its last opened
        // thread.
        let hasThreads = self.settingsWorkflow.projectThreads.contains {
          $0.projectPath == path && !$0.newThread
        }
        self.openProject(
          at: URL(fileURLWithPath: path, isDirectory: true),
          threadId: !hasThreads || self.projectHistoryManager?.threadId == -1 ? -1 : nil)
      }
      projectSelectWorkflow = nil
      return
    }
    guard workflow === modelSelectWorkflow else { return }
    guard case .identifier(let identifier as String) = item else {
      remoteModelCatalogRequest?.cancel()
      remoteModelCatalogRequest = nil
      workflow.viewControllable.dismiss(animated: true)
      modelSelectWorkflow = nil
      return
    }
    workflow.viewControllable.dismiss(animated: true) { [weak self] in
      guard let self else { return }
      if let remoteModel = self.parseRemoteThreadModelIdentifier(identifier) {
        self.selectRemoteModel(remoteModel.model, provider: remoteModel.provider)
      } else {
        self.selectLocalModel(file: identifier)
      }
    }
    remoteModelCatalogRequest?.cancel()
    remoteModelCatalogRequest = nil
    modelSelectWorkflow = nil
  }

  func didTapTrash(item: ItemViewModel.ItemIdentifier, workflow: ItemSelectWorkflow) {
  }

  func contextMenu(item: ItemViewModel.ItemIdentifier, workflow: ItemSelectWorkflow) -> UIMenu? {
    guard workflow === modelSelectWorkflow, case .identifier(let file as String) = item,
      let specification = LLMZoo.specificationForModel(file)
    else { return nil }
    // A download that stopped between a model's files leaves only some of them.
    let fileURLs = ([specification.file] + [specification.engram].compactMap { $0 }).map {
      URL(fileURLWithPath: LLMZoo.filePathForModelDownloaded($0))
    }.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard !fileURLs.isEmpty else { return nil }
    let revealAction = UIAction(title: ProjectController.revealTitle) { _ in
      #if targetEnvironment(macCatalyst)
        // Opening a checkpoint would hand it to another app, so select the files in Finder.
        if let sharedWorkspace = (NSClassFromString("NSWorkspace") as? NSObject.Type)?.value(
          forKey: "sharedWorkspace") as? NSObject
        {
          sharedWorkspace.perform(
            NSSelectorFromString("activateFileViewerSelectingURLs:"), with: fileURLs)
          return
        }
      #endif
      UIApplication.shared.open(fileURLs[0].deletingLastPathComponent())
    }
    // Keep files another downloaded model still needs, such as an engram its variants share.
    let filesRequired = LLMZoo.availableFiles(excluding: LLMZoo.self).union(
      LLMZoo.availableFiles(excluding: specification.file))
    let removingFileURLs = fileURLs.filter { !filesRequired.contains($0.lastPathComponent) }
    guard !removingFileURLs.isEmpty else { return UIMenu(children: [revealAction]) }
    let removeDownloadAction = UIAction(
      title: LocalizedString.forKey("remove_download_dot"),
      attributes: isLocalModelInUse(specification) ? [.destructive, .disabled] : .destructive
    ) { [weak self, weak workflow] _ in
      guard let self, let workflow else { return }
      self.confirmRemovingDownload(
        of: specification, fileURLs: removingFileURLs, workflow: workflow)
    }
    return UIMenu(children: [revealAction, removeDownloadAction])
  }

  func didSelectShowAll(showAll: Bool, workflow: ItemSelectWorkflow) {
  }

  func didSelectShowDetails(showDetails: Bool, workflow: ItemSelectWorkflow) {
    guard workflow === modelSelectWorkflow else { return }
    workspace.dictionary["model_selector_shows_details", Bool.self] = showDetails
  }

  func didDismiss(workflow: ItemSelectWorkflow) {
    if workflow === projectSelectWorkflow {
      projectSelectWorkflow = nil
      return
    }
    guard workflow === modelSelectWorkflow else { return }
    remoteModelCatalogRequest?.cancel()
    remoteModelCatalogRequest = nil
    modelSelectWorkflow = nil
  }
}

extension ChatWorkflow {
  func handleKeyboardShortcut(_ action: KeyboardShortcutAction) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch action {
    case .newProject:
      withSettingsPresented { [weak self] in
        self?.settingsWorkflow.presentNewProjectPrompt()
      }
    case .newChat:
      guard let projectURL else { return }
      selectThread(ProjectController.Thread(projectPath: projectURL.path, threadId: -1))
    case .machineSettings:
      withSettingsPresented { [weak self] in
        self?.settingsWorkflow.presentMachineSettings()
      }
    case .projectsTab:
      settingsWorkflow.selectProjectsTab()
    case .settingsTab:
      settingsWorkflow.selectSettingsTab()
    case .kitTab:
      settingsWorkflow.selectKitTab()
    case .activitiesTab:
      settingsWorkflow.selectActivitiesTab()
    case .focusChat:
      chatInputController.focus()
    case .stopConversation:
      chatInputController.stop()
    }
  }

  /// On the phone, settings slides in over the chat from the leading edge; a screen edge pan
  /// drives it when `interactive`.
  private func presentSettings(interactive: Bool, completion: (() -> Void)? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    viewController.view.endEditing(true)
    settingsWorkflow.presentInteractively = interactive
    viewController.present(
      settingsWorkflow.viewControllable, animated: true, completion: completion)
  }

  /// Settings presents its own prompts, so on the phone it comes up first.
  private func withSettingsPresented(_ body: @escaping () -> Void) {
    guard userInterfaceIdiom == .phone,
      settingsWorkflow.viewControllable.presentingViewController == nil
    else {
      body()
      return
    }
    presentSettings(interactive: false, completion: body)
  }

  /// On the phone, puts settings away once what it opened shows, unless it is still asking
  /// something first.
  private func dismissSettings() {
    let settingsViewController = settingsWorkflow.viewControllable
    guard settingsViewController.presentingViewController != nil,
      settingsViewController.presentedViewController == nil
    else { return }
    settingsViewController.dismiss(animated: true)
  }
}

extension ChatWorkflow: ChatViewControllableDelegate {
  func chatViewController(
    _ viewController: UIViewController,
    didReceiveScreenEdgePan screenEdgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer
  ) {
    // This is to trigger settings workflow presentation.
    switch screenEdgePanGestureRecognizer.state {
    case .began:
      presentSettings(interactive: true)
    case .changed:
      let translationX = screenEdgePanGestureRecognizer.translation(in: viewController.view).x
      // 48 removes the hinge that still visible after settings presented.
      let percent = translationX / (viewController.view.bounds.width - 48)
      settingsWorkflow.percentDrivenInteractiveTransition?.update(percent)
    case .ended:
      let translationX = screenEdgePanGestureRecognizer.translation(in: viewController.view).x
      let percent = translationX / (viewController.view.bounds.width - 48)
      if percent > 0.5
        || (translationX > 48
          && screenEdgePanGestureRecognizer.velocity(in: viewController.view).x >= 800)
      {
        settingsWorkflow.percentDrivenInteractiveTransition?.finish()
      } else {
        settingsWorkflow.percentDrivenInteractiveTransition?.cancel()
      }
    case .cancelled, .failed:  // Failed is not possible, only for discrete gestures.
      settingsWorkflow.percentDrivenInteractiveTransition?.cancel()
    case .possible:
      // This is not possible, it only happens for discrete gestures.
      break
    @unknown default:
      break
    }
  }

  func chatViewController(
    _ viewController: UIViewController, didSetProjectDemoHidden isHidden: Bool
  ) {
    projectWorkspace?.dictionary["project_demo_hidden", Bool.self] = isHidden
  }

  func chatViewControllerDidRequestNewProject(_ viewController: UIViewController) {
    handleKeyboardShortcut(.newProject)
  }

  func chatViewControllerDidRequestNewChat(_ viewController: UIViewController) {
    handleKeyboardShortcut(.newChat)
  }

  func chatViewControllerDidRequestMachineSettings(_ viewController: UIViewController) {
    handleKeyboardShortcut(.machineSettings)
  }

  func chatViewControllerDidRequestProjectsTab(_ viewController: UIViewController) {
    handleKeyboardShortcut(.projectsTab)
  }

  func chatViewControllerDidRequestSettingsTab(_ viewController: UIViewController) {
    handleKeyboardShortcut(.settingsTab)
  }

  func chatViewControllerDidRequestKitTab(_ viewController: UIViewController) {
    handleKeyboardShortcut(.kitTab)
  }

  func chatViewControllerDidRequestActivitiesTab(_ viewController: UIViewController) {
    handleKeyboardShortcut(.activitiesTab)
  }

  func chatViewControllerDidRequestWelcome(_ viewController: UIViewController) {
    // Opening the welcome thread rebuilds the walkthrough, so this also replays it.
    selectThread(
      ProjectController.Thread(
        projectPath: settingsWorkflow.workspaceFolderURL.path,
        threadId: OnboardingState.threadIdentifier))
  }

  func chatViewController(
    _ viewController: UIViewController,
    didSelectCopyHistoryText text: String
  ) {
    UIPasteboard.general.string = text
  }

  func chatViewControllerDidRequestContinueIncompleteResponse(
    _ viewController: UIViewController
  ) {
    continueIncompleteResponse()
  }

  func chatViewController(
    _ viewController: UIViewController,
    didSteerQueuedItem queuedItem: ProjectQueuedItem
  ) {
    guard let projectURL else { return }
    let threadIdentifier = ProjectThreadIdentifier(
      projectURL: projectURL, threadId: queuedItem.threadId)
    guard queuedItems.contains(queuedItem),
      steeringQueuedItems[threadIdentifier]?.contains(queuedItem) != true
    else {
      return
    }
    steeringQueuedItems[threadIdentifier, default: []].append(queuedItem)
    self.viewController.setSteeringQueuedItems(steeringQueuedItems[threadIdentifier] ?? [])
    // While stopping, the stop under way sends this item along with the others steered.
    if chatInputController.sendState == .sending {
      chatInputControllerDidTapStop(chatInputController)
    }
    // Nothing left to stop (a cancelled status request ends at once); send it now.
    if chatInputController.sendState == .idle {
      continueWithQueuedItems()
    }
  }

  func chatViewController(
    _ viewController: UIViewController,
    didDeleteQueuedItem queuedItem: ProjectQueuedItem
  ) {
    guard let projectWorkspace,
      projectHistoryManager?.threadId == queuedItem.threadId,
      let item = queuedItems.first(where: {
        $0.threadId == queuedItem.threadId && $0.datetime == queuedItem.datetime
      })
    else { return }
    projectWorkspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      guard let deletionRequest = ProjectQueuedItemChangeRequest.deletionRequest(item) else {
        return
      }
      transactionContext.try(submit: deletionRequest)
    }
  }
}

extension ChatWorkflow: ProjectBarControllerDelegate {
  func projectBarControllerDidTapSettings(_ controller: ProjectBarController) {
    workspace.dictionary["settings_selected_index", Int.self] = 0
    guard userInterfaceIdiom == .phone else { return }
    presentSettings(interactive: false)
  }

  func projectBarController(
    _ controller: ProjectBarController, didTapProjectSelector sourceView: UIView
  ) {
    let projects = settingsWorkflow.projects
    // On the phone, each project is followed by its threads, as in the drawer: the welcome thread
    // first, then the most recent. iPad and Mac list threads in the sidebar instead.
    let threadsByProject =
      userInterfaceIdiom == .phone
      ? Dictionary(
        grouping: settingsWorkflow.projectThreads.filter { !$0.newThread }, by: \.projectPath)
      : [:]
    var items = [ItemDisplayCollectionViewCellViewModel]()
    var listedThreads = [ProjectController.Thread]()
    for project in projects {
      items.append(
        .itemAcronymViewModel(
          ItemAcronymViewModel(
            itemIdentifier: .identifier(project.path), title: .title(project.title),
            backgroundColor: .clear, detail: project.path,
            thumbnail: .image(
              #imageLiteral(resourceName: "folder-filled-16").withTintColor(
                .secondaryText, renderingMode: .alwaysOriginal)),
            isList: true)))
      let threads = (threadsByProject[project.path] ?? []).sorted { lhs, rhs in
        let lhsIsWelcome = lhs.threadId == OnboardingState.threadIdentifier
        let rhsIsWelcome = rhs.threadId == OnboardingState.threadIdentifier
        if lhsIsWelcome != rhsIsWelcome { return lhsIsWelcome }
        return lhs.updatedAt > rhs.updatedAt
      }
      for thread in threads.prefix(20) {
        items.append(
          .itemAcronymViewModel(
            ItemAcronymViewModel(
              itemIdentifier: .identifier(thread),
              title: .title(thread.title ?? LocalizedString.forKey("untitled")),
              backgroundColor: .clear, detail: thread.lastMessage ?? "",
              thumbnail: .image(
                #imageLiteral(resourceName: "chat-24").withTintColor(
                  .tertiaryText, renderingMode: .alwaysOriginal)),
              isList: true)))
        listedThreads.append(thread)
      }
    }
    let projectSelectWorkflow = ItemSelectWorkflow(
      userInterfaceIdiom: sourceView.traitCollection.userInterfaceIdiom, cellHeight: 32,
      minimumLineSpacing: 4, workspace: workspace, isSwitchDisplayed: false,
      isDetailSwitchDisplayed: false)
    self.projectSelectWorkflow = projectSelectWorkflow
    projectSelectWorkflow.delegate = self
    projectSelectWorkflow.updateTitle(title: LocalizedString.forKey("projects"))
    projectSelectWorkflow.setViewModels(
      [ItemDisplaySectionModel(identifier: .noSection, items: items)], flag: nil)
    if let popoverPresentationController = projectSelectWorkflow.viewControllable
      .popoverPresentationController
    {
      popoverPresentationController.sourceView = sourceView
      popoverPresentationController.sourceRect = sourceView.bounds
      popoverPresentationController.permittedArrowDirections = .up
      popoverPresentationController.popoverLayoutMargins = UIEdgeInsets(
        top: 0, left: 12, bottom: 0, right: 12)
    }
    presentedViewController.present(projectSelectWorkflow.viewControllable, animated: true)
    let openProject = projectURL.flatMap { projectURL in
      projects.first {
        URL(fileURLWithPath: $0.path, isDirectory: true)
          .standardizedFileURL.resolvingSymlinksInPath().path
          == projectURL.standardizedFileURL.resolvingSymlinksInPath().path
      }
    }
    if let openProject {
      let openThread = projectHistoryManager.flatMap { projectHistoryManager in
        listedThreads.first {
          $0.projectPath == openProject.path && $0.threadId == projectHistoryManager.threadId
        }
      }
      // A new thread, or one past the first 20 of its project, isn't listed; select its project.
      let selectedItem: ItemViewModel.ItemIdentifier =
        openThread.map { .identifier($0) } ?? .identifier(openProject.path)
      DispatchQueue.main.async {
        projectSelectWorkflow.selectItem(at: selectedItem)
      }
    }
  }

  func projectBarControllerDidTapNewChat(_ controller: ProjectBarController) {
    handleKeyboardShortcut(.newChat)
  }
}

extension ChatWorkflow: ChatInputControllerDelegate {
  func chatInputController(
    _ controller: ChatInputController, currentText: String, shouldChangeTextIn range: NSRange,
    replacementText text: String
  ) {
    if textHistoryManager.currentPositiveText != currentText {
      textHistoryManager.pushChange(
        range: NSRange(
          location: 0, length: textHistoryManager.currentPositiveText.utf16.count),
        replacementText: currentText, textType: .positiveText)
    }
    let currentTextLength = (currentText as NSString).length
    guard
      range.location >= 0 && range.length >= 0 && range.location <= currentTextLength
        && range.length <= currentTextLength - range.location
    else {
      updateTextHistoryPointers()
      return
    }
    textHistoryManager.pushChange(range: range, replacementText: text, textType: .positiveText)
    updateTextHistoryPointers()
  }

  func chatInputController(
    _ controller: ChatInputController, didTapModelSelector sourceView: UIView
  ) {
    didTapModelSelector(sourceView: sourceView, permittedArrowDirections: .down)
  }

  func chatInputControllerDidBeginEditing(_ controller: ChatInputController) {
  }

  func chatInputControllerDidEndEditing(_ controller: ChatInputController) {
  }

  func chatInputController(_ controller: ChatInputController, didRequestHistorySeek edits: Int) {
    textHistoryManager.seek(to: edits)
    controller.setText(textHistoryManager.currentPositiveText)
    updateTextHistoryPointers()
  }

  private func setTextToEmpty() {
    // Reset the text history.
    let _ = textHistoryManager.seek(to: 0, lineage: 0)
    textHistoryManager.pushChange(
      range: NSRange(location: 0, length: 0), replacementText: "", textType: .positiveText)
    textHistoryManager.saveCursor()
    chatInputController.setText("")
    chatInputController.removeAllAttachments()
    updateTextHistoryPointers()
  }

  private func continueIncompleteResponse() {
    guard chatInputController.sendState == .idle,
      let projectHistoryManager,
      let projectWorkspace,
      let projectURL,
      let thread = projectHistoryManager.thread(id: projectHistoryManager.threadId),
      thread.hasIncompleteResponse,
      case .some(.local(let textGenerator, let codeAgent)) = codeAgentWrapper,
      let codeAgent,
      let suspendedResult = codeAgent.suspendedResult
    else { return }
    let file = URL(fileURLWithPath: textGenerator.filePath).lastPathComponent
    // Like a new turn, continuing downloads a model whose files were removed.
    if let specification = LLMZoo.specificationForModel(file),
      !LLMZoo.isModelDownloaded(specification)
    {
      let threadId = thread.id
      downloadLLMModel(specification) { [weak self] success in
        guard let self, success, self.projectHistoryManager === projectHistoryManager,
          self.projectHistoryManager?.threadId == threadId
        else { return }
        self.continueIncompleteResponse()
      }
      return
    }
    agentSchedulerActivation(for: file)
    guard agentScheduler.file == file else { return }
    if agentScheduler.textGenerator == nil {
      agentScheduler.textGenerator = textGenerator
    }
    let startTime = CACurrentMediaTime()
    agentScheduler.setForeground(codeAgent)
    chatInputController.sendState = .sending
    lastPartialResultRendered = 0
    updatePartialResult(
      suspendedResult, startTime: startTime, bashUserInteraction: codeAgent.bashUserInteraction,
      statistics: codeAgent.statistics, codeAgent: codeAgent)
    scheduleLocalTurn(
      codeAgent: codeAgent, safeTokenizer: textGenerator.safeTokenizer, prompt: nil,
      threadId: thread.id,
      projectURL: projectURL, projectWorkspace: projectWorkspace,
      projectHistoryManager: projectHistoryManager, startTime: startTime)
  }

  /// A steer that stopped the turn before any output resends the stopped message, with the images
  /// it was sent with, joined with the steered items in place of its node.
  func continueWithQueuedItems(
    resending stoppedMessage: (prompt: String, imagePaths: [String])? = nil
  ) {
    // A turn the user stopped, by stop or steer, ends while stopping; one that finished on its
    // own is still sending.
    let isStopping = chatInputController.sendState == .stopping
    chatInputController.sendState = .idle
    if let didStopHandler = self.didStopHandler {
      self.didStopHandler = nil
      didStopHandler()
      return
    }
    guard let projectWorkspace, let projectHistoryManager else { return }
    var queuedItems = Array(
      projectWorkspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == projectHistoryManager.threadId,
        orderBy: [ProjectQueuedItem.datetime.ascending]))
    // Steered items go out together in queue order; the rest stay queued behind them.
    let steeringQueuedItems =
      projectURL.flatMap {
        self.steeringQueuedItems[
          ProjectThreadIdentifier(projectURL: $0, threadId: projectHistoryManager.threadId)]
      } ?? []
    let steeredItems = queuedItems.filter { steeringQueuedItems.contains($0) }
    if !steeredItems.isEmpty {
      queuedItems = steeredItems
    }
    guard !queuedItems.isEmpty else { return }
    defer {
      projectWorkspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
        let deletionRequests = queuedItems.compactMap {
          ProjectQueuedItemChangeRequest.deletionRequest($0)
        }
        for deletionRequest in deletionRequests {
          transactionContext.try(submit: deletionRequest)
        }
      }
    }
    let isRestoringUserNode = restoredUserNode != nil && steeredItems.isEmpty
    // Stopping without a steer hands the queue back to the input instead of sending it.
    let isRestoringQueue = isStopping && steeredItems.isEmpty
    let draft = chatInputController.text
    var prompts = queuedItems.compactMap(\.text)
    var imagePaths = queuedItems.flatMap(\.imagePaths)
    if let stoppedMessage, !steeredItems.isEmpty {
      prompts.insert(stoppedMessage.prompt, at: 0)
      imagePaths.insert(contentsOf: stoppedMessage.imagePaths, at: 0)
    } else if isRestoringUserNode {
      let restoredPrompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      if !restoredPrompt.isEmpty {
        prompts.insert(restoredPrompt, at: 0)
      }
    } else if isRestoringQueue {
      let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      if !draft.isEmpty {
        prompts.append(draft)
      }
    }
    let prompt = prompts.joined(separator: "\n\n")
    if isRestoringUserNode || isRestoringQueue {
      // Queued attachments are already in the project; restore their cards from each message.
      let sections = prompts.map(ChatAttachment.parseSections)
      let text = sections.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
      let paths = sections.flatMap(\.paths)
      if textHistoryManager.currentPositiveText != text {
        textHistoryManager.pushChange(
          range: NSRange(
            location: 0, length: textHistoryManager.currentPositiveText.utf16.count),
          replacementText: text, textType: .positiveText)
      }
      chatInputController.setText(textHistoryManager.currentPositiveText)
      if let projectURL {
        chatInputController.addAttachments(
          projectFiles: paths.map { projectURL.appendingPathComponent($0) })
      }
      updateTextHistoryPointers()
      return
    }
    if textHistoryManager.currentPositiveText != prompt {
      textHistoryManager.pushChange(
        range: NSRange(
          location: 0, length: textHistoryManager.currentPositiveText.utf16.count),
        replacementText: prompt, textType: .positiveText)
    }
    didTapSend(prompt, imagePaths: imagePaths)
    if textHistoryManager.currentPositiveText != draft {
      textHistoryManager.pushChange(
        range: NSRange(
          location: 0, length: textHistoryManager.currentPositiveText.utf16.count),
        replacementText: draft, textType: .positiveText)
      updateTextHistoryPointers()
    }
  }

  func chatInputController(
    _ controller: ChatInputController, present viewController: UIViewController
  ) {
    self.presentedViewController.present(viewController, animated: true)
  }

  func chatInputControllerDidTapSend(_ controller: ChatInputController) {
    guard codeAgentWrapper != nil, !controller.isImportingAttachments else { return }
    var prompt = controller.text.trimmingCharacters(in: .whitespacesAndNewlines)
    var imagePaths = [String]()
    if let projectURL, !controller.attachments.isEmpty {
      // Copy into the project so the agent can open attachments by name. Sending the same draft
      // again (after provider setup, for example) reuses the identical copies.
      do {
        let paths = try ChatAttachment.copy(controller.attachments, into: projectURL)
        prompt = ChatAttachment.emitSections(prompt, paths: paths)
        // Models also see attached images directly; other files stay links.
        imagePaths = paths.filter {
          UTType(filenameExtension: ($0 as NSString).pathExtension)?.conforms(to: .image) == true
        }
      } catch {
        let alertController = UIAlertController(
          title: LocalizedString.forKey("attachments"),
          message: LocalizedString.format(
            key: "attachment_copy_failed_detail", error.localizedDescription),
          preferredStyle: .alert)
        alertController.addAction(
          UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
        presentedViewController.present(alertController, animated: true)
        return
      }
    }
    if case .some(.remote(let remoteChatProvider)) = codeAgentWrapper,
      remoteChatProvider.profile == nil
    {
      didTapSend(prompt)
      return
    }
    if case .some(.local) = codeAgentWrapper, let file = selectedLLM,
      let specification = LLMZoo.specificationForModel(file),
      !LLMZoo.isModelDownloaded(specification)
    {
      // Keep the draft editable while downloading, including after cancellation or failure.
      didTapSend(prompt, imagePaths: imagePaths)
      return
    }
    didTapSend(prompt, imagePaths: imagePaths)
    setTextToEmpty()
  }

  /// Image paths are relative to the project.
  private func didTapSend(_ prompt: String, imagePaths: [String] = []) {
    guard !prompt.isEmpty else { return }
    if let projectURL, let threadId = projectHistoryManager?.threadId {
      transientErrorMessages[
        ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)] = nil
    }
    let hasIncompleteResponse =
      projectHistoryManager.flatMap { $0.thread(id: $0.threadId) }?.hasIncompleteResponse == true
    if chatInputController.sendState != .idle || hasIncompleteResponse {
      guard let projectWorkspace, let projectHistoryManager,
        projectHistoryManager.threadId >= 0
      else { return }
      let wallClock = Int64(Date().timeIntervalSince1970 * 1_000)
      let datetime = max(wallClock, (queuedItems.last?.datetime ?? -1) + 1)
      let queuedItem = ProjectQueuedItem(
        threadId: projectHistoryManager.threadId, datetime: datetime, text: prompt,
        imagePaths: imagePaths)
      projectWorkspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
        transactionContext.try(submit: ProjectQueuedItemChangeRequest.upsertRequest(queuedItem))
      } completionHandler: { [weak self, weak projectWorkspace] success in
        guard success, hasIncompleteResponse else { return }
        DispatchQueue.main.async {
          guard let self, self.projectWorkspace === projectWorkspace,
            self.projectHistoryManager?.threadId == queuedItem.threadId
          else { return }
          self.continueIncompleteResponse()
        }
      }
      return
    }
    switch codeAgentWrapper {
    case .some(.remote):
      didTapSendRemote(prompt, imagePaths: imagePaths)
    case .some(.local):
      didTapSendLocal(prompt, imagePaths: imagePaths, viewController: viewController)
    case nil:
      return
    }
  }

  private func didTapSendLocal(
    _ prompt: String, imagePaths: [String], viewController: any ChatViewControllable
  ) {
    guard let file = selectedLLM,
      let specification = LLMZoo.specificationForModel(file)
    else { return }
    guard LLMZoo.isModelDownloaded(specification) else {
      let projectHistoryManager = self.projectHistoryManager
      let threadId = projectHistoryManager?.threadId
      let draft = chatInputController.text
      downloadLLMModel(specification) { [weak self] success in
        guard let self, success, self.chatInputController.sendState == .idle,
          self.selectedLLM == file, case .some(.local) = self.codeAgentWrapper,
          self.projectHistoryManager === projectHistoryManager,
          self.projectHistoryManager?.threadId == threadId,
          self.chatInputController.text == draft
        else { return }
        self.didTapSend(prompt, imagePaths: imagePaths)
        self.setTextToEmpty()
      }
      return
    }
    guard let projectHistoryManager, let projectWorkspace, let projectURL else { return }
    var prefixTokens = [Int32]()
    var prefixEmbedSpans = [EmbedSpan]()
    if projectHistoryManager.threadId >= 0 {
      guard let thread = projectHistoryManager.thread(id: projectHistoryManager.threadId) else {
        return
      }
      if thread.model != file {
        let history = projectHistoryManager.history(threadId: projectHistoryManager.threadId)
        guard
          let convertedHistory = convertedHistoryForLocalModel(
            history, sourceModel: thread.model ?? file, targetModel: file)
        else { return }
        (prefixTokens, prefixEmbedSpans) = ProjectHistoryManager.context(history: convertedHistory)
        let historyIsUnchanged = convertedHistory.elementsEqual(
          history,
          by: { lhs, rhs in
            lhs.threadId == rhs.threadId && lhs.datetime == rhs.datetime
              && lhs.logTokens == rhs.logTokens && lhs.embedSpans == rhs.embedSpans
              && lhs.tokens == rhs.tokens
              && lhs.plaintext == rhs.plaintext && lhs.logPlaintext == rhs.logPlaintext
          })
        let didUpdateHistory =
          historyIsUnchanged
          ? projectHistoryManager.updateThreadModel(
            id: projectHistoryManager.threadId, model: file)
          : projectHistoryManager.rewriteHistory(
            threadId: projectHistoryManager.threadId, nodes: convertedHistory, model: file)
        guard didUpdateHistory else { return }
      } else {
        (prefixTokens, prefixEmbedSpans) = projectHistoryManager.context(
          threadId: projectHistoryManager.threadId)
      }
    }
    guard case .some(.local(let selectedTextGenerator, let existingCodeAgent)) = codeAgentWrapper,
      URL(fileURLWithPath: selectedTextGenerator.filePath).lastPathComponent == file
    else { return }
    let textGenerator: any TextGenerator
    let codeAgent: any CodeAgent
    if let existingCodeAgent, agentScheduler.file == file {
      textGenerator = selectedTextGenerator
      codeAgent = existingCodeAgent
    } else {
      agentSchedulerActivation(for: file)
      guard
        let newWrapper = codeAgentWrapper(
          model: file, prefixTokens: prefixTokens, prefixEmbedSpans: prefixEmbedSpans,
          history: projectHistoryManager.history(threadId: projectHistoryManager.threadId),
          fromSuspension: false),
        case .local(let newTextGenerator, let newCodeAgent) = newWrapper,
        let newCodeAgent
      else { return }
      codeAgentWrapper = newWrapper
      textGenerator = newTextGenerator
      codeAgent = newCodeAgent
    }
    if agentScheduler.textGenerator == nil {
      agentScheduler.textGenerator = textGenerator
    }
    let startTime = CACurrentMediaTime()
    let (_, userTokens, _, _, _) = textGenerator.safeTokenizer.tokenize(
      text: prompt, truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    let textEdits = textHistoryManager.currentEdits
    let textLineage = textHistoryManager.lineage
    let threadId: Int64
    let userDatetime: Int64
    if projectHistoryManager.threadId == -1 {
      let title =
        prompt.components(separatedBy: .newlines).first {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? prompt
      let thread = projectHistoryManager.createThread(
        title: title, model: file, userTokens: userTokens, textEdits: textEdits,
        textLineage: textLineage, imagePaths: imagePaths, lastMessage: prompt)
      projectHistoryManager.threadId = thread.id
      observeQueuedItems(threadId: thread.id)
      threadId = thread.id
      userDatetime = thread.updatedAt
    } else {
      threadId = projectHistoryManager.threadId
      let userNode: ProjectHistoryNode?
      if let restoredUserNode, restoredUserNode.threadId == threadId {
        userNode = projectHistoryManager.replaceUser(
          threadId: threadId, datetime: restoredUserNode.datetime, tokens: userTokens,
          textEdits: textEdits, textLineage: textLineage, imagePaths: imagePaths,
          lastMessage: prompt)
      } else {
        userNode = projectHistoryManager.appendUser(
          threadId: threadId, tokens: userTokens, textEdits: textEdits,
          textLineage: textLineage, imagePaths: imagePaths, lastMessage: prompt)
      }
      guard let userNode else {
        restoreSelectedThread()
        return
      }
      userDatetime = userNode.datetime
    }
    restoredUserNode = nil
    viewController.appendUser(
      prompt, datetime: Date(timeIntervalSince1970: Double(userDatetime) / 1_000))
    viewController.appendAssistant(
      "", isTransient: true,
      mode: .bringup(startTime: startTime))
    let agentPrompt = skillCatalog.prompt(for: prompt)
    agentScheduler.setForeground(codeAgent)
    chatInputController.sendState = .sending
    scheduleLocalTurn(
      codeAgent: codeAgent, safeTokenizer: textGenerator.safeTokenizer, prompt: agentPrompt,
      imagePaths: imagePaths, threadId: threadId,
      projectURL: projectURL, projectWorkspace: projectWorkspace,
      projectHistoryManager: projectHistoryManager, startTime: startTime)
  }

  private func scheduleLocalTurn(
    codeAgent: any CodeAgent, safeTokenizer: TiktokenTokenizer, prompt: String?,
    imagePaths: [String] = [], threadId: Int64,
    projectURL: URL, projectWorkspace: SQLiteWorkspace,
    projectHistoryManager: ProjectHistoryManager, startTime: CFTimeInterval
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    threadNotifications.requestAuthorizationIfNeeded()
    let scheduler = agentScheduler
    let projectPath = projectURL.path
    let workspacePath = settingsWorkflow.workspaceFolderURL.path
    let webSearchIdentifier =
      workspace.dictionary["web_search_identifier", String.self] ?? "duckduckgo"
    let webSearchProvider =
      WebSearchProvider(
        identifier: webSearchIdentifier,
        apiKey: workspace.dictionary["\(webSearchIdentifier)_api_key", String.self] ?? "")
      ?? .duckDuckGo
    let progress: (CodeAgentProgress, CodeAgentStatistics) -> Void = {
      [weak self, weak scheduler] partialResult, statistics in
      let bashUserInteraction = codeAgent.bashUserInteraction
      DispatchQueue.main.async {
        guard let self, let scheduler,
          self.isDisplayed(
            codeAgent: codeAgent, scheduler: scheduler, projectPath: projectPath,
            threadId: threadId)
        else { return }
        self.renderLocalProgress(
          partialResult, startTime: startTime, bashUserInteraction: bashUserInteraction,
          statistics: statistics,
          codeAgent: codeAgent, projectPath: projectPath)
      }
    }
    let completion: (CodeAgentResult, AgentScheduler.CompletionReason) -> Void = {
      [weak self, weak scheduler] result, reason in
      guard !result.isEmpty else {
        DispatchQueue.main.async {
          guard let scheduler else { return }
          if projectHistoryManager.setThreadHasIncompleteResponse(
            id: threadId, hasIncompleteResponse: false)
          {
            if let thread = projectHistoryManager.thread(id: threadId) {
              self?.settingsWorkflow.setInactiveProjectThread(thread, projectPath: projectPath)
            }
          }
          // A steer that stopped the turn before any output keeps the stopped message out of the
          // input; it goes out again with the steered items, displayed or not.
          let isSteering =
            self?.steeringQueuedItems[
              ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)]?.isEmpty == false
          var history = projectHistoryManager.history(threadId: threadId)
          var stoppedNode: ProjectHistoryNode?
          if isSteering, let index = history.lastIndex(where: { $0.role != .memory }),
            case let node = history[index], node.role == .user
          {
            stoppedNode = node
            history.remove(at: index)
          }
          if let self,
            self.isDisplayed(
              codeAgent: codeAgent, scheduler: scheduler, projectPath: projectPath,
              threadId: threadId)
          {
            if isSteering {
              if let stoppedNode {
                self.restoredUserNode = (
                  threadId: stoppedNode.threadId, datetime: stoppedNode.datetime
                )
              }
              self.viewController.setHistory(self.historyMessages(from: history))
              self.continueWithQueuedItems(
                resending: stoppedNode.map {
                  (
                    prompt: $0.plaintext ?? safeTokenizer.decode($0.tokens),
                    imagePaths: $0.imagePaths
                  )
                })
            } else {
              self.restoreSelectedThread()
              self.chatInputController.sendState = .idle
              if let didStopHandler = self.didStopHandler {
                self.didStopHandler = nil
                didStopHandler()
              }
            }
          } else if let self, isSteering, self.agentScheduler === scheduler {
            _ = self.continueBackgroundQueuedItems(
              codeAgent: codeAgent, safeTokenizer: safeTokenizer, threadId: threadId,
              projectURL: projectURL, projectWorkspace: projectWorkspace,
              projectHistoryManager: projectHistoryManager, resending: stoppedNode)
          }
          if !scheduler.hasActiveTurn(codeAgent) {
            scheduler.markAsCompleted(codeAgent)
          }
        }
        return
      }
      let response = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      let toolCallContext = result.toolCallHistory.compactMap {
        ToolsRegistry.parse(
          $0.request, projectPath: projectPath, workspacePath: workspacePath
        )?.subtitle(for: .past)
      }.joined(separator: "\n")
      let displayText =
        [toolCallContext, response].filter { !$0.isEmpty }.joined(separator: "\n---\n")
      let statistics = codeAgent.statistics
      let duration =
        CACurrentMediaTime() - startTime
        - codeAgent.bashUserInteraction.userInteractionInterval(since: startTime)
      DispatchQueue.main.async {
        guard let self, let scheduler else { return }
        defer { self.openPendingNotificationThread() }
        let isDisplayed = self.isDisplayed(
          codeAgent: codeAgent, scheduler: scheduler, projectPath: projectPath,
          threadId: threadId)
        guard
          let node = projectHistoryManager.appendAssistant(
            threadId: threadId, logTokens: result.logTokens, embedSpans: result.embedSpans,
            tokens: result.outputTokens,
            toolCalls: result.toolCallHistory.map { toolCall in
              .init(
                function: toolCall.request.function,
                parameters: toolCall.request.parameters.sorted { $0.key < $1.key }.map {
                  ToolCallParameter(name: $0.key, value: $0.value.value)
                }, reason: toolCall.reason)
            }, duration: duration, compacted: result.compacted,
            incrementTurnCountSinceLastReview: reason == .finished,
            memoryContext: result.memoryContext,
            systemSeenMemoryContext: result.systemSeenMemoryContext, lastMessage: response)
        else {
          if projectHistoryManager.setThreadHasIncompleteResponse(
            id: threadId, hasIncompleteResponse: false)
          {
            if let thread = projectHistoryManager.thread(id: threadId) {
              self.settingsWorkflow.setInactiveProjectThread(thread, projectPath: projectPath)
            }
          }
          if isDisplayed {
            self.restoreSelectedThread()
            self.chatInputController.sendState = .idle
            if let didStopHandler = self.didStopHandler {
              self.didStopHandler = nil
              didStopHandler()
            }
          }
          scheduler.markAsCompleted(codeAgent)
          return
        }
        if projectHistoryManager.setThreadHasIncompleteResponse(
          id: threadId, hasIncompleteResponse: false)
        {
          if let thread = projectHistoryManager.thread(id: threadId) {
            self.settingsWorkflow.setInactiveProjectThread(thread, projectPath: projectPath)
          }
        }
        if isDisplayed {
          self.viewController.setLastMessage(
            displayText, thinking: "", output: "",
            datetime: Date(timeIntervalSince1970: Double(node.datetime) / 1_000),
            duration: duration, isTransient: false, mode: .none)
          self.settingsWorkflow.setPrefillTokensPerSecond(
            statistics.prefillTokensPerSecond,
            tokenGeneratedPerSecond: statistics.tokenGeneratedPerSecond)
          self.settingsWorkflow.setContextUsed(
            statistics.contextUsedTokens,
            contextWindowTokens: statistics.contextWindowTokens)
          self.continueWithQueuedItems()
          if !scheduler.hasActiveTurn(codeAgent) {
            if reason == .finished {
              self.notifyThreadCompletion(
                projectURL: projectURL, threadId: threadId,
                projectHistoryManager: projectHistoryManager, duration: duration)
              if self.scheduleMemoryReview(
                codeAgent: codeAgent, safeTokenizer: safeTokenizer, scheduler: scheduler,
                threadId: threadId, projectURL: projectURL, projectWorkspace: projectWorkspace,
                projectHistoryManager: projectHistoryManager, workspacePath: workspacePath)
              {
                return
              }
            }
            scheduler.markAsCompleted(codeAgent)
          }
        } else {
          // A stopped thread keeps its queue, unless the stop was a steer; reopening it restores
          // the queue to the input.
          let isSteering =
            self.steeringQueuedItems[
              ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)]?.isEmpty == false
          let didScheduleQueuedItems =
            self.agentScheduler === scheduler && (reason == .finished || isSteering)
            && self.continueBackgroundQueuedItems(
              codeAgent: codeAgent, safeTokenizer: safeTokenizer,
              threadId: threadId, projectURL: projectURL,
              projectWorkspace: projectWorkspace,
              projectHistoryManager: projectHistoryManager)
          if !didScheduleQueuedItems {
            if reason == .finished {
              self.notifyThreadCompletion(
                projectURL: projectURL, threadId: threadId,
                projectHistoryManager: projectHistoryManager, duration: duration)
            }
            if projectHistoryManager.setThreadHasUnreadResponse(
              id: threadId, hasUnreadResponse: true)
            {
              if let thread = projectHistoryManager.thread(id: threadId) {
                self.settingsWorkflow.setInactiveProjectThread(thread, projectPath: projectPath)
              }
            }
            if reason == .finished,
              self.scheduleMemoryReview(
                codeAgent: codeAgent, safeTokenizer: safeTokenizer, scheduler: scheduler,
                threadId: threadId, projectURL: projectURL, projectWorkspace: projectWorkspace,
                projectHistoryManager: projectHistoryManager, workspacePath: workspacePath)
            {
              return
            }
            scheduler.markAsCompleted(codeAgent)
          }
        }
      }
    }
    if let file = scheduler.file {
      Self.warmedUpModels.insert(LLMZoo.filePathForModelDownloaded(file))
    }
    // Cancel synchronously, before submitting work; the delegate's UI notification is deferred.
    modelIdleTimer?.setIdle(false)
    if let prompt {
      let isMemoryEnabled = workspace.dictionary["is_memory_enabled", Bool.self] ?? true
      scheduler.ask(
        codeAgent, threadId: threadId, prompt, imagePaths: imagePaths,
        isMemoryEnabled: isMemoryEnabled,
        allowedTools: isMemoryEnabled
          ? nil : Set(ToolsRegistry.Tool.allCases.filter { $0 != .memory }),
        projectPath: projectPath,
        projectWorkspace: projectWorkspace, workspacePath: workspacePath,
        webSearchProvider: webSearchProvider, progress: progress, completion: completion)
    } else {
      scheduler.resume(
        codeAgent, threadId: threadId, projectPath: projectPath,
        projectWorkspace: projectWorkspace, workspacePath: workspacePath,
        webSearchProvider: webSearchProvider, progress: progress, completion: completion)
    }
    if projectHistoryManager.setThreadHasIncompleteResponse(
      id: threadId, hasIncompleteResponse: true)
    {
      // `ask` / `resume` synchronously registers the active turn before the persisted flag can
      // update the thread list. Defer the inactive-project mirror behind that scheduler update so
      // the UI transitions directly to in-progress instead of briefly showing incomplete.
      DispatchQueue.main.async { [weak self] in
        if let thread = projectHistoryManager.thread(id: threadId) {
          self?.settingsWorkflow.setInactiveProjectThread(thread, projectPath: projectPath)
        }
      }
    }
    if isProjectSecurityScopedResourceAccessing,
      self.projectURL?.standardizedFileURL.resolvingSymlinksInPath().path
        == projectURL.standardizedFileURL.resolvingSymlinksInPath().path
    {
      scheduler.adoptSecurityScopedProjectAccess(
        for: codeAgent, projectURL: projectURL, didStartAccessing: true)
      isProjectSecurityScopedResourceAccessing = false
    }
  }

  private func isDisplayed(
    codeAgent: any CodeAgent, scheduler: AgentScheduler, projectPath: String, threadId: Int64
  ) -> Bool {
    guard agentScheduler === scheduler, scheduler.isForeground(codeAgent),
      projectHistoryManager?.threadId == threadId,
      projectURL?.standardizedFileURL.resolvingSymlinksInPath().path
        == URL(fileURLWithPath: projectPath, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath().path,
      case .some(.local(_, let displayedCodeAgent)) = codeAgentWrapper,
      let displayedCodeAgent
    else { return false }
    return ObjectIdentifier(displayedCodeAgent) == ObjectIdentifier(codeAgent)
  }

  private func scheduleMemoryReview(
    codeAgent: any CodeAgent, safeTokenizer: TiktokenTokenizer, scheduler: AgentScheduler,
    threadId: Int64, projectURL: URL, projectWorkspace: SQLiteWorkspace,
    projectHistoryManager: ProjectHistoryManager, workspacePath: String
  ) -> Bool {
    let projectPath = projectURL.path
    let isMemoryEnabled = workspace.dictionary["is_memory_enabled", Bool.self] ?? true
    guard agentScheduler === scheduler, isMemoryEnabled,
      (projectHistoryManager.thread(id: threadId)?.turnCountSinceLastReview ?? 0)
        >= ProjectMemory.memoryReviewInterval,
      !scheduler.hasActiveTurn(codeAgent)
    else { return false }
    let startTime = CACurrentMediaTime()
    if isDisplayed(
      codeAgent: codeAgent, scheduler: scheduler, projectPath: projectPath, threadId: threadId)
    {
      chatInputController.sendState = .sending
      lastPartialResultRendered = 0
      viewController.appendAssistant(
        LocalizedString.forKey("reviewing_memory_dot"), isTransient: true,
        mode: .bringup(startTime: startTime))
    }
    activeMemoryReviews.insert(ObjectIdentifier(codeAgent))
    scheduler.ask(
      codeAgent, threadId: threadId, ProjectMemory.reviewPrompt,
      isMemoryEnabled: true,
      temporary: true, allowedTools: [.memory], projectPath: projectPath,
      projectWorkspace: projectWorkspace, workspacePath: workspacePath, webSearchProvider: .disabled
    ) { [weak self, weak scheduler] progress, _ in
      let bashUserInteraction = codeAgent.bashUserInteraction
      DispatchQueue.main.async {
        guard let self, let scheduler,
          self.isDisplayed(
            codeAgent: codeAgent, scheduler: scheduler, projectPath: projectPath, threadId: threadId
          )
        else { return }
        self.renderMemoryReviewProgress(
          progress, codeAgent: codeAgent, startTime: startTime,
          bashUserInteraction: bashUserInteraction)
      }
    } completion: { [weak self, weak scheduler] result, reason in
      let statistics = codeAgent.statistics
      DispatchQueue.main.async {
        // Review tool exchanges are discarded. Accept only actual writes whose previous
        // contents were already known to this thread; reads and no-ops create no metadata.
        var knownMemory =
          ProjectHistoryManager.memoryContext(
            history: projectHistoryManager.history(threadId: threadId)
          ).memoryContext
          ?? MemoryContext()
        var reviewedMemory: MemoryContext?
        for case let snapshot? in result.toolCallHistory.map({ $0.response?.memory }) {
          if let updated = knownMemory.replacing(snapshot, temporary: true) {
            knownMemory = updated
            reviewedMemory = updated
          }
        }
        if let reviewedMemory {
          projectHistoryManager.appendMemory(threadId: threadId, memoryContext: reviewedMemory)
        }
        guard let self else { return }
        self.activeMemoryReviews.remove(ObjectIdentifier(codeAgent))
        guard let scheduler else { return }
        let isDisplayed = self.isDisplayed(
          codeAgent: codeAgent, scheduler: scheduler, projectPath: projectPath, threadId: threadId)
        if reason == .finished, !result.isEmpty {
          projectHistoryManager.setThreadTurnCountSinceLastReview(
            id: threadId, turnCountSinceLastReview: 0)
        } else if reason == .stopped, let thread = projectHistoryManager.thread(id: threadId) {
          projectHistoryManager.setThreadTurnCountSinceLastReview(
            id: threadId, turnCountSinceLastReview: thread.turnCountSinceLastReview / 2)
        }
        if isDisplayed {
          self.viewController.removeLastTransientMessage()
          self.settingsWorkflow.setContextUsed(
            statistics.contextUsedTokens, contextWindowTokens: statistics.contextWindowTokens)
          self.continueWithQueuedItems()
          if !scheduler.hasActiveTurn(codeAgent) {
            scheduler.markAsCompleted(codeAgent)
          }
        } else {
          let didScheduleQueuedItems =
            self.agentScheduler === scheduler
            && self.continueBackgroundQueuedItems(
              codeAgent: codeAgent, safeTokenizer: safeTokenizer, threadId: threadId,
              projectURL: projectURL, projectWorkspace: projectWorkspace,
              projectHistoryManager: projectHistoryManager)
          if !didScheduleQueuedItems {
            scheduler.markAsCompleted(codeAgent)
          }
        }
        // Review feedback is display-only. Never append its prompt, result, or logTokens to history.
      }
    }
    return true
  }

  private func renderMemoryReviewProgress(
    _ progress: CodeAgentProgress, codeAgent: any CodeAgent, startTime: CFTimeInterval,
    bashUserInteraction: BashUserInteraction
  ) {
    let heading = LocalizedString.forKey("reviewing_memory_dot")
    switch progress {
    case .prefill(_, let finished, let total), .compact(_, let finished, let total):
      viewController.setLastMessage(
        heading, isTransient: true,
        mode: .reading(
          finished, total, startTime: startTime, bashUserInteraction: bashUserInteraction))
    case .generate(let result), .toolsWait(let result):
      guard CACurrentMediaTime() - lastPartialResultRendered >= Self.partialResultRenderInterval
      else { return }
      let response = ToolCallParser.removeToolCalls(
        result.output, toolCallStart: codeAgent.toolCallStart, toolCallEnd: codeAgent.toolCallEnd
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let tools = (result.toolCallHistory + result.toolCalls).compactMap {
        ToolsRegistry.parse($0.request, projectPath: projectURL?.path)?.subtitle(for: .now)
      }.joined(separator: "\n")
      let text = [tools, response].filter { !$0.isEmpty }.joined(separator: "\n\n")
      viewController.setLastMessage(
        text.isEmpty ? heading : heading + "\n---\n" + text, isTransient: true,
        mode: .working(
          result.outputTokens.count, startTime: startTime, bashUserInteraction: bashUserInteraction)
      )
      lastPartialResultRendered = CACurrentMediaTime()
    }
  }

  private func renderLocalProgress(
    _ progress: CodeAgentProgress, startTime: CFTimeInterval,
    bashUserInteraction: BashUserInteraction,
    statistics: CodeAgentStatistics, codeAgent: any CodeAgent, projectPath: String
  ) {
    guard !activeMemoryReviews.contains(ObjectIdentifier(codeAgent)) else {
      renderMemoryReviewProgress(
        progress, codeAgent: codeAgent, startTime: startTime,
        bashUserInteraction: bashUserInteraction)
      return
    }
    let workspacePath = settingsWorkflow.workspaceFolderURL.path
    switch progress {
    case .generate(let result), .toolsWait(let result):
      updatePartialResult(
        result, startTime: startTime, bashUserInteraction: bashUserInteraction,
        statistics: statistics, codeAgent: codeAgent)
      return
    case .prefill(let toolCallHistory, let finished, let total):
      let toolCallHistoryContext = toolCallHistory.compactMap {
        ToolsRegistry.parse(
          $0.request, projectPath: projectPath, workspacePath: workspacePath
        )?.subtitle(for: .past)
      }.joined(separator: "\n")
      viewController.setLastMessage(
        toolCallHistoryContext, isTransient: true,
        mode: .reading(
          finished, total, startTime: startTime, bashUserInteraction: bashUserInteraction))
    case .compact(let toolCallHistory, let finished, let total):
      let toolCallHistoryContext = toolCallHistory.compactMap {
        ToolsRegistry.parse(
          $0.request, projectPath: projectPath, workspacePath: workspacePath
        )?.subtitle(for: .past)
      }.joined(separator: "\n")
      viewController.setLastMessage(
        toolCallHistoryContext, isTransient: true,
        mode: .compacting(
          finished, total, startTime: startTime, bashUserInteraction: bashUserInteraction))
    }
    settingsWorkflow.setPrefillTokensPerSecond(
      statistics.prefillTokensPerSecond,
      tokenGeneratedPerSecond: statistics.tokenGeneratedPerSecond)
    settingsWorkflow.setContextUsed(
      statistics.contextUsedTokens,
      contextWindowTokens: statistics.contextWindowTokens)
  }

  /// A steer that stopped the turn before any output resends the stopped node, with its images,
  /// joined with the steered items in its place.
  private func continueBackgroundQueuedItems(
    codeAgent: any CodeAgent, safeTokenizer: TiktokenTokenizer, threadId: Int64,
    projectURL: URL, projectWorkspace: SQLiteWorkspace,
    projectHistoryManager: ProjectHistoryManager, resending stoppedNode: ProjectHistoryNode? = nil
  ) -> Bool {
    var queuedItems = Array(
      projectWorkspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == threadId,
        orderBy: [ProjectQueuedItem.datetime.ascending]))
    // Steered items go out together in queue order; the rest stay queued behind them.
    let threadIdentifier = ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)
    let steeringQueuedItems = self.steeringQueuedItems[threadIdentifier] ?? []
    let steeredItems = queuedItems.filter { steeringQueuedItems.contains($0) }
    if !steeredItems.isEmpty {
      queuedItems = steeredItems
    }
    var prompts = queuedItems.compactMap(\.text)
    var imagePaths = queuedItems.flatMap(\.imagePaths)
    if let stoppedNode {
      prompts.insert(stoppedNode.plaintext ?? safeTokenizer.decode(stoppedNode.tokens), at: 0)
      imagePaths.insert(contentsOf: stoppedNode.imagePaths, at: 0)
    }
    let prompt = prompts.joined(separator: "\n\n")
    guard !prompt.isEmpty else { return false }
    let (_, userTokens, _, _, _) = safeTokenizer.tokenize(
      text: prompt, truncation: false, maxLength: 0, paddingToken: nil,
      addSpecialTokens: false)
    let userNode: ProjectHistoryNode?
    if let stoppedNode {
      userNode = projectHistoryManager.replaceUser(
        threadId: threadId, datetime: stoppedNode.datetime, tokens: userTokens, textEdits: -1,
        textLineage: -1, imagePaths: imagePaths, lastMessage: prompt)
    } else {
      userNode = projectHistoryManager.appendUser(
        threadId: threadId, tokens: userTokens, textEdits: -1, textLineage: -1,
        imagePaths: imagePaths, lastMessage: prompt)
    }
    guard userNode != nil else { return false }
    // No queue observer prunes a background thread's steered items; they are all sent.
    self.steeringQueuedItems[threadIdentifier] = nil
    projectWorkspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      for queuedItem in queuedItems {
        guard let request = ProjectQueuedItemChangeRequest.deletionRequest(queuedItem) else {
          continue
        }
        transactionContext.try(submit: request)
      }
    }
    let catalog = SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: Bundle.main.resourceURL?.appendingPathComponent(
          "Skills", isDirectory: true),
        projectURL: projectURL, workspaceURL: settingsWorkflow.workspaceFolderURL))
    scheduleLocalTurn(
      codeAgent: codeAgent, safeTokenizer: safeTokenizer, prompt: catalog.prompt(for: prompt),
      imagePaths: imagePaths, threadId: threadId,
      projectURL: projectURL, projectWorkspace: projectWorkspace,
      projectHistoryManager: projectHistoryManager, startTime: CACurrentMediaTime())
    return true
  }

  func chatInputControllerDidTapStop(_ controller: ChatInputController) {
    guard !didTapStopRemote(controller) else { return }
    guard controller.sendState == .sending else { return }
    guard case .some(.local(_, let codeAgent)) = codeAgentWrapper, let codeAgent else { return }
    controller.sendState = .stopping
    agentScheduler.stop(codeAgent)
  }

  private func updatePartialResult(
    _ partialResult: CodeAgentResult, startTime: CFTimeInterval,
    bashUserInteraction: BashUserInteraction,
    statistics: CodeAgentStatistics, codeAgent: any CodeAgent
  ) {
    let partialResultRenderStarted = CACurrentMediaTime()
    guard
      partialResultRenderStarted - lastPartialResultRendered >= Self.partialResultRenderInterval
    else {
      return
    }
    let projectPath = projectURL?.path
    let workspacePath = settingsWorkflow.workspaceFolderURL.path
    let thinkText = partialResult.think
    let outputText = partialResult.output
    let toolCalls = partialResult.toolCalls
    let toolCallHistory = partialResult.toolCallHistory
    let incompleteToolCall = partialResult.incompleteToolCall
    let hasIncompleteToolCall = partialResult.hasIncompleteToolCall
    let tokens = partialResult.thinkTokens.count + partialResult.outputTokens.count
    if outputText.isEmpty {
      let toolCallContext = toolCallHistory.compactMap {
        ToolsRegistry.parse(
          $0.request, projectPath: projectPath, workspacePath: workspacePath
        )?.subtitle(for: .past)
      }.joined(separator: "\n")
      viewController.setLastMessage(
        toolCallContext, thinking: Self.chainOfThoughtExcerpt(thinkText), output: "", datetime: nil,
        duration: 0,
        isTransient: true,
        mode: .thinking(tokens, startTime: startTime, bashUserInteraction: bashUserInteraction))
    } else {
      let response = ToolCallParser.removeToolCalls(
        outputText, toolCallStart: codeAgent.toolCallStart,
        toolCallEnd: codeAgent.toolCallEnd
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      let toolCallHistoryContext = toolCallHistory.compactMap {
        ToolsRegistry.parse(
          $0.request, projectPath: projectPath, workspacePath: workspacePath
        )?.subtitle(for: .past)
      }.joined(separator: "\n")
      if !toolCalls.isEmpty || hasIncompleteToolCall {
        var renderingToolCalls = toolCalls
        if let incompleteToolCall {
          renderingToolCalls.append(incompleteToolCall)
        }
        let toolCallContext = renderingToolCalls.compactMap {
          ToolsRegistry.parse(
            $0.request, projectPath: projectPath, workspacePath: workspacePath
          )?.subtitle(for: .now)
        }.joined(separator: "\n")
        viewController.setLastMessage(
          toolCallHistoryContext, thinking: "",
          output: [response, toolCallContext].filter { !$0.isEmpty }.joined(separator: "\n---\n"),
          datetime: nil, duration: 0, isTransient: true,
          mode: .working(tokens, startTime: startTime, bashUserInteraction: bashUserInteraction))
      } else if response.isEmpty {
        viewController.setLastMessage(
          toolCallHistoryContext, isTransient: true,
          mode: .thinking(tokens, startTime: startTime, bashUserInteraction: bashUserInteraction))
      } else {
        viewController.setLastMessage(
          [toolCallHistoryContext, response].filter { !$0.isEmpty }.joined(separator: "\n---\n"),
          isTransient: false, mode: .none)
      }
    }
    settingsWorkflow.setPrefillTokensPerSecond(
      statistics.prefillTokensPerSecond,
      tokenGeneratedPerSecond: statistics.tokenGeneratedPerSecond)
    settingsWorkflow.setContextUsed(
      statistics.contextUsedTokens,
      contextWindowTokens: statistics.contextWindowTokens)
    lastPartialResultRendered = CACurrentMediaTime()
  }

  private func configureDynamicGraph() {
    queue.async {
      DynamicGraph.queueWatermark =
        DeviceCapability.isUltraPerformance ? 128 : (DeviceCapability.isHighPerformance ? 32 : 8)
      let fileManager = FileManager.default
      let urls = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
      let cacheUrl = urls.first!.appendingPathComponent("mfa_v2")
      try? fileManager.createDirectory(at: cacheUrl, withIntermediateDirectories: true)
      var pathsToRead = [String]()
      var pathToWrite = ""
      var currentFileSize = UInt64.max
      for i in 0..<10 {
        // Try 10 names, to see if the path exists or not, if it exists, put it in the pathsToRead. Also try to select path to write.
        let file = "v\(i).binary.metallib"
        let path = cacheUrl.appendingPathComponent(file).path
        if fileManager.fileExists(atPath: path),
          let attributes = try? fileManager.attributesOfItem(atPath: path),
          let fileSize = attributes[.size] as? UInt64
        {
          if fileSize < currentFileSize {
            currentFileSize = fileSize
            if !pathToWrite.isEmpty {
              pathsToRead.append(pathToWrite)
            }
            pathToWrite = path
          } else {
            pathsToRead.append(path)
          }
        } else if currentFileSize > 0 {
          currentFileSize = 0
          if !pathToWrite.isEmpty {
            pathsToRead.append(pathToWrite)
          }
          pathToWrite = path
        }
      }
      DynamicGraph.binaryArtifacts.pathsToRead = pathsToRead
      DynamicGraph.binaryArtifacts.pathToWrite = pathToWrite
    }
  }
}

// MARK: - Web browse

extension ChatWorkflow {
  func browseWeb(
    arguments: [String], directory: URL, projectURL: URL?, threadId: Int64?,
    isCancelled: @escaping () -> Bool, completion: @escaping (Result<String, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifier = ProjectThreadIdentifier(
      projectURL: projectURL ?? directory, threadId: threadId ?? -1)
    let workflow: BrowserWorkflow
    if let existing = browserWorkflows[identifier] {
      workflow = existing
    } else {
      do {
        workflow = BrowserWorkflow(
          scripts: try BrowserScripts(
            directory: Resources.appBundleURL.appendingPathComponent("Browser")),
          dataStore: browserDataStores.dataStore(
            forProjectAt: URL(fileURLWithPath: identifier.projectPath, isDirectory: true)))
      } catch {
        completion(.failure(error))
        return
      }
      workflow.delegate = self
      browserWorkflows[identifier] = workflow
    }
    let resolver = LocalPathResolver(
      projectPath: directory.path, workspacePath: settingsWorkflow.workspaceFolderURL.path,
      permittedDirectoryURLs: permittedDirectories.urls)
    workflow.execute(
      arguments: arguments,
      resolvePath: { path in resolver.resolve(path).map { ($0.url, $0.rootURL) } },
      isCancelled: isCancelled, completion: completion)
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, hasBrowserFor thread: ProjectController.Thread
  ) -> Bool {
    browserWorkflows[ProjectThreadIdentifier(thread: thread)] != nil
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didConfirmCloseBrowserFor thread: ProjectController.Thread
  ) {
    browserWorkflows.removeValue(forKey: ProjectThreadIdentifier(thread: thread))?.close()
  }

  func settingsWorkflowBrowserTabs(_ workflow: SettingsWorkflow) -> [SettingsWorkflow.BrowserTab] {
    let openChat = projectURL.flatMap { projectURL in
      projectHistoryManager.map {
        ProjectThreadIdentifier(projectURL: projectURL, threadId: $0.threadId)
      }
    }
    // A stable order: by project, then chat, then when each tab opened.
    return browserWorkflows.sorted {
      ($0.key.projectPath, $0.key.threadId) < ($1.key.projectPath, $1.key.threadId)
    }.flatMap { identifier, browserWorkflow in
      browserWorkflow.tabs.map {
        SettingsWorkflow.BrowserTab(
          id: $0.id, title: $0.title,
          projectURL: URL(fileURLWithPath: identifier.projectPath, isDirectory: true),
          threadId: identifier.threadId, isInOpenChat: identifier == openChat)
      }
    }
  }

  func settingsWorkflow(_ workflow: SettingsWorkflow, didOpenBrowserTab id: String) {
    browserWorkflows.values.first { $0.tabs.contains { $0.id == id } }?.show(tabId: id)
  }

  func settingsWorkflow(_ workflow: SettingsWorkflow, didCloseBrowserTab id: String) {
    browserWorkflows.values.first { $0.tabs.contains { $0.id == id } }?.closeTab(id: id)
  }

  func settingsWorkflow(_ workflow: SettingsWorkflow, willDeleteProjectAt url: URL) {
    for identifier in browserWorkflows.keys
    where identifier == ProjectThreadIdentifier(projectURL: url, threadId: identifier.threadId) {
      browserWorkflows.removeValue(forKey: identifier)?.close()
    }
    browserDataStores.delete(forProjectAt: url)
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, hasBrowserDataForProjectAt url: URL,
    completion: @escaping (Bool) -> Void
  ) {
    browserDataStores.hasData(forProjectAt: url, completion: completion)
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didConfirmClearBrowserDataForProjectAt url: URL
  ) {
    browserDataStores.removeData(forProjectAt: url)
  }
}

extension ChatWorkflow: BrowserWorkflowDelegate {
  func browserWorkflowPresentingViewController(_ workflow: BrowserWorkflow) -> UIViewController? {
    presentedViewController
  }

  func browserWorkflowDidChangeTabs(_ workflow: BrowserWorkflow) {
    settingsWorkflow.browserTabsDidChange()
  }
}
