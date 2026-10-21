import Atomics
import DataModels
import Foundation
import LLM
import NNC
import Tokenizer

/// Times a DeepSeek 4 or 4.1 model through its text generator, the decode the chat runs.
final class DeepSeek4Speedometer<Generator: DeepSeekTextGenerator>: Speedometer {
  private static var decodeTokenCount: Int { 128 }
  private static var maximumContextLength: Int { 1_024 * 1_024 }
  // Long enough for the chip to shed the heat of a reading, short enough to keep a run brisk.
  private static var coolDownDuration: TimeInterval { 20 }

  weak var delegate: (any SpeedometerDelegate)?
  let contextLengths: [Int]
  let promptLength: Int
  private var textGenerator: Generator
  private let graph: DynamicGraph
  private let streamContext: StreamContext
  private let storePath: String
  private let libraryURL: URL
  private let thinkingBudget: Int
  private let deterministic: Bool
  private let isStopped = ManagedAtomic(false)
  // Signaled by stop(), so a cool-down in progress ends right away.
  private let stopSignal = DispatchSemaphore(value: 0)
  // Built on the generation queue by the first reading.
  private var transcript: SpeedometerTranscript<Template>?
  private var isWarmedUp = false

  init(
    textGenerator: Generator, contextLengths: [Int], graph: DynamicGraph,
    streamContext: StreamContext, storePath: String, libraryURL: URL, thinkingBudget: Int,
    deterministic: Bool
  ) {
    // Without the KV layout worked out per tier, below 64 GiB stops at 128K.
    let isLargeMemory = ProcessInfo.processInfo.physicalMemory >= 64 * 1_024 * 1_024 * 1_024
    // A reading restores its context from a checkpoint, then prefills one full chunk.
    let promptLength = textGenerator.chunkedPrefillMaxLength
    self.contextLengths = contextLengths.filter { contextLength in
      contextLength.isMultiple(of: promptLength)
        && contextLength.isMultiple(of: textGenerator.checkpointStride)
        && contextLength + promptLength + Self.decodeTokenCount < Self.maximumContextLength
        && (isLargeMemory || contextLength <= 131_072)
    }
    self.promptLength = promptLength
    self.textGenerator = textGenerator
    self.graph = graph
    self.streamContext = streamContext
    self.storePath = storePath
    self.libraryURL = libraryURL
    self.thinkingBudget = thinkingBudget
    self.deterministic = deterministic
  }

  func stop() {
    isStopped.store(true, ordering: .releasing)
    stopSignal.signal()
  }

  func prefillReading(contextLength: Int) -> Double? {
    measured(contextLength: contextLength, decodeTokenCount: 0).map {
      Double($0.prefillTokensPerSecond)
    }
  }

  func decodeReading(contextLength: Int) -> (tokensPerSecond: Double, decodedTokenCount: Int)? {
    measured(contextLength: contextLength, decodeTokenCount: Self.decodeTokenCount).map {
      (Double($0.tokenGeneratedPerSecond), $0.tokenGeneratedSoFar)
    }
  }

  /// Restores `contextLength` tokens, then prefills one chunk of prompt on top of them when
  /// `decodeTokenCount` is 0, or decodes that many tokens after the short decode prompt.
  private func measured(
    contextLength: Int, decodeTokenCount: Int
  ) -> DeepSeekGenerationStatistics? {
    guard !isStopped.load(ordering: .acquiring) else { return nil }
    if transcript == nil {
      transcript = SpeedometerTranscript(
        template: Template(isThinking: thinkingBudget > 0), libraryURL: libraryURL,
        promptLength: promptLength,
        maximumContextLength: contextLengths.max() ?? 0)
    }
    guard let transcript,
      let prompt = decodeTokenCount == 0
        ? transcript.promptTokens(contextLength: contextLength)
        : transcript.decodePromptTokens(contextLength: contextLength)
    else { return nil }
    let context = Array(transcript.contextTokens.prefix(contextLength))
    // Copied from the DeepSeek agent, so readings run with the chat's graph flags.
    let oldFlags = DynamicGraph.flags
    let isMFAEnabled = DeviceCapability.isMFAEnabled.load(ordering: .acquiring) > 0
    if !isMFAEnabled {
      DynamicGraph.flags.insert(.disableMFA)
    } else {
      DynamicGraph.flags.remove(.disableMFA)
      if !DeviceCapability.isMFAGEMMFaster {
        DynamicGraph.flags.insert(.disableMFAGEMM)
      }
      if !DeviceCapability.isMFAAttentionFaster {
        DynamicGraph.flags.insert(.disableMFAAttention)
      }
      switch DeviceCapability.appleNeuralEngineState.load(ordering: .acquiring) {
      case .disabled:
        DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
      case .appleNeuralEngineOnly:
        DynamicGraph.flags.remove(.disableMFAAppleNeuralEngine)
        DynamicGraph.flags.insert(.disableMFAAppleNeuralEngineAndGpu)
      case .appleNeuralEngineAndGPU:
        DynamicGraph.flags.remove(.disableMFAAppleNeuralEngine)
        DynamicGraph.flags.remove(.disableMFAAppleNeuralEngineAndGpu)
      }
    }
    defer {
      streamContext.joined()
      graph.garbageCollect()
      DynamicGraph.flags = oldFlags
    }
    // An untimed reading first loads the weights and compiles the graphs the timed ones use.
    if !isWarmedUp, let warmupPrompt = transcript.promptTokens(contextLength: 0) {
      _ = measure(context: [], prompt: warmupPrompt, decodeTokenCount: Self.decodeTokenCount)
      isWarmedUp = true
    }
    switch measure(context: context, prompt: prompt, decodeTokenCount: decodeTokenCount) {
    case .statistics(let statistics):
      return statistics
    case .failed:
      return nil
    case .missingContext:
      // The first run for this model builds the context into the cache, one time.
      guard build(context: context) else { return nil }
      guard
        case .statistics(let statistics) = measure(
          context: context, prompt: prompt, decodeTokenCount: decodeTokenCount)
      else { return nil }
      return statistics
    }
  }

