import Foundation

/// Presentation only. Transport counters remain in DownloadItemController.ViewModel.
struct MonkeyAnimation {
  struct Clip: Decodable {
    let frames: Int
    let travel: [Double]
    let distance: Double
  }

  enum Phase: String {
    case firstPeek, secondPeek, climb, perched, bounding, approach, contact, push, release,
      waitingToKick
    case kick, catchUp, settle, rest, retry, celebrate, finished
  }

  static let scale = 0.8
  private(set) var phase = Phase.firstPeek
  private(set) var progress: Double
  private(set) var elapsed: Double = 0
  private(set) var didKick = false
  private(set) var branchDecisionCount = 0
  private(set) var perch: Double
  private var pushStart: Double = 0
  private var approachProgress: Double?
  private var boundIndex = 0
  private var bounds = 0
  private var pushEnd: Double = 0
  private var kickStart: Double = 0
  private var kickEnd: Double = 0
  private var errorProgress: Double?
  private var restAtStanding = false
  private let clips: [String: Clip]

  init(progress: Double, width: Double, clips: [String: Clip]) {
    self.progress = progress
    self.clips = clips
    perch = max(30, progress * width - 49 * Self.scale) / max(1, width)
    // A resumed download can start beyond the checkpoint. Never move backwards.
    didKick = progress >= 0.7
  }

  var clip: String {
    switch phase {
    case .firstPeek, .secondPeek: return "peek-hide"
    case .climb: return "peek-out-still"
    case .perched: return "out-still"
    case .bounding: return "bound"
    case .approach: return "approach"
    case .contact: return "contact"
    case .push: return "push"
    case .release, .waitingToKick: return "release"
    case .kick: return "standing-kick"
    case .catchUp: return "catch"
    case .settle, .rest: return restAtStanding ? "standing-rest" : "settle"
    case .retry: return restAtStanding ? "standing-retry" : "retry"
    case .celebrate, .finished: return "celebrate"
    }
  }

  var frame: Double {
    let last = Double((clips[clip]?.frames ?? 1) - 1)
    if phase == .rest || phase == .waitingToKick { return last }
    return min(last, elapsed * 60)
  }

  func isWaitingForProgress(realProgress: Double, width: Double) -> Bool {
    if phase == .waitingToKick {
      return realProgress - progress < min(0.025, 69.44 * Self.scale / max(1, width))
    }
    return phase == .push && pushEnd <= pushStart && realProgress <= progress
  }

  private var duration: Double {
    let frames = clips[clip]?.frames ?? 1
    // Original excerpts have half-open ranges; new takes include their exit pose.
    let includesExit = !["peek-hide", "peek-out-still", "approach", "standing-kick"].contains(clip)
    return Double(frames - (includesExit ? 1 : 0)) / 60
  }

  private var travel: Double {
    let values = clips[clip]?.travel ?? []
    guard !values.isEmpty else { return 0 }
    // Match the asset's sampled hold keys, including when the screen runs at 120 Hz.
    return values[min(values.count - 1, Int(frame))]
  }

  func anchorX(width: Double) -> Double {
    let scale = Self.scale
    switch phase {
    case .firstPeek, .secondPeek, .climb, .perched:
      return perch * width
    case .bounding:
      return perch * width + (Double(boundIndex) + travel) * (clips["bound"]?.distance ?? 0) * scale
    case .approach:
      return perch * width + Double(bounds) * (clips["bound"]?.distance ?? 0) * scale
    case .kick, .catchUp:
      let correction =
        phase == .catchUp
        ? ((kickEnd - kickStart) * width - 69.44 * scale) * travel : 0
      return kickStart * width + correction
    default:
      return progress * width
    }
  }

