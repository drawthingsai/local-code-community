import Components
import Localization
import RemoteAPI
import SnapKit
import Style
import UIKit
import UserAccount

protocol OnboardingViewControllerDelegate: AnyObject {
  func onboardingDidCompleteWelcome(_ viewController: OnboardingViewController)
  func onboardingDidRequestContinue(_ viewController: OnboardingViewController)
  func onboardingDidRequestBack(_ viewController: OnboardingViewController)
  func onboarding(
    _ viewController: OnboardingViewController,
    didSelectOption selection: OnboardingState.Selection)
  func onboardingDidRequestConnection(_ viewController: OnboardingViewController)
  func onboarding(_ viewController: OnboardingViewController, didSelectModel model: String)
  func onboarding(_ viewController: OnboardingViewController, didSelectLocalModel model: String)
  func onboarding(
    _ viewController: OnboardingViewController,
    didRequestSignIn provider: AccountManager.SignInProvider,
    sourceView: UIView)
  func onboarding(
    _ viewController: OnboardingViewController,
    didSetProjectIdea idea: OnboardingState.ProjectIdea, isOn: Bool)
  func onboarding(_ viewController: OnboardingViewController, didSetBotModeEnabled isEnabled: Bool)
}

final class OnboardingViewController: UIViewController {
  struct ModelOption: Equatable {
    let selection: OnboardingState.Selection
    let title: String
    let detail: String
    let badge: String
    let isBadgeHighlighted: Bool
  }

  struct LocalModelOption: Equatable {
    let id: String
    let name: String
    /// Nil until the download server has reported the size.
    let downloadSize: String?
    let detail: String
  }

  private static let characterInterval: TimeInterval = 0.01
  private static let checkmarkPause: TimeInterval = 0.12
  private static let linePause: TimeInterval = 0.08

  weak var delegate: OnboardingViewControllerDelegate?
  var state = OnboardingState() {
    didSet {
      guard isViewLoaded else { return }
      guard state.step != oldValue.step else {
        renderState()
        return
      }
      // Cross-fade to the new step from a picture of the one being left.
      let previousStepView = view.snapshotView(afterScreenUpdates: false)
      renderState()
      scrollView.setContentOffset(.zero, animated: false)
      UIAccessibility.post(notification: .screenChanged, argument: pageStack)
      guard let previousStepView else { return }
      view.addSubview(previousStepView)
      UIView.animate(withDuration: 0.3) {
        previousStepView.alpha = 0
      } completion: { _ in
        previousStepView.removeFromSuperview()
      }
    }
  }
  var options: [ModelOption] = [] {
    didSet {
      if isViewLoaded, options != oldValue { renderModelOptions() }
    }
  }
  var models: [String] = [] { didSet { if isViewLoaded { renderModelMenu() } } }
  var selectedModel: String? { didSet { if isViewLoaded { renderModelMenu() } } }
  var localModels: [LocalModelOption] = [] {
    didSet {
      if isViewLoaded, localModels != oldValue { renderLocalModels() }
    }
  }
  var selectedLocalModel: String? {
    didSet { if isViewLoaded { renderLocalModelSelection() } }
  }
  var connectionMessage = "" { didSet { if isViewLoaded { renderState() } } }
  var isLoadingModels = false { didSet { if isViewLoaded { renderModelMenu() } } }

