import XCTest

@testable import RemoteAPI

final class RemoteContextTests: XCTestCase {
  func testEightCompletedToolOnlyTurnsProvideCompactionBoundariesAtSixteenK() throws {
    var transcript = [RemoteTranscriptEntry.user("Inspect and finish the task.")]
    for index in 0..<8 {
      let call = Self.call("call-\(index)")
      transcript.append(
        .assistant(
          String(repeating: "tool-turn-\(index) context ", count: 600), toolCalls: [call]))
      transcript.append(Self.result(for: call))
    }
    XCTAssertEqual(
      RemoteContext.atomicBoundaries(transcript),
      [0, 3, 5, 7, 9, 11, 13, 15, 17])

    let state = RemoteAgentState(transcript: transcript, tokenPerByte: 0.083)
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: 16_384, reservedOutputTokens: 4_096)
    let prepared = RemoteContext.preparedContext(
      state: state, systemPrompt: "System", tools: [Self.readTool],
      configuration: configuration)
    XCTAssertGreaterThanOrEqual(
      prepared.estimatedTokens,
      RemoteContext.compactionThresholdTokens(
        contextWindowTokens: 16_384, configuration: configuration))

    let request = RemoteContext.compactionRequest(
      state: state, preparedContext: prepared, systemPrompt: "System",
      tools: [Self.readTool], configuration: configuration, force: false)
    let sourceMessageCount = try XCTUnwrap(request?.sourceMessageCount)
    XCTAssertTrue([3, 5, 7, 9, 11, 13, 15].contains(sourceMessageCount))
    XCTAssertEqual(transcript[sourceMessageCount - 1].role, .toolResult)
  }

  func testIncompleteToolBatchDoesNotOpenLaterCompactionBoundary() {
    let first = Self.call("first")
    let second = Self.call("second")
    let transcript: [RemoteTranscriptEntry] = [
      .user("Start"),
      .assistant(nil, toolCalls: [first, second]),
      Self.result(for: first),
      .assistant("This cannot close an unanswered tool batch."),
      .user("Continue"),
      .assistant("Later answer"),
    ]

    XCTAssertEqual(RemoteContext.atomicBoundaries(transcript), [0, transcript.count])
  }

  func testMultipleToolResultsMayArriveOutOfOrderButOnlyCloseAsACompleteBatch() {
    let first = Self.call("first")
    let second = Self.call("second")
    let open = Self.call("open")
    let transcript: [RemoteTranscriptEntry] = [
      .user("Start"),
      .assistant(nil, toolCalls: [first, second]),
      Self.result(for: second),
      Self.result(for: first),
      .assistant(nil, toolCalls: [open]),
    ]

    XCTAssertEqual(RemoteContext.atomicBoundaries(transcript), [0, 4, transcript.count])
  }

  func testFailedToolResultClosesExactBatch() {
    let call = Self.call("failed")
    let transcript: [RemoteTranscriptEntry] = [
      .user("Start"),
      .assistant(nil, toolCalls: [call]),
      Self.result(for: call, content: "permission denied", isError: true),
      .assistant("Inspect the failure and continue."),
    ]

    XCTAssertEqual(RemoteContext.atomicBoundaries(transcript), [0, 3, 4])
  }

  func testMixedSuccessAndFailureResultsCloseOnlyAsOneCompleteBatch() {
    let successful = Self.call("successful")
    let failed = Self.call("failed")
    let transcript: [RemoteTranscriptEntry] = [
      .user("Start"),
      .assistant(nil, toolCalls: [successful, failed]),
      Self.result(for: failed, content: "permission denied", isError: true),
      Self.result(for: successful),
      .assistant("Inspect both results and continue."),
    ]

    XCTAssertEqual(RemoteContext.atomicBoundaries(transcript), [0, 4, 5])
  }

  func testSoleSettledToolExchangeHasNoInteriorCompactionCandidate() {
    let call = Self.call("failed")
    let state = RemoteAgentState(
      transcript: [
        .user("Start"),
        .assistant(nil, toolCalls: [call]),
        Self.result(for: call, content: "permission denied", isError: true),
      ])
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: 4_096, reservedOutputTokens: 512)
    let prepared = RemoteContext.preparedContext(
      state: state, systemPrompt: "System", tools: [Self.readTool],
      configuration: configuration)

    XCTAssertEqual(RemoteContext.atomicBoundaries(state.transcript), [0, 3])
    XCTAssertNil(
      RemoteContext.compactionRequest(
        state: state, preparedContext: prepared, systemPrompt: "System",
        tools: [Self.readTool], configuration: configuration, force: true))
  }

  func testAppliedCheckpointPreservesFailedToolTailExactly() throws {
    let failedCall = RemoteToolCall(
      id: "failed", name: "read", arguments: #"{"path":"protected.txt"}"#,
      providerMetadata: [
        .object([
          "provider": .string("fixture"),
          "index": .number(1),
        ])
      ])
    let failedAssistant = RemoteTranscriptEntry.assistant(nil, toolCalls: [failedCall])
    let failedResult = Self.result(
      for: failedCall, content: "permission denied", isError: true)
    let rawTail: [RemoteTranscriptEntry] = [
      .user("Current request"),
      failedAssistant,
      failedResult,
    ]
    let state = RemoteAgentState(
      transcript: [
        .user(String(repeating: "old context ", count: 2_000)),
        RemoteTranscriptEntry(
          role: .assistant, content: [.text("Old answer")],
          providerOutputItems: [
            .object([
              "type": .string("message"),
              "content": .array([
                .object([
                  "type": .string("output_text"),
                  "text": .string("raw-provider-output-must-not-be-counted"),
                ])
              ]),
            ])
          ]),
      ] + rawTail,
      tokenPerByte: 0.25)
    let configuration = RemoteAgentConfiguration(
      contextWindowTokens: 16_384, reservedOutputTokens: 4_096)
    let prepared = RemoteContext.preparedContext(
      state: state, systemPrompt: "System", tools: [Self.readTool],
      configuration: configuration)
    var flattenedState = state
    flattenedState.transcript[1].providerOutputItems = nil
    let flattenedPrepared = RemoteContext.preparedContext(
      state: flattenedState, systemPrompt: "System", tools: [Self.readTool],
      configuration: configuration)
    XCTAssertEqual(prepared.encodedBytes, flattenedPrepared.encodedBytes)
    let request = try XCTUnwrap(
      RemoteContext.compactionRequest(
        state: state, preparedContext: prepared, systemPrompt: "System",
        tools: [Self.readTool], configuration: configuration, force: true))
    XCTAssertFalse(
      try XCTUnwrap(request.messages.last?.text).contains(
        "raw-provider-output-must-not-be-counted"))

    let updated = try XCTUnwrap(
      RemoteContext.state(
        byApplying: "## Active Task\nContinue the current request.", request: request,
        to: state, systemPrompt: "System", tools: [Self.readTool],
        configuration: configuration))

    XCTAssertEqual(request.sourceMessageCount, 2)
    XCTAssertEqual(updated.transcript.count, rawTail.count)
    XCTAssertTrue(
      updated.transcript[0].text?.contains("CURRENT USER MESSAGE\nCurrent request") == true)
    XCTAssertEqual(Array(updated.transcript.dropFirst()), Array(rawTail.dropFirst()))
    XCTAssertEqual(updated.transcript.last?.toolResults.first?.isError, true)
  }

  func testMismatchedOrDuplicateToolResultsDoNotCreateBoundary() {
    let first = Self.call("first")
    let second = Self.call("second")
    let duplicateTranscript: [RemoteTranscriptEntry] = [
      .user("Start"),
      .assistant(nil, toolCalls: [first, second]),
      Self.result(for: first),
      Self.result(for: first),
      .assistant("Later answer"),
    ]
    let mismatchedTranscript: [RemoteTranscriptEntry] = [
      .user("Start"),
      .assistant(nil, toolCalls: [first, second]),
      Self.result(for: first),
      .toolResult(
        "result", toolCallID: second.id, toolName: "write", isError: false),
      .assistant("Later answer"),
    ]

    XCTAssertEqual(
      RemoteContext.atomicBoundaries(duplicateTranscript), [0, duplicateTranscript.count])
    XCTAssertEqual(
      RemoteContext.atomicBoundaries(mismatchedTranscript), [0, mismatchedTranscript.count])
  }

  func testNoToolConversationKeepsExistingAssistantBoundaries() {
    let transcript: [RemoteTranscriptEntry] = [
      .user("First"), .assistant("First answer"),
      .user("Second"), .assistant("Second answer"),
    ]

    XCTAssertEqual(RemoteContext.atomicBoundaries(transcript), [0, 2, 4])
  }

  private static func call(_ id: String) -> RemoteToolCall {
    RemoteToolCall(id: id, name: "read", arguments: #"{"path":"file.txt"}"#)
  }

  private static func result(
    for call: RemoteToolCall, content: String = "result", isError: Bool = false
  ) -> RemoteTranscriptEntry {
    .toolResult(
      content, toolCallID: call.id, toolName: call.name, isError: isError)
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
