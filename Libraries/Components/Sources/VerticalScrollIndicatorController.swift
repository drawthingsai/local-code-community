import UIKit

public final class VerticalScrollIndicatorController {
  public var view: UIView { internalView }
  private let indicatorView: UIView
  private let internalView: View
  private let scrollView: UIScrollView
  private var longPressGestureRecognizer: UILongPressGestureRecognizer? = nil
  private var hoverGestureRecognizer: UIHoverGestureRecognizer? = nil
  private var hoverGestureCount: Int = 0
  private var isHovering = false
  private var lastLocation: CGPoint? = nil
  private var isDragging: Bool { lastLocation != nil }
  public final class ObjCResponder: NSObject {
    weak var controller: VerticalScrollIndicatorController? = nil
  }
  public let objCResponder: ObjCResponder

  public init(scrollView: UIScrollView) {
    internalView = View(frame: .zero)
    indicatorView = UIView(frame: .zero)
    indicatorView.layer.cornerRadius = 4
    indicatorView.backgroundColor = .senaryBorder.withAlphaComponent(0.5)
    indicatorView.alpha = 0
    self.scrollView = scrollView
    internalView.addSubview(indicatorView)
    objCResponder = ObjCResponder()
    let longPressGestureRecognizer = UILongPressGestureRecognizer(
      target: self, action: #selector(longPress(_:)))
    longPressGestureRecognizer.minimumPressDuration = 0
    longPressGestureRecognizer.cancelsTouchesInView = false
    indicatorView.addGestureRecognizer(longPressGestureRecognizer)
    let hoverGestureRecognizer = UIHoverGestureRecognizer(
      target: self, action: #selector(hover(_:)))
    hoverGestureRecognizer.cancelsTouchesInView = false
    internalView.addGestureRecognizer(hoverGestureRecognizer)
    self.hoverGestureRecognizer = hoverGestureRecognizer
    internalView.delegate = self
    objCResponder.controller = self
  }

  deinit {
    if let longPressGestureRecognizer = longPressGestureRecognizer {
      internalView.removeGestureRecognizer(longPressGestureRecognizer)
    }
    if let hoverGestureRecognizer = hoverGestureRecognizer {
      internalView.removeGestureRecognizer(hoverGestureRecognizer)
    }
  }

  @objc
  private func hover(_ gestureRecognizer: UIGestureRecognizer) {
    switch gestureRecognizer.state {
    case .began:
      isHovering = true
      didHoverIn()
    case .ended, .cancelled:
      isHovering = false
      if !isDragging {
        didDelayedHoverOut()
      }
    case .failed, .changed, .possible:
      break
    @unknown default:
      break
    }
  }

  @objc
  private func longPress(_ gestureRecognizer: UIGestureRecognizer) {
    guard isScrollIndicatorEnabled else {
      lastLocation = nil
      return
    }
    let location = gestureRecognizer.location(in: internalView)
    switch gestureRecognizer.state {
    case .began:
      lastLocation = location
      // Grabbing the indicator cancels a pending fade.
      didHoverIn()
    case .changed:
      didMoveIndicator(location: location)
      lastLocation = location
    case .ended, .cancelled:
      didMoveIndicator(location: location)
      lastLocation = nil
      if !isHovering {
        didDelayedHoverOut()
      }
    default:
      break
    }
  }

  private var isScrollIndicatorEnabled: Bool {
    scrollView.contentSize.height + scrollView.contentInset.top + scrollView.contentInset.bottom
      > scrollView.bounds.height
  }

  private func didHoverIn() {
    guard isScrollIndicatorEnabled else {
      indicatorView.alpha = 0
      return
    }
    hoverGestureCount += 1
    UIView.animate(
      withDuration: 0.2, delay: 0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      self.indicatorView.alpha = 1
    }
  }

  private func didDelayedHoverOut() {
    hoverGestureCount += 1
    let hoverGestureCount = hoverGestureCount
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800)) { [weak self] in
      guard let self = self, self.hoverGestureCount == hoverGestureCount else { return }
      self.didHoverOut()
    }
  }

