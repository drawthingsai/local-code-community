//Created 11/13/23

import Dflat
import Style
import UIKit

public struct SettingsSectionItem: SettingsViewObservable {
  private final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsSectionItem
    var view: UIView?
    var titleLabel: UILabel?
    var detailView: UIView?
    var detailLabel: UILabel?
    var sectionView: UIView?
    var views: [UIView] = []  // necessary for sub item view's hidden control

    private let lookUpKey: String
    var toolTipController: ToolTipAndDetailAppearanceController?
    var workspace: Workspace
    var settingsItemsViewModifiers: [any SettingsViewModifying] = []

    init(
      lookUpKey: String, toolTipController: ToolTipAndDetailAppearanceController? = nil,
      workspace: Workspace
    ) {
      self.lookUpKey = lookUpKey
      self.toolTipController = toolTipController
      self.workspace = workspace
    }

    public func makeViews(from item: Item) -> (
      [UIView], any SettingsViewModifying
    ) {
      var titleView: UIView
      var titleLabel: UILabel
      var iconView: UIImageView
      if !item.detail.isEmpty {
        (titleView, titleLabel, iconView) = SettingsViewFactory.makeTitleInfoView(
          title: item.title)
        titleView.snp.makeConstraints { make in
          make.height.equalTo(Theme.current.buttonHeight)
        }
        let detailView = UIView()
        let detailLabel = UILabel(frame: .zero)
        detailLabel.text = item.detail
        detailLabel.textColor = Theme.current.sectionDescriptionColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.numberOfLines = 0
        detailView.addSubview(detailLabel)
        detailLabel.snp.makeConstraints { make in
          make.leading.trailing.equalToSuperview().inset(Theme.current.sectionTitleMargin)
          make.top.equalToSuperview()
          if item.individualSectionStyle {
            make.bottom.equalToSuperview().inset(8)
          } else {
            make.bottom.equalToSuperview()
          }
        }
        FontMetrics.default.scaleFont(Theme.current.sectionDescriptionFont, bindTo: detailLabel)
        let toolTipController = ToolTipAndDetailAppearanceController(
          titleView, detail: detailView, toolTip: detailLabel.text ?? "", lookUpKey: lookUpKey,
          workspace: workspace)
        toolTipController.iconView = iconView
        self.toolTipController = toolTipController
        self.detailView = detailView
        self.detailLabel = detailLabel
      } else {
        (titleView, titleLabel) = SettingsViewFactory.makeTitleView(
          title: item.title)
      }

      let borderAndStackView: (UIView, UIStackView)?
      if item.individualSectionStyle {
        let (borderView, stackView) = SettingsViewFactory.makeSectionStackView(
          individualSectionStyle: item.individualSectionStyle)
        stackView.spacing = Theme.current.sectionItemInternalSpacing
        stackView.addArrangedSubview(titleView)
        if let detailView {
          stackView.addArrangedSubview(detailView)
        }
        borderAndStackView = (borderView, stackView)
      } else {
        titleLabel.snp.remakeConstraints { make in
          make.top.equalToSuperview().offset(Theme.current.sectionTitleMargin)
          make.bottom.equalToSuperview()
          make.leading.equalToSuperview().inset(Theme.current.sectionTitleMargin)
        }
        borderAndStackView = nil
      }
      for subItem in item.settingsItems {
        let (subItemViews, subItemViewModifier) = subItem.viewModifying.makeViews(from: subItem)
        views.append(contentsOf: subItemViews)
        if let stackView = borderAndStackView?.1 {
          subItemViews.forEach { stackView.addArrangedSubview($0) }
        }
        subItemViewModifier.hideView = subItem.isHidden
        settingsItemsViewModifiers.append(subItemViewModifier)
      }

      self.sectionView = borderAndStackView?.0
      view = titleView
      self.titleLabel = titleLabel

      hideView = item.isHidden
      if let borderView = borderAndStackView?.0 {
        borderView.isHidden = item.isHidden
        return ([borderView], self)
      } else {
        if let detailView = detailView {
          return ([titleView, detailView] + views, self)
        }
        return ([titleView] + views, self)
      }
    }

