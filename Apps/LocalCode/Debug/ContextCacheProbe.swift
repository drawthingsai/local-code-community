import Foundation
import LLM
import NNC

private struct ProbeResult {
  var tokens: [Int32]
  var text: String
}

private enum ProbeError: LocalizedError {
  case missingValue(String)
  case unknownArgument(String)
  case invalidInteger(String, String)
  case invalidScenario(String)
  case missingModel(String)

  var errorDescription: String? {
    switch self {
    case .missingValue(let option):
      return "Missing value for \(option)."
    case .unknownArgument(let argument):
      return "Unknown argument: \(argument)."
    case .invalidInteger(let option, let value):
      return "Invalid integer for \(option): \(value)."
    case .invalidScenario(let scenario):
      return
        "Invalid scenario: \(scenario). Use same-prompt, save-only, prime-only, seed-prefix, or all."
    case .missingModel(let path):
      return "Model checkpoint does not exist: \(path)."
    }
  }
}

private enum Scenario: String {
  case samePrompt = "same-prompt"
  case saveOnly = "save-only"
  case primeOnly = "prime-only"
  case seedPrefix = "seed-prefix"
  case all
}

private struct ProbeOptions {
  var modelPath =
    "~/Library/Containers/3FF07B09-E372-4369-B2C8-8B80DD420025/Data/Documents/Models/qwen_3.6_27b_i2x.ckpt"
  var projectPath = "/private/tmp/localcode-context-cache-probe"
  var prompt = "Without looking online, can you write a sudoku solver."
  var seedPrompt = "Without looking online, explain what a binary search tree is."
  var maxNewTokens = 64
  var seedMaxNewTokens = 1
  var thinkingBudget = 32_768
  var scenario = Scenario.seedPrefix
  var clearCache = true
  var printText = true
  var printTokenIds = true
  var progressEvery = 0
  var stopOnBashToolCall = false
  var toolCallTailTokens = 128
  var queueWatermark: Int? = nil
  var disableMFAAppleNeuralEngine = false

  static func parse() throws -> ProbeOptions {
    var options = ProbeOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      func value() throws -> String {
        guard !arguments.isEmpty else { throw ProbeError.missingValue(argument) }
        return arguments.removeFirst()
      }
      func integerValue() throws -> Int {
        let rawValue = try value()
        guard let parsed = Int(rawValue) else {
          throw ProbeError.invalidInteger(argument, rawValue)
        }
        return parsed
      }
      switch argument {
      case "--model-path":
        options.modelPath = try value()
      case "--project-path":
        options.projectPath = try value()
      case "--prompt":
        options.prompt = try value()
      case "--seed-prompt":
        options.seedPrompt = try value()
      case "--max-new-tokens":
        options.maxNewTokens = try integerValue()
      case "--seed-max-new-tokens":
        options.seedMaxNewTokens = try integerValue()
      case "--thinking-budget":
        options.thinkingBudget = try integerValue()
      case "--scenario":
        let rawValue = try value()
        guard let scenario = Scenario(rawValue: rawValue) else {
          throw ProbeError.invalidScenario(rawValue)
        }
        options.scenario = scenario
      case "--keep-cache":
        options.clearCache = false
      case "--clear-cache":
        options.clearCache = true
      case "--no-text":
        options.printText = false
      case "--no-token-ids":
        options.printTokenIds = false
      case "--progress-every":
        options.progressEvery = try integerValue()
      case "--stop-on-bash-tool-call":
        options.stopOnBashToolCall = true
      case "--tool-call-tail-tokens":
        options.toolCallTailTokens = try integerValue()
      case "--queue-watermark":
        options.queueWatermark = try integerValue()
      case "--disable-mfa-apple-neural-engine":
        options.disableMFAAppleNeuralEngine = true
      default:
        throw ProbeError.unknownArgument(argument)
      }
    }
    options.modelPath = (options.modelPath as NSString).expandingTildeInPath
    options.projectPath = (options.projectPath as NSString).expandingTildeInPath
    return options
  }
}