  private func didHoverOut() {
    UIView.animate(
      withDuration: 0.2, delay: 0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      self.indicatorView.alpha = 0
    }
  }

  private func didMoveIndicator(location: CGPoint) {
    guard isScrollIndicatorEnabled else {
      indicatorView.alpha = 0
      return
    }
    guard let lastLocation = lastLocation else { return }
    let yDiff = location.y - lastLocation.y
    let contentSize = scrollView.contentSize
    let contentInset = scrollView.contentInset
    let verticalScrollIndicatorInsets = scrollView.verticalScrollIndicatorInsets
    let bounds = scrollView.bounds
    let upperBound = contentSize.height + contentInset.bottom + contentInset.top - bounds.height
    let unrestrictedSize =
      bounds.height / (contentSize.height + contentInset.bottom + contentInset.top)
    let indicatorBounds = internalView.bounds
    let indicatorSize = max(
      min(1, unrestrictedSize)
        * (indicatorBounds.height - verticalScrollIndicatorInsets.top
          - verticalScrollIndicatorInsets.bottom),
      16
    ).rounded()
    let scaleFactor =
      upperBound
      / (indicatorBounds.height - verticalScrollIndicatorInsets.top
        - verticalScrollIndicatorInsets.bottom - indicatorSize)
    var contentOffset = scrollView.contentOffset
    contentOffset.y += yDiff * scaleFactor
    contentOffset.y = min(max(-contentInset.top, contentOffset.y), upperBound - contentInset.top)
    scrollView.setContentOffset(contentOffset, animated: false)
  }

  private func viewDidLayoutSubviews() {
    guard isScrollIndicatorEnabled else {
      indicatorView.alpha = 0
      indicatorView.frame = .zero
      return
    }
    let contentOffset = scrollView.contentOffset
    let contentSize = scrollView.contentSize
    let contentInset = scrollView.contentInset
    let verticalScrollIndicatorInsets = scrollView.verticalScrollIndicatorInsets
    let bounds = scrollView.bounds
    let y = contentOffset.y + contentInset.top
    let upperBound = contentSize.height + contentInset.bottom + contentInset.top - bounds.height
    let unrestrictedSize =
      bounds.height / (contentSize.height + contentInset.bottom + contentInset.top)
    let indicatorBounds = internalView.bounds
    let indicatorSize = max(
      min(1, unrestrictedSize)
        * (indicatorBounds.height - verticalScrollIndicatorInsets.top
          - verticalScrollIndicatorInsets.bottom),
      16
    ).rounded()
    let indicatorY =
      (indicatorBounds.height - verticalScrollIndicatorInsets.top
        - verticalScrollIndicatorInsets.bottom - indicatorSize) * min(max(0, y / upperBound), 1)
    indicatorView.frame = CGRect(
      x: 2, y: 2 + indicatorY + verticalScrollIndicatorInsets.top, width: 8, height: indicatorSize)
  }
}

extension VerticalScrollIndicatorController {
  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === self.scrollView else { return }
    guard isScrollIndicatorEnabled else {
      indicatorView.alpha = 0
      indicatorView.frame = .zero
      return
    }
    viewDidLayoutSubviews()
    if indicatorView.alpha == 0 {
      didHoverIn()
    }
    // Stays up while hovered or dragged; leaving the strip or letting go hides it.
    if !isHovering && !isDragging {
      didDelayedHoverOut()
    }
  }
}

extension VerticalScrollIndicatorController.ObjCResponder: UICollectionViewDelegate {
  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    controller?.scrollViewDidScroll(scrollView)
  }
}

extension VerticalScrollIndicatorController {
  private final class View: UIView {
    weak var delegate: VerticalScrollIndicatorController? = nil
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      // Trackpad and wheel scrolling falls through to the scroll view underneath; hover and
      // dragging the indicator still land here.
      guard event?.type != .scroll else { return false }
      return super.point(inside: point, with: event)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard let delegate = delegate else { return }
      // Delay to the end so we have correct scroll view size layout.
      DispatchQueue.main.async {
        delegate.viewDidLayoutSubviews()
      }
    }
  }
}
