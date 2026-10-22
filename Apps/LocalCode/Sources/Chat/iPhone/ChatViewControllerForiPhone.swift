import Components
import ProjectHistoryManager
import SnapKit
import Style
import UIKit

/// The phone layout: one full-screen conversation. `ChatWorkflow` presents the projects / settings /
/// kit panel over it from the leading edge.
final class ChatViewControllerForiPhone: UIViewController, ChatViewControllable {
  /// Hides the transcript behind the status bar and project bar, fading out just below the bar.
  private final class TopFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override func layoutSubviews() {
      super.layoutSubviews()
      updateGradient()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      updateGradient()
    }

    private func updateGradient() {
      guard let gradientLayer = layer as? CAGradientLayer else { return }
      let color = UIColor.tertiaryBackground.resolvedColor(with: traitCollection)
      gradientLayer.colors = [
        color.cgColor, color.cgColor, color.withAlphaComponent(0).cgColor,
      ]
      let height = max(bounds.height, 1)
      gradientLayer.locations = [0, NSNumber(value: Double(max(height - 20, 0) / height)), 1]
    }
  }

  weak var delegate: ChatViewControllableDelegate?
  var isBotModeEnabled = false
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
  private(set) var localPathResolver: LocalPathResolver?

  private let chatInputController: ChatInputController
  private let projectBarController: ProjectBarController
  private let emptyBannerController: EmptyBannerController
  private var onboardingViewController: OnboardingViewController?
  private var chatBannerView: UIView?
  private var projectHistoryItems = [ProjectHistoryItem]()
  private var actionableMessageItem: ProjectHistoryItem?
  private var queuedItems = [ProjectQueuedItem]()
  private var nextProjectHistoryItemId = 0
  private var queuedItemsViewBottomConstraint: Constraint?
  private var chatBannerBottomToQueueConstraint: Constraint?
  private var chatInputHorizontalConstraint: Constraint?
  private var keyboardAppearanceMonitor: KeyboardAppearanceMonitor? = nil

  private lazy var chatContainerView = UIView(frame: .zero)
  private lazy var backgroundView: UIView = {
    let view = UIView(frame: .zero)
    view.alpha = 0
    view.backgroundColor = .secondaryBackground
    view.layer.shadowOpacity = 0.25
    view.layer.shadowColor = UIColor.primaryShadow.cgColor
    view.layer.shadowOffset = CGSize(width: -2, height: -2)
    view.layer.shadowRadius = 5
    view.isUserInteractionEnabled = false
    return view
  }()
  private lazy var queuedItemsStackView: UIStackView = {
    let stackView = UIStackView(frame: .zero)
    stackView.axis = .vertical
    stackView.spacing = 2
    stackView.alignment = .fill
    stackView.distribution = .fill
    return stackView
  }()
  private lazy var queuedItemsView: UIView = {
    let view = BorderView.defaultBorderView(cornerRadius: 20)
    view.borderColor = .duodenaryBorder
    view.layer.borderWidth = 0.5
    view.backgroundColor = .novemdecenaryBackground
    view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    view.clipsToBounds = true
    view.addSubview(queuedItemsStackView)
    queuedItemsStackView.snp.makeConstraints { make in
      make.top.equalToSuperview().inset(8)
      make.trailing.equalToSuperview().inset(8)
      make.leading.equalToSuperview().inset(16)
      make.bottom.equalToSuperview().inset(7.5)
    }
    return view
  }()
  private lazy var projectHistoryCollectionView: UICollectionView = {
    let collectionView = UICollectionView(
      frame: .zero, collectionViewLayout: Self.projectHistoryCollectionViewLayout())
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    // On the phone the keyboard covers most of the chat; any scroll puts it away.
    collectionView.keyboardDismissMode = .onDrag
    collectionView.showsHorizontalScrollIndicator = false
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 24 + 12, right: 0)
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
  private lazy var topFadeView: TopFadeView = {
    let view = TopFadeView(frame: .zero)
    view.isUserInteractionEnabled = false
    return view
  }()
  /// Covers the transcript under the status bar in the settings color while settings is presented.
  private lazy var statusBarBackgroundView: UIView = {
    let view = UIView(frame: .zero)
    view.alpha = 0
    view.backgroundColor = .primaryBackground
    view.isUserInteractionEnabled = false
    return view
  }()
  private lazy var screenEdgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer = {
    let screenEdgePanGestureRecognizer = UIScreenEdgePanGestureRecognizer(
      target: self, action: #selector(screenEdgePan(_:)))
    screenEdgePanGestureRecognizer.edges = [.left]
    return screenEdgePanGestureRecognizer
  }()

  init(
    chatInputController: ChatInputController, projectBarController: ProjectBarController,
    emptyBannerController: EmptyBannerController
  ) {
    self.chatInputController = chatInputController
    self.projectBarController = projectBarController
    self.emptyBannerController = emptyBannerController
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Local Code"
    view.backgroundColor = .tertiaryBackground
    view.addGestureRecognizer(screenEdgePanGestureRecognizer)
    view.addSubview(backgroundView)
    backgroundView.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalToSuperview()
      make.top.equalTo(view.safeAreaLayoutGuide)
    }

    view.addSubview(chatContainerView)
    chatContainerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    chatInputController.addAttachmentDropInteraction(to: chatContainerView)
    chatInputController.setAttachmentDropDelegate(of: projectHistoryCollectionView)

    chatContainerView.addSubview(projectHistoryCollectionView)
    chatContainerView.addSubview(topFadeView)
    chatContainerView.addSubview(statusBarBackgroundView)
    chatContainerView.addSubview(queuedItemsView)
    chatContainerView.addSubview(chatInputController.view)
    chatContainerView.addSubview(projectBarController.view)
    projectHistoryCollectionView.delegate = self
    // A tap in the conversation also puts the keyboard away; links and buttons still get it.
    let dismissKeyboardTap = UITapGestureRecognizer(
      target: self, action: #selector(dismissKeyboard))
    dismissKeyboardTap.cancelsTouchesInView = false
    projectHistoryCollectionView.addGestureRecognizer(dismissKeyboardTap)

    projectBarController.view.snp.makeConstraints { make in
      make.top.equalTo(chatContainerView.safeAreaLayoutGuide).offset(8)
      make.leading.trailing.equalTo(chatContainerView.safeAreaLayoutGuide).inset(16)
    }
    // At rest the input sits on the safe area, 16pt in from the sides; over the keyboard it sits
    // 8pt above it and widens to 8pt from the sides.
    chatInputController.view.snp.makeConstraints { make in
      chatInputHorizontalConstraint =
        make.leading.trailing.equalTo(chatContainerView.safeAreaLayoutGuide).inset(16).constraint
      make.bottom.equalTo(chatContainerView.safeAreaLayoutGuide).priority(.high)
      make.bottom.lessThanOrEqualTo(view.keyboardLayoutGuide.snp.top).offset(-8)
    }
    if #available(iOS 17.0, *) {
      // Without a keyboard the guide's top is the bottom edge rather than the safe area, so the
      // input can rest on the safe area. Earlier systems keep it 8pt above.
      view.keyboardLayoutGuide.usesBottomSafeArea = false
    }
    keyboardAppearanceMonitor = KeyboardAppearanceMonitor(
      self, viewsScrollToVisible: [], isAdditionalSafeAreaInsetsManaged: false
    ) { [weak self] beginKeyboardFrame, endKeyboardFrame in
      guard let self = self, beginKeyboardFrame != endKeyboardFrame else { return }
      // We use this to guess if the keyboard is up or not.
      let isKeyboardUp = endKeyboardFrame.minY < self.view.bounds.height * 0.8
      self.chatInputHorizontalConstraint?.update(inset: isKeyboardUp ? 8 : 16)
    }
    // The queue sits on the input rather than tucking under its glass; the extra 0.5pt lays its
    // bottom border over the input's top one. Hidden, it waits 23pt lower.
    queuedItemsView.snp.makeConstraints { make in
      make.leading.trailing.equalTo(chatInputController.view).inset(24)
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
    // The transcript runs under the project bar; its top inset tracks the bar in
    // viewDidLayoutSubviews.
    projectHistoryCollectionView.snp.makeConstraints { make in
      make.leading.trailing.equalTo(chatContainerView.safeAreaLayoutGuide).inset(16)
      make.top.equalToSuperview()
      make.bottom.equalTo(queuedItemsView.snp.top).offset(24)
    }
    topFadeView.snp.makeConstraints { make in
      make.top.equalToSuperview()
      make.bottom.equalTo(projectBarController.view.snp.bottom).offset(20)
      make.leading.trailing.equalToSuperview()
    }
    statusBarBackgroundView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.bottom.equalTo(chatContainerView.safeAreaLayoutGuide.snp.top)
    }
    // A layout guide keeps the banner centered between the bar and the input as the keyboard moves.
    let bannerSpace = UILayoutGuide()
    chatContainerView.addLayoutGuide(bannerSpace)
    bannerSpace.snp.makeConstraints { make in
      make.top.equalTo(projectBarController.view.snp.bottom)
      make.bottom.equalTo(chatInputController.view.snp.top)
      make.leading.trailing.equalTo(projectHistoryCollectionView)
    }
    chatContainerView.addSubview(emptyBannerController.view)
    emptyBannerController.view.snp.makeConstraints { make in
      make.leading.trailing.equalTo(chatContainerView.safeAreaLayoutGuide).inset(16)
      make.centerY.equalTo(bannerSpace)
    }

    updateChatInputEmptyState()
    updateQueuedItems(from: [])
    applyProjectHistorySnapshot(
      scrollTo: projectHistoryItems.last, animated: false,
      scrollToItem: !projectHistoryItems.isEmpty)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let topInset = projectBarController.view.frame.maxY + 16
    if projectHistoryCollectionView.contentInset.top != topInset {
      projectHistoryCollectionView.contentInset.top = topInset
      projectHistoryCollectionView.verticalScrollIndicatorInsets.top = topInset
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    backgroundView.layer.shadowColor = UIColor.primaryShadow.cgColor
  }

  @objc private func dismissKeyboard() {
    view.endEditing(true)
  }

  @objc private func screenEdgePan(_ gestureRecognizer: UIScreenEdgePanGestureRecognizer) {
    delegate?.chatViewController(self, didReceiveScreenEdgePan: gestureRecognizer)
  }

  // MARK: - ChatViewControllable

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

  func setOnboardingViewController(
    _ controller: OnboardingViewController?, animated: Bool, completionHandler: (() -> Void)?
  ) {
    loadViewIfNeeded()
    let previousController = onboardingViewController
    onboardingViewController = controller
    if let controller {
      view.endEditing(true)
      addChild(controller)
      chatContainerView.addSubview(controller.view)
      controller.view.snp.makeConstraints {
        $0.edges.equalTo(chatContainerView.safeAreaLayoutGuide)
      }
      controller.bannerGuide.snp.remakeConstraints { make in
        make.edges.equalTo(emptyBannerController.view)
      }
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
      let isOnboarding = onboardingViewController != nil
      chatInputController.view.isHidden = isOnboarding
      queuedItemsView.isHidden = isOnboarding
      projectHistoryCollectionView.isHidden = isOnboarding
      projectBarController.view.isHidden = isOnboarding
      topFadeView.isHidden = isOnboarding
      updateChatInputEmptyState()
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

  func insertChatBannerView(_ bannerView: UIView) {
    loadViewIfNeeded()
    if let chatBannerView, chatBannerView !== bannerView {
      removeChatBannerView(chatBannerView)
    }
    chatBannerView = bannerView
    chatBannerBottomToQueueConstraint = nil
    if let onboardingViewController {
      onboardingViewController.insertBannerView(bannerView)
      return
    }
    chatContainerView.addSubview(bannerView)
    bannerView.snp.remakeConstraints { make in
      make.leading.trailing.equalTo(chatInputController.view)
      make.bottom.equalTo(chatInputController.view.snp.top).offset(-12).priority(.high)
      chatBannerBottomToQueueConstraint =
        make.bottom.equalTo(queuedItemsView.snp.top).offset(-12).constraint
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
    guard animated, view.window != nil else { return }
    UIView.animate(
      withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      self.view.layoutIfNeeded()
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

  // MARK: - Private

  private func updateChatInputEmptyState() {
    let isEmpty = projectHistoryItems.isEmpty && actionableMessageItem == nil
    chatInputController.isEmptyState = isEmpty
    guard isViewLoaded else { return }
    emptyBannerController.setVisible(onboardingViewController == nil && isEmpty, animated: true)
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
      return section
    }
  }
}

extension ChatViewControllerForiPhone: ProjectHistoryAssistantViewCellDelegate {
  func projectHistoryAssistantViewCellDidSelectCopy(_ cell: ProjectHistoryAssistantViewCell) {
    delegate?.chatViewController(self, didSelectCopyHistoryText: cell.text)
  }

  func projectHistoryAssistantViewCellDidSelectContinue(_ cell: ProjectHistoryAssistantViewCell) {
    delegate?.chatViewControllerDidRequestContinueIncompleteResponse(self)
  }
}

extension ChatViewControllerForiPhone: ProjectHistoryUserViewCellDelegate {
  func projectHistoryUserViewCellDidSelectCopy(_ cell: ProjectHistoryUserViewCell) {
    delegate?.chatViewController(self, didSelectCopyHistoryText: cell.text)
  }
}

extension ChatViewControllerForiPhone: QueuedItemViewDelegate {
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

extension ChatViewControllerForiPhone: UICollectionViewDelegate {}

extension ChatViewControllerForiPhone: AnimatingTransitioningPresentable {
  func animate(alongsideTransition transition: SettingsAnimatedTransitioning.Transition) {
    switch transition {
    case .easeIn:
      view.backgroundColor = .primaryBackground
      backgroundView.alpha = 1
      statusBarBackgroundView.alpha = 1
    case .easeOut:
      view.backgroundColor = .tertiaryBackground
      backgroundView.alpha = 0
      statusBarBackgroundView.alpha = 0
    }
  }

  func animate(
    alongsideTransition transition: SettingsAnimatedTransitioning.Transition,
    interactivelyWithPercent percent: CGFloat
  ) {
    switch transition {
    case .easeIn:
      view.backgroundColor = UIColor.interpolate(
        from: .tertiaryBackground, to: .primaryBackground, with: percent)
      backgroundView.alpha = percent
      statusBarBackgroundView.alpha = percent
    case .easeOut:
      view.backgroundColor = UIColor.interpolate(
        from: .primaryBackground, to: .tertiaryBackground, with: percent)
      backgroundView.alpha = 1.0 - percent
      statusBarBackgroundView.alpha = 1.0 - percent
    }
  }
}
