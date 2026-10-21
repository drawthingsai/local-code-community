import UIKit

extension UIColor {
  public static var primaryColor: UIColor {
    return colorPalette(for: .red)
  }

  public func mixed(with color: UIColor, weight: CGFloat) -> UIColor {
    // Clamp the weight to the valid range [0, 1]
    let clampedWeight = max(0.0, min(1.0, weight))

    // Get the RGBA components of the two colors
    var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)

    getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

    // Linearly interpolate each component
    let newRed = r1 * (1.0 - clampedWeight) + r2 * clampedWeight
    let newGreen = g1 * (1.0 - clampedWeight) + g2 * clampedWeight
    let newBlue = b1 * (1.0 - clampedWeight) + b2 * clampedWeight
    let newAlpha = a1 * (1.0 - clampedWeight) + a2 * clampedWeight

    return UIColor(red: newRed, green: newGreen, blue: newBlue, alpha: newAlpha)
  }

  public static var primaryColor200: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 226.0 / 255.0, green: 193.0 / 255.0, blue: 186.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 251.0 / 255.0, green: 214.0 / 255.0, blue: 207.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var primaryTextColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return .white
      default:
        return UIColor(red: 23.0 / 255.0, green: 26.0 / 255.0, blue: 31.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var secondaryTextColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return .white.withAlphaComponent(0.8)
      default:
        return UIColor(red: 123.0 / 255.0, green: 126.0 / 255.0, blue: 131.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var secondaryColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 86.0 / 255.0, green: 160.0 / 255.0, blue: 216.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 96.0 / 255.0, green: 178.0 / 255.0, blue: 240.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var secondaryColor200: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 185.0 / 255.0, green: 208.0 / 255.0, blue: 225.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 205.0 / 255.0, green: 231.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var backgroundGrayColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 66.0 / 255.0, green: 72.0 / 255.0, blue: 86.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 248.0 / 255.0, green: 249.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var slightlyWhite: UIColor {
    return UIColor(red: 248.0 / 255.0, green: 249.0 / 255.0, blue: 250.0 / 255.0, alpha: 1)
  }

  public static var placeholderImageColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(white: 1, alpha: 0.5)
      default:
        return UIColor(red: 241.0 / 255.0, green: 0.5, blue: 106.0 / 255.0, alpha: 0.7)
      }
    }
  }

  public static var segmentedCotrolSelectedColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 66.0 / 255.0, green: 71.0 / 255.0, blue: 85.0 / 255.0, alpha: 1)
      default:
        return .white
      }
    }
  }

  public static var buttonBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 50.0 / 255.0, green: 55.0 / 255.0, blue: 67.0 / 255.0, alpha: 1)
      default:
        return .white
      }
    }
  }

  public static var buttonForegroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return .white
      default:
        return .primaryColor
      }
    }
  }

  public static var inversePrimaryTextColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 23.0 / 255.0, green: 26.0 / 255.0, blue: 31.0 / 255.0, alpha: 1)
      default:
        return .white
      }
    }
  }

  public static var inverseBackgroundGrayColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 189.0 / 255.0, green: 193.0 / 255.0, blue: 202.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 111.0 / 255.0, green: 119.0 / 255.0, blue: 135.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var inverseButtonBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 222.0 / 255.0, green: 225.0 / 255.0, blue: 230.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 86.0 / 255.0, green: 93.0 / 255.0, blue: 109.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var buttonDangerBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 86.0 / 255.0, green: 23.0 / 255.0, blue: 9.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 254.0 / 255.0, green: 243.0 / 255.0, blue: 241.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var buttonWarningBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 70.0 / 255.0, green: 58.0 / 255.0, blue: 5.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 253.0 / 255.0, green: 250.0 / 255.0, blue: 232.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var inverseButtonDangerBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 245.0 / 255.0, green: 171.0 / 255.0, blue: 154.0 / 255.0, alpha: 1)
      default:
        return UIColor(red: 121.0 / 255.0, green: 32.0 / 255.0, blue: 12.0 / 255.0, alpha: 1)
      }
    }
  }

  public static var selectorGrayColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 0.718, green: 0.749, blue: 0.776, alpha: 1.0)  // "#B7BFC7"
      default:
        return UIColor(red: 0.549, green: 0.592, blue: 0.643, alpha: 1)  //"#8C97A4"
      }
    }
  }

  public static var manageButtonBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return .grey700
      default:
        return UIColor(red: 0.745, green: 0.784, blue: 0.820, alpha: 1)  //"#BEC8D1"
      }
    }
  }

  public static var settingsBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey100
      default:
        return .grey200
      }
    }
  }

  public static var grey100Accent: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return UIColor(red: 0.549, green: 0.592, blue: 0.643, alpha: 1)  //"#8C97A4"
      default:
        return UIColor(red: 0.745, green: 0.784, blue: 0.820, alpha: 1)  //"#BEC8D1"
      }
    }
  }

  public static var menuItemColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return .grey800
      default:
        return .grey600
      }
    }
  }

  public static var menuItemHighlightColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return .grey1000
      default:
        return .grey400
      }
    }
  }
  public static var menuItemHighlightBackgroundColor: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        return .grey400
      default:
        return .grey1200
      }
    }
  }
  /// NEW™️ COLOR PALETTE @2024

  static var grey000: UIColor {
    return UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)  // "#000000"
  }

  static var grey100: UIColor {
    return UIColor(red: 0.035, green: 0.039, blue: 0.043, alpha: 1.0)  // "#090A0B"
  }

  public static var grey200: UIColor {
    return UIColor(red: 0.075, green: 0.078, blue: 0.09, alpha: 1.0)  // "#131417"
  }

  static var grey300: UIColor {
    return UIColor(red: 0.102, green: 0.11, blue: 0.122, alpha: 1.0)  // "#1A1C1F"
  }

  static var grey350: UIColor {
    return UIColor(red: 32.0 / 255, green: 35.0 / 255, blue: 41.0 / 255, alpha: 1.0)
  }

  public static var grey400: UIColor {
    return UIColor(red: 0.149, green: 0.161, blue: 0.2, alpha: 1.0)  // "#252933"
  }

  public static var grey450: UIColor {
    return UIColor(red: 52.0 / 255, green: 56.0 / 255, blue: 69.0 / 255, alpha: 1.0)
  }

  public static var grey500: UIColor {
    return UIColor(red: 0.259, green: 0.278, blue: 0.333, alpha: 1.0)  // "#424755"
  }

  public static var grey600: UIColor {
    return UIColor(red: 0.333, green: 0.369, blue: 0.408, alpha: 1.0)  // "#555E68", same for both
  }

  static var grey700: UIColor {
    return UIColor(red: 0.549, green: 0.592, blue: 0.643, alpha: 1.0)  // "#8C97A4"
  }

  static var grey800: UIColor {
    return UIColor(red: 0.718, green: 0.749, blue: 0.776, alpha: 1.0)  // "#B7BFC7"
  }

  static var grey850: UIColor {
    return UIColor(red: 201.0 / 255, green: 206.0 / 255, blue: 212.0 / 255, alpha: 1.0)
  }

  public static var grey900: UIColor {
    return UIColor(red: 0.855, green: 0.867, blue: 0.878, alpha: 1.0)  // "#DADDE0"
  }

  public static var grey1000: UIColor {
    return UIColor(red: 0.91, green: 0.918, blue: 0.925, alpha: 1.0)  // "#E8EAEC"
  }

  public static var grey1100: UIColor {
    return UIColor(red: 0.957, green: 0.961, blue: 0.965, alpha: 1.0)  // "#F4F5F6"
  }

  static var grey1150: UIColor {
    return UIColor(red: 250.0 / 255, green: 251.0 / 255, blue: 252.0 / 255, alpha: 1.0)
  }

  // white!
  public static var grey1200: UIColor {
    return UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)  // "#FFFFFF"
  }

  public enum ColorPalette: Int, CaseIterable {
    case lavender = 0
    case blue
    case aqua
    case mint
    case green
    case chartreuse
    case yellow
    case orange
    case red
    case brown
    case ochre
    case fuchsia
  }

  public static func randomColorPalette() -> ColorPalette {
    let maxIndex = ColorPalette.fuchsia.rawValue
    let randomIndex = Int.random(in: 0...maxIndex)
    return ColorPalette(rawValue: randomIndex)!
  }

  public static var wizTonePaletteLight: [UIColor] {
    [
      UIColor(red: 72.0 / 255.0, green: 23.0 / 255.0, blue: 163.0 / 255.0, alpha: 1),  // 4817A3 lavender
      UIColor(red: 0.0 / 255.0, green: 102.0 / 255.0, blue: 153.0 / 255.0, alpha: 1),  // 006699 blue
      UIColor(red: 0.0 / 255.0, green: 153.0 / 255.0, blue: 153.0 / 255.0, alpha: 1),  // 009999 Aqua
      UIColor(red: 0.0 / 255.0, green: 143.0 / 255.0, blue: 91.0 / 255.0, alpha: 1),  // 008F5B Mint
      UIColor(red: 10.0 / 255.0, green: 173.0 / 255.0, blue: 10.0 / 255.0, alpha: 1),  // 0AAD0A Green
      UIColor(red: 89.0 / 255.0, green: 143.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // 598F00 Chartreuse
      UIColor(red: 184.0 / 255.0, green: 152.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // B89800 Yellow
      UIColor(red: 184.0 / 255.0, green: 110.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // B86E00 Orange
      UIColor(red: 194.0 / 255.0, green: 42.0 / 255.0, blue: 12.0 / 255.0, alpha: 1),  // C22A0C Red
      UIColor(red: 122.0 / 255.0, green: 68.0 / 255.0, blue: 5.0 / 255.0, alpha: 1),  // 7A4405 Brown
      UIColor(red: 143.0 / 255.0, green: 115.0 / 255.0, blue: 6.0 / 255.0, alpha: 1),  // 8F7306 Ochre
      UIColor(red: 194.0 / 255.0, green: 47.0 / 255.0, blue: 130.0 / 255.0, alpha: 1),  // C22F82 Fuchsia
    ]
  }

  public static var wizTonePaletteDark: [UIColor] {
    [
      UIColor(red: 43.0 / 255.0, green: 10.0 / 255.0, blue: 102.0 / 255.0, alpha: 1),  // 2B0A66 lavender
      UIColor(red: 0.0 / 255.0, green: 68.0 / 255.0, blue: 102.0 / 255.0, alpha: 1),  // 004466 blue
      UIColor(red: 0.0 / 255.0, green: 102.0 / 255.0, blue: 102.0 / 255.0, alpha: 1),  // 006666 Aqua
      UIColor(red: 0.0 / 255.0, green: 91.0 / 255.0, blue: 58.0 / 255.0, alpha: 1),  // 005B3A Mint
      UIColor(red: 6.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0, alpha: 1),  // 067706 Green
      UIColor(red: 58.0 / 255.0, green: 91.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // 3A5B00 Chartreuse
      UIColor(red: 120.0 / 255.0, green: 102.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // 786600 Yellow
      UIColor(red: 120.0 / 255.0, green: 70.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // 784600 Orange
      UIColor(red: 122.0 / 255.0, green: 26.0 / 255.0, blue: 8.0 / 255.0, alpha: 1),  // 7A1A08 Red
      UIColor(red: 77.0 / 255.0, green: 42.0 / 255.0, blue: 3.0 / 255.0, alpha: 1),  // 4D2A03 Brown
      UIColor(red: 91.0 / 255.0, green: 72.0 / 255.0, blue: 4.0 / 255.0, alpha: 1),  // 5B4804 Ochre
      UIColor(red: 122.0 / 255.0, green: 29.0 / 255.0, blue: 82.0 / 255.0, alpha: 1),  // 7A1D52 Fuchsia
    ]
  }

  public static var wizPaletteLight: [UIColor] {
    [
      UIColor(red: 124.0 / 255.0, green: 68.0 / 255.0, blue: 227.0 / 255.0, alpha: 1),  // 7C44E3 lavender
      UIColor(red: 9.0 / 255.0, green: 146.0 / 255.0, blue: 214.0 / 255.0, alpha: 1),  // 0992D6 blue
      UIColor(red: 26.0 / 255.0, green: 214.0 / 255.0, blue: 214.0 / 255.0, alpha: 1),  // 1AD6D6 Aqua
      UIColor(red: 0.0 / 255.0, green: 204.0 / 255.0, blue: 130.0 / 255.0, alpha: 1),  // 00CC82 Mint
      UIColor(red: 70.0 / 255.0, green: 235.0 / 255.0, blue: 70.0 / 255.0, alpha: 1),  // 46EB46 Green
      UIColor(red: 136.0 / 255.0, green: 204.0 / 255.0, blue: 24.0 / 255.0, alpha: 1),  // 88CC18 Chartreuse
      UIColor(red: 245.0 / 255.0, green: 208.0 / 255.0, blue: 29.0 / 255.0, alpha: 1),  // F5D01D Yellow
      UIColor(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 29.0 / 255.0, alpha: 1),  // F59E1D Orange
      UIColor(red: 255.0 / 255.0, green: 85.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // FF5533 Red
      UIColor(red: 184.0 / 255.0, green: 122.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // B87A33 Brown
      UIColor(red: 204.0 / 255.0, green: 175.0 / 255.0, blue: 57.0 / 255.0, alpha: 1),  // CCAF39 Ochre
      UIColor(red: 255.0 / 255.0, green: 122.0 / 255.0, blue: 198.0 / 255.0, alpha: 1),  // FF7AC6 Fuchsia
    ]
  }
  public static var wizPaletteDark: [UIColor] {
    [
      UIColor(red: 132.0 / 255.0, green: 87.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),  // 8457FF lavender
      UIColor(red: 7.0 / 255.0, green: 118.0 / 255.0, blue: 184.0 / 255.0, alpha: 1),  // 0776B8 blue
      UIColor(red: 14.0 / 255.0, green: 173.0 / 255.0, blue: 173.0 / 255.0, alpha: 1),  // 0EADAD Aqua
      UIColor(red: 14.0 / 255.0, green: 173.0 / 255.0, blue: 111.0 / 255.0, alpha: 1),  // 0EAD6F Mint
      UIColor(red: 51.0 / 255.0, green: 184.0 / 255.0, blue: 44.0 / 255.0, alpha: 1),  // 33B82C Green
      UIColor(red: 101.0 / 255.0, green: 153.0 / 255.0, blue: 24.0 / 255.0, alpha: 1),  // 659918 Chartreuse
      UIColor(red: 184.0 / 255.0, green: 165.0 / 255.0, blue: 15.0 / 255.0, alpha: 1),  // B8A50F Yellow
      UIColor(red: 199.0 / 255.0, green: 138.0 / 255.0, blue: 24.0 / 255.0, alpha: 1),  // C78A18 Orange
      UIColor(red: 222.0 / 255.0, green: 62.0 / 255.0, blue: 38.0 / 255.0, alpha: 1),  // DE3E26 Red
      UIColor(red: 122.0 / 255.0, green: 84.0 / 255.0, blue: 29.0 / 255.0, alpha: 1),  // 7A541D Brown
      UIColor(red: 163.0 / 255.0, green: 127.0 / 255.0, blue: 46.0 / 255.0, alpha: 1),  // A37F2E Ochre
      UIColor(red: 235.0 / 255.0, green: 94.0 / 255.0, blue: 169.0 / 255.0, alpha: 1),  // EB5EA9 Fuchsia
    ]
  }
  // glass (overlay)
  static var wizOverlayLight: [UIColor] {
    [
      UIColor(red: 248.0 / 255.0, green: 246.0 / 255.0, blue: 254.0 / 255.0, alpha: 1),  // lavender
      UIColor(red: 242.0 / 255.0, green: 249.0 / 255.0, blue: 254.0 / 255.0, alpha: 1),  // blue
      UIColor(red: 239 / 255.0, green: 253.0 / 255.0, blue: 253.0 / 255.0, alpha: 1),  // Aqua
      UIColor(red: 239.0 / 255.0, green: 252.0 / 255.0, blue: 247.0 / 255.0, alpha: 1),  // Mint
      UIColor(red: 241.0 / 255.0, green: 253.0 / 255.0, blue: 241.0 / 255.0, alpha: 1),  //  Green
      UIColor(red: 247.0 / 255.0, green: 252.0 / 255.0, blue: 240.0 / 255.0, alpha: 1),  // Chartreuse
      UIColor(red: 255.0 / 255.0, green: 253.0 / 255.0, blue: 239.0 / 255.0, alpha: 1),  // Yellow
      UIColor(red: 255.0 / 255.0, green: 249.0 / 255.0, blue: 240.0 / 255.0, alpha: 1),  // Orange
      UIColor(red: 254.0 / 255.0, green: 245.0 / 255.0, blue: 243.0 / 255.0, alpha: 1),  // Red
      UIColor(red: 250.0 / 255.0, green: 246.0 / 255.0, blue: 241.0 / 255.0, alpha: 1),  // Brown
      UIColor(red: 251.0 / 255.0, green: 249.0 / 255.0, blue: 241.0 / 255.0, alpha: 1),  // Ochre
      UIColor(red: 255.0 / 255.0, green: 245.0 / 255.0, blue: 250.0 / 255.0, alpha: 1),  // Fuchsia
    ]
  }

  static var wizOverlayDark: [UIColor] {
    return [
      UIColor(red: 25.0 / 255.0, green: 26.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #2C2E3F Lavender
      UIColor(red: 25.0 / 255.0, green: 27.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #27303C Blue
      UIColor(red: 25.0 / 255.0, green: 28.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #26343E Aqua
      UIColor(red: 25.0 / 255.0, green: 29.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #263439 Mint
      UIColor(red: 25.0 / 255.0, green: 31.0 / 255.0, blue: 30.0 / 255.0, alpha: 1),  // #273533 Green
      UIColor(red: 25.0 / 255.0, green: 31.0 / 255.0, blue: 29.0 / 255.0, alpha: 1),  // #2C3432 Chartreuse
      UIColor(red: 28.0 / 255.0, green: 31.0 / 255.0, blue: 25.0 / 255.0, alpha: 1),  // #343731 Yellow
      UIColor(red: 31.0 / 255.0, green: 25.0 / 255.0, blue: 28.0 / 255.0, alpha: 1),  // #343233 Orange
      UIColor(red: 31.0 / 255.0, green: 25.0 / 255.0, blue: 26.0 / 255.0, alpha: 1),  // #332E36 Red
      UIColor(red: 25.0 / 255.0, green: 26.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #2D2E34 Brown
      UIColor(red: 25.0 / 255.0, green: 26.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #2F3033 Ochre
      UIColor(red: 28.0 / 255.0, green: 25.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #352E3D Fuchsia
    ]
  }

  static var wizShadeLight: [UIColor] {
    return [
      UIColor(red: 106.0 / 255.0, green: 53.0 / 255.0, blue: 204.0 / 255.0, alpha: 1),  // #7A60C6 Lavender
      UIColor(red: 0.0 / 255.0, green: 129.0 / 255.0, blue: 194.0 / 255.0, alpha: 1),  // #3284C1 Blue
      UIColor(red: 16.0 / 255.0, green: 194.0 / 255.0, blue: 194.0 / 255.0, alpha: 1),  // #0CB2B1 Aqua
      UIColor(red: 0.0 / 255.0, green: 184.0 / 255.0, blue: 117.0 / 255.0, alpha: 1),  // #0EA86F Mint
      UIColor(red: 53.0 / 255.0, green: 204.0 / 255.0, blue: 53.0 / 255.0, alpha: 1),  // #22BD21 Green
      UIColor(red: 119.0 / 255.0, green: 184.0 / 255.0, blue: 15.0 / 255.0, alpha: 1),  // #72AD11 Chartreuse
      UIColor(red: 214.0 / 255.0, green: 181.0 / 255.0, blue: 17.0 / 255.0, alpha: 1),  // #CCB208 Yellow
      UIColor(red: 214.0 / 255.0, green: 135.0 / 255.0, blue: 17.0 / 255.0, alpha: 1),  // #CC8A17 Orange
      UIColor(red: 235.0 / 255.0, green: 70.0 / 255.0, blue: 38.0 / 255.0, alpha: 1),  // #C3523B Red
      UIColor(red: 163.0 / 255.0, green: 103.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),  // #8F5C20 Brown
      UIColor(red: 194.0 / 255.0, green: 164.0 / 255.0, blue: 47.0 / 255.0, alpha: 1),  // #998121 Ochre
      UIColor(red: 235.0 / 255.0, green: 94.0 / 255.0, blue: 174.0 / 255.0, alpha: 1),  // #CC5497 Fuchsia
    ]
  }

  static var wizShadeDark: [UIColor] {
    return [
      UIColor(red: 114.0 / 255.0, green: 70.0 / 255.0, blue: 235.0 / 255.0, alpha: 1),  // #5E4BB2 Lavender
      UIColor(red: 0.0 / 255.0, green: 103.0 / 255.0, blue: 163.0 / 255.0, alpha: 1),  // #2E6D94 Blue
      UIColor(red: 6.0 / 255.0, green: 153.0 / 255.0, blue: 153.0 / 255.0, alpha: 1),  // #1AA398 Aqua
      UIColor(red: 6.0 / 255.0, green: 153.0 / 255.0, blue: 95.0 / 255.0, alpha: 1),  // #1A995C Mint
      UIColor(red: 37.0 / 255.0, green: 153.0 / 255.0, blue: 31.0 / 255.0, alpha: 1),  // #37AB26 Green
      UIColor(red: 86.0 / 255.0, green: 133.0 / 255.0, blue: 16.0 / 255.0, alpha: 1),  // #749917 Chartreuse
      UIColor(red: 163.0 / 255.0, green: 146.0 / 255.0, blue: 7.0 / 255.0, alpha: 1),  // #CCB208 Yellow
      UIColor(red: 153.0 / 255.0, green: 102.0 / 255.0, blue: 6.0 / 255.0, alpha: 1),  // #CC7921 Orange
      UIColor(red: 191.0 / 255.0, green: 45.0 / 255.0, blue: 23.0 / 255.0, alpha: 1),  // #C2473C Red
      UIColor(red: 112.0 / 255.0, green: 75.0 / 255.0, blue: 22.0 / 255.0, alpha: 1),  // #704C28 Brown
      UIColor(red: 143.0 / 255.0, green: 108.0 / 255.0, blue: 29.0 / 255.0, alpha: 1),  // #8F6525 Ochre
      UIColor(red: 214.0 / 255.0, green: 69.0 / 255.0, blue: 146.0 / 255.0, alpha: 1),  // #D453A2 Fuchsia
    ]
  }

  static var wizPastelLight: [UIColor] {
    return [
      UIColor(red: 207.0 / 255.0, green: 186.0 / 255.0, blue: 245.0 / 255.0, alpha: 1),  // #7A60C6 Lavender
      UIColor(red: 178.0 / 255.0, green: 216.0 / 255.0, blue: 235.0 / 255.0, alpha: 1),  // #3284C1 Blue
      UIColor(red: 171.0 / 255.0, green: 224.0 / 255.0, blue: 224.0 / 255.0, alpha: 1),  // #0CB2B1 Aqua
      UIColor(red: 163.0 / 255.0, green: 214.0 / 255.0, blue: 195.0 / 255.0, alpha: 1),  // #0EA86F Mint
      UIColor(red: 178.0 / 255.0, green: 235.0 / 255.0, blue: 178.0 / 255.0, alpha: 1),  // #22BD21 Green
      UIColor(red: 204.0 / 255.0, green: 224.0 / 255.0, blue: 171.0 / 255.0, alpha: 1),  // #72AD11 Chartreuse
      UIColor(red: 224.0 / 255.0, green: 215.0 / 255.0, blue: 171.0 / 255.0, alpha: 1),  // #CCB208 Yellow
      UIColor(red: 224.0 / 255.0, green: 203.0 / 255.0, blue: 171.0 / 255.0, alpha: 1),  // #CC8A17 Orange
      UIColor(red: 255.0 / 255.0, green: 204.0 / 255.0, blue: 194.0 / 255.0, alpha: 1),  // #C3523B Red
      UIColor(red: 224.0 / 255.0, green: 199.0 / 255.0, blue: 171.0 / 255.0, alpha: 1),  // #8F5C20 Brown
      UIColor(red: 224.0 / 255.0, green: 214.0 / 255.0, blue: 171.0 / 255.0, alpha: 1),  // #998121 Ochre
      UIColor(red: 235.0 / 255.0, green: 178.0 / 255.0, blue: 210.0 / 255.0, alpha: 1),  // #CC5497 Fuchsia
    ]
  }

  static var wizPastelDark: [UIColor] {
    return [
      UIColor(red: 45.0 / 255.0, green: 39.0 / 255.0, blue: 61.0 / 255.0, alpha: 1),  // #5E4BB2 Lavender
      UIColor(red: 39.0 / 255.0, green: 53.0 / 255.0, blue: 61.0 / 255.0, alpha: 1),  // #2E6D94 Blue
      UIColor(red: 39.0 / 255.0, green: 61.0 / 255.0, blue: 61.0 / 255.0, alpha: 1),  // #1AA398 Aqua
      UIColor(red: 39.0 / 255.0, green: 60.0 / 255.0, blue: 61.0 / 255.0, alpha: 1),  // #1A995C Mint
      UIColor(red: 40.0 / 255.0, green: 61.0 / 255.0, blue: 39.0 / 255.0, alpha: 1),  // #37AB26 Green
      UIColor(red: 52.0 / 255.0, green: 61.0 / 255.0, blue: 39.0 / 255.0, alpha: 1),  // #749917 Chartreuse
      UIColor(red: 61.0 / 255.0, green: 59.0 / 255.0, blue: 39.0 / 255.0, alpha: 1),  // #CCB208 Yellow
      UIColor(red: 61.0 / 255.0, green: 54.0 / 255.0, blue: 39.0 / 255.0, alpha: 1),  // #CC7921 Orange
      UIColor(red: 61.0 / 255.0, green: 39.0 / 255.0, blue: 43.0 / 255.0, alpha: 1),  // #C2473C Red
      UIColor(red: 61.0 / 255.0, green: 52.0 / 255.0, blue: 39.0 / 255.0, alpha: 1),  // #704C28 Brown
      UIColor(red: 61.0 / 255.0, green: 54.0 / 255.0, blue: 39.0 / 255.0, alpha: 1),  // #8F6525 Ochre
      UIColor(red: 61.0 / 255.0, green: 39.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #D453A2 Fuchsia
    ]
  }

  public static var paletteLight: [UIColor] {
    return [
      UIColor(red: 143.0 / 255.0, green: 102.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),  // #8F66FF Lavender
      UIColor(red: 56.0 / 255.0, green: 180.0 / 255.0, blue: 252.0 / 255.0, alpha: 1),  // #38B4FC Blue
      UIColor(red: 0.227, green: 0.878, blue: 0.878, alpha: 1),  // #3AE0E0 Aqua
      UIColor(red: 0.235, green: 0.839, blue: 0.620, alpha: 1),  // #3CD69E Mint
      UIColor(red: 0.31, green: 0.92, blue: 0.31, alpha: 1),  // #50EB50 Green
      UIColor(red: 0.627, green: 0.859, blue: 0.251, alpha: 1),  // #A0DB40 Chartreuse
      UIColor(red: 0.980, green: 0.878, blue: 0.216, alpha: 1),  // #FAE037 Yellow
      UIColor(red: 255.0 / 255.0, green: 167.0 / 255.0, blue: 41.0 / 255.0, alpha: 1),  // #FFA729 Orange
      UIColor(red: 1, green: 94.0 / 255.0, blue: 77.0 / 255.0, alpha: 1),  // #FF5E4D Red
      UIColor(red: 0.741, green: 0.541, blue: 0.310, alpha: 1),  // #BD8A4F Brown
      UIColor(red: 199.0 / 255.0, green: 175.0 / 255.0, blue: 80.0 / 255.0, alpha: 1),  // #C7AF50 Ochre
      UIColor(red: 0.980, green: 0.510, blue: 0.776, alpha: 1),  // #FA82C6 Fuchsia
    ]
  }

  public static var paletteDark: [UIColor] {
    return [
      UIColor(red: 127.0 / 255.0, green: 89.0 / 255.0, blue: 245.0 / 255.0, alpha: 1),  // #7F59EB Lavender
      UIColor(red: 27.0 / 255.0, green: 162.0 / 255.0, blue: 224.0 / 255.0, alpha: 1),  // #1BA2E0 Blue
      UIColor(red: 0.173, green: 0.722, blue: 0.722, alpha: 1),  // #2CB8B8 Aqua
      UIColor(red: 0.173, green: 0.682, blue: 0.482, alpha: 1),  // #2CAE7B Mint
      UIColor(red: 64.0 / 255.0, green: 190.0 / 255.0, blue: 57.0 / 255.0, alpha: 1),  // #40BE39 Green
      UIColor(red: 0.486, green: 0.682, blue: 0.157, alpha: 1),  // #7CAE28 Chartreuse
      UIColor(red: 0.882, green: 0.843, blue: 0.106, alpha: 1),  // #E1D71B Yellow
      UIColor(red: 229.0 / 255.0, green: 139.0 / 255.0, blue: 28.0 / 255.0, alpha: 1),  // #E58B1C Orange
      UIColor(red: 227.0 / 255.0, green: 74.0 / 255.0, blue: 57.0 / 255.0, alpha: 1),  // #E34A39 Red
      UIColor(red: 0.522, green: 0.400, blue: 0.227, alpha: 1),  // #85663A Brown
      UIColor(red: 163.0 / 255.0, green: 130.0 / 255.0, blue: 56.0 / 255.0, alpha: 1),  // #A38238 Ochre
      UIColor(red: 0.910, green: 0.424, blue: 0.682, alpha: 1),  // #E86CAE Fuchsia
    ]
  }

  // glass (overlay)
  static var overlayLight: [UIColor] {
    return [
      UIColor(red: 248.0 / 255.0, green: 246.0 / 255.0, blue: 254.0 / 255.0, alpha: 1),  // #F8F6FE Lavender
      UIColor(red: 242.0 / 255.0, green: 249.0 / 255.0, blue: 254.0 / 255.0, alpha: 1),  // #F2F9FE Blue
      UIColor(red: 239.0 / 255.0, green: 253.0 / 255.0, blue: 253.0 / 255.0, alpha: 1),  // #EFFDFD Aqua
      UIColor(red: 239.0 / 255.0, green: 252.0 / 255.0, blue: 247.0 / 255.0, alpha: 1),  // #EFFCF7 Mint
      UIColor(red: 241.0 / 255.0, green: 253.0 / 255.0, blue: 241.0 / 255.0, alpha: 1),  // #F1FDF1 Green
      UIColor(red: 247.0 / 255.0, green: 252.0 / 255.0, blue: 240.0 / 255.0, alpha: 1),  // #F7FCF0 Chartreuse
      UIColor(red: 255.0 / 255.0, green: 253.0 / 255.0, blue: 239.0 / 255.0, alpha: 1),  // #FFFDEF Yellow
      UIColor(red: 255.0 / 255.0, green: 249.0 / 255.0, blue: 240.0 / 255.0, alpha: 1),  // #FFF9F0 Orange
      UIColor(red: 254.0 / 255.0, green: 245.0 / 255.0, blue: 243.0 / 255.0, alpha: 1),  // #FEF5F3 Red
      UIColor(red: 250.0 / 255.0, green: 246.0 / 255.0, blue: 241.0 / 255.0, alpha: 1),  // #FAF6F1 Brown
      UIColor(red: 251.0 / 255.0, green: 249.0 / 255.0, blue: 241.0 / 255.0, alpha: 1),  // #FBF9F1 Ochre
      UIColor(red: 255.0 / 255.0, green: 245.0 / 255.0, blue: 250.0 / 255.0, alpha: 1),  // #FFF5FA Fuchsia
    ]
  }

  static var overlayDark: [UIColor] {
    return [
      UIColor(red: 44.0 / 255.0, green: 46.0 / 255.0, blue: 63.0 / 255.0, alpha: 1),  // #2C2E3F Lavender
      UIColor(red: 39.0 / 255.0, green: 48.0 / 255.0, blue: 60.0 / 255.0, alpha: 1),  // #27303C Blue
      UIColor(red: 38.0 / 255.0, green: 52.0 / 255.0, blue: 62.0 / 255.0, alpha: 1),  // #26343E Aqua
      UIColor(red: 38.0 / 255.0, green: 52.0 / 255.0, blue: 57.0 / 255.0, alpha: 1),  // #263439 Mint
      UIColor(red: 0.18705882, green: 0.20784314, blue: 0.20487398, alpha: 1),  // Green Glass
      UIColor(red: 44.0 / 255.0, green: 52.0 / 255.0, blue: 50.0 / 255.0, alpha: 1),  // #2C3432 Chartreuse
      UIColor(red: 52.0 / 255.0, green: 55.0 / 255.0, blue: 49.0 / 255.0, alpha: 1),  // #343731 Yellow
      UIColor(red: 52.0 / 255.0, green: 50.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #343233 Orange
      UIColor(red: 51.0 / 255.0, green: 46.0 / 255.0, blue: 54.0 / 255.0, alpha: 1),  // #332E36 Red
      UIColor(red: 45.0 / 255.0, green: 46.0 / 255.0, blue: 52.0 / 255.0, alpha: 1),  // #2D2E34 Brown
      UIColor(red: 47.0 / 255.0, green: 48.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #2F3033 Ochre
      UIColor(red: 53.0 / 255.0, green: 46.0 / 255.0, blue: 61.0 / 255.0, alpha: 1),  // #352E3D Fuchsia
    ]
  }

  static var shadeLight: [UIColor] {
    return [
      UIColor(red: 117.0 / 255.0, green: 84.0 / 255.0, blue: 209.0 / 255.0, alpha: 1),  // #7554D1 Lavender
      UIColor(red: 25.0 / 255.0, green: 134.0 / 255.0, blue: 207.0 / 255.0, alpha: 1),  // #1986CF Blue
      UIColor(red: 12.0 / 255.0, green: 178.0 / 255.0, blue: 177.0 / 255.0, alpha: 1),  // #0CB2B1 Aqua
      UIColor(red: 14.0 / 255.0, green: 168.0 / 255.0, blue: 111.0 / 255.0, alpha: 1),  // #0EA86F Mint
      UIColor(red: 34.0 / 255.0, green: 189.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),  // #22BD21 Green
      UIColor(red: 114.0 / 255.0, green: 173.0 / 255.0, blue: 17.0 / 255.0, alpha: 1),  // #72AD11 Chartreuse
      UIColor(red: 204.0 / 255.0, green: 178.0 / 255.0, blue: 8.0 / 255.0, alpha: 1),  // #CCB208 Yellow
      UIColor(red: 229.0 / 255.0, green: 134.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // #E58600 Orange
      UIColor(red: 207.0 / 255.0, green: 50.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),  // #CF3221 Red
      UIColor(red: 143.0 / 255.0, green: 92.0 / 255.0, blue: 32.0 / 255.0, alpha: 1),  // #8F5C20 Brown
      UIColor(red: 153.0 / 255.0, green: 129.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),  // #998121 Ochre
      UIColor(red: 204.0 / 255.0, green: 84.0 / 255.0, blue: 151.0 / 255.0, alpha: 1),  // #CC5497 Fuchsia
    ]
  }

  static var shadeDark: [UIColor] {
    return [
      UIColor(red: 98.0 / 255.0, green: 76.0 / 255.0, blue: 199.0 / 255.0, alpha: 1),  // #624CC7 Lavender
      UIColor(red: 47.0 / 255.0, green: 147.0 / 255.0, blue: 194.0 / 255.0, alpha: 1),  // #2F93C2 Blue
      UIColor(red: 26.0 / 255.0, green: 163.0 / 255.0, blue: 152.0 / 255.0, alpha: 1),  // #1AA398 Aqua
      UIColor(red: 151.0 / 255.0, green: 83.0 / 255.0, blue: 60.0 / 255.0, alpha: 1),  // #1A995C Mint
      UIColor(red: 55.0 / 255.0, green: 171.0 / 255.0, blue: 38.0 / 255.0, alpha: 1),  // #37AB26 Green
      UIColor(red: 116.0 / 255.0, green: 153.0 / 255.0, blue: 23.0 / 255.0, alpha: 1),  // #749917 Chartreuse
      UIColor(red: 204.0 / 255.0, green: 178.0 / 255.0, blue: 8.0 / 255.0, alpha: 1),  // #CCB208 Yellow
      UIColor(red: 229.0 / 255.0, green: 113.0 / 255.0, blue: 11.0 / 255.0, alpha: 1),  // #E5710B Orange
      UIColor(red: 207.0 / 255.0, green: 58.0 / 255.0, blue: 56.0 / 255.0, alpha: 1),  // #CF3A38 Red
      UIColor(red: 112.0 / 255.0, green: 76.0 / 255.0, blue: 40.0 / 255.0, alpha: 1),  // #704C28 Brown
      UIColor(red: 143.0 / 255.0, green: 101.0 / 255.0, blue: 37.0 / 255.0, alpha: 1),  // #8F6525 Ochre
      UIColor(red: 212.0 / 255.0, green: 83.0 / 255.0, blue: 162.0 / 255.0, alpha: 1),  // #D453A2 Fuchsia
    ]
  }

  // placeholders for pastel and tone
  static var pastelLight: [UIColor] {
    return [
      UIColor(red: 202.0 / 255.0, green: 184.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),  // #CAB8FF Lavender
      UIColor(red: 184.0 / 255.0, green: 229.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),  // #B8E5FF Blue
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Aqua
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Mint
      UIColor(red: 196.0 / 255.0, green: 253.0 / 255.0, blue: 196.0 / 255.0, alpha: 1),  // #C4FDC4 Green
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Chartreuse
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Yellow
      UIColor(red: 250.0 / 255.0, green: 225.0 / 255.0, blue: 190.0 / 255.0, alpha: 1),  // #FAE1BE Orange
      UIColor(red: 255.0 / 255.0, green: 204.0 / 255.0, blue: 194.0 / 255.0, alpha: 1),  // #FFCCC2 Red
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Brown
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Ochre
      UIColor(red: 255.0 / 255.0, green: 194.0 / 255.0, blue: 224.0 / 255.0, alpha: 1),  // #XXXXXX Fuchsia
    ]
  }

  static var pastelDark: [UIColor] {
    return [
      UIColor(red: 47.0 / 255.0, green: 34.0 / 255.0, blue: 71.0 / 255.0, alpha: 1),  // #2F2247 Lavender
      UIColor(red: 29.0 / 255.0, green: 47.0 / 255.0, blue: 61.0 / 255.0, alpha: 1),  // #1D2F3D Blue
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Aqua
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Mint
      UIColor(red: 0.19781819, green: 0.32, blue: 0.192, alpha: 1),  // Green Pastel
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Chartreuse
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Yellow
      UIColor(red: 96.0 / 255.0, green: 77.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #604D33 Orange
      UIColor(red: 71.0 / 255.0, green: 37.0 / 255.0, blue: 34.0 / 255.0, alpha: 1),  // #472522 Red
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Brown
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Ochre
      UIColor(red: 71.0 / 255.0, green: 34.0 / 255.0, blue: 56.0 / 255.0, alpha: 1),  // #XXXXXX Fuchsia
    ]
  }

  static var toneLight: [UIColor] {
    return [
      UIColor(red: 97.0 / 255.0, green: 47.0 / 255.0, blue: 235.0 / 255.0, alpha: 1),  // #612FEB Lavender
      UIColor(red: 0.0 / 255.0, green: 127.0 / 255.0, blue: 212.0 / 255.0, alpha: 1),  // #007FD4 Blue
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Aqua
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Mint
      UIColor(red: 10.0 / 255.0, green: 173.0 / 255.0, blue: 10.0 / 255.0, alpha: 1),  // #0AAD0A Green
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Chartreuse
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Yellow
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Orange
      UIColor(red: 212.0 / 255.0, green: 21.0 / 255.0, blue: 0.0 / 255.0, alpha: 1),  // #D41500 Red
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Brown
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Ochre
      UIColor(red: 212.0 / 255.0, green: 0.0 / 255.0, blue: 120.0 / 255.0, alpha: 1),  // #XXXXXX Fuchsia
    ]
  }

  static var toneDark: [UIColor] {
    return [
      UIColor(red: 117.0 / 255.0, green: 66.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),  // #7542FF Lavender
      UIColor(red: 5.0 / 255.0, green: 154.0 / 255.0, blue: 240.0 / 255.0, alpha: 1),  // #059AF0 Blue
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Aqua
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Mint
      UIColor(red: 53.0 / 255.0, green: 204.0 / 255.0, blue: 53.0 / 255.0, alpha: 1),  // #35CC35 Green
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Chartreuse
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Yellow
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Orange
      UIColor(red: 255.0 / 255.0, green: 60.0 / 255.0, blue: 20.0 / 255.0, alpha: 1),  // #FF3C14 Red
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Brown
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Ochre
      UIColor(red: 250.0 / 255.0, green: 130.0 / 255.0, blue: 138.0 / 255.0, alpha: 1),  // #XXXXXX Fuchsia
    ]
  }

  // Note that these are not correct values besides the green.
  static var tintLight: [UIColor] {
    return [
      UIColor(red: 131.0 / 255.0, green: 94.0 / 255.0, blue: 235.0 / 255.0, alpha: 1),  // #835EEB Lavender
      UIColor(red: 50.0 / 255.0, green: 164.0 / 255.0, blue: 229.0 / 255.0, alpha: 1),  // #32A4E5 Blue
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Aqua
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Mint
      UIColor(red: 103.0 / 255.0, green: 213.0 / 255.0, blue: 103.0 / 255.0, alpha: 1),  // #67D567 Green
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Chartreuse
      UIColor(red: 214.0 / 255.0, green: 193.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #D6C133 Yellow
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Orange
      UIColor(red: 232.0 / 255.0, green: 90.0 / 255.0, blue: 74.0 / 255.0, alpha: 1),  // #E85A4A Red
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Brown
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Ochre
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Fuchsia
    ]
  }

  static var tintDark: [UIColor] {
    return [
      UIColor(red: 66.0 / 255.0, green: 37.0 / 255.0, blue: 133.0 / 255.0, alpha: 1),  // #422585 Lavender
      UIColor(red: 17.0 / 255.0, green: 81.0 / 255.0, blue: 128.0 / 255.0, alpha: 1),  // #115180 Blue
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Aqua
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Mint
      UIColor(red: 25.0 / 255.0, green: 117.0 / 255.0, blue: 25.0 / 255.0, alpha: 1),  // #197519 Green
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Chartreuse
      UIColor(red: 117.0 / 255.0, green: 105.0 / 255.0, blue: 36.0 / 255.0, alpha: 1),  // #756924 Yellow
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Orange
      UIColor(red: 135.0 / 255.0, green: 47.0 / 255.0, blue: 41.0 / 255.0, alpha: 1),  // #872F29 Red
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Brown
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Ochre
      UIColor(red: 37.0 / 255.0, green: 41.0 / 255.0, blue: 51.0 / 255.0, alpha: 1),  // #XXXXXX Fuchsia
    ]
  }

  public static func colorPalette(for dtColorPalette: ColorPalette) -> UIColor {
    return paletteForIndex(dtColorPalette.rawValue)
  }
  public static func paletteForIndex(_ colorPaletteIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = max(0, colorPaletteIndex % UIColor.paletteDark.count)
        return UIColor.paletteDark[index]
      default:
        let index = max(0, colorPaletteIndex % UIColor.paletteLight.count)
        return UIColor.paletteLight[index]
      }
    }
  }

  public static func overlayPalette(for palette: ColorPalette) -> UIColor {
    return overlayForIndex(palette.rawValue)
  }
  static func overlayForIndex(_ glassColorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = glassColorIndex % UIColor.paletteDark.count
        return UIColor.overlayDark[index]
      default:
        let index = glassColorIndex % UIColor.paletteLight.count
        return UIColor.overlayLight[index]
      }
    }
  }

  public static func shadePalette(for palette: ColorPalette) -> UIColor {
    return shadeForIndex(palette.rawValue)
  }
  static func shadeForIndex(_ shadeColorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = shadeColorIndex % UIColor.paletteDark.count
        return UIColor.shadeDark[index]
      default:
        let index = shadeColorIndex % UIColor.paletteLight.count
        return UIColor.shadeLight[index]
      }
    }
  }

  public static func pastelPalette(for palette: ColorPalette) -> UIColor {
    return pastelForIndex(palette.rawValue)
  }
  static func pastelForIndex(_ colorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = colorIndex % UIColor.paletteDark.count
        return UIColor.pastelDark[index]
      default:
        let index = colorIndex % UIColor.paletteLight.count
        return UIColor.pastelLight[index]
      }
    }
  }

  public static func tonePalette(for palette: ColorPalette) -> UIColor {
    return toneForIndex(palette.rawValue)
  }
  static func toneForIndex(_ colorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = colorIndex % UIColor.paletteDark.count
        return UIColor.toneDark[index]
      default:
        let index = colorIndex % UIColor.paletteLight.count
        return UIColor.toneLight[index]
      }
    }
  }

  public static func tintPalette(for palette: ColorPalette) -> UIColor {
    return tintForIndex(palette.rawValue)
  }
  static func tintForIndex(_ colorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = colorIndex % UIColor.paletteDark.count
        return UIColor.tintDark[index]
      default:
        let index = colorIndex % UIColor.paletteLight.count
        return UIColor.tintLight[index]
      }
    }
  }

  public static func wizColorPalette(for colorPalette: ColorPalette) -> UIColor {
    return wizPaletteForIndex(colorPalette.rawValue)
  }
  public static func wizPaletteForIndex(_ colorPaletteIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = colorPaletteIndex % UIColor.wizPaletteDark.count
        return UIColor.wizPaletteDark[index]
      default:
        let index = colorPaletteIndex % UIColor.wizPaletteLight.count
        return UIColor.wizPaletteLight[index]
      }
    }
  }

  public static func wizOverlayPalette(for palette: ColorPalette) -> UIColor {
    return wizOverlayForIndex(palette.rawValue)
  }
  static func wizOverlayForIndex(_ glassColorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = glassColorIndex % UIColor.paletteDark.count
        return UIColor.wizOverlayDark[index]
      default:
        let index = glassColorIndex % UIColor.paletteLight.count
        return UIColor.wizOverlayLight[index]
      }
    }
  }

  public static func wizShadePalette(for palette: ColorPalette) -> UIColor {
    return wizShadeForIndex(palette.rawValue)
  }
  static func wizShadeForIndex(_ shadeColorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = shadeColorIndex % UIColor.paletteDark.count
        return UIColor.wizShadeDark[index]
      default:
        let index = shadeColorIndex % UIColor.paletteLight.count
        return UIColor.wizShadeLight[index]
      }
    }
  }

  public static func wizPastelPalette(for palette: ColorPalette) -> UIColor {
    return wizPastelForIndex(palette.rawValue)
  }
  static func wizPastelForIndex(_ shadeColorIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = shadeColorIndex % UIColor.paletteDark.count
        return UIColor.wizPastelDark[index]
      default:
        let index = shadeColorIndex % UIColor.paletteLight.count
        return UIColor.wizPastelLight[index]
      }
    }
  }

  public static func wizToneColorPalette(for colorPalette: ColorPalette) -> UIColor {
    return wizTonePaletteForIndex(colorPalette.rawValue)
  }

  public static func wizTonePaletteForIndex(_ colorPaletteIndex: Int) -> UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .dark:
        let index = colorPaletteIndex % UIColor.wizTonePaletteDark.count
        return UIColor.wizTonePaletteDark[index]
      default:
        let index = colorPaletteIndex % UIColor.wizTonePaletteLight.count
        return UIColor.wizTonePaletteLight[index]
      }
    }
  }
}

