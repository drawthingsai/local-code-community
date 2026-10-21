import DataModels
import Foundation
import LLM
import NNC

private enum ProbeError: Error {
  case invalidArgument(String)
  case missingWeights(String)
  case incompleteWarmup
  case emptyPrefill
}

/// Run cold and warmed measurements in separate processes, with identical checkpoint and prompt
/// arguments. Each measurement constructs a fresh full generator after disposing of warm-up state.
@main
private struct PrefillWarmupProbe {
  static func main() {
    do {
      try run()
    } catch {
      fputs("PrefillWarmupProbe failed: \(error)\n", stderr)
      exit(1)
    }
  }

  private static func run() throws {
    var modelPath = ""
    var model = "qwen3.5-4b"
    var warmup = true
    var prefillTokens = 0
    var prefillRepeats = 1
    var decodeTokens = 0
    var thinkingBudget = 0
    var deterministic = true
    var synchronizeChunks = false
    var chunkLength = 4_096
    var disableMFAAppleNeuralEngine = false
    var queueWatermark = 128
    var weightsStreaming: DeviceCapability.WeightsStreaming?
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      if argument == "--disable-mfa-apple-neural-engine" {
        disableMFAAppleNeuralEngine = true
        continue
      }
      if argument == "--synchronize-chunks" {
        synchronizeChunks = true
        continue
      }
      guard !arguments.isEmpty else { throw ProbeError.invalidArgument(argument) }
      let value = arguments.removeFirst()
      switch argument {
      case "--model-path": modelPath = value
      case "--model": model = value
      case "--warmup":
        guard let enabled = Bool(value) else { throw ProbeError.invalidArgument(argument) }
        warmup = enabled
      case "--prefill-tokens":
        guard let count = Int(value), count >= 0 && count <= 131_072 else {
          throw ProbeError.invalidArgument(argument)
        }
        prefillTokens = count
      case "--prefill-repeats":
        guard let count = Int(value), count > 0 && count <= 8 else {
          throw ProbeError.invalidArgument(argument)
        }
        prefillRepeats = count
      case "--thinking-budget":
        guard let count = Int(value), count >= 0 else { throw ProbeError.invalidArgument(argument) }
        thinkingBudget = count
      case "--deterministic":
        guard let enabled = Bool(value) else { throw ProbeError.invalidArgument(argument) }
        deterministic = enabled
      case "--decode-tokens":
        guard let count = Int(value), count >= 0 && count <= 512 else {
          throw ProbeError.invalidArgument(argument)
        }
        decodeTokens = count
      case "--chunk-length":
        guard let count = Int(value), count == 2_048 || count == 4_096 else {
          throw ProbeError.invalidArgument(argument)
        }
        chunkLength = count
      case "--queue-watermark":
        guard let count = Int(value), count > 0 else { throw ProbeError.invalidArgument(argument) }
        queueWatermark = count
      case "--weights-streaming":
        switch value {
        case "8": weightsStreaming = ._8GiB
        case "16": weightsStreaming = ._16GiB
        case "32": weightsStreaming = ._32GiB
        case "48": weightsStreaming = ._48GiB
        case "disabled": weightsStreaming = .disabled
        default: throw ProbeError.invalidArgument(argument)
        }
      default: throw ProbeError.invalidArgument(argument)
      }
    }
    guard FileManager.default.fileExists(atPath: modelPath) else {
      throw ProbeError.missingWeights(modelPath)
    }
    let configuration: Qwen3_5ModelConfiguration
    switch model {
    case "qwen3.5-4b": configuration = .qwen3_5_4B
    case "qwen3.5-9b": configuration = .qwen3_5_9B
    case "qwen3.6-27b": configuration = .qwen3_5_27B
    case "deepseek-v4-flash": configuration = .qwen3_5_4B  // Unused in the DeepSeek path.
    default: throw ProbeError.invalidArgument(model)
    }
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let stream = StreamContext(.GPU(0))
    let previousFlags = DynamicGraph.flags
    defer { DynamicGraph.flags = previousFlags }
    if disableMFAAppleNeuralEngine {
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    }
    let executionFlags = DynamicGraph.flags
    let previousQueueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = queueWatermark
    defer { DynamicGraph.queueWatermark = previousQueueWatermark }
    print(
      "swift_optimized=\(!_isDebugAssertConfiguration()) queue_watermark=\(queueWatermark) execution_flags=\(executionFlags.rawValue) inference_dynamic_c=true"
    )
    fflush(stdout)
    try graph.withStream(stream) {
      try graph.withNoGrad {
        if warmup {
          let start = Date()
          print("warmup_start")
          fflush(stdout)
          let completed = autoreleasepool {
            let warmupGraph = DynamicGraph()
            warmupGraph.maxConcurrency = .limit(4)
            let warmupStream = StreamContext(.GPU(0))
            defer {
              warmupStream.joined()
              warmupGraph.garbageCollect()
            }
            return warmupGraph.withStream(warmupStream) {
              warmupGraph.withNoGrad {
                if model == "deepseek-v4-flash" {
                  return DeepSeek4TextGenerator(
                    filePath: modelPath, chunkedPrefillMaxLength: chunkLength,
                    weightsStreaming: weightsStreaming
                  ).warmupPrefill(graph: warmupGraph)
                }
                return Qwen3_5TextGenerator(
                  filePath: modelPath, configuration: configuration,
                  tieEmbedding: model == "qwen3.5-4b", chunkedPrefillMaxLength: chunkLength
                ).warmupPrefill(graph: warmupGraph)
              }
            }
          }
          guard completed else { throw ProbeError.incompleteWarmup }
          precondition(DynamicGraph.flags == executionFlags)
          print("warmup_complete=true warmup_seconds=\(Date().timeIntervalSince(start))")
          fflush(stdout)
        }
        guard prefillTokens > 0 else { return }
        let contextTokens = (0..<prefillTokens).map { Int32(1 + $0 % 255) }
        let tokens = graph.variable(Tensor<Int32>(contextTokens).toGPU(0))
        var deepSeekGenerator = DeepSeek4TextGenerator(
          filePath: modelPath, chunkedPrefillMaxLength: chunkLength,
          weightsStreaming: weightsStreaming)
        var qwenGenerator = Qwen3_5TextGenerator(
          filePath: modelPath, configuration: configuration, tieEmbedding: model == "qwen3.5-4b",
          chunkedPrefillMaxLength: chunkLength)
        var referenceTokens: [Int32]?
        for repeatIndex in 1...prefillRepeats {
          stream.setSeed(42)
          let start = Date()
          var loopStart = start
          var chunkStart = start
          var decodeStart: TimeInterval?
          var previousTokenTime: TimeInterval?
          var previousTokenCount = 0
          // Callback intervals preserve the generator's pipelining; do not join the GPU per token.
          let decodeProgress: (Int) -> Void = { count in
            let now = ProcessInfo.processInfo.systemUptime
            if let previousTokenTime, let decodeStart, count > previousTokenCount {
              print(
                "decode_repeat=\(repeatIndex) generated_count=\(count) token_seconds=\((now - previousTokenTime) / Double(count - previousTokenCount)) decode_seconds=\(now - decodeStart)"
              )
              fflush(stdout)
            }
            if decodeStart == nil { decodeStart = now }
            previousTokenTime = now
            previousTokenCount = count
          }
          let progress: (Int, Int) -> Void = { count, length in
            if synchronizeChunks { graph.joined() }
            let now = Date()
            if count == 0 { loopStart = now }
            print(
              "prefill_repeat=\(repeatIndex) progress=\(count)/\(length) elapsed_seconds=\(now.timeIntervalSince(start)) chunk_seconds=\(now.timeIntervalSince(chunkStart)) synchronized=\(synchronizeChunks)"
            )
            fflush(stdout)
            chunkStart = now
          }
          let result: [Int32]
          if model == "deepseek-v4-flash" {
            var cache = DeepSeek4TextGenerator.KVCache()
            let contextCache = DeepSeek4ContextCache(
              projectPath: nil, checkpointStride: deepSeekGenerator.checkpointStride)
            result = deepSeekGenerator.decode(
              graph: graph, tokens: tokens, tokenOffset: 0, thinkingBudget: thinkingBudget,
              deterministic: deterministic,
              kvCache: &cache, contextTokens: contextTokens,
              contextCache: contextCache
            ) { count, length, generated, _ in
              precondition(
                DynamicGraph.flags == executionFlags.union(.disableMFAAttentionSpecializingC))
              if generated.isEmpty {
                progress(count, length)
              } else {
                decodeProgress(generated.count)
              }
              return count < length || generated.count < decodeTokens ? .continue : .pause
            }
          } else {
            var cache = [DynamicGraph.AnyTensor]()
            var draftCache = [DynamicGraph.AnyTensor]()
            result = qwenGenerator.decode(
              graph: graph, tokens: tokens, tokenOffset: 0, thinkingBudget: thinkingBudget,
              deterministic: deterministic,
              kvCache: &cache, draftCache: &draftCache, contextTokens: contextTokens,
              contextCache: Qwen3_5ContextCache(projectPath: nil, checkpointStride: chunkLength)
            ) { count, length, generated, _ in
              precondition(
                DynamicGraph.flags == executionFlags.union(.disableMFAAttentionSpecializingC))
              if generated.isEmpty {
                progress(count, length)
              } else {
                decodeProgress(generated.count)
              }
              return count < length || generated.count < decodeTokens ? .continue : .pause
            }
          }
          graph.joined()
          precondition(DynamicGraph.flags == executionFlags)
          guard !result.isEmpty else { throw ProbeError.emptyPrefill }
          let comparedTokens = Array(result.prefix(max(decodeTokens, 1)))
          if let referenceTokens { precondition(comparedTokens == referenceTokens) }
          referenceTokens = comparedTokens
          if decodeTokens > 0 {
            print(
              "generation_repeat=\(repeatIndex) prefill_tokens=\(prefillTokens) generated_tokens=\(comparedTokens) generation_seconds=\(Date().timeIntervalSince(start))"
            )
          } else {
            print(
              "prefill_repeat=\(repeatIndex) prefill_tokens=\(prefillTokens) first_token=\(result[0]) prefill_seconds=\(Date().timeIntervalSince(start)) execution_seconds=\(Date().timeIntervalSince(loopStart))"
            )
          }
          fflush(stdout)
        }
      }
    }
    print("PrefillWarmupProbe OK")
  }
}
