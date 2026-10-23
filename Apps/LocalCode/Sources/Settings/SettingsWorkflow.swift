import Atomics
import BashToolContext
import CLICloudAuth
import Combine
import Components
import Darwin
import Dflat
import Dispatch
import EventKit
import Localization
import ModelZoo
import Photos
import ProjectHistoryManager
import RemoteAPI
import SQLiteDflat
import Tokenizer
import UIKit
import UniformTypeIdentifiers
import UserAccount
import WebSearch

protocol SettingsWorkflowDelegate: AnyObject {
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, residentProjectWorkspace projectPath: String
  ) -> SQLiteWorkspace?
  func settingsWorkflow(_ workflow: SettingsWorkflow, didSelectProjectAt url: URL)
  /// A project folder made in the projects list, once the list shows it.
  func settingsWorkflow(_ workflow: SettingsWorkflow, didCreateProjectAt url: URL)
  /// A new project's community template finished extracting into its folder.
  func settingsWorkflow(_ workflow: SettingsWorkflow, didFillProjectAt url: URL)
  /// The open project's folder leaves the workspace: moved outside the app, or about to go to the
  /// Trash from the projects list.
  func settingsWorkflowDidRemoveOpenProject(_ workflow: SettingsWorkflow)
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didSelectThread thread: ProjectController.Thread)
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didDeleteThread thread: ProjectController.Thread)
  func settingsWorkflow(_ workflow: SettingsWorkflow, willDeleteProjectAt url: URL)
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, hasBrowserDataForProjectAt url: URL,
    completion: @escaping (Bool) -> Void)
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didConfirmClearBrowserDataForProjectAt url: URL)
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, hasBrowserFor thread: ProjectController.Thread
  ) -> Bool
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didConfirmCloseBrowserFor thread: ProjectController.Thread)
  func settingsWorkflowBrowserTabs(_ workflow: SettingsWorkflow) -> [SettingsWorkflow.BrowserTab]
  func settingsWorkflow(_ workflow: SettingsWorkflow, didOpenBrowserTab id: String)
  func settingsWorkflow(_ workflow: SettingsWorkflow, didCloseBrowserTab id: String)
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didRequestSelect provider: RemoteProvider?, sourceView: UIView)
  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didRequestConfigure provider: RemoteProvider, sourceView: UIView)
  func settingsWorkflowDidUpdateHostedProvider(_ workflow: SettingsWorkflow)
  func settingsWorkflowDidRequestModelSpeed(_ workflow: SettingsWorkflow)
}

final class SettingsWorkflow: Workflow {
  private struct ThreadIdentifier: Hashable {
    let projectPath: String
    let threadId: Int64
  }

  /// An open browser tab and the chat it belongs to.
  struct BrowserTab {
    let id: String
    let title: String
    let projectURL: URL
    let threadId: Int64
    let isInOpenChat: Bool
  }

  var viewControllable: UIViewController { viewController }
  weak var delegate: SettingsWorkflowDelegate?
  /// On the phone, settings is presented over the chat; a screen edge pan drives it interactively.
  var presentInteractively = false
  var percentDrivenInteractiveTransition: UIPercentDrivenInteractiveTransition?
  final class TransitioningController: NSObject {
    weak var delegate: SettingsWorkflow?
  }

  private let workspace: SQLiteWorkspace
  private let permittedDirectories: PermittedDirectories
  private let userInterfaceIdiom: UIUserInterfaceIdiom
  private let queue: DispatchQueue
  private let projectsQueue = DispatchQueue(
    label: "com.liuliu.local-code.projects", qos: .userInitiated)
  private let containerProtectionQueue = DispatchQueue(
    label: "com.liuliu.local-code.container-protection", qos: .utility)
  private let projectsUpdateVersion = ManagedAtomic<Int>(0)
  private let viewController: SettingsViewController
  private let projectsController: ProjectController
  private let settingsSectionsController: SettingsSectionsController
  private let kitSectionsController: KitSectionsController
  private let activitiesSectionsController: ActivitiesSectionsController
  private let accountWorkflow: AccountWorkflow
  private let transitioningController = TransitioningController()
  private var isAwaitingHostedModelSignIn = false
  var isOnboardingSelected = false {
    didSet {
      if isOnboardingSelected != oldValue {
        projectsController.setThreads(
          threadsWithWelcomeThread(projectsController.threads), animated: true)
      }
      updateActiveProjectSelection()
      // Model Speed would replace the welcome walkthrough, so it waits until that closes.
      settingsSectionsController.isModelSpeedEnabled = !isOnboardingSelected
    }
  }
  private var machineSettingsWorkflow: MachineSettingsWorkflow?
  private var selectedIndexSubscription: Workspace.Subscription?
  private var recentThreadsSelectedSubscription: Workspace.Subscription?
  private var botModeSubscription: Workspace.Subscription?
  private var workspaceFolderSubscription: Workspace.Subscription?
  private var lockdownModeSubscription: Workspace.Subscription?
  private var drawThingsModelsFolderSubscription: Workspace.Subscription?
  private var permitEnabledSubscription: Workspace.Subscription?
  private var permittedDirectoriesSubscription: Workspace.Subscription?
  private var disabledPermittedDirectoriesSubscription: Workspace.Subscription?
  private var appDataDirectorySubscriptions = [Workspace.Subscription]()
  private weak var drawThingsModelsFolderPicker: UnifiedDocumentPickerController?
  private weak var appDataDirectoryPicker: UnifiedDocumentPickerController?
  private var communityTemplateWorkflow: CommunityTemplateWorkflow?
  /// The folder `appDataDirectoryPicker` asks for.
  private var requestedAppDataDirectory = AppDataDirectory.messages
  private var reasoningEffortSubscription: Workspace.Subscription?
  private var workAttitudeSubscription: Workspace.Subscription?
  private var memoryEnabledSubscription: Workspace.Subscription?
  private var thinkingBudgetSubscription: Workspace.Subscription?
  private var webSearchIdentifierSubscription: Workspace.Subscription?
  private var kagiAPIKeySubscription: Workspace.Subscription?
  private var braveAPIKeySubscription: Workspace.Subscription?
  private var remoteProviderSubscription: Workspace.Subscription?
  private var workspaceFolderWatcher: DispatchSourceFileSystemObject?
  private var projectHistoryManager: ProjectHistoryManager?
  private var projectHistoryProject: SQLiteWorkspace?
  private var projectHistoryProjectURL: URL?
  private var projectThreadSubscription: Workspace.Subscription?
  private var activeProjectThreads: [ProjectThread]?
  /// The project folder just made here, revealed once the projects list shows it.
  private var createdProjectURL: URL?
  private var inProgressThreadIdentifiers = Set<ThreadIdentifier>()
  /// Lists running shell commands in Activities again when one starts or finishes.
  private var runningJobsSubscription: AnyCancellable?

