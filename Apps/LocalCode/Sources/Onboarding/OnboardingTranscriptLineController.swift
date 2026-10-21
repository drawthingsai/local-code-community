import SnapKit
import Style
import UIKit

/// One line of the welcome transcript: an optional leading command shown as inline code, the
/// typed text, and a trailing checkmark.
final class OnboardingTranscriptLineController {
  let view = UIView(frame: .zero)
  let text: String
  let hasCheck: Bool

  /// How many characters of the text have been typed so far.
  var typedCount = 0 {
    didSet {
      guard typedCount != oldValue else { return }
      let typed = text.prefix(typedCount)
      codeLabel.text = String(typed.prefix(commandLength))
      textLabel.text = String(typed.dropFirst(commandLength))
      codeBackgroundView.isHidden = commandLength == 0 || typedCount == 0
    }
  }
  private(set) var isChecked = false

  // The command is styled as it types, including prefixes shorter than its full name.
  private let commandLength: Int
  private lazy var contentStack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .center
    stack.spacing = 8
    return stack
  }()
  private lazy var textStack: UIStackView = {
    let stack = UIStackView()
    stack.alignment = .top
    return stack
  }()
  private lazy var codeBackgroundView: UIView = {
    let view = UIView()
    view.backgroundColor = .septenaryFill
    view.layer.cornerRadius = 4
    view.isHidden = true
    return view
  }()
  private lazy var codeLabel: UILabel = {
    let label = UILabel()
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(
      .monospacedSystemFont(ofSize: 15, weight: .light), bindTo: label)
    return label
  }()
  private lazy var textLabel: UILabel = {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .primaryText
    FontMetrics.default.scaleFont(
      .systemFont(ofSize: 15, weight: hasCheck ? .light : .medium), bindTo: label)
    return label
  }()
  private lazy var checkView: UIImageView = {
    let imageView = UIImageView(
      image: UIImage(
        systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)))
    imageView.tintColor = .successText
    imageView.contentMode = .scaleAspectFit
    imageView.alpha = 0
    return imageView
  }()

  /// - Parameter topMargin: Extra space above the line, used to separate sections.
  init(text: String, command: String?, hasCheck: Bool, topMargin: CGFloat) {
    self.text = text
    self.hasCheck = hasCheck
    commandLength = command.flatMap { text.hasPrefix($0) ? $0.count : nil } ?? 0
    view.isAccessibilityElement = true
    view.accessibilityLabel = text
    view.addSubview(contentStack)
    contentStack.addArrangedSubview(textStack)
    textStack.addArrangedSubview(codeBackgroundView)
    textStack.addArrangedSubview(textLabel)
    codeBackgroundView.addSubview(codeLabel)
    contentStack.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(topMargin)
      // The text shares its leading edge with the row under the transcript, as in the chat.
      make.leading.trailing.equalToSuperview()
      make.bottom.equalToSuperview().offset(-4)
    }
    codeLabel.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview()
      make.leading.trailing.equalToSuperview().inset(4)
    }
    codeBackgroundView.setContentHuggingPriority(.required, for: .horizontal)
    codeBackgroundView.setContentCompressionResistancePriority(.required, for: .horizontal)
    guard hasCheck else { return }
    // The checkmark follows the text, so the text hugs and a spacer takes the remaining width.
    textLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    contentStack.addArrangedSubview(checkView)
    contentStack.addArrangedSubview(UIView())
    checkView.snp.makeConstraints { make in
      make.size.equalTo(16)
    }
  }

  func setChecked(_ isChecked: Bool, animated: Bool) {
    guard hasCheck else { return }
    self.isChecked = isChecked
    checkView.layer.removeAllAnimations()
    guard isChecked, animated else {
      checkView.alpha = isChecked ? 1 : 0
      checkView.transform = .identity
      return
    }
    checkView.transform = CGAffineTransform(scaleX: 0.25, y: 0.25)
    UIView.animate(withDuration: 0.12) {
      self.checkView.alpha = 1
      self.checkView.transform = .identity
    }
  }
}
