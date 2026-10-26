import Foundation

public enum ToolCallParser {
  public static func removeToolCalls(
    _ string: String, toolCallStart: String, toolCallEnd: String
  ) -> String {
    guard !toolCallStart.isEmpty, !toolCallEnd.isEmpty else { return string }
    var output = ""
    var index = string.startIndex
    while let startRange = string[index...].range(of: toolCallStart) {
      output += String(string[index..<startRange.lowerBound])
      guard let endRange = string[startRange.upperBound...].range(of: toolCallEnd) else {
        index = string.endIndex
        break
      }
      index = endRange.upperBound
    }
    output += String(string[index...])
    removeTrailingPartialDelimiter(
      &output, toolCallStart: toolCallStart, toolCallEnd: toolCallEnd)
    return output
  }

  // A multi-token delimiter can be split at the end of the response while streaming.
  // Only proper prefixes qualify; a complete orphan delimiter is malformed input.
  static func removeTrailingPartialDelimiter(
    _ output: inout String, toolCallStart: String, toolCallEnd: String
  ) {
    let maximumTrailingMatchLength = min(
      output.count, max(toolCallStart.count - 1, toolCallEnd.count - 1))
    if maximumTrailingMatchLength > 0 {
      for length in stride(from: maximumTrailingMatchLength, through: 1, by: -1) {
        let matchesStart =
          length < toolCallStart.count && output.hasSuffix(toolCallStart.prefix(length))
        let matchesEnd =
          length < toolCallEnd.count && output.hasSuffix(toolCallEnd.prefix(length))
        if matchesStart || matchesEnd {
          output.removeLast(length)
          break
        }
      }
    }
  }

}

public struct ToolCall: Codable, Sendable {
  public struct Request: Codable, Sendable {
    public struct Parameter: Codable, Sendable {
      public var string: Bool
      public var value: String

      public init(string: Bool, value: String) {
        self.string = string
        self.value = value
      }
    }

    public var function: String
    public var parameters: [String: Parameter]

    public init(function: String, parameters: [String: Parameter]) {
      self.function = function
      self.parameters = parameters
    }
  }

  public var id: Int32
  public var raw: String
  public var request: Request
  public var response: ToolResponse?
  /// Visible assistant text accompanying this call, shared by calls in the same generation.
  public var reason: String?

  public init(
    id: Int32, raw: String = "", request: Request, response: ToolResponse? = nil,
    reason: String? = nil
  ) {
    self.id = id
    self.raw = raw
    self.request = request
    self.response = response
    self.reason = reason
  }
}

/// A memory target's rendered entries, as a memory tool result showed them.
struct MemorySnapshot: Codable, Sendable, Equatable {
  /// `ProjectMemory.Target` raw value.
  var target: String
  var text: String
  /// Pre-write entries captured under the memory lock; nil for reads and no-op writes.
  var previousText: String? = nil
}

/// Ordered text and media, encoded as an array or a legacy text-only string. A response carrying
/// a memory snapshot is encoded as an object instead.
public struct ToolResponse: Codable, Sendable, Equatable {
  public enum Content: Codable, Sendable, Equatable {
    case text(String)
    case imageDigest(Data)
  }

  public var content: [Content]
  var memory: MemorySnapshot? = nil

  private enum CodingKeys: String, CodingKey {
    case content
    case memory
  }

  public init(_ content: [Content]) {
    self.content = content
  }

  public init(text: String) {
    content = [.text(text)]
  }

  init(text: String, memory: MemorySnapshot?) {
    content = [.text(text)]
    self.memory = memory
  }

  public init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: CodingKeys.self) {
      self.init(try container.decode([Content].self, forKey: .content))
      memory = try container.decodeIfPresent(MemorySnapshot.self, forKey: .memory)
      return
    }
    let container = try decoder.singleValueContainer()
    if let text = try? container.decode(String.self) {
      self.init(text: text)
    } else {
      self.init(try container.decode([Content].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    if let memory {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(content, forKey: .content)
      try container.encode(memory, forKey: .memory)
      return
    }
    var container = encoder.singleValueContainer()
    if content.count == 1, case .text(let text) = content[0] {
      try container.encode(text)
    } else {
      try container.encode(content)
    }
  }
}
