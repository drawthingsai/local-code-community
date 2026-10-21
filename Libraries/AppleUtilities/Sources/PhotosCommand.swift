import ArgumentParser
import BashToolContext
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import ios_system

struct PhotosCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "photos",
    abstract: "Find, export, import, edit, and organize photos and videos in Photos.",
    discussion: """
      Results are JSON, with IDs local to this device. To look at a photo or video, use the \
      view tool with the path photos://<id>. Dates are ISO 8601, such as 2026-10-03 or \
      2026-10-03T19:00; dates without a time zone are local time. The first command asks for \
      Photos access, and Photos asks the user before anything is deleted.
      """,
    subcommands: [
      Status.self, Albums.self, List.self, Show.self, Export.self, Import.self, Update.self,
      Edit.self, Revert.self, Delete.self, Changes.self,
    ])

  /// Asks Local Code whether the photos command may run, which asks the user on first use when
  /// `prompt` is true.
  static func authorize(prompt: Bool = true) throws {
    guard let context = BashToolContext.current, let accessPhotos = context.accessPhotos else {
      throw AppleUtilityError.unavailable
    }
    // ios_system needs a synchronous exit status. The system prompt cannot be dismissed, so a
    // cancelled command still waits for the answer.
    let group = DispatchGroup()
    var result: Result<Void, Error> = .failure(AppleUtilityError.cancelled)
    group.enter()
    accessPhotos(prompt, context.bashUserInteraction) {
      result = $0
      group.leave()
    }
    group.wait()
    try result.get()
  }

  /// Photos and videos after a change, read again so that they show it.
  static func records(_ ids: [String]) throws -> [PhotoLibrary.AssetRecord] {
    try PhotoLibrary.assets(ids).map { PhotoLibrary.AssetRecord($0) }
  }

  struct Deleted: Encodable {
    var deleted: [String]
  }
}

extension PhotosCommand {
  struct Status: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Show Photos access without asking for it.")

    struct Access: Encodable {
      var authorized: Bool
      /// The user shares only the photos they selected.
      var limited: Bool?
      var reason: String?
    }

