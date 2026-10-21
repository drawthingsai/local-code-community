import Style
import UIKit

final class BorderView: UIView {
  var borderColor: UIColor = .clear {
    didSet {
      layer.borderColor = borderColor.cgColor
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    layer.borderColor = borderColor.cgColor
  }
}

extension BorderView {
  static func defaultBorderView(cornerRadius: CGFloat = 8) -> BorderView {
    let borderView = BorderView()
    borderView.borderColor = .primaryBorder
    borderView.layer.cornerRadius = cornerRadius
    borderView.layer.borderWidth = 1
    return borderView
  }
}
