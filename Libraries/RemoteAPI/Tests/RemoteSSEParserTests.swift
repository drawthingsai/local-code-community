import Foundation
import XCTest

@testable import RemoteAPI

final class RemoteSSEParserTests: XCTestCase {
  func testParsesChunkedCommentsMultilineDataUnicodeAndDone() throws {
    let wire = Data(
      ": keepalive\r\ndata: first\r\ndata: second🙂\r\n\r\ndata: [DONE]\r\n\r\n".utf8)
    var parser = RemoteSSEParser()
    var events = [RemoteSSEParser.Event]()
    for byte in wire {
      events += try parser.append(Data([byte]))
    }
    XCTAssertEqual(events, [.data("first\nsecond🙂"), .done])
  }

  func testAccumulatorCombinesTextUsageAndFragmentedToolCalls() throws {
    var accumulator = OpenAICompatibleStreamAccumulator()
    _ = try accumulator.append(
      #"{"choices":[{"index":0,"delta":{"content":"Checking","reasoning":"Need ","reasoning_details":[{"type":"reasoning.text","text":"Need ","format":"unknown","index":0}],"tool_calls":[{"index":1,"id":"call_","type":"function","function":{"name":"re","arguments":"{\"pa"}},{"index":0,"id":"first","type":"function","function":{"name":"date","arguments":{}}}]}},{"index":1,"delta":{"content":"ignored"}}]}"#
    )
    let progress = try accumulator.append(
      #"{"choices":[{"index":0,"delta":{"reasoning_content":"both.","reasoning_details":[{"type":"reasoning.text","text":"both files.","format":"unknown","index":0}],"tool_calls":[{"index":1,"id":"2","function":{"name":"ad","arguments":"th\":\"a\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":2,"completion_tokens":1,"total_tokens":3}}"#
    )
    XCTAssertEqual(progress?.text, "Checking")
    let thinking = try XCTUnwrap(
      accumulator.completion.content.compactMap { block -> RemoteThinking? in
        guard case .thinking(let thinking) = block else { return nil }
        return thinking
      }.first)
    XCTAssertEqual(thinking.text, "Need both.")
    XCTAssertEqual(
      thinking.providerMetadata,
      [
        .object([
          "type": .string("reasoning.text"),
          "text": .string("Need both files."),
          "id": .null,
          "format": .string("unknown"),
          "index": .number(0),
        ])
      ])
    XCTAssertEqual(progress?.toolCalls.map(\.id), ["first", "call_2"])
    XCTAssertEqual(progress?.toolCalls.map(\.name), ["date", "read"])
    XCTAssertEqual(progress?.toolCalls.map(\.arguments), ["{}", #"{"path":"a"}"#])
    XCTAssertEqual(accumulator.completion.usage?.totalTokens, 3)
    XCTAssertEqual(accumulator.completion.stopReason, "tool_calls")
  }

  func testAccumulatorMergesSignatureOnlyReasoningDelta() throws {
    var accumulator = OpenAICompatibleStreamAccumulator()
    _ = try accumulator.append(
      #"{"choices":[{"index":0,"delta":{"reasoning":"Plan.","reasoning_details":[{"type":"reasoning.text","text":"Plan.","format":"anthropic-claude-v1","index":0}]}}]}"#
    )
    _ = try accumulator.append(
      #"{"choices":[{"index":0,"delta":{"reasoning_details":[{"type":"reasoning.text","signature":"sig","format":"anthropic-claude-v1","index":0}],"tool_calls":[{"index":0,"id":"call","type":"function","function":{"name":"read","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
    )
    let thinking = try XCTUnwrap(
      accumulator.completion.content.compactMap { block -> RemoteThinking? in
        guard case .thinking(let thinking) = block else { return nil }
        return thinking
      }.first)
    XCTAssertEqual(
      thinking.providerMetadata,
      [
        .object([
          "type": .string("reasoning.text"),
          "text": .string("Plan."),
          "signature": .string("sig"),
          "id": .null,
          "format": .string("anthropic-claude-v1"),
          "index": .number(0),
        ])
      ])
    XCTAssertTrue(thinking.providerMetadata?.allSatisfy(\.isValidOpenRouterReasoningDetail) == true)
  }

  func testRejectsOversizedMalformedAndProviderErrorEvents() throws {
    var parser = RemoteSSEParser(maximumEventBytes: 4)
    XCTAssertThrowsError(try parser.append(Data("data: 12345\n\n".utf8))) { error in
      XCTAssertEqual(error as? RemoteChatError, .responseTooLarge(maximumBytes: 4))
    }

    var accumulator = OpenAICompatibleStreamAccumulator()
    XCTAssertThrowsError(try accumulator.append("{not-json"))
    XCTAssertThrowsError(
      try accumulator.append("{\"error\":{\"message\":\"bad\",\"status_code\":429}}")
    ) { error in
      XCTAssertEqual(error as? RemoteChatError, .provider(statusCode: 429, message: "bad"))
    }
    XCTAssertThrowsError(
      try accumulator.append("{\"error\":{\"message\":\"stream failed\"}}")
    ) { error in
      XCTAssertEqual(error as? RemoteChatError, .providerStream("stream failed"))
    }
  }
}
