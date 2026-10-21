import Dflat
import Downloader
import ModelZoo
import UIKit

extension ResumableDownloader {
  static func backend(from workspace: Workspace) -> Backend {
    workspace.dictionary["use_system_downloader", Bool.self] == true ? .downloadTask : .automatic
  }
}

final class DownloadController<Zoo: DownloadZoo>: EmbeddedDownloadControllerDelegate {
  let models: [EmbeddedDownloadController.DownloadItem]
  let embeddedDownloadController: EmbeddedDownloadController
  private let backend: ResumableDownloader.Backend
  private let progressAggregator = DownloadProgressAggregator()
  private var downloader: (any ModelDownloader)?
  private var generation: UInt64 = 0
  private var isFinished = false
  private var previousIdleTimerDisabled: Bool?
  private var completionHandlers: [(Bool) -> Void]
  private var lastDownloadProgress:
    (written: Int64, transferred: Int64, expected: Int64, index: Int)?

  init(
    models: [EmbeddedDownloadController.DownloadItem],
    embeddedDownloadController: EmbeddedDownloadController,
    backend: ResumableDownloader.Backend,
    completionHandler: @escaping (Bool) -> Void
  ) {
    self.models = EmbeddedDownloadController.finalizeDownoladItems(list: models).filter {
      !Zoo.isModelDownloaded($0.file)
    }
    self.embeddedDownloadController = embeddedDownloadController
    self.backend = backend
    completionHandlers = [completionHandler]
    embeddedDownloadController.delegate = self
    progressAggregator.onExpectedLengthsChanged = { [weak self] in
      self?.refreshDownloadProgress()
    }
    progressAggregator.items = DownloadProgressAggregator.internalDownloadable(
      files: self.models.map { $0.file })
  }

  deinit {
    downloader?.cancel()
    if let previousIdleTimerDisabled {
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }
  }

  func addCompletionHandler(_ completionHandler: @escaping (Bool) -> Void) {
    guard !isFinished else { return }
    completionHandlers.append(completionHandler)
  }

  func start() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isFinished, downloader == nil else { return }
    guard let index = models.firstIndex(where: { !Zoo.isModelDownloaded($0.file) }) else {
      finish(success: true)
      return
    }
    if previousIdleTimerDisabled == nil {
      previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
    }
    UIApplication.shared.isIdleTimerDisabled = true
    let model = models[index]
    var viewModel = embeddedDownloadController.viewModel
    viewModel.title = model.name
    viewModel.subtitle = model.subtitle
    viewModel.file = model.file
    viewModel.mode = .download
    embeddedDownloadController.viewModel = viewModel
    lastDownloadProgress = (0, 0, 0, index)
    refreshDownloadProgress()

    let downloader: any ModelDownloader = HFXetDownloader.for(
      model, zoo: Zoo.self, backend: backend)
    self.downloader = downloader
    generation += 1
    let generation = generation
    downloader.resume { [weak self] written, transferred, expected, isComplete, error in
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.isFinished, self.generation == generation else { return }
        if let error {
          // Invalidate queued callbacks before cancelling or allowing a retry.
          self.generation += 1
          self.downloader?.cancel()
          self.downloader = nil
          if let previousIdleTimerDisabled = self.previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
          }
          var viewModel = self.embeddedDownloadController.viewModel
          viewModel.mode = .error
          viewModel.file = error.localizedDescription
          self.embeddedDownloadController.viewModel = viewModel
          return
        }
        self.lastDownloadProgress = (written, transferred, expected, index)
        self.refreshDownloadProgress()
        if isComplete {
          self.generation += 1
          self.downloader = nil
          self.start()
        }
      }
    }
  }

  func cancel() {
    finish(success: false)
  }

  func didTapCloseDownload() {
    cancel()
  }

  func didTapRetryDownload() {
    start()
  }

  private func refreshDownloadProgress() {
    guard let progress = lastDownloadProgress else { return }
    let aggregate = progressAggregator.aggregate(
      totalBytesWritten: progress.written, totalBytesTransferred: progress.transferred,
      totalBytesExpectedToWrite: progress.expected, index: progress.index,
      currentFile: models[progress.index].file)
    var viewModel = embeddedDownloadController.viewModel
    viewModel.downloadedBytes = aggregate.totalBytesWritten
    viewModel.transferredBytes = aggregate.totalBytesTransferred
    viewModel.totalBytes = aggregate.totalBytesExpectedToWrite
    viewModel.progress = nil
    viewModel.index = progress.index
    viewModel.totalDownloads = models.count
    embeddedDownloadController.viewModel = viewModel
  }

  private func finish(success: Bool) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !isFinished else { return }
    isFinished = true
    generation += 1
    downloader?.cancel()
    downloader = nil
    progressAggregator.cancel()
    lastDownloadProgress = nil
    if let previousIdleTimerDisabled {
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
      self.previousIdleTimerDisabled = nil
    }
    if embeddedDownloadController.delegate === self {
      embeddedDownloadController.delegate = nil
    }
    let completionHandlers = self.completionHandlers
    self.completionHandlers.removeAll()
    for completionHandler in completionHandlers {
      completionHandler(success)
    }
  }
}
