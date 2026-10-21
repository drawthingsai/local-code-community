//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

public struct SettingsActionItem<T: Equatable>: SettingsViewObservable {
  private final class ViewModifier: SettingsViewModifying {
    public var view: UIView?

    typealias Item = SettingsActionItem<T>

    private var button: UIButton?

    // actions
    public var currentValue: T?
    public var buttonAction: ((UIView, T) -> Void)?
    public var makeButtonsUI: ((T, UIButton) -> Void)? = nil

    public init(
      buttonAction: ((UIView, T) -> Void)? = nil,
      makeButtonsUI: ((T, UIButton) -> Void)? = nil
    ) {
      self.buttonAction = buttonAction
      self.makeButtonsUI = makeButtonsUI
    }
    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      let view = UIView()
      self.view = view
      currentValue = item.value
      let button = Button(type: .custom)
      self.button = button
      view.addSubview(button)
      button.snp.makeConstraints { make in
        make.leading.trailing.bottom.equalToSuperview()
        make.top.equalToSuperview().offset(item.extraTopPadding)
      }
      if let _ = buttonAction {
        button.addAction(
          UIAction(handler: { [weak self] action in
            guard let self = self, let value = self.currentValue,
              let sourceView = action.sender as? UIView
            else { return }
            self.buttonAction?(sourceView, value)
          }), for: .touchUpInside)
      }
      makeButtonsUI?(item.value, button)
      return ([view], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      updatingItem.value = newItem.value
      currentValue = updatingItem.value
      if let button = button {
        makeButtonsUI?(newItem.value, button)
      }
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
  public private(set) var viewModifying: any SettingsViewModifying

  public init(
    value: T, extraTopPadding: CGFloat = 0,
    buttonAction: ((UIView, T) -> Void)? = nil,
    makeButtonsUI: ((T, UIButton) -> Void)? = nil
  ) {
    self.value = value
    self.extraTopPadding = extraTopPadding
    self.viewModifying = ViewModifier(buttonAction: buttonAction, makeButtonsUI: makeButtonsUI)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsActionItem<T> else { return false }
    return value == other.value && isHidden == other.isHidden && isEnabled == other.isEnabled
      && extraTopPadding == other.extraTopPadding
  }
}
