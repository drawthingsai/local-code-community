#if targetEnvironment(macCatalyst)
  import Lottie
  import UIKit

  /// Draws Dock tiles: the app's icon as the system draws it with its raster monkey painted out, so
  /// the red fill, the squircle's rim and shadow and the sparkles stay the system's own, and a
  /// clip's vector monkey on top where the icon's sits, made to look like the icon's: its body
  /// warped onto the icon art's, its ink and cream moved to the icon art's, and the red let through
  /// it like the icon's translucent layer. Main queue only.
  final class DockTileRenderer {
    /// The tile: 128 pt on a 2x display.
    static let pixels = 256
    /// The clips' 180 × 185 unit composition in the tile: pixels a unit, and its origin (fitted on
    /// the head against the system's rendering of the icon).
    private static let unit: CGFloat = 1.08419
    private static let origin = CGPoint(x: 29.586, y: 42.278)
    /// The rig's two colors and the icon art's, in sRGB: the clips draw a lighter, bluer ink.
    private static let rigInk: SIMD3<Float> = [3, 43, 60]
    private static let rigCream: SIMD3<Float> = [250, 243, 226]
    private static let iconInk: SIMD3<Float> = [1, 26, 39]
    private static let iconCream: SIMD3<Float> = [252, 247, 230]

    /// The app's icon as the system draws it for the Dock, which every takeover starts from and
    /// ends on.
    let appIcon: CGImage
    private let background: CGImage
    private let squircleMask: CGImage
    private let warp: DockTileWarp
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var layers = [ObjectIdentifier: LottieAnimationLayer]()

    /// Nil when the icon is not the one the tile is made for (the red fill not found, as with the
    /// Dark, Clear or Tinted icon styles).
    init?(appIcon: CGImage, warp: DockTileWarp) {
      let n = Self.pixels
      let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
      var pixels = [UInt8](repeating: 0, count: n * n * 4)
      let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard
          let context = CGContext(
            data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
            space: displayP3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(appIcon, in: CGRect(x: 0, y: 0, width: n, height: n))
        return true
      }
      guard drawn else { return nil }
      // Rows run from the top in the buffer.
      let inside = (0..<n * n).map { pixels[$0 * 4 + 3] >= 250 }
      let red = (0..<n * n).map { i -> Bool in
        let r = Int(pixels[i * 4])
        let g = Int(pixels[i * 4 + 1])
        let b = Int(pixels[i * 4 + 2])
        return inside[i] && r >= 190 && g <= 150 && b <= 140 && r - g >= 90
      }
      // The fill as the system draws it (the glass makes it a gentle gradient): a quadratic per
      // channel, fitted away from the rim and from anything drawn on it.
      let sample = zip(Self.eroded(red, n, 2), Self.eroded(inside, n, 7)).map { $0 && $1 }
      guard let fill = Self.fitQuadratic(pixels, where: sample, n: n) else { return nil }
      // The raster monkey is the largest thing on the fill; the sparkles are apart from it.
      guard
        let monkey = Self.components(zip(inside, red).map { $0 && !$1 }, n).max(by: {
          $0.count < $1.count
        })
      else { return nil }
      var painted = [Bool](repeating: false, count: n * n)
      for i in monkey { painted[i] = true }
      for (i, isMonkey) in zip(Self.dilated(painted, n, 2), inside).map({ $0 && $1 }).enumerated()
      where isMonkey {
        let color = fill(Float(i % n) + 0.5, Float(i / n) + 0.5)
        for c in 0..<3 { pixels[i * 4 + c] = UInt8(min(max(color[c].rounded(), 0), 255)) }
        pixels[i * 4 + 3] = 255
      }
      // The monkey draws inside the squircle, with its anti-aliased edge from the icon's alpha (above
      // the shadow).
      let squircle = (0..<n * n).map {
        UInt8((255 * min(max((Float(pixels[$0 * 4 + 3]) - 180) / 75, 0), 1)).rounded())
      }
      guard let background = Self.image(Data(pixels), space: displayP3),
        let squircleMask = Self.grayImage(squircle)
      else { return nil }
      self.appIcon = appIcon
      self.background = background
      self.squircleMask = squircleMask
      self.warp = warp
    }

    /// The tile at `frame` of `animation`, as premultiplied Display P3 RGBA.
    func tile(_ animation: LottieAnimation, frame: AnimationFrameTime) -> Data {
      let n = Self.pixels
      let monkey = monkeyImage(animation, frame: frame)
      var pixels = Data(count: n * n * 4)
      pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(
          data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
          space: displayP3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let bounds = CGRect(x: 0, y: 0, width: n, height: n)
        context.draw(background, in: bounds)
        context.clip(to: bounds, mask: squircleMask)
        // The monkey goes on as one finished picture: the rig draws a dark silhouette with the
        // cream on top, and letting the red through shape by shape would let the silhouette through
        // the cream as well.
        context.draw(monkey, in: bounds)
      }
      return pixels
    }

    /// A tile made by `tile(_:frame:)`.
    func image(_ pixels: Data) -> CGImage {
      Self.image(pixels, space: displayP3)!
    }

    /// `tile` and the app's icon mixed, `weight` of the tile. Both are premultiplied and share the
    /// icon's alpha, so one drawn with the other added on top is an exact cross-fade.
    func crossFade(_ tile: CGImage, weight: Double) -> CGImage {
      let n = Self.pixels
      let bounds = CGRect(x: 0, y: 0, width: n, height: n)
      let context = CGContext(
        data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: displayP3,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      context.setAlpha(weight)
      context.draw(tile, in: bounds)
      context.setBlendMode(.plusLighter)
      context.setAlpha(1 - weight)
      context.draw(appIcon, in: bounds)
      return context.makeImage()!
    }

    /// Lets go of what the renderer keeps for `animation`.
    func forget(_ animation: LottieAnimation) {
      layers[ObjectIdentifier(animation)] = nil
    }

    /// The clip's monkey alone at `frame`, in sRGB (Lottie's colors are sRGB values): rendered at
    /// twice the tile's size and sampled into the tile through the warp, with the icon art's colors
    /// (each channel mapped linearly, so edges between them stay in proportion) and partly
    /// transparent like the icon's translucent layer.
    private func monkeyImage(_ animation: LottieAnimation, frame: AnimationFrameTime) -> CGImage {
      let n = Self.pixels
      let m = 2 * n
      var large = [UInt8](repeating: 0, count: m * m * 4)
      large.withUnsafeMutableBytes { buffer in
        let context = CGContext(
          data: buffer.baseAddress, width: m, height: m, bitsPerComponent: 8, bytesPerRow: m * 4,
          space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: Self.origin.x, y: CGFloat(n) - Self.origin.y)
        context.scaleBy(x: Self.unit, y: -Self.unit)
        let layer = layer(for: animation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.currentFrame = frame
        layer.forceDisplayUpdate()
        CATransaction.commit()
        layer.render(in: context)
      }
      var pixels = warp.sample(large)
      let scale = (Self.iconCream - Self.iconInk) / (Self.rigCream - Self.rigInk)
      let offset = Self.iconInk - scale * Self.rigInk
      for i in stride(from: 0, to: n * n * 4, by: 4) where pixels[i + 3] > 0 {
        let alpha = Float(pixels[i + 3])
        // Premultiplied: an affine map's offset scales with the alpha.
        var color = scale * SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
        color += offset * (alpha / 255)
        color = color.rounded(.toNearestOrAwayFromZero).clamped(
          lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: alpha))
        let lightness = (color.x + color.y + color.z) / (3 * alpha)
        let keep = 1 - Self.translucency(row: Float(i / (4 * n)) + 0.5, lightness: lightness)
        pixels[i] = UInt8((color.x * keep).rounded())
        pixels[i + 1] = UInt8((color.y * keep).rounded())
        pixels[i + 2] = UInt8((color.z * keep).rounded())
        pixels[i + 3] = UInt8((alpha * keep).rounded())
      }
      return Self.image(Data(pixels), space: sRGB)!
    }

    private func layer(for animation: LottieAnimation) -> LottieAnimationLayer {
      if let layer = layers[ObjectIdentifier(animation)] { return layer }
      let layer = LottieAnimationLayer(
        animation: animation,
        configuration: LottieConfiguration(renderingEngine: .mainThread, colorSpace: sRGB))
      layer.frame = animation.bounds
      // A bare layer places its animation itself (LottieAnimationView does this in layout).
      layer.sublayers?.first?.position = CGPoint(x: animation.bounds.midX, y: animation.bounds.midY)
      layers[ObjectIdentifier(animation)] = layer
      return layer
    }

    /// The icon's layer has translucency 0.3, which the system draws as the red showing through
    /// little at the helmet's top and more toward the bottom, and through the ink about three
    /// quarters as much as through the cream. Fitted on the system's rendering against the art's own
    /// colors: the share of red at a tile row, for a color of `lightness` 0 to 1.
    private static func translucency(row: Float, lightness: Float) -> Float {
      min(max(0.03 + 0.00028 * (4 * row - 220), 0), 0.3) * (0.75 + 0.25 * lightness)
    }

    private static func image(_ pixels: Data, space: CGColorSpace) -> CGImage? {
      guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
      return CGImage(
        width: pixels.count / (4 * Self.pixels), height: Self.pixels, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: 4 * Self.pixels, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func grayImage(_ values: [UInt8]) -> CGImage? {
      guard let provider = CGDataProvider(data: Data(values) as CFData) else { return nil }
      return CGImage(
        width: Self.pixels, height: Self.pixels, bitsPerComponent: 8, bitsPerPixel: 8,
        bytesPerRow: Self.pixels, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
        decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - The fill and the masks

    /// A least-squares quadratic in x and y for each color channel, over the `sample` pixels.
    private static func fitQuadratic(_ pixels: [UInt8], where sample: [Bool], n: Int) -> (
      (Float, Float) -> SIMD3<Float>
    )? {
      func terms(_ x: Float, _ y: Float) -> [Double] {
        let u = Double(x) / Double(n)
        let v = Double(y) / Double(n)
        return [1, u, v, u * u, u * v, v * v]
      }
      var normal = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
      var right = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 6)
      var count = 0
      for i in 0..<n * n where sample[i] {
        let t = terms(Float(i % n) + 0.5, Float(i / n) + 0.5)
        for a in 0..<6 {
          for b in 0..<6 { normal[a][b] += t[a] * t[b] }
          for c in 0..<3 { right[a][c] += t[a] * Double(pixels[i * 4 + c]) }
        }
        count += 1
      }
      guard count > 500 else { return nil }
      // Gaussian elimination with partial pivoting, three right-hand sides at once.
      for column in 0..<6 {
        let pivot = (column..<6).max { abs(normal[$0][column]) < abs(normal[$1][column]) }!
        normal.swapAt(column, pivot)
        right.swapAt(column, pivot)
        guard abs(normal[column][column]) > 1e-12 else { return nil }
        for row in 0..<6 where row != column {
          let f = normal[row][column] / normal[column][column]
          for k in column..<6 { normal[row][k] -= f * normal[column][k] }
          for c in 0..<3 { right[row][c] -= f * right[column][c] }
        }
      }
      let coefficients = (0..<3).map { c in (0..<6).map { right[$0][c] / normal[$0][$0] } }
      return { x, y in
        let t = terms(x, y)
        let value = coefficients.map { zip($0, t).reduce(0) { $0 + $1.0 * $1.1 } }
        return SIMD3(Float(value[0]), Float(value[1]), Float(value[2]))
      }
    }

    /// The mask shrunk by `iterations` pixels (4-neighbor).
    private static func eroded(_ mask: [Bool], _ n: Int, _ iterations: Int) -> [Bool] {
      var mask = mask
      for _ in 0..<iterations {
        var next = mask
        for i in 0..<n * n where mask[i] {
          let x = i % n
          let y = i / n
          if x == 0 || y == 0 || x == n - 1 || y == n - 1 || !mask[i - 1] || !mask[i + 1]
            || !mask[i - n] || !mask[i + n]
          {
            next[i] = false
          }
        }
        mask = next
      }
      return mask
    }

    private static func dilated(_ mask: [Bool], _ n: Int, _ iterations: Int) -> [Bool] {
      eroded(mask.map { !$0 }, n, iterations).map { !$0 }
    }

    /// The mask's 4-connected parts, as pixel indices.
    private static func components(_ mask: [Bool], _ n: Int) -> [[Int]] {
      var seen = [Bool](repeating: false, count: n * n)
      var components = [[Int]]()
      for start in 0..<n * n where mask[start] && !seen[start] {
        var stack = [start]
        var members = [Int]()
        seen[start] = true
        while let i = stack.popLast() {
          members.append(i)
          let x = i % n
          let y = i / n
          for (j, isInside) in [
            (i - 1, x > 0), (i + 1, x < n - 1), (i - n, y > 0), (i + n, y < n - 1),
          ]
          where isInside && mask[j] && !seen[j] {
            seen[j] = true
            stack.append(j)
          }
        }
        components.append(members)
      }
      return components
    }
  }
#endif
