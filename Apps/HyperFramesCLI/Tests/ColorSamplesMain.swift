import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let image: CGImage
if url.pathExtension == "png" {
  let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
  image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
  guard image.colorSpace?.name == CGColorSpace.sRGB else {
    fatalError("Snapshot must carry an sRGB color profile: \(String(describing: image.colorSpace))")
  }
} else {
  let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  image = try generator.copyCGImage(at: .zero, actualTime: nil)
}
let context = CGContext(
  data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
)!
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "stripes" {
  let distinct = (0..<image.width).filter { x in
    let p = pixels + (image.height / 2 * image.width + x) * 4
    return (p[2] > 240 && p[0] < 15) || (p[0] > 240 && p[2] < 15)
  }.count
  guard distinct > image.width * 9 / 10 else {
    fatalError("High-density vector detail was lost: \(distinct)/\(image.width)")
  }
  print("High-density vector detail preserved")
  exit(0)
}
let samples = (0..<16).map { index -> [Int] in
  let x = (index % 4) * image.width / 4 + image.width / 8
  let y = (index / 4) * image.height / 4 + image.height / 8
  let p = pixels + (y * image.width + x) * 4
  return [Int(p[2]), Int(p[1]), Int(p[0]), Int(p[3])]
}
print(String(decoding: try JSONSerialization.data(withJSONObject: samples), as: UTF8.self))
