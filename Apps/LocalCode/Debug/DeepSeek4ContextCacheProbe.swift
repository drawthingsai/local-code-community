import Foundation
import NNC

private struct ProbeResult {
  var generatedTokens: [Int32]
  var restoredTokenLength: Int
  var duration: TimeInterval
}

private enum ProbeError: LocalizedError {
  case invalidArgument(String)
  case missingFile(String)
  case emptyTokens(String)
  case insufficientTokens(required: Int, available: Int)
  case unexpectedRestore(run: String, expected: Int, actual: Int)
  case tokenMismatch(run: String, expected: [Int32], actual: [Int32])
  case insufficientGeneratedTokens(run: String, required: Int, actual: Int)
  case cacheWasNotWritten(String)

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let argument):
      return "Invalid argument: \(argument)"
    case .missingFile(let path):
      return "File does not exist: \(path)"
    case .emptyTokens(let path):
      return "No token IDs found in: \(path)"
    case .insufficientTokens(let required, let available):
      return
        "The probe needs \(required) prompt tokens but only \(available) are available. "
        + "Pass --repeat-token-ids to repeat the fixture."
    case .unexpectedRestore(let run, let expected, let actual):
      return "\(run) restored \(actual) tokens; expected \(expected)."
    case .tokenMismatch(let run, let expected, let actual):
      return "\(run) generated \(actual); expected \(expected)."
    case .insufficientGeneratedTokens(let run, let required, let actual):
      return "\(run) generated \(actual) tokens; at least \(required) are required."
    case .cacheWasNotWritten(let path):
      return "The context cache was not written at \(path)."
    }
  }
}

private enum Scenario: String {
  case samePrompt = "same-prompt"
  case sharedPrefix = "shared-prefix"
  case decodeBoundary = "decode-boundary"
  case all
}

private struct ProbeOptions {
  var modelPath = ""
  var tokenIDsPath = ""
  var projectPath = "/private/tmp/localcode-deepseek4-context-cache-probe"
  var promptTokenCount = 8_193
  var generatedTokenCount = 4
  var chunkedPrefillMaxLength = 4_096
  var compilePrefillHeadroom = 64 * 1_024
  var repeatTokenIDs = false
  var clearCache = true
  var printProgress = false
  var disableMFAAppleNeuralEngine = false
  var scenario = Scenario.all

  static func parse() throws -> ProbeOptions {
    var options = ProbeOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      func value() throws -> String {
        guard !arguments.isEmpty else { throw ProbeError.invalidArgument(argument) }
        return arguments.removeFirst()
      }
      func positiveInteger() throws -> Int {
        guard let result = Int(try value()), result > 0 else {
          throw ProbeError.invalidArgument(argument)
        }
        return result
      }
      switch argument {
      case "--model-path":
        options.modelPath = try value()
      case "--token-ids-file":
        options.tokenIDsPath = try value()
      case "--project-path":
        options.projectPath = try value()
      case "--prompt-tokens":
        options.promptTokenCount = try positiveInteger()
      case "--generated-tokens":
        options.generatedTokenCount = try positiveInteger()
      case "--chunked-prefill-max-length":
        options.chunkedPrefillMaxLength = try positiveInteger()
      case "--compile-prefill-headroom":
        options.compilePrefillHeadroom = try positiveInteger()
      case "--scenario":
        let rawValue = try value()
        guard let scenario = Scenario(rawValue: rawValue) else {
          throw ProbeError.invalidArgument(argument)
        }
        options.scenario = scenario
      case "--repeat-token-ids":
        options.repeatTokenIDs = true
      case "--keep-cache":
        options.clearCache = false
      case "--clear-cache":
        options.clearCache = true
      case "--print-progress":
        options.printProgress = true
      case "--disable-mfa-apple-neural-engine":
        options.disableMFAAppleNeuralEngine = true
      default:
        throw ProbeError.invalidArgument(argument)
      }
    }
    guard !options.modelPath.isEmpty, !options.tokenIDsPath.isEmpty else {
      throw ProbeError.invalidArgument("--model-path and --token-ids-file are required")
    }
    options.modelPath = (options.modelPath as NSString).expandingTildeInPath
    options.tokenIDsPath = (options.tokenIDsPath as NSString).expandingTildeInPath
    options.projectPath = (options.projectPath as NSString).expandingTildeInPath
    return options
  }
}

@main
private struct DeepSeek4ContextCacheProbe {
  private static let checkpointStride = 4_096

