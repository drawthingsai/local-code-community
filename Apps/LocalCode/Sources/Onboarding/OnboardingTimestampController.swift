import Localization
import SnapKit
import Style
import UIKit

/// The row under the onboarding transcript. While initializing it mirrors the chat's thinking
/// row; once done it mirrors the chat response's footer.
final class OnboardingTimestampController {
  var view: UIView { stack }
  /// The footer line shown once initializing is over.
  var text: String? {
    get { datetimeLabel.text }
    set { datetimeLabel.text = newValue }
  }
  var isInitializing = false {
    didSet {
      guard isInitializing != oldValue else { return }
      iconView.isHidden = !isInitializing
      spinner.isHidden = !isInitializing
      modeLabel.isHidden = !isInitializing
      datetimeLabel.isHidden = isInitializing
      // Keeps about 12pt of visible space under the text in both states: the icon fills the
      // row, while the shorter footer line is centred in it.
      stack.layoutMargins.top = isInitializing ? 4 : 0
      if isInitializing { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
  }

  private lazy var stack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .center
    stack.spacing = 8
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = .zero
    return stack
  }()
  private lazy var iconView: UIImageView = {
    let imageView = UIImageView(image: #imageLiteral(resourceName: "monkey"))
    imageView.backgroundColor = .quattuordecenaryBackground
    imageView.layer.cornerRadius = 6
    imageView.isHidden = true
    return imageView
  }()
  private lazy var spinner: UIActivityIndicatorView = {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.isHidden = true
    return spinner
  }()
  private lazy var modeLabel: UILabel = {
    let label = UILabel()
    label.text = LocalizedString.forKey("initializing")
    label.textColor = .quaternaryText
    label.isHidden = true
    FontMetrics.default.scaleFont(.italicSystemFont(ofSize: 15), bindTo: label)
    return label
  }()
  private lazy var datetimeLabel: UILabel = {
    let label = UILabel()
    label.textColor = .quaternaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 13), bindTo: label)
    return label
  }()

  init() {
    stack.addArrangedSubview(iconView)
    stack.addArrangedSubview(spinner)
    stack.addArrangedSubview(modeLabel)
    stack.addArrangedSubview(datetimeLabel)
    stack.setCustomSpacing(4, after: spinner)
    iconView.snp.makeConstraints { make in
      make.size.equalTo(24)
    }
    spinner.snp.makeConstraints { make in
      make.size.equalTo(20)
    }
  }
}
