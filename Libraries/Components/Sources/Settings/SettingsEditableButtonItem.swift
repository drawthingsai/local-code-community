//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

public struct SettingsEditableButtonItem<T: Equatable>: SettingsViewObservable {
  final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsEditableButtonItem<T>
    // views
    public var view: UIView?
    public var button: UIButton?

    public var textField: UITextField?
    public var didChangeValue: (String) -> Void

    private var textFieldDelegate: ObjCTextFieldDelegate?

    public init(didChangeValue: @escaping (String) -> Void) {
      self.didChangeValue = didChangeValue
      self.textFieldDelegate = ObjCTextFieldDelegate(viewModifier: self)
    }

    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      let view = UIView()
      self.view = view
      let label = UILabel(frame: .zero)
      label.text = item.title
      label.textColor = Theme.current.primaryContentColor
      FontMetrics.default.scaleFont(Theme.current.secondaryContentFont, bindTo: label)
      view.addSubview(label)
      label.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(1.5 + item.extraTopPadding)
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
      }
      view.addSubview(label)
      let button = SettingsViewFactory.makeDropdownButton(
        alternativeImage: #imageLiteral(resourceName: "pencil").withRenderingMode(.alwaysTemplate))
      self.button = button
      let textField = UITextField(frame: .zero)
      self.textField = textField
      textField.backgroundColor = Theme.current.primaryContentBackgroundColor
      textField.textAlignment = .left
      textField.textColor = Theme.current.primaryContentColor
      textField.layer.cornerRadius = Theme.current.itemCornerRadius
      FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: textField) {
        $0.font = $1
      }
      textField.returnKeyType = .done
      textField.keyboardType = .numberPad
      view.addSubview(textField)
      view.addSubview(button)
      button.snp.makeConstraints { make in
        if let _ = item.title {
          make.top.equalTo(label.snp.bottom).offset(1.5 + Theme.current.stackViewItemSpacing)
        } else {
          make.top.equalToSuperview().offset(item.extraTopPadding)
        }
        make.bottom.equalToSuperview()
        make.height.equalTo(40)
        make.leading.trailing.equalToSuperview()
      }
      textField.snp.makeConstraints { make in
        make.top.bottom.equalTo(button)
        make.leading.equalTo(button).offset(Theme.current.sectionContentMargin)
        make.trailing.equalTo(button).offset(-8)
      }
      button.addAction(
        UIAction { [weak self] _ in
          guard let self = self else { return }
          self.startEditing()
        }, for: .touchUpInside)
      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      updatingItem.value = newItem.value
      button?.setTitle(newItem.buttonTitle, for: .normal)
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }
  }
  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var extraTopPadding: CGFloat
  public var value: T
  public var title: String?
  public var buttonTitle: String
  public private(set) var viewModifying: any SettingsViewModifying
  public init(
    value: T,
    title: String? = nil,
    buttonTitle: String,
    extraTopPadding: CGFloat = 0,
    didChangeValue: @escaping (String) -> Void
  ) {
    self.value = value
    self.title = title
    self.buttonTitle = buttonTitle
    self.extraTopPadding = extraTopPadding
    self.viewModifying = ViewModifier(didChangeValue: didChangeValue)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsEditableButtonItem else { return false }
    return self.value == other.value && isHidden == other.isHidden && isEnabled == other.isEnabled
      && title == other.title
  }
}

extension SettingsEditableButtonItem.ViewModifier {
  public func startEditing() {
    guard let textField = textField else { return }
    textField.delegate = textFieldDelegate
    textField.text = button?.currentTitle
    textField.superview?.bringSubviewToFront(textField)
    textField.becomeFirstResponder()
  }
  private final class ObjCTextFieldDelegate: NSObject, UITextFieldDelegate {
    weak var viewModifier: SettingsEditableButtonItem.ViewModifier?
    init(viewModifier: SettingsEditableButtonItem.ViewModifier) {
      self.viewModifier = viewModifier
    }
    func textFieldDidBeginEditing(_ textField: UITextField) {
      textField.selectedTextRange = textField.textRange(
        from: textField.beginningOfDocument, to: textField.endOfDocument)
    }
    func textFieldDidEndEditing(_ textField: UITextField, reason: UITextField.DidEndEditingReason) {
      textField.superview?.sendSubviewToBack(textField)
      if reason == .committed {
        if textField.text != viewModifier?.button?.currentTitle {
          guard let text = textField.text else { return }
          viewModifier?.didChangeValue(text)
        }
      }
    }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      textField.endEditing(true)
      return false
    }
  }
}
