import Components
import DataModels
import Localization
import SQLiteDflat
import SnapKit
import Style
import UIKit

extension ModelIdleTimeout {
  fileprivate var title: String {
    switch self {
    case .tenSeconds: return LocalizedString.forKey("after_10_seconds")
    case .oneMinute: return LocalizedString.forKey("after_1_minute")
    case .fiveMinutes: return LocalizedString.forKey("after_5_minutes")
    case .tenMinutes: return LocalizedString.forKey("after_10_minutes")
    case .never: return LocalizedString.forKey("never")
    }
  }
}

extension SleepPrevention {
  fileprivate var title: String {
    switch self {
    case .disabled: return LocalizedString.forKey("disabled")
    case .system: return LocalizedString.forKey("system_only")
    case .systemAndDisplay: return LocalizedString.forKey("system_and_display")
    }
  }
}

enum UseAppleNeuralEngineOption {
  case automatic
  case yesPreferAppleNeuralEngineOnly
  case yesPreferAppleNeuralEngineAndGPU
  case no
}

extension UseAppleNeuralEngineOption {
  fileprivate var title: String {
    switch self {
    case .automatic: return LocalizedString.forKey("automatic")
    case .yesPreferAppleNeuralEngineOnly:
      return LocalizedString.forKey("yes_prefer_apple_neural_engine_only")
    case .yesPreferAppleNeuralEngineAndGPU:
      return LocalizedString.forKey("yes_prefer_apple_neural_engine_and_gpu")
    case .no: return LocalizedString.forKey("no")
    }
  }
}

enum LanguageSettingsOption {
  case english
  case spanish
  case simplifiedChinese
  case traditionalChinese
  case japanese
  case korean
  case french
  case german
  case vietnamese
}

private func makeLanguageSettingsMenu(
  _ current: LanguageSettingsOption, handler: @escaping (LanguageSettingsOption) -> Void
) -> UIMenu {
  return UIMenu(children: [
    UIAction(title: LocalizedString.forKey("english"), state: current == .english ? .on : .off) {
      _ in
      handler(.english)
    },
    UIAction(title: LocalizedString.forKey("spanish"), state: current == .spanish ? .on : .off) {
      _ in
      handler(.spanish)
    },
    UIAction(
      title: LocalizedString.forKey("simplified_chinese"),
      state: current == .simplifiedChinese ? .on : .off
    ) { _ in
      handler(.simplifiedChinese)
    },
    UIAction(
      title: LocalizedString.forKey("traditional_chinese"),
      state: current == .traditionalChinese ? .on : .off
    ) { _ in
      handler(.traditionalChinese)
    },
    UIAction(title: LocalizedString.forKey("japanese"), state: current == .japanese ? .on : .off) {
      _ in
      handler(.japanese)
    },
    UIAction(title: LocalizedString.forKey("korean"), state: current == .korean ? .on : .off) {
      _ in
      handler(.korean)
    },
    UIAction(title: LocalizedString.forKey("french"), state: current == .french ? .on : .off) {
      _ in
      handler(.french)
    },
    UIAction(title: LocalizedString.forKey("german"), state: current == .german ? .on : .off) {
      _ in
      handler(.german)
    },
    UIAction(
      title: LocalizedString.forKey("vietnamese"), state: current == .vietnamese ? .on : .off
    ) { _ in
      handler(.vietnamese)
    },
  ])
}

private func makeFontSizeSettingsMenu(
  _ current: FontSizeCategory, handler: @escaping (FontSizeCategory) -> Void
) -> UIMenu {
  return UIMenu(children: [
    UIAction(
      title: LocalizedString.forKey("extra_small"), state: current == .extraSmall ? .on : .off
    ) { _ in
      handler(.extraSmall)
    },
    UIAction(title: LocalizedString.forKey("small"), state: current == .small ? .on : .off) {
      _ in
      handler(.small)
    },
    UIAction(title: LocalizedString.forKey("normal"), state: current == .normal ? .on : .off) {
      _ in
      handler(.normal)
    },
    UIAction(title: LocalizedString.forKey("large"), state: current == .large ? .on : .off) {
      _ in
      handler(.large)
    },
    UIAction(
      title: LocalizedString.forKey("extra_large"), state: current == .extraLarge ? .on : .off
    ) { _ in
      handler(.extraLarge)
    },
  ])
}

