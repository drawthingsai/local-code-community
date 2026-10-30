import Style
import UIKit

/// Host status: the banner's astronaut monkey and sparkles on its tile, cropped to the monkey's
/// end of the banner. The tile shows a Mac's status: mint when available, gray when offline or not
/// yet checked, and while busy it cycles through the banner's colors, faster than the banner.
final class HostStatusIconView: UIView {
  enum Status: Equatable {
    case available
    case busy
    case offline
  }

  var status: Status = .offline {
    didSet {
      guard status != oldValue else { return }
      updateTile()
    }
  }

  /// The visible part of the banner's 1114 × 206 composition (see EmptyBannerController).
  private static let crop = CGRect(x: -21, y: -5, width: 228, height: 212)
  static let aspectRatio = crop.width / crop.height

  private let tileLayer = CAShapeLayer()
  private let artworkLayer = CALayer()

  /// The monkey and sparkles, drawn once for the crop.
  private static let artwork: UIImage = {
    let size = CGSize(width: crop.width / 4, height: crop.height / 4)
    return UIGraphicsImageRenderer(size: size).image { context in
      context.cgContext.scaleBy(x: size.height / crop.height, y: size.height / crop.height)
      context.cgContext.translateBy(x: -crop.minX, y: -crop.minY)
      UIImage(named: "monkey-astronaut-sparkles")?.draw(in: EmptyBannerController.sparklesRect)
      UIImage(named: "monkey-astronaut")?.draw(in: EmptyBannerController.monkeyRect)
    }
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    layer.addSublayer(tileLayer)
    artworkLayer.contents = Self.artwork.cgImage
    artworkLayer.contentsGravity = .resizeAspect
    layer.addSublayer(artworkLayer)
    updateTile()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = bounds.height / Self.crop.height
    // The banner's background, aspect-fit into the composition: 1084 × 175 scaled to 1114 wide
    // and centered vertically. Only its leading end shows; the rest runs past the crop.
    let backgroundHeight = 175.0 * 1114 / 1084
    let tile = CGRect(
      x: -Self.crop.minX * scale, y: ((206 - backgroundHeight) / 2 - Self.crop.minY) * scale,
      width: (Self.crop.width + 40) * scale, height: backgroundHeight * scale)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    tileLayer.frame = bounds
    tileLayer.path =
      UIBezierPath(roundedRect: tile, cornerRadius: 24 * 1114 / 1084 * scale).cgPath
    let mask = CAShapeLayer()
    mask.path = UIBezierPath(rect: bounds).cgPath
    tileLayer.mask = mask
    artworkLayer.frame = bounds
    CATransaction.commit()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle
    else { return }
    // The colors resolve per appearance.
    updateTile()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Layer animations are dropped when the view leaves a window.
    updateTile()
  }

  private func updateTile() {
    tileLayer.removeAnimation(forKey: "cycle")
    let resolve = { (color: UIColor) in color.resolvedColor(with: self.traitCollection).cgColor }
    switch status {
    case .available:
      // The banner's mint.
      tileLayer.fillColor = resolve(EmptyBannerController.cycleColors[2])
    case .offline:
      tileLayer.fillColor = resolve(.senaryText)
    case .busy:
      // The banner's colors in its order, much faster than the banner: seven eased steps from
      // red back to red, with no hold.
      let step = 0.2
      let duration = 7 * step
      let colors = [UIColor.primaryColor] + EmptyBannerController.cycleColors
      let animation = CAKeyframeAnimation(keyPath: "fillColor")
      animation.values = colors.map(resolve)
      animation.keyTimes = (0...7).map { NSNumber(value: Double($0) * step / duration) }
      let eased = CAMediaTimingFunction(controlPoints: 0.33, 0, 0.67, 1)
      animation.timingFunctions = Array(repeating: eased, count: 7)
      animation.duration = duration
      animation.repeatCount = .infinity
      animation.isRemovedOnCompletion = false
      tileLayer.fillColor = resolve(.primaryColor)
      tileLayer.add(animation, forKey: "cycle")
    }
  }
}
