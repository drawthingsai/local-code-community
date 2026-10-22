import BashToolContext
import Dflat
import Foundation
import Localization
import ModelZoo
import ProjectHistoryManager
import QuartzCore
import RemoteAPI
import SQLiteDflat
import UIKit
import WebSearch

extension ChatWorkflow {
  func registerRemoteChatProvider(_ remoteChatProvider: RemoteChatProvider) {
    remoteChatProviders[remoteChatProvider.provider.rawValue] = remoteChatProvider
    remoteChatProvider.statusDidChange = { [weak self, weak remoteChatProvider] id, status in
      guard let self, let remoteChatProvider,
        self.isSelected(remoteChatProvider, conversation: id)
      else { return }
      self.settingsWorkflow.setRemoteContextStatus(status)
    }
  }

  func remoteChatProvider(for provider: RemoteProvider) -> RemoteChatProvider {
    if let remoteChatProvider = remoteChatProviders[provider.rawValue] {
      return remoteChatProvider
    }
    let remoteChatProvider = RemoteChatProvider(provider: provider, workspace: workspace)
    registerRemoteChatProvider(remoteChatProvider)
    return remoteChatProvider
  }

  private func select(_ remoteChatProvider: RemoteChatProvider) {
    workspace.dictionary["chat_backend", String.self] = remoteChatProvider.provider.rawValue
    codeAgentWrapper = .remote(remoteChatProvider)
    settingsWorkflow.setRemoteContextStatus(nil)
    chatInputController.setModel(
      name: remoteChatProvider.title,
      image: Self.modelImage(for: remoteChatProvider.provider))
    settingsWorkflow.setRemoteMetrics(nil)
  }

  private func selectLocalProvider() {
    guard chatInputController.sendState == .idle else { return }
    workspace.dictionary["chat_backend", String.self] = nil
    settingsWorkflow.setRemoteContextStatus(nil)
    guard let selectedLLM else {
      codeAgentWrapper = nil
      chatInputController.setModel(
        name: LocalizedString.forKey("unspecified"), image: Self.modelImage(for: nil))
      settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
      settingsWorkflow.setContextUsed(0, contextWindowTokens: 0)
      return
    }
    self.selectedLLM = selectedLLM
    chatInputController.setModel(
      name: LLMZoo.humanReadableNameForModel(selectedLLM), image: Self.modelImage(for: selectedLLM))
  }

  private func remoteConversationID() -> ProjectThreadIdentifier? {
    guard let projectURL, let projectHistoryManager, projectHistoryManager.threadId >= 0 else {
      return nil
    }
    return ProjectThreadIdentifier(
      projectURL: projectURL, threadId: projectHistoryManager.threadId)
  }

  private func isSelected(
    _ remoteChatProvider: RemoteChatProvider,
    conversation id: ProjectThreadIdentifier
  ) -> Bool {
    guard case .some(.remote(let selectedProvider)) = codeAgentWrapper,
      selectedProvider === remoteChatProvider,
      projectHistoryManager?.threadId == id.threadId,
      let projectURL
    else { return false }
    return ProjectThreadIdentifier(
      projectURL: projectURL, threadId: id.threadId
    ).projectPath == id.projectPath
  }

  func handle(url: URL) -> Bool {
    settingsWorkflow.handle(url: url)
  }

  var remoteChatProviderIdentifier: String? {
    guard case .some(.remote(let remoteChatProvider)) = codeAgentWrapper,
      let model = remoteChatProvider.provider.model(in: workspace)
    else { return nil }
    return remoteThreadModelIdentifier(provider: remoteChatProvider.provider, model: model)
  }

  func remoteThreadModelIdentifier(provider: RemoteProvider, model: String) -> String {
    "cloud:\(provider.rawValue):\(model)"
  }

