import Components
import Localization
import SnapKit
import Style
import UIKit

protocol SettingsViewControllerDelegate: AnyObject {
  func settingsViewController(_ viewController: SettingsViewController, didSelectIndex index: Int)
  func settingsViewControllerDidTapMachineSettings(_ viewController: SettingsViewController)
  func settingsViewControllerDidTapAccount(
    _ viewController: SettingsViewController, sourceView: UIView)
  func settingsViewControllerDidTapNewProject(_ viewController: SettingsViewController)
  func settingsViewControllerDidTapNewProjectFromTemplate(_ viewController: SettingsViewController)
  func settingsViewControllerDidTapNewThread(_ viewController: SettingsViewController)
  func settingsViewController(
    _ viewController: SettingsViewController, didSelectRecentThreads isRecentThreadsSelected: Bool)
}

final class SettingsViewController: UIViewController {
  weak var delegate: SettingsViewControllerDelegate?

  private let userInterfaceIdiom: UIUserInterfaceIdiom
  private let menuControl: MenuControl
  private let pages: [LightweightViewControllable]
  private var selectedIndex = 0
  private var currentChild: LightweightViewControllable?
  private var configurationTitleTrailingToThreadsConstraint: Constraint?
  var isBotModeEnabled = false {
    didSet {
      guard isBotModeEnabled != oldValue else { return }
      menuControl.setImage(
        UIImage(named: isBotModeEnabled ? "monkey-24" : "folder-24") ?? UIImage(),
        title: configurationTitles[0], forItemAt: 0)
      configurationTitleLabel.text = configurationTitle
      let allThreadsAccessibilityLabel = LocalizedString.forKey(
        isBotModeEnabled ? "all_bots" : "all_projects")
      if let threadsModeSegmentedControl {
        threadsModeSegmentedControl.imageForSegment(at: 0)?.accessibilityLabel =
          allThreadsAccessibilityLabel
      } else {
        allThreadsButton.accessibilityLabel = allThreadsAccessibilityLabel
      }
      newButton.accessibilityLabel = newButtonAccessibilityLabel
      newButton.menu = newButtonMenu
    }
  }
  private(set) var isRecentThreadsSelected = false
  // Recents lists threads rather than projects, so its new button starts a thread instead.
  private var newButtonAccessibilityLabel: String {
    LocalizedString.forKey(
      isRecentThreadsSelected ? "new_chat" : isBotModeEnabled ? "new_bot" : "new_project")
  }
  // Projects and bots offer a menu to start an empty one or one from a community template.
  private var newButtonMenu: UIMenu? {
    guard !isRecentThreadsSelected else { return nil }
    return UIMenu(children: [
      UIAction(
        title: LocalizedString.forKey(isBotModeEnabled ? "new_bot_dot" : "new_project_dot"),
        image: isBotModeEnabled
          ? UIImage(named: "monkey-filled-16")?.withRenderingMode(.alwaysTemplate)
          : UIImage(systemName: "folder.badge.plus")
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.settingsViewControllerDidTapNewProject(self)
      },
      UIAction(
        title: LocalizedString.forKey(
          isBotModeEnabled ? "new_bot_from_template_dot" : "new_from_template_dot"),
        image: UIImage(systemName: "square.grid.2x2")
      ) { [weak self] _ in
        guard let self else { return }
        self.delegate?.settingsViewControllerDidTapNewProjectFromTemplate(self)
      },
    ])
  }
  private var newButtonImage: UIImage? {
    UIImage(named: isRecentThreadsSelected ? "chat-new-24" : "plus-24")?.withTintColor(
      .senaryText)
  }
  private var configurationTitle: String {
    guard selectedIndex == 0 else { return configurationTitles[selectedIndex] }
    if isRecentThreadsSelected {
      return LocalizedString.forKey("recent_threads")
    }
    return LocalizedString.forKey(isBotModeEnabled ? "all_bots" : "all_projects")
  }
  private var configurationTitles: [String] {
    [
      LocalizedString.forKey(isBotModeEnabled ? "bots" : "projects"),
      LocalizedString.forKey("settings"),
      LocalizedString.forKey("kit"),
      LocalizedString.forKey("activities"),
    ]
  }

