import CoreFoundation
import Foundation

// Rate normalization, conic interpolation, and integration follow HyperFrames
// speedRamp.ts / audioAutomation.ts at b66739820762551e0af268d19568cd8a790a35f2.
// Upstream is licensed under Apache-2.0; see Vendors/HyperFrames/LICENSE.
// Build this table once and share it with WebKit so audio and picture use one clock.
struct HTMLVideoPlaybackRate {
  let times: [Double]
  let sources: [Double]
  let firstRate: Double
  let lastRate: Double

  var isConstant: Bool { times.count == 1 }
  var dictionary: [String: Any] {
    ["times": times, "sources": sources, "firstRate": firstRate, "lastRate": lastRate]
  }

  init(constant: Double, points: [[String: Any]]) throws {
    struct Point {
      var t: Double
      var v: Double
      var curve: Double
      var viaX: Double?
      var viaY: Double?
    }
    func number(_ value: Any?) -> Double? {
      let result: Double?
      if let text = value as? String {
        result = Double(text.trimmingCharacters(in: .whitespaces))
      } else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
        result = value.doubleValue
      } else {
        result = nil
      }
      return result.flatMap { $0.isFinite ? $0 : nil }
    }
    var normalized = [Double: Point]()
    for point in points {
      guard let t = number(point["t"]), let v = number(point["v"]) else { continue }
      let time = max(0, t)
      normalized[time] = Point(
        t: time, v: min(10, max(0.1, v)),
        curve: min(1, max(-1, number(point["curve"]) ?? 0)),
        viaX: number(point["viaX"]).map { min(0.999, max(0.001, $0)) },
        viaY: number(point["viaY"]).map { min(0.999, max(0.001, $0)) })
    }
    let points = Array(normalized.values.sorted { $0.t < $1.t }.prefix(512))
    guard let first = points.first, let last = points.last else {
      guard constant.isFinite, (0.1...10).contains(constant) else {
        throw HTMLVideoExportError.invalid("Playback rate must be in 0.1…10.")
      }
      times = [0]
      sources = [0]
      firstRate = constant
      lastRate = constant
      return
    }
    func sample(_ time: Double) -> Double {
      if time <= first.t { return first.v }
      if time >= last.t { return last.v }
      var lo = 0
      var hi = points.count - 1
      while hi - lo > 1 {
        let mid = (lo + hi) / 2
        if points[mid].t <= time { lo = mid } else { hi = mid }
      }
      let a = points[lo]
      let b = points[hi]
      let x = (time - a.t) / (b.t - a.t)
      let progress: Double
      if let viaX = a.viaX, let viaY = a.viaY, abs(viaX - viaY) >= 1e-6 {
        let dx = viaX - 0.5
        let dy = viaY - 0.5
        let edge = 0.999
        let needX = dx > 0 ? dx / (edge - viaX) : dx < 0 ? -dx / (viaX - (1 - edge)) : 0
        let needY = dy > 0 ? dy / (edge - viaY) : dy < 0 ? -dy / (viaY - (1 - edge)) : 0
        let weight = min(1e6, max(1, needX, needY))
        let cx = viaX + dx / weight
        let cy = viaY + dy / weight
        let spread = 2 - 2 * weight
        let qa = x * spread - 1 + 2 * weight * cx
        let qb = -x * spread - 2 * weight * cx
        let t: Double
        if abs(qa) < 1e-12 {
          t = abs(qb) < 1e-12 ? x : -x / qb
        } else {
          let root = sqrt(max(0, qb * qb - 4 * qa * x))
          let one = (-qb + root) / (2 * qa)
          let two = (-qb - root) / (2 * qa)
          if one >= -1e-9 && one <= 1 + 1e-9 {
            t = min(1, max(0, one))
          } else if two >= -1e-9 && two <= 1 + 1e-9 {
            t = min(1, max(0, two))
          } else {
            t = x
          }
        }
        let rest = 1 - t
        let denominator = rest * rest + 2 * weight * t * rest + t * t
        progress = denominator > 0 ? (2 * weight * cy * t * rest + t * t) / denominator : x
      } else {
        progress = pow(x, pow(2, 2 * a.curve))
      }
      return exp(log(a.v) + (log(b.v) - log(a.v)) * progress)
    }
    var times = [0.0]
    var sources = [0.0]
    func append(_ time: Double) {
      let previous = times.last!
      guard time > previous else { return }
      sources.append(sources.last! + (sample(previous) + sample(time)) / 2 * (time - previous))
      times.append(time)
    }
    append(first.t)
    for index in 1..<points.count {
      let a = points[index - 1].t
      let b = points[index].t
      for cell in 1...48 { append(a + (b - a) * Double(cell) / 48) }
    }
    self.times = times
    self.sources = sources
    firstRate = first.v
    lastRate = last.v
  }

  init(dictionary: [String: Any]) throws {
    guard let times = dictionary["times"] as? [Double],
      let sources = dictionary["sources"] as? [Double],
      let first = dictionary["firstRate"] as? Double, let last = dictionary["lastRate"] as? Double,
      !times.isEmpty, times.count == sources.count, times.count <= 24530,
      times[0] == 0, sources[0] == 0, (0.1...10).contains(first), (0.1...10).contains(last),
      times.allSatisfy(\.isFinite), sources.allSatisfy(\.isFinite),
      zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }),
      zip(sources, sources.dropFirst()).allSatisfy({ $0 < $1 })
    else { throw HTMLVideoExportError.invalid("Invalid media playback-rate table.") }
    self.times = times
    self.sources = sources
    firstRate = first
    lastRate = last
  }

  func sourceTime(at time: Double) -> Double {
    if time <= 0 { return time * firstRate }
    if time >= times.last! { return sources.last! + (time - times.last!) * lastRate }
    return interpolate(time, from: times, to: sources)
  }

  func timelineTime(at source: Double) -> Double {
    if source <= 0 { return source / firstRate }
    if source >= sources.last! { return times.last! + (source - sources.last!) / lastRate }
    return interpolate(source, from: sources, to: times)
  }

  private func interpolate(_ value: Double, from: [Double], to: [Double]) -> Double {
    var lo = 0
    var hi = from.count - 1
    while hi - lo > 1 {
      let mid = (lo + hi) / 2
      if from[mid] <= value { lo = mid } else { hi = mid }
    }
    return to[lo] + (to[hi] - to[lo]) * (value - from[lo]) / (from[hi] - from[lo])
  }
}
