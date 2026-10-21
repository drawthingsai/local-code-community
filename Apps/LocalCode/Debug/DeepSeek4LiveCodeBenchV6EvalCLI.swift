import Foundation
import NNC

private struct LiveCodeBenchProblem: Decodable {
  let questionTitle: String
  let questionContent: String
  let questionID: String
  let starterCode: String
  let difficulty: String

  private enum CodingKeys: String, CodingKey {
    case questionTitle = "question_title"
    case questionContent = "question_content"
    case questionID = "question_id"
    case starterCode = "starter_code"
    case difficulty
  }
}

private enum LiveCodeBenchEvalError: LocalizedError {
  case missingValue(String)
  case invalidValue(argument: String, value: String)
  case unknownArgument(String)
  case missingFile(String)
  case outputAlreadyExists(String)
  case invalidDatasetCount(expected: Int, actual: Int)
  case invalidDatasetRange(start: Int, limit: Int, count: Int)
  case duplicateProblemID(String)
  case invalidResumeRecord(String)

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
    case .outputAlreadyExists(let path):
      return "Output already exists and is non-empty; use --resume or a new path: \(path)"
    case .invalidDatasetCount(let expected, let actual):
      return "Expected \(expected) LiveCodeBench v6 problems, found \(actual)."
    case .invalidDatasetRange(let start, let limit, let count):
      return "Requested start \(start), limit \(limit), but the dataset contains \(count) cases."
    case .duplicateProblemID(let questionID):
      return "Dataset contains duplicate question_id: \(questionID)"
    case .invalidResumeRecord(let description):
      return "Invalid resume record: \(description)"
    }
  }
}

private struct Options {
  var modelPath = ""
  var datasetPath = "Apps/LocalCode/Eval/LiveCodeBenchV6.jsonl"
  var outputPath = ""
  var start = 0
  var limit: Int?
  var expectedProblemCount = 175
  var thinkingBudget = 65_536
  var answerBudget = 65_536
  var seed: UInt32 = 42
  var maxConcurrency = 1
  var queueWatermark = 128
  var progressInterval = 512
  var resume = false

  static func parse() throws -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      func value() throws -> String {
        guard !arguments.isEmpty else {
          throw LiveCodeBenchEvalError.missingValue(argument)
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
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.start = start
      case "--limit":
        let rawValue = try value()
        guard let limit = Int(rawValue), limit > 0 else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.limit = limit
      case "--expected-problem-count":
        let rawValue = try value()
        guard let count = Int(rawValue), count > 0 else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.expectedProblemCount = count
      case "--thinking-budget":
        let rawValue = try value()
        guard let budget = Int(rawValue), budget > 0 else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.thinkingBudget = budget
      case "--answer-budget":
        let rawValue = try value()
        guard let budget = Int(rawValue), budget > 0 else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.answerBudget = budget
      case "--seed":
        let rawValue = try value()
        guard let seed = UInt32(rawValue) else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.seed = seed
      case "--max-concurrency":
        let rawValue = try value()
        guard let maxConcurrency = Int(rawValue), maxConcurrency > 0 else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.maxConcurrency = maxConcurrency
      case "--queue-watermark":
        let rawValue = try value()
        guard let queueWatermark = Int(rawValue), queueWatermark > 0 else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.queueWatermark = queueWatermark
      case "--progress-interval":
        let rawValue = try value()
        guard let progressInterval = Int(rawValue), progressInterval > 0 else {
          throw LiveCodeBenchEvalError.invalidValue(argument: argument, value: rawValue)
        }
        options.progressInterval = progressInterval
      case "--resume":
        options.resume = true
      default:
        throw LiveCodeBenchEvalError.unknownArgument(argument)
      }
    }
    guard !options.modelPath.isEmpty else {
      throw LiveCodeBenchEvalError.missingValue("--model-path")
    }
    guard !options.outputPath.isEmpty else {
      throw LiveCodeBenchEvalError.missingValue("--output-jsonl")
    }
    return options
  }
}