    func result() throws -> any Encodable {
      do {
        try PhotosCommand.authorize(prompt: false)
        return Access(
          authorized: true,
          limited: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited ? true : nil)
      } catch {
        return Access(authorized: false, reason: error.localizedDescription)
      }
    }
  }

  struct List: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List or search photos and videos, newest first.",
      discussion: """
        Hidden photos and videos are left out unless --hidden is given. Pass next_offset as \
        --offset, with the same filters, for the next page.
        """)

    enum MediaType: String, ExpressibleByArgument, CaseIterable {
      case photo, video, audio

      var mediaType: PHAssetMediaType {
        switch self {
        case .photo: return .image
        case .video: return .video
        case .audio: return .audio
        }
      }
    }

    @Option(
      help: ArgumentHelp(
        "Only this album or smart album ID from `photos albums list`.", valueName: "id")
    )
    var album: String?
    @Option(help: "Only photos, videos, or audio.") var type: MediaType?
    @Option(
      help: ArgumentHelp(
        "Only this kind, such as screenshot, live, portrait, panorama, slow_motion, or screen_recording. Repeat to match any of several.",
        valueName: "subtype"))
    var subtype: [String] = []
    @Flag(help: "Only favorites.") var favorite = false
    @Flag(help: "Only hidden photos and videos.") var hidden = false
    @Option(
      help: ArgumentHelp("Every photo in this burst ID from `photos show`.", valueName: "id"))
    var burst: String?
    @Option(
      help: ArgumentHelp("Only those taken at or after this date.", valueName: "date"),
      transform: parseDate)
    var from: Date?
    @Option(
      help: ArgumentHelp("Only those taken before this date.", valueName: "date"),
      transform: parseDate)
    var to: Date?
    @Option(
      parsing: .unconditional,
      help: ArgumentHelp("Only those taken near this place.", valueName: "latitude,longitude"))
    var near: PhotoLibrary.Coordinate?
    @Option(help: ArgumentHelp("With --near, the distance in kilometers. Defaults to 1."))
    var radius: Double?
    @Option(
      parsing: .unconditional,
      help:
        "Only those whose caption, keywords, or filename contain this text, ignoring case. Needs iOS 27 or macOS 27."
    )
    var query: String?
    @Flag(help: "Oldest first.") var oldestFirst = false
    @OptionGroup var pagination: Pagination

    func validate() throws {
      let names = PhotoLibrary.subtypeNames.map(\.name)
      for subtype in subtype where !names.contains(subtype) {
        throw ValidationError(
          "Unknown --subtype \(subtype). Use one of: \(names.joined(separator: ", ")).")
      }
      if album != nil, burst != nil {
        throw ValidationError("--album and --burst cannot be used together.")
      }
      if let from, let to, to <= from { throw ValidationError("--to must be after --from.") }
      if let radius {
        guard near != nil else { throw ValidationError("--radius needs --near.") }
        guard radius > 0 else { throw ValidationError("--radius must be positive.") }
      }
      if let query {
        guard !query.isEmpty else { throw ValidationError("--query must not be empty.") }
        guard PhotoLibrary.supportsExtendedMetadata else {
          throw ValidationError(
            "--query needs iOS 27 or macOS 27 and a build with the corresponding SDK.")
        }
      }
    }

    func result() throws -> any Encodable {
      struct Page: Encodable {
        var assets: [PhotoLibrary.AssetRecord]
        var nextOffset: Int?
      }
      try PhotosCommand.authorize()
      let options = PHFetchOptions()
      var predicates = [NSPredicate]()
      if let type {
        predicates.append(NSPredicate(format: "mediaType == %d", type.mediaType.rawValue))
      }
      let mask = PhotoLibrary.subtypeNames.filter { subtype.contains($0.name) }.reduce(0) {
        $0 | $1.mask
      }
      if mask != 0 {
        predicates.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", Int(mask)))
      }
      if favorite { predicates.append(NSPredicate(format: "favorite == YES")) }
      if hidden {
        options.includeHiddenAssets = true
        predicates.append(NSPredicate(format: "hidden == YES"))
      }
      if let from { predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate)) }
      if let to { predicates.append(NSPredicate(format: "creationDate < %@", to as NSDate)) }
      if !predicates.isEmpty {
        options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
      }
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: oldestFirst)]
      let extendedMetadata = PhotoLibrary.supportsExtendedMetadata
      #if compiler(>=6.4)
        if #available(iOS 27, macOS 27, *) {
          options.prefetchAssetExtendedMetadata = extendedMetadata
        }
      #endif
      let assets: PHFetchResult<PHAsset>
      if let album {
        assets = PHAsset.fetchAssets(in: try PhotoLibrary.album(album), options: options)
      } else if let burst {
        options.includeAllBurstAssets = true
        assets = PHAsset.fetchAssets(withBurstIdentifier: burst, options: options)
      } else {
        assets = PHAsset.fetchAssets(with: options)
      }

      let (offset, limit) = (pagination.offset, pagination.limit)
      // Photos cannot filter by place or text, so those filters scan; the others index directly.
      guard near != nil || query != nil else {
        let end = min(assets.count, offset + limit)
        return Page(
          assets: offset < end
            ? assets.objects(at: IndexSet(integersIn: offset..<end)).map {
              PhotoLibrary.AssetRecord($0, extendedMetadata: extendedMetadata)
            } : [],
          nextOffset: end < assets.count ? end : nil)
      }
      let center = near?.location
      let distance = (radius ?? 1) * 1_000
      var records = [PhotoLibrary.AssetRecord]()
      var skipped = 0
      var index = 0
      // Read one extra match to tell whether there is another page.
      while records.count <= limit, index < assets.count {
        try checkCancellation()
        let asset = assets.object(at: index)
        index += 1
        if let center {
          guard let location = asset.location, location.distance(from: center) <= distance else {
            continue
          }
        }
        #if compiler(>=6.4)
          if let query, #available(iOS 27, macOS 27, *) {
            let metadata = asset.extendedMetadata
            guard
              ([metadata.caption, metadata.originalFilename] + metadata.keywords).contains(where: {
                $0?.localizedCaseInsensitiveContains(query) == true
              })
            else { continue }
          }
        #endif
        guard skipped >= offset else {
          skipped += 1
          continue
        }
        records.append(PhotoLibrary.AssetRecord(asset, extendedMetadata: extendedMetadata))
      }
      let hasMore = records.count > limit
      if hasMore { records.removeLast() }
      return Page(assets: records, nextOffset: hasMore ? offset + limit : nil)
    }
  }

  struct Show: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Show photos or videos with their albums and files.",
      discussion: """
        edited is true when the photo has an edited version. Captions, keywords, and ratings \
        need iOS 27 or macOS 27.
        """)

    @Argument(help: ArgumentHelp("IDs from `photos list`.", valueName: "id")) var ids: [String]

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      return try PhotoLibrary.assets(ids).map { asset in
        var record = PhotoLibrary.AssetRecord(asset)
        record.addDetails(of: asset)
        return record
      }
    }
  }

  struct Export: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Write photos and videos to files.",
      discussion: """
        Writes the current version, with the video of a Live Photo, using the original file \
        names. Photos may download them from iCloud first.
        """)

    @Argument(help: ArgumentHelp("IDs from `photos list`.", valueName: "id")) var ids: [String]
    @Option(
      help: ArgumentHelp(
        "The folder to write to. Defaults to the current folder.", valueName: "dir")
    )
    var output = "."
    @Flag(help: "Write the originals, without edits, and the RAW file of a RAW+JPEG pair.")
    var original = false
    @Flag(
      help:
        "Write the current version as JPEG instead, for tools that cannot read HEIC. A video gives its poster frame."
    )
    var jpeg = false
    @Option(help: ArgumentHelp("With --jpeg, the longest side in pixels.", valueName: "pixels"))
    var maxSize: Int?

    struct Exported: Encodable {
      var id: String
      var files: [String]
    }

    func validate() throws {
      if original, jpeg { throw ValidationError("--original and --jpeg cannot be used together.") }
      if let maxSize {
        guard jpeg else { throw ValidationError("--max-size needs --jpeg.") }
        guard maxSize > 0 else { throw ValidationError("--max-size must be positive.") }
      }
    }

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let assets = try PhotoLibrary.assets(ids)
      let directory = fileURL(output, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let cancellation = ios_getCommandCancellationContext()
      let isCancelled = { ios_commandCancellationRequested(cancellation) != 0 }
      var exported = [Exported]()
      for (id, asset) in zip(ids, assets) {
        try checkCancellation()
        let resources = PHAssetResource.assetResources(for: asset)
        // Resources of edited photos have names such as FullSizeRender.heic.
        let name =
          resources.first { [.photo, .video, .audio].contains($0.type) }.map {
            ($0.originalFilename as NSString).deletingPathExtension
          }.flatMap { $0.isEmpty ? nil : $0 } ?? PhotoLibrary.id(forLocalIdentifier: id)
        if jpeg {
          let image = try PhotoLibrary.render(
            asset, maxPixelSize: maxSize, isCancelled: isCancelled)
          let url = availableURL(directory, name: name, extension: "jpg")
          try PhotoLibrary.imageData(image, type: .jpeg).write(to: url)
          exported.append(Exported(id: id, files: [url.path]))
          continue
        }
        var files = [String]()
        for resource in Self.resources(resources, original: original) {
          try checkCancellation()
          let url = availableURL(
            directory, name: name,
            extension: (resource.originalFilename as NSString).pathExtension)
          let options = PHAssetResourceRequestOptions()
          options.isNetworkAccessAllowed = true
          // ios_system needs a synchronous exit status.
          let group = DispatchGroup()
          var failure: Error?
          group.enter()
          PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) {
            failure = $0
            group.leave()
          }
          group.wait()
          if let failure { throw failure }
          files.append(url.path)
        }
        exported.append(Exported(id: id, files: files))
      }
      return exported
    }

    /// The files of the current version, which edits replace, or of the original.
    static func resources(_ resources: [PHAssetResource], original: Bool) -> [PHAssetResource] {
      let types = Set(resources.map(\.type))
      return resources.filter {
        switch $0.type {
        case .photo: return original || !types.contains(.fullSizePhoto)
        case .video: return original || !types.contains(.fullSizeVideo)
        case .pairedVideo: return original || !types.contains(.fullSizePairedVideo)
        case .audio: return true
        case .alternatePhoto: return original
        case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo: return !original
        default: return false
        }
      }
    }
  }

  struct Import: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Add image and video files to Photos.")

    @Argument(help: ArgumentHelp("Image or video files.", valueName: "file")) var files: [String]
    @Option(help: ArgumentHelp("Also add them to this album ID.", valueName: "id")) var album:
      String?

    struct Imported: Encodable {
      var file: String
      var id: String
    }

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let resources = try files.map { file -> (url: URL, type: PHAssetResourceType) in
        let url = fileURL(file)
        guard FileManager.default.fileExists(atPath: url.path),
          let type = UTType(filenameExtension: url.pathExtension)
        else { throw PhotosError.unsupportedFile(file) }
        if type.conforms(to: .image) { return (url, .photo) }
        if type.conforms(to: .audiovisualContent) { return (url, .video) }
        throw PhotosError.unsupportedFile(file)
      }
      let album = try album.map(PhotoLibrary.album)
      if let album, !album.canPerform(.addContent) {
        throw PhotosError.readOnlyAlbum(album.localIdentifier)
      }
      try checkCancellation()
      var placeholders = [PHObjectPlaceholder]()
      try PhotoLibrary.performChanges {
        for resource in resources {
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = resource.url.lastPathComponent
          request.addResource(with: resource.type, fileURL: resource.url, options: options)
          if let placeholder = request.placeholderForCreatedAsset {
            placeholders.append(placeholder)
          }
        }
        if let album {
          PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray)
        }
      }
      return zip(files, placeholders).map {
        Imported(file: $0, id: PhotoLibrary.id(forLocalIdentifier: $1.localIdentifier))
      }
    }
  }

  struct Update: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Change whether photos are favorites or hidden, and their date, place, or caption.",
      discussion: """
        Pass an empty --location or --caption to clear it. Captions, keywords, and ratings need \
        iOS 27 or macOS 27.
        """)

    @Argument(help: ArgumentHelp("IDs from `photos list`.", valueName: "id")) var ids: [String]
    @Flag(inversion: .prefixedNo, help: "Mark as a favorite, or not.") var favorite: Bool?
    @Flag(inversion: .prefixedNo, help: "Hide, or show again.") var hidden: Bool?
    @Option(help: ArgumentHelp("New date taken.", valueName: "date"), transform: parseDate)
    var date: Date?
    @Option(
      parsing: .unconditional,
      help: ArgumentHelp("New place taken.", valueName: "latitude,longitude"))
    var location: String?
    @Option(parsing: .unconditional, help: "New caption.") var caption: String?
    @Option(
      name: .customLong("add-keyword"), parsing: .unconditionalSingleValue,
      help: ArgumentHelp("Add a keyword. Repeat for several.", valueName: "keyword"))
    var addKeywords: [String] = []
    @Option(
      name: .customLong("remove-keyword"), parsing: .unconditionalSingleValue,
      help: ArgumentHelp("Remove a keyword. Repeat for several.", valueName: "keyword"))
    var removeKeywords: [String] = []
    @Option(help: "Star rating from 1 to 5, or 0 for none.") var rating: Int?

    func validate() throws {
      guard
        favorite != nil || hidden != nil || date != nil || location != nil || caption != nil
          || !addKeywords.isEmpty || !removeKeywords.isEmpty || rating != nil
      else { throw ValidationError("Pass at least one change.") }
      if let location, !location.isEmpty, PhotoLibrary.Coordinate(argument: location) == nil {
        throw ValidationError("--location must be latitude,longitude, such as 37.33,-122.03.")
      }
      if let rating, !(0...5).contains(rating) {
        throw ValidationError("--rating must be from 0 to 5.")
      }
      if caption != nil || !addKeywords.isEmpty || !removeKeywords.isEmpty || rating != nil {
        guard PhotoLibrary.supportsExtendedMetadata else {
          throw ValidationError(
            "Captions, keywords, and ratings need iOS 27 or macOS 27 and a build with the corresponding SDK."
          )
        }
      }
    }

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let assets = try PhotoLibrary.assets(ids)
      for (id, asset) in zip(ids, assets) where !asset.canPerform(.properties) {
        throw PhotosError.notEditable(id)
      }
      try checkCancellation()
      let location = location.map { PhotoLibrary.Coordinate(argument: $0)?.location }
      try PhotoLibrary.performChanges {
        for asset in assets {
          let request = PHAssetChangeRequest(for: asset)
          if let favorite { request.isFavorite = favorite }
          if let hidden { request.isHidden = hidden }
          if let date { request.creationDate = date }
          if let location { request.location = location }
          #if compiler(>=6.4)
            if #available(iOS 27, macOS 27, *) {
              if let caption { request.caption = caption.isEmpty ? nil : caption }
              addKeywords.forEach(request.addKeyword)
              removeKeywords.forEach(request.removeKeyword)
              if let rating { request.rating = PHAsset.Rating(rawValue: rating) ?? .unset }
            }
          #endif
        }
      }
      return try PhotosCommand.records(ids)
    }
  }

  struct Edit: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Save an image file as a photo's edited version.",
      discussion: """
        Photos keeps the original, and `photos revert` restores it. To edit a photo, export it, \
        change the file with any tool, and pass the result here.
        """)

    @Argument(help: ArgumentHelp("A photo ID from `photos list`.", valueName: "id")) var id: String
    @Argument(help: ArgumentHelp("The edited image.", valueName: "file")) var file: String

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let asset = try PhotoLibrary.assets([id])[0]
      guard asset.mediaType == .image else { throw PhotosError.notAPhoto(id) }
      guard asset.canPerform(.content) else { throw PhotosError.notEditable(id) }
      guard let source = CGImageSourceCreateWithURL(fileURL(file) as CFURL, nil),
        CGImageSourceGetCount(source) > 0
      else { throw PhotosError.unsupportedFile(file) }
      try checkCancellation()
      let options = PHContentEditingInputRequestOptions()
      options.isNetworkAccessAllowed = true
      // Photos calls back on the main thread, so this waits on the command thread.
      let group = DispatchGroup()
      var input: PHContentEditingInput?
      var info = [AnyHashable: Any]()
      group.enter()
      asset.requestContentEditingInput(with: options) {
        input = $0
        info = $1
        group.leave()
      }
      group.wait()
      guard let input else {
        throw info[PHContentEditingInputErrorKey] as? Error ?? PhotosError.notEditable(id)
      }
      let output = PHContentEditingOutput(contentEditingInput: input)
      output.adjustmentData = PHAdjustmentData(
        formatIdentifier: "com.liuliu.local-code.photos-edit", formatVersion: "1",
        data: Data((file as NSString).lastPathComponent.utf8))
      var type = UTType.jpeg
      var url = output.renderedContentURL
      if #available(iOS 17, macOS 14, *), let defaultType = output.defaultRenderedContentType {
        type = defaultType
        url = try output.renderedContentURL(for: defaultType)
      }
      guard
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL, type.identifier as CFString, 1, nil)
      else { throw PhotosError.encodingFailed }
      // Keeps the file's metadata, including its orientation.
      CGImageDestinationAddImageFromSource(
        destination, source, 0,
        [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw PhotosError.encodingFailed }
      try checkCancellation()
      try PhotoLibrary.performChanges {
        PHAssetChangeRequest(for: asset).contentEditingOutput = output
      }
      return try PhotosCommand.records([id])[0]
    }
  }

  struct Revert: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove the edits from photos or videos, restoring their originals.")

    @Argument(help: ArgumentHelp("IDs from `photos list`.", valueName: "id")) var ids: [String]

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let assets = try PhotoLibrary.assets(ids)
      for (id, asset) in zip(ids, assets) where !asset.canPerform(.content) {
        throw PhotosError.notEditable(id)
      }
      try checkCancellation()
      try PhotoLibrary.performChanges {
        for asset in assets { PHAssetChangeRequest(for: asset).revertAssetContentToOriginal() }
      }
      return try PhotosCommand.records(ids)
    }
  }

  struct Delete: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Delete photos or videos.",
      discussion: """
        Photos asks the user to confirm, then keeps them in Recently Deleted for 30 days.
        """)

    @Argument(help: ArgumentHelp("IDs from `photos list`.", valueName: "id")) var ids: [String]

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let assets = try PhotoLibrary.assets(ids)
      for (id, asset) in zip(ids, assets) where !asset.canPerform(.delete) {
        throw PhotosError.notEditable(id)
      }
      try checkCancellation()
      try PhotoLibrary.performChanges { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
      return PhotosCommand.Deleted(deleted: ids)
    }
  }

  struct Changes: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List what changed in Photos since a token.",
      discussion: """
        Without --since, this returns a token for now. Later, pass it as --since for the IDs of \
        photos, albums, and folders inserted, updated, or deleted since then, with a new token.
        """)

    @Option(help: ArgumentHelp("A token from an earlier `photos changes`.", valueName: "token"))
    var since: String?

    struct ObjectChanges: Encodable {
      var inserted = [String]()
      var updated = [String]()
      var deleted = [String]()
    }

    struct ChangeSet: Encodable {
      var token: String
      var assets: ObjectChanges?
      var albums: ObjectChanges?
      var folders: ObjectChanges?
    }

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let library = PHPhotoLibrary.shared()
      guard let since else { return ChangeSet(token: try Self.encode(library.currentChangeToken)) }
      guard let data = Data(base64Encoded: since),
        let start = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: PHPersistentChangeToken.self, from: data)
      else { throw PhotosError.invalidChangeToken }
      var token = start
      var assets = Self.NetChanges()
      var albums = Self.NetChanges()
      var folders = Self.NetChanges()
      do {
        for change in try library.fetchPersistentChanges(since: start) {
          try checkCancellation()
          assets.apply(try change.changeDetails(for: .asset))
          albums.apply(try change.changeDetails(for: .assetCollection))
          folders.apply(try change.changeDetails(for: .collectionList))
          token = change.changeToken
        }
      } catch let error as NSError
        where error.domain == PHPhotosErrorDomain
        && [
          PHPhotosError.persistentChangeTokenExpired.rawValue,
          PHPhotosError.persistentChangeDetailsUnavailable.rawValue,
        ].contains(error.code)
      {
        throw PhotosError.expiredChangeToken
      }
      return ChangeSet(
        token: try Self.encode(token),
        assets: assets.changes(id: PhotoLibrary.id(forLocalIdentifier:)),
        albums: albums.changes(id: { $0 }), folders: folders.changes(id: { $0 }))
    }

    static func encode(_ token: PHPersistentChangeToken) throws -> String {
      try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        .base64EncodedString()
    }

    /// Combines changes in order, so that an object inserted and then deleted is left out.
    struct NetChanges {
      var inserted = Set<String>()
      var updated = Set<String>()
      var deleted = Set<String>()

      mutating func apply(_ details: PHPersistentObjectChangeDetails) {
        apply(
          inserted: details.insertedLocalIdentifiers, updated: details.updatedLocalIdentifiers,
          deleted: details.deletedLocalIdentifiers)
      }

      mutating func apply(inserted: Set<String>, updated: Set<String>, deleted: Set<String>) {
        self.inserted.formUnion(inserted)
        self.updated.formUnion(updated.subtracting(self.inserted))
        for identifier in deleted {
          self.updated.remove(identifier)
          if self.inserted.remove(identifier) == nil { self.deleted.insert(identifier) }
        }
      }

      func changes(id: (String) -> String) -> ObjectChanges {
        ObjectChanges(
          inserted: inserted.map(id).sorted(), updated: updated.map(id).sorted(),
          deleted: deleted.map(id).sorted())
      }
    }
  }
}

