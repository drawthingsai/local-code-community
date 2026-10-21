import Downloader
import Foundation
import ModelZoo

protocol ModelDownloader: AnyObject {
  typealias ProgressHandler = (
    _ totalBytesWritten: Int64, _ totalBytesTransferred: Int64,
    _ totalBytesExpectedToWrite: Int64, _ isComplete: Bool, _ error: Error?
  ) -> Void

  func resume(_ handler: @escaping ProgressHandler)
  func cancel()
}

extension ResumableDownloader: ModelDownloader {
  func resume(_ handler: @escaping ModelDownloader.ProgressHandler) {
    resume { totalBytesWritten, totalBytesExpectedToWrite, isComplete, error in
      handler(
        totalBytesWritten, totalBytesWritten, totalBytesExpectedToWrite, isComplete, error)
    }
  }
}

private func staticModelURL(for file: String) -> URL {
  let encodedFile = file.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? file
  return URL(string: "https://static.libnnc.org/\(encodedFile)")!
}

#if canImport(HFXet)
  import HFXet

  final class HFXetDownloader: ModelDownloader {
    private final class CallbackContext {
      weak var downloader: HFXetDownloader?
      let generation: UInt64
      let metadata: HuggingFaceXetMetadata
      let partialSize: Int64

      init(
        downloader: HFXetDownloader, generation: UInt64, metadata: HuggingFaceXetMetadata,
        partialSize: Int64
      ) {
        self.downloader = downloader
        self.generation = generation
        self.metadata = metadata
        self.partialSize = partialSize
      }
    }

    private let officialRepository: String
    private let file: String
    private let localURL: URL
    private let sha256: String?
    private let fallbackBackend: ResumableDownloader.Backend

    private var generation: UInt64 = 0
    private var metadataResolver: HuggingFaceXetMetadataResolver?
    private var fallbackDownloader: ResumableDownloader?
    private var progressHandler: ModelDownloader.ProgressHandler?
    private var nativeHandle: UnsafeMutableRawPointer?

    init(
      officialRepository: String, file: String, localURL: URL, sha256: String?,
      fallbackBackend: ResumableDownloader.Backend
    ) {
      self.officialRepository = officialRepository
      self.file = file
      self.localURL = localURL
      self.sha256 = sha256
      self.fallbackBackend = fallbackBackend
    }

    deinit {
      cancel()
    }

    func resume(_ handler: @escaping ModelDownloader.ProgressHandler) {
      cancel()
      generation += 1
      let generation = generation
      progressHandler = handler

      let resolver = HuggingFaceXetMetadataResolver()
      metadataResolver = resolver
      resolver.resolve(officialRepository: officialRepository, file: file) {
        [weak self] result in
        DispatchQueue.main.async {
          guard let self, self.generation == generation else { return }
          self.metadataResolver = nil
          switch result {
          case .success(let metadata):
            self.startXetDownload(metadata: metadata, generation: generation)
          case .failure:
            self.startFallback(generation: generation)
          }
        }
      }
    }

    func cancel() {
      generation += 1
      progressHandler = nil
      metadataResolver?.cancel()
      metadataResolver = nil
      fallbackDownloader?.cancel()
      fallbackDownloader = nil
      if let nativeHandle {
        hf_xet_download_cancel(nativeHandle)
      }
      nativeHandle = nil
    }

    // An interrupted Xet download leaves the start of the file here, and the next attempt
    // continues after it. The name carries the Xet hash so a newer revision of the file never
    // continues from an older revision's bytes.
    private func partialURL(for metadata: HuggingFaceXetMetadata) -> URL {
      localURL.appendingPathExtension("\(metadata.fileHash).xet-partial")
    }

    // Removes this file's partial Xet downloads, including older revisions' and the unhashed
    // name earlier versions used.
    private func removePartialDownloads(except keptURL: URL? = nil) {
      let directoryURL = localURL.deletingLastPathComponent()
      let prefix = localURL.lastPathComponent + "."
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
      else { return }
      for name in names
      where name.hasPrefix(prefix) && name.hasSuffix("xet-partial")
        && name != keptURL?.lastPathComponent
      {
        try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(name))
      }
    }

    private static func fileSize(at url: URL) -> Int64 {
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func startXetDownload(metadata: HuggingFaceXetMetadata, generation: UInt64) {
      let partialURL = self.partialURL(for: metadata)
      do {
        try FileManager.default.createDirectory(
          at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      } catch {
        startFallback(generation: generation)
        return
      }
      removePartialDownloads(except: partialURL)
      // The partial file can stay between launches, so create it here to exclude it from backup.
      if !FileManager.default.fileExists(atPath: partialURL.path) {
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
      }
      var excludedURL = partialURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? excludedURL.setResourceValues(values)
      let partialSize = Self.fileSize(at: partialURL)

      let context = Unmanaged.passRetained(
        CallbackContext(
          downloader: self, generation: generation, metadata: metadata, partialSize: partialSize))
      let handle = metadata.refreshURL.absoluteString.withCString { refreshURL in
        metadata.fileHash.withCString { fileHash in
          (sha256 ?? "").withCString { sha256 in
            partialURL.path.withCString { destinationPath in
              hf_xet_download_start(
                refreshURL, fileHash, metadata.fileSize, sha256, destinationPath,
                context.toOpaque(),
                { context, completedBytes, transferredBytes, totalBytes in
                  guard let context else { return }
                  let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context)
                    .takeUnretainedValue()
                  DispatchQueue.main.async {
                    guard let downloader = callbackContext.downloader,
                      downloader.generation == callbackContext.generation,
                      let progressHandler = downloader.progressHandler
                    else { return }
                    progressHandler(
                      Int64(clamping: completedBytes), Int64(clamping: transferredBytes),
                      Int64(clamping: totalBytes), false, nil)
                  }
                },
                { handle, context, status, errorMessage in
                  guard let context else {
                    if let handle { hf_xet_download_release(handle) }
                    return
                  }
                  let callbackContext = Unmanaged<CallbackContext>.fromOpaque(context)
                    .takeRetainedValue()
                  let error = errorMessage.map { String(cString: $0) }
                  DispatchQueue.main.async {
                    if let handle { hf_xet_download_release(handle) }
                    callbackContext.downloader?.xetDownloadCompleted(
                      handle: handle, status: status, errorMessage: error,
                      generation: callbackContext.generation, metadata: callbackContext.metadata,
                      partialSize: callbackContext.partialSize)
                  }
                })
            }
          }
        }
      }
      guard let handle else {
        context.release()
        startFallback(generation: generation)
        return
      }
      nativeHandle = handle
    }

    private func xetDownloadCompleted(
      handle: UnsafeMutableRawPointer?, status: Int32, errorMessage _: String?, generation: UInt64,
      metadata: HuggingFaceXetMetadata, partialSize: Int64
    ) {
      guard self.generation == generation else { return }
      if nativeHandle == handle {
        nativeHandle = nil
      }
      let partialURL = self.partialURL(for: metadata)
      guard status == Int32(HF_XET_DOWNLOAD_SUCCESS) else {
        // Partial files are kept so a later attempt can resume. A failure after more of the file
        // reached disk is likely transient, such as a dropped connection, so continue with Xet.
        // Only an attempt that made no progress falls back to the static server.
        if status != Int32(HF_XET_DOWNLOAD_CANCELLED) {
          if Self.fileSize(at: partialURL) > partialSize {
            startXetDownload(metadata: metadata, generation: generation)
          } else {
            startFallback(generation: generation)
          }
        }
        return
      }
      do {
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: partialURL, to: localURL)
        var installedURL = localURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? installedURL.setResourceValues(values)
        let attributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        progressHandler?(size, size, size, false, nil)
        progressHandler?(size, size, size, true, nil)
        progressHandler = nil
      } catch {
        startFallback(generation: generation)
      }
    }

    private func startFallback(generation: UInt64) {
      guard self.generation == generation, fallbackDownloader == nil else { return }
      let downloader = ResumableDownloader(
        remoteUrl: staticModelURL(for: file), localUrl: localURL, sha256: sha256,
        backend: fallbackBackend)
      fallbackDownloader = downloader
      // The static download writes its own copy, so once it has downloaded 1 MiB, drop the Xet
      // partial rather than holding both on disk. Until then the partial stays, so a fallback that
      // fails early, such as when offline, loses nothing a later Xet attempt could resume. Bytes
      // count from the first report, which includes any the static download resumed from disk.
      var initialBytesWritten: Int64?
      var didRemovePartialDownloads = false
      downloader.resume { [weak self] totalBytesWritten, totalBytesExpected, isComplete, error in
        guard let self, self.generation == generation else { return }
        let progressHandler = self.progressHandler
        if isComplete || error != nil {
          self.fallbackDownloader = nil
          self.progressHandler = nil
        }
        let startingBytesWritten = initialBytesWritten ?? totalBytesWritten
        initialBytesWritten = startingBytesWritten
        if !didRemovePartialDownloads
          && (totalBytesWritten - startingBytesWritten >= 1_048_576 || (isComplete && error == nil))
        {
          didRemovePartialDownloads = true
          // Xet attempts start on the main queue, so check there that none has started since.
          DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.removePartialDownloads()
          }
        }
        progressHandler?(
          totalBytesWritten, totalBytesWritten, totalBytesExpected, isComplete, error)
      }
    }
  }
#else
  typealias HFXetDownloader = ResumableDownloader

  extension ResumableDownloader {
    convenience init(
      officialRepository _: String, file: String, localURL: URL, sha256: String?,
      fallbackBackend: Backend
    ) {
      self.init(
        remoteUrl: staticModelURL(for: file), localUrl: localURL, sha256: sha256,
        backend: fallbackBackend)
    }
  }
#endif

extension ModelDownloader {
  static func `for`<Zoo: DownloadZoo>(
    _ model: EmbeddedDownloadController.DownloadItem, zoo: Zoo.Type,
    backend: ResumableDownloader.Backend
  ) -> any ModelDownloader {
    let localURL = URL(fileURLWithPath: zoo.filePathForModelDownloaded(model.file))
    let sha256 = model.sha256 ?? zoo.fileSHA256ForModelDownloaded(model.file)
    if let huggingFaceLink = model.huggingFaceLink {
      return HFXetDownloader(
        officialRepository: huggingFaceLink, file: model.file, localURL: localURL, sha256: sha256,
        fallbackBackend: backend)
    }
    return ResumableDownloader(
      remoteUrl: staticModelURL(for: model.file), localUrl: localURL, sha256: sha256,
      backend: backend)
  }
}
