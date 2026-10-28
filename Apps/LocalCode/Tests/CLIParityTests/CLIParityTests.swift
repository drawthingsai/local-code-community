import AVFoundation
import ArgumentParser
import Darwin
import Foundation
import ModelZoo
import NNC
import RemoteAPI
import XCTest
import ios_system

@testable import LocalCodeCLI

extension ToolResponse {
  fileprivate var text: String {
    content.compactMap { part -> String? in
      guard case .text(let text) = part else { return nil }
      return text
    }.joined(separator: "\n")
  }
}

final class CLIParityTests: XCTestCase {
  private var directory: URL!
  private var workingDirectory: String!

  override func setUpWithError() throws {
    workingDirectory = FileManager.default.currentDirectoryPath
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(workingDirectory))
    try FileManager.default.removeItem(at: directory)
  }

  func testDeepSeekReasoningEffortEncoding() {
    typealias V4 = DeepSeek4CodeAgent<DeepSeek4TextGenerator>.ReasoningEffort
    typealias V41 = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.ReasoningEffort
    for (effort, budget): (V41, Int) in [(.low, 50), (.high, 75), (.max, 100)] {
      let rendered = effort.emitSections([(systemPromptForDeepSeek4_1, true)]).map(\.text).joined()
      XCTAssertTrue(
        rendered.hasPrefix(
          "<｜begin▁of▁sentence｜><｜System｜>Reasoning Effort: \(budget) (range 1-100, the higher the value, the more thorough the reasoning)\n\nYou are"
        ))
      let nonThinking = effort.emitSections(
        [(systemPromptForDeepSeek4_1, true)], thinkingEnabled: false
      ).map(\.text).joined()
      XCTAssertTrue(nonThinking.hasPrefix("<｜begin▁of▁sentence｜><｜System｜>You are"))
      XCTAssertFalse(nonThinking.contains("Reasoning Effort:"))
    }
    XCTAssertEqual(V41(.low), .low)
    XCTAssertEqual(V41(.medium), .high)
    XCTAssertEqual(V4(.low), .high)
    XCTAssertFalse(
      V4.high.emitSections([(systemPromptForDeepSeek4, true)]).map(\.text).joined().contains(
        "Reasoning Effort:"))
    XCTAssertTrue(
      V4.max.emitSections([(systemPromptForDeepSeek4, true)]).map(\.text).joined().hasPrefix(
        "<｜begin▁of▁sentence｜>Reasoning Effort: Absolute maximum"))
  }

  func testDeepSeek41ThinkingModeAndEffortSurviveResume() throws {
    typealias Agent = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>
    let template = "<｜begin▁of▁sentence｜><｜System｜>{{REASONING_EFFORT}}SYSTEM"
    func makeAgent() -> Agent {
      Agent(
        textGenerator: DeepSeek4_1TextGenerator(
          filePath: "/missing/model", engramFilePath: "/missing/engram"),
        graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
        unsafeTokenizer: DeepSeek4_1TextGenerator.unsafeTokenizer,
        safeTokenizer: DeepSeek4_1TextGenerator.safeTokenizer, systemPromptTemplate: template)
    }
    let temporaryAgent = makeAgent()
    let originalContextSize = temporaryAgent.statistics.contextUsedTokens
    for budget: Int32 in [0, 1024] {
      temporaryAgent.thinkingBudget = budget
      temporaryAgent.reasoningEffort = .low
      let system = Agent.ReasoningEffort.low.emitSections(
        [(template, true)], thinkingEnabled: budget > 0
      ).map(\.text).joined()
      let expectedLength =
        DeepSeek4_1TextGenerator.unsafeTokenizer.tokenize(text: system, addSpecialTokens: false).0
        .count
        + DeepSeek4_1TextGenerator.safeTokenizer.tokenize(text: "Hello", addSpecialTokens: false).0
        .count + 3
      _ = temporaryAgent.ask(
        "Hello", isMemoryEnabled: false, temporary: true, threadId: -1, projectPath: directory.path
      ) { progress, _ in
        if case .prefill(_, _, let length) = progress { XCTAssertEqual(length, expectedLength) }
        return .abort
      }
      XCTAssertEqual(temporaryAgent.statistics.contextUsedTokens, originalContextSize)
    }
    for budget: Int32 in [0, 1024] {
      let agent = makeAgent()
      agent.thinkingBudget = budget
      agent.reasoningEffort = .low
      let system = Agent.ReasoningEffort.low.emitSections(
        [(template, true)], thinkingEnabled: budget > 0
      ).map(\.text).joined()
      let expectedLength =
        DeepSeek4_1TextGenerator.unsafeTokenizer.tokenize(text: system, addSpecialTokens: false).0
        .count
        + DeepSeek4_1TextGenerator.safeTokenizer.tokenize(text: "Hello", addSpecialTokens: false).0
        .count + 3
      let threadId = Int64(100 + budget)
      _ = agent.ask(
        "Hello", isMemoryEnabled: false, threadId: threadId, projectPath: directory.path
      ) { progress, _ in
        if case .prefill(_, _, let length) = progress { XCTAssertEqual(length, expectedLength) }
        return .pause
      }
      try agent.hibernate(threadId: threadId)
      let restored = makeAgent()
      XCTAssertTrue(try restored.restoreSuspension(threadId: threadId, projectPath: directory.path))
      _ = restored.resume { progress, _ in
        if case .prefill(_, _, let length) = progress { XCTAssertEqual(length, expectedLength) }
        return .abort
      }
    }
  }

  func testDeepSeekAgentsPauseHibernateAndRestoreBeforeLoading() throws {
    func check<Generator: DeepSeekTextGenerator>(_ generator: Generator, threadId: Int64) throws {
      let graph = DynamicGraph()
      let stream = StreamContext(.GPU(0))
      func makeAgent() -> DeepSeek4CodeAgent<Generator> {
        DeepSeek4CodeAgent(
          textGenerator: generator, graph: graph, streamContext: stream,
          unsafeTokenizer: Generator.unsafeTokenizer, safeTokenizer: Generator.safeTokenizer,
          systemPromptTemplate: "You are a helpful assistant.")
      }
      let agent = makeAgent()
      var callbacks = 0
      _ = agent.ask(
        "Hello", isMemoryEnabled: false, threadId: threadId, projectPath: directory.path
      ) {
        progress, _ in
        if case .prefill = progress { callbacks += 1 }
        return .pause
      }
      XCTAssertEqual(callbacks, 1)
      XCTAssertNotNil(agent.suspendedResult)
      try agent.hibernate(threadId: threadId)
      let restored = makeAgent()
      XCTAssertTrue(try restored.restoreSuspension(threadId: threadId, projectPath: directory.path))
      XCTAssertNotNil(restored.suspendedResult)
      callbacks = 0
      _ = restored.resume { progress, _ in
        if case .prefill = progress { callbacks += 1 }
        return .abort
      }
      XCTAssertEqual(callbacks, 1)
      XCTAssertNil(restored.suspendedResult)
    }
    try check(
      DeepSeek4TextGenerator(filePath: "/missing/deepseek4.ckpt", chunkedPrefillMaxLength: 512),
      threadId: 40)
    try check(
      DeepSeek4_1TextGenerator(
        filePath: "/missing/deepseek4_1.ckpt", engramFilePath: "/missing/deepseek4_1.engram"),
      threadId: 41)
  }

  func testDeepSeek41VersionAndStreamingSelection() throws {
    let specification = try XCTUnwrap(
      LLMZoo.builtinSpecifications.first { $0.version == .deepseek_4_1_flash })
    XCTAssertNotNil(specification.engram)
    let command = try XCTUnwrap(
      LocalCodeCLI.parseAsRoot([
        "local-agent", "--model", specification.file, "--message", "hello", "--weights-streaming",
        "16",
      ]) as? LocalAgentCLI)
    XCTAssertEqual(try command.specification().version, .deepseek_4_1_flash)
  }

  func testEveryAppModelCanBeSelectedByFileAndName() throws {
    for model in LLMZoo.builtinSpecifications {
      for identifier in [model.file, model.name] {
        let command = try XCTUnwrap(
          LocalCodeCLI.parseAsRoot([
            "local-agent", "--model", identifier, "--message", "hello",
            "--reasoning-effort", "max", "--thinking-budget", "0", "--no-deterministic",
          ]) as? LocalAgentCLI)
        XCTAssertEqual(try command.specification().file, model.file)
        XCTAssertFalse(command.deterministic)
        XCTAssertEqual(command.reasoningEffort, .max)
      }
    }
  }

  func testAuthCommandValidation() throws {
    for provider in ["anthropic", "openai"] {
      let login = try XCTUnwrap(
        LocalCodeCLI.parseAsRoot([
          "auth", "login", "--provider", provider, "--no-browser",
        ]) as? AuthLoginCLI)
      XCTAssertFalse(login.browser)
    }
    for arguments in [
      ["--provider", "openrouter"],
      ["--provider", "openai-compatible"],
      ["--provider", "anthropic", "--base-url", "https://example.com"],
      ["--provider", "anthropic", "--base-url", "http://api.anthropic.com/v1"],
      ["--provider", "openai", "--base-url", "https://api.openai.com/other"],
    ] {
      XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(["auth", "login"] + arguments))
    }
  }

  func testAnthropicLoginExchangesLoopbackCallback() async throws {
    let authorization = try RemoteOAuth.anthropicAuthorization()
    XCTAssertNotEqual(authorization.state, authorization.verifier)
    CLIURLProtocol.handler = { request in
      XCTAssertEqual(request.url?.host, "platform.claude.com")
      return #"{"access_token":"login-access","refresh_token":"login-refresh","expires_in":3600}"#
    }
    defer { CLIURLProtocol.handler = nil }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CLIURLProtocol.self]
    let command = try AuthLoginCLI.parse(["--provider", "anthropic"])
    let credential = try await command.authorize(
      session: URLSession(configuration: configuration), timeout: 10,
      openBrowser: { url in
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let state = items.first { $0.name == "state" }!.value!
        let redirect = items.first { $0.name == "redirect_uri" }!.value!
        var callback = URLComponents(string: redirect)!
        callback.host = "127.0.0.1"
        callback.queryItems = [
          URLQueryItem(name: "state", value: state),
          URLQueryItem(name: "code", value: "fixture-code"),
        ]
        do {
          let (_, response) = try await URLSession.shared.data(from: callback.url!)
          XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } catch {
          XCTFail("Loopback callback failed: \(error)")
        }
      })
    XCTAssertEqual(credential.accessToken, "login-access")
    XCTAssertEqual(credential.refreshToken, "login-refresh")
    XCTAssertGreaterThan(credential.expiresAt.timeIntervalSinceNow, 3_500)
  }

  func testAnthropicLoginTimesOutWhileWaitingForUser() async throws {
    let command = try AuthLoginCLI.parse(["--provider", "anthropic", "--no-browser"])
    do {
      _ = try await command.authorize(timeout: 0.1)
      XCTFail("Login should time out without a callback")
    } catch {
      XCTAssertEqual(error as? RemoteOAuthError, .timedOut)
    }
  }

  func testAnthropicLoginRejectsWrongCallbackState() async throws {
    let command = try AuthLoginCLI.parse(["--provider", "anthropic"])
    do {
      _ = try await command.authorize(
        timeout: 10,
        openBrowser: { _ in
          let url = URL(string: "http://127.0.0.1:53692/callback?code=fixture&state=wrong")!
          do {
            let (_, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 400)
          } catch { XCTFail("Loopback request failed: \(error)") }
        })
      XCTFail("A callback with the wrong state must fail before token exchange")
    } catch {
      XCTAssertEqual(error as? RemoteOAuthError, .invalidAuthorizationResponse)
    }
  }

  func testSavedCredentialsSelectionRefreshAndLogout() async throws {
    _ = try configureEmbeddedCommandEnvironment()
    let bridge = RemoteToolsBridge(
      projectPath: directory.path, workspacePath: directory.path, webSearchProvider: .disabled)
    let toolResult: RemoteToolExecutionResult = await withCheckedContinuation { continuation in
      _ = bridge.execute(
        RemoteToolCall(
          id: "auth-shell", name: "bash",
          arguments: #"{"command":"python3 -c 'print(\"AUTH_SHELL_OK\")'","refresh_sec":5}"#),
        bashUserInteraction: .init(), progress: { _ in }
      ) { continuation.resume(returning: $0) }
    }
    XCTAssertFalse(toolResult.isError)
    XCTAssertTrue(toolResult.content.contains("AUTH_SHELL_OK"), toolResult.content)
    let account = "https://cli-auth-\(UUID().uuidString.lowercased()).invalid/v1"
    let endpoint = try RemoteProviderEndpoint(
      provider: .anthropic, baseURL: URL(string: account), model: "test")
    let keyVariable = "LOCAL_CODE_CLI_AUTH_TEST_KEY"
    let oldKey = ProcessInfo.processInfo.environment[keyVariable]
    let oldDefaultKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    unsetenv("ANTHROPIC_API_KEY")
    unsetenv(keyVariable)
    defer {
      try? RemoteCredentialStore.delete(account: account, provider: .anthropic)
      CLIURLProtocol.handler = nil
      if let oldKey { setenv(keyVariable, oldKey, 1) } else { unsetenv(keyVariable) }
      if let oldDefaultKey { setenv("ANTHROPIC_API_KEY", oldDefaultKey, 1) }
    }
    var command = try RemoteAgentCLI.parse([
      "--provider", "anthropic", "--base-url", account, "--model", "test", "--message", "hello",
    ])
    XCTAssertThrowsError(try command.authorization(endpoint: endpoint))
    try RemoteCredentialStore.upsertAPIKey("saved-key", account: account, provider: .anthropic)
    let saved = try await command.authorization(endpoint: endpoint).authorization()
    XCTAssertEqual(saved.token, "saved-key")
    command.apiKeyEnvironment = keyVariable
    XCTAssertThrowsError(try command.authorization(endpoint: endpoint))
    setenv(keyVariable, "environment-key", 1)
    let overridden = try await command.authorization(endpoint: endpoint).authorization()
    XCTAssertEqual(overridden.token, "environment-key")

    let expired = try JSONDecoder().decode(
      RemoteOAuthCredential.self,
      from: Data(
        #"{"accessToken":"expired","refreshToken":"refresh","expiresAt":0}"#.utf8))
    try RemoteCredentialStore.upsertOAuth(expired, account: account, provider: .anthropic)
    let record = try XCTUnwrap(
      RemoteCredentialStore.readCredential(account: account, provider: .anthropic))
    var refreshes = 0
    CLIURLProtocol.handler = { request in
      refreshes += 1
      XCTAssertEqual(request.url?.host, "platform.claude.com")
      return #"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600}"#
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CLIURLProtocol.self]
    let authorizer = RemoteCredentialAuthorizer(
      provider: .anthropic, account: account, credential: record,
      session: URLSession(configuration: configuration))
    let renewed = try await authorizer.authorization()
    XCTAssertEqual(renewed.kind, .oauth)
    XCTAssertEqual(renewed.token, "renewed")
    _ = try await authorizer.authorization()
    XCTAssertEqual(refreshes, 1)
    let refreshed = try XCTUnwrap(
      RemoteCredentialStore.readCredential(account: account, provider: .anthropic))
    XCTAssertEqual(refreshed.identifier, record.identifier)
    guard case .oauth(let oauth) = refreshed.value else { return XCTFail("Expected OAuth") }
    XCTAssertEqual(oauth.refreshToken, "rotated")
    var logout = try AuthLogoutCLI.parse(["--provider", "anthropic", "--base-url", account])
    try logout.run()
    XCTAssertNil(try RemoteCredentialStore.readCredential(account: account, provider: .anthropic))
    do {
      _ = try await authorizer.authorization()
      XCTFail("A signed-out credential must not authorize another request")
    } catch {}
  }

  func testCompatibleAuthenticationRequiresExplicitCustomServerCredentials() async throws {
    let account = "https://cli-auth-\(UUID().uuidString.lowercased()).invalid/v1"
    let endpoint = try RemoteProviderEndpoint(
      provider: .openAICompatible, baseURL: URL(string: account), model: "test")
    let environment = ["OPENAI_API_KEY": "ambient-openai-secret"]

    var command = try RemoteAgentCLI.parse([
      "--provider", "openai-compatible", "--base-url", account, "--model", "test", "--message",
      "hello",
    ])
    XCTAssertThrowsError(
      try command.authorization(
        endpoint: endpoint, environment: environment, readCredential: { _, _ in nil }))
    command.noAuth = true
    let anonymous = try await command.authorization(
      endpoint: endpoint, environment: environment, readCredential: { _, _ in nil }
    ).authorization()
    XCTAssertEqual(anonymous.kind, .unauthenticated)
    XCTAssertEqual(anonymous.token, "")
    command.noAuth = false
    command.apiKeyEnvironment = "OPENAI_API_KEY"
    let explicit = try await command.authorization(
      endpoint: endpoint, environment: environment, readCredential: { _, _ in nil }
    ).authorization()
    XCTAssertEqual(explicit.token, "ambient-openai-secret")
    command.noAuth = true
    XCTAssertThrowsError(
      try command.authorization(
        endpoint: endpoint, environment: environment, readCredential: { _, _ in nil }))
    command.noAuth = false
    command.apiKeyEnvironment = nil
    let official = try RemoteProviderEndpoint(provider: .openAICompatible, model: "test")
    let ambient = try await command.authorization(
      endpoint: official, environment: environment, readCredential: { _, _ in nil }
    ).authorization()
    XCTAssertEqual(ambient.token, "ambient-openai-secret")
  }

  func testLocalSubcommandReceivesOptionsAlsoUsedByBenchmarks() throws {
    let command = try XCTUnwrap(
      LocalCodeCLI.parseAsRoot([
        "local-agent", "--model", "qwen_3.8_27b_i4x.ckpt", "--message", "hello",
        "--model-store", "/missing/checkpoint.ckpt", "--queue-watermark", "7",
        "--trace", "--disable-mfa-apple-neural-engine",
      ]) as? LocalAgentCLI)
    XCTAssertEqual(command.modelStore, "/missing/checkpoint.ckpt")
    XCTAssertEqual(command.queueWatermark, 7)
    XCTAssertTrue(command.options.trace)
    XCTAssertTrue(command.disableMFAAppleNeuralEngine)
  }

  func testTokenBudgetAccumulatesModelRoundsAndCompaction() {
    var counter = LocalAgentTokenCounter()
    var result = CodeAgentResult.empty
    result.thinkTokens = Array(repeating: 1, count: 12)
    counter.update(.generate(result))
    result.outputTokens = Array(repeating: 1, count: 8)
    counter.update(.generate(result))
    counter.update(.toolsWait(result))
    counter.update(.prefill([], 0, 10))
    counter.update(.prefill([], 5, 10))
    XCTAssertEqual(counter.count, 20)
    result.thinkTokens = []
    result.outputTokens = Array(repeating: 1, count: 7)
    counter.update(.generate(result))
    counter.update(.compact([], 0, 100))
    counter.update(.compact([], 3, 0))
    XCTAssertEqual(counter.count, 30)
  }

  func testPromptAndNumericValidationHappensBeforeLoadingModels() {
    let local = ["local-agent", "--model", "qwen_3.8_27b_i4x.ckpt"]
    for arguments in [
      [], ["--message", "a", "--prompt-file", "b"],
      ["--message", "a", "--thinking-budget", "-1"],
      ["--message", "a", "--maximum-generated-tokens", "0"],
      ["--message", "a", "--chunked-prefill-max-length", "1"],
      ["--message", "a", "--weights-streaming", "8"],
    ] {
      XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(local + arguments))
    }
    let remote = ["remote-agent", "--provider", "anthropic", "--model", "test"]
    XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(remote))
    XCTAssertThrowsError(
      try LocalCodeCLI.parseAsRoot(remote + ["--message", "a", "--compaction-target", "nan"]))
    let command = try? LocalCodeCLI.parseAsRoot(
      remote + ["--message", "a", "--reasoning-effort", "max"])
    XCTAssertEqual((command as? RemoteAgentCLI)?.reasoningEffort, .max)
    XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(["--prefill-token-count", "0"]))
    XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(["--ttft-tokens", "-1"]))
  }

  func testPromptFilesAndWorkspaceBoundaries() throws {
    let prompt = directory.appendingPathComponent("prompt.txt")
    try "café 👋".write(to: prompt, atomically: true, encoding: .utf8)
    let project = directory.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    var options = try AgentCLIOptions.parse([
      "--project", project.path, "--workspace", directory.path, "--prompt-file", prompt.path,
    ])
    XCTAssertEqual(try options.readPrompt(), "café 👋")
    XCTAssertEqual(try options.directories().workspace, directory.resolvingSymlinksInPath())
    options.workspace = project.appendingPathComponent("nested").path
    try FileManager.default.createDirectory(
      atPath: options.workspace!, withIntermediateDirectories: true)
    XCTAssertThrowsError(try options.directories())
    try " \n".write(to: prompt, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try options.readPrompt())
  }

  func testRemoteResumePreservesToolResultsAndProviderReasoning() throws {
    struct Record: Encodable {
      var provider = "anthropic"
      var model = "test"
      var baseURL = "https://api.anthropic.com"
      var project: String
      var state: RemoteAgentState
    }
    let state = RemoteAgentState(
      transcript: [
        .user("Read the file"),
        .assistant(
          nil, thinking: RemoteThinking(text: "plan", signature: "signature"),
          toolCalls: [RemoteToolCall(id: "1", name: "read", arguments: #"{"path":"a"}"#)]),
        .toolResult("file contents", toolCallID: "1", toolName: "read", isError: false),
        .assistant("Done"),
      ], tokenPerByte: 0.4, effectiveContextWindowTokens: 8_192)
    var options = AgentCLIOptions()
    let output = directory.appendingPathComponent("nested/result.json")
    options.resultJSON = output.path
    try options.writeResult(Record(project: directory.path, state: state))
    let decoded = try JSONDecoder().decode(
      RemoteAgentResumeRecord.self, from: Data(contentsOf: output))
    XCTAssertEqual(decoded.state.agentState, state)
  }

  func testLocalResumeRejectsOtherProjectBeforeInference() throws {
    let checkpoint = directory.appendingPathComponent("empty.ckpt")
    try Data().write(to: checkpoint)
    let record = directory.appendingPathComponent("resume.json")
    let data = try JSONSerialization.data(withJSONObject: [
      "model": "qwen_3.8_27b_i4x.ckpt", "project": "/different-project", "prefixTokens": [1, 2, 3],
    ])
    try data.write(to: record)
    var command = try LocalAgentCLI.parse([
      "--model", "qwen_3.8_27b_i4x.ckpt", "--model-store", checkpoint.path,
      "--project", directory.path, "--message", "hello", "--resume", record.path,
    ])
    XCTAssertThrowsError(try command.run()) { error in
      XCTAssertTrue(String(describing: error).contains("different model or project"))
    }
  }

  func testRemoteImageReadUsesPermittedPathsAndImmutableBytes() async throws {
    let imageData = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9S8AAAAASUVORK5CYII="
      ))
    let file = directory.appendingPathComponent("fixture.png")
    try imageData.write(to: file)
    let bridge = RemoteToolsBridge(
      projectPath: directory.path, workspacePath: directory.path, webSearchProvider: .disabled,
      supportsImageInput: true)
    XCTAssertTrue(
      bridge.tools.first { $0.name == "read" }?.description.contains("visual inspection") == true)
    let plainBridge = RemoteToolsBridge(
      projectPath: directory.path, workspacePath: directory.path, webSearchProvider: .disabled)
    XCTAssertFalse(
      plainBridge.tools.first { $0.name == "read" }?.description.contains("visual inspection")
        == true)
    func read(_ path: String) async -> RemoteToolExecutionResult {
      let arguments = String(
        decoding: try! JSONSerialization.data(withJSONObject: ["path": path]), as: UTF8.self)
      return await withCheckedContinuation { continuation in
        _ = bridge.execute(
          .init(id: "image", name: "read", arguments: arguments), bashUserInteraction: .init(),
          progress: { _ in }
        ) {
          continuation.resume(returning: $0)
        }
      }
    }
    let result = await read("fixture.png")
    XCTAssertFalse(result.isError, result.content)
    XCTAssertEqual(result.images.first?.data, imageData)
    try Data("changed".utf8).write(to: file)
    XCTAssertEqual(result.images.first?.data, imageData)
    let invalid = await read("fixture.png")
    XCTAssertTrue(invalid.isError)
    XCTAssertTrue(invalid.images.isEmpty)
    let outside = directory.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: outside) }
    try imageData.write(to: outside)
    let link = directory.appendingPathComponent("escape.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    for path in [outside.path, "escape.png"] {
      let denied = await read(path)
      XCTAssertTrue(denied.isError, denied.content)
      XCTAssertTrue(denied.images.isEmpty)
    }
  }

  func testRemoteViewSendsPDFPagesOnlyToProvidersWithImageInput() async throws {
    let file = directory.appendingPathComponent("pages.pdf")
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try XCTUnwrap(CGContext(file as CFURL, mediaBox: &mediaBox, nil))
    for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(gray: 0, alpha: 1)] {
      context.beginPDFPage(nil)
      context.setFillColor(color)
      context.fill(mediaBox)
      context.endPDFPage()
    }
    context.closePDF()
    func view(_ bridge: RemoteToolsBridge) async -> RemoteToolExecutionResult {
      await withCheckedContinuation { continuation in
        _ = bridge.execute(
          .init(id: "view", name: "view", arguments: #"{"path":"pages.pdf","pages":2}"#),
          bashUserInteraction: .init(), progress: { _ in }
        ) {
          continuation.resume(returning: $0)
        }
      }
    }
    let bridge = RemoteToolsBridge(
      projectPath: directory.path, workspacePath: directory.path, webSearchProvider: .disabled,
      supportsImageInput: true)
    XCTAssertTrue(bridge.tools.contains { $0.name == "view" })
    let result = await view(bridge)
    XCTAssertFalse(result.isError, result.content)
    XCTAssertTrue(result.content.contains("Page 2 from pages.pdf"), result.content)
    // Pages render at up to 2,048 pixels and are resized as attachments are.
    XCTAssertEqual(result.images.map { [$0.width, $0.height] }, [[791, 1_024], [791, 1_024]])

    let plainBridge = RemoteToolsBridge(
      projectPath: directory.path, workspacePath: directory.path, webSearchProvider: .disabled)
    XCTAssertFalse(plainBridge.tools.contains { $0.name == "view" })
    let refused = await view(plainBridge)
    XCTAssertTrue(refused.isError)
    XCTAssertTrue(refused.images.isEmpty)
  }

  func testOpenRouterImagesSurviveToolLoopAndCLIResume() async throws {
    let environmentName = "LOCAL_CODE_CLI_IMAGE_TEST_KEY"
    setenv(environmentName, "fixture-key", 1)
    defer {
      unsetenv(environmentName)
      CLIURLProtocol.handler = nil
    }
    let imageData = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9S8AAAAASUVORK5CYII="
      ))
    let file = directory.appendingPathComponent("fixture.png")
    try imageData.write(to: file)
    var requests = 0
    CLIURLProtocol.handler = { request in
      requests += 1
      let stream = try XCTUnwrap(request.httpBodyStream)
      stream.open()
      defer { stream.close() }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        bytes.append(contentsOf: buffer.prefix(count))
      }
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      let images = messages.flatMap { ($0["content"] as? [[String: Any]] ?? []) }.filter {
        $0["type"] as? String == "image_url"
      }
      XCTAssertEqual(images.count, requests == 1 ? 2 : 3)
      for image in images {
        XCTAssertEqual(
          (image["image_url"] as? [String: Any])?["url"] as? String,
          "data:image/png;base64," + imageData.base64EncodedString())
      }
      if requests == 1 {
        return
          "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"read1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"{\\\"path\\\":\\\"fixture.png\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}\n\ndata: [DONE]\n\n"
      }
      XCTAssertTrue(messages.contains { $0["tool_call_id"] as? String == "read1" })
      return
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Image observed\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    }
    let record = directory.appendingPathComponent("images.json")
    var command = try RemoteAgentCLI.parse([
      "--provider", "openrouter", "--model", "vision-test", "--api-key-environment",
      environmentName,
      "--context-window-tokens", "32768", "--maximum-output-tokens", "1024",
      "--project", directory.path, "--message", "Read fixture.png", "--result-json", record.path,
      "--image", file.path, "--image", file.path,
    ])
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [CLIURLProtocol.self]
    try await command.run(sessionConfiguration: session)
    try FileManager.default.removeItem(at: file)
    command.image = []
    command.options.resume = record.path
    command.options.message = "Inspect the original images again"
    try await command.run(sessionConfiguration: session)
    XCTAssertEqual(requests, 3)
    let restored = try JSONDecoder().decode(
      RemoteAgentResumeRecord.self, from: Data(contentsOf: record))
    XCTAssertEqual(
      restored.state.transcript.flatMap(\.images).map(\.data), [imageData, imageData, imageData])
  }

  func testRemoteCommandExecutesToolsAndResumesItsSavedConversation() async throws {
    let environmentName = "LOCAL_CODE_CLI_TEST_KEY"
    let previousKey = ProcessInfo.processInfo.environment[environmentName]
    setenv(environmentName, "test-key", 1)
    defer {
      CLIURLProtocol.handler = nil
      if let previousKey {
        setenv(environmentName, previousKey, 1)
      } else {
        unsetenv(environmentName)
      }
    }
    var requests = 0
    CLIURLProtocol.handler = { request in
      requests += 1
      let stream = try XCTUnwrap(request.httpBodyStream)
      stream.open()
      defer { stream.close() }
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 4_096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        bytes.append(contentsOf: buffer.prefix(count))
      }
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      XCTAssertEqual(body["reasoning_effort"] as? String, "high")
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      let system = try XCTUnwrap(messages.first?["content"] as? String)
      XCTAssertTrue(system.contains("available_skills"))
      XCTAssertTrue(system.contains("Python Packages:"))
      if requests == 1 {
        let call: [String: Any] = [
          "choices": [
            [
              "index": 0,
              "delta": [
                "tool_calls": [
                  [
                    "index": 0, "id": "write-1", "type": "function",
                    "function": [
                      "name": "write",
                      "arguments": #"{"path":"parity.txt","content":"CLI_PARITY_OK"}"#,
                    ],
                  ]
                ]
              ], "finish_reason": "tool_calls",
            ]
          ]
        ]
        return "data: "
          + String(decoding: try JSONSerialization.data(withJSONObject: call), as: UTF8.self)
          + "\n\ndata: [DONE]\n\n"
      }
      XCTAssertTrue(messages.contains { $0["role"] as? String == "tool" })
      if requests == 3 {
        XCTAssertTrue(messages.contains { $0["content"] as? String == "Saved parity.txt" })
        XCTAssertEqual(messages.last?["content"] as? String, "Continue from the saved conversation")
      }
      return
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Saved parity.txt\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    }
    let record = directory.appendingPathComponent("run.json")
    var command = try RemoteAgentCLI.parse([
      "--provider", "openai-compatible", "--base-url", "https://cli-parity.invalid/v1",
      "--model", "test-model", "--api-key-environment", environmentName,
      "--context-window-tokens", "32768", "--maximum-output-tokens", "1024",
      "--project", directory.path, "--message", "Write the test file", "--result-json", record.path,
    ])
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [CLIURLProtocol.self]
    try await command.run(sessionConfiguration: session)
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("parity.txt"), encoding: .utf8),
      "CLI_PARITY_OK")
    command.options.resume = record.path
    command.options.message = "Continue from the saved conversation"
    try await command.run(sessionConfiguration: session)
    XCTAssertEqual(requests, 3)
    let restored = try JSONDecoder().decode(
      RemoteAgentResumeRecord.self, from: Data(contentsOf: record))
    XCTAssertEqual(restored.state.transcript.filter { $0.role == .user }.count, 2)
  }

  func testBundledSkillsResolveThroughTheAgentFileNamespace() throws {
    let resources = try XCTUnwrap(Resources.resourceURL)
    let catalog = SkillCatalog.find(
      roots: SkillCatalog.roots(
        builtInSkillsURL: resources.appendingPathComponent("Skills"),
        projectURL: directory, workspaceURL: directory))
    XCTAssertFalse(catalog.entries.isEmpty)
    let resolver = LocalPathResolver(projectPath: directory.path, workspacePath: directory.path)
    for entry in catalog.entries {
      let resolution = try XCTUnwrap(resolver.resolve(entry.modelPath))
      XCTAssertEqual(resolution.url, entry.fileURL)
      XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.url.path))
    }
  }

  func testEmbeddedPythonNodeAndNpmThroughTheActualBashTool() throws {
    _ = try configureEmbeddedCommandEnvironment()
    let request = ToolCall.Request(
      function: "bash",
      parameters: [
        "refresh_sec": .init(string: false, value: "20"),
        "timeout_sec": .init(string: false, value: "20"),
        "command": .init(
          string: true,
          value:
            "python3 -c 'import json; print(json.dumps({\"python_ok\": True}))' && node -e 'console.log(\"node_ok\")' && npm --version"
        ),
      ])
    let invocation = try XCTUnwrap(
      ToolsRegistry.parse(request, projectPath: directory.path, workspacePath: directory.path))
    let completed = expectation(description: "embedded commands")
    invocation.invoke { response in
      defer { completed.fulfill() }
      XCTAssertEqual(response.content.count, 1)
      guard case .text(let output)? = response.content.first else {
        return XCTFail("Expected a text response")
      }
      XCTAssertTrue(output.contains("python_ok"), output)
      XCTAssertTrue(output.contains("node_ok"), output)
      XCTAssertTrue(output.contains("11.19.1"), output)
    }
    wait(for: [completed], timeout: 30)
  }

  func testOfficeResourcesThroughTheActualBashTool() throws {
    _ = try configureEmbeddedCommandEnvironment()
    let request = ToolCall.Request(
      function: "bash",
      parameters: [
        "refresh_sec": .init(string: false, value: "30"),
        "timeout_sec": .init(string: false, value: "30"),
        "command": .init(
          string: true,
          value:
            #"python3 -c 'from docx import Document; d=Document(); d.add_paragraph("Office CLI resources"); d.save("input.docx")' && office convert --input input.docx --output output.pdf && office convert --input input.docx --output output.odt && office render --input input.docx --output-dir pages"#
        ),
      ])
    let invocation = try XCTUnwrap(
      ToolsRegistry.parse(request, projectPath: directory.path, workspacePath: directory.path))
    let completed = expectation(description: "Office CLI conversions")
    invocation.invoke { response in
      defer { completed.fulfill() }
      guard case .text(let output)? = response.content.first else {
        return XCTFail("Expected a text response")
      }
      XCTAssertTrue(output.contains(#""ok":true"#), output)
      XCTAssertTrue(output.contains("pages/page-0001.png"), output)
      XCTAssertFalse(output.contains(self.directory.path), output)
    }
    wait(for: [completed], timeout: 40)
    let png = try Data(contentsOf: directory.appendingPathComponent("pages/page-0001.png"))
    XCTAssertEqual(png.prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
    let pdf = try Data(contentsOf: directory.appendingPathComponent("output.pdf"))
    XCTAssertEqual(pdf.prefix(5), Data("%PDF-".utf8))
    let odt = try Data(contentsOf: directory.appendingPathComponent("output.odt"))
    XCTAssertEqual(odt.prefix(4), Data([0x50, 0x4b, 0x03, 0x04]))
  }

  func testOfficeSkillCheckerThroughTheActualBashTool() throws {
    _ = try configureEmbeddedCommandEnvironment()
    let outputs = directory.appendingPathComponent("outputs", isDirectory: true)
    try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
    let resolver = LocalPathResolver(projectPath: directory.path, workspacePath: directory.path)
    for script in ["check_office.py", "verify_workbook.py"] {
      let checker = try XCTUnwrap(
        resolver.resolve("/app_bundle/Skills/office/scripts/\(script)"))
      try FileManager.default.copyItem(at: checker.url, to: outputs.appendingPathComponent(script))
    }
    try """
    from docx import Document
    from pptx import Presentation
    from openpyxl import Workbook, load_workbook
    from openpyxl.chart import BarChart, Reference
    from openpyxl.worksheet.table import Table
    import json
    import pandas as pd
    import sys

    if len(sys.argv) > 1:
        assert load_workbook("outputs/calculated.xlsx", data_only=True)["Summary"]["B4"].value == 30
        assert load_workbook("outputs/calculated.xlsx", data_only=False)["Summary"]["B4"].value == "=SUM(B2:B3)"
        with open("outputs/workbook-details.json") as stream:
            report = json.load(stream)
        assert report["ok"] and report["formula_count"] == 1
        assert report["representative_cells"][0]["formula_or_value"] == "=SUM(B2:B3)"
        assert report["sheets"][0]["freeze_panes"] == "A2"
        assert report["sheets"][0]["tables"][0]["ref"] == "A1:B3"
        assert report["sheets"][0]["charts"][0]["series_references"] == ["'Summary'!$A$2:$A$3", "'Summary'!$B$2:$B$3"]
        print("OFFICE_SKILL_OK")
    else:
        document = Document()
        document.add_paragraph("Office skill fixture")
        document.save("outputs/report.docx")
        presentation = Presentation()
        slide = presentation.slides.add_slide(presentation.slide_layouts[0])
        slide.shapes.title.text = "Office skill fixture"
        presentation.save("outputs/report.pptx")
        workbook = Workbook()
        sheet = workbook.active
        sheet.title = "Summary"
        sheet.append(["Quarter", "Revenue"])
        for row in pd.DataFrame({"Quarter": ["Q1", "Q2"], "Revenue": [12, 18]}).itertuples(index=False, name=None):
            sheet.append(row)
        sheet.append(["Total", "=SUM(B2:B3)"])
        sheet.freeze_panes = "A2"
        sheet.add_table(Table(displayName="Revenue", ref="A1:B3"))
        chart = BarChart()
        chart.add_data(Reference(sheet, min_col=2, min_row=2, max_row=3))
        chart.set_categories(Reference(sheet, min_col=1, min_row=2, max_row=3))
        sheet.add_chart(chart, "D2")
        workbook.save("outputs/report.xlsx")
    """.write(to: outputs.appendingPathComponent("fixture.py"), atomically: true, encoding: .utf8)
    let commands = [
      "python3 outputs/fixture.py",
      "python3 outputs/check_office.py outputs/report.docx --contains 'Office skill fixture' --out outputs/docx.json",
      "python3 outputs/check_office.py outputs/report.pptx --contains 'Office skill fixture' --count 1 --out outputs/pptx.json",
      "python3 outputs/check_office.py outputs/report.xlsx --contains Summary --count 1 --out outputs/xlsx.json",
      "python3 outputs/verify_workbook.py --project-root . outputs/report.xlsx --expect-sheet Summary --cell 'Summary!B4' > outputs/workbook-details.json",
      "office render --input outputs/report.pptx --output-dir outputs/slides --pages 1 --dpi 144",
      "office render --input outputs/report.xlsx --output-dir outputs/cells --sheet Summary --range A1:B4 --dpi 144",
      "office recalculate --input outputs/report.xlsx --output outputs/calculated.xlsx",
      "python3 outputs/fixture.py verify",
    ]
    let request = ToolCall.Request(
      function: "bash",
      parameters: [
        "refresh_sec": .init(string: false, value: "30"),
        "timeout_sec": .init(string: false, value: "30"),
        "command": .init(string: true, value: commands.joined(separator: " && ")),
      ])
    let invocation = try XCTUnwrap(
      ToolsRegistry.parse(request, projectPath: directory.path, workspacePath: directory.path))
    let completed = expectation(description: "Office skill checker and native operations")
    invocation.invoke { response in
      defer { completed.fulfill() }
      guard case .text(let output)? = response.content.first else {
        return XCTFail("Expected a text response")
      }
      XCTAssertTrue(output.contains("OFFICE_SKILL_OK"), output)
    }
    wait(for: [completed], timeout: 40)
    for format in ["docx", "pptx", "xlsx"] {
      let data = try Data(contentsOf: outputs.appendingPathComponent("\(format).json"))
      let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(report["verdict"] as? String, "pass")
      XCTAssertEqual(report["format"] as? String, format)
    }
  }

  func testHyperFramesSharesNodeIsolationPolicy() throws {
    _ = try configureEmbeddedCommandEnvironment()
    for command in ["node", "npm", "npx", "hyperframes", "/usr/bin/hyperframes"] {
      XCTAssertEqual(
        command.withCString { ios_commandIsExclusiveOrThreadSafe($0) },
        IOS_COMMAND_ISOLATION_EXCLUSIVE_NODE, command)
    }
  }

  func testHyperFramesThroughBashTool() throws {
    _ = try configureEmbeddedCommandEnvironment()
    let completed = expectation(
      description: "HyperFrames scaffold, lint, and capture through the embedded shell")
    let tool = BashTool(
      command:
        "hyperframes init ~/movie --non-interactive && hyperframes lint ~/movie --json && hyperframes snapshot ~/movie --at 1 --zoom '0,0,64,64' --zoom-scale 2",
      timeout: 30, refresh: 30, projectPath: directory.path, workspacePath: directory.path)
    tool.invoke { response in
      let output = response.text
      XCTAssertTrue(output.contains("\"ok\": true"), output)
      XCTAssertTrue(output.contains("contact-sheet.png"), output)
      completed.fulfill()
    }
    wait(for: [completed], timeout: 40)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          directory.appendingPathComponent("movie/snapshots/frame-00-at-1.000s.png").path))
  }

  func testHyperFramesPreviewStreamsThroughShell() throws {
    _ = try configureEmbeddedCommandEnvironment()
    try """
    <!doctype html><div data-composition-id="root" data-width="64" data-height="64"
    data-duration="1">Preview is alive</div>
    """.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    for command in [
      "cd . && hyperframes preview --foreground --no-open --json 2>&1 | tee preview.log",
      "hyperframes preview --foreground --no-open --json 2>&1 | tee preview.log | tee mirror.log",
      "if true; then hyperframes preview --foreground --no-open --json > preview.log 2>&1; fi",
    ] {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("preview.log"))
      let started = expectation(description: "preview is a live Bash job")
      var output = ""
      BashTool(
        command: command, timeout: 30, refresh: 1,
        projectPath: directory.path, workspacePath: directory.path
      ).invoke {
        output = $0.text
        started.fulfill()
      }
      wait(for: [started], timeout: 10)
      let jobLine = try XCTUnwrap(output.split(separator: "\n").first { $0.hasPrefix("job=") })
      let job = try XCTUnwrap(Int(jobLine.dropFirst(4)))
      defer {
        let stopped = expectation(description: "stop preview and pipeline consumer")
        BashStopTool(jobID: job).invoke { response in
          XCTAssertTrue(response.text.contains("status=stopped"), response.text)
          stopped.fulfill()
        }
        wait(for: [stopped], timeout: 5)
      }
      var log = ""
      for _ in 0..<5 {
        log =
          (try? String(contentsOf: directory.appendingPathComponent("preview.log"), encoding: .utf8))
          ?? ""
        if log.contains("http://127.0.0.1:") { break }
        let ready = expectation(description: "stream preview readiness")
        BashWaitTool(jobID: job, refresh: 1).invoke { response in
          output += response.text
          ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
      }
      XCTAssertTrue(output.contains("status=running"), output)
      let range = try XCTUnwrap(
        log.range(of: #"http://127\.0\.0\.1:[0-9]+/"#, options: .regularExpression), log + output)
      if command.contains("tee") { XCTAssertTrue(output.contains("http://127.0.0.1:"), output) }
      if command.contains("mirror.log") {
        XCTAssertTrue(
          try String(contentsOf: directory.appendingPathComponent("mirror.log"), encoding: .utf8)
            .contains(String(log[range])))
      }
      let fetched = expectation(description: "preview responds while pipeline stays alive")
      BashTool(
        command:
          "curl --fail --silent --show-error --max-time 5 \(log[range]) --output fetched.html",
        timeout: 10, refresh: 6, projectPath: directory.path, workspacePath: directory.path
      ).invoke { response in
        XCTAssertTrue(response.text.contains("exit=0"), response.text)
        fetched.fulfill()
      }
      wait(for: [fetched], timeout: 10)
      XCTAssertTrue(
        try String(contentsOf: directory.appendingPathComponent("fetched.html"), encoding: .utf8)
          .contains("hyperframes-player"))
    }
  }

  func testHyperFramesAndHTML2VideoVersionsThroughBashTool() throws {
    _ = try configureEmbeddedCommandEnvironment()
    let completed = expectation(description: "command versions through the embedded shell")
    let tool = BashTool(
      command: "hyperframes --version && html2video --version",
      timeout: 10, refresh: 10, projectPath: directory.path, workspacePath: directory.path)
    tool.invoke { response in
      let output = response.text
      XCTAssertTrue(output.contains("exit=0"), output)
      XCTAssertTrue(output.contains("0.8.78\n1.0.0"), output)
      completed.fulfill()
    }
    wait(for: [completed], timeout: 15)
  }

  func testHTML2VideoThroughBashTool() throws {
    _ = try configureEmbeddedCommandEnvironment()
    try """
    <html><style>body{margin:0;background:#00ff00}</style><script>
    window.html2video={width:64,height:64,duration:0.1};
    </script></html>
    """.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    let completed = expectation(description: "native export through the embedded shell")
    let command = "html2video . --output ~/export.mp4 --json"
    let tool = BashTool(
      command: command, timeout: 20, refresh: 20,
      projectPath: directory.path, workspacePath: directory.path)
    tool.invoke { response in
      let output = response.text
      XCTAssertTrue(output.contains("\"frames\":3"), output)
      completed.fulfill()
    }
    wait(for: [completed], timeout: 30)
    let movie = directory.appendingPathComponent("export.mp4")
    XCTAssertTrue(FileManager.default.fileExists(atPath: movie.path))
    let asset = AVURLAsset(url: movie)
    XCTAssertEqual(asset.duration.seconds, 0.1, accuracy: 0.001)
    let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
    XCTAssertEqual(track.naturalSize, CGSize(width: 64, height: 64))
  }

  func testDirectAndShellRedirectionsOpenTheSameFiles() throws {
    _ = try configureEmbeddedCommandEnvironment()
    let outside = directory.deletingLastPathComponent().appendingPathComponent(
      "redirect-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    // A plain echo takes the direct argv path; the variable sends the same redirect through OSH.
    for (command, name) in [
      ("echo direct > '\(outside.path)/direct.txt'", "direct.txt"),
      ("word=shell; echo $word > '\(outside.path)/shell.txt'", "shell.txt"),
    ] {
      let completed = expectation(description: command)
      BashTool(
        command: command, timeout: 10, refresh: 5,
        projectPath: directory.path, workspacePath: directory.path
      ).invoke { response in
        XCTAssertTrue(response.text.contains("exit=0"), response.text)
        completed.fulfill()
      }
      wait(for: [completed], timeout: 15)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: outside.appendingPathComponent(name).path), command)
    }
  }

  func testBashVirtualDirectoryErrorHints() throws {
    _ = try configureEmbeddedCommandEnvironment()
    let resolver = LocalPathResolver(projectPath: directory.path, workspacePath: directory.path)
    let hints = [
      "/tmp": "Path hint: /tmp is not available; use $TMPDIR (\(resolver.temporaryURL.path)).",
      "/app_bundle":
        "Path hint: /app_bundle is a cd alias; elsewhere use $APP_BUNDLE (\(resolver.appBundleURL.path)).",
    ]
    let cases: [(command: String, aliases: [String])] = [
      ("cd /app_bundle && echo \"$PWD\"", ["/app_bundle"]),
      (
        "printf 'cannot open /home/missing /tmp/missing /app_bundle/missing\\n' >&2; false",
        ["/tmp", "/app_bundle"]
      ),
      ("printf 'cannot open /tmp/missing\\n'; false", ["/tmp"]),
      ("printf 'cannot open /tmp/missing\\n' >&2; true", ["/tmp"]),
      ("printf 'cannot open /home/missing\\n' >&2; false", []),
      (
        #"printf '%s\n' 'open("/home"): path=/tmp, [/app_bundle]' >&2; false"#,
        ["/tmp", "/app_bundle"]
      ),
      ("printf '/home /tmp /app_bundle\\n'", []),
      (
        "printf 'missing /homepage /tmpfile /app_bundleish /private/tmp/file ./tmp/file\\n' >&2; false",
        []
      ),
      ("printf '/home2 /tmp.log /app_bundle-cache ~/tmp\\n' >&2; false", []),
    ]
    for (command, aliases) in cases {
      let completed = expectation(description: command)
      let tool = BashTool(
        command: command, timeout: 10, refresh: 5,
        projectPath: directory.path, workspacePath: directory.path)
      tool.invoke { response in
        let output = response.text
        XCTAssertEqual(output.contains("Path hint:"), !aliases.isEmpty, output)
        for alias in aliases {
          XCTAssertTrue(output.contains(hints[alias]!), output)
        }
        completed.fulfill()
      }
      wait(for: [completed], timeout: 15)
    }
  }

  func testNativeToolsIncludingMemoryAndRegisteredProofCommands() throws {
    _ = try configureEmbeddedCommandEnvironment()
    // XCTest's executable is inside its bundle, unlike the CLI binary. Its data
    // is in the test runfiles directory, so supply the archive explicitly here.
    let leanArchive = URL(fileURLWithPath: workingDirectory)
      .appendingPathComponent("Vendors/Lean/Lean_Init_Std.zip")
    let oldArchive = ProcessInfo.processInfo.environment["LEAN_RESOURCE_ARCHIVE"]
    setenv("LEAN_RESOURCE_ARCHIVE", leanArchive.path, 1)
    defer {
      if let oldArchive {
        setenv("LEAN_RESOURCE_ARCHIVE", oldArchive, 1)
      } else {
        unsetenv("LEAN_RESOURCE_ARCHIVE")
      }
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: leanArchive.path))

    func invoke(_ name: String, _ arguments: String) throws -> String {
      let bridge = RemoteToolsBridge(
        projectPath: directory.path, workspacePath: directory.path, webSearchProvider: .disabled)
      let completed = expectation(description: name)
      var output = ""
      _ = bridge.execute(
        RemoteToolCall(id: UUID().uuidString, name: name, arguments: arguments),
        bashUserInteraction: .init(), progress: { _ in }
      ) { result in
        XCTAssertFalse(result.isError, result.content)
        output = result.content
        completed.fulfill()
      }
      wait(for: [completed], timeout: 60)
      return output
    }
    let formatted = try invoke(
      "bash", #"{"command":"printf '%s:%03d' 'two words' 7","refresh_sec":5}"#)
    XCTAssertTrue(formatted.contains("two words:007"), formatted)
    XCTAssertFalse(formatted.contains("command not found"), formatted)
    let builtinSequence = try invoke(
      "bash",
      #"{"command":"printf '%s' 'redirected value' > builtin.txt && test -s builtin.txt && cat builtin.txt","refresh_sec":5}"#
    )
    XCTAssertTrue(builtinSequence.contains("redirected value"), builtinSequence)
    XCTAssertEqual(
      try String(contentsOf: directory.appendingPathComponent("builtin.txt"), encoding: .utf8),
      "redirected value")
    let failedBuiltin = try invoke("bash", #"{"command":"false","refresh_sec":5}"#)
    XCTAssertTrue(failedBuiltin.contains("exit=1"), failedBuiltin)
    XCTAssertFalse(failedBuiltin.contains("command not found"), failedBuiltin)
    // Shell recursion runs on this process's C stack. Deep recursion works, and
    // runaway recursion fails the command instead of crashing the host.
    let recursion = try invoke(
      "bash",
      #"{"command":"f() { if (( $1 > 0 )); then f $(($1-1)); fi; }; f 1000; echo deep-recursion","refresh_sec":30}"#
    )
    XCTAssertTrue(recursion.contains("deep-recursion"), recursion)
    let runaway = try invoke("bash", #"{"command":"f() { f; }; f","refresh_sec":30}"#)
    XCTAssertTrue(runaway.contains("exit=2"), runaway)
    XCTAssertTrue(runaway.contains("maximum recursion depth exceeded"), runaway)
    _ = try invoke("write", #"{"path":"lines.txt","content":"first\nsecond\nthird\n"}"#)
    XCTAssertTrue(try invoke("read", #"{"path":"lines.txt","max_lines":1}"#).contains("first"))
    XCTAssertTrue(try invoke("more", #"{"count":2}"#).contains("third"))
    _ = try invoke("edit", #"{"path":"lines.txt","old":"second","new":"changed"}"#)
    XCTAssertTrue(
      try invoke("search", #"{"query":"changed","path":"lines.txt"}"#).contains("changed"))
    XCTAssertTrue(try invoke("list", #"{"path":"."}"#).contains("lines.txt"))
    XCTAssertTrue(try invoke("datetime", #"{"timezone":"UTC"}"#).contains("T"))
    XCTAssertTrue(try invoke("check_smt", #"{"code":"(assert false)"}"#).contains("unsat"))
    _ = try invoke(
      "memory", #"{"target":"memory","action":"append","content":"CLI memory marker"}"#)
    XCTAssertTrue(try invoke("memory", #"{"target":"memory"}"#).contains("CLI memory marker"))
    _ = try invoke(
      "memory",
      #"{"target":"memory","action":"replace","old_text":"CLI memory marker","content":"CLI updated marker"}"#
    )
    XCTAssertTrue(try invoke("memory", #"{"target":"memory"}"#).contains("CLI updated marker"))
    _ = try invoke(
      "memory", #"{"target":"memory","action":"remove","old_text":"CLI updated marker"}"#)
    XCTAssertFalse(try invoke("memory", #"{"target":"memory"}"#).contains("CLI updated marker"))
    let commands = try invoke(
      "bash",
      #"{"command":"z3 --version && lean --version && check_lean 'theorem cli_parity : True := by trivial' && df -h .","refresh_sec":30,"timeout_sec":45}"#
    )
    XCTAssertTrue(commands.contains("Z3 version"), commands)
    XCTAssertTrue(commands.contains("Lean"), commands)
    XCTAssertTrue(commands.contains("status: valid"), commands)
    XCTAssertTrue(commands.contains("Filesystem"), commands)
    for stop in [false, true] {
      let started = try invoke(
        "bash", #"{"command":"sleep 1; printf JOB_DONE","refresh_sec":0.01,"timeout_sec":10}"#)
      let jobLine = try XCTUnwrap(started.split(separator: "\n").first { $0.hasPrefix("job=") })
      let job = try XCTUnwrap(Int(jobLine.dropFirst(4)))
      XCTAssertTrue(try invoke("bash_status", "{\"job\":\(job)}").contains("job=\(job)"))
      if stop {
        let stopped = try invoke("bash_stop", "{\"job\":\(job)}")
        XCTAssertTrue(stopped.contains("Stopped"), stopped)
      } else {
        let completed = try invoke("bash_wait", "{\"job\":\(job),\"refresh_sec\":5}")
        XCTAssertTrue(completed.contains("status=completed"), completed)
        XCTAssertTrue(completed.contains("JOB_DONE"), completed)
      }
    }
    // A stop right after a job starts, possibly while its capture is still
    // being prepared, stops the job instead of being lost.
    for _ in 0..<5 {
      let started = try invoke(
        "bash", #"{"command":"sleep 5; echo should-not-run","refresh_sec":0}"#)
      let jobLine = try XCTUnwrap(started.split(separator: "\n").first { $0.hasPrefix("job=") })
      let job = try XCTUnwrap(Int(jobLine.dropFirst(4)))
      let stopped = try invoke("bash_stop", "{\"job\":\(job)}")
      XCTAssertTrue(stopped.contains("status=stopped"), stopped)
      XCTAssertFalse(stopped.contains("should-not-run"), stopped)
    }
  }

  func testEveryAPIKeyProviderThroughItsProductionFactory() async throws {
    let environmentName = "LOCAL_CODE_CLI_FACTORY_TEST_KEY"
    setenv(environmentName, "fixture-key", 1)
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [CLIURLProtocol.self]
    defer {
      CLIURLProtocol.handler = nil
      unsetenv(environmentName)
    }
    let endpoints =
      RemoteProvider.allCases.filter { $0 != .openAI }.map { ($0, "https://cli-parity.invalid/v1") }
      + [(.openAICompatible, "https://api.openai.com")]
    for (provider, baseURL) in endpoints {
      var requests = 0
      CLIURLProtocol.handler = { request in
        requests += 1
        if request.httpMethod == "GET" {
          return #"{"context_length":32768,"max_output_tokens":1024}"#
        }
        XCTAssertEqual(request.httpMethod, "POST")
        if baseURL == "https://api.openai.com" {
          XCTAssertEqual(request.url?.path, "/v1/responses")
          return """
            data: {"type":"response.output_text.delta","delta":"FACTORY_OK"}

            data: {"type":"response.completed","response":{"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}


            """
        }
        if provider == .anthropic {
          return """
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"FACTORY_OK"}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

            data: {"type":"message_stop"}


            """
        }
        return
          "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"FACTORY_OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
      }
      let record = directory.appendingPathComponent("\(provider.rawValue).json")
      var command = try RemoteAgentCLI.parse([
        "--provider", provider.rawValue, "--base-url", baseURL,
        "--model", "fixture/model", "--api-key-environment", environmentName,
        "--project", directory.path, "--message", "fixture", "--result-json", record.path,
      ])
      try await command.run(sessionConfiguration: session)
      XCTAssertEqual(requests, 2)
      let result = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
      XCTAssertEqual(result["finalText"] as? String, "FACTORY_OK")
      XCTAssertEqual(result["provider"] as? String, provider.rawValue)
    }
  }

  func testRemoteFailureSavesStateAndRejectsMismatchedResume() async throws {
    let environmentName = "LOCAL_CODE_CLI_ERROR_TEST_KEY"
    setenv(environmentName, "fixture-key", 1)
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [CLIURLProtocol.self]
    defer {
      CLIURLProtocol.handler = nil
      unsetenv(environmentName)
    }
    var requests = 0
    CLIURLProtocol.handler = { _ in
      requests += 1
      return "data: invalid-json\n\n"
    }
    let record = directory.appendingPathComponent("failed.json")
    var command = try RemoteAgentCLI.parse([
      "--provider", "openai-compatible", "--base-url", "https://cli-parity.invalid/v1",
      "--model", "fixture/model", "--api-key-environment", environmentName,
      "--context-window-tokens", "32768", "--maximum-output-tokens", "1024",
      "--project", directory.path, "--message", "fixture", "--result-json", record.path,
    ])
    do {
      try await command.run(sessionConfiguration: session)
      XCTFail("Malformed provider response should fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("malformed stream"), "\(error)")
    }
    let result = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
    XCTAssertNotNil(result["error"] as? String)
    XCTAssertNotNil(result["state"] as? [String: Any])
    let requestsBeforeResume = requests
    XCTAssertGreaterThan(requestsBeforeResume, 0)
    command.options.resume = record.path
    command.model = "another-model"
    do {
      try await command.run(sessionConfiguration: session)
      XCTFail("Mismatched resume should fail before contacting the provider")
    } catch {
      XCTAssertTrue(
        String(describing: error).contains("different provider, model, endpoint, or project"))
    }
    XCTAssertEqual(requests, requestsBeforeResume)
  }

  func testCLISettingsAndFailureBoundaries() throws {
    let local = ["local-agent", "--model", "qwen_3.8_27b_i4x.ckpt", "--message", "hello"]
    for option in [
      "--thinking-budget", "--queue-watermark", "--maximum-generated-tokens",
      "--chunked-prefill-max-length",
    ] {
      XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(local + [option, "-1"]))
    }
    for arguments in [
      ["--thinking-budget", "131073"], ["--chunked-prefill-max-length", "65537"],
      ["--weights-streaming", "1"], ["--reasoning-effort", "unknown"],
      ["--web-search-provider", "unknown"],
    ] {
      XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(local + arguments))
    }
    for mode in ["--ttft-tokens", "--mtp-draft-tokens"] {
      XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot([mode, "2", "--mtp-generate"]))
    }
    let remote = [
      "remote-agent", "--provider", "anthropic", "--model", "fixture", "--message", "hello",
    ]
    for arguments in [
      ["--context-window-tokens", "4095"], ["--maximum-output-tokens", "0"],
      ["--maximum-rounds", "0"], ["--compaction-threshold", "nan"],
      ["--compaction-threshold", "0.9"], ["--compaction-target", "0.8"],
    ] {
      XCTAssertThrowsError(try LocalCodeCLI.parseAsRoot(remote + arguments))
    }
    let environmentName = "LOCAL_CODE_CLI_KAGI_TEST_KEY"
    var options = try AgentCLIOptions.parse([
      "--message", "hello", "--web-search-provider", "kagi",
      "--web-search-api-key-environment", environmentName,
    ])
    unsetenv(environmentName)
    XCTAssertThrowsError(try options.configuredWebSearchProvider())
    setenv(environmentName, "fixture-key", 1)
    defer { unsetenv(environmentName) }
    XCTAssertEqual(try options.configuredWebSearchProvider(), .kagi(apiKey: "fixture-key"))
    options = try AgentCLIOptions.parse([
      "--message", "hello", "--web-search-provider", "brave",
      "--web-search-api-key-environment", environmentName,
    ])
    unsetenv(environmentName)
    XCTAssertThrowsError(try options.configuredWebSearchProvider())
    setenv(environmentName, " ", 1)
    XCTAssertThrowsError(try options.configuredWebSearchProvider())
    setenv(environmentName, " brave-fixture-key\n", 1)
    XCTAssertEqual(try options.configuredWebSearchProvider(), .brave(apiKey: "brave-fixture-key"))
    options.webSearchProvider = .disabled
    let bridge = RemoteToolsBridge(
      projectPath: directory.path, workspacePath: directory.path,
      webSearchProvider: try options.configuredWebSearchProvider())
    XCTAssertFalse(bridge.tools.contains { $0.name == "websearch" })
    XCTAssertTrue(bridge.tools.contains { $0.name == "webfetch" })
    let original = AgentCLIOptions.fileURL("stable.json")
    XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
    XCTAssertEqual(AgentCLIOptions.fileURL("stable.json"), original)
  }

  func testRemoteCancellationSavesSnapshotAndReturnsSignalStatus() async throws {
    let environmentName = "LOCAL_CODE_CLI_SIGNAL_TEST_KEY"
    setenv(environmentName, "fixture-key", 1)
    defer {
      unsetenv(environmentName)
      CLIURLProtocol.handler = nil
    }
    let session = URLSessionConfiguration.ephemeral
    session.protocolClasses = [CLIURLProtocol.self]
    for signalNumber in [SIGINT, SIGTERM] {
      CLIURLProtocol.handler = { _ in
        // A request starts only after the CLI installs its signal handler.
        XCTAssertEqual(kill(getpid(), signalNumber), 0)
        return nil
      }
      let record = directory.appendingPathComponent("signal-\(signalNumber).json")
      var command = try RemoteAgentCLI.parse([
        "--provider", "openai-compatible", "--base-url", "https://cli-parity.invalid/v1",
        "--model", "fixture", "--api-key-environment", environmentName,
        "--context-window-tokens", "32768", "--maximum-output-tokens", "1024",
        "--project", directory.path, "--message", "fixture", "--result-json", record.path,
      ])
      do {
        try await command.run(sessionConfiguration: session)
        XCTFail("Cancelled run should return its signal status")
      } catch {
        XCTAssertEqual((error as? ExitCode)?.rawValue, 128 + signalNumber)
      }
      let result = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
      XCTAssertTrue((result["error"] as? String)?.contains("cancelled") == true)
      XCTAssertNotNil(result["state"] as? [String: Any])
    }
  }
}

private final class CLIURLProtocol: URLProtocol {
  static var handler: ((URLRequest) throws -> String?)?

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let response = try XCTUnwrap(
        HTTPURLResponse(
          url: XCTUnwrap(request.url), statusCode: 200,
          httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]))
      guard let body = try XCTUnwrap(Self.handler)(request) else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}
