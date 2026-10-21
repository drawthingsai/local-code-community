import Foundation
import NNC

private enum LongBenchEvalError: Error {
  case invalidArgument(String)
  case invalidInput(String)
}

private struct LongBenchProblem: Decodable {
  let id: String
  let domain: String
  let subDomain: String
  let difficulty: String
  let length: String
  let context: String
  let question: String
  let choiceA: String
  let choiceB: String
  let choiceC: String
  let choiceD: String
  let answer: String

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case domain
    case subDomain = "sub_domain"
    case difficulty, length, context, question, answer
    case choiceA = "choice_A"
    case choiceB = "choice_B"
    case choiceC = "choice_C"
    case choiceD = "choice_D"
  }
}

private struct LongBenchInput: Codable {
  let id: String
  let domain: String
  let subDomain: String
  let difficulty: String
  let length: String
  let expectedAnswer: String
  let promptTokenIDs: [Int32]
  let thinkingBudget: Int?
  let reasoningEffort: String?
}

private struct LongBenchResult: Encodable {
  let id: String
  let seed: UInt32
  let domain: String
  let expectedAnswer: String
  let extractedAnswer: String?
  let score: Int
  let promptTokenCount: Int
  let generatedTokenCount: Int
  let thinkingBudget: Int
  let reasoningEffort: String?
  let thinkingTokenCount: Int
  let firstEndThinkIndex: Int?
  let thinkingBoundaryAtCap: Bool
  let answerTokenCount: Int
  let prefillSeconds: Double
  let durationSeconds: Double
  let stopReason: String
  let generatedTokenIDs: [Int32]
  let output: String
  let answerOutput: String
}

