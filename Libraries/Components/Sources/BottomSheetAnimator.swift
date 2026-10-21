import Style
import UIKit

public final class BottomSheetTransitioningController: NSObject,
  UIViewControllerTransitioningDelegate
{
  var bottomSheetAnimator = BottomSheetAnimator()
  public func animationController(
    forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    bottomSheetAnimator.isPresenting = true
    return bottomSheetAnimator
  }

  public func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning?
  {
    bottomSheetAnimator.isPresenting = false
    return bottomSheetAnimator
  }
}

public final class BottomSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  var isPresenting = true  // Determine if we are presenting or dismissing
  var duration = 0.4  // Duration of the animation

  public func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?)
    -> TimeInterval
  {
    return duration
  }

  public func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
    let key =
      isPresenting
      ? UITransitionContextViewControllerKey.to : UITransitionContextViewControllerKey.from
    guard let controller = transitionContext.viewController(forKey: key) else {
      return
    }

    if isPresenting {
      transitionContext.containerView.addSubview(controller.view)
      controller.view.translatesAutoresizingMaskIntoConstraints = false
      controller.view.snp.makeConstraints { make in
        make.leading.trailing.equalToSuperview()
        make.top.equalTo(transitionContext.containerView.snp.bottom)
      }
    }
    transitionContext.containerView.layoutIfNeeded()
    // Animate the transition
    UIView.animate(
      withDuration: duration, delay: 0,
      usingSpringWithDamping: 0.8, initialSpringVelocity: 5, options: .curveEaseOut,
      animations: {
        if self.isPresenting {
          controller.view.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(transitionContext.containerView.snp.bottom)
          }
        } else {
          controller.view.snp.remakeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(transitionContext.containerView.snp.bottom)
          }
        }
        transitionContext.containerView.layoutIfNeeded()
      },
      completion: { finished in
        if !self.isPresenting {
          controller.view.removeFromSuperview()
        }
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
      })
  }
}