extension PhotosCommand {
  struct Albums: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "List, create, rename, move, or delete albums and folders, or change their photos.",
      subcommands: [
        List.self, Create.self, Rename.self, Move.self, Delete.self, Add.self, Remove.self,
      ])

    /// The folder holding an album or folder; nil at the top level.
    static func parent(of collection: PHCollection) -> PHCollectionList? {
      // Newer systems return the root folder for the top level.
      PHCollectionList.fetchCollectionListsContaining(collection, options: nil).firstObject
        .flatMap { $0.collectionListSubtype.rawValue == 101 ? nil : $0 }
    }

    static func record(_ id: String) throws -> PhotoLibrary.AlbumRecord {
      let collection = try PhotoLibrary.collection(id)
      return PhotoLibrary.AlbumRecord(collection, folderID: parent(of: collection)?.localIdentifier)
    }
  }
}

extension PhotosCommand.Albums {
  struct List: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "List albums, folders, and smart albums.",
      discussion: """
        Albums and folders inside a folder have its folder_id. Smart albums, such as Favorites, \
        have a subtype that does not depend on the language.
        """)

    @Option(
      parsing: .unconditional, help: "Only those whose title contains this text, ignoring case.")
    var query: String?

    func validate() throws {
      guard query?.isEmpty != true else { throw ValidationError("--query must not be empty.") }
    }

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      var albums = [PhotoLibrary.AlbumRecord]()
      var seen = Set<String>()
      func add(_ collection: PHCollection, folderID: String?) {
        seen.insert(collection.localIdentifier)
        if let query, !(collection.localizedTitle ?? "").localizedCaseInsensitiveContains(query) {
          return
        }
        albums.append(PhotoLibrary.AlbumRecord(collection, folderID: folderID))
      }
      func visit(_ collections: PHFetchResult<PHCollection>, folderID: String?) throws {
        for index in 0..<collections.count {
          try checkCancellation()
          let collection = collections.object(at: index)
          add(collection, folderID: folderID)
          if let folder = collection as? PHCollectionList {
            try visit(
              PHCollection.fetchCollections(in: folder, options: nil),
              folderID: folder.localIdentifier)
          }
        }
      }
      try visit(PHCollection.fetchTopLevelUserCollections(with: nil), folderID: nil)
      // Shared, synced, and imported albums are not among the user's own albums.
      for type in [PHAssetCollectionType.album, .smartAlbum] {
        let collections = PHAssetCollection.fetchAssetCollections(
          with: type, subtype: .any, options: nil)
        for index in 0..<collections.count {
          try checkCancellation()
          let collection = collections.object(at: index)
          if !seen.contains(collection.localIdentifier) { add(collection, folderID: nil) }
        }
      }
      return albums
    }
  }

  struct Create: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Create an album, or a folder with --folder.")

    @Argument(help: "The title.") var title: String
    @Option(help: ArgumentHelp("Create it in this folder ID.", valueName: "id")) var parent: String?
    @Flag(help: "Create a folder, which holds albums and other folders.") var folder = false

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let parent = try parent.map(PhotoLibrary.folder)
      var created: PHObjectPlaceholder?
      try PhotoLibrary.performChanges {
        let placeholder =
          folder
          ? PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: title)
            .placeholderForCreatedCollectionList
          : PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            .placeholderForCreatedAssetCollection
        created = placeholder
        if let parent {
          PHCollectionListChangeRequest(for: parent)?.addChildCollections([placeholder] as NSArray)
        }
      }
      guard let id = created?.localIdentifier else { throw PhotosError.albumNotFound(title) }
      return try PhotosCommand.Albums.record(id)
    }
  }

  struct Rename: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(abstract: "Rename an album or folder.")

    @Argument(help: ArgumentHelp("An album or folder ID.", valueName: "id")) var id: String
    @Argument(help: "The new title.") var title: String

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let collection = try PhotoLibrary.collection(id)
      guard collection.canPerform(.rename) else { throw PhotosError.readOnlyAlbum(id) }
      try PhotoLibrary.performChanges {
        if let album = collection as? PHAssetCollection {
          PHAssetCollectionChangeRequest(for: album)?.title = title
        } else if let folder = collection as? PHCollectionList {
          PHCollectionListChangeRequest(for: folder)?.title = title
        }
      }
      return try PhotosCommand.Albums.record(id)
    }
  }

  struct Move: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Move an album or folder into a folder, or to the top level without --parent.")

    @Argument(help: ArgumentHelp("An album or folder ID.", valueName: "id")) var id: String
    @Option(help: ArgumentHelp("The folder ID to move it into.", valueName: "id")) var parent:
      String?

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let collection = try PhotoLibrary.collection(id)
      let oldParent = PhotosCommand.Albums.parent(of: collection)
      let newParent = try parent.map(PhotoLibrary.folder)
      guard oldParent?.localIdentifier != newParent?.localIdentifier else {
        return try PhotosCommand.Albums.record(id)
      }
      let topLevel = PHCollection.fetchTopLevelUserCollections(with: nil)
      try PhotoLibrary.performChanges {
        let item = [collection] as NSArray
        if let oldParent {
          PHCollectionListChangeRequest(for: oldParent)?.removeChildCollections(item)
        } else {
          PHCollectionListChangeRequest(forTopLevelCollectionListUserCollections: topLevel)?
            .removeChildCollections(item)
        }
        if let newParent {
          PHCollectionListChangeRequest(for: newParent)?.addChildCollections(item)
        } else {
          PHCollectionListChangeRequest(forTopLevelCollectionListUserCollections: topLevel)?
            .addChildCollections(item)
        }
      }
      return try PhotosCommand.Albums.record(id)
    }
  }

  struct Delete: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Delete albums or folders. Their photos stay in the library.",
      discussion: "Photos may ask the user to confirm.")

    @Argument(help: ArgumentHelp("Album or folder IDs.", valueName: "id")) var ids: [String]

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let collections = try ids.map(PhotoLibrary.collection)
      for (id, collection) in zip(ids, collections) where !collection.canPerform(.delete) {
        throw PhotosError.readOnlyAlbum(id)
      }
      try checkCancellation()
      let albums = collections.compactMap { $0 as? PHAssetCollection }
      let folders = collections.compactMap { $0 as? PHCollectionList }
      try PhotoLibrary.performChanges {
        if !albums.isEmpty {
          PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray)
        }
        if !folders.isEmpty {
          PHCollectionListChangeRequest.deleteCollectionLists(folders as NSArray)
        }
      }
      return PhotosCommand.Deleted(deleted: ids)
    }
  }

  struct Add: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(abstract: "Add photos or videos to an album.")

    @Argument(help: ArgumentHelp("An album ID.", valueName: "album-id")) var albumID: String
    @Argument(help: ArgumentHelp("IDs from `photos list`.", valueName: "id")) var ids: [String]

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let album = try PhotoLibrary.album(albumID)
      guard album.canPerform(.addContent) else { throw PhotosError.readOnlyAlbum(albumID) }
      let assets = try PhotoLibrary.assets(ids)
      try checkCancellation()
      try PhotoLibrary.performChanges {
        PHAssetCollectionChangeRequest(for: album)?.addAssets(assets as NSArray)
      }
      return try PhotosCommand.Albums.record(albumID)
    }
  }

  struct Remove: AppleUtilitySubcommand {
    static let configuration = CommandConfiguration(
      abstract: "Remove photos or videos from an album. They stay in the library.")

    @Argument(help: ArgumentHelp("An album ID.", valueName: "album-id")) var albumID: String
    @Argument(help: ArgumentHelp("IDs from `photos list`.", valueName: "id")) var ids: [String]

    func result() throws -> any Encodable {
      try PhotosCommand.authorize()
      let album = try PhotoLibrary.album(albumID)
      guard album.canPerform(.removeContent) else { throw PhotosError.readOnlyAlbum(albumID) }
      let assets = try PhotoLibrary.assets(ids)
      try checkCancellation()
      try PhotoLibrary.performChanges {
        PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
      }
      return try PhotosCommand.Albums.record(albumID)
    }
  }
}
