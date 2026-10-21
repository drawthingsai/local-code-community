import QuartzCore
import UIKit

public enum FBShimmerDirection: Int {
  case right
  case left
  case up
  case down
}

public final class FBShimmeringView: UIView {
  public var contentView: UIView? {
    didSet {
      oldValue?.layer.mask = nil
      if let oldValue, oldValue.superview === self {
        oldValue.removeFromSuperview()
      }
      contentBoundsForMask = .null
      guard let contentView else {
        return
      }
      contentView.frame = bounds
      contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(contentView)
      setNeedsLayout()
      updateShimmering(restartAnimation: true)
    }
  }

  public var isShimmering = false {
    didSet {
      guard isShimmering != oldValue else {
        return
      }
      updateShimmering(restartAnimation: true)
    }
  }

  public var shimmering: Bool {
    get { isShimmering }
    set { isShimmering = newValue }
  }

  public var shimmeringSpeed: CGFloat = 230 {
    didSet {
      guard shimmeringSpeed != oldValue else {
        return
      }
      updateShimmering(restartAnimation: true)
    }
  }

  public var shimmeringHighlightLength: CGFloat = 1 {
    didSet {
      guard shimmeringHighlightLength != oldValue else {
        return
      }
      updateShimmering(restartAnimation: true)
    }
  }

  public var shimmeringPauseDuration: TimeInterval = 0.4 {
    didSet {
      guard shimmeringPauseDuration != oldValue else {
        return
      }
      updateShimmering(restartAnimation: true)
    }
  }

  public var shimmeringDirection: FBShimmerDirection = .right {
    didSet {
      guard shimmeringDirection != oldValue else {
        return
      }
      updateShimmering(restartAnimation: true)
    }
  }

  public var shimmeringOpacity: CGFloat = 0.28 {
    didSet {
      guard shimmeringOpacity != oldValue else {
        return
      }
      updateMaskColors()
    }
  }

  public var shimmeringAnimationOpacity: CGFloat = 1 {
    didSet {
      guard shimmeringAnimationOpacity != oldValue else {
        return
      }
      updateMaskColors()
    }
  }

  private static let slideAnimationKey = "FBShimmer.slide"

  private let shimmerMaskLayer = CAGradientLayer()
  private var contentBoundsForMask = CGRect.null
  private var maskStartPosition = CGPoint.zero
  private var maskEndPosition = CGPoint.zero

  public override init(frame: CGRect) {
    super.init(frame: frame)
    updateMaskColors()
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    contentView?.frame = bounds
    guard isShimmering else {
      return
    }
    updateShimmering(restartAnimation: false)
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    guard isShimmering else {
      return
    }
    if window == nil {
      shimmerMaskLayer.removeAnimation(forKey: Self.slideAnimationKey)
    } else {
      updateShimmering(restartAnimation: false)
    }
  }

  private func updateShimmering(restartAnimation: Bool) {
    guard let contentView else {
      return
    }
    guard isShimmering else {
      shimmerMaskLayer.removeAnimation(forKey: Self.slideAnimationKey)
      contentView.layer.mask = nil
      return
    }
    if contentView.layer.mask !== shimmerMaskLayer {
      contentView.layer.mask = shimmerMaskLayer
    }
    let slideAnimation = shimmerMaskLayer.animation(forKey: Self.slideAnimationKey)
    let animationProgress = restartAnimation ? 0 : currentSlideAnimationProgress()
    let boundsChanged = updateMaskLayout()
    if window != nil
      && (restartAnimation || boundsChanged
        || slideAnimation == nil)
    {
      startSlideAnimation(progress: animationProgress)
    }
  }

  private func updateMaskColors() {
    let baseOpacity = min(1, max(0, shimmeringOpacity))
    let highlightOpacity = min(1, max(0, shimmeringAnimationOpacity))
    shimmerMaskLayer.colors = [
      UIColor(white: 1, alpha: baseOpacity).cgColor,
      UIColor(white: 1, alpha: highlightOpacity).cgColor,
      UIColor(white: 1, alpha: baseOpacity).cgColor,
    ]
  }

