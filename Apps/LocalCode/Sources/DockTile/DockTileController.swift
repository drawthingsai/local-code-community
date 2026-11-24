import SQLiteDflat

#if targetEnvironment(macCatalyst)
  import Combine
  import Dflat
  import Lottie
  import UIKit

  /// Animates the app's Dock icon while agents work (`AgentActivity`): the astronaut reads while they
  /// take things in and thinks while they generate, and the icon comes back when they are done. The
  /// tile takes over from the icon with a short fade on the clip's still neutral pose, and hands the
  /// Dock back the same way. Not with "Reduce reasoning animation" or Reduce Motion, nor when the
  /// icon is drawn in another style than the default (the tile is made from the default one); in
  /// Low Power Mode the thought bubble holds still. Main queue only.
  final class DockTileController {
    /// A clip as the banner chains its pair: the intro plays to its marker, the loop (which starts
    /// and ends on the marker's pose) repeats, and the intro plays on from the marker back to
    /// neutral.
    private final class Clip {
      let activity: AgentActivity
      /// The first intro frame that changes anything in the tile; before it the clip holds neutral.
      let firstMove: AnimationFrameTime
      let marker: AnimationFrameTime
      let last: AnimationFrameTime
      let loopLength: AnimationFrameTime
      /// Let go once every frame of the clip is kept, and whenever the Dock goes back to the icon.
      var animations: (intro: LottieAnimation, loop: LottieAnimation)?
      var missingFrames = Set<FrameKey>()
      /// Whether the loop is one drawing throughout, once all of it is kept.
      var isLoopStill = false

      init(
        activity: AgentActivity, firstMove: AnimationFrameTime, intro: LottieAnimation,
        loop: LottieAnimation, marker: AnimationFrameTime
      ) {
        self.activity = activity
        self.firstMove = firstMove
        self.marker = marker
        last = intro.endFrame - 1
        loopLength = loop.endFrame - loop.startFrame
        animations = (intro, loop)
      }
    }

    private struct FrameKey: Hashable {
      let activity: AgentActivity
      let isLoop: Bool
      let frame: Int
    }

    private enum Phase {
      case idle
      /// Playing the intro from `from`; fading in from `fadeFrom` of the tile, if given.
      case intro(Clip, start: CFTimeInterval, from: AnimationFrameTime, fadeFrom: Double?)
      case loop(Clip, start: CFTimeInterval)
      case tail(Clip, start: CFTimeInterval)
      /// On the neutral pose, waiting for the next clip to load.
      case neutral(Clip)
      /// Fading from `from` of the tile back to the icon.
      case fadeOut(Clip, start: CFTimeInterval, from: Double)
    }

    private struct Step {
      let clip: Clip
      let isLoop: Bool
      let frame: AnimationFrameTime
      /// How much of the tile shows over the icon.
      let weight: Double
    }

    /// Tile updates a second; the clips run at 60 fps.
    private static let rate = 30.0
    private static let frameStep = 60 / rate
    /// The loops only move the thought bubble (1% of the tile). Each new image costs about 2.5 ms
    /// here and more in the Dock, which adds up over hours of thinking, so they update half as often.
    private static let loopRate = 15.0
    private static let loopFrameStep = 60 / loopRate
    private static let fade = 0.3
    /// How long a new activity has to last before the tile follows it (the agents switch between
    /// generating, tools and prefill every few seconds), how long idle has to last before the icon
    /// comes back (so back-to-back turns don't flicker), and how long a pose stays at least.
    private static let settle = 1.0
    private static let idleSettle = 3.0
    private static let minimumHold = 4.0
    /// Measured at tile size.
    private static let firstMoves: [AgentActivity: AnimationFrameTime] = [
      .thinking: 43, .reading: 63,
    ]
    // Xcode copies the animation folder; Bazel flattens its individual resources.
    #if LOCALCODE_CATALYST_ASAN
      private static let assetSubdirectory: String? = "Animations/Astronaut"
    #else
      private static let assetSubdirectory: String? = nil
    #endif

    private let dockTile: DockTile?
    private lazy var warp = DockTileWarp()
    private var renderer: DockTileRenderer?
    private var rendererIcon: Data?
    private var clips = [AgentActivity: Clip]()
    private var loadingClips = Set<AgentActivity>()
    // Every tile kept, LZFSE-compressed and shared by content: a frame's content hash, and the
    // tiles by hash.
    private var frameHashes = [FrameKey: Int]()
    private var tiles = [Int: Data]()
    private var decodedTile: (hash: Int, image: CGImage)?
    private var shown: (hash: Int, weight: Double)?

    private var agentActivity = AgentActivity.idle
    private var isReduceReasoningAnimationEnabled = false
    private var requested = AgentActivity.idle
    private var requestedAt = 0.0
    private var target = AgentActivity.idle
    private var targetAt = 0.0
    private var settleWork: DispatchWorkItem?
    private var phase = Phase.idle
    private var timer: Timer?
    private var processActivity: NSObjectProtocol?

    private var activitySubscription: AnyCancellable?
    private var reduceReasoningAnimationSubscription: Workspace.Subscription?
    private var systemObservers = [NSObjectProtocol]()

    init(workspace: SQLiteWorkspace) {
      dockTile = DockTile()
      guard dockTile != nil else { return }
      activitySubscription = AgentActivity.current.receive(on: DispatchQueue.main).sink {
        [weak self] activity in
        guard let self else { return }
        self.agentActivity = activity
        self.requestDidChange()
      }
      reduceReasoningAnimationSubscription = workspace.dictionary.subscribe(
        "reduce_reasoning_animation", of: Bool.self
      ) { [weak self] value in
        guard let self else { return }
        switch value {
        case .deleted:
          self.isReduceReasoningAnimationEnabled = false
        case .initial(let value):
          self.isReduceReasoningAnimationEnabled = value ?? false
        case .updated(let value):
          self.isReduceReasoningAnimationEnabled = value
        }
        self.requestDidChange()
      }
      systemObservers.append(
        NotificationCenter.default.addObserver(
          forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil,
          queue: .main
        ) { [weak self] _ in
          self?.requestDidChange()
        })
      systemObservers.append(
        NotificationCenter.default.addObserver(
          forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
          // The thought bubble starts or stops moving.
          guard let self, case .loop = self.phase else { return }
          self.startTimer()
        })
    }

    deinit {
      for observer in systemObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      settleWork?.cancel()
      stopTimer()
      switch phase {
      case .idle:
        break
      default:
        dockTile?.show(nil)
      }
    }

    // MARK: - What to show

    /// "Reduce reasoning animation" and Reduce Motion keep the system's icon.
    private var isAnimationOff: Bool {
      isReduceReasoningAnimationEnabled || UIAccessibility.isReduceMotionEnabled
    }

    private func requestDidChange() {
      let requested: AgentActivity = isAnimationOff ? .idle : agentActivity
      guard requested != self.requested else { return }
      self.requested = requested
      requestedAt = CACurrentMediaTime()
      // Decoding takes a few hundred milliseconds; the settle leaves time for it. Not when the icon
      // is in a style the tile can't be made for.
      if requested != .idle, readyClip(requested) == nil, renderer != nil || rendererIcon == nil {
        load(requested)
      }
      // A turn over within the settle: the tile never took over, but a clip may have been decoded.
      releaseDecodedClips()
      reconsider()
    }

    /// Lets go of decoded clips while the icon shows and nothing is about to play. A clip only
    /// completes once all its parts have played; the next request decodes again what is missing.
    private func releaseDecodedClips() {
      guard case .idle = phase, requested == .idle, target == .idle else { return }
      for clip in clips.values {
        guard let animations = clip.animations else { continue }
        renderer?.forget(animations.intro)
        renderer?.forget(animations.loop)
        clip.animations = nil
      }
    }

    private func reconsider() {
      settleWork?.cancel()
      settleWork = nil
      guard requested != target else { return }
      let now = CACurrentMediaTime()
      var ready: CFTimeInterval
      if isAnimationOff {
        ready = now
      } else {
        ready = requestedAt + (requested == .idle ? Self.idleSettle : Self.settle)
        if target != .idle {
          ready = max(ready, targetAt + Self.minimumHold)
        }
      }
      guard ready <= now else {
        let work = DispatchWorkItem { [weak self] in self?.reconsider() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (ready - now), execute: work)
        return
      }
      target = requested
      targetAt = now
      targetDidChange()
    }

    private func targetDidChange() {
      switch phase {
      case .idle:
        guard target != .idle else {
          // A takeover that never started (its clip still decoding, say) is off.
          releaseDecodedClips()
          return
        }
        takeOver()
      default:
        // The timeline follows the target from the next tick.
        startTimer()
      }
    }

    /// Starts the tile on `target`'s clip, from the app's icon as the system draws it now.
    private func takeOver() {
      guard let dockTile,
        let icon = dockTile.appIcon(
          scale: CGFloat(DockTileRenderer.pixels) / dockTile.size.width,
          colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
      else { return }
      let iconPixels = icon.dataProvider?.data as Data?
      if iconPixels != rendererIcon || renderer == nil {
        // A new appearance or icon style: everything kept was drawn on the old icon.
        rendererIcon = iconPixels
        renderer = DockTileRenderer(appIcon: icon, warp: warp)
        frameHashes.removeAll()
        tiles.removeAll()
        decodedTile = nil
        for clip in clips.values {
          clip.missingFrames = allFrames(clip)
          clip.isLoopStill = false
        }
      }
      guard renderer != nil else { return }
      guard let clip = readyClip(target) else {
        load(target)
        return
      }
      begin(clip, fadeFrom: 0, at: CACurrentMediaTime())
    }

    private func begin(_ clip: Clip, fadeFrom: Double?, at start: CFTimeInterval) {
      let lead = fadeFrom == nil ? 0 : Self.fade * 60
      phase = .intro(clip, start: start, from: clip.firstMove - lead, fadeFrom: fadeFrom)
      startTimer()
      tick()
    }

    /// The clip for `activity`, if it can play: loaded, or with all its frames kept.
    private func readyClip(_ activity: AgentActivity) -> Clip? {
      guard let clip = clips[activity], clip.animations != nil || clip.missingFrames.isEmpty else {
        return nil
      }
      return clip
    }

    private func load(_ activity: AgentActivity) {
      guard let firstMove = Self.firstMoves[activity], !loadingClips.contains(activity) else {
        return
      }
      loadingClips.insert(activity)
      let name = activity == .thinking ? "thinking" : "reading"
      let subdirectory = Self.assetSubdirectory
      DispatchQueue.global(qos: .utility).async { [weak self] in
        let animations = [name, name + "-loop"].map { clip in
          Bundle.main.path(forResource: "monkey-" + clip, ofType: "json", inDirectory: subdirectory)
            .flatMap { LottieAnimation.filepath($0, animationCache: nil) }
        }
        DispatchQueue.main.async {
          guard let self else { return }
          self.loadingClips.remove(activity)
          guard let intro = animations[0], let loop = animations[1],
            let marker = intro.frameTime(forMarker: name)
          else { return }
          let clip =
            self.clips[activity]
            ?? Clip(
              activity: activity, firstMove: firstMove, intro: intro, loop: loop, marker: marker)
          clip.animations = (intro, loop)
          clip.missingFrames = self.allFrames(clip).subtracting(self.frameHashes.keys)
          self.clips[activity] = clip
          // Not needed any more if the request it was for is over.
          self.releaseDecodedClips()
          self.targetDidChange()
        }
      }
    }

    /// Every frame a clip can show, on the tile's frame grid.
    /// The intro plays from its fade-in lead up to the marker; the tail, from the marker back to
    /// neutral, counts its frames from the marker.
    private func allFrames(_ clip: Clip) -> Set<FrameKey> {
      let activity = clip.activity
      let intro = stride(from: clip.firstMove - Self.fade * 60, to: clip.marker, by: Self.frameStep)
      let tail = stride(from: clip.marker, through: clip.last, by: Self.frameStep)
      let loop = stride(from: 0, to: clip.loopLength, by: Self.loopFrameStep)
      return Set(
        (Array(intro) + Array(tail)).map {
          FrameKey(activity: activity, isLoop: false, frame: Int($0.rounded()))
        } + loop.map { FrameKey(activity: activity, isLoop: true, frame: Int($0.rounded())) })
    }

    // MARK: - The timeline

    private var isBubbleStill: Bool {
      ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Frames since `start`, on the tile's frame grid.
    private func frames(since start: CFTimeInterval, now: CFTimeInterval) -> AnimationFrameTime {
      (max(0, now - start) * Self.rate).rounded(.down) * Self.frameStep
    }

    private func step(_ now: CFTimeInterval) -> Step? {
      while true {
        switch phase {
        case .idle:
          return nil
        case .intro(let clip, let start, let from, let fadeFrom):
          let frame = from + frames(since: start, now: now)
          if frame >= clip.marker {
            let reached = start + (clip.marker - from) / 60
            phase =
              target == clip.activity ? .loop(clip, start: reached) : .tail(clip, start: reached)
            continue
          }
          var weight = 1.0
          if let fadeFrom {
            weight = fadeFrom + (1 - fadeFrom) * min(max((frame - from) / (Self.fade * 60), 0), 1)
          }
          return Step(clip: clip, isLoop: false, frame: frame, weight: weight)
        case .loop(let clip, let start):
          if isBubbleStill || clip.isLoopStill {
            guard target == clip.activity else {
              phase = .tail(clip, start: now)
              continue
            }
            return Step(clip: clip, isLoop: true, frame: 0, weight: 1)
          }
          if (now - start) * 60 >= clip.loopLength {
            // The latest start of a pass (the timer may have paused for many while the bubble was
            // still).
            let passes = ((now - start) * 60 / clip.loopLength).rounded(.down)
            let wrapped = start + passes * clip.loopLength / 60
            phase =
              target == clip.activity ? .loop(clip, start: wrapped) : .tail(clip, start: wrapped)
            continue
          }
          let frame = (max(0, now - start) * Self.loopRate).rounded(.down) * Self.loopFrameStep
          // Leave early where the loop is back on the marker's drawing.
          if target != clip.activity, let hash = frameHash(clip, isLoop: true, frame: frame),
            hash == frameHash(clip, isLoop: true, frame: 0)
          {
            phase = .tail(clip, start: now)
            continue
          }
          return Step(clip: clip, isLoop: true, frame: frame, weight: 1)
        case .tail(let clip, let start):
          let frame = clip.marker + frames(since: start, now: now)
          if frame > clip.last {
            let reached = start + (clip.last - clip.marker + Self.frameStep) / 60
            if target == .idle {
              phase = .fadeOut(clip, start: reached, from: 1)
            } else if let next = readyClip(target) {
              // Every clip starts and ends on neutral: straight on into the next one's motion.
              phase = .intro(next, start: reached, from: next.firstMove, fadeFrom: nil)
            } else {
              phase = .neutral(clip)
              load(target)
            }
            continue
          }
          return Step(clip: clip, isLoop: false, frame: frame, weight: 1)
        case .neutral(let clip):
          if target == .idle {
            phase = .fadeOut(clip, start: now, from: 1)
            continue
          }
          if let next = readyClip(target) {
            phase = .intro(next, start: now, from: next.firstMove, fadeFrom: nil)
            continue
          }
          return Step(clip: clip, isLoop: false, frame: clip.last, weight: 1)
        case .fadeOut(let clip, let start, let from):
          let weight = from * (1 - min(frames(since: start, now: now) / 60 / Self.fade, 1))
          if target != .idle, let next = readyClip(target) {
            // Back onto the tile from wherever the fade is.
            phase = .intro(
              next, start: now, from: next.firstMove - Self.fade * 60, fadeFrom: weight)
            continue
          }
          if weight <= 0 {
            phase = .idle
            continue
          }
          return Step(clip: clip, isLoop: false, frame: clip.last, weight: weight)
        }
      }
    }

    private func tick() {
      guard let dockTile, let renderer else { return }
      guard let step = step(CACurrentMediaTime()),
        let hash = frameHash(step.clip, isLoop: step.isLoop, frame: step.frame)
      else {
        phase = .idle
        shown = nil
        dockTile.show(nil)
        stopTimer()
        releaseDecodedClips()
        if target != .idle {
          takeOver()
        }
        return
      }
      if shown?.hash != hash || shown?.weight != step.weight {
        let image: CGImage
        if step.weight <= 0 {
          image = renderer.appIcon
        } else if step.weight >= 1 {
          image = tileImage(hash, renderer: renderer)
        } else {
          image = renderer.crossFade(tileImage(hash, renderer: renderer), weight: step.weight)
        }
        dockTile.show(image)
        shown = (hash, step.weight)
      }
      // Nothing moves on a still loop, nor on neutral while the next clip loads.
      switch phase {
      case .loop(let clip, _) where target == clip.activity && (isBubbleStill || clip.isLoopStill):
        stopTimer()
      case .neutral:
        stopTimer()
      default:
        break
      }
    }

    /// The content hash of a clip's frame, rendering and keeping the tile the first time.
    private func frameHash(_ clip: Clip, isLoop: Bool, frame: AnimationFrameTime) -> Int? {
      let key = FrameKey(activity: clip.activity, isLoop: isLoop, frame: Int(frame.rounded()))
      if let hash = frameHashes[key] { return hash }
      guard let renderer, let animations = clip.animations else { return nil }
      let pixels = renderer.tile(isLoop ? animations.loop : animations.intro, frame: frame)
      // Every byte: `Data`'s own hash looks at the first 80 only.
      var hasher = Hasher()
      pixels.withUnsafeBytes { hasher.combine(bytes: $0) }
      let hash = hasher.finalize()
      if tiles[hash] == nil {
        tiles[hash] = (try? (pixels as NSData).compressed(using: .lzfse)) as Data?
      }
      decodedTile = (hash, renderer.image(pixels))
      frameHashes[key] = hash
      clip.missingFrames.remove(key)
      if isLoop, !clip.missingFrames.contains(where: \.isLoop) {
        let loopHashes = frameHashes.filter { $0.key.activity == clip.activity && $0.key.isLoop }
        clip.isLoopStill = Set(loopHashes.values).count == 1
      }
      if clip.missingFrames.isEmpty {
        // Every frame is kept: the animations (tens of megabytes decoded) can go.
        renderer.forget(animations.intro)
        renderer.forget(animations.loop)
        clip.animations = nil
      }
      return hash
    }

    private func tileImage(_ hash: Int, renderer: DockTileRenderer) -> CGImage {
      if let decodedTile, decodedTile.hash == hash { return decodedTile.image }
      guard let compressed = tiles[hash],
        let pixels = try? (compressed as NSData).decompressed(using: .lzfse) as Data
      else { return renderer.appIcon }
      let image = renderer.image(pixels)
      decodedTile = (hash, image)
      return image
    }

    private func startTimer() {
      guard timer == nil else { return }
      let timer = Timer(timeInterval: 1 / Self.rate, repeats: true) { [weak self] _ in
        self?.tick()
      }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
      if processActivity == nil {
        // Sleep prevention usually holds one while agents work, but not when it is turned off, and
        // without one App Nap slows the timer of a hidden app. This one leaves sleep alone.
        processActivity = ProcessInfo.processInfo.beginActivity(
          options: .userInitiatedAllowingIdleSystemSleep, reason: "Animating the Dock tile")
      }
    }

    private func stopTimer() {
      timer?.invalidate()
      timer = nil
      if let processActivity {
        ProcessInfo.processInfo.endActivity(processActivity)
        self.processActivity = nil
      }
    }
  }
#else
  /// The Dock is on the Mac only.
  final class DockTileController {
    init(workspace: SQLiteWorkspace) {}
  }
#endif
