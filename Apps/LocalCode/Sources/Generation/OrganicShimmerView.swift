import CoreImage
import UIKit

/// Native adaptation of the organic shimmer: a warped color band and a synchronized edge beam.
final class OrganicShimmerView: UIView {
  var isShimmering = false {
    didSet {
      guard isShimmering != oldValue else { return }
      updateAnimation()
    }
  }

  private let bandLayer = CALayer()
  private let edgeLayer = CALayer()
  private let bandMask = CALayer()
  private let edgeMask = CALayer()
  private var renderedSize = CGSize.zero
  private var renderedScale: CGFloat = 0
  private var motionObserver: NSObjectProtocol?
  private static let animationKey = "organicSweep"
  private static let imageContext = CIContext()
  private static let bandMaskImage = makeSweepMask(warped: true)
  private static let edgeMaskImage = makeSweepMask(warped: false)

  private struct Blob {
    let x: CGFloat
    let y: CGFloat
    let rx: CGFloat
    let ry: CGFloat
    let color: UIColor
  }

  private static let bandBlobs: [Blob] = [
    Blob(x: 0.20, y: 0.15, rx: 0.4945, ry: 0.3846, color: color(40, 140, 255, 0.14)),
    Blob(x: 0.65, y: 0.25, rx: 0.4396, ry: 0.3297, color: color(255, 50, 100, 0.13)),
    Blob(x: 0.30, y: 0.55, rx: 0.3846, ry: 0.4396, color: color(50, 200, 80, 0.12)),
    Blob(x: 0.75, y: 0.65, rx: 0.4945, ry: 0.3846, color: color(180, 40, 240, 0.13)),
    Blob(x: 0.45, y: 0.85, rx: 0.3846, ry: 0.3297, color: color(255, 120, 40, 0.12)),
    Blob(x: 0.10, y: 0.85, rx: 0.3297, ry: 0.3297, color: color(30, 185, 170, 0.11)),
  ]
  private static let edgeBlobs: [Blob] = [
    Blob(x: 0.33, y: -0.074, rx: 0.2958, ry: 0.1690, color: color(255, 50, 100, 0.62)),
    Blob(x: 0.12, y: -0.05, rx: 0.2535, ry: 0.1479, color: color(40, 140, 255, 0.48)),
    Blob(x: 0.021, y: 0.683, rx: 0.1690, ry: 0.2958, color: color(50, 200, 80, 0.55)),
    Blob(x: 0.021, y: 0.683, rx: 0.0845, ry: 0.1479, color: color(30, 185, 170, 0.44)),
    Blob(x: 0.744, y: 1, rx: 0.7606, ry: 0.1338, color: color(100, 70, 255, 0.58)),
    Blob(x: 0.55, y: 1, rx: 0.3592, ry: 0.1127, color: color(40, 140, 255, 0.51)),
    Blob(x: 0.939, y: 0, rx: 0.3099, ry: 0.1338, color: color(255, 120, 40, 0.65)),
    Blob(x: 1, y: 0.271, rx: 0.1127, ry: 0.1761, color: color(240, 50, 180, 0.50)),
    Blob(x: 1, y: 0.271, rx: 0.2183, ry: 0.2042, color: color(180, 40, 240, 0.56)),
  ]

