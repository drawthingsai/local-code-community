import UIKit

final class CustomSlider: UISlider {
  override func trackRect(forBounds bounds: CGRect) -> CGRect {
    CGRect(x: bounds.minX, y: bounds.midY - 1, width: bounds.width, height: 2)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -8, dy: -2).contains(point)
  }
}
