import Foundation

public enum HTMLVideoExportError: LocalizedError {
  case invalid(String)
  case cancelled
  case timeout
  case browser(String)
  case writer(String)

  public var errorDescription: String? {
    switch self {
    case .invalid(let message), .browser(let message), .writer(let message): return message
    case .cancelled: return "HTML video export cancelled."
    case .timeout: return "HTML video export timed out waiting for the page or encoder."
    }
  }
}

public struct HTMLVideoExportOptions {
  public let input: URL
  public let output: URL
  public let format: String
  public let alpha: Bool
  public let width: Int?
  public let height: Int?
  public let duration: Double?
  public let fpsNumerator: Int32
  public let fpsDenominator: Int32
  public let timeout: TimeInterval
  public let variables: [String: Any]

  public init(
    input: URL, output: URL, width: Int? = nil, height: Int? = nil,
    duration: Double? = nil, fps: String = "30", timeout: TimeInterval = 60,
    variables: [String: Any] = [:], format: String? = nil, alpha: Bool = false
  ) throws {
    let rate = fps.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(rate.count), let numerator = Int32(rate[0]), numerator > 0,
      let denominator = rate.count == 2 ? Int32(rate[1]) : 1, denominator > 0,
      Double(numerator) / Double(denominator) <= 240
    else { throw HTMLVideoExportError.invalid("--fps must be an integer or fraction in (0, 240].") }
    guard timeout.isFinite, timeout > 0 else {
      throw HTMLVideoExportError.invalid("--timeout must be a positive number of seconds.")
    }
    if let duration, !duration.isFinite || duration <= 0 || duration > 86400 {
      throw HTMLVideoExportError.invalid("--duration must be in (0, 86400] seconds.")
    }
    for size in [width, height].compactMap({ $0 }) where size < 2 || size > 8192 || size % 2 != 0 {
      throw HTMLVideoExportError.invalid("Video dimensions must be even integers from 2 to 8192.")
    }
    guard input.isFileURL, output.isFileURL else {
      throw HTMLVideoExportError.invalid("Input and output must be local file paths.")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
      throw HTMLVideoExportError.invalid("Input does not exist: \(input.path)")
    }
    let page = isDirectory.boolValue ? input.appendingPathComponent("index.html") : input
    guard FileManager.default.isReadableFile(atPath: page.path),
      ["html", "htm"].contains(page.pathExtension.lowercased())
    else {
      throw HTMLVideoExportError.invalid(
        "Input must be an HTML file or a project containing index.html.")
    }
    let format = format ?? output.pathExtension.lowercased()
    guard ["mp4", "mov"].contains(format), output.pathExtension.lowercased() == format else {
      throw HTMLVideoExportError.invalid(
        "Use --format mp4 or mov with a matching output extension.")
    }
    guard !alpha || format == "mov" else {
      throw HTMLVideoExportError.invalid(
        "--alpha requires MOV output (--format mov --output overlay.mov).")
    }
    #if !canImport(UIKit)
      if alpha {
        guard #available(macOS 14.0, *) else {
          throw HTMLVideoExportError.invalid(
            "Transparent WebKit capture requires macOS 14 or later.")
        }
      }
    #endif
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw HTMLVideoExportError.invalid("Output already exists: \(output.path)")
    }
    self.input = page.standardizedFileURL.resolvingSymlinksInPath()
    self.output = output.standardizedFileURL
    self.format = format
    self.alpha = alpha
    self.width = width
    self.height = height
    self.duration = duration
    self.fpsNumerator = numerator
    self.fpsDenominator = denominator
    self.timeout = timeout
    self.variables = variables
  }
}

public struct HTMLVideoExportResult: Codable {
  public let output: String
  public let width: Int
  public let height: Int
  public let frames: Int
  public let fpsNumerator: Int32
  public let fpsDenominator: Int32
  public let duration: Double
}
