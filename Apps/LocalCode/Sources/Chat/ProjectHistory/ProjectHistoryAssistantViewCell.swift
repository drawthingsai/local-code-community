import Localization
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SnapKit
import Style
import UIKit

protocol ProjectHistoryAssistantViewCellDelegate: AnyObject {
  func projectHistoryAssistantViewCellDidSelectCopy(_ cell: ProjectHistoryAssistantViewCell)
  func projectHistoryAssistantViewCellDidSelectContinue(_ cell: ProjectHistoryAssistantViewCell)
}

final class ProjectHistoryAssistantViewCell: UICollectionViewCell {
  static let reusableIdentifier = "ProjectHistoryAssistantViewCell"

  weak var delegate: ProjectHistoryAssistantViewCellDelegate?

  var text: String = "" {
    didSet {
      guard text != oldValue else { return }
      markdownTextView.string = text
      setNeedsLayout()
    }
  }
  var localPathResolver: LocalPathResolver? {
    didSet {
      guard localPathResolver != oldValue else { return }
      markdownTextView.configuration = ProjectHistoryMarkdownConfiguration.make(
        localPathResolver: localPathResolver)
      setNeedsLayout()
    }
  }
  private lazy var markdownTextView: MarkdownTextView = {
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
    textView.configuration = ProjectHistoryMarkdownConfiguration.make(localPathResolver: nil)
    return textView
  }()
  private lazy var datetimeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .quaternaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13), bindTo: label)
    return label
  }()
  private lazy var copyButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = .zero
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "copy-16").withRenderingMode(
      .alwaysTemplate)
    button.configuration = configuration
    button.accessibilityLabel = LocalizedString.forKey("copy")
    button.addSubview(copyCheckImageView)
    copyCheckImageView.snp.makeConstraints { make in
      make.center.equalToSuperview()
    }
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectHistoryAssistantViewCellDidSelectCopy(self)
        self.copyResetTimer?.invalidate()
        self.setCopyCompleted(true, animated: true)
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
          guard let self else { return }
          self.copyResetTimer = nil
          self.setCopyCompleted(false, animated: true)
        }
        self.copyResetTimer = timer
        RunLoop.main.add(timer, forMode: .common)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var copyCheckImageView: UIImageView = {
    let imageView = UIImageView(
      image: #imageLiteral(resourceName: "check-16").withRenderingMode(.alwaysTemplate))
    imageView.tintColor = .senaryText
    imageView.alpha = 0
    imageView.transform = CGAffineTransform(scaleX: 0.25, y: 0.25)
    return imageView
  }()
  private lazy var refreshButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = .zero
    configuration.baseForegroundColor = .senaryText
    configuration.image = #imageLiteral(resourceName: "refresh-16").withRenderingMode(
      .alwaysTemplate)
    button.configuration = configuration
    return button
  }()
  private lazy var continueButton: UIButton = {
    let button = UIButton(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.title = LocalizedString.forKey("continue")
    configuration.image = #imageLiteral(resourceName: "arrow-right-thick-16").withRenderingMode(
      .alwaysTemplate)
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 2
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 8, bottom: 0, trailing: 6)
    configuration.baseBackgroundColor = .clear
    configuration.baseForegroundColor = .shadePalette(for: .blue)
    configuration.background.backgroundColor = .overlayPalette(for: .blue)
    configuration.background.cornerRadius = 8
    button.configuration = configuration
    button.isHidden = true
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 12, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectHistoryAssistantViewCellDidSelectContinue(self)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var metadataView = UIView(frame: .zero)
  private var refreshButtonTrailingConstraint: Constraint?
  private var continueButtonTrailingConstraint: Constraint?
  private var remoteImageDidLoadObserver: NSObjectProtocol?
  private var copyResetTimer: Timer?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(markdownTextView)
    contentView.addSubview(metadataView)
    metadataView.addSubview(datetimeLabel)
    metadataView.addSubview(copyButton)
    metadataView.addSubview(refreshButton)
    metadataView.addSubview(continueButton)
    markdownTextView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.bottom.equalTo(metadataView.snp.top).offset(-8)
    }
    metadataView.snp.makeConstraints { make in
      make.height.equalTo(24)
      make.leading.bottom.equalToSuperview()
    }
    datetimeLabel.snp.makeConstraints { make in
      make.leading.centerY.equalToSuperview()
    }
    copyButton.snp.makeConstraints { make in
      make.size.equalTo(24)
      make.leading.equalTo(datetimeLabel.snp.trailing).offset(8)
      make.centerY.equalToSuperview()
    }
    refreshButton.snp.makeConstraints { make in
      make.size.equalTo(24)
      make.leading.equalTo(copyButton.snp.trailing).offset(4)
      make.centerY.equalToSuperview()
      refreshButtonTrailingConstraint = make.trailing.equalToSuperview().constraint
    }
    continueButton.snp.makeConstraints { make in
      make.height.equalTo(24)
      make.leading.equalTo(datetimeLabel.snp.trailing).offset(8)
      make.centerY.equalToSuperview()
      continueButtonTrailingConstraint = make.trailing.equalToSuperview().priority(.high).constraint
    }
    continueButtonTrailingConstraint?.deactivate()
    remoteImageDidLoadObserver = NotificationCenter.default.addObserver(
      forName: .projectHistoryRemoteImageDidLoad, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.window != nil else { return }
      self.markdownTextView.configuration = ProjectHistoryMarkdownConfiguration.make(
        localPathResolver: self.localPathResolver)
      self.setNeedsLayout()
      (self.superview as? UICollectionView)?.collectionViewLayout.invalidateLayout()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    // Resolve markdown image sizes at the row width before measuring its height.
    setNeedsLayout()
    layoutIfNeeded()
    return super.preferredLayoutAttributesFitting(layoutAttributes)
  }

  override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
    super.apply(layoutAttributes)
    // A margin change can move the row without resizing it, which skips layoutSubviews.
    updateTableOverflowInsets()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateTableOverflowInsets()
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    if let view = super.hitTest(point, with: event) {
      return view
    }
    // Wide tables scroll out past the row's sides, where the row's own bounds check drops touches.
    guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
    return markdownTextView.hitTest(convert(point, to: markdownTextView), with: event)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    copyResetTimer?.invalidate()
    copyResetTimer = nil
    setCopyCompleted(false, animated: false)
    markdownTextView.removeEmbeddedMedia()
    markdownTextView.resignFirstResponder()
    markdownTextView.selectedTextRange = nil
  }

  deinit {
    copyResetTimer?.invalidate()
    if let remoteImageDidLoadObserver {
      NotificationCenter.default.removeObserver(remoteImageDidLoadObserver)
    }
  }

  // Wide tables rest on the text column but scroll out to the transcript's edges, like a document
  // page. The row's side gaps are the margins the collection view lays it out in.
  private func updateTableOverflowInsets() {
    guard let superview else { return }
    markdownTextView.tableOverflowInsets = UIEdgeInsets(
      top: 0, left: frame.minX - superview.bounds.minX, bottom: 0,
      right: superview.bounds.maxX - frame.maxX)
  }

  private func setCopyCompleted(_ completed: Bool, animated: Bool) {
    copyButton.accessibilityValue =
      completed ? LocalizedString.forKey("copied_to_clipboard") : nil
    let updateIcons = {
      let hiddenTransform = CGAffineTransform(scaleX: 0.25, y: 0.25)
      self.copyButton.imageView?.alpha = completed ? 0 : 1
      self.copyButton.imageView?.transform = completed ? hiddenTransform : .identity
      self.copyCheckImageView.alpha = completed ? 1 : 0
      self.copyCheckImageView.transform = completed ? .identity : hiddenTransform
    }
    if animated {
      UIView.animate(
        withDuration: 0.25, delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: updateIcons)
    } else {
      copyButton.imageView?.layer.removeAllAnimations()
      copyCheckImageView.layer.removeAllAnimations()
      UIView.performWithoutAnimation(updateIcons)
    }
  }

  func setDatetime(_ datetime: Date, duration: TimeInterval, isIncomplete: Bool = false) {
    continueButton.isHidden = !isIncomplete
    copyButton.isHidden = isIncomplete
    refreshButton.isHidden = isIncomplete
    if isIncomplete {
      refreshButtonTrailingConstraint?.deactivate()
      continueButtonTrailingConstraint?.activate()
      datetimeLabel.text = formatDatetime(datetime)
    } else if duration > 0 {
      continueButtonTrailingConstraint?.deactivate()
      refreshButtonTrailingConstraint?.activate()
      datetimeLabel.text =
        formatDatetime(datetime) + " · " + LocalizedString.forKey("worked") + " "
        + formatElapsedTime(duration)
    } else {
      continueButtonTrailingConstraint?.deactivate()
      refreshButtonTrailingConstraint?.activate()
      datetimeLabel.text = formatDatetime(datetime)
    }
  }
}
