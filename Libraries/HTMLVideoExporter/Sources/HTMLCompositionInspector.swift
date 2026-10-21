import AVFoundation
import CoreText
import Foundation
import ImageIO
import QuartzCore
import WebKit

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// A seekable page shared by the HyperFrames audit and snapshot commands.
/// All methods and completions run on the main queue, like HTMLVideoExporter.
public final class HTMLCompositionInspector {
  private final class ObjCResponder: NSObject, WKNavigationDelegate {
    weak var owner: HTMLCompositionInspector?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { owner?.prepare() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      owner?.completeLoad(.failure(error))
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      owner?.completeLoad(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      owner?.completeLoad(.failure(HTMLVideoExportError.browser("Web content process terminated.")))
    }
  }
  private let responder = ObjCResponder()
  private var webView: WKWebView?
  private var temporaryFile: URL?
  private var completion: ((Result<Any, Error>) -> Void)?
  private var timer: Timer?
  private var preparing = false

  public init() { responder.owner = self }

  public func close() {
    dispatchPrecondition(condition: .onQueue(.main))
    timer?.invalidate()
    timer = nil
    webView?.stopLoading()
    webView?.configuration.userContentController.removeAllScriptMessageHandlers()
    webView?.navigationDelegate = nil
    webView?.removeFromSuperview()
    webView = nil
    if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
    temporaryFile = nil
    completeLoad(.failure(HTMLVideoExportError.cancelled))
  }

  public func load(
    directory: URL, html: String, timeout: Double,
    completion: @escaping (Result<Any, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    close()
    self.completion = completion
    preparing = false
    do {
      let file = directory.appendingPathComponent(".hyperframes-inspect-\(UUID().uuidString).html")
      try html.write(to: file, atomically: true, encoding: .utf8)
      temporaryFile = file
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.mediaTypesRequiringUserActionForPlayback = .all
      configuration.userContentController.addScriptMessageHandler(
        HTMLVideoMediaBridge(directory: directory), contentWorld: .page, name: "html2videoMedia")
      configuration.userContentController.addUserScript(
        WKUserScript(
          source: HTMLVideoPage.bootstrap + "\n" + Self.auditBootstrap,
          injectionTime: .atDocumentStart, forMainFrameOnly: true))
      let view = WKWebView(
        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: configuration)
      webView = view
      view.navigationDelegate = responder
      view.underPageBackgroundColor = .clear
      #if canImport(UIKit)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          .flatMap(\.windows).first { $0.isKeyWindow }?.rootViewController?.view.addSubview(view)
        view.isHidden = true
      #endif
      let deadline = CACurrentMediaTime() + timeout
      let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        guard CACurrentMediaTime() >= deadline else { return }
        self?.completeLoad(.failure(HTMLVideoExportError.timeout))
      }
      self.timer = timer
      RunLoop.main.add(timer, forMode: .common)
      HTMLVideoPage.initialViewport(html, in: view) { [weak self] result in
        guard let self, self.webView === view, self.completion != nil else { return }
        do {
          view.frame.size = try result.get()
          view.loadFileURL(file, allowingReadAccessTo: directory)
        } catch { self.completeLoad(.failure(error)) }
      }
    } catch { completeLoad(.failure(error)) }
  }

  private func completeLoad(_ result: Result<Any, Error>) {
    guard let completion else { return }
    self.completion = nil
    timer?.invalidate()
    timer = nil
    completion(result)
  }

  private func prepare() {
    guard !preparing, let webView else { return }
    preparing = true
    webView.callAsyncJavaScript(
      HTMLVideoPage.prepare,
      arguments: ["requestedWidth": 0, "requestedHeight": 0, "requestedDuration": 0], in: nil,
      in: .page
    ) { [weak self] result in
      guard let self else { return }
      do {
        guard let metadata = try result.get() as? [String: Any],
          let width = metadata["width"] as? Double, let height = metadata["height"] as? Double,
          width.isFinite, height.isFinite, (1...8192).contains(width), (1...8192).contains(height)
        else { throw HTMLVideoExportError.invalid("Invalid composition dimensions.") }
        webView.frame.size = CGSize(width: width, height: height)
        self.completeLoad(.success(metadata))
      } catch { self.completeLoad(.failure(error)) }
    }
  }

