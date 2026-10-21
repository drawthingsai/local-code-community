import Foundation

extension EmbedKind: Codable {}

// Generated in another file; all stored fields are Sendable value types.
extension EmbedKind: @unchecked Sendable {}
extension EmbedSpan: @unchecked Sendable {}

extension EmbedSpan: Codable {
  private enum CodingKeys: String, CodingKey { case start, length, digest, kind }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      start: try container.decode(Int64.self, forKey: .start),
      length: try container.decode(Int64.self, forKey: .length),
      digest: Array(try container.decode(Data.self, forKey: .digest)),
      kind: try container.decode(EmbedKind.self, forKey: .kind))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(start, forKey: .start)
    try container.encode(length, forKey: .length)
    // Preserve the base64 digest representation used by saved CLI sessions.
    try container.encode(Data(digest), forKey: .digest)
    try container.encode(kind, forKey: .kind)
  }
}

extension EmbedSpan {
  public var end: Int64 { start + length }

  public func offset(by offset: Int) -> Self {
    Self(start: start + Int64(offset), length: length, digest: digest, kind: kind)
  }

  /// Retain complete media spans and rebase them to a slice of the token stream.
  public static func slice(_ spans: [Self], range: Range<Int>) -> [Self] {
    spans.compactMap { span in
      guard span.start < range.upperBound && span.end > range.lowerBound else { return nil }
      precondition(span.start >= range.lowerBound && span.end <= range.upperBound)
      return span.offset(by: -range.lowerBound)
    }
  }

  /// Update positions when text is inserted, removed, or replaced between media spans.
  public static func replacingTokens(
    _ spans: [Self], range: Range<Int>, replacementCount: Int
  ) -> [Self] {
    spans.map { span in
      if span.end <= range.lowerBound { return span }
      precondition(span.start >= range.upperBound)
      return span.offset(by: replacementCount - range.count)
    }
  }
}
