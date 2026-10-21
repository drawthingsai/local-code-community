import Foundation
import NNC

private struct AIMEProblem: Decodable {
  let question: String
  let expectedAnswer: String
}

private enum AIMEEvalError: LocalizedError {
  case missingValue(String)
  case invalidValue(argument: String, value: String)
  case unknownArgument(String)
  case missingFile(String)
  case invalidDatasetRange(start: Int, limit: Int, count: Int)

  var errorDescription: String? {
    switch self {
    case .missingValue(let argument):
      return "Missing value for \(argument)."
    case .invalidValue(let argument, let value):
      return "Invalid value for \(argument): \(value)"
    case .unknownArgument(let argument):
      return "Unknown argument: \(argument)"
    case .missingFile(let path):
      return "File does not exist: \(path)"
    case .invalidDatasetRange(let start, let limit, let count):
      return "Requested start \(start), limit \(limit), but the dataset contains \(count) cases."
    }
  }
}

private struct AIMEResult: Encodable {
  let caseIndex: Int
  let seed: UInt32
  let question: String
  let expectedAnswer: String
  let extractedAnswer: String?
  let score: Int
  let promptTokenCount: Int
  let generatedTokenCount: Int
  let thinkingTokenCount: Int
  let durationSeconds: Double
  let stopReason: String
  let prefillTokensPerSecond: Float
  let generatedTokensPerSecond: Float
  let generatedTokenIDs: [Int32]
  let output: String
}

private struct Options {
  var modelPath = ""
  var datasetPath = "Apps/LocalCode/Eval/AIME2025.jsonl"
  var outputPath = ""
  var start = 0
  var limit = 30
  var seed: UInt32 = 42
  var maxNewTokens = 81_920
  var thinkingBudget = 65_536
  var maxConcurrency = 1
  var queueWatermark = 128

