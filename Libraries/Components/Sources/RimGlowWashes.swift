import UIKit

/// The rim glow's seven radial washes, ported from the "Get Pro" button's CSS. They drift around
/// a unit square while their hues cycle; an owner sizes them with `layout(in:)` and masks them
/// to a band along its edge. CALayer filters are unavailable on iOS, so the hue rotation
/// animates the gradient colors instead.
public final class RimGlowWashes {
  private struct Wash {
    /// The SVG gradientTransform's linear part, in the 67×42 viewBox.
    var transform: CGAffineTransform
    var opacity: Float
    var stops: [(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, location: Double)]
    /// background-position at 0%, 25%, 50% and 75% of the drift.
    var positions: [CGPoint]
  }

  // Topmost first, like the CSS background-image list.
  private static let washes: [Wash] = [
    Wash(
      transform: CGAffineTransform(a: 0.34726, b: 0, c: 0, d: 0.89585, tx: 0, ty: 0),
      opacity: 0.88, stops: [(0, 110, 245, 1, 0), (0, 110, 245, 0, 1)],
      positions: [CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), .zero]),
    Wash(
      transform: CGAffineTransform(a: -1.3, b: 0.25, c: -1.2633, d: -2.7471, tx: 0, ty: 0),
      opacity: 0.5, stops: [(0, 110, 245, 1, 0), (0, 110, 245, 0, 1)],
      positions: [
        CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1),
      ]),
    Wash(
      transform: CGAffineTransform(a: 1.05, b: -0.8, c: 0.46018, d: 3.6184, tx: 0, ty: 0),
      opacity: 0.4, stops: [(204, 0, 167, 1, 0), (170, 0, 204, 0, 0.71709)],
      positions: [
        CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1), .zero,
      ]),
    Wash(
      transform: CGAffineTransform(a: -0.51067, b: 0, c: 0, d: -1.1396, tx: 0, ty: 0),
      opacity: 1, stops: [(204, 0, 167, 1, 0), (170, 0, 204, 0, 1)],
      positions: [CGPoint(x: 0, y: 1), .zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]),
    Wash(
      transform: CGAffineTransform(a: -0.45, b: -0.75, c: 1.9052, d: -0.7091, tx: 0, ty: 0),
      opacity: 1, stops: [(255, 173, 85, 1, 0), (255, 173, 85, 0, 1)],
      positions: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1)]),
    Wash(
      transform: CGAffineTransform(a: 1.25, b: -0.35, c: -0.4013, d: 3.5959, tx: 0, ty: 0),
      opacity: 1,
      stops: [
        (0, 204, 68, 1, 0), (0, 196, 102, 0.75, 0.25), (0, 187, 136, 0.5, 0.5),
        (0, 170, 204, 0, 1),
      ],
      positions: [
        CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
      ]),
    Wash(
      transform: CGAffineTransform(a: -0.87391, b: 0.73043, c: -4.1482, d: -1.9503, tx: 0, ty: 0),
      opacity: 1, stops: [(0, 170, 204, 1, 0), (0, 170, 204, 0, 1)],
      positions: [
        CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5), .zero, CGPoint(x: 1, y: 0.5),
      ]),
  ]

  private static let hueDuration: CFTimeInterval = 4
  private static let driftDuration: CFTimeInterval = 5

  /// A unit square scaled to the owner's bounds, so the drift keeps running through resizes.
  public let layer = CALayer()

  private let containerLayers: [CALayer]
  private let gradientLayers: [CAGradientLayer]

  public init() {
    layer.anchorPoint = .zero
    layer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    layer.position = .zero
    var containerLayers = [CALayer]()
    var gradientLayers = [CAGradientLayer]()
    for wash in Self.washes.reversed() {
      let gradientLayer = CAGradientLayer()
      gradientLayer.type = .radial
      // The SVG gradient is a radius-10 circle at the viewBox center, mapped by its transform.
      gradientLayer.bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
      gradientLayer.position = CGPoint(x: 33.5, y: 21)
      gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
      gradientLayer.endPoint = CGPoint(x: 1, y: 1)
      gradientLayer.colors = Self.colors(for: wash, hueRotation: 0)
      gradientLayer.locations = wash.stops.map { NSNumber(value: $0.location) }
      gradientLayer.opacity = wash.opacity
      gradientLayer.setAffineTransform(wash.transform)
      // Each wash is 180% of the square, slid across its 80% excess.
      let containerLayer = CALayer()
      containerLayer.bounds = CGRect(x: 0, y: 0, width: 67, height: 42)
      containerLayer.transform = CATransform3DMakeScale(1.8 / 67, 1.8 / 42, 1)
      containerLayer.position = Self.washPosition(wash.positions[0])
      containerLayer.addSublayer(gradientLayer)
      layer.addSublayer(containerLayer)
      containerLayers.append(containerLayer)
      gradientLayers.append(gradientLayer)
    }
    self.containerLayers = containerLayers.reversed()
    self.gradientLayers = gradientLayers.reversed()
  }

  /// Without implicit animation; call inside the owner's own transaction to batch it.
  public func layout(in bounds: CGRect) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.position = bounds.origin
    layer.transform = CATransform3DMakeScale(bounds.width, bounds.height, 1)
    CATransaction.commit()
  }

  public func addAnimations() {
    // Reduce Motion holds the first frame, which still reads as a rim glow.
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    for (containerLayer, wash) in zip(containerLayers, Self.washes) {
      let drift = CAKeyframeAnimation(keyPath: "position")
      drift.values = (wash.positions + [wash.positions[0]]).map {
        NSValue(cgPoint: Self.washPosition($0))
      }
      drift.keyTimes = [0, 0.25, 0.5, 0.75, 1]
      drift.timingFunctions = Array(
        repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
      drift.duration = Self.driftDuration
      drift.repeatCount = .infinity
      containerLayer.add(drift, forKey: "drift")
    }
    for (gradientLayer, wash) in zip(gradientLayers, Self.washes) {
      let hue = CAKeyframeAnimation(keyPath: "colors")
      // hue-rotate(-360deg): a full turn backwards in 30° steps, ending where it starts.
      hue.values = (0...12).map { Self.colors(for: wash, hueRotation: -CGFloat($0) / 12) }
      hue.duration = Self.hueDuration
      hue.repeatCount = .infinity
      gradientLayer.add(hue, forKey: "hue")
    }
  }

  public func removeAnimations() {
    containerLayers.forEach { $0.removeAnimation(forKey: "drift") }
    gradientLayers.forEach { $0.removeAnimation(forKey: "hue") }
  }

  /// Where a wash sits for a background-position, in the unit square.
  private static func washPosition(_ position: CGPoint) -> CGPoint {
    CGPoint(x: 0.9 - 0.8 * position.x, y: 0.9 - 0.8 * position.y)
  }

  /// The CSS colors with saturate(1.3), hue-rotated by a fraction of a turn.
  private static func colors(for wash: Wash, hueRotation: CGFloat) -> [CGColor] {
    wash.stops.map { stop in
      var hue: CGFloat = 0
      var saturation: CGFloat = 0
      var brightness: CGFloat = 0
      var alpha: CGFloat = 0
      UIColor(red: stop.red / 255, green: stop.green / 255, blue: stop.blue / 255, alpha: 1)
        .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
      let rotated = (hue + hueRotation).truncatingRemainder(dividingBy: 1)
      return UIColor(
        hue: rotated < 0 ? rotated + 1 : rotated, saturation: min(1, saturation * 1.3),
        brightness: brightness, alpha: stop.alpha
      ).cgColor
    }
  }
}
