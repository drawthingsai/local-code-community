import UIKit

public final class CustomSlider: UISlider {
  public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    return bounds.insetBy(dx: -8, dy: -2).contains(point)
  }
}
