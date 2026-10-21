import DataModels
import Diffusion
import ImageGenerator
import LocalImageGenerator
import Localization
import NNC
import UIKit

/// Presents CLI feedback using the same progress estimation as InGenerationController.
final class CLIMediaGenerationController {
  let id: UUID
  let imagePreviewController: ImagePreviewController
  private let cancelGeneration: () -> Void
  private let version: ModelVersion
  private static let previewQueue = DispatchQueue(
    label: "com.liuliu.local-code.preview", qos: .userInitiated)
  private var estimation = GenerationEstimation.default
  private var signposts: Set<ImageGeneratorSignpost>
  private var generationStart: CFTimeInterval = 0
  private var progressStart: CFTimeInterval = 0
  private var durationThisFar: TimeInterval = 0
  private var estimatedTotalDuration: TimeInterval = 0
  private var timerBlock: DispatchWorkItem?
  private var isStopped = false

  init(
    id: UUID, name: String, version: ModelVersion, prompt: String,
    signposts: Set<ImageGeneratorSignpost>,
    cancel: @escaping () -> Void
  ) {
    self.id = id
    self.version = version
    self.signposts = signposts
    cancelGeneration = cancel
    imagePreviewController = ImagePreviewController(
      viewModel: .init(
        title: name, prompt: prompt,
        progress: .init(
          leadingLabel: LocalizedString.forKey("starting_dot"), trailingLabel: "00:00 / ∞",
          progress: 0)))
    beginSegment()
  }

  deinit {
    timerBlock?.cancel()
  }

  func beginSegment() {
    guard !isStopped else { return }
    timerBlock?.cancel()
    estimation = .default
    generationStart = CACurrentMediaTime()
    progressStart = generationStart
    durationThisFar = 0
    estimatedTotalDuration = GenerationEstimator.estimateTotalDuration(
      estimation, signposts: signposts)
    imagePreviewController.viewModel.progress.leadingLabel = LocalizedString.forKey("starting_dot")
    updateProgress()
  }

  func update(
    signpost: ImageGeneratorSignpost, signposts: Set<ImageGeneratorSignpost>,
    preview: Tensor<FloatType>?
  ) {
    guard !isStopped else { return }
    self.signposts = signposts
    let now = CACurrentMediaTime()
    GenerationEstimator.correct(
      duration: now - generationStart, estimation: &estimation, signpost: signpost,
      signposts: signposts)
    let (updatedDuration, updatedTotal) = GenerationEstimator.estimateUpToDateDuration(
      from: estimation, signpost: signpost, signposts: signposts)
    // Match the app's smoothing and correction when an estimate changes substantially.
    let previousDuration =
      estimatedTotalDuration > 0
      ? (durationThisFar + now - progressStart) / estimatedTotalDuration * updatedTotal : 0
    durationThisFar = min(max(previousDuration, updatedDuration), updatedTotal)
    if updatedTotal > 0 {
      let reflectedProgress = durationThisFar / updatedTotal
      let realProgress = updatedDuration / updatedTotal
      if (reflectedProgress > 0.90 && reflectedProgress - realProgress > 0.1)
        || reflectedProgress - realProgress > 0.3333
      {
        durationThisFar = updatedDuration
      }
    }
    estimatedTotalDuration = updatedTotal
    progressStart = now
    var viewModel = imagePreviewController.viewModel
    viewModel.progress.leadingLabel = Self.labelForSignpost(signpost, signposts: signposts)
    imagePreviewController.viewModel = viewModel
    if let preview {
      // Keep conversion off the main thread; a shared serial queue preserves preview order.
      Self.previewQueue.async { [weak self, version] in
        guard self != nil else { return }
        let (images, _) = ImageConverter.images(
          fromLatent: preview, canUseTAESD: false, version: version)
        guard !images.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
          guard let self, !self.isStopped else { return }
          self.imagePreviewController.viewModel.images = images
        }
      }
    }
    timerBlock?.cancel()
    updateProgress()
  }

  func cancel() {
    guard !isStopped else { return }
    finish()
    var progress = imagePreviewController.viewModel.progress
    progress.leadingLabel = LocalizedString.forKey("stopping")
    progress.trailingLabel = ""
    imagePreviewController.viewModel.progress = progress
    cancelGeneration()
  }

  func finish() {
    isStopped = true
    imagePreviewController.didTapClose = nil
    imagePreviewController.stopAnimatingPreview()
    timerBlock?.cancel()
    timerBlock = nil
  }

  private func updateProgress() {
    guard !isStopped else { return }
    let now = CACurrentMediaTime()
    let elapsed = now - generationStart
    let total = max(estimatedTotalDuration, elapsed)
    var progress = imagePreviewController.viewModel.progress
    if total < 3600 {
      progress.trailingLabel = String(
        format: LocalizedString.forKey("duration_minutes_est"),
        Int(elapsed / 60), Int(elapsed) % 60, Int(total / 60), Int(total) % 60)
    } else {
      progress.trailingLabel = String(
        format: LocalizedString.forKey("duration_est"),
        Int(elapsed / 3600), Int(elapsed / 60) % 60, Int(elapsed) % 60,
        Int(total / 3600), Int(total / 60) % 60, Int(total) % 60)
    }
    progress.progress =
      estimatedTotalDuration > 0
      ? min(1, max(0, (durationThisFar + now - progressStart) / estimatedTotalDuration)) : 0
    imagePreviewController.viewModel.progress = progress
    let timerBlock = DispatchWorkItem { [weak self] in self?.updateProgress() }
    self.timerBlock = timerBlock
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: timerBlock)
  }

  private static func labelForSignpost(
    _ signpost: ImageGeneratorSignpost, signposts: Set<ImageGeneratorSignpost>
  ) -> String {
    switch signpost {
    case .faceRestored, .secondPassImageDecoded, .imageUpscaled:
      return LocalizedString.forKey("finishing_dot")
    case .imageEncoded, .secondPassImageEncoded, .textEncoded, .controlsGenerated:
      return LocalizedString.forKey("processing_dot")
    case .sampling(let step), .secondPassSampling(let step):
      let steps =
        signposts.compactMap { candidate -> Int? in
          switch (signpost, candidate) {
          case (.sampling, .sampling(let steps)),
            (.secondPassSampling, .secondPassSampling(let steps)):
            return steps
          default: return nil
          }
        }.first ?? 0
      if step == steps { return LocalizedString.forKey("finishing_dot") }
      return LocalizedString.forKey("sampling_dot") + " \(step + 1) / \(steps)"
    case .imageDecoded:
      if signposts.contains(.secondPassImageDecoded) {
        return LocalizedString.forKey("processing_dot")
      } else if signposts.contains(.imageUpscaled) {
        return LocalizedString.forKey("upscaling_dot")
      }
      return LocalizedString.forKey("finishing_dot")
    }
  }
}
