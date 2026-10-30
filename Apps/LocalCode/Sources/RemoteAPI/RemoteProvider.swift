import Localization
import ModelZoo
import RemoteAPI
import SQLiteDflat
import UIKit

private let compatibleContextWindowKey = "openai_compatible_context_window_tokens"
private let compatibleMaximumOutputKey = "openai_compatible_maximum_output_tokens"

private struct RemoteProviderAppConfiguration {
  var title: String
  var profileTitle: String
  var modelDictionaryKey: String
  var modelsDictionaryKey: String
  var baseURLDictionaryKey: String?
  var compactionThresholdDictionaryKey: String
  var titleKey: String
  var detailKey: String
  var invalidKey: String
  var keyRequiredKey: String
}

extension RemoteProvider {
  var modelDictionaryKey: String { appConfiguration.modelDictionaryKey }

  var title: String {
    appConfiguration.title
  }

  var configurationDetail: String {
    LocalizedString.forKey(appConfiguration.detailKey)
  }

  fileprivate var appConfiguration: RemoteProviderAppConfiguration {
    switch self {
    case .localCode:
      return RemoteProviderAppConfiguration(
        title: LocalizedString.forKey("cloud_compute"),
        profileTitle: LocalizedString.forKey("cloud_compute"),
        modelDictionaryKey: "localcode_model", modelsDictionaryKey: "localcode_models",
        baseURLDictionaryKey: nil,
        compactionThresholdDictionaryKey: "localcode_compaction_threshold",
        titleKey: "cloud_compute",
        detailKey: "cloud_compute_configuration_detail",
        invalidKey: "remote_api_invalid_configuration",
        keyRequiredKey: "remote_api_key_required")
    case .openRouter:
      return RemoteProviderAppConfiguration(
        title: "OpenRouter", profileTitle: "OpenRouter",
        modelDictionaryKey: "openrouter_model", modelsDictionaryKey: "openrouter_models",
        baseURLDictionaryKey: nil,
        compactionThresholdDictionaryKey: "openrouter_compaction_threshold",
        titleKey: "openrouter_api", detailKey: "openrouter_api_configuration_detail",
        invalidKey: "openrouter_api_invalid_configuration",
        keyRequiredKey: "openrouter_api_key_required")
    case .openAICompatible:
      return RemoteProviderAppConfiguration(
        title: LocalizedString.forKey("remote_api"),
        profileTitle: LocalizedString.forKey("remote_api"),
        modelDictionaryKey: "openai_compatible_model",
        modelsDictionaryKey: "openai_compatible_models",
        baseURLDictionaryKey: "openai_compatible_base_url",
        compactionThresholdDictionaryKey: "openai_compatible_compaction_threshold",
        titleKey: "remote_api", detailKey: "remote_api_configuration_detail",
        invalidKey: "remote_api_invalid_configuration",
        keyRequiredKey: "remote_api_key_required")
    case .openAI:
      return RemoteProviderAppConfiguration(
        title: "OpenAI", profileTitle: "OpenAI",
        modelDictionaryKey: "openai_model", modelsDictionaryKey: "openai_models",
        baseURLDictionaryKey: nil,
        compactionThresholdDictionaryKey: "openai_compaction_threshold",
        titleKey: "openai_sign_in_provider", detailKey: "openai_sign_in_configuration_detail",
        invalidKey: "remote_api_invalid_configuration",
        keyRequiredKey: "remote_api_key_required")
    case .anthropic:
      return RemoteProviderAppConfiguration(
        title: "Anthropic", profileTitle: "Claude",
        modelDictionaryKey: "anthropic_model", modelsDictionaryKey: "anthropic_models",
        baseURLDictionaryKey: nil,
        compactionThresholdDictionaryKey: "anthropic_compaction_threshold",
        titleKey: "claude_api", detailKey: "claude_api_configuration_detail",
        invalidKey: "claude_api_invalid_configuration",
        keyRequiredKey: "claude_api_key_required")
    case .deviceLink:
      return RemoteProviderAppConfiguration(
        title: LocalizedString.forKey("device_link"),
        profileTitle: LocalizedString.forKey("device_link"),
        modelDictionaryKey: "devicelink_model", modelsDictionaryKey: "devicelink_models",
        baseURLDictionaryKey: nil,
        compactionThresholdDictionaryKey: "devicelink_compaction_threshold",
        titleKey: "device_link", detailKey: "device_link_model_detail",
        invalidKey: "remote_api_invalid_configuration",
        keyRequiredKey: "remote_api_key_required")
    }
  }

