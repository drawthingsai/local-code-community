import Localization
import SnapKit
import Style
import UIKit

protocol MessageZoomControllerDelegate: AnyObject {
  func messageZoomControllerDidTapActualSize(_ controller: MessageZoomController)
}

/// Shows the message zoom on a button that returns it to 100%. The button shows while the zoom is
/// not 100%; back at 100% it stays for two seconds, then goes away.
final class MessageZoomController {
  weak var delegate: MessageZoomControllerDelegate?

  var view: UIView { button }
  var zoom = 100 {
    didSet {
      guard zoom != oldValue, var configuration = button.configuration else { return }
      configuration.title = (Double(zoom) / 100).formatted(.percent.precision(.fractionLength(0)))
      button.configuration = configuration
      // The button is up while the zoom is not 100%, and through the two seconds after.
      let wasShown = oldValue != 100 || hideTimer != nil
      hideTimer?.invalidate()
      hideTimer = nil
      guard zoom == 100 else {
        if !wasShown {
          setShown(true)
        }
        return
      }
      let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
        guard let self else { return }
        self.hideTimer = nil
        self.setShown(false)
      }
      RunLoop.main.add(timer, forMode: .common)
      hideTimer = timer
    }
  }

  // The button pops in: it grows from nothing past its size and settles, fading in a little sooner.
  // It leaves faster, shrinking to nothing as it fades. Either starts from where the button is on
  // screen, so one caught on its way out grows back. Reduce Motion only fades.
  private func setShown(_ isShown: Bool) {
    let layer = button.layer
    let presentationLayer = layer.presentation() ?? layer
    let fromScale =
      button.isHidden
      ? 0.01 : presentationLayer.value(forKeyPath: "transform.scale.x") as? CGFloat ?? 1
    let scaleAnimation: CAAnimation
    let opacityAnimation = CABasicAnimation(keyPath: "opacity")
    opacityAnimation.fromValue = presentationLayer.opacity
    if isShown {
      // cubic-bezier(0.34, 1.36, 0.64, 1) carries the scale past 1 before it settles. Core
      // Animation holds a timing function at its end value, so the scale follows the curve through
      // keyframes sampled along it.
      func bezier(_ s: CGFloat, _ control1: CGFloat, _ control2: CGFloat) -> CGFloat {
        3 * (1 - s) * (1 - s) * s * control1 + 3 * (1 - s) * s * s * control2 + s * s * s
      }
      let samples = (0...30).map { CGFloat($0) / 30 }
      let popAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
      popAnimation.keyTimes = samples.map { NSNumber(value: Double(bezier($0, 0.34, 0.64))) }
      popAnimation.values = samples.map { fromScale + (1 - fromScale) * bezier($0, 1.36, 1) }
      popAnimation.duration = 0.5
      scaleAnimation = popAnimation
      opacityAnimation.duration = 0.4
      opacityAnimation.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.36, 0.64, 1)
    } else {
      let timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
      let shrinkAnimation = CABasicAnimation(keyPath: "transform.scale")
      shrinkAnimation.fromValue = fromScale
      shrinkAnimation.toValue = 0.01
      shrinkAnimation.duration = 0.18
      shrinkAnimation.timingFunction = timingFunction
      scaleAnimation = shrinkAnimation
      opacityAnimation.duration = 0.18
      opacityAnimation.timingFunction = timingFunction
    }
    let reducesMotion = UIAccessibility.isReduceMotionEnabled
    if isShown {
      button.isHidden = false
      button.transform = .identity
    } else if !reducesMotion {
      button.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
    }
    button.alpha = isShown ? 1 : 0
    // A saved zoom shows the button before it is in a window; it is simply there when the window
    // comes up.
    guard button.window != nil else {
      button.isHidden = !isShown
      return
    }
    CATransaction.begin()
    CATransaction.setCompletionBlock { [weak self] in
      // A zoom change on its way out brought the button back.
      guard let self, self.zoom == 100, self.hideTimer == nil else { return }
      self.button.isHidden = true
    }
    if !reducesMotion {
      layer.add(scaleAnimation, forKey: "scale")
    }
    layer.add(opacityAnimation, forKey: "opacity")
    CATransaction.commit()
  }

  // Styled as the project button.
  private lazy var button: UIButton = {
    let button = UIButton(type: .custom)
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) {
      configuration = .glass()
    } else {
      configuration = .filled()
    }
    configuration.cornerStyle = .capsule
    configuration.baseForegroundColor = .primaryText
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12, leading: 20, bottom: 12, trailing: 20)
    if #unavailable(iOS 26.0) {
      configuration.background.backgroundColor = .tertiaryFill
    }
    button.configuration = configuration
    button.toolTip = LocalizedString.forKey("actual_size")
    button.accessibilityHint = LocalizedString.forKey("actual_size")
    button.isHidden = true
    button.alpha = 0
    FontMetrics.default.scaleFont(.systemFont(ofSize: 16, weight: .medium), bindTo: button)
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.messageZoomControllerDidTapActualSize(self)
      }, for: .touchUpInside)
    button.snp.makeConstraints { make in
      make.height.equalTo(52)
    }
    return button
  }()
  private var hideTimer: Timer?

  deinit {
    hideTimer?.invalidate()
  }
}
