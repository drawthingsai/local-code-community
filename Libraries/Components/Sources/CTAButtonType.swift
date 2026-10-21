import Localization
import Style
import UIKit

public enum CTAButtonType: Hashable {
  case plus
  case max
  case maxSecondary

  public var actionTitle: String {
    switch self {
    case .plus:
      return LocalizedString.forKey("get_dt_+")
    case .max, .maxSecondary:
      return LocalizedString.forKey("get_dt_max")
    }
  }

  public var actionImage: UIImage {
    switch self {
    case .plus:
      return UIImage(imageLiteralResourceName: "recommended-filled-16").withTintColor(.nonaryText)
    case .max, .maxSecondary:
      return UIImage(imageLiteralResourceName: "burst-filled-16").withTintColor(.nonaryText)
    }
  }

  public var upsellDescription: String {
    switch self {
    case .plus:
      return LocalizedString.forKey("unlock_plus_description")
    case .max, .maxSecondary:
      return LocalizedString.forKey("unlock_max_description")
    }
  }

  public var gradientLocations: [NSNumber] {
    switch self {
    case .plus:
      return [0, 0.51, 1]
    case .max:
      return [0, 0.15, 0.25, 0.4, 0.5, 0.6, 0.75, 0.85, 1]
    case .maxSecondary:
      return [0, 0.15, 0.5, 0.85, 1]
    }
  }

  public var gradientColors: [UIColor] {
    switch self {
    case .plus:
      return UIColor.primaryGradientColors
    case .max:
      return UIColor.metalPrimaryGradientColors
    case .maxSecondary:
      return UIColor.metalSecondaryGradientColors
    }
  }

  public func makeGradientView(cornerRadius: CGFloat) -> GradientView {
    let gradientView = GradientView(frame: .zero)
    gradientView.gradientLayer.cornerRadius = cornerRadius
    gradientView.clipsToBounds = true
    gradientView.colors = gradientColors
    gradientView.gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientView.gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    gradientView.gradientLayer.locations = gradientLocations
    gradientView.isUserInteractionEnabled = false
    return gradientView
  }

  public func applyFilledStyle(
    to button: UIButton, cornerRadius: CGFloat = 13, showsImage: Bool = true
  ) {
    var configuration = button.configuration ?? UIButton.Configuration.filled()
    configuration.title = actionTitle
    configuration.baseForegroundColor = .nonaryText
    configuration.image = showsImage ? actionImage : nil
    configuration.imagePadding = showsImage ? 8 : 0
    configuration.background.cornerRadius = cornerRadius
    configuration.background.backgroundColor = .primaryFill
    button.configuration = configuration
  }
}
