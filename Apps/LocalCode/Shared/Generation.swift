import Foundation
import LLM
import NNC
import Tokenizer

public enum ModelVariant: String, CaseIterable, Sendable {
  case qwen3_5_4B = "qwen3.5-4b"
  case qwen3_5_9B = "qwen3.5-9b"
  case qwen3_5_27B = "qwen3.6-27b"

  public var configuration: Qwen3_5ModelConfiguration {
    switch self {
    case .qwen3_5_4B:
      return .qwen3_5_4B
    case .qwen3_5_9B:
      return .qwen3_5_9B
    case .qwen3_5_27B:
      return .qwen3_5_27B
    }
  }

  public var defaultModelStore: String {
    switch self {
    case .qwen3_5_4B:
      return "qwen_3.5_4b_f16.ckpt"
    case .qwen3_5_9B:
      return "qwen_3.5_9b_f16.ckpt"
    case .qwen3_5_27B:
      return "qwen_3.6_27b_f16.ckpt"
    }
  }

  public var defaultTokenizerDirectory: String {
    switch self {
    case .qwen3_5_4B:
      return "Models/Qwen3.5-4B"
    case .qwen3_5_9B:
      return "Models/Qwen3.5-9B"
    case .qwen3_5_27B:
      return "Models/Qwen3.6-27B"
    }
  }

  public var tieEmbedding: Bool {
    switch self {
    case .qwen3_5_4B:
      return true
    case .qwen3_5_9B:
      return false
    case .qwen3_5_27B:
      return false
    }
  }
}

public struct GenerationResult: Sendable {
  public var promptTokenIds: [Int32]
  public var generatedTokenIds: [Int32]
  public var generatedText: String
  public var fullText: String
}

public struct GenerationTiming: Sendable {
  public var loadAndCompileMilliseconds: Double
  public var prefillMilliseconds: Double
  public var decodeCompileMilliseconds: Double
  public var decodeLoopMilliseconds: Double
  public var decodeLoopTokens: Int

  public var decodeLoopTokensPerSecond: Double {
    decodeLoopMilliseconds > 0
      ? Double(decodeLoopTokens) / (decodeLoopMilliseconds / 1_000) : 0
  }

  fileprivate init(_ timing: Qwen3_5GenerationTiming) {
    loadAndCompileMilliseconds = timing.loadAndCompileMilliseconds
    prefillMilliseconds = timing.prefillMilliseconds
    decodeCompileMilliseconds = timing.decodeCompileMilliseconds
    decodeLoopMilliseconds = timing.decodeLoopMilliseconds
    decodeLoopTokens = timing.decodeLoopTokens
  }
}

public struct MeasuredGenerationResult: Sendable {
  public var result: GenerationResult
  public var timing: GenerationTiming
}

public struct MTPMeasuredGenerationResult: Sendable {
  public var result: GenerationResult
  public var timing: GenerationTiming
  public var acceptedDrafts: Int
  public var rejectedDrafts: Int
  public var d1AcceptedDrafts: Int
  public var d1RejectedDrafts: Int
  public var d1AcceptanceRate: Double
  public var d2AcceptedDrafts: Int
  public var d2RejectedDrafts: Int
  public var d2AcceptanceRate: Double
  public var replayRounds: Int
}

public struct TTFTBenchmarkResult: Sendable {
  public var tokenLength: Int
  public var runs: Int
  public var warmups: Int
  public var durationsMilliseconds: [Double]
}

public enum GenerationError: LocalizedError {
  case invalidModelStore(String)
  case invalidTokenizerDirectory(String)
  case invalidVariant(String)
  case emptyPrompt

  public var errorDescription: String? {
    switch self {
    case .invalidModelStore(let path):
      return "Model checkpoint does not exist: \(path)"
    case .invalidTokenizerDirectory(let path):
      return "Tokenizer directory is missing vocab.json or merges.txt: \(path)"
    case .invalidVariant(let value):
      return "Unknown model variant: \(value)"
    case .emptyPrompt:
      return "Prompt is empty."
    }
  }
}

public final class TextGenerationEngine {
  private let modelStore: String
  private let tokenizerDirectory: String
  private let variant: ModelVariant
  private let tokenizer: TiktokenTokenizer

  public init(
    modelStore: String, tokenizerDirectory: String,
    variant: ModelVariant = .qwen3_5_4B
  ) throws {
    self.modelStore = try Self.resolvedModelStore(modelStore)
    self.tokenizerDirectory = try Self.resolvedTokenizerDirectory(tokenizerDirectory)
    self.variant = variant
    self.tokenizer = try Self.loadTokenizer(tokenizerDirectory: self.tokenizerDirectory)
  }

