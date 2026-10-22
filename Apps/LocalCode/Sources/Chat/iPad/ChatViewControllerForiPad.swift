import AVKit
import Components
import Localization
import ProjectHistoryManager
import SnapKit
import Style
import UIKit

extension UIResponder {
  /// Call this method inside a `UIResponder.touchesBegan(_:with:)` method to perform window drag.
  ///
  /// This method has effect only when your app is running on macOS.
  public func performMacCatalystWindowDrag() {
    // NSApplication.shared.currentEvent
    // NSWindow.performDrag(with:)
    #if targetEnvironment(macCatalyst)
      guard
        let nsApp =
          ((NSClassFromString("NSApplication") as? NSObject.Type)?.value(
            forKey: "sharedApplication") as? NSObject),
        let currentEvent = nsApp.value(forKey: "currentEvent") as? NSObject,
        let nsWindow = currentEvent.value(forKey: "window") as? NSObject
      else { return }
      nsWindow.perform(NSSelectorFromString("performWindowDragWithEvent:"), with: currentEvent)
    #endif
  }

  public func performMacCatalystZoom() {
    // NSApplication.shared.currentEvent
    // NSWindow.performZoom(_:)
    #if targetEnvironment(macCatalyst)
      guard
        let nsApp =
          ((NSClassFromString("NSApplication") as? NSObject.Type)?.value(
            forKey: "sharedApplication") as? NSObject),
        let currentEvent = nsApp.value(forKey: "currentEvent") as? NSObject,
        let nsWindow = currentEvent.value(forKey: "window") as? NSObject
      else { return }
      nsWindow.perform(NSSelectorFromString("performZoom:"), with: currentEvent)
    #endif
  }
}

private final class MovableTitlebar: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
    tapGestureRecognizer.numberOfTapsRequired = 2
    addGestureRecognizer(tapGestureRecognizer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func doubleTapped() {
    performMacCatalystZoom()
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    performMacCatalystWindowDrag()
    super.touchesBegan(touches, with: event)
  }
}

protocol ChatViewControllableDelegate: AnyObject {
  func chatViewControllerDidRequestNewProject(_ viewController: UIViewController)
  func chatViewControllerDidRequestNewChat(_ viewController: UIViewController)
  func chatViewControllerDidRequestMachineSettings(_ viewController: UIViewController)
  func chatViewControllerDidRequestProjectsTab(_ viewController: UIViewController)
  func chatViewControllerDidRequestSettingsTab(_ viewController: UIViewController)
  func chatViewControllerDidRequestKitTab(_ viewController: UIViewController)
  func chatViewControllerDidRequestActivitiesTab(_ viewController: UIViewController)
  func chatViewControllerDidRequestWelcome(_ viewController: UIViewController)
  func chatViewController(
    _ viewController: UIViewController,
    didSelectCopyHistoryText text: String)
  func chatViewControllerDidRequestContinueIncompleteResponse(_ viewController: UIViewController)
  func chatViewController(
    _ viewController: UIViewController,
    didSteerQueuedItem queuedItem: ProjectQueuedItem)
  func chatViewController(
    _ viewController: UIViewController,
    didDeleteQueuedItem queuedItem: ProjectQueuedItem)
  func chatViewController(
    _ viewController: UIViewController, didSetProjectDemoHidden isHidden: Bool)
  func chatViewController(
    _ viewController: UIViewController,
    didReceiveScreenEdgePan screenEdgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer)
}

final class ChatViewControllerForiPad: UIViewController, ChatViewControllable {

  weak var delegate: ChatViewControllableDelegate?