  static func main() throws {
    let options = try ProbeOptions.parse()
    guard FileManager.default.fileExists(atPath: options.modelPath) else {
      throw ProbeError.missingFile(options.modelPath)
    }
    let loadedTokens = try loadTokenIDs(path: options.tokenIDsPath)
    let promptTokens: [Int32]
    if loadedTokens.count >= options.promptTokenCount {
      promptTokens = Array(loadedTokens.prefix(options.promptTokenCount))
    } else if options.repeatTokenIDs {
      promptTokens = (0..<options.promptTokenCount).map {
        loadedTokens[$0 % loadedTokens.count]
      }
    } else {
      throw ProbeError.insufficientTokens(
        required: options.promptTokenCount, available: loadedTokens.count)
    }
    let expectedRestore = ((promptTokens.count - 1) / checkpointStride) * checkpointStride
    if options.scenario != .decodeBoundary && expectedRestore < checkpointStride * 2 {
      throw ProbeError.invalidArgument("the prompt must span at least two checkpoints")
    }

    let oldFlags = DynamicGraph.flags
    if options.disableMFAAppleNeuralEngine {
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    }
    defer { DynamicGraph.flags = oldFlags }

    emit("model_path=\(options.modelPath)")
    emit("project_path=\(options.projectPath)")
    emit("cache_path=\(cachePath(projectPath: options.projectPath))")
    emit("prompt_tokens=\(promptTokens.count)")
    emit("expected_restore_tokens=\(expectedRestore)")
    emit("scenario=\(options.scenario.rawValue)")

    switch options.scenario {
    case .samePrompt:
      try runSamePrompt(options: options, tokens: promptTokens, expectedRestore: expectedRestore)
    case .sharedPrefix:
      try runSharedPrefix(options: options, tokens: promptTokens, expectedRestore: expectedRestore)
    case .decodeBoundary:
      try runDecodeBoundary(options: options, tokens: promptTokens)
    case .all:
      try runSamePrompt(options: options, tokens: promptTokens, expectedRestore: expectedRestore)
      try runSharedPrefix(
        options: options, tokens: promptTokens, expectedRestore: expectedRestore,
        reuseExistingCache: true)
      try runDecodeBoundary(options: options, tokens: promptTokens)
    }
    emit("DeepSeek4ContextCacheProbe OK")
  }

  private static func runSamePrompt(
    options: ProbeOptions, tokens: [Int32], expectedRestore: Int
  ) throws {
    emit("scenario_begin=same-prompt")
    if options.clearCache {
      clearCache(projectPath: options.projectPath)
    }
    let baseline = try run(
      name: "baseline_no_cache", options: options, tokens: tokens,
      projectPath: nil, expectedRestore: 0)
    let prime = try run(
      name: "prime_same_prompt", options: options, tokens: tokens,
      projectPath: options.projectPath,
      expectedRestore: options.clearCache ? 0 : nil)
    try requireMatching(prime, baseline: baseline, run: "prime_same_prompt")
    let cachePath = cachePath(projectPath: options.projectPath)
    guard FileManager.default.fileExists(atPath: cachePath) else {
      throw ProbeError.cacheWasNotWritten(cachePath)
    }
    let hit = try run(
      name: "hit_same_prompt", options: options, tokens: tokens,
      projectPath: options.projectPath, expectedRestore: expectedRestore)
    try requireMatching(hit, baseline: baseline, run: "hit_same_prompt")
    emit("scenario_end=same-prompt")
  }

  private static func runSharedPrefix(
    options: ProbeOptions, tokens: [Int32], expectedRestore: Int,
    reuseExistingCache: Bool = false
  ) throws {
    emit("scenario_begin=shared-prefix")
    if options.clearCache && !reuseExistingCache {
      clearCache(projectPath: options.projectPath)
    }
    if !reuseExistingCache {
      _ = try run(
        name: "seed_prefix", options: options, tokens: tokens,
        projectPath: options.projectPath,
        expectedRestore: options.clearCache ? 0 : nil)
    }
    var branchTokens = tokens
    let branchIndex = expectedRestore
    branchTokens[branchIndex] = branchTokens[branchIndex] == 3 ? 4 : 3
    let baseline = try run(
      name: "branch_baseline_no_cache", options: options, tokens: branchTokens,
      projectPath: nil, expectedRestore: 0)
    let hit = try run(
      name: "branch_prefix_hit", options: options, tokens: branchTokens,
      projectPath: options.projectPath, expectedRestore: expectedRestore)
    try requireMatching(hit, baseline: baseline, run: "branch_prefix_hit")
    emit("scenario_end=shared-prefix")
  }

