import UIKit

/// The composer's divider between the text and its controls, which is also the text history
/// slider: a 2pt line that grows a thumb once there are edits to go back to, and takes drags
/// anywhere along its height.
final class DividerSlider: UISlider {
  /// Without history there is nothing to scrub, so it reads as a plain divider.
  var hasHistory = false {
    didSet {
      guard oldValue != hasHistory else { return }
      setThumbImage(hasHistory ? #imageLiteral(resourceName: "thumb-20") : UIImage(), for: .normal)
      isUserInteractionEnabled = hasHistory
      minimumTrackTintColor = hasHistory ? .secondaryColor : .primaryBorder
      maximumTrackTintColor = hasHistory ? .octonaryBackground : .primaryBorder
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    minimumTrackTintColor = .primaryBorder
    maximumTrackTintColor = .primaryBorder
    setThumbImage(UIImage(), for: .normal)
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func trackRect(forBounds bounds: CGRect) -> CGRect {
    CGRect(x: bounds.minX, y: bounds.midY - 1, width: bounds.width, height: 2)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -8, dy: -6).contains(point)
  }
}