  init(
    workspace: SQLiteWorkspace,
    userInterfaceIdiom: UIUserInterfaceIdiom,
    queue: DispatchQueue,
    accountManager: AccountManager,
    accountClient: AccountClient?, permittedDirectories: PermittedDirectories
  ) {
    self.workspace = workspace
    self.permittedDirectories = permittedDirectories
    self.userInterfaceIdiom = userInterfaceIdiom
    self.queue = queue
    accountWorkflow = AccountWorkflow(
      workspace: workspace, accountManager: accountManager, client: accountClient)
    projectsController = ProjectController(userInterfaceIdiom: userInterfaceIdiom)
    // Phones only talk to remote backends; local inference is not offered there.
    settingsSectionsController = SettingsSectionsController(
      workspace: workspace, isOnDeviceAvailable: userInterfaceIdiom != .phone)
    kitSectionsController = KitSectionsController(workspace: workspace)
    activitiesSectionsController = ActivitiesSectionsController(workspace: workspace)
    viewController = SettingsViewController(
      userInterfaceIdiom: userInterfaceIdiom, projectsController: projectsController,
      settingsSectionsController: settingsSectionsController,
      kitSectionsController: kitSectionsController,
      activitiesSectionsController: activitiesSectionsController)
    viewController.delegate = self
    if userInterfaceIdiom == .phone {
      viewController.transitioningDelegate = transitioningController
      viewController.modalPresentationStyle = .custom
      transitioningController.delegate = self
    }
    projectsController.delegate = self
    settingsSectionsController.hostedAccountBalance = accountWorkflow.balance
    settingsSectionsController.isHostedAccountSignedIn = accountWorkflow.isSignedIn
    settingsSectionsController.delegate = self
    kitSectionsController.delegate = self
    activitiesSectionsController.delegate = self
    accountWorkflow.delegate = self
    runningJobsSubscription = BashJobRegistry.runningJobs.receive(on: DispatchQueue.main).sink {
      [weak self] runningJobs in
      self?.updateProcesses(runningJobs)
    }
    permitEnabledSubscription = workspace.dictionary.subscribe("is_permit_enabled", of: Bool.self) {
      [weak self] value in
      let isEnabled: Bool
      switch value {
      case .deleted: isEnabled = true
      case .initial(let value): isEnabled = value ?? true
      case .updated(let value): isEnabled = value
      }
      DispatchQueue.main.async {
        self?.kitSectionsController.isPermitEnabled = isEnabled
      }
    }
    permittedDirectoriesSubscription = workspace.dictionary.subscribe(
      "permitted_directories", of: [String: Data].self
    ) { [weak self] value in
      let bookmarks: [String: Data]
      switch value {
      case .deleted: bookmarks = [:]
      case .initial(let value): bookmarks = value ?? [:]
      case .updated(let value): bookmarks = value
      }
      DispatchQueue.main.async {
        self?.kitSectionsController.permittedDirectories = bookmarks.keys.sorted()
      }
    }
    disabledPermittedDirectoriesSubscription = workspace.dictionary.subscribe(
      "disabled_permitted_directories", of: Set<String>.self
    ) { [weak self] value in
      let disabled: Set<String>
      switch value {
      case .deleted: disabled = []
      case .initial(let value): disabled = value ?? []
      case .updated(let value): disabled = value
      }
      DispatchQueue.main.async {
        self?.kitSectionsController.disabledPermittedDirectories = disabled
      }
    }
    appDataDirectorySubscriptions = [AppDataDirectory.messages, .mail, .notes].map { directory in
      workspace.dictionary.subscribe(directory.bookmarkKey, of: Data.self) { [weak self] _ in
        DispatchQueue.main.async {
          self?.updatePermission(for: directory)
        }
      }
    }
    refreshProtectedResourcePermissions()
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
      DispatchQueue.main.async {
        self.viewController.isBotModeEnabled = isBotModeEnabled
        self.projectsController.isBotModeEnabled = isBotModeEnabled
        self.settingsSectionsController.isBotModeEnabled = isBotModeEnabled
      }
    }
    recentThreadsSelectedSubscription = workspace.dictionary.subscribe(
      "settings_recent_threads_selected", of: Bool.self
    ) { [weak self] value in
      guard let self else { return }
      let isRecentThreadsSelected: Bool
      switch value {
      case .deleted:
        isRecentThreadsSelected = false
      case .initial(let value):
        isRecentThreadsSelected = value ?? false
      case .updated(let value):
        isRecentThreadsSelected = value
      }
      DispatchQueue.main.async {
        self.viewController.setIsRecentThreadsSelected(isRecentThreadsSelected, animated: false)
        self.projectsController.isRecentThreadsSelected = isRecentThreadsSelected
      }
    }
    selectedIndexSubscription = workspace.dictionary.subscribe(
      "settings_selected_index", of: Int.self
    ) { [weak self] value in
      guard let self else { return }
      DispatchQueue.main.async {
        switch value {
        case .deleted:
          self.viewController.setSelectedIndex(0, animated: false)
        case .initial(let index):
          self.viewController.setSelectedIndex(index ?? 0, animated: false)
        case .updated(let index):
          self.viewController.setSelectedIndex(index, animated: false)
          // Thread titles may have changed since Activities last listed tabs and processes.
          if index == 3 {
            self.updateBrowserTabs()
            self.updateProcesses()
          }
        }
      }
    }
    workspaceFolderSubscription = workspace.dictionary.subscribe(
      "workspace_folder", of: Data.self
    ) { [weak self] value in
      guard let self else { return }
      DispatchQueue.main.async {
        switch value {
        case .deleted:
          self.updateWorkspaceFolder(nil)
        case .initial(let bookmarkData):
          self.updateWorkspaceFolder(bookmarkData)
        case .updated(let bookmarkData):
          self.updateWorkspaceFolder(bookmarkData)
        }
      }
    }
    lockdownModeSubscription = workspace.dictionary.subscribe("lockdown_mode", of: Bool.self) {
      [weak self] value in
      let isEnabled: Bool
      switch value {
      case .deleted: isEnabled = false
      case .initial(let value): isEnabled = value ?? false
      case .updated(let value): isEnabled = value
      }
      // The initial value converts containers created with Complete protection at launch.
      self?.containerProtectionQueue.async {
        let root = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if !ContainerProtection.setProtection(
          isEnabled ? .complete : .completeUntilFirstUserAuthentication, in: root)
        {
          print("Container protection is not fully converted; retrying at the next launch.")
        }
      }
    }
    drawThingsModelsFolderSubscription = workspace.dictionary.subscribe(
      "draw_things_external_models_folder", of: Data.self
    ) { [weak self] value in
      guard let self else { return }
      let bookmarkData: Data?
      switch value {
      case .deleted:
        bookmarkData = nil
      case .initial(let value):
        bookmarkData = value
      case .updated(let value):
        bookmarkData = value
      }
      DispatchQueue.main.async {
        var isStale = false
        self.kitSectionsController.drawThingsModelsFolder = bookmarkData.flatMap {
          try? URL(resolvingBookmarkData: $0, bookmarkDataIsStale: &isStale).path
        }
      }
    }
    reasoningEffortSubscription = workspace.dictionary.subscribe(
      "reasoning_effort", of: ReasoningEffort.self
    ) { [weak self] value in
      guard let self else { return }
      let reasoningEffort: ReasoningEffort
      switch value {
      case .deleted:
        reasoningEffort = .high
      case .initial(let value):
        reasoningEffort = value ?? .high
      case .updated(let value):
        reasoningEffort = value
      }
      DispatchQueue.main.async {
        self.settingsSectionsController.reasoningEffort = reasoningEffort
      }
    }
    workAttitudeSubscription = workspace.dictionary.subscribe(
      "work_attitude", of: WorkAttitude.self
    ) { [weak self] value in
      guard let self else { return }
      let workAttitude: WorkAttitude
      switch value {
      case .deleted:
        workAttitude = .deterministic
      case .initial(let value):
        workAttitude = value ?? .deterministic
      case .updated(let value):
        workAttitude = value
      }
      DispatchQueue.main.async {
        self.settingsSectionsController.workAttitude = workAttitude
      }
    }
    memoryEnabledSubscription = workspace.dictionary.subscribe(
      "is_memory_enabled", of: Bool.self
    ) { [weak self] value in
      guard let self else { return }
      let isMemoryEnabled: Bool
      switch value {
      case .deleted:
        isMemoryEnabled = true
      case .initial(let value):
        isMemoryEnabled = value ?? true
      case .updated(let value):
        isMemoryEnabled = value
      }
      DispatchQueue.main.async {
        self.settingsSectionsController.isMemoryEnabled = isMemoryEnabled
      }
    }
    thinkingBudgetSubscription = workspace.dictionary.subscribe(
      "thinking_budget", of: Int.self
    ) { [weak self] value in
      guard let self else { return }
      let thinkingBudget: Int
      switch value {
      case .deleted:
        thinkingBudget = 65_536
      case .initial(let value):
        thinkingBudget = value ?? 65_536
      case .updated(let value):
        thinkingBudget = value
      }
      DispatchQueue.main.async {
        self.settingsSectionsController.thinkingBudget = Int32(
          min(max(thinkingBudget, 0), 128 * 1024))
      }
    }
    webSearchIdentifierSubscription = workspace.dictionary.subscribe(
      "web_search_identifier", of: String.self
    ) { [weak self] value in
      guard let self else { return }
      let identifier: String
      switch value {
      case .deleted:
        identifier = "duckduckgo"
      case .initial(let value):
        identifier = value ?? "duckduckgo"
      case .updated(let value):
        identifier = value
      }
      let apiKey = workspace.dictionary["\(identifier)_api_key", String.self] ?? ""
      let searchProvider =
        WebSearchProvider(identifier: identifier, apiKey: apiKey) ?? .duckDuckGo
      DispatchQueue.main.async {
        self.settingsSectionsController.webSearchAPIKey = apiKey
        self.settingsSectionsController.searchProvider = searchProvider
      }
    }
    kagiAPIKeySubscription = workspace.dictionary.subscribe(
      "kagi_api_key", of: String.self
    ) { [weak self] value in
      guard let self else { return }
      let kagiAPIKey: String
      switch value {
      case .deleted:
        kagiAPIKey = ""
      case .initial(let value):
        kagiAPIKey = value ?? ""
      case .updated(let value):
        kagiAPIKey = value
      }
      let identifier =
        workspace.dictionary["web_search_identifier", String.self] ?? "duckduckgo"
      guard identifier == "kagi" else { return }
      let apiKey = kagiAPIKey
      let searchProvider =
        WebSearchProvider(identifier: identifier, apiKey: apiKey) ?? .duckDuckGo
      DispatchQueue.main.async {
        self.settingsSectionsController.webSearchAPIKey = apiKey
        self.settingsSectionsController.searchProvider = searchProvider
      }
    }
    braveAPIKeySubscription = workspace.dictionary.subscribe(
      "brave_api_key", of: String.self
    ) { [weak self] value in
      guard let self else { return }
      let braveAPIKey: String
      switch value {
      case .deleted:
        braveAPIKey = ""
      case .initial(let value):
        braveAPIKey = value ?? ""
      case .updated(let value):
        braveAPIKey = value
      }
      let identifier =
        workspace.dictionary["web_search_identifier", String.self] ?? "duckduckgo"
      guard identifier == "brave" else { return }
      let apiKey = braveAPIKey
      let searchProvider =
        WebSearchProvider(identifier: identifier, apiKey: apiKey) ?? .duckDuckGo
      DispatchQueue.main.async {
        self.settingsSectionsController.webSearchAPIKey = apiKey
        self.settingsSectionsController.searchProvider = searchProvider
      }
    }
    remoteProviderSubscription = workspace.dictionary.subscribe(
      "chat_backend", of: String.self
    ) { [weak self] value in
      guard let self else { return }
      let backend: String?
      switch value {
      case .deleted:
        backend = nil
      case .initial(let value):
        backend = value
      case .updated(let value):
        backend = value
      }
      DispatchQueue.main.async {
        self.settingsSectionsController.remoteProvider = backend.flatMap(
          RemoteProvider.init(rawValue:))
      }
    }
  }

  deinit {
    stopWatchingWorkspaceFolder()
  }

  func handle(url: URL) -> Bool {
    accountWorkflow.handle(url: url)
  }

  func presentAccount(from presenter: UIViewController, sourceView: UIView) {
    viewController.isAccountButtonSelected = true
    accountWorkflow.present(from: presenter, sourceView: sourceView)
  }

  func toolAccountProvider(from presenter: UIViewController) -> ToolAccountProvider {
    accountWorkflow.toolAccountProvider(from: presenter)
  }

  func refreshAccountBalance() {
    accountWorkflow.refreshBalance()
  }

  func presentAccountTopUp(
    from presenter: UIViewController, completion: ((AccountWorkflow.TopUpResult) -> Void)? = nil
  ) {
    accountWorkflow.presentTopUp(from: presenter, completion: completion)
  }

  func signInFromOnboarding(
    provider: AccountManager.SignInProvider, presentingViewController: UIViewController,
    sourceView: UIView
  ) {
    accountWorkflow.present(
      from: presentingViewController, sourceView: sourceView, signInProvider: provider)
  }

  private var defaultWorkspaceFolderURL: URL {
    let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    let workspaceUrl = urls.first!.appendingPathComponent("Workspace", isDirectory: true)
    try? FileManager.default.createDirectory(at: workspaceUrl, withIntermediateDirectories: true)
    return workspaceUrl
  }

  var workspaceFolderURL: URL {
    guard let bookmarkData = workspace.dictionary["workspace_folder", Data.self],
      let url = resolveWorkspaceFolderURL(from: bookmarkData)
    else { return defaultWorkspaceFolderURL }
    return url
  }

  var projects: [(path: String, title: String)] {
    projectsController.projects
  }

  /// Every project's threads as the drawer lists them, the welcome thread included.
  var projectThreads: [ProjectController.Thread] {
    projectsController.threads
  }

  private func updateActiveProjectThreads(_ projectThreads: [ProjectThread]) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let projectHistoryManager, let projectHistoryProjectURL else {
      projectsController.selectedThread = nil
      return
    }
    activeProjectThreads = projectThreads
    let listedActiveProjectThreads =
      projectThreads.map {
        // An older subscription delivery must not overwrite flags from pending writes.
        let thisThread = projectHistoryManager.cachedThread(id: $0.id) ?? $0
        return ProjectController.Thread(
          projectPath: projectHistoryProjectURL.path, threadId: $0.id, title: $0.title,
          updatedAt: $0.updatedAt, model: $0.model, lastMessage: $0.lastMessage,
          hasUnreadResponse: thisThread.hasUnreadResponse,
          hasIncompleteResponse: thisThread.hasIncompleteResponse,
          status: threadStatus(
            projectPath: projectHistoryProjectURL.path, threadId: $0.id,
            hasUnreadResponse: thisThread.hasUnreadResponse,
            hasIncompleteResponse: thisThread.hasIncompleteResponse))
      }
      + [
        ProjectController.Thread(
          projectPath: projectHistoryProjectURL.path,
          threadId: -1)
      ]
    var threads = projectsController.threads
    if let insertionIndex = threads.firstIndex(where: {
      isSameProjectURL(
        URL(fileURLWithPath: $0.projectPath, isDirectory: true), projectHistoryProjectURL)
    }) {
      threads.removeAll {
        isSameProjectURL(
          URL(fileURLWithPath: $0.projectPath, isDirectory: true), projectHistoryProjectURL)
      }
      threads.insert(contentsOf: listedActiveProjectThreads, at: insertionIndex)
      projectsController.setThreads(threadsWithWelcomeThread(threads), animated: true)
    }
    updateActiveProjectSelection()
  }

  private func updateActiveProjectSelection() {
    dispatchPrecondition(condition: .onQueue(.main))
    // Activities lists the open chat's tabs and processes first.
    defer {
      updateBrowserTabs()
      updateProcesses()
    }
    guard !isOnboardingSelected else {
      // The welcome thread is virtual and covers whichever project is open, so it is matched
      // by its identifier alone.
      projectsController.selectedThread = projectsController.threads.first {
        $0.threadId == OnboardingState.threadIdentifier
      }
      return
    }
    guard let projectHistoryManager, let projectHistoryProjectURL else {
      projectsController.selectedThread = nil
      return
    }
    let activeThreadId = projectHistoryManager.threadId
    projectsController.selectedThread = projectsController.threads.first {
      isSameProjectURL(
        URL(fileURLWithPath: $0.projectPath, isDirectory: true), projectHistoryProjectURL)
        && $0.threadId == activeThreadId
    }
  }

  func setActiveThreads(_ threads: [(projectPath: String, threadId: Int64)]) {
    dispatchPrecondition(condition: .onQueue(.main))
    let identifiers = Set(
      threads.map {
        ThreadIdentifier(
          projectPath: URL(fileURLWithPath: $0.projectPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path,
          threadId: $0.threadId)
      })
    guard identifiers != inProgressThreadIdentifiers else { return }
    inProgressThreadIdentifiers = identifiers
    let threads = projectsController.threads.map {
      // Completion updates the history manager's cache before calling `markAsCompleted`, but
      // the thread list may still hold an older subscription snapshot. Read the current flags
      // from the history manager when updating scheduler activity.
      let thisThread: ProjectThread?
      if let projectHistoryProjectURL,
        isSameProjectURL(
          URL(fileURLWithPath: $0.projectPath, isDirectory: true), projectHistoryProjectURL)
      {
        thisThread = projectHistoryManager?.cachedThread(id: $0.threadId)
      } else {
        thisThread = nil
      }
      let hasUnreadResponse = thisThread?.hasUnreadResponse ?? $0.hasUnreadResponse
      let hasIncompleteResponse = thisThread?.hasIncompleteResponse ?? $0.hasIncompleteResponse
      return ProjectController.Thread(
        projectPath: $0.projectPath, threadId: $0.threadId, title: $0.title,
        updatedAt: $0.updatedAt, model: $0.model, lastMessage: $0.lastMessage,
        hasUnreadResponse: hasUnreadResponse,
        hasIncompleteResponse: hasIncompleteResponse,
        status: threadStatus(
          projectPath: $0.projectPath, threadId: $0.threadId,
          hasUnreadResponse: hasUnreadResponse,
          hasIncompleteResponse: hasIncompleteResponse))
    }
    projectsController.setThreads(threads, animated: false)
  }

  private func threadStatus(
    projectPath: String, threadId: Int64, hasUnreadResponse: Bool,
    hasIncompleteResponse: Bool
  ) -> ProjectController.Thread.Status {
    let identifier = ThreadIdentifier(
      projectPath: URL(fileURLWithPath: projectPath, isDirectory: true)
        .standardizedFileURL.resolvingSymlinksInPath().path,
      threadId: threadId)
    if inProgressThreadIdentifiers.contains(identifier) {
      return .inProgress
    }
    if hasIncompleteResponse {
      return .incomplete
    }
    return hasUnreadResponse ? .new : .idle
  }

  /// Threads outside the open project have no subscription, so mirror their writes into the list.
  func setInactiveProjectThread(_ thread: ProjectThread, projectPath: String) {
    dispatchPrecondition(condition: .onQueue(.main))
    let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    if let projectHistoryProjectURL,
      isSameProjectURL(projectURL, projectHistoryProjectURL)
    {
      return
    }
    var threads = projectsController.threads
    guard
      let index = threads.firstIndex(where: {
        $0.threadId == thread.id
          && isSameProjectURL(
            URL(fileURLWithPath: $0.projectPath, isDirectory: true),
            projectURL)
      })
    else { return }
    let updatedThread = ProjectController.Thread(
      projectPath: threads[index].projectPath, threadId: thread.id, title: thread.title,
      updatedAt: thread.updatedAt, model: thread.model, lastMessage: thread.lastMessage,
      hasUnreadResponse: thread.hasUnreadResponse,
      hasIncompleteResponse: thread.hasIncompleteResponse,
      status: threadStatus(
        projectPath: threads[index].projectPath, threadId: thread.id,
        hasUnreadResponse: thread.hasUnreadResponse,
        hasIncompleteResponse: thread.hasIncompleteResponse))
    guard threads[index] != updatedThread else { return }
    threads[index] = updatedThread
    projectsController.setThreads(threads, animated: false)
  }

  func setRemoteContextStatus(_ status: RemoteAgentStatus?) {
    dispatchPrecondition(condition: .onQueue(.main))
    if let status {
      setContextUsed(
        status.estimatedContextTokens,
        contextWindowTokens: status.effectiveContextWindowTokens)
    } else {
      setContextUsed(0, contextWindowTokens: 0)
    }
  }

  func refreshRemoteProviderConfiguration() {
    settingsSectionsController.refreshRemoteProviderConfiguration()
  }

  func setProjectHistoryManager(
    _ projectHistoryManager: ProjectHistoryManager?, project: SQLiteWorkspace?, projectURL: URL?
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard
      self.projectHistoryManager !== projectHistoryManager
        || projectHistoryProject !== project
    else {
      projectHistoryProjectURL = projectURL
      updateActiveProjectSelection()
      return
    }
    projectThreadSubscription?.cancel()
    projectThreadSubscription = nil
    self.projectHistoryManager = projectHistoryManager
    projectHistoryProject = project
    projectHistoryProjectURL = projectURL
    activeProjectThreads = nil
    guard let projectHistoryManager, let project, projectURL != nil else {
      projectsController.selectedThread = nil
      return
    }
    let projectThreads = project.fetch(for: ProjectThread.self).all(
      orderBy: [ProjectThread.updatedAt.descending, ProjectThread.id.descending])
    updateActiveProjectThreads(Array(projectThreads))
    projectThreadSubscription = project.subscribe(fetchedResult: projectThreads) {
      [weak self, weak projectHistoryManager, weak project] projectThreads in
      DispatchQueue.main.async {
        guard let self, self.projectHistoryManager === projectHistoryManager,
          self.projectHistoryProject === project
        else { return }
        let previouslySelectedThread = self.projectsController.selectedThread
        self.updateActiveProjectThreads(Array(projectThreads))
        // Wait for the persisted update before replacing a deleted active conversation.
        guard let previouslySelectedThread, previouslySelectedThread.threadId >= 0,
          let projectHistoryProjectURL = self.projectHistoryProjectURL,
          self.isSameProjectURL(
            URL(fileURLWithPath: previouslySelectedThread.projectPath, isDirectory: true),
            projectHistoryProjectURL),
          !projectThreads.contains(where: { $0.id == previouslySelectedThread.threadId }),
          let selectedThread = self.projectsController.selectedThread
        else { return }
        self.delegate?.settingsWorkflow(self, didSelectThread: selectedThread)
      }
    }
  }

  private func resolveWorkspaceFolderURL(from bookmarkData: Data) -> URL? {
    var isStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmarkData,
        bookmarkDataIsStale: &isStale
      ),
      !isStale
    else { return nil }
    return url
  }

  private func updateWorkspaceFolder(_ bookmarkData: Data?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let bookmarkData, let url = resolveWorkspaceFolderURL(from: bookmarkData) else {
      projectsController.workspaceFolder = nil
      startWatchingWorkspaceFolder(defaultWorkspaceFolderURL)
      updateProjects()
      return
    }
    projectsController.workspaceFolder = url.path
    startWatchingWorkspaceFolder(url)
    updateProjects()
  }

  private func startWatchingWorkspaceFolder(_ url: URL) {
    dispatchPrecondition(condition: .onQueue(.main))
    stopWatchingWorkspaceFolder()
    let didStartAccessing = url.startAccessingSecurityScopedResource()
    let fileDescriptor = open(url.path, O_EVTONLY)
    guard fileDescriptor >= 0 else {
      if didStartAccessing {
        url.stopAccessingSecurityScopedResource()
      }
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fileDescriptor,
      eventMask: [.write, .rename, .delete],
      queue: .main)
    source.setEventHandler { [weak self] in
      self?.updateProjects()
    }
    source.setCancelHandler {
      close(fileDescriptor)
      if didStartAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
    workspaceFolderWatcher = source
    source.resume()
  }

  private func stopWatchingWorkspaceFolder() {
    workspaceFolderWatcher?.cancel()
    workspaceFolderWatcher = nil
  }

  private func updateProjects() {
    dispatchPrecondition(condition: .onQueue(.main))
    let updateVersion = projectsUpdateVersion.wrappingIncrementThenLoad(
      ordering: .acquiringAndReleasing)
    let workspaceFolderURL = self.workspaceFolderURL
    let activeProjectURL = projectHistoryProjectURL
    let activeThreads = activeProjectThreads
    let activeThreadId = projectHistoryManager?.threadId
    let didStartAccessing = workspaceFolderURL.startAccessingSecurityScopedResource()
    projectsQueue.async { [weak self] in
      defer {
        DispatchQueue.main.async {
          if didStartAccessing {
            workspaceFolderURL.stopAccessingSecurityScopedResource()
          }
        }
      }
      guard let self,
        self.projectsUpdateVersion.load(ordering: .acquiring) == updateVersion
      else { return }
      let folders =
        (try? FileManager.default.contentsOfDirectory(
          at: workspaceFolderURL, includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles])) ?? []
      let folderURLs: [URL] = folders.compactMap { folderURL in
        let resourceValues = try? folderURL.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues?.isDirectory == true else { return nil }
        return folderURL
      }.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
          == .orderedAscending
      }
      let projectURLs = [workspaceFolderURL] + folderURLs
      let activeProjectIndex = activeProjectURL.flatMap { activeProjectURL in
        projectURLs.firstIndex {
          self.isSameProjectURL($0, activeProjectURL)
        }
      }
      // The open project is gone once it is neither the root nor an existing folder in it. This
      // checks the folder rather than the listing, which comes back empty when listing fails.
      let isActiveProjectRemoved =
        activeProjectURL.map {
          !self.isSameProjectURL($0, workspaceFolderURL)
            && (!self.isSameProjectURL($0.deletingLastPathComponent(), workspaceFolderURL)
              || !self.isExistingProjectFolder($0))
        } ?? false
      var threadsByProject = projectURLs.map {
        [
          ProjectController.Thread(
            projectPath: $0.path,
            threadId: -1)
        ]
      }
      var selectedThread: ProjectController.Thread?
      var projectIndices = Array(projectURLs.indices)
      if let activeProjectIndex {
        projectIndices.removeAll { $0 == activeProjectIndex }
        projectIndices.insert(activeProjectIndex, at: 0)
      }
      for projectIndex in projectIndices {
        guard self.projectsUpdateVersion.load(ordering: .acquiring) == updateVersion
        else { return }
        let projectURL = projectURLs[projectIndex]
        let projectThreads: [ProjectThread]
        if projectIndex == activeProjectIndex, let activeThreads {
          projectThreads = activeThreads
        } else if let projectWorkspace = self.openExistingProjectWorkspace(at: projectURL) {
          projectThreads = Array(
            projectWorkspace.fetch(for: ProjectThread.self).all(
              orderBy: [ProjectThread.updatedAt.descending, ProjectThread.id.descending]))
          projectWorkspace.shutdown(flags: [])
        } else {
          projectThreads = []
        }
        let listedThreads =
          projectThreads.map {
            ProjectController.Thread(
              projectPath: projectURL.path, threadId: $0.id, title: $0.title,
              updatedAt: $0.updatedAt, model: $0.model, lastMessage: $0.lastMessage,
              hasUnreadResponse: $0.hasUnreadResponse,
              hasIncompleteResponse: $0.hasIncompleteResponse)
          }
          + [
            ProjectController.Thread(
              projectPath: projectURL.path,
              threadId: -1)
          ]
        threadsByProject[projectIndex] = listedThreads
        if projectIndex == activeProjectIndex, let activeThreadId {
          selectedThread = listedThreads.first {
            $0.threadId == activeThreadId
          }
        }
        guard self.projectsUpdateVersion.load(ordering: .acquiring) == updateVersion
        else { return }
        let threads = threadsByProject.flatMap { $0 }
        let selectedThread = selectedThread
        let isLastProject = projectIndex == projectIndices.last
        DispatchQueue.main.async { [weak self] in
          guard let self,
            self.projectsUpdateVersion.load(ordering: .acquiring) == updateVersion
          else { return }
          self.projectsController.setThreads(
            self.threadsWithWelcomeThread(
              threads.map {
                ProjectController.Thread(
                  projectPath: $0.projectPath, threadId: $0.threadId, title: $0.title,
                  updatedAt: $0.updatedAt, model: $0.model, lastMessage: $0.lastMessage,
                  hasUnreadResponse: $0.hasUnreadResponse,
                  hasIncompleteResponse: $0.hasIncompleteResponse,
                  status: self.threadStatus(
                    projectPath: $0.projectPath, threadId: $0.threadId,
                    hasUnreadResponse: $0.hasUnreadResponse,
                    hasIncompleteResponse: $0.hasIncompleteResponse))
              }), animated: true)
          self.projectsController.selectedThread = selectedThread
          self.updateActiveProjectSelection()
          // Acts once per update. Projects above a revealed one also still grow as their threads
          // load, which would push it out of view.
          guard isLastProject else { return }
          if isActiveProjectRemoved, let activeProjectURL,
            self.projectHistoryProjectURL.map({ self.isSameProjectURL($0, activeProjectURL) })
              ?? false
          {
            self.delegate?.settingsWorkflowDidRemoveOpenProject(self)
          }
          guard let createdProjectURL = self.createdProjectURL else { return }
          self.createdProjectURL = nil
          guard
            let projectPath = threads.first(where: {
              self.isSameProjectURL(
                URL(fileURLWithPath: $0.projectPath, isDirectory: true), createdProjectURL)
            })?.projectPath
          else { return }
          self.projectsController.scrollToProjectOnNextRunLoop(at: projectPath)
          self.delegate?.settingsWorkflow(
            self, didCreateProjectAt: URL(fileURLWithPath: projectPath, isDirectory: true))
        }
      }
    }
  }

  // The welcome thread is virtual: it is listed in the workspace project only while selected.
  private func threadsWithWelcomeThread(_ threads: [ProjectController.Thread])
    -> [ProjectController.Thread]
  {
    dispatchPrecondition(condition: .onQueue(.main))
    var threads = threads.filter { $0.threadId != OnboardingState.threadIdentifier }
    let workspaceFolderURL = self.workspaceFolderURL
    guard isOnboardingSelected,
      let index = threads.firstIndex(where: {
        isSameProjectURL(
          URL(fileURLWithPath: $0.projectPath, isDirectory: true), workspaceFolderURL)
      })
    else { return threads }
    threads.insert(
      ProjectController.Thread(
        projectPath: threads[index].projectPath, threadId: OnboardingState.threadIdentifier,
        title: LocalizedString.forKey("welcome_to_local_code")), at: index)
    return threads
  }

  private func openExistingProjectWorkspace(at projectURL: URL) -> SQLiteWorkspace? {
    let metadataURL = projectURL.appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("metadata.sqlite3", isDirectory: false)
    guard FileManager.default.fileExists(atPath: metadataURL.path) else { return nil }
    return SQLiteWorkspace(filePath: metadataURL.path, fileProtectionLevel: .noProtection)
  }

  private func resolvedSelectedProjectURL() -> URL? {
    guard let bookmarkData = workspace.dictionary["project", Data.self] else { return nil }
    guard let url = resolveProjectURL(from: bookmarkData),
      isExistingProjectFolder(url)
    else {
      workspace.dictionary["project", Data.self] = nil
      return nil
    }
    return url
  }

  private func resolveProjectURL(from bookmarkData: Data) -> URL? {
    var isStale = false
    guard
      let url = try? URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale),
      !isStale
    else { return nil }
    return url
  }

  private func isExistingProjectFolder(_ projectURL: URL) -> Bool {
    let didStartAccessing = projectURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        projectURL.stopAccessingSecurityScopedResource()
      }
    }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func isSameProjectURL(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.resolvingSymlinksInPath().path
      == rhs.standardizedFileURL.resolvingSymlinksInPath().path
  }

  private func presentCannotRenameAlert() {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("cannot_rename"),
      message: LocalizedString.forKey("cannot_rename_message"),
      preferredStyle: .alert)
    alertController.addAction(UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
    viewController.present(alertController, animated: true)
  }

  private func presentCannotCreateDirectoryAlert() {
    let alertController = UIAlertController(
      title: LocalizedString.forKey(
        self.workspace.dictionary["bot_mode", Bool.self] == true
          ? "cannot_create_bot" : "cannot_create_directory"),
      message: LocalizedString.forKey("cannot_create_directory_message"),
      preferredStyle: .alert)
    alertController.addAction(UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
    viewController.present(alertController, animated: true)
  }

  func selectProjectsTab() {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["settings_selected_index", Int.self] = 0
  }

  func selectSettingsTab() {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["settings_selected_index", Int.self] = 1
  }

  func selectKitTab() {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["settings_selected_index", Int.self] = 2
  }

  func selectActivitiesTab() {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["settings_selected_index", Int.self] = 3
  }

  /// A browser tab opened, closed, or changed; Activities lists the tabs again.
  func browserTabsDidChange() {
    dispatchPrecondition(condition: .onQueue(.main))
    updateBrowserTabs()
  }

  private func updateBrowserTabs() {
    let tabs = delegate?.settingsWorkflowBrowserTabs(self) ?? []
    activitiesSectionsController.setBrowserTabs(
      current: tabs.filter(\.isInOpenChat).map {
        SettingsBrowserTabsItem.Tab(id: $0.id, title: $0.title, threadTitle: nil)
      },
      others: tabs.filter { !$0.isInOpenChat }.map {
        SettingsBrowserTabsItem.Tab(
          id: $0.id, title: $0.title,
          threadTitle: threadTitle(projectURL: $0.projectURL, threadId: $0.threadId))
      })
  }

  /// Lists the jobs a subscription delivered, or reads the registry's current jobs without one.
  private func updateProcesses(_ runningJobs: [BashJobRegistry.RunningJob]? = nil) {
    var current = [SettingsProcessesItem.Process]()
    var others = [SettingsProcessesItem.Process]()
    // Every agent runs commands with its chat in the context; anything else has no chat to list.
    let runningJobs = runningJobs ?? BashJobRegistry.runningJobs.value
    for job in runningJobs {
      guard let projectURL = job.projectURL, let threadId = job.threadId else { continue }
      // Rows are one line; a multi-line command reads as one with its lines joined.
      let command = job.command.components(separatedBy: .newlines).map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty }.joined(separator: " ")
      if let projectHistoryManager, let projectHistoryProjectURL,
        threadId == projectHistoryManager.threadId,
        isSameProjectURL(projectURL, projectHistoryProjectURL)
      {
        current.append(
          SettingsProcessesItem.Process(id: job.id, command: command, threadTitle: nil))
      } else {
        others.append(
          SettingsProcessesItem.Process(
            id: job.id, command: command,
            threadTitle: threadTitle(projectURL: projectURL, threadId: threadId)))
      }
    }
    activitiesSectionsController.setProcesses(current: current, others: others)
  }

  /// The chat's title from the project lists, or its project's name before it has one.
  private func threadTitle(projectURL: URL, threadId: Int64) -> String {
    let identifier = ProjectThreadIdentifier(projectURL: projectURL, threadId: threadId)
    let title = projectsController.threads.first {
      $0.threadId == threadId && ProjectThreadIdentifier(thread: $0) == identifier
    }?.title
    return title.flatMap { $0.isEmpty ? nil : $0 } ?? projectURL.lastPathComponent
  }

  func presentMachineSettings() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard machineSettingsWorkflow == nil else { return }
    let machineSettingsWorkflow = MachineSettingsWorkflow(
      workspace: workspace, userInterfaceIdiom: userInterfaceIdiom, queue: queue)
    machineSettingsWorkflow.delegate = self
    viewController.present(machineSettingsWorkflow.viewControllable, animated: true) {
      machineSettingsWorkflow.didPresentMachineSettingsView()
    }
    self.machineSettingsWorkflow = machineSettingsWorkflow
  }

  /// Asks for the new project's name, then creates it, filled from the named community template
  /// when one is given.
  func presentNewProjectPrompt(templateName: String? = nil) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["settings_selected_index", Int.self] = 0
    let defaultName =
      templateName
      ?? String(format: "%@-%05d", LocalizedString.forKey("untitled"), Int.random(in: 0...99_999))
    let alertController = UIAlertController(
      title: LocalizedString.forKey(
        self.workspace.dictionary["bot_mode", Bool.self] == true ? "new_bot" : "new_directory"),
      message: nil,
      preferredStyle: .alert)
    alertController.addTextField {
      $0.placeholder = LocalizedString.forKey("name")
      $0.text = defaultName
      $0.selectedTextRange = $0.textRange(from: $0.beginningOfDocument, to: $0.endOfDocument)
    }
    let createAction = UIAlertAction(title: LocalizedString.forKey("create"), style: .default) {
      [weak self, weak alertController] _ in
      guard let self, let alertController else { return }
      self.createProjectDirectory(
        named: alertController.textFields?.first?.text, templateName: templateName)
    }
    alertController.addAction(createAction)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    alertController.preferredAction = createAction
    viewController.present(alertController, animated: true)
  }

  func presentCommunityTemplates() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard communityTemplateWorkflow == nil else { return }
    let communityTemplateWorkflow = CommunityTemplateWorkflow()
    communityTemplateWorkflow.delegate = self
    viewController.present(communityTemplateWorkflow.viewControllable, animated: true) {
      communityTemplateWorkflow.didPresentCommunityTemplateView()
    }
    self.communityTemplateWorkflow = communityTemplateWorkflow
  }

  private func renameProject(_ projectPath: String, to newName: String?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let newName = newName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !newName.isEmpty
    else { return }
    let oldURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    guard oldURL.lastPathComponent != newName else { return }
    let workspaceURL = oldURL.deletingLastPathComponent()
    let newURL = workspaceURL.appendingPathComponent(newName, isDirectory: true)
    let normalizedWorkspacePath = workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
    guard
      newURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        == normalizedWorkspacePath,
      !FileManager.default.fileExists(atPath: newURL.path)
    else {
      presentCannotRenameAlert()
      return
    }
    let selectedProjectURL = resolvedSelectedProjectURL()
    let didStartAccessing = workspaceURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        workspaceURL.stopAccessingSecurityScopedResource()
      }
    }
    do {
      try FileManager.default.moveItem(at: oldURL, to: newURL)
    } catch {
      presentCannotRenameAlert()
      return
    }
    if selectedProjectURL.map({ isSameProjectURL($0, oldURL) }) ?? false {
      delegate?.settingsWorkflow(self, didSelectProjectAt: newURL)
    }
    updateProjects()
  }

  /// Creates a project folder for each name, only in a workspace that has no folders yet, and
  /// fills it from the community template of its template name once that downloads.
  func createProjects(_ projects: [(name: String, templateName: String)]) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !projects.isEmpty else { return }
    let workspaceURL = workspaceFolderURL
    let didStartAccessing = workspaceURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        workspaceURL.stopAccessingSecurityScopedResource()
      }
    }
    let folders =
      (try? FileManager.default.contentsOfDirectory(
        at: workspaceURL, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])) ?? []
    guard
      !folders.contains(where: {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      })
    else { return }
    var createdProjects = [(url: URL, templateName: String)]()
    for project in projects {
      let url = workspaceURL.appendingPathComponent(project.name, isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      } catch {
        continue
      }
      createdProjects.append((url: url, templateName: project.templateName))
    }
    updateProjects()
    // The projects are usable right away, and stay empty if their templates can't be downloaded.
    for project in createdProjects {
      let didStartAccessing = workspaceURL.startAccessingSecurityScopedResource()
      TemplateZoo.copy(templateNamed: project.templateName, to: project.url) { [weak self] error in
        if didStartAccessing {
          workspaceURL.stopAccessingSecurityScopedResource()
        }
        guard error == nil else { return }
        DispatchQueue.main.async {
          guard let self else { return }
          self.delegate?.settingsWorkflow(self, didFillProjectAt: project.url)
        }
      }
    }
  }

  private func createProjectDirectory(named name: String?, templateName: String?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    else { return }
    let workspaceURL = workspaceFolderURL
    let newURL = workspaceURL.appendingPathComponent(name, isDirectory: true)
    let normalizedWorkspacePath =
      workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
    let didStartAccessing = workspaceURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        workspaceURL.stopAccessingSecurityScopedResource()
      }
    }
    guard
      newURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        == normalizedWorkspacePath,
      !FileManager.default.fileExists(atPath: newURL.path)
    else {
      presentCannotCreateDirectoryAlert()
      return
    }
    do {
      try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
    } catch {
      presentCannotCreateDirectoryAlert()
      return
    }
    // Recents lists no project without threads, so the new one is revealed among all projects.
    workspace.dictionary["settings_recent_threads_selected", Bool.self] = false
    createdProjectURL = newURL
    updateProjects()
    guard let templateName else { return }
    // The project is usable right away, and stays empty if its template can't be downloaded.
    let didStartAccessingTemplate = workspaceURL.startAccessingSecurityScopedResource()
    TemplateZoo.copy(templateNamed: templateName, to: newURL) { [weak self] error in
      if didStartAccessingTemplate {
        workspaceURL.stopAccessingSecurityScopedResource()
      }
      DispatchQueue.main.async {
        guard let self else { return }
        guard error != nil else {
          self.delegate?.settingsWorkflow(self, didFillProjectAt: newURL)
          return
        }
        let alertController = UIAlertController(
          title: LocalizedString.forKey("cannot_download_template"),
          message: LocalizedString.forKey("cannot_download_template_message"),
          preferredStyle: .alert)
        alertController.addAction(
          UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
        self.viewController.present(alertController, animated: true)
      }
    }
  }
}

