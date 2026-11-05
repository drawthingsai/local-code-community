import BashToolContext
import DataModels
import Foundation
import ModelZoo
import NNC
import SQLiteDflat

/// Serves a real model through `ServeController` and `AgentScheduler`, the path the app uses,
/// without any of the app's UI. Point a client at the printed URL.
///
///   SIGUSR1 runs a fake foreground chat turn for `--chat-seconds`, which should pause a request.
///   SIGUSR2 retires the scheduler, as switching the chat's model does; a request should carry on.
///   SIGHUP turns serving off, as its toggle does; a request should end and the scheduler go idle.
@main
enum ResponsesServeProbe {
  static func main() {
    var values = [String: String]()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while arguments.count >= 2 {
      values[arguments.removeFirst()] = arguments.removeFirst()
    }
    guard let modelPath = values["--model-path"], let family = values["--family"],
      let cachePath = values["--cache-project-path"]
    else {
      print(
        "Usage: --model-path <ckpt> --family <qwen_3_5_27b|deepseek_4|deepseek_4_1> --cache-project-path <dir> [--chat-seconds 8] [--hot-limit 1] [--time-slice 2] [--weights-streaming 48] [--ip 0.0.0.0] [--port 11435]"
      )
      exit(2)
    }
    let probe = Probe(
      modelPath: modelPath, family: family, cacheProjectPath: cachePath,
      chatSeconds: values["--chat-seconds"].flatMap(TimeInterval.init) ?? 8,
      hotLimit: values["--hot-limit"].flatMap(Int.init),
      timeSlice: values["--time-slice"].flatMap(TimeInterval.init)
        ?? ServeController.defaultTimeSlice,
      weightsStreaming: values["--weights-streaming"].flatMap(Int.init).flatMap(
        DeviceCapability.WeightsStreaming.init(rawValue:)), ip: values["--ip"],
      port: values["--port"].flatMap(Int.init))
    probe.start()
    // A run loop, as in the app, since ServeController's timers need one.
    withExtendedLifetime(probe) { RunLoop.main.run() }
  }
}

/// A chat turn that holds the model for a while without using it.
private final class FakeChatAgent: CodeAgent {
  let seconds: TimeInterval
  init(seconds: TimeInterval) { self.seconds = seconds }
  let bashUserInteraction = BashUserInteraction()
  var thinkingBudget: Int32 = 0
  var deterministic = true
  var statistics = CodeAgentStatistics()
  var suspendedResult: CodeAgentResult? { nil }
  var toolCallStart = ""
  var toolCallEnd = ""
  var toolCallSpecialTokens = [Int32: String]()
  func ask(
    _ prompt: String, imagePaths: [String], isMemoryEnabled: Bool, temporary: Bool,
    allowedTools: Set<ToolsRegistry.Tool>?, threadId: Int64,
    environment: any CodeAgentEnvironment,
    progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState
  ) -> CodeAgentResult {
    resume(progress: progress)
  }
  func resume(progress: (CodeAgentProgress, CodeAgentStatistics) -> ContinuationState)
    -> CodeAgentResult
  {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
      _ = progress(.generate(.empty), statistics)
      Thread.sleep(forTimeInterval: 0.1)
    }
    return .empty
  }
  func hibernate(threadId: Int64) throws {}
  func unloadCaches() {}
  func restoreSuspension(threadId: Int64, environment: any CodeAgentEnvironment) throws -> Bool {
    false
  }
  func canStopImmediately(with result: CodeAgentResult) -> Bool { true }
  func isCapReachedForStopping(from resultAtStop: CodeAgentResult, to result: CodeAgentResult)
    -> Bool
  { true }
}

