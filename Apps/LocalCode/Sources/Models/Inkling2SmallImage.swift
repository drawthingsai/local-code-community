import CoreGraphics
import CryptoKit
import DataModels
import Foundation
import ImageIO
import LLM
import NNC

/// An image for Inkling 2 Small's vision tower, which takes it unresized: padded to whole 40-pixel
/// tokens, one token per 2x2 block of 20-pixel patches. An iPhone scales an image above 4 MP down
/// to it first.
public struct Inkling2SmallImage {
  public let digest: Data
  public let grid: (height: Int, width: Int)
  public let tokenCount: Int
  private let image: CGImage
  // The size the patches are drawn at: the image's own, or the one it is scaled down to.
  private let size: (width: Int, height: Int)

  /// The file's pixel size, upright after EXIF orientation.
  private static func uprightSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      var width = properties[kCGImagePropertyPixelWidth] as? Int,
      var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { return nil }
    if let orientation = properties[kCGImagePropertyOrientation] as? Int,
      (5...8).contains(orientation)
    {
      swap(&width, &height)
    }
    return (width, height)
  }

  /// On an iPhone, the size an image above 4 MP (2,048 x 2,048 pixels) is scaled down to at its
  /// aspect ratio, which bounds the vision tower's rows and the tokens the image takes of the 64K
  /// window there: 2,704 for a square one. Nil keeps the image's own size.
  private static func scaledSize(width: Int, height: Int) -> (width: Int, height: Int)? {
    let maximumPixels = 4 * 1_024 * 1_024
    guard DeviceCapability.isPhone(), width * height > maximumPixels else { return nil }
    let scale = (Double(maximumPixels) / Double(width * height)).squareRoot()
    return (max(Int(Double(width) * scale), 1), max(Int(Double(height) * scale), 1))
  }

  /// The token grid from the file's size alone, upright after EXIF orientation.
  public static func grid(filePath: String) -> (height: Int, width: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: filePath) as CFURL, nil),
      let upright = uprightSize(source)
    else { return nil }
    let size = scaledSize(width: upright.width, height: upright.height) ?? upright
    return Inkling2SmallVisionGrid(height: size.height, width: size.width)
  }

  public init?(filePath: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let upright = Self.uprightSize(source)
    else { return nil }
    let scaled = Self.scaledSize(width: upright.width, height: upright.height)
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: scaled.map { max($0.width, $0.height) }
            ?? max(upright.width, upright.height),
        ] as CFDictionary)
    else { return nil }
    self.image = image
    digest = Data(SHA256.hash(data: data))
    // ImageIO rounds a scaled image's shorter side its own way, so that image is drawn at the size
    // `grid(filePath:)` counts from; an unscaled one keeps the size it decodes to.
    size = scaled ?? (image.width, image.height)
    grid = Inkling2SmallVisionGrid(height: size.height, width: size.width)
    tokenCount = grid.height * grid.width
  }

  /// Block-major vision patches and the class token's zero patch (Inkling2SmallVisionPreprocess).
  /// Pixels are drawn into sRGB without alpha, so sRGB and untagged files keep the values PIL's
  /// `convert("RGB")` reads in the reference processor.
  public func patches() -> Tensor<Float16>? {
    let width = size.width
    let height = size.height
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var rgb = Tensor<Float16>(.CPU, .NHWC(1, height, width, 3))
    rgb.withUnsafeMutableBytes { buffer in
      let values = buffer.bindMemory(to: Float16.self)
      for i in 0..<(width * height) {
        for channel in 0..<3 {
          values[i * 3 + channel] = Float16(Float(pixels[i * 4 + channel]) / 255)
        }
      }
    }
    return Inkling2SmallVisionPreprocess(rgb).patches
  }
}
