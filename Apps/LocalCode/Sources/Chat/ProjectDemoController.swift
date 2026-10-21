import AVFoundation
import Localization
import Lottie
import SnapKit
import Style
import UIKit

protocol ProjectDemoControllerDelegate: AnyObject {
  func projectDemoController(
    _ controller: ProjectDemoController, didRequestFullScreenWith player: AVPlayer)
  func projectDemoControllerDidTapClose(_ controller: ProjectDemoController)
}

/// A classic all-in-one computer, badged with the LocalCode banner, that plays the demo video a
/// project's template ships as `.localc/project_demo.mp4` in place of the empty banner. It shows
/// the first frame until played inline from the screen or the play button; the other button
/// expands the video to full screen. The etched badge monkey cycles through its expressions until
/// the video plays, then looks up and holds there.
final class ProjectDemoController {
  weak var delegate: ProjectDemoControllerDelegate?
  var view: UIView { containerView }
  var videoURL: URL? {
    didSet {
      guard videoURL != oldValue else { return }
      player.pause()
      presentationSizeObservation = nil
      setScreenAspectRatio(CGSize(width: 4, height: 3))
      if let endObserver {
        NotificationCenter.default.removeObserver(endObserver)
        self.endObserver = nil
      }
      guard let videoURL else {
        player.replaceCurrentItem(with: nil)
        return
      }
      let item = AVPlayerItem(url: videoURL)
      player.replaceCurrentItem(with: item)
      // Shape the tube to the video once its size is known.
      presentationSizeObservation = item.observe(\.presentationSize) { [weak self] item, _ in
        let size = item.presentationSize
        DispatchQueue.main.async {
          self?.setScreenAspectRatio(size)
        }
      }
      // Rewind at the end so the set rests on the opening frame, ready to play again.
      endObserver = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
      ) { [weak self] _ in
        self?.player.pause()
        self?.player.seek(to: .zero)
      }
    }
  }
  // While the set switches between the demo and the banner, the transition owns both views.
  private(set) var isSwitching = false

  // Early-'80s platinum plastic, lit from above.
  private static let caseShadeColor = UIColor(red: 0.83, green: 0.80, blue: 0.70, alpha: 1)
  // The keys and the badge share one flat scheme: a light face, a border, and dark marks.
  private static let keyFaceColor = UIColor(red: 0.97, green: 0.96, blue: 0.90, alpha: 1)
  private static let keyBorderColor = UIColor(red: 0.74, green: 0.71, blue: 0.62, alpha: 1)
  private static let controlColor = UIColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1)
  // Shared by the tube face and the picture so bars around the video read as bezel.
  private static let tubeColor = UIColor(white: 0.03, alpha: 1)
  private static let caseFrontInset: CGFloat = 9

  // The banner the set switches to and from; it shares the set's superview.
  private let bannerController: EmptyBannerController
  private let player = AVPlayer()
  private var endObserver: NSObjectProtocol?
  private var timeControlStatusObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?
  private var screenAspectConstraint: Constraint?
  private var isVisible = false
  private var isMonkeyLookingUp = false
  private var isLoadingMonkey = false
  private var monkeyRequest = 0
  private var monkeyRestTimer: Timer?
  private var monkeyExpressions = [String]()
  private var lookUpAnimation: LottieAnimation?

  private lazy var containerView: ContainerView = {
    let view = ContainerView(frame: .zero)
    view.isHidden = true
    view.alpha = 0
    return view
  }()
  // The case in flat color: a body whose narrower top reads as the box seen from slightly above,
  // wrapping a front plate with tighter corners. Every corner and the sloped top sit within the
  // caps, so stretching only lengthens the straight edges.
  private lazy var caseView: UIImageView = {
    let view = UIImageView(
      image: UIImage(named: "project-demo-case")?.resizableImage(
        withCapInsets: UIEdgeInsets(top: 32, left: 32, bottom: 32, right: 32),
        resizingMode: .stretch))
    view.isUserInteractionEnabled = true
    return view
  }()
  // A flat, squarish frame around the tube.
  private lazy var screenFrameView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = UIColor(red: 0.80, green: 0.78, blue: 0.70, alpha: 1)
    view.layer.cornerRadius = 6
    view.layer.cornerCurve = .continuous
    return view
  }()
  // The rounded, gently bowed black face of the tube.
  private lazy var recessView = TubeView(frame: .zero)
  private lazy var screenView: PlayerView = {
    let view = PlayerView(frame: .zero)
    view.playerLayer.player = player
    // Show the whole picture; any space around it matches the bezel and disappears into it.
    view.playerLayer.videoGravity = .resizeAspect
    view.backgroundColor = Self.tubeColor
    return view
  }()
  private lazy var playGlyphView: UIImageView = {
    let view = UIImageView(
      image: UIImage(
        systemName: "play.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)))
    view.tintColor = UIColor.white.withAlphaComponent(0.9)
    return view
  }()
  // The bright beam the picture collapses into when the set switches off.
  private lazy var beamView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = .white
    view.alpha = 0
    view.isUserInteractionEnabled = false
    return view
  }()
  // Covers the screen, so tapping anywhere on it plays or pauses.
  private lazy var screenButton: UIButton = {
    let button = UIButton(type: .custom)
    button.accessibilityLabel = LocalizedString.forKey("preview")
    button.addAction(
      UIAction { [weak self] _ in
        self?.togglePlayback()
      }, for: .touchUpInside)
    return button
  }()
  // The LocalCode banner, monkey and wordmark, on a badge styled like the keys.
  private lazy var badgePlateView: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = Self.keyFaceColor
    view.layer.cornerRadius = 5
    view.layer.cornerCurve = .continuous
    view.layer.borderWidth = 1
    view.layer.borderColor = Self.keyBorderColor.cgColor
    return view
  }()
  private lazy var badgeMonkeyView: LottieAnimationView = {
    let view = LottieAnimationView(
      configuration: LottieConfiguration(renderingEngine: .automatic))
    view.contentMode = .scaleAspectFit
    view.backgroundBehavior = .pauseAndRestore
    view.respectAnimationFrameRate = true
    return view
  }()
  private lazy var badgeView: UIImageView = {
    let view = UIImageView(
      image: UIImage(named: "local-code-banner")?.withRenderingMode(.alwaysTemplate))
    view.tintColor = Self.controlColor
    view.contentMode = .scaleAspectFit
    return view
  }()
  private lazy var powerLightView: UIView = {
    let view = UIView(frame: .zero)
    view.layer.cornerRadius = 3
    return view
  }()
  // A key in flat color with a border; it darkens while pressed.
  private lazy var playPauseButton: UIButton = {
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = Self.keyFaceColor
    configuration.baseForegroundColor = Self.controlColor
    configuration.background.cornerRadius = 5
    configuration.background.strokeColor = Self.keyBorderColor
    configuration.background.strokeWidth = 1
    configuration.contentInsets = .zero
    let button = UIButton(configuration: configuration)
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.baseBackgroundColor =
        $0.isHighlighted ? Self.caseShadeColor : Self.keyFaceColor
      $0.configuration = configuration
    }
    button.addAction(
      UIAction { [weak self] _ in
        self?.togglePlayback()
      }, for: .touchUpInside)
    return button
  }()
  private lazy var expandButton: UIButton = {
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = Self.keyFaceColor
    configuration.baseForegroundColor = Self.controlColor
    configuration.background.cornerRadius = 5
    configuration.background.strokeColor = Self.keyBorderColor
    configuration.background.strokeWidth = 1
    configuration.contentInsets = .zero
    configuration.image = UIImage(
      systemName: "arrow.up.left.and.arrow.down.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
    let button = UIButton(configuration: configuration)
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.baseBackgroundColor =
        $0.isHighlighted ? Self.caseShadeColor : Self.keyFaceColor
      $0.configuration = configuration
    }
    button.accessibilityLabel = LocalizedString.forKey("full_screen")
    button.addAction(
      UIAction { [weak self] _ in
        guard let self, self.videoURL != nil else { return }
        self.delegate?.projectDemoController(self, didRequestFullScreenWith: self.player)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var closeButton: UIButton = {
    var configuration = UIButton.Configuration.filled()
    configuration.baseBackgroundColor = Self.keyFaceColor
    configuration.baseForegroundColor = Self.controlColor
    configuration.background.cornerRadius = 5
    configuration.background.strokeColor = Self.keyBorderColor
    configuration.background.strokeWidth = 1
    configuration.contentInsets = .zero
    configuration.image = UIImage(
      systemName: "xmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
    let button = UIButton(configuration: configuration)
    button.configurationUpdateHandler = {
      guard var configuration = $0.configuration else { return }
      configuration.baseBackgroundColor =
        $0.isHighlighted ? Self.caseShadeColor : Self.keyFaceColor
      $0.configuration = configuration
    }
    button.accessibilityLabel = LocalizedString.forKey("close")
    button.addAction(
      UIAction { [weak self] _ in
        guard let self else { return }
        self.delegate?.projectDemoControllerDidTapClose(self)
      }, for: .touchUpInside)
    return button
  }()
  private lazy var knobStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [playPauseButton, expandButton, closeButton])
    stackView.axis = .horizontal
    stackView.spacing = 8
    return stackView
  }()
  private lazy var baseView: UIView = {
    let view = UIView(frame: .zero)
    // The recessed foot.
    view.backgroundColor = UIColor(red: 0.62, green: 0.60, blue: 0.53, alpha: 1)
    view.layer.cornerRadius = 5
    view.layer.cornerCurve = .continuous
    return view
  }()

  init(bannerController: EmptyBannerController) {
    self.bannerController = bannerController
    containerView.controller = self
    view.addSubview(baseView)
    view.addSubview(caseView)
    caseView.addSubview(screenFrameView)
    screenFrameView.addSubview(recessView)
    recessView.addSubview(screenView)
    screenView.addSubview(playGlyphView)
    screenView.addSubview(beamView)
    recessView.addSubview(screenButton)
    caseView.addSubview(badgePlateView)
    badgePlateView.addSubview(badgeMonkeyView)
    badgePlateView.addSubview(badgeView)
    caseView.addSubview(knobStackView)
    caseView.addSubview(powerLightView)
    caseView.snp.makeConstraints { make in
      make.top.leading.trailing.equalToSuperview()
    }
    screenFrameView.snp.makeConstraints { make in
      make.top.equalToSuperview().inset(Self.caseFrontInset + 16)
      make.leading.trailing.equalToSuperview().inset(16)
    }
    recessView.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(6)
    }
    screenView.snp.makeConstraints { make in
      make.edges.equalToSuperview().inset(7)
      screenAspectConstraint =
        make.height.equalTo(screenView.snp.width).multipliedBy(3.0 / 4.0)
        .constraint
    }
    playGlyphView.snp.makeConstraints { make in
      make.center.equalToSuperview()
    }
    beamView.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    screenButton.snp.makeConstraints { make in
      make.edges.equalToSuperview()
    }
    // The tall chin of the classic case: badge at the lower left, controls at the lower right.
    badgePlateView.snp.makeConstraints { make in
      make.leading.equalTo(screenFrameView).offset(2)
      make.centerY.equalTo(knobStackView)
    }
    // Monkey and wordmark keep the banner's proportions: the monkey stands a little taller.
    badgeMonkeyView.snp.makeConstraints { make in
      make.top.bottom.equalToSuperview().inset(2)
      make.leading.equalToSuperview().inset(4)
      make.height.equalTo(badgeView).multipliedBy(193.289 / 149.860)
      make.width.equalTo(badgeMonkeyView.snp.height).multipliedBy(180.0 / 185.0)
    }
    badgeView.snp.makeConstraints { make in
      make.leading.equalTo(badgeMonkeyView.snp.trailing).offset(3)
      make.trailing.equalToSuperview().inset(4)
      make.centerY.equalTo(badgeMonkeyView)
      // The badge grows with the set, keeping its original 84 points on a 520-point set.
      make.width.equalTo(caseView).multipliedBy(84.0 / 520)
      make.height.equalTo(badgeView.snp.width).multipliedBy(149.860 / 892.022)
    }
    for button in [playPauseButton, expandButton, closeButton] {
      button.snp.makeConstraints { make in
        make.width.equalTo(30)
        make.height.equalTo(20)
      }
    }
    knobStackView.snp.makeConstraints { make in
      make.trailing.equalTo(screenFrameView).inset(2)
      make.top.equalTo(screenFrameView.snp.bottom).offset(16)
      make.bottom.equalToSuperview().inset(26)
    }
    powerLightView.snp.makeConstraints { make in
      make.width.height.equalTo(6)
      make.trailing.equalTo(knobStackView.snp.leading).offset(-12)
      make.centerY.equalTo(knobStackView)
    }
    baseView.snp.makeConstraints { make in
      make.top.equalTo(caseView.snp.bottom).offset(-4)
      make.centerX.equalTo(caseView)
      make.width.equalTo(caseView).multipliedBy(0.86)
      make.height.equalTo(10)
      make.bottom.equalToSuperview()
    }
    // Full-screen playback shares this player, so the set follows its state rather than taps.
    timeControlStatusObservation = player.observe(\.timeControlStatus, options: [.initial]) {
      [weak self] _, _ in
      DispatchQueue.main.async {
        self?.updatePlaybackState()
      }
    }
  }

  deinit {
    monkeyRestTimer?.invalidate()
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
  }

  func setVisible(_ visible: Bool, animated: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
    if visible {
      playNextMonkeyExpression()
    } else {
      player.pause()
      monkeyRestTimer?.invalidate()
      monkeyRestTimer = nil
      monkeyRequest += 1
      isLoadingMonkey = false
      isMonkeyLookingUp = false
      badgeMonkeyView.stop()
    }
    let closedTransform = CGAffineTransform(translationX: 0, y: -16).scaledBy(x: 0.97, y: 0.97)
    guard animated, view.window != nil else {
      view.isHidden = !visible
      view.alpha = visible ? 1 : 0
      view.transform = visible ? .identity : closedTransform
      return
    }
    if visible {
      view.isHidden = false
      view.transform = closedTransform
    }
    UIView.animate(
      withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      self.view.alpha = visible ? 1 : 0
      self.view.transform = visible ? .identity : closedTransform
    } completion: { _ in
      if !self.isVisible {
        self.view.isHidden = true
      }
    }
  }

  /// Switches the set off: the picture collapses into a line, the banner opens out of that line
  /// on the screen, then the set fades away and the banner settles into its usual place.
  func switchOff(completion: @escaping () -> Void) {
    guard !isSwitching else { return }
    isSwitching = true
    powerOff { [self] in
      let banner = bannerController.view
      banner.superview?.bringSubviewToFront(banner)
      bannerController.setVisible(true, animated: false)
      banner.transform = bannerTransformOnScreen
      banner.alpha = 0
      let uncover = UIView(
        frame: CGRect(x: 0, y: banner.bounds.midY, width: banner.bounds.width, height: 0))
      uncover.backgroundColor = .black
      banner.mask = uncover
      UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseOut) {
        uncover.frame = banner.bounds
        banner.alpha = 1
      } completion: { [self] _ in
        banner.mask = nil
        UIView.animate(withDuration: 0.5, delay: 0.2, options: .curveEaseInOut) {
          banner.transform = .identity
          self.view.alpha = 0
        } completion: { [self] _ in
          setVisible(false, animated: false)
          resetScreen()
          isSwitching = false
          completion()
        }
      }
    }
  }

  /// Switches the set back on, reversing `switchOff`.
  func switchOn(completion: @escaping () -> Void) {
    guard !isSwitching else { return }
    isSwitching = true
    let banner = bannerController.view
    banner.superview?.bringSubviewToFront(banner)
    setVisible(true, animated: false)
    prepareToPowerOn()
    view.alpha = 0
    banner.superview?.layoutIfNeeded()
    UIView.animate(withDuration: 0.5, delay: 0, options: .curveEaseInOut) { [self] in
      banner.transform = bannerTransformOnScreen
      view.alpha = 1
    } completion: { [self] _ in
      let cover = UIView(frame: banner.bounds)
      cover.backgroundColor = .black
      banner.mask = cover
      UIView.animate(withDuration: 0.3, delay: 0.1, options: .curveEaseIn) {
        cover.frame = CGRect(x: 0, y: banner.bounds.midY, width: banner.bounds.width, height: 0)
        banner.alpha = 0
      } completion: { [self] _ in
        banner.mask = nil
        bannerController.setVisible(false, animated: false)
        powerOn { [self] in
          isSwitching = false
          completion()
        }
      }
    }
  }

  /// Scales and moves the banner so it sits centered on the screen, with a margin inside the
  /// bezel.
  private var bannerTransformOnScreen: CGAffineTransform {
    let banner = bannerController.view
    let screen = recessView.convert(recessView.bounds, to: banner.superview)
    let rect = screen.insetBy(dx: screen.width * 0.1, dy: screen.height * 0.1)
    let scale = min(
      rect.width / max(banner.bounds.width, 1), rect.height / max(banner.bounds.height, 1))
    return CGAffineTransform(
      translationX: rect.midX - banner.center.x, y: rect.midY - banner.center.y
    ).scaledBy(x: scale, y: scale)
  }

  /// Shapes the tube toward the video while staying close to a classic CRT: widescreen video sits
  /// in a slightly taller tube, between 10:7 and square.
  private func setScreenAspectRatio(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let ratio = min(max(size.height / size.width, 0.7), 1)
    screenAspectConstraint?.deactivate()
    screenView.snp.makeConstraints { make in
      screenAspectConstraint =
        make.height.equalTo(screenView.snp.width).multipliedBy(ratio)
        .constraint
    }
  }

  private func togglePlayback() {
    guard videoURL != nil else { return }
    if player.timeControlStatus == .paused {
      player.play()
    } else {
      player.pause()
    }
  }

  /// Switches the picture off like an old CRT: it collapses into a bright line, the line shrinks
  /// to a dot, and the dot fades out.
  private func powerOff(completion: @escaping () -> Void) {
    player.pause()
    UIView.animateKeyframes(withDuration: 0.6, delay: 0, options: []) {
      UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) {
        self.screenView.transform = CGAffineTransform(scaleX: 1, y: 0.01)
        self.beamView.alpha = 1
      }
      UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.35) {
        self.screenView.transform = CGAffineTransform(scaleX: 0.02, y: 0.01)
      }
      UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
        self.screenView.alpha = 0
      }
    } completion: { _ in
      completion()
    }
  }

  /// Leaves the picture switched off, ready for `powerOn`.
  private func prepareToPowerOn() {
    screenView.transform = CGAffineTransform(scaleX: 0.02, y: 0.01)
    screenView.alpha = 0
    beamView.alpha = 1
  }

  /// Switches the picture back on: a dot of light stretches into a line, and the line opens into
  /// the picture.
  private func powerOn(completion: @escaping () -> Void) {
    UIView.animateKeyframes(withDuration: 0.6, delay: 0, options: []) {
      UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
        self.screenView.alpha = 1
      }
      UIView.addKeyframe(withRelativeStartTime: 0.2, relativeDuration: 0.35) {
        self.screenView.transform = CGAffineTransform(scaleX: 1, y: 0.01)
      }
      UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
        self.screenView.transform = .identity
        self.beamView.alpha = 0
      }
    } completion: { _ in
      completion()
    }
  }

  /// Restores the picture after it was switched off.
  private func resetScreen() {
    screenView.transform = .identity
    screenView.alpha = 1
    beamView.alpha = 0
  }

  private func updatePlaybackState() {
    let playing = player.timeControlStatus != .paused
    powerLightView.backgroundColor = playing ? UIColor.systemRed : UIColor.systemGreen
    playPauseButton.configuration?.image = UIImage(
      systemName: playing ? "pause.fill" : "play.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
    playPauseButton.accessibilityLabel = LocalizedString.forKey(playing ? "pause" : "play")
    UIView.animate(withDuration: 0.2) {
      self.playGlyphView.alpha = playing ? 0 : 1
    }
    setMonkeyLookingUp(playing)
  }

  /// Plays the look-up expression to its peak and holds it while the video plays, then finishes
  /// it and goes back to cycling expressions.
  private func setMonkeyLookingUp(_ lookingUp: Bool) {
    guard isVisible, lookingUp != isMonkeyLookingUp else { return }
    isMonkeyLookingUp = lookingUp
    monkeyRestTimer?.invalidate()
    monkeyRestTimer = nil
    monkeyRequest += 1
    isLoadingMonkey = false
    if lookingUp {
      loadMonkeyAnimation("look-up") { [weak self] animation in
        guard let self else { return }
        self.lookUpAnimation = animation
        self.showMonkeyAnimation(animation)
        self.badgeMonkeyView.play(
          fromFrame: animation.startFrame,
          toFrame: animation.frameTime(forMarker: "look-up") ?? animation.endFrame,
          loopMode: .playOnce)
      }
    } else if let animation = badgeMonkeyView.animation, animation === lookUpAnimation {
      badgeMonkeyView.play(
        fromFrame: badgeMonkeyView.currentFrame, toFrame: animation.endFrame, loopMode: .playOnce
      ) { [weak self] finished in
        guard finished else { return }
        self?.restMonkey()
      }
    } else {
      playNextMonkeyExpression()
    }
  }

  private func playNextMonkeyExpression() {
    guard isVisible, view.window != nil, !isMonkeyLookingUp, !isLoadingMonkey,
      monkeyRestTimer == nil, !badgeMonkeyView.isAnimationPlaying
    else { return }
    if monkeyExpressions.isEmpty {
      monkeyExpressions = ["smile", "happy", "look-down", "sleepy", "surprised"].shuffled()
    }
    loadMonkeyAnimation(monkeyExpressions.removeLast()) { [weak self] animation in
      guard let self else { return }
      self.showMonkeyAnimation(animation)
      self.badgeMonkeyView.play(
        fromFrame: animation.startFrame, toFrame: animation.endFrame, loopMode: .playOnce
      ) { [weak self] finished in
        guard finished else { return }
        self?.restMonkey()
      }
    }
  }

  /// Holds the shared neutral pose between expressions, like the empty banner.
  private func restMonkey() {
    guard isVisible, !isMonkeyLookingUp else { return }
    monkeyRestTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) {
      [weak self] _ in
      self?.monkeyRestTimer = nil
      self?.playNextMonkeyExpression()
    }
  }

  private func showMonkeyAnimation(_ animation: LottieAnimation) {
    if badgeMonkeyView.animation !== animation {
      badgeMonkeyView.animation = animation
    }
    badgeMonkeyView.currentFrame = animation.startFrame
    badgeMonkeyView.forceDisplayUpdate()
  }

  /// Decodes an astronaut expression off the main thread, recolored for the badge; requests
  /// superseded by a newer state change are dropped.
  private func loadMonkeyAnimation(
    _ expression: String, completion: @escaping (LottieAnimation) -> Void
  ) {
    if expression == "look-up", let lookUpAnimation {
      completion(lookUpAnimation)
      return
    }
    guard
      let url = Bundle.main.url(
        forResource: "monkey-\(expression)", withExtension: "json",
        subdirectory: EmptyBannerController.assetSubdirectory)
    else { return }
    let request = monkeyRequest
    isLoadingMonkey = true
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let animation = (try? Data(contentsOf: url)).map(Self.etched).flatMap {
        try? LottieAnimation.from(data: $0)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, request == self.monkeyRequest else { return }
        self.isLoadingMonkey = false
        if let animation {
          completion(animation)
        }
      }
    }
  }

  /// Recolors the two-tone astronaut artwork in the badge's scheme: its light fills take the
  /// badge's face color and its dark ink takes the color of the marks. The artwork is a large file
  /// with only a few static fill and stroke colors, each written as `"c":{"a":0,"k":[r,g,b]}`, so
  /// those spots are rewritten in place instead of decoding and re-encoding the whole file.
  private static func etched(_ data: Data) -> Data {
    let prefix = Data(#""c":{"a":0,"k":["#.utf8)
    let surface = keyFaceColor.rgbComponents
    let ink = controlColor.rgbComponents
    var result = Data()
    result.reserveCapacity(data.count)
    var index = data.startIndex
    while let match = data.range(of: prefix, in: index..<data.endIndex),
      let end = data[match.upperBound...].firstIndex(of: UInt8(ascii: "]"))
    {
      result.append(data[index..<match.upperBound])
      let rgba = String(decoding: data[match.upperBound..<end], as: UTF8.self)
        .split(separator: ",").compactMap { Double($0) }
      if rgba.count >= 3 {
        let luminance = 0.299 * rgba[0] + 0.587 * rgba[1] + 0.114 * rgba[2]
        let components = (luminance > 0.5 ? surface : ink) + rgba.dropFirst(3)
        result.append(contentsOf: components.map { String($0) }.joined(separator: ",").utf8)
      } else {
        result.append(data[match.upperBound..<end])
      }
      index = end
    }
    result.append(data[index...])
    return result
  }

  private final class ContainerView: UIView {
    weak var controller: ProjectDemoController?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      controller?.playNextMonkeyExpression()
    }
  }

  /// The black face of the tube: rounded corners and edges that bow gently outward. The bow
  /// follows the tube's size, so the mask is redrawn whenever it is laid out.
  private final class TubeView: UIView {
    private static let cornerRadius: CGFloat = 22
    private static let bow: CGFloat = 3

    /// Each edge is a curve whose midpoint reaches the bounds while its ends sit one bow inside.
    private static func path(in bounds: CGRect, cornerRadius radius: CGFloat) -> UIBezierPath {
      let rect = bounds.insetBy(dx: bow, dy: bow)
      let path = UIBezierPath()
      path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX - radius, y: rect.minY),
        controlPoint: CGPoint(x: rect.midX, y: rect.minY - bow * 2))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: rect.minY + radius),
        controlPoint: CGPoint(x: rect.maxX, y: rect.minY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
        controlPoint: CGPoint(x: rect.maxX + bow * 2, y: rect.midY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
        controlPoint: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX + radius, y: rect.maxY),
        controlPoint: CGPoint(x: rect.midX, y: rect.maxY + bow * 2))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX, y: rect.maxY - radius),
        controlPoint: CGPoint(x: rect.minX, y: rect.maxY))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX, y: rect.minY + radius),
        controlPoint: CGPoint(x: rect.minX - bow * 2, y: rect.midY))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX + radius, y: rect.minY),
        controlPoint: CGPoint(x: rect.minX, y: rect.minY))
      path.close()
      return path
    }
    private let shapeLayer = CAShapeLayer()

    override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = ProjectDemoController.tubeColor
      layer.mask = shapeLayer
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      shapeLayer.path = Self.path(in: bounds, cornerRadius: Self.cornerRadius).cgPath
      CATransaction.commit()
    }
  }

  private final class PlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  }
}

extension UIColor {
  fileprivate var rgbComponents: [Double] {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    getRed(&red, green: &green, blue: &blue, alpha: nil)
    return [red, green, blue].map(Double.init)
  }
}
