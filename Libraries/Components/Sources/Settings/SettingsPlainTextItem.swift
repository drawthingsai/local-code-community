//Created 12/7/23
// TODO: this might be similar to the WizDividerTextDetailCollectionViewCell... we can determine which one to use when a concrete instance is added. commented added to avoid changing the margins here for theme implementation
import Style
import UIKit

extension SettingsPlainTextItem {
  final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsPlainTextItem

    public var view: UIView?
    var leadingLabel: UILabel?
    var trailingLabel: UILabel?

    func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {
      let view = UIView()
      self.view = view
      let leadingLabel = UILabel(frame: .zero)
      leadingLabel.text = item.value.leadingText
      leadingLabel.textColor = Theme.current.sectionTitleColor
      FontMetrics.default.scaleFont(
        .systemFont(ofSize: item.fontSize, weight: item.fontWeight), bindTo: leadingLabel)
      let trailingLabel = UILabel(frame: .zero)
      trailingLabel.text = item.value.trailingText
      trailingLabel.textColor = Theme.current.sectionTitleColor
      FontMetrics.default.scaleFont(
        .systemFont(ofSize: item.fontSize, weight: item.fontWeight), bindTo: trailingLabel)

      view.addSubview(leadingLabel)
      view.addSubview(trailingLabel)
      leadingLabel.snp.makeConstraints { make in
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
        make.top.equalToSuperview().offset(1.5 + item.extraTopPadding)
        make.bottom.equalToSuperview().offset(-1.5)
      }
      trailingLabel.snp.makeConstraints { make in
        make.trailing.equalToSuperview().offset(-Theme.current.sectionContentMargin)
        make.top.equalToSuperview().offset(1.5 + item.extraTopPadding)
        make.bottom.equalToSuperview().offset(-1.5)
      }
      self.leadingLabel = leadingLabel
      self.trailingLabel = trailingLabel
      view.isHidden = item.isHidden
      return ([view], self)
    }

    func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      guard !updatingItem.isEquivalent(to: newItem) else { return updatingItem }
      updatingItem.value = newItem.value
      leadingLabel?.text = updatingItem.value.leadingText
      trailingLabel?.text = updatingItem.value.trailingText
      if updatingItem.fontSize != newItem.fontSize, let leadingLabel = leadingLabel,
        let trailingLabel = trailingLabel
      {
        FontMetrics.default.clearBinding(to: leadingLabel)
        FontMetrics.default.clearBinding(to: trailingLabel)
        FontMetrics.default.scaleFont(.systemFont(ofSize: newItem.fontSize), bindTo: leadingLabel)
        FontMetrics.default.scaleFont(.systemFont(ofSize: newItem.fontSize), bindTo: trailingLabel)
        updatingItem.fontSize = newItem.fontSize
      }
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }
  }
}

public struct SettingsPlainTextItem: SettingsViewObservable {
  public struct Complex: Equatable {
    public let leadingText: String
    public let trailingText: String
  }
  public var value: Complex
  public var fontSize: CGFloat
  public var fontWeight: UIFont.Weight
  public var isEnabled: Bool = true
  public var isHidden: Bool = false
  public var extraTopPadding: CGFloat

  public private(set) var viewModifying: any SettingsViewModifying = ViewModifier()
  public init(
    leadingText: String, trailingText: String, fontSize: CGFloat = 11,
    fontWeight: UIFont.Weight = .regular, extraTopPadding: CGFloat = 0
  ) {
    self.value = Complex(leadingText: leadingText, trailingText: trailingText)
    self.fontSize = fontSize
    self.fontWeight = fontWeight
    self.extraTopPadding = extraTopPadding
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsPlainTextItem else { return false }
    return value == other.value && fontSize == other.fontSize && fontWeight == other.fontWeight
      && isHidden == other.isHidden && isEnabled == other.isEnabled
  }

}