  mutating func advance(
    by delta: Double, realProgress: Double, width: Double, isError: Bool,
    isComplete: Bool, chooseClimb: () -> Bool
  ) {
    guard phase != .finished else { return }
    let width = max(1, width)
    let real = min(1, max(0, realProgress))
    if isError {
      if errorProgress == nil { errorProgress = progress }
    } else {
      errorProgress = nil
    }
    let ceiling = min(real, errorProgress ?? 1)
    progress = min(progress, ceiling)
    elapsed += max(0, delta)

    switch phase {
    case .firstPeek, .secondPeek, .climb:
      // Leave room for an exact landing even if transport finishes during a peek.
      // Both peeks and the climb stay at the same perch.
      let stride = (clips["bound"]?.distance ?? 25.86) * Self.scale / width
      let firstLanding = perch + 49 * Self.scale / width
      let lastLanding = firstLanding + floor(max(0, 1 - firstLanding) / stride) * stride
      let target = phase == .secondPeek ? ceiling : min(ceiling, lastLanding)
      progress += (target - progress) * (1 - exp(-delta * 8))
      guard elapsed >= duration else { break }
      if phase == .firstPeek {
        branchDecisionCount += 1
        // This is the only random decision, after the first hide is complete.
        let climb = chooseClimb()
        enter(climb && !isError ? .climb : .secondPeek)
      } else if phase == .secondPeek {
        enter(.finished)
      } else {
        enter(.perched)
      }

    case .perched:
      let stride = (clips["bound"]?.distance ?? 25.86) * Self.scale / width
      let firstLanding = perch + 49 * Self.scale / width
      if approachProgress == nil {
        // Hold the next reachable edge: whole short bounds, then the original
        // bound into the push stance. Never shorten or stretch the final step.
        let maximum = Int(floor(max(0, 1 - firstLanding) / stride))
        bounds = min(maximum, max(0, Int(ceil((progress - firstLanding) / stride - 1e-9))))
        approachProgress = firstLanding + Double(bounds) * stride
      }
      let landing = approachProgress!
      let target = min(ceiling, landing)
      progress += (target - progress) * (1 - exp(-delta * 8))
      if !isError && elapsed >= 0.6 && ceiling >= landing
        && progress >= landing - 0.000001
      {
        progress = landing
        if progress >= 0.7 { didKick = true }
        enter(bounds > 0 ? .bounding : .approach)
      }

    case .bounding:
      if elapsed >= duration {
        boundIndex += 1
        enter(boundIndex < bounds ? .bounding : .approach)
      }

    case .approach:
      if elapsed >= duration { enter(.contact) }

    case .contact, .catchUp, .retry:
      if elapsed >= duration {
        enter(.push)
        preparePush(ceiling: ceiling, width: width, complete: isComplete)
      }

    case .push:
      if pushEnd <= pushStart {
        elapsed = 0
        if isError {
          restAtStanding = false
          enter(.settle)
        } else if isComplete && progress >= 1 - 0.000001 {
          enter(.celebrate)
        } else if !didKick && progress >= 0.7 - 0.000001 {
          enter(.release)
        } else {
          preparePush(ceiling: ceiling, width: width, complete: isComplete)
        }
        break
      }
      progress = min(ceiling, pushStart + (pushEnd - pushStart) * travel)
      if elapsed >= duration {
        progress = min(ceiling, pushEnd)
        if isError {
          restAtStanding = false
          enter(.settle)
        } else if isComplete && progress >= 1 - 0.000001 {
          enter(.celebrate)
        } else if !didKick && progress >= 0.7 - 0.000001 {
          enter(.release)
        } else {
          enter(.push)
          preparePush(ceiling: ceiling, width: width, complete: isComplete)
        }
      }

    case .release:
      if elapsed >= duration {
        if isError {
          restAtStanding = true
          enter(.settle)
        } else {
          enter(.waitingToKick)
        }
      }

    case .waitingToKick:
      if isError {
        restAtStanding = true
        enter(.settle)
      } else if ceiling - progress >= min(0.025, 69.44 * Self.scale / width) || isComplete {
        kickStart = progress
        kickEnd = min(ceiling, progress + 69.44 * Self.scale / width)
        didKick = true
        enter(.kick)
      }

    case .kick:
      progress = min(ceiling, kickStart + (kickEnd - kickStart) * travel)
      if elapsed >= duration {
        kickEnd = progress
        enter(.catchUp)
      }

    case .settle:
      if elapsed >= duration { enter(.rest) }
    case .rest:
      if !isError { enter(.retry) }
    case .celebrate:
      if elapsed >= duration { enter(.finished) }
    case .finished:
      break
    }
    progress = min(ceiling, max(0, progress))
  }

  private mutating func enter(_ next: Phase) {
    phase = next
    elapsed = 0
  }

  private mutating func preparePush(ceiling: Double, width: Double, complete: Bool) {
    pushStart = progress
    let checkpoint = didKick ? 1.0 : 0.7
    let stride = 24.96 * Self.scale / width
    // Completion can catch up over a few shoves without delaying model readiness.
    let amount = complete ? max(stride, (1 - progress) / 3) : stride
    pushEnd = max(pushStart, min(checkpoint, min(ceiling, progress + amount)))
  }
}