private func makeUseAppleNeuralEngineMenu(
  _ current: UseAppleNeuralEngineOption, default: UseAppleNeuralEngineOption,
  handler: @escaping (UseAppleNeuralEngineOption) -> Void
) -> UIMenu {
  return UIMenu(children: [
    UIAction(
      title: LocalizedString.format(key: "automatic_state", `default`.title),
      state: current == .automatic ? .on : .off
    ) { _ in
      handler(.automatic)
    },
    UIAction(
      title: UseAppleNeuralEngineOption.yesPreferAppleNeuralEngineOnly.title,
      state: current == .yesPreferAppleNeuralEngineOnly ? .on : .off
    ) { _ in
      handler(.yesPreferAppleNeuralEngineOnly)
    },
    UIAction(
      title: UseAppleNeuralEngineOption.yesPreferAppleNeuralEngineAndGPU.title,
      state: current == .yesPreferAppleNeuralEngineAndGPU ? .on : .off
    ) { _ in
      handler(.yesPreferAppleNeuralEngineAndGPU)
    },
    UIAction(title: LocalizedString.forKey("no"), state: current == .no ? .on : .off) { _ in
      handler(.no)
    },
  ])
}

extension DeviceCapability.WeightsStreaming {
  fileprivate var title: String {
    switch self {
    case .disabled:
      return LocalizedString.forKey("disabled")
    case ._8GiB, ._16GiB, ._24GiB, ._32GiB, ._40GiB, ._48GiB, ._56GiB, ._64GiB, ._72GiB:
      return "\(rawValue) GiB"
    }
  }
}

private func makeWeightsStreamingMenu(
  _ current: DeviceCapability.WeightsStreaming?,
  default defaultTier: DeviceCapability.WeightsStreaming,
  handler: @escaping (DeviceCapability.WeightsStreaming?) -> Void
) -> UIMenu {
  var actions = [
    UIAction(
      title: LocalizedString.format(key: "automatic_state", defaultTier.title),
      state: current == nil ? .on : .off
    ) { _ in
      handler(nil)
    }
  ]
  for tier in DeviceCapability.WeightsStreaming.allCases {
    actions.append(
      UIAction(title: tier.title, state: current == tier ? .on : .off) { _ in
        handler(tier)
      })
  }
  return UIMenu(children: actions)
}

protocol MachineSettingsViewControllerDelegate: AnyObject {
  func didTapClose()
  func didSelectUseAppleNeuralEngine(_: UseAppleNeuralEngineOption)
  func didSelectWeightsStreaming(
    _: DeviceCapability.WeightsStreaming?)
  func didTapCleanupTmpDir()
  func didTapResetToDefault()
  func didSelectLanguage(_: LanguageSettingsOption)
  func didSelectFontSize(_: FontSizeCategory)
  func didUseSystemDownloaderUpdated(_: Bool)
  func didBotModeUpdated(_: Bool)
  func didLockdownModeUpdated(_: Bool)
  func didReduceReasoningAnimationUpdated(_: Bool)
  func didPrefillWarmupUpdated(_: Bool)
  func didSelectModelIdleTimeout(_: ModelIdleTimeout)
  func didSelectSleepPrevention(_: SleepPrevention)
}

private enum MachineSettingsSection: Equatable, Hashable {
  case prefillWarmup
  case modelIdleTimeout
  case sleepPrevention
  case botMode
  case systemDownloader
  case useAppleNeuralEngineFor8BitSModels
  case weightsStreaming
  case temporaryDirectory
  case lockdownMode
  case languageSettings
  case fontSize
  case reduceReasoningAnimation
}

final class MachineSettingsViewController: UIViewController, EscapeKeyDismissible {
  weak var delegate: MachineSettingsViewControllerDelegate?

  var modelIdleTimeout = ModelIdleTimeout.default {
    didSet {
      guard modelIdleTimeout != oldValue else { return }
      updateSettingsSections()
    }
  }

  var sleepPrevention = SleepPrevention.default {
    didSet {
      guard sleepPrevention != oldValue else { return }
      updateSettingsSections()
    }
  }

  var prefillWarmup: Bool = false {
    didSet {
      guard prefillWarmup != oldValue else { return }
      updateSettingsSections()
    }
  }

