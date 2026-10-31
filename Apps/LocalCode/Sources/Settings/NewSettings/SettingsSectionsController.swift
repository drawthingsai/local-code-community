import Components
import Localization
import RemoteAPI
import SQLiteDflat
import SnapKit
import Style
import UIKit
import WebSearch

private enum SettingsSection: CaseIterable, Hashable {
  case whereModelsRun
  case reasoningEffort
  case thinkingBudget
  case searchProvider
  case workAttitude
  case memory
}

extension ReasoningEffort {
  var title: String {
    switch self {
    case .low:
      return LocalizedString.forKey("low")
    case .medium:
      return LocalizedString.forKey("medium")
    case .high:
      return LocalizedString.forKey("high")
    case .max:
      return LocalizedString.forKey("max")
    }
  }
}

enum WorkAttitude: String, Codable, CaseIterable {
  case deterministic
  case creative

  var title: String {
    switch self {
    case .deterministic:
      return LocalizedString.forKey("deterministic")
    case .creative:
      return LocalizedString.forKey("creative")
    }
  }
}

/// The provider's row under Where Models Run, with its account for the gear's menu.
private struct RemoteProviderConfigurationRow: Equatable {
  var provider: RemoteProvider
  var status: String
  /// Nil while signed out.
  var authenticationKind: RemoteAuthenticationKind?
}

/// From the gear's menu on a provider's row.
enum RemoteAccountAction {
  /// Signs in again, or changes the key.
  case configure
  case signOut
}

protocol SettingsSectionsControllerDelegate: AnyObject {
  func settingsSectionsController(
    _ controller: SettingsSectionsController,
    didReasoningEffortChange reasoningEffort: ReasoningEffort)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didWorkAttitudeChange workAttitude: WorkAttitude)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didMemoryEnabledChange isMemoryEnabled: Bool)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didThinkingBudgetChange thinkingBudget: Int32)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didSearchProviderChange provider: WebSearchProvider)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didChangeAPIKey apiKey: String)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didSelectRemoteProvider provider: RemoteProvider?,
    sourceView: UIView)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didTapRemoteProvider provider: RemoteProvider,
    sourceView: UIView)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didRequest action: RemoteAccountAction,
    forRemoteProvider provider: RemoteProvider)
  func settingsSectionsController(
    _ controller: SettingsSectionsController, didChangeRemoteCompactionThreshold value: Double,
    provider: RemoteProvider)
  func settingsSectionsControllerDidRequestTopUp(_ controller: SettingsSectionsController)
  func settingsSectionsControllerDidRequestModelSpeed(_ controller: SettingsSectionsController)
}

extension WebSearchProvider {
  var title: String {
    switch self {
    case .duckDuckGo:
      return LocalizedString.forKey("search_provider_duckduckgo")
    case .sogou:
      return LocalizedString.forKey("search_provider_sogou")
    case .kagi:
      return LocalizedString.forKey("search_provider_kagi")
    case .brave:
      return LocalizedString.forKey("search_provider_brave")
    case .disabled:
      return LocalizedString.forKey("disabled")
    }
  }
}