private final class Probe: ServeControllerDelegate {
  private let modelPath: String
  private let family: String
  private let cacheProjectPath: String
  private let chatSeconds: TimeInterval
  private let hotLimit: Int?
  private let timeSlice: TimeInterval
  private let ip: String?
  private let port: Int?
  private let weightsStreaming: DeviceCapability.WeightsStreaming?
  private let queue = DispatchQueue(label: "responses-serve-probe.generation")
  private let graph = DynamicGraph()
  private let streamContext = StreamContext(.GPU(0))
  // Where the app keeps the settings ServeController reads, and the model it serves.
  private lazy var serveWorkspace = SQLiteWorkspace(
    filePath: NSTemporaryDirectory()
      + "responses-serve-probe-settings-\(UUID().uuidString).sqlite3",
    fileProtectionLevel: .noProtection)
  private var controller: ServeController?
  private lazy var scheduler = makeScheduler()
  private lazy var textGenerator: any TextGenerator = makeTextGenerator()
  private var signalSources = [DispatchSourceSignal]()
  private var chatAgent: FakeChatAgent?
  private lazy var chatWorkspace = SQLiteWorkspace(
    filePath: NSTemporaryDirectory() + "responses-serve-probe-\(UUID().uuidString).sqlite3",
    fileProtectionLevel: .noProtection)
  private var stateSubscription: Any?

  init(
    modelPath: String, family: String, cacheProjectPath: String, chatSeconds: TimeInterval,
    hotLimit: Int?, timeSlice: TimeInterval, weightsStreaming: DeviceCapability.WeightsStreaming?,
    ip: String?, port: Int?
  ) {
    self.ip = ip
    self.port = port
    self.hotLimit = hotLimit
    self.timeSlice = timeSlice
    self.weightsStreaming = weightsStreaming
    self.modelPath = modelPath
    self.family = family
    self.cacheProjectPath = cacheProjectPath
    self.chatSeconds = chatSeconds
  }

  func start() {
    DynamicGraph.queueWatermark =
      DeviceCapability.isUltraPerformance ? 128 : (DeviceCapability.isHighPerformance ? 32 : 8)
    graph.maxConcurrency = .limit(4)
    serveWorkspace.dictionary["serve_model", String.self] =
      URL(fileURLWithPath: modelPath).lastPathComponent
    if let ip {
      serveWorkspace.dictionary["serve_ip", String.self] = ip
    }
    if let port {
      serveWorkspace.dictionary["serve_port", Int.self] = port
    }
    let controller = ServeController(
      queue: queue, graph: graph, streamContext: streamContext, workspace: serveWorkspace,
      timeSlice: timeSlice)
    controller.delegate = self
    self.controller = controller
    var lastLine = ""
    stateSubscription = controller.state.receive(on: DispatchQueue.main).sink { state in
      let request = state.metrics.requests.last
      let line =
        "listener=\(state.listener) phase=\(String(describing: state.activePhase)) queued=\(state.queuedRequestCount) served=\(state.metrics.requestCount) cache=\(state.contextCacheSize ?? 0) last=\(request.map { "\($0.status) in=\($0.inputTokens) cached=\($0.cachedInputTokens) out=\($0.outputTokens) \($0.prefillTokensPerSecond)/s \($0.generationTokensPerSecond)/s wait=\($0.timing.waitingSeconds) read=\($0.timing.prefillSeconds) write=\($0.timing.generationSeconds) first=\($0.timing.timeToFirstToken ?? -1)" } ?? "-") samples=\(state.metrics.samples.suffix(3).map { Int($0.generationTokensPerSecond) }) memory=\((state.metrics.samples.last?.memoryBytes ?? 0) / 1_048_576)MB"
      if line != lastLine {
        lastLine = line
        print(line)
        fflush(stdout)
      }
    }
    print(
      "Serving \(modelPath) at \(ServeController.baseURL(port: controller.state.value.port)), pid \(getpid())"
    )
    fflush(stdout)
    signal(SIGUSR1, SIG_IGN)
    signal(SIGUSR2, SIG_IGN)
    signal(SIGHUP, SIG_IGN)
    for (number, handler) in [
      (SIGUSR1, runFakeChatTurn), (SIGUSR2, retireScheduler), (SIGHUP, turnOffServing),
    ] {
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler(handler: handler)
      source.resume()
      signalSources.append(source)
    }
  }

  private func makeScheduler() -> AgentScheduler {
    let scheduler = AgentScheduler(queue: queue, maximumHotCodeAgentCount: hotLimit ?? Int.max)
    scheduler.set(
      filePath: modelPath, residentWeightsSize: textGenerator.residentWeightsSize,
      estimatedKVCacheSize: type(of: textGenerator).estimatedKVCacheSize)
    return scheduler
  }

