import Foundation
import WebKit

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

/// The common browser capture and color-conversion boundary for PNG and video output.
/// Captures rasterize at the requested density without changing the page's layout viewport.
enum HTMLPageSnapshot {
  case image(CGImage)
  case pdf(Data)

  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

  static func capture(
    _ webView: WKWebView, rect: CGRect, pixelWidth: Double, preservingAlpha: Bool,
    completion: @escaping (Result<HTMLPageSnapshot, Error>) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    #if !canImport(UIKit)
      // AppKit snapshots paint an opaque backdrop. The public PDF API preserves
      // the composited alpha, including Canvas/WebGL, in screen media.
      if preservingAlpha {
        guard #available(macOS 14.0, *) else {
          completion(
            .failure(
              HTMLVideoExportError.invalid("Transparent capture requires macOS 14 or later.")))
          return
        }
        let config = WKPDFConfiguration()
        config.rect = rect
        config.allowTransparentBackground = true
        webView.createPDF(configuration: config) { completion($0.map { .pdf($0) }) }
        return
      }
    #endif
    let config = WKSnapshotConfiguration()
    config.rect = rect
    #if canImport(UIKit)
      config.snapshotWidth = NSNumber(
        value: pixelWidth / Double(webView.traitCollection.displayScale))
    #else
      config.snapshotWidth = NSNumber(value: pixelWidth)
    #endif
    config.afterScreenUpdates = true
    webView.takeSnapshot(with: config) { image, error in
      #if canImport(UIKit)
        let cgImage = image?.cgImage
      #else
        let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
      #endif
      guard let cgImage else {
        completion(.failure(error ?? HTMLVideoExportError.browser("WebKit returned no snapshot.")))
        return
      }
      completion(.success(.image(cgImage)))
    }
  }

  /// The caller supplies an sRGB context, backed by PNG pixels or a video pixel buffer.
  func draw(in context: CGContext, width: Int, height: Int) throws {
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    switch self {
    case .image(let image): context.draw(image, in: rect)
    case .pdf(let data):
      guard let provider = CGDataProvider(data: data as CFData),
        let document = CGPDFDocument(provider), let page = document.page(at: 1)
      else { throw HTMLVideoExportError.browser("WebKit returned no PDF page.") }
      context.saveGState()
      let box = page.getBoxRect(.mediaBox)
      context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
      context.translateBy(x: -box.minX, y: -box.minY)
      context.drawPDFPage(page)
      context.restoreGState()
    }
  }
}
