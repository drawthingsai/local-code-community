#if canImport(UIKit)
  import UIKit

  /// Autoscrolls the scroll view around a text view that does not scroll itself while a pointer
  /// drag selects past the scroll view's visible edge, and extends the selection to the pointer as
  /// the text moves under it. UIKit only autoscrolls the text view itself, so a long message in a
  /// transcript could not be selected past what is on screen.
  final class SelectionAutoscrollController {
    /// Like AppKit's autoscroll, which scrolls by the pointer's distance past the edge about 20
    /// times a second: points per second for each point past the edge.
    private static let speed: CGFloat = 20
    private unowned let textView: UITextView
    private let panGestureRecognizer: UIPanGestureRecognizer
    private var displayLink: CADisplayLink? = nil
    private var lastTimestamp: CFTimeInterval? = nil
    /// In window coordinates; the text moves under it while autoscrolling.
    private var pointerLocation: CGPoint? = nil
    /// What the drag selects by after a double- or triple-click; nil selects by character.
    fileprivate var granularity: UITextGranularity? = nil
    /// What stays selected at the fixed end of the drag, taken when autoscrolling first starts.
    private var anchor: UITextRange? = nil
    final class ObjCResponder: NSObject {
      weak var controller: SelectionAutoscrollController? = nil
    }
    private let objCResponder: ObjCResponder

    init(textView: UITextView) {
      self.textView = textView
      objCResponder = ObjCResponder()
      panGestureRecognizer = UIPanGestureRecognizer()
      #if targetEnvironment(macCatalyst)
        // The Mac has only the pointer; which type its clicks arrive as depends on whether the app
        // opts in to indirect input.
        panGestureRecognizer.allowedTouchTypes = [
          NSNumber(value: UITouch.TouchType.direct.rawValue),
          NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
      #else
        // A finger drag scrolls the scroll view instead of selecting.
        panGestureRecognizer.allowedTouchTypes = [
          NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
      #endif
      // Only watches the drag; UIKit's text interaction still does the selecting.
      panGestureRecognizer.cancelsTouchesInView = false
      panGestureRecognizer.delaysTouchesBegan = false
      panGestureRecognizer.delaysTouchesEnded = false
      panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
      panGestureRecognizer.delegate = objCResponder
      textView.addGestureRecognizer(panGestureRecognizer)
      objCResponder.controller = self
    }

    deinit {
      displayLink?.invalidate()
    }

    @objc
    private func pan(_ gestureRecognizer: UIPanGestureRecognizer) {
      switch gestureRecognizer.state {
      case .began, .changed:
        pointerLocation = gestureRecognizer.location(in: nil)
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(
          target: objCResponder, selector: #selector(ObjCResponder.displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
      case .ended, .cancelled, .failed:
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
        pointerLocation = nil
        anchor = nil
      case .possible:
        break
      @unknown default:
        break
      }
    }

    fileprivate func displayLinkDidFire(_ displayLink: CADisplayLink) {
      // Cap the step so a stalled frame does not jump the scroll.
      let elapsed = min(lastTimestamp.map { displayLink.timestamp - $0 } ?? 0, 1.0 / 30)
      lastTimestamp = displayLink.timestamp
      guard let pointerLocation, textView.window != nil, textView.isSelectable,
        !textView.isScrollEnabled, !textView.isTextDragActive
      else { return }
      var superview = textView.superview
      while let view = superview, !((view as? UIScrollView)?.isScrollEnabled ?? false) {
        superview = view.superview
      }
      guard let scrollView = superview as? UIScrollView, !scrollView.isDragging else { return }
      // The visible region is where content rests, clear of whatever covers the insets.
      let insets = scrollView.adjustedContentInset
      let bounds = scrollView.bounds
      let location = scrollView.convert(pointerLocation, from: nil)
      let overshoot: CGFloat
      if location.y < bounds.minY + insets.top {
        overshoot = location.y - (bounds.minY + insets.top)
      } else if location.y > bounds.maxY - insets.bottom {
        overshoot = location.y - (bounds.maxY - insets.bottom)
      } else {
        return
      }
      if anchor == nil {
        // A drag that has not selected anything yet is not selecting text.
        guard let selectedTextRange = textView.selectedTextRange, !selectedTextRange.isEmpty,
          let position = textView.closestPosition(to: textView.convert(pointerLocation, from: nil))
        else { return }
        // The pointer drags the selection end nearer to it; the word or paragraph at the other end
        // stays selected even when the pointer crosses back over it.
        let offset = textView.offset(from: textView.beginningOfDocument, to: position)
        let startOffset = textView.offset(
          from: textView.beginningOfDocument, to: selectedTextRange.start)
        let endOffset = textView.offset(
          from: textView.beginningOfDocument, to: selectedTextRange.end)
        let (fixedEnd, direction): (UITextPosition, UITextStorageDirection) =
          abs(offset - startOffset) <= abs(offset - endOffset)
          ? (selectedTextRange.end, .backward) : (selectedTextRange.start, .forward)
        anchor =
          granularity.flatMap {
            textView.tokenizer.rangeEnclosingPosition(
              fixedEnd, with: $0, inDirection: .storage(direction))
          } ?? textView.textRange(from: fixedEnd, to: fixedEnd)
      }
      guard let anchor else { return }
      // Scroll no further than this text reaches: past it there is nothing more to select, and the
      // text must stay on screen to keep the drag.
      let textFrame = textView.convert(textView.bounds, to: scrollView)
      let contentOffset = scrollView.contentOffset
      var y = contentOffset.y + overshoot * Self.speed * elapsed
      if overshoot > 0 {
        let maxY = min(
          textFrame.maxY + insets.bottom - bounds.height,
          scrollView.contentSize.height + insets.bottom - bounds.height)
        y = min(y, max(contentOffset.y, maxY))
      } else {
        let minY = max(textFrame.minY - insets.top, -insets.top)
        y = max(y, min(contentOffset.y, minY))
      }
      guard y != contentOffset.y else { return }
      scrollView.contentOffset = CGPoint(x: contentOffset.x, y: y)
      // The pointer has not moved, so UIKit will not extend the selection over the scrolled text.
      let point = textView.convert(pointerLocation, from: nil)
      guard let position = textView.closestPosition(to: point) else { return }
      // Like UIKit, select the whole word or paragraph under the pointer.
      let unit = granularity.flatMap { granularity in
        textView.characterRange(at: point).flatMap {
          textView.tokenizer.rangeEnclosingPosition(
            $0.start, with: granularity, inDirection: .storage(.forward))
        }
      }
      let start = unit?.start ?? position
      let end = unit?.end ?? position
      guard
        let range = textView.textRange(
          from: textView.compare(anchor.start, to: start) == .orderedAscending
            ? anchor.start : start,
          to: textView.compare(anchor.end, to: end) == .orderedDescending ? anchor.end : end)
      else { return }
      textView.selectedTextRange = range
    }
  }

  extension SelectionAutoscrollController.ObjCResponder: UIGestureRecognizerDelegate {
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
      // A drag after a double- or triple-click selects by word or paragraph.
      controller?.granularity =
        touch.tapCount >= 3 ? .paragraph : touch.tapCount == 2 ? .word : nil
      return true
    }

    @objc
    func displayLinkDidFire(_ displayLink: CADisplayLink) {
      controller?.displayLinkDidFire(displayLink)
    }
  }
#endif