  private lazy var backgroundViewClipper: UIView = {
    let view = UIView(frame: .zero)
    view.clipsToBounds = true
    view.isUserInteractionEnabled = false
    return view
  }()

  private lazy var childContentView: UIView = {
    let view = UIView(frame: .zero)
    return view
  }()

  private lazy var contextUsedBarController = LabeledProgressBarController(
    viewModel: LabeledProgressBarController.ViewModel(
      leadingLabel: LocalizedString.format(
        key: "context_x_used", Double(0).formatted(.percent.precision(.fractionLength(1)))),
      trailingLabel: "0 / 0",
      progress: 0),
    defaultHeight: 24, labelHorizontalInset: 8, labelFontSize: 12, centerYOffset: 0)

  private lazy var contextUsedView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .secondaryBackground

    let topDivider = SettingsViewFactory.makeDividerView()
    topDivider.backgroundColor = .primaryBorder
    view.addSubview(topDivider)
    topDivider.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.height.equalTo(1)
    }

    view.addSubview(contextUsedBarController.view)
    contextUsedBarController.view.snp.makeConstraints { make in
      make.top.equalTo(topDivider.snp.bottom).offset(16)
      make.leading.trailing.equalToSuperview().inset(Theme.current.sectionContentMargin)
      make.height.equalTo(24)
      make.bottom.equalToSuperview().offset(-20)
    }

    return view
  }()

  private lazy var configurationView: UIView = {
    let view = PassThroughView(frame: .zero)
    view.layer.maskedCorners = [.layerMinXMinYCorner]
    view.layer.cornerRadius = 16
    view.clipsToBounds = true
    view.backgroundColor = .secondaryBackground
    return view
  }()

  private lazy var configurationTitleLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = configurationTitle
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: label)
    return label
  }()

  private lazy var backgroundShadow: UIView = {
    let view = UIView(frame: .zero)
    view.layer.cornerRadius = 16
    view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    view.backgroundColor = .secondaryBackground
    view.layer.shadowOffset = CGSize(width: -2, height: -2)
    view.layer.shadowOpacity = 0.25
    view.layer.shadowRadius = 5
    view.isUserInteractionEnabled = false
    view.layer.shadowColor = UIColor.primaryShadow.cgColor
    return view
  }()

  private lazy var backgroundView: UIView = {
    let view = UIView(frame: .zero)
    view.layer.cornerRadius = 16
    view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    view.backgroundColor = .secondaryBackground
    if userInterfaceIdiom != .phone {
      view.layer.shadowOffset = CGSize(width: -2, height: -2)
      view.layer.shadowOpacity = 0.25
      view.layer.shadowRadius = 5
      view.layer.shadowColor = UIColor.primaryShadow.cgColor
    }
    view.isUserInteractionEnabled = false
    return view
  }()

  private lazy var machineSettingsButton: UIButton = {
    let button = UIButton(type: .custom)
    if #available(iOS 26.0, *) {
      // A borderless Liquid Glass 8pt rounded square. Selected or pressed, it takes the muted gray
      // it used before glass.
      var configuration = UIButton.Configuration.glass()
      configuration.cornerStyle = .fixed
      configuration.background.cornerRadius = 8
      configuration.image = #imageLiteral(resourceName: "cpu").withRenderingMode(.alwaysTemplate)
      configuration.baseForegroundColor = .senaryText
      button.configuration = configuration
      // Clearing the background color would tint the glass with the tint color, so put back the
      // glass's own background when the button isn't active.
      let restingBackground = configuration.background
      button.configurationUpdateHandler = {
        guard var configuration = $0.configuration else { return }
        let isActive = $0.state.contains(.selected) || $0.state.contains(.highlighted)
        configuration.baseForegroundColor = isActive ? .secondaryText : .senaryText
        configuration.background = restingBackground
        if isActive {
          configuration.background.backgroundColor = .quinaryFill
        }
        $0.configuration = configuration
      }
    } else {
      var configuration = UIButton.Configuration.plain()
      configuration.background.cornerRadius = 8
      configuration.background.strokeColor = .secondaryBorder
      configuration.background.strokeWidth = 1
      configuration.background.backgroundColor = .primaryBackground
      configuration.image = #imageLiteral(resourceName: "cpu").withTintColor(.senaryText)
      button.configuration = configuration
      button.configurationUpdateHandler = {
        guard var configuration = $0.configuration else { return }
        if $0.state.contains(.selected) || $0.state.contains(.highlighted) {
          configuration.baseBackgroundColor = .quinaryFill
          configuration.baseForegroundColor = .secondaryText
          configuration.background.backgroundColor = .quinaryFill
          configuration.background.strokeColor = .senaryBorder
        } else if $0.state.contains(.normal) {
          configuration.baseBackgroundColor = .primaryBackground
          configuration.baseForegroundColor = .senaryText
          configuration.background.backgroundColor = .primaryBackground
          configuration.background.strokeColor = .secondaryBorder
        }
        $0.configuration = configuration
      }
    }
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.settingsViewControllerDidTapMachineSettings(self)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var accountButton: UIButton = {
    let button = UIButton(type: .custom)
    if #available(iOS 26.0, *) {
      // Same borderless Liquid Glass square as the machine settings button.
      var configuration = UIButton.Configuration.glass()
      configuration.cornerStyle = .fixed
      configuration.background.cornerRadius = 8
      configuration.image = UIImage(systemName: "person.crop.circle")?.withRenderingMode(
        .alwaysTemplate)
      configuration.baseForegroundColor = .senaryText
      button.configuration = configuration
      let restingBackground = configuration.background
      button.configurationUpdateHandler = {
        guard var configuration = $0.configuration else { return }
        let isActive = $0.state.contains(.selected) || $0.state.contains(.highlighted)
        configuration.baseForegroundColor = isActive ? .secondaryText : .senaryText
        configuration.background = restingBackground
        if isActive {
          configuration.background.backgroundColor = .quinaryFill
        }
        $0.configuration = configuration
      }
    } else {
      var configuration = UIButton.Configuration.plain()
      configuration.background.cornerRadius = 8
      configuration.background.strokeColor = .secondaryBorder
      configuration.background.strokeWidth = 1
      configuration.background.backgroundColor = .primaryBackground
      configuration.image = UIImage(systemName: "person.crop.circle")?.withTintColor(.senaryText)
      button.configuration = configuration
      button.configurationUpdateHandler = {
        guard var configuration = $0.configuration else { return }
        if $0.state.contains(.selected) || $0.state.contains(.highlighted) {
          configuration.baseBackgroundColor = .quinaryFill
          configuration.baseForegroundColor = .secondaryText
          configuration.background.backgroundColor = .quinaryFill
          configuration.background.strokeColor = .senaryBorder
        } else {
          configuration.baseBackgroundColor = .primaryBackground
          configuration.baseForegroundColor = .senaryText
          configuration.background.backgroundColor = .primaryBackground
          configuration.background.strokeColor = .secondaryBorder
        }
        $0.configuration = configuration
      }
    }
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        isAccountButtonSelected = true
        delegate?.settingsViewControllerDidTapAccount(self, sourceView: button)
      }, for: .touchUpInside)
    return button
  }()

  private lazy var threadsModePill: UIView = {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.backgroundColor = UIColor {
      $0.userInterfaceStyle == .light ? .grey1000 : .grey200
    }
    view.layer.cornerRadius = 14
    return view
  }()

  private lazy var allThreadsButton = makeThreadsModeButton(
    image: #imageLiteral(resourceName: "chat-24"),
    accessibilityLabel: LocalizedString.forKey(isBotModeEnabled ? "all_bots" : "all_projects"),
    isRecentThreads: false)

  private lazy var recentThreadsButton = makeThreadsModeButton(
    image: #imageLiteral(resourceName: "clock-24"),
    accessibilityLabel: LocalizedString.forKey("recent_threads"), isRecentThreads: true)

  // Only set on iOS 26+, where the system segmented control replaces the buttons and pill.
  private var threadsModeSegmentedControl: UISegmentedControl?

  private lazy var threadsModeView: UIView = {
    if #available(iOS 26.0, *) {
      // UISegmentedControl only gets the tab-bar-like Liquid Glass treatment inside a bar, so
      // host it as the title view of a standalone navigation bar.
      let allThreadsImage = #imageLiteral(resourceName: "chat-24").withRenderingMode(
        .alwaysTemplate)
      allThreadsImage.accessibilityLabel = LocalizedString.forKey(
        isBotModeEnabled ? "all_bots" : "all_projects")
      let recentThreadsImage = #imageLiteral(resourceName: "clock-24").withRenderingMode(
        .alwaysTemplate)
      recentThreadsImage.accessibilityLabel = LocalizedString.forKey("recent_threads")
      let segmentedControl = UISegmentedControl(items: [allThreadsImage, recentThreadsImage])
      segmentedControl.selectedSegmentIndex = isRecentThreadsSelected ? 1 : 0
      segmentedControl.addAction(
        UIAction { [weak self] in
          guard let self, let segmentedControl = $0.sender as? UISegmentedControl else { return }
          let isRecentThreads = segmentedControl.selectedSegmentIndex == 1
          self.setIsRecentThreadsSelected(isRecentThreads, animated: true)
          self.delegate?.settingsViewController(self, didSelectRecentThreads: isRecentThreads)
        }, for: .valueChanged)
      segmentedControl.snp.makeConstraints { make in
        make.height.equalTo(36)
      }
      threadsModeSegmentedControl = segmentedControl
      let navigationItem = UINavigationItem()
      navigationItem.titleView = segmentedControl
      let navigationBar = UINavigationBar(frame: .zero)
      navigationBar.items = [navigationItem]
      return navigationBar
    }
    let view = UIView(frame: .zero)
    view.backgroundColor = UIColor {
      $0.userInterfaceStyle == .light
        ? UIColor(white: 237.0 / 255.0, alpha: 1) : UIColor(white: 37.0 / 255.0, alpha: 1)
    }
    view.layer.cornerRadius = 18
    view.addSubview(threadsModePill)
    view.addSubview(allThreadsButton)
    view.addSubview(recentThreadsButton)
    // 75pt wide: 1pt insets on both sides and 1pt separator between two 36pt cells.
    allThreadsButton.snp.makeConstraints { make in
      make.leading.top.bottom.equalToSuperview().inset(1)
      make.width.equalTo(36)
    }
    recentThreadsButton.snp.makeConstraints { make in
      make.leading.equalTo(allThreadsButton.snp.trailing).offset(1)
      make.trailing.top.bottom.equalToSuperview().inset(1)
      make.width.equalTo(36)
    }
    allThreadsButton.isSelected = !isRecentThreadsSelected
    recentThreadsButton.isSelected = isRecentThreadsSelected
    threadsModePill.snp.makeConstraints { make in
      make.size.equalTo(28)
      make.center.equalTo(isRecentThreadsSelected ? recentThreadsButton : allThreadsButton)
    }
    return view
  }()

  private func makeThreadsModeButton(
    image: UIImage, accessibilityLabel: String, isRecentThreads: Bool
  ) -> UIButton {
    let button = UIButton(type: .custom)
    button.accessibilityLabel = accessibilityLabel
    var configuration = UIButton.Configuration.borderless()
    configuration.image = image.withRenderingMode(.alwaysTemplate)
    // The 28pt pill owns selection; suppress the button's default selected fill.
    configuration.baseBackgroundColor = .clear
    configuration.baseForegroundColor = .senaryText
    configuration.contentInsets = .zero
    button.configuration = configuration
    button.tintAdjustmentMode = .normal
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.setIsRecentThreadsSelected(isRecentThreads, animated: true)
        self.delegate?.settingsViewController(self, didSelectRecentThreads: isRecentThreads)
      }, for: .touchUpInside)
    return button
  }

  private lazy var newButton: UIButton = {
    let button = UIButton(type: .custom)
    button.accessibilityLabel = newButtonAccessibilityLabel
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = .clear
    configuration.image = newButtonImage
    configuration.background.cornerRadius = 8
    button.configuration = configuration
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      if $0.state.contains(.focused) || $0.state.contains(.highlighted) {
        configuration.baseBackgroundColor = .quinaryBackground
      } else {
        configuration.baseBackgroundColor = .clear
      }
      $0.configuration = configuration
    }
    button.menu = newButtonMenu
    button.showsMenuAsPrimaryAction = !isRecentThreadsSelected
    button.addAction(
      UIAction { [weak self] _ in
        guard let self, self.isRecentThreadsSelected else { return }
        self.delegate?.settingsViewControllerDidTapNewThread(self)
      }, for: .touchUpInside)
    return button
  }()

  func setIsRecentThreadsSelected(_ isRecentThreadsSelected: Bool, animated: Bool) {
    guard isRecentThreadsSelected != self.isRecentThreadsSelected else { return }
    self.isRecentThreadsSelected = isRecentThreadsSelected
    configurationTitleLabel.text = configurationTitle
    newButton.configuration?.image = newButtonImage
    newButton.accessibilityLabel = newButtonAccessibilityLabel
    newButton.menu = newButtonMenu
    newButton.showsMenuAsPrimaryAction = !isRecentThreadsSelected
    // Materialize the container first so the pill and buttons share a view hierarchy.
    let threadsModeView = threadsModeView
    if let threadsModeSegmentedControl {
      threadsModeSegmentedControl.selectedSegmentIndex = isRecentThreadsSelected ? 1 : 0
      return
    }
    allThreadsButton.isSelected = !isRecentThreadsSelected
    recentThreadsButton.isSelected = isRecentThreadsSelected
    let oldFrame = threadsModePill.frame
    threadsModePill.snp.remakeConstraints { make in
      make.size.equalTo(28)
      make.center.equalTo(isRecentThreadsSelected ? recentThreadsButton : allThreadsButton)
    }
    guard animated, threadsModeView.window != nil else { return }
    threadsModeView.layoutIfNeeded()
    threadsModePill.layer.addStretchSpringAnimation(
      from: oldFrame, to: threadsModePill.frame, axis: .horizontal)
  }

  func setContextUsed(_ usedTokens: Int, contextWindowTokens: Int) {
    let usedTokens = max(usedTokens, 0)
    let contextWindowTokens = max(contextWindowTokens, 0)
    let progress =
      contextWindowTokens > 0
      ? min(max(Double(usedTokens) / Double(contextWindowTokens), 0), 1) : 0
    let count: (Int) -> String = {
      NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal)
    }
    var viewModel = contextUsedBarController.viewModel
    viewModel.leadingLabel = LocalizedString.format(
      key: "context_x_used", progress.formatted(.percent.precision(.fractionLength(1))))
    viewModel.trailingLabel = "\(count(usedTokens)) / \(count(contextWindowTokens))"
    viewModel.progress = progress
    contextUsedBarController.viewModel = viewModel
  }
  var isAccountButtonSelected: Bool {
    get { accountButton.isSelected }
    set { accountButton.isSelected = newValue }
  }

  init(
    userInterfaceIdiom: UIUserInterfaceIdiom, projectsController: ProjectController,
    settingsSectionsController: SettingsSectionsController,
    kitSectionsController: KitSectionsController,
    activitiesSectionsController: ActivitiesSectionsController
  ) {
    self.userInterfaceIdiom = userInterfaceIdiom
    self.pages = [
      projectsController, settingsSectionsController, kitSectionsController,
      activitiesSectionsController,
    ]
    self.menuControl = MenuControl(
      icons: [
        #imageLiteral(resourceName: "folder-24"), #imageLiteral(resourceName: "gear-24"),
        #imageLiteral(resourceName: "kit-24"), #imageLiteral(resourceName: "histogram-chart-24"),
      ],
      titles: [
        LocalizedString.forKey("projects"),
        LocalizedString.forKey("settings"),
        LocalizedString.forKey("kit"),
        LocalizedString.forKey("activities"),
      ])
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    if userInterfaceIdiom == .phone {
      view = UIView(frame: .zero)
    } else {
      // Let unused title-bar space reach ChatViewControllerForiPad's movable title bar.
      view = PassThroughView(frame: .zero)
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    if userInterfaceIdiom == .phone {
      // We are going to animate in the primary background.
      view.backgroundColor = .tertiaryBackground
      backgroundViewClipper.backgroundColor = .tertiaryBackground
    } else {
      view.backgroundColor = .primaryBackground
      backgroundViewClipper.backgroundColor = .primaryBackground
    }
    #if targetEnvironment(macCatalyst)
      if #available(macCatalyst 26, *) {
        // The window owns the shared material behind the rail and rounded panel corners.
        view.backgroundColor = .clear
        view.isOpaque = false
        backgroundViewClipper.backgroundColor = .clear
      }
    #endif

    view.addSubview(backgroundViewClipper)
    backgroundViewClipper.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalToSuperview()
      // On the phone, settings is presented below the status bar, which can be taller than 60pt.
      make.top.equalToSuperview().offset(userInterfaceIdiom == .phone ? -100 : -60)
    }
    if userInterfaceIdiom == .phone {
      backgroundShadow.alpha = 0
      backgroundViewClipper.addSubview(backgroundShadow)
    }
    backgroundViewClipper.addSubview(backgroundView)

    view.addSubview(menuControl.view)
    backgroundView.snp.makeConstraints { make in
      make.leading.equalTo(menuControl.view.snp.trailing)
      make.top.bottom.equalTo(view)
      make.trailing.equalTo(view).offset(60)
    }
    if userInterfaceIdiom == .phone {
      backgroundShadow.snp.makeConstraints { make in
        make.edges.equalTo(backgroundView)
      }
    }

    view.addSubview(childContentView)
    view.addSubview(contextUsedView)
    menuControl.view.snp.makeConstraints { make in
      make.leading.equalToSuperview()
      make.top.equalTo(view.safeAreaLayoutGuide.snp.top).offset(16)
      #if targetEnvironment(macCatalyst)
        if #available(iOS 26, macOS 26, macCatalyst 26, *) {
          make.width.equalTo(88 + 14)
        } else {
          make.width.equalTo(88)
        }
      #else
        make.width.equalTo(78)
      #endif
    }
    view.addSubview(accountButton)
    accountButton.snp.makeConstraints { make in
      make.centerX.equalTo(menuControl.view)
      if userInterfaceIdiom == .phone {
        if UIScreen.main.isAllScreen {
          make.bottom.equalTo(view.snp.bottomMargin).offset(-4)
          make.size.equalTo(40)
        } else {
          make.bottom.equalTo(view.snp.bottomMargin).offset(-8)
          make.size.equalTo(32)
        }
      } else {
        make.bottom.equalToSuperview().offset(-20)
        make.size.equalTo(40)
      }
    }
    view.addSubview(machineSettingsButton)
    machineSettingsButton.snp.makeConstraints { make in
      make.centerX.equalTo(menuControl.view)
      if userInterfaceIdiom != .phone || UIScreen.main.isAllScreen {
        make.size.equalTo(40)
        make.bottom.equalTo(accountButton.snp.top).offset(-12)
      } else {
        make.size.equalTo(32)
        make.bottom.equalTo(accountButton.snp.top).offset(-8)
      }
    }
    view.addSubview(configurationView)
    configurationView.snp.makeConstraints { make in
      make.trailing.top.equalToSuperview()
      make.leading.equalTo(menuControl.view.snp.trailing)
      make.height.equalTo(52)
    }
    let divider = SettingsViewFactory.makeDividerView()
    configurationView.addSubview(divider)
    divider.snp.makeConstraints { make in
      make.height.equalTo(1)
      make.leading.trailing.bottom.equalTo(configurationView)
    }
    configurationView.addSubview(newButton)
    newButton.isHidden = selectedIndex != 0
    newButton.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.trailing.equalToSuperview().offset(-14)
      make.size.equalTo(36)
    }
    // On iOS 26+ the navigation bar's margin overlaps the new button; keep it underneath.
    configurationView.insertSubview(threadsModeView, belowSubview: newButton)
    threadsModeView.isHidden = selectedIndex != 0
    threadsModeView.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      if threadsModeSegmentedControl != nil {
        // The segmented control keeps its natural width (92pt, 88pt on Mac Catalyst) so the
        // selection stays a wide pill. UINavigationBar drops its title view unless it has 16pt
        // margins around it; offset by the resulting 18pt margin to keep the visible 8pt
        // spacing. It centers the title view 22pt below its top, so a 44pt bar keeps it
        // centered here.
        make.trailing.equalTo(newButton.snp.leading).offset(10)
        make.width.equalTo(128)
        make.height.equalTo(44)
      } else {
        make.trailing.equalTo(newButton.snp.leading).offset(-8)
        make.width.equalTo(75)
        make.height.equalTo(36)
      }
    }
    configurationView.addSubview(configurationTitleLabel)
    configurationTitleLabel.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(24)
      make.trailing.lessThanOrEqualToSuperview().offset(-14).priority(.high)
      configurationTitleTrailingToThreadsConstraint =
        make.trailing.lessThanOrEqualTo(threadsModeView.snp.leading).offset(
          threadsModeSegmentedControl != nil ? 10 : -8
        ).constraint
      make.centerY.equalToSuperview()
    }

    contextUsedView.snp.makeConstraints { make in
      make.leading.equalTo(menuControl.view.snp.trailing)
      make.trailing.bottom.equalToSuperview()
      make.height.equalTo(61)
    }
    childContentView.snp.makeConstraints { make in
      make.top.equalTo(configurationView.snp.bottom)
      make.bottom.equalTo(contextUsedView.snp.top)
      make.trailing.equalToSuperview()
      make.leading.equalTo(menuControl.view.snp.trailing)
    }
    setSelectedIndex(selectedIndex, animated: false)
    menuControl.delegate = self
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if userInterfaceIdiom == .phone {
      backgroundShadow.layer.shadowColor = UIColor.primaryShadow.cgColor
    } else {
      backgroundView.layer.shadowColor = UIColor.primaryShadow.cgColor
    }
  }

  func setSelectedIndex(_ index: Int, animated: Bool) {
    let index = min(max(index, 0), pages.count - 1)
    selectedIndex = index
    menuControl.setCurrentIndex(index, animated: animated)
    configurationTitleLabel.text = configurationTitle
    newButton.isHidden = index != 0
    threadsModeView.isHidden = index != 0
    configurationTitleTrailingToThreadsConstraint?.isActive = index == 0
    displayChild(pages[index])
  }

  /// Pages stay in the hierarchy once shown and are hidden when another is selected, so switching
  /// tabs doesn't lay a page out again from scratch while the rail animates.
  private func displayChild(_ child: LightweightViewControllable) {
    guard child !== currentChild else { return }
    currentChild?.view.isHidden = true
    child.loadViewIfNeeded()
    if child.view.superview !== childContentView {
      childContentView.addSubview(child.view)
      child.view.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
    }
    child.view.isHidden = false
    currentChild = child
  }
}