@main
private struct ContextCacheProbe {
  static func main() throws {
    let options = try ProbeOptions.parse()
    guard FileManager.default.fileExists(atPath: options.modelPath) else {
      throw ProbeError.missingModel(options.modelPath)
    }

    let oldQueueWatermark = DynamicGraph.queueWatermark
    if let queueWatermark = options.queueWatermark {
      DynamicGraph.queueWatermark = queueWatermark
    }
    defer {
      if options.queueWatermark != nil {
        DynamicGraph.queueWatermark = oldQueueWatermark
      }
    }

    let oldFlags = DynamicGraph.flags
    if options.disableMFAAppleNeuralEngine {
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    }
    defer {
      if options.disableMFAAppleNeuralEngine {
        DynamicGraph.flags = oldFlags
      }
    }

    emit("model_path: \(options.modelPath)")
    emit("project_path: \(options.projectPath)")
    emit("cache_path: \(cachePath(projectPath: options.projectPath))")
    emit("scenario: \(options.scenario.rawValue)")
    emit("thinking_budget: \(options.thinkingBudget)")
    emit("tokenizing_target_prompt")
    let targetTokens = promptTokens(for: options.prompt, thinkingBudget: options.thinkingBudget)
    emit("tokenizing_seed_prompt")
    let seedTokens = promptTokens(for: options.seedPrompt, thinkingBudget: options.thinkingBudget)
    emit("target_prompt_tokens: \(targetTokens.count)")
    emit("seed_prompt_tokens: \(seedTokens.count)")
    emit("max_new_tokens: \(options.maxNewTokens)")
    emit("progress_every: \(options.progressEvery)")
    emit("stop_on_bash_tool_call: \(options.stopOnBashToolCall)")

    switch options.scenario {
    case .samePrompt:
      try runSamePromptScenario(options: options, targetTokens: targetTokens)
    case .saveOnly:
      try runSaveOnlyScenario(options: options, targetTokens: targetTokens)
    case .primeOnly:
      try runPrimeOnlyScenario(options: options, targetTokens: targetTokens)
    case .seedPrefix:
      try runSeedPrefixScenario(
        options: options, targetTokens: targetTokens, seedTokens: seedTokens)
    case .all:
      try runSamePromptScenario(options: options, targetTokens: targetTokens)
      try runSaveOnlyScenario(options: options, targetTokens: targetTokens)
      try runPrimeOnlyScenario(options: options, targetTokens: targetTokens)
      try runSeedPrefixScenario(
        options: options, targetTokens: targetTokens, seedTokens: seedTokens)
    }
  }

  private static func runSamePromptScenario(
    options: ProbeOptions, targetTokens: [Int32]
  ) throws {
    emit("scenario_begin: same-prompt")
    if options.clearCache {
      clearCache(projectPath: options.projectPath)
    }
    let baseline = try run(
      name: "baseline_no_cache", modelPath: options.modelPath, tokens: targetTokens,
      thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
      projectPath: nil, progressEvery: options.progressEvery, options: options)
    emit(result: baseline, name: "baseline_no_cache", baseline: nil, options: options)

    let prime = try run(
      name: "prime_same_prompt", modelPath: options.modelPath, tokens: targetTokens,
      thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
      projectPath: options.projectPath, progressEvery: options.progressEvery, options: options)
    emit(result: prime, name: "prime_same_prompt", baseline: baseline, options: options)

    let hit = try run(
      name: "hit_same_prompt", modelPath: options.modelPath, tokens: targetTokens,
      thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
      projectPath: options.projectPath, progressEvery: options.progressEvery, options: options)
    emit(result: hit, name: "hit_same_prompt", baseline: baseline, options: options)
    emit("scenario_end: same-prompt")
  }

  private static func runSaveOnlyScenario(
    options: ProbeOptions, targetTokens: [Int32]
  ) throws {
    emit("scenario_begin: save-only")
    if options.clearCache {
      clearCache(projectPath: options.projectPath)
    }
    let baseline =
      options.stopOnBashToolCall
      ? try runConversation(
        name: "baseline_no_cache", modelPath: options.modelPath, prompt: options.prompt,
        thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
        projectPath: nil, progressEvery: options.progressEvery, options: options)
      : try run(
        name: "baseline_no_cache", modelPath: options.modelPath, tokens: targetTokens,
        thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
        projectPath: nil, progressEvery: options.progressEvery, options: options)
    emit(result: baseline, name: "baseline_no_cache", baseline: nil, options: options)

    if options.clearCache {
      clearCache(projectPath: options.projectPath)
    }
    let cacheEnabled =
      options.stopOnBashToolCall
      ? try runConversation(
        name: "cache_enabled", modelPath: options.modelPath, prompt: options.prompt,
        thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
        projectPath: options.projectPath, progressEvery: options.progressEvery, options: options)
      : try run(
        name: "cache_enabled_empty", modelPath: options.modelPath, tokens: targetTokens,
        thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
        projectPath: options.projectPath, progressEvery: options.progressEvery, options: options)
    emit(result: cacheEnabled, name: "cache_enabled_empty", baseline: baseline, options: options)
    emit("scenario_end: save-only")
  }

