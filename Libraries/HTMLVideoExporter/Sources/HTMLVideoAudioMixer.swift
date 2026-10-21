import AVFoundation
import Foundation
import WebKit

/// Builds an offline audio mix on the captured picture's clock. Main-thread callbacks only.
final class HTMLVideoAudioMixer {
  private let composition = AVMutableComposition()
  private var parameters = [AVMutableAudioMixInputParameters]()
  private var session: AVAssetExportSession?
  private var cancelled = false
  private var effects: HTMLVideoAudioEffects?
  private struct Group {
    let composition = AVMutableComposition()
    var parameters = [AVMutableAudioMixInputParameters]()
    let metadata: [String: Any]
  }
  private var groups = [String: Group]()
  private var groupOrder = [String]()
  private var alpha = false
  private var fileType: AVFileType = .mp4

  var progress: Float { Float(effects?.activity ?? 0) + (session?.progress ?? 0) }

  func cancel() {
    cancelled = true
    session?.cancelExport()
    effects?.cancel()
  }

  func start(
    video: URL, output: URL, clips: [[String: Any]], duration: Double, webView: WKWebView,
    alpha: Bool = false,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    if clips.contains(where: {
      $0["fxChain"] != nil || $0["group"] != nil
        || $0["hasEffects"] as? Bool == true
    }) {
      do { effects = try HTMLVideoAudioEffects(webView: webView) } catch {
        completion(.failure(error))
        return
      }
    }
    self.alpha = alpha
    fileType = output.pathExtension == "mov" ? .mov : .mp4
    let picture = AVURLAsset(url: video)
    picture.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
      DispatchQueue.main.async {
        guard !self.cancelled else { return }
        do {
          guard let source = picture.tracks(withMediaType: .video).first,
            let track = self.composition.addMutableTrack(
              withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
          else { throw HTMLVideoExportError.writer("Captured video has no picture track.") }
          try track.insertTimeRange(
            CMTimeRange(start: .zero, duration: picture.duration), of: source, at: .zero)
          track.preferredTransform = source.preferredTransform
          self.addAudio(
            clips: clips, index: 0, duration: duration, output: output, completion: completion)
        } catch { completion(.failure(error)) }
      }
    }
  }

