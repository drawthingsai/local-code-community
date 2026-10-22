import DataModels
import Dflat
import SQLiteDflat
import Style
import UIKit

protocol MachineSettingsWorkflowDelegate: AnyObject {
  func didDismiss(workflow: MachineSettingsWorkflow)
}

final class MachineSettingsWorkflow: Workflow {
  var viewControllable: UIViewController { viewController }

  private let workspace: SQLiteWorkspace
  private let queue: DispatchQueue
  private let viewController: MachineSettingsViewController
  private var prefillWarmupSubscription: Workspace.Subscription?
  private var modelIdleTimeoutSubscription: Workspace.Subscription?
  private var useAppleNeuralEngineFor8BitSModelsSubscription: Workspace.Subscription?
  private var weightsStreamingSubscription: Workspace.Subscription?
  private var useSystemDownloaderSubscription: Workspace.Subscription?
  private var botModeSubscription: Workspace.Subscription?
  private var lockdownModeSubscription: Workspace.Subscription?
  private var reduceReasoningAnimationSubscription: Workspace.Subscription?

  final class ObjCResponder: NSObject {
    weak var workflow: MachineSettingsWorkflow?
  }

  private let objCResponder = ObjCResponder()
  weak var delegate: MachineSettingsWorkflowDelegate?

  init(workspace: SQLiteWorkspace, userInterfaceIdiom: UIUserInterfaceIdiom, queue: DispatchQueue) {
    self.workspace = workspace
    self.queue = queue
    viewController = MachineSettingsViewController(
      defaultUseAppleNeuralEngineFor8BitSModels: DeviceCapability.isMFAAppleNeuralEngineFaster
        ? .yesPreferAppleNeuralEngineAndGPU : .no,
      workspace: workspace,
      defaultWeightsStreaming:
        DeviceCapability.weightsStreaming,
      userInterfaceIdiom: userInterfaceIdiom)
    viewController.modalPresentationStyle = .formSheet
    viewController.delegate = self
    objCResponder.workflow = self

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
      self.viewController.modelIdleTimeout =
        rawValue.flatMap(ModelIdleTimeout.init(rawValue:)) ?? .default
    }
    prefillWarmupSubscription = workspace.dictionary.subscribe("prefill_warmup", of: Bool.self) {
      [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.viewController.prefillWarmup = DeviceCapability.isPrefillWarmupPreferred
      case .initial(let value):
        self.viewController.prefillWarmup = value ?? DeviceCapability.isPrefillWarmupPreferred
      case .updated(let value):
        self.viewController.prefillWarmup = value
      }
    }
    useAppleNeuralEngineFor8BitSModelsSubscription = workspace.dictionary.subscribe(
      "use_mfa_apple_neural_engine_v2", of: Int.self
    ) { [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.updateUseAppleNeuralEngineFor8BitSModels(nil)
      case .initial(let value):
        self.updateUseAppleNeuralEngineFor8BitSModels(value)
      case .updated(let value):
        self.updateUseAppleNeuralEngineFor8BitSModels(value)
      }
    }
    useSystemDownloaderSubscription = workspace.dictionary.subscribe(
      "use_system_downloader", of: Bool.self
    ) { [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.updateUseSystemDownloader(false)
      case .initial(let value):
        self.updateUseSystemDownloader(value ?? false)
      case .updated(let value):
        self.updateUseSystemDownloader(value)
      }
    }
    botModeSubscription = workspace.dictionary.subscribe("bot_mode", of: Bool.self) {
      [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.viewController.isBotModeEnabled = false
      case .initial(let value):
        self.viewController.isBotModeEnabled = value ?? false
      case .updated(let value):
        self.viewController.isBotModeEnabled = value
      }
    }
    lockdownModeSubscription = workspace.dictionary.subscribe("lockdown_mode", of: Bool.self) {
      [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.viewController.isLockdownModeEnabled = false
      case .initial(let value):
        self.viewController.isLockdownModeEnabled = value ?? false
      case .updated(let value):
        self.viewController.isLockdownModeEnabled = value
      }
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
    weightsStreamingSubscription = workspace.dictionary.subscribe(
      "weights_streaming", of: Int.self
    ) { [weak self] value in
      guard let self else { return }
      switch value {
      case .deleted:
        self.updateWeightsStreaming(nil)
      case .initial(let value):
        self.updateWeightsStreaming(value)
      case .updated(let value):
        self.updateWeightsStreaming(value)
      }
    }

    if let currentLanguages = UserDefaults.standard.object(forKey: "AppleLanguages") as? [String],
      let currentLanguage = currentLanguages.first
    {
      viewController.languageSettings = Self.languageSettingsOption(for: currentLanguage)
    } else {
      viewController.languageSettings = Self.languageSettingsOption(for: nil)
    }
    viewController.fontSizeSettings = FontMetrics.default.size
  }

