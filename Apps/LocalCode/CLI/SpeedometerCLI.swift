import ArgumentParser
import DataModels
import Foundation
import LLM
import ModelZoo
import NNC

struct SpeedometerCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "speedometer",
    abstract:
      "Time a one-chunk prefill and a 128-token decode at growing context lengths, as Model Speed does."
  )

  @Option(help: "Model file identifier or display name from the models command.")
  var model: String

  @Option(help: "Checkpoint directory. Defaults to Local Code's model directory.")
  var modelsDir: String?

  @Option(help: "Explicit checkpoint path for the selected model's architecture.")
  var modelStore: String?

  @Option(
    help:
      "Context length, a multiple of 4096, to take a reading at; may be repeated. Defaults to Model Speed's."
  )
  var contextLength: [Int] = []

  @Option(help: "Context cache path. Defaults to speed_context_cache.sqlite3 under Caches.")
  var cache: String?

  @Option(help: "Thinking-token budget, from 0 to 131072.")
  var thinkingBudget: Int = 65_536

  @Flag(inversion: .prefixedNo, help: "Use the app's deterministic sampling mode.")
  var deterministic = true

  @Option(help: "Maximum prefill chunk length. Defaults to the app's device policy.")
  var chunkedPrefillMaxLength: Int?

  @Option(
    help:
      "Maximum DeepSeek weight tier in GiB: 8, 16, 24, 32, 40, 48, 56, 64, 72, or 0 for no streaming. Loads the largest tier at or below it that fits in 72% of available memory; 0 always loads every weight. V4 uses 48 for 56 and 64, and is fully resident at 72."
  )
  var weightsStreaming: Int?

  @Option(help: "Write the readings to this JSON file.")
  var resultJSON: String?

  mutating func validate() throws {
    guard (0...131_072).contains(thinkingBudget) else {
      throw ValidationError("--thinking-budget must be between 0 and 131072.")
    }
    guard contextLength.allSatisfy({ $0 >= 0 && $0.isMultiple(of: 4_096) }) else {
      throw ValidationError("--context-length must be a non-negative multiple of 4096.")
    }
    if let chunkedPrefillMaxLength, !(257...65_536).contains(chunkedPrefillMaxLength) {
      throw ValidationError("--chunked-prefill-max-length must be between 257 and 65536.")
    }
    if let weightsStreaming, DeviceCapability.WeightsStreaming(rawValue: weightsStreaming) == nil {
      throw ValidationError("--weights-streaming must be 0, 8, 16, 24, 32, 40, 48, 56, 64, or 72.")
    }
    let specification = try specification()
    if weightsStreaming != nil, specification.version != .deepseek_4_flash,
      specification.version != .deepseek_4_1_flash
    {
      throw ValidationError("--weights-streaming applies only to DeepSeek models.")
    }
  }

  func specification() throws -> LLMZoo.Specification {
    guard
      let specification = LLMZoo.builtinSpecifications.first(where: {
        $0.file == model || $0.name.caseInsensitiveCompare(model) == .orderedSame
      })
    else { throw ValidationError("Unknown model '\(model)'. Run LocalCodeCLI models.") }
    return specification
  }

  mutating func run() throws {
    let specification = try specification()
    let checkpoint: String
    if let modelStore {
      checkpoint = AgentCLIOptions.fileURL(modelStore).path
    } else if let modelsDir {
      checkpoint = try AgentCLIOptions.directory(modelsDir).appendingPathComponent(
        specification.file
      ).path
    } else {
      checkpoint = LLMZoo.filePathForModelDownloaded(specification.file)
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: checkpoint, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw ValidationError("Model checkpoint does not exist: \(checkpoint)")
    }
    // The transcript reads the same Python standard library the app bundles.
    guard
      let libraryURL = [
        Bundle.main.resourceURL?.appendingPathComponent("Library", isDirectory: true),
        Resources.repositoryURL?.appendingPathComponent(
          "Vendors/PythonIOS/ResourcesMacOS/Library", isDirectory: true),
      ].compactMap({ $0?.appendingPathComponent("lib/python3.14", isDirectory: true) }).first(
        where: { FileManager.default.fileExists(atPath: $0.path) })
    else {
      throw ValidationError(
        "Could not locate the embedded Python resources. Run through Bazel from the repository workspace."
      )
    }
    let storePath =
      cache.map { AgentCLIOptions.fileURL($0).path }
      ?? (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent(
        "speed_context_cache.sqlite3"
      ).path
    let chunkLength = chunkedPrefillMaxLength ?? DeviceCapability.chunkedPrefillMaxLength
    let contextLengths = contextLength.isEmpty ? SpeedometerReading.contextLengths : contextLength
    let oldWatermark = DynamicGraph.queueWatermark
    // The app's queue watermark for this device.
    DynamicGraph.queueWatermark =
      DeviceCapability.isUltraPerformance ? 128 : (DeviceCapability.isHighPerformance ? 32 : 8)
    defer { DynamicGraph.queueWatermark = oldWatermark }
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let stream = StreamContext(.GPU(0))
    let speedometer: any Speedometer
    switch specification.version {
    case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
      let configuration: Qwen3_5ModelConfiguration
      let tieEmbedding: Bool
      switch specification.version {
      case .qwen_3_5_4b:
        configuration = .qwen3_5_4B
        tieEmbedding = true
      case .qwen_3_5_9b:
        configuration = .qwen3_5_9B
        tieEmbedding = false
      default:
        configuration = .qwen3_5_27B
        tieEmbedding = false
      }
      speedometer = Qwen3_5Speedometer(
        textGenerator: Qwen3_5TextGenerator(
          filePath: checkpoint, configuration: configuration, tieEmbedding: tieEmbedding,
          chunkedPrefillMaxLength: chunkLength),
        model: specification.file, contextLengths: contextLengths, graph: graph,
        streamContext: stream, storePath: storePath, libraryURL: libraryURL,
        thinkingBudget: thinkingBudget, deterministic: deterministic)
    case .deepseek_4_flash:
      speedometer = DeepSeek4Speedometer(
        textGenerator: DeepSeek4TextGenerator(
          filePath: checkpoint, chunkedPrefillMaxLength: chunkLength,
          weightsStreaming: weightsStreaming.flatMap(
            DeviceCapability.WeightsStreaming.init(rawValue:))),
        contextLengths: contextLengths, graph: graph, streamContext: stream,
        storePath: storePath, libraryURL: libraryURL, thinkingBudget: thinkingBudget,
        deterministic: deterministic)
    case .deepseek_4_1_flash:
      guard let engram = specification.engram else {
        throw ValidationError("DeepSeek 4.1 requires an Engram companion.")
      }
      let engramPath = URL(fileURLWithPath: checkpoint).deletingLastPathComponent()
        .appendingPathComponent(engram).path
      guard FileManager.default.fileExists(atPath: engramPath, isDirectory: &isDirectory),
        !isDirectory.boolValue
      else {
        throw ValidationError("Engram companion does not exist: \(engramPath)")
      }
      speedometer = DeepSeek4Speedometer(
        textGenerator: DeepSeek4_1TextGenerator(
          filePath: checkpoint, engramFilePath: engramPath, chunkedPrefillMaxLength: chunkLength,
          weightsStreaming: weightsStreaming.flatMap(
            DeviceCapability.WeightsStreaming.init(rawValue:))),
        contextLengths: contextLengths, graph: graph, streamContext: stream,
        storePath: storePath, libraryURL: libraryURL, thinkingBudget: thinkingBudget,
        deterministic: deterministic)
    }
    let interrupt = AgentCLIInterrupt { speedometer.stop() }
    let progress = SpeedometerCLIProgress()
    if isatty(STDERR_FILENO) != 0 {
      speedometer.delegate = progress
    }
    let skippedLengths = contextLengths.filter { !speedometer.contextLengths.contains($0) }
    FileHandle.standardError.write(
      Data(
        ("\(specification.name), \(chunkLength)-token prefill chunks, cache at \(storePath)\n"
          + (skippedLengths.isEmpty
            ? ""
            : "Skipping \(skippedLengths) for the model's context window, the prefill chunk, or this device's memory.\n"))
          .utf8))
    print("context  prefill tok/s  decode tok/s  decoded  seconds")
    var readings = [SpeedometerReading]()
    for contextLength in speedometer.contextLengths {
      FileHandle.standardError.write(
        Data("Reading at \(contextLength) tokens of context.\n".utf8))
      let start = Date()
      let prefillTokensPerSecond = speedometer.prefillReading(contextLength: contextLength)
      let decode = prefillTokensPerSecond.flatMap { _ in
        speedometer.decodeReading(contextLength: contextLength)
      }
      progress.clear()
      guard let prefillTokensPerSecond, let decode else { break }
      let reading = SpeedometerReading(
        contextLength: contextLength, prefillTokensPerSecond: prefillTokensPerSecond,
        decodeTokensPerSecond: decode.tokensPerSecond, decodedTokenCount: decode.decodedTokenCount)
      readings.append(reading)
      print(
        String(
          format: "%7d  %13.1f  %12.1f  %7d  %7.1f", reading.contextLength,
          reading.prefillTokensPerSecond, reading.decodeTokensPerSecond, reading.decodedTokenCount,
          Date().timeIntervalSince(start)))
    }
    if let resultJSON {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(
        SpeedometerCLIResult(
          model: specification.file, chunkedPrefillMaxLength: chunkLength, readings: readings)
      ).write(to: AgentCLIOptions.fileURL(resultJSON))
    }
    if let signalNumber = interrupt.signalNumber {
      throw ExitCode(128 + signalNumber)
    }
    guard readings.count == speedometer.contextLengths.count else {
      throw ValidationError("Stopped after \(readings.count) of the readings.")
    }
  }
}

/// Keeps one line on the terminal updated with what the reading is doing.
private final class SpeedometerCLIProgress: SpeedometerDelegate {
  func speedometer(_ speedometer: any Speedometer, didUpdate progress: SpeedometerProgress) {
    switch progress {
    case .reading(let finished, let total):
      FileHandle.standardError.write(Data("\r\u{1B}[KReading \(finished)/\(total) tokens".utf8))
    case .writing(let tokens):
      FileHandle.standardError.write(Data("\r\u{1B}[KWriting \(tokens) tokens".utf8))
    case .coolingDown:
      FileHandle.standardError.write(Data("\r\u{1B}[KCooling down".utf8))
    }
  }

  func clear() {
    guard isatty(STDERR_FILENO) != 0 else { return }
    FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
  }
}

private struct SpeedometerCLIResult: Encodable {
  var model: String
  var chunkedPrefillMaxLength: Int
  var readings: [SpeedometerReading]
}
