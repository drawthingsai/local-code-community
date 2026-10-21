import UIKit

public final class LayoutVisualEffectView: UIVisualEffectView {
  public var onLayoutChange: ((LayoutVisualEffectView) -> Void)? = nil

  override public func layoutSubviews() {
    super.layoutSubviews()
    onLayoutChange?(self)
  }
}