  private static func runPrimeOnlyScenario(
    options: ProbeOptions, targetTokens: [Int32]
  ) throws {
    emit("scenario_begin: prime-only")
    if options.clearCache {
      clearCache(projectPath: options.projectPath)
    }
    let cacheEnabled = try run(
      name: "prime_only", modelPath: options.modelPath, tokens: targetTokens,
      thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
      projectPath: options.projectPath, progressEvery: options.progressEvery, options: options)
    emit(result: cacheEnabled, name: "prime_only", baseline: nil, options: options)
    emit("scenario_end: prime-only")
  }

  private static func runSeedPrefixScenario(
    options: ProbeOptions, targetTokens: [Int32], seedTokens: [Int32]
  ) throws {
    emit("scenario_begin: seed-prefix")
    if options.clearCache {
      clearCache(projectPath: options.projectPath)
    }
    let baseline = try run(
      name: "baseline_no_cache", modelPath: options.modelPath, tokens: targetTokens,
      thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
      projectPath: nil, progressEvery: options.progressEvery, options: options)
    emit(result: baseline, name: "baseline_no_cache", baseline: nil, options: options)

    let seed = try run(
      name: "seed_cache", modelPath: options.modelPath, tokens: seedTokens,
      thinkingBudget: options.thinkingBudget, maxNewTokens: options.seedMaxNewTokens,
      projectPath: options.projectPath, progressEvery: options.progressEvery, options: options)
    emit(result: seed, name: "seed_cache", baseline: nil, options: options)

    let hit = try run(
      name: "hit_after_seed", modelPath: options.modelPath, tokens: targetTokens,
      thinkingBudget: options.thinkingBudget, maxNewTokens: options.maxNewTokens,
      projectPath: options.projectPath, progressEvery: options.progressEvery, options: options)
    emit(result: hit, name: "hit_after_seed", baseline: baseline, options: options)
    emit("scenario_end: seed-prefix")
  }

  private static func run(
    name: String, modelPath: String, tokens: [Int32], thinkingBudget: Int, maxNewTokens: Int,
    projectPath: String?, progressEvery: Int, options: ProbeOptions
  ) throws -> ProbeResult {
    emit("run_begin: \(name)")
    var generator = Qwen3_5TextGenerator(
      filePath: modelPath, configuration: .qwen3_5_27B, tieEmbedding: false,
      chunkedPrefillMaxLength: 2_048)
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let streamContext = StreamContext(.GPU(0))
    var kvCache = [DynamicGraph.AnyTensor]()
    var draftCache = [DynamicGraph.AnyTensor]()
    let contextCache = Qwen3_5ContextCache(
      projectPath: projectPath, checkpointStride: generator.chunkedPrefillMaxLength)
    let tokenLimit = max(1, maxNewTokens)
    var toolCallStopTokenCount: Int? = nil
    let generated = graph.withStream(streamContext) {
      graph.withNoGrad {
        let tokenGPU = graph.variable(Tensor<Int32>(tokens).toGPU(0))
        return generator.decode(
          graph: graph, tokens: tokenGPU, tokenOffset: 0, thinkingBudget: thinkingBudget,
          kvCache: &kvCache, draftCache: &draftCache, contextTokens: tokens,
          contextCache: contextCache
        ) { _, _, generated, _ in
          if progressEvery > 0 && generated.count % progressEvery == 0 {
            emit("\(name)_progress_generated_tokens: \(generated.count)")
          }
          if options.stopOnBashToolCall {
            let text = Qwen3_5TextGenerator.unsafeTokenizer.decode(generated)
            if let toolCallRange = text.range(of: "<tool_call>") {
              let toolCallText = text[toolCallRange.lowerBound...]
              if toolCallText.contains("bash") {
                if toolCallStopTokenCount == nil {
                  toolCallStopTokenCount = min(
                    tokenLimit, generated.count + max(0, options.toolCallTailTokens))
                  emit("\(name)_bash_tool_call_seen_at: \(generated.count)")
                }
                if toolCallText.contains("</tool_call>") {
                  emit("\(name)_bash_tool_call_closed_at: \(generated.count)")
                  return false
                }
              }
            }
            if let toolCallStopTokenCount = toolCallStopTokenCount,
              generated.count >= toolCallStopTokenCount
            {
              emit("\(name)_bash_tool_call_tail_stop_at: \(generated.count)")
              return false
            }
          }
          return generated.count < tokenLimit
        }
      }
    }
    emit("run_end: \(name)")
    return ProbeResult(
      tokens: generated, text: Qwen3_5TextGenerator.unsafeTokenizer.decode(generated))
  }

