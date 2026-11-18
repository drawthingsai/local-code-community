import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LLM
import NNC

/// An image for Inkling 2 Small's vision tower, which takes it unresized: padded to whole 40-pixel
/// tokens, one token per 2x2 block of 20-pixel patches.
public struct Inkling2SmallImage {
  public let digest: Data
  public let grid: (height: Int, width: Int)
  public let tokenCount: Int
  private let image: CGImage

  /// The token grid from the file's size alone, upright after EXIF orientation.
  public static func grid(filePath: String) -> (height: Int, width: Int)? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: filePath) as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      var width = properties[kCGImagePropertyPixelWidth] as? Int,
      var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { return nil }
    if let orientation = properties[kCGImagePropertyOrientation] as? Int,
      (5...8).contains(orientation)
    {
      swap(&width, &height)
    }
    return Inkling2SmallVisionGrid(height: height, width: width)
  }

  public init?(filePath: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary)
    else { return nil }
    self.image = image
    digest = Data(SHA256.hash(data: data))
    grid = Inkling2SmallVisionGrid(height: image.height, width: image.width)
    tokenCount = grid.height * grid.width
  }

  /// Block-major vision patches and the class token's zero patch (Inkling2SmallVisionPreprocess).
  /// Pixels are drawn into sRGB without alpha, so sRGB and untagged files keep the values PIL's
  /// `convert("RGB")` reads in the reference processor.
  public func patches() -> Tensor<Float>? {
    let width = image.width
    let height = image.height
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var rgb = Tensor<Float>(.CPU, .NHWC(1, height, width, 3))
    rgb.withUnsafeMutableBytes { buffer in
      let values = buffer.bindMemory(to: Float.self)
      for i in 0..<(width * height) {
        for channel in 0..<3 {
          values[i * 3 + channel] = Float(pixels[i * 4 + channel]) / 255
        }
      }
    }
    return Inkling2SmallVisionPreprocess(rgb).patches
  }
}
