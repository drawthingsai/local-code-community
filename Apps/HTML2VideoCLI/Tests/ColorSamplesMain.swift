import AVFoundation
import CoreGraphics
import Foundation

let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
let image = try generator.copyCGImage(at: .zero, actualTime: nil)
let context = CGContext(
  data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
)!
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
let samples = (0..<16).map { i -> [Int] in
  let x = (i % 4) * image.width / 4 + image.width / 8
  let y = (i / 4) * image.height / 4 + image.height / 8
  let p = pixels + (y * image.width + x) * 4
  return [Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3])]
}
print(String(decoding: try JSONSerialization.data(withJSONObject: samples), as: UTF8.self))