  private static func runConversation(
    name: String, modelPath: String, prompt: String, thinkingBudget: Int, maxNewTokens: Int,
    projectPath: String?, progressEvery: Int, options: ProbeOptions
  ) throws -> ProbeResult {
    emit("conversation_begin: \(name)")
    var generator = Qwen3_5TextGenerator(
      filePath: modelPath, configuration: .qwen3_5_27B, tieEmbedding: false,
      chunkedPrefillMaxLength: 2_048)
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let streamContext = StreamContext(.GPU(0))
    var kvCache = [DynamicGraph.AnyTensor]()
    var draftCache = [DynamicGraph.AnyTensor]()
    let contextCache = Qwen3_5ContextCache(
      projectPath: projectPath, checkpointStride: generator.chunkedPrefillMaxLength)
    let tokenLimit = max(1, maxNewTokens)
    let (_, systemTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: systemPromptForQwen3_5, truncation: false, maxLength: 0)
    let (_, localPrefixTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: "<|im_start|>user\n", truncation: false, maxLength: 0)
    let suffix: String
    if thinkingBudget > 0 {
      suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n"
    } else {
      suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }
    let (_, suffixTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: suffix, truncation: false, maxLength: 0)
    let (_, toolResponsePrefixTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: "<tool_response>", truncation: false, maxLength: 0)
    let (_, toolResponseSuffixTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: "</tool_response>", truncation: false, maxLength: 0)

    var prefixTokens = [Int32]()
    var (_, userTokens, _, _, _) = Qwen3_5TextGenerator.safeTokenizer.tokenize(
      text: prompt, truncation: false, maxLength: 0)
    var allGenerated = [Int32]()
    var allText = ""
    var parser = Qwen3_5ToolCallParser()
    var turnIndex = 0
    var didHitBash = false
    while allGenerated.count < tokenLimit && turnIndex < 8 {
      let tokens: [Int32]
      let tokenOffset: Int
      let contextTokens: [Int32]
      if kvCache.isEmpty {
        tokens = systemTokens + prefixTokens + localPrefixTokens + userTokens + suffixTokens
        tokenOffset = 0
        contextTokens = tokens
      } else {
        tokens = localPrefixTokens + userTokens + suffixTokens
        tokenOffset = systemTokens.count + prefixTokens.count
        contextTokens = systemTokens + prefixTokens + tokens
      }
      emit("\(name)_turn_begin: \(turnIndex)")
      let remainingTokenLimit = max(1, tokenLimit - allGenerated.count)
      var toolCallStopTokenCount: Int? = nil
      let turnOutput = graph.withStream(streamContext) {
        graph.withNoGrad {
          let tokenGPU = graph.variable(Tensor<Int32>(tokens).toGPU(0))
          return generator.decode(
            graph: graph, tokens: tokenGPU, tokenOffset: tokenOffset,
            thinkingBudget: thinkingBudget, kvCache: &kvCache, draftCache: &draftCache,
            contextTokens: contextTokens, contextCache: contextCache
          ) { _, _, generated, _ in
            let totalGeneratedCount = allGenerated.count + generated.count
            if progressEvery > 0 && totalGeneratedCount % progressEvery == 0 {
              emit("\(name)_progress_generated_tokens: \(totalGeneratedCount)")
            }
            let text = Qwen3_5TextGenerator.unsafeTokenizer.decode(generated)
            if let toolCallRange = text.range(of: "<tool_call>") {
              let toolCallText = text[toolCallRange.lowerBound...]
              if toolCallText.contains("bash") {
                didHitBash = true
                if toolCallStopTokenCount == nil {
                  toolCallStopTokenCount = min(
                    remainingTokenLimit, generated.count + max(0, options.toolCallTailTokens))
                  emit("\(name)_bash_tool_call_seen_at: \(totalGeneratedCount)")
                }
                if toolCallText.contains("</tool_call>") {
                  emit("\(name)_bash_tool_call_closed_at: \(totalGeneratedCount)")
                  return false
                }
              }
            }
            if let toolCallStopTokenCount = toolCallStopTokenCount,
              generated.count >= toolCallStopTokenCount
            {
              emit("\(name)_bash_tool_call_tail_stop_at: \(totalGeneratedCount)")
              return false
            }
            return generated.count < remainingTokenLimit
          }
        }
      }
      emit("\(name)_turn_end: \(turnIndex)")
      allGenerated += turnOutput
      let turnText = Qwen3_5TextGenerator.unsafeTokenizer.decode(turnOutput)
      allText += turnText
      prefixTokens += localPrefixTokens + userTokens + suffixTokens + turnOutput
      let parserResult = parser.append(turnText)
      let toolCalls = parserResult.toolCalls
      emit(
        "\(name)_turn_tool_calls: \(toolCalls.map { $0.request.function }.joined(separator: ","))")
      if didHitBash || toolCalls.contains(where: { $0.request.function == "bash" }) {
        break
      }
      guard !toolCalls.isEmpty else {
        break
      }
      var toolTokens = [Int32]()
      for toolCall in toolCalls {
        let response = syntheticToolResponse(for: toolCall)
        let (_, responseTokens, _, _, _) = Qwen3_5TextGenerator.safeTokenizer.tokenize(
          text: "\n" + response + "\n", truncation: false, maxLength: 0)
        toolTokens += toolResponsePrefixTokens + responseTokens + toolResponseSuffixTokens
      }
      userTokens = toolTokens
      parser.reset()
      turnIndex += 1
    }
    emit("conversation_end: \(name)")
    return ProbeResult(tokens: allGenerated, text: allText)
  }

