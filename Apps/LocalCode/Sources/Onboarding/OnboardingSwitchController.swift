import SnapKit
import Style
import UIKit

protocol OnboardingSwitchControllerDelegate: AnyObject {
  func onboardingSwitchController(_ controller: OnboardingSwitchController, didSetOn isOn: Bool)
}

/// A card on the last onboarding page that turns one choice on or off. A card with an icon
/// shows it in place of a detail line and sits closer to its edges.
final class OnboardingSwitchController {
  weak var delegate: OnboardingSwitchControllerDelegate?

  var view: UIView { borderView }
  var isOn: Bool {
    get { switchView.isOn }
    set { switchView.isOn = newValue }
  }

  private lazy var borderView: BorderView = {
    let view = BorderView.defaultBorderView(cornerRadius: 16)
    view.backgroundColor = .tertiaryBackground
    return view
  }()
  private lazy var contentStack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .center
    stack.spacing = 8
    return stack
  }()
  private lazy var iconView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = false
    return imageView
  }()
  private lazy var textStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 2
    return stack
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .primaryText
    label.isAccessibilityElement = false
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var detailLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .senaryText
    label.isAccessibilityElement = false
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .regular), bindTo: label)
    return label
  }()
  private lazy var switchView: UISwitch = {
    let switchView = UISwitch()
    switchView.onTintColor = .primaryColor
    switchView.addAction(
      UIAction { [weak self, weak switchView] _ in
        guard let self, let switchView else { return }
        self.delegate?.onboardingSwitchController(self, didSetOn: switchView.isOn)
      }, for: .valueChanged)
    return switchView
  }()

  init(title: String, detail: String? = nil, icon: UIImage? = nil) {
    titleLabel.text = title
    detailLabel.text = detail
    iconView.image = icon
    // The switch speaks for the whole card.
    switchView.accessibilityLabel = title
    switchView.accessibilityHint = detail
    borderView.addSubview(contentStack)
    borderView.addSubview(switchView)
    if icon != nil {
      contentStack.addArrangedSubview(iconView)
      iconView.snp.makeConstraints { make in
        make.size.equalTo(24)
      }
    }
    contentStack.addArrangedSubview(textStack)
    textStack.addArrangedSubview(titleLabel)
    if detail != nil {
      textStack.addArrangedSubview(detailLabel)
    }
    contentStack.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview().inset(12)
      make.leading.equalToSuperview().offset(icon != nil ? 12 : 16)
      make.trailing.equalTo(switchView.snp.leading).offset(-12)
    }
    switchView.setContentCompressionResistancePriority(.required, for: .horizontal)
    switchView.snp.makeConstraints { make in
      make.centerY.equalToSuperview()
      make.top.greaterThanOrEqualToSuperview().inset(8)
      make.trailing.equalToSuperview().offset(icon != nil ? -12 : -20)
    }
  }
}
