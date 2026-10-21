import UIKit

public final class ShadowView: UIView {
  public var cornerRadius: CGFloat = 0
  public var contentInsets: UIEdgeInsets = .zero
  override public func layoutSubviews() {
    super.layoutSubviews()
    let path = CGMutablePath()
    path.addRect(CGRectInset(bounds, -layer.shadowRadius * 2, -layer.shadowRadius * 2))
    let width = bounds.width - contentInsets.right - contentInsets.left
    let height = bounds.height - contentInsets.bottom - contentInsets.top
    if cornerRadius > 0, width >= cornerRadius * 2, height >= cornerRadius * 2 {
      path.addRoundedRect(
        in: CGRect(
          x: bounds.minX + contentInsets.left, y: bounds.minY + contentInsets.top,
          width: width, height: height),
        cornerWidth: cornerRadius, cornerHeight: cornerRadius)
    } else {
      path.addRect(
        CGRect(
          x: bounds.minX + contentInsets.left, y: bounds.minY + contentInsets.top,
          width: width, height: height))
    }
    if let maskLayer = layer.mask as? CAShapeLayer {
      maskLayer.path = path
    } else {
      let maskLayer = CAShapeLayer()
      maskLayer.path = path
      maskLayer.fillRule = .evenOdd
      layer.mask = maskLayer
    }
  }
}
