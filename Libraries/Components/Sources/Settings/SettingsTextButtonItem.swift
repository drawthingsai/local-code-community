//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

extension SettingsTextButtonItem {
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
    private final class TextViewResponder: NSObject, UITextViewDelegate {
      weak var viewModifier: SettingsTextButtonItem.ViewModifier? = nil
      func textViewDidBeginEditing(_ textView: UITextView) {
        textView.selectedTextRange = textView.textRange(
          from: textView.beginningOfDocument, to: textView.endOfDocument)
      }

      func textViewDidEndEditing(_ textView: UITextView) {
        guard let viewModifier = viewModifier else { return }
        if let text = textView.text, text != viewModifier.value {
          viewModifier.deactivateTextView()
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
          DispatchQueue.main.async {
            viewModifier.didChangeText(newText)
          }
        }
        return true
      }
    }

    public typealias Item = SettingsTextButtonItem
    // views
    public var view: UIView?
    public var button: UIButton?

    var value: String

    var textView: UITextView?
    public var didChangeText: (String) -> Void

    private let textViewResponder: TextViewResponder

    public init(value: String, didChangeText: @escaping (String) -> Void) {
      self.value = value
      self.didChangeText = didChangeText
      self.textViewResponder = TextViewResponder()
      self.textViewResponder.viewModifier = self
    }

    public func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let view = UIView()

      self.view = view
      let buttonView = UIView()
      buttonView.layer.cornerRadius = Theme.current.secondaryItemCornerRadius
      buttonView.clipsToBounds = true

      let button = SettingsViewFactory.makeDropdownButton(
        alternativeImage: #imageLiteral(resourceName: "chevron-down-16"))

      self.button = button
      button.showsMenuAsPrimaryAction = true

      let textView = TextView()
      textView.returnKeyType = .done
      let style = NSMutableParagraphStyle()
      style.lineSpacing = 4
      textView.typingAttributes = [NSAttributedString.Key.paragraphStyle: style]
      FontMetrics.default.scaleFont(
        Theme.current.rowTitleFont, bindTo: textView
      ) {
        $0.font = $1
      }
      textView.textContainerInset = .zero
      textView.textContainer.lineFragmentPadding = 12
      textView.text = item.value
      textView.backgroundColor = .clear
      textView.textColor = Theme.current.rowTitleColor
      textView.tintColor = .colorPalette(for: .blue)
      textView.delegate = textViewResponder
      textView.isSelectable = true
      textView.isEditable = false
      textView.isScrollEnabled = false

      self.textView = textView

      let shadowView = UIView(frame: .zero)
      shadowView.layer.cornerRadius = 16
      shadowView.backgroundColor = .tertiaryBackground
      shadowView.layer.shadowOpacity = 1
      shadowView.layer.shadowColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.04).cgColor
      shadowView.layer.shadowOffset = CGSize(width: 0, height: 3)
      shadowView.layer.shadowRadius = 1
      view.addSubview(shadowView)
      shadowView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      view.addSubview(buttonView)
      buttonView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      buttonView.addSubview(button)
      buttonView.addSubview(textView)

      textView.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview().inset(Theme.current.sectionItemInternalSpacing)
        make.leading.equalToSuperview().offset(8)
        make.trailing.equalToSuperview().offset(-36)
      }
      button.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      deactivateTextView()
      updateButtonMenu(value: item.value, items: item.items)
      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      if updatingItem.value != newItem.value {
        updatingItem.value = newItem.value
        textView?.text = newItem.value
      }
      if updatingItem.items != newItem.items {
        updatingItem.items = newItem.items
        updateButtonMenu(value: updatingItem.value, items: updatingItem.items)
      }
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }
  }
}

public struct SettingsTextButtonItem: SettingsViewObservable {

  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var value: String
  public var items: [String]
  public private(set) var viewModifying: any SettingsViewModifying
  public init(
    value: String,
    items: [String],
    didChangeText: @escaping (String) -> Void
  ) {
    self.value = value
    self.items = items
    self.viewModifying = ViewModifier(value: value, didChangeText: didChangeText)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsTextButtonItem else { return false }
    return self.value == other.value && self.items == other.items && isHidden == other.isHidden
      && isEnabled == other.isEnabled
  }

}

extension SettingsTextButtonItem.ViewModifier {

  public func updateButtonMenu(value: String, items: [String]) {
    var actions = [UIAction]()
    for item in items {
      actions.append(
        UIAction(
          title: String(item),
          state: value == item ? .on : .off
        ) { [weak self] _ in
          guard let self = self else { return }
          didChangeText(item)
        })
    }

    actions.append(
      UIAction(
        title: LocalizedString.forKey("enter_text")
      ) { [weak self] _ in
        guard let self = self else { return }
        self.pressButton()
      })

    button?.menu = UIMenu(children: actions)
  }
  public func activateTextView() {
    guard let textView = textView else { return }
    textView.isEditable = true
    textView.isUserInteractionEnabled = true
    textView.isSelectable = true
    textView.becomeFirstResponder()
  }

  public func deactivateTextView() {
    guard let textView = textView else { return }
    textView.isEditable = false
    textView.isSelectable = false
    textView.isUserInteractionEnabled = false
  }

  public func pressButton() {
    guard let textView = textView else { return }
    textView.delegate = textViewResponder
    activateTextView()
  }

}