  func account(in workspace: SQLiteWorkspace) -> RemoteProviderAccount? {
    let baseURL: URL
    if self == .localCode {
      baseURL = AccountRouterConfiguration.baseURL.appendingPathComponent(
        "v1/openrouter", isDirectory: false)
    } else if let baseURLDictionaryKey = appConfiguration.baseURLDictionaryKey {
      guard let value = workspace.dictionary[baseURLDictionaryKey, String.self],
        let url = URL(string: value)
      else { return nil }
      baseURL = url
    } else {
      guard let defaultBaseURL else { return nil }
      baseURL = defaultBaseURL
    }
    guard let endpoint = try? RemoteProviderAccountEndpoint(provider: self, baseURL: baseURL),
      let credential = try? RemoteCredentialStore.readCredential(
        account: endpoint.baseURL.absoluteString, provider: self),
      self != .openAI || credential.kind == .oauth,
      self != .openAICompatible || credential.kind != .oauth
    else { return nil }
    return RemoteProviderAccount(
      endpoint: endpoint, credentialIdentifier: credential.identifier,
      authorization: RemoteCredentialAuthorizer(
        provider: self, account: endpoint.baseURL.absoluteString, credential: credential))
  }

  /// On `model`, or the model picked for the provider.
  func profile(in workspace: SQLiteWorkspace, model: String? = nil) -> RemoteProviderProfile? {
    // A Mac's model needs no account: the device's link reaches the Mac.
    if self == .deviceLink {
      guard let model = model ?? self.model(in: workspace), let macModel = MacModel(model),
        let endpoint = try? RemoteProviderEndpoint(provider: self, model: model)
      else { return nil }
      let reasoningEffort =
        workspace.dictionary["reasoning_effort", ReasoningEffort.self] ?? .high
      return RemoteProviderProfile(
        endpoint: endpoint, modelDisplayName: modelDisplayName(model, in: workspace),
        credentialIdentifier: "", authorization: RemoteUnauthenticatedAuthorization(),
        compactionThreshold: compactionThreshold(in: workspace),
        reasoningEffort: RemoteReasoningEffort(rawValue: reasoningEffort.rawValue) ?? .high,
        fallbackLimits: RemoteModelLimits(
          contextWindowTokens: ChatWorkflow.inferenceContextWindow(forModel: macModel.file),
          maximumOutputTokens: 32_768))
    }
    guard let account = account(in: workspace), let model = model ?? self.model(in: workspace),
      let endpoint = try? RemoteProviderEndpoint(
        provider: self, baseURL: account.endpoint.baseURL, model: model)
    else { return nil }
    let reasoningEffort =
      workspace.dictionary["reasoning_effort", ReasoningEffort.self] ?? .high
    return RemoteProviderProfile(
      endpoint: endpoint, modelDisplayName: modelDisplayName(model, in: workspace),
      credentialIdentifier: account.credentialIdentifier,
      authorization: account.authorization, compactionThreshold: compactionThreshold(in: workspace),
      reasoningEffort: RemoteReasoningEffort(rawValue: reasoningEffort.rawValue) ?? .high,
      fallbackLimits: self == .openAICompatible
        ? RemoteModelLimits(
          contextWindowTokens: workspace.dictionary[
            compatibleContextWindowKey, Int.self]
            ?? RemoteModelLimits.openAICompatibleFallback.contextWindowTokens,
          maximumOutputTokens: workspace.dictionary[
            compatibleMaximumOutputKey, Int.self]
            ?? RemoteModelLimits.openAICompatibleFallback.maximumOutputTokens)
        : .openAICompatibleFallback)
  }

  func configurationStatus(in workspace: SQLiteWorkspace) -> String {
    guard self != .deviceLink else {
      return model(in: workspace).map { modelDisplayName($0, in: workspace) }
        ?? LocalizedString.forKey("no_model_selected")
    }
    guard account(in: workspace) != nil else {
      return LocalizedString.forKey("remote_api_not_configured")
    }
    return LocalizedString.format(
      key: "remote_api_configured_model",
      model(in: workspace).map { modelDisplayName($0, in: workspace) }
        ?? LocalizedString.forKey("no_model_selected"))
  }

