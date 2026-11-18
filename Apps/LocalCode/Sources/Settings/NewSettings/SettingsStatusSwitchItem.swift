import Components
import Localization
import SnapKit
import Style
import UIKit

/// A chat app's Enable switch, which also shows how the app is connected, as the server switch does
/// in Draw Things: a dot, and the status in place of "Enable" while it's on. Why a connection failed
/// shows in a warning line under it.
struct SettingsStatusSwitchItem: SettingsViewObservable {
  enum Status: Equatable {
    /// The switch is off.
    case off
    /// Connecting, or waiting on something to set up.
    case pending
    case connected
    case failed
  }

  final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsStatusSwitchItem
    var view: UIView?
    private var stackView: UIStackView?
    private var backgroundView: UIView?
    private var dotView: UIView?
    private var titleLabel: UILabel?
    private var switchView: UISwitch?
    private var warningView: UIView?
    private let handleValueChange: (Bool) -> Void

    init(handleValueChange: @escaping (Bool) -> Void) {
      self.handleValueChange = handleValueChange
    }

    func updateViews(_ updatingItem: Item, with newItem: Item) -> Item {
      var updatingItem = updatingItem
      updatingItem.value = newItem.value
      updatingItem.status = newItem.status
      updatingItem.statusText = newItem.statusText
      updatingItem.warning = newItem.warning
      apply(newItem, animated: true)
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }

    func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let stackView = UIStackView()
      stackView.axis = .vertical
      stackView.alignment = .fill
      stackView.spacing = 8
      self.stackView = stackView
      self.view = stackView
      let row = UIView()
      let backgroundView = UIView(frame: .zero)
      backgroundView.isUserInteractionEnabled = false
      backgroundView.backgroundColor = Theme.current.primaryContentBackgroundColor
      backgroundView.layer.cornerRadius = 8
      backgroundView.clipsToBounds = true
      self.backgroundView = backgroundView
      row.addSubview(backgroundView)
      backgroundView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      let dotView = UIView()
      dotView.layer.cornerRadius = 5
      dotView.layer.borderWidth = 2
      self.dotView = dotView
      row.addSubview(dotView)
      dotView.snp.makeConstraints { make in
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
        make.centerY.equalToSuperview()
        make.size.equalTo(10)
      }
      let switchView = UISwitch(frame: .zero)
      switchView.onTintColor = Theme.current.controlOnTintColor
      switchView.addAction(
        UIAction { [weak self] _ in
          self?.handleValueChange(switchView.isOn)
        }, for: .valueChanged)
      self.switchView = switchView
      row.addSubview(switchView)
      switchView.snp.makeConstraints { make in
        make.centerY.equalToSuperview()
        make.trailing.equalToSuperview().inset(Theme.current.sectionContentMargin)
      }
      let titleLabel = UILabel()
      titleLabel.textColor = Theme.current.rowTitleColor
      FontMetrics.default.scaleFont(Theme.current.rowTitleFont, bindTo: titleLabel)
      // A long status truncates rather than push the switch out.
      titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      self.titleLabel = titleLabel
      row.addSubview(titleLabel)
      titleLabel.snp.makeConstraints { make in
        make.leading.equalTo(dotView.snp.trailing).offset(6)
        make.centerY.equalToSuperview()
        make.trailing.lessThanOrEqualTo(switchView.snp.leading).offset(-8)
      }
      row.snp.makeConstraints { make in
        make.height.equalTo(Theme.current.buttonHeight)
      }
      let warningView = SettingsViewFactory.makeIncompatibleView()
      warningView.isHidden = true
      self.warningView = warningView
      stackView.addArrangedSubview(row)
      stackView.addArrangedSubview(warningView)
      apply(item, animated: false)
      return ([stackView], self)
    }

    private func apply(_ item: Item, animated: Bool) {
      switchView?.isOn = item.value
      let color: UIColor
      switch item.status {
      case .off: color = .disabled
      case .pending: color = .warningText
      case .connected: color = .successText
      case .failed: color = .errorText
      }
      dotView?.layer.borderColor = color.cgColor
      dotView?.backgroundColor = item.status == .off ? .clear : color
      titleLabel?.text = item.status == .off ? LocalizedString.forKey("enable") : item.statusText
      SettingsViewFactory.setWarningView(
        item.warning, animated: animated, incompatibleView: warningView,
        backgroundView: backgroundView, stackView: stackView)
    }
  }

  var isHidden = false
  var isEnabled = true
  var value: Bool
  var status: Status
  /// What the row says while the switch is on, such as "Connected as @bot".
  var statusText: String
  /// Why the connection failed.
  var warning: SettingsWarning?
  private(set) var viewModifying: any SettingsViewModifying

  init(
    value: Bool, status: Status, statusText: String, warning: SettingsWarning?,
    handleValueChange: @escaping (Bool) -> Void
  ) {
    self.value = value
    self.status = status
    self.statusText = statusText
    self.warning = warning
    self.viewModifying = ViewModifier(handleValueChange: handleValueChange)
  }

  func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsStatusSwitchItem else { return false }
    return value == other.value && status == other.status && statusText == other.statusText
      && warning == other.warning && isHidden == other.isHidden && isEnabled == other.isEnabled
  }
}
