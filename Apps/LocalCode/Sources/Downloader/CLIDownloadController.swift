import Components
import Foundation
import UIKit

/// Presents an existing CLI download; the command owns its transport and cancellation.
final class CLIDownloadController: EmbeddedDownloadControllerDelegate {
  let id: UUID
  let embeddedDownloadController: EmbeddedDownloadController
  let cancel: () -> Void
  private let progressAggregator = DownloadProgressAggregator()
  private var progress: (file: String, index: Int, written: Int64, expected: Int64)?

  init(id: UUID, name: String, subtitle: String, files: [String], cancel: @escaping () -> Void) {
    self.id = id
    self.cancel = cancel
    embeddedDownloadController = EmbeddedDownloadController(
      viewModel: DownloadItemController.ViewModel(
        image: #imageLiteral(resourceName: "keyboard-money"), title: name, subtitle: subtitle,
        file: files.first ?? "", index: 0, totalDownloads: files.count,
        downloadedBytes: 0, totalBytes: 0, mode: .download))
    embeddedDownloadController.delegate = self
    progressAggregator.onExpectedLengthsChanged = { [weak self] in self?.refreshProgress() }
    progressAggregator.items = DownloadProgressAggregator.internalDownloadable(files: files)
  }

  func update(file: String, index: Int, written: Int64, expected: Int64) {
    progress = (file, index, written, expected)
    refreshProgress()
  }

  private func refreshProgress() {
    guard let progress else { return }
    let aggregate = progressAggregator.aggregate(
      totalBytesWritten: progress.written, totalBytesTransferred: progress.written,
      totalBytesExpectedToWrite: progress.expected, index: progress.index,
      currentFile: progress.file)
    var viewModel = embeddedDownloadController.viewModel
    viewModel.file = progress.file
    viewModel.index = progress.index
    viewModel.downloadedBytes = aggregate.totalBytesWritten
    viewModel.transferredBytes = aggregate.totalBytesTransferred
    viewModel.totalBytes = aggregate.totalBytesExpectedToWrite
    embeddedDownloadController.viewModel = viewModel
  }

  func didTapCloseDownload() {
    cancel()
  }

  func didTapRetryDownload() {
    // CLI failures are returned to the command; this card never enters retry mode.
  }
}
