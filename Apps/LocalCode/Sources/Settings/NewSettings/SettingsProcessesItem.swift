import Components
import Localization
import SnapKit
import Style
import UIKit

/// Running shell commands: this chat's first, then a divider and every other chat's. The divider
/// shows whenever other chats have commands running, even when this chat has none. Rows only
/// show the command; the minus button stops it. With no commands running, the item says so.
struct SettingsProcessesItem: SettingsViewObservable {
  struct Process: Equatable {
    let id: Int
    let command: String
    /// The chat the command belongs to, for commands of other chats.
    let threadTitle: String?
  }

  var isEnabled = true
  var isHidden = false
  var currentProcesses: [Process]
  var otherProcesses: [Process]
  var stop: (Int) -> Void
  private let viewModifier = ViewModifier()
  var viewModifying: any SettingsViewModifying { viewModifier }

  func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? Self else { return false }
    return currentProcesses == other.currentProcesses && otherProcesses == other.otherProcesses
      && isEnabled == other.isEnabled && isHidden == other.isHidden
  }

  private final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsProcessesItem
    private struct Row {
      let view: UIView
      let label: UIButton
      let minus: UIButton
    }

    private let stackView = UIStackView()
    var view: UIView? { stackView }
    private var rows = [Int: Row]()
    private var stop: ((Int) -> Void)?

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
        image: #imageLiteral(resourceName: "histogram-chart-24").withRenderingMode(.alwaysTemplate))
      iconView.tintColor = Theme.current.primaryContentColor
      let label = UILabel(frame: .zero)
      label.text = LocalizedString.forKey("no_running_process")
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
      item.currentProcesses = newItem.currentProcesses
      item.otherProcesses = newItem.otherProcesses
      item.isEnabled = newItem.isEnabled
      item.isHidden = newItem.isHidden
      item.stop = newItem.stop
      return item
    }

    private func updateRows(_ item: Item) {
      stop = item.stop
      let processes = item.currentProcesses + item.otherProcesses
      let ids = Set(processes.map(\.id))
      for id in rows.keys where !ids.contains(id) {
        rows.removeValue(forKey: id)?.view.removeFromSuperview()
      }
      var views = [UIView]()
      for process in item.currentProcesses {
        views.append(row(for: process, isEnabled: item.isEnabled).view)
      }
      // Unlike browser tabs, the divider stays when this chat has nothing running, so other
      // chats' commands never read as this chat's.
      if !item.otherProcesses.isEmpty {
        views.append(dividerView)
      }
      for process in item.otherProcesses {
        views.append(row(for: process, isEnabled: item.isEnabled).view)
      }
      if processes.isEmpty {
        views.append(emptyView)
      }
      // Rows keep their views; only the order and the divider change.
      guard stackView.arrangedSubviews != views else { return }
      stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
      views.forEach { stackView.addArrangedSubview($0) }
    }

    private func row(for process: Process, isEnabled: Bool) -> Row {
      let row: Row
      if let existing = rows[process.id] {
        row = existing
      } else {
        let view = UIView()
        // Styled like the browser tab buttons, but there is nothing to open: no trailing image
        // and no interaction.
        let label = UIButton(type: .custom)
        label.layer.cornerRadius = Theme.current.itemCornerRadius
        var labelConfiguration = UIButton.Configuration.bordered()
        labelConfiguration.titleAlignment = .leading
        labelConfiguration.contentInsets = NSDirectionalEdgeInsets(
          top: 0, leading: 12, bottom: 0, trailing: 12)
        labelConfiguration.background.cornerRadius = Theme.current.itemCornerRadius
        labelConfiguration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
        labelConfiguration.baseForegroundColor = Theme.current.primaryContentColor
        labelConfiguration.titleLineBreakMode = .byTruncatingHead
        label.contentHorizontalAlignment = .leading
        label.tintColor = .systemBackground
        label.configuration = labelConfiguration
        label.isUserInteractionEnabled = false
        label.accessibilityTraits = .staticText
        FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: label)
        let minus = UIButton(type: .custom)
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
        configuration.baseForegroundColor = Theme.current.primaryContentColor
        configuration.background.cornerRadius = Theme.current.itemCornerRadius
        configuration.image = #imageLiteral(resourceName: "minus-large")
          .withTintColor(Theme.current.primaryContentColor)
        minus.configuration = configuration
        minus.accessibilityLabel = LocalizedString.forKey("stop")
        view.addSubview(label)
        view.addSubview(minus)
        minus.snp.makeConstraints { make in
          make.top.bottom.trailing.equalToSuperview()
          make.size.equalTo(Theme.current.buttonHeight)
        }
        label.snp.makeConstraints { make in
          make.top.bottom.leading.equalToSuperview()
          make.trailing.equalTo(minus.snp.leading).offset(-Theme.current.stackViewItemSpacing)
        }
        let id = process.id
        minus.addAction(UIAction { [weak self] _ in self?.stop?(id) }, for: .touchUpInside)
        row = Row(view: view, label: label, minus: minus)
        rows[process.id] = row
      }
      // Another chat's name follows the command, dimmer, and stays visible because long
      // commands truncate at the head.
      var title = AttributedString(process.command)
      if let threadTitle = process.threadTitle {
        var suffix = AttributedString(" · " + threadTitle)
        suffix.foregroundColor = Theme.current.sectionDescriptionColor
        title += suffix
      }
      row.label.configuration?.attributedTitle = title
      row.label.accessibilityLabel =
        process.threadTitle.map { "\(process.command), \($0)" } ?? process.command
      row.minus.accessibilityValue = process.command
      row.view.isUserInteractionEnabled = isEnabled
      return row
    }
  }
}
