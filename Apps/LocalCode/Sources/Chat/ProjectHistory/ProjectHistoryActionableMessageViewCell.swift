import Components
import SnapKit
import Style
import UIKit

final class ProjectHistoryActionableMessageViewCell: UICollectionViewCell {
  static let reusableIdentifier = "ProjectHistoryActionableMessageViewCell"

  var viewModel: ProjectHistoryItem.ActionableMessage? {
    didSet {
      guard viewModel !== oldValue else { return }
      iconView.layer.removeAnimation(forKey: "loading")
      updateMessageText()
      button.isHidden = viewModel?.ctaText == nil
      labelTrailingToButtonConstraint?.isActive = viewModel?.ctaText != nil
      var configuration = button.configuration
      configuration?.title = viewModel?.ctaText
      configuration?.image = nil
      guard let viewModel else {
        iconView.image = nil
        button.configuration = configuration
        return
      }
      let palette: UIColor.ColorPalette
      let imageName: String
      let iconSize: CGFloat
      switch viewModel.messageType {
      case .warning:
        palette = .orange
        imageName = "warning-filled-16"
        iconSize = 16
      case .success:
        palette = .green
        imageName = "check-circle-filled-16"
        iconSize = 13
      case .error:
        palette = .red
        imageName = "error-filled-16"
        iconSize = 16
      case .loading:
        palette = .blue
        imageName = "message-spinner"
        iconSize = 19.5
      }
      messageView.backgroundColor = .overlayPalette(for: palette)
      // Figma overlays Border Tertiary at 12% on the palette's pastel outline.
      messageView.borderColor = UIColor { traits in
        UIColor.pastelPalette(for: palette).resolvedColor(with: traits).mixed(
          with: UIColor.tertiaryBorder.resolvedColor(with: traits).withAlphaComponent(1),
          weight: 0.12)
      }
      iconContainer.backgroundColor =
        viewModel.messageType == .loading ? .clear : .pastelPalette(for: palette)
      iconView.tintColor =
        viewModel.messageType == .loading
        ? .colorPalette(for: palette) : .shadePalette(for: palette)
      // Preserve the white check in the two-color success asset.
      iconView.image = UIImage(named: imageName)?.withRenderingMode(
        viewModel.messageType == .success ? .alwaysOriginal : .alwaysTemplate)
      iconView.snp.updateConstraints { make in
        make.size.equalTo(iconSize)
      }
      if viewModel.messageType == .loading {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = 1
        animation.repeatCount = .infinity
        iconView.layer.add(animation, forKey: "loading")
      }
      if viewModel.messageType == .warning {
        configuration?.image = UIImage(named: "arrow-right-16")?.withRenderingMode(.alwaysTemplate)
      }
      configuration?.contentInsets = .init(
        top: 8, leading: 12, bottom: 8,
        trailing: viewModel.messageType == .warning ? 10 : 12)
      button.configuration = configuration
      setNeedsLayout()
    }
  }

  private lazy var messageView: BorderView = {
    let view = BorderView(frame: .zero)
    view.layer.cornerRadius = 16
    view.layer.borderWidth = 1
    return view
  }()
  private lazy var iconContainer: UIView = {
    let view = UIView(frame: .zero)
    view.layer.cornerRadius = 8
    return view
  }()
  private lazy var iconView: UIImageView = {
    let view = UIImageView(frame: .zero)
    view.contentMode = .scaleAspectFit
    view.isAccessibilityElement = false
    return view
  }()
  private lazy var label: UILabel = {
    let label = UILabel(frame: .zero)
    label.numberOfLines = 0
    label.textColor = .primaryText
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }()
  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.setContentHuggingPriority(.required, for: .horizontal)
    var configuration = UIButton.Configuration.filled()
    configuration.baseForegroundColor = .nonaryText
    configuration.baseBackgroundColor = .primaryFill
    configuration.cornerStyle = .fixed
    configuration.background.cornerRadius = 8
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    button.configuration = configuration
    button.isHidden = true
    return button
  }()
  private var labelTrailingToButtonConstraint: Constraint?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(messageView)
    messageView.addSubview(iconContainer)
    iconContainer.addSubview(iconView)
    messageView.addSubview(label)
    messageView.addSubview(button)
    messageView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    iconContainer.snp.makeConstraints { make in
      make.leading.top.equalToSuperview().inset(12)
      make.size.equalTo(24)
      make.bottom.lessThanOrEqualToSuperview().inset(12)
    }
    iconView.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.size.equalTo(16)
    }
    label.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview().inset(14)
      make.leading.equalTo(iconContainer.snp.trailing).offset(12)
      make.trailing.equalToSuperview().inset(12).priority(.high)
      labelTrailingToButtonConstraint =
        make.trailing.equalTo(button.snp.leading).offset(-16).constraint
    }
    labelTrailingToButtonConstraint?.deactivate()
    button.snp.makeConstraints { make in
      make.top.greaterThanOrEqualToSuperview().inset(8)
      make.bottom.trailing.equalToSuperview().inset(8)
      make.height.greaterThanOrEqualTo(32)
    }

    FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: label) {
      [weak self] label, font in
      label.font = font
      self?.updateMessageText()
    }
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .semibold), bindTo: button) {
      button, font in
      button.configuration?.titleTextAttributesTransformer =
        UIConfigurationTextAttributesTransformer {
          var attributes = $0
          attributes.font = font
          attributes.uiKit.kern = -0.12 * font.pointSize / 12
          return attributes
        }
    }
    button.addAction(
      UIAction { [weak self] _ in self?.viewModel?.ctaHandler?() }, for: .touchUpInside)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    viewModel = nil
  }

  private func updateMessageText() {
    guard let viewModel else {
      label.attributedText = nil
      return
    }
    // UILabel can adopt the title's semibold font from its previous attributed text.
    let font = UIFont.systemFont(ofSize: label.font.pointSize)
    let scale = font.pointSize / 14
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 20 * scale
    paragraph.maximumLineHeight = 20 * scale
    let text = NSMutableAttributedString(
      string: viewModel.title + (viewModel.subtitle.isEmpty ? "" : " — " + viewModel.subtitle),
      attributes: [
        .font: font, .foregroundColor: UIColor.primaryText, .kern: -0.21 * scale,
        .paragraphStyle: paragraph,
      ])
    text.addAttribute(
      .font, value: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold),
      range: NSRange(location: 0, length: viewModel.title.utf16.count))
    label.attributedText = text
  }
}
