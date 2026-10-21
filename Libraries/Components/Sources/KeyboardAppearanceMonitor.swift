import Foundation
import UIKit

public final class KeyboardAppearanceMonitor {

  private static func findFrstResponder(of view: UIView) -> UIView? {
    guard !view.isFirstResponder else { return view }
    for subview in view.subviews {
      if let firstResponder = findFrstResponder(of: subview) {
        return firstResponder
      }
    }
    return nil
  }

  private var showKeyboard: NSObjectProtocol? = nil

  private var changeKeyboard: NSObjectProtocol? = nil

  private weak var viewController: UIViewController?
  private let viewsScrollToVisible: [UIScrollView]
  private let notificationCenter: NotificationCenter
  private let additionalSafeAreaInsets: UIEdgeInsets
  private let isAdditionalSafeAreaInsetsManaged: Bool
  private let animateAlongKeyboardFrameChange:
    ((_ beginKeyboardFrame: CGRect, _ endKeyboardFrame: CGRect) -> Void)?
  public init(
    _ viewController: UIViewController,
    viewsScrollToVisible: [UIScrollView] = [],
    notificationCenter: NotificationCenter = .default,
    isAdditionalSafeAreaInsetsManaged: Bool = false,
    animateAlongKeyboardFrameChange: (
      (_ beginKeyboardFrame: CGRect, _ endKeyboardFrame: CGRect) -> Void
    )? = nil
  ) {

    self.viewController = viewController
    self.viewsScrollToVisible = viewsScrollToVisible
    self.notificationCenter = notificationCenter
    self.isAdditionalSafeAreaInsetsManaged = isAdditionalSafeAreaInsetsManaged
    self.animateAlongKeyboardFrameChange = animateAlongKeyboardFrameChange
    // Copy the additionalSafeAreaInsets for this viewController. Afterwards, it will be managed by us.
    additionalSafeAreaInsets = viewController.additionalSafeAreaInsets

    showKeyboard = notificationCenter.addObserver(
      forName: UIResponder.keyboardWillShowNotification, object: nil, queue: nil
    ) { [weak self] notification in
      self?.keyboardWillShow(notification: notification)
    }

    changeKeyboard = notificationCenter.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: nil
    ) { [weak self] notification in
      self?.keyboardWillChangeFrame(notification: notification)
    }
  }

  deinit {
    if let changeKeyboard = changeKeyboard {
      notificationCenter.removeObserver(changeKeyboard)
    }
    if let showKeyboard = showKeyboard {
      notificationCenter.removeObserver(showKeyboard)
    }
  }

  private static func minYDiscountingSafeArea(
    minY: CGFloat, screenBottom: CGFloat, viewFrameBottomWithSystemSafeAreaInset: CGFloat
  ) -> CGFloat {
    guard minY > viewFrameBottomWithSystemSafeAreaInset else {
      return minY
    }
    guard minY < screenBottom else {
      return minY - (screenBottom - viewFrameBottomWithSystemSafeAreaInset)
    }
    return viewFrameBottomWithSystemSafeAreaInset
  }

  private func keyboardWillShow(notification: Notification) {
    guard let viewController = viewController, let _ = viewController.viewIfLoaded?.window else {
      return
    }
    // Loop over scroll views to find the first responder. Once found, scroll it into focus.
    for scrollView in viewsScrollToVisible {
      guard let firstResponder = Self.findFrstResponder(of: scrollView) else { continue }
      // We only have one first responder to handle.
      let scrollRect = firstResponder.convert(firstResponder.bounds, to: scrollView)
      scrollView.scrollRectToVisible(scrollRect, animated: true)
      break
    }
  }

  private func keyboardWillChangeFrame(notification: Notification) {
    guard
      let viewController = viewController,
      let _ = viewController.viewIfLoaded?.window,  // If it has no window, we cannot compute its screen coordinate, therefore, computation on viewFrame will be wrong.
      let userInfo = notification.userInfo,
      let beginKeyboardFrame = userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect,
      let endKeyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else {
      return
    }
    dispatchPrecondition(condition: .onQueue(.main))
    // On iPad, there is additional animation to push formSheet up, and that happens after this one.
    // Hence, pushing our update to the end of the run loop to make sure the viewController.view.bounds
    // is up-to-date.
    let isAdditionalSafeAreaInsetsManaged = isAdditionalSafeAreaInsetsManaged
    DispatchQueue.main.async {
      // We need to know the screen coordinate of the safe area to make the proper decision.
      let systemSafeAreaBottomInset =
        viewController.view.safeAreaInsets.bottom - viewController.additionalSafeAreaInsets.bottom
        + self.additionalSafeAreaInsets.bottom
      let viewFrame = viewController.view.convert(viewController.view.bounds, to: nil)
      let screenBottom = UIScreen.main.bounds.maxY
      let viewFrameBottomWithSystemSafeAreaInset = viewFrame.maxY - systemSafeAreaBottomInset
      if isAdditionalSafeAreaInsetsManaged {
        viewController.additionalSafeAreaInsets.bottom +=
          Self.minYDiscountingSafeArea(
            minY: beginKeyboardFrame.minY, screenBottom: screenBottom,
            viewFrameBottomWithSystemSafeAreaInset: viewFrameBottomWithSystemSafeAreaInset)
          - Self.minYDiscountingSafeArea(
            minY: endKeyboardFrame.minY, screenBottom: screenBottom,
            viewFrameBottomWithSystemSafeAreaInset: viewFrameBottomWithSystemSafeAreaInset)
      }

      self.animateUpdates(
        userInfo, viewController, beginKeyboardFrame: beginKeyboardFrame,
        endKeyboardFrame: endKeyboardFrame)
    }
  }

  private func animateUpdates(
    _ userInfo: [AnyHashable: Any], _ viewController: UIViewController, beginKeyboardFrame: CGRect,
    endKeyboardFrame: CGRect
  ) {
    let duration =
      userInfo[UIResponder.keyboardAnimationDurationUserInfoKey]
      .flatMap { $0 as? Double } ?? 0.25

    let animateAlongKeyboardFrameChange = animateAlongKeyboardFrameChange
    if duration > 0 {
      let curve =
        userInfo[UIResponder.keyboardAnimationCurveUserInfoKey]
        .flatMap { $0 as? Int }
        .flatMap { UIView.AnimationCurve(rawValue: $0) } ?? .easeInOut

      UIViewPropertyAnimator(duration: duration, curve: curve) {
        animateAlongKeyboardFrameChange?(beginKeyboardFrame, endKeyboardFrame)
        viewController.view.layoutIfNeeded()
      }
      .startAnimation()
    } else {
      animateAlongKeyboardFrameChange?(beginKeyboardFrame, endKeyboardFrame)
      viewController.view.layoutIfNeeded()
    }
  }
}
