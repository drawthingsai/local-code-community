import ArgumentParser
import Foundation
import LocalCodeCore
import NNC

public struct LocalCodeCLI: ParsableCommand {
  public init() {}
  public static let configuration = CommandConfiguration(
    commandName: "LocalCodeCLI",
    abstract: "Run Local Code models and agents.",
    subcommands: [
      LocalAgentCLI.self, RemoteAgentCLI.self, LocalModelsCLI.self, AuthCLI.self, GenerateCLI.self,
      SpeedometerCLI.self,
    ],
    defaultSubcommand: GenerateCLI.self)
}

struct GenerateCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "generate", abstract: "Run raw model generation and benchmarks.")

  @Option(help: "Built-in model shape: qwen3.5-4b, qwen3.5-9b, or qwen3.6-27b.")
  var variant: String = ModelVariant.qwen3_5_4B.rawValue

  @Option(help: "NNC sqlite checkpoint path. Defaults to the selected variant's root checkpoint.")
  var modelStore: String?

  @Option(help: "Directory containing vocab.json and merges.txt.")
  var tokenizerDir: String?

  @Option(help: "Prompt to prefill before autoregressive decode.")
  var prompt: String = "Hello"

  @Option(help: "Maximum generated tokens.")
  var maxNewTokens: Int = 8

  @Option(help: "Repeat prompt tokens cyclically to this prefill length before generation.")
  var prefillTokenCount: Int?

  @Option(help: "Run a TTFT benchmark with this synthetic prompt token length.")
  var ttftTokens: Int?

  @Option(help: "Run an MTP draft-depth acceptance sweep up to this draft length.")
  var mtpDraftTokens: Int?

  @Option(help: "Greedy start positions for MTP draft-depth acceptance sweep.")
  var mtpDraftStarts: Int = 16

  @Option(help: "TTFT timed runs.")
  var ttftRuns: Int = 5

  @Option(help: "TTFT warmup runs before timing.")
  var ttftWarmups: Int = 1

  @Option(help: "Override DynamicGraph.queueWatermark while the CLI runs.")
  var queueWatermark: Int?

  @Flag(help: "Disable MFA Apple Neural Engine paths while the CLI runs.")
  var disableMFAAppleNeuralEngine: Bool = false

  @Flag(help: "Print partial generated tokens.")
  var trace: Bool = false

  @Flag(help: "Print measured generation timing.")
  var measureGeneration: Bool = false

  @Flag(help: "Run D1 MTP optimistic generation benchmark.")
  var mtpGenerate: Bool = false

  @Flag(help: "Print timing summary without generated token ids or text.")
  var summaryOnly: Bool = false

  mutating func validate() throws {
    guard ModelVariant(rawValue: variant) != nil else {
      throw GenerationError.invalidVariant(self.variant)
    }
    guard maxNewTokens > 0, mtpDraftStarts > 0, ttftRuns > 0, ttftWarmups >= 0 else {
      throw ValidationError("Token counts and run counts must be positive; warmups may be zero.")
    }
    for value in [prefillTokenCount, ttftTokens, mtpDraftTokens, queueWatermark].compactMap({ $0 })
    {
      guard value > 0 else {
        throw ValidationError("Token counts and queue watermark must be positive.")
      }
    }
    let selectedSpecialModes =
      (ttftTokens == nil ? 0 : 1) + (mtpDraftTokens == nil ? 0 : 1)
      + (mtpGenerate ? 1 : 0)
    if selectedSpecialModes > 1 {
      throw ValidationError(
        "Use only one of --ttft-tokens, --mtp-draft-tokens, or --mtp-generate."
      )
    }
  }

  mutating func run() throws {
    guard let variant = ModelVariant(rawValue: variant) else {
      throw GenerationError.invalidVariant(self.variant)
    }
    let oldQueueWatermark = DynamicGraph.queueWatermark
    if let queueWatermark = queueWatermark {
      DynamicGraph.queueWatermark = queueWatermark
    }
    defer {
      if queueWatermark != nil {
        DynamicGraph.queueWatermark = oldQueueWatermark
      }
    }
    let oldFlags = DynamicGraph.flags
    if disableMFAAppleNeuralEngine {
      DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine)
    }
    defer {
      if disableMFAAppleNeuralEngine {
        DynamicGraph.flags = oldFlags
      }
    }
    let engine = try TextGenerationEngine(
      modelStore: AgentCLIOptions.fileURL(modelStore ?? variant.defaultModelStore).path,
      tokenizerDirectory: AgentCLIOptions.fileURL(tokenizerDir ?? variant.defaultTokenizerDirectory)
        .path,
      variant: variant)
    if let mtpDraftTokens = mtpDraftTokens {
      let result = try engine.measureMTPDraftAcceptance(
        prompt: prompt, startCount: mtpDraftStarts, maxDraftTokens: mtpDraftTokens,
        prefillTokenCount: prefillTokenCount)
      print("mtp_draft_prompt_tokens: \(result.promptTokenCount)")
      print("mtp_draft_starts: \(result.startCount)")
      print("mtp_draft_max_tokens: \(result.maxDraftTokens)")
      print(
        "mtp_draft_average_accepted_tokens: \(String(format: "%.4f", result.averageAcceptedDraftTokens))"
      )
      for (index, count) in result.acceptedPrefixCounts.enumerated() {
        let rate = result.acceptedPrefixRates[index]
        print("mtp_draft_prefix_\(index + 1)_accepted: \(count)")
        print("mtp_draft_prefix_\(index + 1)_rate: \(String(format: "%.4f", rate))")
      }
      print(
        "mtp_draft_accepted_length_counts: \(result.acceptedLengthCounts.map(String.init).joined(separator: ","))"
      )
      return
    }
    if mtpGenerate {
      let measured = try engine.measureMTPGeneration(
        prompt: prompt, maxNewTokens: maxNewTokens, prefillTokenCount: prefillTokenCount)
      let timing = measured.timing
      print("generation_prompt_tokens: \(measured.result.promptTokenIds.count)")
      print("generation_generated_tokens: \(measured.result.generatedTokenIds.count)")
      print(
        "generation_load_compile_ms: \(String(format: "%.3f", timing.loadAndCompileMilliseconds))"
      )
      print("generation_prefill_ms: \(String(format: "%.3f", timing.prefillMilliseconds))")
      print(
        "generation_decode_compile_ms: \(String(format: "%.3f", timing.decodeCompileMilliseconds))")
      print("generation_decode_loop_tokens: \(timing.decodeLoopTokens)")
      print("generation_decode_loop_ms: \(String(format: "%.3f", timing.decodeLoopMilliseconds))")
      print(
        "generation_decode_loop_tokens_per_second: \(String(format: "%.3f", timing.decodeLoopTokensPerSecond))"
      )
      print("mtp_generation_accepted_drafts: \(measured.acceptedDrafts)")
      print("mtp_generation_rejected_drafts: \(measured.rejectedDrafts)")
      print("mtp_generation_d1_accepted_drafts: \(measured.d1AcceptedDrafts)")
      print("mtp_generation_d1_rejected_drafts: \(measured.d1RejectedDrafts)")
      print(
        "mtp_generation_d1_acceptance_rate: \(String(format: "%.4f", measured.d1AcceptanceRate))")
      print("mtp_generation_d2_accepted_drafts: \(measured.d2AcceptedDrafts)")
      print("mtp_generation_d2_rejected_drafts: \(measured.d2RejectedDrafts)")
      print(
        "mtp_generation_d2_acceptance_rate: \(String(format: "%.4f", measured.d2AcceptanceRate))")
      print("mtp_generation_replay_rounds: \(measured.replayRounds)")
      guard !summaryOnly else {
        return
      }
      print("prompt_ids: \(measured.result.promptTokenIds.map(String.init).joined(separator: ","))")
      print(
        "generated_ids: \(measured.result.generatedTokenIds.map(String.init).joined(separator: ","))"
      )
      print("generated_text: \(measured.result.generatedText)")
      print("full_text: \(measured.result.fullText)")
      return
    }
    if let ttftTokens = ttftTokens {
      let result = try engine.benchmarkTTFT(
        prompt: prompt, tokenLength: ttftTokens, runs: ttftRuns, warmups: ttftWarmups)
      let durations = result.durationsMilliseconds
      let minDuration = durations.min() ?? 0
      let medianDuration = durations.sorted()[durations.count / 2]
      let maxPromptTokensPerSecond =
        minDuration > 0 ? Double(result.tokenLength) / (minDuration / 1_000) : 0
      let durationText = durations.map { String(format: "%.3f", $0) }.joined(separator: ",")
      print("ttft_tokens: \(result.tokenLength)")
      print("ttft_runs: \(result.runs)")
      print("ttft_warmups: \(result.warmups)")
      print("ttft_durations_ms: \(durationText)")
      print("ttft_max_prompt_tps: \(String(format: "%.1f", maxPromptTokensPerSecond))")
      print("ttft_min_ms: \(String(format: "%.3f", minDuration))")
      print("ttft_median_ms: \(String(format: "%.3f", medianDuration))")
      return
    }
    let shouldTrace = trace
    let partialHandler: (GenerationResult) -> Bool = { partial in
      if shouldTrace {
        print("partial_ids: \(partial.generatedTokenIds.map(String.init).joined(separator: ","))")
        print("partial_text: \(partial.generatedText)")
      }
      return true
    }
    let result: GenerationResult
    if measureGeneration {
      let measured = try engine.measureGeneration(
        prompt: prompt, maxNewTokens: maxNewTokens, prefillTokenCount: prefillTokenCount,
        partialHandler: partialHandler)
      let timing = measured.timing
      print("generation_prompt_tokens: \(measured.result.promptTokenIds.count)")
      print("generation_generated_tokens: \(measured.result.generatedTokenIds.count)")
      print(
        "generation_load_compile_ms: \(String(format: "%.3f", timing.loadAndCompileMilliseconds))")
      print("generation_prefill_ms: \(String(format: "%.3f", timing.prefillMilliseconds))")
      print(
        "generation_decode_compile_ms: \(String(format: "%.3f", timing.decodeCompileMilliseconds))")
      print("generation_decode_loop_tokens: \(timing.decodeLoopTokens)")
      print("generation_decode_loop_ms: \(String(format: "%.3f", timing.decodeLoopMilliseconds))")
      print(
        "generation_decode_loop_tokens_per_second: \(String(format: "%.3f", timing.decodeLoopTokensPerSecond))"
      )
      result = measured.result
    } else {
      result = try engine.generate(
        prompt: prompt, maxNewTokens: maxNewTokens, prefillTokenCount: prefillTokenCount,
        partialHandler: partialHandler)
    }
    guard !summaryOnly else {
      return
    }
    print("prompt_ids: \(result.promptTokenIds.map(String.init).joined(separator: ","))")
    print("generated_ids: \(result.generatedTokenIds.map(String.init).joined(separator: ","))")
    print("generated_text: \(result.generatedText)")
    print("full_text: \(result.fullText)")
  }
}
