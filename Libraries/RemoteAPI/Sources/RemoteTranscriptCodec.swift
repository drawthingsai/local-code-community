import Foundation

public enum RemoteTranscriptCodecError: LocalizedError {
  case invalidEncoding
  case unsupportedVersion(Int)

  public var errorDescription: String? {
    switch self {
    case .invalidEncoding:
      return "The saved conversation checkpoint could not be decoded."
    case .unsupportedVersion(let version):
      return "Saved conversation checkpoint version \(version) is not supported."
    }
  }
}

public enum RemoteTranscriptCodec {
  private struct Record: Codable {
    var version: Int
    var entries: [RemoteTranscriptEntry]

    init(entries: [RemoteTranscriptEntry]) {
      version = 1
      self.entries = entries
    }
  }

  public static func decode(_ plaintext: String) throws -> [RemoteTranscriptEntry] {
    guard let data = plaintext.data(using: .utf8),
      let record = try? JSONDecoder().decode(Record.self, from: data)
    else {
      throw RemoteTranscriptCodecError.invalidEncoding
    }
    guard record.version == 1 else {
      throw RemoteTranscriptCodecError.unsupportedVersion(record.version)
    }
    return record.entries
  }

  public static func encode(_ entries: [RemoteTranscriptEntry]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(Record(entries: entries))
    guard let plaintext = String(data: data, encoding: .utf8) else {
      throw RemoteTranscriptCodecError.invalidEncoding
    }
    return plaintext
  }
}
