import Downloader
import Foundation
import ModelZoo
import SQLiteDflat

protocol LocalModelSizeLoaderDelegate: AnyObject {
  func localModelSizeLoaderDidLoadSize(_ loader: LocalModelSizeLoader)
}

/// Looks up the download size of local models' files. Sizes are remembered once the download
/// server has reported them, so each is only looked up once.
final class LocalModelSizeLoader {
  weak var delegate: LocalModelSizeLoaderDelegate?

  private let workspace: SQLiteWorkspace
  private var probes = [URLSessionDataTask]()
  // Files with a lookup in flight, so asking again before it finishes does not start another.
  private var pendingFiles = Set<String>()

  init(workspace: SQLiteWorkspace) {
    self.workspace = workspace
  }

  deinit {
    for probe in probes { probe.cancel() }
  }

  /// A model's total covers every file it downloads, including DeepSeek's separate engram and
  /// drafter, and is only known once the size of each is.
  static func downloadSize(
    of specification: LLMZoo.Specification, in workspace: SQLiteWorkspace
  ) -> String? {
    let files = specification.files
    let fileSizes = files.compactMap { workspace.dictionary["model_size_\($0)", Int.self] }
    guard fileSizes.count == files.count else { return nil }
    return ByteCountFormatter.string(
      fromByteCount: Int64(fileSizes.reduce(0, +)), countStyle: .file)
  }

  func load(_ specifications: [LLMZoo.Specification]) {
    for specification in specifications {
      let files = specification.files.filter {
        workspace.dictionary["model_size_\($0)", Int.self] == nil && !pendingFiles.contains($0)
      }
      for file in files {
        pendingFiles.insert(file)
        // Ask where the download would fetch the file: the Hugging Face mirror for a model
        // that has one, and the static server otherwise or when the mirror does not have it.
        guard let huggingFaceLink = specification.huggingFaceLink else {
          loadStaticSize(of: file)
          continue
        }
        let task = HuggingFaceXetMetadataResolver().resolve(
          officialRepository: huggingFaceLink, file: file
        ) { [weak self] result in
          guard let self else { return }
          guard case .success(let metadata) = result else {
            self.loadStaticSize(of: file)
            return
          }
          self.didLoad(size: Int(metadata.fileSize), of: file)
        }
        if let task { probes.append(task) }
      }
    }
  }

  private func loadStaticSize(of file: String) {
    for item in DownloadProgressAggregator.internalDownloadable(files: [file]) {
      probes.append(
        ResumableDownloader.probe(remoteUrl: item.remoteURL) { [weak self] result in
          DispatchQueue.main.async {
            guard let self else { return }
            guard case .success(let probe) = result else {
              self.pendingFiles.remove(file)
              return
            }
            self.didLoad(size: Int(probe.expectedLength), of: file)
          }
        })
    }
  }

  private func didLoad(size: Int, of file: String) {
    pendingFiles.remove(file)
    workspace.dictionary["model_size_\(file)", Int.self] = size
    delegate?.localModelSizeLoaderDidLoadSize(self)
  }
}