/// A paired attention evaluation using LongBench v2's official zero-shot prompt and scorer.
///
/// Preparation is CPU-only; saved token IDs make both attention arms consume identical inputs.
@main
private struct QwenLongBenchV2EvalCLI {
  static func main() throws {
    var datasetPath = ""
    var outputPath = ""
    var modelPath = ""
    var prepareOnly = false
    var maxNewTokens = 128
    var thinkingBudget = 0
    var reasoningEffort = "medium"
    var baseSeed: UInt32 = 42
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      if argument == "--prepare-only" {
        prepareOnly = true
        continue
      }
      guard !arguments.isEmpty else { throw LongBenchEvalError.invalidArgument(argument) }
      let value = arguments.removeFirst()
      switch argument {
      case "--dataset": datasetPath = value
      case "--output-jsonl": outputPath = value
      case "--model-path": modelPath = value
      case "--max-new-tokens":
        guard let count = Int(value), (1...131_072).contains(count) else {
          throw LongBenchEvalError.invalidArgument(argument)
        }
        maxNewTokens = count
      case "--thinking-budget":
        guard let count = Int(value), (0...131_071).contains(count) else {
          throw LongBenchEvalError.invalidArgument(argument)
        }
        thinkingBudget = count
      case "--reasoning-effort":
        // Match Qwen3.8's official medium template: thinking on, no extra system instruction.
        guard value == "medium" else { throw LongBenchEvalError.invalidArgument(argument) }
        reasoningEffort = value
      case "--seed":
        guard let seed = UInt32(value) else { throw LongBenchEvalError.invalidArgument(argument) }
        baseSeed = seed
      default: throw LongBenchEvalError.invalidArgument(argument)
      }
    }
    guard maxNewTokens > thinkingBudget,
      FileManager.default.fileExists(atPath: datasetPath), !outputPath.isEmpty,
      !FileManager.default.fileExists(atPath: outputPath)
    else { throw LongBenchEvalError.invalidArgument("Fresh output and existing dataset required") }
    let data = try String(contentsOfFile: datasetPath, encoding: .utf8)
    // JSONL records are LF-separated; U+0085/U+2028/U+2029 can occur inside valid JSON strings.
    let lines = data.split(separator: "\n")
    guard !lines.isEmpty else { throw LongBenchEvalError.invalidInput("Empty dataset") }
    let encoder = JSONEncoder()
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: outputURL, options: .withoutOverwriting)
    let handle = try FileHandle(forWritingTo: outputURL)
    defer { try? handle.close() }
    if prepareOnly {
      for line in lines {
        let problem = try JSONDecoder().decode(LongBenchProblem.self, from: Data(line.utf8))
        guard ["A", "B", "C", "D"].contains(problem.answer) else {
          throw LongBenchEvalError.invalidInput(problem.id)
        }
        // Official prompts/0shot.txt; no truncation or extra system instruction.
        let userPrompt = """
          Please read the following text and answer the question below.

          <text>
          \(problem.context.trimmingCharacters(in: .whitespacesAndNewlines))
          </text>

          What is the correct answer to this question: \(problem.question.trimmingCharacters(in: .whitespacesAndNewlines))
          Choices:
          (A) \(problem.choiceA.trimmingCharacters(in: .whitespacesAndNewlines))
          (B) \(problem.choiceB.trimmingCharacters(in: .whitespacesAndNewlines))
          (C) \(problem.choiceC.trimmingCharacters(in: .whitespacesAndNewlines))
          (D) \(problem.choiceD.trimmingCharacters(in: .whitespacesAndNewlines))

          Format your response as follows: "The correct answer is (insert answer here)".
          """
        let prefix = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
          text: "<|im_start|>user\n", addSpecialTokens: false
        ).0
        let content = Qwen3_5TextGenerator.safeTokenizer.tokenize(
          text: userPrompt, truncation: false, maxLength: 0, paddingToken: nil,
          addSpecialTokens: false
        ).1
        let suffix = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
          text: thinkingBudget > 0
            ? "<|im_end|>\n<|im_start|>assistant\n<think>\n"
            : "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
          addSpecialTokens: false
        ).0
        let input = LongBenchInput(
          id: problem.id, domain: problem.domain, subDomain: problem.subDomain,
          difficulty: problem.difficulty, length: problem.length, expectedAnswer: problem.answer,
          promptTokenIDs: prefix + content + suffix, thinkingBudget: thinkingBudget,
          reasoningEffort: thinkingBudget > 0 ? reasoningEffort : nil)
        try handle.write(contentsOf: encoder.encode(input) + Data([0x0a]))
        print(
          "prepared id=\(input.id) domain=\(input.domain) prompt_tokens=\(input.promptTokenIDs.count)"
        )
        fflush(stdout)
      }
      try handle.synchronize()
      return
    }
    guard FileManager.default.fileExists(atPath: modelPath) else {
      throw LongBenchEvalError.invalidArgument("Missing model checkpoint")
    }
    let inputs = try lines.map {
      try JSONDecoder().decode(LongBenchInput.self, from: Data($0.utf8))
    }
    guard Set(inputs.map(\.id)).count == inputs.count,
      inputs.allSatisfy({
        !$0.promptTokenIDs.isEmpty && $0.promptTokenIDs.count + maxNewTokens <= 262_144
          && ($0.thinkingBudget ?? 0) == thinkingBudget
          && (thinkingBudget == 0 || $0.reasoningEffort == reasoningEffort)
      })
    else { throw LongBenchEvalError.invalidInput("Duplicate ID or context length overflow") }
    let oldFlags = DynamicGraph.flags
    let oldWatermark = DynamicGraph.queueWatermark
    DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    DynamicGraph.queueWatermark = 128
    defer {
      DynamicGraph.flags = oldFlags
      DynamicGraph.queueWatermark = oldWatermark
    }
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(1)
    let stream = StreamContext(.GPU(0))
    var generator = Qwen3_5TextGenerator(
      filePath: modelPath, configuration: .qwen3_5_27B, tieEmbedding: false,
      chunkedPrefillMaxLength: 4_096)
    let regexes = try [#"The correct answer is \(([A-D])\)"#, #"The correct answer is ([A-D])"#]
      .map { try NSRegularExpression(pattern: $0) }
    var correct = 0
    for (index, input) in inputs.enumerated() {
      let seed = baseSeed &+ UInt32(index)
      DynamicGraph.setSeed(seed)
      stream.setSeed(seed)
      let tokens = graph.variable(Tensor<Int32>(input.promptTokenIDs).toGPU(0))
      var kvCache = [DynamicGraph.AnyTensor]()
      var draftCache = [DynamicGraph.AnyTensor]()
      let contextCache = Qwen3_5ContextCache(projectPath: nil, checkpointStride: 4_096)
      var start = ProcessInfo.processInfo.systemUptime
      var prefillSeconds: Double?
      var stopReason = "generator_returned"
      var lastProgress = -1
      var lastGenerationProgress = 0
      print(
        "begin id=\(input.id) domain=\(input.domain) prompt_tokens=\(input.promptTokenIDs.count) seed=\(seed) thinking_temperature=1 thinking_min_p=0.05 answer_temperature=0 thinking_budget=\(thinkingBudget) reasoning_effort=\(thinkingBudget > 0 ? reasoningEffort : "none") max_new_tokens=\(maxNewTokens)"
      )
      fflush(stdout)
      let generated = graph.withStream(stream) {
        graph.withNoGrad {
          generator.decode(
            graph: graph, tokens: tokens, tokenOffset: 0, thinkingBudget: thinkingBudget,
            deterministic: true,
            kvCache: &kvCache, draftCache: &draftCache,
            contextTokens: input.promptTokenIDs, contextCache: contextCache
          ) { count, total, generated, _ in
            if count == 0 {
              stream.joined()
              start = ProcessInfo.processInfo.systemUptime
            }
            if generated.isEmpty && count != lastProgress {
              lastProgress = count
              print("prefill id=\(input.id) progress=\(count)/\(total)")
              fflush(stdout)
            }
            if !generated.isEmpty && prefillSeconds == nil {
              stream.joined()
              prefillSeconds = ProcessInfo.processInfo.systemUptime - start
            }
            if generated.count >= lastGenerationProgress + 1_024 {
              lastGenerationProgress = generated.count
              print(
                "generation id=\(input.id) tokens=\(generated.count) thinking_ended=\(generated.contains(248_069))"
              )
              fflush(stdout)
            }
            if generated.count >= maxNewTokens {
              stopReason = "max_new_tokens"
              return .abort
            }
            return .continue
          }
        }
      }
      stream.joined()
      let duration = ProcessInfo.processInfo.systemUptime - start
      let kept = Array(generated.prefix(maxNewTokens))
      let text = Qwen3_5TextGenerator.unsafeTokenizer.decode(kept)
      let endThinkIndex = thinkingBudget > 0 ? kept.firstIndex(of: 248_069) : nil
      let answerTokens =
        thinkingBudget > 0
        ? endThinkIndex.map { Array(kept.dropFirst($0 + 1)) } ?? [] : kept
      let answerText = Qwen3_5TextGenerator.unsafeTokenizer.decode(answerTokens)
      let normalized = answerText.replacingOccurrences(of: "*", with: "")
      let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
      var extracted: String?
      for regex in regexes {
        if let match = regex.firstMatch(in: normalized, range: range),
          let capture = Range(match.range(at: 1), in: normalized)
        {
          extracted = String(normalized[capture])
          break
        }
      }
      let score = extracted == input.expectedAnswer ? 1 : 0
      correct += score
      if kept.last.map({ [248_046, 248_044].contains($0) }) == true
        && stopReason == "generator_returned"
      {
        stopReason = "eos"
      }
      let result = LongBenchResult(
        id: input.id, seed: seed, domain: input.domain, expectedAnswer: input.expectedAnswer,
        extractedAnswer: extracted, score: score, promptTokenCount: input.promptTokenIDs.count,
        generatedTokenCount: kept.count, thinkingBudget: thinkingBudget,
        reasoningEffort: thinkingBudget > 0 ? reasoningEffort : nil,
        thinkingTokenCount: thinkingBudget > 0 ? endThinkIndex ?? kept.count : 0,
        firstEndThinkIndex: endThinkIndex,
        thinkingBoundaryAtCap: endThinkIndex.map { $0 >= thinkingBudget - 1 } ?? false,
        answerTokenCount: answerTokens.count, prefillSeconds: prefillSeconds ?? duration,
        durationSeconds: duration, stopReason: stopReason, generatedTokenIDs: kept, output: text,
        answerOutput: answerText)
      try handle.write(contentsOf: encoder.encode(result) + Data([0x0a]))
      try handle.synchronize()
      print(
        "result id=\(input.id) score=\(score) expected=\(input.expectedAnswer) extracted=\(extracted ?? "nil") prefill_seconds=\(result.prefillSeconds) seconds=\(duration) output=\(String(reflecting: text))"
      )
      fflush(stdout)
      graph.garbageCollect()
    }
    print("summary correct=\(correct) total=\(inputs.count)")
  }
}
