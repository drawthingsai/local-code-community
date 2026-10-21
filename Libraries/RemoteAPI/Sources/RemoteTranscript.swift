import Foundation

public struct RemoteModelIdentity: Equatable, Sendable, Codable {
  public var provider: String
  public var model: String

  public init(provider: String, model: String) {
    self.provider = provider
    self.model = model
  }
}

public struct RemoteToolCall: Equatable, Sendable, Codable {
  public var id: String
  public var name: String
  public var arguments: String
  public var providerMetadata: [RemoteJSONValue]?

  public init(
    id: String, name: String, arguments: String,
    providerMetadata: [RemoteJSONValue]? = nil
  ) {
    self.id = id
    self.name = name
    self.arguments = arguments
    self.providerMetadata = providerMetadata
  }
}

extension RemoteToolCall {
  var hasJSONObjectArguments: Bool {
    guard let data = arguments.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data)
    else { return false }
    return value is [String: Any]
  }
}

extension RemoteJSONValue {
  var isValidOpenRouterReasoningDetail: Bool {
    guard case .object(let object) = self,
      case .string(let type) = object["type"],
      let id = object["id"], id.isNullOrNonemptyString,
      case .string(let format) = object["format"],
      [
        "unknown", "openai-responses-v1", "azure-openai-responses-v1", "xai-responses-v1",
        "anthropic-claude-v1", "google-gemini-v1",
      ].contains(format)
    else { return false }
    if let index = object["index"] {
      guard case .number(let value) = index, value.isFinite, value >= 0,
        value.rounded(.towardZero) == value
      else { return false }
    }
    let commonKeys: Set<String> = ["type", "id", "format", "index"]
    switch type {
    case "reasoning.summary":
      guard Set(object.keys).isSubset(of: commonKeys.union(["summary"])),
        case .string = object["summary"]
      else { return false }
    case "reasoning.encrypted":
      guard Set(object.keys).isSubset(of: commonKeys.union(["data"])),
        case .string(let data) = object["data"], !data.isEmpty
      else { return false }
    case "reasoning.text":
      guard Set(object.keys).isSubset(of: commonKeys.union(["text", "signature"])),
        case .string = object["text"]
      else { return false }
      if let signature = object["signature"], !signature.isNullOrString {
        return false
      }
    default:
      return false
    }
    return true
  }

  private var isNullOrString: Bool {
    switch self {
    case .null, .string:
      return true
    default:
      return false
    }
  }

  private var isNullOrNonemptyString: Bool {
    switch self {
    case .null:
      return true
    case .string(let value):
      return !value.isEmpty
    default:
      return false
    }
  }
}

public struct RemoteToolResult: Equatable, Sendable, Codable {
  public var toolCallID: String
  public var toolName: String
  public var content: String
  public var images: [RemoteImage]
  public var isError: Bool

  public init(
    toolCallID: String, toolName: String, content: String, isError: Bool, images: [RemoteImage] = []
  ) {
    self.toolCallID = toolCallID
    self.toolName = toolName
    self.content = content
    self.images = images
    self.isError = isError
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallID, toolName, content, isError, images
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(String.self, forKey: .toolCallID)
    toolName = try container.decode(String.self, forKey: .toolName)
    content = try container.decode(String.self, forKey: .content)
    isError = try container.decode(Bool.self, forKey: .isError)
    images = try container.decodeIfPresent([RemoteImage].self, forKey: .images) ?? []
  }
}

public struct RemoteThinking: Equatable, Sendable, Codable {
  public var text: String?
  public var signature: String?
  public var redactedData: String?
  public var providerMetadata: [RemoteJSONValue]?

  public init(
    text: String? = nil, signature: String? = nil, redactedData: String? = nil,
    providerMetadata: [RemoteJSONValue]? = nil
  ) {
    self.text = text
    self.signature = signature
    self.redactedData = redactedData
    self.providerMetadata = providerMetadata
  }
}

public enum RemoteContentBlock: Equatable, Sendable, Codable {
  case text(String)
  case image(RemoteImage)
  case thinking(RemoteThinking)
  case toolCall(RemoteToolCall)
  case toolResult(RemoteToolResult)

