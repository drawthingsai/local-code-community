//Created 10/25/23

import SnapKit
import Style
import UIKit

public protocol MenuControlDelegate: AnyObject {
  func didSelect(index: Int)
}

public enum BarPosition {
  case leading
  case trailing
  case top
  case bottom
}

// TODO: should we support scrolling in menu control? animating to menu button?
public final class MenuControl {
  public weak var delegate: MenuControlDelegate?

  public lazy var view: UIView = {
    return UIView(frame: .zero)
  }()

  public lazy var stackView: UIStackView = {
    let view = UIStackView(frame: .zero)
    return view
  }()

  private lazy var bar: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .primaryColor
    view.layer.cornerRadius = 1
    return view
  }()

  private var menuItems: [UIButton] = []  // TODO: decided which type of view is better we will likely want to support icons
  public private(set) var currentIndex = 0
  private var barCenterConstraint: Constraint? = nil

  public func setCurrentIndex(_ currentIndex: Int, animated: Bool) {
    guard currentIndex != self.currentIndex else { return }
    let oldValue = self.currentIndex
    self.currentIndex = currentIndex
    menuItems[oldValue].isSelected = false
    menuItems[currentIndex].isSelected = true
    if animated {
      UIView.animate(
        withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
        options: .curveEaseOut
      ) {
        self.updateBarCenterConstraint()
        self.view.layoutIfNeeded()
      }
    } else {
      updateBarCenterConstraint()
    }

  }

  public func setEnabled(_ isEnabled: Bool, forItemAt index: Int) {
    guard index >= 0 && index < menuItems.count else { return }
    menuItems[index].isEnabled = isEnabled
  }

  /// Hidden items collapse out of the stack. Indices keep referring to all items, hidden or not.
  public func setHidden(_ isHidden: Bool, forItemAt index: Int) {
    guard index >= 0 && index < menuItems.count, menuItems[index].isHidden != isHidden else {
      return
    }
    menuItems[index].isHidden = isHidden
    updateBarCenterConstraint()
  }

  private func updateBarCenterConstraint() {
    // Position the bar by where the current item sits among the visible items.
    let visibleItems = menuItems.filter { !$0.isHidden }
    guard let position = visibleItems.firstIndex(of: menuItems[currentIndex]) else { return }
    let multiplier = (CGFloat(position) * 2 + 1) / CGFloat(visibleItems.count)
    barCenterConstraint?.deactivate()
    bar.snp.makeConstraints { make in
      if stackView.axis == .horizontal {
        barCenterConstraint = make.centerX.equalToSuperview().multipliedBy(multiplier).constraint
      } else {
        barCenterConstraint = make.centerY.equalToSuperview().multipliedBy(multiplier).constraint
      }
    }
  }

  public init(
    titles: [String]?, icons: [UIImage]?, axis: NSLayoutConstraint.Axis,
    barPosition: BarPosition? = nil, spacing: CGFloat,
    contentInsets: NSDirectionalEdgeInsets
  ) {
    stackView.axis = axis
    stackView.spacing = spacing
    stackView.distribution = .equalCentering
    guard let count = titles?.count ?? icons?.count else { return }
    for i in 0..<count {
      let button = UIButton(type: .custom)
      var configuration = UIButton.Configuration.plain()
      configuration.title = titles?[i]
      configuration.contentInsets = contentInsets
      if let icon = icons?[i] {
        configuration.image = icon.withRenderingMode(.alwaysTemplate)
        configuration.imagePlacement = .top
        if let title = titles?[i], !title.isEmpty {
          configuration.imagePadding = 5
        }
      }
      button.configurationUpdateHandler = {
        guard var configuration = $0.configuration else { return }
        if $0.state.contains(.disabled) {
          configuration.baseForegroundColor = .septenaryText
        } else if $0.state.contains(.selected) {
          configuration.baseForegroundColor = .primaryColor
        } else if $0.state.contains(.normal) {
          configuration.baseForegroundColor = .senaryText
        }
        $0.configuration = configuration
      }
      configuration.background.cornerRadius = 8
      configuration.baseBackgroundColor = .clear
      configuration.baseForegroundColor = .senaryText
      button.configuration = configuration
      button.addAction(
        UIAction { [weak self] _ in
          guard let self = self else { return }
          self.setCurrentIndex(i, animated: true)
          self.delegate?.didSelect(index: i)
        }, for: .touchUpInside)
      FontMetrics.default.scaleFont(.systemFont(ofSize: 11), bindTo: button)
      stackView.addArrangedSubview(button)
      menuItems.append(button)
      if i == 0 {
        button.isSelected = true
      }
    }
    self.view.addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.top.bottom.leading.trailing.equalToSuperview()
    }
    self.view.addSubview(bar)
    if axis == .horizontal {
      bar.snp.makeConstraints { make in
        make.width.equalTo(menuItems[0])
        barCenterConstraint =
          make.centerX.equalToSuperview().multipliedBy(1 / CGFloat(count)).constraint
        if let barPosition, barPosition == .top {
          make.top.equalToSuperview()
        } else {
          make.bottom.equalToSuperview()
        }
        make.height.equalTo(4)
      }
    } else {
      bar.snp.makeConstraints { make in
        make.height.equalTo(menuItems[0])
        barCenterConstraint =
          make.centerY.equalToSuperview().multipliedBy(1 / CGFloat(count)).constraint
        if let barPosition, barPosition == .leading {
          make.leading.equalToSuperview()
        } else {
          make.trailing.equalToSuperview()
        }
        make.width.equalTo(4)
      }
    }
  }
}
