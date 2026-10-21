import Components
import Localization
import SnapKit
import Style
import UIKit

struct SettingsPermittedDirectoriesItem: SettingsViewObservable {
  var isEnabled = true
  var isHidden = false
  var value: [String: Bool]
  var setEnabled: (String, Bool) -> Void
  var remove: (String) -> Void
  private let viewModifier = ViewModifier()
  var viewModifying: any SettingsViewModifying { viewModifier }

  func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? Self else { return false }
    return value == other.value && isEnabled == other.isEnabled && isHidden == other.isHidden
  }

  private final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsPermittedDirectoriesItem
    private struct Row {
      let view: UIView
      let dropdown: UIButton
      let tooltip: ToolTipController
    }

    private let stackView = UIStackView()
    var view: UIView? { stackView }
    private var rows = [String: Row]()
    private var setEnabled: ((String, Bool) -> Void)?
    private var remove: ((String) -> Void)?

    func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      stackView.axis = .vertical
      stackView.alignment = .fill
      stackView.spacing = Theme.current.stackViewItemSpacing
      updateRows(item)
      hideView = item.isHidden
      return ([stackView], self)
    }

    func updateViews(_ updatingItem: Item, with newItem: Item) -> Item {
      updateRows(newItem)
      hideView = newItem.isHidden
      var item = updatingItem
      item.value = newItem.value
      item.isEnabled = newItem.isEnabled
      item.isHidden = newItem.isHidden
      item.setEnabled = newItem.setEnabled
      item.remove = newItem.remove
      return item
    }

    private func updateRows(_ item: Item) {
      setEnabled = item.setEnabled
      remove = item.remove
      for path in rows.keys where item.value[path] == nil {
        rows.removeValue(forKey: path)?.view.removeFromSuperview()
      }
      for (index, path) in item.value.keys.sorted().enumerated() {
        let row: Row
        if let existing = rows[path] {
          row = existing
        } else {
          let view = UIView()
          let dropdown = SettingsViewFactory.makeDropdownButton(
            titleLineBreakMode: .byTruncatingHead)
          dropdown.showsMenuAsPrimaryAction = true
          let minus = UIButton(type: .custom)
          var configuration = UIButton.Configuration.filled()
          configuration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
          configuration.baseForegroundColor = Theme.current.primaryContentColor
          configuration.background.cornerRadius = Theme.current.itemCornerRadius
          configuration.image = #imageLiteral(resourceName: "minus-large")
            .withTintColor(Theme.current.primaryContentColor)
          minus.configuration = configuration
          minus.accessibilityLabel = LocalizedString.forKey("remove")
          minus.accessibilityValue = path
          view.addSubview(dropdown)
          view.addSubview(minus)
          minus.snp.makeConstraints { make in
            make.top.bottom.trailing.equalToSuperview()
            make.size.equalTo(Theme.current.buttonHeight)
          }
          dropdown.snp.makeConstraints { make in
            make.top.bottom.leading.equalToSuperview()
            make.trailing.equalTo(minus.snp.leading).offset(-Theme.current.stackViewItemSpacing)
          }
          minus.addAction(UIAction { [weak self] _ in self?.remove?(path) }, for: .touchUpInside)
          let tooltip = ToolTipController(
            control: dropdown, containerView: view, toolTip: path, position: .top,
            maxWidth: 224, ancestorOf: 6)
          row = Row(view: view, dropdown: dropdown, tooltip: tooltip)
          rows[path] = row
          stackView.insertArrangedSubview(view, at: index)
        }
        let isEnabled = item.value[path] == true
        row.dropdown.setTitle(isEnabled ? path : LocalizedString.forKey("disabled"), for: .normal)
        row.dropdown.accessibilityLabel = path
        row.dropdown.accessibilityValue = LocalizedString.forKey(isEnabled ? "enabled" : "disabled")
        row.dropdown.menu = UIMenu(children: [
          UIAction(title: path, state: isEnabled ? .on : .off) { [weak self] _ in
            self?.setEnabled?(path, true)
          },
          UIAction(title: LocalizedString.forKey("disabled"), state: isEnabled ? .off : .on) {
            [weak self] _ in self?.setEnabled?(path, false)
          },
        ])
        row.view.isUserInteractionEnabled = item.isEnabled
      }
    }
  }
}
