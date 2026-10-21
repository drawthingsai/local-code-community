import UIKit

public final class BouncyController {
  private let control: UIView
  private let views: [UIView]
  private var longPressGestureRecognizer: UILongPressGestureRecognizer? = nil
  public let scaleFactor: Double
  public let usingSpringWithDamping: Double
  public let initialSpringVelocity: Double
  public let allowableMovement: CGFloat
  public let touchDownAnimationDuration: Double
  public let touchUpAnimationDuration: Double

  final class ObjCResponder: NSObject, UIGestureRecognizerDelegate {
    weak var controller: BouncyController? = nil
  }
  private let objCResponder: ObjCResponder = ObjCResponder()
  private var startLocation: CGPoint = .zero

  public init(
    view: UIView, views: [UIView], scaleFactor: Double, usingSpringWithDamping: Double,
    initialSpringVelocity: Double, allowableMovement: CGFloat, touchDownAnimationDuration: Double,
    touchUpAnimationDuration: Double
  ) {
    self.control = view
    self.views = views
    self.scaleFactor = scaleFactor
    self.usingSpringWithDamping = usingSpringWithDamping
    self.initialSpringVelocity = initialSpringVelocity
    self.allowableMovement = allowableMovement
    self.touchDownAnimationDuration = touchDownAnimationDuration
    self.touchUpAnimationDuration = touchUpAnimationDuration
    let longPressGestureRecognizer = UILongPressGestureRecognizer(
      target: self, action: #selector(longPress(_:)))
    longPressGestureRecognizer.delegate = objCResponder
    longPressGestureRecognizer.minimumPressDuration = 0
    longPressGestureRecognizer.cancelsTouchesInView = false
    view.addGestureRecognizer(longPressGestureRecognizer)
    self.longPressGestureRecognizer = longPressGestureRecognizer
    objCResponder.controller = self
  }

  deinit {
    if let longPressGestureRecognizer = longPressGestureRecognizer {
      control.removeGestureRecognizer(longPressGestureRecognizer)
    }
  }

  public init(
    control: UIControl, views: [UIView], scaleFactor: Double, usingSpringWithDamping: Double,
    initialSpringVelocity: Double, touchDownAnimationDuration: Double,
    touchUpAnimationDuration: Double
  ) {
    self.control = control
    self.views = views
    self.scaleFactor = scaleFactor
    self.usingSpringWithDamping = usingSpringWithDamping
    self.initialSpringVelocity = initialSpringVelocity
    allowableMovement = 0
    self.touchDownAnimationDuration = touchDownAnimationDuration
    self.touchUpAnimationDuration = touchUpAnimationDuration
    objCResponder.controller = self
    control.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.didTouchDown()
      }, for: .touchDown)
    control.addAction(
      UIAction { [weak self] _ in
        guard let self = self else { return }
        self.didTouchUp()
      }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
  }

  @objc
  private func longPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
    switch gestureRecognizer.state {
    case .began:
      startLocation = gestureRecognizer.location(in: nil)
      didTouchDown()
    case .ended, .cancelled:
      didTouchUp()
    case .changed:
      let location = gestureRecognizer.location(in: nil)
      if ((location.x - startLocation.x) * (location.x - startLocation.x)
        + (location.y - startLocation.y) * (location.y - startLocation.y)).squareRoot()
        > allowableMovement
      {
        // Trigger a failed state.
        gestureRecognizer.isEnabled = false
        gestureRecognizer.isEnabled = true
      }
    case .failed, .possible:
      break
    @unknown default:
      break
    }
  }

  private var touchDownSentinel: Int = 0
  private var touchDownTiming: CFTimeInterval = 0

  private func didTouchDown() {
    let control = control
    let views = views
    touchDownSentinel += 1
    touchDownTiming = CACurrentMediaTime()
    let scaleFactor = scaleFactor
    UIView.animate(
      withDuration: touchDownAnimationDuration, delay: 0,
      options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
    ) {
      control.transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
      for view in views {
        view.transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
      }
    }
  }

  private func didTouchUp() {
    let control = control
    let views = views
    let usingSpringWithDamping = usingSpringWithDamping
    let initialSpringVelocity = initialSpringVelocity
    let touchDownAnimationDuration = touchDownAnimationDuration
    let animationBlock = {
      UIView.animate(
        withDuration: touchDownAnimationDuration, delay: 0,
        usingSpringWithDamping: usingSpringWithDamping,
        initialSpringVelocity: initialSpringVelocity,
        options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
      ) {
        control.transform = .identity
        for view in views {
          view.transform = .identity
        }
      }
    }
    let currentMediaTime = CACurrentMediaTime()
    if currentMediaTime - touchDownTiming >= touchUpAnimationDuration * 0.667 {
      animationBlock()
    } else {
      let touchDownSentinel = touchDownSentinel
      DispatchQueue.main.asyncAfter(
        deadline: .now()
          + .milliseconds(
            200 - Int((1000 * (currentMediaTime - touchDownTiming)).rounded(.down)))
      ) {
        guard touchDownSentinel == self.touchDownSentinel else {
          return
        }
        animationBlock()
      }
    }
  }
}

extension BouncyController.ObjCResponder {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    return true
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard let view = touch.view else { return true }
    guard view !== controller?.control else { return true }
    // Shouldn't interfere with UIControl.
    if view is UIControl {
      return false
    }
    // If it is an UIImageView but has gesture recognizer attached, we shouldn't interfere.
    if !(view.gestureRecognizers?.isEmpty ?? true) {
      return false
    }
    return true
  }
}
