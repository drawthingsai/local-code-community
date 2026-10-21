import ArgumentParser
import CoreLocation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

enum PhotosError: LocalizedError {
  case assetNotFound(String)
  case albumNotFound(String)
  case folderNotFound(String)
  case readOnlyAlbum(String)
  case notEditable(String)
  case notAPhoto(String)
  case unsupportedFile(String)
  case imageUnavailable(String)
  case encodingFailed
  case invalidChangeToken
  case expiredChangeToken
  case declined

  var errorDescription: String? {
    switch self {
    case .assetNotFound(let id):
      return "No photo or video has ID \(id). Run `photos list` for IDs."
    case .albumNotFound(let id):
      return "No album or folder has ID \(id). Run `photos albums list` for IDs."
    case .folderNotFound(let id):
      return "No folder has ID \(id). Run `photos albums list` for folder IDs."
    case .readOnlyAlbum(let id): return "Album \(id) cannot be changed."
    case .notEditable(let id): return "Photos does not allow changing \(id)."
    case .notAPhoto(let id): return "\(id) is not a photo. Only photos can be edited."
    case .unsupportedFile(let path): return "\(path) is not an image or video that Photos can use."
    case .imageUnavailable(let id): return "Photos could not provide an image for \(id)."
    case .encodingFailed: return "Could not encode the image."
    case .invalidChangeToken: return "--since must be a token from `photos changes`."
    case .expiredChangeToken:
      return
        "The token is older than Photos' change history. Run `photos changes` without --since for a new token, then list the library again."
    case .declined: return "The user did not allow the change."
    }
  }
}

/// PhotoKit access shared by the photos command and the View tool. Calls block, so make them off
/// the main thread, after Local Code allows Photos access.
public enum PhotoLibrary {
  /// The iOS / macOS 27 Photos APIs also require the SDK shipped with Swift 6.4.
  static var supportsExtendedMetadata: Bool {
    #if compiler(>=6.4)
      if #available(iOS 27, macOS 27, *) { return true }
    #endif
    return false
  }

  /// Every asset's local identifier ends with this; IDs leave it out to stay short.
  private static let assetSuffix = "/L0/001"
  private static let urlPrefix = "photos://"

  /// The asset ID in a photos://<id> path, as the View tool takes it.
  public static func assetID(inPath path: String) -> String? {
    guard path.lowercased().hasPrefix(urlPrefix) else { return nil }
    let id = path.dropFirst(urlPrefix.count).trimmingCharacters(in: .whitespaces)
    return id.isEmpty ? nil : id
  }

  /// The asset's current version as PNG, no larger than `maxPixelSize` on its longest side. PNG
  /// keeps screenshots and text sharp. A video gives its poster frame.
  public static func pngData(forAssetID id: String, maxPixelSize: Int) throws -> (
    data: Data, isVideo: Bool
  ) {
    let asset = try assets([id])[0]
    let image = try render(asset, maxPixelSize: maxPixelSize, isCancelled: { false })
    return (try imageData(image, type: .png), asset.mediaType == .video)
  }

  static func id(forLocalIdentifier localIdentifier: String) -> String {
    localIdentifier.hasSuffix(assetSuffix)
      ? String(localIdentifier.dropLast(assetSuffix.count)) : localIdentifier
  }

  /// Takes an ID, a photos://<id> path, or a full local identifier.
  static func localIdentifier(forAssetID id: String) -> String {
    let id = assetID(inPath: id) ?? id
    return id.contains("/") ? id : id + assetSuffix
  }

  /// The assets in the order of `ids`, including hidden ones.
  static func assets(_ ids: [String]) throws -> [PHAsset] {
    let localIdentifiers = ids.map(localIdentifier(forAssetID:))
    let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
    var assets = [String: PHAsset]()
    for index in 0..<result.count {
      let asset = result.object(at: index)
      assets[asset.localIdentifier] = asset
    }
    return try zip(ids, localIdentifiers).map { id, localIdentifier in
      guard let asset = assets[localIdentifier] else { throw PhotosError.assetNotFound(id) }
      return asset
    }
  }

  /// An album or smart album.
  static func album(_ id: String) throws -> PHAssetCollection {
    guard
      let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
        .firstObject
    else { throw PhotosError.albumNotFound(id) }
    return album
  }