  func didPresentMachineSettingsView() {
    viewController.presentationController?.delegate = objCResponder
  }

  private func didDismissView() {
    delegate?.didDismiss(workflow: self)
  }

  private static func languageSettingsOption(for optionalLanguageCode: String?)
    -> LanguageSettingsOption
  {
    let localLanguageCode = Locale.current.languageCode ?? "en"
    let scriptCode = Locale.current.scriptCode ?? ""
    let languageCode = optionalLanguageCode ?? "\(localLanguageCode)-\(scriptCode)"

    if languageCode.hasPrefix("en") {
      return .english
    } else if languageCode.hasPrefix("es") {
      return .spanish
    } else if languageCode.hasPrefix("zh-Hant") {
      return .traditionalChinese
    } else if languageCode.hasPrefix("zh") {
      return .simplifiedChinese
    } else if languageCode.hasPrefix("ja") {
      return .japanese
    } else if languageCode.hasPrefix("ko") {
      return .korean
    } else if languageCode.hasPrefix("fr") {
      return .french
    } else if languageCode.hasPrefix("de") {
      return .german
    } else if languageCode.hasPrefix("vi") {
      return .vietnamese
    }
    return .english
  }

  private func updateUseAppleNeuralEngineFor8BitSModels(_ value: Int?) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let value = value.flatMap(DeviceCapability.AppleNeuralEngineState.init(rawValue:)) else {
      viewController.useAppleNeuralEngineFor8BitSModels = .automatic
      return
    }
    switch value {
    case .disabled:
      viewController.useAppleNeuralEngineFor8BitSModels = .no
    case .appleNeuralEngineOnly:
      viewController.useAppleNeuralEngineFor8BitSModels = .yesPreferAppleNeuralEngineOnly
    case .appleNeuralEngineAndGPU:
      viewController.useAppleNeuralEngineFor8BitSModels = .yesPreferAppleNeuralEngineAndGPU
    }
  }

  private func updateUseSystemDownloader(_ value: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    viewController.useSystemDownloader = value
  }

  private func updateWeightsStreaming(_ value: Int?) {
    dispatchPrecondition(condition: .onQueue(.main))
    viewController.weightsStreaming = value.flatMap(
      DeviceCapability.WeightsStreaming.init(rawValue:))
  }
}

extension MachineSettingsWorkflow.ObjCResponder: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    workflow?.didDismissView()
  }
}

extension MachineSettingsWorkflow: MachineSettingsViewControllerDelegate {
  func didTapClose() {
    viewController.dismiss(animated: true) { [weak self] in
      self?.didDismissView()
    }
  }

  func didSelectUseAppleNeuralEngine(_ useAppleNeuralEngine: UseAppleNeuralEngineOption) {
    switch useAppleNeuralEngine {
    case .automatic:
      workspace.dictionary["use_mfa_apple_neural_engine_v2", Int.self] = nil
    case .yesPreferAppleNeuralEngineOnly:
      workspace.dictionary["use_mfa_apple_neural_engine_v2", Int.self] =
        DeviceCapability.AppleNeuralEngineState.appleNeuralEngineOnly.rawValue
    case .yesPreferAppleNeuralEngineAndGPU:
      workspace.dictionary["use_mfa_apple_neural_engine_v2", Int.self] =
        DeviceCapability.AppleNeuralEngineState.appleNeuralEngineAndGPU.rawValue
    case .no:
      workspace.dictionary["use_mfa_apple_neural_engine_v2", Int.self] =
        DeviceCapability.AppleNeuralEngineState.disabled.rawValue
    }
  }

