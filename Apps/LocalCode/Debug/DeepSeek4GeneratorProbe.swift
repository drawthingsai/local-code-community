import Darwin
import DataModels
import DrawThingsCLILib
import Foundation
import NNC

private enum ProbeError: LocalizedError {
  case invalidArgument(String)
  case missingFile(String)
  case emptyTokens(String)
  case tokenMismatch(expected: [Int32], actual: [Int32])

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let argument):
      return "Invalid argument: \(argument)"
    case .missingFile(let path):
      return "File does not exist: \(path)"
    case .emptyTokens(let path):
      return "No token IDs found in: \(path)"
    case .tokenMismatch(let expected, let actual):
      return "Generated token mismatch. Expected \(expected), got \(actual)."
    }
  }
}

private struct ProbeOptions {
  var modelPath = ""
  var tokenIDsPath = ""
  var expectedTokenIDsPath: String?
  var promptTokenCount: Int?
  var repeatTokenIDs = false
  var generatedTokenCount = 4
  var chunkedPrefillMaxLength = 4_096
  var compilePrefillHeadroom = 64 * 1_024
  var weightsStreaming: DeviceCapability.WeightsStreaming?
  var disableMFAAppleNeuralEngine = false
  var printProgress = false
  var verifyReload = false
  var reloadCLIArguments: [String]?
  var reloadTokenIDsPath: String?

  static func parse() throws -> ProbeOptions {
    var options = ProbeOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      func value() throws -> String {
        guard !arguments.isEmpty else { throw ProbeError.invalidArgument(argument) }
        return arguments.removeFirst()
      }
      switch argument {
      case "--model-path":
        options.modelPath = try value()
      case "--token-ids-file":
        options.tokenIDsPath = try value()
      case "--expected-token-ids-file":
        options.expectedTokenIDsPath = try value()
      case "--prompt-tokens":
        guard let count = Int(try value()), count > 0 else {
          throw ProbeError.invalidArgument(argument)
        }
        options.promptTokenCount = count
      case "--repeat-token-ids":
        options.repeatTokenIDs = true
      case "--generated-tokens":
        guard let count = Int(try value()), count > 0 else {
          throw ProbeError.invalidArgument(argument)
        }
        options.generatedTokenCount = count
      case "--chunked-prefill-max-length":
        guard let length = Int(try value()), length > 0 else {
          throw ProbeError.invalidArgument(argument)
        }
        options.chunkedPrefillMaxLength = length
      case "--compile-prefill-headroom":
        guard let length = Int(try value()), length > 0 else {
          throw ProbeError.invalidArgument(argument)
        }
        options.compilePrefillHeadroom = length
      case "--weights-streaming":
        switch try value() {
        case "automatic":
          options.weightsStreaming = nil
        case "8":
          options.weightsStreaming = ._8GiB
        case "16":
          options.weightsStreaming = ._16GiB
        case "24":
          options.weightsStreaming = ._24GiB
        case "32":
          options.weightsStreaming = ._32GiB
        case "40":
          options.weightsStreaming = ._40GiB
        case "48":
          options.weightsStreaming = ._48GiB
        case "56":
          options.weightsStreaming = ._56GiB
        case "64":
          options.weightsStreaming = ._64GiB
        case "72":
          options.weightsStreaming = ._72GiB
        case "disabled":
          options.weightsStreaming = .disabled
        default:
          throw ProbeError.invalidArgument(argument)
        }
      case "--disable-mfa-apple-neural-engine":
        options.disableMFAAppleNeuralEngine = true
      case "--print-progress":
        options.printProgress = true
      case "--verify-reload":
        options.verifyReload = true
      case "--reload-cli-arguments-file":
        options.reloadCLIArguments = try JSONDecoder().decode(
          [String].self, from: Data(contentsOf: URL(fileURLWithPath: try value())))
        options.verifyReload = true
      case "--reload-token-ids-file":
        options.reloadTokenIDsPath = try value()
        options.verifyReload = true
      default:
        throw ProbeError.invalidArgument(argument)
      }
    }
    guard !options.modelPath.isEmpty, !options.tokenIDsPath.isEmpty else {
      throw ProbeError.invalidArgument("--model-path and --token-ids-file are required")
    }
    return options
  }
}

