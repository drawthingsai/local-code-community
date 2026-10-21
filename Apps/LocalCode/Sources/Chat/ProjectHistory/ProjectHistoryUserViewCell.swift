import Localization
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SnapKit
import Style
import UIKit

protocol ProjectHistoryUserViewCellDelegate: AnyObject {
  func projectHistoryUserViewCellDidSelectCopy(_ cell: ProjectHistoryUserViewCell)
}

final class ProjectHistoryUserViewCell: UICollectionViewCell {
  static let reusableIdentifier = "ProjectHistoryUserViewCell"

  weak var delegate: ProjectHistoryUserViewCellDelegate?

  var text: String = "" {
    didSet {
      guard text != oldValue else { return }
      markdownTextView.string = text
      markdownTextView.invalidateIntrinsicContentSize()
      invalidateIntrinsicContentSize()
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
  var datetime: Date? {
    didSet {
      guard datetime != oldValue else { return }
      datetimeLabel.text = datetime.map(formatDatetime)
    }
  }

  private lazy var bubbleView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .clear
    view.layer.cornerRadius = 16
    view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner]
    view.clipsToBounds = true
    let bottomTrailingCornerRadiusView = UIView(frame: .zero)
    bottomTrailingCornerRadiusView.isUserInteractionEnabled = false
    bottomTrailingCornerRadiusView.backgroundColor = .octodecenaryBackground
    bottomTrailingCornerRadiusView.layer.cornerRadius = 8
    bottomTrailingCornerRadiusView.layer.maskedCorners = [.layerMaxXMaxYCorner]
    view.addSubview(bottomTrailingCornerRadiusView)
    bottomTrailingCornerRadiusView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    return view
  }()
  private lazy var markdownTextView: MarkdownTextView = {
    let textView = MarkdownTextView(frame: .zero, textContainer: nil)
    textView.backgroundColor = .clear
    textView.tintColor = .octonaryText
    textView.isEditable = false
    // Read-only history text: let file drops reach the conversation's attachment drop.
    if let textDropInteraction = textView.textDropInteraction {
      textView.removeInteraction(textDropInteraction)
    }
    textView.isSelectable = true
    textView.isScrollEnabled = false
    textView.alwaysBounceVertical = false
    textView.isUserInteractionEnabled = true
    textView.usesNaturalWidthForIntrinsicContentSize = true
    textView.setContentHuggingPriority(UILayoutPriority(999), for: .horizontal)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    FontMetrics.default.scaleFont(.systemFont(ofSize: 15), bindTo: textView) {
      $0.baseFont = $1
    }
    textView.configuration = ProjectHistoryMarkdownConfiguration.make(localPathResolver: nil)
    return textView
  }()
  private lazy var datetimeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .quaternaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: label)
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
        self.delegate?.projectHistoryUserViewCellDidSelectCopy(self)
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
  private lazy var metadataView = UIView(frame: .zero)
  private var remoteImageDidLoadObserver: NSObjectProtocol?
  private var copyResetTimer: Timer?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.clipsToBounds = false
    contentView.addSubview(bubbleView)
    contentView.addSubview(metadataView)
    bubbleView.addSubview(markdownTextView)
    metadataView.addSubview(copyButton)
    metadataView.addSubview(datetimeLabel)
    bubbleView.snp.makeConstraints { make in
      make.top.trailing.equalToSuperview()
      make.bottom.equalTo(metadataView.snp.top).offset(-4)
      make.leading.greaterThanOrEqualToSuperview().offset(80)
      make.width.lessThanOrEqualToSuperview().multipliedBy(0.78)
    }
    markdownTextView.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(16)
      make.top.equalToSuperview().inset(8)
      make.bottom.equalToSuperview().inset(12)
    }
    metadataView.snp.makeConstraints { make in
      make.height.equalTo(24)
      make.trailing.equalTo(bubbleView).offset(-8)
      make.bottom.equalToSuperview()
    }
    copyButton.snp.makeConstraints { make in
      make.size.equalTo(24)
      make.leading.centerY.equalToSuperview()
    }
    datetimeLabel.snp.makeConstraints { make in
      make.leading.equalTo(copyButton.snp.trailing).offset(8)
      make.trailing.centerY.equalToSuperview()
    }
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
    // Resolve markdown image sizes at the bubble width before measuring its height.
    setNeedsLayout()
    layoutIfNeeded()
    return super.preferredLayoutAttributesFitting(layoutAttributes)
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
}