  @discardableResult
  private func updateMaskLayout() -> Bool {
    guard let contentView else {
      return false
    }
    let contentBounds = contentView.bounds
    guard contentBounds.width > 0, contentBounds.height > 0, shimmeringSpeed > 0 else {
      return false
    }
    let boundsChanged = contentBounds != contentBoundsForMask
    contentBoundsForMask = contentBounds
    let length = shimmeringDirection.isHorizontal ? contentBounds.width : contentBounds.height
    let extraDistance = length + shimmeringSpeed * max(0, shimmeringPauseDuration)
    let fullShimmerLength = length * 3 + extraDistance
    let travelDistance = length * 2 + extraDistance
    let highlightLength = min(1, max(0, shimmeringHighlightLength))
    let highlightOutsideLength = (1 - highlightLength) / 2
    shimmerMaskLayer.locations = [
      NSNumber(value: Double(highlightOutsideLength)),
      NSNumber(value: 0.5),
      NSNumber(value: Double(1 - highlightOutsideLength)),
    ]
    let startPoint = (length + extraDistance) / fullShimmerLength
    let endPoint = travelDistance / fullShimmerLength

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmerMaskLayer.anchorPoint = .zero
    switch shimmeringDirection {
    case .right:
      shimmerMaskLayer.startPoint = CGPoint(x: startPoint, y: 0.5)
      shimmerMaskLayer.endPoint = CGPoint(x: endPoint, y: 0.5)
      shimmerMaskLayer.bounds = CGRect(
        x: 0, y: 0, width: fullShimmerLength, height: contentBounds.height)
      maskStartPosition = CGPoint(x: -travelDistance, y: 0)
      maskEndPosition = .zero
    case .left:
      shimmerMaskLayer.startPoint = CGPoint(x: startPoint, y: 0.5)
      shimmerMaskLayer.endPoint = CGPoint(x: endPoint, y: 0.5)
      shimmerMaskLayer.bounds = CGRect(
        x: 0, y: 0, width: fullShimmerLength, height: contentBounds.height)
      maskStartPosition = .zero
      maskEndPosition = CGPoint(x: -travelDistance, y: 0)
    case .down:
      shimmerMaskLayer.startPoint = CGPoint(x: 0.5, y: startPoint)
      shimmerMaskLayer.endPoint = CGPoint(x: 0.5, y: endPoint)
      shimmerMaskLayer.bounds = CGRect(
        x: 0, y: 0, width: contentBounds.width, height: fullShimmerLength)
      maskStartPosition = CGPoint(x: 0, y: -travelDistance)
      maskEndPosition = .zero
    case .up:
      shimmerMaskLayer.startPoint = CGPoint(x: 0.5, y: startPoint)
      shimmerMaskLayer.endPoint = CGPoint(x: 0.5, y: endPoint)
      shimmerMaskLayer.bounds = CGRect(
        x: 0, y: 0, width: contentBounds.width, height: fullShimmerLength)
      maskStartPosition = .zero
      maskEndPosition = CGPoint(x: 0, y: -travelDistance)
    }
    shimmerMaskLayer.position = maskStartPosition
    CATransaction.commit()
    return boundsChanged
  }

  private func currentSlideAnimationProgress() -> Double {
    guard let animation = shimmerMaskLayer.animation(forKey: Self.slideAnimationKey),
      animation.duration > 0
    else {
      return 0
    }
    let currentTime = shimmerMaskLayer.convertTime(CACurrentMediaTime(), from: nil)
    let elapsedTime = currentTime - animation.beginTime
    guard elapsedTime.isFinite, elapsedTime > 0 else {
      return 0
    }
    return elapsedTime.truncatingRemainder(dividingBy: animation.duration) / animation.duration
  }

  private func startSlideAnimation(progress: Double) {
    guard let contentView else {
      return
    }
    let length =
      shimmeringDirection.isHorizontal ? contentView.bounds.width : contentView.bounds.height
    guard length > 0, shimmeringSpeed > 0 else {
      return
    }
    shimmerMaskLayer.removeAnimation(forKey: Self.slideAnimationKey)
    let animation = CABasicAnimation(keyPath: "position")
    animation.fromValue = NSValue(cgPoint: maskStartPosition)
    animation.toValue = NSValue(cgPoint: maskEndPosition)
    animation.duration = max(
      0.1, TimeInterval(length / shimmeringSpeed) + max(0, shimmeringPauseDuration))
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.isRemovedOnCompletion = false
    let boundedProgress = min(1, max(0, progress))
    animation.beginTime =
      shimmerMaskLayer.convertTime(CACurrentMediaTime(), from: nil)
      - animation.duration * boundedProgress
    shimmerMaskLayer.add(animation, forKey: Self.slideAnimationKey)
  }
}

extension FBShimmerDirection {
  fileprivate var isHorizontal: Bool {
    switch self {
    case .right, .left:
      return true
    case .up, .down:
      return false
    }
  }
}