  static func parse() throws -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      func value() throws -> String {
        guard !arguments.isEmpty else {
          throw AIMEEvalError.missingValue(argument)
        }
        return arguments.removeFirst()
      }
      switch argument {
      case "--model-path":
        options.modelPath = try value()
      case "--dataset":
        options.datasetPath = try value()
      case "--output-jsonl":
        options.outputPath = try value()
      case "--start":
        let rawValue = try value()
        guard let start = Int(rawValue), start >= 0 else {
          throw AIMEEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.start = start
      case "--limit":
        let rawValue = try value()
        guard let limit = Int(rawValue), limit > 0 else {
          throw AIMEEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.limit = limit
      case "--max-new-tokens":
        let rawValue = try value()
        guard let maxNewTokens = Int(rawValue), maxNewTokens > 0 else {
          throw AIMEEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.maxNewTokens = maxNewTokens
      case "--seed":
        let rawValue = try value()
        guard let seed = UInt32(rawValue) else {
          throw AIMEEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.seed = seed
      case "--thinking-budget":
        let rawValue = try value()
        guard let thinkingBudget = Int(rawValue), thinkingBudget > 0 else {
          throw AIMEEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.thinkingBudget = thinkingBudget
      case "--max-concurrency":
        let rawValue = try value()
        guard let maxConcurrency = Int(rawValue), maxConcurrency > 0 else {
          throw AIMEEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.maxConcurrency = maxConcurrency
      case "--queue-watermark":
        let rawValue = try value()
        guard let queueWatermark = Int(rawValue), queueWatermark > 0 else {
          throw AIMEEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.queueWatermark = queueWatermark
      default:
        throw AIMEEvalError.unknownArgument(argument)
      }
    }
    guard !options.modelPath.isEmpty else {
      throw AIMEEvalError.missingValue("--model-path")
    }
    guard !options.outputPath.isEmpty else {
      throw AIMEEvalError.missingValue("--output-jsonl")
    }
    guard options.maxNewTokens > options.thinkingBudget else {
      throw AIMEEvalError.invalidValue(
        argument: "--max-new-tokens", value: String(options.maxNewTokens))
    }
    return options
  }
}

@main
private struct QwenAIME25EvalCLI {
  private static let endThinkToken: Int32 = 248_069
  private static let eosTokens = Set<Int32>([248_046, 248_044])
  private static let progressInterval = 512
  private static let systemPrompt =
    "You are solving a hard benchmark question. Reason carefully. The final answer must follow the requested format exactly."
  private static let answerRegex = try! NSRegularExpression(
    pattern: #"(?im)^\s*Answer:\s*(-?\d+)\s*$"#)
  private static let terminatedAnswerRegex = try! NSRegularExpression(
    pattern: #"(?im)^\s*Answer:\s*(-?\d+)[ \t]*\r?\n"#)
  private static let integerRegex = try! NSRegularExpression(pattern: #"-?\d+"#)

  static func main() throws {
    let options = try Options.parse()
    guard FileManager.default.fileExists(atPath: options.modelPath) else {
      throw AIMEEvalError.missingFile(options.modelPath)
    }
    guard FileManager.default.fileExists(atPath: options.datasetPath) else {
      throw AIMEEvalError.missingFile(options.datasetPath)
    }

    let dataset = try String(contentsOfFile: options.datasetPath, encoding: .utf8)
    let problems = try dataset.split(whereSeparator: \Character.isNewline).map {
      try JSONDecoder().decode(AIMEProblem.self, from: Data($0.utf8))
    }
    guard options.start < problems.count,
      options.limit <= problems.count - options.start
    else {
      throw AIMEEvalError.invalidDatasetRange(
        start: options.start, limit: options.limit, count: problems.count)
    }

    let oldFlags = DynamicGraph.flags
    let oldQueueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    DynamicGraph.queueWatermark = options.queueWatermark
    defer {
      DynamicGraph.flags = oldFlags
      DynamicGraph.queueWatermark = oldQueueWatermark
    }

    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(options.maxConcurrency)
    let streamContext = StreamContext(.GPU(0))
    print(
      "config thinking_temperature=1 thinking_min_p=0.05 answer_temperature=0 base_seed=\(options.seed)"
    )

    var generator = Qwen3_5TextGenerator(
      filePath: options.modelPath, configuration: .qwen3_5_27B,
      tieEmbedding: false, chunkedPrefillMaxLength: 4_096)
    let outputURL = URL(fileURLWithPath: options.outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: outputURL)
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? outputHandle.close() }
    let encoder = JSONEncoder()

    var correct = 0
    for caseIndex in options.start..<(options.start + options.limit) {
      let seed = options.seed &+ UInt32(caseIndex)
      DynamicGraph.setSeed(seed)
      streamContext.setSeed(seed)
      let problem = problems[caseIndex]
      let userPrompt =
        problem.question.trimmingCharacters(in: .whitespacesAndNewlines)
        + "\n\nSolve the problem. At the end, write exactly one final line in this format and do not write anything after it:\nAnswer: <integer>"
      let prompt =
        "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        + "<|im_start|>user\n\(userPrompt)<|im_end|>\n"
        + "<|im_start|>assistant\n<think>\n"
      let promptTokenIDs = Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
        text: prompt, addSpecialTokens: false
      ).0
      let input = graph.variable(
        Tensor<Int32>(promptTokenIDs, .CPU, .C(promptTokenIDs.count)).toGPU(0))
      var kvCache = [DynamicGraph.AnyTensor]()
      var draftCache = [DynamicGraph.AnyTensor]()
      let contextCache = Qwen3_5ContextCache(projectPath: nil, checkpointStride: 4_096)
      var stopReason = "generator_returned"
      var lastProgress = 0
      var inspectedTokenCount = 0
      var endThinkIndex: Int?
      let startTime = Date.timeIntervalSinceReferenceDate
      let generated = graph.withStream(streamContext) {
        graph.withNoGrad {
          generator.decode(
            graph: graph, tokens: input, tokenOffset: 0,
            thinkingBudget: options.thinkingBudget,
            kvCache: &kvCache, draftCache: &draftCache,
            contextTokens: promptTokenIDs, contextCache: contextCache
          ) { _, _, generated, statistics in
            if endThinkIndex == nil && inspectedTokenCount < generated.count {
              endThinkIndex = generated[inspectedTokenCount...].firstIndex(of: endThinkToken)
            }
            inspectedTokenCount = generated.count

            if generated.count >= lastProgress + progressInterval {
              lastProgress = generated.count
              let tail = decode(Array(generated.suffix(96)))
                .replacingOccurrences(of: "\n", with: " ")
              let tokensPerSecond = String(
                format: "%.2f", statistics.tokenGeneratedPerSecond)
              print(
                "progress case=\(caseIndex) tokens=\(generated.count) tok_s=\(tokensPerSecond) tail=\(String(reflecting: tail))"
              )
              fflush(stdout)
            }
            if generated.count >= options.maxNewTokens {
              stopReason = "max_new_tokens"
              return .abort
            }
            if let endThinkIndex {
              let answerTokens = Array(generated.dropFirst(endThinkIndex + 1))
              if extractTerminatedAnswer(from: decode(answerTokens)) != nil {
                stopReason = "answer"
                return .abort
              }
            }
            return .continue
          }
        }
      }
      graph.joined()

      if endThinkIndex == nil {
        endThinkIndex = generated.firstIndex(of: endThinkToken)
      }
      let duration = Date.timeIntervalSinceReferenceDate - startTime
      let output = decode(generated)
      let answerTokens = endThinkIndex.map { Array(generated.dropFirst($0 + 1)) } ?? []
      let extractedAnswer = extractAnswer(from: decode(answerTokens))
      guard let expectedAnswer = normalizeAnswer(problem.expectedAnswer) else {
        throw AIMEEvalError.invalidValue(
          argument: "expectedAnswer", value: problem.expectedAnswer)
      }
      let score = extractedAnswer == expectedAnswer ? 1 : 0
      correct += score
      if generated.last.map(eosTokens.contains) == true && stopReason == "generator_returned" {
        stopReason = "eos"
      }
      let statistics = generator.statistics
      let result = AIMEResult(
        caseIndex: caseIndex, seed: seed, question: problem.question,
        expectedAnswer: expectedAnswer, extractedAnswer: extractedAnswer, score: score,
        promptTokenCount: promptTokenIDs.count, generatedTokenCount: generated.count,
        thinkingTokenCount: endThinkIndex ?? generated.count,
        durationSeconds: duration, stopReason: stopReason,
        prefillTokensPerSecond: statistics.prefillTokensPerSecond,
        generatedTokensPerSecond: statistics.tokenGeneratedPerSecond,
        generatedTokenIDs: generated, output: output)
      outputHandle.write(try encoder.encode(result))
      outputHandle.write(Data([0x0a]))

      let tail = String(output.suffix(800)).replacingOccurrences(of: "\n", with: " ")
      let extractedAnswerDescription = extractedAnswer ?? "nil"
      let durationDescription = String(format: "%.2f", duration)
      print(
        "result case=\(caseIndex) score=\(score) expected=\(expectedAnswer) extracted=\(extractedAnswerDescription) prompt_tokens=\(promptTokenIDs.count) generated_tokens=\(generated.count) thinking_tokens=\(result.thinkingTokenCount) stop=\(stopReason) seconds=\(durationDescription)"
      )
      print("result_tail case=\(caseIndex) \(String(reflecting: tail))")
      fflush(stdout)
    }
    print("summary correct=\(correct) total=\(options.limit)")
  }

  private static func decode(_ tokenIDs: [Int32]) -> String {
    let content =
      tokenIDs.firstIndex(where: eosTokens.contains).map {
        Array(tokenIDs[..<$0])
      } ?? tokenIDs
    return Qwen3_5TextGenerator.unsafeTokenizer.decode(content)
  }

  private static func extractAnswer(from text: String) -> String? {
    extractAnswer(from: text, matching: answerRegex)
  }

  private static func extractTerminatedAnswer(from text: String) -> String? {
    extractAnswer(from: text, matching: terminatedAnswerRegex)
  }

  private static func extractAnswer(
    from text: String, matching regex: NSRegularExpression
  ) -> String? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.matches(in: text, range: range).last,
      let capture = Range(match.range(at: 1), in: text)
    else { return nil }
    return normalizeAnswer(String(text[capture]))
  }

  private static func normalizeAnswer(_ text: String) -> String? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = integerRegex.matches(in: text, range: range).last,
      let matchRange = Range(match.range, in: text),
      let value = Int(text[matchRange])
    else { return nil }
    return String(value)
  }
}