  override var keyCommands: [UIKeyCommand]? {
    let command = UIKeyCommand(
      input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissWithEscape))
    command.wantsPriorityOverSystemBehavior = true
    return [command]
  }

  var languageSettings: LanguageSettingsOption = .english {
    didSet {
      guard languageSettings != oldValue else { return }
      updateSettingsSections()
    }
  }
  var fontSizeSettings: FontSizeCategory = FontMetrics.systemDefaultFontSizeCategory {
    didSet {
      guard fontSizeSettings != oldValue else { return }
      updateSettingsSections()
    }
  }
  var useAppleNeuralEngineFor8BitSModels: UseAppleNeuralEngineOption = .automatic {
    didSet {
      guard useAppleNeuralEngineFor8BitSModels != oldValue else { return }
      updateSettingsSections()
    }
  }
  var weightsStreaming: DeviceCapability.WeightsStreaming?
  {
    didSet {
      guard weightsStreaming != oldValue else { return }
      updateSettingsSections()
    }
  }
  var isBotModeEnabled = false {
    didSet {
      guard isBotModeEnabled != oldValue else { return }
      updateSettingsSections()
    }
  }
  var isLockdownModeEnabled = false {
    didSet {
      guard isLockdownModeEnabled != oldValue else { return }
      updateSettingsSections()
    }
  }
  var isReduceReasoningAnimationEnabled = false {
    didSet {
      guard isReduceReasoningAnimationEnabled != oldValue else { return }
      updateSettingsSections()
    }
  }
  var useSystemDownloader: Bool = false {
    didSet {
      guard useSystemDownloader != oldValue else { return }
      updateSettingsSections()
    }
  }

  private let defaultUseAppleNeuralEngineFor8BitSModels: UseAppleNeuralEngineOption
  private let defaultWeightsStreaming: DeviceCapability.WeightsStreaming
  private let workspace: SQLiteWorkspace
  private let userInterfaceIdiom: UIUserInterfaceIdiom
  private lazy var stackView = UIStackView(frame: .zero)
  private var gradientLayer: CAGradientLayer?
  private var itemReconciler:
    SettingsItemReconciler<
      MachineSettingsSection, KeyValuePairs<MachineSettingsSection, any SettingsViewObservable>
    >?

  private lazy var xButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "close-16").withRenderingMode(
      .alwaysTemplate)
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.background.backgroundColor =
        $0.isHighlighted || $0.state.contains(.focused) ? .quinaryBackground : .clear
      $0.configuration = configuration
    }
    button.addAction(
      UIAction { [weak self] _ in
        self?.delegate?.didTapClose()
      }, for: .touchUpInside)
    return button
  }()

  private lazy var titleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = LocalizedString.forKey("machine_settings")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15, weight: .medium), bindTo: label)
    return label
  }()

  private lazy var restoreButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("restore_default")
    configuration.background.cornerRadius = 8
    configuration.baseBackgroundColor = .primaryFill
    configuration.baseForegroundColor = .nonaryText
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 16, bottom: 0, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        self?.delegate?.didTapResetToDefault()
      }, for: .touchUpInside)
    return button
  }()

  private lazy var topDivider: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .primaryBorder
    view.isUserInteractionEnabled = false
    return view
  }()

  init(
    defaultUseAppleNeuralEngineFor8BitSModels: UseAppleNeuralEngineOption,
    workspace: SQLiteWorkspace,
    defaultWeightsStreaming:
      DeviceCapability.WeightsStreaming,
    userInterfaceIdiom: UIUserInterfaceIdiom
  ) {
    self.defaultUseAppleNeuralEngineFor8BitSModels = defaultUseAppleNeuralEngineFor8BitSModels
    self.defaultWeightsStreaming =
      defaultWeightsStreaming
    self.workspace = workspace
    self.userInterfaceIdiom = userInterfaceIdiom
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .secondaryBackground

    view.addSubview(xButton)
    xButton.snp.makeConstraints { make in
      make.top.equalTo(view.snp.topMargin).offset(10)
      make.trailing.equalToSuperview().offset(-14)
      make.width.height.equalTo(32)
    }

    view.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.centerY.equalTo(xButton)
      make.leading.equalToSuperview().offset(24)
      make.trailing.lessThanOrEqualTo(xButton.snp.leading).offset(-12)
    }

    view.addSubview(topDivider)
    topDivider.snp.makeConstraints { make in
      make.bottom.equalTo(view.snp.topMargin).offset(52)
      make.height.equalTo(1)
      make.leading.trailing.equalToSuperview()
    }

    let scrollView = UIScrollView(frame: .zero)
    scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 20, left: 0, bottom: 80, right: 0)
    #if targetEnvironment(macCatalyst)
      scrollView.showsVerticalScrollIndicator = false
    #endif
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.automaticallyAdjustsScrollIndicatorInsets = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 80, right: 0)
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(52)
      if userInterfaceIdiom == .phone && UIScreen.main.isAllScreen {
        make.bottom.equalTo(view.snp.bottomMargin).offset(12)
      } else {
        make.bottom.equalTo(view.snp.bottomMargin)
      }
      if userInterfaceIdiom == .phone {
        make.leading.equalToSuperview().offset(12)
        make.trailing.equalToSuperview()
      } else {
        make.leading.equalToSuperview().offset(20)
        make.trailing.equalToSuperview().offset(-8)
      }
    }

    stackView.axis = .vertical
    stackView.distribution = .equalSpacing
    stackView.alignment = .fill
    stackView.spacing = 8
    scrollView.addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.top.bottom.equalTo(scrollView.contentLayoutGuide)
      if userInterfaceIdiom == .phone {
        make.leading.trailing.equalTo(scrollView.contentLayoutGuide).inset(12)
        make.width.equalTo(scrollView.frameLayoutGuide).offset(-24)
      } else {
        make.leading.trailing.equalTo(scrollView.contentLayoutGuide).inset(20)
        make.width.equalTo(scrollView.frameLayoutGuide).offset(-40)
      }
    }

    var itemReconciler = SettingsItemReconciler<
      MachineSettingsSection, KeyValuePairs<MachineSettingsSection, any SettingsViewObservable>
    >(view: stackView)
    itemReconciler.items = makeSections()
    self.itemReconciler = itemReconciler

    let overshadowView = UIView(frame: .zero)
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.secondaryBackground.withAlphaComponent(0).cgColor,
      UIColor.secondaryBackground.cgColor,
      UIColor.secondaryBackground.cgColor,
    ]
    gradientLayer.locations = [0, 0.5, 1]
    gradientLayer.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 80)
    self.gradientLayer = gradientLayer
    overshadowView.layer.addSublayer(gradientLayer)
    overshadowView.clipsToBounds = true
    view.addSubview(overshadowView)
    overshadowView.snp.makeConstraints { make in
      make.height.equalTo(80)
      make.leading.trailing.equalToSuperview()
      if userInterfaceIdiom == .phone && UIScreen.main.isAllScreen {
        make.bottom.equalTo(view.snp.bottomMargin).offset(12)
      } else {
        make.bottom.equalTo(view.snp.bottomMargin)
      }
    }

    view.addSubview(restoreButton)
    restoreButton.snp.makeConstraints { make in
      make.leading.greaterThanOrEqualToSuperview().offset(20)
      make.trailing.equalToSuperview().offset(-20)
      make.height.equalTo(40)
      make.centerY.equalTo(overshadowView)
    }
  }

  @objc func dismissWithEscape() {
    delegate?.didTapClose()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    gradientLayer?.colors = [
      UIColor.secondaryBackground.withAlphaComponent(0).cgColor,
      UIColor.secondaryBackground.cgColor,
      UIColor.secondaryBackground.cgColor,
    ]
  }

  private func updateSettingsSections() {
    itemReconciler?.items = makeSections()
  }

  private func makeSections() -> KeyValuePairs<
    MachineSettingsSection, any SettingsViewObservable
  > {
    return [
      .prefillWarmup: prefillWarmupSection(),
      .modelIdleTimeout: modelIdleTimeoutSection(),
      .sleepPrevention: sleepPreventionSection(),
      .systemDownloader: systemDownloaderSection(),
      .useAppleNeuralEngineFor8BitSModels: useAppleNeuralEngineFor8BitSModelsSection(),
      .weightsStreaming: weightsStreamingSection(),
      .temporaryDirectory: temporaryDirectorySection(),
      .lockdownMode: lockdownModeSection(),
      .languageSettings: languageSettingsSection(),
      .fontSize: fontSizeSection(),
      .reduceReasoningAnimation: reduceReasoningAnimationSection(),
      .botMode: botModeSection(),
    ]
  }

  private func modelIdleTimeoutSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: modelIdleTimeout.title,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] _, button in
            guard let self else { return }
            button?.menu = UIMenu(
              children: ModelIdleTimeout.allCases.map { timeout in
                UIAction(title: timeout.title, state: self.modelIdleTimeout == timeout ? .on : .off)
                {
                  [weak self] _ in
                  self?.delegate?.didSelectModelIdleTimeout(timeout)
                }
              })
            button?.setTitle(self.modelIdleTimeout.title, for: .normal)
          })
      ], title: LocalizedString.forKey("unload_models_when_idle"),
      detail: LocalizedString.forKey("unload_models_when_idle_detail"),
      lookUpKey: "unload_models_when_idle_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private func sleepPreventionSection() -> SettingsSectionItem {
    #if targetEnvironment(macCatalyst)
      let detail = LocalizedString.forKey("prevent_sleep_while_working_detail")
    #else
      let detail = LocalizedString.forKey("prevent_sleep_while_working_ios_detail")
    #endif
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: sleepPrevention.title,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] _, button in
            guard let self else { return }
            button?.menu = UIMenu(
              children: SleepPrevention.options.map { prevention in
                UIAction(
                  title: prevention.title, state: self.sleepPrevention == prevention ? .on : .off
                ) { [weak self] _ in
                  self?.delegate?.didSelectSleepPrevention(prevention)
                }
              })
            button?.setTitle(self.sleepPrevention.title, for: .normal)
          })
      ], title: LocalizedString.forKey("prevent_sleep_while_working"),
      detail: detail,
      lookUpKey: "prevent_sleep_while_working_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private func prefillWarmupSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(
          value: prefillWarmup, title: LocalizedString.forKey("enable"),
          handleValueChange: { [weak self] value in
            self?.delegate?.didPrefillWarmupUpdated(value)
          })
      ], title: LocalizedString.forKey("prefill_warmup"),
      detail: LocalizedString.forKey("prefill_warmup_detail"),
      lookUpKey: "prefill_warmup_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private func botModeSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(
          value: isBotModeEnabled, title: LocalizedString.forKey("enable"),
          handleValueChange: { [weak self] value in
            self?.delegate?.didBotModeUpdated(value)
          })
      ], title: LocalizedString.forKey("bot_mode"),
      detail: LocalizedString.forKey("bot_mode_detail"),
      lookUpKey: "bot_mode_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private func lockdownModeSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(
          value: isLockdownModeEnabled, title: LocalizedString.forKey("enable"),
          handleValueChange: { [weak self] value in
            self?.delegate?.didLockdownModeUpdated(value)
          })
      ], title: LocalizedString.forKey("lockdown_mode"),
      detail: LocalizedString.forKey("lockdown_mode_detail"),
      lookUpKey: "lockdown_mode_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private func reduceReasoningAnimationSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(
          value: isReduceReasoningAnimationEnabled, title: LocalizedString.forKey("enable"),
          handleValueChange: { [weak self] value in
            self?.delegate?.didReduceReasoningAnimationUpdated(value)
          })
      ], title: LocalizedString.forKey("reduce_reasoning_animation"),
      detail: LocalizedString.forKey("reduce_reasoning_animation_detail"),
      lookUpKey: "reduce_reasoning_animation_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private func systemDownloaderSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(
          value: useSystemDownloader, title: LocalizedString.forKey("enable"),
          handleValueChange: { [weak self] value in
            self?.delegate?.didUseSystemDownloaderUpdated(value)
          })
      ], title: LocalizedString.forKey("system_downloader"),
      detail: LocalizedString.forKey("system_downloader_detail"),
      lookUpKey: "system_downloader_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private var useAppleNeuralEngineFor8BitSModelsTitle: String {
    switch useAppleNeuralEngineFor8BitSModels {
    case .automatic:
      return LocalizedString.format(
        key: "automatic_state", defaultUseAppleNeuralEngineFor8BitSModels.title)
    case .yesPreferAppleNeuralEngineOnly, .yesPreferAppleNeuralEngineAndGPU, .no:
      return useAppleNeuralEngineFor8BitSModels.title
    }
  }

  private func useAppleNeuralEngineFor8BitSModelsSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: useAppleNeuralEngineFor8BitSModelsTitle,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] _, button in
            guard let self else { return }
            button?.menu = makeUseAppleNeuralEngineMenu(
              self.useAppleNeuralEngineFor8BitSModels,
              default: self.defaultUseAppleNeuralEngineFor8BitSModels
            ) { [weak self] useAppleNeuralEngineFor8BitSModels in
              self?.delegate?.didSelectUseAppleNeuralEngine(useAppleNeuralEngineFor8BitSModels)
            }
            button?.setTitle(self.useAppleNeuralEngineFor8BitSModelsTitle, for: .normal)
          })
      ], title: LocalizedString.forKey("use_apple_neural_engine_for_8bit_s_models"),
      detail: LocalizedString.forKey("apple_neural_engine_for_8bit_s_models_detail"),
      lookUpKey: "apple_neural_engine_for_8bit_s_models_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private var weightsStreamingTitle: String {
    guard let weightsStreaming else {
      return LocalizedString.format(
        key: "automatic_state", defaultWeightsStreaming.title)
    }
    return weightsStreaming.title
  }

  private func weightsStreamingSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: weightsStreamingTitle,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] _, button in
            guard let self else { return }
            button?.menu = makeWeightsStreamingMenu(
              self.weightsStreaming,
              default: self.defaultWeightsStreaming
            ) { [weak self] tier in
              self?.delegate?.didSelectWeightsStreaming(tier)
            }
            button?.setTitle(self.weightsStreamingTitle, for: .normal)
          })
      ], title: LocalizedString.forKey("weights_streaming"),
      detail: LocalizedString.forKey("weights_streaming_detail"),
      lookUpKey: "weights_streaming_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private func temporaryDirectorySection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: LocalizedString.forKey("cleanup"),
          buttonImage: UIImage(named: "arrow-right") ?? UIImage(systemName: "arrow.right"),
          buttonAction: { [weak self] _, _ in
            self?.delegate?.didTapCleanupTmpDir()
          },
          makeButtonsUI: { _, button in
            button?.setTitle(LocalizedString.forKey("cleanup"), for: .normal)
          })
      ], title: LocalizedString.forKey("temporary_directory"),
      detail: LocalizedString.forKey("temporary_directory_detail"),
      lookUpKey: "temporary_directory_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private var languageSettingsTitle: String {
    switch languageSettings {
    case .english:
      return LocalizedString.forKey("english")
    case .spanish:
      return LocalizedString.forKey("spanish")
    case .simplifiedChinese:
      return LocalizedString.forKey("simplified_chinese")
    case .traditionalChinese:
      return LocalizedString.forKey("traditional_chinese")
    case .japanese:
      return LocalizedString.forKey("japanese")
    case .korean:
      return LocalizedString.forKey("korean")
    case .french:
      return LocalizedString.forKey("french")
    case .german:
      return LocalizedString.forKey("german")
    case .vietnamese:
      return LocalizedString.forKey("vietnamese")
    }
  }

  private func languageSettingsSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: languageSettingsTitle,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] _, button in
            guard let self else { return }
            button?.menu = makeLanguageSettingsMenu(self.languageSettings) {
              [weak self] languageSettings in
              self?.delegate?.didSelectLanguage(languageSettings)
            }
            button?.setTitle(self.languageSettingsTitle, for: .normal)
          })
      ], title: LocalizedString.forKey("language_settings"),
      detail: LocalizedString.forKey("language_settings_detail"),
      lookUpKey: "language_settings_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }

  private var fontSizeTitle: String {
    switch fontSizeSettings {
    case .extraSmall:
      return LocalizedString.forKey("extra_small")
    case .small:
      return LocalizedString.forKey("small")
    case .normal:
      return LocalizedString.forKey("normal")
    case .large:
      return LocalizedString.forKey("large")
    case .extraLarge:
      return LocalizedString.forKey("extra_large")
    }
  }

  private func fontSizeSection() -> SettingsSectionItem {
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: fontSizeTitle,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] _, button in
            guard let self else { return }
            button?.menu = makeFontSizeSettingsMenu(self.fontSizeSettings) {
              [weak self] fontSize in
              self?.delegate?.didSelectFontSize(fontSize)
            }
            button?.setTitle(self.fontSizeTitle, for: .normal)
          })
      ], title: LocalizedString.forKey("font_size_settings"),
      detail: LocalizedString.forKey("font_size_settings_detail"),
      lookUpKey: "font_size_settings_detail_hidden",
      individualSectionStyle: false,
      workspace: workspace)
  }
}
