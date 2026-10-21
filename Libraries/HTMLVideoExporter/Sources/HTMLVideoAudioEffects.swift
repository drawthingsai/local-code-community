import AVFoundation
import Foundation
import WebKit

/// Runs the shared HyperFrames graph in an isolated WebKit world. One clip or
/// group at a time; PCM crosses the bridge in bounded chunks, never one huge string.
final class HTMLVideoAudioEffects {
  static let world = WKContentWorld.world(name: "html2video.audio-effects")
  private weak var webView: WKWebView?
  private let directory: URL
  // AVAssetReader may decode/time-stretch synchronously. Keep that work off the
  // WebKit thread; all ownership and continuation decisions remain on main.
  private let decodingQueue = DispatchQueue(label: "html2video.audio-decode")
  private var reader: AVAssetReader?
  private var file: AVAudioFile?
  private var cancelled = false
  private var completion: ((Result<URL, Error>) -> Void)?
  private var output: URL?
  private var channels = 2
  private var frames = 0
  private var cursor = 0
  private var clip = [String: Any]()
  private var elapsed = 0.0
  private var remaining = 0.0
  private var range = CMTimeRange.zero
  private let sampleRate = 48000.0
  private(set) var activity = 0

  init(webView: WKWebView) throws {
    self.webView = webView
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "html2video-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func cancel() {
    cancelled = true
    reader?.cancelReading()
    file = nil
    completion = nil
    webView?.evaluateJavaScript("globalThis.__html2videoFX.clear()", in: nil, in: Self.world) { _ in
    }
    try? FileManager.default.removeItem(at: directory)
  }

  func render(
    asset: AVAsset, mix: AVAudioMix?, range: CMTimeRange, clip: [String: Any],
    elapsed: Double, remaining: Double, completion: @escaping (Result<URL, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !cancelled else { return }
    self.completion = completion
    self.clip = clip
    self.range = range
    self.elapsed = elapsed
    self.remaining = remaining
    self.cursor = 0
    self.frames = Int(ceil(range.duration.seconds * sampleRate))
    self.output = directory.appendingPathComponent("\(UUID().uuidString).caf")
    do {
      let tracks = asset.tracks(withMediaType: .audio)
      channels =
        tracks.flatMap(\.formatDescriptions).compactMap {
          CMAudioFormatDescriptionGetStreamBasicDescription($0 as! CMAudioFormatDescription)
            .map { Int($0.pointee.mChannelsPerFrame) }
        }.max() ?? 2
      guard frames > 0, frames < Int(UInt32.max), (1...32).contains(channels) else {
        throw HTMLVideoExportError.invalid("Invalid offline audio dimensions.")
      }
      let reader = try AVAssetReader(asset: asset)
      self.reader = reader
      reader.timeRange = range
      let pcm = AVAssetReaderAudioMixOutput(
        audioTracks: tracks,
        audioSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
          AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
      pcm.audioMix = mix
      pcm.audioTimePitchAlgorithm = .spectral
      guard reader.canAdd(pcm) else {
        throw HTMLVideoExportError.writer("Cannot decode audio for effects.")
      }
      reader.add(pcm)
      guard reader.startReading() else {
        throw reader.error ?? HTMLVideoExportError.writer("Cannot start audio decoding.")
      }
      evaluate(
        "globalThis.__html2videoFX.begin(frames, channels, sampleRate); return true;",
        arguments: ["frames": frames, "channels": channels, "sampleRate": sampleRate]
      ) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success: self.read(pcm, reader: reader)
        case .failure(let error): self.finish(.failure(error))
        }
      }
    } catch { finish(.failure(error)) }
  }