  private enum BlockType: String, Codable {
    case text
    case image
    case thinking
    case toolCall = "tool_call"
    case toolResult = "tool_result"
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case image
    case thinking
    case toolCall = "tool_call"
    case toolResult = "tool_result"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(BlockType.self, forKey: .type) {
    case .text:
      self = .text(try container.decode(String.self, forKey: .text))
    case .image:
      self = .image(try container.decode(RemoteImage.self, forKey: .image))
    case .thinking:
      self = .thinking(try container.decode(RemoteThinking.self, forKey: .thinking))
    case .toolCall:
      self = .toolCall(try container.decode(RemoteToolCall.self, forKey: .toolCall))
    case .toolResult:
      self = .toolResult(try container.decode(RemoteToolResult.self, forKey: .toolResult))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode(BlockType.text, forKey: .type)
      try container.encode(text, forKey: .text)
    case .image(let image):
      try container.encode(BlockType.image, forKey: .type)
      try container.encode(image, forKey: .image)
    case .thinking(let thinking):
      try container.encode(BlockType.thinking, forKey: .type)
      try container.encode(thinking, forKey: .thinking)
    case .toolCall(let call):
      try container.encode(BlockType.toolCall, forKey: .type)
      try container.encode(call, forKey: .toolCall)
    case .toolResult(let result):
      try container.encode(BlockType.toolResult, forKey: .type)
      try container.encode(result, forKey: .toolResult)
    }
  }
}

extension Array where Element == RemoteContentBlock {
  var hasMeaningfulRemoteOutput: Bool {
    contains { block in
      switch block {
      case .text(let text):
        return !text.isEmpty
      case .image:
        return true
      case .thinking(let thinking):
        return thinking.text?.isEmpty == false || thinking.signature?.isEmpty == false
          || thinking.redactedData?.isEmpty == false || thinking.providerMetadata?.isEmpty == false
      case .toolCall(let call):
        return !call.id.isEmpty || !call.name.isEmpty || !call.arguments.isEmpty
      case .toolResult(let result):
        return !result.content.isEmpty || !result.images.isEmpty
      }
    }
  }

  var estimatedRemoteOutputBytes: Int {
    reduce(into: 0) { count, block in
      switch block {
      case .text(let text):
        count += text.utf8.count
      case .thinking(let thinking):
        count += thinking.text?.utf8.count ?? 0
      case .toolCall(let call):
        count += call.name.utf8.count + call.arguments.utf8.count
      case .toolResult, .image:
        break
      }
    }
  }

  var remoteText: String {
    compactMap { block in
      guard case .text(let text) = block else { return nil }
      return text
    }.joined()
  }

  var remoteThinking: [RemoteThinking] {
    compactMap { block in
      guard case .thinking(let thinking) = block else { return nil }
      return thinking
    }
  }

  var remoteToolCalls: [RemoteToolCall] {
    compactMap { block in
      guard case .toolCall(let call) = block else { return nil }
      return call
    }
  }

  var remoteToolResults: [RemoteToolResult] {
    compactMap { block in
      guard case .toolResult(let result) = block else { return nil }
      return result
    }
  }
}

public struct RemoteTranscriptEntry: Equatable, Sendable, Codable {
  public enum Role: String, Codable, Sendable {
    case system
    case user
    case assistant
    case toolResult = "tool_result"
  }

  public var role: Role
  public var content: [RemoteContentBlock]
  public var source: RemoteModelIdentity?
  public var providerOutputItems: [RemoteJSONValue]?

  public init(
    role: Role, content: [RemoteContentBlock], source: RemoteModelIdentity? = nil,
    providerOutputItems: [RemoteJSONValue]? = nil
  ) {
    self.role = role
    self.content = content
    self.source = source
    self.providerOutputItems = providerOutputItems
  }

  public static func system(_ text: String) -> RemoteTranscriptEntry {
    RemoteTranscriptEntry(role: .system, content: [.text(text)])
  }

  public static func user(_ text: String, images: [RemoteImage] = []) -> RemoteTranscriptEntry {
    RemoteTranscriptEntry(
      role: .user, content: [.text(text)] + images.map(RemoteContentBlock.image))
  }

