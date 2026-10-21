import UIKit

/// A rim glow for drop targets: `RimGlowWashes` shown only in a soft band along the rounded edge.
/// The CSS blur is left out; the washes are already soft at this size.
public final class RimGlowController {
  public enum CornerRadius {
    /// The radius of the view the glow covers.
    case fixed(CGFloat)
    /// Each corner concentric with the glow's container, such as the display or a sheet, for a
    /// view that reaches its container's edge without rounded corners of its own. The corners
    /// are square before iOS 26, which can't tell.
    case containerConcentric
  }

  private static let strength: CGFloat = 0.5
  /// The band starts at the edge and fades out over this many points.
  private static let rimSoftness: CGFloat = 16

  public let view: GradientView

  public private(set) var isGlowing = false

  /// Without animation, the glow also drops any fade in flight, for when the view is about to
  /// resize and a fading glow would show at the old size.
  public func setGlowing(_ isGlowing: Bool, animated: Bool) {
    let wasGlowing = self.isGlowing
    self.isGlowing = isGlowing
    if isGlowing && !wasGlowing {
      layoutWashes()
      washes.addAnimations()
    }
    guard animated else {
      view.layer.removeAllAnimations()
      view.alpha = isGlowing ? Self.strength : 0
      if !isGlowing {
        washes.removeAnimations()
      }
      return
    }
    guard isGlowing != wasGlowing else { return }
    UIView.animate(
      withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]
    ) {
      self.view.alpha = isGlowing ? Self.strength : 0
    } completion: { _ in
      guard !self.isGlowing else { return }
      self.washes.removeAnimations()
    }
  }

  private let cornerRadius: CornerRadius
  private let washes = RimGlowWashes()
  private let maskLayer = CALayer()

  /// The corner radius matches the view the glow covers, so the band follows its edge.
  public init(cornerRadius: CornerRadius) {
    self.cornerRadius = cornerRadius
    view = GradientView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.alpha = 0
    if case .containerConcentric = cornerRadius, #available(iOS 26.0, *) {
      view.cornerConfiguration = .corners(radius: .containerConcentric())
    }
    view.layer.addSublayer(washes.layer)
    view.layer.mask = maskLayer
    view.onLayoutChange = { [weak self] _ in
      guard let self, self.isGlowing else { return }
      self.layoutWashes()
    }
  }

  private func layoutWashes() {
    let bounds = view.bounds
    // Fill everything outside the rounded edge; its shadow falls inward, leaving a soft band
    // along the edge and the inside clear. Shadow blur is in pixels, not points.
    let format = UIGraphicsImageRendererFormat.preferred()
    let mask = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
      let path = UIBezierPath(rect: bounds.insetBy(dx: -Self.rimSoftness, dy: -Self.rimSoftness))
      path.append(edgePath(in: bounds))
      path.usesEvenOddFillRule = true
      context.cgContext.setShadow(
        offset: .zero, blur: Self.rimSoftness * format.scale,
        color: UIColor.black.cgColor)
      UIColor.black.setFill()
      path.fill()
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    maskLayer.frame = bounds
    maskLayer.contents = mask.cgImage
    maskLayer.contentsScale = mask.scale
    washes.layout(in: bounds)
    CATransaction.commit()
  }

  private func edgePath(in bounds: CGRect) -> UIBezierPath {
    switch cornerRadius {
    case .fixed(let radius):
      return UIBezierPath(roundedRect: bounds, cornerRadius: radius)
    case .containerConcentric:
      guard #available(iOS 26.0, *) else { return UIBezierPath(rect: bounds) }
      // Called from layoutSubviews, so a change in these radii lays the glow out again. Corners
      // can differ, such as a canvas meeting the display's corners on one side only.
      let topLeft = CGPoint(x: bounds.minX, y: bounds.minY)
      let topRight = CGPoint(x: bounds.maxX, y: bounds.minY)
      let bottomRight = CGPoint(x: bounds.maxX, y: bounds.maxY)
      let bottomLeft = CGPoint(x: bounds.minX, y: bounds.maxY)
      let path = CGMutablePath()
      path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
      path.addArc(
        tangent1End: topRight, tangent2End: bottomRight,
        radius: view.effectiveRadius(corner: .topRight))
      path.addArc(
        tangent1End: bottomRight, tangent2End: bottomLeft,
        radius: view.effectiveRadius(corner: .bottomRight))
      path.addArc(
        tangent1End: bottomLeft, tangent2End: topLeft,
        radius: view.effectiveRadius(corner: .bottomLeft))
      path.addArc(
        tangent1End: topLeft, tangent2End: topRight,
        radius: view.effectiveRadius(corner: .topLeft))
      path.closeSubpath()
      return UIBezierPath(cgPath: path)
    }
  }
}
