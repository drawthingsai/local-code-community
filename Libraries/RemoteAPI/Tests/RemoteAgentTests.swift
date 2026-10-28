import Foundation
import XCTest

@testable import RemoteAPI

final class RemoteAgentTests: XCTestCase {
  func testNativeToolLoopRegeneratesMalformedArgumentsAndPreservesTranscript() throws {
    let reasoningDetails: [RemoteJSONValue] = [
      .object([
        "type": .string("reasoning.text"),
        "text": .string("Need both files."),
        "id": .string("reasoning-1"),
        "format": .string("anthropic-claude-v1"),
        "index": .number(0),
      ])
    ]
    let calls = [
      RemoteToolCall(id: "a", name: "read", arguments: #"{"path":"a"}"#),
      RemoteToolCall(id: "b", name: "read", arguments: #"{"path":"b"}"#),
    ]
    let provider = RecordingProvider { request, index in
      switch index {
      case 0:
        return .success(
          RemoteCompletion(
            text: "",
            toolCalls: [
              RemoteToolCall(id: "invalid-a", name: "read", arguments: #"{"path":"a""#)
            ],
            providerOutputItems: [
              .object([
                "type": .string("function_call"),
                "arguments": .string(#"{"path":"a""#),
              ])
            ]))
      case 1, 2:
        XCTAssertEqual(request.messages.suffix(2).map(\.role), [.assistant, .toolResult])
        XCTAssertEqual(request.messages[request.messages.count - 2].toolCalls[0].arguments, "{}")
        XCTAssertEqual(
          request.messages[request.messages.count - 2].providerOutputItems?.first?.objectString(
            for: "arguments"), "{}")
        XCTAssertTrue(
          request.messages.last?.toolResults[0].content.contains("invalid_arguments") == true)
        if index == 1 {
          return .success(
            RemoteCompletion(
              text: "",
              toolCalls: [
                RemoteToolCall(id: "invalid-b", name: "read", arguments: #"["a"]"#)
              ],
              providerOutputItems: [
                .object([
                  "type": .string("function_call"), "arguments": .string(#"["a"]"#),
                ])
              ]))
        }
        return .success(
          RemoteCompletion(
            text: "Checking", toolCalls: calls, usage: .init(promptTokens: 100),
            thinking: RemoteThinking(providerMetadata: reasoningDetails)))
      default:
        XCTAssertEqual(
          request.messages.suffix(3).map(\.role), [.assistant, .toolResult, .toolResult])
        XCTAssertEqual(
          request.messages[request.messages.count - 3].thinking.first?.providerMetadata,
          reasoningDetails)
        XCTAssertEqual(
          request.messages.suffix(2).compactMap { $0.toolResults.first?.toolCallID }, ["a", "b"])
        XCTAssertEqual(
          request.messages.suffix(2).compactMap { $0.toolResults.first?.content },
          ["a-result", "b-result"])
        return .success(RemoteCompletion(text: "Done", toolCalls: []))
      }
    }
    var executionOrder = [String]()
    let agent = makeAgent(
      provider: provider,
      executor: {
        call, _, completion in
        executionOrder.append(call.id)
        completion(RemoteToolExecutionResult(content: "\(call.id)-result", subtitle: call.id))
        return nil
      })
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "agent completion")
    var progress = [RemoteAgentProgress]()
    agent.send("Inspect", progress: { progress.append($0) }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(executionOrder, ["a", "b"])
    XCTAssertEqual(provider.requests.count, 4)
    XCTAssertEqual(try result?.get().text, "Checking\n\nDone")
    XCTAssertEqual(
      try result?.get().tools.map(\.subtitle),
      [
        "Model didn't produce well-formed JSON for read; asking it to regenerate (1/2)",
        "Model didn't produce well-formed JSON for read; asking it to regenerate (2/2)",
        "a", "b",
      ])
    XCTAssertTrue(
      progress.contains {
        $0.tools.contains { $0.subtitle.contains("asking it to regenerate (1/2)") }
      })
    XCTAssertEqual(
      agent.state.transcript.map(\.role),
      [
        .user, .assistant, .toolResult, .assistant, .toolResult, .assistant, .toolResult,
        .toolResult, .assistant,
      ])
    XCTAssertEqual(agent.state.transcript[1].toolCalls[0].arguments, "{}")
    XCTAssertEqual(agent.state.transcript[3].toolCalls[0].arguments, "{}")
    XCTAssertEqual(agent.state.transcript[5].thinking.first?.providerMetadata, reasoningDetails)
    XCTAssertEqual(agent.state.transcript[5].source, provider.modelIdentity)

    let incapableProvider = RecordingProvider { _, index in
      .success(
        RemoteCompletion(
          text: "",
          toolCalls: [
            RemoteToolCall(
              id: "invalid-\(index)", name: "read", arguments: #"{"path":"README.md""#)
          ]))
    }
    let incapableAgent = makeAgent(
      provider: incapableProvider,
      executor: { _, _, _ in
        XCTFail("Malformed model-generated arguments must not reach the tool executor.")
        return nil
      })
    var incapableResult: Result<RemoteAgentCompletion, RemoteChatError>?
    let incapableCompletion = expectation(description: "incapable model completion")
    incapableAgent.send("Inspect", progress: { _ in }) {
      incapableResult = $0
      incapableCompletion.fulfill()
    }
    wait(for: [incapableCompletion], timeout: 1)

    XCTAssertEqual(
      incapableResult, .failure(.invalidToolArguments(function: "read")))
    XCTAssertEqual(incapableProvider.requests.count, 3)
    XCTAssertEqual(
      incapableAgent.state.transcript.compactMap { $0.toolCalls.first?.arguments },
      ["{}", "{}", "{}"])
    XCTAssertTrue(
      incapableAgent.state.transcript.last?.text?.contains("repeatedly returned malformed JSON")
        == true)

    let poisonedCall = RemoteToolCall(
      id: "poisoned", name: "read", arguments: #"{"path":"README.md""#)
    let poisonedState = RemoteAgentState(
      transcript: [
        .user("Earlier request"),
        RemoteTranscriptEntry(
          role: .assistant,
          content: [
            .thinking(
              RemoteThinking(
                text: "must not fall back to plaintext reasoning",
                providerMetadata: [
                  .object([
                    "type": .string("reasoning.encrypted"),
                    "data": .string("poisoned"),
                    "unexpected": .string("must not be replayed"),
                  ])
                ])),
            .toolCall(poisonedCall),
          ],
          source: RemoteModelIdentity(
            provider: RemoteProvider.localCode.rawValue, model: "vendor/model"),
          providerOutputItems: [
            .object(["type": .string("reasoning"), "id": .string("rs_poisoned")]),
            .object([
              "type": .string("function_call"), "id": .string("fc_poisoned"),
              "arguments": .string(#"{"path":"README.md""#),
            ]),
          ]),
        .toolResult(
          RemoteToolError.content(
            type: "invalid_arguments", function: "read",
            message: "Tool arguments must be a valid JSON object."),
          toolCallID: poisonedCall.id, toolName: poisonedCall.name, isError: true),
        .assistant("Earlier request failed"),
        .assistant(""),
      ])
    let recoveredProvider = RecordingProvider { request, _ in
      XCTAssertFalse(request.messages.contains { !$0.hasAssistantPayload })
      XCTAssertEqual(
        request.messages.compactMap { $0.toolCalls.first?.arguments }.first, "{}")
      return .success(RemoteCompletion(text: "Recovered poisoned history", toolCalls: []))
    }
    let recoveredAgent = makeAgent(provider: recoveredProvider, state: poisonedState)
    var recoveredResult: Result<RemoteAgentCompletion, RemoteChatError>?
    let recoveredCompletion = expectation(description: "poisoned history completion")
    recoveredAgent.send("Continue", progress: { _ in }) {
      recoveredResult = $0
      recoveredCompletion.fulfill()
    }
    wait(for: [recoveredCompletion], timeout: 1)

    XCTAssertEqual(try recoveredResult?.get().text, "Recovered poisoned history")
    XCTAssertEqual(recoveredProvider.requests.count, 1)
    XCTAssertFalse(recoveredAgent.state.transcript.contains { !$0.hasAssistantPayload })
    XCTAssertNil(recoveredProvider.requests[0].messages[2].thinking.first?.providerMetadata)
    XCTAssertNil(recoveredProvider.requests[0].messages[2].thinking.first?.text)
    XCTAssertEqual(recoveredProvider.requests[0].messages[2].providerOutputItems?.count, 1)
    XCTAssertEqual(
      recoveredProvider.requests[0].messages[2].providerOutputItems?.first?.objectString(
        for: "arguments"), "{}")

    let malformedReasoningProvider = RecordingProvider(
      modelIdentity: RemoteModelIdentity(
        provider: RemoteProvider.openRouter.rawValue, model: "vendor/model")
    ) { _, _ in
      .success(
        RemoteCompletion(
          text: "",
          toolCalls: [RemoteToolCall(id: "unsafe", name: "read", arguments: "{}")],
          thinking: RemoteThinking(
            providerMetadata: [
              .object([
                "type": .string("reasoning.encrypted"),
                "data": .string("missing required envelope fields"),
              ])
            ])))
    }
    let malformedReasoningAgent = makeAgent(
      provider: malformedReasoningProvider,
      executor: { _, _, _ in
        XCTFail("A tool call with malformed reasoning metadata must not be executed.")
        return nil
      })
    var malformedReasoningResult: Result<RemoteAgentCompletion, RemoteChatError>?
    let malformedReasoningCompletion = expectation(description: "malformed reasoning completion")
    malformedReasoningAgent.send("Inspect", progress: { _ in }) {
      malformedReasoningResult = $0
      malformedReasoningCompletion.fulfill()
    }
    wait(for: [malformedReasoningCompletion], timeout: 1)

    guard case .failure(.malformedStream(let message)) = malformedReasoningResult else {
      return XCTFail("Expected malformed reasoning metadata to fail before tool execution.")
    }
    XCTAssertTrue(message.contains("reasoning_details"))
    XCTAssertTrue(malformedReasoningAgent.state.transcript.last?.toolCalls.isEmpty == true)
  }

  func testCompactionReplacesSummarizedPrefixAndSendsIterativeCheckpoint() throws {
    let oldCall = RemoteToolCall(
      id: "old-call", name: "read", arguments: #"{"path":"old.txt"}"#)
    let oldText = String(repeating: "old source detail ", count: 700)
    let initialState = RemoteAgentState(
      transcript: [
        .user(oldText),
        .assistant(
          nil,
          thinking: RemoteThinking(
            text: "Private intermediate reasoning that should not enter the checkpoint."),
          toolCalls: [oldCall]),
        .toolResult(
          String(repeating: "old tool output ", count: 500), toolCallID: oldCall.id,
          toolName: oldCall.name, isError: false),
        .assistant("Old work finished"),
        .user(String(repeating: "second old turn ", count: 500)),
        .assistant("Second answer"),
        .user("Keep this recent turn"),
        .assistant("Recent answer"),
      ])
    let provider = RecordingProvider { request, _ in
      if request.tools.isEmpty {
        XCTAssertTrue(request.messages[0].text?.contains("checkpoint writer") == true)
        XCTAssertTrue(request.messages[1].text?.contains("old source detail") == true)
        XCTAssertTrue(request.messages[1].text?.contains("Old work finished") == true)
        XCTAssertFalse(request.messages[1].text?.contains("old tool output") == true)
        XCTAssertFalse(request.messages[1].text?.contains("Private intermediate") == true)
        return .success(
          RemoteCompletion(
            text:
              "## Active Task\nContinue the current request.\n\n## Completed Work\nOld work finished.",
            toolCalls: [], usage: .init(promptTokens: 2_000)))
      }
      XCTAssertTrue(
        request.messages.contains { $0.text?.contains("CONTEXT CHECKPOINT") == true })
      XCTAssertFalse(request.messages.contains { $0.text == oldText })
      return .success(RemoteCompletion(text: "Current answer", toolCalls: []))
    }
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: 16_384, reservedOutputTokens: 512,
      compactionThreshold: 0.35, compactionTarget: 0.20)
    let agent = makeAgent(
      provider: provider, configuration: configuration, state: initialState)
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "compacted completion")
    agent.send("Current request", progress: { _ in }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(try result?.get().text, "Current answer")
    XCTAssertGreaterThanOrEqual(provider.requests.filter(\.tools.isEmpty).count, 1)
    XCTAssertTrue(
      agent.state.transcript.contains { $0.text?.contains("CONTEXT CHECKPOINT") == true })
    XCTAssertFalse(agent.state.transcript.contains { $0.text == oldText })
    XCTAssertFalse(
      agent.state.transcript.contains {
        $0.toolResults.contains { $0.toolCallID == oldCall.id }
      })
    XCTAssertEqual(agent.state.transcript.suffix(2).map(\.role), [.user, .assistant])
  }

  func testFailedToolResultSurvivesCompactionWithoutReexecution() throws {
    let oldCall = RemoteToolCall(
      id: "old", name: "read", arguments: #"{"path":"old.txt"}"#)
    let liveCall = RemoteToolCall(
      id: "live-failure", name: "read", arguments: #"{"path":"missing.txt"}"#)
    let failedContent = RemoteToolError.content(
      type: "command_failed", function: liveCall.name,
      message: String(repeating: "failure payload ", count: 220))
    let initialState = RemoteAgentState(
      transcript: [
        .user(String(repeating: "old tool-only context ", count: 150)),
        .assistant(nil, toolCalls: [oldCall]),
        .toolResult(
          "old result", toolCallID: oldCall.id, toolName: oldCall.name, isError: false),
      ],
      tokenPerByte: 1)
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: 16_384, reservedOutputTokens: 512,
      compactionThreshold: 0.35, compactionTarget: 0.20)
    let provider = RecordingProvider { request, index in
      switch index {
      case 0:
        XCTAssertFalse(request.tools.isEmpty)
        return .success(RemoteCompletion(text: "", toolCalls: [liveCall]))
      case 1:
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertFalse(
          request.messages.contains {
            $0.toolCalls.contains { $0.id == liveCall.id }
              || $0.toolResults.contains { $0.toolCallID == liveCall.id }
          })
        return .success(
          RemoteCompletion(
            text: "## Active Task\nContinue after the failed read.", toolCalls: []))
      case 2:
        XCTAssertFalse(request.tools.isEmpty)
        XCTAssertEqual(
          request.messages.map(\.role),
          [.system, .user, .assistant, .toolResult])
        XCTAssertTrue(request.messages[1].text?.contains("CONTEXT CHECKPOINT") == true)
        XCTAssertTrue(request.messages[1].text?.contains("CURRENT USER MESSAGE") == true)
        XCTAssertTrue(request.messages[1].text?.contains("Continue") == true)
        XCTAssertEqual(request.messages[2].toolCalls, [liveCall])
        XCTAssertEqual(
          request.messages[3].toolResults,
          [
            RemoteToolResult(
              toolCallID: liveCall.id, toolName: liveCall.name,
              content: failedContent, isError: true)
          ])
        return .success(RemoteCompletion(text: "Recovered", toolCalls: []))
      default:
        XCTFail("Unexpected additional provider request")
        return .failure(.provider(statusCode: 500, message: "unexpected request"))
      }
    }
    var executedIDs = [String]()
    let agent = makeAgent(
      provider: provider, configuration: configuration, state: initialState,
      executor: { call, _, completion in
        executedIDs.append(call.id)
        completion(
          RemoteToolExecutionResult(
            content: failedContent, subtitle: "Read failed", isError: true))
        return nil
      })
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "completion after failed-result compaction")
    agent.send("Continue", progress: { _ in }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(try result?.get().text, "Recovered")
    XCTAssertEqual(executedIDs, [liveCall.id])
    XCTAssertEqual(provider.requests.count, 3)
    XCTAssertEqual(provider.requests.filter(\.tools.isEmpty).count, 1)
    let retainedResults = agent.state.transcript.flatMap(\.toolResults).filter {
      $0.toolCallID == liveCall.id
    }
    XCTAssertEqual(retainedResults.count, 1)
    XCTAssertEqual(retainedResults.first?.content, failedContent)
    XCTAssertEqual(retainedResults.first?.isError, true)
  }

  func testPreparedContextPreservesAtomicToolExchangeAtRetentionBoundary() {
    var transcript = (0..<14).map { index in
      index.isMultiple(of: 2)
        ? RemoteTranscriptEntry.user(String(repeating: "old user context ", count: 40))
        : RemoteTranscriptEntry.assistant(String(repeating: "old assistant context ", count: 40))
    }
    let calls = [
      RemoteToolCall(id: "boundary-a", name: "read", arguments: "{}"),
      RemoteToolCall(id: "boundary-b", name: "read", arguments: "{}"),
    ]
    transcript.append(.assistant(nil, toolCalls: calls))
    transcript.append(
      .toolResult(
        "first result", toolCallID: calls[0].id, toolName: calls[0].name, isError: false))
    transcript.append(
      .toolResult(
        "second result", toolCallID: calls[1].id, toolName: calls[1].name,
        isError: false))
    transcript.append(.assistant("Boundary tool work finished"))
    for index in 0..<10 {
      transcript.append(
        index.isMultiple(of: 2)
          ? .user("recent user \(index)")
          : .assistant("recent assistant \(index)"))
    }
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: 4_096, reservedOutputTokens: 512,
      compactionThreshold: 0.35)
    let state = RemoteAgentState(transcript: transcript)
    let prepared = RemoteContext.preparedContext(
      state: state, systemPrompt: "System", tools: [Self.readTool],
      configuration: configuration)
    guard
      let callIndex = prepared.messages.firstIndex(where: {
        $0.toolCalls.map(\.id) == calls.map(\.id)
      }),
      callIndex + 3 < prepared.messages.count
    else {
      return XCTFail("The boundary-spanning tool exchange was removed.")
    }
    XCTAssertEqual(
      prepared.messages[callIndex...callIndex + 3].map(\.role),
      [.assistant, .toolResult, .toolResult, .assistant])
    XCTAssertEqual(
      prepared.messages[callIndex + 1].toolResults.first?.toolCallID, calls[0].id)
    XCTAssertEqual(
      prepared.messages[callIndex + 2].toolResults.first?.toolCallID, calls[1].id)
  }

  func testContextLimitForcesCompactionAndRetriesFromCheckpoint() throws {
    let initialState = RemoteAgentState(
      transcript: [
        .user(String(repeating: "first ", count: 600)),
        .assistant("first answer"),
        .user(String(repeating: "second ", count: 600)),
        .assistant("second answer"),
      ])
    let provider = RecordingProvider { request, index in
      switch index {
      case 0:
        XCTAssertFalse(request.tools.isEmpty)
        return .failure(
          .provider(statusCode: 400, message: "maximum context length exceeded"))
      case 1:
        XCTAssertTrue(request.tools.isEmpty)
        return .success(
          RemoteCompletion(text: "## Active Task\nAnswer the latest request.", toolCalls: []))
      default:
        XCTAssertFalse(request.tools.isEmpty)
        return .success(RemoteCompletion(text: "Recovered", toolCalls: []))
      }
    }
    let agent = makeAgent(
      provider: provider,
      configuration: RemoteAgentConfiguration(
        contextWindowTokens: 128_000, reservedOutputTokens: 1_024),
      state: initialState)
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "recovered completion")
    agent.send("latest", progress: { _ in }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(try result?.get().text, "Recovered")
    XCTAssertEqual(provider.requests.count, 3)
    XCTAssertLessThan(agent.state.effectiveContextWindowTokens ?? .max, 128_000)
    XCTAssertTrue(
      agent.state.transcript.contains { $0.text?.contains("CONTEXT CHECKPOINT") == true })
    XCTAssertFalse(
      agent.state.transcript.contains { $0.text == initialState.transcript[0].text })
  }

  func testCancellationClosesEveryOutstandingToolCallAndIgnoresLateCompletion() {
    let calls = [
      RemoteToolCall(id: "a", name: "read", arguments: "{}"),
      RemoteToolCall(id: "b", name: "read", arguments: "{}"),
    ]
    let provider = RecordingProvider { _, _ in
      .success(RemoteCompletion(text: "", toolCalls: calls))
    }
    var deferredCompletion: ((RemoteToolExecutionResult) -> Void)?
    var toolWasCancelled = false
    let toolStarted = expectation(description: "tool started")
    let agent = makeAgent(
      provider: provider,
      executor: { _, _, completion in
        deferredCompletion = completion
        toolStarted.fulfill()
        return {
          toolWasCancelled = true
        }
      })
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "cancelled completion")
    agent.send("Start", progress: { _ in }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [toolStarted], timeout: 1)
    agent.cancel()
    wait(for: [completion], timeout: 1)
    deferredCompletion?(RemoteToolExecutionResult(content: "late", subtitle: "late"))

    XCTAssertEqual(result, .failure(.cancelled))
    XCTAssertTrue(toolWasCancelled)
    XCTAssertEqual(
      agent.state.transcript.map(\.role),
      [.user, .assistant, .toolResult, .toolResult, .assistant])
    XCTAssertEqual(agent.state.transcript[2].toolResults.first?.toolCallID, "a")
    XCTAssertEqual(agent.state.transcript[3].toolResults.first?.toolCallID, "b")
    XCTAssertTrue(
      agent.state.transcript[2].toolResults.first?.content.contains("cancelled") == true)
    XCTAssertFalse(agent.state.transcript.contains { $0.text == "late" })
  }

  func testOutputLimitIsNotCommittedAsSuccessfulCompletion() {
    let provider = RecordingProvider { _, _ in
      .success(
        RemoteCompletion(
          text: "This response is incomplete", toolCalls: [], stopReason: "length"))
    }
    let agent = makeAgent(provider: provider)
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "incomplete completion")
    agent.send("Start", progress: { _ in }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(result, .failure(.incompleteResponse("length")))
    XCTAssertEqual(agent.state.transcript.map(\.role), [.user, .assistant])
    XCTAssertTrue(agent.state.transcript[1].text?.contains("incomplete") == true)
    XCTAssertTrue(
      agent.state.transcript[1].text?.contains("stopped this response early") == true)
  }

  func testTransientProviderFailureRetriesWithoutDuplicatingHistory() {
    let provider = RecordingProvider { _, index in
      index == 0
        ? .failure(.provider(statusCode: 529, message: "temporarily overloaded"))
        : .success(RemoteCompletion(text: "Recovered", toolCalls: []))
    }
    let agent = makeAgent(
      provider: provider,
      configuration: RemoteAgentConfiguration(
        contextWindowTokens: 32_768, maximumRequestRetries: 2, retryBaseDelay: 0.01))
    let expectation = expectation(description: "retry")
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    agent.send("Start", progress: { _ in }) {
      result = $0
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertEqual(try result?.get().text, "Recovered")
    XCTAssertEqual(provider.requests.count, 2)
    XCTAssertEqual(agent.state.transcript.map(\.role), [.user, .assistant])
  }

  func testReportsObservedRemoteMetricsWithoutInventingPromptThroughput() throws {
    var now: TimeInterval = 10
    let provider = RecordingProvider(streamingResponse: { _, _, progress in
      now = 11
      progress(RemoteStreamProgress(content: [.thinking(RemoteThinking())]))
      now = 12
      progress(RemoteStreamProgress(text: "Hello", toolCalls: []))
      now = 14
      return .success(
        RemoteCompletion(
          text: "Hello world", toolCalls: [],
          usage: RemoteUsage(promptTokens: 100, completionTokens: 8)))
    })
    let agent = makeAgent(provider: provider, timeProvider: { now })
    var snapshots = [RemoteAgentMetrics]()
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "metrics")
    agent.send("Start", progress: { snapshots.append($0.metrics) }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 1)

    XCTAssertNil(snapshots[0].averageTimeToFirstToken)
    XCTAssertEqual(snapshots[1].averageTimeToFirstToken, 2)
    XCTAssertEqual(
      try XCTUnwrap(snapshots[1].observedOutputTokensPerSecond), 5.0 / 3.0 / 2.0,
      accuracy: 0.0001)
    XCTAssertTrue(snapshots[1].isOutputRateEstimated)
    XCTAssertEqual(try result?.get().metrics.averageTimeToFirstToken, 2)
    XCTAssertEqual(try result?.get().metrics.observedOutputTokensPerSecond, 2)
    XCTAssertFalse(try XCTUnwrap(result?.get().metrics.isOutputRateEstimated))
  }

  func testProgressStreamsThinkingForTheCurrentRequest() throws {
    let call = RemoteToolCall(id: "read-1", name: "read", arguments: "{}")
    let provider = RecordingProvider(streamingResponse: { _, index, progress in
      if index == 0 {
        progress(RemoteStreamProgress(content: [.thinking(RemoteThinking(text: "Plan"))]))
        progress(
          RemoteStreamProgress(content: [
            .thinking(RemoteThinking(text: "Plan the read.")), .toolCall(call),
          ]))
        return .success(
          RemoteCompletion(
            text: "", toolCalls: [call], thinking: RemoteThinking(text: "Plan the read.")))
      }
      progress(RemoteStreamProgress(content: [.thinking(RemoteThinking(text: "Wrap up"))]))
      progress(
        RemoteStreamProgress(content: [.thinking(RemoteThinking(text: "Wrap up")), .text("Done")]))
      return .success(
        RemoteCompletion(text: "Done", toolCalls: [], thinking: RemoteThinking(text: "Wrap up")))
    })
    let agent = makeAgent(provider: provider)
    var snapshots = [RemoteAgentProgress]()
    let completion = expectation(description: "thinking progress")
    agent.send("Read", progress: { snapshots.append($0) }) { _ in completion.fulfill() }
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(snapshots.first?.thinking, "Plan")
    XCTAssertEqual(snapshots.first?.text, "")
    XCTAssertTrue(snapshots.contains { $0.thinking == "Plan the read." && !$0.streamingToolCalls.isEmpty })
    // A new request starts without the previous request's reasoning, which ends at its text.
    XCTAssertTrue(snapshots.contains { $0.thinking == "Wrap up" && $0.text.isEmpty })
    XCTAssertEqual(snapshots.last?.text, "Done")
    XCTAssertEqual(snapshots.last?.thinking, "")
  }

  func testAveragesTimeToFirstTokenAcrossToolRounds() throws {
    var now: TimeInterval = 10
    let provider = RecordingProvider(streamingResponse: { _, index, progress in
      if index == 0 {
        now = 12
        progress(
          RemoteStreamProgress(
            text: "", toolCalls: [RemoteToolCall(id: "read-1", name: "read", arguments: "{}")]))
        now = 14
        return .success(
          RemoteCompletion(
            text: "", toolCalls: [RemoteToolCall(id: "read-1", name: "read", arguments: "{}")],
            usage: RemoteUsage(completionTokens: 8)))
      }
      now = 15
      progress(RemoteStreamProgress(text: "Done", toolCalls: []))
      now = 18
      return .success(
        RemoteCompletion(
          text: "Done", toolCalls: [], usage: RemoteUsage(completionTokens: 6)))
    })
    let agent = makeAgent(provider: provider, timeProvider: { now })
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    let completion = expectation(description: "two model rounds")
    agent.send("Read", progress: { _ in }) {
      result = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 1)

    XCTAssertEqual(provider.requests.count, 2)
    XCTAssertEqual(try result?.get().metrics.averageTimeToFirstToken, 1.5)
    XCTAssertEqual(try result?.get().metrics.observedOutputTokensPerSecond, 1.75)
    XCTAssertFalse(try XCTUnwrap(result?.get().metrics.isOutputRateEstimated))
  }

  private func makeAgent(
    provider: RemoteChatProviding,
    configuration: RemoteAgentConfiguration = RemoteAgentConfiguration(
      contextWindowTokens: 32_768),
    state: RemoteAgentState = RemoteAgentState(),
    stateDidChange: @escaping () -> Void = {},
    timeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    executor: @escaping RemoteAgent.ToolExecutor = { call, _, completion in
      completion(RemoteToolExecutionResult(content: "ok", subtitle: call.name))
      return nil
    }
  ) -> RemoteAgent {
    RemoteAgent(
      provider: provider, systemPrompt: "System", tools: [Self.readTool],
      configuration: configuration, state: state, stateDidChange: stateDidChange,
      timeProvider: timeProvider,
      toolExecutor: executor)
  }

  private static let readTool = RemoteFunctionTool(
    name: "read", description: "Read a file.",
    parameters: .object([
      "type": .string("object"),
      "properties": .object([
        "path": .object(["type": .string("string")])
      ]),
    ]))
}

final class RemoteTranscriptCodecTests: XCTestCase {
  func testRoundTripRetainsNeutralContentBlocks() throws {
    let identity = RemoteModelIdentity(
      provider: RemoteProvider.openRouter.rawValue, model: "test-model")
    let transcript = RemoteContext.entriesByPrependingCheckpoint(
      "Earlier work completed.",
      to: [
        .user("current request"),
        .assistant(
          "current answer",
          thinking: RemoteThinking(text: "private reasoning", signature: "opaque-signature"),
          source: identity),
        RemoteTranscriptEntry(
          role: .assistant, content: [.text("provider answer")], source: identity,
          providerOutputItems: [
            .object([
              "type": .string("message"), "id": .string("msg_123"),
              "status": .string("completed"), "phase": .string("final_answer"),
            ])
          ]),
      ])
    let restored = try RemoteTranscriptCodec.decode(RemoteTranscriptCodec.encode(transcript))

    XCTAssertEqual(restored, transcript)
    XCTAssertTrue(restored[0].text?.contains("CONTEXT CHECKPOINT") == true)
    XCTAssertEqual(restored[1].source, identity)
    XCTAssertEqual(restored[1].thinking.first?.signature, "opaque-signature")
    XCTAssertEqual(restored[2].providerOutputItems, transcript[2].providerOutputItems)
  }
}

private final class FakeRequest: RemoteRequestCancellable {
  private(set) var isCancelled = false
  func cancel() { isCancelled = true }
}

private final class RecordingProvider: RemoteChatProviding {
  struct Request {
    var messages: [RemoteTranscriptEntry]
    var tools: [RemoteFunctionTool]
  }

  let modelIdentity: RemoteModelIdentity
  var requests = [Request]()
  private let response:
    (Request, Int, (RemoteStreamProgress) -> Void) -> Result<RemoteCompletion, RemoteChatError>

  init(
    modelIdentity: RemoteModelIdentity = RemoteModelIdentity(
      provider: "test", model: "test-model"),
    response: @escaping (Request, Int) -> Result<RemoteCompletion, RemoteChatError>
  ) {
    self.modelIdentity = modelIdentity
    self.response = { request, index, _ in response(request, index) }
  }

  init(
    modelIdentity: RemoteModelIdentity = RemoteModelIdentity(
      provider: "test", model: "test-model"),
    streamingResponse: @escaping (
      Request, Int, (RemoteStreamProgress) -> Void
    ) -> Result<RemoteCompletion, RemoteChatError>
  ) {
    self.modelIdentity = modelIdentity
    response = streamingResponse
  }

  func streamChat(
    messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
    progress: @escaping (RemoteStreamProgress) -> Void,
    completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
  ) -> RemoteRequestCancellable {
    let request = Request(messages: messages, tools: tools)
    let index = requests.count
    requests.append(request)
    completion(response(request, index, progress))
    return FakeRequest()
  }
}