  /// Creates the color layers and their shared sweep geometry.
  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    backgroundColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? Self.color(34, 34, 38, 1) : Self.color(238, 238, 238, 1)
    }
    clipsToBounds = true
    layer.cornerRadius = 16
    layer.addSublayer(bandLayer)
    layer.addSublayer(edgeLayer)
    bandLayer.mask = bandMask
    edgeLayer.mask = edgeMask
    edgeLayer.opacity = 0.7
    bandMask.contents = Self.bandMaskImage
    edgeMask.contents = Self.edgeMaskImage
    motionObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.updateAnimation() }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
  }

  /// Rebuilds the baked color textures only when the size or display scale changes.
  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = traitCollection.displayScale
    guard bounds.width > 0, bounds.height > 0,
      renderedSize != bounds.size || renderedScale != scale
    else { return }
    renderedSize = bounds.size
    renderedScale = scale
    let unit = min(bounds.width, bounds.height) / 142
    let overhang = 20 * unit
    let extent = bounds.insetBy(dx: -overhang, dy: -overhang)
    let tile = CGRect(origin: CGPoint(x: overhang, y: overhang), size: bounds.size)
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    let renderer = UIGraphicsImageRenderer(size: extent.size, format: format)
    let band = renderer.image { context in
      Self.drawBlobs(
        Self.bandBlobs, in: CGRect(origin: .zero, size: extent.size),
        context: context.cgContext)
    }
    let ring = renderer.image { context in
      let path = UIBezierPath(
        roundedRect: tile.insetBy(dx: unit / 2, dy: unit / 2),
        cornerRadius: max(0, 16 - unit / 2))
      context.cgContext.addPath(path.cgPath)
      context.cgContext.setLineWidth(unit)
      context.cgContext.replacePathWithStrokedPath()
      context.cgContext.clip()
      Self.drawBlobs(Self.edgeBlobs, in: tile, context: context.cgContext)
    }
    // Bake soft inner glow and bloom once per size; only the masks animate each frame.
    let glow = renderer.image { context in
      let path = UIBezierPath(roundedRect: tile, cornerRadius: 16)
      context.cgContext.addPath(path.cgPath)
      context.cgContext.setLineWidth(14 * unit)
      context.cgContext.replacePathWithStrokedPath()
      context.cgContext.clip()
      Self.drawBlobs(Self.edgeBlobs, in: tile, context: context.cgContext)
    }
    let edge = renderer.image { _ in
      Self.blurred(glow, radius: 20 * unit).draw(at: .zero, blendMode: .normal, alpha: 0.7)
      Self.blurred(glow, radius: 4 * unit).draw(at: .zero, blendMode: .normal, alpha: 0.3)
      ring.draw(at: .zero, blendMode: .normal, alpha: 0.45)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bandLayer.frame = extent
    edgeLayer.frame = extent
    bandLayer.contents = Self.blurred(band, radius: 5 * unit).cgImage
    edgeLayer.contents = edge.cgImage
    for mask in [bandMask, edgeMask] {
      mask.anchorPoint = .zero
      mask.bounds = CGRect(x: 0, y: 0, width: extent.width * 2.8, height: extent.height * 2.8)
    }
    CATransaction.commit()
    updateAnimation()
  }

  /// Stops detached animations and starts both masks together when attached.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAnimation()
  }

  private func updateAnimation() {
    let moving = isShimmering && window != nil && !UIAccessibility.isReduceMotionEnabled
    let beginTime = CACurrentMediaTime()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for mask in [bandMask, edgeMask] {
      mask.removeAnimation(forKey: Self.animationKey)
      // Center the band for a static, colorful Reduce Motion / stopped state.
      mask.position = CGPoint(x: -bandLayer.bounds.width * 0.9, y: -bandLayer.bounds.height * 0.9)
      if moving && renderedSize != .zero {
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = CGPoint(
          x: -bandLayer.bounds.width * 1.8, y: -bandLayer.bounds.height * 1.8)
        animation.toValue = CGPoint.zero
        animation.duration = 3
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.repeatCount = .infinity
        animation.beginTime = mask.convertTime(beginTime, from: nil)
        mask.add(animation, forKey: Self.animationKey)
      }
    }
    CATransaction.commit()
  }

  private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> UIColor {
    UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
  }

  private static func drawBlobs(_ blobs: [Blob], in rect: CGRect, context: CGContext) {
    // CSS paints the first gradient on top.
    for blob in blobs.reversed() {
      context.saveGState()
      context.translateBy(x: rect.minX + blob.x * rect.width, y: rect.minY + blob.y * rect.height)
      context.scaleBy(x: blob.rx * rect.width, y: blob.ry * rect.height)
      if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [blob.color.cgColor, blob.color.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1])
      {
        context.drawRadialGradient(
          gradient, startCenter: .zero, startRadius: 0,
          endCenter: .zero, endRadius: 1, options: [])
      }
      context.restoreGState()
    }
  }

  private static func blurred(_ image: UIImage, radius: CGFloat) -> UIImage {
    guard let cgImage = image.cgImage else { return image }
    let input = CIImage(cgImage: cgImage)
    let output = input.applyingFilter(
      "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * image.scale])
    guard let result = imageContext.createCGImage(output, from: input.extent) else { return image }
    return UIImage(cgImage: result, scale: image.scale, orientation: .up)
  }

  private static func makeSweepMask(warped: Bool) -> CGImage? {
    // A fixed, smooth displacement field approximates the SVG turbulence without a per-frame filter.
    // Both masks use the recipe's 280% travelling window and share the same diagonal clock.
    let size = 384
    let stops: [(Double, Double)] =
      warped
      ? [
        (0, 0), (0.292, 0), (0.383, 0.25), (0.4532, 0.7), (0.5, 1),
        (0.5468, 0.7), (0.617, 0.25), (0.708, 0), (1, 0),
      ]
      : [
        (0, 0), (0.136, 0), (0.24, 0.06), (0.344, 0.18), (0.435, 0.45),
        (0.5, 1), (0.5468, 0.5), (0.591, 0), (1, 0),
      ]
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
      for x in 0..<size {
        let u = Double(x) / Double(size - 1)
        let v = Double(y) / Double(size - 1)
        let displacement =
          warped
          ? (sin(u * 16 + sin(v * 11) + 7) * 0.014
            + sin(v * 23 - u * 9 + 7) * 0.008) : 0
        let position = min(1, max(0, (u + v) / 2 + displacement))
        var alpha = 0.0
        for i in 1..<stops.count where position <= stops[i].0 {
          let start = stops[i - 1]
          let end = stops[i]
          let fraction = (position - start.0) / (end.0 - start.0)
          alpha = start.1 + (end.1 - start.1) * fraction
          break
        }
        let value = UInt8(min(255, max(0, (alpha * 255).rounded())))
        let offset = (y * size + x) * 4
        for channel in 0..<4 { pixels[offset + channel] = value }
      }
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(
      width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
