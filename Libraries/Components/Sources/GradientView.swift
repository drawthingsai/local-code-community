import UIKit

public final class GradientView: UIView {
  override class public var layerClass: AnyClass { CAGradientLayer.self }

  public var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

  public var onLayoutChange: ((GradientView) -> Void)? = nil

  public var colors = [UIColor]() {
    didSet {
      gradientLayer.colors = colors.map { $0.cgColor }
    }
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    onLayoutChange?(self)
  }

  public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    gradientLayer.colors = colors.map { $0.cgColor }
  }
}