private struct EvalRecord: Codable {
  let schemaVersion: Int
  let phase: String
  let caseIndex: Int
  let questionID: String
  let questionTitle: String
  let difficulty: String
  let baseSeed: UInt32
  let caseSeed: UInt32
  let thinkingBudget: Int
  let answerBudget: Int
  let promptTokenCount: Int
  let generatedTokenCount: Int
  let thinkingTokenCount: Int
  let forcedThinkingBoundary: Bool
  let durationSeconds: Double
  let stopReason: String
  let prefillTokensPerSecond: Float
  let generatedTokensPerSecond: Float
  let tokenIDs: [Int32]
  let output: String
}

private struct GenerationResult {
  let tokens: [Int32]
  let duration: Double
  let stopReason: String
  let statistics: DeepSeekGenerationStatistics
}

@main
private struct DeepSeek4LiveCodeBenchV6EvalCLI {
  private static let endThinkToken: Int32 = 128_822
  private static let eosToken: Int32 = 1
  private static let schemaVersion = 2
  private static let systemPrompt =
    "A conversation between User and Assistant. The user asks a question, and the Assistant solves it. The assistant first thinks about the reasoning process in the mind and then provides the user with the answer. The reasoning process and answer are enclosed within <think> </think> and <answer> </answer> tags, respectively, i.e., <think> reasoning process here </think> <answer> answer here </answer>."

