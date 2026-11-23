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

  /// Where the panel rests: below the status bar, with a strip of the chat showing beside it.
  /// An iPhone Duo changes both.
  ///
  /// `containerView` is the transition's container or the window; they cover the same area.
  static func presentedFrame(in containerView: UIView) -> CGRect {
    let window = (containerView as? UIWindow) ?? containerView.window
    var top = window?.safeAreaInsets.top ?? 0
    var chatWidth: CGFloat = 48
    if #available(iOS 27.1, *), let window {
      if window.traitCollection.verticalBarEdge != .unspecified {
        // An iPhone Duo keeps its side bar at the trailing edge while the chat moves, with the
        // bar's buttons centered 48 pt in. Twice that shows, and the buttons are in the middle
        // of it.
        chatWidth = 48 * 2
      } else if window.traitCollection.horizontalSizeClass == .regular,
        let statusItems = containerView.reservedRegions(kind: .occlusion).first(where: {
          $0.frame.minY <= 0 && $0.frame.maxX >= containerView.bounds.maxX
        })
      {
        // An unfolded iPhone Duo turned upright has the clock and its signal indicator in the
        // top trailing corner. The panel stops where they start, so both are over the chat.
        // With nothing above it, it runs to the top.
        chatWidth = containerView.bounds.maxX - statusItems.frame.minX
        top = 0
      }
    }
    return CGRect(
      x: 0, y: top, width: containerView.bounds.width - chatWidth,
      height: containerView.bounds.height - top)
  }

  override var frameOfPresentedViewInContainerView: CGRect {
    guard let containerView = containerView else { return .zero }
    return Self.presentedFrame(in: containerView)
  }

  override func presentationTransitionWillBegin() {
    dimmingView.backgroundColor = .clear
    dimmingView.addGestureRecognizer(dismissTapGesture)
    dimmingView.isUserInteractionEnabled = true
    containerView?.insertSubview(dimmingView, at: 0)

    dimmingView.snp.makeConstraints { (make) in
      make.edges.equalToSuperview()
    }
    // The window's safe area runs the display's whole width. Settings starts below the status
    // bar, so none of it reaches settings, except on an unfolded iPhone Duo turned upright, where
    // settings runs to the top beside the status items. There it keeps 24 pt, as much as it has
    // beside the chat with the phone held wide, which clears the display's rounded corner.
    let topSafeArea =
      (containerView?.window?.safeAreaInsets.top ?? 0) - frameOfPresentedViewInContainerView.minY
    presentedViewController.additionalSafeAreaInsets.top = min(topSafeArea, 24) - topSafeArea
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

  override func dismissalTransitionDidEnd(_ completed: Bool) {
    guard completed else { return }
    presentedViewController.additionalSafeAreaInsets.top = 0
    // A dismissal that is not animated skips the animator, which is what moves the chat back.
    // That happens when an iPhone Duo unfolds and settings goes beside the chat.
    presentingViewController.view.frame.origin.x = 0
    SettingsAnimatedTransitioning.presentable(for: presentedViewController)?.animate(
      alongsideTransition: .easeOut)
    SettingsAnimatedTransitioning.presentable(for: presentingViewController)?.animate(
      alongsideTransition: .easeOut)
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
    // See presentationTransitionWillBegin. The phone can fold or turn while settings is open.
    let topSafeArea =
      (containerView?.window?.safeAreaInsets.top ?? 0)
      - calculatedFrameOfPresentedViewInContainerView.minY
    presentedViewController.additionalSafeAreaInsets.top = min(topSafeArea, 24) - topSafeArea
    // The window can change size while settings is open, such as when an iPhone Duo folds. The
    // transition left the chat beside settings at the old width.
    guard shouldSetFrameWhenAccessingPresentedView, !isPanningSheet, let presentedView,
      let presentingView = presentingViewController.view
    else { return }
    presentingView.frame.origin.x = presentedView.frame.maxX
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
    let thresholdConstant = Self.presentedFrame(in: containerView).width * 0.667
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