  private let settingsViewController: UIViewController
  private let chatInputController: ChatInputController
  private var onboardingViewController: OnboardingViewController?
  private var modelSpeedViewController: ModelSpeedViewController?
  private var chatBannerView: UIView?
  private let projectBarController: ProjectBarController
  private let emptyBannerController: EmptyBannerController
  private var projectHistoryItems = [ProjectHistoryItem]()
  private var actionableMessageItem: ProjectHistoryItem?
  private var queuedItems = [ProjectQueuedItem]()
  private var nextProjectHistoryItemId = 0
  private var projectHistoryVerticalScrollIndicatorController: VerticalScrollIndicatorController? =
    nil
  private var queuedItemsViewBottomConstraint: Constraint? = nil
  private var chatBannerBottomToQueueConstraint: Constraint? = nil
  private(set) var localPathResolver: LocalPathResolver?
  // Replaces the empty banner when the open project ships a demo video, unless the project
  // switched it off for the banner.
  private lazy var projectDemoController: ProjectDemoController = {
    let controller = ProjectDemoController(bannerController: emptyBannerController)
    controller.delegate = self
    return controller
  }()
  // Next to the banner, switches the demo back on.
  private lazy var projectDemoButton: UIButton = {
    var configuration = UIButton.Configuration.gray()
    configuration.image = UIImage(
      systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11))
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = .label
    let button = UIButton(configuration: configuration)
    button.accessibilityLabel = LocalizedString.forKey("preview")
    button.isHidden = true
    button.alpha = 0
    button.addAction(
      UIAction { [weak self] _ in
        guard let self, !self.projectDemoController.isSwitching else { return }
        self.isProjectDemoHidden = false
        self.delegate?.chatViewController(self, didSetProjectDemoHidden: false)
        UIView.animate(withDuration: 0.2) {
          self.projectDemoButton.alpha = 0
        } completion: { _ in
          self.projectDemoButton.isHidden = true
        }
        self.projectDemoController.switchOn { [weak self] in
          self?.updateChatInputEmptyState()
        }
      }, for: .touchUpInside)
    return button
  }()
  private var isProjectDemoHidden = false

  func setProjectDemo(url: URL?, isHidden: Bool) {
    projectDemoController.videoURL = url
    isProjectDemoHidden = isHidden
    updateChatInputEmptyState()
  }

  func setLocalPathResolver(_ resolver: LocalPathResolver?, refreshVisibleCells: Bool) {
    guard resolver != localPathResolver else { return }
    localPathResolver = resolver
    // During a project switch, setHistory replaces every item. Its cell provider
    // applies the new resolver; rebuilding the outgoing transcript is wasted work.
    guard refreshVisibleCells, isViewLoaded else { return }
    for cell in projectHistoryCollectionView.visibleCells {
      if let cell = cell as? ProjectHistoryAssistantViewCell {
        cell.localPathResolver = localPathResolver
      } else if let cell = cell as? ProjectHistoryAssistantThinkViewCell {
        cell.localPathResolver = localPathResolver
      } else if let cell = cell as? ProjectHistoryUserViewCell {
        cell.localPathResolver = localPathResolver
      }
    }
    projectHistoryCollectionView.collectionViewLayout.invalidateLayout()
  }
  private lazy var middleRightContainerView: UIView = {
    let view = UIView(frame: .zero)
    view.layer.maskedCorners = [.layerMaxXMinYCorner]
    #if targetEnvironment(macCatalyst)
      view.layer.cornerRadius = 0
    #else
      view.layer.cornerRadius = 16
    #endif
    view.clipsToBounds = true
    view.backgroundColor = .tertiaryBackground
    return view
  }()
  private lazy var middleContainerView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .tertiaryBackground
    return view
  }()
  private lazy var chatContentView: PassThroughView = {
    PassThroughView(frame: .zero)
  }()
  private lazy var queuedItemsStackView: UIStackView = {
    let stackView = UIStackView(frame: .zero)
    stackView.axis = .vertical
    stackView.spacing = 4
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.clipsToBounds = true
    return stackView
  }()
  private lazy var queuedItemsView: UIView = {
    let view = UIView(frame: .zero)
    // The shadows are cut out where the container is, so only what falls outside it shows.
    let shadow1 = ShadowView(frame: .zero)
    shadow1.cornerRadius = 24
    shadow1.contentInsets = UIEdgeInsets(top: -10, left: -10, bottom: -10, right: -10)
    shadow1.backgroundColor = .novemdecenaryBackground
    shadow1.layer.cornerRadius = 24 - 10
    shadow1.layer.shadowColor = UIColor.black.cgColor
    shadow1.layer.shadowOffset = CGSize(width: 0, height: 8)
    shadow1.layer.shadowRadius = 10
    shadow1.layer.shadowOpacity = 0.08
    view.addSubview(shadow1)
    shadow1.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(10)
    }
    let shadow2 = ShadowView(frame: .zero)
    shadow2.cornerRadius = 24
    shadow2.contentInsets = UIEdgeInsets(top: -6, left: -6, bottom: -6, right: -6)
    shadow2.backgroundColor = .novemdecenaryBackground
    shadow2.layer.cornerRadius = 24 - 6
    shadow2.layer.shadowColor = UIColor.black.cgColor
    shadow2.layer.shadowOffset = CGSize(width: 0, height: 4)
    shadow2.layer.shadowRadius = 6
    shadow2.layer.shadowOpacity = 0.16
    view.addSubview(shadow2)
    shadow2.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(6)
    }
    let containerView = BorderView.defaultBorderView(cornerRadius: 24)
    containerView.borderColor = .duodenaryBorder
    containerView.layer.borderWidth = 0.5
    containerView.backgroundColor = .novemdecenaryBackground
    containerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    containerView.clipsToBounds = true
    view.addSubview(containerView)
    containerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    containerView.addSubview(queuedItemsStackView)
    queuedItemsStackView.snp.makeConstraints { make in
      make.top.equalToSuperview().inset(8)
      make.trailing.equalToSuperview().inset(12)
      make.bottom.equalToSuperview().inset(7.5)
      make.leading.equalToSuperview().inset(20)
    }
    return view
  }()
  private lazy var projectHistoryCollectionView: UICollectionView = {
    let collectionView = UICollectionView(
      frame: .zero, collectionViewLayout: Self.projectHistoryCollectionViewLayout())
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.keyboardDismissMode = .interactive
    collectionView.showsVerticalScrollIndicator = false
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.automaticallyAdjustsScrollIndicatorInsets = false
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.scrollIndicatorInsets = UIEdgeInsets(
      top: 16, left: 0, bottom: 16, right: 0)
    // A window resize measures rows before they take the new width, so a markdown image still
    // has its old size then. Its text view resizes the image afterwards; re-measure the row.
    collectionView.selfSizingInvalidation = .enabledIncludingConstraints
    collectionView.register(
      ProjectHistoryAssistantViewCell.self,
      forCellWithReuseIdentifier: ProjectHistoryAssistantViewCell.reusableIdentifier)
    collectionView.register(
      ProjectHistoryAssistantThinkViewCell.self,
      forCellWithReuseIdentifier: ProjectHistoryAssistantThinkViewCell.reusableIdentifier)
    collectionView.register(
      ProjectHistoryUserViewCell.self,
      forCellWithReuseIdentifier: ProjectHistoryUserViewCell.reusableIdentifier)
    collectionView.register(
      ProjectHistoryActionableMessageViewCell.self,
      forCellWithReuseIdentifier: ProjectHistoryActionableMessageViewCell.reusableIdentifier)
    return collectionView
  }()
  private lazy var projectHistoryContentInsetController = ContentInsetController(
    scrollView: projectHistoryCollectionView)
  private let middleContainerTopBlurMaskLayer: CAGradientLayer = {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.white.cgColor,
      UIColor.white.withAlphaComponent(0.8).cgColor,
      UIColor.white.withAlphaComponent(0).cgColor,
    ]
    gradientLayer.locations = [0, 0.2, 1]
    return gradientLayer
  }()
  private lazy var middleContainerTopBlurView: LayoutVisualEffectView = {
    let visualEffectView = LayoutVisualEffectView(
      effect: UIBlurEffect(style: .systemThickMaterial))
    visualEffectView.isUserInteractionEnabled = false
    visualEffectView.layer.mask = middleContainerTopBlurMaskLayer
    let maskLayer = middleContainerTopBlurMaskLayer
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
  private lazy var projectHistoryCollectionViewDiffableDataSource =
    UICollectionViewDiffableDataSource<Int, ProjectHistoryItem.ItemIdentifier>(
      collectionView: projectHistoryCollectionView
    ) { [weak self] collectionView, indexPath, item in
      guard let self else { return nil }
      let projectHistoryItem: ProjectHistoryItem
      if item.type == .actionableMessageItem {
        guard let actionableMessageItem else { return nil }
        projectHistoryItem = actionableMessageItem
      } else {
        projectHistoryItem = projectHistoryItems[indexPath.item]
      }
      switch projectHistoryItem {
      case .actionableMessageItem(_, let message):
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: ProjectHistoryActionableMessageViewCell.reusableIdentifier,
            for: indexPath) as! ProjectHistoryActionableMessageViewCell
        cell.viewModel = message
        return cell
      case .assistant(_, let text, let datetime, let duration):
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: ProjectHistoryAssistantViewCell.reusableIdentifier,
            for: indexPath) as! ProjectHistoryAssistantViewCell
        cell.localPathResolver = localPathResolver
        cell.text = text
        cell.setDatetime(datetime, duration: duration)
        cell.delegate = self
        return cell
      case .assistantIncomplete(_, let text, let datetime):
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: ProjectHistoryAssistantViewCell.reusableIdentifier,
            for: indexPath) as! ProjectHistoryAssistantViewCell
        cell.localPathResolver = localPathResolver
        cell.text = text
        cell.setDatetime(datetime, duration: 0, isIncomplete: true)
        cell.delegate = self
        return cell
      case .assistantThink(_, let text, let thinking, let output, let mode):
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: ProjectHistoryAssistantThinkViewCell.reusableIdentifier,
            for: indexPath) as! ProjectHistoryAssistantThinkViewCell
        cell.localPathResolver = localPathResolver
        cell.isReduceReasoningAnimationEnabled = isReduceReasoningAnimationEnabled
        cell.viewModel = ProjectHistoryAssistantThinkViewCell.ViewModel(
          temporary: text, thinking: thinking, output: output, mode: mode)
        return cell
      case .user(_, let text, let datetime):
        let cell =
          collectionView.dequeueReusableCell(
            withReuseIdentifier: ProjectHistoryUserViewCell.reusableIdentifier,
            for: indexPath) as! ProjectHistoryUserViewCell
        cell.localPathResolver = localPathResolver
        cell.text = text
        cell.datetime = datetime
        cell.delegate = self
        return cell
      }
    }
  private lazy var middleRightContainerBackgroundView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .white
    view.layer.maskedCorners = [.layerMaxXMinYCorner]
    view.layer.cornerRadius = 16
    view.layer.shadowOpacity = 0.25
    view.layer.shadowColor = UIColor.primaryShadow.cgColor
    view.layer.shadowOffset = CGSize(width: -2, height: -2)
    view.layer.shadowRadius = 5
    view.isUserInteractionEnabled = false
    return view
  }()

  var isBotModeEnabled = false {
    didSet {
      guard isBotModeEnabled != oldValue else { return }
      UIMenuSystem.main.setNeedsRebuild()
    }
  }
  var isReduceReasoningAnimationEnabled = false {
    didSet {
      guard isReduceReasoningAnimationEnabled != oldValue, isViewLoaded else { return }
      for case let cell as ProjectHistoryAssistantThinkViewCell
        in projectHistoryCollectionView.visibleCells
      {
        cell.isReduceReasoningAnimationEnabled = isReduceReasoningAnimationEnabled
      }
    }
  }

  override var keyCommands: [UIKeyCommand]? {
    Self.keyboardCommands(isBotModeEnabled: isBotModeEnabled)
  }

  override func buildMenu(with builder: UIMenuBuilder) {
    super.buildMenu(with: builder)
    Self.buildMainMenu(with: builder, isBotModeEnabled: isBotModeEnabled)
  }

  init(
    chatInputController: ChatInputController, projectBarController: ProjectBarController,
    emptyBannerController: EmptyBannerController,
    settingsViewController: UIViewController
  ) {
    self.settingsViewController = settingsViewController
    self.chatInputController = chatInputController
    self.projectBarController = projectBarController
    self.emptyBannerController = emptyBannerController
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @available(iOS 26.0, *)
  @objc private func updateTransparency() {
    let reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
    #if targetEnvironment(macCatalyst)
      // Restore the solid app color when the shared window material should not show through.
      view.backgroundColor = UIColor.primaryBackground.withAlphaComponent(
        reduceTransparency ? 1 : 0.15)
      view.isOpaque = reduceTransparency
    #endif
    // Reduce Transparency turns the soft edge into a solid fill. On Mac the edge spans the whole
    // chat column it is attached to, and on macOS 26 that fill hides the transcript.
    projectHistoryCollectionView.bottomEdgeEffect.isHidden = reduceTransparency
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Local Code"
    navigationItem.largeTitleDisplayMode = .never
    view.backgroundColor = .primaryBackground
    if #available(iOS 26.0, *) {
      updateTransparency()
      NotificationCenter.default.addObserver(
        self, selector: #selector(updateTransparency),
        name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }
    updateChatInputEmptyState()

    // Keep the custom title bar behind the panels so interactive controls continue to receive taps.
    #if targetEnvironment(macCatalyst)
      let titlebar = MovableTitlebar(frame: .zero)
      view.addSubview(titlebar)
      titlebar.snp.makeConstraints { make in
        make.leading.trailing.equalToSuperview()
        make.top.equalTo(view.snp.top)
        make.bottom.equalTo(view.snp.topMargin)
      }
    #endif

    addChild(settingsViewController)
    view.addSubview(settingsViewController.view)
    settingsViewController.didMove(toParent: self)

    let leftPanelWidth: CGFloat
    #if targetEnvironment(macCatalyst)
      if #available(iOS 26, macOS 26, macCatalyst 26, *) {
        leftPanelWidth = 466 + 14
      } else {
        leftPanelWidth = 466
      }
    #else
      leftPanelWidth = (UIScreen.main.bounds.width * 0.245).rounded() + 78 + 24
    #endif

    settingsViewController.view.snp.makeConstraints { make in
      make.leading.bottom.equalToSuperview()
      make.width.equalTo(leftPanelWidth)
      #if targetEnvironment(macCatalyst)
        make.top.equalTo(view.snp.top)
      #else
        make.top.equalTo(view.snp.topMargin)
      #endif
    }

    #if targetEnvironment(macCatalyst)
      view.addSubview(middleRightContainerBackgroundView)
      view.addSubview(middleRightContainerView)
      middleRightContainerBackgroundView.snp.makeConstraints { make in
        make.edges.equalTo(middleRightContainerView)
      }
    #else
      let backgroundClipper = UIView(frame: .zero)
      backgroundClipper.clipsToBounds = true
      backgroundClipper.isUserInteractionEnabled = false
      view.addSubview(backgroundClipper)
      backgroundClipper.addSubview(middleRightContainerBackgroundView)
      view.addSubview(middleRightContainerView)
      middleRightContainerBackgroundView.snp.makeConstraints { make in
        make.leading.equalToSuperview().offset(-60)
        make.top.bottom.trailing.equalTo(middleRightContainerView)
      }
      backgroundClipper.snp.makeConstraints { make in
        make.top.equalToSuperview()
        make.leading.bottom.trailing.equalTo(middleRightContainerView)
      }
    #endif

    middleRightContainerView.snp.makeConstraints { make in
      make.leading.equalTo(settingsViewController.view.snp.trailing)
      make.trailing.bottom.equalToSuperview()
      #if targetEnvironment(macCatalyst)
        make.top.equalTo(view.snp.top)
      #else
        make.top.equalTo(view.snp.topMargin)
      #endif
    }

    middleRightContainerView.addSubview(middleContainerView)
    middleContainerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    // Dropping files anywhere over the conversation or the composer attaches them. The history
    // collection view takes drops itself, so it gets the same handling as its drop delegate.
    chatInputController.addAttachmentDropInteraction(to: middleContainerView)
    chatInputController.setAttachmentDropDelegate(of: projectHistoryCollectionView)

    // The middle panel is not pass-through, so place its title bar above that panel.
    #if targetEnvironment(macCatalyst)
      let middleRightTitlebar = MovableTitlebar(frame: .zero)
      view.addSubview(middleRightTitlebar)
      middleRightTitlebar.snp.makeConstraints { make in
        make.leading.equalTo(middleRightContainerView)
        make.trailing.equalToSuperview()
        make.top.equalTo(view.snp.top)
        make.bottom.equalTo(view.snp.topMargin)
      }
    #endif

    middleContainerView.addSubview(projectHistoryCollectionView)
    middleContainerView.addSubview(projectHistoryContentInsetController.view)
    middleContainerView.addSubview(middleContainerTopBlurView)
    middleContainerView.addSubview(chatContentView)
    middleContainerView.addSubview(projectBarController.view)
    chatContentView.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview()
      make.centerX.equalToSuperview()
      make.leading.greaterThanOrEqualToSuperview().offset(48)
      make.trailing.lessThanOrEqualToSuperview().offset(-48)
      make.width.lessThanOrEqualTo(960)
      make.width.equalToSuperview().offset(-96).priority(.high.advanced(by: 1))
      make.width.equalTo(960).priority(.high)
    }
    chatContentView.addSubview(queuedItemsView)
    chatContentView.addSubview(chatInputController.view)

    let projectHistoryVerticalScrollIndicatorController = VerticalScrollIndicatorController(
      scrollView: projectHistoryCollectionView)
    projectHistoryCollectionView.delegate =
      projectHistoryVerticalScrollIndicatorController.objCResponder
    self.projectHistoryVerticalScrollIndicatorController =
      projectHistoryVerticalScrollIndicatorController
    middleContainerView.addSubview(projectHistoryVerticalScrollIndicatorController.view)
    projectHistoryVerticalScrollIndicatorController.view.snp.makeConstraints { make in
      make.top.bottom.trailing.equalToSuperview()
      make.width.equalTo(12)
    }
    chatContentView.keyboardLayoutGuide.followsUndockedKeyboard = false
    chatInputController.view.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview()
      make.bottom.equalTo(chatContentView.safeAreaLayoutGuide.snp.bottom).offset(-24).priority(
        .high)
      make.bottom.lessThanOrEqualTo(chatContentView.keyboardLayoutGuide.snp.top).offset(-16)
    }
    // The queue sits on the input rather than tucking under its glass; the extra 0.5pt lays its
    // bottom border over the input's top one. Hidden, it waits 23pt lower.
    queuedItemsView.snp.makeConstraints { make in
      make.leading.trailing.equalTo(chatInputController.view).inset(32)
      make.height.equalTo(36).priority(.low)
      if queuedItems.isEmpty {
        queuedItemsViewBottomConstraint =
          make.bottom.equalTo(chatInputController.view.snp.top).offset(23.5).constraint
        queuedItemsView.alpha = 0
      } else {
        queuedItemsViewBottomConstraint =
          make.bottom.equalTo(chatInputController.view.snp.top).offset(0.5).constraint
        queuedItemsView.alpha = 1
      }
    }
    // The transcript fills the panel so it scrolls from anywhere over it, and on under the project
    // bar and the input, but its content rests between them in the chat column.
    projectHistoryCollectionView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    projectHistoryContentInsetController.view.snp.makeConstraints { make in
      make.edges.equalTo(projectHistoryCollectionView)
    }
    projectHistoryContentInsetController.layoutGuide.snp.makeConstraints { make in
      make.top.equalTo(projectBarController.view.snp.bottom).offset(16)
      // As low as the queue allows; a chat banner holds it higher.
      make.bottom.lessThanOrEqualTo(queuedItemsView.snp.top).offset(-36)
      make.bottom.equalTo(queuedItemsView.snp.top).offset(-36).priority(.low)
      make.leading.trailing.equalTo(chatContentView).inset(32)
    }
    middleContainerTopBlurView.snp.makeConstraints { make in
      make.top.equalTo(projectHistoryCollectionView)
      make.height.equalTo(26)
      make.leading.trailing.equalToSuperview()
    }
    if #available(iOS 26.0, *) {
      // The transcript softens as it scrolls under the input, the queue and a chat banner; with
      // nothing under them, the panel shows through unchanged.
      let edgeElementContainerInteraction = UIScrollEdgeElementContainerInteraction()
      edgeElementContainerInteraction.scrollView = projectHistoryCollectionView
      edgeElementContainerInteraction.edge = .bottom
      chatContentView.addInteraction(edgeElementContainerInteraction)
      projectHistoryCollectionView.bottomEdgeEffect.style = .soft
    }
    projectBarController.view.snp.makeConstraints { make in
      make.leading.top.equalTo(middleContainerView).inset(20)
      make.trailing.lessThanOrEqualTo(middleContainerView).inset(20)
    }
    // A layout guide keeps the banner centered as the input/keyboard moves.
    let bannerSpace = UILayoutGuide()
    middleContainerView.addLayoutGuide(bannerSpace)
    bannerSpace.snp.makeConstraints { make in
      make.top.equalTo(projectBarController.view.snp.bottom)
      make.bottom.equalTo(chatInputController.view.snp.top)
      make.leading.trailing.equalTo(chatContentView)
    }
    middleContainerView.addSubview(emptyBannerController.view)
    emptyBannerController.view.snp.makeConstraints { make in
      make.leading.trailing.equalTo(chatContentView).inset(16)
      make.centerY.equalTo(bannerSpace)
    }
    // Below the top blur, so a set pushed up by the keyboard slides under the project bar like the
    // transcript does.
    middleContainerView.insertSubview(
      projectDemoController.view, belowSubview: middleContainerTopBlurView)
    // The set keeps its size: centered when there is room, and pushed up to stay clear of the
    // input when the keyboard takes the space.
    projectDemoController.view.snp.makeConstraints { make in
      make.leading.trailing.equalTo(chatContentView).inset(64)
      // Centering gives way first, so the set moves rather than shrinks.
      make.centerY.equalTo(bannerSpace).priority(.low)
      make.bottom.lessThanOrEqualTo(chatInputController.view.snp.top).offset(-12)
    }
    middleContainerView.addSubview(projectDemoButton)
    projectDemoButton.snp.makeConstraints { make in
      make.width.height.equalTo(32)
      make.centerX.equalTo(emptyBannerController.view)
      make.top.equalTo(emptyBannerController.view.snp.bottom).offset(12)
    }
    updateChatInputEmptyState()
    updateQueuedItems(from: [])
    applyProjectHistorySnapshot(
      scrollTo: projectHistoryItems.last, animated: false,
      scrollToItem: !projectHistoryItems.isEmpty)
    #if targetEnvironment(macCatalyst)
      resolveWindowMovablePeriodically()
    #endif
  }

  func setOnboardingViewController(
    _ controller: OnboardingViewController?, animated: Bool, completionHandler: (() -> Void)?
  ) {
    loadViewIfNeeded()
    let previousController = onboardingViewController
    onboardingViewController = controller
    if let controller {
      view.endEditing(true)
      addChild(controller)
      middleContainerView.addSubview(controller.view)
      controller.view.snp.makeConstraints { $0.edges.equalToSuperview() }
      // The walkthrough's banner starts out exactly where the empty banner sits.
      controller.bannerGuide.snp.remakeConstraints { make in
        make.edges.equalTo(emptyBannerController.view)
      }
      controller.didMove(toParent: self)
    }
    // The chat stays live underneath until the walkthrough covers it, so its animated monkey
    // is on screen all the way through the cross-fade.
    let completion = { [self] in
      // Move the card to its new home first, so it never leaves the window with the
      // walkthrough it was shown in.
      if let chatBannerView {
        insertChatBannerView(chatBannerView)
      }
      if let previousController {
        previousController.willMove(toParent: nil)
        previousController.view.removeFromSuperview()
        previousController.removeFromParent()
      }
      updateChatVisibility()
      completionHandler?()
    }
    guard animated, let controller else {
      completion()
      return
    }
    controller.view.alpha = 0
    UIView.animate(withDuration: 0.3) {
      controller.view.alpha = 1
    } completion: { _ in
      completion()
    }
  }

  func setModelSpeedViewController(_ controller: ModelSpeedViewController?, animated: Bool) {
    loadViewIfNeeded()
    let previousController = modelSpeedViewController
    modelSpeedViewController = controller
    if let controller {
      view.endEditing(true)
      addChild(controller)
      middleContainerView.addSubview(controller.view)
      controller.view.snp.makeConstraints { $0.edges.equalToSuperview() }
      controller.didMove(toParent: self)
    }
    let completion = { [self] in
      if let chatBannerView {
        insertChatBannerView(chatBannerView)
      }
      if let previousController {
        previousController.willMove(toParent: nil)
        previousController.view.removeFromSuperview()
        previousController.removeFromParent()
      }
      updateChatVisibility()
    }
    guard animated else {
      controller?.setFooterVisible(true, animated: false)
      completion()
      return
    }
    let animatesFooter = !UIAccessibility.isReduceMotionEnabled
    if let controller {
      controller.view.alpha = 0
      UIView.animate(withDuration: 0.3) {
        controller.view.alpha = 1
      } completion: { [self] _ in
        completion()
        // The footer comes in once the page is up, as the welcome walkthrough's does.
        guard modelSpeedViewController === controller else { return }
        controller.setFooterVisible(true, animated: animatesFooter)
      }
    } else if let previousController {
      // The footer leaves first, then the page fades back to the chat underneath.
      previousController.setFooterVisible(false, animated: animatesFooter) { [self] in
        updateChatVisibility()
        UIView.animate(withDuration: 0.3) {
          previousController.view.alpha = 0
        } completion: { _ in
          completion()
        }
      }
    } else {
      completion()
    }
  }

  /// Hides the chat while the welcome walkthrough or the Model Speed page covers it.
  private func updateChatVisibility() {
    let isCovered = onboardingViewController != nil || modelSpeedViewController != nil
    chatContentView.isHidden = isCovered
    projectHistoryCollectionView.isHidden = isCovered
    projectBarController.view.isHidden = isCovered
    middleContainerTopBlurView.isHidden = isCovered
    projectHistoryVerticalScrollIndicatorController?.view.isHidden = isCovered
    updateChatInputEmptyState()
  }

  func insertChatBannerView(_ bannerView: UIView) {
    loadViewIfNeeded()
    if let chatBannerView, chatBannerView !== bannerView {
      removeChatBannerView(chatBannerView)
    }
    chatBannerView = bannerView
    chatBannerBottomToQueueConstraint = nil
    // The card sits above the chat input, or above the footer of the walkthrough or the Model
    // Speed page while one shows. Inserting the current card again moves it to wherever it now
    // belongs.
    if let onboardingViewController {
      onboardingViewController.insertBannerView(bannerView)
      return
    }
    if let modelSpeedViewController {
      modelSpeedViewController.insertBannerView(bannerView)
      return
    }
    chatContentView.addSubview(bannerView)
    bannerView.snp.remakeConstraints { make in
      make.leading.trailing.equalTo(chatInputController.view)
      make.bottom.equalTo(chatInputController.view.snp.top).offset(-16).priority(.high)
      chatBannerBottomToQueueConstraint =
        make.bottom.equalTo(queuedItemsView.snp.top).offset(-16).constraint
      // The transcript rests above the card, and settles back when the card leaves.
      make.top.greaterThanOrEqualTo(projectHistoryContentInsetController.layoutGuide.snp.bottom)
        .offset(36)
    }
    chatBannerBottomToQueueConstraint?.isActive = !queuedItems.isEmpty
  }

  func removeChatBannerView(_ bannerView: UIView) {
    guard chatBannerView === bannerView else { return }
    chatBannerBottomToQueueConstraint?.deactivate()
    chatBannerBottomToQueueConstraint = nil
    bannerView.removeFromSuperview()
    chatBannerView = nil
  }

  private func resolveWindowMovablePeriodically() {
    let isWindowMovable = presentedViewController != nil
    (view.window?.windowScene?.delegate as? SceneDelegate)?
      .setWindowVisualEffectAndMovable(
        isWindowMovable)
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
      self?.resolveWindowMovablePeriodically()
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    middleRightContainerBackgroundView.layer.shadowColor = UIColor.primaryShadow.cgColor
  }

  static func buildMainMenu(with builder: UIMenuBuilder, isBotModeEnabled: Bool) {
    let editMenuTitle = builder.menu(for: .edit)?.title ?? "Edit"
    let editMenuChildren = [builder.menu(for: .undoRedo), builder.menu(for: .standardEdit)]
      .compactMap { $0 }
    builder.replace(
      menu: .edit,
      with: UIMenu(title: editMenuTitle, identifier: .edit, children: editMenuChildren))
    if #available(iOS 17.0, *) {
      builder.remove(menu: .autoFill)
    }

    let machineSettingsMenu = UIMenu(
      title: "", identifier: .preferences, options: .displayInline,
      children: [keyboardCommand(for: .machineSettings, isBotModeEnabled: isBotModeEnabled)])
    if builder.menu(for: .preferences) == nil {
      builder.insertSibling(machineSettingsMenu, afterMenu: .about)
    } else {
      builder.replace(menu: .preferences, with: machineSettingsMenu)
    }
    builder.insertSibling(
      UIMenu(
        title: "", options: .displayInline,
        children: [
          UICommand(
            title: LocalizedString.forKey("welcome_dot"), action: #selector(menuWelcomeAction(_:)))
        ]), afterMenu: .about)

    let fileMenuTitle = builder.menu(for: .file)?.title ?? "File"
    let fileCommandsMenu = UIMenu(
      title: "", options: .displayInline,
      children: [
        keyboardCommand(for: .newProject, isBotModeEnabled: isBotModeEnabled),
        keyboardCommand(for: .newChat, isBotModeEnabled: isBotModeEnabled),
        keyboardCommand(for: .stopConversation, isBotModeEnabled: isBotModeEnabled),
      ])
    let fileMenuChildren =
      [fileCommandsMenu] + (builder.menu(for: .close).map { [$0] } ?? [])
    builder.replace(
      menu: .file,
      with: UIMenu(title: fileMenuTitle, identifier: .file, children: fileMenuChildren))

    let viewMenuTitle = builder.menu(for: .view)?.title ?? "View"
    builder.replace(
      menu: .view,
      with: UIMenu(
        title: viewMenuTitle, identifier: .view,
        children: [
          keyboardCommand(for: .projectsTab, isBotModeEnabled: isBotModeEnabled),
          keyboardCommand(for: .settingsTab, isBotModeEnabled: isBotModeEnabled),
          keyboardCommand(for: .kitTab, isBotModeEnabled: isBotModeEnabled),
          keyboardCommand(for: .activitiesTab, isBotModeEnabled: isBotModeEnabled),
          keyboardCommand(for: .focusChat, isBotModeEnabled: isBotModeEnabled),
        ]))
    builder.remove(menu: .fullscreen)
    builder.remove(menu: .format)
    builder.remove(menu: .help)
  }

  private static func keyboardCommands(isBotModeEnabled: Bool) -> [UIKeyCommand] {
    let actions: [(KeyboardShortcutAction, Selector)] = [
      (.newProject, #selector(menuNewProjectAction(_:))),
      (.newChat, #selector(menuNewChatAction(_:))),
      (.machineSettings, #selector(menuMachineSettingsAction(_:))),
      (.projectsTab, #selector(menuProjectsTabAction(_:))),
      (.settingsTab, #selector(menuSettingsTabAction(_:))),
      (.kitTab, #selector(menuKitTabAction(_:))),
      (.activitiesTab, #selector(menuActivitiesTabAction(_:))),
      (.focusChat, #selector(menuFocusChatAction(_:))),
      (.stopConversation, #selector(menuStopConversationAction(_:))),
    ]
    return actions.map { keyboardCommand(for: $0, action: $1, isBotModeEnabled: isBotModeEnabled) }
  }

  private static func keyboardCommand(for action: KeyboardShortcutAction, isBotModeEnabled: Bool)
    -> UIKeyCommand
  {
    let selector: Selector
    switch action {
    case .newProject:
      selector = #selector(menuNewProjectAction(_:))
    case .newChat:
      selector = #selector(menuNewChatAction(_:))
    case .machineSettings:
      selector = #selector(menuMachineSettingsAction(_:))
    case .projectsTab:
      selector = #selector(menuProjectsTabAction(_:))
    case .settingsTab:
      selector = #selector(menuSettingsTabAction(_:))
    case .kitTab:
      selector = #selector(menuKitTabAction(_:))
    case .activitiesTab:
      selector = #selector(menuActivitiesTabAction(_:))
    case .focusChat:
      selector = #selector(menuFocusChatAction(_:))
    case .stopConversation:
      selector = #selector(menuStopConversationAction(_:))
    }
    return keyboardCommand(for: action, action: selector, isBotModeEnabled: isBotModeEnabled)
  }

  private static func keyboardCommand(
    for action: KeyboardShortcutAction, action selector: Selector, isBotModeEnabled: Bool
  ) -> UIKeyCommand {
    let shortcut = action.shortcut
    let command = UIKeyCommand(
      title: action.title(isBotModeEnabled: isBotModeEnabled), action: selector,
      input: shortcut.input,
      modifierFlags: shortcut.modifierFlags)
    command.wantsPriorityOverSystemBehavior = true
    return command
  }

  @objc private func menuNewProjectAction(_ sender: UIKeyCommand) {
    delegate?.chatViewControllerDidRequestNewProject(self)
  }

  @objc private func menuNewChatAction(_ sender: UIKeyCommand) {
    delegate?.chatViewControllerDidRequestNewChat(self)
  }

  @objc private func menuMachineSettingsAction(_ sender: UIKeyCommand) {
    delegate?.chatViewControllerDidRequestMachineSettings(self)
  }

  @objc private func menuProjectsTabAction(_ sender: UIKeyCommand) {
    delegate?.chatViewControllerDidRequestProjectsTab(self)
  }

  @objc private func menuSettingsTabAction(_ sender: UIKeyCommand) {
    delegate?.chatViewControllerDidRequestSettingsTab(self)
  }

  @objc private func menuKitTabAction(_ sender: UIKeyCommand) {
    delegate?.chatViewControllerDidRequestKitTab(self)
  }

  @objc private func menuActivitiesTabAction(_ sender: UIKeyCommand) {
    delegate?.chatViewControllerDidRequestActivitiesTab(self)
  }

  @objc private func menuWelcomeAction(_ sender: UICommand) {
    delegate?.chatViewControllerDidRequestWelcome(self)
  }

  @objc private func menuFocusChatAction(_ sender: UIKeyCommand) {
    chatInputController.focus()
  }

  @objc private func menuStopConversationAction(_ sender: UIKeyCommand) {
    chatInputController.stop()
  }

  /// The session-only message is appended to the snapshot, never to conversation history.
  func setActionableMessage(_ message: ProjectHistoryItem.ActionableMessage?) {
    // Item type distinguishes this stable identifier from conversation identifiers.
    actionableMessageItem = message.map { .actionableMessageItem(id: 0, message: $0) }
    updateChatInputEmptyState()
    guard isViewLoaded else { return }
    applyProjectHistorySnapshot(
      scrollTo: actionableMessageItem ?? projectHistoryItems.last, animated: true,
      scrollToItem: message != nil)
  }

  func appendUser(_ text: String, datetime: Date) {
    let item = ProjectHistoryItem.user(
      id: loadNextProjectHistoryItemId(), text: text, datetime: datetime)
    projectHistoryItems.append(item)
    updateChatInputEmptyState()
    applyProjectHistorySnapshot(scrollTo: item, animated: true, scrollToItem: true)
  }

  func setHistory(
    _ messages: [ChatHistoryMessage], hasIncompleteResponse: Bool, incompleteResponseText: String
  ) {
    projectHistoryItems = messages.map { message in
      switch message {
      case .assistant(let text, let datetime, let duration):
        return .assistant(
          id: loadNextProjectHistoryItemId(), text: text, datetime: datetime,
          duration: duration)
      case .user(let text, let datetime):
        return .user(id: loadNextProjectHistoryItemId(), text: text, datetime: datetime)
      }
    }
    if hasIncompleteResponse {
      let datetime: Date
      switch messages.last {
      case .some(.assistant(_, let messageDatetime, _)):
        datetime = messageDatetime
      case .some(.user(_, let messageDatetime)):
        datetime = messageDatetime
      case nil:
        datetime = Date()
      }
      projectHistoryItems.append(
        .assistantIncomplete(
          id: loadNextProjectHistoryItemId(), text: incompleteResponseText, datetime: datetime))
    }
    updateChatInputEmptyState()
    guard isViewLoaded else { return }
    applyProjectHistorySnapshot(
      scrollTo: projectHistoryItems.last, animated: false,
      scrollToItem: !projectHistoryItems.isEmpty)
  }

  func setQueuedItems(_ items: [ProjectQueuedItem], animated: Bool) {
    guard queuedItems != items else { return }
    let previousQueuedItems = queuedItems
    queuedItems = items
    guard isViewLoaded else { return }
    updateQueuedItems(from: previousQueuedItems)
    queuedItemsView.alpha = queuedItems.isEmpty ? 0 : 1
    queuedItemsViewBottomConstraint?.update(offset: queuedItems.isEmpty ? 23.5 : 0.5)
    chatBannerBottomToQueueConstraint?.isActive = !queuedItems.isEmpty
    if previousQueuedItems.count < queuedItems.count {
      queuedItemsView.layoutIfNeeded()
    }
    guard animated, let view = viewIfLoaded, view.window != nil else { return }
    UIView.animate(
      withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      view.layoutIfNeeded()
    }
  }

  func setSteeringQueuedItems(_ items: [ProjectQueuedItem]) {
    guard isViewLoaded else { return }
    for case let view as QueuedItemView in queuedItemsStackView.arrangedSubviews {
      view.isSteering = items.contains(view.queuedItem)
    }
  }

  func appendAssistant(
    _ text: String, thinking: String, output: String, datetime: Date?, duration: TimeInterval,
    isTransient: Bool, mode: ProjectHistoryItem.Mode
  ) {
    let item: ProjectHistoryItem
    if isTransient {
      item = .assistantThink(
        id: loadNextProjectHistoryItemId(), text: text, thinking: thinking, output: output,
        mode: mode)
    } else if case .assistantThink(let id, _, _, _, _) = projectHistoryItems.last {
      item = .assistant(
        id: id, text: text, datetime: datetime ?? Date(), duration: duration)
      projectHistoryItems[projectHistoryItems.count - 1] = item
      updateChatInputEmptyState()
      applyProjectHistorySnapshot(scrollTo: item, animated: false, scrollToItem: false)
      return
    } else {
      item = .assistant(
        id: loadNextProjectHistoryItemId(), text: text, datetime: datetime ?? Date(),
        duration: duration)
    }
    projectHistoryItems.append(item)
    updateChatInputEmptyState()
    applyProjectHistorySnapshot(scrollTo: item, animated: true, scrollToItem: true)
  }

  func setLastMessage(
    _ text: String, thinking: String, output: String, datetime: Date?, duration: TimeInterval,
    isTransient: Bool, mode: ProjectHistoryItem.Mode
  ) {
    guard let lastItem = projectHistoryItems.last else {
      appendAssistant(
        text, thinking: thinking, output: output, datetime: datetime, duration: duration,
        isTransient: isTransient, mode: mode)
      return
    }
    let item: ProjectHistoryItem
    switch lastItem {
    case .assistant(let id, _, let currentDatetime, let currentDuration):
      item =
        isTransient
        ? .assistantThink(id: id, text: text, thinking: thinking, output: output, mode: mode)
        : .assistant(
          id: id, text: text, datetime: datetime ?? currentDatetime,
          duration: duration > 0 ? duration : currentDuration)
    case .assistantIncomplete(let id, _, let currentDatetime):
      item =
        isTransient
        ? .assistantThink(id: id, text: text, thinking: thinking, output: output, mode: mode)
        : .assistant(
          id: id, text: text, datetime: datetime ?? currentDatetime, duration: duration)
    case .assistantThink(let id, _, _, _, _):
      item =
        isTransient
        ? .assistantThink(id: id, text: text, thinking: thinking, output: output, mode: mode)
        : .assistant(
          id: id, text: text, datetime: datetime ?? Date(), duration: duration)
    case .user, .actionableMessageItem:
      appendAssistant(
        text, thinking: thinking, output: output, datetime: datetime, duration: duration,
        isTransient: isTransient, mode: mode)
      return
    }
    projectHistoryItems[projectHistoryItems.count - 1] = item
    updateChatInputEmptyState()
    applyProjectHistorySnapshot(scrollTo: item, animated: false, scrollToItem: false)
  }

  func removeLastTransientMessage() {
    guard case .assistantThink = projectHistoryItems.last else { return }
    projectHistoryItems.removeLast()
    updateChatInputEmptyState()
    applyProjectHistorySnapshot(
      scrollTo: projectHistoryItems.last, animated: false, scrollToItem: false)
  }

  private func updateChatInputEmptyState() {
    let isEmpty = projectHistoryItems.isEmpty && actionableMessageItem == nil
    chatInputController.isEmptyState = isEmpty
    guard isViewLoaded else { return }
    let showsEmptyState =
      onboardingViewController == nil && modelSpeedViewController == nil && isEmpty
    guard !projectDemoController.isSwitching else { return }
    let hasProjectDemo = projectDemoController.videoURL != nil
    let showsProjectDemo = showsEmptyState && hasProjectDemo && !isProjectDemoHidden
    emptyBannerController.setVisible(showsEmptyState && !showsProjectDemo, animated: true)
    projectDemoController.setVisible(showsProjectDemo, animated: true)
    let showsProjectDemoButton = showsEmptyState && hasProjectDemo && isProjectDemoHidden
    if showsProjectDemoButton {
      projectDemoButton.isHidden = false
    }
    UIView.animate(withDuration: 0.25) {
      self.projectDemoButton.alpha = showsProjectDemoButton ? 1 : 0
    } completion: { _ in
      self.projectDemoButton.isHidden = self.projectDemoButton.alpha == 0
    }
  }

  private func updateQueuedItems(from previousQueuedItems: [ProjectQueuedItem]) {
    let difference = queuedItems.difference(from: previousQueuedItems) {
      $0.threadId == $1.threadId && $0.datetime == $1.datetime
    }
    for removal in difference.removals.reversed() {
      guard case .remove(let offset, _, _) = removal else { continue }
      let view = queuedItemsStackView.arrangedSubviews[offset]
      queuedItemsStackView.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    for insertion in difference.insertions {
      guard case .insert(let offset, let queuedItem, _) = insertion else { continue }
      let view = QueuedItemView(queuedItem: queuedItem, buttonSize: 32)
      view.delegate = self
      queuedItemsStackView.insertArrangedSubview(view, at: offset)
    }
    for (queuedItem, view) in zip(queuedItems, queuedItemsStackView.arrangedSubviews) {
      (view as? QueuedItemView)?.queuedItem = queuedItem
    }
  }

  private func loadNextProjectHistoryItemId() -> Int {
    defer { nextProjectHistoryItemId += 1 }
    return nextProjectHistoryItemId
  }

  private func applyProjectHistorySnapshot(
    scrollTo item: ProjectHistoryItem?, animated: Bool, scrollToItem: Bool
  ) {
    let shouldScrollToItem: Bool
    if scrollToItem {
      shouldScrollToItem = true
    } else {
      let contentHeight =
        projectHistoryCollectionView.contentSize.height
        + projectHistoryCollectionView.adjustedContentInset.top
        + projectHistoryCollectionView.adjustedContentInset.bottom
      if contentHeight <= projectHistoryCollectionView.bounds.height {
        shouldScrollToItem = true
      } else {
        let bottomOffset =
          projectHistoryCollectionView.contentSize.height
          + projectHistoryCollectionView.adjustedContentInset.bottom
          - projectHistoryCollectionView.bounds.height
        shouldScrollToItem = projectHistoryCollectionView.contentOffset.y >= bottomOffset - 16
      }
    }
    var snapshot = NSDiffableDataSourceSnapshot<Int, ProjectHistoryItem.ItemIdentifier>()
    snapshot.appendSections([0])
    snapshot.appendItems(projectHistoryItems.map(\.identifier))
    // A trailing presentation cell leaves all conversation indexes unchanged.
    if let actionableMessageItem {
      snapshot.appendItems([actionableMessageItem.identifier])
    }
    if let item {
      snapshot.reconfigureItems([item.identifier])
    }
    let scrollIdentifier = actionableMessageItem?.identifier ?? item?.identifier
    projectHistoryCollectionViewDiffableDataSource.apply(snapshot, animatingDifferences: animated) {
      [weak self] in
      guard let self else { return }
      guard shouldScrollToItem else { return }
      guard let identifier = scrollIdentifier,
        let indexPath = projectHistoryCollectionViewDiffableDataSource.indexPath(
          for: identifier)
      else { return }
      projectHistoryCollectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }
  }

  private static func projectHistoryCollectionViewLayout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { _, _ in
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
      let item = NSCollectionLayoutItem(layoutSize: itemSize)
      let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
      let section = NSCollectionLayoutSection(group: group)
      section.interGroupSpacing = 16
      // The sides of the content inset guide arrive as layout margins.
      section.contentInsetsReference = .layoutMargins
      return section
    }
  }
}

extension ChatViewControllerForiPad: ProjectHistoryAssistantViewCellDelegate {
  func projectHistoryAssistantViewCellDidSelectCopy(_ cell: ProjectHistoryAssistantViewCell) {
    delegate?.chatViewController(self, didSelectCopyHistoryText: cell.text)
  }

  func projectHistoryAssistantViewCellDidSelectContinue(_ cell: ProjectHistoryAssistantViewCell) {
    delegate?.chatViewControllerDidRequestContinueIncompleteResponse(self)
  }
}

extension ChatViewControllerForiPad: ProjectHistoryUserViewCellDelegate {
  func projectHistoryUserViewCellDidSelectCopy(_ cell: ProjectHistoryUserViewCell) {
    delegate?.chatViewController(self, didSelectCopyHistoryText: cell.text)
  }
}

extension ChatViewControllerForiPad: QueuedItemViewDelegate {
  func queuedItemView(
    _ view: QueuedItemView, didTapSteerQueuedItem queuedItem: ProjectQueuedItem
  ) {
    delegate?.chatViewController(self, didSteerQueuedItem: queuedItem)
  }

  func queuedItemView(
    _ view: QueuedItemView, didTapDeleteQueuedItem queuedItem: ProjectQueuedItem
  ) {
    delegate?.chatViewController(self, didDeleteQueuedItem: queuedItem)
  }
}

extension ChatViewControllerForiPad: ProjectDemoControllerDelegate {
  func projectDemoController(
    _ controller: ProjectDemoController, didRequestFullScreenWith player: AVPlayer
  ) {
    let playerViewController = AVPlayerViewController()
    playerViewController.player = player
    present(playerViewController, animated: true) {
      player.play()
    }
  }

  func projectDemoControllerDidTapClose(_ controller: ProjectDemoController) {
    guard !controller.isSwitching else { return }
    isProjectDemoHidden = true
    delegate?.chatViewController(self, didSetProjectDemoHidden: true)
    controller.switchOff { [weak self] in
      self?.updateChatInputEmptyState()
    }
  }
}