  private static func runDecodeBoundary(options: ProbeOptions, tokens: [Int32]) throws {
    emit("scenario_begin=decode-boundary")
    let promptLength = checkpointStride - 1
    guard tokens.count >= promptLength else {
      throw ProbeError.insufficientTokens(required: promptLength, available: tokens.count)
    }
    var decodeOptions = options
    decodeOptions.generatedTokenCount = max(2, options.generatedTokenCount)
    decodeOptions.projectPath += "-decode-boundary"
    clearCache(projectPath: decodeOptions.projectPath)

    let promptTokens = Array(tokens.prefix(promptLength))
    let seed = try run(
      name: "seed_decode_boundary", options: decodeOptions, tokens: promptTokens,
      projectPath: decodeOptions.projectPath, expectedRestore: 0)
    guard seed.generatedTokens.count >= 2 else {
      throw ProbeError.insufficientGeneratedTokens(
        run: "seed_decode_boundary", required: 2, actual: seed.generatedTokens.count)
    }
    let continuationTokens = promptTokens + Array(seed.generatedTokens.prefix(2))
    let baseline = try run(
      name: "decode_boundary_baseline_no_cache", options: decodeOptions,
      tokens: continuationTokens, projectPath: nil, expectedRestore: 0)
    let hit = try run(
      name: "decode_boundary_hit", options: decodeOptions, tokens: continuationTokens,
      projectPath: decodeOptions.projectPath, expectedRestore: checkpointStride)
    try requireMatching(hit, baseline: baseline, run: "decode_boundary_hit")
    emit("scenario_end=decode-boundary")
  }

  private static func run(
    name: String, options: ProbeOptions, tokens: [Int32], projectPath: String?,
    expectedRestore: Int?
  ) throws -> ProbeResult {
    emit("run_begin=\(name)")
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let streamContext = StreamContext(.GPU(0))
    var generator = DeepSeek4TextGenerator(
      filePath: options.modelPath,
      chunkedPrefillMaxLength: options.chunkedPrefillMaxLength,
      compilePrefillHeadroom: options.compilePrefillHeadroom)
    var kvCache = DeepSeek4TextGenerator.KVCache()
    let contextCache = DeepSeek4ContextCache(
      projectPath: projectPath, checkpointStride: checkpointStride)
    var emptyCallbackCount = 0
    var restoredTokenLength = 0
    let start = Date()
    let generated = graph.withStream(streamContext) {
      graph.withNoGrad {
        let tokenGPU = graph.variable(Tensor<Int32>(tokens, .CPU, .C(tokens.count)).toGPU(0))
        return generator.decode(
          graph: graph, tokens: tokenGPU, tokenOffset: 0, thinkingBudget: 0,
          kvCache: &kvCache, contextTokens: tokens, contextCache: contextCache
        ) { prefillStart, prefillLength, generated, statistics in
          if generated.isEmpty {
            if emptyCallbackCount == 1 {
              restoredTokenLength = prefillStart
            }
            emptyCallbackCount += 1
          }
          if options.printProgress {
            emit(
              "\(name)_progress prefill=\(prefillStart)/\(prefillLength) "
                + "generated=\(generated.count) prefill_tok_s=\(statistics.prefillTokensPerSecond)")
          }
          return generated.count < options.generatedTokenCount
        }
      }
    }
    graph.joined()
    let result = ProbeResult(
      generatedTokens: Array(generated.prefix(options.generatedTokenCount)),
      restoredTokenLength: restoredTokenLength,
      duration: Date().timeIntervalSince(start))
    emit(
      "run_end=\(name) restored_tokens=\(result.restoredTokenLength) "
        + "generated_ids=\(result.generatedTokens.map(String.init).joined(separator: ",")) "
        + "seconds=\(result.duration)")
    if let expectedRestore, result.restoredTokenLength != expectedRestore {
      throw ProbeError.unexpectedRestore(
        run: name, expected: expectedRestore, actual: result.restoredTokenLength)
    }
    return result
  }

  private static func requireMatching(
    _ result: ProbeResult, baseline: ProbeResult, run: String
  ) throws {
    guard result.generatedTokens == baseline.generatedTokens else {
      throw ProbeError.tokenMismatch(
        run: run, expected: baseline.generatedTokens, actual: result.generatedTokens)
    }
    emit("\(run)_matches_baseline=true")
  }

  private static func loadTokenIDs(path: String) throws -> [Int32] {
    guard FileManager.default.fileExists(atPath: path) else {
      throw ProbeError.missingFile(path)
    }
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let tokens = contents.split(whereSeparator: \Character.isWhitespace).compactMap {
      Int32($0)
    }
    guard !tokens.isEmpty else { throw ProbeError.emptyTokens(path) }
    return tokens
  }

  private static func cachePath(projectPath: String) -> String {
    URL(fileURLWithPath: projectPath, isDirectory: true)
      .appendingPathComponent(".localc", isDirectory: true)
      .appendingPathComponent("context_cache.sqlite3").path
  }

  private static func clearCache(projectPath: String) {
    let path = cachePath(projectPath: projectPath)
    for cacheFile in [path, path + "-shm", path + "-wal"]
    where FileManager.default.fileExists(atPath: cacheFile) {
      try? FileManager.default.removeItem(atPath: cacheFile)
    }
  }

  private static func emit(_ line: String) {
    if let data = (line + "\n").data(using: .utf8) {
      FileHandle.standardOutput.write(data)
    }
  }
}