  public func generate(
    prompt: String, maxNewTokens: Int, prefillTokenCount: Int? = nil,
    partialHandler: ((GenerationResult) -> Bool)? = nil
  ) throws -> GenerationResult {
    try runGeneration(
      prompt: prompt, maxNewTokens: maxNewTokens, prefillTokenCount: prefillTokenCount,
      partialHandler: partialHandler
    ).result
  }

  public func measureGeneration(
    prompt: String, maxNewTokens: Int, prefillTokenCount: Int? = nil,
    partialHandler: ((GenerationResult) -> Bool)? = nil
  ) throws -> MeasuredGenerationResult {
    try runGeneration(
      prompt: prompt, maxNewTokens: maxNewTokens, prefillTokenCount: prefillTokenCount,
      partialHandler: partialHandler)
  }

  private func runGeneration(
    prompt: String, maxNewTokens: Int, prefillTokenCount: Int?,
    partialHandler: ((GenerationResult) -> Bool)?
  ) throws -> MeasuredGenerationResult {
    let promptTokenIds = try makePromptTokenIds(prompt: prompt, tokenLength: prefillTokenCount)
    let graph = DynamicGraph()
    let generator = Qwen3_5TextGeneration<Float16>(
      filePath: modelStore, configuration: variant.configuration, tieEmbedding: variant.tieEmbedding
    )
    var timing: Qwen3_5GenerationTiming?
    let generatedTokenIds = try generator.generate(
      graph: graph, promptTokenIds: promptTokenIds, maxTokens: max(1, maxNewTokens)
    ) { generatedTokenIds in
      guard let partialHandler = partialHandler else { return true }
      let result = GenerationResult(
        promptTokenIds: promptTokenIds, generatedTokenIds: generatedTokenIds,
        generatedText: tokenizer.decode(generatedTokenIds),
        fullText: tokenizer.decode(promptTokenIds + generatedTokenIds))
      return partialHandler(result)
    } timingHandler: {
      timing = $0
    }
    let result = GenerationResult(
      promptTokenIds: promptTokenIds, generatedTokenIds: generatedTokenIds,
      generatedText: tokenizer.decode(generatedTokenIds),
      fullText: tokenizer.decode(promptTokenIds + generatedTokenIds))
    return MeasuredGenerationResult(
      result: result, timing: GenerationTiming(timing!))
  }

  public func measureMTPDraftAcceptance(
    prompt: String, startCount: Int, maxDraftTokens: Int, prefillTokenCount: Int? = nil
  ) throws -> Qwen3_5MTPDraftAcceptanceResult {
    let promptTokenIds = try makePromptTokenIds(prompt: prompt, tokenLength: prefillTokenCount)
    let graph = DynamicGraph()
    let generator = Qwen3_5TextGeneration<Float16>(
      filePath: modelStore, configuration: variant.configuration, tieEmbedding: variant.tieEmbedding
    )
    return try generator.measureMTPDraftAcceptance(
      graph: graph, promptTokenIds: promptTokenIds, startCount: max(1, startCount),
      maxDraftTokens: max(1, maxDraftTokens))
  }

  public func measureMTPGeneration(
    prompt: String, maxNewTokens: Int, prefillTokenCount: Int? = nil
  ) throws -> MTPMeasuredGenerationResult {
    let promptTokenIds = try makePromptTokenIds(prompt: prompt, tokenLength: prefillTokenCount)
    let graph = DynamicGraph()
    let generator = Qwen3_5TextGeneration<Float16>(
      filePath: modelStore, configuration: variant.configuration, tieEmbedding: variant.tieEmbedding
    )
    let measured = try generator.generateWithMTPDrafting(
      graph: graph, promptTokenIds: promptTokenIds, maxTokens: max(1, maxNewTokens))
    let result = GenerationResult(
      promptTokenIds: promptTokenIds, generatedTokenIds: measured.generatedTokenIds,
      generatedText: tokenizer.decode(measured.generatedTokenIds),
      fullText: tokenizer.decode(promptTokenIds + measured.generatedTokenIds))
    return MTPMeasuredGenerationResult(
      result: result, timing: GenerationTiming(measured.timing),
      acceptedDrafts: measured.acceptedDrafts, rejectedDrafts: measured.rejectedDrafts,
      d1AcceptedDrafts: measured.d1AcceptedDrafts,
      d1RejectedDrafts: measured.d1RejectedDrafts,
      d1AcceptanceRate: measured.d1AcceptanceRate,
      d2AcceptedDrafts: measured.d2AcceptedDrafts,
      d2RejectedDrafts: measured.d2RejectedDrafts,
      d2AcceptanceRate: measured.d2AcceptanceRate,
      replayRounds: measured.replayRounds)
  }

