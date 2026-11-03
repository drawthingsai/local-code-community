import Foundation
import LLM
import NNC
import ProjectHistoryManager
import Tokenizer

/// What serving needs from a model family: the chat template going in, the tool-call format coming
/// out, and the family's own decode and caches. Everything else lives in `ResponsesAgent`.
protocol ResponsesModelAdapter: AnyObject {
  var filePath: String { get }
  var maximumContextLength: Int { get }
  var minimumGenerationReserve: Int { get }
  /// How many tokens the latest decode brought back from the context cache.
  var restoredTokenLength: Int? { get }
  /// How many tokens the KV cache holds after the latest decode.
  var kvCacheTokenLength: Int { get }
  /// The whole conversation up to and including the assistant's opening tokens.
  func promptTokens(for request: ResponsesRequest, isThinking: Bool) -> [Int32]
  func makeOutputParser(isThinking: Bool) -> ResponsesOutputParser
  func isTerminal(_ token: Int32) -> Bool
  func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    contextTokens: [Int32], thinkingBudget: Int, deterministic: Bool,
    handler: (Int, Int, [Int32], CodeAgentStatistics) -> ContinuationState
  ) -> [Int32]
  func resetCaches()
}

/// Finds tool calls in the text a model writes.
protocol ResponsesToolCallScanner {
  var toolCalls: [ToolCall] { get }
  /// The model's turn has nothing left to say, whether or not it stops by itself.
  var didCompleteToolCalls: Bool { get }
  mutating func append(_ text: String)
  /// `output` with its tool calls, and any start of one still being written, taken out.
  func visibleText(in output: String) -> String
}

/// Splits generated tokens into thinking, text and tool calls as they arrive, holding back bytes
/// that don't yet form a whole character.
struct ResponsesOutputParser {
  private let thinkEndToken: Int32
  private let isTerminal: (Int32) -> Bool
  private var scanner: any ResponsesToolCallScanner
  private var thinkStreamer: TiktokenTokenizer.TokenStreamer
  private var outputStreamer: TiktokenTokenizer.TokenStreamer
  private var toolCallStreamer: TiktokenTokenizer.TokenStreamer
  private(set) var isThinkingOpen: Bool
  private(set) var think = ""
  private var output = ""
  private(set) var thinkTokenCount = 0

  init(
    isThinking: Bool, thinkEndToken: Int32, isTerminal: @escaping (Int32) -> Bool,
    safeTokenizer: TiktokenTokenizer, unsafeTokenizer: TiktokenTokenizer,
    toolCallSpecialTokens: [Int32: String], scanner: any ResponsesToolCallScanner
  ) {
    self.thinkEndToken = thinkEndToken
    self.isTerminal = isTerminal
    self.scanner = scanner
    isThinkingOpen = isThinking
    thinkStreamer = safeTokenizer.makeTokenStreamer()
    outputStreamer = safeTokenizer.makeTokenStreamer(specialTokens: toolCallSpecialTokens)
    toolCallStreamer = unsafeTokenizer.makeTokenStreamer()
  }

  var toolCalls: [ToolCall] { scanner.toolCalls }
  var didCompleteToolCalls: Bool { scanner.didCompleteToolCalls }

  /// The text so far, without the model's whitespace around it. Trimming the end holds back the
  /// newline between text and a tool call, which belongs to neither.
  var visibleText: String {
    scanner.visibleText(in: output).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  mutating func append(_ tokens: [Int32]) {
    for token in tokens where !isTerminal(token) {
      if isThinkingOpen {
        if token == thinkEndToken {
          isThinkingOpen = false
          think += thinkStreamer.finish()
        } else {
          thinkTokenCount += 1
          think += thinkStreamer.append([token])
        }
      } else {
        output += outputStreamer.append([token])
        scanner.append(toolCallStreamer.append([token]))
      }
    }
  }

  mutating func finish() {
    think += thinkStreamer.finish()
    output += outputStreamer.finish()
    scanner.append(toolCallStreamer.finish())
  }
}

func responsesModelAdapter(for textGenerator: any TextGenerator, projectPath: String)
  -> (any ResponsesModelAdapter)?
{
  switch textGenerator {
  case let textGenerator as Qwen3_5TextGenerator:
    return Qwen3_5ResponsesModelAdapter(textGenerator: textGenerator, projectPath: projectPath)
  case let textGenerator as DeepSeek4TextGenerator:
    return DeepSeekResponsesModelAdapter(textGenerator: textGenerator, projectPath: projectPath)
  case let textGenerator as DeepSeek4_1TextGenerator:
    return DeepSeekResponsesModelAdapter(textGenerator: textGenerator, projectPath: projectPath)
  default:
    return nil
  }
}

final class Qwen3_5ResponsesModelAdapter: ResponsesModelAdapter {
  private struct Scanner: ResponsesToolCallScanner {
    var parser = Qwen3_5ToolCallParser()
    var toolCalls: [ToolCall] { parser.toolCalls }
    // The model ends its turn after the calls it wants.
    var didCompleteToolCalls: Bool { false }
    mutating func append(_ text: String) { parser.append(text) }
    func visibleText(in output: String) -> String {
      Qwen3_5ToolCallParser.removeToolCalls(output)
    }
  }

