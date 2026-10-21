import SnapKit
import UIKit

final class SettingsPresentationController: UIPresentationController {
  private var calculatedFrameOfPresentedViewInContainerView = CGRect.zero
  private var isPanningSheet = false
  private var shouldSetFrameWhenAccessingPresentedView = false
  private let dimmingView = UIView()
  private lazy var dismissTapGesture = UITapGestureRecognizer(
    target: self, action: #selector(didTapDismiss))
  private var startOriginX = CGFloat(0)
  private var totalTranslationX = CGFloat(0)
  private lazy var panGesture = {
    let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(sender:)))
    panGesture.delegate = self
    return panGesture
  }()

  override var presentedView: UIView? {
    if shouldSetFrameWhenAccessingPresentedView && !isPanningSheet {
      super.presentedView?.frame = calculatedFrameOfPresentedViewInContainerView
    }
    return super.presentedView
  }

  override var frameOfPresentedViewInContainerView: CGRect {
    guard let containerView = containerView else { return .zero }
    let windowWideTopSafeArea = containerView.window?.safeAreaInsets.top ?? 0
    return CGRect(
      x: 0, y: windowWideTopSafeArea, width: containerView.bounds.width - 48,
      height: containerView.bounds.height - windowWideTopSafeArea)
  }

  override func presentationTransitionWillBegin() {
    dimmingView.backgroundColor = .clear
    dimmingView.addGestureRecognizer(dismissTapGesture)
    dimmingView.isUserInteractionEnabled = true
    containerView?.insertSubview(dimmingView, at: 0)

    dimmingView.snp.makeConstraints { (make) in
      make.edges.equalToSuperview()
    }
    let coordinator = presentedViewController.transitionCoordinator
    coordinator?.animate(
      alongsideTransition: { _ in
        self.dimmingView.alpha = 1
      }, completion: nil)
  }

  override func presentationTransitionDidEnd(_ completed: Bool) {
    shouldSetFrameWhenAccessingPresentedView = completed
    dimmingView.addGestureRecognizer(panGesture)
    guard !completed else { return }
    dimmingView.removeFromSuperview()
  }

  override func dismissalTransitionWillBegin() {
    let coordinator = presentedViewController.transitionCoordinator
    coordinator?.animate(
      alongsideTransition: { _ in
        self.dimmingView.alpha = 0
      }, completion: nil)
    shouldSetFrameWhenAccessingPresentedView = false
  }

  override func size(
    forChildContentContainer container: UIContentContainer,
    withParentContainerSize parentSize: CGSize
  ) -> CGSize {
    parentSize
  }

  override func containerViewDidLayoutSubviews() {
    super.containerViewDidLayoutSubviews()
    calculatedFrameOfPresentedViewInContainerView = frameOfPresentedViewInContainerView
  }
}

extension SettingsPresentationController: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    otherGestureRecognizer is UIPanGestureRecognizer
  }
}

extension SettingsPresentationController {
  @objc private func didTapDismiss() {
    presentedViewController.dismiss(animated: true)
  }

  @objc private func handlePan(sender: UIPanGestureRecognizer) {
    guard let containerView = containerView else { return }
    let translation = sender.translation(in: containerView).x
    sender.setTranslation(.zero, in: containerView)
    if !isPanningSheet {
      totalTranslationX = translation
      startOriginX = presentedViewController.view.frame.minX
      isPanningSheet = true
    } else {
      totalTranslationX += translation
    }
    let currentOrigin = presentedViewController.view.frame.origin
    let translateX = startOriginX + totalTranslationX
    let percent = min(max(-translateX / presentedViewController.view.frame.width, 0), 1)
    switch sender.state {
    case .ended, .cancelled:
      stabilize(finalVelocity: sender.velocity(in: containerView).x, animated: true)
    default:
      let updatedOrigin: CGPoint
      if translateX <= calculatedFrameOfPresentedViewInContainerView.minX {
        updatedOrigin = CGPoint(x: translateX, y: currentOrigin.y)
      } else {
        // See https://medium.com/@esskeetit/how-uiscrollview-works-e418adc47060#0ae2
        let f = translateX
        let d = CGFloat(48)
        let c = CGFloat(0.55)
        updatedOrigin = CGPoint(x: (1.0 - (1.0 / (f * c / d + 1))) * d, y: currentOrigin.y)
      }
      presentedViewController.view.frame = CGRect(
        origin: updatedOrigin, size: presentedViewController.view.frame.size)
      if let view = presentingViewController.view {
        view.frame = CGRect(
          origin: CGPoint(
            x: updatedOrigin.x + presentedViewController.view.frame.size.width,
            y: view.frame.origin.y), size: view.frame.size)
      }
      SettingsAnimatedTransitioning.presentable(for: presentedViewController)?.animate(
        alongsideTransition: .easeOut, interactivelyWithPercent: percent)
      SettingsAnimatedTransitioning.presentable(for: presentingViewController)?.animate(
        alongsideTransition: .easeOut, interactivelyWithPercent: percent)
    }
  }

  private func stabilize(finalVelocity: CGFloat, animated: Bool) {
    guard let containerView = containerView else { return }
    let currentX = presentedViewController.view.frame.minX
    let thresholdConstant = (containerView.frame.width - 48) * 0.667
    let thresholdX = -thresholdConstant
    let currentOrigin = presentedViewController.view.frame.origin

    if currentX < thresholdX || (currentX < 48 && finalVelocity <= -800) {
      presentedViewController.dismiss(animated: true)
    } else {
      let origin = CGPoint(x: 0, y: currentOrigin.y)
      if animated {
        animateSheet(origin: origin) { _ in
          self.isPanningSheet = false
        }
      } else {
        presentedViewController.view.frame = CGRect(
          origin: origin, size: presentedViewController.view.frame.size)
        isPanningSheet = false
      }
    }
  }

  private func animateSheet(origin: CGPoint, completion: @escaping (Bool) -> Void) {
    UIView.animate(
      withDuration: 0.4, delay: 0.0, usingSpringWithDamping: 0.8, initialSpringVelocity: 5,
      options: .curveEaseOut,
      animations: {
        self.presentedViewController.view.frame = CGRect(
          origin: origin, size: self.presentedViewController.view.frame.size)
        SettingsAnimatedTransitioning.presentable(for: self.presentedViewController)?.animate(
          alongsideTransition: .easeIn, interactivelyWithPercent: 1)
        if let view = self.presentingViewController.view {
          view.frame = CGRect(
            origin: CGPoint(
              x: origin.x + self.presentedViewController.view.frame.size.width,
              y: view.frame.origin.y), size: view.frame.size)
        }
        SettingsAnimatedTransitioning.presentable(for: self.presentingViewController)?.animate(
          alongsideTransition: .easeIn, interactivelyWithPercent: 1)
      },
      completion: completion
    )
  }
}
