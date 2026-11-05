import Tokenizer

public protocol TextGenerator {
  static var estimatedKVCacheSize: UInt64 { get }
  /// The most memory the weights hold once loaded, which bounds how many KV caches fit beside them.
  var residentWeightsSize: UInt64 { get }

  var safeTokenizer: TiktokenTokenizer { get }
  var filePath: String { get }
  /// Every file it opens, `filePath` first. A model folder change can move any of them.
  var filePaths: [String] { get }
  func unload()
}

extension TextGenerator {
  public var filePaths: [String] { [filePath] }
}
