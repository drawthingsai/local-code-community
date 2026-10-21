import Tokenizer

public protocol TextGenerator {
  static var estimatedKVCacheSize: UInt64 { get }

  var safeTokenizer: TiktokenTokenizer { get }
  var filePath: String { get }
  func unload()
}