extension SettingsViewController: MenuControlDelegate {
  func didSelect(index: Int) {
    setSelectedIndex(index, animated: true)
    delegate?.settingsViewController(self, didSelectIndex: index)
  }
}

extension SettingsViewController: AnimatingTransitioningPresentable {
  func animate(alongsideTransition transition: SettingsAnimatedTransitioning.Transition) {
    switch transition {
    case .easeIn:
      view.backgroundColor = .primaryBackground
      backgroundViewClipper.backgroundColor = .primaryBackground
      backgroundShadow.alpha = 1
    case .easeOut:
      view.backgroundColor = .tertiaryBackground
      backgroundViewClipper.backgroundColor = .tertiaryBackground
      backgroundShadow.alpha = 0
    }
  }

  func animate(
    alongsideTransition transition: SettingsAnimatedTransitioning.Transition,
    interactivelyWithPercent percent: CGFloat
  ) {
    switch transition {
    case .easeIn:
      let backgroundColor = UIColor.interpolate(
        from: .tertiaryBackground, to: .primaryBackground, with: percent)
      view.backgroundColor = backgroundColor
      backgroundViewClipper.backgroundColor = backgroundColor
      backgroundShadow.alpha = percent
    case .easeOut:
      let backgroundColor = UIColor.interpolate(
        from: .primaryBackground, to: .tertiaryBackground, with: percent)
      view.backgroundColor = backgroundColor
      backgroundViewClipper.backgroundColor = backgroundColor
      backgroundShadow.alpha = 1.0 - percent
    }
  }
}
