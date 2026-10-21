import Style
import UIKit

public protocol ImageExpansionAnimatable {
  var imageExpansionDestinationView: UIImageView { get }
}

public final class ImageExpansionTransitionAnimator: NSObject {

  private let isPresenting: Bool
  private let duration: TimeInterval = 0.35
  private let originalImageView: UIImageView
  private let originalOccludingViews: [UIView]

  public init(
    isPresenting: Bool, originalImageView: UIImageView, originalOccludingViews: [UIView] = []
  ) {
    self.isPresenting = isPresenting
    self.originalImageView = originalImageView
    self.originalOccludingViews = originalOccludingViews
    super.init()
  }
}

extension ImageExpansionTransitionAnimator: UIViewControllerAnimatedTransitioning {
  public func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?)
    -> TimeInterval
  {
    return duration
  }

  public func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
    guard let fromVC = transitionContext.viewController(forKey: .from),
      let toVC = transitionContext.viewController(forKey: .to)
    else {
      transitionContext.completeTransition(false)
      return
    }

    let containerView = transitionContext.containerView

    if isPresenting {
      guard let toVC = toVC as? UIViewController & ImageExpansionAnimatable else {
        transitionContext.completeTransition(false)
        return
      }
      containerView.addSubview(toVC.view)
      toVC.view.setNeedsLayout()
      toVC.view.layoutIfNeeded()
      toVC.view.alpha = 0
      originalImageView.isHidden = true

      let finalImageView = toVC.imageExpansionDestinationView
      finalImageView.isHidden = true
      let finalFrame = containerView.convert(finalImageView.frame, from: finalImageView.superview)
      let transitionImageView = UIImageView(image: originalImageView.image)
      transitionImageView.contentMode = .scaleAspectFill
      transitionImageView.clipsToBounds = true
      transitionImageView.layer.cornerRadius = originalImageView.layer.cornerRadius
      transitionImageView.frame = containerView.convert(
        originalImageView.frame, from: originalImageView.superview)
      containerView.addSubview(transitionImageView)
      originalImageView.isHidden = true
      let fakeViews = setupOccludingViews(
        containerView: containerView, occludingViews: originalOccludingViews)

      UIView.animate(
        withDuration: duration, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5,
        options: .curveEaseInOut
      ) {
        transitionImageView.frame = finalFrame
        transitionImageView.layer.cornerRadius = finalImageView.layer.cornerRadius
        fakeViews.forEach { $0.alpha = 0 }
        toVC.view.alpha = 1
      } completion: { _ in
        self.originalImageView.isHidden = false
        finalImageView.isHidden = false
        transitionImageView.removeFromSuperview()
        fakeViews.forEach { $0.removeFromSuperview() }
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
      }
    } else {
      guard let fromVC = fromVC as? UIViewController & ImageExpansionAnimatable else {
        transitionContext.completeTransition(false)
        return
      }
      if toVC.view.superview == nil {
        containerView.insertSubview(toVC.view, belowSubview: fromVC.view)
      }
      self.originalImageView.isHidden = true
      let finalImageView = fromVC.imageExpansionDestinationView
      finalImageView.isHidden = true
      let transitionImageView = UIImageView(image: finalImageView.image)
      transitionImageView.contentMode = .scaleAspectFill
      transitionImageView.clipsToBounds = true
      transitionImageView.layer.cornerRadius = finalImageView.layer.cornerRadius
      transitionImageView.frame = containerView.convert(
        finalImageView.frame, from: finalImageView.superview)
      containerView.addSubview(transitionImageView)
      let fakeViews = setupOccludingViews(
        containerView: containerView, occludingViews: originalOccludingViews)
      let originalFrame = containerView.convert(
        originalImageView.frame, from: originalImageView.superview)

      UIView.animate(
        withDuration: duration, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5,
        options: .curveEaseInOut
      ) {
        transitionImageView.frame = originalFrame
        fromVC.view.alpha = 0
        transitionImageView.layer.cornerRadius = self.originalImageView.layer.cornerRadius
      } completion: { completed in
        self.originalImageView.isHidden = false
        finalImageView.isHidden = false
        transitionImageView.removeFromSuperview()
        fromVC.view.removeFromSuperview()
        toVC.view.layoutIfNeeded()
        fakeViews.forEach { $0.removeFromSuperview() }
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
      }
    }
  }

  func setupOccludingViews(containerView: UIView, occludingViews: [UIView]) -> [UIView] {
    let newOccludingViews: [UIView] = occludingViews.compactMap {
      guard !$0.isKind(of: UIVisualEffectView.self) else {
        return UIVisualEffectView(effect: ($0 as! UIVisualEffectView).effect)
      }
      return $0.snapshotView(afterScreenUpdates: true)
    }
    guard newOccludingViews.count > 0 else { return [] }
    newOccludingViews.enumerated().forEach {
      containerView.addSubview($0.1)
      $0.1.frame = containerView.convert(
        occludingViews[$0.0].frame, from: occludingViews[$0.0].superview)
    }
    return newOccludingViews
  }
}
