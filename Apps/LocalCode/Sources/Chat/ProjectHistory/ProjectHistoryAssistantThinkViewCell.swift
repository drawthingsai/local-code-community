import Components
import FBShimmer
import Localization
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SnapKit
import Style
import UIKit

final class ProjectHistoryAssistantThinkViewCell: UICollectionViewCell {
  static let reusableIdentifier = "ProjectHistoryAssistantThinkViewCell"

  struct ViewModel: Equatable {
    var temporary: String
    var thinking: String
    var output: String
    var mode: ProjectHistoryItem.Mode
  }

  var viewModel: ViewModel = ViewModel(temporary: "", thinking: "", output: "", mode: .none) {
    didSet {
      guard viewModel != oldValue else { return }
      let hasActivity = !viewModel.thinking.isEmpty || !viewModel.output.isEmpty
      // Finished tool calls end with the separator while thinking or output follows them.
      let text =
        hasActivity && !viewModel.temporary.isEmpty
        ? viewModel.temporary + "\n---" : viewModel.temporary
      if markdownTextView.string != text {
        markdownTextView.string = text
      }
      markdownTextView.isHidden = text.isEmpty
      if viewModel.thinking != oldValue.thinking {
        updateThinking(previousThinking: oldValue.thinking)
      }
      if viewModel.output != oldValue.output {
        outputTextView.string = viewModel.output
        outputTextView.isHidden = viewModel.output.isEmpty
      }
      if text.isEmpty && !hasActivity {
        imageViewTopConstraint?.activate()
      } else {
        imageViewTopConstraint?.deactivate()
      }
      if viewModel.mode != oldValue.mode {
        activityIndicator.startAnimating()
        updateModeLabel()
      }
    }
  }
  var localPathResolver: LocalPathResolver? {
    didSet {
      guard localPathResolver != oldValue else { return }
      updateConfigurations()
      setNeedsLayout()
    }
  }
  // The Reduce Reasoning Animation machine setting; Reduce Motion reduces it regardless.
  var isReduceReasoningAnimationEnabled = false {
    didSet {
      guard isReduceReasoningAnimationEnabled != oldValue else { return }
      updateShimmering()
    }
  }

  private static let thinkingLineLimit: CGFloat = 20
  // Matches the chat history's top fade in ChatViewControllerForiPad.
  private static let thinkingFadeHeight: CGFloat = 26

