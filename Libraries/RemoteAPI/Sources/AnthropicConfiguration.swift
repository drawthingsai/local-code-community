import Foundation

public struct AnthropicConfiguration: Equatable, Sendable {
  public static let defaultBaseURL = URL(string: "https://api.anthropic.com/v1")!

  public let baseURL: URL
  public let model: String
  public let maximumOutputTokens: Int
  public let maximumRequestBytes: Int
  public let maximumEventBytes: Int
  public let maximumErrorBytes: Int

  public init(
    model: String, baseURL: URL = AnthropicConfiguration.defaultBaseURL,
    maximumOutputTokens: Int = 8_192, maximumRequestBytes: Int = 2 * 1_024 * 1_024,
    maximumEventBytes: Int = 1 * 1_024 * 1_024, maximumErrorBytes: Int = 64 * 1_024
  ) throws {
    let normalizedBaseURL = try RemoteEndpointURL.normalizedBaseURL(baseURL)
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw RemoteChatError.missingModel }
    self.baseURL = normalizedBaseURL
    self.model = model
    self.maximumOutputTokens = max(1, maximumOutputTokens)
    self.maximumRequestBytes = max(1, maximumRequestBytes)
    self.maximumEventBytes = max(1, maximumEventBytes)
    self.maximumErrorBytes = max(1, maximumErrorBytes)
  }

  public var endpointURL: URL {
    baseURL.appendingPathComponent("messages", isDirectory: false)
  }
}
