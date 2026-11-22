//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

extension SettingsTextFieldItem {
  final class ViewModifier: SettingsViewModifying {
    public typealias Item = SettingsTextFieldItem
    // views
    public var view: UIView?
    public var incompatibleView: UIView?
    public var textField: UITextField?
    public var stackView: UIStackView?
    public var textView: UIView?

    public var value: String
    public var didChangeText: (String) -> Void

    // A secret shows its full value only while it is being edited.
    private let isSecret: Bool
    private let textFieldResponder: ObjcTextFieldResponder

    public init(value: String, isSecret: Bool, didChangeText: @escaping (String) -> Void) {
      self.didChangeText = didChangeText
      self.value = value
      self.isSecret = isSecret
      textFieldResponder = ObjcTextFieldResponder()
      textFieldResponder.viewModifier = self
    }

    // A fixed count of bullets hides the length, and the last four characters tell one value
    // from another. A short value shows none of its characters. Whitespace around a pasted value
    // is not part of it.
    private static func maskedText(_ value: String) -> String {
      let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return "" }
      let bullets = String(repeating: "•", count: 8)
      return value.count >= 12 ? bullets + value.suffix(4) : bullets
    }

    public func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let textView = UIView()
      textView.layer.cornerRadius = 8

      self.textView = textView
      let stackView = UIStackView()
      stackView.axis = .vertical
      stackView.distribution = .equalSpacing
      stackView.alignment = .fill
      stackView.spacing = 8
      self.view = stackView
      self.stackView = stackView

      let incompatibleView = SettingsViewFactory.makeIncompatibleView()
      self.incompatibleView = incompatibleView

      let textField = UITextField(frame: .zero)
      self.textField = textField
      textField.backgroundColor = .tertiaryFill
      textField.textAlignment = .left
      textField.textColor = .tertiaryText
      textField.layer.cornerRadius = 8
      textField.text = isSecret ? Self.maskedText(value) : value
      textField.placeholder = item.placeholderText
      textField.delegate = textFieldResponder
      if isSecret {
        // Monospace puts the bullets and the characters on one grid. The placeholder is prose,
        // so it keeps the proportional font.
        FontMetrics.default.scaleFont(
          .monospacedSystemFont(ofSize: 14, weight: .regular), bindTo: textField
        ) {
          $0.font = $1
          $0.attributedPlaceholder = NSAttributedString(
            string: $0.placeholder ?? "",
            attributes: [.font: UIFont.systemFont(ofSize: $1.pointSize)])
        }
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
      } else {
        FontMetrics.default.scaleFont(.systemFont(ofSize: 14), bindTo: textField) {
          $0.font = $1
        }
      }
      textField.returnKeyType = .done

      textView.addSubview(textField)
      let backgroundView = BorderView(frame: .zero)
      backgroundView.borderColor = UIColor.primaryBorder
      backgroundView.backgroundColor = .tertiaryFill
      backgroundView.layer.cornerRadius = 8
      backgroundView.layer.borderWidth = 1.0

      textView.addSubview(backgroundView)
      backgroundView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
        make.height.equalTo(40)
      }
      backgroundView.addSubview(textField)
      textField.snp.makeConstraints { make in
        make.top.bottom.equalToSuperview()
        make.leading.equalToSuperview().offset(12)
        make.trailing.equalToSuperview().offset(-12)
      }
      stackView.addArrangedSubview(textView)
      stackView.addArrangedSubview(incompatibleView)
      SettingsViewFactory.setWarningView(
        isIncompatible: item.isIncompatible, animated: false, incompatibleView: incompatibleView,
        backgroundView: textView, stackView: stackView)

      return ([stackView], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      updatingItem.placeholderText = newItem.placeholderText
      updatingItem.value = newItem.value
      updatingItem.didChangeText = newItem.didChangeText
      if let textField = textField {
        let text =
          isSecret && !textField.isEditing ? Self.maskedText(newItem.value) : newItem.value
        if textField.text != text {
          textField.text = text
        }
        if textField.placeholder != newItem.placeholderText {
          if isSecret {
            textField.attributedPlaceholder = NSAttributedString(
              string: newItem.placeholderText,
              attributes: [.font: UIFont.systemFont(ofSize: textField.font?.pointSize ?? 14)])
          } else {
            textField.placeholder = newItem.placeholderText
          }
        }
      }
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      value = newItem.value
      updatingItem.isIncompatible = newItem.isIncompatible
      SettingsViewFactory.setWarningView(
        isIncompatible: newItem.isIncompatible, animated: true, incompatibleView: incompatibleView,
        backgroundView: textView, stackView: stackView)
      return updatingItem
    }
  }
}

public struct SettingsTextFieldItem: SettingsViewObservable {

  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var placeholderText: String
  public var isIncompatible: Bool = false
  public var didChangeText: (String) -> Void
  public var value: String
  public private(set) var viewModifying: any SettingsViewModifying
  public init(
    value: String,
    placeholderText: String,
    isSecret: Bool = false,
    isIncompatible: Bool = false,
    didChangeText: @escaping (String) -> Void
  ) {
    self.value = value
    self.placeholderText = placeholderText
    self.isIncompatible = isIncompatible
    self.didChangeText = didChangeText
    self.viewModifying = ViewModifier(
      value: value, isSecret: isSecret, didChangeText: didChangeText)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsTextFieldItem else { return false }
    return self.placeholderText == other.placeholderText && self.value == other.value
      && isHidden == other.isHidden && isEnabled == other.isEnabled
      && isIncompatible == other.isIncompatible
  }
}

extension SettingsTextFieldItem.ViewModifier {

  private final class ObjcTextFieldResponder: NSObject, UITextFieldDelegate {
    weak var viewModifier: SettingsTextFieldItem.ViewModifier? = nil
    func textFieldDidBeginEditing(_ textField: UITextField) {
      if let viewModifier = viewModifier, viewModifier.isSecret {
        textField.text = viewModifier.value
      }
      textField.selectedTextRange = textField.textRange(
        from: textField.beginningOfDocument, to: textField.endOfDocument)
    }
    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
      textField.superview?.sendSubviewToBack(textField)
      guard let viewModifier = viewModifier else { return }
      if reason == .committed, let text = textField.text, text != viewModifier.value {
        viewModifier.didChangeText(text)
      }
      if viewModifier.isSecret {
        // The field no longer holds the text, so keep it here for the next edit. The owner may
        // not report the change back, for example when it only trimmed whitespace.
        let text = textField.text ?? ""
        viewModifier.value = text
        textField.text = SettingsTextFieldItem.ViewModifier.maskedText(text)
      }
    }
    func textField(
      _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
      replacementString string: String
    ) -> Bool {
      guard let viewModifier = viewModifier else { return false }
      // The masked text is never a value, so it cannot be edited into one.
      guard !viewModifier.isSecret || textField.isEditing else { return false }
      let newText = ((textField.text ?? "") as NSString).replacingCharacters(
        in: range, with: string)
      if newText != viewModifier.value {
        // Push this update to the end of the run loop so the text field is updated already.
        // Note that this implementation is more stable if we use asyncAfter rather than
        // async for some internal implementation issues with UIKit.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
          viewModifier.didChangeText(newText)
        }
      }
      return true
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      textField.endEditing(true)
      return false
    }
  }
}
