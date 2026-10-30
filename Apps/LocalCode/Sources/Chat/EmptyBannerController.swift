import CoreImage
import Lottie
import SnapKit
import Style
import UIKit

/// The animated astronaut composition shown while project history is empty.
final class EmptyBannerController {
  var view: UIView { containerView }
  private lazy var containerView: BannerView = {
    let view = BannerView(frame: .zero)
    view.isHidden = true
    view.alpha = 0
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    return view
  }()
  private lazy var bannerView: UIView = {
    let view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = true
    view.accessibilityTraits = .image
    return view
  }()
  private lazy var animationView: LottieAnimationView = {
    let view = LottieAnimationView(
      configuration: LottieConfiguration(renderingEngine: .automatic))
    view.contentMode = .scaleAspectFit
    view.backgroundBehavior = .pauseAndRestore
    view.loopMode = .playOnce
    view.respectAnimationFrameRate = true
    return view
  }()
  private lazy var neutralView: UIImageView = {
    let view = UIImageView(
      image: UIImage(named: "monkey-astronaut")?.withRenderingMode(.alwaysOriginal))
    view.contentMode = .scaleAspectFit
    return view
  }()
  private lazy var backgroundView: UIImageView = {
    // The vector rectangle scales its corners along with the composition.
    let view = UIImageView(
      image: UIImage(named: "local-code-banner-background")?.withRenderingMode(.alwaysTemplate))
    view.tintColor = .primaryColor
    view.contentMode = .scaleAspectFit
    return view
  }()
  private lazy var wordmarkView: UIImageView = {
    let view = UIImageView(
      image: UIImage(named: "local-code-banner")?.withRenderingMode(.alwaysOriginal))
    view.contentMode = .scaleAspectFit
    return view
  }()
  private lazy var sparklesView: UIImageView = {
    let view = UIImageView(
      image: UIImage(named: "monkey-astronaut-sparkles")?.withRenderingMode(.alwaysOriginal))
    view.contentMode = .scaleAspectFit
    return view
  }()
  private var expressions = [String]()
  private var lastExpression: String?
  private var pendingAnimation: LottieAnimation?
  private var isLoading = false
  private var isBetweenExpressions = true
  private var restTimer: Timer?
  private var segmentEnd: AnimationFrameTime = 0
  private var segmentCompletion: (() -> Void)?
  // After a stretch without user events the monkey dozes off with sleepy up to its
  // "sleepy" marker, chains breaths and butterflies, and wakes with the rest of sleepy.
  private enum Sleep {
    case awake, loading, dozing, sleeping, waking
  }
  private var sleep = Sleep.awake
  private var sleepAnimations:
    (
      sleepy: LottieAnimation, loop: LottieAnimation, butterflies: LottieAnimation,
      horse: LottieAnimation
    )?
  private var asleepSince: CFTimeInterval = 0
  // After a long sleep, the badge's rider occasionally rides once around the helmet.
  private static let horseRideDelay: TimeInterval = 30 * 60
  private static let horseRideChance = 0.01
  private var wantsToWake = false
  private var lastUserEvent = CACurrentMediaTime()
  private var idleTimer: Timer?
  private static let idleInterval: TimeInterval = 10
  private var observers = [NSObjectProtocol]()
  private var isVisible = false
  private let animatesBackground: Bool
  private var visibilityAnimator: UIViewPropertyAnimator?
  private var backgroundAnimator: UIViewPropertyAnimator?
  private var blurredSnapshotView: UIImageView?
  private static let imageContext = CIContext()
  // Xcode copies the animation folder; Bazel flattens its individual resources.
  #if LOCALCODE_CATALYST_ASAN
    static let assetSubdirectory: String? = "Animations/Astronaut"
  #else
    static let assetSubdirectory: String? = nil
  #endif

