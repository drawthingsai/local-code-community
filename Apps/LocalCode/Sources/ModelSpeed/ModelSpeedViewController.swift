import Components
import FBShimmer
import Localization
import SnapKit
import Style
import SwiftUI
import UIKit

protocol ModelSpeedViewControllerDelegate: AnyObject {
  func modelSpeedViewControllerDidTapStop(_ viewController: ModelSpeedViewController)
  func modelSpeedViewControllerDidTapStartAgain(_ viewController: ModelSpeedViewController)
  func modelSpeedViewControllerDidTapDone(_ viewController: ModelSpeedViewController)
  func modelSpeedViewController(
    _ viewController: ModelSpeedViewController, didTapShare sourceView: UIView)
  func modelSpeedViewController(
    _ viewController: ModelSpeedViewController, didTapModelSelector sourceView: UIView)
}

final class ModelSpeedViewController: UIViewController {
  struct Measurement: Equatable {
    let contextLength: Int
    let prefillTokensPerSecond: Double
    /// Nil until the reading's decode pass, which follows its prefill pass, is over.
    var decodeTokensPerSecond: Double? = nil
  }

  weak var delegate: ModelSpeedViewControllerDelegate?
  /// The context lengths the run covers, in the order it measures them.
  var contextLengths: [Int] = [] { didSet { if isViewLoaded { renderCharts() } } }
  var measurements: [Measurement] = [] { didSet { if isViewLoaded { renderCharts() } } }
  var isRunning = false {
    didSet {
      guard isViewLoaded, oldValue != isRunning else { return }
      // A cross-fade, so the buttons coming and going don't squeeze one another.
      UIView.transition(
        with: footerContainerView, duration: 0.25,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) {
        self.renderRunState()
        self.footerContainerView.layoutIfNeeded()
      }
    }
  }
  /// Names the model and the hardware the run measures.
  var subtitle: String? {
    get { subtitleLabel.text }
    set { subtitleLabel.text = newValue }
  }
  /// The prompt each prefill reading measures, in tokens, which the prefill chart names.
  var promptLength = 0 {
    didSet {
      prefillDetailLabel.text = LocalizedString.format(
        key: "prompt_processing_detail", ModelSpeedChartView.label(for: promptLength))
    }
  }

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
  private lazy var pageStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 24
    return stack
  }()
  private lazy var heading: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 4
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 6, left: 12, bottom: 0, right: 12)
    return stack
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = LocalizedString.forKey("model_speed")
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 28, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var subtitleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .light), bindTo: label)
    return label
  }()
  // Orange and blue tell the two charts apart at a glance, colorblind readers included.
  private lazy var prefillChartController = UIHostingController(
    rootView: ModelSpeedChartView(palette: .orange, contextLengths: [], points: []))
  private lazy var decodeChartController = UIHostingController(
    rootView: ModelSpeedChartView(palette: .blue, contextLengths: [], points: []))
  private lazy var prefillDetailLabel = UILabel()
  private lazy var decodeDetailLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("token_generation_detail")
    return label
  }()
  private lazy var prefillCard = makeChart(
    title: LocalizedString.forKey("prompt_processing"), detailLabel: prefillDetailLabel,
    chartView: prefillChartController.view)
  private lazy var decodeCard = makeChart(
    title: LocalizedString.forKey("token_generation"), detailLabel: decodeDetailLabel,
    chartView: decodeChartController.view)
  // Styled as the thinking cell's mode label, which shows the same reading and writing.
  private lazy var progressLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = LocalizedString.forKey("reading_dot")
    label.textColor = .octonaryText
    FontMetrics.default.scaleFont(.italicSystemFont(ofSize: 15), bindTo: label)
    return label
  }()
  private lazy var progressContentView: UIView = {
    let view = UIView(frame: .zero)
    view.addSubview(progressLabel)
    return view
  }()
  // The progress keeps its row while idle, so the page holds still as a run starts and stops.
  private lazy var progressShimmerView: FBShimmeringView = {
    let view = FBShimmeringView(frame: .zero)
    view.contentView = progressContentView
    view.shimmeringOpacity = 0.28
    view.shimmeringAnimationOpacity = 1
    view.shimmeringSpeed = 360
    view.shimmeringPauseDuration = 0.05
    view.alpha = 0
    return view
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
  private lazy var footerActions: UIStackView = {
    let stack = UIStackView()
    stack.spacing = 6
    stack.alignment = .center
    return stack
  }()
  private lazy var modelIconView: UIImageView = {
    let imageView = UIImageView(
      image: #imageLiteral(resourceName: "cube").withRenderingMode(.alwaysTemplate))
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = .senaryText
    imageView.isUserInteractionEnabled = false
    return imageView
  }()
  // The same model selector as the chat input's.
  private lazy var modelButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.cornerStyle = .capsule
    configuration.background.backgroundColor = .novemdecenaryBackground
    configuration.baseForegroundColor = .primaryText
    configuration.title = LocalizedString.forKey("unspecified")
    configuration.titleLineBreakMode = .byTruncatingHead
    configuration.image = #imageLiteral(resourceName: "chevron-down-16").withRenderingMode(
      .alwaysTemplate)
    configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in .senaryText }
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 34, bottom: 0, trailing: 10)
    button.configuration = configuration
    button.configurationUpdateHandler = { button in
      guard var configuration = button.configuration else { return }
      configuration.background.backgroundColor =
        button.isHighlighted ? .quinaryBackground : .novemdecenaryBackground
      button.configuration = configuration
    }
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: button)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.addSubview(modelIconView)
    modelIconView.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(10)
      make.centerY.equalToSuperview()
      make.width.height.equalTo(20)
    }
    button.addAction(
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.delegate?.modelSpeedViewController(self, didTapModelSelector: button)
      }, for: .touchUpInside)
    return button
  }()
  // Share and Start again are styled as the welcome walkthrough's back button.
  private lazy var shareButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("share")
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
      UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.delegate?.modelSpeedViewController(self, didTapShare: button)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var stopButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("stop")
    configuration.baseBackgroundColor = .primaryFill
    configuration.baseForegroundColor = .nonaryText
    configuration.background.cornerRadius = 20
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 16, bottom: 8, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.titleLabel?.numberOfLines = 1
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.modelSpeedViewControllerDidTapStop(self)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var startAgainButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("start_again")
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
        self.delegate?.modelSpeedViewControllerDidTapStartAgain(self)
      }, for: .touchUpInside)
    return button
  }()
  // Stop and Done are styled as the welcome walkthrough's next button.
  private lazy var doneButton: UIButton = {
    let button = UIButton(type: .system)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("done")
    configuration.baseBackgroundColor = .primaryFill
    configuration.baseForegroundColor = .nonaryText
    configuration.background.cornerRadius = 20
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 16, bottom: 8, trailing: 16)
    button.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
    button.titleLabel?.numberOfLines = 1
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.modelSpeedViewControllerDidTapDone(self)
      }, for: .touchUpInside)
    return button
  }()

  private var progress: SpeedometerProgress?
  private var progressStartTime: CFTimeInterval = 0
  private var progressTimer: Timer?
  private var fitsVisibleHeightConstraint: Constraint?
  private weak var bannerView: UIView?
  private var compactLayout = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .tertiaryBackground
    view.addSubview(scrollView)
    view.addSubview(topBlurView)
    view.addSubview(footerBannerController.view)
    view.addSubview(scrollIndicatorController.view)
    scrollView.addSubview(scrollContent)
    scrollContent.addSubview(column)
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
      // Above the charts' preferred height, so they shrink before the page scrolls. Below
      // every compression resistance, so nothing else does.
      fitsVisibleHeightConstraint =
        make.height.lessThanOrEqualTo(scrollView.frameLayoutGuide).offset(-12).priority(
          .low.advanced(by: 2)
        ).constraint
    }
    // The page sits in the same column as the welcome walkthrough's.
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
    pageStack.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview()
      make.leading.trailing.equalToSuperview().inset(32)
    }
    pageStack.addArrangedSubview(heading)
    heading.addArrangedSubview(titleLabel)
    heading.addArrangedSubview(subtitleLabel)
    for (chartController, card) in [
      (prefillChartController, prefillCard), (decodeChartController, decodeCard),
    ] {
      addChild(chartController)
      pageStack.addArrangedSubview(card)
      chartController.didMove(toParent: self)
    }
    pageStack.addArrangedSubview(progressShimmerView)
    // The thinking cell's gap between its text and the 24pt row its label is centered in.
    pageStack.setCustomSpacing(12, after: decodeCard)
    // The shimmer spans the column, as the thinking cell's spans the chat, so it passes at the
    // same pace.
    progressContentView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
      make.height.equalTo(24).priority(.high)
    }
    // Lines up with the heading.
    progressLabel.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.top.greaterThanOrEqualToSuperview()
      make.leading.equalToSuperview().offset(12)
      make.trailing.lessThanOrEqualToSuperview().offset(-12)
    }
    // Both charts give up the same height.
    prefillChartController.view.snp.makeConstraints { make in
      make.height.equalTo(decodeChartController.view)
    }

    footer.addSubview(footerShadow1)
    footer.addSubview(footerShadow2)
    footer.addSubview(footerContainerView)
    footerContainerView.addSubview(modelButton)
    footerContainerView.addSubview(footerActions)
    footerActions.addArrangedSubview(shareButton)
    footerActions.addArrangedSubview(stopButton)
    footerActions.addArrangedSubview(startAgainButton)
    footerActions.addArrangedSubview(doneButton)
    footerShadow1.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(10)
    }
    footerShadow2.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(6)
    }
    footerContainerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    footerBannerController.view.snp.makeConstraints { make in
      make.centerX.equalToSuperview()
      make.width.equalTo(column)
      make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-20)
      make.height.greaterThanOrEqualTo(72)
    }
    modelButton.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(16)
      make.centerY.equalToSuperview()
      make.height.equalTo(32)
      make.trailing.lessThanOrEqualTo(footerActions.snp.leading).offset(-12)
    }
    footerActions.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview().inset(16)
      make.trailing.equalToSuperview().offset(-16)
    }
    for button in [shareButton, stopButton, startAgainButton, doneButton] {
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.setContentCompressionResistancePriority(.required, for: .horizontal)
      button.snp.makeConstraints { make in
        make.height.greaterThanOrEqualTo(40)
      }
    }

    renderCharts()
    renderRunState()
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
      fitsVisibleHeightConstraint?.update(offset: -bottomInset)
    }
    let compact = min(758, view.bounds.width - 48) < 620
    if compactLayout != compact {
      compactLayout = compact
      pageStack.snp.updateConstraints { make in
        make.leading.trailing.equalToSuperview().inset(compact ? 8 : 32)
      }
    }
  }

  func setModel(name: String, image: UIImage) {
    modelButton.configuration?.title = name
    modelIconView.image = image
  }

  /// Shows what a run is reading or writing below the charts; nil between runs.
  func setProgress(_ progress: SpeedometerProgress?) {
    // Each phase gets its own clock, kept while only its counts change.
    switch (self.progress, progress) {
    case (.reading(_, let oldTotal), .reading(_, let total)) where oldTotal == total:
      break
    case (.writing, .writing):
      break
    default:
      progressStartTime = CACurrentMediaTime()
    }
    let isVisibilityChanged = (self.progress == nil) != (progress == nil)
    self.progress = progress
    if progress == nil {
      progressTimer?.invalidate()
      progressTimer = nil
    } else if progressTimer == nil {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        self?.renderProgress()
      }
      progressTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }
    renderProgress()
    guard isVisibilityChanged, isViewLoaded else { return }
    let isVisible = progress != nil
    progressShimmerView.isShimmering = isVisible
    UIView.animate(withDuration: 0.2) {
      self.progressShimmerView.alpha = isVisible ? 1 : 0
    }
  }

  private func renderProgress() {
    let elapsedTime = formatElapsedTime(CACurrentMediaTime() - progressStartTime)
    switch progress {
    case .reading(let finished, let total):
      progressLabel.text =
        LocalizedString.forKey("reading_dot") + " (\(finished)/\(total), \(elapsedTime))"
    case .writing(let tokens):
      progressLabel.text = LocalizedString.forKey("writing_dot") + " (\(tokens), \(elapsedTime))"
    case .coolingDown:
      progressLabel.text = LocalizedString.forKey("cooling_down_dot") + " (\(elapsedTime))"
    case nil:
      break
    }
  }

  /// Brings the footer in or out the way the cards above the chat input come and go.
  func setFooterVisible(_ visible: Bool, animated: Bool, completion: @escaping () -> Void = {}) {
    loadViewIfNeeded()
    // The banner skips its completion when it is already where it is asked to be.
    guard footerBannerController.isVisible != visible else {
      completion()
      return
    }
    footerBannerController.setVisible(visible, animated: animated, completion: completion)
  }

  /// The heading and both charts on the page's background, for sharing.
  func resultsImage() -> UIImage {
    // Ends at the decode chart, leaving out the status line below it while a run goes on.
    let contentBounds = CGRect(
      x: 0, y: 0, width: pageStack.bounds.width, height: decodeCard.frame.maxY)
    let contentImage = UIGraphicsImageRenderer(bounds: contentBounds).image { _ in
      pageStack.drawHierarchy(in: pageStack.bounds, afterScreenUpdates: true)
    }
    let bounds = contentBounds.insetBy(dx: -24, dy: -24)
    return UIGraphicsImageRenderer(bounds: bounds).image { context in
      UIColor.tertiaryBackground.resolvedColor(with: traitCollection).setFill()
      context.fill(bounds)
      contentImage.draw(at: .zero)
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

  private func makeChart(title: String, detailLabel: UILabel, chartView: UIView) -> UIView {
    let card = BorderView.defaultBorderView(cornerRadius: 16)
    card.backgroundColor = .novemdecenaryBackground
    card.borderColor = .primaryBorder

    let titleLabel = UILabel()
    titleLabel.numberOfLines = 0
    titleLabel.text = title
    titleLabel.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: titleLabel)

    detailLabel.numberOfLines = 0
    detailLabel.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .light), bindTo: detailLabel)

    chartView.backgroundColor = .clear
    let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, chartView])
    stack.axis = .vertical
    stack.spacing = 4
    stack.setCustomSpacing(20, after: detailLabel)
    card.addSubview(stack)
    stack.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20))
    }
    // Charts give up height, down to 140, before the page has to scroll.
    chartView.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
    chartView.setContentCompressionResistancePriority(.defaultLow - 1, for: .vertical)
    chartView.snp.makeConstraints { make in
      make.height.greaterThanOrEqualTo(140)
      make.height.lessThanOrEqualTo(200)
      make.height.equalTo(200).priority(.low.advanced(by: 1))
    }
    return card
  }

  private func renderCharts() {
    prefillChartController.rootView = ModelSpeedChartView(
      palette: .orange, contextLengths: contextLengths,
      points: measurements.map {
        ModelSpeedChartView.Point(
          contextLength: $0.contextLength, tokensPerSecond: $0.prefillTokensPerSecond)
      })
    decodeChartController.rootView = ModelSpeedChartView(
      palette: .blue, contextLengths: contextLengths,
      points: measurements.compactMap { measurement in
        measurement.decodeTokensPerSecond.map {
          ModelSpeedChartView.Point(contextLength: measurement.contextLength, tokensPerSecond: $0)
        }
      })
  }

  // While running, Stop stands where Start again and Done appear once the run is over.
  private func renderRunState() {
    setHidden(isRunning, for: startAgainButton)
    setHidden(isRunning, for: doneButton)
    setHidden(!isRunning, for: stopButton)
  }

  private func setHidden(_ isHidden: Bool, for view: UIView) {
    guard view.isHidden != isHidden else { return }
    view.isHidden = isHidden
    view.alpha = isHidden ? 0 : 1
  }
}
