#if canImport(UIKit)
  import UIKit

  /// A scroll indicator strip for a horizontally scrolling view, shown on hover or scroll and
  /// draggable. Lay `view` along the bottom of the scroll view and set the scroll view's delegate
  /// to `objCResponder`.
  final class HorizontalScrollIndicatorController {
    var view: UIView { internalView }
    private let indicatorView: UIView
    private let internalView: View
    private let scrollView: UIScrollView
    private var longPressGestureRecognizer: UILongPressGestureRecognizer? = nil
    private var hoverGestureRecognizer: UIHoverGestureRecognizer? = nil
    private var hoverGestureCount: Int = 0
    private var isHovering = false
    private var lastLocation: CGPoint? = nil
    private var isDragging: Bool { lastLocation != nil }
    final class ObjCResponder: NSObject {
      weak var controller: HorizontalScrollIndicatorController? = nil
    }
    let objCResponder: ObjCResponder

    init(scrollView: UIScrollView) {
      internalView = View(frame: .zero)
      indicatorView = UIView(frame: .zero)
      indicatorView.layer.cornerRadius = 4
      // The grey of the host app's vertical scroll indicator.
      indicatorView.backgroundColor = UIColor { traitCollection in
        switch traitCollection.userInterfaceStyle {
        case .light:
          return UIColor(red: 0.549, green: 0.592, blue: 0.643, alpha: 0.5)
        default:
          return UIColor(red: 0.333, green: 0.369, blue: 0.408, alpha: 0.5)
        }
      }
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
      scrollView.contentSize.width + scrollView.contentInset.left + scrollView.contentInset.right
        > scrollView.bounds.width
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
      let xDiff = location.x - lastLocation.x
      let contentSize = scrollView.contentSize
      let contentInset = scrollView.contentInset
      let horizontalScrollIndicatorInsets = scrollView.horizontalScrollIndicatorInsets
      let bounds = scrollView.bounds
      let upperBound = contentSize.width + contentInset.right + contentInset.left - bounds.width
      let unrestrictedSize =
        bounds.width / (contentSize.width + contentInset.right + contentInset.left)
      let indicatorBounds = internalView.bounds
      let indicatorSize = max(
        min(1, unrestrictedSize)
          * (indicatorBounds.width - horizontalScrollIndicatorInsets.left
            - horizontalScrollIndicatorInsets.right),
        16
      ).rounded()
      let scaleFactor =
        upperBound
        / (indicatorBounds.width - horizontalScrollIndicatorInsets.left
          - horizontalScrollIndicatorInsets.right - indicatorSize)
      var contentOffset = scrollView.contentOffset
      contentOffset.x += xDiff * scaleFactor
      contentOffset.x = min(
        max(-contentInset.left, contentOffset.x), upperBound - contentInset.left)
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
      let horizontalScrollIndicatorInsets = scrollView.horizontalScrollIndicatorInsets
      let bounds = scrollView.bounds
      let x = contentOffset.x + contentInset.left
      let upperBound = contentSize.width + contentInset.right + contentInset.left - bounds.width
      let unrestrictedSize =
        bounds.width / (contentSize.width + contentInset.right + contentInset.left)
      let indicatorBounds = internalView.bounds
      let indicatorSize = max(
        min(1, unrestrictedSize)
          * (indicatorBounds.width - horizontalScrollIndicatorInsets.left
            - horizontalScrollIndicatorInsets.right),
        16
      ).rounded()
      let indicatorX =
        (indicatorBounds.width - horizontalScrollIndicatorInsets.left
          - horizontalScrollIndicatorInsets.right - indicatorSize) * min(max(0, x / upperBound), 1)
      indicatorView.frame = CGRect(
        x: indicatorX + horizontalScrollIndicatorInsets.left, y: 2, width: indicatorSize, height: 8)
    }
  }

  extension HorizontalScrollIndicatorController {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
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

  extension HorizontalScrollIndicatorController.ObjCResponder: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      controller?.scrollViewDidScroll(scrollView)
    }
  }

  extension HorizontalScrollIndicatorController {
    private final class View: UIView {
      weak var delegate: HorizontalScrollIndicatorController? = nil
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
#endif
