import Components
import Localization
import SnapKit
import Style
import UIKit

/// Open browser tabs: this chat's first, then a divider and every other chat's. A row opens its
/// tab's window; the minus button closes the tab, and the New Tab row under them opens a blank
/// one in this chat. With no tabs, the item offers to open one for Local Code, where the person
/// can sign in before agents use it.
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
  /// Opens a blank tab in this chat.
  var openNew: () -> Void
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
    private var openNew: (() -> Void)?
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
      let button = UIButton(type: .custom)
      var configuration = UIButton.Configuration.filled()
      configuration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
      configuration.baseForegroundColor = Theme.current.primaryContentColor
      configuration.background.cornerRadius = Theme.current.itemCornerRadius
      configuration.image = #imageLiteral(resourceName: "browser-tab-24").withRenderingMode(
        .alwaysTemplate)
      configuration.imagePlacement = .top
      configuration.imagePadding = 8
      configuration.title = LocalizedString.forKey("open_a_tab_for_local_code")
      button.configuration = configuration
      FontMetrics.default.scaleFont(.systemFont(ofSize: 13), bindTo: button)
      button.addAction(UIAction { [weak self] _ in self?.openNew?() }, for: .touchUpInside)
      button.snp.makeConstraints { make in
        make.height.equalTo(88)
      }
      return button
    }()

    /// Under the tabs, styled as one, its title in italics like the thread list's new thread.
    private lazy var newTabView: UIView = {
      let button = Self.makeRowButton(
        font: .italicSystemFont(ofSize: Theme.current.primaryContentFont.pointSize))
      button.configuration?.title = LocalizedString.forKey("new_browser_tab")
      button.addAction(UIAction { [weak self] _ in self?.openNew?() }, for: .touchUpInside)
      button.snp.makeConstraints { make in
        make.height.equalTo(Theme.current.buttonHeight)
      }
      return button
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
      item.openNew = newItem.openNew
      item.close = newItem.close
      return item
    }

    private func updateRows(_ item: Item) {
      open = item.open
      openNew = item.openNew
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
      views.append(tabs.isEmpty ? emptyView : newTabView)
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
        let button = Self.makeRowButton()
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

    /// Styled as Settings' dropdowns, with a tab's icon before the title.
    private static func makeRowButton(font: UIFont = Theme.current.primaryContentFont)
      -> UIButton
    {
      let button = UIButton(type: .custom)
      button.layer.cornerRadius = Theme.current.itemCornerRadius
      var configuration = UIButton.Configuration.bordered()
      configuration.image = #imageLiteral(resourceName: "browser-tab-24")
        .withRenderingMode(.alwaysTemplate)
      configuration.imagePadding = 8
      configuration.titleAlignment = .leading
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 0, leading: 12, bottom: 0, trailing: 12)
      configuration.background.cornerRadius = Theme.current.itemCornerRadius
      configuration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
      configuration.baseForegroundColor = Theme.current.primaryContentColor
      configuration.titleLineBreakMode = .byTruncatingHead
      button.configuration = configuration
      button.contentHorizontalAlignment = .leading
      button.tintColor = .systemBackground
      FontMetrics.default.scaleFont(font, bindTo: button)
      return button
    }
  }
}
