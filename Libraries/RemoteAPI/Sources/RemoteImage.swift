import Foundation
import ImageIO

/// An immutable image snapshot. Persist the bytes, not a path that can change before replay.
public struct RemoteImage: Equatable, Sendable, Codable {
  public static let maximumBytes = 10 * 1_024 * 1_024

  public enum ImageError: Error, LocalizedError {
    case tooLarge
    case unsupportedImage

    public var errorDescription: String? {
      switch self {
      case .tooLarge:
        return "Images must be at most 10 MiB."
      case .unsupportedImage:
        return "Provide a valid PNG, JPEG, WebP, or GIF image."
      }
    }
  }

  public let data: Data
  public let mediaType: String
  public let width: Int
  public let height: Int

  public init(data: Data) throws {
    guard data.count <= Self.maximumBytes else { throw ImageError.tooLarge }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source) as String?,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 32_768, height <= 32_768
    else { throw ImageError.unsupportedImage }
    switch type {
    case "public.png": mediaType = "image/png"
    case "public.jpeg": mediaType = "image/jpeg"
    case "org.webmproject.webp": mediaType = "image/webp"
    case "com.compuserve.gif": mediaType = "image/gif"
    default: throw ImageError.unsupportedImage
    }
    self.data = data
    self.width = width
    self.height = height
  }

  public init(contentsOf url: URL) throws {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else { throw ImageError.unsupportedImage }
    guard let size = values.fileSize, size <= Self.maximumBytes else { throw ImageError.tooLarge }
    try self.init(data: Data(contentsOf: url))
  }

  /// Reads an image the user attached. Photos are often larger than a model needs, rotated by
  /// EXIF, or HEIC, so those are redrawn with the long side at most `maximumPixelSize`. At 1,024
  /// pixels an image plans for at most 4,096 tokens, which leaves room in a small local context.
  public init(attachmentContentsOf url: URL, maximumPixelSize: Int = 1_024) throws {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let type = CGImageSourceGetType(source) as String?,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { throw ImageError.unsupportedImage }
    if max(width, height) <= maximumPixelSize,
      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
      ["public.png", "public.jpeg", "org.webmproject.webp", "com.compuserve.gif"].contains(type),
      let image = try? RemoteImage(contentsOf: url)
    {
      self = image
      return
    }
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: min(maximumPixelSize, max(width, height)),
        ] as CFDictionary)
    else { throw ImageError.unsupportedImage }
    let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, (isOpaque ? "public.jpeg" : "public.png") as CFString, 1, nil)
    else { throw ImageError.unsupportedImage }
    CGImageDestinationAddImage(
      destination, image,
      isOpaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
    guard CGImageDestinationFinalize(destination) else { throw ImageError.unsupportedImage }
    try self.init(data: data as Data)
  }

  var dataURL: String { "data:\(mediaType);base64,\(data.base64EncodedString())" }

  // A conservative planning allowance, not a provider billing formula. Image tokens must
  // never be estimated from base64 length or used to calibrate the text token/byte ratio.
  var estimatedTokens: Int { max(1_024, ((width + 15) / 16) * ((height + 15) / 16)) }
  var description: String { "\(width)×\(height) \(mediaType) image" }

  private enum CodingKeys: String, CodingKey { case data }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(data: container.decode(Data.self, forKey: .data))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(data, forKey: .data)
  }
}