extension SettingsWorkflow: SettingsViewControllerDelegate {
  func settingsViewController(_ viewController: SettingsViewController, didSelectIndex index: Int) {
    workspace.dictionary["settings_selected_index", Int.self] = index
  }

  func settingsViewControllerDidTapNewProject(_ viewController: SettingsViewController) {
    presentNewProjectPrompt()
  }

  func settingsViewControllerDidTapNewProjectFromTemplate(_ viewController: SettingsViewController)
  {
    presentCommunityTemplates()
  }

  func settingsViewControllerDidTapNewThread(_ viewController: SettingsViewController) {
    // Recents mixes threads from every project, so start the new thread in the open project, or
    // the workspace root when none is open, as if its "Start a new thread" row were tapped.
    let projectURL = projectHistoryProjectURL ?? workspaceFolderURL
    projectController(
      projectsController,
      didSelectThread: ProjectController.Thread(projectPath: projectURL.path, threadId: -1))
  }

  func settingsViewController(
    _ viewController: SettingsViewController, didSelectRecentThreads isRecentThreadsSelected: Bool
  ) {
    workspace.dictionary["settings_recent_threads_selected", Bool.self] = isRecentThreadsSelected
  }

  func settingsViewControllerDidTapMachineSettings(_ viewController: SettingsViewController) {
    presentMachineSettings()
  }

