import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LLM
import NNC
import ProjectHistoryManager

public struct Qwen3_5Image {
  public let digest: Data
  public let grid: (t: Int, h: Int, w: Int)
  public let tokenCount: Int
  private let image: CGImage
  private let configuration: Qwen3_5VisionConfiguration

  public static func grid(filePath: String, configuration: Qwen3_5VisionConfiguration)
    -> (t: Int, h: Int, w: Int)?
  {
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
    let size = Qwen3_5VisionSize(height: height, width: width, configuration: configuration)
    return (1, size.height / configuration.patchSize, size.width / configuration.patchSize)
  }

  public init?(filePath: String, configuration: Qwen3_5VisionConfiguration) {
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
    self.configuration = configuration
    digest = Data(SHA256.hash(data: data))
    let size = Qwen3_5VisionSize(
      height: image.height, width: image.width, configuration: configuration)
    grid = (1, size.height / configuration.patchSize, size.width / configuration.patchSize)
    tokenCount = Qwen3_5VisionTokenCount(gridThw: grid, configuration: configuration)
  }

  public func patches() -> Tensor<Float>? {
    let width = image.width
    let height = image.height
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    var rgb = Tensor<Float>(.CPU, .NHWC(1, height, width, 3))
    rgb.withUnsafeMutableBytes { buffer in
      let values = buffer.bindMemory(to: Float.self)
      for i in 0..<(width * height) {
        for channel in 0..<3 {
          values[i * 3 + channel] = Float(pixels[i * 4 + channel]) / 127.5 - 1
        }
      }
    }
    return Qwen3_5VisionPreprocess(rgb, configuration: configuration).patches
  }
}

/// Per-image rotary tensors live only during prefill. Checkpoints retain the scalar cursor delta.
struct Qwen3_5ImageRotaryEmbedding<FloatType: TensorNumeric & BinaryFloatingPoint> {
  let configuration: Qwen3_5ModelConfiguration
  let visionConfiguration: Qwen3_5VisionConfiguration
  private var imageRotaries = [Int64: (tensor: Tensor<FloatType>, base: Int)]()

  init(configuration: Qwen3_5ModelConfiguration, visionConfiguration: Qwen3_5VisionConfiguration) {
    self.configuration = configuration
    self.visionConfiguration = visionConfiguration
  }

  mutating func embedding(
    start: Int, length: Int, lookahead: Int, ropeDelta: Int,
    spans: [EmbedSpan], imageGrids: [Int64: (t: Int, h: Int, w: Int)]
  ) -> (tensor: Tensor<FloatType>, ropeDelta: Int) {
    // Unavailable images retain their placeholder tokens and use text positions.
    let spans = spans.filter { imageGrids[$0.start] != nil }
    let end = start + length + lookahead
    var overall = Tensor<FloatType>(.CPU, .NHWC(1, end - start, 1, configuration.attentionHeadDim))
    var position = start
    var delta = ropeDelta
    var endRopeDelta = ropeDelta
    let targetEnd = start + length
    while position < end {
      // Split at the target endpoint so lookahead cannot change the checkpoint's scalar.
      let limit = position < targetEnd ? targetEnd : end
      let next: Int
      if let span = spans.first(where: { $0.start <= position && position < $0.end }) {
        let grid = imageGrids[span.start]!
        next = min(limit, Int(span.end))
        let imageOffset = position - Int(span.start)
        let width = grid.w / visionConfiguration.spatialMergeSize
        if imageRotaries[span.start] == nil {
          let precedingExtent =
            imageOffset == 0
            ? 0 : max((imageOffset - 1) / width, min(width - 1, imageOffset - 1)) + 1
          let base = position + delta - precedingExtent
          var ids = Qwen3_5MakeMultimodalPositionIDs(
            tokenTypeIDs: Array(repeating: 1, count: Int(span.length)),
            imageGridThw: [grid], configuration: visionConfiguration)
          ids.temporal = ids.temporal.map { $0 + base }
          ids.height = ids.height.map { $0 + base }
          ids.width = ids.width.map { $0 + base }
          imageRotaries[span.start] = (
            Qwen3_5RotaryEmbedding(
              positionIDs: ids, configuration: configuration, of: FloatType.self), base
          )
        }
        guard let rotary = imageRotaries[span.start] else {
          preconditionFailure("Missing prepared image rotary")
        }
        overall[
          0..<1, (position - start)..<(next - start), 0..<1, 0..<configuration.attentionHeadDim] =
          rotary.tensor[
            0..<1, imageOffset..<(imageOffset + next - position), 0..<1,
            0..<configuration.attentionHeadDim]
        let processed = next - Int(span.start)
        delta = rotary.base + max((processed - 1) / width, min(width - 1, processed - 1)) + 1 - next
      } else {
        next = min(
          limit, spans.first(where: { $0.start > position }).map { Int($0.start) } ?? limit)
        overall[
          0..<1, (position - start)..<(next - start), 0..<1, 0..<configuration.attentionHeadDim] =
          Qwen3_5RotaryEmbedding(
            sequenceLength: next - position, cachedTokenLength: position + delta,
            configuration: configuration, of: FloatType.self)
      }
      position = next
      if position == targetEnd { endRopeDelta = delta }
    }
    return (overall, endRopeDelta)
  }
}
