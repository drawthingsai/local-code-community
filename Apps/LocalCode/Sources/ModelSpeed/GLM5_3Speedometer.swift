import Atomics
import DataModels
import Foundation
import LLM
import NNC
import Tokenizer

/// Times GLM 5.3 through `GLM5_3TextGenerator`, the decode the chat runs.
final class GLM5_3Speedometer: Speedometer {
  private static var decodeTokenCount: Int { 128 }
  // Long enough for the chip to shed the heat of a reading, short enough to keep a run brisk.
  private static var coolDownDuration: TimeInterval { 20 }

  weak var delegate: (any SpeedometerDelegate)?
  let contextLengths: [Int]
  let promptLength: Int
  private var textGenerator: GLM5_3TextGenerator
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
    textGenerator: GLM5_3TextGenerator, contextLengths: [Int], graph: DynamicGraph,
    streamContext: StreamContext, storePath: String, libraryURL: URL, thinkingBudget: Int,
    deterministic: Bool
  ) {
    // A reading restores its context from a checkpoint, then prefills one full chunk. Only the
    // 11 attention layers keep rows, about 17 KB a token, which the quarter of memory the weights
    // tier leaves free holds for any reading within the context window.
    let promptLength = textGenerator.chunkedPrefillMaxLength
    self.contextLengths = contextLengths.filter { contextLength in
      contextLength.isMultiple(of: promptLength)
        && contextLength.isMultiple(of: textGenerator.checkpointStride)
        && contextLength + promptLength + Self.decodeTokenCount
          < GLM5_3TextGenerator.maximumContextLength
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
  ) -> GLM5_3TextGenerator.Statistics? {
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
    // Copied from the GLM agent, so readings run with the chat's graph flags.
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
    case statistics(GLM5_3TextGenerator.Statistics)
    case missingContext
    case failed
  }

  /// Restores `context` from the cache, prefills `prompt`, and decodes up to `decodeTokenCount`
  /// tokens after it, or stops at the end of the prefill when that is 0.
  private func measure(context: [Int32], prompt: [Int32], decodeTokenCount: Int) -> Measurement {
    let contextLength = context.count
    let tokens = context + prompt
    // Restoring stops at the context, and nothing is saved while timing.
    let contextCache = GLM5_3ContextCache(
      storePath: storePath, checkpointStride: textGenerator.checkpointStride, isReadOnly: true,
      maximumRestoredTokenLength: contextLength)
    let isStopped = isStopped
    var isMissingContext = false
    var isCooledDown = false
    var kvCache = GLM5_3TextGenerator.KVCache()
    DynamicGraph.setSeed(0)
    let tokensGPU = graph.variable(Tensor<Int32>(tokens).toGPU(0))
    _ = graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.decode(
          graph: graph, tokens: tokensGPU, tokenOffset: 0, thinkingBudget: thinkingBudget,
          outputSampling: deterministic ? .deterministic : .creative, kvCache: &kvCache,
          contextTokens: tokens, contextCache: contextCache
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
    let contextCache = GLM5_3ContextCache(
      storePath: storePath, checkpointStride: textGenerator.checkpointStride, isReadOnly: false,
      maximumRestoredTokenLength: .max)
    let isStopped = isStopped
    var isBuilt = false
    var kvCache = GLM5_3TextGenerator.KVCache()
    let tokensGPU = graph.variable(Tensor<Int32>(context).toGPU(0))
    _ = graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.decode(
          graph: graph, tokens: tokensGPU, tokenOffset: 0, thinkingBudget: thinkingBudget,
          outputSampling: deterministic ? .deterministic : .creative, kvCache: &kvCache,
          contextTokens: context, contextCache: contextCache
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

  /// Copied from the GLM agent's transcript renderer and tool-call format.
  private struct Template: SpeedometerTemplate {
    let isThinking: Bool

    var assistantPromptTokens: [Int32] {
      isThinking
        ? [GLM5_3TextGenerator.assistantToken, GLM5_3TextGenerator.thinkStartToken]
        : [
          GLM5_3TextGenerator.assistantToken, GLM5_3TextGenerator.thinkStartToken,
          GLM5_3TextGenerator.thinkEndToken,
        ]
    }

    func requestTokens(_ text: String) -> [Int32] {
      unsafeTokens("[gMASK]<sop>") + userTokens(text)
    }

    func userTokens(_ text: String) -> [Int32] {
      [GLM5_3TextGenerator.userToken] + tokens(text)
    }

    func readCallTokens(path: String, startLine: Int) -> [Int32] {
      var parameters = [("path", path)]
      if startLine > 1 {
        parameters.append(("start_line", "\(startLine)"))
      }
      var callTokens =
        [
          GLM5_3TextGenerator.assistantToken, GLM5_3TextGenerator.thinkStartToken,
          GLM5_3TextGenerator.thinkEndToken,
        ] + unsafeTokens("<tool_call>") + tokens("read")
      for (name, value) in parameters {
        callTokens +=
          unsafeTokens("<arg_key>") + tokens(name) + unsafeTokens("</arg_key><arg_value>")
          + tokens(value) + unsafeTokens("</arg_value>")
      }
      return callTokens + unsafeTokens("</tool_call>")
    }

    // The observation role also ends the assistant turn before it, as the model's stop token.
    func toolResultTokens(_ content: [Int32]) -> [Int32] {
      [GLM5_3TextGenerator.observationToken] + unsafeTokens("<tool_response>") + content
        + unsafeTokens("</tool_response>")
    }

    func tokens(_ text: String) -> [Int32] {
      GLM5_3TextGenerator.safeTokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
      ).1
    }

    func text(_ tokens: [Int32]) -> String {
      GLM5_3TextGenerator.safeTokenizer.decode(tokens)
    }

    private func unsafeTokens(_ text: String) -> [Int32] {
      GLM5_3TextGenerator.unsafeTokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
      ).1
    }
  }
}
