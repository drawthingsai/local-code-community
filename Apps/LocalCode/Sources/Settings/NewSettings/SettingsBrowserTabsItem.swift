import Components
import Localization
import SnapKit
import Style
import UIKit

/// Open browser tabs: this chat's first, then a divider and every other chat's. A row opens its
/// tab's window; the minus button closes the tab. With no tabs, the item says so.
struct SettingsBrowserTabsItem: SettingsViewObservable {
  struct Tab: Equatable {
    let id: String
    let title: String
    /// The chat the tab belongs to, for tabs of other chats.
    let threadTitle: String?
  }

  var isEnabled = true
  var isHidden = false
  var currentTabs: [Tab]
  var otherTabs: [Tab]
  var open: (String) -> Void
  var close: (String) -> Void
  private let viewModifier = ViewModifier()
  var viewModifying: any SettingsViewModifying { viewModifier }

  func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? Self else { return false }
    return currentTabs == other.currentTabs && otherTabs == other.otherTabs
      && isEnabled == other.isEnabled && isHidden == other.isHidden
  }

  private final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsBrowserTabsItem
    private struct Row {
      let view: UIView
      let button: UIButton
      let minus: UIButton
    }

    private let stackView = UIStackView()
    var view: UIView? { stackView }
    private var rows = [String: Row]()
    private var open: ((String) -> Void)?
    private var close: ((String) -> Void)?

    private lazy var dividerView: UIView = {
      let view = UIView(frame: .zero)
      let divider = SettingsViewFactory.makeDividerView()
      view.addSubview(divider)
      divider.snp.makeConstraints { make in
        make.leading.trailing.equalToSuperview().inset(4)
        make.top.bottom.equalToSuperview().inset(4)
        make.height.equalTo(1)
      }
      return view
    }()

    private lazy var emptyView: UIView = {
      let iconView = UIImageView(
        image: #imageLiteral(resourceName: "browser-tab-24").withRenderingMode(.alwaysTemplate))
      iconView.tintColor = Theme.current.primaryContentColor
      let label = UILabel(frame: .zero)
      label.text = LocalizedString.forKey("no_open_tabs")
      label.textColor = Theme.current.primaryContentColor
      label.textAlignment = .center
      FontMetrics.default.scaleFont(.systemFont(ofSize: 13), bindTo: label)
      let stackView = UIStackView(arrangedSubviews: [iconView, label])
      stackView.axis = .vertical
      stackView.alignment = .center
      stackView.spacing = 8
      let view = UIView(frame: .zero)
      view.addSubview(stackView)
      stackView.snp.makeConstraints { make in
        make.center.equalToSuperview()
        make.top.greaterThanOrEqualToSuperview().offset(16)
        make.leading.greaterThanOrEqualToSuperview()
      }
      view.snp.makeConstraints { make in
        make.height.equalTo(88)
      }
      return view
    }()

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
      item.currentTabs = newItem.currentTabs
      item.otherTabs = newItem.otherTabs
      item.isEnabled = newItem.isEnabled
      item.isHidden = newItem.isHidden
      item.open = newItem.open
      item.close = newItem.close
      return item
    }

    private func updateRows(_ item: Item) {
      open = item.open
      close = item.close
      let tabs = item.currentTabs + item.otherTabs
      let ids = Set(tabs.map(\.id))
      for id in rows.keys where !ids.contains(id) {
        rows.removeValue(forKey: id)?.view.removeFromSuperview()
      }
      var views = [UIView]()
      for tab in item.currentTabs {
        views.append(row(for: tab, isEnabled: item.isEnabled).view)
      }
      if !item.currentTabs.isEmpty && !item.otherTabs.isEmpty {
        views.append(dividerView)
      }
      for tab in item.otherTabs {
        views.append(row(for: tab, isEnabled: item.isEnabled).view)
      }
      if tabs.isEmpty {
        views.append(emptyView)
      }
      // Rows keep their views; only the order and the divider change.
      guard stackView.arrangedSubviews != views else { return }
      stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
      views.forEach { stackView.addArrangedSubview($0) }
    }

    private func row(for tab: Tab, isEnabled: Bool) -> Row {
      let row: Row
      if let existing = rows[tab.id] {
        row = existing
      } else {
        let view = UIView()
        let button = UIButton(type: .custom)
        button.layer.cornerRadius = Theme.current.itemCornerRadius
        var buttonConfiguration = UIButton.Configuration.bordered()
        buttonConfiguration.image = #imageLiteral(resourceName: "browser-tab-24")
          .withRenderingMode(.alwaysTemplate)
        buttonConfiguration.imagePadding = 8
        buttonConfiguration.titleAlignment = .leading
        buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(
          top: 0, leading: 12, bottom: 0, trailing: 12)
        buttonConfiguration.background.cornerRadius = Theme.current.itemCornerRadius
        buttonConfiguration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
        buttonConfiguration.baseForegroundColor = Theme.current.primaryContentColor
        buttonConfiguration.titleLineBreakMode = .byTruncatingHead
        button.contentHorizontalAlignment = .leading
        button.tintColor = .systemBackground
        button.configuration = buttonConfiguration
        FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: button)
        let minus = UIButton(type: .custom)
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
        configuration.baseForegroundColor = Theme.current.primaryContentColor
        configuration.background.cornerRadius = Theme.current.itemCornerRadius
        configuration.image = #imageLiteral(resourceName: "minus-large")
          .withTintColor(Theme.current.primaryContentColor)
        minus.configuration = configuration
        minus.accessibilityLabel = LocalizedString.forKey("close")
        view.addSubview(button)
        view.addSubview(minus)
        minus.snp.makeConstraints { make in
          make.top.bottom.trailing.equalToSuperview()
          make.size.equalTo(Theme.current.buttonHeight)
        }
        button.snp.makeConstraints { make in
          make.top.bottom.leading.equalToSuperview()
          make.trailing.equalTo(minus.snp.leading).offset(-Theme.current.stackViewItemSpacing)
        }
        let id = tab.id
        button.addAction(UIAction { [weak self] _ in self?.open?(id) }, for: .touchUpInside)
        minus.addAction(UIAction { [weak self] _ in self?.close?(id) }, for: .touchUpInside)
        row = Row(view: view, button: button, minus: minus)
        rows[tab.id] = row
      }
      // Another chat's name follows the page title, dimmer, and stays visible because long
      // titles truncate at the head.
      var title = AttributedString(tab.title)
      if let threadTitle = tab.threadTitle {
        var suffix = AttributedString(" · " + threadTitle)
        suffix.foregroundColor = Theme.current.sectionDescriptionColor
        title += suffix
      }
      row.button.configuration?.attributedTitle = title
      row.button.accessibilityLabel =
        tab.threadTitle.map { "\(tab.title), \($0)" } ?? tab.title
      row.minus.accessibilityValue = tab.title
      row.view.isUserInteractionEnabled = isEnabled
      return row
    }
  }
}
