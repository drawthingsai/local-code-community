import Combine
import Dflat
import Downloader
import Localization
import ModelZoo
import RemoteAPI
import SQLiteDflat
import UIKit
import UserAccount

protocol OnboardingWorkflowDelegate: AnyObject {
  func onboardingWorkflow(
    _ workflow: OnboardingWorkflow, didRequestSignIn provider: AccountManager.SignInProvider,
    sourceView: UIView)
  /// Asks for the local model chosen on the model step to start downloading right away. It is
  /// only selected once onboarding finishes.
  func onboardingWorkflow(
    _ workflow: OnboardingWorkflow, didRequestDownloadOfLocalModel file: String)
  func onboardingWorkflow(_ workflow: OnboardingWorkflow, didSelectLocalModel file: String)
  /// Asks for a project folder for each starter project left on when onboarding finishes, filled
  /// from the community template of that name.
  func onboardingWorkflow(
    _ workflow: OnboardingWorkflow,
    didRequestProjects projects: [(name: String, templateName: String)])
  func onboardingWorkflowDidUpdateRemoteProvider(_ workflow: OnboardingWorkflow)
  /// - Parameter provider: The chosen remote provider, or nil for a local model.
  func onboardingWorkflow(_ workflow: OnboardingWorkflow, didFinishWith provider: RemoteProvider?)
}

final class OnboardingWorkflow: Workflow {
  weak var delegate: OnboardingWorkflowDelegate?

  let viewController = OnboardingViewController()
  var viewControllable: UIViewController { viewController }

  private let workspace: SQLiteWorkspace
  private let accountManager: AccountManager
  // Progress lives only as long as the walkthrough is showing; reopening it starts over.
  private var state = OnboardingState()
  private var accountSubscription: AnyCancellable?
  private var modelSubscriptions = [Workspace.Subscription]()
  private var credentialObserver: NSObjectProtocol?
  private let modelClient = RemoteModelMetadataClient()
  private var modelRequest: RemoteRequestCancellable?
  private var modelRequestIdentifier = UUID()
  private lazy var localModelSizeLoader: LocalModelSizeLoader = {
    let loader = LocalModelSizeLoader(workspace: workspace)
    loader.delegate = self
    return loader
  }()

  // The choice stays pending here until Continue hands it to the chat workflow, which owns
  // the selected model.
  private var pendingLocalModel: String?
  private var selectedLocalModel: LLMZoo.Specification? {
    let selectedFile = pendingLocalModel ?? workspace.dictionary["llm_model", String.self]
    return localModelSpecifications.first { $0.file == selectedFile }
      ?? localModelSpecifications.first
  }

