import Foundation

public struct OpenAICompatibleConfiguration: Equatable, Sendable {
  public let baseURL: URL
  public let model: String
  public let maximumRequestBytes: Int
  public let maximumEventBytes: Int
  public let maximumErrorBytes: Int
  public let maximumOutputTokens: Int
  public let includeUsageInStream: Bool
  let usesMaxCompletionTokens: Bool
  let supportsReasoningMessageFields: Bool
  let preservesReasoningAcrossTurns: Bool

  public init(
    baseURL: URL, model: String, maximumRequestBytes: Int? = nil,
    maximumEventBytes: Int = 1 * 1_024 * 1_024, maximumErrorBytes: Int = 64 * 1_024,
    maximumOutputTokens: Int = 8_192, includeUsageInStream: Bool? = nil
  ) throws {
    let normalizedBaseURL = try RemoteEndpointURL.normalizedBaseURL(baseURL, allowsLocalHTTP: true)
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw RemoteChatError.missingModel }
    self.baseURL = normalizedBaseURL
    self.model = model
    // Room for base64 images, which are each up to RemoteImage.maximumBytes before encoding.
    self.maximumRequestBytes = max(1, maximumRequestBytes ?? 32 * 1_024 * 1_024)
    self.maximumEventBytes = max(1, maximumEventBytes)
    self.maximumErrorBytes = max(1, maximumErrorBytes)
    self.maximumOutputTokens = max(1, maximumOutputTokens)
    let host = normalizedBaseURL.host?.lowercased() ?? ""
    usesMaxCompletionTokens = ["api.openai.com", "openrouter.ai"].contains(host)
    supportsReasoningMessageFields = host != "api.openai.com"
    preservesReasoningAcrossTurns = host == "openrouter.ai"
    self.includeUsageInStream =
      includeUsageInStream ?? usesMaxCompletionTokens
  }

  public var endpointURL: URL {
    let versionedBaseURL = RemoteEndpointURL.openAICompatibleAPIBaseURL(baseURL)
    return versionedBaseURL.appendingPathComponent("chat/completions", isDirectory: false)
  }

  public var responsesEndpointURL: URL {
    let versionedBaseURL = RemoteEndpointURL.openAICompatibleAPIBaseURL(baseURL)
    return versionedBaseURL.appendingPathComponent("responses", isDirectory: false)
  }
}
