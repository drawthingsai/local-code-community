import UIKit

public final class GlossyView: UIView {
  public var isHighlighted: Bool = false
  public var isEnabled: Bool = false
  public override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }
    guard isEnabled else {
      context.saveGState()
      context.addRect(rect)
      context.setFillColor(UIColor.septenaryFill.cgColor)
      context.drawPath(using: .fill)
      context.restoreGState()
      return
    }

    guard !isHighlighted else {
      context.saveGState()
      context.addRect(rect)
      context.setFillColor(UIColor.wizColorPalette(for: .lavender).cgColor)
      context.drawPath(using: .fill)
      context.restoreGState()
      // Inner shadow
      context.saveGState()
      let innerShadowPath = UIBezierPath(
        roundedRect: rect.insetBy(dx: -6, dy: -6), cornerRadius: rect.height / 2 + 6)
      context.addPath(innerShadowPath.cgPath)
      context.setLineWidth(11)
      context.setStrokeColor(UIColor.white.cgColor)
      context.setShadow(
        offset: CGSize(width: 0, height: 4), blur: 8,
        color: UIColor.wizShadePalette(for: .lavender).cgColor)
      context.strokePath()
      context.restoreGState()
      return
    }

    // Gradient background
    let backgroundColors: CFArray
    if traitCollection.userInterfaceStyle == .dark {
      backgroundColors =
        [
          UIColor(red: 135.0 / 255.0, green: 93.0 / 255.0, blue: 222.0 / 255.0, alpha: 1).cgColor,
          UIColor(red: 112.0 / 255.0, green: 55.0 / 255.0, blue: 229.0 / 255.0, alpha: 1).cgColor,
          UIColor(red: 112.0 / 255.0, green: 55.0 / 255.0, blue: 229.0 / 255.0, alpha: 1).cgColor,
        ] as CFArray
    } else {
      backgroundColors =
        [
          UIColor(red: 173.0 / 255.0, green: 137.0 / 255.0, blue: 245.0 / 255.0, alpha: 1).cgColor,
          UIColor(red: 146.0 / 255.0, green: 92.0 / 255.0, blue: 1, alpha: 1).cgColor,
          UIColor(red: 146.0 / 255.0, green: 92.0 / 255.0, blue: 1, alpha: 1).cgColor,
        ] as CFArray
    }
    let backgroundGradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: backgroundColors,
      locations: [0.0, 0.5, 1.0])!
    context.saveGState()
    context.addRect(rect)
    context.clip()
    context.drawLinearGradient(
      backgroundGradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: rect.height),
      options: [])
    context.restoreGState()

    // Inner shadow
    context.saveGState()
    let innerShadowPath = UIBezierPath(
      roundedRect: rect.insetBy(dx: -6, dy: -6), cornerRadius: rect.height / 2 + 6)
    context.addPath(innerShadowPath.cgPath)
    context.setLineWidth(11)
    context.setStrokeColor(UIColor.white.cgColor)
    if traitCollection.userInterfaceStyle == .dark {
      context.setShadow(
        offset: CGSize(width: 0, height: 4), blur: 8,
        color: UIColor(red: 159.0 / 255.0, green: 135.0 / 255.0, blue: 224.0 / 255.0, alpha: 0.5)
          .cgColor)
    } else {
      context.setShadow(
        offset: CGSize(width: 0, height: 4), blur: 8,
        color: UIColor(red: 211.0 / 255.0, green: 173.0 / 255.0, blue: 1, alpha: 0.5)
          .cgColor)
    }
    context.strokePath()
    context.restoreGState()

    // Gradient stroke
    let strokeColors: CFArray
    if traitCollection.userInterfaceStyle == .dark {
      strokeColors =
        [
          UIColor(red: 90.0 / 255.0, green: 39.0 / 255.0, blue: 194.0 / 255.0, alpha: 0).cgColor,
          UIColor(red: 90.0 / 255.0, green: 39.0 / 255.0, blue: 194.0 / 255.0, alpha: 0).cgColor,
          UIColor(red: 90.0 / 255.0, green: 39.0 / 255.0, blue: 194.0 / 255.0, alpha: 0).cgColor,
          UIColor(red: 90.0 / 255.0, green: 39.0 / 255.0, blue: 194.0 / 255.0, alpha: 0.5).cgColor,
        ] as CFArray
    } else {
      strokeColors =
        [
          UIColor(red: 127.0 / 255.0, green: 69.0 / 255.0, blue: 245.0 / 255.0, alpha: 0).cgColor,
          UIColor(red: 127.0 / 255.0, green: 69.0 / 255.0, blue: 245.0 / 255.0, alpha: 0).cgColor,
          UIColor(red: 127.0 / 255.0, green: 69.0 / 255.0, blue: 245.0 / 255.0, alpha: 0).cgColor,
          UIColor(red: 127.0 / 255.0, green: 69.0 / 255.0, blue: 245.0 / 255.0, alpha: 0.5).cgColor,
        ] as CFArray
    }
    let strokeGradient = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: strokeColors,
      locations: [0.0, 0.33, 0.67, 1.0])!

    let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
    context.saveGState()
    context.addPath(path.cgPath)
    context.setLineWidth(4)
    context.replacePathWithStrokedPath()
    context.clip()
    let startPoint = CGPoint(x: rect.minX, y: rect.minY)
    let endPoint = CGPoint(x: rect.minX, y: rect.maxY)
    context.drawLinearGradient(strokeGradient, start: startPoint, end: endPoint, options: [])
    context.restoreGState()
  }

  private var buttonPressStateController: ButtonPressStateController? = nil

  // This should be called once to associate its state with the button state.
  public func connect(_ button: UIButton) {
    button.configurationUpdateHandler = { [weak self] in
      guard let self = self else { return }
      if $0.state.contains(.selected) || $0.state.contains(.focused)
        || $0.state.contains(.highlighted)
      {
        self.isHighlighted = true
        self.isEnabled = true
      } else if $0.state.contains(.disabled) {
        self.isHighlighted = false
        self.isEnabled = false
      } else {
        self.isHighlighted = false
        self.isEnabled = true
      }
      self.setNeedsDisplay()
    }
    buttonPressStateController = ButtonPressStateController(button)
  }
}