  // The local choices depend only on this device, so they are built once.
  private lazy var localModelSpecifications: [LLMZoo.Specification] =
    OnboardingState.offeredLocalModels(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    .compactMap { LLMZoo.specificationForModel($0) }
  private var localModelOptions: [OnboardingViewController.LocalModelOption] {
    localModelSpecifications.map { specification in
      // The quantization suffix is an implementation detail the choice does not need.
      let name = specification.name.replacingOccurrences(
        of: #" \(\d+-bit[^)]*\)$"#, with: "", options: .regularExpression)
      let size = LocalModelSizeLoader.downloadSize(of: specification, in: workspace)
      return OnboardingViewController.LocalModelOption(
        id: specification.file, name: name, downloadSize: size, detail: specification.note ?? "")
    }
  }

  init(workspace: SQLiteWorkspace, accountManager: AccountManager) {
    self.workspace = workspace
    self.accountManager = accountManager
    viewController.delegate = self
    viewController.localModels = localModelOptions
    accountSubscription = accountManager.accountValueSubject.receive(on: DispatchQueue.main).sink {
      [weak self] _ in self?.refresh()
    }
    for provider in RemoteProvider.allCases {
      modelSubscriptions.append(
        workspace.dictionary.subscribe(provider.modelDictionaryKey, of: String.self) {
          [weak self] _ in
          DispatchQueue.main.async { self?.refresh() }
        })
    }
    modelSubscriptions.append(
      workspace.dictionary.subscribe("llm_model", of: String.self) { [weak self] _ in
        DispatchQueue.main.async { self?.refresh() }
      })
    credentialObserver = NotificationCenter.default.addObserver(
      forName: RemoteCredentialStore.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.refresh() }
    refresh()
    loadModels()
    localModelSizeLoader.load(localModelSpecifications)
  }

  deinit {
    modelRequest?.cancel()
    if let credentialObserver { NotificationCenter.default.removeObserver(credentialObserver) }
  }

  private var provider: RemoteProvider? {
    if case .remote(let provider) = state.selection { return provider }
    return nil
  }

  func refresh() {
    updateState()
    viewController.state = state
    viewController.selectedLocalModel = selectedLocalModel?.file
    viewController.options = modelOptions
    viewController.models = provider?.cachedModels(in: workspace) ?? []
    viewController.selectedModel = provider?.model(in: workspace)
    viewController.connectionMessage = LocalizedString.forKey(
      state.isProviderConnected
        ? "connected_choose_a_model_detail" : "connect_your_provider_to_continue")
  }

  /// Derives the state from the account and saved credentials, which can change outside this
  /// flow, and moves off a step that is no longer valid.
  private func updateState() {
    state.isAccountSignedIn = accountManager.isSignedIn
    state.isBotModeEnabled = workspace.dictionary["bot_mode", Bool.self] ?? false
    let account = provider?.account(in: workspace)
    state.isProviderConnected = account != nil
    state.isModelSelected =
      provider?.profile(in: workspace).map {
        $0.endpoint.baseURL == account?.endpoint.baseURL
      } ?? false
    if state.step == .account, state.isAccountSignedIn {
      state.step = state.canContinue ? .finished : .model
    }
    if state.step == .finished, !state.canContinue {
      state.step =
        state.selection == .remote(.localCode) && !state.isAccountSignedIn ? .account : .model
    }
  }

  private var modelOptions: [OnboardingViewController.ModelOption] {
    let defaultModelName = localModelOptions.first?.name ?? "Qwen 3.8 27B"
    let localOption = OnboardingViewController.ModelOption(
      selection: .local, title: LocalizedString.forKey("local_model"),
      detail: LocalizedString.format(key: "onboarding_local_model_detail", defaultModelName),
      badge: LocalizedString.forKey("recommended"), isBadgeHighlighted: true)
    return [localOption]
      + RemoteProvider.allCases.map { provider in
        let account = provider.account(in: workspace)
        let badge: String
        if provider == .localCode {
          badge = LocalizedString.forKey(
            !state.isAccountSignedIn
              ? "requires_sign_in" : account == nil ? "setting_up" : "signed_in")
        } else {
          badge = LocalizedString.forKey(
            account == nil
              ? "not_connected"
              : account?.authorization.kind == RemoteAuthenticationKind.unauthenticated
                ? "remote_api_connected_without_key"
                : account?.authorization.kind == .oauth ? "signed_in" : "api_key_connected")
        }
        let title: String
        let detail: String
        switch provider {
        case .localCode:
          title = LocalizedString.forKey("cloud_compute_by_draw_things")
          detail = LocalizedString.forKey("cloud_compute_by_draw_things_detail")
        case .openAICompatible:
          title = provider.title
          detail = LocalizedString.forKey("openai_compatible_api_detail")
        case .anthropic:
          title = provider.title
          detail = LocalizedString.forKey("anthropic_detail")
        case .openAI, .openRouter:
          title = provider.title
          detail = provider.configurationDetail
        }
        return OnboardingViewController.ModelOption(
          selection: .remote(provider), title: title, detail: detail, badge: badge,
          isBadgeHighlighted: account != nil && (provider != .localCode || state.isAccountSignedIn))
      }
  }

  private func loadModels() {
    modelRequest?.cancel()
    modelRequest = nil
    let identifier = UUID()
    modelRequestIdentifier = identifier
    viewController.isLoadingModels = false
    guard let provider, provider != .localCode, let account = provider.account(in: workspace)
    else { return }
    viewController.isLoadingModels = true
    modelRequest = modelClient.fetchModels(
      accountEndpoint: account.endpoint, authorization: account.authorization
    ) {
      [weak self] result in
      DispatchQueue.main.async {
        guard let self, self.modelRequestIdentifier == identifier else { return }
        self.modelRequest = nil
        self.viewController.isLoadingModels = false
        switch result {
        case .success(let models):
          provider.setCachedModels(models, in: self.workspace)
          self.refresh()
          self.delegate?.onboardingWorkflowDidUpdateRemoteProvider(self)
          if models.isEmpty {
            self.viewController.connectionMessage = LocalizedString.forKey(
              "no_models_returned_detail")
          }
        case .failure(let error):
          self.refresh()
          self.viewController.connectionMessage = LocalizedString.format(
            key: "could_not_load_models_detail", error.localizedDescription)
        }
      }
    }
  }
}

extension OnboardingWorkflow: LocalModelSizeLoaderDelegate {
  func localModelSizeLoaderDidLoadSize(_ loader: LocalModelSizeLoader) {
    viewController.localModels = localModelOptions
  }
}

extension OnboardingWorkflow: OnboardingViewControllerDelegate {
  func onboardingDidCompleteWelcome(_ viewController: OnboardingViewController) {
    state.welcomeCompleted = true
    refresh()
  }

  func onboardingDidRequestContinue(_ viewController: OnboardingViewController) {
    refresh()
    guard state.canContinue else { return }
    if state.selection == .local, let selectedLocalModel {
      if state.step == .model {
        delegate?.onboardingWorkflow(
          self, didRequestDownloadOfLocalModel: selectedLocalModel.file)
      } else if state.step == .finished {
        delegate?.onboardingWorkflow(self, didSelectLocalModel: selectedLocalModel.file)
      }
    }
    if state.step == .finished {
      workspace.dictionary["onboarding_completed", Bool.self] = true
      delegate?.onboardingWorkflow(
        self,
        didRequestProjects: OnboardingState.ProjectIdea.allCases.filter {
          state.projectIdeas.contains($0)
        }.map { (name: LocalizedString.forKey($0.rawValue), templateName: $0.templateName) })
      delegate?.onboardingWorkflow(self, didFinishWith: provider)
      return
    }
    state.advance()
    refresh()
  }

  func onboardingDidRequestBack(_ viewController: OnboardingViewController) {
    state.goBack()
    refresh()
  }

  func onboarding(
    _ viewController: OnboardingViewController,
    didSelectOption selection: OnboardingState.Selection
  ) {
    state.selection = selection
    refresh()
    loadModels()
  }

  func onboardingDidRequestConnection(_ viewController: OnboardingViewController) {
    guard let provider else { return }
    RemoteProviderConfiguration.present(
      provider, workspace: workspace, on: viewController, modelIsOptional: true
    ) { [weak self] _ in
      guard let self else { return }
      self.refresh()
      self.loadModels()
      self.delegate?.onboardingWorkflowDidUpdateRemoteProvider(self)
    }
  }

  func onboarding(_ viewController: OnboardingViewController, didSelectModel model: String) {
    provider?.setModel(model, in: workspace)
    refresh()
    delegate?.onboardingWorkflowDidUpdateRemoteProvider(self)
  }

  func onboarding(_ viewController: OnboardingViewController, didSelectLocalModel model: String) {
    guard localModelSpecifications.contains(where: { $0.file == model }) else { return }
    state.selection = .local
    pendingLocalModel = model
    refresh()
  }

  func onboarding(
    _ viewController: OnboardingViewController,
    didRequestSignIn provider: AccountManager.SignInProvider,
    sourceView: UIView
  ) {
    delegate?.onboardingWorkflow(self, didRequestSignIn: provider, sourceView: sourceView)
  }

  func onboarding(
    _ viewController: OnboardingViewController,
    didSetProjectIdea idea: OnboardingState.ProjectIdea, isOn: Bool
  ) {
    if isOn {
      state.projectIdeas.insert(idea)
    } else {
      state.projectIdeas.remove(idea)
    }
    refresh()
  }

  // Bot mode is an app setting, so it takes effect right away like its switch in Settings.
  func onboarding(_ viewController: OnboardingViewController, didSetBotModeEnabled isEnabled: Bool)
  {
    workspace.dictionary["bot_mode", Bool.self] = isEnabled
    refresh()
  }
}
