import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LLM
import NNC

public struct DeepSeek4_1Image {
  public let digest: Data
  public let tokenCount: Int
  private let image: CGImage

  public init?(filePath: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else { return nil }
    digest = Data(SHA256.hash(data: data))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
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
    let config = DeepSeek4_1VisionConfiguration.deepSeekV4_1Flash
    let grid = DeepSeek4_1VisionGrid(width: image.width, height: image.height)
    let targetWidth = grid.width * config.patchSize
    let targetHeight = grid.height * config.patchSize
    guard
      let context = CGContext(
        data: nil, width: targetWidth, height: targetHeight,
        bitsPerComponent: 8, bytesPerRow: targetWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 127 / 255, green: 127 / 255, blue: 127 / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    let scale = min(
      Double(targetWidth) / Double(image.width), Double(targetHeight) / Double(image.height))
    let fittedWidth = Int((Double(image.width) * scale).rounded(.toNearestOrEven))
    let fittedHeight = Int((Double(image.height) * scale).rounded(.toNearestOrEven))
    context.interpolationQuality = .high
    context.draw(
      image,
      in: CGRect(
        x: (targetWidth - fittedWidth) / 2,
        y: (targetHeight - fittedHeight) / 2, width: fittedWidth, height: fittedHeight))
    guard let normalized = context.makeImage() else { return nil }
    self.image = normalized
    tokenCount = DeepSeek4_1VisionTokenCount(grid: grid)
  }

  public func patches() -> (tensor: Tensor<Float16>, grid: (height: Int, width: Int)) {
    let p = DeepSeek4_1VisionConfiguration.deepSeekV4_1Flash.patchSize
    let width = image.width
    let height = image.height
    precondition(width.isMultiple(of: p) && height.isMultiple(of: p))
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    let grid = (height: height / p, width: width / p)
    var patches = Tensor<Float16>(.CPU, .WC(grid.height * grid.width, 3 * p * p))
    patches.withUnsafeMutableBytes { buffer in
      let values = buffer.bindMemory(to: Float16.self)
      var index = 0
      for y in 0..<grid.height {
        for x in 0..<grid.width {
          for channel in 0..<3 {
            for py in 0..<p {
              for px in 0..<p {
                values[index] = Float16(
                  Float(pixels[((y * p + py) * width + x * p + px) * 4 + channel]) / 127.5 - 1)
                index += 1
              }
            }
          }
        }
      }
    }
    return (patches, grid)
  }
}
