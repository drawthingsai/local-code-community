import Foundation
import LLM
import NNC
import ProjectHistoryManager
import Tokenizer
import XCTest

@testable import LocalCodeCLI

/// Prefills one token per chunk and then generates `generatedTokens`, recording each decode. As
/// the real generators do, pause keeps one pending prediction, abort returns only evaluated
/// tokens, and a context that ends in end of sentence generates nothing.
private struct ScriptedDeepSeekGenerator: DeepSeekTextGenerator {
  struct KVCache: DeepSeekKVCache {
    var tokenLength = 0
    func snapshot() -> Self { self }
  }

  struct ContextCache: DeepSeekContextCache {
    init(projectPath: String?, checkpointStride: Int) {}
    init(
      storePath: String, checkpointStride: Int, isReadOnly: Bool, maximumRestoredTokenLength: Int
    ) {}
    var restoredTokenLength: Int? { nil }
  }

  final class Recorder {
    var decodes = [(tokenOffset: Int, contextTokens: [Int32])]()
  }

  static var version: LLMVersion { DeepSeek4TextGenerator.version }
  static var unsafeTokenizer: TiktokenTokenizer { DeepSeek4TextGenerator.unsafeTokenizer }
  static var safeTokenizer: TiktokenTokenizer { DeepSeek4TextGenerator.safeTokenizer }
  static var estimatedKVCacheSize: UInt64 { 0 }
  var residentWeightsSize: UInt64 { 0 }
  var filePath: String { "/missing/scripted.ckpt" }
  var chunkedPrefillMaxLength: Int { 4_096 }
  var statistics: DeepSeekGenerationStatistics { DeepSeekGenerationStatistics() }
  var lastInteractionStatistics: DeepSeekGenerationStatistics { DeepSeekGenerationStatistics() }
  static let endOfSentenceToken: Int32 = 1
  let recorder: Recorder
  let generatedTokens: [Int32]

  func unload() {}

  mutating func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    thinkingBudget: Int, deterministic: Bool, kvCache: inout KVCache,
    contextTokens: [Int32], contextCache: ContextCache,
    embedSpans: [EmbedSpan], projectPath: String?,
    continuationHandler: (Int, Int, [Int32], DeepSeekGenerationStatistics) ->
      DeepSeekGenerationContinuationState
  ) -> [Int32] {
    recorder.decodes.append((tokenOffset, contextTokens))
    let tokenLength = tokens.shape[0]
    guard continuationHandler(0, tokenLength, [], statistics) == .continue else { return [] }
    guard tokenLength > 0, kvCache.tokenLength == tokenOffset,
      contextTokens.count == tokenOffset + tokenLength
    else { return [] }
    for prefilled in 1...tokenLength {
      kvCache.tokenLength = tokenOffset + prefilled
      switch continuationHandler(prefilled, tokenLength, [], statistics) {
      case .continue: break
      case .pause: return prefilled == tokenLength ? Array(generatedTokens.prefix(1)) : []
      case .abort: return []
      }
    }
    guard contextTokens.last != Self.endOfSentenceToken else { return [] }
    var generated = [Int32]()
    for token in generatedTokens {
      generated.append(token)
      kvCache.tokenLength += 1
      switch continuationHandler(kvCache.tokenLength, kvCache.tokenLength, generated, statistics) {
      case .continue: break
      case .pause: return Array(generatedTokens.prefix(generated.count + 1))
      case .abort: return generated
      }
    }
    return generated
  }
}

private typealias DeepSeekAgent = DeepSeek4CodeAgent<ScriptedDeepSeekGenerator>