  public func evaluate(
    _ source: String, arguments: [String: Any] = [:],
    completion: @escaping (Result<Any, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let webView else {
      completion(.failure(HTMLVideoExportError.browser("No composition loaded.")))
      return
    }
    webView.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { result in
      completion(result)
    }
  }

  public func seek(_ time: Double, completion: @escaping (Result<Any, Error>) -> Void) {
    evaluate(
      "window.__hyperframesAuditTime = seconds; await window.__html2videoSeek(seconds); return true;",
      arguments: ["seconds": time], completion: completion)
  }

  public func snapshot(
    zoom: String?, scale: Double, completion: @escaping (Result<Any, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let webView else {
      completion(.failure(HTMLVideoExportError.browser("No composition loaded.")))
      return
    }
    guard scale.isFinite, (1...8).contains(scale) else {
      completion(.failure(HTMLVideoExportError.invalid("Invalid snapshot scale.")))
      return
    }
    let capture: (CGRect) -> Void = { rect in
      let rect = rect.intersection(webView.bounds)
      guard !rect.isNull, rect.width > 0, rect.height > 0 else {
        completion(.success(NSNull()))
        return
      }
      guard rect.width * scale <= 16384, rect.height * scale <= 16384 else {
        completion(
          .failure(HTMLVideoExportError.invalid("Snapshot exceeds 16384 pixels per side.")))
        return
      }
      HTMLPageSnapshot.capture(
        webView, rect: rect, pixelWidth: rect.width * scale, preservingAlpha: true
      ) { result in
        do {
          let png = try Self.png(
            try result.get(), width: Int((rect.width * scale).rounded()),
            height: Int((rect.height * scale).rounded()))
          completion(.success(png.base64EncodedString()))
        } catch { completion(.failure(error)) }
      }
    }
    guard let zoom else {
      capture(webView.bounds)
      return
    }
    let numbers = zoom.split(separator: ",", omittingEmptySubsequences: false).compactMap {
      Double($0.trimmingCharacters(in: .whitespaces))
    }
    if numbers.count == 4 {
      guard numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else {
        completion(.failure(HTMLVideoExportError.invalid("Invalid zoom rectangle.")))
        return
      }
      capture(CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
    } else {
      evaluate(
        "const element = document.querySelector(selector); if (!element) throw new Error('Zoom selector not found: ' + selector); for (let node=element;node;node=node.parentElement) { const style=getComputedStyle(node); if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return {x:0,y:0,width:0,height:0}; } const r=element.getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height};",
        arguments: ["selector": zoom]
      ) { result in
        do {
          guard let rect = try result.get() as? [String: Double], let x = rect["x"],
            let y = rect["y"], let w = rect["width"], let h = rect["height"]
          else { throw HTMLVideoExportError.invalid("Invalid zoom bounds.") }
          capture(CGRect(x: x, y: y, width: w, height: h))
        } catch { completion(.failure(error)) }
      }
    }
  }

  private static func png(_ snapshot: HTMLPageSnapshot, width: Int, height: Int) throws -> Data {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: HTMLPageSnapshot.colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw HTMLVideoExportError.invalid("Cannot allocate snapshot.") }
    try snapshot.draw(in: context, width: width, height: height)
    guard let image = context.makeImage() else {
      throw HTMLVideoExportError.invalid("Cannot create snapshot.")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { throw HTMLVideoExportError.invalid("Cannot encode PNG.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw HTMLVideoExportError.invalid("Cannot finish PNG.")
    }
    return data as Data
  }

  public static func contactSheet(images: [String], times: [Double]) throws -> String {
    guard !images.isEmpty, images.count <= 100 else {
      throw HTMLVideoExportError.invalid("Invalid contact sheet image count.")
    }
    let columns = min(3, images.count)
    let cellWidth = 480
    let cellHeight = 300
    let width = columns * cellWidth
    let height = ((images.count + columns - 1) / columns) * cellHeight
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: HTMLPageSnapshot.colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw HTMLVideoExportError.invalid("Cannot allocate contact sheet.") }
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for (index, encoded) in images.enumerated() {
      guard let data = Data(base64Encoded: encoded),
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { throw HTMLVideoExportError.invalid("Invalid contact sheet image.") }
      let x = index % columns * cellWidth
      let y = height - (index / columns + 1) * cellHeight
      let scale = min(
        Double(cellWidth - 16) / Double(image.width), Double(cellHeight - 40) / Double(image.height)
      )
      let w = Double(image.width) * scale
      let h = Double(image.height) * scale
      context.draw(
        image,
        in: CGRect(
          x: Double(x) + (Double(cellWidth) - w) / 2, y: Double(y) + 32, width: w, height: h))
      let label = String(format: "%.3f s", index < times.count ? times[index] : 0)
      let text = NSAttributedString(
        string: label,
        attributes: [
          kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName(
            "Helvetica" as CFString, 15, nil),
          kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1),
        ])
      context.textPosition = CGPoint(x: x + 12, y: y + 10)
      CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    guard let image = context.makeImage() else {
      throw HTMLVideoExportError.invalid("Cannot create contact sheet.")
    }
    return try png(.image(image), width: width, height: height).base64EncodedString()
  }

  private static let auditBootstrap = #"""
    window.__hfVariables = {};
    window.__hyperframesNativeFindings = [];
    const record = (code, message, url) => window.__hyperframesNativeFindings.push({code,severity:'error',message:String(message),url,selector:'[data-composition-id]',dataAttributes:{},sourceFile:'index.html',bbox:{x:0,y:0,width:0,height:0},time:window.__hyperframesAuditTime || 0});
    addEventListener('error', event => { if (event.target !== window) record('request_failed','Failed to load resource', event.target.src || event.target.href); else record('runtime_error',event.message,event.filename); }, true);
    addEventListener('unhandledrejection', event => record('runtime_error',event.reason));
    const originalError = console.error.bind(console);
    console.error = (...args) => { record('runtime_error',args.join(' ')); originalError(...args); };
    const originalFetch = window.fetch;
    window.fetch = async (...args) => {
      try { const response = await originalFetch(...args); if (!response.ok) record('http_error', 'HTTP ' + response.status, response.url); return response; }
      catch (error) { record('request_failed',error,args[0]?.url || String(args[0])); throw error; }
    };
    const originalSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function(...args) {
      this.addEventListener('loadend', () => { if (this.status >= 400 || this.status === 0) record('http_error','HTTP ' + this.status,this.responseURL); });
      return originalSend.apply(this,args);
    };
    """#
}
