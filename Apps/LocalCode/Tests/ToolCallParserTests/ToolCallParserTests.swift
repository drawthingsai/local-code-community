import Foundation
import XCTest

final class ToolCallParserTests: XCTestCase {
  private let toolCallStart = "<｜DSML｜tool_calls>"
  private let toolCallEnd = "</｜DSML｜tool_calls>"

  func testToolCallReasonSurvivesSuspensionEncoding() throws {
    let call = ToolCall(
      id: 1, raw: "tool call", request: .init(function: "read", parameters: [:]),
      response: ToolResponse(text: "file contents"),
      reason: "I'll inspect the implementation. 🔎\nThen check its callers.")
    let restored = try JSONDecoder().decode(
      ToolCall.self, from: JSONEncoder().encode(call))
    XCTAssertEqual(restored.reason, call.reason)
    XCTAssertEqual(restored.id, call.id)
    XCTAssertEqual(restored.raw, call.raw)
    XCTAssertEqual(restored.request.function, call.request.function)
    XCTAssertEqual(restored.response, call.response)
  }

  func testToolCallSuspensionWithoutReasonStillDecodes() throws {
    let data = Data(
      #"{"id":1,"raw":"tool call","request":{"function":"read","parameters":{"path":{"string":true,"value":"file.swift"}}},"response":"file contents"}"#
        .utf8)
    let call = try JSONDecoder().decode(ToolCall.self, from: data)
    XCTAssertNil(call.reason)
    XCTAssertEqual(call.request.function, "read")
    XCTAssertEqual(call.request.parameters["path"]?.value, "file.swift")
    XCTAssertEqual(call.response, ToolResponse(text: "file contents"))
  }

  // Fixture matches encoding.py's V4.1 encode_arguments_to_dsml / tool_calls_template.
  func testDeepSeek41StreamingAndBatchParsing() throws {
    let block = """
      <｜DSML｜ calls>
      <｜DSML｜ invoke name="read">
      <｜DSML｜ parameter name="path" string="true">SKILL.md</｜DSML｜ parameter>
      <｜DSML｜ parameter name="max_lines" string="false">500</｜DSML｜ parameter>
      </｜DSML｜ invoke>
      </｜DSML｜ calls>
      """
    let format = DeepSeek4ToolCallParser.Format(version: .deepseek_4_1_flash)
    for split in block.indices {
      var parser = DeepSeek4ToolCallParser(format: format)
      parser.append("I'll read the skill.\n\n" + block[..<split])
      parser.append(String(block[split...]))
      XCTAssertTrue(parser.didCompleteToolCallBlock)
      let call = try XCTUnwrap(parser.toolCalls.first)
      XCTAssertEqual(call.request.function, "read")
      XCTAssertEqual(call.request.parameters["path"]?.value, "SKILL.md")
      XCTAssertEqual(call.request.parameters["path"]?.string, true)
      XCTAssertEqual(call.request.parameters["max_lines"]?.string, false)
    }
    XCTAssertEqual(
      ToolCallParser.parse(
        block, format: format
      ).count, 1)
    XCTAssertEqual(
      ToolCallParser.removeToolCalls(
        "before" + block + "after",
        toolCallStart: format.toolCallStart, toolCallEnd: format.toolCallEnd), "beforeafter")
    var oldParser = DeepSeek4ToolCallParser(format: .init(version: .deepseek_4_flash))
    oldParser.append(block)
    XCTAssertFalse(oldParser.didCompleteToolCallBlock)
  }

  func testDeepSeek41PartialDelimiterRemainsHidden() {
    let output = "I'll read the skill.\n\n<｜DSML｜ ca"
    let format = DeepSeek4ToolCallParser.Format(version: .deepseek_4_1_flash)
    XCTAssertEqual(
      ToolCallParser.removeToolCalls(
        output, toolCallStart: format.toolCallStart,
        toolCallEnd: format.toolCallEnd), "I'll read the skill.\n\n")
  }