  func modelDisplayName(_ model: String, in workspace: SQLiteWorkspace) -> String {
    if self == .deviceLink {
      // As the model selector listed it: the model, then the Mac.
      return workspace.dictionary["devicelink_model_names", [String: String].self]?[model]
        ?? MacModel(model).map { LLMZoo.humanReadableNameForModel($0.file) } ?? model
    }
    guard self == .localCode else { return model }
    return workspace.dictionary["localcode_model_names", [String: String].self]?[model] ?? model
  }

  func model(in workspace: SQLiteWorkspace) -> String? {
    workspace.dictionary[appConfiguration.modelDictionaryKey, String.self]
  }

  func setModel(_ model: String, in workspace: SQLiteWorkspace) {
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { return }
    workspace.dictionary[appConfiguration.modelDictionaryKey, String.self] = model
  }

  func cachedModels(in workspace: SQLiteWorkspace) -> [String] {
    var seen = Set<String>()
    let models =
      workspace.dictionary[appConfiguration.modelsDictionaryKey, [String].self]
      ?? [model(in: workspace)].compactMap { $0 }
    return models.compactMap { model in
      let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !model.isEmpty, seen.insert(model).inserted else { return nil }
      return model
    }
  }

  func setCachedModels(_ models: [String], in workspace: SQLiteWorkspace) {
    var seen = Set<String>()
    let models = models.compactMap { model -> String? in
      let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !model.isEmpty, seen.insert(model).inserted else { return nil }
      return model
    }
    var cachedModels = models
    if self == .openAICompatible, let model = model(in: workspace), !seen.contains(model) {
      cachedModels.append(model)
    }
    workspace.dictionary[appConfiguration.modelsDictionaryKey, [String].self] = cachedModels
  }

  func hasCachedModel(_ model: String, in workspace: SQLiteWorkspace) -> Bool {
    (workspace.dictionary[appConfiguration.modelsDictionaryKey, [String].self] ?? []).contains(
      model)
  }

  func compactionThreshold(in workspace: SQLiteWorkspace) -> Double {
    let value =
      workspace.dictionary[appConfiguration.compactionThresholdDictionaryKey, Double.self]
      ?? RemoteAgentConfiguration.defaultCompactionThreshold
    return min(
      max(RemoteAgentConfiguration.minimumCompactionThreshold, value),
      RemoteAgentConfiguration.maximumCompactionThreshold)
  }

  func setCompactionThreshold(_ value: Double, in workspace: SQLiteWorkspace) {
    workspace.dictionary[appConfiguration.compactionThresholdDictionaryKey, Double.self] = min(
      max(RemoteAgentConfiguration.minimumCompactionThreshold, value),
      RemoteAgentConfiguration.maximumCompactionThreshold)
  }
}

struct RemoteProviderAccount {
  let endpoint: RemoteProviderAccountEndpoint
  let credentialIdentifier: String
  let authorization: any RemoteAuthorizationProviding
}

struct RemoteProviderProfile: Equatable {
  let endpoint: RemoteProviderEndpoint
  let modelDisplayName: String
  let credentialIdentifier: String
  let authorization: any RemoteAuthorizationProviding
  let compactionThreshold: Double
  let reasoningEffort: RemoteReasoningEffort
  let fallbackLimits: RemoteModelLimits

  var model: String { endpoint.model }

  var title: String {
    "\(endpoint.provider.appConfiguration.profileTitle) · \(modelDisplayName)"
  }

  static func == (lhs: RemoteProviderProfile, rhs: RemoteProviderProfile) -> Bool {
    lhs.endpoint == rhs.endpoint && lhs.credentialIdentifier == rhs.credentialIdentifier
      && lhs.authorization.kind == rhs.authorization.kind
      && lhs.compactionThreshold == rhs.compactionThreshold
      && lhs.reasoningEffort == rhs.reasoningEffort
      && lhs.fallbackLimits == rhs.fallbackLimits
  }
}

enum RemoteProviderConfigurationChange {
  case saved
  case removed
}

