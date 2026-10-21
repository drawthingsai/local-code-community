import SnapKit
import UIKit

protocol AccountPresentationControllerDelegate: AnyObject {
  func didDismissPresentedController()
}

final class AccountPresentationController: UIPresentationController {
  private let dimmingView = UIView()
  private lazy var dismissTapGesture = UITapGestureRecognizer(
    target: self, action: #selector(didTapDismiss))

  weak var presentationDelegate: AccountPresentationControllerDelegate?

  override func presentationTransitionWillBegin() {
    dimmingView.backgroundColor = .clear
    dimmingView.addGestureRecognizer(dismissTapGesture)
    dimmingView.isUserInteractionEnabled = true
    containerView?.insertSubview(dimmingView, at: 0)
    dimmingView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    let coordinator = presentedViewController.transitionCoordinator
    coordinator?.animate(
      alongsideTransition: { _ in
        self.dimmingView.alpha = 1
      }, completion: nil)
  }

  override func presentationTransitionDidEnd(_ completed: Bool) {
    guard !completed else { return }
    dimmingView.removeFromSuperview()
  }

  override func dismissalTransitionWillBegin() {
    let coordinator = presentedViewController.transitionCoordinator
    coordinator?.animate(
      alongsideTransition: { _ in
        self.dimmingView.alpha = 0
      }, completion: nil)
  }

  override func size(
    forChildContentContainer container: UIContentContainer,
    withParentContainerSize parentSize: CGSize
  ) -> CGSize {
    parentSize
  }

  override func preferredContentSizeDidChange(
    forChildContentContainer container: UIContentContainer
  ) {
    super.preferredContentSizeDidChange(forChildContentContainer: container)
    guard container === presentedViewController, let presentedView else { return }
    presentedView.snp.updateConstraints { make in
      make.height.equalTo(presentedViewController.preferredContentSize.height).priority(.low)
    }
    UIView.animate(withDuration: 0.2) {
      self.containerView?.layoutIfNeeded()
    }
  }

  @objc private func didTapDismiss() {
    presentedViewController.dismiss(animated: true) {
      self.presentationDelegate?.didDismissPresentedController()
    }
  }
}