final class DeepSeek4AgentTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func makeAgent(
    generating generatedTokens: [Int32], recorder: ScriptedDeepSeekGenerator.Recorder
  ) -> DeepSeekAgent {
    let agent = DeepSeekAgent(
      textGenerator: ScriptedDeepSeekGenerator(
        recorder: recorder, generatedTokens: generatedTokens),
      graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
      unsafeTokenizer: ScriptedDeepSeekGenerator.unsafeTokenizer,
      safeTokenizer: ScriptedDeepSeekGenerator.safeTokenizer,
      systemPromptTemplate: "You are a helpful assistant.")
    agent.thinkingBudget = 0
    return agent
  }

  private func textTokens(_ text: String) -> [Int32] {
    ScriptedDeepSeekGenerator.safeTokenizer.tokenize(text: text, addSpecialTokens: false).0
  }

  func testInterruptedColdReplayKeepsSavedOutput() throws {
    let saved = textTokens("One two three four")
    XCTAssertGreaterThan(saved.count, 2)
    let recorder = ScriptedDeepSeekGenerator.Recorder()
    let agent = makeAgent(generating: saved, recorder: recorder)
    // Pause with the last saved token still pending.
    _ = agent.ask(
      "Hello", isMemoryEnabled: false, threadId: 60,
      environment: ProjectEnvironment(projectPath: directory.path)
    ) { progress, _ in
      guard case .generate(let result) = progress else { return .continue }
      return result.outputTokens.count == saved.count - 1 ? .pause : .continue
    }
    XCTAssertEqual(agent.suspendedResult?.outputTokens, saved)
    let base = try XCTUnwrap(recorder.decodes.last?.contextTokens)

    // A cold resume replays all but the pending token. Pausing partway through that prefill
    // keeps every saved token.
    agent.unloadCaches()
    var prefillCallbacks = 0
    _ = agent.resume { progress, _ in
      guard case .prefill = progress else { return .continue }
      prefillCallbacks += 1
      return prefillCallbacks == 2 ? .pause : .continue
    }
    XCTAssertEqual(recorder.decodes.last?.contextTokens, base + saved.dropLast())
    XCTAssertEqual(agent.suspendedResult?.outputTokens, saved)

    // The cache now ends inside the base context. The next resume still replays the saved
    // output, and an abort there keeps it as the answer.
    let replayIndex = recorder.decodes.count
    let result = agent.resume { _, _ in .abort }
    XCTAssertEqual(recorder.decodes[replayIndex].contextTokens, base + saved.dropLast())
    XCTAssertEqual(result.outputTokens, saved)
    XCTAssertNil(agent.suspendedResult)
  }

  func testResumingPendingEndOfSentenceEndsTurn() throws {
    let text = textTokens("One two three")
    let saved = text + [ScriptedDeepSeekGenerator.endOfSentenceToken]
    let recorder = ScriptedDeepSeekGenerator.Recorder()
    let agent = makeAgent(generating: saved, recorder: recorder)
    // Pause with the end of sentence still pending.
    _ = agent.ask(
      "Hello", isMemoryEnabled: false, threadId: 61,
      environment: ProjectEnvironment(projectPath: directory.path)
    ) { progress, _ in
      guard case .generate(let result) = progress else { return .continue }
      return result.outputTokens.count == text.count ? .pause : .continue
    }
    XCTAssertEqual(agent.suspendedResult?.outputTokens, text)
    let base = try XCTUnwrap(recorder.decodes.last?.contextTokens)

    // Resuming evaluates the end of sentence and generates nothing after it.
    let resumeIndex = recorder.decodes.count
    let result = agent.resume { _, _ in .continue }
    XCTAssertEqual(recorder.decodes[resumeIndex].contextTokens, base + saved)
    XCTAssertEqual(result.outputTokens, text)
    XCTAssertNil(agent.suspendedResult)

    // The next turn continues from the cache, which includes the end of sentence.
    let nextIndex = recorder.decodes.count
    _ = agent.ask(
      "Thanks", isMemoryEnabled: false, threadId: 61,
      environment: ProjectEnvironment(projectPath: directory.path)
    ) { _, _ in .abort }
    XCTAssertEqual(recorder.decodes[nextIndex].tokenOffset, base.count + saved.count)
  }
}
