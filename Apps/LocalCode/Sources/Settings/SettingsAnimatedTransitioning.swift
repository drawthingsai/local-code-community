import UIKit

protocol AnimatingTransitioningPresentable {
  func animate(alongsideTransition: SettingsAnimatedTransitioning.Transition)
  func animate(
    alongsideTransition: SettingsAnimatedTransitioning.Transition, interactivelyWithPercent: CGFloat
  )
}

final class SettingsAnimatedTransitioning: NSObject {
  enum Transition {
    case easeIn
    case easeOut
  }
  private let duration: TimeInterval
  private let transition: Transition
  private let interactive: Bool
  init(duration: TimeInterval, transition: Transition, interactive: Bool) {
    self.duration = duration
    self.transition = transition
    self.interactive = interactive
  }

  /// Settings is presented over the navigation controller the chat sits in; the chat follows the
  /// transition.
  static func presentable(for viewController: UIViewController)
    -> AnimatingTransitioningPresentable?
  {
    ((viewController as? UINavigationController)?.topViewController ?? viewController)
      as? AnimatingTransitioningPresentable
  }
}

extension SettingsAnimatedTransitioning: UIViewControllerAnimatedTransitioning {
  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?)
    -> TimeInterval
  {
    duration
  }

  func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
    guard let to = transitionContext.viewController(forKey: .to),
      let from = transitionContext.viewController(forKey: .from)
    else {
      transitionContext.completeTransition(true)
      return
    }
    let containerView = transitionContext.containerView

    let source: UIViewController
    let sourceFrame: CGRect
    let target: UIViewController
    let targetFrame: CGRect
    let windowWideTopSafeArea = containerView.window?.safeAreaInsets.top ?? 0
    switch transition {
    case .easeIn:
      sourceFrame = CGRect(
        x: containerView.bounds.width - 48, y: 0, width: from.view.frame.width,
        height: from.view.frame.height)
      source = from
      containerView.addSubview(to.view)
      to.view.frame = CGRect(
        x: -containerView.bounds.width + 48, y: windowWideTopSafeArea,
        width: containerView.bounds.width - 48,
        height: containerView.bounds.height - windowWideTopSafeArea)
      to.view.layoutIfNeeded()
      targetFrame = CGRect(
        x: 0, y: windowWideTopSafeArea, width: to.view.frame.width, height: to.view.frame.height)
      target = to
    case .easeOut:
      sourceFrame = CGRect(x: 0, y: 0, width: to.view.frame.width, height: to.view.frame.height)
      source = to
      targetFrame = CGRect(
        x: -containerView.bounds.width + 48, y: windowWideTopSafeArea, width: from.view.frame.width,
        height: from.view.frame.height)
      target = from
    }
    let transition = self.transition
    let sourcePresentable = Self.presentable(for: source)
    let targetPresentable = Self.presentable(for: target)
    if interactive {
      UIView.animateKeyframes(
        withDuration: transitionDuration(using: transitionContext), delay: 0, options: [],
        animations: {
          // This is required otherwise it won't be linear interpolation for some reason.
          UIView.setAnimationCurve(.linear)
          UIView.addKeyframe(
            withRelativeStartTime: 0, relativeDuration: 1,
            animations: {
              target.view.frame = targetFrame
              source.view.frame = sourceFrame
              sourcePresentable?.animate(alongsideTransition: transition)
              targetPresentable?.animate(alongsideTransition: transition)
            })
        }
      ) { didComplete in
        if transition == .easeOut {
          target.view.removeFromSuperview()
        }
        if didComplete {
          transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        }
      }
    } else {
      UIView.animate(
        withDuration: transitionDuration(using: transitionContext), delay: 0,
        usingSpringWithDamping: 0.8, initialSpringVelocity: 5, options: .curveEaseOut
      ) {
        target.view.frame = targetFrame
        source.view.frame = sourceFrame
        sourcePresentable?.animate(alongsideTransition: transition)
        targetPresentable?.animate(alongsideTransition: transition)
      } completion: { didComplete in
        if transition == .easeOut {
          target.view.removeFromSuperview()
        }
        transitionContext.completeTransition(didComplete)
      }
    }
  }
}