  init(animatesBackground: Bool = true) {
    self.animatesBackground = animatesBackground
    view.addSubview(bannerView)
    bannerView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    bannerView.addSubview(backgroundView)
    bannerView.addSubview(wordmarkView)
    bannerView.addSubview(sparklesView)
    bannerView.addSubview(neutralView)
    bannerView.addSubview(animationView)
    view.snp.makeConstraints { make in
      make.height.equalTo(view.snp.width).multipliedBy(206.0 / 1114)
    }
    backgroundView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    // Artwork coordinates recalculated for the full-width background,
    // vertically centered in the 1114 × 206 composition. The monkey's rounded
    // bottom-leading corner is concentric with the background's, and its
    // sparkles keep their place around it.
    for (subview, rect) in [
      (wordmarkView, CGRect(x: 200.397, y: 31.577, width: 892.022, height: 149.860)),
      (neutralView, Self.monkeyRect),
      (sparklesView, Self.sparklesRect),
    ] {
      // Locate centers so artwork can extend above or beside the background.
      let centerGuide = UILayoutGuide()
      bannerView.addLayoutGuide(centerGuide)
      centerGuide.snp.makeConstraints { make in
        make.top.leading.equalToSuperview()
        make.width.equalTo(bannerView.snp.width).multipliedBy(rect.midX / 1114)
        make.height.equalTo(bannerView.snp.height).multipliedBy(rect.midY / 206)
      }
      subview.snp.makeConstraints { make in
        make.centerX.equalTo(centerGuide.snp.trailing)
        make.centerY.equalTo(centerGuide.snp.bottom)
        make.width.equalTo(bannerView.snp.width).multipliedBy(rect.width / 1114)
        make.height.equalTo(subview.snp.width).multipliedBy(rect.height / rect.width)
      }
    }
    animationView.snp.makeConstraints { make in
      make.edges.equalTo(neutralView)
    }

    containerView.controller = self
    for name in [
      UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          self?.updatePlayback()
        })
    }
    // Typing on the software keyboard happens in its own window, so text changes count too.
    for name in [
      KeyboardShortcutWindow.didReceiveUserEventNotification,
      UITextView.textDidChangeNotification, UITextField.textDidChangeNotification,
      UIApplication.didBecomeActiveNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          self?.noteUserEvent()
        })
    }
  }

  deinit {
    restTimer?.invalidate()
    idleTimer?.invalidate()
    backgroundAnimator?.stopAnimation(true)
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func setVisible(_ visible: Bool, animated: Bool) {
    guard visible != isVisible else { return }
    if !visible {
      restTimer?.invalidate()
      restTimer = nil
      idleTimer?.invalidate()
      idleTimer = nil
      animationView.pause()
    }
    if let visibilityAnimator {
      visibilityAnimator.stopAnimation(false)
      visibilityAnimator.finishAnimation(at: .current)
      self.visibilityAnimator = nil
    }
    blurredSnapshotView?.removeFromSuperview()
    blurredSnapshotView = nil
    bannerView.alpha = 1
    let wasHidden = view.isHidden
    isVisible = visible
    if !visible {
      updateBackgroundAnimation()
    }
    view.accessibilityElementsHidden = !visible
    let closedTransform = CGAffineTransform(translationX: 0, y: -16).scaledBy(x: 0.97, y: 0.97)

    guard animated, view.window != nil else {
      view.isHidden = !visible
      view.alpha = visible ? 1 : 0
      view.transform = visible ? .identity : closedTransform
      if visible {
        updatePlayback()
      }
      return
    }

    view.isHidden = false
    if wasHidden || view.alpha == 0 {
      view.alpha = 0
      view.transform = closedTransform
    }
    bannerView.layoutIfNeeded()
    // Match the Download card's blur/fade while retaining the current monkey pose.
    if bannerView.bounds.width > 0, bannerView.bounds.height > 0 {
      let renderer = UIGraphicsImageRenderer(bounds: bannerView.bounds)
      let snapshot = renderer.image { context in
        (bannerView.layer.presentation() ?? bannerView.layer).render(in: context.cgContext)
      }
      if let input = CIImage(image: snapshot) {
        let blurred = input.clampedToExtent().applyingFilter(
          "CIGaussianBlur", parameters: [kCIInputRadiusKey: 2 * snapshot.scale])
        if let image = Self.imageContext.createCGImage(blurred, from: input.extent) {
          let snapshotView = UIImageView(
            image: UIImage(cgImage: image, scale: snapshot.scale, orientation: .up))
          snapshotView.isUserInteractionEnabled = false
          view.addSubview(snapshotView)
          snapshotView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
          }
          snapshotView.alpha = visible ? 1 : 0
          bannerView.alpha = visible ? 0 : 1
          blurredSnapshotView = snapshotView
        }
      }
    }

    let animator = UIViewPropertyAnimator(
      duration: visible ? 0.35 : 0.25,
      timingParameters: UICubicTimingParameters(
        controlPoint1: CGPoint(x: 0.22, y: 1), controlPoint2: CGPoint(x: 0.36, y: 1)))
    let snapshotView = blurredSnapshotView
    animator.addAnimations { [view, bannerView] in
      view.alpha = visible ? 1 : 0
      view.transform = visible ? .identity : closedTransform
      bannerView.alpha = visible ? 1 : (snapshotView == nil ? 1 : 0)
      snapshotView?.alpha = visible ? 0 : 1
    }
    animator.addCompletion { [weak self] position in
      guard let self, position == .end, self.isVisible == visible else { return }
      self.view.isHidden = !visible
      self.bannerView.alpha = 1
      self.blurredSnapshotView?.removeFromSuperview()
      self.blurredSnapshotView = nil
      self.visibilityAnimator = nil
    }
    visibilityAnimator = animator
    animator.startAnimation()
    if visible {
      updatePlayback()
    }
  }

  /// The monkey and its sparkles in the 1114 × 206 composition.
  static let monkeyRect = CGRect(x: 3.148, y: -4.461, width: 188.065, height: 193.289)
  static let sparklesRect = CGRect(x: -20.489, y: -4.461, width: 1144.830, height: 211.701)

  /// The banner background's color cycle, after its starting red.
  // Reviewed Lab palette, converted to sRGB for each appearance.
  // Follow neighboring hues to reduce RGB interpolation drift from Lab,
  // returning to adaptive Draw Things red after seven transitions.
  static let cycleColors: [UIColor] = [
    UIColor { traitCollection in  // Orange: #EC9711 / #E69105
      if traitCollection.userInterfaceStyle == .dark {
        return UIColor(red: 230.0 / 255, green: 145.0 / 255, blue: 5.0 / 255, alpha: 1)
      }
      return UIColor(red: 236.0 / 255, green: 151.0 / 255, blue: 17.0 / 255, alpha: 1)
    },
    UIColor { traitCollection in  // Lime: #80BC1B / #7BB612
      if traitCollection.userInterfaceStyle == .dark {
        return UIColor(red: 123.0 / 255, green: 182.0 / 255, blue: 18.0 / 255, alpha: 1)
      }
      return UIColor(red: 128.0 / 255, green: 188.0 / 255, blue: 27.0 / 255, alpha: 1)
    },
    UIColor { traitCollection in  // Mint: #00B782 / #009F71
      if traitCollection.userInterfaceStyle == .dark {
        return UIColor(red: 0, green: 159.0 / 255, blue: 113.0 / 255, alpha: 1)
      }
      return UIColor(red: 0, green: 183.0 / 255, blue: 130.0 / 255, alpha: 1)
    },
    UIColor { traitCollection in  // Cyan: #00B4B4 / #009C9D
      if traitCollection.userInterfaceStyle == .dark {
        return UIColor(red: 0, green: 156.0 / 255, blue: 157.0 / 255, alpha: 1)
      }
      return UIColor(red: 0, green: 180.0 / 255, blue: 180.0 / 255, alpha: 1)
    },
    UIColor(red: 143.0 / 255, green: 102.0 / 255, blue: 1, alpha: 1),
    UIColor { traitCollection in  // Pink: #F47DC1 / #EB74B8
      if traitCollection.userInterfaceStyle == .dark {
        return UIColor(red: 235.0 / 255, green: 116.0 / 255, blue: 184.0 / 255, alpha: 1)
      }
      return UIColor(red: 244.0 / 255, green: 125.0 / 255, blue: 193.0 / 255, alpha: 1)
    },
    .primaryColor,
  ]

  private func updateBackgroundAnimation(colorIndex: Int = 0) {
    guard animatesBackground else { return }
    guard isVisible, view.window != nil,
      UIApplication.shared.applicationState == .active
    else {
      backgroundAnimator?.stopAnimation(false)
      backgroundAnimator?.finishAnimation(at: .current)
      backgroundAnimator = nil
      return
    }
    guard backgroundAnimator == nil else { return }
    if colorIndex == 0 {
      backgroundView.tintColor = .primaryColor
    }
    let colors = Self.cycleColors
    // Ease each 3-second transition separately, with a 2-second hold on red:
    // 2 + 7 * 3 = 23 seconds per loop.
    let animator = UIViewPropertyAnimator(
      duration: 3,
      timingParameters: UICubicTimingParameters(
        controlPoint1: CGPoint(x: 0.33, y: 0), controlPoint2: CGPoint(x: 0.67, y: 1)))
    animator.addAnimations { [backgroundView] in
      backgroundView.tintColor = colors[colorIndex]
    }
    animator.addCompletion { [weak self] position in
      guard let self, position == .end else { return }
      self.backgroundAnimator = nil
      self.updateBackgroundAnimation(colorIndex: (colorIndex + 1) % colors.count)
    }
    backgroundAnimator = animator
    animator.startAnimation(afterDelay: colorIndex == 0 ? 2 : 0)
  }

  private func updatePlayback() {
    updateBackgroundAnimation()
    guard isVisible, view.window != nil,
      UIApplication.shared.applicationState == .active
    else {
      idleTimer?.invalidate()
      idleTimer = nil
      return
    }
    scheduleIdleTimer()
    if !isBetweenExpressions {
      if !animationView.isAnimationPlaying {
        playCurrentSegment()
      }
      return
    }
    guard restTimer == nil else { return }
    if sleep == .loading {
      // Every expression starts and ends on the neutral pose, as does sleepy.
      if let sleepy = sleepAnimations?.sleepy,
        let sleepFrame = sleepy.frameTime(forMarker: "sleepy")
      {
        sleep = .dozing
        isBetweenExpressions = false
        animationView.animation = sleepy
        animationView.currentFrame = sleepy.startFrame
        animationView.forceDisplayUpdate()
        neutralView.isHidden = true
        playSegment(to: sleepFrame) { [weak self] in
          self?.continueSleeping()
        }
      }
      return
    }
    guard !isLoading else { return }
    if let animation = pendingAnimation {
      pendingAnimation = nil
      isBetweenExpressions = false
      animationView.animation = animation
      animationView.currentFrame = animation.startFrame
      animationView.forceDisplayUpdate()
      neutralView.isHidden = true
      playSegment(to: animation.endFrame) { [weak self] in
        self?.finishExpression()
      }
      loadNextExpression()
      return
    }
    loadNextExpression()
  }

  private func playSegment(to end: AnimationFrameTime, then completion: @escaping () -> Void) {
    segmentEnd = end
    segmentCompletion = completion
    guard isVisible, view.window != nil, UIApplication.shared.applicationState == .active else {
      // updatePlayback resumes the segment once the banner is on screen again.
      animationView.pause()
      return
    }
    playCurrentSegment()
  }

  private func playCurrentSegment() {
    // Resume from the frame on screen; a dozing monkey can be woken mid-segment.
    animationView.play(
      fromFrame: animationView.realtimeAnimationFrame, toFrame: segmentEnd, loopMode: .playOnce
    ) { [weak self] finished in
      guard finished else { return }
      self?.segmentCompletion?()
    }
  }

  private func finishExpression() {
    isBetweenExpressions = true
    guard isVisible else { return }
    // Keep the shared neutral pose on screen between expressions.
    restTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) {
      [weak self] _ in
      self?.restTimer = nil
      self?.updatePlayback()
    }
  }

  private func noteUserEvent() {
    lastUserEvent = CACurrentMediaTime()
    switch sleep {
    case .loading:
      // Not asleep yet; drop the load and keep the expression rotation going.
      sleep = .awake
      sleepAnimations = nil
      // The rotation may have paused between expressions to wait for the load.
      updatePlayback()
    case .dozing, .sleeping:
      wake()
    case .awake, .waking:
      break
    }
    scheduleIdleTimer()
  }

  private func scheduleIdleTimer() {
    guard idleTimer == nil, sleep == .awake, isVisible, view.window != nil,
      UIApplication.shared.applicationState == .active
    else { return }
    // User events only record their time, so a burst of them never reschedules the timer.
    let remaining = Self.idleInterval - (CACurrentMediaTime() - lastUserEvent)
    idleTimer = Timer.scheduledTimer(withTimeInterval: max(0, remaining), repeats: false) {
      [weak self] _ in
      guard let self else { return }
      self.idleTimer = nil
      if CACurrentMediaTime() - self.lastUserEvent < Self.idleInterval {
        self.scheduleIdleTimer()
      } else {
        self.loadSleepAnimations()
      }
    }
  }

  private func loadSleepAnimations() {
    guard sleep == .awake, isVisible else { return }
    let urls = ["sleepy", "sleepy-loop", "sleepy-butterflies", "sleepy-horse"].compactMap {
      Bundle.main.url(
        forResource: "monkey-\($0)", withExtension: "json", subdirectory: Self.assetSubdirectory)
    }
    guard urls.count == 4 else { return }
    sleep = .loading
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let animations = urls.map { LottieAnimation.filepath($0.path, animationCache: nil) }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.sleep == .loading else { return }
        guard let sleepy = animations[0], let loop = animations[1], let butterflies = animations[2],
          let horse = animations[3]
        else {
          self.sleep = .awake
          self.scheduleIdleTimer()
          return
        }
        self.sleepAnimations = (sleepy, loop, butterflies, horse)
        // Doze off once the current expression and its rest are over.
        self.updatePlayback()
      }
    }
  }

  private func continueSleeping() {
    guard let sleepAnimations else { return }
    if wantsToWake, let sleepFrame = sleepAnimations.sleepy.frameTime(forMarker: "sleepy") {
      playWake(from: sleepFrame)
      return
    }
    if sleep != .sleeping {
      sleep = .sleeping
      asleepSince = CACurrentMediaTime()
    }
    // Every clip starts and ends on sleepy's "sleepy" frame, so they chain in any order.
    let clip: LottieAnimation
    if CACurrentMediaTime() - asleepSince >= Self.horseRideDelay,
      Double.random(in: 0..<1) < Self.horseRideChance
    {
      clip = sleepAnimations.horse
    } else {
      clip = Double.random(in: 0..<1) < 0.8 ? sleepAnimations.loop : sleepAnimations.butterflies
    }
    animationView.animation = clip
    animationView.currentFrame = clip.startFrame
    playSegment(to: clip.endFrame) { [weak self] in
      self?.continueSleeping()
    }
  }

  private func wake() {
    guard let sleepy = sleepAnimations?.sleepy,
      let sleepFrame = sleepy.frameTime(forMarker: "sleepy"),
      let butterfliesFrame = sleepy.frameTime(forMarker: "butterflies")
    else { return }
    switch sleep {
    case .dozing:
      // The doze is the start of sleepy itself; play straight on into the wake.
      sleep = .waking
      playSegment(to: sleepy.endFrame) { [weak self] in
        self?.finishWaking()
      }
    case .sleeping:
      // Breaths, butterflies, and the ride match sleepy frame for frame from its "sleepy"
      // marker until its butterflies appear. Inside that window, wake right away from the
      // matching frame; otherwise finish this breath first.
      let frame = animationView.realtimeAnimationFrame
      if frame <= butterfliesFrame - sleepFrame {
        playWake(from: sleepFrame + frame)
      } else {
        wantsToWake = true
      }
    case .awake, .loading, .waking:
      break
    }
  }

  private func playWake(from frame: AnimationFrameTime) {
    guard let sleepy = sleepAnimations?.sleepy else { return }
    sleep = .waking
    wantsToWake = false
    animationView.animation = sleepy
    animationView.currentFrame = frame
    playSegment(to: sleepy.endFrame) { [weak self] in
      self?.finishWaking()
    }
  }

  private func finishWaking() {
    sleep = .awake
    sleepAnimations = nil
    // Count the next stretch of inactivity from when he is awake again.
    lastUserEvent = CACurrentMediaTime()
    finishExpression()
  }

  private func loadNextExpression() {
    guard isVisible, !isLoading, pendingAnimation == nil else { return }
    if expressions.isEmpty {
      expressions = ["smile", "happy", "look-up", "look-down", "surprised"].shuffled()
      if expressions.last == lastExpression {
        expressions.swapAt(0, expressions.count - 1)
      }
    }
    let expression = expressions.removeLast()
    lastExpression = expression
    guard
      let url = Bundle.main.url(
        forResource: "monkey-\(expression)", withExtension: "json",
        subdirectory: Self.assetSubdirectory)
    else { return }
    isLoading = true
    // Decoding the detailed paths belongs off the UI thread. Do not retain
    // all these large models in Lottie's process-wide animation cache.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let animation = LottieAnimation.filepath(url.path, animationCache: nil)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.isLoading = false
        self.pendingAnimation = animation
        if animation != nil {
          self.updatePlayback()
        }
      }
    }
  }

  private final class BannerView: UIView {
    weak var controller: EmptyBannerController?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      controller?.updatePlayback()
    }
  }
}
