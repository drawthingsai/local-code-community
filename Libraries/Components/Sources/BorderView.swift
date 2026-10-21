//  Created by 4/18/24.
//
import Style
import UIKit

public final class BorderView: UIView {

  public var borderColor: UIColor = .clear {
    didSet {
      layer.borderColor = borderColor.cgColor
    }
  }

  override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    layer.borderColor = borderColor.cgColor
  }
}

extension BorderView {
  public static func defaultBorderView(cornerRadius: CGFloat = 8) -> BorderView {
    let borderView = BorderView()
    borderView.borderColor = .primaryBorder
    borderView.layer.cornerRadius = cornerRadius
    borderView.layer.borderWidth = 1
    return borderView
  }
}