  func parseRemoteThreadModelIdentifier(
    _ identifier: String
  ) -> (provider: RemoteProvider, model: String)? {
    let components = identifier.split(
      separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
    guard components.count == 3, components[0] == "cloud",
      let provider = RemoteProvider(rawValue: String(components[1])), !components[2].isEmpty
    else { return nil }
    return (provider, String(components[2]))
  }

  func remoteModelSection(
    provider: RemoteProvider, models: [String]
  ) -> ItemDisplaySectionModel {
    let viewModels = models.map { model in
      let viewModel = ItemAcronymViewModel(
        itemIdentifier: .identifier(remoteThreadModelIdentifier(provider: provider, model: model)),
        title: .title(provider.modelDisplayName(model, in: workspace)),
        backgroundColor: .secondaryFill,
        // The provider is the same for every row, so a remote model has no detail to show.
        detail: "",
        thumbnail: .image(Self.modelImage(for: provider)),
        isList: true, thumbnailTintColor: .primaryText)
      return ItemDisplayCollectionViewCellViewModel.itemAcronymViewModel(viewModel)
    }
    return ItemDisplaySectionModel(identifier: .noSection, items: viewModels)
  }

  func populateRemoteModels(
    provider: RemoteProvider, modelSelectWorkflow: ItemSelectWorkflow
  ) {
    guard provider != .localCode, let account = provider.account(in: workspace) else { return }
    remoteModelCatalogRequest = remoteModelMetadataClient.fetchModels(
      accountEndpoint: account.endpoint, authorization: account.authorization
    ) { [weak self, weak modelSelectWorkflow] result in
      DispatchQueue.main.async {
        guard let self, let modelSelectWorkflow,
          self.modelSelectWorkflow === modelSelectWorkflow,
          case .some(.remote(let remoteChatProvider)) = self.codeAgentWrapper,
          remoteChatProvider.provider == provider,
          case .success(let models) = result
        else { return }
        provider.setCachedModels(models, in: self.workspace)
        modelSelectWorkflow.setViewModels(
          [
            self.remoteModelSection(
              provider: provider, models: provider.cachedModels(in: self.workspace))
          ], flag: nil)
        if let identifier = self.remoteChatProviderIdentifier {
          modelSelectWorkflow.selectItem(at: .identifier(identifier))
        }
      }
    }
  }

  private func selectRemoteProvider(_ provider: RemoteProvider, sourceView: UIView) {
    guard chatInputController.sendState == .idle
    else { return }
    if provider == .localCode {
      let remoteChatProvider = remoteChatProvider(for: provider)
      select(remoteChatProvider)
      settingsWorkflow.refreshRemoteProviderConfiguration()
      return
    }
    if provider.account(in: workspace) != nil {
      select(remoteChatProvider(for: provider))
      settingsWorkflow.refreshRemoteProviderConfiguration()
    } else {
      presentRemoteProviderConfiguration(provider, sourceView: sourceView)
    }
  }

  func presentRemoteProviderConfiguration(_ provider: RemoteProvider, sourceView: UIView? = nil) {
    guard chatInputController.sendState == .idle
    else { return }
    if provider == .localCode {
      settingsWorkflow.presentAccount(
        from: presentedViewController, sourceView: sourceView ?? projectBarController.view)
      return
    }
    RemoteProviderConfiguration.present(
      provider, workspace: workspace, on: presentedViewController
    ) { [weak self] change in
      guard let self else { return }
      guard chatInputController.sendState == .idle else { return }
      settingsWorkflow.refreshRemoteProviderConfiguration()
      switch change {
      case .saved:
        let remoteChatProvider = remoteChatProvider(for: provider)
        guard !remoteChatProvider.hasActiveConversations() else { return }
        select(remoteChatProvider)
      case .removed:
        remoteChatProviders[provider.rawValue]?.unload()
        guard case .some(.remote(let remoteChatProvider)) = codeAgentWrapper,
          remoteChatProvider.provider == provider
        else { return }
        workspace.dictionary["chat_backend", String.self] = nil
        if let selectedLLM {
          self.selectedLLM = selectedLLM
          chatInputController.setModel(
            name: LLMZoo.humanReadableNameForModel(selectedLLM),
            image: Self.modelImage(for: selectedLLM))
        } else {
          codeAgentWrapper = nil
          chatInputController.setModel(
            name: LocalizedString.forKey("unspecified"), image: Self.modelImage(for: nil))
          settingsWorkflow.setPrefillTokensPerSecond(0, tokenGeneratedPerSecond: 0)
          settingsWorkflow.setContextUsed(0, contextWindowTokens: 0)
        }
      }
    }
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didRequestSelect provider: RemoteProvider?, sourceView: UIView
  ) {
    if let provider {
      selectRemoteProvider(provider, sourceView: sourceView)
    } else {
      selectLocalProvider()
      settingsWorkflow.refreshRemoteProviderConfiguration()
    }
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didRequestConfigure provider: RemoteProvider,
    sourceView: UIView
  ) {
    if provider == .localCode {
      didTapModelSelector(sourceView: sourceView)
      return
    }
    presentRemoteProviderConfiguration(provider, sourceView: sourceView)
  }

  func selectRemoteModel(_ model: String, provider: RemoteProvider) {
    guard chatInputController.sendState == .idle,
      case .some(.remote(let remoteChatProvider)) = codeAgentWrapper,
      remoteChatProvider.provider == provider,
      provider != .localCode || provider.hasCachedModel(model, in: workspace)
    else { return }
    provider.setModel(model, in: workspace)
    select(remoteChatProvider)
    settingsWorkflow.refreshRemoteProviderConfiguration()
  }

  func settingsWorkflowDidUpdateHostedProvider(_ workflow: SettingsWorkflow) {
    onboardingWorkflow?.refresh()
    if RemoteProvider.localCode.profile(in: workspace) == nil {
      let localCodeProvider = remoteChatProviders[RemoteProvider.localCode.rawValue]
      localCodeProvider?.statusRequest?.request.cancel()
      localCodeProvider?.statusRequest = nil
      localCodeProvider?.unload()
    }
    guard case .some(.remote(let remoteChatProvider)) = codeAgentWrapper,
      remoteChatProvider.provider == .localCode
    else { return }
    if let modelSelectWorkflow {
      modelSelectWorkflow.setViewModels(
        [
          remoteModelSection(
            provider: .localCode, models: RemoteProvider.localCode.cachedModels(in: workspace))
        ], flag: nil)
      if let identifier = remoteChatProviderIdentifier {
        modelSelectWorkflow.selectItem(at: .identifier(identifier))
      }
    }
    remoteChatProvider.statusRequest?.request.cancel()
    remoteChatProvider.statusRequest = nil
    settingsWorkflow.setRemoteContextStatus(nil)
    chatInputController.setModel(
      name: remoteChatProvider.title,
      image: Self.modelImage(for: remoteChatProvider.provider))
    restoreRemoteConversation()
  }

  func settingsWorkflow(
    _ workflow: SettingsWorkflow, didDeleteThread thread: ProjectController.Thread
  ) {
    let conversationID = ProjectThreadIdentifier(
      projectURL: URL(fileURLWithPath: thread.projectPath, isDirectory: true),
      threadId: thread.threadId)
    remoteChatProviders.values.forEach { $0.remove(conversationID) }
    browserWorkflows.removeValue(forKey: ProjectThreadIdentifier(thread: thread))?.close()
  }

  func didTapSendRemote(_ prompt: String) {
    guard chatInputController.sendState == .idle,
      case .some(.remote(let remoteChatProvider)) = codeAgentWrapper
    else { return }
    let provider = remoteChatProvider.provider
    if prompt.caseInsensitiveCompare("/status") == .orderedSame {
      sendRemoteStatus(remoteChatProvider: remoteChatProvider, viewController: viewController)
      return
    }
    guard let profile = remoteChatProvider.profile else {
      if provider.account(in: workspace) != nil {
        chatInputController.selectModel()
      } else {
        presentRemoteProviderConfiguration(provider)
      }
      return
    }
    guard let projectURL, let projectHistoryManager else {
      let alertController = UIAlertController(
        title: LocalizedString.forKey("cloud"),
        message: LocalizedString.forKey(
          workspace.dictionary["bot_mode", Bool.self] == true
            ? "cloud_bot_required" : "cloud_project_required"), preferredStyle: .alert)
      alertController.addAction(
        UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
      presentedViewController.present(alertController, animated: true)
      return
    }
    guard workspace.dictionary["remote_api_disclosure_acknowledged", Bool.self] == true else {
      let alertController = UIAlertController(
        title: LocalizedString.forKey("remote_api_disclosure_title"),
        message: LocalizedString.forKey("remote_api_disclosure_message"),
        preferredStyle: .alert)
      alertController.addAction(
        UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
      alertController.addAction(
        UIAlertAction(title: LocalizedString.forKey("continue"), style: .default) {
          [weak self] _ in
          guard let self, case .some(.remote(let remoteChatProvider)) = self.codeAgentWrapper,
            remoteChatProvider.provider == provider
          else { return }
          workspace.dictionary["remote_api_disclosure_acknowledged", Bool.self] = true
          didTapSendRemote(prompt)
        })
      presentedViewController.present(alertController, animated: true)
      return
    }

    let textEdits = textHistoryManager.currentEdits
    let textLineage = textHistoryManager.lineage
    let threadModel = remoteThreadModelIdentifier(provider: provider, model: profile.model)
    let threadId: Int64
    let userDatetime: Int64
    let conversationModel: String
    if projectHistoryManager.threadId == -1 {
      let title =
        prompt.components(separatedBy: .newlines).first {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? prompt
      let thread = projectHistoryManager.createThread(
        title: title, model: threadModel, userTokens: [], textEdits: textEdits,
        textLineage: textLineage, plaintext: prompt)
      projectHistoryManager.threadId = thread.id
      observeQueuedItems(threadId: thread.id)
      threadId = thread.id
      userDatetime = thread.updatedAt
      conversationModel = threadModel
    } else {
      threadId = projectHistoryManager.threadId
      guard let thread = projectHistoryManager.thread(id: threadId) else { return }
      guard let sourceModel = thread.model ?? selectedLLM else { return }
      if thread.model != threadModel {
        // Only local models store tokens; any other thread (a remote provider's, including one
        // this build no longer knows) already keeps plain text and only needs its model updated.
        if parseRemoteThreadModelIdentifier(sourceModel) != nil
          || LLMZoo.specificationForModel(sourceModel) == nil
        {
          guard projectHistoryManager.updateThreadModel(id: threadId, model: threadModel) else {
            return
          }
        } else {
          let history = projectHistoryManager.history(threadId: threadId)
          guard
            let convertedHistory = convertedHistoryForRemoteModel(
              history, sourceModel: sourceModel),
            projectHistoryManager.rewriteHistory(
              threadId: threadId, nodes: convertedHistory, model: threadModel)
          else { return }
        }
      }
      let userNode: ProjectHistoryNode?
      if let restoredUserNode, restoredUserNode.threadId == threadId {
        userNode = projectHistoryManager.replaceUser(
          threadId: threadId, datetime: restoredUserNode.datetime, tokens: [],
          textEdits: textEdits, textLineage: textLineage, plaintext: prompt)
      } else {
        userNode = projectHistoryManager.appendUser(
          threadId: threadId, tokens: [], textEdits: textEdits,
          textLineage: textLineage, plaintext: prompt)
      }
      guard let userNode else {
        restoreRemoteConversation()
        return
      }
      userDatetime = userNode.datetime
      conversationModel = threadModel
    }
    restoredUserNode = nil
    let conversationID = ProjectThreadIdentifier(
      projectURL: projectURL, threadId: threadId)
    let conversation = ProjectRemoteConversation.load(
      history: projectHistoryManager.history(threadId: threadId), model: conversationModel)

    let webSearchIdentifier =
      workspace.dictionary["web_search_identifier", String.self] ?? "duckduckgo"
    let webSearchProvider =
      WebSearchProvider(
        identifier: webSearchIdentifier,
        apiKey: workspace.dictionary["\(webSearchIdentifier)_api_key", String.self] ?? "")
      ?? .duckDuckGo
    let bashUserInteraction = BashUserInteraction()
    let startTime = CACurrentMediaTime()
    viewController.appendUser(
      prompt, datetime: Date(timeIntervalSince1970: Double(userDatetime) / 1_000))
    viewController.appendAssistant(
      "", isTransient: true,
      mode: .reading(0, 0, startTime: startTime, bashUserInteraction: bashUserInteraction))
    chatInputController.sendState = .sending
    threadNotifications.requestAuthorizationIfNeeded()
    remoteChatProvider.bashToolContext = bashToolContext
    remoteChatProvider.prepare(
      conversationID, profile: profile, workspacePath: settingsWorkflow.workspaceFolderURL.path,
      webSearchProvider: webSearchProvider, state: conversation.state,
      forceHistoryCheckpoint: conversation.forceCheckpoint, forSending: true
    ) { [weak self] preparationResult in
      guard let self else { return }
      if case .failure = preparationResult {
        if self.isSelected(remoteChatProvider, conversation: conversationID) {
          var history = projectHistoryManager.history(threadId: threadId)
          self.restoreDraftIfNeeded(from: &history)
          viewController.setHistory(self.historyMessages(from: history))
          self.chatInputController.sendState = .idle
          if let didStopHandler = self.didStopHandler {
            self.didStopHandler = nil
            didStopHandler()
          }
        }
        return
      }
      remoteChatProvider.send(
        prompt,
        in: conversationID, bashUserInteraction: bashUserInteraction,
        progress: { [weak self] progress in
          guard let self,
            self.isSelected(remoteChatProvider, conversation: conversationID)
          else { return }
          self.updateRemoteProgress(
            progress, startTime: startTime, bashUserInteraction: bashUserInteraction)
        },
        completion: { [weak self] result, historyResult, wasCancelled in
          guard let self else { return }
          if remoteChatProvider.provider == .localCode {
            self.settingsWorkflow.refreshAccountBalance()
            if case .failure(let error) = result,
              case .provider(statusCode: 402, message: _) = error
            {
              self.settingsWorkflow.presentAccountTopUp(from: self.presentedViewController)
            }
          }
          defer { self.openPendingNotificationThread() }
          let text: String
          let response: String
          switch result {
          case .success(let completion):
            if self.isSelected(remoteChatProvider, conversation: conversationID) {
              self.settingsWorkflow.setRemoteMetrics(completion.metrics)
            }
            let tools = completion.tools.map(\.subtitle).filter { !$0.isEmpty }.joined(
              separator: "\n")
            text = [tools, completion.text].filter { !$0.isEmpty }.joined(separator: "\n---\n")
            response = completion.text
          case .failure(let error):
            text = error.localizedDescription
            response = text
          }
          let historyEntry: (plaintext: String, compacted: Bool)?
          switch historyResult {
          case .success(let entry):
            historyEntry = entry
          case .failure(let error):
            historyEntry = nil
            print("Unable to encode remote conversation history: %@", error.localizedDescription)
          }
          let duration =
            CACurrentMediaTime() - startTime
            - bashUserInteraction.userInteractionInterval(since: startTime)
          guard
            projectHistoryManager.appendAssistant(
              threadId: threadId, logTokens: [], tokens: [], toolCalls: [],
              plaintext: text, logPlaintext: historyEntry?.plaintext,
              duration: duration, compacted: historyEntry?.compacted ?? false,
              lastMessage: response) != nil
          else {
            if self.isSelected(remoteChatProvider, conversation: conversationID) {
              self.restoreRemoteConversation()
              self.continueWithQueuedItems()
            }
            return
          }
          if remoteChatProvider.provider == .localCode, !wasCancelled,
            case .failure(.provider(statusCode: 429, message: _)) = result
          {
            self.showTopUpAction(
              title: LocalizedString.forKey("free_request_rate_limit_reached"),
              subtitle: LocalizedString.forKey("free_request_rate_limit_description"),
              conversation: conversationID)
          }
          if self.isSelected(remoteChatProvider, conversation: conversationID) {
            viewController.setLastMessage(
              text, duration: duration, isTransient: false, mode: .none)
            self.continueWithQueuedItems()
          }
          if case .success = result, !wasCancelled, !remoteChatProvider.isActive(conversationID) {
            self.notifyThreadCompletion(
              projectURL: projectURL, threadId: threadId,
              projectHistoryManager: projectHistoryManager, duration: duration)
          }
        })
    }
  }

  func restoreRemoteConversation() {
    guard case .some(.remote(let remoteChatProvider)) = codeAgentWrapper
    else { return }
    restoredUserNode = nil
    guard let projectURL, let projectHistoryManager else {
      cancelRemoteStatusRequest(remoteChatProvider)
      viewController.setHistory([])
      chatInputController.sendState = .idle
      settingsWorkflow.setRemoteContextStatus(nil)
      settingsWorkflow.setRemoteMetrics(nil)
      return
    }
    let threadId = projectHistoryManager.threadId
    guard threadId >= 0, let thread = projectHistoryManager.thread(id: threadId) else {
      cancelRemoteStatusRequest(remoteChatProvider)
      viewController.setHistory([])
      chatInputController.sendState = .idle
      settingsWorkflow.setRemoteContextStatus(nil)
      settingsWorkflow.setRemoteMetrics(nil)
      return
    }
    let conversationID = ProjectThreadIdentifier(
      projectURL: projectURL, threadId: threadId)
    settingsWorkflow.setRemoteMetrics(remoteChatProvider.metrics(for: conversationID))
    var history = projectHistoryManager.history(threadId: threadId)
    if remoteChatProvider.isActive(conversationID) {
      viewController.setHistory(historyMessages(from: history))
      let bashUserInteraction = remoteChatProvider.bashUserInteraction(for: conversationID)
      let startTime = CACurrentMediaTime()
      lastPartialResultRendered = 0
      viewController.appendAssistant(
        "", isTransient: true,
        mode: .reading(0, 0, startTime: startTime, bashUserInteraction: bashUserInteraction))
      if let progress = remoteChatProvider.latestProgress(for: conversationID) {
        updateRemoteProgress(
          progress, startTime: startTime, bashUserInteraction: bashUserInteraction)
      }
      chatInputController.sendState = .sending
      settingsWorkflow.setRemoteContextStatus(remoteChatProvider.status(for: conversationID))
      return
    }
    chatInputController.sendState = .idle
    if history.last(where: { $0.role != .memory })?.role != .user, !queuedItems.isEmpty {
      viewController.setHistory(historyMessages(from: history))
      continueWithQueuedItems()
      return
    }
    restoreDraftIfNeeded(from: &history)
    viewController.setHistory(historyMessages(from: history))
    guard let profile = remoteChatProvider.profile else {
      cancelRemoteStatusRequest(remoteChatProvider)
      settingsWorkflow.setRemoteContextStatus(nil)
      return
    }
    guard let conversationModel = thread.model ?? selectedLLM else { return }
    let conversation = ProjectRemoteConversation.load(
      history: history, model: conversationModel)
    let webSearchIdentifier =
      workspace.dictionary["web_search_identifier", String.self] ?? "duckduckgo"
    let webSearchProvider =
      WebSearchProvider(
        identifier: webSearchIdentifier,
        apiKey: workspace.dictionary["\(webSearchIdentifier)_api_key", String.self] ?? "")
      ?? .duckDuckGo
    settingsWorkflow.setRemoteContextStatus(remoteChatProvider.status(for: conversationID))
    remoteChatProvider.bashToolContext = bashToolContext
    remoteChatProvider.prepare(
      conversationID, profile: profile, workspacePath: settingsWorkflow.workspaceFolderURL.path,
      webSearchProvider: webSearchProvider, state: conversation.state,
      forceHistoryCheckpoint: conversation.forceCheckpoint)
  }

  private func sendRemoteStatus(
    remoteChatProvider: RemoteChatProvider, viewController: any ChatViewControllable
  ) {
    if projectURL != nil {
      restoreRemoteConversation()
    }
    let agentStatus = remoteConversationID().flatMap {
      remoteChatProvider.status(for: $0)
    }
    viewController.appendUser("/status", datetime: Date())
    guard let profile = remoteChatProvider.profile else {
      viewController.appendAssistant(
        RemoteStatusReport.markdown(
          providerTitle: nil, agentStatus: agentStatus,
          account: .notExposed),
        isTransient: false, mode: .none)
      return
    }

    guard remoteChatProvider.provider == .openRouter else {
      viewController.appendAssistant(
        RemoteStatusReport.markdown(
          providerTitle: profile.title, agentStatus: agentStatus,
          account: .notExposed),
        isTransient: false, mode: .none)
      return
    }

    viewController.appendAssistant(
      RemoteStatusReport.markdown(
        providerTitle: profile.title, agentStatus: agentStatus,
        account: .loading),
      isTransient: true,
      mode: .reading(0, 0, startTime: CACurrentMediaTime()))
    chatInputController.sendState = .sending
    cancelRemoteStatusRequest(remoteChatProvider)
    let provider = remoteChatProvider.provider
    let requestIdentifier = UUID()
    let request = remoteChatProvider.openRouterKeyStatusClient.fetch(
      authorization: profile.authorization
    ) { [weak self, weak viewController] result in
      DispatchQueue.main.async {
        guard let self, let viewController,
          case .some(.remote(let remoteChatProvider)) = self.codeAgentWrapper,
          remoteChatProvider.statusRequest?.identifier == requestIdentifier,
          remoteChatProvider.provider == provider
        else { return }
        remoteChatProvider.statusRequest = nil
        let account: RemoteStatusReport.Account
        switch result {
        case .success(let status):
          account = .openRouter(status)
        case .failure(let error):
          account = .failed(error.localizedDescription)
        }
        viewController.setLastMessage(
          RemoteStatusReport.markdown(
            providerTitle: profile.title,
            agentStatus: self.remoteConversationID().flatMap {
              remoteChatProvider.status(for: $0)
            },
            account: account),
          isTransient: false, mode: .none)
        self.chatInputController.sendState = .idle
        if let didStopHandler = self.didStopHandler {
          self.didStopHandler = nil
          didStopHandler()
        }
      }
    }
    remoteChatProvider.statusRequest = RemoteChatProvider.StatusRequest(
      identifier: requestIdentifier, request: request)
  }

  func didTapStopRemote(_ controller: ChatInputController) -> Bool {
    guard case .some(.remote(let remoteChatProvider)) = codeAgentWrapper else { return false }
    if remoteChatProvider.statusRequest != nil {
      controller.sendState = .stopping
      cancelRemoteStatusRequest(remoteChatProvider)
      viewController.setLastMessage(
        RemoteStatusReport.markdown(
          providerTitle: remoteChatProvider.profile?.title,
          agentStatus: remoteConversationID().flatMap {
            remoteChatProvider.status(for: $0)
          },
          account: .failed(RemoteChatError.cancelled.localizedDescription)),
        isTransient: false, mode: .none)
      controller.sendState = .idle
      if let didStopHandler = self.didStopHandler {
        self.didStopHandler = nil
        didStopHandler()
      }
      return true
    }
    guard let conversationID = remoteConversationID() else { return true }
    guard remoteChatProvider.isActive(conversationID) else {
      return true
    }
    controller.sendState = .stopping
    remoteChatProvider.cancel(conversationID)
    return true
  }

  func unloadRemoteConversations() {
    cancelRemoteStatusRequests()
    guard let projectURL else { return }
    let projectPath = ProjectThreadIdentifier(
      projectURL: projectURL, threadId: -1
    ).projectPath
    remoteChatProviders.values.forEach {
      $0.removeConversations(projectPath: projectPath)
    }
  }

  func cancelRemoteStatusRequests() {
    remoteChatProviders.values.forEach(cancelRemoteStatusRequest)
  }

  private func cancelRemoteStatusRequest(_ remoteChatProvider: RemoteChatProvider) {
    let request = remoteChatProvider.statusRequest?.request
    remoteChatProvider.statusRequest = nil
    request?.cancel()
  }

  private func updateRemoteProgress(
    _ progress: RemoteAgentProgress, startTime: CFTimeInterval,
    bashUserInteraction: BashUserInteraction?
  ) {
    settingsWorkflow.setRemoteMetrics(progress.metrics)
    guard CACurrentMediaTime() - lastPartialResultRendered >= Self.partialResultRenderInterval
    else {
      return
    }
    let completedTools = progress.tools.filter(\.isCompleted).map(\.subtitle)
    let runningTools = progress.tools.filter { !$0.isCompleted }.map(\.subtitle)
    let streamingTools = progress.streamingToolCalls.map { call in
      call.name.isEmpty
        ? LocalizedString.forKey("remote_api_tool_call") : call.name
    }
    let toolHistory = completedTools.filter { !$0.isEmpty }.joined(separator: "\n")
    let currentTools = (runningTools + streamingTools).filter { !$0.isEmpty }.joined(
      separator: "\n")
    let text = [toolHistory, progress.text, currentTools].filter { !$0.isEmpty }.joined(
      separator: "\n---\n")
    viewController.setLastMessage(
      text, isTransient: true,
      mode: currentTools.isEmpty
        ? .thinking(
          progress.text.utf8.count, startTime: startTime, bashUserInteraction: bashUserInteraction)
        : .working(
          progress.tools.count, startTime: startTime, bashUserInteraction: bashUserInteraction))
    // Measured after rendering, as updatePartialResult does: a render slower than the interval
    // otherwise makes every queued progress render too, and the main queue never drains.
    lastPartialResultRendered = CACurrentMediaTime()
  }
}
