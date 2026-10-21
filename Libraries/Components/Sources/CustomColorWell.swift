import Style
import UIKit

public protocol CustomColorWellDelegate: AnyObject {
  func didUpdateCustomColorWellSelectedColor(selectedColor: UIColor)
}

public final class CustomColorWell: UIControl, UIGestureRecognizerDelegate {
  public weak var delegate: CustomColorWellDelegate? = nil

  public var selectedColor: UIColor? {
    get { colorWell.selectedColor }
    set { colorWell.selectedColor = newValue }
  }

  private let colorWell: UIColorWell = {
    let colorWell = UIColorWell()
    colorWell.translatesAutoresizingMaskIntoConstraints = false
    colorWell.supportsAlpha = true
    colorWell.selectedColor = .primaryColor
    return colorWell
  }()
  private let imageView: UIImageView = {
    let imageView = UIImageView()
    imageView.image = #imageLiteral(resourceName: "plus")

    return imageView
  }()

  public override var isSelected: Bool {
    didSet {
      layer.borderColor = isSelected ? UIColor.white.cgColor : UIColor.clear.cgColor
    }
  }

  public override var isHighlighted: Bool {
    didSet {
      layer.borderColor = isHighlighted ? UIColor.white.cgColor : UIColor.clear.cgColor
    }
  }
  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(colorWell)
    colorWell.snp.makeConstraints { make in
      make.top.equalToSuperview().offset(-10)
      make.bottom.equalToSuperview().offset(10)
      make.leading.equalToSuperview().offset(-10)
      make.trailing.equalToSuperview().offset(10)
    }
    addSubview(imageView)
    imageView.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.width.height.equalTo(14)
    }

    colorWell.addTarget(self, action: #selector(colorDidChange(_:)), for: .valueChanged)
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError()
  }

  @objc func colorDidChange(_ sender: UIColorWell) {
    if let color = sender.selectedColor {
      delegate?.didUpdateCustomColorWellSelectedColor(selectedColor: color)
    }
  }
}