extension UIColor {
  public static var disabled: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey400
      default:
        return .grey500
      }
    }
  }

  public static var warning: UIColor {
    return colorPalette(for: .yellow)
  }

  public static var error: UIColor {
    return colorPalette(for: .red)
  }
}

extension UIColor {
  // semantic color library
  // backgrounds
  // app background
  public static var primaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey100
      }
    }
  }

  // nav and secondary menu background
  public static var secondaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1100
      default:
        return .grey200
      }
    }
  }

  // editor background
  public static var tertiaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1200
      default:
        return .grey300
      }
    }
  }

  // prompt background
  public static var quaternaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1100
      default:
        return .grey400
      }
    }
  }

  // selected state for projects and scripts
  public static var quinaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey400
      }
    }
  }

  // image history cell background
  public static var senaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey300
      }
    }
  }

  // button loading background
  public static var septenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey900
      default:
        return .grey300
      }
    }
  }

  // connecting status loading background
  public static var octonaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey500
      }
    }
  }

  public static var undenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey000.withAlphaComponent(0.04)
      default:
        return .grey1200.withAlphaComponent(0.04)
      }
    }
  }

  public static var duodenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey000.withAlphaComponent(0.04)
      default:
        return .grey1200.withAlphaComponent(0.04)
      }
    }
  }

  public static var quattuordecenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey1000
      }
    }
  }

  public static var quindecenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey000.withAlphaComponent(0.32)
      default:
        return .grey000.withAlphaComponent(0.32)
      }
    }
  }

  public static var sedecenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey900
      default:
        return .grey500
      }
    }
  }

  public static var octodecenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1100
      default:
        return .grey400
      }
    }
  }

  public static var novemdecenaryBackground: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1150
      default:
        return .grey350
      }
    }
  }

  // labels
  // page title
  public static var primaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey400
      default:
        return .grey900
      }
    }
  }

  // section title
  public static var secondaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey500
      default:
        return .grey800
      }
    }
  }

  public static var tertiaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey600
      default:
        return .grey800
      }
    }
  }

  // detail tool tip
  public static var quaternaryText: UIColor {
    return .grey700
  }

  // generate button
  public static var quinaryText: UIColor {
    return .grey1200
  }

  // title button, detail icon, unselected cells interactive colors
  public static var senaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey600
      default:
        return .grey700
      }
    }
  }

  // image history view's cell icon
  public static var septenaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey700
      default:
        return .grey600
      }
    }
  }

  public static var octonaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey400
      default:
        return .grey1200
      }
    }
  }

  public static var nonaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1200
      default:
        return .grey400
      }
    }
  }

  public static var denaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey900
      default:
        return .grey400
      }
    }
  }

  public static var undenaryText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey500
      default:
        return .grey500
      }
    }
  }

  // fills
  // selected state's contents segmented control, aspect ratio
  public static var primaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey400
      default:
        return .grey1100
      }
    }
  }

  // slider max segment
  public static var secondaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey900
      default:
        return .grey400
      }
    }
  }

  // button's background
  public static var tertiaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1200
      default:
        return .grey400
      }
    }
  }

  // selected segmented control's background
  public static var quaternaryFillA: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1200
      default:
        return .grey000
      }
    }
  }

  // unused value that matches with figma design
  public static var quaternaryFillB: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1200
      default:
        return .grey500
      }
    }
  }

  // machine buttons
  public static var quinaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey900
      default:
        return .grey200
      }
    }
  }

  // selected segmented control's bar
  public static var senaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1200
      default:
        return .grey500
      }
    }
  }
  // disabled buttons
  public static var septenaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey400
      }
    }
  }
  // readonly capsule and tags
  public static var octonaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1000
      default:
        return .grey300
      }
    }
  }
  // secondary button such as timers
  public static var nonaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1200
      default:
        return .grey300
      }
    }
  }

  public static var denaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey1100
      default:
        return .grey200
      }
    }
  }

  public static var undenaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey200
      default:
        return .grey1100
      }
    }
  }

  public static var duodenaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey000.withAlphaComponent(0.08)
      default:
        return .grey1200.withAlphaComponent(0.08)
      }
    }
  }

  public static var tredecenaryFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey400
      default:
        return .grey400
      }
    }
  }

  public static var quindecenaryFill: UIColor {
    UIColor.black.withAlphaComponent(0.08)
  }

  // border
  public static var primaryBorder: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey900
      default:
        return .grey400
      }
    }
  }

  public static var secondaryBorder: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey800
      default:
        return .grey500
      }
    }
  }

  // context button divider
  public static var tertiaryBorder: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey000.withAlphaComponent(0.08)
      default:
        return .grey1200.withAlphaComponent(0.08)
      }
    }
  }

  // default state for aspect ratio cell
  public static var quaternaryBorder: UIColor {
    return .grey600
  }

  // generate button divider
  public static var quinaryBorder: UIColor {
    return .grey000.withAlphaComponent(0.08)
  }

  // generate button divider
  public static var denaryBorder: UIColor {
    return .grey000.withAlphaComponent(0.16)
  }

  public static var senaryBorder: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey700
      default:
        return .grey600
      }
    }
  }

  public static var duodenaryBorder: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey850
      default:
        return .grey450
      }
    }
  }

  // accents
  // background
  public static var errorBackground: UIColor {
    return overlayPalette(for: .red)
  }

  public static var warningBackground: UIColor {
    return overlayPalette(for: .yellow)
  }

  public static var successBackground: UIColor {
    return overlayPalette(for: .green)
  }

  public static var promptBackground: UIColor {
    return overlayPalette(for: .blue)
  }

  // labels
  public static var errorText: UIColor {
    return colorPalette(for: .red)
  }

  public static var warningText: UIColor {
    return tintPalette(for: .yellow)
  }

  public static var successText: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return shadePalette(for: .green)
      default:
        return colorPalette(for: .green)
      }
    }
  }

  public static var promptText: UIColor {
    return colorPalette(for: .blue)
  }

  // fills
  public static var errorFill: UIColor {
    return colorPalette(for: .red)
  }

  public static var warningFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return shadePalette(for: .yellow)
      default:
        return colorPalette(for: .yellow)
      }
    }
  }

  public static var successFill: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return shadePalette(for: .green)
      default:
        return colorPalette(for: .green)
      }
    }
  }

  public static var promptFill: UIColor {
    return colorPalette(for: .blue)
  }

  // borders
  public static var errorBorder: UIColor {
    return colorPalette(for: .red)
  }

  public static var warningBorder: UIColor {
    return tintPalette(for: .yellow)
  }

  public static var successBorder: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return shadePalette(for: .green)
      default:
        return colorPalette(for: .green)
      }
    }
  }

  public static var promptBorderBlue: UIColor {
    return colorPalette(for: .blue)
  }

  public static var promptBorderGrey: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return .grey900
      default:
        return .grey500
      }
    }
  }

  public static var primaryShadow: UIColor {
    UIColor { traitCollection in
      switch traitCollection.userInterfaceStyle {
      case .light:
        return UIColor(white: 0, alpha: 0.16)
      default:
        return UIColor(white: 0, alpha: 0.72)
      }
    }
  }
}