    public func updateViews(
      _ updatingSectionItem: Item,
      with sectionItem: Item
    ) -> Item {
      var updatingSectionItem = updatingSectionItem
      guard updatingSectionItem.settingsItems.count == sectionItem.settingsItems.count else {
        // probably need to remake all the views but not practical atm so will figure out a way to extend this behavior later
        return updatingSectionItem
      }
      var updatedSettingsItems: [any SettingsViewObservable] = []
      // If we are going to show the section, first trigger this, so we won't mark all views to be shown.
      let hiddenStateChanged: Bool
      if !sectionItem.isHidden && updatingSectionItem.isHidden != sectionItem.isHidden {
        hideView = sectionItem.isHidden
        updatingSectionItem.isHidden = sectionItem.isHidden
        hiddenStateChanged = true
      } else {
        hiddenStateChanged = false
      }
      for i in 0..<sectionItem.settingsItems.count {
        let updatedItem = settingsItemsViewModifiers[i]
          .updateViews(
            updatingSectionItem.settingsItems[i],
            with: sectionItem.settingsItems[i])
        // If we changed hidden state before, need to keep it up-to-date.
        if hiddenStateChanged {
          settingsItemsViewModifiers[i].hideView = updatedItem.isHidden
        }
        updatedSettingsItems.append(updatedItem)
      }
      updatingSectionItem.settingsItems = updatedSettingsItems
      // If we already shown the section from above, this line won't trigger. We only hide sections from here.
      if updatingSectionItem.isHidden != sectionItem.isHidden {
        hideView = sectionItem.isHidden
        updatingSectionItem.isHidden = sectionItem.isHidden
      }
      updatingSectionItem.title = sectionItem.title
      if let titleLabel = titleLabel {
        titleLabel.text = updatingSectionItem.title
      }
      updatingSectionItem.detail = sectionItem.detail
      if let detailLabel = detailLabel {
        detailLabel.text = updatingSectionItem.detail
      }
      return updatingSectionItem
    }

    public var hideView: Bool {
      get {
        return view?.isHidden ?? true
      }
      set {
        guard hideView != newValue else { return }
        let viewChange = {
          self.view?.isHidden = newValue
          self.view?.alpha = newValue ? 0 : 1
          self.sectionView?.isHidden = newValue
          self.sectionView?.alpha = newValue ? 0 : 1
          // Only need to update detail view if it is not within a section.
          if self.sectionView == nil {
            if let detailView = self.detailView, let toolTipController = self.toolTipController {
              let isHidden = newValue || toolTipController.isHidden
              detailView.isHidden = isHidden
              detailView.alpha = isHidden ? 0 : 1
            }
            for view in self.views {
              view.isHidden = newValue
              view.alpha = newValue ? 0 : 1
            }
          } else {
            for view in self.views {
              view.alpha = newValue ? 0 : 1
            }
          }
        }
        guard view?.window != nil else {
          viewChange()
          return
        }
        UIView.animate(
          withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
          viewChange()
          if let sectionView = self.sectionView {
            sectionView.superview?.layoutIfNeeded()
          } else {
            self.view?.superview?.layoutIfNeeded()
          }
        }
      }
    }
  }
  public var isHidden: Bool = false
  public var isEnabled: Bool = true
  public var individualSectionStyle: Bool

  public var settingsItems: [any SettingsViewObservable]

  public var viewModifying: any SettingsViewModifying {
    viewModifier
  }

  private var title: String
  private var detail: String
  private let viewModifier: ViewModifier

  public init(
    settingsItems: [any SettingsViewObservable], title: String, detail: String, lookUpKey: String,
    individualSectionStyle: Bool = true, workspace: Workspace
  ) {
    self.title = title
    self.detail = detail
    self.settingsItems = settingsItems
    self.individualSectionStyle = individualSectionStyle
    viewModifier = ViewModifier(
      lookUpKey: lookUpKey, workspace: workspace)
  }
}

extension SettingsSectionItem {
  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsSectionItem else { return false }
    return settingsItems.count == other.settingsItems.count && isHidden == other.isHidden
      && isEnabled == other.isEnabled && title == other.title && detail == other.detail  // I might also need to add detail.
      && zip(settingsItems, other.settingsItems)
        .allSatisfy { $0.isEquivalent(to: $1) }
  }
}
