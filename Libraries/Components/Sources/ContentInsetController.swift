import SnapKit
import UIKit

/// Lays out where a vertically scrolling view's content rests with Auto Layout.
///
/// Pin `view` to the scroll view's frame, then constrain `layoutGuide` to where the content should
/// rest. The top and bottom gaps between the two become the content insets, so the content still
/// scrolls under whatever covers those edges. The side gaps become the layout margins, which a
/// compositional layout fills with `contentInsetsReference = .layoutMargins`. Both follow anything
/// that moves the guide, such as a growing input, the keyboard or a window resize.
public final class ContentInsetController {
  public var view: UIView { internalView }
  /// Where the content rests. The gaps are measured from the scroll view's frame, so constrain this
  /// to a safe area where one matters.
  public let layoutGuide = UILayoutGuide()
  private let internalView: View
  // A guide that only moves does not lay out its owning view, but a subview that only moves does.
  private let trackingView: UIView
  private let scrollView: UIScrollView

  public init(scrollView: UIScrollView) {
    internalView = View(frame: .zero)
    internalView.isUserInteractionEnabled = false
    trackingView = UIView(frame: .zero)
    trackingView.isUserInteractionEnabled = false
    self.scrollView = scrollView
    // The gaps are the whole insets and margins; neither the safe area nor the superview's margins
    // may add to them.
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.insetsLayoutMarginsFromSafeArea = false
    scrollView.preservesSuperviewLayoutMargins = false
    internalView.addLayoutGuide(layoutGuide)
    internalView.addSubview(trackingView)
    trackingView.snp.makeConstraints { make in
      make.edges.equalTo(layoutGuide)
    }
    internalView.controller = self
  }

  private func layoutSubviews() {
    let bounds = internalView.bounds
    let frame = trackingView.frame
    var contentInset = scrollView.contentInset
    contentInset.top = frame.minY
    contentInset.bottom = bounds.height - frame.maxY
    if scrollView.contentInset != contentInset {
      scrollView.contentInset = contentInset
    }
    var layoutMargins = scrollView.layoutMargins
    layoutMargins.left = frame.minX
    layoutMargins.right = bounds.width - frame.maxX
    if scrollView.layoutMargins != layoutMargins {
      scrollView.layoutMargins = layoutMargins
    }
  }

  private final class View: UIView {
    weak var controller: ContentInsetController?

    override func layoutSubviews() {
      super.layoutSubviews()
      controller?.layoutSubviews()
    }
  }
}
