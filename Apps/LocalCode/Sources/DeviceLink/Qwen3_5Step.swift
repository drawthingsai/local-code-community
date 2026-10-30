import Foundation
import NNC
import RemoteAPI
import Tokenizer

/// A step's result as the Inference service sends it, as JSON: what a remote agent's chat provider
/// returns for one request.
struct InferenceStepCompletion: Codable {
  var content: [RemoteContentBlock]
  var usage: RemoteUsage?
  var stopReason: String?
}

/// One step of one of the Mac's Qwen models for another device's thread (Inference). The device runs
/// its agent and tools; the step reads the Mac's own tool instructions with the device's system
/// prompt as its context, then the device's transcript, and writes the model's reasoning, answer and
/// tool calls. Reading starts from the longest prefix the device's context cache on the Mac holds,
/// so a thread's next step mostly reads what's new. Runs on the generation queue.
struct Qwen3_5Step {
  enum Error: Swift.Error {
    case cancelled
  }

  let textGenerator: Qwen3_5TextGenerator
  let graph: DynamicGraph
  let streamContext: StreamContext
  let reasoningEffort: ReasoningEffort
  let thinkingBudget: Int
  let deterministic: Bool
  /// The device's folder on the Mac, where its context cache lives.
  let cachePath: String

  /// The step's events go out at most this often while it writes.
  private static let progressInterval: TimeInterval = 0.1

  func run(
    _ transcript: [RemoteTranscriptEntry], maximumOutputTokens: Int,
    isCancelled: @escaping () -> Bool, reading: @escaping (_ finished: Int, _ total: Int) -> Void,
    progress: @escaping ([RemoteContentBlock]) -> Void
  ) throws -> InferenceStepCompletion {
    // The device's own instructions describe where its tools run; they take the place of the
    // project's context in the Mac's prompt, which carries the tools themselves.
    let systemText = transcript.filter { $0.role == .system }.flatMap(\.content).compactMap {
      block -> String? in
      guard case .text(let text) = block else { return nil }
      return text
    }.joined(separator: "\n\n")
    let systemTokens = Qwen3_5CodeAgent.systemTokens(
      systemPromptTemplate: systemPromptForQwen3_5, reasoningEffort: .init(reasoningEffort),
      memoryContext: .empty, skillCatalog: .empty,
      projectContext: ProjectContext(content: systemText), environmentContext: .empty,
      unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
      safeTokenizer: textGenerator.safeTokenizer)
    let transcriptTokens = Qwen3_5CodeAgent.parse(try RemoteAgentTranscriptAdapter.parse(transcript))
    let opener = Qwen3_5CodeAgent.unsafeTokens(
      thinkingBudget > 0
        ? "<|im_start|>assistant\n<think>\n" : "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    let contextTokens = systemTokens + transcriptTokens + opener
    let stepThinkingBudget =
      thinkingBudget > 0
      ? min(
        thinkingBudget,
        max(
          1,
          Qwen3_5CodeAgent.maximumContextLength - contextTokens.count
            - Qwen3_5CodeAgent.minimumGenerationReserve))
      : 0
    var textGenerator = textGenerator
    var kvCache = [DynamicGraph.AnyTensor]()
    var draftCache = [DynamicGraph.AnyTensor]()
    let contextCache = Qwen3_5ContextCache(
      projectPath: cachePath, checkpointStride: textGenerator.chunkedPrefillMaxLength)
    var lastProgress = Date.distantPast
    var wasCancelled = false
    let tokens = graph.withStream(streamContext) {
      graph.withNoGrad {
        textGenerator.decode(
          graph: graph, tokens: graph.variable(Tensor<Int32>(contextTokens).toGPU(0)),
          tokenOffset: 0, thinkingBudget: stepThinkingBudget, deterministic: deterministic,
          kvCache: &kvCache, draftCache: &draftCache, contextTokens: contextTokens,
          contextCache: contextCache, projectPath: cachePath
        ) { prefillStart, prefillLength, generatedTokens, _ in
          guard !isCancelled() else {
            wasCancelled = true
            return .abort
          }
          guard !generatedTokens.isEmpty else {
            reading(prefillStart, prefillLength)
            return .continue
          }
          guard generatedTokens.count <= stepThinkingBudget + maximumOutputTokens else {
            return .abort
          }
          let now = Date()
          if now.timeIntervalSince(lastProgress) >= Self.progressInterval {
            lastProgress = now
            progress(content(of: generatedTokens))
          }
          return .continue
        }
      }
    }
    guard !wasCancelled else { throw Error.cancelled }
    var generated = tokens
    while generated.last == 248_046 || generated.last == 248_044 { generated.removeLast() }
    let content = content(of: generated)
    return InferenceStepCompletion(
      content: content,
      usage: RemoteUsage(
        promptTokens: contextTokens.count, completionTokens: tokens.count,
        totalTokens: contextTokens.count + tokens.count),
      stopReason: content.contains {
        if case .toolCall = $0 { return true }
        return false
      } ? "tool_calls" : "stop")
  }

  /// The reasoning, the answer without its tool calls, and the tool calls written in full, as a
  /// remote model writes them. While writing, a reasoning that hasn't ended is all there is.
  private func content(of tokens: [Int32]) -> [RemoteContentBlock] {
    let thinkTokens: [Int32]
    let outputTokens: [Int32]
    if thinkingBudget > 0 {
      if let endThinkIndex = tokens.firstIndex(of: 248_069) {
        thinkTokens = Array(tokens[..<endThinkIndex])
        outputTokens = Array(tokens[tokens.index(after: endThinkIndex)...])
      } else {
        thinkTokens = tokens
        outputTokens = []
      }
    } else {
      thinkTokens = []
      outputTokens = tokens
    }
    var parser = Qwen3_5ToolCallParser()
    var streamer = Qwen3_5TextGenerator.unsafeTokenizer.makeTokenStreamer()
    parser.append(streamer.append(outputTokens))
    parser.append(streamer.finish())
    let think = textGenerator.safeTokenizer.decode(thinkTokens).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let text = ToolCallParser.removeToolCalls(
      textGenerator.safeTokenizer.decode(
        outputTokens, specialTokens: Qwen3_5ToolCallParser.toolCallSpecialTokens),
      toolCallStart: Qwen3_5ToolCallParser.toolCallStart,
      toolCallEnd: Qwen3_5ToolCallParser.toolCallEnd
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    var content = [RemoteContentBlock]()
    if !think.isEmpty { content.append(.thinking(RemoteThinking(text: think))) }
    if !text.isEmpty { content.append(.text(text)) }
    content += parser.toolCalls.map { toolCall in
      .toolCall(
        RemoteToolCall(
          id: "call_\(toolCall.id)", name: toolCall.request.function,
          arguments: Self.arguments(toolCall.request.parameters)))
    }
    return content
  }

  /// A tool call's parameters as a remote model writes them: JSON, strings as strings.
  private static func arguments(_ parameters: [String: ToolCall.Request.Parameter]) -> String {
    var object = [String: Any]()
    for (name, parameter) in parameters {
      if !parameter.string, let data = parameter.value.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      {
        object[name] = value
      } else {
        object[name] = parameter.value
      }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }
}