  private lazy var scrollView: UIScrollView = {
    let scrollView = UIScrollView()
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.automaticallyAdjustsScrollIndicatorInsets = false
    scrollView.contentInsetAdjustmentBehavior = .never
    // The scroll view runs up to the footer; the inset keeps the last content clear of it.
    scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
    scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
    return scrollView
  }()
  private lazy var scrollIndicatorController: VerticalScrollIndicatorController = {
    let controller = VerticalScrollIndicatorController(scrollView: scrollView)
    scrollView.delegate = controller.objCResponder
    return controller
  }()
  private lazy var topBlurMaskLayer: CAGradientLayer = {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.white.cgColor,
      UIColor.white.withAlphaComponent(0.8).cgColor,
      UIColor.white.withAlphaComponent(0).cgColor,
    ]
    gradientLayer.locations = [0, 0.2, 1]
    return gradientLayer
  }()
  private lazy var topBlurView: LayoutVisualEffectView = {
    let visualEffectView = LayoutVisualEffectView(
      effect: UIBlurEffect(style: .systemThickMaterial))
    visualEffectView.isUserInteractionEnabled = false
    visualEffectView.layer.mask = topBlurMaskLayer
    let maskLayer = topBlurMaskLayer
    visualEffectView.onLayoutChange = { view in
      guard maskLayer.frame != view.bounds else { return }
      maskLayer.frame = view.bounds
    }
    let shadeView = UIView(frame: .zero)
    shadeView.backgroundColor = .tertiaryBackground
    visualEffectView.contentView.addSubview(shadeView)
    shadeView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return visualEffectView
  }()
  private lazy var scrollContent = UIView()
  private lazy var column = UIView()
  private lazy var bannerController: EmptyBannerController = {
    let controller = EmptyBannerController(animatesBackground: false)
    controller.setVisible(true, animated: false)
    return controller
  }()
  /// The banner follows this guide, which rests in the page. A host that shows a banner of its
  /// own can start it there instead, and the introduction then brings it into the page.
  private(set) lazy var bannerGuide = UILayoutGuide()
  private lazy var pageStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    return stack
  }()

  private lazy var welcomePage: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    // Revealed once the introduction has moved the banner into place.
    stack.alpha = 0
    return stack
  }()
  private lazy var welcomeLines: [OnboardingTranscriptLineController] = {
    // A line with a command keeps it first in every translation so it can be styled as code.
    let lines: [(key: String, command: String?, hasCheck: Bool)] = [
      ("getting_things_ready", nil, false),
      ("python_batteries_included", nil, true),
      ("node_js_packed_in", nil, true),
      ("shell_tools_ready", nil, true),
      ("office_chores_under_control", "office", true),
      ("version_control_packed_in", nil, true),
      ("video_creation_from_idea_to_final_cut", nil, true),
      ("formal_reasoning_on_tap", nil, true),
      ("draw_things_cli_hooked_up", "draw-things-cli", true),
      ("making_it_fast", nil, false),
      ("apple_silicon_up_to_2x_faster", nil, true),
      ("app_sandbox_locked_down", nil, true),
      ("private_execution_built_in", nil, true),
      ("awesomeness_110_percent", nil, true),
      ("ready_to_work", nil, false),
    ]
    return lines.enumerated().map { index, line in
      // A section title after the first one gets extra space above it.
      let controller = OnboardingTranscriptLineController(
        text: LocalizedString.forKey(line.key), command: line.command, hasCheck: line.hasCheck,
        topMargin: !line.hasCheck && index > 0 ? 16 : 0)
      controller.view.isHidden = true
      return controller
    }
  }()
  private lazy var timestampController: OnboardingTimestampController = {
    let controller = OnboardingTimestampController()
    controller.isInitializing = true
    return controller
  }()

  private lazy var modelPage: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 24
    return stack
  }()
  private lazy var modelHeading: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 0, right: 12)
    return stack
  }()
  private lazy var modelTitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("choose_a_model")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 28, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var modelSubtitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("choose_a_model_detail")
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label)
    return label
  }()
  private lazy var primaryOptions: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 16
    return stack
  }()
  // Each foldable section sits in a clipping container. A stack view hides the container by
  // closing over it, so the section keeps its layout and is uncovered as the page makes room,
  // instead of being squashed.
  private lazy var otherOptionsContainer: UIView = {
    let view = UIView()
    view.clipsToBounds = true
    return view
  }()
  private lazy var providerDetailsContainer: UIView = {
    let view = UIView()
    view.clipsToBounds = true
    return view
  }()
  private lazy var localModelContentContainer: UIView = {
    let view = UIView()
    view.clipsToBounds = true
    return view
  }()
  private lazy var otherOptions: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 16
    return stack
  }()
  // The Local Model card shares one outline with the model choices underneath it.
  private lazy var localModelGroup = BorderView.defaultBorderView(cornerRadius: 16)
  private lazy var localModelGroupStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    return stack
  }()
  private lazy var localModelContent: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 16
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 0, left: 12, bottom: 16, right: 12)
    return stack
  }()
  private lazy var localModelOptions: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 16
    return stack
  }()
  private lazy var otherModelsButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("other_models")
    configuration.baseBackgroundColor = .novemdecenaryBackground
    configuration.baseForegroundColor = .senaryText
    configuration.cornerStyle = .capsule
    configuration.background.strokeColor = .secondaryBorder
    configuration.background.strokeWidth = 1
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 4, leading: 10, bottom: 4, trailing: 6)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.otherModelsExpanded.toggle()
        UIView.animate(withDuration: 0.3) {
          self.renderLocalModelSelection()
          self.view.layoutIfNeeded()
        }
      }, for: .touchUpInside)
    return button
  }()
  private lazy var otherProvidersButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("other_providers")
    configuration.baseBackgroundColor = .tertiaryBackground
    configuration.baseForegroundColor = .primaryText
    configuration.background.cornerRadius = 16
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 4, leading: 10, bottom: 4, trailing: 6)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.otherProvidersExpanded.toggle()
        UIView.animate(withDuration: 0.3) {
          self.renderState()
          self.view.layoutIfNeeded()
        }
      }, for: .touchUpInside)
    return button
  }()
  private lazy var providerDetails: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    return stack
  }()
  private lazy var connectionLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .light), bindTo: label)
    return label
  }()
  private lazy var connectButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = .tertiaryBackground
    configuration.baseForegroundColor = .primaryText
    configuration.background.cornerRadius = 16
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 16, bottom: 12, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        if self.state.selection == .remote(.localCode) {
          self.delegate?.onboarding(self, didRequestSignIn: .apple, sourceView: button)
        } else {
          self.delegate?.onboardingDidRequestConnection(self)
        }
      }, for: .touchUpInside)
    return button
  }()
  private lazy var modelButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = .tertiaryBackground
    configuration.baseForegroundColor = .primaryText
    configuration.background.cornerRadius = 16
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 16, bottom: 12, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: button)
    button.showsMenuAsPrimaryAction = true
    return button
  }()

  private lazy var accountPage: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 24
    return stack
  }()
  private lazy var accountHeading: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    return stack
  }()
  private lazy var accountTitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("create_an_account")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 28, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var accountDescriptionLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label)
    return label
  }()
  private lazy var accountButtons: UIStackView = {
    let stack = UIStackView()
    stack.spacing = 12
    stack.distribution = .fillEqually
    return stack
  }()
  private lazy var appleSignInButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("sign_in_with_apple")
    configuration.image = UIImage(named: "apple-20")?.withRenderingMode(.alwaysTemplate)
    configuration.imagePadding = 6
    configuration.baseBackgroundColor = .primaryText
    configuration.baseForegroundColor = .nonaryText
    configuration.background.cornerRadius = 16
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 16, bottom: 12, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.delegate?.onboarding(self, didRequestSignIn: .apple, sourceView: button)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var googleSignInButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("sign_in_with_google")
    configuration.image = UIImage(named: "google-20")
    configuration.imagePadding = 6
    configuration.baseBackgroundColor = .tertiaryBackground
    configuration.baseForegroundColor = .primaryText
    configuration.background.cornerRadius = 16
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 16, bottom: 12, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.delegate?.onboarding(self, didRequestSignIn: .google, sourceView: button)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var accountStatusLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label)
    return label
  }()
  private lazy var accountManageButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("manage_account")
    configuration.baseBackgroundColor = .tertiaryBackground
    configuration.baseForegroundColor = .primaryText
    configuration.background.cornerRadius = 16
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 16, bottom: 12, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.delegate?.onboarding(self, didRequestSignIn: .apple, sourceView: button)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var accountInfoController: OnboardingModelController = {
    let controller = OnboardingModelController(
      title: LocalizedString.forKey("your_account_your_workspace"),
      detail: LocalizedString.forKey("your_account_your_workspace_detail"), badge: "",
      icon: UIImage(named: "person-24")?.withRenderingMode(.alwaysTemplate))
    controller.view.isUserInteractionEnabled = false
    return controller
  }()

  private lazy var finishedPage: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 24
    return stack
  }()
  private lazy var finishedHeading: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 0, right: 12)
    return stack
  }()
  private lazy var finishedTitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("you_are_all_set")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 28, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var finishedSubtitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("you_are_all_set_detail")
    label.textColor = .senaryText
    // Lines are 24pt apart at the 14pt design size and grow with the scaled font.
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label) {
      label, font in
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.minimumLineHeight = 24 * font.pointSize / 14
      paragraphStyle.maximumLineHeight = 24 * font.pointSize / 14
      label.attributedText = NSAttributedString(
        string: label.text ?? "", attributes: [.font: font, .paragraphStyle: paragraphStyle])
    }
    return label
  }()
  private lazy var workspaceOverviewController = OnboardingOverviewController(
    image: UIImage(named: "onboarding-workspace"), title: LocalizedString.forKey("workspace"),
    detail: LocalizedString.forKey("onboarding_workspace_detail"))
  private lazy var projectsOverviewController = OnboardingOverviewController(
    image: UIImage(named: "onboarding-projects"), title: LocalizedString.forKey("projects"),
    detail: LocalizedString.forKey("onboarding_projects_detail"))
  private lazy var threadsOverviewController = OnboardingOverviewController(
    image: UIImage(named: "onboarding-threads"), title: LocalizedString.forKey("threads"),
    detail: LocalizedString.forKey("onboarding_threads_detail"))
  private lazy var projectIdeasHeading: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 0, right: 12)
    return stack
  }()
  private lazy var projectIdeasTitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("here_are_some_project_ideas")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 28, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var projectIdeasSubtitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("here_are_some_project_ideas_detail")
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label) {
      label, font in
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.minimumLineHeight = 24 * font.pointSize / 14
      paragraphStyle.maximumLineHeight = 24 * font.pointSize / 14
      label.attributedText = NSAttributedString(
        string: label.text ?? "", attributes: [.font: font, .paragraphStyle: paragraphStyle])
    }
    return label
  }()
  // Rows of two cards each, which stand on end to make one column on a narrow page.
  private lazy var projectIdeaRows: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 12
    return stack
  }()
  private lazy var projectIdeaControllers:
    [OnboardingState.ProjectIdea: OnboardingSwitchController] = {
      var controllers = [OnboardingState.ProjectIdea: OnboardingSwitchController]()
      for idea in OnboardingState.ProjectIdea.allCases {
        let controller = OnboardingSwitchController(
          title: LocalizedString.forKey(idea.rawValue),
          detail: LocalizedString.forKey(idea.rawValue + "_detail"))
        controller.delegate = self
        controllers[idea] = controller
      }
      return controllers
    }()
  private lazy var botModeHeading: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 4, left: 12, bottom: 0, right: 12)
    return stack
  }()
  private lazy var botModeTitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("bot_mode")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 28, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var botModeSubtitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("bot_mode_detail")
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label) {
      label, font in
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.minimumLineHeight = 24 * font.pointSize / 14
      paragraphStyle.maximumLineHeight = 24 * font.pointSize / 14
      label.attributedText = NSAttributedString(
        string: label.text ?? "", attributes: [.font: font, .paragraphStyle: paragraphStyle])
    }
    return label
  }()
  // The card takes one column of the project ideas.
  private lazy var botModeRow: UIStackView = {
    let stack = UIStackView()
    stack.spacing = 12
    stack.distribution = .fillEqually
    return stack
  }()
  /// Hold the empty column beside a lone card in a row, so it stays leading aligned at the
  /// width of one column. A narrow page has one column and hides them.
  private var columnSpacers = [UIView]()
  private lazy var botModeController: OnboardingSwitchController = {
    let controller = OnboardingSwitchController(
      title: LocalizedString.forKey("enable_bot_mode"), icon: UIImage(named: "monkey"))
    controller.delegate = self
    return controller
  }()

  // The footer comes in the way the cards above the chat input do.
  private lazy var footerBannerController = ChatBannerController(contentView: footer)
  private lazy var footer: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .clear
    return view
  }()
  private lazy var footerShadow1: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .novemdecenaryBackground
    view.layer.cornerRadius = 32 - 10
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOffset = CGSize(width: 0, height: 8)
    // The design's blur of 20 is twice the layer's shadow radius; its spread of -10 is the inset.
    view.layer.shadowRadius = 10
    view.layer.shadowOpacity = 0.08
    return view
  }()
  private lazy var footerShadow2: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .novemdecenaryBackground
    view.layer.cornerRadius = 32 - 6
    view.layer.shadowColor = UIColor.black.cgColor
    view.layer.shadowOffset = CGSize(width: 0, height: 4)
    // The design's blur of 12 is twice the layer's shadow radius; its spread of -6 is the inset.
    view.layer.shadowRadius = 6
    view.layer.shadowOpacity = 0.16
    return view
  }()
  private lazy var footerContainerView: BorderView = {
    let view = BorderView.defaultBorderView(cornerRadius: 32)
    view.backgroundColor = .novemdecenaryBackground
    view.borderColor = .duodenaryBorder
    view.clipsToBounds = true
    return view
  }()
  private lazy var trackerLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .septenaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label)
    return label
  }()
  private lazy var footerActions: UIStackView = {
    let stack = UIStackView()
    stack.spacing = 6
    stack.alignment = .center
    return stack
  }()
  private lazy var backButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("back")
    configuration.baseBackgroundColor = .quaternaryFillB
    configuration.baseForegroundColor = .octonaryText
    configuration.background.cornerRadius = 20
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 16, bottom: 8, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.titleLabel?.numberOfLines = 1
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.onboardingDidRequestBack(self)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var skipButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("skip")
    configuration.baseBackgroundColor = .quaternaryFillB
    configuration.baseForegroundColor = .octonaryText
    configuration.background.cornerRadius = 20
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 16, bottom: 8, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.titleLabel?.numberOfLines = 1
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.onboardingDidRequestContinue(self)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var nextButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = .primaryFill
    configuration.baseForegroundColor = .nonaryText
    configuration.background.cornerRadius = 20
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 6
    // The trailing icon sits closer to the edge than a title does.
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 16, bottom: 8, trailing: 10)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.titleLabel?.numberOfLines = 1
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.onboardingDidRequestContinue(self)
      }, for: .touchUpInside)
    return button
  }()

  private var optionControllers = [OnboardingState.Selection: OnboardingModelController]()
  private var localModelControllers = [String: OnboardingLocalModelController]()
  private var introductionTimer: Timer?
  private var transcriptStart: CFTimeInterval?
  private var introStarted = false
  private weak var bannerView: UIView?
  private var otherProvidersExpanded = false
  private var otherModelsExpanded = false
  private var compactLayout = false

  private var initializationDuration: TimeInterval {
    welcomeLines.reduce(0) {
      $0 + Double($1.text.count) * Self.characterInterval
        + ($1.hasCheck ? Self.checkmarkPause : 0) + Self.linePause
    }
  }

  private var completedTimestampText: String {
    formatDatetime(Date()) + " · " + LocalizedString.forKey("worked") + " "
      + formatElapsedTime(initializationDuration)
  }

  deinit { introductionTimer?.invalidate() }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .tertiaryBackground
    view.addSubview(scrollView)
    view.addSubview(topBlurView)
    view.addSubview(footerBannerController.view)
    view.addSubview(scrollIndicatorController.view)
    view.addLayoutGuide(bannerGuide)
    scrollView.addSubview(scrollContent)
    scrollContent.addSubview(column)
    column.addSubview(bannerController.view)
    column.addSubview(pageStack)
    scrollView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.bottom.equalTo(footerBannerController.view.snp.top)
    }
    topBlurView.snp.makeConstraints { make in
      make.top.equalTo(scrollView)
      make.height.equalTo(26)
      make.leading.trailing.equalToSuperview()
    }
    scrollIndicatorController.view.snp.makeConstraints { make in
      make.top.bottom.trailing.equalToSuperview()
      make.width.equalTo(12)
    }
    scrollContent.snp.makeConstraints { make in
      make.edges.equalTo(scrollView.contentLayoutGuide)
      make.width.equalTo(scrollView.frameLayoutGuide)
    }
    column.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(96)
      make.bottom.equalToSuperview().offset(-32)
      make.centerX.equalToSuperview()
      make.leading.greaterThanOrEqualToSuperview().offset(24)
      make.trailing.lessThanOrEqualToSuperview().offset(-24)
      make.width.lessThanOrEqualTo(758)
      make.width.equalToSuperview().offset(-48).priority(.high)
      make.width.equalTo(758).priority(.high.advanced(by: -1))
    }
    constrainBannerGuideToPage()
    // The banner constrains its own aspect ratio.
    bannerController.view.snp.makeConstraints { make in
      make.top.leading.trailing.equalTo(bannerGuide)
    }
    pageStack.snp.makeConstraints { make in
      make.top.equalTo(bannerController.view.snp.bottom).offset(48)
      make.leading.trailing.equalToSuperview().inset(32)
      make.bottom.equalToSuperview()
    }
    pageStack.addArrangedSubview(welcomePage)
    pageStack.addArrangedSubview(modelPage)
    pageStack.addArrangedSubview(accountPage)
    pageStack.addArrangedSubview(finishedPage)

    for line in welcomeLines {
      welcomePage.addArrangedSubview(line.view)
    }
    welcomePage.addArrangedSubview(timestampController.view)
    timestampController.view.snp.makeConstraints { make in
      make.height.greaterThanOrEqualTo(24)
    }

    modelPage.addArrangedSubview(modelHeading)
    modelHeading.addArrangedSubview(modelTitleLabel)
    modelHeading.addArrangedSubview(modelSubtitleLabel)
    modelPage.addArrangedSubview(primaryOptions)
    modelPage.addArrangedSubview(otherOptionsContainer)
    modelPage.addArrangedSubview(providerDetailsContainer)
    let otherProvidersRow = UIStackView(
      arrangedSubviews: [UIView(), otherProvidersButton, UIView()])
    otherProvidersRow.distribution = .equalCentering
    modelPage.addArrangedSubview(otherProvidersRow)
    providerDetails.addArrangedSubview(connectionLabel)
    providerDetails.addArrangedSubview(connectButton)
    providerDetails.addArrangedSubview(modelButton)
    localModelGroup.addSubview(localModelGroupStack)
    localModelGroupStack.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    localModelGroupStack.addArrangedSubview(localModelContentContainer)
    for (container, section) in [
      (otherOptionsContainer, otherOptions), (providerDetailsContainer, providerDetails),
      (localModelContentContainer, localModelContent),
    ] {
      container.addSubview(section)
      section.snp.makeConstraints { make in
        make.top.leading.trailing.equalToSuperview()
        // The section keeps its size while the container closes over it.
        make.bottom.equalToSuperview().priority(.medium)
      }
    }
    localModelContent.addArrangedSubview(localModelOptions)
    let otherModelsRow = UIStackView(arrangedSubviews: [UIView(), otherModelsButton, UIView()])
    otherModelsRow.distribution = .equalCentering
    localModelContent.addArrangedSubview(otherModelsRow)

    accountPage.addArrangedSubview(accountHeading)
    accountHeading.addArrangedSubview(accountTitleLabel)
    accountHeading.addArrangedSubview(accountDescriptionLabel)
    accountPage.addArrangedSubview(accountButtons)
    accountPage.addArrangedSubview(accountStatusLabel)
    accountPage.addArrangedSubview(accountManageButton)
    accountPage.addArrangedSubview(accountInfoController.view)
    accountButtons.addArrangedSubview(appleSignInButton)
    accountButtons.addArrangedSubview(googleSignInButton)
    appleSignInButton.snp.makeConstraints { make in
      make.height.greaterThanOrEqualTo(48)
    }
    googleSignInButton.snp.makeConstraints { make in
      make.height.greaterThanOrEqualTo(48)
    }

    finishedPage.addArrangedSubview(finishedHeading)
    finishedHeading.addArrangedSubview(finishedTitleLabel)
    finishedHeading.addArrangedSubview(finishedSubtitleLabel)
    for controller in [
      workspaceOverviewController, projectsOverviewController, threadsOverviewController,
    ] {
      finishedPage.addArrangedSubview(controller.view)
      finishedPage.setCustomSpacing(48, after: controller.view)
    }
    finishedPage.setCustomSpacing(64, after: threadsOverviewController.view)
    finishedPage.addArrangedSubview(projectIdeasHeading)
    finishedPage.setCustomSpacing(36, after: projectIdeasHeading)
    projectIdeasHeading.addArrangedSubview(projectIdeasTitleLabel)
    projectIdeasHeading.addArrangedSubview(projectIdeasSubtitleLabel)
    finishedPage.addArrangedSubview(projectIdeaRows)
    finishedPage.setCustomSpacing(64, after: projectIdeaRows)
    let projectIdeas = OnboardingState.ProjectIdea.allCases
    for index in stride(from: 0, to: projectIdeas.count, by: 2) {
      let row = UIStackView(
        arrangedSubviews: projectIdeas[index..<min(index + 2, projectIdeas.count)].compactMap {
          projectIdeaControllers[$0]?.view
        })
      row.spacing = 12
      row.distribution = .fillEqually
      projectIdeaRows.addArrangedSubview(row)
    }
    finishedPage.addArrangedSubview(botModeHeading)
    finishedPage.setCustomSpacing(36, after: botModeHeading)
    botModeHeading.addArrangedSubview(botModeTitleLabel)
    botModeHeading.addArrangedSubview(botModeSubtitleLabel)
    finishedPage.addArrangedSubview(botModeRow)
    botModeRow.addArrangedSubview(botModeController.view)
    for case let row as UIStackView in projectIdeaRows.arrangedSubviews + [botModeRow]
    where row.arrangedSubviews.count == 1 {
      let spacer = UIView()
      row.addArrangedSubview(spacer)
      columnSpacers.append(spacer)
    }

    footer.addSubview(footerShadow1)
    footer.addSubview(footerShadow2)
    footer.addSubview(footerContainerView)
    footerContainerView.addSubview(trackerLabel)
    footerContainerView.addSubview(footerActions)
    footerShadow1.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(10)
    }
    footerShadow2.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(6)
    }
    footerContainerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    footerActions.addArrangedSubview(backButton)
    footerActions.addArrangedSubview(skipButton)
    footerActions.addArrangedSubview(nextButton)
    footerBannerController.view.snp.makeConstraints { make in
      make.centerX.equalToSuperview()
      make.width.equalTo(column)
      make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-20)
      make.height.greaterThanOrEqualTo(72)
    }
    trackerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    trackerLabel.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(24)
      make.centerY.equalToSuperview()
      make.trailing.lessThanOrEqualTo(footerActions.snp.leading).offset(-12)
    }
    footerActions.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview().inset(16)
      make.trailing.equalToSuperview().offset(-16)
    }
    for button in [backButton, skipButton, nextButton] {
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.setContentCompressionResistancePriority(.required, for: .horizontal)
      button.snp.makeConstraints { make in
        make.height.greaterThanOrEqualTo(40)
      }
    }

    renderModelOptions()
    renderLocalModels()
    renderModelMenu()
    renderState()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // The page can scroll clear of a card sitting above the footer.
    var bottomInset: CGFloat = 12
    if let bannerView, bannerView.superview === view {
      bottomInset += bannerView.bounds.height + 16
    }
    if scrollView.contentInset.bottom != bottomInset {
      scrollView.contentInset.bottom = bottomInset
    }
    let compact = min(758, view.bounds.width - 48) < 620
    if compactLayout != compact {
      compactLayout = compact
      accountButtons.axis = compact ? .vertical : .horizontal
      for controller in [
        workspaceOverviewController, projectsOverviewController, threadsOverviewController,
      ] {
        controller.isCompact = compact
      }
      for case let row as UIStackView in projectIdeaRows.arrangedSubviews {
        row.axis = compact ? .vertical : .horizontal
      }
      for spacer in columnSpacers {
        spacer.isHidden = compact
      }
      pageStack.snp.updateConstraints { make in
        make.leading.trailing.equalToSuperview().inset(compact ? 8 : 32)
      }
      renderState()
    }
  }

  /// Shows a card from the host, such as a model download, above the footer.
  func insertBannerView(_ bannerView: UIView) {
    loadViewIfNeeded()
    self.bannerView = bannerView
    // The footer stays on top, so a card arriving from below comes out from behind it.
    view.insertSubview(bannerView, belowSubview: footerBannerController.view)
    bannerView.snp.remakeConstraints { make in
      make.leading.trailing.equalTo(footerBannerController.view)
      make.bottom.equalTo(footerBannerController.view.snp.top).offset(-16)
    }
  }

  private func constrainBannerGuideToPage() {
    bannerGuide.snp.remakeConstraints { make in
      make.top.equalTo(column)
      make.leading.trailing.equalTo(column).inset(12)
      make.height.equalTo(0)
    }
  }

  /// Plays the welcome introduction once. The view has to be on screen for it to start.
  func startIntroduction() {
    guard view.window != nil, !introStarted else { return }
    introStarted = true
    // Lay the banner out in the page right away and stand it back where it was with a
    // transform, so the whole banner moves as one piece. The animated monkey cannot follow a
    // size change that is itself animated.
    let banner = bannerController.view
    view.layoutIfNeeded()
    let startFrame = banner.frame
    constrainBannerGuideToPage()
    view.layoutIfNeeded()
    let scale = startFrame.width / banner.frame.width
    banner.transform = CGAffineTransform(
      translationX: startFrame.midX - banner.frame.midX, y: startFrame.midY - banner.frame.midY
    ).scaledBy(x: scale, y: scale)
    // Hold the starting picture for a moment, then let the banner spring into the page.
    let animated = !UIAccessibility.isReduceMotionEnabled
    UIView.animate(
      withDuration: animated ? 0.8 : 0, delay: animated ? 0.8 : 0, usingSpringWithDamping: 0.75,
      initialSpringVelocity: 0
    ) {
      banner.transform = .identity
    } completion: { [weak self] _ in
      guard let self, self.view.window != nil else { return }
      self.welcomePage.alpha = 1
      self.transcriptStart = CACurrentMediaTime()
      let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
        self?.advanceTranscript()
      }
      self.introductionTimer = timer
      RunLoop.main.add(timer, forMode: .common)
      self.advanceTranscript()
    }
  }

  private func advanceTranscript() {
    guard let transcriptStart else { return }
    let elapsed = CACurrentMediaTime() - transcriptStart
    var lineStart: TimeInterval = 0
    for line in welcomeLines {
      let characterCount = min(
        line.text.count, max(0, Int((elapsed - lineStart) / Self.characterInterval)))
      if characterCount > 0 {
        line.view.isHidden = false
        line.typedCount = characterCount
      }
      let completedAt =
        lineStart + Double(line.text.count) * Self.characterInterval
        + (line.hasCheck ? Self.checkmarkPause : 0)
      if elapsed >= completedAt, !line.isChecked {
        line.setChecked(true, animated: !UIAccessibility.isReduceMotionEnabled)
      }
      lineStart = completedAt + Self.linePause
    }
    if elapsed >= initializationDuration, timestampController.isInitializing {
      timestampController.isInitializing = false
      timestampController.text = completedTimestampText
    }
    // Leave the completed transcript alone for a moment before the navigation comes in.
    if elapsed >= initializationDuration + 0.5 {
      introductionTimer?.invalidate()
      introductionTimer = nil
      delegate?.onboardingDidCompleteWelcome(self)
    }
  }

  /// Hides or shows an arranged subview, fading it so the change can animate. A stack view
  /// counts repeated hides made inside an animation block, so the value is only set when it
  /// actually changes.
  private func setHidden(_ isHidden: Bool, for view: UIView) {
    guard view.isHidden != isHidden else { return }
    view.isHidden = isHidden
    view.alpha = isHidden ? 0 : 1
  }

  private func renderState() {
    setHidden(state.step != .welcome, for: welcomePage)
    setHidden(state.step != .model, for: modelPage)
    setHidden(state.step != .account, for: accountPage)
    setHidden(state.step != .finished, for: finishedPage)
    footerBannerController.setVisible(
      state.step != .welcome || state.welcomeCompleted,
      animated: !UIAccessibility.isReduceMotionEnabled)
    if state.welcomeCompleted {
      for line in welcomeLines {
        setHidden(false, for: line.view)
        line.typedCount = line.text.count
        line.setChecked(true, animated: false)
      }
      timestampController.isInitializing = false
      timestampController.text = completedTimestampText
    }
    let progress = LocalizedString.format(
      key: "x_of_y", (state.steps.firstIndex(of: state.step) ?? 0) + 1, state.steps.count)
    let title: String
    switch state.step {
    case .welcome: title = LocalizedString.forKey("welcome_to_local_code")
    case .model: title = LocalizedString.forKey("choose_a_model")
    case .account: title = LocalizedString.forKey("create_an_account")
    case .finished: title = LocalizedString.forKey("you_are_all_set")
    }
    trackerLabel.text = compactLayout ? progress : "\(progress) · \(title)"
    setHidden(state.step == .welcome, for: backButton)
    setHidden(state.step != .account || !state.canSkipAccount, for: skipButton)
    nextButton.isEnabled = state.canContinue
    skipButton.isEnabled = state.canContinue
    setHidden(state.step == .account && state.canSkipAccount, for: nextButton)
    nextButton.configuration?.title =
      LocalizedString.forKey(
        state.step == .welcome
          ? "get_started"
          : state.step == .finished
            ? (compactLayout ? "start" : "start_new_thread")
            : (compactLayout ? "next" : "continue"))
    nextButton.configuration?.image = UIImage(
      named: state.step == .finished ? "chat-new-24" : "arrow-right-thick-24"
    )?.withRenderingMode(.alwaysTemplate)
    for (idea, controller) in projectIdeaControllers {
      controller.isOn = state.projectIdeas.contains(idea)
    }
    botModeController.isOn = state.isBotModeEnabled
    // Bot Mode calls projects bots throughout the app, so this page follows its switch.
    let isBotModeEnabled = state.isBotModeEnabled
    workspaceOverviewController.detail = LocalizedString.forKey(
      isBotModeEnabled ? "onboarding_workspace_bot_detail" : "onboarding_workspace_detail")
    projectsOverviewController.title = LocalizedString.forKey(
      isBotModeEnabled ? "bots" : "projects")
    projectsOverviewController.detail = LocalizedString.forKey(
      isBotModeEnabled ? "onboarding_bots_detail" : "onboarding_projects_detail")
    threadsOverviewController.detail = LocalizedString.forKey(
      isBotModeEnabled ? "onboarding_threads_bot_detail" : "onboarding_threads_detail")
    projectIdeasTitleLabel.text = LocalizedString.forKey(
      isBotModeEnabled ? "here_are_some_bot_ideas" : "here_are_some_project_ideas")
    // Swap only the characters so the text keeps its scaled font and line height.
    let projectIdeasDetail = NSMutableAttributedString(
      attributedString: projectIdeasSubtitleLabel.attributedText ?? NSAttributedString())
    projectIdeasDetail.replaceCharacters(
      in: NSRange(location: 0, length: projectIdeasDetail.length),
      with: LocalizedString.forKey(
        isBotModeEnabled ? "here_are_some_bot_ideas_detail" : "here_are_some_project_ideas_detail"))
    projectIdeasSubtitleLabel.attributedText = projectIdeasDetail
    setHidden(!otherProvidersExpanded, for: otherOptionsContainer)
    otherProvidersButton.accessibilityValue = LocalizedString.forKey(
      otherProvidersExpanded ? "expanded" : "collapsed")
    otherProvidersButton.configuration?.image = UIImage(
      named: otherProvidersExpanded ? "chevron-up-16" : "chevron-down-16"
    )?.withRenderingMode(.alwaysTemplate)
    let routerNeedsSetup =
      state.selection == .remote(.localCode) && state.isAccountSignedIn && !state.canContinue
    setHidden(
      state.selection == .local || (state.selection == .remote(.localCode) && !routerNeedsSetup),
      for: providerDetailsContainer)
    connectionLabel.text =
      routerNeedsSetup ? LocalizedString.forKey("setting_up_cloud_compute") : connectionMessage
    connectButton.configuration?.title =
      LocalizedString.forKey(
        routerNeedsSetup
          ? "manage_account" : state.isProviderConnected ? "manage_connection" : "connect_provider")
    setHidden(
      !state.isProviderConnected || state.selection == .remote(.localCode), for: modelButton)
    for (selection, controller) in optionControllers {
      controller.isSelected = state.selection == selection
    }
    renderLocalModelSelection()
    accountDescriptionLabel.text =
      LocalizedString.forKey(
        state.selection == .remote(.localCode)
          ? "sign_in_to_use_cloud_compute_detail" : "local_code_account_optional_detail")
    setHidden(state.isAccountSignedIn, for: accountButtons)
    setHidden(!state.isAccountSignedIn, for: accountManageButton)
    setHidden(!state.isAccountSignedIn, for: accountStatusLabel)
    accountStatusLabel.text =
      LocalizedString.forKey(
        state.selection == .remote(.localCode) && !state.canContinue
          ? "signed_in_setting_up_cloud_compute" : "you_are_signed_in_to_local_code")
  }

  private func renderModelOptions() {
    for controller in optionControllers.values {
      controller.view.removeFromSuperview()
    }
    optionControllers.removeAll()
    localModelGroup.removeFromSuperview()
    for option in options {
      let controller = OnboardingModelController(
        selection: option.selection, title: option.title, detail: option.detail,
        badge: option.badge, isBadgeHighlighted: option.isBadgeHighlighted)
      controller.delegate = self
      controller.isSelected = option.selection == state.selection
      optionControllers[option.selection] = controller
      switch option.selection {
      case .local:
        controller.isOutlined = false
        localModelGroupStack.insertArrangedSubview(controller.view, at: 0)
        primaryOptions.addArrangedSubview(localModelGroup)
      case .remote(.localCode):
        primaryOptions.addArrangedSubview(controller.view)
      case .remote:
        otherOptions.addArrangedSubview(controller.view)
      }
    }
    renderLocalModelSelection()
  }

  private func renderLocalModels() {
    for controller in localModelControllers.values {
      controller.view.removeFromSuperview()
    }
    localModelControllers.removeAll()
    for model in localModels {
      let controller = OnboardingLocalModelController(model: model)
      controller.delegate = self
      localModelControllers[model.id] = controller
      localModelOptions.addArrangedSubview(controller.view)
    }
    renderLocalModelSelection()
  }

  private func renderLocalModelSelection() {
    let isLocal = state.selection == .local
    localModelGroup.backgroundColor = isLocal ? .novemdecenaryBackground : .tertiaryBackground
    localModelGroup.borderColor = isLocal ? .quaternaryBorder : .primaryBorder
    setHidden(!isLocal, for: localModelContentContainer)
    for (id, controller) in localModelControllers {
      controller.isSelected = id == selectedLocalModel
      setHidden(!otherModelsExpanded && !controller.isSelected, for: controller.view)
    }
    setHidden(localModels.count < 2, for: otherModelsButton)
    otherModelsButton.accessibilityValue = LocalizedString.forKey(
      otherModelsExpanded ? "expanded" : "collapsed")
    otherModelsButton.configuration?.image = UIImage(
      named: otherModelsExpanded ? "chevron-up-16" : "chevron-down-16"
    )?.withRenderingMode(.alwaysTemplate)
  }

  private func renderModelMenu() {
    modelButton.configuration?.title =
      isLoadingModels
      ? LocalizedString.forKey("loading_models")
      : selectedModel ?? LocalizedString.forKey("choose_a_model")
    modelButton.menu = UIMenu(
      children: models.map { model in
        UIAction(title: model, state: model == selectedModel ? .on : .off) { [weak self] _ in
          guard let self else { return }
          self.delegate?.onboarding(self, didSelectModel: model)
        }
      })
    modelButton.isEnabled = !isLoadingModels && !models.isEmpty
  }
}

extension OnboardingViewController: OnboardingModelControllerDelegate {
  func onboardingModelControllerDidSelect(_ controller: OnboardingModelController) {
    guard let selection = controller.selection else { return }
    UIView.animate(withDuration: 0.2) {
      self.delegate?.onboarding(self, didSelectOption: selection)
      self.view.layoutIfNeeded()
    }
  }
}

extension OnboardingViewController: OnboardingLocalModelControllerDelegate {
  func onboardingLocalModelControllerDidSelect(_ controller: OnboardingLocalModelController) {
    delegate?.onboarding(self, didSelectLocalModel: controller.model.id)
  }
}

extension OnboardingViewController: OnboardingSwitchControllerDelegate {
  func onboardingSwitchController(_ controller: OnboardingSwitchController, didSetOn isOn: Bool) {
    if controller === botModeController {
      delegate?.onboarding(self, didSetBotModeEnabled: isOn)
    } else if let idea = projectIdeaControllers.first(where: { $0.value === controller })?.key {
      delegate?.onboarding(self, didSetProjectIdea: idea, isOn: isOn)
    }
  }
}
