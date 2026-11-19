import Atomics
import DataModels
import Foundation
import LLM
import NNC
import Tokenizer

/// Times Inkling 2 Small through `Inkling2SmallTextGenerator`, the decode the chat runs.
final class Inkling2Speedometer: Speedometer {
  private static var decodeTokenCount: Int { 128 }
  // Long enough for the chip to shed the heat of a reading, short enough to keep a run brisk.
  private static var coolDownDuration: TimeInterval { 20 }

  weak var delegate: (any SpeedometerDelegate)?
  let contextLengths: [Int]
  let promptLength: Int
  private var textGenerator: Inkling2SmallTextGenerator
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
    textGenerator: Inkling2SmallTextGenerator, contextLengths: [Int], graph: DynamicGraph,
    streamContext: StreamContext, storePath: String, libraryURL: URL, thinkingBudget: Int,
    deterministic: Bool
  ) {
    // A reading restores its context from a checkpoint, then prefills one full chunk. Only the 8
    // full-attention layers keep rows past the sliding window, 32 KB a token, about 6 GiB at the
    // chat's context window, which the memory the weights tier leaves free holds.
    let promptLength = textGenerator.chunkedPrefillMaxLength
    self.contextLengths = contextLengths.filter { contextLength in
      contextLength.isMultiple(of: promptLength)
        && contextLength.isMultiple(of: textGenerator.checkpointStride)
        && contextLength + promptLength + Self.decodeTokenCount
          < Inkling2CodeAgent.maximumContextLength
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
    // Copied from the Inkling agent, so readings run with the chat's graph flags.
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
    let contextCache = Inkling2SmallContextCache(
      storePath: storePath, checkpointStride: textGenerator.checkpointStride, isReadOnly: true,
      maximumRestoredTokenLength: contextLength)
    let isStopped = isStopped
    var isMissingContext = false
    var isCooledDown = false
    var kvCache = Inkling2SmallTextGenerator.KVCache()
    DynamicGraph.setSeed(0)
    let tokensGPU = graph.variable(Tensor<Int32>(tokens).toGPU(0))
    _ = graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.decode(
          graph: graph, tokens: tokensGPU, tokenOffset: 0, thinkingBudget: thinkingBudget,
          deterministic: deterministic, kvCache: &kvCache, contextTokens: tokens,
          contextCache: contextCache
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
    let contextCache = Inkling2SmallContextCache(
      storePath: storePath, checkpointStride: textGenerator.checkpointStride, isReadOnly: false,
      maximumRestoredTokenLength: .max)
    let isStopped = isStopped
    var isBuilt = false
    var kvCache = Inkling2SmallTextGenerator.KVCache()
    let tokensGPU = graph.variable(Tensor<Int32>(context).toGPU(0))
    _ = graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.decode(
          graph: graph, tokens: tokensGPU, tokenOffset: 0, thinkingBudget: thinkingBudget,
          deterministic: deterministic, kvCache: &kvCache, contextTokens: context,
          contextCache: contextCache
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

  /// Copied from the Inkling agent's transcript renderer and tool-call format.
  private struct Template: SpeedometerTemplate {
    let isThinking: Bool

    // As the Serve adapter opens a reply: the model's thinking message, or its message without one.
    var assistantPromptTokens: [Int32] {
      isThinking
        ? [Inkling2CodeAgent.modelMessageToken, Inkling2CodeAgent.thinkingContentToken]
        : [Inkling2CodeAgent.modelMessageToken]
    }

    // The template states the effort before the first message that isn't the system's, at its
    // default of 0.9, or 0 with thinking off as the agent does.
    func requestTokens(_ text: String) -> [Int32] {
      let effort: Inkling2CodeAgent.ReasoningEffort = isThinking ? .high : .none
      return Inkling2CodeAgent.message(
        Inkling2CodeAgent.systemMessageToken, tokens("Thinking effort level: \(effort.level)"))
        + userTokens(text)
    }

    func userTokens(_ text: String) -> [Int32] {
      Inkling2CodeAgent.message(Inkling2CodeAgent.userMessageToken, tokens(text))
    }

    // The model ends its turn after the call.
    func readCallTokens(path: String, startLine: Int) -> [Int32] {
      var arguments: [String: Any] = ["path": path]
      if startLine > 1 {
        arguments["start_line"] = startLine
      }
      let body =
        "{\"name\":\"read\",\"args\":" + Inkling2ToolCallParser.json(arguments) + "}"
      return [Inkling2CodeAgent.modelMessageToken] + tokens("read")
        + [Inkling2CodeAgent.invokeToolJSONContentToken] + tokens(body)
        + [Inkling2CodeAgent.endMessageToken, Inkling2CodeAgent.endOfTurnToken]
    }

    func toolResultTokens(_ content: [Int32]) -> [Int32] {
      Inkling2CodeAgent.message(Inkling2CodeAgent.toolMessageToken, header: tokens("read"), content)
    }

    func tokens(_ text: String) -> [Int32] {
      Inkling2SmallTextGenerator.safeTokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
      ).1
    }

    func text(_ tokens: [Int32]) -> String {
      Inkling2SmallTextGenerator.safeTokenizer.decode(tokens)
    }
  }
}