  static func main() throws {
    let options = try Options.parse()
    guard FileManager.default.fileExists(atPath: options.modelPath) else {
      throw LiveCodeBenchEvalError.missingFile(options.modelPath)
    }
    guard FileManager.default.fileExists(atPath: options.datasetPath) else {
      throw LiveCodeBenchEvalError.missingFile(options.datasetPath)
    }

    let dataset = try String(contentsOfFile: options.datasetPath, encoding: .utf8)
    let problems = try dataset.split(whereSeparator: \Character.isNewline).map {
      try JSONDecoder().decode(LiveCodeBenchProblem.self, from: Data($0.utf8))
    }.sorted { $0.questionID < $1.questionID }
    guard problems.count == options.expectedProblemCount else {
      throw LiveCodeBenchEvalError.invalidDatasetCount(
        expected: options.expectedProblemCount, actual: problems.count)
    }
    for index in 1..<problems.count
    where problems[index - 1].questionID == problems[index].questionID {
      throw LiveCodeBenchEvalError.duplicateProblemID(problems[index].questionID)
    }
    let limit = options.limit ?? (problems.count - options.start)
    guard options.start < problems.count, limit <= problems.count - options.start else {
      throw LiveCodeBenchEvalError.invalidDatasetRange(
        start: options.start, limit: limit, count: problems.count)
    }

    let existingRecords = try loadExistingRecords(options: options)
    var thinkingRecords = [String: EvalRecord]()
    var answerRecords = [String: EvalRecord]()
    for record in existingRecords {
      try validate(record: record, options: options, problems: problems)
      switch record.phase {
      case "thinking":
        guard thinkingRecords.updateValue(record, forKey: record.questionID) == nil else {
          throw LiveCodeBenchEvalError.invalidResumeRecord(
            "duplicate thinking record for \(record.questionID)")
        }
      case "answer":
        guard answerRecords.updateValue(record, forKey: record.questionID) == nil else {
          throw LiveCodeBenchEvalError.invalidResumeRecord(
            "duplicate answer record for \(record.questionID)")
        }
      default:
        throw LiveCodeBenchEvalError.invalidResumeRecord("unknown phase \(record.phase)")
      }
    }
    for (questionID, answerRecord) in answerRecords {
      guard let thinkingRecord = thinkingRecords[questionID] else {
        throw LiveCodeBenchEvalError.invalidResumeRecord(
          "answer record without thinking record for \(questionID)")
      }
      guard answerRecord.thinkingTokenCount == thinkingRecord.thinkingTokenCount,
        answerRecord.forcedThinkingBoundary == thinkingRecord.forcedThinkingBoundary
      else {
        throw LiveCodeBenchEvalError.invalidResumeRecord(
          "answer and thinking metadata disagree for \(questionID)")
      }
    }

    let outputURL = URL(fileURLWithPath: options.outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: options.outputPath) {
      _ = FileManager.default.createFile(atPath: options.outputPath, contents: nil)
    }
    let outputHandle = try FileHandle(forWritingTo: outputURL)
    try outputHandle.seekToEnd()
    defer { try? outputHandle.close() }
    let encoder = JSONEncoder()

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
    var generator = DeepSeek4TextGenerator(
      filePath: options.modelPath, chunkedPrefillMaxLength: 4_096)
    print(
      "config dataset=v6 problems=\(problems.count) start=\(options.start) limit=\(limit) seed=\(options.seed) thinking_temperature=1 thinking_min_p=0.01 answer_temperature=0 thinking_budget=\(options.thinkingBudget) answer_budget=\(options.answerBudget)"
    )
    fflush(stdout)

    var skippedForcedThinking = 0
    for caseIndex in options.start..<(options.start + limit) {
      let problem = problems[caseIndex]
      let prompt = prompt(for: problem)
      let promptTokenIDs = DeepSeek4TextGenerator.unsafeTokenizer.tokenize(
        text: prompt, addSpecialTokens: false
      ).0
      let caseSeed = options.seed &+ UInt32(truncatingIfNeeded: caseIndex)
      let thinkingRecord: EvalRecord
      if let existing = thinkingRecords[problem.questionID] {
        thinkingRecord = existing
        print(
          "resume phase=thinking case=\(caseIndex) id=\(problem.questionID) tokens=\(existing.generatedTokenCount) forced=\(existing.forcedThinkingBoundary) stop=\(existing.stopReason)"
        )
      } else {
        let result = generate(
          graph: graph, streamContext: streamContext, generator: &generator,
          promptTokenIDs: promptTokenIDs, thinkingBudget: options.thinkingBudget,
          maximumGeneratedTokens: options.thinkingBudget + 1, stopAtEndThink: true,
          seed: caseSeed, progressInterval: options.progressInterval,
          progressPrefix: "thinking case=\(caseIndex) id=\(problem.questionID)")
        let endThinkIndex = result.tokens.firstIndex(of: endThinkToken)
        let forcedThinkingBoundary = endThinkIndex == options.thinkingBudget
        thinkingRecord = EvalRecord(
          schemaVersion: schemaVersion, phase: "thinking", caseIndex: caseIndex,
          questionID: problem.questionID, questionTitle: problem.questionTitle,
          difficulty: problem.difficulty, baseSeed: options.seed, caseSeed: caseSeed,
          thinkingBudget: options.thinkingBudget, answerBudget: options.answerBudget,
          promptTokenCount: promptTokenIDs.count,
          generatedTokenCount: result.tokens.count,
          thinkingTokenCount: endThinkIndex ?? result.tokens.count,
          forcedThinkingBoundary: forcedThinkingBoundary,
          durationSeconds: result.duration,
          stopReason: forcedThinkingBoundary ? "forced_end_think" : result.stopReason,
          prefillTokensPerSecond: result.statistics.prefillTokensPerSecond,
          generatedTokensPerSecond: result.statistics.tokenGeneratedPerSecond,
          tokenIDs: result.tokens, output: decode(result.tokens))
        try append(thinkingRecord, encoder: encoder, outputHandle: outputHandle)
        thinkingRecords[problem.questionID] = thinkingRecord
        print(
          "result phase=thinking case=\(caseIndex) id=\(problem.questionID) tokens=\(result.tokens.count) thinking_tokens=\(thinkingRecord.thinkingTokenCount) forced=\(forcedThinkingBoundary) stop=\(thinkingRecord.stopReason) seconds=\(String(format: "%.2f", result.duration))"
        )
      }
      fflush(stdout)

      if thinkingRecord.forcedThinkingBoundary {
        skippedForcedThinking += 1
      }
      if let existing = answerRecords[problem.questionID] {
        print(
          "resume phase=answer case=\(caseIndex) id=\(problem.questionID) tokens=\(existing.generatedTokenCount) stop=\(existing.stopReason)"
        )
        fflush(stdout)
        continue
      }

      let sharedThinkingTokens = thinkingRecord.tokenIDs.firstIndex(of: endThinkToken).map {
        Array(thinkingRecord.tokenIDs[...$0])
      }
      let result: GenerationResult
      if thinkingRecord.forcedThinkingBoundary {
        result = GenerationResult(
          tokens: [], duration: 0, stopReason: "forced_thinking_boundary",
          statistics: DeepSeekGenerationStatistics())
      } else if let sharedThinkingTokens {
        result = generate(
          graph: graph, streamContext: streamContext, generator: &generator,
          promptTokenIDs: promptTokenIDs + sharedThinkingTokens, thinkingBudget: 0,
          maximumGeneratedTokens: options.answerBudget, stopAtEndThink: false,
          seed: caseSeed, progressInterval: options.progressInterval,
          progressPrefix: "answer case=\(caseIndex) id=\(problem.questionID)")
      } else {
        result = GenerationResult(
          tokens: [], duration: 0, stopReason: "missing_end_think",
          statistics: DeepSeekGenerationStatistics())
      }
      let answerRecord = EvalRecord(
        schemaVersion: schemaVersion, phase: "answer", caseIndex: caseIndex,
        questionID: problem.questionID, questionTitle: problem.questionTitle,
        difficulty: problem.difficulty, baseSeed: options.seed, caseSeed: caseSeed,
        thinkingBudget: options.thinkingBudget, answerBudget: options.answerBudget,
        promptTokenCount: promptTokenIDs.count + (sharedThinkingTokens?.count ?? 0),
        generatedTokenCount: result.tokens.count,
        thinkingTokenCount: thinkingRecord.thinkingTokenCount,
        forcedThinkingBoundary: thinkingRecord.forcedThinkingBoundary,
        durationSeconds: result.duration, stopReason: result.stopReason,
        prefillTokensPerSecond: result.statistics.prefillTokensPerSecond,
        generatedTokensPerSecond: result.statistics.tokenGeneratedPerSecond,
        tokenIDs: result.tokens, output: decode(result.tokens))
      try append(answerRecord, encoder: encoder, outputHandle: outputHandle)
      answerRecords[problem.questionID] = answerRecord
      print(
        "result phase=answer case=\(caseIndex) id=\(problem.questionID) tokens=\(result.tokens.count) stop=\(result.stopReason) seconds=\(String(format: "%.2f", result.duration))"
      )
      fflush(stdout)
    }
    print(
      "summary completed_cases=\(limit) skipped_forced_thinking=\(skippedForcedThinking)"
    )
  }