  func settingsViewControllerDidTapAccount(
    _ viewController: SettingsViewController, sourceView: UIView
  ) {
    accountWorkflow.present(from: viewController, sourceView: sourceView)
  }
}

extension SettingsWorkflow: ProjectControllerDelegate {
  func projectController(
    _ controller: ProjectController, didSelectThread thread: ProjectController.Thread
  ) {
    let rootURL = workspaceFolderURL
    let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }
    delegate?.settingsWorkflow(self, didSelectThread: thread)
  }

  func projectController(
    _ controller: ProjectController,
    didSelectRenameProject projectPath: String
  ) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("enter_new_name"),
      message: nil,
      preferredStyle: .alert)
    alertController.addTextField {
      $0.text = URL(fileURLWithPath: projectPath, isDirectory: true).lastPathComponent
      $0.selectedTextRange = $0.textRange(from: $0.beginningOfDocument, to: $0.endOfDocument)
    }
    let continueAction =
      UIAlertAction(title: LocalizedString.forKey("rename"), style: .default) {
        [weak self, weak alertController] _ in
        guard let self, let alertController else { return }
        self.renameProject(projectPath, to: alertController.textFields?.first?.text)
      }
    alertController.addAction(continueAction)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    alertController.preferredAction = continueAction
    viewController.present(alertController, animated: true)
  }

  func projectController(
    _ controller: ProjectController,
    didSelectRenameThread thread: ProjectController.Thread
  ) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("enter_new_name"), message: nil, preferredStyle: .alert)
    alertController.addTextField {
      $0.text = thread.title
      $0.selectedTextRange = $0.textRange(from: $0.beginningOfDocument, to: $0.endOfDocument)
    }
    let renameAction = UIAlertAction(title: LocalizedString.forKey("rename"), style: .default) {
      [weak self, weak alertController] _ in
      guard let self, let alertController,
        let title = alertController.textFields?.first?.text?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !title.isEmpty, title != thread.title
      else { return }
      let rootURL = self.workspaceFolderURL
      let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
      defer {
        if didStartAccessing {
          rootURL.stopAccessingSecurityScopedResource()
        }
      }
      let projectURL = URL(fileURLWithPath: thread.projectPath, isDirectory: true)
      let projectWorkspace: SQLiteWorkspace?
      let projectHistoryManager: ProjectHistoryManager
      let isActiveProject: Bool
      if let activeProjectHistoryManager = self.projectHistoryManager,
        let activeProjectURL = self.projectHistoryProjectURL,
        self.isSameProjectURL(projectURL, activeProjectURL)
      {
        projectWorkspace = nil
        projectHistoryManager = activeProjectHistoryManager
        isActiveProject = true
      } else if let residentProjectWorkspace = self.delegate?.settingsWorkflow(
        self, residentProjectWorkspace: thread.projectPath)
      {
        projectWorkspace = nil
        projectHistoryManager = ProjectHistoryManager(project: residentProjectWorkspace)
        isActiveProject = false
      } else {
        guard let openedProjectWorkspace = self.openExistingProjectWorkspace(at: projectURL) else {
          return
        }
        projectWorkspace = openedProjectWorkspace
        projectHistoryManager = ProjectHistoryManager(project: openedProjectWorkspace)
        isActiveProject = false
      }
      defer { projectWorkspace?.shutdown(flags: []) }
      guard projectHistoryManager.renameThread(id: thread.threadId, title: title)
      else { return }
      if !isActiveProject, let updatedThread = projectHistoryManager.thread(id: thread.threadId) {
        let updatedThread = ProjectController.Thread(
          projectPath: thread.projectPath, threadId: updatedThread.id,
          title: updatedThread.title, updatedAt: updatedThread.updatedAt,
          model: updatedThread.model, lastMessage: updatedThread.lastMessage,
          hasUnreadResponse: updatedThread.hasUnreadResponse,
          hasIncompleteResponse: updatedThread.hasIncompleteResponse,
          status: thread.status
        )
        var threads = self.projectsController.threads
        if let index = threads.firstIndex(where: {
          $0.projectPath == thread.projectPath
            && $0.threadId == thread.threadId
        }) {
          threads[index] = updatedThread
          self.projectsController.setThreads(threads, animated: false)
        }
        if self.projectsController.selectedThread?.projectPath == thread.projectPath,
          self.projectsController.selectedThread?.threadId == thread.threadId
        {
          self.projectsController.selectedThread = updatedThread
        }
      }
    }
    alertController.addAction(renameAction)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    alertController.preferredAction = renameAction
    viewController.present(alertController, animated: true)
  }

  func projectController(
    _ controller: ProjectController,
    didSelectDeleteProject projectPath: String
  ) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey(
        self.workspace.dictionary["bot_mode", Bool.self] == true ? "delete_bot" : "delete_directory"
      ),
      message: LocalizedString.forKey(
        self.workspace.dictionary["bot_mode", Bool.self] == true
          ? "move_bot_to_trash_warning" : "move_directory_to_trash_warning"),
      preferredStyle: .alert)
    let deleteAction = UIAlertAction(
      title: LocalizedString.forKey("move_to_trash"), style: .destructive
    ) { [weak self] _ in
      guard let self else { return }
      let directoryURL = URL(fileURLWithPath: projectPath, isDirectory: true)
      let workspaceURL = self.workspaceFolderURL
      let normalizedWorkspaceURL = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
      guard
        directoryURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
          == normalizedWorkspaceURL,
        directoryURL.standardizedFileURL.resolvingSymlinksInPath() != normalizedWorkspaceURL
      else { return }
      if let activeProjectURL = self.projectHistoryProjectURL,
        self.isSameProjectURL(directoryURL, activeProjectURL)
      {
        self.delegate?.settingsWorkflowDidRemoveOpenProject(self)
        guard
          self.projectHistoryProjectURL.map({ !self.isSameProjectURL(directoryURL, $0) }) ?? true
        else {
          let errorAlertController = UIAlertController(
            title: LocalizedString.forKey(
              self.workspace.dictionary["bot_mode", Bool.self] == true
                ? "cannot_move_bot_to_trash" : "cannot_move_directory_to_trash"),
            message: LocalizedString.forKey(
              self.workspace.dictionary["bot_mode", Bool.self] == true
                ? "cannot_move_active_bot_to_trash_message"
                : "cannot_move_active_directory_to_trash_message"),
            preferredStyle: .alert)
          errorAlertController.addAction(
            UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
          self.viewController.present(errorAlertController, animated: true)
          return
        }
      }
      // Browsers close while the folder exists, so its path resolves as their identifiers did.
      self.delegate?.settingsWorkflow(self, willDeleteProjectAt: directoryURL)
      let didStartAccessing = workspaceURL.startAccessingSecurityScopedResource()
      self.projectsQueue.async { [weak self] in
        let errorMessage: String?
        do {
          try FileManager.default.trashItem(at: directoryURL, resultingItemURL: nil)
          errorMessage = nil
        } catch {
          errorMessage = error.localizedDescription
        }
        DispatchQueue.main.async {
          if didStartAccessing {
            workspaceURL.stopAccessingSecurityScopedResource()
          }
          guard let self else { return }
          if let errorMessage {
            let errorAlertController = UIAlertController(
              title: LocalizedString.forKey(
                self.workspace.dictionary["bot_mode", Bool.self] == true
                  ? "cannot_move_bot_to_trash" : "cannot_move_directory_to_trash"),
              message: errorMessage,
              preferredStyle: .alert)
            errorAlertController.addAction(
              UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
            self.viewController.present(errorAlertController, animated: true)
          } else {
            self.updateProjects()
          }
        }
      }
    }
    alertController.addAction(deleteAction)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    viewController.present(alertController, animated: true)
  }

  func projectController(
    _ controller: ProjectController,
    didSelectDeleteThread thread: ProjectController.Thread
  ) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("delete_thread"),
      message: LocalizedString.forKey("delete_thread_warning"),
      preferredStyle: .alert)
    let deleteAction = UIAlertAction(
      title: LocalizedString.forKey("delete"), style: .destructive
    ) { [weak self] _ in
      guard let self else { return }
      let rootURL = self.workspaceFolderURL
      let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
      defer {
        if didStartAccessing {
          rootURL.stopAccessingSecurityScopedResource()
        }
      }
      let projectURL = URL(fileURLWithPath: thread.projectPath, isDirectory: true)
      let projectWorkspace: SQLiteWorkspace?
      let projectHistoryManager: ProjectHistoryManager
      let isActiveProject: Bool
      if let activeProjectHistoryManager = self.projectHistoryManager,
        let activeProjectURL = self.projectHistoryProjectURL,
        self.isSameProjectURL(projectURL, activeProjectURL)
      {
        projectWorkspace = nil
        projectHistoryManager = activeProjectHistoryManager
        isActiveProject = true
      } else if let residentProjectWorkspace = self.delegate?.settingsWorkflow(
        self, residentProjectWorkspace: thread.projectPath)
      {
        projectWorkspace = nil
        projectHistoryManager = ProjectHistoryManager(project: residentProjectWorkspace)
        isActiveProject = false
      } else {
        guard let openedProjectWorkspace = self.openExistingProjectWorkspace(at: projectURL) else {
          return
        }
        projectWorkspace = openedProjectWorkspace
        projectHistoryManager = ProjectHistoryManager(project: openedProjectWorkspace)
        isActiveProject = false
      }
      defer { projectWorkspace?.shutdown(flags: []) }
      guard projectHistoryManager.deleteThread(id: thread.threadId) else { return }
      self.delegate?.settingsWorkflow(self, didDeleteThread: thread)
      guard !isActiveProject else { return }
      var threads = self.projectsController.threads
      threads.removeAll {
        $0.projectPath == thread.projectPath && $0.threadId == thread.threadId
      }
      self.projectsController.setThreads(threads, animated: true)
    }
    alertController.addAction(deleteAction)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    viewController.present(alertController, animated: true)
  }

  func projectController(
    _ controller: ProjectController, hasBrowserFor thread: ProjectController.Thread
  ) -> Bool {
    delegate?.settingsWorkflow(self, hasBrowserFor: thread) ?? false
  }

  func projectController(
    _ controller: ProjectController, didSelectCloseBrowserFor thread: ProjectController.Thread
  ) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("close_browser_tabs"),
      message: LocalizedString.forKey("close_browser_tabs_detail"),
      preferredStyle: .alert)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("close"), style: .destructive) {
        [weak self] _ in
        guard let self else { return }
        self.delegate?.settingsWorkflow(self, didConfirmCloseBrowserFor: thread)
      })
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    viewController.present(alertController, animated: true)
  }

  func projectController(
    _ controller: ProjectController,
    didSelectExportModelContextFor thread: ProjectController.Thread
  ) {
    let rootURL = workspaceFolderURL
    let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }
    let projectURL = URL(fileURLWithPath: thread.projectPath, isDirectory: true)
    let projectWorkspace: SQLiteWorkspace?
    let projectHistoryManager: ProjectHistoryManager
    if let activeProjectHistoryManager = self.projectHistoryManager,
      let activeProjectURL = projectHistoryProjectURL,
      isSameProjectURL(projectURL, activeProjectURL)
    {
      projectWorkspace = nil
      projectHistoryManager = activeProjectHistoryManager
    } else if let residentProjectWorkspace = delegate?.settingsWorkflow(
      self, residentProjectWorkspace: thread.projectPath)
    {
      projectWorkspace = nil
      projectHistoryManager = ProjectHistoryManager(project: residentProjectWorkspace)
    } else {
      guard let openedProjectWorkspace = openExistingProjectWorkspace(at: projectURL) else {
        return
      }
      projectWorkspace = openedProjectWorkspace
      projectHistoryManager = ProjectHistoryManager(project: openedProjectWorkspace)
    }
    defer { projectWorkspace?.shutdown(flags: []) }
    guard let model = projectHistoryManager.thread(id: thread.threadId)?.model else { return }
    let history = projectHistoryManager.history(threadId: thread.threadId)
    var filename = (thread.title ?? "").replacingOccurrences(of: "/", with: "-")
    if filename.isEmpty {
      filename = "context"
    }
    // Decoding a long context takes a while, so build the file off the main queue.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let contents: String
      let pathExtension: String
      if let version = LLMZoo.specificationForModel(model)?.version {
        // The unsafe tokenizer decodes control tokens back to their text form.
        let unsafeTokenizer: TiktokenTokenizer
        switch version {
        case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
          unsafeTokenizer = Qwen3_5TextGenerator.unsafeTokenizer
        case .deepseek_4_flash:
          unsafeTokenizer = DeepSeek4TextGenerator.unsafeTokenizer
        case .deepseek_4_1_flash:
          unsafeTokenizer = DeepSeek4_1TextGenerator.unsafeTokenizer
        }
        contents = unsafeTokenizer.decode(ProjectHistoryManager.context(history: history).tokens)
        pathExtension = "txt"
      } else {
        // Remote threads keep a JSON transcript instead of tokens, so export it one entry per line.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        contents = ProjectRemoteConversation.load(history: history, model: model).state.transcript
          .compactMap { try? encoder.encode($0) }
          .map { String(decoding: $0, as: UTF8.self) + "\n" }
          .joined()
        pathExtension = "jsonl"
      }
      let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        filename, isDirectory: false
      ).appendingPathExtension(pathExtension)
      guard (try? contents.write(to: fileURL, atomically: true, encoding: .utf8)) != nil else {
        return
      }
      DispatchQueue.main.async {
        guard let self else { return }
        let documentPicker = UIDocumentPickerViewController(
          forExporting: [fileURL], asCopy: true)
        self.viewController.present(documentPicker, animated: true)
      }
    }
  }

  func projectController(
    _ controller: ProjectController, hasBrowserDataForProjectAt projectPath: String,
    completion: @escaping (Bool) -> Void
  ) {
    guard let delegate else {
      completion(false)
      return
    }
    delegate.settingsWorkflow(
      self, hasBrowserDataForProjectAt: URL(fileURLWithPath: projectPath, isDirectory: true),
      completion: completion)
  }

  func projectController(
    _ controller: ProjectController, didSelectClearBrowserDataForProjectAt projectPath: String
  ) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("clear_browser_data"),
      message: LocalizedString.forKey(
        workspace.dictionary["bot_mode", Bool.self] == true
          ? "clear_bot_browser_data_detail" : "clear_directory_browser_data_detail"),
      preferredStyle: .alert)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("clear"), style: .destructive) {
        [weak self] _ in
        guard let self else { return }
        self.delegate?.settingsWorkflow(
          self,
          didConfirmClearBrowserDataForProjectAt: URL(
            fileURLWithPath: projectPath, isDirectory: true))
      })
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    viewController.present(alertController, animated: true)
  }

  func projectController(
    _ controller: ProjectController,
    didSelectRevealProject projectPath: String
  ) {
    let url = URL(fileURLWithPath: projectPath, isDirectory: true)
    let workspaceURL = url.deletingLastPathComponent()
    let didStartAccessing = workspaceURL.startAccessingSecurityScopedResource()
    UIApplication.shared.open(url, options: [:]) { _ in
      if didStartAccessing {
        workspaceURL.stopAccessingSecurityScopedResource()
      }
    }
  }

  func projectController(
    _ controller: ProjectController, didSelectWorkspaceFolder currentFolder: String?
  ) {
    let documentPicker = UnifiedDocumentPickerController(forOpeningContentTypes: [.folder])
    documentPicker.directoryURL =
      currentFolder.map { URL(fileURLWithPath: $0) } ?? workspaceFolderURL
    documentPicker.allowsMultipleSelection = false
    documentPicker.delegate = self
    viewController.present(documentPicker, animated: true)
  }

  func projectControllerDidSelectInsideAppDocuments(_ controller: ProjectController) {
    workspace.dictionary["workspace_folder", Data.self] = nil
  }

  func projectControllerDidSelectRevealWorkspace(_ controller: ProjectController) {
    let url = workspaceFolderURL
    let didStartAccessing = url.startAccessingSecurityScopedResource()
    UIApplication.shared.open(url, options: [:]) { _ in
      if didStartAccessing {
        url.stopAccessingSecurityScopedResource()
      }
    }
  }
}

