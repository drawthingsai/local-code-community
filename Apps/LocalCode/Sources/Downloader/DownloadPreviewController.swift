import Components
import UIKit

/// Temporary visual fixture. No downloader, file writes, or model-availability changes.
final class DownloadPreviewController: EmbeddedDownloadControllerDelegate {
  enum Scenario {
    case normal, error, fast
  }

  let embeddedDownloadController: EmbeddedDownloadController
  var didClose: (() -> Void)?
  private let scenario: Scenario
  private var timer: Timer?
  private var elapsed: TimeInterval = 0
  private var lastTick = CACurrentMediaTime()
  private var didFail = false
  private var didFinish = false
  private var isWaitingForRetry = false

  init(scenario: Scenario) {
    self.scenario = scenario
    embeddedDownloadController = EmbeddedDownloadController(
      viewModel: DownloadItemController.ViewModel(
        image: #imageLiteral(resourceName: "keyboard-money"), title: "Qwen 3.6B (2-bit)",
        subtitle: "Download animation preview", file: "Qwen_3.6B_q5p.ckpt",
        index: 0, totalDownloads: 3, downloadedBytes: 0,
        totalBytes: Int64(21_916.18 * 1024 * 1024), mode: .download))
    embeddedDownloadController.delegate = self
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.tick()
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }

  deinit { timer?.invalidate() }

  private func tick() {
    let now = CACurrentMediaTime()
    defer { lastTick = now }
    guard !isWaitingForRetry, !didFinish,
      UIApplication.shared.applicationState == .active
    else { return }
    elapsed += min(0.2, now - lastTick)
    let points: [(Double, Double)] =
      scenario == .fast
      ? [(0, 0), (1, 0.42), (2, 1)]
      : [
        (0, 0), (2, 0.2), (4, 0.42), (8, 0.5), (11, 0.6), (14, 0.68),
        (18, 0.68), (20, 0.85), (26, 0.94), (32, 1),
      ]
    var progress = 1.0
    for i in 1..<points.count where elapsed < points[i].0 {
      let start = points[i - 1]
      let end = points[i]
      progress = start.1 + (end.1 - start.1) * (elapsed - start.0) / (end.0 - start.0)
      break
    }
    var model = embeddedDownloadController.viewModel
    model.downloadedBytes = Int64(Double(model.totalBytes) * progress)
    if scenario == .error && !didFail && elapsed >= 15 {
      didFail = true
      isWaitingForRetry = true
      model.mode = .error
      model.file = "Preview paused — tap retry to continue"
    }
    embeddedDownloadController.viewModel = model
    if progress >= 1 {
      didFinish = true
      timer?.invalidate()
      timer = nil
      embeddedDownloadController.finish(success: true) { [weak self] in self?.didClose?() }
    }
  }

  func didTapCloseDownload() {
    timer?.invalidate()
    timer = nil
    embeddedDownloadController.finish(success: false) {}
    didClose?()
  }

  func didTapRetryDownload() {
    guard isWaitingForRetry else { return }
    var model = embeddedDownloadController.viewModel
    model.mode = .download
    model.file = "Qwen_3.6B_q5p.ckpt"
    embeddedDownloadController.viewModel = model
    isWaitingForRetry = false
    lastTick = CACurrentMediaTime()
  }
}