  private static func prompt(for problem: LiveCodeBenchProblem) -> String {
    var question =
      "You will be given a question (problem specification) and will generate a correct Python program that matches the specification and passes all tests.\n\nQuestion: \(problem.questionContent)\n\n"
    if problem.starterCode.isEmpty {
      question +=
        "Read the inputs from stdin solve the problem and write the answer to stdout (do not directly test on the sample inputs). Enclose your code within delimiters as follows. Ensure that when the python program runs, it reads the inputs, runs the algorithm and writes output to STDOUT.\n```python\n# YOUR CODE HERE\n```\n\n"
    } else {
      question +=
        "You will use the following starter code to write the solution to the problem and enclose your code within delimiters.\n```python\n\(problem.starterCode)\n```\n\n"
    }
    return
      "<｜begin▁of▁sentence｜>\(systemPrompt)<｜User｜>\(question)<｜Assistant｜><think>"
  }

  private static func generate(
    graph: DynamicGraph, streamContext: StreamContext,
    generator: inout DeepSeek4TextGenerator, promptTokenIDs: [Int32], thinkingBudget: Int,
    maximumGeneratedTokens: Int, stopAtEndThink: Bool, seed: UInt32,
    progressInterval: Int, progressPrefix: String
  ) -> GenerationResult {
    DynamicGraph.setSeed(seed)
    streamContext.setSeed(seed)
    let input = graph.variable(
      Tensor<Int32>(promptTokenIDs, .CPU, .C(promptTokenIDs.count)).toGPU(0))
    var kvCache = DeepSeek4TextGenerator.KVCache()
    let contextCache = DeepSeek4ContextCache(
      projectPath: nil, checkpointStride: generator.checkpointStride)
    var stopReason = "generator_returned"
    var lastProgress = 0
    var inspectedTokenCount = 0
    let startTime = Date.timeIntervalSinceReferenceDate
    let generated = graph.withStream(streamContext) {
      graph.withNoGrad {
        generator.decode(
          graph: graph, tokens: input, tokenOffset: 0, thinkingBudget: thinkingBudget,
          deterministic: true, kvCache: &kvCache, contextTokens: promptTokenIDs,
          contextCache: contextCache
        ) { _, _, generated, statistics in
          if stopAtEndThink && inspectedTokenCount < generated.count,
            generated[inspectedTokenCount...].contains(endThinkToken)
          {
            stopReason = "end_think"
            return .abort
          }
          inspectedTokenCount = generated.count
          if generated.count >= maximumGeneratedTokens {
            stopReason = stopAtEndThink ? "thinking_budget" : "answer_budget"
            return .abort
          }
          if generated.count >= lastProgress + progressInterval {
            lastProgress = generated.count
            let tail = decode(Array(generated.suffix(96)))
              .replacingOccurrences(of: "\n", with: " ")
            print(
              "progress \(progressPrefix) tokens=\(generated.count) tok_s=\(String(format: "%.2f", statistics.tokenGeneratedPerSecond)) tail=\(String(reflecting: tail))"
            )
            fflush(stdout)
          }
          return .continue
        }
      }
    }
    graph.joined()
    if generated.last == eosToken && stopReason == "generator_returned" {
      stopReason = "eos"
    }
    return GenerationResult(
      tokens: generated,
      duration: Date.timeIntervalSinceReferenceDate - startTime,
      stopReason: stopReason, statistics: generator.statistics)
  }

