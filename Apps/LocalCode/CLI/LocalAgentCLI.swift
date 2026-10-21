import ArgumentParser
import DataModels
import Foundation
import LLM
import ModelZoo
import NNC
import ProjectHistoryManager

extension CodeAgentReasoningEffort: ExpressibleByArgument {}

struct LocalAgentCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "local-agent",
    abstract: "Run the app's local coding agents, tools, skills, and context compaction.")

  @OptionGroup var options: AgentCLIOptions

  @Option(help: "Image file path to prepend to the prompt; may be repeated (Qwen or DeepSeek 4.1).")
  var image: [String] = []

  @Option(help: "Model file identifier or display name from the models command.")
  var model: String

  @Option(help: "Checkpoint directory. Defaults to Local Code's model directory.")
  var modelsDir: String?

  @Option(help: "Explicit checkpoint path for the selected model's architecture.")
  var modelStore: String?

  @Option(help: "Reasoning effort: low, medium, high, or max.")
  var reasoningEffort: CodeAgentReasoningEffort = .high

  @Option(help: "Thinking-token budget, from 0 to 131072.")
  var thinkingBudget: Int32 = 65_536

  @Flag(inversion: .prefixedNo, help: "Use the app's deterministic sampling mode.")
  var deterministic = true

  @Option(help: "Maximum prefill chunk length. Defaults to the app's device policy.")
  var chunkedPrefillMaxLength: Int?

  @Option(
    help:
      "Maximum DeepSeek weight tier in GiB: 8, 16, 24, 32, 40, 48, 56, 64, 72, or 0 for no streaming. Loads the largest tier at or below it that fits in 80% of available memory; 0 always loads every weight. V4 uses 48 for 56 and 64, and is fully resident at 72."
  )
  var weightsStreaming: Int?

  @Option(help: "Stop after this many generated tokens across the agent turn.")
  var maximumGeneratedTokens: Int = 131_072

  @Option(help: "Override DynamicGraph.queueWatermark while the agent runs.")
  var queueWatermark: Int = 128

  @Flag(help: "Disable MFA Apple Neural Engine paths while the agent runs.")
  var disableMFAAppleNeuralEngine = false

  mutating func validate() throws {
    guard (0...131_072).contains(thinkingBudget) else {
      throw ValidationError("--thinking-budget must be between 0 and 131072.")
    }
    guard maximumGeneratedTokens > 0, queueWatermark > 0 else {
      throw ValidationError("--maximum-generated-tokens and --queue-watermark must be positive.")
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
    let prompt = try options.readPrompt()
    let directories = try options.directories()
    let searchProvider = try options.configuredWebSearchProvider()
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
    let restored = try options.resume.map {
      try JSONDecoder().decode(
        LocalAgentResumeRecord.self, from: Data(contentsOf: AgentCLIOptions.fileURL($0)))
    }
    if let restored {
      guard restored.model == specification.file,
        AgentCLIOptions.fileURL(restored.project) == directories.project
      else { throw ValidationError("The saved conversation uses a different model or project.") }
      let vocabularySize: Int
      switch specification.version {
      case .deepseek_4_flash:
        vocabularySize = DeepSeek4ModelConfiguration.deepSeekV4Flash.vocabularySize
      case .deepseek_4_1_flash:
        vocabularySize = DeepSeek4_1ModelConfiguration.deepSeekV4_1Flash.vocabularySize
      case .qwen_3_5_4b, .qwen_3_5_9b, .qwen_3_5_27b:
        vocabularySize = Qwen3_5ModelConfiguration.qwen3_5_27B.vocabularySize
      }
      guard restored.prefixTokens.allSatisfy({ $0 >= 0 && Int($0) < vocabularySize }) else {
        throw ValidationError("The saved conversation contains invalid token IDs for this model.")
      }
    }
    let pythonHome = try configureEmbeddedCommandEnvironment()
    let catalog = SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: Resources.resourceURL?.appendingPathComponent("Skills"),
        projectURL: directories.project, workspaceURL: directories.workspace))
    let projectContext = ProjectContext.load(projectURL: directories.project)
    let environment = EnvironmentContext(
      model: specification.name, provider: "Local, via s4nnc", pythonLibraryURL: pythonHome)
    let chunkLength = chunkedPrefillMaxLength ?? DeviceCapability.chunkedPrefillMaxLength
    let prefixTokens = restored?.prefixTokens ?? []
    let prefixEmbedSpans = restored?.prefixEmbedSpans ?? []
    guard
      specification.version != .deepseek_4_flash || (image.isEmpty && prefixEmbedSpans.isEmpty)
    else {
      throw ValidationError("This model does not support image input.")
    }
    let oldWatermark = DynamicGraph.queueWatermark
    let oldFlags = DynamicGraph.flags
    DynamicGraph.queueWatermark = queueWatermark
    if disableMFAAppleNeuralEngine { DynamicGraph.flags.insert(.disableMFAAppleNeuralEngine) }
    defer {
      DynamicGraph.queueWatermark = oldWatermark
      DynamicGraph.flags = oldFlags
    }
    let graph = DynamicGraph()
    graph.maxConcurrency = .limit(4)
    let stream = StreamContext(.GPU(0))
    let agent: any CodeAgent
    let templateModel = (specification.file as NSString).deletingPathExtension
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
      let generator = Qwen3_5TextGenerator(
        filePath: checkpoint, configuration: configuration,
        tieEmbedding: tieEmbedding, chunkedPrefillMaxLength: chunkLength)
      agent = Qwen3_5CodeAgent(
        textGenerator: generator, graph: graph, streamContext: stream,
        unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
        safeTokenizer: Qwen3_5TextGenerator.safeTokenizer,
        systemPromptTemplate: SystemPromptTemplate.load(
          projectURL: directories.project, model: templateModel, template: systemPromptForQwen3_5),
        reasoningEffort: .init(reasoningEffort), skillCatalog: catalog,
        projectContext: projectContext, environmentContext: environment, prefixTokens: prefixTokens,
        prefixEmbedSpans: prefixEmbedSpans)
    case .deepseek_4_flash:
      let generator = DeepSeek4TextGenerator(
        filePath: checkpoint, chunkedPrefillMaxLength: chunkLength,
        weightsStreaming: weightsStreaming.flatMap(
          DeviceCapability.WeightsStreaming.init(rawValue:)))
      agent = DeepSeek4CodeAgent(
        textGenerator: generator, graph: graph, streamContext: stream,
        unsafeTokenizer: DeepSeek4TextGenerator.unsafeTokenizer,
        safeTokenizer: DeepSeek4TextGenerator.safeTokenizer,
        systemPromptTemplate: SystemPromptTemplate.load(
          projectURL: directories.project, model: templateModel, template: systemPromptForDeepSeek4),
        reasoningEffort: .init(reasoningEffort), skillCatalog: catalog,
        projectContext: projectContext, environmentContext: environment, prefixTokens: prefixTokens,
        prefixEmbedSpans: prefixEmbedSpans)
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
      let generator = DeepSeek4_1TextGenerator(
        filePath: checkpoint, engramFilePath: engramPath, chunkedPrefillMaxLength: chunkLength,
        weightsStreaming: weightsStreaming.flatMap(
          DeviceCapability.WeightsStreaming.init(rawValue:)))
      agent = DeepSeek4CodeAgent(
        textGenerator: generator, graph: graph, streamContext: stream,
        unsafeTokenizer: DeepSeek4_1TextGenerator.unsafeTokenizer,
        safeTokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
        systemPromptTemplate: SystemPromptTemplate.load(
          projectURL: directories.project, model: templateModel,
          template: systemPromptForDeepSeek4_1),
        reasoningEffort: .init(reasoningEffort), skillCatalog: catalog,
        projectContext: projectContext, environmentContext: environment, prefixTokens: prefixTokens,
        prefixEmbedSpans: prefixEmbedSpans)
    }
    agent.thinkingBudget = thinkingBudget
    agent.deterministic = deterministic
    let startedAt = Date()
    let interrupt = AgentCLIInterrupt()
    var limitReached = false
    var tokenCounter = LocalAgentTokenCounter()
    let tracer =
      options.trace
      ? LocalAgentTrace(
        agent: agent, project: directories.project.path, workspace: directories.workspace.path)
      : nil
    let tokenLimit = maximumGeneratedTokens
    // A unique cache identity keeps independent CLI runs from sharing suspension files.
    let threadId = Int64.random(in: 1...Int64.max)
    let result = agent.ask(
      catalog.prompt(for: prompt), imagePaths: image.map { AgentCLIOptions.fileURL($0).path },
      isMemoryEnabled: false, temporary: false,
      allowedTools: nil, threadId: threadId,
      projectPath: directories.project.path, workspacePath: directories.workspace.path,
      webSearchProvider: searchProvider
    ) { progress, _ in
      tracer?.consume(progress)
      tokenCounter.update(progress)
      if tokenCounter.count >= tokenLimit { limitReached = true }
      return limitReached || interrupt.signalNumber != nil ? .abort : .continue
    }
    tracer?.finish()
    let finalText = ToolCallParser.removeToolCalls(
      result.output, toolCallStart: agent.toolCallStart,
      toolCallEnd: agent.toolCallEnd
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let statistics = agent.statistics
    try options.writeResult(
      LocalAgentRunOutput(
        model: specification.file, project: directories.project.path,
        startedAt: startedAt, durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
        finalText: finalText, stoppedAtTokenLimit: limitReached,
        interrupted: interrupt.signalNumber != nil,
        outputTokens: result.outputTokens, toolCalls: result.toolCallHistory,
        generatedTokens: tokenCounter.count,
        contextUsedTokens: statistics.contextUsedTokens,
        contextWindowTokens: statistics.contextWindowTokens,
        prefixTokens: result.compacted ? result.logTokens : prefixTokens + result.logTokens,
        prefixEmbedSpans: result.compacted
          ? result.embedSpans
          : prefixEmbedSpans + result.embedSpans.map { $0.offset(by: prefixTokens.count) }))
    print(finalText)
    if let signal = interrupt.signalNumber { throw ExitCode(128 + signal) }
    if limitReached {
      throw ValidationError("The agent reached --maximum-generated-tokens before completing.")
    }
  }
}