  func didBotModeUpdated(_ value: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["bot_mode", Bool.self] = value
  }

  func didLockdownModeUpdated(_ value: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["lockdown_mode", Bool.self] = value
  }

  func didReduceReasoningAnimationUpdated(_ value: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["reduce_reasoning_animation", Bool.self] = value
  }

  func didPrefillWarmupUpdated(_ value: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["prefill_warmup", Bool.self] = value
  }

  func didSelectModelIdleTimeout(_ timeout: ModelIdleTimeout) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["model_idle_timeout", Int.self] = timeout.rawValue
  }

  func didUseSystemDownloaderUpdated(_ value: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    workspace.dictionary["use_system_downloader", Bool.self] = value
  }

  func didSelectWeightsStreaming(
    _ tier: DeviceCapability.WeightsStreaming?
  ) {
    workspace.dictionary["weights_streaming", Int.self] = tier?.rawValue
  }

  func didTapCleanupTmpDir() {
    queue.async {
      let fileManager = FileManager.default
      let tmpDir = NSTemporaryDirectory()
      if let directories = try? fileManager.contentsOfDirectory(atPath: tmpDir) {
        for directory in directories {
          try? fileManager.removeItem(
            atPath: (tmpDir as NSString).appendingPathComponent(directory))
        }
      }
      let urls = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
      if let documentUrl = urls.first {
        let trashUrl = documentUrl.appendingPathComponent(".Trash")
        if let directories = try? fileManager.contentsOfDirectory(atPath: trashUrl.path) {
          for directory in directories {
            try? fileManager.removeItem(at: trashUrl.appendingPathComponent(directory))
          }
        }
      }
      if let cacheUrl = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
        let bundleIdentifier = Bundle.main.bundleIdentifier
      {
        let appUrl = cacheUrl.appendingPathComponent(bundleIdentifier)
        if let directories = try? fileManager.contentsOfDirectory(atPath: appUrl.path) {
          for directory in directories {
            guard directory.contains(".metal") || directory.contains(".gpu") else { continue }
            try? fileManager.removeItem(at: appUrl.appendingPathComponent(directory))
          }
        }
        let mfaV2Url = cacheUrl.appendingPathComponent("mfa_v2")
        if let directories = try? fileManager.contentsOfDirectory(atPath: mfaV2Url.path) {
          for directory in directories {
            try? fileManager.removeItem(at: mfaV2Url.appendingPathComponent(directory))
          }
        }
      }
    }
  }

  func didTapResetToDefault() {
    workspace.dictionary["model_idle_timeout", Int.self] = nil
    workspace.dictionary["prefill_warmup", Bool.self] = nil
    workspace.dictionary["bot_mode", Bool.self] = nil
    workspace.dictionary["lockdown_mode", Bool.self] = nil
    workspace.dictionary["reduce_reasoning_animation", Bool.self] = nil
    workspace.dictionary["use_mfa_apple_neural_engine_v2", Int.self] = nil
    workspace.dictionary["use_system_downloader", Bool.self] = nil
    workspace.dictionary["weights_streaming", Int.self] = nil

    viewController.languageSettings = Self.languageSettingsOption(for: nil)
    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    viewController.fontSizeSettings = FontMetrics.systemDefaultFontSizeCategory
    FontMetrics.default.size = FontMetrics.systemDefaultFontSizeCategory
    UserDefaults.standard.removeObject(forKey: "AppFontSize")
  }

  func didSelectLanguage(_ languageSettings: LanguageSettingsOption) {
    let languageCode: String
    switch languageSettings {
    case .english:
      languageCode = "en"
    case .spanish:
      languageCode = "es"
    case .simplifiedChinese:
      languageCode = "zh-Hans"
    case .traditionalChinese:
      languageCode = "zh-Hant"
    case .japanese:
      languageCode = "ja"
    case .korean:
      languageCode = "ko"
    case .french:
      languageCode = "fr"
    case .german:
      languageCode = "de"
    case .vietnamese:
      languageCode = "vi"
    }
    viewController.languageSettings = languageSettings
    UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
  }

  func didSelectFontSize(_ fontSizeSettings: FontSizeCategory) {
    FontMetrics.default.size = fontSizeSettings
    viewController.fontSizeSettings = fontSizeSettings
  }
}
