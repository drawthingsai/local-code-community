//Created 12/11/23

import UIKit

public protocol SettingsViewModifying: AnyObject {
  associatedtype Item: SettingsViewObservable
  var view: UIView? { get }
  // make views from a given item that the view modifier knows how to handle
  func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying)

  // apply a same-type requirement on the params
  func updateViews(
    _ updatingItem: Item,
    with newItem: Item
  ) -> Item
}

extension SettingsViewModifying {
  public var hideView: Bool {
    get {
      return view?.isHidden ?? true
    }
    set {
      guard hideView != newValue, let view = view else { return }
      let viewChange = {
        view.isHidden = newValue
        view.alpha = newValue ? 0 : 1
      }
      guard view.window != nil else {
        viewChange()
        return
      }
      UIView.animate(
        withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]
      ) {
        viewChange()
        view.superview?.layoutIfNeeded()
      }
    }
  }
}

extension SettingsViewModifying {
  public func makeViews(from item: any SettingsViewObservable) -> (
    [UIView], any SettingsViewModifying
  ) {
    guard let item = item as? Item else { return ([], self) }
    return makeViews(from: item)
  }
  public func updateViews(
    _ updatingItem: any SettingsViewObservable,
    with newItem: any SettingsViewObservable
  ) -> any SettingsViewObservable {
    guard let updatingItem = updatingItem as? Item, let newItem = newItem as? Item else {
      return updatingItem
    }
    return updateViews(updatingItem, with: newItem)
  }
}
