import Foundation

public enum RemoteJSONValue: Equatable, Sendable, Codable {
  case object([String: RemoteJSONValue])
  case array([RemoteJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode([String: RemoteJSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([RemoteJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else {
      self = .number(try container.decode(Double.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var compactJSONString: String? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

public struct RemoteFunctionTool: Equatable, Sendable, Codable {
  private struct Function: Codable {
    var name: String
    var description: String
    var parameters: RemoteJSONValue
  }

  public var name: String
  public var description: String
  public var parameters: RemoteJSONValue

  public init(name: String, description: String, parameters: RemoteJSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    guard type == "function" else {
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: container, debugDescription: "Only function tools are supported.")
    }
    let function = try container.decode(Function.self, forKey: .function)
    self.init(
      name: function.name, description: function.description, parameters: function.parameters)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode("function", forKey: .type)
    try container.encode(
      Function(name: name, description: description, parameters: parameters), forKey: .function)
  }

  private enum CodingKeys: String, CodingKey {
    case type
    case function
  }
}

public struct RemoteUsage: Equatable, Sendable, Codable {
  public var promptTokens: Int?
  public var completionTokens: Int?
  public var totalTokens: Int?

  public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.totalTokens = totalTokens
  }

  private enum CodingKeys: String, CodingKey {
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case totalTokens = "total_tokens"
  }
}

public struct RemoteStreamProgress: Equatable, Sendable {
  public var content: [RemoteContentBlock]

  public init(text: String, toolCalls: [RemoteToolCall]) {
    content = (text.isEmpty ? [] : [.text(text)]) + toolCalls.map(RemoteContentBlock.toolCall)
  }

  public init(content: [RemoteContentBlock]) {
    self.content = content
  }

  public var text: String {
    content.remoteText
  }

  public var toolCalls: [RemoteToolCall] {
    content.remoteToolCalls
  }

  var hasMeaningfulOutput: Bool {
    content.hasMeaningfulRemoteOutput
  }

  var estimatedOutputBytes: Int {
    content.estimatedRemoteOutputBytes
  }
}

public struct RemoteCompletion: Equatable, Sendable {
  public var content: [RemoteContentBlock]
  public var usage: RemoteUsage?
  public var stopReason: String?
  public var providerOutputItems: [RemoteJSONValue]?

  public init(
    content: [RemoteContentBlock], usage: RemoteUsage? = nil, stopReason: String? = nil,
    providerOutputItems: [RemoteJSONValue]? = nil
  ) {
    self.content = content
    self.usage = usage
    self.stopReason = stopReason
    self.providerOutputItems = providerOutputItems
  }

  public init(
    text: String, toolCalls: [RemoteToolCall], usage: RemoteUsage? = nil,
    thinking: RemoteThinking? = nil, stopReason: String? = nil,
    providerOutputItems: [RemoteJSONValue]? = nil
  ) {
    var content = [RemoteContentBlock]()
    if let thinking { content.append(.thinking(thinking)) }
    if !text.isEmpty { content.append(.text(text)) }
    content += toolCalls.map(RemoteContentBlock.toolCall)
    self.init(
      content: content, usage: usage, stopReason: stopReason,
      providerOutputItems: providerOutputItems)
  }

  public var text: String {
    content.remoteText
  }

  public var toolCalls: [RemoteToolCall] {
    content.remoteToolCalls
  }
}

public protocol RemoteRequestCancellable: AnyObject {
  func cancel()
}

extension URLSessionTask: RemoteRequestCancellable {}

public protocol RemoteChatProviding: AnyObject {
  var modelIdentity: RemoteModelIdentity { get }
  /// Adapter capability; the selected model must also accept images.
  var supportsImageInput: Bool { get }

  @discardableResult
  func streamChat(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable
}

extension RemoteChatProviding {
  public var supportsImageInput: Bool { false }
}
