//Created 11/13/23

import Dflat
import Localization
import Style
import UIKit

public struct SettingsButtonItem<T: Equatable>: SettingsViewObservable {
  private final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsButtonItem<T>

    public var buttonImage: UIImage = #imageLiteral(resourceName: "chevron-down-16")
      .withRenderingMode(.alwaysTemplate)
    // views
    public var view: UIView?
    public var stackView: UIStackView?
    public var button: UIButton?
    public var buttonImageView: UIImageView?
    /// Over the trailing image, with its own menu, while the rest of the button keeps its action.
    public var accessoryButton: UIButton?
    public var incompatibleView: UIView?
    public var titleLabel: UILabel?
    public var toolTipController: ToolTipController?

    // actions
    public var currentValue: T?
    public var buttonAction: ((UIView, T) -> Void)?
    public var makeButtonsUI: ((T, UIButton?) -> Void)? = nil
    public var accessoryMenu: ((T) -> UIMenu?)? = nil

    public init(
      buttonAction: ((UIView, T) -> Void)? = nil,
      buttonImage: UIImage? = nil,
      makeButtonsUI: ((T, UIButton?) -> Void)? = nil,
      accessoryMenu: ((T) -> UIMenu?)? = nil
    ) {
      self.buttonAction = buttonAction
      self.makeButtonsUI = makeButtonsUI
      self.accessoryMenu = accessoryMenu
      if let buttonImage {
        self.buttonImage = buttonImage
      }
    }
    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      currentValue = item.value
      let buttonView = UIView()
      let stackView = UIStackView()
      stackView.axis = .vertical
      stackView.distribution = .equalSpacing
      stackView.alignment = .fill
      stackView.spacing = 8
      self.view = stackView
      self.stackView = stackView
      let label = UILabel(frame: .zero)
      label.text = item.title
      label.textColor = Theme.current.secondaryContentColor
      FontMetrics.default.scaleFont(Theme.current.secondaryContentFont, bindTo: label)
      self.titleLabel = label
      buttonView.addSubview(label)
      label.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(1.5 + item.extraTopPadding)
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
      }
      let button = SettingsViewFactory.makeDropdownButton(
        alternativeImage: buttonImage,
        onImageViewCreated: { self.buttonImageView = $0 })
      self.button = button
      button.showsMenuAsPrimaryAction = item.showsMenuAsPrimaryAction
      buttonView.addSubview(button)
      let incompatibleView = SettingsViewFactory.makeIncompatibleView()
      incompatibleView.isHidden = true
      self.incompatibleView = incompatibleView

      stackView.addArrangedSubview(buttonView)
      stackView.addArrangedSubview(incompatibleView)
      button.snp.makeConstraints { make in
        make.leading.trailing.equalToSuperview()
        if let _ = item.title {
          make.top.equalTo(label.snp.bottom).offset(1.5 + Theme.current.stackViewItemSpacing)
        } else {
          make.top.equalToSuperview().offset(item.extraTopPadding)
        }
        make.bottom.equalToSuperview()
        make.height.equalTo(Theme.current.buttonHeight)
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
      if accessoryMenu != nil {
        let accessoryButton = UIButton(type: .custom)
        accessoryButton.showsMenuAsPrimaryAction = true
        button.addSubview(accessoryButton)
        accessoryButton.snp.makeConstraints { make in
          make.top.bottom.trailing.equalToSuperview()
          // Centered on the image, which is its margin in from the trailing edge.
          make.width.equalTo(Theme.current.sectionContentMargin * 2 + 16)
        }
        self.accessoryButton = accessoryButton
        updateAccessoryMenu(item.value)
      }
      if item.showsTooltip {
        let toolTip = ToolTipController(
          control: button, containerView: stackView, toolTip: button.title(for: .normal) ?? "",
          position: .top, maxWidth: 224, ancestorOf: 6)
        toolTipController = toolTip
      }
      SettingsViewFactory.setWarningView(
        isIncompatible: item.isIncompatible, animated: false, incompatibleView: incompatibleView,
        backgroundView: button, stackView: stackView)
      return ([stackView], self)
    }

    public func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      updatingItem.value = newItem.value
      currentValue = updatingItem.value
      updatingItem.isIncompatible = newItem.isIncompatible
      if let newModifier = newItem.viewModifying as? ViewModifier {
        buttonImageView?.image = newModifier.buttonImage
      }
      makeButtonsUI?(newItem.value, button)
      updateAccessoryMenu(newItem.value)
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      updatingItem.title = newItem.title
      titleLabel?.text = updatingItem.title
      toolTipController?.toolTip = button?.title(for: .normal) ?? ""
      SettingsViewFactory.setWarningView(
        isIncompatible: newItem.isIncompatible, animated: true, incompatibleView: incompatibleView,
        backgroundView: button, stackView: stackView)
      return updatingItem
    }

    /// With no menu for the value, a tap on the image is the button's.
    private func updateAccessoryMenu(_ value: T) {
      let menu = accessoryMenu?(value)
      accessoryButton?.menu = menu
      accessoryButton?.isHidden = menu == nil
      accessoryButton?.accessibilityLabel = menu?.title
    }
  }

  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var isIncompatible: Bool = false
  public var extraTopPadding: CGFloat
  public var value: T
  public private(set) var viewModifying: any SettingsViewModifying

  public var title: String?
  public var showsMenuAsPrimaryAction: Bool
  public var showsTooltip: Bool

  public init(
    value: T, title: String? = nil, buttonImage: UIImage? = nil, isIncompatible: Bool = false,
    showsMenuAsPrimaryAction: Bool = false, extraTopPadding: CGFloat = 0,
    showsTooltip: Bool = false,
    buttonAction: ((UIView, T) -> Void)? = nil,
    makeButtonsUI: ((T, UIButton?) -> Void)? = nil,
    accessoryMenu: ((T) -> UIMenu?)? = nil
  ) {
    self.value = value
    self.title = title
    self.isIncompatible = isIncompatible
    self.showsMenuAsPrimaryAction = showsMenuAsPrimaryAction
    self.extraTopPadding = extraTopPadding
    self.showsTooltip = showsTooltip
    self.viewModifying = ViewModifier(
      buttonAction: buttonAction, buttonImage: buttonImage,
      makeButtonsUI: makeButtonsUI, accessoryMenu: accessoryMenu)
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsButtonItem<T> else { return false }
    return value == other.value && isHidden == other.isHidden && isEnabled == other.isEnabled
      && isIncompatible == other.isIncompatible && title == other.title
      && showsMenuAsPrimaryAction == other.showsMenuAsPrimaryAction
      && showsTooltip == other.showsTooltip && extraTopPadding == other.extraTopPadding
  }
}
