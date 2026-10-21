import Foundation

// Generated in another file; both stored fields are Sendable value types.
extension MemoryContext: @unchecked Sendable {}

// Suspended turns keep their memory contexts in JSON.
extension MemoryContext: Codable {
  private enum CodingKeys: String, CodingKey {
    case user
    case memory
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      user: try container.decodeIfPresent(String.self, forKey: .user),
      memory: try container.decodeIfPresent(String.self, forKey: .memory))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(user, forKey: .user)
    try container.encodeIfPresent(memory, forKey: .memory)
  }
}
