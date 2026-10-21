import CryptoKit
import Foundation
import Yams

enum SystemPromptTemplate {
  private static let fileNamePrefix = "templated_system_prompt_"
  private static let fileNameSuffix = ".md"
  private static let maximumFileNameByteCount = 255

  static func load(
    projectURL: URL?, model: String, template: String
  ) -> String {
    guard let projectURL else { return template }
    let fileURL = fileURL(projectURL: projectURL, model: model)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      try? write(template, model: model, to: fileURL)
      return template
    }

    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
      return template
    }
    let document = parse(contents)
    let bodyHash = sha256(document.body)
    guard document.sha256?.lowercased() == bodyHash else {
      return document.body
    }
    guard document.body != template || document.model != model else {
      return document.body
    }
    try? write(template, model: model, to: fileURL)
    return template
  }

  static func fileURL(projectURL: URL, model: String) -> URL {
    projectURL
      .appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent(fileName(model: model), isDirectory: false)
  }

  static func fileName(model: String) -> String {
    let encodedSegments = model.utf8.map { byte -> String in
      switch byte {
      case 45, 46, 48...57, 65...90, 95, 97...122:
        return String(UnicodeScalar(byte))
      default:
        return String(format: "%%%02X", byte)
      }
    }
    let encodedModel = encodedSegments.joined()
    let fileName = fileNamePrefix + encodedModel + fileNameSuffix
    guard fileName.utf8.count > maximumFileNameByteCount else { return fileName }

    let digest = sha256(model)
    let digestSuffix = "_\(digest)"
    let encodedModelByteLimit =
      maximumFileNameByteCount - fileNamePrefix.utf8.count - digestSuffix.utf8.count
      - fileNameSuffix.utf8.count
    var truncatedModel = ""
    for segment in encodedSegments {
      guard truncatedModel.utf8.count + segment.utf8.count <= encodedModelByteLimit else {
        break
      }
      truncatedModel += segment
    }
    return fileNamePrefix + truncatedModel + digestSuffix + fileNameSuffix
  }

  private static func write(_ body: String, model: String, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let encodedModel = try encoder.encode(model)
    guard let quotedModel = String(data: encodedModel, encoding: .utf8) else {
      throw SystemPromptTemplateError.invalidModel
    }
    let contents =
      "---\nmodel: \(quotedModel)\nsha256: \"\(sha256(body))\"\n---\n" + body
    try Data(contents.utf8).write(to: fileURL, options: .atomic)
  }

  private static func parse(_ contents: String) -> (
    model: String?, sha256: String?, body: String
  ) {
    var contentsWithoutBOM = contents
    if contentsWithoutBOM.hasPrefix("\u{feff}") {
      contentsWithoutBOM.removeFirst()
    }
    guard let firstLineEnd = contentsWithoutBOM.firstIndex(of: "\n"),
      contentsWithoutBOM[..<firstLineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        == "---"
    else { return (nil, nil, contents) }

    let yamlStart = contentsWithoutBOM.index(after: firstLineEnd)
    var lineStart = yamlStart
    while lineStart <= contentsWithoutBOM.endIndex {
      let lineEnd =
        contentsWithoutBOM[lineStart...].firstIndex(of: "\n")
        ?? contentsWithoutBOM.endIndex
      let line = contentsWithoutBOM[lineStart..<lineEnd]
      if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
        let yaml = String(contentsWithoutBOM[yamlStart..<lineStart])
        let bodyStart =
          lineEnd < contentsWithoutBOM.endIndex
          ? contentsWithoutBOM.index(after: lineEnd) : contentsWithoutBOM.endIndex
        let body = String(contentsWithoutBOM[bodyStart...])
        guard let metadata = try? Yams.load(yaml: yaml) as? [String: Any] else {
          return (nil, nil, body)
        }
        return (metadata["model"] as? String, metadata["sha256"] as? String, body)
      }
      guard lineEnd < contentsWithoutBOM.endIndex else { break }
      lineStart = contentsWithoutBOM.index(after: lineEnd)
    }
    return (nil, nil, contents)
  }

  private static func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

private enum SystemPromptTemplateError: LocalizedError {
  case invalidModel

  var errorDescription: String? {
    switch self {
    case .invalidModel:
      return "The model identifier could not be encoded."
    }
  }
}
