import XCTest

final class GLM5_3ToolCallParserTests: XCTestCase {
  func testEveryStreamingSplitAndMultipleCalls() throws {
    let call =
      "<tool_call> write \n<arg_key> path </arg_key> \n<arg_value>a.txt</arg_value>\n<arg_key>content</arg_key><arg_value> raw\n<tool_call>example\n </arg_value> </tool_call>"
    let text = "Before" + call + "between<tool_call>datetime</tool_call>after"
    for split in text.indices {
      var parser = GLM5_3ToolCallParser()
      parser.append(String(text[..<split]))
      parser.append(String(text[split...]))
      XCTAssertEqual(parser.toolCalls.map(\.request.function), ["write", "datetime"])
      XCTAssertEqual(
        parser.toolCalls.first?.request.parameters["content"]?.value, " raw\n<tool_call>example\n ")
      XCTAssertEqual(parser.toolCalls.first?.request.parameters["path"]?.value, "a.txt")
      XCTAssertEqual(parser.toolCalls.map(\.id), [0, 1])
      XCTAssertFalse(parser.hasIncompleteToolCall)
    }
    XCTAssertEqual(GLM5_3ToolCallParser.removeToolCalls(text), "Beforebetweenafter")
  }

  func testIncompleteValueAndPartialDelimiters() {
    var parser = GLM5_3ToolCallParser()
    for char in "<tool_call>edit<arg_key>new</arg_key><arg_value>hello</arg_val" {
      parser.append(String(char))
    }
    XCTAssertTrue(parser.hasIncompleteToolCall)
    XCTAssertEqual(parser.incompleteToolCall?.request.function, "edit")
    XCTAssertEqual(parser.incompleteToolCall?.request.parameters["new"]?.value, "hello")
    parser.append("ue></tool_call>")
    XCTAssertEqual(parser.toolCalls.count, 1)
    XCTAssertFalse(parser.hasIncompleteToolCall)
    XCTAssertEqual(GLM5_3ToolCallParser.removeToolCalls("answer<tool_ca"), "answer")
  }

  func testMalformedCallEndsWithoutConsumingNextCall() {
    for malformed in [
      "<tool_call>read<arg_key>path</tool_call>",
      "<tool_call>read<arg_key>path</arg_key><arg_value>missing end</tool_call>",
      "<tool_call><arg_key>path</arg_key><arg_value>x</arg_value></tool_call>",
    ] {
      var parser = GLM5_3ToolCallParser()
      for char in malformed + "<tool_call>datetime</tool_call>" { parser.append(String(char)) }
      XCTAssertEqual(parser.toolCalls.map(\.request.function), ["datetime"])
      XCTAssertFalse(parser.hasIncompleteToolCall)
    }
  }
}
