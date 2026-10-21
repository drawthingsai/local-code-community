import SnapKit
import Style
import UIKit

protocol OnboardingModelControllerDelegate: AnyObject {
  func onboardingModelControllerDidSelect(_ controller: OnboardingModelController)
}

/// A card on the model page. A card without an icon is selectable and shows a radio indicator.
final class OnboardingModelController {
  weak var delegate: OnboardingModelControllerDelegate?

  var view: UIView { borderView }
  let selection: OnboardingState.Selection?
  var isSelected = false {
    didSet { updateSelection() }
  }
  /// A card embedded in another outline gives up its own border and background.
  var isOutlined = true {
    didSet {
      borderView.layer.borderWidth = isOutlined ? 1 : 0
      updateSelection()
    }
  }

  private let usesRadio: Bool
  private lazy var borderView = BorderView.defaultBorderView(cornerRadius: 16)
  private lazy var contentStack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .top
    stack.spacing = 8
    return stack
  }()
  private lazy var indicatorView: UIImageView = {
    let imageView = UIImageView(image: UIImage(systemName: "circle"))
    imageView.tintColor = .senaryText
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()
  private lazy var textStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 6
    return stack
  }()
  private lazy var headerStack: UIStackView = {
    let stack = UIStackView()
    stack.spacing = 8
    stack.alignment = .center
    return stack
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var badgeLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 12, weight: .light)
    label.layer.cornerRadius = 12
    label.clipsToBounds = true
    return label
  }()
  private lazy var detailLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .light), bindTo: label)
    return label
  }()
  // Covers the card so the whole surface is one tap target and one accessibility element.
  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.onboardingModelControllerDidSelect(self)
      }, for: .touchUpInside)
    return button
  }()

  init(
    selection: OnboardingState.Selection? = nil, title: String, detail: String, badge: String,
    isBadgeHighlighted: Bool = false, icon: UIImage? = nil
  ) {
    self.selection = selection
    usesRadio = icon == nil
    borderView.backgroundColor = .tertiaryBackground
    if let icon {
      indicatorView.image = icon
    }
    titleLabel.text = title
    detailLabel.text = detail
    badgeLabel.text = badge.isEmpty ? nil : "  \(badge)  "
    badgeLabel.textColor = isBadgeHighlighted ? .successText : .senaryText
    badgeLabel.backgroundColor =
      isBadgeHighlighted ? .successBackground : .novemdecenaryBackground
    badgeLabel.isHidden = badge.isEmpty
    button.accessibilityLabel = [title, badge, detail].filter { !$0.isEmpty }.joined(
      separator: ". ")
    borderView.addSubview(contentStack)
    borderView.addSubview(button)
    contentStack.addArrangedSubview(indicatorView)
    contentStack.addArrangedSubview(textStack)
    textStack.addArrangedSubview(headerStack)
    textStack.addArrangedSubview(detailLabel)
    headerStack.addArrangedSubview(titleLabel)
    headerStack.addArrangedSubview(badgeLabel)
    contentStack.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(12)
    }
    button.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    indicatorView.snp.makeConstraints { make in
      make.size.equalTo(24)
    }
    badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
    badgeLabel.snp.makeConstraints { make in
      make.height.greaterThanOrEqualTo(24)
    }
  }

  private func updateSelection() {
    if isOutlined {
      borderView.backgroundColor = isSelected ? .novemdecenaryBackground : .tertiaryBackground
    } else {
      borderView.backgroundColor = .clear
    }
    borderView.borderColor = isSelected ? .senaryText : .primaryBorder
    if usesRadio {
      indicatorView.image = UIImage(
        systemName: isSelected ? "largecircle.fill.circle" : "circle")
      indicatorView.tintColor = isSelected ? .primaryText : .quaternaryText
    }
    button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
  }
}