  private static let thinkEndToken: Int32 = 248_069
  private static let imEndToken: Int32 = 248_046
  private static let endOfTextToken: Int32 = 248_044

  private var textGenerator: Qwen3_5TextGenerator
  private let projectPath: String
  private var kvCache = [DynamicGraph.AnyTensor]()
  var kvCacheTokenLength: Int { textGenerator.kvCacheTokenLength }
  private var draftCache = [DynamicGraph.AnyTensor]()
  private(set) var restoredTokenLength: Int?

  init(textGenerator: Qwen3_5TextGenerator, projectPath: String) {
    self.textGenerator = textGenerator
    self.projectPath = projectPath
  }

  var filePath: String { textGenerator.filePath }
  var maximumContextLength: Int { Qwen3_5CodeAgent.maximumContextLength }
  var minimumGenerationReserve: Int { Qwen3_5CodeAgent.minimumGenerationReserve }

  func promptTokens(for request: ResponsesRequest, isThinking: Bool) -> [Int32] {
    let systemTokens = tokenizeSystemPromptSections(
      Self.systemSections(instructions: request.instructions, tools: request.tools),
      unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
      safeTokenizer: Qwen3_5TextGenerator.safeTokenizer)
    let assistantTokens = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: isThinking
        ? "<|im_start|>assistant\n<think>\n" : "<|im_start|>assistant\n<think>\n\n</think>\n\n",
      truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
    ).1
    return systemTokens + request.transcript.flatMap(Self.transcriptTokens) + assistantTokens
  }

