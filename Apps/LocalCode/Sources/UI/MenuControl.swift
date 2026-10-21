import Components
import SnapKit
import Style
import UIKit

protocol MenuControlDelegate: AnyObject {
  func didSelect(index: Int)
}

final class MenuControl {
  weak var delegate: MenuControlDelegate?

  let view = UIView(frame: .zero)

  private lazy var highlightView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .pastelPalette(for: .red)
    view.layer.cornerRadius = 16
    return view
  }()

  private var menuItems: [UIButton] = []
  private var toolTipControllers: [ToolTipController] = []
  private(set) var currentIndex = 0

  func setCurrentIndex(_ currentIndex: Int, animated: Bool) {
    guard currentIndex != self.currentIndex else { return }
    menuItems[self.currentIndex].isSelected = false
    menuItems[currentIndex].isSelected = true
    self.currentIndex = currentIndex
    let oldFrame = highlightView.frame
    highlightView.snp.remakeConstraints { make in
      make.edges.equalTo(menuItems[currentIndex])
    }
    guard animated else { return }
    view.layoutIfNeeded()
    let newFrame = highlightView.frame
    highlightView.layer.addStretchSpringAnimation(from: oldFrame, to: newFrame, axis: .vertical)
  }

  func setImage(_ image: UIImage, title: String, forItemAt index: Int) {
    guard menuItems.indices.contains(index) else { return }
    menuItems[index].configuration?.image = image.withRenderingMode(.alwaysTemplate)
    menuItems[index].accessibilityLabel = title
    toolTipControllers[index].toolTip = title
  }

  func setEnabled(_ isEnabled: Bool, forItemAt index: Int) {
    guard index >= 0 && index < menuItems.count else { return }
    menuItems[index].isEnabled = isEnabled
  }

  init(icons: [UIImage], titles: [String]) {
    let stackView = UIStackView(frame: .zero)
    stackView.axis = .vertical
    stackView.spacing = 4
    for (i, icon) in icons.enumerated() {
      let button = UIButton(type: .custom)
      var configuration = UIButton.Configuration.plain()
      configuration.image = icon.withRenderingMode(.alwaysTemplate)
      configuration.background.cornerRadius = 16
      configuration.baseBackgroundColor = .clear
      configuration.baseForegroundColor = .senaryText
      button.configurationUpdateHandler = {
        guard var configuration = $0.configuration else { return }
        if $0.state.contains(.disabled) {
          configuration.baseForegroundColor = .septenaryText
        } else if $0.state.contains(.selected) {
          configuration.baseForegroundColor = .shadePalette(for: .red)
        } else {
          configuration.baseForegroundColor = .senaryText
        }
        $0.configuration = configuration
      }
      button.configuration = configuration
      button.accessibilityLabel = titles[i]
      button.isSelected = i == 0
      button.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          self.setCurrentIndex(i, animated: true)
          self.delegate?.didSelect(index: i)
        }, for: .touchUpInside)
      button.snp.makeConstraints { make in
        make.size.equalTo(48)
      }
      stackView.addArrangedSubview(button)
      menuItems.append(button)
      // Attach the tool tip to the superview so it draws above the content next to the rail.
      toolTipControllers.append(
        ToolTipController(
          control: button, containerView: view, toolTip: titles[i], position: .trailing,
          ancestorOf: 1))
    }
    view.addSubview(highlightView)
    view.addSubview(stackView)
    stackView.snp.makeConstraints { make in
      make.top.bottom.centerX.equalToSuperview()
    }
    highlightView.snp.makeConstraints { make in
      make.edges.equalTo(menuItems[0])
    }
  }
}