  static func folder(_ id: String) throws -> PHCollectionList {
    guard
      let folder = PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [id], options: nil)
        .firstObject
    else { throw PhotosError.folderNotFound(id) }
    return folder
  }

  /// An album or a folder.
  static func collection(_ id: String) throws -> PHCollection {
    do {
      return try album(id)
    } catch PhotosError.albumNotFound {
      guard let folder = try? folder(id) else { throw PhotosError.albumNotFound(id) }
      return folder
    }
  }

  /// Applies `changes` and waits for them. Photos asks the user to confirm deletions.
  static func performChanges(_ changes: @escaping () -> Void) throws {
    do {
      try PHPhotoLibrary.shared().performChangesAndWait(changes)
    } catch let error as NSError where error.code == PHPhotosError.userCancelled.rawValue {
      throw PhotosError.declined
    }
  }

  /// The current version of an asset, fit within `maxPixelSize` when given. Photos may download
  /// it from iCloud; `isCancelled` stops that.
  static func render(_ asset: PHAsset, maxPixelSize: Int?, isCancelled: @escaping () -> Bool)
    throws -> CGImage
  {
    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true
    options.progressHandler = { _, _, stop, _ in
      if isCancelled() { stop.pointee = true }
    }
    var targetSize = PHImageManagerMaximumSize
    if let maxPixelSize {
      let longestSide = max(asset.pixelWidth, asset.pixelHeight)
      if longestSide == 0 {
        targetSize = CGSize(width: maxPixelSize, height: maxPixelSize)
      } else if longestSide > maxPixelSize {
        let scale = CGFloat(maxPixelSize) / CGFloat(longestSide)
        targetSize = CGSize(
          width: max(1, (CGFloat(asset.pixelWidth) * scale).rounded()),
          height: max(1, (CGFloat(asset.pixelHeight) * scale).rounded()))
      }
      options.resizeMode = .exact
    }
    var image: CGImage?
    var failure: Error?
    PHImageManager.default().requestImage(
      for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options
    ) { result, info in
      failure = info?[PHImageErrorKey] as? Error
      guard let result else { return }
      #if canImport(UIKit)
        // Photos can return pixels with an orientation to apply, which a CGImage drops.
        if result.imageOrientation == .up {
          image = result.cgImage
        } else {
          let format = UIGraphicsImageRendererFormat()
          format.scale = 1
          image =
            UIGraphicsImageRenderer(size: result.size, format: format).image { _ in
              result.draw(at: .zero)
            }.cgImage
        }
      #else
        image = result.cgImage(forProposedRect: nil, context: nil, hints: nil)
      #endif
    }
    if isCancelled() { throw AppleUtilityError.cancelled }
    guard let image else {
      throw failure ?? PhotosError.imageUnavailable(id(forLocalIdentifier: asset.localIdentifier))
    }
    return image
  }

  static func imageData(_ image: CGImage, type: UTType) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, type.identifier as CFString, 1, nil)
    else { throw PhotosError.encodingFailed }
    // PNG ignores the quality.
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PhotosError.encodingFailed }
    return data as Data
  }
}

// MARK: - Records

extension PhotoLibrary {
  struct Coordinate: Encodable, Equatable, ExpressibleByArgument {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
      self.latitude = latitude
      self.longitude = longitude
    }