enum RemoteProviderConfiguration {
  static func present(
    _ provider: RemoteProvider, workspace: SQLiteWorkspace, on viewController: UIViewController,
    modelIsOptional: Bool = false,
    completion: @escaping (RemoteProviderConfigurationChange) -> Void
  ) {
    if provider == .localCode {
      let alertController = UIAlertController(
        title: LocalizedString.forKey("cloud_compute"),
        message: LocalizedString.forKey("cloud_compute_configuration_detail"),
        preferredStyle: .alert)
      alertController.addAction(UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
      viewController.present(alertController, animated: true)
      return
    }
    let configuration = provider.appConfiguration
    let currentModel = workspace.dictionary[configuration.modelDictionaryKey, String.self] ?? ""
    let currentBaseURL = configuration.baseURLDictionaryKey.flatMap {
      workspace.dictionary[$0, String.self]
    }
    let currentAccount = provider.account(in: workspace)
    if provider == .openAI {
      let alertController = UIAlertController(
        title: provider.title,
        message: currentAccount == nil
          ? provider.configurationDetail : provider.configurationStatus(in: workspace),
        preferredStyle: .alert)
      let signIn = UIAlertAction(
        title: LocalizedString.forKey("remote_oauth_openai_action"), style: .default
      ) { [weak viewController] _ in
        guard let viewController else { return }
        DispatchQueue.main.async {
          RemoteOAuthLogin.present(provider: .openAI, on: viewController) { result in
            switch result {
            case .success(let credential):
              do {
                try RemoteCredentialStore.upsertOAuth(
                  credential, account: RemoteProvider.openAI.defaultBaseURL!.absoluteString,
                  provider: .openAI)
                workspace.dictionary[configuration.modelsDictionaryKey, [String].self] = nil
                completion(.saved)
              } catch {
                presentError(on: viewController, message: error.localizedDescription)
              }
            case .failure(let error):
              presentError(on: viewController, message: error.localizedDescription)
            }
          }
        }
      }
      alertController.addAction(signIn)
      if let currentAccount {
        alertController.addAction(
          UIAlertAction(title: LocalizedString.forKey("sign_out"), style: .destructive) {
            [weak viewController] _ in
            guard let viewController else { return }
            do {
              try RemoteCredentialStore.delete(
                account: currentAccount.endpoint.baseURL.absoluteString, provider: .openAI)
              completion(.removed)
            } catch {
              presentError(on: viewController, message: error.localizedDescription)
            }
          })
      }
      alertController.addAction(
        UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
      alertController.preferredAction = signIn
      viewController.present(alertController, animated: true)
      return
    }
    let hasEditableBaseURL = configuration.baseURLDictionaryKey != nil
    let modelIsOptional = modelIsOptional || provider == .openAICompatible
    let showsModelField = modelIsOptional || provider != .anthropic
    let modelIndex = showsModelField ? (hasEditableBaseURL ? 1 : 0) : nil
    let keyIndex = (hasEditableBaseURL ? 1 : 0) + (showsModelField ? 1 : 0)
    let alertController: UIAlertController?
    let compatibleForm: CompatibleAPIConfigurationViewController?
    let formController: UIViewController
    let fields: [UITextField]
    if provider == .openAICompatible {
      let form = CompatibleAPIConfigurationViewController()
      form.baseURLField.text = currentBaseURL
      form.modelField.text = currentModel
      form.contextField.text = workspace.dictionary[compatibleContextWindowKey, Int.self].map(
        String.init)
      form.outputField.text = workspace.dictionary[compatibleMaximumOutputKey, Int.self].map(
        String.init)
      form.disconnectButton.isHidden = currentAccount == nil
      fields = [
        form.baseURLField, form.modelField, form.apiKeyField, form.contextField, form.outputField,
      ]
      compatibleForm = form
      alertController = nil
      formController = form
    } else {
      let alert = UIAlertController(
        title: LocalizedString.forKey(configuration.titleKey),
        message: provider.configurationDetail, preferredStyle: .alert)
      if showsModelField {
        alert.addTextField {
          $0.placeholder = LocalizedString.forKey(modelIsOptional ? "model_optional" : "model")
          $0.text = currentModel
          $0.autocapitalizationType = .none
          $0.autocorrectionType = .no
        }
      }
      alert.addTextField {
        $0.placeholder = LocalizedString.forKey("remote_api_key_placeholder")
        $0.isSecureTextEntry = true
        $0.textContentType = .password
        $0.autocapitalizationType = .none
        $0.autocorrectionType = .no
      }
      fields = alert.textFields ?? []
      compatibleForm = nil
      alertController = alert
      formController = alert
    }

    let accountEndpointFromFields: () -> RemoteProviderAccountEndpoint? = {
      let baseURL: URL
      if hasEditableBaseURL {
        let value = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: value) else { return nil }
        baseURL = url
      } else {
        guard let defaultBaseURL = provider.defaultBaseURL else { return nil }
        baseURL = defaultBaseURL
      }
      return try? RemoteProviderAccountEndpoint(provider: provider, baseURL: baseURL)
    }
    let endpointFromFields: () -> RemoteProviderEndpoint? = {
      guard let modelIndex,
        fields.indices.contains(modelIndex), let accountEndpoint = accountEndpointFromFields()
      else { return nil }
      let model = fields[modelIndex].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return try? RemoteProviderEndpoint(
        provider: provider, baseURL: accountEndpoint.baseURL, model: model)
    }
    let persistConfiguration: (RemoteProviderAccountEndpoint, RemoteProviderEndpoint?) -> Void = {
      [weak compatibleForm] accountEndpoint, endpoint in
      if let baseURLDictionaryKey = configuration.baseURLDictionaryKey {
        workspace.dictionary[baseURLDictionaryKey, String.self] =
          accountEndpoint.baseURL.absoluteString
      }
      if let endpoint {
        workspace.dictionary[configuration.modelDictionaryKey, String.self] = endpoint.model
      } else if modelIsOptional, accountEndpoint.baseURL != currentAccount?.endpoint.baseURL {
        workspace.dictionary[configuration.modelDictionaryKey, String.self] = nil
      }
      workspace.dictionary[configuration.modelsDictionaryKey, [String].self] = nil
      if let compatibleForm {
        compatibleForm.presentingViewController?.dismiss(animated: true) { completion(.saved) }
      } else {
        completion(.saved)
      }
    }

    let save = { [weak formController, weak viewController] in
      guard let formController, let viewController else { return }
      let errorPresenter = provider == .openAICompatible ? formController : viewController
      guard fields.indices.contains(keyIndex) else { return }
      guard let accountEndpoint = accountEndpointFromFields() else {
        presentError(
          on: errorPresenter,
          message: LocalizedString.forKey(configuration.invalidKey))
        return
      }
      let endpoint: RemoteProviderEndpoint?
      if let modelIndex,
        !modelIsOptional
          || !(fields[modelIndex].text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true)
      {
        guard let configuredEndpoint = endpointFromFields() else {
          presentError(
            on: errorPresenter,
            message: LocalizedString.forKey(configuration.invalidKey))
          return
        }
        endpoint = configuredEndpoint
      } else {
        endpoint = nil
      }
      let newKey = fields[keyIndex].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      var fallbackContext: Int?
      var fallbackOutput: Int?
      if provider == .openAICompatible {
        let context =
          fields[keyIndex + 1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output =
          fields[keyIndex + 2].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        fallbackContext = Int(context)
        fallbackOutput = Int(output)
        guard
          context.isEmpty || (fallbackContext.map { (4_096...10_000_000).contains($0) } ?? false),
          output.isEmpty || (fallbackOutput.map { (512...10_000_000).contains($0) } ?? false)
        else {
          presentError(
            on: errorPresenter, message: LocalizedString.forKey("remote_api_invalid_limits"))
          return
        }
      }
      let saveConfiguration = {
        if provider == .openAICompatible {
          workspace.dictionary[compatibleContextWindowKey, Int.self] =
            fallbackContext
          workspace.dictionary[compatibleMaximumOutputKey, Int.self] = fallbackOutput
        }
        persistConfiguration(accountEndpoint, endpoint)
      }
      do {
        let update = try RemoteCredentialUpdate.resolve(
          key: newKey, provider: provider,
          existing: RemoteCredentialStore.readCredential(
            account: accountEndpoint.baseURL.absoluteString, provider: provider))
        switch update {
        case .apiKey(let key):
          try RemoteCredentialStore.upsertAPIKey(
            key, account: accountEndpoint.baseURL.absoluteString, provider: provider)
        case .unchanged:
          break
        case .keyRequired:
          presentError(
            on: errorPresenter, message: LocalizedString.forKey(configuration.keyRequiredKey))
          return
        case .unauthenticated:
          if let currentAccount, currentAccount.authorization.kind != .unauthenticated {
            let confirmation = UIAlertController(
              title: LocalizedString.forKey("remote_api_without_key_title"),
              message: LocalizedString.forKey("remote_api_changed_url_without_key"),
              preferredStyle: .alert)
            confirmation.addAction(
              UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
            confirmation.addAction(
              UIAlertAction(
                title: LocalizedString.forKey("remote_api_connect_without_key"), style: .default
              ) { [weak confirmation] _ in
                do {
                  try RemoteCredentialStore.upsertUnauthenticated(
                    account: accountEndpoint.baseURL.absoluteString)
                  saveConfiguration()
                } catch {
                  confirmation?.dismiss(animated: true) {
                    presentError(on: errorPresenter, message: error.localizedDescription)
                  }
                }
              })
            formController.present(confirmation, animated: true)
            return
          }
          try RemoteCredentialStore.upsertUnauthenticated(
            account: accountEndpoint.baseURL.absoluteString)
        }
        saveConfiguration()
      } catch {
        presentError(on: errorPresenter, message: error.localizedDescription)
      }
    }
    if let compatibleForm {
      compatibleForm.saveButton.addAction(UIAction { _ in save() }, for: .touchUpInside)
      compatibleForm.cancelButton.addAction(
        UIAction { [weak compatibleForm] _ in
          compatibleForm?.dismiss(animated: true)
        }, for: .touchUpInside)
    } else if let alertController {
      let saveAction = UIAlertAction(title: LocalizedString.forKey("save"), style: .default) { _ in
        save()
      }
      alertController.addAction(saveAction)
      alertController.preferredAction = saveAction
    }
    if provider == .anthropic, let alertController {
      alertController.addAction(
        UIAlertAction(
          title: LocalizedString.forKey("remote_oauth_anthropic_action"), style: .default
        ) {
          [weak viewController] _ in
          guard let viewController, let accountEndpoint = accountEndpointFromFields() else {
            if let viewController {
              presentError(
                on: viewController, message: LocalizedString.forKey(configuration.invalidKey))
            }
            return
          }
          DispatchQueue.main.async {
            RemoteOAuthLogin.present(provider: provider, on: viewController) { result in
              switch result {
              case .success(let credential):
                do {
                  try RemoteCredentialStore.upsertOAuth(
                    credential, account: accountEndpoint.baseURL.absoluteString, provider: provider)
                  persistConfiguration(accountEndpoint, nil)
                } catch {
                  presentError(on: viewController, message: error.localizedDescription)
                }
              case .failure(let error):
                presentError(on: viewController, message: error.localizedDescription)
              }
            }
          }
        })
    }
    if let currentAccount {
      let remove = { [weak formController, weak viewController] in
        guard let formController, let viewController else { return }
        do {
          try RemoteCredentialStore.delete(
            account: currentAccount.endpoint.baseURL.absoluteString, provider: provider)
          if provider == .openAICompatible {
            formController.dismiss(animated: true) { completion(.removed) }
          } else {
            completion(.removed)
          }
        } catch {
          presentError(
            on: provider == .openAICompatible ? formController : viewController,
            message: error.localizedDescription)
        }
      }
      if let compatibleForm {
        compatibleForm.disconnectButton.addAction(UIAction { _ in remove() }, for: .touchUpInside)
      } else if let alertController {
        alertController.addAction(
          UIAlertAction(
            title: LocalizedString.forKey(
              currentAccount.authorization.kind == .oauth ? "sign_out" : "remove_api_key"),
            style: .destructive
          ) { _ in remove() })
      }
    }
    alertController?.addAction(
      UIAlertAction(title: LocalizedString.forKey("cancel"), style: .cancel))
    viewController.present(formController, animated: true)
  }

  private static func presentError(on viewController: UIViewController, message: String) {
    let alertController = UIAlertController(
      title: LocalizedString.forKey("remote_api_error"), message: message,
      preferredStyle: .alert)
    alertController.addAction(
      UIAlertAction(title: LocalizedString.forKey("ok"), style: .default))
    viewController.present(alertController, animated: true)
  }
}
