import AVFoundation
import Foundation
import QuartzCore
import WebKit

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// One export owns one WebKit page and at most one captured frame. Call on the main thread;
/// WebKit callbacks and completion remain there. Pixel conversion runs on a private serial queue.
public final class HTMLVideoExporter {
  private final class ObjCResponder: NSObject, WKNavigationDelegate {
    weak var exporter: HTMLVideoExporter?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      exporter?.webView(webView, didFinish: navigation)
    }

    func webView(
      _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
      exporter?.webView(webView, didFail: navigation, withError: error)
    }

    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      exporter?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      exporter?.webViewWebContentProcessDidTerminate(webView)
    }
  }

  private let objCResponder = ObjCResponder()
  private let options: HTMLVideoExportOptions
  private let cancellationRequested: () -> Bool
  private let progress: (Int, Int) -> Void
  private var completion: ((Result<HTMLVideoExportResult, Error>) -> Void)?
  private var webView: WKWebView?
  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var mediaBridge: HTMLVideoMediaBridge?
  private var audioClips = [[String: Any]]()
  private var audioMixer: HTMLVideoAudioMixer?
  private var mixingProgress: Float = 0
  private var mixedOutput: URL?
  private var readiness: NSKeyValueObservation?
  private var timer: Timer?
  private var deadline: CFTimeInterval = .infinity
  private var pendingBuffer: CVPixelBuffer?
  private var frame = 0
  private var frames = 0
  private var width = 0
  private var height = 0
  private var preparing = false
  private var finished = false
  private let conversionQueue = DispatchQueue(label: "html2video.pixels")
  private let temporaryOutput: URL

  public init(
    options: HTMLVideoExportOptions, cancellationRequested: @escaping () -> Bool = { false },
    progress: @escaping (Int, Int) -> Void = { _, _ in }
  ) {
    self.options = options
    self.cancellationRequested = cancellationRequested
    self.progress = progress
    temporaryOutput = options.output.deletingLastPathComponent().appendingPathComponent(
      ".html2video-\(UUID().uuidString).\(options.format)")
    objCResponder.exporter = self
  }

  public func start(completion: @escaping (Result<HTMLVideoExportResult, Error>) -> Void) {
    precondition(Thread.isMainThread)
    precondition(self.completion == nil && !finished, "An exporter can only run once.")
    self.completion = completion
    do {
      try FileManager.default.createDirectory(
        at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true)
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.mediaTypesRequiringUserActionForPlayback = .all
      let mediaBridge = HTMLVideoMediaBridge(directory: options.input.deletingLastPathComponent())
      self.mediaBridge = mediaBridge
      configuration.userContentController.addScriptMessageHandler(
        mediaBridge, contentWorld: .page, name: "html2videoMedia")
      configuration.userContentController.addUserScript(
        WKUserScript(
          source: HTMLVideoPage.bootstrap
            + "\nwindow.__HF_EXPORT_RENDER_SEEK_CONFIG = {fps: \(Double(options.fpsNumerator) / Double(options.fpsDenominator)), fpsSource: 'render-options'};",
          injectionTime: .atDocumentStart, forMainFrameOnly: true))
      configuration.userContentController.addUserScript(
        WKUserScript(
          source: HTMLVideoAudioEffectsRuntime.script, injectionTime: .atDocumentStart,
          forMainFrameOnly: true, in: HTMLVideoAudioEffects.world))
      let variables = try JSONSerialization.data(
        withJSONObject: options.variables, options: [.sortedKeys])
      configuration.userContentController.addUserScript(
        WKUserScript(
          source: "window.__hfVariables = \(String(decoding: variables, as: UTF8.self));",
          injectionTime: .atDocumentStart, forMainFrameOnly: true))
      let webView = WKWebView(
        frame: CGRect(x: 0, y: 0, width: options.width ?? 1920, height: options.height ?? 1080),
        configuration: configuration)
      self.webView = webView
      webView.navigationDelegate = objCResponder
      if options.alpha { webView.underPageBackgroundColor = .clear }
      #if canImport(UIKit)
        if options.alpha {
          webView.isOpaque = false
          webView.backgroundColor = .clear
          webView.scrollView.backgroundColor = .clear
        }
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Attaching keeps WebKit's rendering lifecycle active even when the capture view is hidden.
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          .flatMap(\.windows).first { $0.isKeyWindow }
        window?.rootViewController?.view.addSubview(webView)
        webView.isHidden = true
      #endif
      deadline = CACurrentMediaTime() + options.timeout
      let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        guard let self, !self.finished else { return }
        if self.cancellationRequested() {
          self.finish(.failure(HTMLVideoExportError.cancelled))
        } else if let mixer = self.audioMixer, mixer.progress > self.mixingProgress {
          self.mixingProgress = mixer.progress
          self.deadline = CACurrentMediaTime() + self.options.timeout
        } else if CACurrentMediaTime() >= self.deadline {
          self.finish(.failure(HTMLVideoExportError.timeout))
        }
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
      let html = try String(contentsOf: options.input, encoding: .utf8)
      HTMLVideoPage.initialViewport(
        html, in: webView, width: options.width, height: options.height
      ) { [weak self] result in
        guard let self, !self.finished else { return }
        do {
          webView.frame.size = try result.get()
          webView.loadFileURL(
            self.options.input, allowingReadAccessTo: self.options.input.deletingLastPathComponent()
          )
        } catch { self.finish(.failure(error)) }
      }
    } catch { finish(.failure(error)) }
  }

  public func cancel() {
    precondition(Thread.isMainThread)
    finish(.failure(HTMLVideoExportError.cancelled))
  }

  private func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !finished, !preparing else { return }
    preparing = true
    webView.callAsyncJavaScript(
      HTMLVideoPage.prepare,
      arguments: [
        "requestedWidth": options.width ?? 0, "requestedHeight": options.height ?? 0,
        "requestedDuration": options.duration ?? 0,
      ], in: nil, in: .page
    ) { [weak self] result in
      guard let self, !self.finished else { return }
      do {
        guard let metadata = try result.get() as? [String: Any],
          let w = metadata["width"] as? Double, let h = metadata["height"] as? Double,
          let duration = metadata["duration"] as? Double,
          w.isFinite, h.isFinite, duration.isFinite, (2...8192).contains(w),
          (2...8192).contains(h), w.rounded() == w, h.rounded() == h,
          Int(w) % 2 == 0, Int(h) % 2 == 0, duration > 0, duration <= 86400
        else {
          throw HTMLVideoExportError.invalid(
            "Page must declare even dimensions (2…8192) and a positive duration (≤86400s).")
        }
        self.audioClips = metadata["audio"] as? [[String: Any]] ?? []
        self.width = Int(w)
        self.height = Int(h)
        self.frames = Int(
          ceil(duration * Double(self.options.fpsNumerator) / Double(self.options.fpsDenominator)))
        self.webView?.frame.size = CGSize(width: w, height: h)
        webView.callAsyncJavaScript(
          "for (const clip of clips) { globalThis.__html2videoFX.validate(clip); if (clip.group) globalThis.__html2videoFX.validate(clip.group); } return true;",
          arguments: ["clips": self.audioClips], in: nil, in: HTMLVideoAudioEffects.world
        ) { [weak self] result in
          guard let self, !self.finished else { return }
          do {
            _ = try result.get()
            try self.beginWriting()
            self.nextFrame()
          } catch { self.finish(.failure(error)) }
        }
      } catch { self.finish(.failure(error)) }
    }
  }

  private func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    finish(.failure(error))
  }

  private func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finish(.failure(error))
  }

  private func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(.failure(HTMLVideoExportError.browser("Web content process terminated during export.")))
  }

  private func beginWriting() throws {
    let writer = try AVAssetWriter(
      outputURL: temporaryOutput, fileType: options.format == "mov" ? .mov : .mp4)
    self.writer = writer
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: options.alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.h264,
        AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          // CoreVideo exposes this same value on our older deployment targets.
          AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
          AVVideoExpectedSourceFrameRateKey: Double(options.fpsNumerator)
            / Double(options.fpsDenominator),
          AVVideoAllowFrameReorderingKey: false,
        ],
      ])
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw HTMLVideoExportError.writer("Cannot create the requested video encoder.")
    }
    writer.add(input)
    self.input = input
    adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      ])
    guard writer.startWriting() else {
      throw writer.error ?? HTMLVideoExportError.writer("Cannot start encoder.")
    }
    writer.startSession(atSourceTime: .zero)
    // Readiness is KVO-observable. Observe transitions rather than polling or blocking WebKit.
    readiness = input.observe(\.isReadyForMoreMediaData, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.appendPendingFrame() }
    }
  }

  private func nextFrame() {
    guard !finished, let webView else { return }
    if cancellationRequested() {
      finish(.failure(HTMLVideoExportError.cancelled))
      return
    }
    deadline = CACurrentMediaTime() + options.timeout
    guard frame < frames else {
      input?.markAsFinished()
      writer?.endSession(
        atSourceTime: CMTime(
          value: Int64(frames) * Int64(options.fpsDenominator), timescale: options.fpsNumerator))
      writer?.finishWriting { [weak self] in
        DispatchQueue.main.async {
          guard let self, !self.finished else { return }
          guard self.writer?.status == .completed else {
            self.finish(
              .failure(self.writer?.error ?? HTMLVideoExportError.writer("Encoder did not finish."))
            )
            return
          }
          if self.audioClips.isEmpty {
            self.publish(self.temporaryOutput)
          } else {
            self.webView?.callAsyncJavaScript(
              "return window.__html2videoAudio();", arguments: [:], in: nil, in: .page
            ) { [weak self] result in
              guard let self, !self.finished else { return }
              do {
                guard let audio = try result.get() as? [[String: Any]] else {
                  throw HTMLVideoExportError.browser("Page returned invalid audio metadata.")
                }
                let mixer = HTMLVideoAudioMixer()
                self.audioMixer = mixer
                let output = self.temporaryOutput.deletingPathExtension().appendingPathExtension(
                  "mixed.\(self.options.format)")
                self.mixedOutput = output
                mixer.start(
                  video: self.temporaryOutput, output: output, clips: audio,
                  duration: Double(self.frames) * Double(self.options.fpsDenominator)
                    / Double(self.options.fpsNumerator), webView: self.webView!,
                  alpha: self.options.alpha
                ) { [weak self] result in
                  guard let self, !self.finished else { return }
                  switch result {
                  case .success: self.publish(output)
                  case .failure(let error): self.finish(.failure(error))
                  }
                }
              } catch { self.finish(.failure(error)) }
            }
          }
        }
      }
      return
    }
    let seconds = Double(frame) * Double(options.fpsDenominator) / Double(options.fpsNumerator)
    webView.callAsyncJavaScript(
      "await window.__html2videoSeek(seconds); return true;",
      arguments: ["seconds": seconds], in: nil, in: .page
    ) { [weak self] result in
      guard let self, !self.finished else { return }
      do {
        _ = try result.get()
        self.snapshot()
      } catch { self.finish(.failure(error)) }
    }
  }

  private func snapshot() {
    guard let webView, !finished else { return }
    HTMLPageSnapshot.capture(
      webView, rect: webView.bounds, pixelWidth: Double(width), preservingAlpha: options.alpha
    ) { [weak self] result in
      guard let self, !self.finished else { return }
      do { self.convertSnapshot(try result.get()) } catch { self.finish(.failure(error)) }
    }
  }

  private func convertSnapshot(_ snapshot: HTMLPageSnapshot) {
    guard let pool = adaptor?.pixelBufferPool else { return }
    let width = self.width
    let height = self.height
    let alpha = options.alpha
    conversionQueue.async { [weak self] in
      let result: Result<CVPixelBuffer, Error> = Result {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
          let pixelBuffer
        else { throw HTMLVideoExportError.writer("Cannot allocate video frame.") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let space = HTMLPageSnapshot.colorSpace
        guard
          let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
              | CGImageAlphaInfo.premultipliedFirst.rawValue
          )
        else { throw HTMLVideoExportError.writer("Cannot create video pixel context.") }
        // The context produces sRGB pixels. Use the same transfer function on the
        // buffer and encoded track; tagging these pixels as BT.709 lifts midtones.
        CVBufferSetAttachments(
          pixelBuffer,
          [
            kCVImageBufferCGColorSpaceKey as String: space,
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_sRGB,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
          ] as CFDictionary, .shouldPropagate)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if alpha {
          context.clear(rect)
        } else {
          context.setFillColor(CGColor(gray: 0, alpha: 1))
          context.fill(rect)
        }
        try snapshot.draw(in: context, width: width, height: height)
        return pixelBuffer
      }
      DispatchQueue.main.async {
        guard let self, !self.finished else { return }
        do {
          self.pendingBuffer = try result.get()
          self.appendPendingFrame()
        } catch { self.finish(.failure(error)) }
      }
    }
  }

  private func appendPendingFrame() {
    guard !finished, let buffer = pendingBuffer, let input, let writer, let adaptor else { return }
    guard writer.status == .writing else {
      finish(.failure(writer.error ?? HTMLVideoExportError.writer("Encoder stopped.")))
      return
    }
    guard input.isReadyForMoreMediaData else { return }
    let time = CMTime(
      value: Int64(frame) * Int64(options.fpsDenominator), timescale: options.fpsNumerator)
    guard adaptor.append(buffer, withPresentationTime: time) else {
      finish(.failure(writer.error ?? HTMLVideoExportError.writer("Cannot append frame.")))
      return
    }
    pendingBuffer = nil
    frame += 1
    progress(frame, frames)
    nextFrame()
  }

  private func publish(_ output: URL) {
    do {
      // moveItem fails if another export created the destination; never overwrite user output.
      try FileManager.default.moveItem(at: output, to: options.output)
      finish(
        .success(
          HTMLVideoExportResult(
            output: options.output.path, width: width, height: height,
            frames: frames, fpsNumerator: options.fpsNumerator,
            fpsDenominator: options.fpsDenominator,
            duration: Double(frames) * Double(options.fpsDenominator) / Double(options.fpsNumerator)
          )))
    } catch { finish(.failure(error)) }
  }

  private func finish(_ result: Result<HTMLVideoExportResult, Error>) {
    guard !finished else { return }
    finished = true
    timer?.invalidate()
    timer = nil
    readiness = nil
    mediaBridge?.cancel()
    audioMixer?.cancel()
    webView?.configuration.userContentController.removeScriptMessageHandler(
      forName: "html2videoMedia", contentWorld: .page)
    webView?.navigationDelegate = nil
    webView?.stopLoading()
    webView?.removeFromSuperview()
    webView = nil
    if case .failure = result {
      writer?.cancelWriting()
    }
    pendingBuffer = nil
    if let mixedOutput { try? FileManager.default.removeItem(at: mixedOutput) }
    try? FileManager.default.removeItem(at: temporaryOutput)
    let completion = self.completion
    self.completion = nil
    if case .failure(let error) = result,
      let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
    {
      completion?(.failure(HTMLVideoExportError.browser(message)))
    } else {
      completion?(result)
    }
  }
}
