//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

extension SettingsMonospaceTextItem {
  final class ViewModifier: SettingsViewModifying {
    public typealias Item = SettingsMonospaceTextItem

    public var view: UIView?
    public var label: UILabel?

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      updatingItem.title = newItem.title
      label?.text = newItem.title
      return updatingItem
    }

    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      let view = UIView()
      self.view = view
      let label = UILabel(frame: .zero)
      self.label = label
      label.text = item.title
      label.textColor = Theme.current.rowTitleColor
      FontMetrics.default.scaleFont(
        .monospacedSystemFont(ofSize: 14, weight: .medium), bindTo: label)
      view.addSubview(label)
      label.snp.makeConstraints { make in
        make.center.equalToSuperview()
      }
      view.snp.makeConstraints { make in
        make.height.equalTo(Theme.current.buttonHeight)
      }
      return ([view], self)
    }
  }
}

public struct SettingsMonospaceTextItem: SettingsViewObservable {
  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public private(set) var viewModifying: any SettingsViewModifying
  public var title: String

  public init(title: String) {
    self.title = title
    self.viewModifying = ViewModifier()
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsMonospaceTextItem else { return false }
    return title == other.title && isHidden == other.isHidden && isEnabled == other.isEnabled
  }
}
