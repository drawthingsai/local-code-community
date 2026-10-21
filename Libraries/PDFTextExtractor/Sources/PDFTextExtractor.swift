import CPDFInspector
import Foundation

public enum PDFTextExtractor {
  public struct Page {
    public var number: Int
    public var markdown: String
    public var needsOCR: Bool
  }

  public enum ExtractionError: LocalizedError {
    case encrypted
    case failed(String)

    public var errorDescription: String? {
      switch self {
      case .encrypted: return "PDF requires a password or uses unsupported encryption."
      case .failed(let message): return message
      }
    }
  }

  private final class Result {
    var pages = [Page]()
    var error = "Could not extract PDF text."
  }

  /// Converts locally without OCR. The caller owns scheduling and password prompting.
  public static func extract(_ data: Data, password: String? = nil) throws -> [Page] {
    let result = Result()
    let passwordBytes = password.map { Array($0.utf8) }
    let status = data.withUnsafeBytes { bytes in
      func extract(_ password: UnsafePointer<UInt8>?, count: Int) -> Int32 {
        pdf_inspector_extract(
          bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, password, count,
          Unmanaged.passUnretained(result).toOpaque(),
          { context, page, bytes, count, needsOCR in
            let result = Unmanaged<Result>.fromOpaque(context!).takeUnretainedValue()
            result.pages.append(
              Page(
                number: Int(page),
                markdown: String(
                  decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self),
                needsOCR: needsOCR))
          },
          { context, bytes, count in
            let result = Unmanaged<Result>.fromOpaque(context!).takeUnretainedValue()
            result.error = String(
              decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
          })
      }
      if let passwordBytes {
        return passwordBytes.withUnsafeBufferPointer { extract($0.baseAddress, count: $0.count) }
      }
      return extract(nil, count: 0)
    }
    switch Int(status) {
    case PDF_INSPECTOR_OK: return result.pages
    case PDF_INSPECTOR_ENCRYPTED: throw ExtractionError.encrypted
    default: throw ExtractionError.failed(result.error)
    }
  }
}