  public static func assistant(
    _ text: String? = nil, thinking: RemoteThinking? = nil,
    toolCalls: [RemoteToolCall] = [], source: RemoteModelIdentity? = nil
  ) -> RemoteTranscriptEntry {
    var content = [RemoteContentBlock]()
    if let thinking {
      content.append(.thinking(thinking))
    }
    if let text, !text.isEmpty {
      content.append(.text(text))
    }
    content += toolCalls.map(RemoteContentBlock.toolCall)
    return RemoteTranscriptEntry(role: .assistant, content: content, source: source)
  }

  public static func toolResult(
    _ content: String, toolCallID: String, toolName: String, isError: Bool,
    images: [RemoteImage] = []
  ) -> RemoteTranscriptEntry {
    RemoteTranscriptEntry(
      role: .toolResult,
      content: [
        .toolResult(
          RemoteToolResult(
            toolCallID: toolCallID, toolName: toolName, content: content, isError: isError,
            images: images))
      ])
  }

  public var images: [RemoteImage] {
    content.flatMap { block -> [RemoteImage] in
      switch block {
      case .image(let image): return [image]
      case .toolResult(let result): return result.images
      default: return []
      }
    }
  }

  public var text: String? {
    let text = content.remoteText
    return text.isEmpty ? nil : text
  }

  public var thinking: [RemoteThinking] {
    content.remoteThinking
  }

  public var thinkingText: String? {
    let text = thinking.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    return text.isEmpty ? nil : text
  }

  public var toolCalls: [RemoteToolCall] {
    content.remoteToolCalls
  }

  public var toolResults: [RemoteToolResult] {
    content.remoteToolResults
  }

  var hasAssistantPayload: Bool {
    guard role == .assistant else { return true }
    if text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      || !toolCalls.isEmpty || providerOutputItems?.isEmpty == false
    {
      return true
    }
    return thinking.contains {
      $0.text?.isEmpty == false || $0.signature?.isEmpty == false
        || $0.redactedData?.isEmpty == false || $0.providerMetadata?.isEmpty == false
    }
  }

  public func replacingText(with text: String) -> RemoteTranscriptEntry {
    var entry = self
    let insertionIndex =
      entry.content.firstIndex {
        if case .text = $0 { return true }
        return false
      } ?? entry.content.firstIndex {
        if case .toolCall = $0 { return true }
        if case .toolResult = $0 { return true }
        return false
      } ?? entry.content.endIndex
    entry.content.removeAll {
      if case .text = $0 { return true }
      return false
    }
    if !text.isEmpty {
      entry.content.insert(.text(text), at: min(insertionIndex, entry.content.endIndex))
    }
    return entry
  }

  public func removingThinking() -> RemoteTranscriptEntry {
    var entry = self
    entry.content.removeAll {
      if case .thinking = $0 { return true }
      return false
    }
    entry.providerOutputItems?.removeAll { item in
      guard case .object(let object) = item,
        case .string("reasoning")? = object["type"]
      else { return false }
      return true
    }
    if entry.providerOutputItems?.isEmpty == true {
      entry.providerOutputItems = nil
    }
    return entry
  }

  func replacingMalformedToolArguments() -> RemoteTranscriptEntry {
    var entry = self
    entry.content = entry.content.map { block in
      guard case .toolCall(var call) = block, !call.hasJSONObjectArguments else {
        return block
      }
      call.arguments = "{}"
      return .toolCall(call)
    }
    entry.providerOutputItems = entry.providerOutputItems?.map { item in
      guard case .object(var object) = item,
        case .string("function_call")? = object["type"],
        case .string(let arguments)? = object["arguments"]
      else { return item }
      let hasJSONObjectArguments: Bool
      if let data = arguments.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data)
      {
        hasJSONObjectArguments = value is [String: Any]
      } else {
        hasJSONObjectArguments = false
      }
      guard !hasJSONObjectArguments else { return item }
      object["arguments"] = .string("{}")
      return .object(object)
    }
    return entry
  }

  func removingMalformedOpenRouterReasoningDetails() -> RemoteTranscriptEntry {
    guard
      source?.provider == RemoteProvider.openRouter.rawValue
        || source?.provider == RemoteProvider.localCode.rawValue
    else { return self }
    let metadata = thinking.flatMap { $0.providerMetadata ?? [] }
    guard !metadata.isEmpty, !metadata.allSatisfy(\.isValidOpenRouterReasoningDetail) else {
      return self
    }
    return removingThinking()
  }
}