  /// Assistant turns come out the way the model writes them, unlike the agent's transcript
  /// renderer, so that a client replaying a turn continues the KV cache instead of dropping it.
  private static func transcriptTokens(_ entry: AgentTranscriptEntry) -> [Int32] {
    guard case .assistant(let text, let thinking, let toolCalls) = entry else {
      return Qwen3_5CodeAgent.parse([entry])
    }
    func unsafeTokens(_ text: String) -> [Int32] {
      Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
      ).1
    }
    func safeTokens(_ text: String) -> [Int32] {
      Qwen3_5TextGenerator.safeTokenizer.tokenize(
        text: text, truncation: false, maxLength: 0, paddingToken: nil, addSpecialTokens: false
      ).1
    }
    // Without thinking, the same opening as the one `promptTokens` asked the model to continue.
    var tokens =
      thinking.isEmpty
      ? unsafeTokens("<|im_start|>assistant\n<think>\n\n</think>\n\n")
      : unsafeTokens("<|im_start|>assistant\n<think>\n") + safeTokens(thinking)
        + unsafeTokens("\n</think>\n\n")
    tokens += safeTokens(text + (text.isEmpty || toolCalls.isEmpty ? "" : "\n\n"))
    for (index, toolCall) in toolCalls.enumerated() {
      if index > 0 {
        tokens += safeTokens("\n")
      }
      // One piece of text, so it splits into the tokens a model writing it would use.
      var body = "\n<function=\(toolCall.function)>\n"
      for (name, parameter) in toolCall.parameters.sorted(by: { $0.key < $1.key }) {
        body += "<parameter=\(name)>\n\(parameter.value)\n</parameter>\n"
      }
      body += "</function>\n"
      tokens += unsafeTokens("<tool_call>")
      tokens += safeTokens(body)
      tokens += unsafeTokens("</tool_call>")
    }
    return tokens + unsafeTokens("<|im_end|>\n")
  }

  /// The tools part follows the agent's prompt, without the instructions meant for its own tools.
  static func systemSections(instructions: String, tools: [ResponsesRequest.Tool])
    -> [SystemPromptSection]
  {
    guard !instructions.isEmpty || !tools.isEmpty else { return [] }
    var sections: [SystemPromptSection] = [("<|im_start|>system\n", true)]
    if !tools.isEmpty {
      sections.append(("# Tools\n\nYou have access to the following functions:\n\n<tools>\n", true))
      sections.append((tools.map(\.schemaLine).joined(separator: "\n") + "\n", false))
      sections.append(
        (
          """
          </tools>

          If you choose to call a function ONLY reply in the following format with NO suffix:

          <tool_call>
          <function=example_function_name>
          <parameter=example_parameter_1>
          value_1
          </parameter>
          <parameter=example_parameter_2>
          This is the value for the second parameter
          that can span
          multiple lines
          </parameter>
          </function>
          </tool_call>

          <IMPORTANT>
          Reminder:
          - Function calls MUST follow the specified format: an inner <function=...></function> block must be nested within <tool_call></tool_call> XML tags
          - Required parameters MUST be specified
          - You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after
          - If there is no function call available, answer the question like normal with your current knowledge and do not tell the user about function calls
          </IMPORTANT>
          \(instructions.isEmpty ? "" : "\n")
          """, true
        ))
    }
    if !instructions.isEmpty {
      sections.append((instructions, false))
    }
    sections.append(("<|im_end|>\n", true))
    return sections
  }

  func makeOutputParser(isThinking: Bool) -> ResponsesOutputParser {
    ResponsesOutputParser(
      isThinking: isThinking, thinkEndToken: Self.thinkEndToken,
      isTerminal: { [self] in
        isTerminal($0)
      }, safeTokenizer: Qwen3_5TextGenerator.safeTokenizer,
      unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
      toolCallSpecialTokens: Qwen3_5ToolCallParser.toolCallSpecialTokens, scanner: Scanner())
  }

  func isTerminal(_ token: Int32) -> Bool {
    token == Self.imEndToken || token == Self.endOfTextToken
  }

  func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    contextTokens: [Int32], thinkingBudget: Int, deterministic: Bool,
    handler: (Int, Int, [Int32], CodeAgentStatistics) -> ContinuationState
  ) -> [Int32] {
    let contextCache = Qwen3_5ContextCache(
      projectPath: projectPath, checkpointStride: textGenerator.chunkedPrefillMaxLength)
    defer { restoredTokenLength = contextCache.restoredTokenLength }
    return textGenerator.decode(
      graph: graph, tokens: tokens, tokenOffset: tokenOffset, thinkingBudget: thinkingBudget,
      deterministic: deterministic, kvCache: &kvCache, draftCache: &draftCache,
      contextTokens: contextTokens, contextCache: contextCache
    ) { prefillStart, prefillLength, generatedTokens, statistics in
      Qwen3_5TextGenerator.ContinuationState(
        handler(
          prefillStart, prefillLength, generatedTokens,
          CodeAgentStatistics(
            prefillDurationSoFar: statistics.prefillDurationSoFar,
            prefillTokensSoFar: statistics.prefillTokensSoFar,
            tokenGenerationDurationSoFar: statistics.tokenGenerationDurationSoFar,
            tokenGeneratedSoFar: statistics.tokenGeneratedSoFar,
            contextUsedTokens: contextTokens.count + generatedTokens.count,
            contextWindowTokens: Qwen3_5CodeAgent.maximumContextLength)))
    }
  }

  func resetCaches() {
    textGenerator.ropeDelta = 0
    textGenerator.hasPaddedImages = false
    kvCache.removeAll(keepingCapacity: false)
    draftCache.removeAll(keepingCapacity: false)
  }
}

final class DeepSeekResponsesModelAdapter<Generator: DeepSeekTextGenerator>: ResponsesModelAdapter {
  private struct Scanner: ResponsesToolCallScanner {
    let format: DeepSeek4ToolCallParser.Format
    var parser: DeepSeek4ToolCallParser
    init(format: DeepSeek4ToolCallParser.Format) {
      self.format = format
      parser = DeepSeek4ToolCallParser(format: format)
    }
    var toolCalls: [ToolCall] { parser.toolCalls }
    // The agent stops here too, since the model can keep writing after its calls.
    var didCompleteToolCalls: Bool { parser.didCompleteToolCallBlock }
    mutating func append(_ text: String) { parser.append(text) }
    func visibleText(in output: String) -> String {
      ToolCallParser.removeToolCalls(output, format: format)
    }
  }

  private static var endOfSentenceToken: Int32 { 1 }
  private static var assistantToken: Int32 { 128_804 }
  private static var thinkStartToken: Int32 { 128_821 }
  private static var thinkEndToken: Int32 { 128_822 }

  private var textGenerator: Generator
  private let projectPath: String
  private var kvCache = Generator.KVCache()
  var kvCacheTokenLength: Int { kvCache.tokenLength }
  private(set) var restoredTokenLength: Int?

