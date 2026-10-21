import CoreImage
import SnapKit
import UIKit

/// Shared presentation for cards embedded above the chat input.
final class ChatBannerController {
  let view = UIView(frame: .zero)
  private let contentView: UIView
  private(set) var isVisible = false
  private var visibilityAnimator: UIViewPropertyAnimator?
  private var blurredSnapshotView: UIImageView?
  private static let imageContext = CIContext()

  init(contentView: UIView) {
    self.contentView = contentView
    view.addSubview(contentView)
    contentView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    view.isHidden = true
    view.alpha = 0
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
  }

  func setVisible(_ visible: Bool, animated: Bool, completion: @escaping () -> Void = {}) {
    guard visible != isVisible else { return }
    if let visibilityAnimator {
      visibilityAnimator.stopAnimation(false)
      visibilityAnimator.finishAnimation(at: .current)
      self.visibilityAnimator = nil
    }
    blurredSnapshotView?.removeFromSuperview()
    blurredSnapshotView = nil
    contentView.alpha = 1
    let wasHidden = view.isHidden
    isVisible = visible
    view.isUserInteractionEnabled = visible
    view.accessibilityElementsHidden = !visible
    let closedTransform = CGAffineTransform(translationX: 0, y: 16).scaledBy(x: 0.97, y: 0.97)

    guard animated, view.window != nil else {
      view.isHidden = !visible
      view.alpha = visible ? 1 : 0
      view.transform = visible ? .identity : closedTransform
      completion()
      return
    }

    view.isHidden = false
    if wasHidden || view.alpha == 0 {
      view.alpha = 0
      view.transform = closedTransform
    }
    contentView.layoutIfNeeded()
    // Crossfade a 2 pt blurred snapshot with the live card for the blur transition.
    if contentView.bounds.width > 0, contentView.bounds.height > 0 {
      let renderer = UIGraphicsImageRenderer(bounds: contentView.bounds)
      let snapshot = renderer.image { context in
        contentView.layer.render(in: context.cgContext)
      }
      if let input = CIImage(image: snapshot) {
        let blurred = input.clampedToExtent().applyingFilter(
          "CIGaussianBlur", parameters: [kCIInputRadiusKey: 2 * snapshot.scale])
        if let image = Self.imageContext.createCGImage(blurred, from: input.extent) {
          let snapshotView = UIImageView(
            image: UIImage(cgImage: image, scale: snapshot.scale, orientation: .up))
          snapshotView.isUserInteractionEnabled = false
          view.addSubview(snapshotView)
          snapshotView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
          }
          snapshotView.alpha = visible ? 1 : 0
          contentView.alpha = visible ? 0 : 1
          blurredSnapshotView = snapshotView
        }
      }
    }

    let animator = UIViewPropertyAnimator(
      duration: visible ? 0.35 : 0.25,
      timingParameters: UICubicTimingParameters(
        controlPoint1: CGPoint(x: 0.22, y: 1), controlPoint2: CGPoint(x: 0.36, y: 1)))
    let snapshotView = blurredSnapshotView
    animator.addAnimations { [view, contentView] in
      view.alpha = visible ? 1 : 0
      view.transform = visible ? .identity : closedTransform
      contentView.alpha = visible ? 1 : (snapshotView == nil ? 1 : 0)
      snapshotView?.alpha = visible ? 0 : 1
    }
    animator.addCompletion { [weak self] position in
      guard let self, position == .end, self.isVisible == visible else { return }
      self.view.isHidden = !visible
      self.contentView.alpha = 1
      self.blurredSnapshotView?.removeFromSuperview()
      self.blurredSnapshotView = nil
      self.visibilityAnimator = nil
      completion()
    }
    visibilityAnimator = animator
    animator.startAnimation()
  }
}
