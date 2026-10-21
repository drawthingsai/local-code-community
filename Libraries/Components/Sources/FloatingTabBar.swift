import SnapKit
import Style
import UIKit

public protocol FloatingTabBarDelegate: AnyObject {
  func didSelect(tabBar: FloatingTabBar, index: Int)
}

public final class FloatingTabBar {
  public let view: UIView
  public private(set) var index: Int
  public weak var delegate: FloatingTabBarDelegate? = nil
  private let stackView: UIStackView
  private let buttons: [UIButton]
  private let pill: UIView

  public struct Item {
    public var title: String
    public var image: UIImage?
    public init(title: String, image: UIImage? = nil) {
      self.title = title
      self.image = image
    }
  }

  public init(items: [Item]) {
    precondition(!items.isEmpty)
    view = UIView(frame: .zero)
    let backgroundColor = UIColor {
      if $0.userInterfaceStyle == .light {
        return UIColor(white: 237.0 / 255.0, alpha: 1)
      } else {
        return UIColor(white: 37.0 / 255.0, alpha: 1)
      }
    }
    let contentView: UIView
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = false
      let effectView = UIVisualEffectView(effect: effect)
      effectView.cornerConfiguration = .capsule()
      view.addSubview(effectView)
      effectView.snp.makeConstraints { make in
        make.edges.equalToSuperview()
      }
      contentView = effectView.contentView
    } else {
      view.backgroundColor = backgroundColor
      view.layer.cornerRadius = 20
      contentView = view
    }
    pill = UIView(frame: .zero)
    pill.backgroundColor = UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey200
      }
    }
    pill.layer.shadowColor = UIColor(white: 0, alpha: 0.08).cgColor
    pill.layer.shadowOffset = CGSize(width: 0, height: 2)
    pill.layer.shadowRadius = 16
    pill.layer.cornerRadius = 16
    contentView.addSubview(pill)
    stackView = UIStackView(frame: .zero)
    stackView.axis = .horizontal
    stackView.spacing = 0
    stackView.distribution = .equalSpacing
    stackView.alignment = .fill
    contentView.addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(4)
      make.top.bottom.equalToSuperview()
      make.height.equalTo(40)
    }
    var buttons = [UIButton]()
    for item in items {
      let button = UIButton(type: .custom)
      var configuration = UIButton.Configuration.borderless()
      if let image = item.image {
        configuration.contentInsets = NSDirectionalEdgeInsets(
          top: 0, leading: 8, bottom: 0, trailing: 14)
        configuration.title = item.title
        configuration.image = image.withRenderingMode(.alwaysTemplate)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 4
      } else {
        configuration.contentInsets = NSDirectionalEdgeInsets(
          top: 0, leading: 14, bottom: 0, trailing: 14)
        configuration.title = item.title
      }
      configuration.baseBackgroundColor = .clear
      configuration.baseForegroundColor = .senaryText
      configuration.titleLineBreakMode = .byTruncatingMiddle
      button.configurationUpdateHandler = {
        if $0.state.contains(.selected) {
          $0.configuration?.baseForegroundColor = .primaryText
          FontMetrics.default.clearBinding(to: $0)
          FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .semibold), bindTo: button)
        } else {
          $0.configuration?.baseForegroundColor = .senaryText
          FontMetrics.default.clearBinding(to: $0)
          FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
        }
      }
      button.contentHorizontalAlignment = .center
      button.configuration = configuration
      button.tintAdjustmentMode = .normal
      FontMetrics.default.scaleFont(.systemFont(ofSize: 14, weight: .medium), bindTo: button)
      buttons.append(button)
      stackView.addArrangedSubview(button)
    }
    self.buttons = buttons
    index = 0
    buttons[0].isSelected = true
    pill.snp.makeConstraints { make in
      make.height.equalTo(32)
      make.leading.trailing.centerY.equalTo(buttons[0])
    }
    for (i, button) in buttons.enumerated() {
      button.addAction(
        UIAction { [weak self] _ in
          guard let self = self else { return }
          self.setIndex(i, animated: true)
          self.delegate?.didSelect(tabBar: self, index: index)
        }, for: .touchUpInside)
    }
  }

  public func setIndex(_ index: Int, animated: Bool) {
    guard index != self.index else { return }
    self.index = index
    for (i, button) in buttons.enumerated() {
      button.isSelected = (i == index)
    }
    let oldFrame = pill.frame
    pill.snp.remakeConstraints { make in
      make.height.equalTo(32)
      make.leading.trailing.centerY.equalTo(buttons[index])
    }
    guard animated else {
      return
    }
    view.layoutIfNeeded()
    // Tabs are wide and far apart, so the full stretch reads as too much here.
    pill.layer.addStretchSpringAnimation(
      from: oldFrame, to: pill.frame, axis: .horizontal, stretch: 0.4)
  }
}