final class SettingsSectionsController {
  let view = UIView(frame: .zero)
  weak var delegate: SettingsSectionsControllerDelegate?
  private let workspace: SQLiteWorkspace
  private let isOnDeviceAvailable: Bool
  private var isViewLoaded = false
  private var verticalScrollIndicatorController: VerticalScrollIndicatorController? = nil
  private let sections: [SettingsSection]
  private var displayingSections: [SettingsSection: any SettingsViewObservable] = [:]
  private var sectionViewModifiers: [SettingsSection: any SettingsViewModifying] = [:]
  var reasoningEffort: ReasoningEffort = .high {
    didSet {
      guard reasoningEffort != oldValue else { return }
      updateSettingsSections()
    }
  }
  var workAttitude: WorkAttitude = .deterministic {
    didSet {
      guard workAttitude != oldValue else { return }
      updateSettingsSections()
    }
  }
  var isBotModeEnabled = false {
    didSet {
      guard isBotModeEnabled != oldValue else { return }
      updateSettingsSections()
    }
  }
  var isMemoryEnabled = true {
    didSet {
      guard isMemoryEnabled != oldValue else { return }
      updateSettingsSections()
    }
  }
  var thinkingBudget: Int32 = 65_536 {
    didSet {
      guard thinkingBudget != oldValue else { return }
      updateSettingsSections()
    }
  }
  var searchProvider: WebSearchProvider = .duckDuckGo {
    didSet {
      guard searchProvider != oldValue else { return }
      updateSettingsSections()
    }
  }
  var webSearchAPIKey = "" {
    didSet {
      guard webSearchAPIKey != oldValue else { return }
      updateSettingsSections()
    }
  }
  var remoteProvider: RemoteProvider? {
    didSet {
      guard remoteProvider != oldValue else { return }
      updateSettingsSections()
      updateAccountBalanceVisibility()
      if isViewLoaded {
        viewMoreButton.isHidden = remoteProvider != nil
      }
    }
  }
  var isModelSpeedEnabled = true {
    didSet {
      if isViewLoaded {
        viewMoreButton.isEnabled = isModelSpeedEnabled
      }
    }
  }
  var hostedAccountBalance: String? {
    didSet {
      guard hostedAccountBalance != oldValue, isViewLoaded else { return }
      accountBalanceView.balance = hostedAccountBalance
    }
  }
  var isHostedAccountSignedIn = false {
    didSet {
      guard isHostedAccountSignedIn != oldValue else { return }
      updateSettingsSections()
      updateAccountBalanceVisibility()
    }
  }
  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView(frame: .zero)
    scrollView.alwaysBounceVertical = true
    scrollView.contentInsetAdjustmentBehavior = .never
    #if targetEnvironment(macCatalyst)
      scrollView.showsVerticalScrollIndicator = false
    #endif
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.automaticallyAdjustsScrollIndicatorInsets = false
    scrollView.contentInset = UIEdgeInsets(
      top: Theme.current.individualStackViewItemSpacing, left: 0,
      bottom: Theme.current.individualStackViewItemSpacing, right: 0)
    return scrollView
  }()
  private lazy var stackView: UIStackView = {
    let stackView = UIStackView(frame: .zero)
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.spacing = Theme.current.individualStackViewItemSpacing
    return stackView
  }()
  public var promptProcessingLabel: String? {
    get { promptProcessingView.label.text }
    set { promptProcessingView.label.text = newValue }
  }
  public var promptProcessingTitle: String? {
    get { promptProcessingView.titleLabel.text }
    set { promptProcessingView.titleLabel.text = newValue }
  }
  private lazy var promptProcessingView: (view: UIView, titleLabel: UILabel, label: UILabel) =
    makeAverageSpeedItemView(
      title: LocalizedString.forKey("prompt_processing"),
      image: #imageLiteral(resourceName: "prompt-processing-16").withRenderingMode(.alwaysTemplate),
      value: "0.0 tok/s")
  public var tokenGenerationLabel: String? {
    get { tokenGenerationView.label.text }
    set { tokenGenerationView.label.text = newValue }
  }
  public var tokenGenerationTitle: String? {
    get { tokenGenerationView.titleLabel.text }
    set { tokenGenerationView.titleLabel.text = newValue }
  }
  private lazy var tokenGenerationView: (view: UIView, titleLabel: UILabel, label: UILabel) =
    makeAverageSpeedItemView(
      title: LocalizedString.forKey("token_generation"),
      image: #imageLiteral(resourceName: "token-generation-16").withRenderingMode(.alwaysTemplate),
      value: "0.0 tok/s")
  public var performanceTitle: String? {
    get { performanceTitleLabel.text }
    set { performanceTitleLabel.text = newValue }
  }
  private lazy var performanceTitleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = LocalizedString.forKey("avg_speed")
    label.textColor = .secondaryText
    label.lineBreakMode = .byTruncatingTail
    label.numberOfLines = 1
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .semibold), bindTo: label)
    return label
  }()
  private lazy var viewMoreButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.title = LocalizedString.forKey("view_more")
    configuration.image = #imageLiteral(resourceName: "arrow-right-16").withRenderingMode(
      .alwaysTemplate)
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.baseForegroundColor = .secondaryText
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 12, bottom: 8, trailing: 8)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .medium), bindTo: button)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    // Model Speed runs local models only.
    button.isHidden = remoteProvider != nil
    button.isEnabled = isModelSpeedEnabled
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.settingsSectionsControllerDidRequestModelSpeed(self)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var accountBalanceView: AccountBalanceView = {
    let view = AccountBalanceView()
    view.balance = hostedAccountBalance
    view.isHidden = remoteProvider != .localCode || !isHostedAccountSignedIn
    view.onTopUp = { [weak self] in
      guard let self else { return }
      delegate?.settingsSectionsControllerDidRequestTopUp(self)
    }
    return view
  }()
  private lazy var averageSpeedView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .secondaryBackground

    let topDivider = SettingsViewFactory.makeDividerView()
    topDivider.backgroundColor = .primaryBorder
    view.addSubview(topDivider)
    topDivider.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.height.equalTo(1)
    }

    let titleView = UIView(frame: .zero)
    let titleIconView = UIImageView(
      image: #imageLiteral(resourceName: "speedometer-20").withRenderingMode(.alwaysTemplate))
    titleIconView.tintColor = .secondaryText
    titleIconView.contentMode = .scaleAspectFit
    titleView.addSubview(titleIconView)
    titleIconView.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(20)
      make.centerY.equalToSuperview()
      make.size.equalTo(20)
    }

    titleView.addSubview(viewMoreButton)
    viewMoreButton.snp.makeConstraints { make in
      // With the 8pt trailing content inset, the arrow ends 20pt from the edge.
      make.trailing.equalToSuperview().offset(-12)
      make.centerY.equalToSuperview()
    }

    titleView.addSubview(performanceTitleLabel)
    performanceTitleLabel.snp.makeConstraints { make in
      make.leading.equalTo(titleIconView.snp.trailing).offset(4)
      make.trailing.lessThanOrEqualTo(viewMoreButton.snp.leading).offset(-8)
      make.centerY.equalToSuperview()
    }

    let statsView = UIView(frame: .zero)
    let statsStackView = UIStackView(frame: .zero)
    statsStackView.axis = .horizontal
    statsStackView.alignment = .fill
    statsStackView.distribution = .fill
    statsStackView.spacing = 0
    statsView.addSubview(statsStackView)
    statsStackView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    let stackTopDivider = SettingsViewFactory.makeDividerView()
    stackTopDivider.backgroundColor = .primaryBorder
    statsView.addSubview(stackTopDivider)
    stackTopDivider.snp.makeConstraints { make in
      make.height.equalTo(1)
      make.top.leading.trailing.equalTo(statsStackView)
    }

    let divider = SettingsViewFactory.makeDividerView()
    divider.backgroundColor = .primaryBorder

    statsStackView.addArrangedSubview(promptProcessingView.view)
    statsStackView.addArrangedSubview(divider)
    statsStackView.addArrangedSubview(tokenGenerationView.view)
    divider.snp.makeConstraints { make in
      make.width.equalTo(1)
    }
    promptProcessingView.view.snp.makeConstraints { make in
      make.width.equalTo(tokenGenerationView.view)
    }

    let contentStackView = UIStackView(
      arrangedSubviews: [accountBalanceView, titleView, statsView])
    contentStackView.axis = .vertical
    contentStackView.alignment = .fill
    contentStackView.spacing = 0
    view.addSubview(contentStackView)
    contentStackView.snp.makeConstraints { make in
      make.top.equalTo(topDivider.snp.bottom)
      make.leading.trailing.bottom.equalToSuperview()
    }
    titleView.snp.makeConstraints { make in
      make.height.equalTo(56)
    }

    return view
  }()

  init(workspace: SQLiteWorkspace, isOnDeviceAvailable: Bool) {
    self.workspace = workspace
    self.isOnDeviceAvailable = isOnDeviceAvailable
    self.sections = [
      .whereModelsRun,
      .reasoningEffort,
      .thinkingBudget,
      .searchProvider,
      .workAttitude,
      .memory,
    ]
  }

  func refreshRemoteProviderConfiguration() {
    updateSettingsSections()
  }

  func loadViewIfNeeded() {
    guard !isViewLoaded else { return }
    isViewLoaded = true
    view.backgroundColor = .secondaryBackground

    view.addSubview(scrollView)
    view.addSubview(averageSpeedView)
    scrollView.addSubview(stackView)
    averageSpeedView.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalToSuperview()
    }
    scrollView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.bottom.equalTo(averageSpeedView.snp.top)
    }
    stackView.snp.makeConstraints { make in
      make.leading.trailing.equalTo(scrollView.contentLayoutGuide).inset(
        Theme.current.individualStackViewItemSpacing)
      make.top.bottom.equalTo(scrollView.contentLayoutGuide)
      make.width.equalTo(scrollView.frameLayoutGuide).offset(
        -Theme.current.individualStackViewItemSpacing * 2)
    }
    #if targetEnvironment(macCatalyst)
      let verticalScrollIndicatorController = VerticalScrollIndicatorController(
        scrollView: scrollView)
      scrollView.delegate = verticalScrollIndicatorController.objCResponder
      self.verticalScrollIndicatorController = verticalScrollIndicatorController
      view.addSubview(verticalScrollIndicatorController.view)
      verticalScrollIndicatorController.view.snp.makeConstraints { make in
        make.top.bottom.trailing.equalTo(scrollView)
        make.width.equalTo(12)
      }
    #endif

    for section in sections {
      let sectionItem = makeSection(section)
      let (sectionViews, sectionViewModifier) = sectionItem.viewModifying.makeViews(
        from: sectionItem)
      sectionViews.forEach { stackView.addArrangedSubview($0) }
      displayingSections[section] = sectionItem
      sectionViewModifiers[section] = sectionViewModifier
    }
  }

  private func makeSection(_ section: SettingsSection) -> SettingsSectionItem {
    switch section {
    case .reasoningEffort:
      return reasoningEffortSection()
    case .workAttitude:
      return workAttitudeSection()
    case .thinkingBudget:
      return thinkingBudgetSection()
    case .searchProvider:
      return searchProviderSection()
    case .whereModelsRun:
      return whereModelsRunSection()
    case .memory:
      return memorySection()
    }
  }

  private func updateSettingsSections() {
    guard isViewLoaded else { return }
    for section in sections {
      let sectionItem = makeSection(section)
      guard let displayingSection = displayingSections[section],
        let viewModifier = sectionViewModifiers[section]
      else { continue }
      displayingSections[section] = viewModifier.updateViews(displayingSection, with: sectionItem)
    }
  }

  private func updateAccountBalanceVisibility() {
    guard isViewLoaded else { return }
    accountBalanceView.isHidden = remoteProvider != .localCode || !isHostedAccountSignedIn
  }

  private func reasoningEffortSection() -> SettingsSectionItem {
    SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: reasoningEffort,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] reasoningEffort, button in
            button?.menu = UIMenu(
              children: ReasoningEffort.allCases.map { effort in
                UIAction(
                  title: effort.title, state: reasoningEffort == effort ? .on : .off
                ) { [weak self] _ in
                  guard let self else { return }
                  self.delegate?.settingsSectionsController(
                    self, didReasoningEffortChange: effort)
                }
              })
            button?.setTitle(reasoningEffort.title, for: .normal)
          })
      ], title: LocalizedString.forKey("reasoning_effort"),
      detail: LocalizedString.forKey("reasoning_effort_detail"),
      lookUpKey: "local_code_reasoning_effort_detail_hidden", workspace: workspace)
  }

  private func workAttitudeSection() -> SettingsSectionItem {
    var section = SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: workAttitude,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] workAttitude, button in
            button?.menu = UIMenu(
              children: WorkAttitude.allCases.map { attitude in
                UIAction(
                  title: attitude.title, state: workAttitude == attitude ? .on : .off
                ) { [weak self] _ in
                  guard let self else { return }
                  self.delegate?.settingsSectionsController(
                    self, didWorkAttitudeChange: attitude)
                }
              })
            button?.setTitle(workAttitude.title, for: .normal)
          })
      ], title: LocalizedString.forKey("work_attitude"),
      detail: LocalizedString.forKey("work_attitude_detail"),
      lookUpKey: "local_code_work_attitude_detail_hidden", workspace: workspace)
    section.isHidden = remoteProvider != nil
    return section
  }

  private func memorySection() -> SettingsSectionItem {
    var section = SettingsSectionItem(
      settingsItems: [
        SettingsSwitchItem(
          value: isMemoryEnabled,
          title: LocalizedString.forKey("enable"),
          handleValueChange: { [weak self] value in
            guard let self else { return }
            self.delegate?.settingsSectionsController(self, didMemoryEnabledChange: value)
          })
      ], title: LocalizedString.forKey("memory"),
      detail: LocalizedString.forKey(isBotModeEnabled ? "bot_memory_detail" : "memory_detail"),
      lookUpKey: "local_code_memory_detail_hidden", workspace: workspace)
    section.isHidden = remoteProvider != nil
    return section
  }

  private func thinkingBudgetSection() -> SettingsSectionItem {
    var section = SettingsSectionItem(
      settingsItems: [
        SettingsSliderItem(
          title: LocalizedString.forKey("thinking_budget_tokens"), minValue: 0,
          maxValue: 128 * 1024, value: Float(thinkingBudget),
          valueType: .scale,
          customScale: SettingsSliderItem.CustomScale(
            rounded: { ($0 / 256).rounded() * 256 },
            increment: { min(128 * 1024, (($0 / 256).rounded() + 1) * 256) }
          )
        ) { [weak self] value in
          guard let self else { return }
          self.delegate?.settingsSectionsController(
            self, didThinkingBudgetChange: Int32(min(max(Int(value), 0), 128 * 1024)))
        }
      ], title: LocalizedString.forKey("thinking_budget"),
      detail: LocalizedString.forKey("thinking_budget_detail"),
      lookUpKey: "local_code_thinking_budget_detail_hidden", workspace: workspace)
    section.isHidden = remoteProvider != nil
    return section
  }

  private func searchProviderSection() -> SettingsSectionItem {
    let apiKey = webSearchAPIKey
    var apiKeyPlainTextItem = SettingsPlainTextItem(
      leadingText: LocalizedString.forKey("api_key"), trailingText: "")
    var apiKeyItem = SettingsTextFieldItem(
      value: apiKey,
      placeholderText: LocalizedString.forKey("enter_your_api_key"),
      didChangeText: { [weak self] text in
        guard let self else { return }
        self.delegate?.settingsSectionsController(
          self, didChangeAPIKey: text)
      })
    switch searchProvider {
    case .kagi, .brave:
      apiKeyPlainTextItem.isHidden = false
      apiKeyItem.isHidden = false
    case .duckDuckGo, .sogou, .disabled:
      apiKeyPlainTextItem.isHidden = true
      apiKeyItem.isHidden = true
    }
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: searchProvider,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] searchProvider, button in
            button?.menu = UIMenu(
              children: WebSearchProvider.allCases.map { provider in
                UIAction(
                  title: provider.title,
                  state: searchProvider.identifier == provider.identifier ? .on : .off
                ) { [weak self] _ in
                  guard let self else { return }
                  self.delegate?.settingsSectionsController(
                    self, didSearchProviderChange: provider)
                }
              })
            button?.setTitle(searchProvider.title, for: .normal)
          }),
        apiKeyPlainTextItem,
        apiKeyItem,
      ], title: LocalizedString.forKey("search_provider"),
      detail: LocalizedString.forKey("search_provider_detail"),
      lookUpKey: "local_code_search_provider_detail_hidden", workspace: workspace)
  }

  private func whereModelsRunSection() -> SettingsSectionItem {
    let providers: [RemoteProvider?] =
      (isOnDeviceAvailable ? [nil] : []) + RemoteProvider.allCases.map(Optional.some)
    let noProviderTitle = LocalizedString.forKey(isOnDeviceAvailable ? "on_device" : "unspecified")
    let provider = remoteProvider ?? .openRouter
    let requiresHostedSignIn = remoteProvider == .localCode && !isHostedAccountSignedIn
    var configurationItem = SettingsSectionItem(
      settingsItems: [
        // Signed in, the row picks the provider's model, and the gear has the account.
        SettingsButtonItem(
          value: RemoteProviderConfigurationRow(
            provider: provider,
            status: requiresHostedSignIn
              ? LocalizedString.forKey("sign_in_to_local_code")
              : provider.configurationStatus(in: workspace),
            authenticationKind: provider == .localCode
              ? nil : provider.account(in: workspace)?.authorization.kind),
          buttonImage: UIImage(
            systemName: requiresHostedSignIn ? "person.crop.circle" : "gearshape")?
            .withRenderingMode(.alwaysTemplate),
          buttonAction: { [weak self] sourceView, row in
            guard let self else { return }
            self.delegate?.settingsSectionsController(
              self, didTapRemoteProvider: row.provider, sourceView: sourceView)
          },
          makeButtonsUI: { row, button in
            button?.setTitle(row.status, for: .normal)
          },
          accessoryMenu: { [weak self] row in
            guard let authenticationKind = row.authenticationKind else { return nil }
            let configureTitle: String
            if row.provider == .openAI {
              configureTitle = LocalizedString.forKey("remote_oauth_openai_action")
            } else if row.provider == .anthropic && authenticationKind == .oauth {
              configureTitle = LocalizedString.forKey("remote_oauth_anthropic_action")
            } else {
              configureTitle = LocalizedString.forKey("api_key")
            }
            return UIMenu(
              title: row.provider.title,
              children: [
                UIAction(title: configureTitle) { [weak self] _ in
                  guard let self else { return }
                  self.delegate?.settingsSectionsController(
                    self, didRequest: .configure, forRemoteProvider: row.provider)
                },
                UIAction(
                  title: LocalizedString.forKey(
                    authenticationKind == .oauth ? "sign_out" : "remove_api_key"),
                  attributes: .destructive
                ) { [weak self] _ in
                  guard let self else { return }
                  self.delegate?.settingsSectionsController(
                    self, didRequest: .signOut, forRemoteProvider: row.provider)
                },
              ])
          }),
        SettingsSliderItem(
          title: LocalizedString.forKey("remote_compaction_trigger"),
          minValue: Float(RemoteAgentConfiguration.minimumCompactionThreshold),
          maxValue: Float(RemoteAgentConfiguration.maximumCompactionThreshold),
          value: Float(provider.compactionThreshold(in: workspace)), valueType: .percent()
        ) { [weak self] value in
          guard let self, remoteProvider == provider else { return }
          self.delegate?.settingsSectionsController(
            self, didChangeRemoteCompactionThreshold: Double(value), provider: provider)
        },
      ], title: provider.title, detail: provider.configurationDetail,
      lookUpKey: "local_code_remote_provider_detail_hidden", individualSectionStyle: false,
      workspace: workspace)
    configurationItem.isHidden = remoteProvider == nil
    return SettingsSectionItem(
      settingsItems: [
        SettingsButtonItem(
          value: remoteProvider,
          showsMenuAsPrimaryAction: true,
          makeButtonsUI: { [weak self] selectedProvider, button in
            button?.menu = UIMenu(
              children: providers.map { provider in
                UIAction(
                  title: provider?.title ?? noProviderTitle,
                  state: selectedProvider == provider ? .on : .off
                ) { [weak self, weak button] _ in
                  guard let self, let button else { return }
                  self.delegate?.settingsSectionsController(
                    self, didSelectRemoteProvider: provider, sourceView: button)
                }
              })
            button?.setTitle(
              selectedProvider?.title ?? noProviderTitle, for: .normal)
          }),
        configurationItem,
      ], title: LocalizedString.forKey("where_models_run"),
      detail: LocalizedString.forKey("where_models_run_detail"),
      lookUpKey: "local_code_provider_detail_hidden", workspace: workspace)
  }

  private func makeAverageSpeedItemView(title: String, image: UIImage, value: String) -> (
    view: UIView, titleLabel: UILabel, label: UILabel
  ) {
    let view = UIView(frame: .zero)
    view.backgroundColor = .secondaryBackground

    let imageView = UIImageView(image: image)
    imageView.tintColor = .senaryText
    imageView.contentMode = .scaleAspectFit
    view.addSubview(imageView)
    imageView.snp.makeConstraints { make in
      make.leading.top.equalToSuperview().offset(16)
      make.size.equalTo(16)
    }

    let titleLabel = UILabel(frame: .zero)
    titleLabel.text = title
    titleLabel.textColor = .senaryText
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.numberOfLines = 1
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .regular), bindTo: titleLabel)
    view.addSubview(titleLabel)
    titleLabel.snp.makeConstraints { make in
      make.leading.equalTo(imageView.snp.trailing).offset(4)
      make.trailing.lessThanOrEqualToSuperview().offset(-16)
      make.centerY.equalTo(imageView)
    }

    let valueLabel = UILabel(frame: .zero)
    valueLabel.text = value
    valueLabel.textColor = .secondaryText
    valueLabel.lineBreakMode = .byTruncatingTail
    valueLabel.numberOfLines = 1
    FontMetrics.default.scaleFont(
      .monospacedDigitSystemFont(ofSize: 21, weight: .semibold), bindTo: valueLabel)
    view.addSubview(valueLabel)
    valueLabel.snp.makeConstraints { make in
      make.top.equalTo(imageView.snp.bottom).offset(8)
      make.leading.trailing.bottom.equalToSuperview().inset(16)
    }

    return (view, titleLabel, valueLabel)
  }
}

extension SettingsSectionsController: LightweightViewControllable {}
