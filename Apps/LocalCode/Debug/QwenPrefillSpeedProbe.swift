import DataModels
import Foundation
import LLM
import NNC

private enum PrefillSpeedError: Error {
  case invalidArgument(String)
  case missingFile(String)
  case incompleteReading(Int)
}

/// Uses Model Speed's transcript and cache restore, but measures only the new-token prefill.
///
/// Joins at the boundaries so restore and pending MTP work cannot bias the measured duration.
private final class PrefillTiming: SpeedometerDelegate {
  let stream: StreamContext
  let promptTokens: Int
  private var start: TimeInterval?
  var seconds: Double?

  init(stream: StreamContext, promptTokens: Int = 4_096) {
    self.stream = stream
    self.promptTokens = promptTokens
  }

  func reset() {
    start = nil
    seconds = nil
  }

  func speedometer(_ speedometer: any Speedometer, didUpdate progress: SpeedometerProgress) {
    guard case .reading(let finished, let total) = progress else { return }
    didUpdate(finished: finished, total: total)
  }

  func didUpdate(finished: Int, total: Int) {
    guard total == promptTokens else { return }
    if finished == 0 {
      // The initial callback precedes restore; the next zero callback follows it. Restart there.
      stream.joined()
      start = ProcessInfo.processInfo.systemUptime
    } else if finished == total, let start {
      stream.joined()
      seconds = ProcessInfo.processInfo.systemUptime - start
    }
  }
}

private struct PrefillSpeedReading: Encodable {
  let contextTokens: Int
  let promptTokens: Int
  let repeatIndex: Int
  let warmup: Bool
  let seconds: Double
  let tokensPerSecond: Double
  let thermalState: Int
}