extension SettingsWorkflow: SettingsSectionsControllerDelegate {
  func settingsSectionsControllerDidRequestTopUp(_ controller: SettingsSectionsController) {
    accountWorkflow.presentTopUp(from: viewController)
  }

  func settingsSectionsControllerDidRequestModelSpeed(_ controller: SettingsSectionsController) {
    delegate?.settingsWorkflowDidRequestModelSpeed(self)
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didSearchProviderChange provider: WebSearchProvider
  ) {
    if workspace.dictionary["web_search_identifier", String.self] != provider.identifier {
      workspace.dictionary["web_search_identifier", String.self] = provider.identifier
    }
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didChangeAPIKey apiKey: String
  ) {
    let key: String
    switch settingsSectionsController.searchProvider {
    case .kagi:
      key = "kagi_api_key"
    case .brave:
      key = "brave_api_key"
    case .duckDuckGo, .sogou, .disabled:
      return
    }
    let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if workspace.dictionary[key, String.self] != apiKey {
      workspace.dictionary[key, String.self] = apiKey
    }
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController,
    didReasoningEffortChange reasoningEffort: ReasoningEffort
  ) {
    workspace.dictionary["reasoning_effort", ReasoningEffort.self] = reasoningEffort
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didWorkAttitudeChange workAttitude: WorkAttitude
  ) {
    workspace.dictionary["work_attitude", WorkAttitude.self] = workAttitude
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didMemoryEnabledChange isMemoryEnabled: Bool
  ) {
    workspace.dictionary["is_memory_enabled", Bool.self] = isMemoryEnabled
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didThinkingBudgetChange thinkingBudget: Int32
  ) {
    workspace.dictionary["thinking_budget", Int.self] = Int(
      min(max(thinkingBudget, 0), 128 * 1024))
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didSelectRemoteProvider provider: RemoteProvider?,
    sourceView: UIView
  ) {
    delegate?.settingsWorkflow(self, didRequestSelect: provider, sourceView: sourceView)
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didTapRemoteProvider provider: RemoteProvider,
    sourceView: UIView
  ) {
    if provider == .localCode && !accountWorkflow.isSignedIn {
      isAwaitingHostedModelSignIn = true
      accountWorkflow.present(
        from: viewController, sourceView: sourceView, placement: .below, isSignInOnly: true)
      return
    }
    delegate?.settingsWorkflow(self, didRequestConfigure: provider, sourceView: sourceView)
  }

