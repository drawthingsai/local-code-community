import SnapKit
import UIKit

final class AccountAnimatedTransitioning: NSObject {
  enum Transition {
    case easeIn
    case easeOut
  }

  enum Placement {
    case trailing
    case below
  }

  private let duration: TimeInterval
  private let transition: Transition
  private let sourceView: UIView
  private let placement: Placement

  init(duration: TimeInterval, transition: Transition, sourceView: UIView, placement: Placement) {
    self.duration = duration
    self.transition = transition
    self.sourceView = sourceView
    self.placement = placement
  }
}

extension AccountAnimatedTransitioning: UIViewControllerAnimatedTransitioning {
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
    let target: UIViewController
    let targetTransform: CGAffineTransform
    let targetAlpha: CGFloat
    let sourceRect = sourceView.convert(sourceView.bounds, to: containerView)
    let contentSize = transition == .easeIn ? to.preferredContentSize : from.view.bounds.size
    let collapsedTransform: CGAffineTransform
    switch placement {
    case .trailing:
      collapsedTransform = CGAffineTransform(
        translationX: -contentSize.width / 2,
        y: contentSize.height / 2 - sourceRect.height / 2
      ).scaledBy(x: 0.05, y: 0.05)
    case .below:
      collapsedTransform = CGAffineTransform(
        translationX: (contentSize.width - sourceRect.width) / 2,
        y: -(contentSize.height + sourceRect.height) / 2 - 10
      ).scaledBy(x: 0.05, y: 0.05)
    }
    switch transition {
    case .easeIn:
      containerView.addSubview(to.view)
      switch placement {
      case .trailing:
        to.view.frame = CGRect(
          x: sourceRect.maxX + 10, y: sourceRect.maxY - contentSize.height,
          width: contentSize.width, height: contentSize.height)
        to.view.snp.makeConstraints { make in
          make.left.equalTo(sourceView.snp.right).offset(10)
          make.bottom.equalTo(sourceView)
          make.width.equalTo(contentSize.width)
          make.height.equalTo(contentSize.height).priority(.low)
        }
      case .below:
        to.view.frame = CGRect(
          x: sourceRect.maxX - contentSize.width, y: sourceRect.maxY + 10,
          width: contentSize.width, height: contentSize.height)
        to.view.snp.makeConstraints { make in
          make.right.equalTo(sourceView)
          make.top.equalTo(sourceView.snp.bottom).offset(10)
          make.width.equalTo(contentSize.width)
          make.height.equalTo(contentSize.height).priority(.low)
        }
      }
      to.view.layoutIfNeeded()
      to.view.alpha = 0.1
      to.view.transform = collapsedTransform
      target = to
      targetAlpha = 1
      targetTransform = .identity
    case .easeOut:
      target = from
      targetTransform = collapsedTransform
      targetAlpha = 0.1
    }
    let transition = self.transition
    UIView.animate(
      withDuration: transitionDuration(using: transitionContext), delay: 0,
      usingSpringWithDamping: 0.8, initialSpringVelocity: 5, options: .curveEaseOut
    ) {
      target.view.transform = targetTransform
      target.view.alpha = targetAlpha
    } completion: { didComplete in
      if transition == .easeOut {
        target.view.removeFromSuperview()
      }
      transitionContext.completeTransition(didComplete)
    }
  }
}