  /// Leaves the GPU idle for `coolDownDuration`. False when stopped meanwhile.
  private func coolDown() -> Bool {
    delegate?.speedometer(self, didUpdate: .coolingDown)
    _ = stopSignal.wait(timeout: .now() + Self.coolDownDuration)
    return !isStopped.load(ordering: .acquiring)
  }

  private enum Measurement {
    case statistics(DeepSeekGenerationStatistics)
    case missingContext
    case failed
  }

  /// Restores `context` from the cache, prefills `prompt`, and decodes up to `decodeTokenCount`
  /// tokens after it, or stops at the end of the prefill when that is 0.
  private func measure(context: [Int32], prompt: [Int32], decodeTokenCount: Int) -> Measurement {
    let contextLength = context.count
    let tokens = context + prompt
    // Restoring stops at the context, and nothing is saved while timing.
    let contextCache = Generator.ContextCache(
      storePath: storePath, checkpointStride: textGenerator.checkpointStride, isReadOnly: true,
      maximumRestoredTokenLength: contextLength)
    let isStopped = isStopped
    var isMissingContext = false
    var isCooledDown = false
    var kvCache = Generator.KVCache()
    DynamicGraph.setSeed(0)
    let tokensGPU = graph.variable(Tensor<Int32>(tokens).toGPU(0))
    _ = graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.decode(
          graph: graph, tokens: tokensGPU, tokenOffset: 0, thinkingBudget: thinkingBudget,
          deterministic: deterministic, kvCache: &kvCache, contextTokens: tokens,
          contextCache: contextCache, embedSpans: [], projectPath: nil
        ) { prefillStart, _, generatedTokens, _ in
          guard !isStopped.load(ordering: .acquiring) else { return .abort }
          // Stops right after a restore that fell short, before any of the context is prefilled.
          if let restoredTokenLength = contextCache.restoredTokenLength,
            restoredTokenLength < contextLength
          {
            isMissingContext = true
            return .abort
          }
          // The generator calls back at the context's end after its restore and before it times
          // the prefill. The prefill pass rests the chip there, once its context is in place, so
          // it doesn't inherit the heat of the warm-up, a context build, or the reading before it.
          // The decode pass follows right after.
          if decodeTokenCount == 0, !isCooledDown, prefillStart == contextLength {
            isCooledDown = true
            guard coolDown() else { return .abort }
          }
          delegate?.speedometer(
            self,
            didUpdate: generatedTokens.isEmpty
              ? .reading(finished: max(0, prefillStart - contextLength), total: prompt.count)
              : .writing(tokens: generatedTokens.count))
          if decodeTokenCount == 0 {
            return generatedTokens.isEmpty && prefillStart < tokens.count ? .continue : .abort
          }
          return generatedTokens.count >= decodeTokenCount ? .abort : .continue
        }
      }
    }
    // An aborted prefill can leave work on the stream that the next decode must not overlap.
    streamContext.joined()
    guard !isMissingContext else { return .missingContext }
    let statistics = textGenerator.lastInteractionStatistics
    guard !isStopped.load(ordering: .acquiring), statistics.prefillTokensSoFar == prompt.count,
      statistics.prefillDurationSoFar > 0,
      decodeTokenCount == 0 || statistics.tokenGenerationDurationSoFar > 0
    else { return .failed }
    return .statistics(statistics)
  }

  /// Prefills `context`, saving checkpoints into the cache along the way, and stops before decode.
  private func build(context: [Int32]) -> Bool {
    let contextCache = Generator.ContextCache(
      storePath: storePath, checkpointStride: textGenerator.checkpointStride, isReadOnly: false,
      maximumRestoredTokenLength: .max)
    let isStopped = isStopped
    var isBuilt = false
    var kvCache = Generator.KVCache()
    let tokensGPU = graph.variable(Tensor<Int32>(context).toGPU(0))
    _ = graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.decode(
          graph: graph, tokens: tokensGPU, tokenOffset: 0, thinkingBudget: thinkingBudget,
          deterministic: deterministic, kvCache: &kvCache, contextTokens: context,
          contextCache: contextCache, embedSpans: [], projectPath: nil
        ) { prefillStart, tokenLength, generatedTokens, _ in
          guard !isStopped.load(ordering: .acquiring) else { return .abort }
          delegate?.speedometer(
            self, didUpdate: .reading(finished: prefillStart, total: tokenLength))
          // The last checkpoint is saved before prefill reports reaching the end.
          if prefillStart >= tokenLength || !generatedTokens.isEmpty {
            isBuilt = true
            return .abort
          }
          return .continue
        }
      }
    }
    streamContext.joined()
    return isBuilt
  }

  /// Copied from the DeepSeek agent's transcript renderer and tool-call format.
  private struct Template: SpeedometerTemplate {
    private static var beginOfSentenceToken: Int32 { 0 }
    private static var endOfSentenceToken: Int32 { 1 }
    private static var userToken: Int32 { 128_803 }
    private static var assistantToken: Int32 { 128_804 }
    private static var thinkStartToken: Int32 { 128_821 }
    private static var thinkEndToken: Int32 { 128_822 }

    let isThinking: Bool

    var assistantPromptTokens: [Int32] {
      [Self.assistantToken, isThinking ? Self.thinkStartToken : Self.thinkEndToken]
    }

    func requestTokens(_ text: String) -> [Int32] {
      [Self.beginOfSentenceToken] + userTokens(text)
    }

    func userTokens(_ text: String) -> [Int32] {
      [Self.userToken] + tokens(text)
    }

    func readCallTokens(path: String, startLine: Int) -> [Int32] {
      let format:
        (
          toolCallStart: String, toolCallEnd: String, invokeStart: String, invokeEnd: String,
          parameterStart: String, parameterEnd: String
        )
      switch Generator.version {
      case .deepseek_4_1_flash:
        format = (
          "<｜DSML｜ calls>", "</｜DSML｜ calls>", "<｜DSML｜ invoke", "</｜DSML｜ invoke>",
          "<｜DSML｜ parameter", "</｜DSML｜ parameter>"
        )
      default:
        format = (
          "<｜DSML｜tool_calls>", "</｜DSML｜tool_calls>", "<｜DSML｜invoke", "</｜DSML｜invoke>",
          "<｜DSML｜parameter", "</｜DSML｜parameter>"
        )
      }
      var parameters = [(name: "path", value: path, isString: true)]
      if startLine > 1 {
        parameters.append((name: "start_line", value: "\(startLine)", isString: false))
      }
      var callTokens =
        [Self.assistantToken, Self.thinkEndToken] + tokens("\n\n")
        + unsafeTokens(format.toolCallStart + "\n") + unsafeTokens(format.invokeStart + " name=\"")
        + tokens("read") + unsafeTokens("\">\n")
      for parameter in parameters {
        callTokens +=
          unsafeTokens(format.parameterStart + " name=\"") + tokens(parameter.name)
          + unsafeTokens("\" string=\"\(parameter.isString ? "true" : "false")\">")
          + tokens(parameter.value) + unsafeTokens(format.parameterEnd + "\n")
      }
      return callTokens + unsafeTokens(format.invokeEnd + "\n") + unsafeTokens(format.toolCallEnd)
        + [Self.endOfSentenceToken]
    }

    func toolResultTokens(_ content: [Int32]) -> [Int32] {
      [Self.userToken] + tokens("<tool_result>") + content + tokens("</tool_result>")
    }

    func tokens(_ text: String) -> [Int32] {
      Generator.safeTokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
      ).1
    }

    func text(_ tokens: [Int32]) -> String {
      Generator.safeTokenizer.decode(tokens)
    }

    private func unsafeTokens(_ text: String) -> [Int32] {
      Generator.unsafeTokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
      ).1
    }
  }
}