  init(textGenerator: Generator, projectPath: String) {
    self.textGenerator = textGenerator
    self.projectPath = projectPath
  }

  var filePath: String { textGenerator.filePath }
  var maximumContextLength: Int { DeepSeek4CodeAgent<Generator>.maximumContextLength }
  var minimumGenerationReserve: Int { DeepSeek4CodeAgent<Generator>.minimumGenerationReserve }

  func promptTokens(for request: ResponsesRequest, isThinking: Bool) -> [Int32] {
    let systemTokens = tokenizeSystemPromptSections(
      Self.systemSections(
        instructions: request.instructions, tools: request.tools, version: Generator.version),
      unsafeTokenizer: Generator.unsafeTokenizer, safeTokenizer: Generator.safeTokenizer)
    return systemTokens + DeepSeek4CodeAgent<Generator>.parse(request.transcript) + [
      Self.assistantToken, isThinking ? Self.thinkStartToken : Self.thinkEndToken,
    ]
  }

  /// The tools part follows the agent's prompt, without the instructions meant for its own tools.
  static func systemSections(
    instructions: String, tools: [ResponsesRequest.Tool], version: LLMVersion
  ) -> [SystemPromptSection] {
    let format = DeepSeek4ToolCallParser.Format(version: version)
    var sections: [SystemPromptSection] = [
      (
        version == .deepseek_4_1_flash
          ? "<｜begin▁of▁sentence｜><｜System｜>" : "<｜begin▁of▁sentence｜>", true
      )
    ]
    if !instructions.isEmpty {
      sections.append((instructions + (tools.isEmpty ? "" : "\n\n"), false))
    }
    if !tools.isEmpty {
      sections.append(
        (
          """
          ## DSML tools

          You have access to native DSML tools. Invoke tools by writing exactly this shape:

          \(format.toolCallStart)
          \(format.invokeStart) name="$TOOL_NAME">
          \(format.parameterStart) name="$PARAMETER_NAME" string="true|false">$PARAMETER_VALUE\(format.parameterEnd)
          \(format.invokeEnd)
          \(format.toolCallEnd)

          String parameters use raw text and string="true". All other types (numbers, booleans, arrays, objects) use JSON text and string="false".

          ## Available Tool Schemas


          """, true
        ))
      sections.append((tools.map(\.schemaLine).joined(separator: "\n"), false))
    }
    return sections
  }

  func makeOutputParser(isThinking: Bool) -> ResponsesOutputParser {
    ResponsesOutputParser(
      isThinking: isThinking, thinkEndToken: Self.thinkEndToken,
      isTerminal: { [self] in
        isTerminal($0)
      }, safeTokenizer: Generator.safeTokenizer, unsafeTokenizer: Generator.unsafeTokenizer,
      toolCallSpecialTokens: DeepSeek4ToolCallParser.toolCallSpecialTokens,
      scanner: Scanner(format: DeepSeek4ToolCallParser.Format(version: Generator.version)))
  }

  func isTerminal(_ token: Int32) -> Bool {
    token == Self.endOfSentenceToken
  }

  func decode(
    graph: DynamicGraph, tokens: DynamicGraph.Tensor<Int32>, tokenOffset: Int,
    contextTokens: [Int32], thinkingBudget: Int, deterministic: Bool,
    handler: (Int, Int, [Int32], CodeAgentStatistics) -> ContinuationState
  ) -> [Int32] {
    let contextCache = Generator.ContextCache(
      projectPath: projectPath, checkpointStride: textGenerator.checkpointStride)
    defer { restoredTokenLength = contextCache.restoredTokenLength }
    return textGenerator.decode(
      graph: graph, tokens: tokens, tokenOffset: tokenOffset, thinkingBudget: thinkingBudget,
      deterministic: deterministic, kvCache: &kvCache, contextTokens: contextTokens,
      contextCache: contextCache, embedSpans: [], projectPath: nil
    ) { prefillStart, prefillLength, generatedTokens, statistics in
      DeepSeekGenerationContinuationState(
        handler(
          prefillStart, prefillLength, generatedTokens,
          CodeAgentStatistics(
            prefillDurationSoFar: statistics.prefillDurationSoFar,
            prefillTokensSoFar: statistics.prefillTokensSoFar,
            tokenGenerationDurationSoFar: statistics.tokenGenerationDurationSoFar,
            tokenGeneratedSoFar: statistics.tokenGeneratedSoFar,
            contextUsedTokens: contextTokens.count + generatedTokens.count,
            contextWindowTokens: DeepSeek4CodeAgent<Generator>.maximumContextLength)))
    }
  }

  func resetCaches() {
    kvCache = Generator.KVCache()
  }
}
