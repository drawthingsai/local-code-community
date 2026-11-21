import Components
import SnapKit
import Style
import UIKit

protocol OnboardingChoiceControllerDelegate: AnyObject {
  func onboardingChoiceControllerDidSelect(_ controller: OnboardingChoiceController)
}

/// One of a row of choices on the reading style page: a glyph that shows the choice, over its
/// name.
final class OnboardingChoiceController {
  weak var delegate: OnboardingChoiceControllerDelegate?

  var view: UIView { borderView }
  var isSelected = false {
    didSet { updateSelection() }
  }

  private let titleFontFamily: String?
  private lazy var borderView = BorderView.defaultBorderView(cornerRadius: 12)
  private lazy var titleLabel: UILabel = {
    let label = UILabel()
    label.textAlignment = .center
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.8
    label.isAccessibilityElement = false
    FontMetrics.default.scaleFont(.systemFont(ofSize: 11, weight: .regular), bindTo: label) {
      [titleFontFamily] in
      $0.font = MarkdownFonts.default.textFont(replacing: $1, family: titleFontFamily)
    }
    return label
  }()
  // Covers the tile so the whole surface is one tap target and one accessibility element.
  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.onboardingChoiceControllerDidSelect(self)
      }, for: .touchUpInside)
    return button
  }()

  /// - Parameter titleFontFamily: The font family the name is set in, for a choice of font.
  ///   Nil is the system font.
  init(title: String, titleFontFamily: String? = nil, glyphView: UIView) {
    self.titleFontFamily = titleFontFamily
    titleLabel.text = title
    button.accessibilityLabel = title
    glyphView.isUserInteractionEnabled = false
    borderView.addSubview(glyphView)
    borderView.addSubview(titleLabel)
    borderView.addSubview(button)
    borderView.snp.makeConstraints { make in
      make.height.equalTo(72)
    }
    // The glyph keeps its place above the name whatever its size.
    glyphView.snp.makeConstraints { make in
      make.centerX.equalToSuperview()
      make.centerY.equalTo(borderView.snp.top).offset(28)
    }
    titleLabel.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(6)
      make.bottom.equalToSuperview().offset(-10)
    }
    button.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    updateSelection()
  }

  private func updateSelection() {
    borderView.backgroundColor = isSelected ? .novemdecenaryBackground : .tertiaryBackground
    borderView.borderColor = isSelected ? .senaryText : .primaryBorder
    titleLabel.textColor = isSelected ? .primaryText : .senaryText
    button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
  }
}