  private func makePromptTokenIds(prompt: String, tokenLength: Int?) throws -> [Int32] {
    let promptTokenIds = tokenizer.tokenize(text: prompt, addSpecialTokens: false).0
    guard !promptTokenIds.isEmpty else {
      throw GenerationError.emptyPrompt
    }
    if let tokenLength = tokenLength {
      precondition(tokenLength > 0)
      return (0..<tokenLength).map { promptTokenIds[$0 % promptTokenIds.count] }
    }
    return promptTokenIds
  }

  public func benchmarkTTFT(
    prompt: String, tokenLength: Int, runs: Int, warmups: Int
  ) throws -> TTFTBenchmarkResult {
    precondition(tokenLength > 0)
    let promptTokenIds = try makePromptTokenIds(prompt: prompt, tokenLength: tokenLength)
    let graph = DynamicGraph()
    let generator = Qwen3_5TextGeneration<Float16>(
      filePath: modelStore, configuration: variant.configuration, tieEmbedding: variant.tieEmbedding
    )
    let durations = try generator.benchmarkTTFT(
      graph: graph, promptTokenIds: promptTokenIds, runs: max(1, runs), warmups: max(0, warmups))
    return TTFTBenchmarkResult(
      tokenLength: tokenLength, runs: durations.count, warmups: max(0, warmups),
      durationsMilliseconds: durations)
  }

  private static func loadTokenizer(tokenizerDirectory: String) throws -> TiktokenTokenizer {
    let directoryURL = URL(fileURLWithPath: tokenizerDirectory)
    let vocabURL = directoryURL.appendingPathComponent("vocab.json")
    let mergesURL = directoryURL.appendingPathComponent("merges.txt")
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: vocabURL.path),
      fileManager.fileExists(atPath: mergesURL.path)
    else {
      throw GenerationError.invalidTokenizerDirectory(tokenizerDirectory)
    }
    return TiktokenTokenizer(
      vocabulary: try Data(contentsOf: vocabURL), merges: try Data(contentsOf: mergesURL),
      specialTokens: qwenSpecialTokens, unknownToken: "<|endoftext|>",
      startToken: "<|endoftext|>", endToken: "<|im_end|>", pretokenizer: .qwen3_5)
  }

  private static func resolvedModelStore(_ path: String) throws -> String {
    let expandedPath = (path as NSString).expandingTildeInPath
    var candidates = [expandedPath]
    if !expandedPath.hasPrefix("/") {
      let environment = ProcessInfo.processInfo.environment
      for key in ["BUILD_WORKING_DIRECTORY", "BUILD_WORKSPACE_DIRECTORY"] {
        if let root = environment[key], !root.isEmpty {
          candidates.append(URL(fileURLWithPath: root).appendingPathComponent(expandedPath).path)
        }
      }
    }
    for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
      return candidate
    }
    throw GenerationError.invalidModelStore(path)
  }

  private static func resolvedTokenizerDirectory(_ path: String) throws -> String {
    let expandedPath = (path as NSString).expandingTildeInPath
    var candidates = [expandedPath]
    if !expandedPath.hasPrefix("/") {
      let environment = ProcessInfo.processInfo.environment
      for key in ["BUILD_WORKING_DIRECTORY", "BUILD_WORKSPACE_DIRECTORY"] {
        if let root = environment[key], !root.isEmpty {
          candidates.append(URL(fileURLWithPath: root).appendingPathComponent(expandedPath).path)
        }
      }
    }
    for candidate in candidates where hasTokenizerFiles(candidate) {
      return candidate
    }
    throw GenerationError.invalidTokenizerDirectory(path)
  }

  private static func hasTokenizerFiles(_ path: String) -> Bool {
    let directoryURL = URL(fileURLWithPath: path)
    let fileManager = FileManager.default
    return fileManager.fileExists(atPath: directoryURL.appendingPathComponent("vocab.json").path)
      && fileManager.fileExists(atPath: directoryURL.appendingPathComponent("merges.txt").path)
  }
}

private let qwenSpecialTokens: [String: Int32] = [
  "<|endoftext|>": 248_044,
  "<|im_start|>": 248_045,
  "<|im_end|>": 248_046,
  "<|object_ref_start|>": 248_047,
  "<|object_ref_end|>": 248_048,
  "<|box_start|>": 248_049,
  "<|box_end|>": 248_050,
  "<|quad_start|>": 248_051,
  "<|quad_end|>": 248_052,
  "<|vision_start|>": 248_053,
  "<|vision_end|>": 248_054,
  "<|vision_pad|>": 248_055,
  "<|image_pad|>": 248_056,
  "<|video_pad|>": 248_057,
  "<think>": 248_068,
  "</think>": 248_069,
]
