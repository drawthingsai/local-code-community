import AVFoundation
import Foundation
import WebKit

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// Decodes local media without advancing a browser playback clock.
final class HTMLVideoMediaBridge: NSObject, WKScriptMessageHandlerWithReply {
  private let directory: URL
  private var assets = [URL: AVURLAsset]()
  private var generators = [URL: AVAssetImageGenerator]()
  private var cancelled = false

  init(directory: URL) { self.directory = directory.resolvingSymlinksInPath() }

  func cancel() {
    cancelled = true
    for generator in generators.values { generator.cancelAllCGImageGeneration() }
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard !cancelled else {
      replyHandler(nil, "Export cancelled.")
      return
    }
    guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
      let path = body["src"] as? String, let url = URL(string: path), url.isFileURL,
      url.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/")
    else {
      replyHandler(nil, "Media must be a local file inside the HTML project directory.")
      return
    }
    let asset = assets[url] ?? AVURLAsset(url: url)
    assets[url] = asset
    if body["operation"] as? String == "metadata" {
      let rateMap: HTMLVideoPlaybackRate
      do {
        rateMap = try HTMLVideoPlaybackRate(
          constant: body["rate"] as? Double ?? 1,
          points: body["ratePoints"] as? [[String: Any]] ?? [])
      } catch {
        replyHandler(nil, error.localizedDescription)
        return
      }
      asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
        DispatchQueue.main.async {
          guard !self.cancelled else {
            replyHandler(nil, "Export cancelled.")
            return
          }
          let duration = asset.duration.seconds
          guard duration.isFinite, duration > 0 else {
            replyHandler(nil, "Cannot decode media: \(url.lastPathComponent)")
            return
          }
          let track = asset.tracks(withMediaType: .video).first
          let size = track.map { $0.naturalSize.applying($0.preferredTransform) } ?? .zero
          replyHandler(
            [
              "duration": duration, "width": abs(size.width), "height": abs(size.height),
              "rateMap": rateMap.dictionary,
            ], nil)
        }
      }
    } else if body["operation"] as? String == "frame", let seconds = body["time"] as? Double,
      seconds.isFinite, seconds >= 0
    {
      let generator: AVAssetImageGenerator
      if let existing = generators[url] {
        generator = existing
      } else {
        generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generators[url] = generator
      }
      // Seek just inside the requested sample. Floating-point clip arithmetic at an
      // exact sample boundary can otherwise make ImageGenerator return its predecessor.
      let time = CMTimeMinimum(
        CMTime(seconds: seconds + 0.000001, preferredTimescale: 1_000_000_000),
        CMTimeSubtract(asset.duration, CMTime(value: 1, timescale: 60000)))
      generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
        _, image, _, result, error in
        guard result == .succeeded, let image else {
          DispatchQueue.main.async {
            replyHandler(nil, error?.localizedDescription ?? "Cannot decode video frame.")
          }
          return
        }
        #if canImport(UIKit)
          let data = UIImage(cgImage: image).pngData()
        #else
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #endif
        DispatchQueue.main.async {
          guard !self.cancelled, let data else {
            replyHandler(nil, "Video frame cancelled or unavailable.")
            return
          }
          replyHandler("data:image/png;base64," + data.base64EncodedString(), nil)
        }
      }
    } else {
      replyHandler(nil, "Invalid media request.")
    }
  }
}
