import SnapKit
import Style
import UIKit

/// An illustrated explanation of one Local Code concept on the last onboarding page.
final class OnboardingOverviewController {
  var view: UIView { stack }

  /// Stacks the illustration above the text when the page is too narrow for both.
  var isCompact = false {
    didSet {
      guard isCompact != oldValue else { return }
      stack.axis = isCompact ? .vertical : .horizontal
      if isCompact {
        illustrationWidthConstraint?.deactivate()
      } else {
        illustrationWidthConstraint?.activate()
      }
    }
  }

  var title: String {
    get { titleLabel.text ?? "" }
    set { titleLabel.text = newValue }
  }
  var detail: String {
    didSet {
      // Swap only the characters so the text keeps its scaled font and line height.
      let text = NSMutableAttributedString(
        attributedString: detailLabel.attributedText ?? NSAttributedString())
      text.replaceCharacters(in: NSRange(location: 0, length: text.length), with: detail)
      detailLabel.attributedText = text
    }
  }

  private var illustrationWidthConstraint: Constraint?
  private lazy var stack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .top
    stack.spacing = 16
    return stack
  }()
  private lazy var illustrationView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = false
    return imageView
  }()
  private lazy var textStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 8
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    return stack
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 18, weight: .medium), bindTo: label)
    return label
  }()
  private lazy var detailLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = detail
    label.textColor = .senaryText
    // Lines are 20pt apart at the 12pt design size and grow with the scaled font.
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .light), bindTo: label) {
      label, font in
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.minimumLineHeight = 20 * font.pointSize / 12
      paragraphStyle.maximumLineHeight = 20 * font.pointSize / 12
      label.attributedText = NSAttributedString(
        string: label.text ?? "", attributes: [.font: font, .paragraphStyle: paragraphStyle])
    }
    return label
  }()

  init(image: UIImage?, title: String, detail: String) {
    self.detail = detail
    illustrationView.image = image
    titleLabel.text = title
    stack.addArrangedSubview(illustrationView)
    stack.addArrangedSubview(textStack)
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(detailLabel)
    illustrationView.snp.makeConstraints { make in
      make.height.equalTo(illustrationView.snp.width).multipliedBy(3.0 / 4.0)
      illustrationWidthConstraint = make.width.equalTo(400).priority(.high).constraint
      make.width.lessThanOrEqualTo(stack)
    }
  }
}
