// TODO: this might be similar to the WizDividerTextDetailCollectionViewCell... we can determine which one to use when a concrete instance is added. commented added to avoid changing the margins here for theme implementation not sure what the press functions are for here
import Dflat
import Localization
import Style
import UIKit

extension SettingsMultilineTextViewItem {
  final class ViewModifier: SettingsViewModifying {
    final class TextView: UITextView {
      var isShiftPressed: Bool = false
      init() {
        super.init(frame: .zero, textContainer: nil)
      }
      required init?(coder: NSCoder) {
        fatalError()
      }
      override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.modifierFlags == .shift }) {
          isShiftPressed = true
        }
        super.pressesBegan(presses, with: event)
      }
      override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.modifierFlags == .shift }) {
          isShiftPressed = false
        }
        super.pressesEnded(presses, with: event)
      }
      override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.modifierFlags == .shift }) {
          isShiftPressed = false
        }
        super.pressesCancelled(presses, with: event)
      }
    }

    public typealias Item = SettingsMultilineTextViewItem
    // views
    public var view: UIView?
    var textView: UITextView?
    var placeholderLabel: UILabel?

    var value: String
    var didChangeText: (String) -> Void

    private let textViewResponder: ObjcTextViewResponder

    public init(value: String, didChangeText: @escaping (String) -> Void) {
      self.value = value
      self.didChangeText = didChangeText
      textViewResponder = ObjcTextViewResponder()
      textViewResponder.viewModifier = self
    }

    public func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {

      let textView = TextView()
      textView.returnKeyType = .done
      let style = NSMutableParagraphStyle()
      style.lineSpacing = 4
      textView.typingAttributes = [NSAttributedString.Key.paragraphStyle: style]
      FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: textView) {
        $0.font = $1
      }
      textView.layer.cornerRadius = 8
      textView.textContainer.lineFragmentPadding = 12
      textView.text = value
      textView.backgroundColor = .tertiaryFill
      textView.textColor = .tertiaryText
      textView.delegate = textViewResponder
      self.textView = textView

      let placeholderLabel = UILabel(frame: .zero)
      FontMetrics.default.scaleFont(.systemFont(ofSize: 15), bindTo: placeholderLabel)
      placeholderLabel.isUserInteractionEnabled = false
      placeholderLabel.alpha = 0.5
      placeholderLabel.textColor = .primaryTextColor
      placeholderLabel.text = item.placeholderText
      placeholderLabel.isHidden = value.count > 0
      self.placeholderLabel = placeholderLabel
      let backgroundView = BorderView(frame: .zero)
      backgroundView.borderColor = UIColor.primaryBorder
      backgroundView.backgroundColor = .tertiaryFill
      backgroundView.layer.cornerRadius = 8
      backgroundView.layer.borderWidth = 1.0

      backgroundView.addSubview(textView)
      backgroundView.snp.makeConstraints { make in
        make.height.equalTo(item.textFieldHeight)
      }
      backgroundView.addSubview(textView)
      textView.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.leading.equalToSuperview()
        make.trailing.equalToSuperview()
      }
      backgroundView.addSubview(placeholderLabel)
      placeholderLabel.snp.makeConstraints { make in
        make.top.equalTo(textView).offset(8)
        make.leading.equalTo(textView).offset(12)
        make.trailing.equalTo(textView).offset(-12)
      }
      self.view = backgroundView

      return ([backgroundView], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      updatingItem.placeholderText = newItem.placeholderText
      updatingItem.value = newItem.value
      updatingItem.didChangeText = newItem.didChangeText
      if let textView = textView {
        if textView.text != newItem.value {
          textView.text = newItem.value
        }
      }
      if updatingItem.textFieldHeight != newItem.textFieldHeight {
        view?.snp.makeConstraints { make in
          make.height.equalTo(newItem.textFieldHeight)
        }
        updatingItem.textFieldHeight = newItem.textFieldHeight
      }
      if let placeholderLabel = placeholderLabel {
        if placeholderLabel.text != newItem.placeholderText {
          placeholderLabel.text = newItem.placeholderText
        }
        if let textView = textView {
          placeholderLabel.isHidden = textView.text.count > 0
        }
      }

      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      value = newItem.value
      return updatingItem
    }
  }
}

public struct SettingsMultilineTextViewItem: SettingsViewObservable {

  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var placeholderText: String
  public var didChangeText: (String) -> Void
  public var value: String
  public var textFieldHeight: Float
  public private(set) var viewModifying: any SettingsViewModifying
  public init(
    value: String,
    placeholderText: String,
    textFieldHeight: Float = 94,
    didChangeText: @escaping (String) -> Void
  ) {
    self.value = value
    self.placeholderText = placeholderText
    self.didChangeText = didChangeText
    self.textFieldHeight = textFieldHeight
    self.viewModifying = ViewModifier(
      value: value, didChangeText: didChangeText)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsMultilineTextViewItem else { return false }
    return self.placeholderText == other.placeholderText && self.value == other.value
      && isHidden == other.isHidden && isEnabled == other.isEnabled
  }
}

extension SettingsMultilineTextViewItem.ViewModifier {

  private final class ObjcTextViewResponder: NSObject, UITextViewDelegate {
    weak var viewModifier: SettingsMultilineTextViewItem.ViewModifier? = nil
    func textViewDidBeginEditing(_ textView: UITextView) {
      guard let viewModifier = viewModifier else { return }
      textView.selectedTextRange = textView.textRange(
        from: textView.beginningOfDocument, to: textView.endOfDocument)
      viewModifier.placeholderLabel?.isHidden = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
      guard let viewModifier = viewModifier else { return }
      if let text = textView.text, text != viewModifier.value {
        viewModifier.didChangeText(text)
      }
    }

    func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard let textView = textView as? TextView else { return false }
      if text == "\n" && !textView.isShiftPressed {
        textView.endEditing(true)
        return false
      }

      guard let viewModifier = viewModifier else { return false }
      let newText = ((textView.text ?? "") as NSString).replacingCharacters(in: range, with: text)
      if newText != viewModifier.value {
        // Push this update to the end of the run loop so the text field is updated already.
        viewModifier.placeholderLabel?.isHidden = newText.count > 0
        DispatchQueue.main.async {
          viewModifier.didChangeText(newText)
        }
      }
      return true
    }
  }
}
