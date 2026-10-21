//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

extension SettingsSwitchItem {
  final class ViewModifier: SettingsViewModifying {
    public typealias Item = SettingsSwitchItem

    public var view: UIView?
    public var label: UILabel?
    public var switchView: UISwitch?
    public var handleValueChange: (Bool) -> Void
    public var incompatibleView: UIView?
    public var stackView: UIStackView?
    public var backgroundView: UIView?

    public init(handleValueChange: @escaping (Bool) -> Void) {
      self.handleValueChange = handleValueChange
    }
    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      switchView?.isEnabled = newItem.isEnabled
      switchView?.isOn = newItem.value
      updatingItem.isEnabled = newItem.isEnabled
      updatingItem.value = newItem.value
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      updatingItem.title = newItem.title
      label?.text = newItem.title
      updatingItem.isIncompatible = newItem.isIncompatible
      SettingsViewFactory.setWarningView(
        isIncompatible: newItem.isIncompatible, animated: true, incompatibleView: incompatibleView,
        backgroundView: backgroundView, stackView: stackView)
      return updatingItem
    }

    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      let view = UIView()
      let stackView = UIStackView()
      stackView.axis = .vertical
      stackView.distribution = .equalSpacing
      stackView.alignment = .fill
      stackView.spacing = 8
      self.view = stackView
      self.stackView = stackView

      let backgroundView = UIView(frame: .zero)
      backgroundView.isUserInteractionEnabled = false
      backgroundView.backgroundColor = Theme.current.primaryContentBackgroundColor
      backgroundView.layer.cornerRadius = 8
      backgroundView.clipsToBounds = true
      self.backgroundView = backgroundView
      view.addSubview(backgroundView)
      backgroundView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      let label = UILabel(frame: .zero)
      self.label = label
      label.text = item.title
      label.textColor = Theme.current.rowTitleColor
      FontMetrics.default.scaleFont(Theme.current.rowTitleFont, bindTo: label)
      view.addSubview(label)
      label.snp.makeConstraints { make in
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
        make.centerY.equalToSuperview()
      }
      let switchView = UISwitch(frame: .zero)
      self.switchView = switchView
      switchView.isEnabled = item.isEnabled
      switchView.onTintColor = Theme.current.controlOnTintColor
      view.addSubview(switchView)
      switchView.isOn = item.value
      switchView.snp.makeConstraints { make in
        make.centerY.equalTo(label)
        make.trailing.equalToSuperview().inset(Theme.current.sectionContentMargin)
      }
      switchView.addAction(
        UIAction { [weak self] _ in
          self?.handleValueChange(switchView.isOn)
        }, for: .valueChanged)
      view.snp.makeConstraints { make in
        make.height.equalTo(Theme.current.buttonHeight)
      }
      let incompatibleView = SettingsViewFactory.makeIncompatibleView()
      self.incompatibleView = incompatibleView

      stackView.addArrangedSubview(view)
      stackView.addArrangedSubview(incompatibleView)
      SettingsViewFactory.setWarningView(
        isIncompatible: item.isIncompatible, animated: false, incompatibleView: incompatibleView,
        backgroundView: backgroundView, stackView: stackView)
      return ([stackView], self)
    }
  }
}

public struct SettingsSwitchItem: SettingsViewObservable {
  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var value: Bool  // switch on/off
  public private(set) var viewModifying: any SettingsViewModifying
  public var title: String
  public var isIncompatible: Bool = false

  public init(
    value: Bool, title: String, isIncompatible: Bool = false,
    handleValueChange: @escaping (Bool) -> Void
  ) {
    self.value = value
    self.title = title
    self.isIncompatible = isIncompatible
    self.viewModifying = ViewModifier(handleValueChange: handleValueChange)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsSwitchItem else { return false }
    return value == other.value && title == other.title && isHidden == other.isHidden
      && isEnabled == other.isEnabled && isIncompatible == other.isIncompatible
  }
}
