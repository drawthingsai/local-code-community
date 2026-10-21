import UIKit

extension CALayer {
  /// Animates a layer whose model frame just changed from `oldFrame` to `newFrame` along `axis`,
  /// Dynamic Island style: the edge in the direction of travel leads on a stiffer spring and the
  /// other trails, so the layer stretches in flight and squashes on arrival. The cross axis moves
  /// opposite to the main axis to keep the layer's "volume". Additive animations keep it subpixel
  /// and stack when interrupted. `stretch` scales how far the trailing edge lags and how much the
  /// cross axis squashes; 0 moves the layer rigidly.
  public func addStretchSpringAnimation(
    from oldFrame: CGRect, to newFrame: CGRect, axis: NSLayoutConstraint.Axis,
    stretch: CGFloat = 1
  ) {
    let isVertical = axis == .vertical
    let (oldMin, oldMax, newMin, newMax) =
      isVertical
      ? (oldFrame.minY, oldFrame.maxY, newFrame.minY, newFrame.maxY)
      : (oldFrame.minX, oldFrame.maxX, newFrame.minX, newFrame.maxX)
    let isMovingForward = newMin > oldMin
    let edges: [(delta: CGFloat, lengthSign: CGFloat, isLeading: Bool)] = [
      (oldMin - newMin, -1, !isMovingForward),
      (oldMax - newMax, 1, isMovingForward),
    ]
    for edge in edges where edge.delta != 0 {
      let response: Double = edge.isLeading ? 0.3 : 0.3 + 0.1 * stretch
      let dampingRatio: Double = edge.isLeading ? 0.8 : 0.8 + 0.2 * stretch
      let lengthDelta = edge.delta * edge.lengthSign
      for (keyPath, fromValue) in [
        (isVertical ? "position.y" : "position.x", edge.delta / 2),
        (isVertical ? "bounds.size.height" : "bounds.size.width", lengthDelta),
        (isVertical ? "bounds.size.width" : "bounds.size.height", -0.3 * stretch * lengthDelta),
      ] {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / response, 2)
        animation.damping = 4 * .pi * dampingRatio / response
        animation.fromValue = fromValue
        animation.toValue = 0
        animation.isAdditive = true
        animation.duration = animation.settlingDuration
        add(animation, forKey: nil)
      }
    }
  }
}