  func testDeepSeek41IncompleteParameterAndEscapedClosingTag() throws {
    var parser = DeepSeek4ToolCallParser(format: .init(version: .deepseek_4_1_flash))
    parser.append(
      """
      <｜DSML｜ calls>
      <｜DSML｜ invoke name="write">
      <｜DSML｜ parameter name="content" string="true">hello</｜DSML｜ par
      """)
    XCTAssertEqual(parser.incompleteToolCall?.request.parameters["content"]?.value, "hello")
    parser.reset()
    parser.append(
      """
      <｜DSML｜ calls>
      <｜DSML｜ invoke name="write">
      <｜DSML｜ parameter name="content" string="true">&lt;/｜DSML｜ parameter></｜DSML｜ parameter>
      </｜DSML｜ invoke>
      </｜DSML｜ calls>
      """)
    XCTAssertTrue(parser.didCompleteToolCallBlock)
    XCTAssertEqual(
      parser.toolCalls.first?.request.parameters["content"]?.value, "</｜DSML｜ parameter>")
  }

  func testDeepSeekRemovesToolCallWithEndDelimiterInParameter() throws {
    let format = DeepSeek4ToolCallParser.Format(version: .deepseek_4_flash)
    let block = """
      <｜DSML｜tool_calls>
      <｜DSML｜invoke name="write">
      <｜DSML｜parameter name="content" string="true">let end = "</｜DSML｜tool_calls>"</｜DSML｜parameter>
      </｜DSML｜invoke>
      </｜DSML｜tool_calls>
      """
    let output = "I'll write the fixture.\n\n" + block + "after"
    let call = try XCTUnwrap(ToolCallParser.parse(output, format: format).first)
    XCTAssertEqual(
      call.request.parameters["content"]?.value, #"let end = "</｜DSML｜tool_calls>""#)
    XCTAssertEqual(
      ToolCallParser.removeToolCalls(output, format: format),
      "I'll write the fixture.\n\nafter")
    XCTAssertEqual(
      ToolCallParser.removeToolCalls("answer<｜DSML｜tool_calls>call", format: format), "answer")
    XCTAssertEqual(ToolCallParser.removeToolCalls("answer</｜DSML｜", format: format), "answer")
  }

  func testRemovesCompleteAndIncompleteToolCalls() {
    XCTAssertEqual(
      removeToolCalls(
        "before<｜DSML｜tool_calls>call</｜DSML｜tool_calls>after"),
      "beforeafter")
    XCTAssertEqual(removeToolCalls("before<｜DSML｜tool_calls>call"), "before")
  }

  func testRemovesTrailingPartialToolCallStart() {
    XCTAssertEqual(removeToolCalls("answer<"), "answer")
    XCTAssertEqual(removeToolCalls("answer<｜DSML｜"), "answer")
    XCTAssertEqual(removeToolCalls("answer<｜DSML｜tool_calls"), "answer")
  }

  func testRemovesTrailingPartialToolCallEnd() {
    XCTAssertEqual(removeToolCalls("answer</"), "answer")
    XCTAssertEqual(removeToolCalls("answer</｜DSML｜"), "answer")
    XCTAssertEqual(removeToolCalls("answer</｜DSML｜tool_calls"), "answer")
  }

  func testPreservesUnmatchedBoundaryText() {
    XCTAssertEqual(removeToolCalls("<div>answer</div>"), "<div>answer</div>")
    XCTAssertEqual(removeToolCalls("answer<tool"), "answer<tool")
    XCTAssertEqual(
      removeToolCalls("answer</｜DSML｜tool_calls>"),
      "answer</｜DSML｜tool_calls>")
    XCTAssertEqual(removeToolCalls("> quoted answer"), "> quoted answer")
    XCTAssertEqual(removeToolCalls("tool_calls>answer"), "tool_calls>answer")
  }

  func testDeepSeekIncompleteToolCallRemovesTrailingPartialParameterEnd() {
    for suffix in ["<", "</", "</｜DSML｜", "</｜DSML｜parameter"] {
      XCTAssertEqual(deepSeekIncompleteParameterValue(suffix: suffix), "echo hello")
    }
  }

  func testDeepSeekIncompleteToolCallPreservesUnmatchedParameterText() {
    XCTAssertEqual(
      deepSeekIncompleteParameterValue(suffix: "<not-parameter-end>"),
      "echo hello<not-parameter-end>")
  }

  func testDeepSeekCompleteToolCallAfterLeadingText() {
    var parser = DeepSeek4ToolCallParser(format: .init(version: .deepseek_4_flash))
    let result = parser.append(
      """
      leading answer
      <｜DSML｜tool_calls>
      <｜DSML｜invoke name="bash">
      <｜DSML｜parameter name="command" string="true">echo hello</｜DSML｜parameter>
      </｜DSML｜invoke>
      </｜DSML｜tool_calls>
      """)

    XCTAssertEqual(result.toolCalls.count, 1)
    XCTAssertEqual(result.toolCalls.first?.request.function, "bash")
    XCTAssertEqual(result.toolCalls.first?.request.parameters["command"]?.value, "echo hello")
    XCTAssertTrue(result.didCompleteToolCallBlock)
  }

  func testDeepSeekStreamedToolCallParametersOnlyGrow() {
    let format = DeepSeek4ToolCallParser.Format(version: .deepseek_4_flash)
    assertStreamedParametersOnlyGrow(
      """
      <｜DSML｜tool_calls>
      <｜DSML｜invoke name="read">
      <｜DSML｜parameter name="path" string="true">src/main.ts</｜DSML｜parameter>
      <｜DSML｜parameter name="max_lines" string="false">500</｜DSML｜parameter>
      </｜DSML｜invoke>
      </｜DSML｜tool_calls>
      """, values: ["path": "src/main.ts", "max_lines": "500"]
    ) { prefix in
      var parser = DeepSeek4ToolCallParser(format: format)
      parser.append(prefix)
      return (parser.toolCalls.first ?? parser.incompleteToolCall)?.request.parameters ?? [:]
    }
  }

  func testQwenStreamedToolCallParametersOnlyGrow() {
    assertStreamedParametersOnlyGrow(
      """
      <tool_call>
      <function=read>
      <parameter=path>
      src/main.ts
      </parameter>
      <parameter=max_lines>
      500
      </parameter>
      </function>
      </tool_call>
      """, values: ["path": "src/main.ts", "max_lines": "500"]
    ) { prefix in
      var parser = Qwen3_5ToolCallParser()
      parser.append(prefix)
      return (parser.toolCalls.first ?? parser.incompleteToolCall)?.request.parameters ?? [:]
    }
    assertStreamedParametersOnlyGrow(
      """
      <tool_call>
      <function=bash>
      <parameter=command>
      ls -la
      </parameter>
      <parameter=timeout_sec>
      30
      </parameter>
      </function>
      </tool_call>
      """, values: ["command": "ls -la", "timeout_sec": "30"]
    ) { prefix in
      var parser = Qwen3_5ToolCallParser()
      parser.append(prefix)
      return (parser.toolCalls.first ?? parser.incompleteToolCall)?.request.parameters ?? [:]
    }
  }

  // The chat renders a streaming tool call only while it validates, so a parameter that empties,
  // picks up closing-tag text, or drops out removes the line until its value settles.
  private func assertStreamedParametersOnlyGrow(
    _ block: String, values: [String: String],
    parameters: (String) -> [String: ToolCall.Request.Parameter],
    file: StaticString = #filePath, line: UInt = #line
  ) {
    var previousNames = Set<String>()
    for split in block.indices {
      let prefix = String(block[..<split])
      let streamed = parameters(prefix)
      for (name, parameter) in streamed {
        XCTAssertFalse(
          parameter.value.isEmpty, "\(name) is empty after \(prefix.debugDescription)",
          file: file, line: line)
        XCTAssertTrue(
          values[name]?.hasPrefix(parameter.value) == true,
          "\(name) is \(parameter.value.debugDescription) after \(prefix.debugDescription)",
          file: file, line: line)
      }
      XCTAssertTrue(
        previousNames.isSubset(of: streamed.keys),
        "parameters dropped after \(prefix.debugDescription)", file: file, line: line)
      previousNames = Set(streamed.keys)
    }
  }

  private func removeToolCalls(_ string: String) -> String {
    ToolCallParser.removeToolCalls(
      string, toolCallStart: toolCallStart, toolCallEnd: toolCallEnd)
  }

  private func deepSeekIncompleteParameterValue(suffix: String) -> String? {
    var parser = DeepSeek4ToolCallParser(format: .init(version: .deepseek_4_flash))
    let result = parser.append(
      """
      <｜DSML｜tool_calls>
      <｜DSML｜invoke name="bash">
      <｜DSML｜parameter name="command" string="true">echo hello\(suffix)
      """)
    return result.incompleteToolCall?.request.parameters["command"]?.value
  }
}