// Agent statistics average recent model calls even during prefill. Count the
// actual generated-token progress instead, resetting each round at prefill.
struct LocalAgentTokenCounter {
  private var previous = 0
  private(set) var count = 0

  mutating func update(_ progress: CodeAgentProgress) {
    let current: Int
    switch progress {
    case .toolsWait:
      return
    case .prefill:
      previous = 0
      return
    case .generate(let result):
      current = result.thinkTokens.count + result.outputTokens.count
    case .compact(_, let generated, let prefill):
      guard prefill == 0 else {
        previous = 0
        return
      }
      current = generated
    }
    count += max(0, current - previous)
    previous = current
  }
}

struct LocalAgentResumeRecord: Decodable {
  var model: String
  var project: String
  var prefixTokens: [Int32]
  var prefixEmbedSpans: [EmbedSpan]?
}

private struct LocalAgentRunOutput: Encodable {
  var model: String
  var project: String
  var startedAt: Date
  var durationMilliseconds: Double
  var finalText: String
  var stoppedAtTokenLimit: Bool
  var interrupted: Bool
  var outputTokens: [Int32]
  var toolCalls: [ToolCall]
  var generatedTokens: Int
  var contextUsedTokens: Int
  var contextWindowTokens: Int
  var prefixTokens: [Int32]
  var prefixEmbedSpans: [EmbedSpan]
}