  private lazy var markdownTextView = Self.makeMarkdownTextView()
  private lazy var thinkingTextView: MarkdownTextView = {
    let textView = Self.makeMarkdownTextView()
    textView.configuration = ProjectHistoryMarkdownConfiguration.make(
      localPathResolver: nil, isTransient: true, allowsEmbeddedMedia: false)
    // Always its full height; the clip view does the cutting.
    textView.setContentCompressionResistancePriority(.required, for: .vertical)
    return textView
  }()
  private lazy var outputTextView: MarkdownTextView = {
    let textView = Self.makeMarkdownTextView()
    textView.isHidden = true
    return textView
  }()
  // Shows the bottom thinkingLineLimit lines of thinking: the text view is pinned to the bottom and
  // clipped above, with a fade on the top edge once it overflows.
  private lazy var thinkingClipView: UIView = {
    let view = UIView(frame: .zero)
    view.clipsToBounds = true
    view.isHidden = true
    view.addSubview(thinkingTextView)
    return view
  }()
  // The chat history's top fade curve, inverted for a mask: hidden, 20% visible a fifth of the way
  // down, then fully visible at thinkingFadeHeight.
  private let thinkingFadeMaskLayer: CAGradientLayer = {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.white.withAlphaComponent(0).cgColor,
      UIColor.white.withAlphaComponent(0.2).cgColor,
      UIColor.white.cgColor,
    ]
    return gradientLayer
  }()
  private lazy var textStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [
      markdownTextView, thinkingClipView, outputTextView,
    ])
    stackView.axis = .vertical
    return stackView
  }()
  private lazy var shimmerContentView: UIView = {
    let view = UIView(frame: .zero)
    view.addSubview(modeLabel)
    return view
  }()
  // Only the status row shimmers. It still spans the chat, so the band passes at the same pace as
  // the Model Speed page's.
  private lazy var shimmerView: FBShimmeringView = {
    let view = FBShimmeringView(frame: .zero)
    view.contentView = shimmerContentView
    view.shimmeringOpacity = 0.28
    view.shimmeringAnimationOpacity = 1
    view.shimmeringSpeed = 360
    view.shimmeringPauseDuration = 0.05
    return view
  }()
  private lazy var modeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = LocalizedString.forKey("thinking_dot")
    label.textColor = .octonaryText
    FontMetrics.default.scaleFont(.italicSystemFont(ofSize: 15), bindTo: label)
    return label
  }()
  private lazy var activityIndicator: UIActivityIndicatorView = {
    let activityIndicator = UIActivityIndicatorView(style: .medium)
    activityIndicator.hidesWhenStopped = true
    return activityIndicator
  }()
  private lazy var divider = SettingsViewFactory.makeDividerView()
  private var imageViewTopConstraint: Constraint? = nil
  private var thinkingClipHeightConstraint: Constraint? = nil
  private var thinkingOverflow: CGFloat = 0
  private var isThinkingAppended = false
  private var elapsedTimeTimer: Timer?
  private var reducesAnimation: Bool {
    isReduceReasoningAnimationEnabled || UIAccessibility.isReduceMotionEnabled
  }
  private var thinkingMaxHeight: CGFloat {
    ceil(thinkingTextView.baseFont.lineHeight * Self.thinkingLineLimit)
  }
  private var remoteImageDidLoadObserver: NSObjectProtocol?
  private var reduceMotionObserver: NSObjectProtocol?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    let imageView = UIImageView(image: #imageLiteral(resourceName: "monkey"))
    imageView.isUserInteractionEnabled = false
    imageView.backgroundColor = .quattuordecenaryBackground
    imageView.layer.cornerRadius = 6
    contentView.addSubview(textStackView)
    contentView.addSubview(shimmerView)
    contentView.addSubview(divider)
    contentView.addSubview(imageView)
    contentView.addSubview(activityIndicator)
    divider.snp.makeConstraints { make in
      make.top.equalToSuperview()
      make.bottom.equalTo(imageView.snp.top).offset(-6).priority(.high)
      make.width.equalTo(2)
      make.leading.equalToSuperview().offset(4)
    }
    imageView.snp.makeConstraints { make in
      make.width.equalTo(24)
      make.height.equalTo(24).priority(.high.advanced(by: 1))
      make.leading.bottom.equalToSuperview()
      imageViewTopConstraint = make.top.equalToSuperview().constraint
      imageViewTopConstraint?.deactivate()
    }
    activityIndicator.snp.makeConstraints { make in
      make.size.equalTo(20)
      make.centerY.equalTo(imageView)
      make.leading.equalTo(imageView.snp.trailing).offset(8)
    }
    shimmerView.snp.makeConstraints { make in
      make.centerY.equalTo(imageView)
      make.trailing.equalToSuperview()
      make.leading.equalTo(divider.snp.trailing).offset(6)
    }
    shimmerContentView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    textStackView.snp.makeConstraints { make in
      make.top.trailing.equalToSuperview()
      make.leading.equalTo(divider.snp.trailing).offset(6)
      make.bottom.equalTo(imageView.snp.top).offset(-12).priority(.high)
    }
    thinkingClipView.snp.makeConstraints { make in
      thinkingClipHeightConstraint = make.height.lessThanOrEqualTo(thinkingMaxHeight).constraint
      make.height.equalTo(thinkingTextView).priority(.low)
    }
    thinkingTextView.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalToSuperview()
    }
    modeLabel.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview()
      make.leading.equalTo(activityIndicator.snp.trailing).offset(4)
    }
    remoteImageDidLoadObserver = NotificationCenter.default.addObserver(
      forName: .projectHistoryRemoteImageDidLoad, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.window != nil else { return }
      self.updateConfigurations()
      self.setNeedsLayout()
      (self.superview as? UICollectionView)?.collectionViewLayout.invalidateLayout()
    }
    reduceMotionObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.updateShimmering()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Nested views only get their frames once laid out; the thinking window measures them.
    contentView.layoutIfNeeded()
    layoutThinkingWindow()
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    // Resolve markdown image sizes at the row width before measuring its height.
    setNeedsLayout()
    layoutIfNeeded()
    return super.preferredLayoutAttributesFitting(layoutAttributes)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    for textView in [markdownTextView, thinkingTextView, outputTextView] {
      textView.removeEmbeddedMedia()
      textView.resignFirstResponder()
      textView.selectedTextRange = nil
    }
    thinkingTextView.layer.removeAllAnimations()
    isThinkingAppended = false
  }

  deinit {
    elapsedTimeTimer?.invalidate()
    if let remoteImageDidLoadObserver {
      NotificationCenter.default.removeObserver(remoteImageDidLoadObserver)
    }
    if let reduceMotionObserver {
      NotificationCenter.default.removeObserver(reduceMotionObserver)
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateShimmering()
    elapsedTimeTimer?.invalidate()
    elapsedTimeTimer = nil
    if window != nil {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        self?.updateModeLabel()
      }
      RunLoop.main.add(timer, forMode: .common)
      elapsedTimeTimer = timer
    }
  }

  private func updateShimmering() {
    shimmerView.isShimmering = window != nil && !reducesAnimation
  }

  private func updateConfigurations() {
    let configuration = ProjectHistoryMarkdownConfiguration.make(
      localPathResolver: localPathResolver, isTransient: true)
    markdownTextView.configuration = configuration
    outputTextView.configuration = configuration
    // Thinking only passes through the window for a few seconds, so it never creates web or video
    // views; those references render as text.
    thinkingTextView.configuration = ProjectHistoryMarkdownConfiguration.make(
      localPathResolver: localPathResolver, isTransient: true, allowsEmbeddedMedia: false)
  }

  private func updateThinking(previousThinking: String) {
    thinkingTextView.string = viewModel.thinking
    thinkingClipView.isHidden = viewModel.thinking.isEmpty
    thinkingClipHeightConstraint?.update(offset: thinkingMaxHeight)
    // Only text appended at the bottom slides; a trimmed head or a new turn snaps into place.
    isThinkingAppended =
      !previousThinking.isEmpty && viewModel.thinking.hasPrefix(previousThinking)
    setNeedsLayout()
  }

  // Measures the thinking window after layout, since the text view's height is only settled there
  // (images and LaTeX included). Self-sizing first lays the cell out at its old height, which
  // squeezes the clip view, so compare against the fixed window height instead of the clip's.
  private func layoutThinkingWindow() {
    let clipBounds = thinkingClipView.bounds
    let overflow =
      thinkingClipView.isHidden ? 0 : max(thinkingTextView.bounds.height - thinkingMaxHeight, 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    thinkingFadeMaskLayer.frame = clipBounds
    let fade = Double(Self.thinkingFadeHeight / max(clipBounds.height, 1))
    thinkingFadeMaskLayer.locations = [0, NSNumber(value: fade * 0.2), NSNumber(value: fade)]
    CATransaction.commit()
    thinkingClipView.layer.mask = overflow > 0 ? thinkingFadeMaskLayer : nil
    // Appended lines push the text up the bottom-pinned clip (a restyle, like a closing code fence,
    // can pull it down). Start it where it was and ease it into place. An explicit layer animation
    // still runs inside the data source's non-animated apply, and an additive one lets a change
    // that lands mid-move add to the move.
    if overflow != thinkingOverflow, isThinkingAppended, !reducesAnimation {
      let animation = CABasicAnimation(keyPath: "transform.translation.y")
      animation.isAdditive = true
      animation.fromValue = overflow - thinkingOverflow
      animation.toValue = 0
      animation.duration = 0.5
      animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
      thinkingTextView.layer.add(animation, forKey: nil)
    }
    thinkingOverflow = overflow
  }

  private func updateModeLabel() {
    switch viewModel.mode {
    case .bringup(let startTime, let bashUserInteraction):
      let duration =
        CACurrentMediaTime() - startTime
        - (bashUserInteraction?.userInteractionInterval(since: startTime) ?? 0)
      modeLabel.text =
        LocalizedString.forKey("bringing_up_dot")
        + " (\(formatElapsedTime(duration)))"
    case .reading(let finished, let total, let startTime, let bashUserInteraction):
      let duration =
        CACurrentMediaTime() - startTime
        - (bashUserInteraction?.userInteractionInterval(since: startTime) ?? 0)
      modeLabel.text =
        LocalizedString.forKey("reading_dot")
        + " ("
        + (total > 0 ? "\(finished)/\(total), " : "")
        + "\(formatElapsedTime(duration)))"
    case .thinking(let tokens, let startTime, let bashUserInteraction):
      let duration =
        CACurrentMediaTime() - startTime
        - (bashUserInteraction?.userInteractionInterval(since: startTime) ?? 0)
      modeLabel.text =
        LocalizedString.forKey("thinking_dot")
        + " (\(tokens), \(formatElapsedTime(duration)))"
    case .working(let tokens, let startTime, let bashUserInteraction):
      let duration =
        CACurrentMediaTime() - startTime
        - (bashUserInteraction?.userInteractionInterval(since: startTime) ?? 0)
      modeLabel.text =
        LocalizedString.forKey("working_dot")
        + " (\(tokens), \(formatElapsedTime(duration)))"
    case .compacting(let finished, let total, let startTime, let bashUserInteraction):
      let duration =
        CACurrentMediaTime() - startTime
        - (bashUserInteraction?.userInteractionInterval(since: startTime) ?? 0)
      if total > 0 {
        modeLabel.text =
          LocalizedString.forKey("compacting_dot")
          + " (\(finished)/\(total), \(formatElapsedTime(duration)))"
      } else {
        modeLabel.text =
          LocalizedString.forKey("compacting_dot")
          + " (\(finished), \(formatElapsedTime(duration)))"
      }
    case .none:
      modeLabel.text = LocalizedString.forKey("working_dot")
    }
  }

  private static func makeMarkdownTextView() -> MarkdownTextView {
    let textView = MarkdownTextView(frame: .zero, textContainer: nil)
    textView.backgroundColor = .clear
    textView.tintColor = .primaryColor
    textView.isEditable = false
    // Read-only history text: let file drops reach the conversation's attachment drop.
    if let textDropInteraction = textView.textDropInteraction {
      textView.removeInteraction(textDropInteraction)
    }
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.alwaysBounceVertical = false
    textView.isUserInteractionEnabled = true
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15), bindTo: textView) {
      $0.baseFont = $1
    }
    textView.configuration = ProjectHistoryMarkdownConfiguration.make(
      localPathResolver: nil, isTransient: true)
    return textView
  }
}
