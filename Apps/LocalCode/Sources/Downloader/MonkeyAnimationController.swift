import Lottie
import Style
import UIKit

final class MonkeyAnimationController {
  var view: UIView { overlayView }
  var isRunning: Bool { motion != nil }
  private let overlayView: OverlayView
  private let animationView: LottieAnimationView
  private weak var downloadController: EmbeddedDownloadController?
  private let clips: [String: MonkeyAnimation.Clip]
  private var motion: MonkeyAnimation?
  private var displayedClip = ""
  private var displayedStyle: UIUserInterfaceStyle?
  private var displayLink: CADisplayLink?
  private var previousTimestamp: CFTimeInterval?
  private var hasAppeared = false
  private var isComplete = false
  private var completion: (() -> Void)?
  private lazy var responder = ObjCResponder(controller: self)
  // Xcode copies the animation folder; Bazel flattens its individual resources.
  #if LOCALCODE_CATALYST_ASAN
    private static let assetSubdirectory: String? = "Animations/Monkey"
  #else
    private static let assetSubdirectory: String? = nil
  #endif

  init?(downloadController: EmbeddedDownloadController) {
    guard
      let url = Bundle.main.url(
        forResource: "monkey-motion", withExtension: "json", subdirectory: Self.assetSubdirectory),
      let data = try? Data(contentsOf: url),
      let clips = try? JSONDecoder().decode([String: MonkeyAnimation.Clip].self, from: data),
      let peek = LottieAnimation.named("monkey-peek-hide", subdirectory: Self.assetSubdirectory)
    else { return nil }
    self.downloadController = downloadController
    self.clips = clips
    // These assets are verified with this renderer. MAC, rather than Lottie's
    // internal playback clock, selects every frame alongside the progress value.
    animationView = LottieAnimationView(
      animation: peek, configuration: LottieConfiguration(renderingEngine: .mainThread))
    overlayView = OverlayView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    view.accessibilityElementsHidden = true
    animationView.isHidden = true
    animationView.contentMode = .scaleAspectFit
    view.addSubview(animationView)
    overlayView.controller = self
  }

  deinit { displayLink?.invalidate() }

  func update() {
    guard let downloadController else { return }
    if motion == nil {
      if isComplete, downloadController.displayedProgress >= 1 - 0.000001 {
        let completion = completion
        self.completion = nil
        completion?()
        return
      }
      guard !hasAppeared,
        downloadController.viewModel.mode == .download,
        downloadController.displayedProgress >= 0.4,
        view.bounds.width > 0, view.window != nil
      else { return }
      hasAppeared = true
      downloadController.beginMonkeyAnimation()
      motion = MonkeyAnimation(
        progress: downloadController.displayedProgress,
        width: view.bounds.width, clips: clips)
      animationView.isHidden = false
      let displayLink = CADisplayLink(
        target: responder, selector: #selector(ObjCResponder.tick(_:)))
      displayLink.preferredFramesPerSecond = 60
      displayLink.add(to: .main, forMode: .common)
      self.displayLink = displayLink
      render()
    } else {
      displayLink?.isPaused = false
    }
  }

  /// Download readiness is already reported; only the banner's removal waits.
  func finish(completion: @escaping () -> Void) {
    isComplete = true
    self.completion = completion
    update()
  }

  func cancel() {
    hasAppeared = true
    completion = nil
    returnControl()
  }

  private func tick(_ link: CADisplayLink) {
    guard let downloadController, view.window != nil,
      UIApplication.shared.applicationState == .active
    else {
      previousTimestamp = nil
      return
    }
    let delta = min(1.0 / 15, max(0, link.timestamp - (previousTimestamp ?? link.timestamp)))
    previousTimestamp = link.timestamp
    guard var motion else { return }
    motion.advance(
      by: delta, realProgress: downloadController.realProgress,
      width: view.bounds.width,
      isError: downloadController.viewModel.mode == .error,
      isComplete: isComplete,
      chooseClimb: { Bool.random() })
    self.motion = motion
    downloadController.setDisplayedProgress(motion.progress)
    if motion.phase == .finished {
      returnControl()
    } else {
      render()
      if !isComplete
        && motion.isWaitingForProgress(
          realProgress: downloadController.realProgress,
          width: view.bounds.width)
        || motion.phase == .rest && downloadController.viewModel.mode == .error
      {
        link.isPaused = true
        previousTimestamp = nil
      }
    }
  }

  private func render() {
    guard let motion else { return }
    if displayedClip != motion.clip {
      guard
        let animation = LottieAnimation.named(
          "monkey-\(motion.clip)", subdirectory: Self.assetSubdirectory)
      else {
        returnControl()
        return
      }
      animationView.animation = animation
      displayedClip = motion.clip
      displayedStyle = nil
    }
    let style = view.traitCollection.userInterfaceStyle
    if displayedStyle != style {
      displayedStyle = style
      // Brown palette from the approved dark HTML. Preserve the existing light colors.
      for (name, lightColor, darkRGB) in [
        ("Ink", UIColor.primaryText, 0x9A7659),
        ("Shade", UIColor.secondaryText, 0x79583F),
        ("Face", UIColor.tertiaryBackground, 0xF3E5CF),
        ("Features", UIColor.primaryText, 0x30241F),
        ("Highlight", UIColor.tertiaryBackground, 0xFFFAF2),
        ("Blush", UIColor(red: 230 / 255, green: 162 / 255, blue: 152 / 255, alpha: 1), 0xD7A098),
      ] {
        let color =
          style == .dark
          ? UIColor(
            red: CGFloat((darkRGB >> 16) & 0xFF) / 255,
            green: CGFloat((darkRGB >> 8) & 0xFF) / 255,
            blue: CGFloat(darkRGB & 0xFF) / 255, alpha: 1)
          : lightColor.resolvedColor(with: view.traitCollection)
        animationView.setValueProvider(
          ColorValueProvider(color.lottieColorValue),
          keypath: AnimationKeypath(keypath: "**.\(name).Color"))
      }
    }
    let scale = MonkeyAnimation.scale
    animationView.frame = CGRect(
      x: motion.anchorX(width: view.bounds.width) - 120 * scale,
      y: -140 * scale, width: 240 * scale, height: 180 * scale)
    animationView.currentFrame = motion.frame
    animationView.forceDisplayUpdate()
  }

  private func returnControl() {
    displayLink?.invalidate()
    displayLink = nil
    previousTimestamp = nil
    motion = nil
    animationView.isHidden = true
    downloadController?.endMonkeyAnimation()
    update()
  }

  // The overlay shares the bar's constraints. UIKit lays it out in the normal
  // pass; no progress update forces layout or measures a partly updated fill.
  private final class OverlayView: UIView {
    weak var controller: MonkeyAnimationController?
    override func layoutSubviews() {
      super.layoutSubviews()
      controller?.update()
      controller?.render()
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      controller?.update()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      controller?.render()
    }
  }

  private final class ObjCResponder: NSObject {
    weak var controller: MonkeyAnimationController?
    init(controller: MonkeyAnimationController) { self.controller = controller }
    @objc func tick(_ displayLink: CADisplayLink) { controller?.tick(displayLink) }
  }
}