@main
private struct QwenPrefillSpeedProbe {
  static func main() throws {
    var modelPath = ""
    var cachePath = ""
    var outputPath = ""
    var contextLengths = [4_096, 8_192, 16_384, 32_768, 65_536, 131_072]
    var promptLengths = [4_096]
    var repeats = 3
    var reuseCache = false
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      if argument == "--reuse-cache" {
        reuseCache = true
        continue
      }
      guard !arguments.isEmpty else { throw PrefillSpeedError.invalidArgument(argument) }
      let value = arguments.removeFirst()
      switch argument {
      case "--model-path": modelPath = value
      case "--cache": cachePath = value
      case "--output-jsonl": outputPath = value
      case "--repeats":
        guard let count = Int(value), (1...8).contains(count) else {
          throw PrefillSpeedError.invalidArgument(argument)
        }
        repeats = count
      case "--context-lengths":
        let lengths = value.split(separator: ",").compactMap { Int($0) }
        guard !lengths.isEmpty, lengths.count == value.split(separator: ",").count,
          lengths.allSatisfy({ (4_096...131_072).contains($0) && $0.isMultiple(of: 4_096) })
        else { throw PrefillSpeedError.invalidArgument(argument) }
        contextLengths = lengths
      case "--prompt-lengths":
        let lengths = value.split(separator: ",").compactMap { Int($0) }
        guard !lengths.isEmpty, lengths.count == value.split(separator: ",").count,
          Set(lengths).count == lengths.count, lengths.allSatisfy({ (1...4_096).contains($0) })
        else { throw PrefillSpeedError.invalidArgument(argument) }
        promptLengths = lengths
      default: throw PrefillSpeedError.invalidArgument(argument)
      }
    }
    guard FileManager.default.fileExists(atPath: modelPath) else {
      throw PrefillSpeedError.missingFile(modelPath)
    }
    let libraryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("Vendors/PythonIOS/ResourcesMacOS/Library/lib/python3.14")
    guard FileManager.default.fileExists(atPath: libraryURL.path) else {
      throw PrefillSpeedError.missingFile(libraryURL.path)
    }
    guard !cachePath.isEmpty, !outputPath.isEmpty,
      (reuseCache && FileManager.default.fileExists(atPath: cachePath))
        || (!reuseCache && !FileManager.default.fileExists(atPath: cachePath)),
      !FileManager.default.fileExists(atPath: outputPath)
    else {
      throw PrefillSpeedError.invalidArgument("Use a fresh output and an independent arm cache")
    }
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: outputURL, options: .withoutOverwriting)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let encoder = JSONEncoder()
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let stream = StreamContext(.GPU(0))
    let oldWatermark = DynamicGraph.queueWatermark
    let oldFlags = DynamicGraph.flags
    DynamicGraph.queueWatermark = 128
    DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    defer {
      stream.joined()
      DynamicGraph.queueWatermark = oldWatermark
      DynamicGraph.flags = oldFlags
    }
    if promptLengths != [4_096] {
      guard reuseCache else {
        throw PrefillSpeedError.invalidArgument("Smaller prefills require --reuse-cache")
      }
      guard
        let transcript = SpeedometerTranscript(
          template: Qwen3_5Speedometer.Template(isThinking: false), libraryURL: libraryURL,
          promptLength: 4_096, maximumContextLength: 131_072)
      else { throw PrefillSpeedError.invalidArgument("Cannot construct Model Speed transcript") }
      var generator = Qwen3_5TextGenerator(
        filePath: modelPath, configuration: .qwen3_5_27B, tieEmbedding: false,
        chunkedPrefillMaxLength: 4_096)
      print(
        "swift_optimized=\(!_isDebugAssertConfiguration()) chunk_length=4096 queue_watermark=128 prompt_lengths=\(promptLengths) mtp=automatic"
      )
      fflush(stdout)
      for contextLength in contextLengths {
        guard let fullPrompt = transcript.promptTokens(contextLength: contextLength) else {
          throw PrefillSpeedError.invalidArgument("Missing prompt for context")
        }
        let context = Array(transcript.contextTokens.prefix(contextLength))
        for promptLength in promptLengths {
          let ids = context + fullPrompt.prefix(promptLength)
          let timing = PrefillTiming(stream: stream, promptTokens: promptLength)
          for repeatIndex in 0...repeats {
            timing.reset()
            print(
              "begin context_tokens=\(contextLength) prompt_tokens=\(promptLength) repeat=\(repeatIndex)"
            )
            fflush(stdout)
            let cache = Qwen3_5ContextCache(
              storePath: cachePath, checkpointStride: 4_096, isReadOnly: true,
              maximumRestoredTokenLength: contextLength)
            var kvCache = [DynamicGraph.AnyTensor]()
            var draftCache = [DynamicGraph.AnyTensor]()
            let tokens = graph.variable(Tensor<Int32>(ids).toGPU(0))
            _ = graph.withStream(stream) {
              graph.withNoGrad {
                generator.decode(
                  graph: graph, tokens: tokens, tokenOffset: 0, thinkingBudget: 0,
                  deterministic: true, kvCache: &kvCache, draftCache: &draftCache,
                  contextTokens: ids, contextCache: cache
                ) { count, _, generated, _ in
                  if let restored = cache.restoredTokenLength, restored < contextLength {
                    return .abort
                  }
                  timing.didUpdate(
                    finished: max(0, count - contextLength), total: promptLength)
                  return generated.isEmpty && count < ids.count ? .continue : .abort
                }
              }
            }
            stream.joined()
            guard cache.restoredTokenLength == contextLength,
              let seconds = timing.seconds, seconds > 0
            else { throw PrefillSpeedError.incompleteReading(contextLength) }
            let reading = PrefillSpeedReading(
              contextTokens: contextLength, promptTokens: promptLength, repeatIndex: repeatIndex,
              warmup: repeatIndex == 0, seconds: seconds,
              tokensPerSecond: Double(promptLength) / seconds,
              thermalState: ProcessInfo.processInfo.thermalState.rawValue)
            var data = try encoder.encode(reading)
            data.append(0x0a)
            try output.write(contentsOf: data)
            try output.synchronize()
            print(String(decoding: data, as: UTF8.self), terminator: "")
            fflush(stdout)
          }
        }
      }
      print("QwenPrefillSpeedProbe OK")
      return
    }
    let speedometer = Qwen3_5Speedometer(
      textGenerator: Qwen3_5TextGenerator(
        filePath: modelPath, configuration: .qwen3_5_27B, tieEmbedding: false,
        chunkedPrefillMaxLength: 4_096),
      model: "qwen_3.8_27b_i4x.ckpt", contextLengths: contextLengths, graph: graph,
      streamContext: stream, storePath: cachePath, libraryURL: libraryURL,
      thinkingBudget: 0, deterministic: true)
    guard speedometer.contextLengths == contextLengths else {
      throw PrefillSpeedError.invalidArgument("Context window or memory capacity")
    }
    let timing = PrefillTiming(stream: stream)
    speedometer.delegate = timing
    print(
      "swift_optimized=\(!_isDebugAssertConfiguration()) chunk_length=4096 queue_watermark=128 prompt_tokens=4096 mtp=automatic"
    )
    fflush(stdout)
    for contextLength in contextLengths {
      // Build/restore the context and warm this exact shape before three fresh-cache readings.
      for repeatIndex in 0...repeats {
        timing.reset()
        print("begin context_tokens=\(contextLength) repeat=\(repeatIndex)")
        fflush(stdout)
        guard speedometer.prefillReading(contextLength: contextLength) != nil,
          let seconds = timing.seconds, seconds > 0
        else { throw PrefillSpeedError.incompleteReading(contextLength) }
        let reading = PrefillSpeedReading(
          contextTokens: contextLength, promptTokens: 4_096, repeatIndex: repeatIndex,
          warmup: repeatIndex == 0, seconds: seconds, tokensPerSecond: 4_096 / seconds,
          thermalState: ProcessInfo.processInfo.thermalState.rawValue)
        var data = try encoder.encode(reading)
        data.append(0x0a)
        try output.write(contentsOf: data)
        try output.synchronize()
        print(String(decoding: data, as: UTF8.self), terminator: "")
        fflush(stdout)
      }
    }
    print("QwenPrefillSpeedProbe OK")
  }
}