  private func makeTextGenerator() -> any TextGenerator {
    let chunk = DeviceCapability.chunkedPrefillMaxLength
    if family == "deepseek_4_1" {
      let tier = DeviceCapability.WeightsStreaming.residentTierForDeepSeek4_1(
        requested: weightsStreaming, draft: false)
      print(
        "Weights streaming: requested \(String(describing: weightsStreaming)), automatic \(DeviceCapability.weightsStreaming), available \(DeviceCapability.availableMemory / 1_073_741_824) GiB, resolved \(tier)"
      )
    }
    switch family {
    case "qwen_3_5_4b":
      return Qwen3_5TextGenerator(
        filePath: modelPath, configuration: .qwen3_5_4B, tieEmbedding: true,
        chunkedPrefillMaxLength: chunk)
    case "qwen_3_5_9b":
      return Qwen3_5TextGenerator(
        filePath: modelPath, configuration: .qwen3_5_9B, tieEmbedding: false,
        chunkedPrefillMaxLength: chunk)
    case "qwen_3_5_27b":
      return Qwen3_5TextGenerator(
        filePath: modelPath, configuration: .qwen3_5_27B, tieEmbedding: false,
        chunkedPrefillMaxLength: chunk)
    case "deepseek_4":
      return DeepSeek4TextGenerator(
        filePath: modelPath, chunkedPrefillMaxLength: chunk, weightsStreaming: weightsStreaming)
    case "deepseek_4_1":
      let url = URL(fileURLWithPath: modelPath)
      let name = url.deletingPathExtension().lastPathComponent
      return DeepSeek4_1TextGenerator(
        filePath: modelPath,
        engramFilePath: url.deletingLastPathComponent().appendingPathComponent(
          "\(name).engram"
        ).path,
        chunkedPrefillMaxLength: chunk, weightsStreaming: weightsStreaming, drafterFile: nil)
    default:
      fatalError("Unknown family \(family)")
    }
  }

  private func runFakeChatTurn() {
    print("SIGUSR1: fake chat turn for \(chatSeconds)s")
    fflush(stdout)
    let agent = FakeChatAgent(seconds: chatSeconds)
    chatAgent = agent
    let scheduler = scheduler
    scheduler.setForeground(agent)
    scheduler.ask(
      agent, threadId: 1, "Chat", isMemoryEnabled: false, projectPath: NSTemporaryDirectory(),
      projectWorkspace: chatWorkspace, workspacePath: nil, webSearchProvider: .disabled,
      progress: { _, _ in },
      completion: { _, _ in
        DispatchQueue.main.async {
          print("Fake chat turn finished")
          fflush(stdout)
          scheduler.setForeground(nil)
          scheduler.markAsCompleted(agent)
        }
      })
  }

  private func retireScheduler() {
    print("SIGUSR2: retiring the scheduler")
    fflush(stdout)
    let retired = scheduler
    let current = makeScheduler()
    scheduler = current
    retired.hibernateAll { [weak self] _ in
      DispatchQueue.main.async {
        print("Retired; handing over")
        fflush(stdout)
        self?.controller?.scheduler(retired, didRetireInFavorOf: current)
      }
    }
  }

  private func turnOffServing() {
    print("SIGHUP: serving off")
    fflush(stdout)
    controller = nil
    // The turn ends at its next token once its connection closes, then tells the scheduler.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
      print("scheduler idle=\(scheduler.isIdle)")
      fflush(stdout)
    }
  }

  func serveController(_ controller: ServeController, schedulerFor model: String) -> AgentScheduler?
  {
    scheduler
  }

  func serveController(_ controller: ServeController, textGeneratorToRun model: String)
    -> (any TextGenerator)?
  {
    // A new one each time, as the chat hands over for a model it doesn't run, so it's serving that
    // has to share it between agents.
    makeTextGenerator()
  }

  func serveControllerContextCacheProjectPath(_ controller: ServeController) -> String {
    cacheProjectPath
  }
}
