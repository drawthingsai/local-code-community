import Style
import UIKit

extension SettingsImageTextItem {
  final class ViewModifier: SettingsViewModifying {
    typealias Item = SettingsImageTextItem

    public var view: UIView?
    var label: UILabel?
    var imageView: UIImageView?
    func makeViews(from item: Item) -> ([UIView], any SettingsViewModifying) {

      let backgroundView = UIView(frame: .zero)
      backgroundView.backgroundColor = Theme.current.primaryContentBackgroundColor
      backgroundView.layer.cornerRadius = 8
      backgroundView.clipsToBounds = true
      backgroundView.snp.makeConstraints { make in
        make.height.equalTo(Theme.current.buttonHeight)
      }
      let imageView = UIImageView()
      imageView.image = item.image
      backgroundView.addSubview(imageView)
      imageView.snp.makeConstraints { make in
        make.leading.equalToSuperview().offset(Theme.current.sectionContentMargin)
        make.centerY.equalToSuperview()
        make.size.equalTo(24)
      }
      let label = UILabel(frame: .zero)
      label.text = item.value
      label.textColor = Theme.current.rowTitleColor
      FontMetrics.default.scaleFont(Theme.current.rowTitleFont, bindTo: label)
      backgroundView.addSubview(label)
      label.snp.makeConstraints { make in
        make.leading.equalTo(imageView.snp.trailing).offset(
          Theme.current.sectionItemInternalSpacing)
        make.centerY.equalToSuperview()
      }

      self.label = label
      self.imageView = imageView
      self.view = backgroundView
      backgroundView.isHidden = item.isHidden
      return ([backgroundView], self)
    }

    func updateViews(
      _ updatingItem: Item,
      with newItem: Item
    ) -> Item {
      var updatingItem = updatingItem
      guard !updatingItem.isEquivalent(to: newItem) else { return updatingItem }
      if updatingItem.value != newItem.value,
        let label = label
      {
        updatingItem.value = newItem.value
        label.text = newItem.value
      }
      if updatingItem.image != newItem.image,
        let imageView = imageView
      {
        updatingItem.image = newItem.image
        imageView.image = newItem.image
      }
      if updatingItem.isHidden != newItem.isHidden {
        hideView = newItem.isHidden
        updatingItem.isHidden = newItem.isHidden
      }
      return updatingItem
    }
  }
}

public struct SettingsImageTextItem: SettingsViewObservable {
  public var value: String
  public var image: UIImage
  public var isEnabled: Bool = true
  public var isHidden: Bool = false

  public private(set) var viewModifying: any SettingsViewModifying = ViewModifier()
  public init(
    value: String, image: UIImage
  ) {
    self.value = value
    self.image = image
  }

  public func isEquivalent(to other: any SettingsViewObservable) -> Bool {
    guard let other = other as? SettingsImageTextItem else { return false }
    return value == other.value && image == other.image && isHidden == other.isHidden
      && isEnabled == other.isEnabled
  }
}