  private static func syntheticToolResponse(for toolCall: ToolCall) -> String {
    switch toolCall.request.function {
    case "write":
      let path =
        toolCall.request.parameters["path"]?.value
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "file"
      let content = toolCall.request.parameters["content"]?.value ?? ""
      return "Wrote \(Data(content.utf8).count) bytes to \(path)"
    default:
      return "OK"
    }
  }

  private static func promptTokens(for prompt: String, thinkingBudget: Int) -> [Int32] {
    let (_, systemTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: systemPromptForQwen3_5, truncation: false, maxLength: 0)
    let (_, prefixTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: "<|im_start|>user\n", truncation: false, maxLength: 0)
    let suffix: String
    if thinkingBudget > 0 {
      suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n"
    } else {
      suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }
    let (_, suffixTokens, _, _, _) = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
      text: suffix, truncation: false, maxLength: 0)
    let (_, userTokens, _, _, _) = Qwen3_5TextGenerator.safeTokenizer.tokenize(
      text: prompt, truncation: false, maxLength: 0)
    return systemTokens + prefixTokens + userTokens + suffixTokens
  }

  private static func emit(
    result: ProbeResult, name: String, baseline: ProbeResult?, options: ProbeOptions
  ) {
    emit("\(name)_generated_tokens: \(result.tokens.count)")
    if options.printTokenIds {
      emit("\(name)_generated_ids: \(result.tokens.map(String.init).joined(separator: ","))")
    }
    if let baseline = baseline {
      emit("\(name)_matches_baseline: \(result.tokens == baseline.tokens)")
      if let mismatch = firstMismatch(result.tokens, baseline.tokens) {
        let lhs = mismatch < result.tokens.count ? String(result.tokens[mismatch]) : "nil"
        let rhs = mismatch < baseline.tokens.count ? String(baseline.tokens[mismatch]) : "nil"
        emit("\(name)_first_mismatch_index: \(mismatch)")
        emit("\(name)_first_mismatch_token: \(lhs)")
        emit("\(name)_baseline_token: \(rhs)")
      }
    }
    if options.printText {
      emit("\(name)_text_begin")
      emit(result.text)
      emit("\(name)_text_end")
    }
    if let snippet = bashToolCallSnippet(in: result.text) {
      emit("\(name)_bash_tool_call_snippet_begin")
      emit(snippet)
      emit("\(name)_bash_tool_call_snippet_end")
    }
  }

  private static func bashToolCallSnippet(in text: String) -> String? {
    var index = text.startIndex
    while let startRange = text[index...].range(of: "<tool_call>") {
      let tail = text[startRange.lowerBound...]
      if let end = tail.range(of: "</tool_call>")?.upperBound {
        let block = String(tail[..<end])
        if block.contains("bash") {
          return block
        }
        index = end
      } else {
        let block = String(tail.prefix(2_000))
        return block.contains("bash") ? block : nil
      }
    }
    return nil
  }

  private static func firstMismatch(_ lhs: [Int32], _ rhs: [Int32]) -> Int? {
    let count = min(lhs.count, rhs.count)
    for index in 0..<count where lhs[index] != rhs[index] {
      return index
    }
    return lhs.count == rhs.count ? nil : count
  }

  private static func cachePath(projectPath: String) -> String {
    URL(fileURLWithPath: projectPath, isDirectory: true)
      .appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("context_cache.sqlite3").path
  }

  private static func emit(_ line: String) {
    if let data = (line + "\n").data(using: .utf8) {
      FileHandle.standardOutput.write(data)
    }
  }

  private static func clearCache(projectPath: String) {
    let path = cachePath(projectPath: projectPath)
    if FileManager.default.fileExists(atPath: path) {
      try? FileManager.default.removeItem(atPath: path)
    }
  }
}
