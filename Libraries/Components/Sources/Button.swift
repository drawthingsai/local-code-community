//Created 11/6/23

import Style
import UIKit

public final class Button: UIButton {

  var application: Bool = false {
    didSet {
      self.setNeedsUpdateConfiguration()
    }
  }

  public override var state: UIControl.State {
    if application {
      return [super.state, .application]
    }
    return super.state
  }

  public static func iconTitleButton(
    title: String, image: UIImage, highlightedForegroundColor: UIColor = .primaryColor,
    highlightedBackgroundColor: UIColor = .buttonBackgroundColor,
    normalForegroundColor: UIColor = .primaryTextColor,
    normalBackgroundColor: UIColor = .buttonBackgroundColor,
    imagePlacement: NSDirectionalRectEdge = .top,
    imagePadding: CGFloat = 2,
    borderWidth: CGFloat = 0,
    highlightedBorderColor: UIColor? = nil,
    borderColor: UIColor? = nil,
    additionalConfigurationOverrider: ((UIButton.Configuration?) -> UIButton.Configuration?)? = nil,
    configurationUpdateHandler: ((UIButton, UIButton.Configuration?) -> UIButton.Configuration?)? =
      nil,
    contentInset: NSDirectionalEdgeInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 8, bottom: 8, trailing: 8),
    selectedForegroundColor: UIColor? = nil,
    selectedBackgroundColor: UIColor? = nil,
    selectedBorderColor: UIColor? = nil,
    applicationForegroundColor: UIColor? = nil,
    applicationBackgroundColor: UIColor? = nil
  ) -> Button {
    let button = Button(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.imagePlacement = imagePlacement
    configuration.imagePadding = 2
    configuration.baseBackgroundColor = normalBackgroundColor
    configuration.baseForegroundColor = normalForegroundColor
    let borderColor = borderColor ?? normalBackgroundColor
    let highlightedBorderColor = highlightedBorderColor ?? highlightedBackgroundColor
    configuration.background.strokeWidth = borderWidth
    configuration.background.strokeColor = borderColor
    button.configurationUpdateHandler = {
      var configuration = $0.configuration
      if $0.state.contains(.highlighted) {
        configuration?.baseBackgroundColor = highlightedBackgroundColor
        configuration?.baseForegroundColor = highlightedForegroundColor
        configuration?.image = image.withTintColor(highlightedForegroundColor)
        configuration?.background.strokeColor = highlightedBorderColor
        configuration?.background.backgroundColor = highlightedBackgroundColor
      } else if $0.state.contains(.application) {
        configuration?.baseBackgroundColor =
          applicationBackgroundColor ?? highlightedBackgroundColor
        configuration?.baseForegroundColor =
          applicationForegroundColor ?? highlightedForegroundColor
        configuration?.image = image.withTintColor(
          applicationForegroundColor ?? highlightedForegroundColor)
        configuration?.background.strokeColor = selectedBorderColor ?? highlightedBorderColor
        configuration?.background.backgroundColor =
          applicationBackgroundColor ?? highlightedBackgroundColor
      } else if $0.state.contains(.selected) {
        configuration?.baseBackgroundColor = selectedBackgroundColor ?? highlightedBackgroundColor
        configuration?.baseForegroundColor = selectedForegroundColor ?? highlightedForegroundColor
        configuration?.image = image.withTintColor(
          selectedForegroundColor ?? highlightedForegroundColor)
        configuration?.background.strokeColor = selectedBorderColor ?? highlightedBorderColor
        configuration?.background.backgroundColor =
          selectedBackgroundColor ?? highlightedBackgroundColor
      } else if $0.state.contains(.normal) {
        configuration?.baseBackgroundColor = normalBackgroundColor
        configuration?.baseForegroundColor = normalForegroundColor
        configuration?.image = image.withTintColor(normalForegroundColor)
        configuration?.background.strokeColor = borderColor
        configuration?.background.backgroundColor = normalBackgroundColor
      }
      configuration = configurationUpdateHandler?($0, configuration) ?? configuration
      $0.configuration = configuration
    }
    configuration.contentInsets = contentInset
    configuration = additionalConfigurationOverrider?(configuration) ?? configuration
    button.configuration = configuration
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.lineBreakMode = .byWordWrapping
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: button)
    return button
  }

  public static func iconButton(
    image: UIImage,
    additionalConfigurationOverrider: ((UIButton.Configuration?) -> UIButton.Configuration?)? = nil,
    configurationUpdateHandler: ((UIButton.Configuration?) -> UIButton.Configuration?)? = nil
  ) -> UIButton {
    let button = Button(type: .custom)
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = .buttonBackgroundColor
    configuration.baseForegroundColor = .primaryTextColor
    button.configurationUpdateHandler = {
      var configuration = $0.configuration
      if $0.state.contains(.selected) || $0.state.contains(.highlighted) {
        configuration?.baseForegroundColor = .primaryColor

        configuration?.image = image.withTintColor(
          .primaryColor)
      } else if $0.state.contains(.normal) {
        configuration?.baseForegroundColor = .primaryTextColor
        configuration?.image = image.withTintColor(
          .primaryTextColor)
      }
      configuration = configurationUpdateHandler?(configuration) ?? configuration
      $0.configuration = configuration
    }
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 8, leading: 8, bottom: 8, trailing: 8)
    configuration = additionalConfigurationOverrider?(configuration) ?? configuration
    button.configuration = configuration
    button.titleLabel?.numberOfLines = 1
    button.titleLabel?.lineBreakMode = .byWordWrapping
    FontMetrics.default.scaleFont(.systemFont(ofSize: 12), bindTo: button)
    return button
  }
}
