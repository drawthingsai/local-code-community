import UIKit

public final class DashBorderView: UIView {
  override class public var layerClass: AnyClass { CAShapeLayer.self }

  public var dashBorderLayer: CAShapeLayer { layer as! CAShapeLayer }

  public var borderColor: UIColor = .clear {
    didSet {
      dashBorderLayer.strokeColor = borderColor.cgColor
    }
  }

  public var lineWidth: CGFloat = 1 {
    didSet {
      dashBorderLayer.lineWidth = lineWidth
      setNeedsLayout()
    }
  }

  public var lineDashPattern: [NSNumber]? = [6, 5] {
    didSet {
      dashBorderLayer.lineDashPattern = lineDashPattern
    }
  }

  public var lineDashPhase: CGFloat = 0 {
    didSet {
      dashBorderLayer.lineDashPhase = lineDashPhase
    }
  }

  public override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    dashBorderLayer.fillColor = UIColor.clear.cgColor
    dashBorderLayer.strokeColor = borderColor.cgColor
    dashBorderLayer.lineWidth = lineWidth
    dashBorderLayer.lineDashPattern = lineDashPattern
    dashBorderLayer.lineDashPhase = lineDashPhase
    dashBorderLayer.lineCap = .round
    dashBorderLayer.lineJoin = .round
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    isUserInteractionEnabled = false
    dashBorderLayer.fillColor = UIColor.clear.cgColor
    dashBorderLayer.strokeColor = borderColor.cgColor
    dashBorderLayer.lineWidth = lineWidth
    dashBorderLayer.lineDashPattern = lineDashPattern
    dashBorderLayer.lineDashPhase = lineDashPhase
    dashBorderLayer.lineCap = .round
    dashBorderLayer.lineJoin = .round
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    let inset = lineWidth * 0.5
    dashBorderLayer.path =
      UIBezierPath(
        roundedRect: bounds.insetBy(dx: inset, dy: inset),
        cornerRadius: max(0, layer.cornerRadius - inset)
      ).cgPath
  }

  public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    dashBorderLayer.strokeColor = borderColor.cgColor
  }
}
