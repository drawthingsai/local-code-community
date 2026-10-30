import Components
import Localization
import SnapKit
import Style
import UIKit

/// The devices this one works with (a phone's Macs, a Mac's phones and iPads), each with its
/// status, and any device waiting to join or disconnected. A row's menu has what can be done with
/// that device. With no devices, the item says so.
struct SettingsLinkedDevicesItem: SettingsViewObservable {
  enum Action: Equatable {
    case disconnect
    /// Lets a device waiting to join in.
    case allow
    /// Refuses a device waiting to join.
    case deny
    /// Lets a disconnected device back.
    case reconnect
  }

  struct Device: Equatable {
    let id: String
    let name: String
    /// Online, busy, offline, waiting to join or disconnected.
    let status: String
    let symbolName: String
    /// In menu order.
    let actions: [Action]
  }

  var isEnabled = true
  var isHidden = false
  var devices: [Device]
  var perform: (Action, String) -> Void
  private let viewModifier = ViewModifier()
  var viewModifying: any SettingsViewModifying { viewModifier }

  func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? Self else { return false }
    return devices == other.devices && isEnabled == other.isEnabled && isHidden == other.isHidden
  }

  private final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsLinkedDevicesItem
    private struct Row {
      let view: UIView
      let label: UIButton
      let menuButton: UIButton
    }

    private let stackView = UIStackView()
    var view: UIView? { stackView }
    private var rows = [String: Row]()
    private var perform: ((Action, String) -> Void)?

    private lazy var emptyView: UIView = {
      let label = UILabel(frame: .zero)
      label.text = LocalizedString.forKey(
        DeviceLinkService.canServe ? "device_link_no_phones" : "device_link_no_macs")
      label.textColor = Theme.current.primaryContentColor
      label.textAlignment = .center
      label.numberOfLines = 0
      FontMetrics.default.scaleFont(.systemFont(ofSize: 13), bindTo: label)
      let view = UIView(frame: .zero)
      view.addSubview(label)
      label.snp.makeConstraints { make in
        make.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8))
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
      item.devices = newItem.devices
      item.isEnabled = newItem.isEnabled
      item.isHidden = newItem.isHidden
      item.perform = newItem.perform
      return item
    }

    private func updateRows(_ item: Item) {
      perform = item.perform
      let ids = Set(item.devices.map(\.id))
      for id in rows.keys where !ids.contains(id) {
        rows.removeValue(forKey: id)?.view.removeFromSuperview()
      }
      var views = item.devices.map { row(for: $0, isEnabled: item.isEnabled).view }
      if item.devices.isEmpty {
        views.append(emptyView)
      }
      // Rows keep their views; only the order changes.
      guard stackView.arrangedSubviews != views else { return }
      stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
      views.forEach { stackView.addArrangedSubview($0) }
    }

    private func row(for device: Device, isEnabled: Bool) -> Row {
      let row: Row
      if let existing = rows[device.id] {
        row = existing
      } else {
        let view = UIView()
        // Styled like the process rows: the device is shown, not opened.
        let label = UIButton(type: .custom)
        label.layer.cornerRadius = Theme.current.itemCornerRadius
        var labelConfiguration = UIButton.Configuration.bordered()
        labelConfiguration.titleAlignment = .leading
        labelConfiguration.imagePadding = 8
        labelConfiguration.titlePadding = 2
        labelConfiguration.contentInsets = NSDirectionalEdgeInsets(
          top: 6, leading: 12, bottom: 6, trailing: 12)
        labelConfiguration.background.cornerRadius = Theme.current.itemCornerRadius
        labelConfiguration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
        labelConfiguration.baseForegroundColor = Theme.current.primaryContentColor
        labelConfiguration.titleLineBreakMode = .byTruncatingTail
        label.contentHorizontalAlignment = .leading
        label.tintColor = .systemBackground
        label.configuration = labelConfiguration
        label.isUserInteractionEnabled = false
        label.accessibilityTraits = .staticText
        FontMetrics.default.scaleFont(Theme.current.primaryContentFont, bindTo: label)
        let menuButton = UIButton(type: .custom)
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Theme.current.primaryContentBackgroundColor
        configuration.baseForegroundColor = Theme.current.primaryContentColor
        configuration.background.cornerRadius = Theme.current.itemCornerRadius
        configuration.image = UIImage(systemName: "ellipsis")
        menuButton.configuration = configuration
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = LocalizedString.forKey("device_link_device_actions")
        view.addSubview(label)
        view.addSubview(menuButton)
        // The status goes under the name, so a row can be taller than the menu button.
        menuButton.snp.makeConstraints { make in
          make.trailing.centerY.equalToSuperview()
          make.size.equalTo(Theme.current.buttonHeight)
        }
        label.snp.makeConstraints { make in
          make.top.bottom.leading.equalToSuperview()
          make.height.greaterThanOrEqualTo(Theme.current.buttonHeight)
          make.trailing.equalTo(menuButton.snp.leading).offset(-Theme.current.stackViewItemSpacing)
        }
        row = Row(view: view, label: label, menuButton: menuButton)
        rows[device.id] = row
      }
      // The status goes under the name, smaller and dimmer.
      row.label.configuration?.title = device.name
      var subtitle = AttributedString(device.status)
      subtitle.foregroundColor = Theme.current.sectionDescriptionColor
      subtitle.font = .systemFont(ofSize: 12)
      row.label.configuration?.attributedSubtitle = subtitle
      row.label.configuration?.image = UIImage(systemName: device.symbolName)
      row.label.accessibilityLabel = "\(device.name), \(device.status)"
      let id = device.id
      let actions = device.actions.map { action -> UIAction in
        let title: String
        let symbolName: String
        var attributes = UIMenuElement.Attributes()
        switch action {
        case .disconnect:
          title = LocalizedString.forKey("device_link_disconnect_device")
          symbolName = "minus.circle"
          attributes = .destructive
        case .allow:
          title = LocalizedString.forKey("device_link_allow_device")
          symbolName = "checkmark.circle"
        case .deny:
          title = LocalizedString.forKey("device_link_deny_device")
          symbolName = "xmark.circle"
          attributes = .destructive
        case .reconnect:
          title = LocalizedString.forKey("device_link_reconnect_device")
          symbolName = "arrow.clockwise.circle"
        }
        return UIAction(
          title: title, image: UIImage(systemName: symbolName), attributes: attributes
        ) { [weak self] _ in self?.perform?(action, id) }
      }
      row.menuButton.menu = UIMenu(title: device.name, children: actions)
      row.menuButton.isHidden = actions.isEmpty
      row.menuButton.accessibilityValue = device.name
      row.view.isUserInteractionEnabled = isEnabled
      return row
    }
  }
}