  private func evaluate(
    _ script: String, arguments: [String: Any], completion: @escaping (Result<Any, Error>) -> Void
  ) {
    guard let webView else {
      completion(.failure(HTMLVideoExportError.cancelled))
      return
    }
    webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: Self.world) {
      [weak self] result in
      guard let self, !self.cancelled else { return }
      self.activity += 1
      completion(result)
    }
  }

  private func read(_ pcm: AVAssetReaderAudioMixOutput, reader: AVAssetReader) {
    let origin = range.start.seconds
    let frames = self.frames
    let channels = self.channels
    decodingQueue.async { [weak self] in
      let result: Result<(Data, Int)?, Error> = Result {
        guard let sample = pcm.copyNextSampleBuffer() else {
          guard reader.status == .completed else {
            throw reader.error ?? HTMLVideoExportError.writer("Audio decoding did not finish.")
          }
          return nil
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
          throw HTMLVideoExportError.writer("Decoded audio has no PCM buffer.")
        }
        let offset = Int(
          round((CMSampleBufferGetPresentationTimeStamp(sample).seconds - origin) * 48000))
        let count = CMSampleBufferGetNumSamples(sample)
        let first = max(0, -offset)
        let last = min(count, frames - offset)
        guard last > first else { return (Data(), max(0, offset)) }
        var data = Data(count: (last - first) * channels * 4)
        let status = data.withUnsafeMutableBytes { bytes in
          CMBlockBufferCopyDataBytes(
            block, atOffset: first * channels * 4, dataLength: bytes.count,
            destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
          throw HTMLVideoExportError.writer("Cannot copy decoded audio samples.")
        }
        return (data, max(0, offset))
      }
      DispatchQueue.main.async {
        guard let self, !self.cancelled else { return }
        do {
          guard let (data, offset) = try result.get() else {
            self.renderSamples()
            return
          }
          if data.isEmpty {
            self.read(pcm, reader: reader)
            return
          }
          self.send(data, offset: offset, at: 0) { [weak self] in
            self?.read(pcm, reader: reader)
          }
        } catch { self.finish(.failure(error)) }
      }
    }
  }

  private func send(_ data: Data, offset: Int, at: Int, completion: @escaping () -> Void) {
    // 8192 frames bounds both the native base64 allocation and WebKit messages.
    let end = min(data.count, at + 8192 * channels * 4)
    evaluate(
      "globalThis.__html2videoFX.append(data, offset); return true;",
      arguments: [
        "data": data.subdata(in: at..<end).base64EncodedString(),
        "offset": offset + at / (channels * 4),
      ]
    ) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error): self.finish(.failure(error))
      case .success:
        if end < data.count {
          self.send(data, offset: offset, at: end, completion: completion)
        } else {
          completion()
        }
      }
    }
  }

  private func renderSamples() {
    reader = nil
    evaluate(
      "return await globalThis.__html2videoFX.render(clip, elapsed, remaining);",
      arguments: ["clip": clip, "elapsed": elapsed, "remaining": remaining]
    ) { [weak self] result in
      guard let self else { return }
      do {
        guard let metadata = try result.get() as? [String: Any],
          let frames = metadata["frames"] as? Int, frames > 0,
          let output = self.output,
          let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate,
            channels: AVAudioChannelCount(self.channels), interleaved: true)
        else { throw HTMLVideoExportError.writer("Invalid audio effect output.") }
        self.frames = frames
        self.file = try AVAudioFile(
          forWriting: output, settings: format.settings,
          commonFormat: .pcmFormatFloat32, interleaved: true)
        self.receive()
      } catch { self.finish(.failure(error)) }
    }
  }

  private func receive() {
    let count = min(8192, frames - cursor)
    evaluate(
      "return globalThis.__html2videoFX.read(offset, count);",
      arguments: ["offset": cursor, "count": count]
    ) { [weak self] result in
      guard let self else { return }
      do {
        guard let base64 = try result.get() as? String, let data = Data(base64Encoded: base64),
          data.count == count * self.channels * 4, let file = self.file,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: UInt32(count))
        else { throw HTMLVideoExportError.writer("Invalid rendered audio samples.") }
        buffer.frameLength = UInt32(count)
        data.withUnsafeBytes { bytes in
          _ = memcpy(
            buffer.mutableAudioBufferList.pointee.mBuffers.mData!, bytes.baseAddress!, data.count)
        }
        try file.write(from: buffer)
        self.cursor += count
        if self.cursor < self.frames {
          self.receive()
        } else {
          self.file = nil
          self.evaluate("globalThis.__html2videoFX.clear(); return true;", arguments: [:]) {
            [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.finish(.success(self.output!))
            case .failure(let error): self.finish(.failure(error))
            }
          }
        }
      } catch { self.finish(.failure(error)) }
    }
  }

  private func finish(_ result: Result<URL, Error>) {
    reader?.cancelReading()
    reader = nil
    file = nil
    let completion = self.completion
    self.completion = nil
    completion?(result)
  }
}
