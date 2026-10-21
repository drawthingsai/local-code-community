import UIKit

public class FadeTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  public var duration = 0.2
  public var isShowingViewController = true

  public func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?)
    -> TimeInterval
  {
    return duration
  }

  public func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
    let containerView = transitionContext.containerView

    guard let toView = transitionContext.view(forKey: .to),
      let fromView = transitionContext.view(forKey: .from)
    else {
      return
    }
    containerView.addSubview(toView)
    fromView.alpha = 1
    toView.alpha = 0

    UIView.animate(
      withDuration: duration,
      animations: {
        fromView.alpha = 0
        toView.alpha = 1
      }
    ) { (completed) in
      transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
  }
}
