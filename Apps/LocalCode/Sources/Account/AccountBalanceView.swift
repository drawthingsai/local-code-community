import Components
import Localization
import SnapKit
import Style
import UIKit

final class AccountBalanceView: UIView {
  var balance: String? {
    get { balanceLabel.text }
    set { balanceLabel.text = newValue }
  }
  var onTopUp: (() -> Void)?

  private lazy var balanceLabel: UILabel = {
    let label = UILabel()
    label.textColor = .secondaryText
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.7
    FontMetrics.default.scaleFont(
      .monospacedDigitSystemFont(ofSize: 16, weight: .medium), bindTo: label)
    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)

    let titleLabel = UILabel()
    titleLabel.text = LocalizedString.forKey("account_balance")
    titleLabel.textColor = .quaternaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: titleLabel)
    addSubview(titleLabel)

    let topUpButton = UIButton(type: .custom)
    var configuration = UIButton.Configuration.plain()
    configuration.cornerStyle = .fixed
    configuration.title = LocalizedString.forKey("add_funds")
    configuration.image = UIImage(imageLiteralResourceName: "arrow-right-16").withTintColor(
      .octonaryText)
    configuration.imagePlacement = .trailing
    configuration.imagePadding = 4
    configuration.background.cornerRadius = 8
    configuration.background.backgroundColor = .clear
    configuration.background.strokeColor = .primaryBorder
    configuration.background.strokeWidth = 1
    configuration.baseForegroundColor = .octonaryText
    configuration.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 8)
    topUpButton.configuration = configuration
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .medium), bindTo: topUpButton)
    topUpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    topUpButton.accessibilityLabel = LocalizedString.forKey("add_funds")
    topUpButton.addAction(
      UIAction { [weak self] _ in self?.onTopUp?() }, for: .touchUpInside)
    addSubview(topUpButton)

    let walletIcon = UIImageView(
      image: UIImage(imageLiteralResourceName: "wallet-24").withTintColor(.secondaryText))
    addSubview(walletIcon)
    addSubview(balanceLabel)
    titleLabel.snp.makeConstraints { make in
      make.top.leading.equalToSuperview().inset(16)
      make.trailing.lessThanOrEqualTo(topUpButton.snp.leading).offset(-8)
    }
    walletIcon.snp.makeConstraints { make in
      make.leading.equalTo(titleLabel)
      make.centerY.equalTo(balanceLabel)
      make.size.equalTo(24)
    }
    balanceLabel.snp.makeConstraints { make in
      make.top.equalTo(titleLabel.snp.bottom).offset(4)
      make.leading.equalTo(walletIcon.snp.trailing).offset(8)
      make.height.greaterThanOrEqualTo(24)
      make.trailing.lessThanOrEqualTo(topUpButton.snp.leading).offset(-8)
      // Settings collapses this arranged subview when LocalCode is not selected.
      // Let UIStackView's required zero-height constraint win while hidden.
      make.bottom.equalToSuperview().inset(12).priority(999)
    }
    topUpButton.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(16)
      make.centerY.equalToSuperview()
      make.height.greaterThanOrEqualTo(32)
    }

    let divider = SettingsViewFactory.makeDividerView()
    addSubview(divider)
    divider.snp.makeConstraints { make in
      make.height.equalTo(0.5)
      make.leading.trailing.bottom.equalToSuperview()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
