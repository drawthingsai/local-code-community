import Foundation
import Localization

#if canImport(Z3Bridge)
  import Z3Bridge
#endif

private let checkSmtMaximumInputBytes = 128 * 1024
private let checkSmtMaximumOutputBytes = 32 * 1024
private let checkSmtTimeoutMilliseconds: UInt32 = 5_000

private enum CheckSmtStatus: String {
  case sat
  case unsat
  case unknown
  case timeout
  case error
}

private enum CheckSmtCommandPolicy {
  private static let allowedCommands: Set<String> = [
    "assert",
    "declare-const",
    "declare-datatype",
    "declare-datatypes",
    "declare-fun",
    "declare-sort",
    "define-fun",
    "define-fun-rec",
    "define-funs-rec",
    "define-sort",
    "set-logic",
  ]

  static func validationError(for code: String) -> String? {
    let bytes = Array(code.utf8)
    var index = 0
    var commandCount = 0
    skipTrivia(in: bytes, index: &index)
    while index < bytes.count {
      guard bytes[index] == 40 else {
        return "SMT-LIB input must contain only top-level commands."
      }
      index += 1
      skipTrivia(in: bytes, index: &index)
      let commandStart = index
      while index < bytes.count, !isTokenDelimiter(bytes[index]) {
        index += 1
      }
      guard commandStart < index else {
        return "Each SMT-LIB command must start with a command name."
      }
      let command = String(decoding: bytes[commandStart..<index], as: UTF8.self)
      guard allowedCommands.contains(command) else {
        return
          "SMT-LIB command '\(command)' is not allowed. Submit declarations, definitions, and assertions only; the runtime performs check-sat and model extraction."
      }

      var depth = 1
      while index < bytes.count, depth > 0 {
        switch bytes[index] {
        case 59:
          skipComment(in: bytes, index: &index)
        case 34:
          guard skipString(in: bytes, index: &index) else {
            return "SMT-LIB input contains an unterminated string."
          }
        case 124:
          guard skipQuotedSymbol(in: bytes, index: &index) else {
            return "SMT-LIB input contains an unterminated quoted symbol."
          }
        case 40:
          depth += 1
          index += 1
        case 41:
          depth -= 1
          index += 1
        default:
          index += 1
        }
      }
      guard depth == 0 else {
        return "SMT-LIB input contains unbalanced parentheses."
      }
      commandCount += 1
      skipTrivia(in: bytes, index: &index)
    }
    return commandCount == 0 ? "SMT-LIB input is empty." : nil
  }

  private static func skipTrivia(in bytes: [UInt8], index: inout Int) {
    while index < bytes.count {
      if isWhitespace(bytes[index]) {
        index += 1
      } else if bytes[index] == 59 {
        skipComment(in: bytes, index: &index)
      } else {
        return
      }
    }
  }

  private static func skipComment(in bytes: [UInt8], index: inout Int) {
    while index < bytes.count, bytes[index] != 10, bytes[index] != 13 {
      index += 1
    }
  }

  private static func skipString(in bytes: [UInt8], index: inout Int) -> Bool {
    index += 1
    while index < bytes.count {
      guard bytes[index] == 34 else {
        index += 1
        continue
      }
      if index + 1 < bytes.count, bytes[index + 1] == 34 {
        index += 2
      } else {
        index += 1
        return true
      }
    }
    return false
  }

  private static func skipQuotedSymbol(in bytes: [UInt8], index: inout Int) -> Bool {
    index += 1
    while index < bytes.count {
      if bytes[index] == 92, index + 1 < bytes.count {
        index += 2
      } else if bytes[index] == 124 {
        index += 1
        return true
      } else {
        index += 1
      }
    }
    return false
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 9 || byte == 10 || byte == 13 || byte == 32
  }

  private static func isTokenDelimiter(_ byte: UInt8) -> Bool {
    isWhitespace(byte) || byte == 40 || byte == 41 || byte == 59
  }
}

public struct CheckSmtTool {
  public var code: String

  public func subtitle(for moment: ToolSubtitleMoment) -> String {
    let title: String
    switch moment {
    case .now:
      title = LocalizedString.forKey("tool_check_smt_now")
    case .past:
      title = LocalizedString.forKey("tool_check_smt_past")
    }
    let program = code.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = program.components(separatedBy: .newlines)
    switch moment {
    case .now where lines.count > 1:
      return "**\(title)**: \n```\n\(program)\n```"
    case .past where lines.count > 1:
      return "**\(title)**: `\(lines[0])...`"
    default:
      return "**\(title)**: `\(program)`"
    }
  }

  public static func parse(_ request: ToolCall.Request) -> CheckSmtTool? {
    guard request.parameters.keys.count == 1,
      let parameter = request.parameters["code"], parameter.string
    else { return nil }
    return CheckSmtTool(code: parameter.value)
  }

  public func invoke(completion: @escaping (String) -> Void) {
    guard code.utf8.count <= checkSmtMaximumInputBytes else {
      completion(
        render(
          status: .error,
          reason: "SMT-LIB input exceeds the 128 KiB limit."))
      return
    }
    if let validationError = CheckSmtCommandPolicy.validationError(for: code) {
      completion(render(status: .error, reason: validationError))
      return
    }

    #if canImport(Z3Bridge)
      let bridgeResult = code.withCString {
        Z3BridgeCheckSMT($0, checkSmtTimeoutMilliseconds)
      }
      defer { Z3BridgeFreeResult(bridgeResult) }
      let status: CheckSmtStatus
      switch bridgeResult.status {
      case Z3BridgeStatusSat:
        status = .sat
      case Z3BridgeStatusUnsat:
        status = .unsat
      case Z3BridgeStatusUnknown:
        status = .unknown
      case Z3BridgeStatusTimeout:
        status = .timeout
      default:
        status = .error
      }
      completion(
        render(
          status: status,
          model: bridgeResult.model.map { String(cString: $0) },
          reason: bridgeResult.reason.map { String(cString: $0) }))
    #else
      completion(
        render(
          status: .error,
          reason: "The Z3 backend is unavailable in this build."))
    #endif
  }

  private func render(
    status: CheckSmtStatus, model: String? = nil, reason: String? = nil
  ) -> String {
    var sections = ["status: \(status.rawValue)"]
    for (label, value, maximumBytes) in [
      ("model", model, 24 * 1024),
      ("reason", reason, 4 * 1024),
    ] {
      guard let value, !value.isEmpty else { continue }
      let truncated = truncate(value, maximumBytes: maximumBytes)
      let indented = truncated.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "  \($0)" }.joined(separator: "\n")
      sections.append("\(label):\n\(indented)")
    }
    return truncate(
      sections.joined(separator: "\n"), maximumBytes: checkSmtMaximumOutputBytes)
  }

  private func truncate(_ value: String, maximumBytes: Int) -> String {
    let bytes = Array(value.utf8)
    guard bytes.count > maximumBytes else { return value }
    let marker = Array("\n...[truncated]".utf8)
    guard maximumBytes > marker.count else {
      return String(decoding: marker.prefix(maximumBytes), as: UTF8.self)
    }
    var prefix = Array(bytes.prefix(maximumBytes - marker.count))
    while String(bytes: prefix, encoding: .utf8) == nil {
      prefix.removeLast()
    }
    return String(decoding: prefix + marker, as: UTF8.self)
  }
}
