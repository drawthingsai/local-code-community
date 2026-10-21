import CryptoKit
import Foundation
import ProjectHistoryManager

public protocol ContextCache {

}

struct ContextCachePrefixHasher {
  private let modelFileName: String?
  private var sha256 = SHA256()
  private(set) var hashedTokenCount = 0
  private var nextEmbeddingSpan = 0

  init(modelFilePath: String) {
    modelFileName = URL(fileURLWithPath: modelFilePath).lastPathComponent
  }

  static func hash(tokens: [Int32], embeddingSpans: [EmbedSpan] = []) -> Data {
    var hasher = ContextCachePrefixHasher(modelFileName: nil)
    return hasher.hash(tokens: tokens, to: tokens.count, embeddingSpans: embeddingSpans)
  }

  private init(modelFileName: String?) {
    self.modelFileName = modelFileName
  }

  mutating func hash(tokens: [Int32], to tokenCount: Int, embeddingSpans: [EmbedSpan] = [])
    -> Data
  {
    precondition(tokenCount >= hashedTokenCount && tokenCount <= tokens.count)
    if hashedTokenCount == 0, let modelFileName {
      sha256.update(data: Data(modelFileName.utf8))
    }
    var data = Data()
    data.reserveCapacity((tokenCount - hashedTokenCount) * MemoryLayout<Int32>.size)
    for position in hashedTokenCount..<tokenCount {
      if nextEmbeddingSpan < embeddingSpans.count,
        embeddingSpans[nextEmbeddingSpan].start == position
      {
        let span = embeddingSpans[nextEmbeddingSpan]
        data.append(span.kind.rawValue)
        data.append(contentsOf: span.digest)
        nextEmbeddingSpan += 1
      }
      var littleEndianToken = tokens[position].littleEndian
      withUnsafeBytes(of: &littleEndianToken) { bytes in
        data.append(contentsOf: bytes)
      }
    }
    sha256.update(data: data)
    hashedTokenCount = tokenCount
    let finalized = sha256
    return Data(finalized.finalize())
  }

  mutating func hash(tokens: [Int32], to tokenCount: Int, embeddingSpans: [EmbedSpan] = [])
    -> String
  {
    let data: Data = hash(tokens: tokens, to: tokenCount, embeddingSpans: embeddingSpans)
    return data.map { String(format: "%02x", $0) }.joined()
  }
}

func contextCacheStorePath(projectPath: String?) -> String? {
  guard let projectPath else { return nil }
  let metadataURL = URL(fileURLWithPath: projectPath, isDirectory: true)
    .appendingPathComponent(".localc", isDirectory: true)
  guard
    (try? FileManager.default.createDirectory(
      at: metadataURL, withIntermediateDirectories: true)) != nil
  else {
    return nil
  }
  return metadataURL.appendingPathComponent("context_cache.sqlite3").path
}