private final class LocalAgentTrace {
  private let agent: any CodeAgent
  private let project: String
  private let workspace: String
  private var text = ""
  private var completedToolCount = 0
  private var phase: String?

  init(agent: any CodeAgent, project: String, workspace: String) {
    self.agent = agent
    self.project = project
    self.workspace = workspace
  }

  func consume(_ progress: CodeAgentProgress) {
    let result: CodeAgentResult
    switch progress {
    case .generate(let value), .toolsWait(let value):
      phase = nil
      result = value
    case .prefill(_, _, let total):
      if phase != "prefill" {
        FileHandle.standardError.write(Data("\n[prefill] \(total) tokens\n".utf8))
        phase = "prefill"
      }
      return
    case .compact:
      if phase != "compact" {
        FileHandle.standardError.write(Data("\n[compacting context]\n".utf8))
        phase = "compact"
      }
      return
    }
    let visible = ToolCallParser.removeToolCalls(
      result.output, toolCallStart: agent.toolCallStart, toolCallEnd: agent.toolCallEnd)
    if visible != text {
      let addition =
        visible.hasPrefix(text) ? String(visible.dropFirst(text.count)) : "\n" + visible
      FileHandle.standardError.write(Data(addition.utf8))
      text = visible
    }
    for call in result.toolCallHistory.dropFirst(completedToolCount) {
      let subtitle =
        ToolsRegistry.parse(call.request, projectPath: project, workspacePath: workspace)?.subtitle(
          for: .past) ?? call.request.function
      FileHandle.standardError.write(Data("\n[completed] \(subtitle)\n".utf8))
    }
    completedToolCount = result.toolCallHistory.count
  }

  func finish() { FileHandle.standardError.write(Data("\n".utf8)) }
}

struct LocalModelsCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "models", abstract: "List the same local models as the app.")

  @Option(help: "Directory in which to check for installed checkpoints.")
  var modelsDir: String?

  mutating func run() throws {
    let directory = try modelsDir.map(AgentCLIOptions.directory)
    for specification in LLMZoo.builtinSpecifications {
      let installed: Bool
      if let directory {
        installed = ([specification.file] + [specification.engram].compactMap { $0 }).allSatisfy {
          FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
      } else {
        installed = LLMZoo.isModelDownloaded(specification)
      }
      print("\(specification.file)\t\(installed ? "installed" : "missing")\t\(specification.name)")
    }
  }
}