@main
private struct DeepSeek4GeneratorProbe {
  static func main() throws {
    let options = try ProbeOptions.parse()
    guard FileManager.default.fileExists(atPath: options.modelPath) else {
      throw ProbeError.missingFile(options.modelPath)
    }
    let loadedTokenIDs = try loadTokenIDs(path: options.tokenIDsPath)
    let tokenIDs: [Int32]
    if let promptTokenCount = options.promptTokenCount {
      guard loadedTokenIDs.count >= promptTokenCount || options.repeatTokenIDs else {
        throw ProbeError.invalidArgument(
          "--prompt-tokens exceeds the \(loadedTokenIDs.count) available token IDs")
      }
      if loadedTokenIDs.count >= promptTokenCount {
        tokenIDs = Array(loadedTokenIDs.prefix(promptTokenCount))
      } else {
        tokenIDs = (0..<promptTokenCount).map { loadedTokenIDs[$0 % loadedTokenIDs.count] }
      }
    } else {
      tokenIDs = loadedTokenIDs
    }
    let expectedTokenIDs = try options.expectedTokenIDsPath.map(loadTokenIDs(path:))

    let oldFlags = DynamicGraph.flags
    if options.disableMFAAppleNeuralEngine {
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    }
    defer { DynamicGraph.flags = oldFlags }
    let queueWatermark = DynamicGraph.queueWatermark
    DynamicGraph.queueWatermark = 128
    defer { DynamicGraph.queueWatermark = queueWatermark }

    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let streamContext = StreamContext(.GPU(0))
    let input = graph.variable(
      Tensor<Int32>(tokenIDs, .CPU, .C(tokenIDs.count)).toGPU(0))
    print(
      "weights_streaming=\(options.weightsStreaming.map { String($0.rawValue) } ?? "automatic")")
    var generator = DeepSeek4TextGenerator(
      filePath: options.modelPath,
      chunkedPrefillMaxLength: options.chunkedPrefillMaxLength,
      compilePrefillHeadroom: options.compilePrefillHeadroom,
      weightsStreaming: options.weightsStreaming)
    var kvCache = DeepSeek4TextGenerator.KVCache()
    let contextCache = DeepSeek4ContextCache(
      projectPath: nil, checkpointStride: generator.checkpointStride)
    let generated = graph.withStream(streamContext) {
      graph.withNoGrad {
        generator.decode(
          graph: graph, tokens: input, tokenOffset: 0, thinkingBudget: 0,
          kvCache: &kvCache, contextTokens: tokenIDs, contextCache: contextCache
        ) { cachedTokenLength, _, generated, statistics in
          if options.printProgress,
            generated.count.isMultiple(of: 128) || cachedTokenLength.isMultiple(of: 512)
          {
            let tail = DeepSeek4TextGenerator.unsafeTokenizer.decode(
              Array(generated.suffix(64)))
            print(
              "generation_progress cached_tokens=\(cachedTokenLength) generated_tokens=\(generated.count) prefill_seconds=\(statistics.prefillDurationSoFar) prefill_tok_s=\(statistics.prefillTokensPerSecond) tail=\(String(reflecting: tail))"
            )
            fflush(stdout)
          }
          return generated.count < options.generatedTokenCount ? .continue : .abort
        }
      }
    }
    streamContext.joined()

    let result = Array(generated.prefix(options.generatedTokenCount))
    print("prompt_tokens=\(tokenIDs.count)")
    print("generated_tokens=\(result.map(String.init).joined(separator: " "))")
    print("generated_text=\(DeepSeek4TextGenerator.unsafeTokenizer.decode(result))")
    print(
      "prefill_tokens_per_second=\(generator.statistics.prefillTokensPerSecond) token_generation_per_second=\(generator.statistics.tokenGeneratedPerSecond)"
    )
    if let expectedTokenIDs {
      let expected = Array(expectedTokenIDs.prefix(options.generatedTokenCount))
      guard result == expected else {
        throw ProbeError.tokenMismatch(expected: expected, actual: result)
      }
      print("DeepSeek4GeneratorProbe TOKEN_MATCH")
    }
    if options.verifyReload {
      let context = tokenIDs + generated
      guard kvCache.tokenLength == context.count else {
        throw ProbeError.invalidArgument(
          "--verify-reload requires generation to reach its token limit")
      }
      let snapshot = graph.withNoGrad { kvCache.snapshot() }
      // Continue from the same conversation state, with a one-token prefill by default.
      let continuationTokens = try options.reloadTokenIDsPath.map(loadTokenIDs(path:)) ?? [198]
      func continueDecoding(stopAfterPrefill: Bool = false) -> [Int32] {
        let tokens: [Int32] = stopAfterPrefill ? [1] : continuationTokens
        return graph.withStream(streamContext) {
          graph.withNoGrad {
            generator.decode(
              graph: graph,
              tokens: graph.variable(Tensor<Int32>(tokens).toGPU(0)),
              tokenOffset: context.count, thinkingBudget: 0,
              kvCache: &kvCache, contextTokens: context + tokens,
              contextCache: contextCache
            ) { completed, total, generated, _ in
              if stopAfterPrefill {
                return completed == total ? .abort : .continue
              }
              if generated.count == 2 {
                print("reload_continuation generated_tokens=2 \(memoryUsage())")
                fflush(stdout)
              }
              return generated.count < options.generatedTokenCount ? .continue : .abort
            }
          }
        }
      }
      let expected = continueDecoding()
      guard expected.count == options.generatedTokenCount else {
        throw ProbeError.invalidArgument("reload continuation ended before its generation limit")
      }
      streamContext.joined()
      print("reload_initial \(memoryUsage())")
      let sharedCopy = generator
      for iteration in 1...2 {
        kvCache = graph.withNoGrad { snapshot.snapshot() }
        // The agent prefills forced terminal tokens before a tool and aborts
        // without reading the sampled token. Do not add a stream join here.
        _ = continueDecoding(stopAfterPrefill: true)
        // Match the embedded tool: model teardown happens on its worker, without
        // collecting the generation graph while the agent waits for the tool.
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
          autoreleasepool {
            let unload = {
              sharedCopy.unload()
              print("reload_iteration=\(iteration) unloaded \(memoryUsage())")
              fflush(stdout)
            }
            if let arguments = options.reloadCLIArguments {
              let context = DrawThingsCLIContext(
                input: stdin, output: stdout, error: stderr,
                environment: ProcessInfo.processInfo.environment,
                isStandardOutputTTY: false,
                resolvePath: { ($0 as NSString).expandingTildeInPath },
                unloadTextGenerator: unload)
              precondition(DrawThingsCLI.run(arguments: arguments, context: context) == 0)
            } else {
              unload()
            }
          }
          completed.signal()
        }
        precondition(completed.wait(timeout: .now() + 600) == .success)
        print("reload_iteration=\(iteration) after_tool \(memoryUsage())")
        fflush(stdout)
        kvCache = graph.withNoGrad { snapshot.snapshot() }
        let actual = continueDecoding()
        streamContext.joined()
        print("reload_iteration=\(iteration) loaded \(memoryUsage())")
        guard actual == expected else {
          throw ProbeError.tokenMismatch(expected: expected, actual: actual)
        }
      }
      sharedCopy.unload()
      print("DeepSeek4GeneratorProbe RELOAD_MATCH")
    }
    print("DeepSeek4GeneratorProbe OK")
  }

  private static func memoryUsage() -> String {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    precondition(status == KERN_SUCCESS)
    return
      "footprint=\(info.phys_footprint) resident_size=\(info.resident_size) compressed=\(info.compressed)"
  }

  private static func loadTokenIDs(path: String) throws -> [Int32] {
    guard FileManager.default.fileExists(atPath: path) else {
      throw ProbeError.missingFile(path)
    }
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let tokenIDs = contents.split(whereSeparator: \Character.isWhitespace).compactMap {
      Int32($0)
    }
    guard !tokenIDs.isEmpty else { throw ProbeError.emptyTokens(path) }
    return tokenIDs
  }
}
