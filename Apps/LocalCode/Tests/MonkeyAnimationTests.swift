import Foundation

@main
struct MonkeyAnimationTests {
  static func main() throws {
    let url = URL(fileURLWithPath: CommandLine.arguments[1])
    let clips = try JSONDecoder().decode(
      [String: MonkeyAnimation.Clip].self, from: Data(contentsOf: url))
    var checks = 0
    var trace = [[String: Any]]()
    for width in [240.0, 340, 600, 1_000] {
      for rate in [30.0, 60, 120] {
        for climb in [false, true] {
          var motion = MonkeyAnimation(progress: 0.4, width: width, clips: clips)
          let perch = motion.anchorX(width: width)
          let stride = clips["bound"]!.distance * MonkeyAnimation.scale
          var decisions = 0
          var kicks = 0
          var previous = motion.phase
          var visited = Set<String>()
          for frame in 0..<Int(rate * 90) {
            let t = Double(frame) / rate
            // Includes a long stall, burst, and completion well ahead of the display.
            let real = t < 5 ? 0.4 + t * 0.035 : t < 11 ? 0.575 : min(1, 0.575 + (t - 11) * 0.04)
            let oldProgress = motion.progress
            motion.advance(
              by: 1 / rate, realProgress: real, width: width,
              isError: false, isComplete: real == 1,
              chooseClimb: {
                precondition(t >= 3 - 1 / rate - 0.000001, "Decision happened during first peek")
                decisions += 1
                return climb
              })
            precondition(motion.progress <= real + 1e-12, "Display exceeded transport")
            precondition(motion.progress >= oldProgress - 1e-12, "Display moved backwards")
            precondition(motion.anchorX(width: width).isFinite)
            if [.firstPeek, .secondPeek, .climb, .perched].contains(motion.phase) {
              precondition(
                motion.anchorX(width: width) == perch, "The second peek changed position")
            }
            if motion.phase == .bounding {
              let travel = clips["bound"]!.travel[Int(motion.frame)]
              let index = (motion.anchorX(width: width) - perch) / stride - travel
              precondition(
                abs(index - index.rounded()) < 1e-8, "A bound changed its fixed distance")
              let steps = (motion.progress * width - perch - 49 * MonkeyAnimation.scale) / stride
              precondition(abs(steps - steps.rounded()) < 1e-8, "Edge is off the landing grid")
              if previous == .bounding {
                precondition(motion.progress == oldProgress, "The edge moved during the approach")
              }
            }
            if motion.phase == .approach {
              precondition(
                abs(
                  motion.anchorX(width: width)
                    - (motion.progress * width - 49 * MonkeyAnimation.scale)) < 1e-8,
                "Approach stretched beyond the approved bound")
            }
            if motion.phase == .kick && previous != .kick { kicks += 1 }
            previous = motion.phase
            visited.insert(motion.phase.rawValue)
            if width == 340 && rate == 60 && climb {
              trace.append([
                "time": t, "clip": motion.clip, "frame": motion.frame,
                "phase": motion.phase.rawValue, "progress": motion.progress,
                "real": real, "anchor": motion.anchorX(width: width),
              ])
            }
            checks += 1
            if motion.phase == .finished { break }
          }
          precondition(decisions == 1 && motion.branchDecisionCount == 1)
          precondition(motion.phase == .finished, "Sequence failed to finish")
          precondition(climb ? kicks == 1 : kicks == 0)
          precondition(climb ? visited.contains("celebrate") : !visited.contains("climb"))
          if climb {
            precondition(motion.progress > 0.999999)
            precondition(visited.contains("bounding"), "Long approach did not repeat short bounds")
          }
        }
      }
    }

    // A stall between landing points must wait for transport, not shorten a hop
    // or move displayed progress backwards to the preceding landing point.
    for initiallyComplete in [false, true] {
      var motion = MonkeyAnimation(progress: 0.4, width: 340, clips: clips)
      for frame in 0..<5_400 {
        let t = Double(frame) / 60
        let real = initiallyComplete || t >= 20 ? 1.0 : 0.6
        let oldProgress = motion.progress
        motion.advance(
          by: 1 / 60, realProgress: real, width: 340,
          isError: false, isComplete: real == 1, chooseClimb: { true })
        precondition(motion.progress <= real + 1e-12)
        precondition(motion.progress >= oldProgress - 1e-12)
        if !initiallyComplete && t > 10 && t < 20 {
          precondition(motion.phase == .perched, "Left before the exact landing became available")
        }
        checks += 1
        if motion.phase == .finished { break }
      }
      precondition(motion.phase == .finished)
    }

    // Fail at different contact states, wait at rest, retry without another coin flip.
    for failAt in [MonkeyAnimation.Phase.push, .release, .waitingToKick, .kick, .catchUp] {
      var motion = MonkeyAnimation(progress: 0.4, width: 340, clips: clips)
      var failureTime: Double?
      var heldProgress: Double?
      var didRest = false
      var decisions = 0
      for frame in 0..<5_400 {
        let t = Double(frame) / 60
        if failureTime == nil && motion.phase == failAt { failureTime = t }
        let error = failureTime.map { t - $0 < 6 } ?? false
        if error && heldProgress == nil { heldProgress = motion.progress }
        let real = t < 8 ? 0.6 : t < 14 ? 0.73 : t < 26 ? 0.95 : 1
        motion.advance(
          by: 1 / 60, realProgress: real, width: 340,
          isError: error, isComplete: t > 20 && !error,
          chooseClimb: {
            decisions += 1
            return true
          })
        if error {
          precondition(abs(motion.progress - heldProgress!) < 1e-9, "Error changed displayed bytes")
          if motion.phase == .rest { didRest = true }
        }
        checks += 1
        if motion.phase == .finished { break }
      }
      precondition(failureTime != nil && didRest, "Error did not settle from \(failAt)")
      precondition(decisions == 1 && motion.phase == .finished)
    }

    // Revised totals may lower real progress; even then it remains a hard ceiling.
    var revised = MonkeyAnimation(progress: 0.8, width: 340, clips: clips)
    revised.advance(
      by: 1 / 60, realProgress: 0.5, width: 340,
      isError: false, isComplete: false, chooseClimb: { true })
    precondition(revised.progress <= 0.5)

    if CommandLine.arguments.count > 2 {
      try JSONSerialization.data(withJSONObject: trace).write(
        to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    print(
      "Passed \(checks) motion frames: progress ceiling, fixed-distance bounds, landing alignment, branch timing, one kick, error/rest/retry, completion, and revised totals."
    )
  }
}