  func settingsSectionsController(
    _ controller: SettingsSectionsController, didChangeRemoteCompactionThreshold value: Double,
    provider: RemoteProvider
  ) {
    provider.setCompactionThreshold(value, in: workspace)
    refreshRemoteProviderConfiguration()
  }
}

extension SettingsWorkflow: KitSectionsControllerDelegate {
  func kitSectionsController(
    _ controller: KitSectionsController, didPermitEnabledChange value: Bool
  ) {
    permittedDirectories.setEnabled(value)
  }

  func kitSectionsController(
    _ controller: KitSectionsController, didSetDirectoryEnabled value: Bool, path: String
  ) {
    permittedDirectories.setEnabled(value, for: path)
  }

  func kitSectionsController(_ controller: KitSectionsController, didRemoveDirectory path: String) {
    permittedDirectories.revoke(path)
  }

  func kitSectionsController(
    _ controller: KitSectionsController, didSelectPermission permission: PermissionState,
    for directory: AppDataDirectory
  ) {
    switch permission {
    case .authorized:
      guard controller.appDataPermissions[directory] != .authorized else { return }
      let documentPicker = UnifiedDocumentPickerController(forOpeningContentTypes: [.folder])
      documentPicker.title = LocalizedString.forKey("permit_folder_access")
      documentPicker.directoryURL = directory.url
      documentPicker.allowsMultipleSelection = false
      documentPicker.delegate = self
      appDataDirectoryPicker = documentPicker
      requestedAppDataDirectory = directory
      viewController.present(documentPicker, animated: true)
    case .denied:
      // Unlike Calendar access, Local Code owns this grant, so Denied revokes it.
      workspace.dictionary[directory.bookmarkKey, Data.self] = nil
      workspace.dictionary[directory.deniedKey, Bool.self] = true
      updatePermission(for: directory)
    case .notDetermined:
      workspace.dictionary[directory.bookmarkKey, Data.self] = nil
      workspace.dictionary[directory.deniedKey, Bool.self] = nil
      updatePermission(for: directory)
    case .deniedBySystem:
      break
    }
  }

