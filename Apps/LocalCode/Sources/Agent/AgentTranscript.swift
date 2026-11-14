import Foundation

struct AgentTranscriptToolCall: Equatable, Sendable {
  struct Parameter: Equatable, Sendable {
    var string: Bool
    var value: String
  }

  var function: String
  var parameters: [String: Parameter]
}

/// An image among a message's or a tool result's text. Only a served request's transcript has
/// them: the chat keeps its images in the embed spans next to its tokens.
struct AgentTranscriptImage: Equatable, Sendable {
  /// How many UTF-8 bytes of the text come before it.
  var offset: Int
  /// The encoded file, as the client sent it.
  var data: Data

  /// `text` cut where its images are: what comes before each of them, then what follows the last.
  static func segments(of text: String, images: [AgentTranscriptImage]) -> [String] {
    guard !images.isEmpty else { return [text] }
    let bytes = Array(text.utf8)
    var segments = [String]()
    var start = 0
    for image in images {
      let end = min(max(image.offset, start), bytes.count)
      segments.append(String(decoding: bytes[start..<end], as: UTF8.self))
      start = end
    }
    segments.append(String(decoding: bytes[start...], as: UTF8.self))
    return segments
  }
}

struct AgentTranscriptToolResult: Equatable, Sendable {
  var content: String
  var isError: Bool
  var images = [AgentTranscriptImage]()
}

enum AgentTranscriptEntry: Equatable, Sendable {
  case user(String, images: [AgentTranscriptImage] = [])
  case assistant(
    text: String, thinking: String, toolCalls: [AgentTranscriptToolCall]
  )
  case toolResults([AgentTranscriptToolResult])
}
