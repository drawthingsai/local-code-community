import ArgumentParser
import BashToolContext
import Foundation
import RemoteAPI
import WebSearch

extension RemoteProvider: @retroactive ExpressibleByArgument {}
extension RemoteRuntime: ExpressibleByArgument {}
extension RemoteReasoningEffort: @retroactive ExpressibleByArgument {}

struct RemoteAgentCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remote-agent",
    abstract: "Run the Cloud agent with Local Code tools and context compaction.")

  @Option(help: "Remote provider: localcode, openai, openai-compatible, openrouter, or anthropic.")
  var provider: RemoteProvider

  @Option(help: "Remote model identifier.")
  var model: String

  @Option(help: "API base URL. Defaults to the selected provider's public endpoint.")
  var baseURL: String?

  @Option(help: "Environment variable containing the API key.")
  var apiKeyEnvironment: String?

  @Flag(help: "Connect to an OpenAI-compatible server without sending an API key.")
  var noAuth = false

  @Option(
    help:
      "Image file to attach (PNG, JPEG, WebP, GIF). Repeat for multiple images."
  )
  var image: [String] = []

  @OptionGroup var options: AgentCLIOptions

  @Option(help: "Reasoning effort: low, medium, high, or max.")
  var reasoningEffort: RemoteReasoningEffort = .high

  @Option(help: "Override the context-window size reported by the provider.")
  var contextWindowTokens: Int?

  @Option(help: "Override the maximum output tokens reported by the provider.")
  var maximumOutputTokens: Int?

  @Option(help: "Maximum model/tool rounds.")
  var maximumRounds: Int = 64

  @Option(help: "Fraction of the selected remote model context that triggers compaction.")
  var compactionThreshold = RemoteAgentConfiguration.defaultCompactionThreshold

  @Option(help: "Target fraction of the remote model context used after compaction.")
  var compactionTarget = RemoteAgentConfiguration.defaultCompactionTarget

  @Option(help: "Optional runtime description appended to the system prompt: mac or ios-system.")
  var runtime: RemoteRuntime = .mac

  mutating func validate() throws {
    guard maximumRounds > 0 else {
      throw ValidationError("--maximum-rounds must be greater than zero.")
    }
    if let contextWindowTokens, contextWindowTokens < 4_096 {
      throw ValidationError("--context-window-tokens must be at least 4096.")
    }
    if let maximumOutputTokens, maximumOutputTokens <= 0 {
      throw ValidationError("--maximum-output-tokens must be greater than zero.")
    }
    guard
      (RemoteAgentConfiguration
        .minimumCompactionThreshold...RemoteAgentConfiguration.maximumCompactionThreshold).contains(
          compactionThreshold)
    else {
      throw ValidationError("--compaction-threshold must be between 0.35 and 0.85.")
    }
    guard compactionTarget >= RemoteAgentConfiguration.minimumCompactionTarget,
      compactionTarget
        <= compactionThreshold - RemoteAgentConfiguration.compactionTargetMargin
    else {
      throw ValidationError(
        "--compaction-target must be at least 0.15 and at least 0.05 below the threshold.")
    }
  }

  mutating func run() async throws {
    try await run(sessionConfiguration: .ephemeral)
  }

  mutating func run(sessionConfiguration: URLSessionConfiguration) async throws {
    let userMessage = try options.readPrompt()
    let images = try image.map {
      try RemoteImage(attachmentContentsOf: AgentCLIOptions.fileURL($0))
    }
    let directories = try options.directories()
    let projectURL = directories.project
    let configuredWebSearchProvider = try options.configuredWebSearchProvider()

    let endpointBaseURL: URL?
    if let baseURL {
      guard let url = URL(string: baseURL) else {
        throw ValidationError("Invalid API base URL: \(baseURL)")
      }
      endpointBaseURL = url
    } else {
      endpointBaseURL = nil
    }
    let endpoint = try RemoteProviderEndpoint(
      provider: provider, baseURL: endpointBaseURL, model: model)
    let authorization = try authorization(endpoint: endpoint)
    let restored = try options.resume.map {
      try JSONDecoder().decode(
        RemoteAgentResumeRecord.self, from: Data(contentsOf: AgentCLIOptions.fileURL($0)))
    }
    if let restored {
      guard restored.provider == provider.rawValue, restored.model == endpoint.model,
        restored.baseURL == endpoint.baseURL.absoluteString,
        AgentCLIOptions.fileURL(restored.project) == projectURL
      else {
        throw ValidationError(
          "The saved conversation uses a different provider, model, endpoint, or project.")
      }
    }
    let discoveredLimits: RemoteModelLimits?
    if contextWindowTokens == nil || maximumOutputTokens == nil {
      discoveredLimits = try await modelLimits(
        endpoint: endpoint, authorization: authorization, sessionConfiguration: sessionConfiguration
      )
    } else {
      discoveredLimits = nil
    }
    guard
      let contextTokens = contextWindowTokens ?? discoveredLimits?.contextWindowTokens,
      let requestedOutputTokens = maximumOutputTokens ?? discoveredLimits?.maximumOutputTokens
    else {
      throw RemoteModelMetadataError.limitsUnavailable
    }
    if let maximumOutputTokens, maximumOutputTokens > contextTokens / 3 {
      throw ValidationError(
        "--maximum-output-tokens must be no more than one third of the context window.")
    }
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: contextTokens, reservedOutputTokens: requestedOutputTokens,
      compactionThreshold: compactionThreshold, compactionTarget: compactionTarget,
      maximumRounds: maximumRounds)
    let underlyingProvider = try endpoint.makeChatProvider(
      authorization: authorization, maximumOutputTokens: configuration.reservedOutputTokens,
      reasoningEffort: reasoningEffort, sessionConfiguration: sessionConfiguration)

    guard images.isEmpty || underlyingProvider.supportsImageInput else {
      throw RemoteChatError.imageInputUnsupported
    }
    let pythonHome = try configureEmbeddedCommandEnvironment()
    let catalog = SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: Resources.resourceURL?.appendingPathComponent("Skills"),
        projectURL: projectURL, workspaceURL: directories.workspace))
    let template = SystemPromptTemplate.load(
      projectURL: projectURL, model: endpoint.model, template: remoteSystemPromptTemplate)
    let context = EnvironmentContext(
      model: endpoint.model, provider: provider.rawValue,
      pythonLibraryURL: pythonHome)
    let measuredProvider = MeasuredRemoteProvider(underlyingProvider)
    let bashUserInteraction = BashUserInteraction()
    let bridge = RemoteToolsBridge(
      projectPath: projectURL.path, workspacePath: directories.workspace.path,
      webSearchProvider: configuredWebSearchProvider,
      supportsImageInput: underlyingProvider.supportsImageInput)
    let agent = RemoteAgent(
      provider: measuredProvider,
      systemPrompt: remoteSystemPrompt(
        template: template, runtime: runtime, skillCatalog: catalog,
        projectContext: ProjectContext.load(projectURL: projectURL), environmentContext: context),
      tools: bridge.tools, configuration: configuration,
      state: restored?.state.agentState ?? RemoteAgentState()
    ) { call, progress, completion in
      bridge.execute(
        call, bashUserInteraction: bashUserInteraction, progress: progress, completion: completion)
    }

    let startedAt = Date()
    let interrupt = AgentCLIInterrupt { agent.cancel() }
    let tracer = options.trace ? RemoteAgentTrace() : nil
    let result = await withCheckedContinuation {
      (
        continuation: CheckedContinuation<
          Result<RemoteAgentCompletion, RemoteChatError>, Never
        >
      ) in
      agent.send(
        catalog.prompt(for: userMessage), images: images,
        progress: { progress in
          tracer?.consume(progress)
          if interrupt.signalNumber != nil { agent.cancel() }
        },
        completion: { continuation.resume(returning: $0) })
    }
    tracer?.finish()

    let finalText: String
    let runError: RemoteChatError?
    switch result {
    case .success(let completion):
      finalText = completion.text
      runError = nil
    case .failure(let error):
      finalText = ""
      runError = error
    }
    let requests = measuredProvider.records
    let state = agent.state
    try options.writeResult(
      RemoteAgentRunOutput(
        provider: provider.rawValue, model: endpoint.model,
        baseURL: endpoint.baseURL.absoluteString,
        project: projectURL.path, startedAt: startedAt,
        durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
        finalText: finalText, error: runError?.localizedDescription,
        requests: requests, state: state))
    if let signal = interrupt.signalNumber { throw ExitCode(128 + signal) }
    if let runError {
      throw runError
    }
    print(finalText)
  }

  func authorization(
    endpoint: RemoteProviderEndpoint,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    readCredential: (String, RemoteProvider) throws -> RemoteStoredCredential? =
      RemoteCredentialStore.readCredential
  ) throws -> any RemoteAuthorizationProviding {
    if noAuth {
      guard provider == .openAICompatible, apiKeyEnvironment == nil else {
        throw ValidationError(
          "--no-auth requires openai-compatible and cannot be combined with --api-key-environment.")
      }
      return RemoteUnauthenticatedAuthorization()
    }
    let environmentName = apiKeyEnvironment ?? provider.defaultAPIKeyEnvironment
    if provider != .openAI,
      // Do not send an ambient OpenAI credential to a user-configured third-party server.
      provider != .openAICompatible || RemoteProvider.isOpenAIAPIHost(endpoint.baseURL)
        || apiKeyEnvironment != nil,
      let apiKey = environment[environmentName]?
        .trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty
    {
      return RemoteAPIKeyAuthorization(apiKey: apiKey)
    }
    // An explicitly selected key variable must not silently switch accounts.
    if apiKeyEnvironment == nil,
      let credential = try readCredential(endpoint.baseURL.absoluteString, provider)
    {
      return RemoteCredentialAuthorizer(
        provider: provider, account: endpoint.baseURL.absoluteString, credential: credential)
    }
    if provider == .openAI {
      throw ValidationError("Run LocalCodeCLI auth login --provider openai to sign in.")
    }
    if provider == .openAICompatible {
      throw ValidationError(
        "Select the API key with --api-key-environment \(environmentName), run LocalCodeCLI auth login --provider openai-compatible, or use --no-auth for a server without authentication."
      )
    }
    throw ValidationError(
      "Set \(environmentName) to the remote provider API key or run LocalCodeCLI auth login --provider \(provider.rawValue)."
    )
  }

  private func modelLimits(
    endpoint: RemoteProviderEndpoint, authorization: any RemoteAuthorizationProviding,
    sessionConfiguration: URLSessionConfiguration
  ) async throws -> RemoteModelLimits {
    let client = RemoteModelMetadataClient(sessionConfiguration: sessionConfiguration)
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<RemoteModelLimits, Error>) in
      _ = client.fetch(
        endpoint: endpoint, authorization: authorization
      ) { result in
        switch result {
        case .success(let limits):
          continuation.resume(returning: limits)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

}

private struct RemoteAgentRunOutput: Encodable {
  var provider: String
  var model: String
  var baseURL: String
  var project: String
  var startedAt: Date
  var durationMilliseconds: Double
  var finalText: String
  var error: String?
  var requests: [MeasuredRemoteProvider.Record]
  var state: RemoteAgentState
}

private final class MeasuredRemoteProvider: RemoteChatProviding {
  struct Record: Encodable {
    var index: Int
    var durationMilliseconds: Double
    var usage: RemoteUsage?
    var error: String?
  }

  private let provider: RemoteChatProviding
  private let lock = NSLock()
  private var nextIndex = 0
  private var storedRecords = [Record]()

  init(_ provider: RemoteChatProviding) {
    self.provider = provider
  }

  var modelIdentity: RemoteModelIdentity { provider.modelIdentity }
  var supportsImageInput: Bool { provider.supportsImageInput }

  var records: [Record] {
    lock.lock()
    defer { lock.unlock() }
    return storedRecords.sorted { $0.index < $1.index }
  }

  func streamChat(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    lock.lock()
    let index = nextIndex
    nextIndex += 1
    lock.unlock()
    let startedAt = Date()
    return provider.streamChat(
      messages: messages, tools: tools, progress: progress
    ) { result in
      let record: Record
      switch result {
      case .success(let response):
        record = Record(
          index: index, durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
          usage: response.usage, error: nil)
      case .failure(let error):
        record = Record(
          index: index, durationMilliseconds: Date().timeIntervalSince(startedAt) * 1_000,
          usage: nil, error: error.localizedDescription)
      }
      self.lock.lock()
      self.storedRecords.append(record)
      self.lock.unlock()
      completion(result)
    }
  }
}

private final class RemoteAgentTrace {
  private let lock = NSLock()
  private var text = ""
  private var thinking = ""
  private var toolState = [String: Bool]()

  func consume(_ progress: RemoteAgentProgress) {
    lock.lock()
    defer { lock.unlock() }
    if progress.thinking != thinking {
      let addition: String
      if progress.thinking.isEmpty {
        addition = "\n"
      } else if !thinking.isEmpty, progress.thinking.hasPrefix(thinking) {
        addition = String(progress.thinking.dropFirst(thinking.count))
      } else {
        addition = "\n[thinking] \(progress.thinking)"
      }
      FileHandle.standardError.write(Data(addition.utf8))
      thinking = progress.thinking
    }
    if progress.text != text {
      let addition =
        progress.text.hasPrefix(text)
        ? String(progress.text.dropFirst(text.count))
        : "\n\(progress.text)"
      FileHandle.standardError.write(Data(addition.utf8))
      text = progress.text
    }
    for tool in progress.tools where toolState[tool.id] != tool.isCompleted {
      let marker = tool.isCompleted ? "completed" : "running"
      FileHandle.standardError.write(Data("\n[\(marker)] \(tool.subtitle)\n".utf8))
      toolState[tool.id] = tool.isCompleted
    }
  }

  func finish() {
    lock.lock()
    defer { lock.unlock() }
    if !text.isEmpty {
      FileHandle.standardError.write(Data("\n".utf8))
    }
  }
}

struct RemoteAgentResumeRecord: Decodable {
  struct State: Decodable {
    var transcript: [RemoteTranscriptEntry]
    var tokenPerByte: Double?
    var effectiveContextWindowTokens: Int?

    var agentState: RemoteAgentState {
      RemoteAgentState(
        transcript: transcript, tokenPerByte: tokenPerByte,
        effectiveContextWindowTokens: effectiveContextWindowTokens)
    }
  }
  var provider: String
  var model: String
  var baseURL: String
  var project: String
  var state: State
}
