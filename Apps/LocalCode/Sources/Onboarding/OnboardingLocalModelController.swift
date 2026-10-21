import SnapKit
import Style
import UIKit

protocol OnboardingLocalModelControllerDelegate: AnyObject {
  func onboardingLocalModelControllerDidSelect(_ controller: OnboardingLocalModelController)
}

/// One downloadable local model under the Local Model card.
final class OnboardingLocalModelController {
  weak var delegate: OnboardingLocalModelControllerDelegate?

  var view: UIView { containerView }
  let model: OnboardingViewController.LocalModelOption
  var isSelected = false {
    didSet { updateSelection() }
  }

  // A stack view hides the card by closing this over it, so the card is not squashed.
  private lazy var containerView: UIView = {
    let view = UIView()
    view.clipsToBounds = true
    return view
  }()
  private lazy var borderView = BorderView.defaultBorderView(cornerRadius: 16)
  private lazy var contentStack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .top
    stack.spacing = 12
    return stack
  }()
  private lazy var indicatorView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    return imageView
  }()
  private lazy var textStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 6
    return stack
  }()
  private lazy var titleRow: UIStackView = {
    let stack = UIStackView()
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
    return stack
  }()
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .primaryText
    // The name and the lighter download size share one label, so both follow the scaled font.
    FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: label) {
      [model] label, font in
      let title = NSMutableAttributedString(string: model.name, attributes: [.font: font])
      if let downloadSize = model.downloadSize {
        title.append(
          NSAttributedString(
            string: " — (\(downloadSize))",
            attributes: [.font: UIFont.systemFont(ofSize: font.pointSize, weight: .light)]))
      }
      label.attributedText = title
    }
    return label
  }()
  private lazy var detailLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.text = model.detail
    label.textColor = .senaryText
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12, weight: .light), bindTo: label)
    return label
  }()
  // Covers the card so the whole surface is one tap target and one accessibility element.
  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    button.accessibilityLabel =
      [model.name, model.downloadSize].compactMap { $0 }.joined(separator: ", ")
      + ". \(model.detail)"
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.onboardingLocalModelControllerDidSelect(self)
      }, for: .touchUpInside)
    return button
  }()

  init(model: OnboardingViewController.LocalModelOption) {
    self.model = model
    updateSelection()
    containerView.addSubview(borderView)
    borderView.addSubview(contentStack)
    borderView.addSubview(button)
    contentStack.addArrangedSubview(indicatorView)
    contentStack.addArrangedSubview(textStack)
    textStack.addArrangedSubview(titleRow)
    textStack.addArrangedSubview(detailLabel)
    titleRow.addArrangedSubview(titleLabel)
    borderView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
      make.bottom.equalToSuperview().priority(.medium)
    }
    contentStack.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(12)
    }
    button.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    indicatorView.snp.makeConstraints { make in
      make.size.equalTo(24)
    }
  }

  private func updateSelection() {
    borderView.backgroundColor = isSelected ? .successBackground : .novemdecenaryBackground
    borderView.borderColor = isSelected ? .successBorder : .secondaryBorder
    indicatorView.image = UIImage(
      named: isSelected ? "download-model-filled-24" : "download-model-24"
    )?.withRenderingMode(.alwaysTemplate)
    indicatorView.tintColor = isSelected ? .successText : .primaryText
    button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
  }
}