    /// Parses "latitude,longitude", such as 37.33,-122.03.
    init?(argument: String) {
      let parts = argument.split(separator: ",").map {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
      guard parts.count == 2, let latitude = parts[0], let longitude = parts[1],
        (-90...90).contains(latitude), (-180...180).contains(longitude)
      else { return nil }
      self.init(latitude: latitude, longitude: longitude)
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
  }

  struct Resource: Encodable {
    var type: String
    var filename: String
    var uti: String
    var width: Int?
    var height: Int?
  }

  struct AlbumReference: Encodable {
    var id: String
    var title: String
  }

  /// `photos list` fills the summary; `photos show` adds the details.
  struct AssetRecord: Encodable {
    var id: String
    var type: String
    var subtypes: [String]?
    var created: Date?
    var width: Int
    var height: Int
    /// Seconds, for videos.
    var duration: Double?
    var favorite: Bool
    var hidden: Bool
    var location: Coordinate?
    var filename: String?
    var caption: String?

    var modified: Date?
    var added: Date?
    var keywords: [String]?
    var rating: Int?
    var source: String?
    var burstID: String?
    var edited: Bool?
    var editable: Bool?
    var albums: [AlbumReference]?
    var resources: [Resource]?

    /// `extendedMetadata` reads the filename and caption, which `photos list` prefetches.
    init(_ asset: PHAsset, extendedMetadata: Bool = false) {
      id = PhotoLibrary.id(forLocalIdentifier: asset.localIdentifier)
      type = PhotoLibrary.mediaTypeNames[asset.mediaType.rawValue] ?? "unknown"
      let subtypes = PhotoLibrary.subtypeNames.filter {
        asset.mediaSubtypes.rawValue & $0.mask != 0
      }.map(\.name)
      self.subtypes = subtypes.isEmpty ? nil : subtypes
      created = asset.creationDate
      width = asset.pixelWidth
      height = asset.pixelHeight
      if asset.mediaType == .video || asset.mediaType == .audio {
        duration = (asset.duration * 100).rounded() / 100
      }
      favorite = asset.isFavorite
      hidden = asset.isHidden
      location = asset.location.map {
        Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
      }
      #if compiler(>=6.4)
        if extendedMetadata, #available(iOS 27, macOS 27, *) {
          filename = asset.extendedMetadata.originalFilename
          caption = asset.extendedMetadata.caption.flatMap { $0.isEmpty ? nil : $0 }
        }
      #endif
    }

    mutating func addDetails(of asset: PHAsset) {
      modified = asset.modificationDate
      if #available(iOS 26, macOS 26, *) { added = asset.addedDate }
      #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
          let metadata = asset.extendedMetadata
          filename = metadata.originalFilename
          caption = metadata.caption.flatMap { $0.isEmpty ? nil : $0 }
          keywords = metadata.keywords.isEmpty ? nil : metadata.keywords
          rating = asset.rating == .unset ? nil : asset.rating.rawValue
        }
      #endif
      source = PhotoLibrary.sourceNames.first { asset.sourceType.rawValue & $0.mask != 0 }?.name
      burstID = asset.burstIdentifier
      edited = asset.hasAdjustments
      editable = asset.canPerform(.content)
      let albums = PHAssetCollection.fetchAssetCollectionsContaining(
        asset, with: .album, options: nil)
      self.albums = (0..<albums.count).map {
        let album = albums.object(at: $0)
        return AlbumReference(id: album.localIdentifier, title: album.localizedTitle ?? "")
      }
      resources = PHAssetResource.assetResources(for: asset).map {
        Resource(
          type: PhotoLibrary.resourceTypeNames[$0.type.rawValue] ?? "other",
          filename: $0.originalFilename, uti: $0.uniformTypeIdentifier,
          width: $0.pixelWidth > 0 ? $0.pixelWidth : nil,
          height: $0.pixelHeight > 0 ? $0.pixelHeight : nil)
      }
      if filename == nil {
        filename = resources?.first { ["photo", "video", "audio"].contains($0.type) }?.filename
      }
    }
  }

  struct AlbumRecord: Encodable {
    var id: String
    var title: String
    /// album, shared_album, smart_album, or folder.
    var kind: String
    /// For smart albums, a name that does not depend on the language, such as favorites.
    var subtype: String?
    /// Photos and videos, for albums.
    var count: Int?
    var folderID: String?

    init(_ collection: PHCollection, folderID: String?) {
      id = collection.localIdentifier
      title = collection.localizedTitle ?? ""
      self.folderID = folderID
      guard let album = collection as? PHAssetCollection else {
        kind = "folder"
        return
      }
      switch album.assetCollectionType {
      case .smartAlbum:
        kind = "smart_album"
        subtype = PhotoLibrary.smartAlbumNames[album.assetCollectionSubtype.rawValue]
      default:
        kind =
          [PHAssetCollectionSubtype.albumCloudShared, .albumMyPhotoStream].contains(
            album.assetCollectionSubtype) ? "shared_album" : "album"
      }
      count =
        album.estimatedAssetCount != NSNotFound
        ? album.estimatedAssetCount : PHAsset.fetchAssets(in: album, options: nil).count
    }
  }
}

// MARK: - Names

extension PhotoLibrary {
  /// Names by raw value, so that cases newer than the deployment target need no availability.
  static let mediaTypeNames = [1: "photo", 2: "video", 3: "audio"]

  static let subtypeNames: [(name: String, mask: UInt)] = [
    ("panorama", 1 << 0), ("hdr", 1 << 1), ("screenshot", 1 << 2), ("live", 1 << 3),
    ("portrait", 1 << 4), ("animated", 1 << 6), ("spatial", 1 << 10), ("streamed", 1 << 16),
    ("slow_motion", 1 << 17), ("timelapse", 1 << 18), ("screen_recording", 1 << 19),
    ("cinematic", 1 << 21),
  ]

  static let sourceNames: [(name: String, mask: UInt)] = [
    ("library", 1 << 0), ("shared_album", 1 << 1), ("synced", 1 << 2),
  ]

  static let resourceTypeNames = [
    1: "photo", 2: "video", 3: "audio", 4: "alternate_photo", 5: "full_size_photo",
    6: "full_size_video", 7: "adjustment_data", 8: "adjustment_base_photo", 9: "paired_video",
    10: "full_size_paired_video", 11: "adjustment_base_paired_video", 12: "adjustment_base_video",
    19: "photo_proxy",
  ]

  static let smartAlbumNames = [
    200: "generic", 201: "panoramas", 202: "videos", 203: "favorites", 204: "timelapses",
    205: "hidden", 206: "recently_added", 207: "bursts", 208: "slow_motion", 209: "library",
    210: "selfies", 211: "screenshots", 212: "portrait", 213: "live_photos", 214: "animated",
    215: "long_exposures", 216: "unable_to_upload", 217: "raw", 218: "cinematic", 219: "spatial",
    220: "screen_recordings",
  ]
}