  func kitSectionsController(
    _ controller: KitSectionsController, didSelectPermission permission: PermissionState,
    for resource: ProtectedResource
  ) {
    switch permission {
    case .authorized:
      if self.permission(for: resource) == .notDetermined {
        requestAccess(to: resource) { _ in }
      } else {
        workspace.dictionary[resource.deniedKey, Bool.self] = nil
        refreshProtectedResourcePermissions()
      }
    case .denied:
      // Only system Settings can revoke access; Denied blocks the commands that use it.
      workspace.dictionary[resource.deniedKey, Bool.self] = true
      refreshProtectedResourcePermissions()
    case .notDetermined, .deniedBySystem:
      break
    }
  }

  func kitSectionsControllerDidSelectDrawThingsModelsInApp(_ controller: KitSectionsController) {
    workspace.dictionary["draw_things_models_in_app", Bool.self] = true
    workspace.dictionary["draw_things_external_models_folder", Data.self] = nil
  }

  func kitSectionsController(
    _ controller: KitSectionsController, didSelectDrawThingsModelsFolder currentFolder: String?
  ) {
    let documentPicker = UnifiedDocumentPickerController(forOpeningContentTypes: [.folder])
    documentPicker.title = LocalizedString.forKey("model_folder")
    documentPicker.directoryURL = currentFolder.map { URL(fileURLWithPath: $0, isDirectory: true) }
    documentPicker.allowsMultipleSelection = false
    documentPicker.delegate = self
    drawThingsModelsFolderPicker = documentPicker
    viewController.present(documentPicker, animated: true)
  }
}

extension SettingsWorkflow: MachineSettingsWorkflowDelegate {
  func didDismiss(workflow: MachineSettingsWorkflow) {
    guard workflow === machineSettingsWorkflow else { return }
    machineSettingsWorkflow = nil
  }
}

extension SettingsWorkflow: AccountWorkflowDelegate {
  func accountWorkflowDidUpdateAccount(_ workflow: AccountWorkflow) {
    guard workflow === accountWorkflow else { return }
    settingsSectionsController.hostedAccountBalance = workflow.balance
    settingsSectionsController.isHostedAccountSignedIn = workflow.isSignedIn
  }

  func accountWorkflowDidDismiss(_ workflow: AccountWorkflow) {
    guard workflow === accountWorkflow else { return }
    isAwaitingHostedModelSignIn = false
    viewController.isAccountButtonSelected = false
  }

  func accountWorkflowDidUpdateHostedProvider(
    _ workflow: AccountWorkflow
  ) {
    guard workflow === accountWorkflow else { return }
    refreshRemoteProviderConfiguration()
    delegate?.settingsWorkflowDidUpdateHostedProvider(self)
    guard isAwaitingHostedModelSignIn,
      workflow.isSignedIn,
      !RemoteProvider.localCode.cachedModels(in: workspace).isEmpty,
      workflow.viewController.presentingViewController != nil
    else { return }
    isAwaitingHostedModelSignIn = false
    workflow.viewController.dismiss(animated: true)
  }
}

