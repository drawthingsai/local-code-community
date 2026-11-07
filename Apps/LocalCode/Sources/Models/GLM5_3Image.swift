import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LLM
import NNC

public struct GLM5_3Image {
  public let digest: Data
  public let grid: (t: Int, h: Int, w: Int)
  public let tokenCount: Int
  private let image: CGImage

  /// The patch grid from the file's size alone, upright after EXIF orientation.
  public static func grid(filePath: String) -> (t: Int, h: Int, w: Int)? {
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
    return grid(height: height, width: width)
  }

  private static func grid(height: Int, width: Int) -> (t: Int, h: Int, w: Int) {
    let configuration = GLM5_3VisionConfiguration.glm5_3Flash
    let canvas = GLM5_3VisionSize(height: height, width: width, configuration: configuration).canvas
    return (1, canvas.height / configuration.patchSize, canvas.width / configuration.patchSize)
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
    grid = Self.grid(height: image.height, width: image.width)
    tokenCount = GLM5_3VisionTokenCount(gridThw: grid)
  }

  /// Block-major vision patches. Pixels are drawn into sRGB without alpha, so sRGB and untagged
  /// files keep the values PIL's `convert("RGB")` reads in the reference processor.
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
    return GLM5_3VisionPreprocess(rgb).patches
  }
}