  private func addAudio(
    clips: [[String: Any]], index: Int, duration: Double, output: URL,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard !cancelled else { return }
    guard index < clips.count else {
      mixGroups(index: 0, duration: duration, output: output, completion: completion)
      return
    }
    let clip = clips[index]
    guard let path = clip["src"] as? String, let url = URL(string: path), url.isFileURL else {
      completion(.failure(HTMLVideoExportError.invalid("Audio sources must be local files.")))
      return
    }
    let asset = AVURLAsset(url: url)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
      DispatchQueue.main.async {
        guard !self.cancelled else { return }
        do {
          let group = clip["group"] as? [String: Any]
          let groupID = group?["id"] as? String
          if let groupID, let group, self.groups[groupID] == nil {
            self.groups[groupID] = Group(metadata: group)
            self.groupOrder.append(groupID)
          }
          let target = groupID.flatMap { self.groups[$0]?.composition } ?? self.composition
          let next: (Result<AVMutableAudioMixInputParameters?, Error>) -> Void = { result in
            guard !self.cancelled else { return }
            do {
              if let parameter = try result.get() {
                if let groupID {
                  self.groups[groupID]?.parameters.append(parameter)
                } else {
                  self.parameters.append(parameter)
                }
              }
              self.addAudio(
                clips: clips, index: index + 1, duration: duration,
                output: output, completion: completion)
            } catch { completion(.failure(error)) }
          }
          if let effects = self.effects,
            clip["fxChain"] != nil || clip["hasEffects"] as? Bool == true
          {
            guard let start = clip["start"] as? Double,
              let visibleStart = clip["visibleStart"] as? Double, let end = clip["end"] as? Double,
              start.isFinite, visibleStart.isFinite, end.isFinite
            else { throw HTMLVideoExportError.invalid("Invalid audio timing.") }
            let lower = max(0, visibleStart)
            guard lower < duration else {
              next(.success(nil))
              return
            }
            // Render from the clip's beginning on a local clock. Discarding its
            // prefix before effects would reset delay/reverb and worklet state.
            let dry = AVMutableComposition()
            var unprocessed = clip
            unprocessed["start"] = 0.0
            unprocessed["visibleStart"] = 0.0
            unprocessed["end"] = end - start
            unprocessed["volume"] = 1.0
            unprocessed["points"] = [[String: Any]]()
            guard
              let (_, upper, parameter) = try self.insert(
                clip: unprocessed, asset: asset, duration: duration - start, into: dry)
            else {
              next(.success(nil))
              return
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameter]
            effects.render(
              asset: dry, mix: mix,
              range: CMTimeRange(
                start: .zero, duration: CMTime(seconds: upper, preferredTimescale: 60000)),
              clip: clip, elapsed: 0, remaining: duration - start
            ) { result in
              guard !self.cancelled else { return }
              switch result {
              case .failure(let error): next(.failure(error))
              case .success(let url):
                self.insertProcessed(
                  url, at: lower, trim: lower - start, into: target, completion: next)
              }
            }
          } else {
            next(
              .success(
                try self.insert(clip: clip, asset: asset, duration: duration, into: target)?.2))
          }
        } catch { completion(.failure(error)) }
      }
    }
  }

  private func export(
    output: URL, duration: Double, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard
      let session = AVAssetExportSession(
        asset: composition,
        presetName: alpha
          ? AVAssetExportPresetHEVCHighestQualityWithAlpha : AVAssetExportPresetHighestQuality)
    else {
      completion(
        .failure(HTMLVideoExportError.writer("Cannot create audio/video export session.")))
      return
    }
    self.session = session
    let mix = AVMutableAudioMix()
    mix.inputParameters = parameters
    session.audioMix = mix
    session.outputURL = output
    session.outputFileType = fileType
    session.timeRange = CMTimeRange(
      start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000))
    session.exportAsynchronously {
      DispatchQueue.main.async {
        guard !self.cancelled else { return }
        if session.status == .completed {
          completion(.success(()))
        } else {
          completion(
            .failure(session.error ?? HTMLVideoExportError.writer("Audio/video mixing failed.")))
        }
      }
    }
  }

  private func mixGroups(
    index: Int, duration: Double, output: URL,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard !cancelled else { return }
    guard index < groupOrder.count else {
      export(output: output, duration: duration, completion: completion)
      return
    }
    let group = groups[groupOrder[index]]!
    guard !group.composition.tracks(withMediaType: .audio).isEmpty else {
      mixGroups(index: index + 1, duration: duration, output: output, completion: completion)
      return
    }
    let mix = AVMutableAudioMix()
    mix.inputParameters = group.parameters
    effects!.render(
      asset: group.composition, mix: mix,
      range: CMTimeRange(
        start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 60000)),
      clip: group.metadata, elapsed: 0, remaining: duration
    ) { [weak self] result in
      guard let self, !self.cancelled else { return }
      switch result {
      case .failure(let error): completion(.failure(error))
      case .success(let url):
        self.insertProcessed(url, at: 0, into: self.composition) { result in
          guard !self.cancelled else { return }
          do {
            if let parameter = try result.get() { self.parameters.append(parameter) }
            self.mixGroups(
              index: index + 1, duration: duration, output: output, completion: completion)
          } catch { completion(.failure(error)) }
        }
      }
    }
  }

  private func insertProcessed(
    _ url: URL, at start: Double, trim: Double = 0, into target: AVMutableComposition,
    completion: @escaping (Result<AVMutableAudioMixInputParameters?, Error>) -> Void
  ) {
    let asset = AVURLAsset(url: url)
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
      DispatchQueue.main.async {
        guard !self.cancelled else { return }
        do {
          let offset = CMTime(seconds: trim, preferredTimescale: 48000)
          guard CMTimeCompare(asset.duration, offset) > 0 else {
            completion(.success(nil))
            return
          }
          guard let source = asset.tracks(withMediaType: .audio).first,
            let track = target.addMutableTrack(
              withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
          else { throw HTMLVideoExportError.writer("Cannot insert processed audio.") }
          try track.insertTimeRange(
            CMTimeRange(start: offset, duration: CMTimeSubtract(asset.duration, offset)),
            of: source,
            at: CMTime(seconds: start, preferredTimescale: 60000))
          let parameter = AVMutableAudioMixInputParameters(track: track)
          parameter.setVolume(1, at: .zero)
          completion(.success(parameter))
        } catch { completion(.failure(error)) }
      }
    }
  }

  private func insert(
    clip: [String: Any], asset: AVAsset, duration: Double,
    into composition: AVMutableComposition
  ) throws -> (Double, Double, AVMutableAudioMixInputParameters)? {
    guard let start = clip["start"] as? Double, let visibleStart = clip["visibleStart"] as? Double,
      let end = clip["end"] as? Double, let trim = clip["trim"] as? Double,
      let rateTable = clip["rateMap"] as? [String: Any], let volume = clip["volume"] as? Double,
      start.isFinite, visibleStart.isFinite, end.isFinite, trim.isFinite,
      volume.isFinite, (0...1).contains(volume), trim >= 0
    else { throw HTMLVideoExportError.invalid("Invalid audio timing or volume (expected 0…1).") }
    let rateMap = try HTMLVideoPlaybackRate(dictionary: rateTable)
    let loop = clip["loop"] as? Bool ?? false
    let length = asset.duration.seconds - trim
    guard length.isFinite, length > 0, let source = asset.tracks(withMediaType: .audio).first else {
      throw HTMLVideoExportError.invalid(
        "Audio source has no decodable audio track or trim exceeds its duration.")
    }
    let lower = max(0, visibleStart)
    let upper = min(duration, end, loop ? end : start + rateMap.timelineTime(at: length))
    guard upper > lower else { return nil }
    guard
      let track = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else {
      throw HTMLVideoExportError.writer("Cannot add audio track.")
    }
    // Match HyperFrames' pitch-preserving audio approximation: at most 240
    // equal timeline slices, normally 250ms. Use the SAME integrated source-time
    // table as video, including when visibility trims a clip or a source loops.
    let slices = rateMap.isConstant ? 1 : min(240, max(1, Int(ceil((upper - lower) / 0.25))))
    let step = (upper - lower) / Double(slices)
    var position = lower
    for slice in 1...slices {
      let sliceEnd = lower + Double(slice) * step
      while position < sliceEnd - 0.000001 {
        let consumed = rateMap.sourceTime(at: position - start)
        var sourceOffset = loop ? consumed.truncatingRemainder(dividingBy: length) : consumed
        if loop && length - sourceOffset < 0.000001 { sourceOffset = 0 }
        let boundary = start + rateMap.timelineTime(at: consumed + length - sourceOffset)
        let next = min(sliceEnd, boundary)
        let count = next - position
        guard count > 0.000001 else { break }
        let destination = CMTime(seconds: position, preferredTimescale: 60000)
        let sourceCount = min(
          length - sourceOffset, rateMap.sourceTime(at: next - start) - consumed)
        let sourceDuration = CMTime(seconds: sourceCount, preferredTimescale: 60000)
        try track.insertTimeRange(
          CMTimeRange(
            start: CMTime(seconds: trim + sourceOffset, preferredTimescale: 60000),
            duration: sourceDuration), of: source, at: destination)
        track.scaleTimeRange(
          CMTimeRange(start: destination, duration: sourceDuration),
          toDuration: CMTime(seconds: count, preferredTimescale: 60000))
        position = next
      }
    }
    let parameter = AVMutableAudioMixInputParameters(track: track)
    parameter.audioTimePitchAlgorithm = .spectral
    let points = clip["points"] as? [[String: Any]] ?? []
    var envelope = [(Double, Float)]()
    for point in points {
      guard let time = point["t"] as? Double, let value = point["v"] as? Double,
        time.isFinite, time >= 0, value.isFinite, (0...1).contains(value),
        time > (envelope.last?.0 ?? -1), point["ease"] == nil, point["easing"] == nil
      else {
        throw HTMLVideoExportError.invalid(
          "Volume automation requires increasing times, linear points, and values in 0…1.")
      }
      envelope.append((time, Float(value)))
    }
    func level(_ globalTime: Double) -> Float {
      guard let first = envelope.first, let last = envelope.last else { return Float(volume) }
      let t = globalTime - start
      if t <= first.0 { return first.1 }
      if t >= last.0 { return last.1 }
      for i in 1..<envelope.count where t <= envelope[i].0 {
        let a = envelope[i - 1]
        let b = envelope[i]
        return a.1 + (b.1 - a.1) * Float((t - a.0) / (b.0 - a.0))
      }
      return last.1
    }
    let boundaries =
      [lower] + envelope.map { $0.0 + start }.filter { $0 > lower && $0 < upper } + [upper]
    for i in 1..<boundaries.count {
      let a = boundaries[i - 1]
      let b = boundaries[i]
      parameter.setVolumeRamp(
        fromStartVolume: level(a), toEndVolume: level(b),
        timeRange: CMTimeRange(
          start: CMTime(seconds: a, preferredTimescale: 60000),
          duration: CMTime(seconds: b - a, preferredTimescale: 60000)))
    }
    return (lower, upper, parameter)
  }
}