extension SettingsWorkflow: UnifiedDocumentPickerControllerDelegate {
  func documentPicker(_ controller: UnifiedDocumentPickerController, didPickDocumentsAt urls: [URL])
  {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let url = urls.first else { return }
    guard url.startAccessingSecurityScopedResource() else { return }
    defer { url.stopAccessingSecurityScopedResource() }
    if controller === appDataDirectoryPicker {
      appDataDirectoryPicker = nil
      let directory = requestedAppDataDirectory
      guard
        url.standardizedFileURL.resolvingSymlinksInPath().path
          == directory.url.standardizedFileURL.resolvingSymlinksInPath().path,
        (try? permittedDirectories.set(directory, url: url)) != nil
      else { return }
      workspace.dictionary[directory.deniedKey, Bool.self] = nil
      updatePermission(for: directory)
      return
    }
    #if targetEnvironment(macCatalyst)
      guard
        let bookmarkData = try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      else { return }
    #else
      guard
        let bookmarkData = try? url.bookmarkData(
          options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      else { return }
    #endif
    if controller === drawThingsModelsFolderPicker {
      workspace.dictionary["draw_things_external_models_folder", Data.self] = bookmarkData
      workspace.dictionary["draw_things_models_in_app", Bool.self] = nil
      drawThingsModelsFolderPicker = nil
    } else {
      workspace.dictionary["workspace_folder", Data.self] = bookmarkData
    }
  }
}

extension SettingsWorkflow {
  func setContextUsed(_ usedTokens: Int, contextWindowTokens: Int) {
    dispatchPrecondition(condition: .onQueue(.main))
    viewController.setContextUsed(usedTokens, contextWindowTokens: contextWindowTokens)
  }

  func setPrefillTokensPerSecond(_ prefillTokensPerSecond: Float, tokenGeneratedPerSecond: Float) {
    settingsSectionsController.performanceTitle = LocalizedString.forKey("avg_speed")
    settingsSectionsController.promptProcessingTitle = LocalizedString.forKey("prompt_processing")
    settingsSectionsController.tokenGenerationTitle = LocalizedString.forKey("token_generation")
    settingsSectionsController.promptProcessingLabel =
      "\(prefillTokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
    settingsSectionsController.tokenGenerationLabel =
      "\(tokenGeneratedPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s"
  }

  func setRemoteMetrics(_ metrics: RemoteAgentMetrics?) {
    settingsSectionsController.performanceTitle = LocalizedString.forKey("remote_performance")
    settingsSectionsController.promptProcessingTitle = LocalizedString.forKey(
      "avg_time_to_first_token")
    settingsSectionsController.tokenGenerationTitle = LocalizedString.forKey("observed_output")
    if let duration = metrics?.averageTimeToFirstToken {
      settingsSectionsController.promptProcessingLabel =
        duration < 1
        ? "\((duration * 1_000).formatted(.number.precision(.fractionLength(0)))) ms"
        : "\(duration.formatted(.number.precision(.fractionLength(1)))) s"
    } else {
      settingsSectionsController.promptProcessingLabel = "—"
    }
    if let rate = metrics?.observedOutputTokensPerSecond {
      settingsSectionsController.tokenGenerationLabel =
        "\(metrics?.isOutputRateEstimated == true ? "~" : "")\(rate.formatted(.number.precision(.fractionLength(1)))) tok/s"
    } else {
      settingsSectionsController.tokenGenerationLabel = "—"
    }
  }
}

/// A resource that the system protects, such as Calendar. Local Code can ask for access once, and
/// block its own commands after access is granted, but only system Settings can revoke access.
enum ProtectedResource: CaseIterable {
  case calendar
  case photos

  var name: String {
    switch self {
    case .calendar: return "Calendar"
    case .photos: return "Photos"
    }
  }

  /// Its pane in system Settings > Privacy & Security.
  var settingsName: String {
    switch self {
    case .calendar: return "Calendars"
    case .photos: return "Photos"
    }
  }

  var deniedKey: String {
    switch self {
    case .calendar: return "is_calendar_denied"
    case .photos: return "is_photos_denied"
    }
  }
}

enum ProtectedResourcePermissionError: LocalizedError {
  case unavailable(ProtectedResource)
  case notDetermined(ProtectedResource)
  case denied(ProtectedResource)
  case deniedBySystem(ProtectedResource)

  var errorDescription: String? {
    switch self {
    case .unavailable(let resource):
      return "\(resource.name) access is unavailable. Try again from Local Code."
    case .notDetermined(let resource):
      return "\(resource.name) access has not been requested yet."
    case .denied(let resource): return "\(resource.name) Permission is set to Denied in Kit."
    case .deniedBySystem(let resource):
      return
        "\(resource.name) access is denied. Allow it in Settings > Privacy & Security > \(resource.settingsName)."
    }
  }
}

extension SettingsWorkflow {
  /// Lets a command use `resource` when its permission allows it. When access has not been
  /// requested and `prompt` is true, this shows the system prompt.
  func access(_ resource: ProtectedResource) -> BashToolContext.AccessProtectedResource {
    { [weak self] prompt, interaction, completion in
      DispatchQueue.main.async {
        guard let self else {
          completion(.failure(ProtectedResourcePermissionError.unavailable(resource)))
          return
        }
        switch self.permission(for: resource) {
        case .authorized:
          completion(.success(()))
        case .denied:
          completion(.failure(ProtectedResourcePermissionError.denied(resource)))
        case .deniedBySystem:
          completion(.failure(ProtectedResourcePermissionError.deniedBySystem(resource)))
        case .notDetermined:
          guard prompt else {
            completion(.failure(ProtectedResourcePermissionError.notDetermined(resource)))
            return
          }
          // The system prompt is time spent waiting for the user, which Bash timeouts exclude.
          let request = interaction.begin(isUserInteraction: true)
          self.requestAccess(to: resource) { granted in
            interaction.cancel(request)
            completion(
              granted
                ? .success(()) : .failure(ProtectedResourcePermissionError.deniedBySystem(resource))
            )
          }
        }
      }
    }
  }

  func refreshProtectedResourcePermissions() {
    dispatchPrecondition(condition: .onQueue(.main))
    for resource in ProtectedResource.allCases {
      kitSectionsController.protectedResourcePermissions[resource] = permission(for: resource)
    }
  }

  private func permission(for resource: ProtectedResource) -> PermissionState {
    let isDenied = workspace.dictionary[resource.deniedKey, Bool.self] == true
    switch resource {
    case .calendar:
      switch EKEventStore.authorizationStatus(for: .event) {
      // On iOS 17 and macOS 14, `fullAccess` has the raw value of the deprecated `authorized`.
      case .authorized:
        return isDenied ? .denied : .authorized
      case .denied, .restricted:
        return .deniedBySystem
      default:
        // Not requested yet, or write-only access that the user can upgrade.
        return .notDetermined
      }
    case .photos:
      switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
      // Limited access covers the photos that the user selected.
      case .authorized, .limited:
        return isDenied ? .denied : .authorized
      case .denied, .restricted:
        return .deniedBySystem
      default:
        return .notDetermined
      }
    }
  }

  private func requestAccess(to resource: ProtectedResource, completion: @escaping (Bool) -> Void) {
    let finish: (Bool) -> Void = { [weak self] granted in
      DispatchQueue.main.async {
        self?.refreshProtectedResourcePermissions()
        completion(granted)
      }
    }
    switch resource {
    case .calendar:
      let store = EKEventStore()
      let handler: EKEventStoreRequestAccessCompletionHandler = { granted, _ in
        // The request needs its store until the user answers.
        withExtendedLifetime(store) {}
        finish(granted)
      }
      if #available(iOS 17, macCatalyst 17, *) {
        store.requestFullAccessToEvents(completion: handler)
      } else {
        store.requestAccess(to: .event, completion: handler)
      }
    case .photos:
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
        finish(status == .authorized || status == .limited)
      }
    }
  }

  private func updatePermission(for directory: AppDataDirectory) {
    dispatchPrecondition(condition: .onQueue(.main))
    if workspace.dictionary[directory.deniedKey, Bool.self] == true {
      kitSectionsController.appDataPermissions[directory] = .denied
    } else if workspace.dictionary[directory.bookmarkKey, Data.self] != nil {
      kitSectionsController.appDataPermissions[directory] = .authorized
    } else {
      kitSectionsController.appDataPermissions[directory] = .notDetermined
    }
  }
}

extension SettingsWorkflow: CommunityTemplateWorkflowDelegate {
  func communityTemplateWorkflow(
    _ workflow: CommunityTemplateWorkflow, didSelectTemplateNamed name: String
  ) {
    presentNewProjectPrompt(templateName: name)
  }

  func didDismiss(workflow: CommunityTemplateWorkflow) {
    guard workflow === communityTemplateWorkflow else { return }
    communityTemplateWorkflow = nil
  }
}

extension SettingsWorkflow: ActivitiesSectionsControllerDelegate {
  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didOpenBrowserTab id: String
  ) {
    delegate?.settingsWorkflow(self, didOpenBrowserTab: id)
  }

  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didCloseBrowserTab id: String
  ) {
    delegate?.settingsWorkflow(self, didCloseBrowserTab: id)
  }

  func activitiesSectionsController(
    _ controller: ActivitiesSectionsController, didSelectStopProcess id: Int
  ) {
    // The command may have finished since the row was listed.
    guard let job = BashJobRegistry.runningJobs.value.first(where: { $0.id == id }) else { return }
    let alertController = UIAlertController(
      title: LocalizedString.forKey("stop_process"),
      message: job.command + "\n\n" + LocalizedString.forKey("stop_process_detail"),
      preferredStyle: .alert)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("stop"), style: .destructive) { _ in
        // Stopping switches the calling thread's ios_system session, as bash_stop does from the
        // agent's thread; keep that off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
          BashJobRegistry.stop(id: id)
        }
      })
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    viewController.present(alertController, animated: true)
  }
}

extension SettingsWorkflow.TransitioningController: UIViewControllerTransitioningDelegate {
  func animationController(
    forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    SettingsAnimatedTransitioning(
      duration: 0.4, transition: .easeIn, interactive: delegate?.presentInteractively ?? false)
  }

  func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning?
  {
    SettingsAnimatedTransitioning(duration: 0.4, transition: .easeOut, interactive: false)
  }

  func presentationController(
    forPresented presented: UIViewController, presenting: UIViewController?,
    source: UIViewController
  ) -> UIPresentationController? {
    SettingsPresentationController(presentedViewController: presented, presenting: presenting)
  }

  func interactionControllerForPresentation(using animator: UIViewControllerAnimatedTransitioning)
    -> UIViewControllerInteractiveTransitioning?
  {
    guard let delegate, delegate.presentInteractively else { return nil }
    let interactiveTransition = UIPercentDrivenInteractiveTransition()
    delegate.percentDrivenInteractiveTransition = interactiveTransition
    return interactiveTransition
  }
}