  private static func decode(_ tokenIDs: [Int32]) -> String {
    let content = tokenIDs.firstIndex(of: eosToken).map { Array(tokenIDs[..<$0]) } ?? tokenIDs
    return DeepSeek4TextGenerator.unsafeTokenizer.decode(content)
  }

  private static func append(
    _ record: EvalRecord, encoder: JSONEncoder, outputHandle: FileHandle
  ) throws {
    outputHandle.write(try encoder.encode(record))
    outputHandle.write(Data([0x0a]))
    try outputHandle.synchronize()
  }

  private static func loadExistingRecords(options: Options) throws -> [EvalRecord] {
    guard FileManager.default.fileExists(atPath: options.outputPath) else { return [] }
    let data = try Data(contentsOf: URL(fileURLWithPath: options.outputPath))
    guard !data.isEmpty else { return [] }
    guard options.resume else {
      throw LiveCodeBenchEvalError.outputAlreadyExists(options.outputPath)
    }
    return try data.split(separator: 0x0a).map {
      try JSONDecoder().decode(EvalRecord.self, from: Data($0))
    }
  }

  private static func validate(
    record: EvalRecord, options: Options, problems: [LiveCodeBenchProblem]
  ) throws {
    guard record.schemaVersion == schemaVersion else {
      throw LiveCodeBenchEvalError.invalidResumeRecord(
        "unsupported schemaVersion \(record.schemaVersion)")
    }
    guard record.baseSeed == options.seed else {
      throw LiveCodeBenchEvalError.invalidResumeRecord(
        "baseSeed \(record.baseSeed) does not match --seed \(options.seed)")
    }
    guard record.thinkingBudget == options.thinkingBudget,
      record.answerBudget == options.answerBudget
    else {
      throw LiveCodeBenchEvalError.invalidResumeRecord(
        "token budgets do not match the current command")
    }
    guard problems.indices.contains(record.caseIndex),
      problems[record.caseIndex].questionID == record.questionID
    else {
      throw LiveCodeBenchEvalError.invalidResumeRecord(
        "caseIndex and questionID disagree for \(record.questionID)")
    }
    let expectedCaseSeed = options.seed &+ UInt32(truncatingIfNeeded: record.caseIndex)
    guard record.caseSeed == expectedCaseSeed else {
      throw LiveCodeBenchEvalError.invalidResumeRecord(
        "caseSeed \(record.caseSeed) does not match expected \(expectedCaseSeed)")
    }
  }
}