extension UIColor {
  public static func interpolate(from: UIColor, to: UIColor, with fraction: CGFloat) -> UIColor {
    let f = min(max(0, fraction), 1)

    var startR: CGFloat = 0
    var startG: CGFloat = 0
    var startB: CGFloat = 0
    var startA: CGFloat = 0
    from.getRed(&startR, green: &startG, blue: &startB, alpha: &startA)

    var endR: CGFloat = 0
    var endG: CGFloat = 0
    var endB: CGFloat = 0
    var endA: CGFloat = 0
    to.getRed(&endR, green: &endG, blue: &endB, alpha: &endA)

    // Interpolate each component
    let r = startR + (endR - startR) * f
    let g = startG + (endG - startG) * f
    let b = startB + (endB - startB) * f
    let a = startA + (endA - startA) * f

    // Create interpolated color
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }
}

extension UIColor {
  // DT Plus gradient
  public static var primaryGradientColors: [UIColor] {
    [
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          UIColor(red: 255.0 / 255.0, green: 94.0 / 255.0, blue: 77.0 / 255.0, alpha: 1)
        default:
          UIColor(red: 227.0 / 255.0, green: 74.0 / 255.0, blue: 57.0 / 255.0, alpha: 1)
        }
      },
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          UIColor(red: 143.0 / 255.0, green: 102.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)
        default:
          UIColor(red: 127.0 / 255.0, green: 89.0 / 255.0, blue: 235.0 / 255.0, alpha: 1)
        }
      },
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          UIColor(red: 56.0 / 255.0, green: 180.0 / 255.0, blue: 252.0 / 255.0, alpha: 1)
        default:
          UIColor(red: 27.0 / 255.0, green: 162.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
        }
      },
    ]
  }

  public static var secondaryGradientColors: [UIColor] {
    [
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          UIColor(red: 232.0 / 255.0, green: 90.0 / 255.0, blue: 74.0 / 255.0, alpha: 1)
        default:
          UIColor(red: 204.0 / 255.0, green: 70.0 / 255.0, blue: 55.0 / 255.0, alpha: 1)
        }
      },
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          UIColor(red: 131.0 / 255.0, green: 164.0 / 255.0, blue: 229.0 / 255.0, alpha: 1)
        default:
          UIColor(red: 116.0 / 255.0, green: 81.0 / 255.0, blue: 214.0 / 255.0, alpha: 1)
        }
      },
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          UIColor(red: 50.0 / 255.0, green: 164.0 / 255.0, blue: 229.0 / 255.0, alpha: 1)
        default:
          UIColor(red: 24.0 / 255.0, green: 146.0 / 255.0, blue: 201.0 / 255.0, alpha: 1)
        }
      },
    ]
  }
  // DT Max gradient
  public static var metalPrimaryGradientColors: [UIColor] {
    [
      // A (0%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 85.0 / 255.0, green: 94.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
        }
      },
      // B (15%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 218.0 / 255.0, green: 221.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        }
      },
      // C (25%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 85.0 / 255.0, green: 94.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
        }
      },
      // D (40%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 85.0 / 255.0, green: 94.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
        }
      },
      // E (50%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        }
      },
      // F (60%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 85.0 / 255.0, green: 94.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
        }
      },
      // G (75%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 85.0 / 255.0, green: 94.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
        }
      },
      // H (85%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 218.0 / 255.0, green: 221.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        }
      },
      // I (100%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 85.0 / 255.0, green: 94.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
        }
      },
    ]
  }

  public static var metalSecondaryGradientColors: [UIColor] {
    [
      // A (0%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 218.0 / 255.0, green: 221.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        }
      },
      // B (15%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        }
      },
      // C (50%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 85.0 / 255.0, green: 94.0 / 255.0, blue: 104.0 / 255.0, alpha: 1)
        }
      },
      // D (85%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 140.0 / 255.0, green: 151.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        }
      },
      // E (100%)
      UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 218.0 / 255.0, green: 221.0 / 255.0, blue: 224.0 / 255.0, alpha: 1)
        default:
          return UIColor(red: 183.0 / 255.0, green: 191.0 / 255.0, blue: 199.0 / 255.0, alpha: 1)
        }
      },
    ]
  }

}
