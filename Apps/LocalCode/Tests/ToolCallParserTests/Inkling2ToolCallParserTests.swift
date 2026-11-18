import XCTest

final class Inkling2ToolCallParserTests: XCTestCase {
  func testEveryStreamingSplitKeepsTextAndCalls() throws {
    let call =
      "<|message_model|>write<|content_invoke_tool_json|>{\"name\":\"write\",\"args\":{\"content\":\"raw\\n<|message_model|>x\",\"path\":\"a.txt\",\"whole\":true,\"max_lines\":5}}<|end_message|>"
    let text =
      "<|message_model|><|content_text|>Before<|end_message|>" + call
      + "<|message_model|><|content_thinking|>hidden<|end_message|>"
      + "<|message_model|>datetime<|content_invoke_tool_json|>{\"name\":\"datetime\",\"args\":{}}<|end_message|>"
      + "<|message_model|><|content_text|> after<|end_message|>"
    for split in text.indices {
      var parser = Inkling2ToolCallParser()
      parser.append(String(text[..<split]))
      parser.append(String(text[split...]))
      parser.finish()
      XCTAssertEqual(parser.text, "Before after")
      XCTAssertEqual(parser.toolCalls.map(\.request.function), ["write", "datetime"])
      let parameters = try XCTUnwrap(parser.toolCalls.first?.request.parameters)
      XCTAssertEqual(parameters["content"]?.value, "raw\n<|message_model|>x")
      XCTAssertEqual(parameters["content"]?.string, true)
      XCTAssertEqual(parameters["path"]?.value, "a.txt")
      XCTAssertEqual(parameters["whole"]?.value, "true")
      XCTAssertEqual(parameters["whole"]?.string, false)
      XCTAssertEqual(parameters["max_lines"]?.value, "5")
      XCTAssertEqual(parser.toolCalls.map(\.id), [0, 1])
      XCTAssertEqual(parser.toolCalls.first?.raw, call)
      XCTAssertFalse(parser.hasIncompleteToolCall)
    }
  }

  func testIncompleteCallShowsArgumentsSoFar() {
    var parser = Inkling2ToolCallParser()
    for character
      in "<|message_model|>edit<|content_invoke_tool_json|>{\"name\":\"edit\",\"args\":{\"path\":\"a.txt\",\"new\":\"hel"
    {
      parser.append(String(character))
    }
    XCTAssertTrue(parser.hasIncompleteToolCall)
    XCTAssertEqual(parser.incompleteToolCall?.request.function, "edit")
    XCTAssertEqual(parser.incompleteToolCall?.request.parameters["path"]?.value, "a.txt")
    XCTAssertEqual(parser.incompleteToolCall?.request.parameters["new"]?.value, "hel")
    parser.append("lo\"}}<|end_message|>")
    XCTAssertEqual(parser.toolCalls.first?.request.parameters["new"]?.value, "hello")
    XCTAssertFalse(parser.hasIncompleteToolCall)
    XCTAssertNil(parser.incompleteToolCall)
    XCTAssertEqual(parser.text, "")
  }

  func testNamesAndMalformedCalls() {
    var parser = Inkling2ToolCallParser()
    parser.append(
      // The body's name wins; a header names a call whose body has none.
      "<|message_model|>bash<|content_invoke_tool_json|>{\"name\":\"read\",\"args\":{}}<|end_message|>"
        + "<|message_model|>list<|content_invoke_tool_json|>{\"args\":{\"path\":\".\"}}<|end_message|>"
        // Malformed bodies and names are not calls.
        + "<|message_model|>read<|content_invoke_tool_json|>{\"name\":\"read\",\"args\":<|end_message|>"
        + "<|message_model|>a<b<|content_invoke_tool_json|>{\"args\":{}}<|end_message|>"
        + "<|message_model|>read<|content_invoke_tool_json|>{\"name\":\"read\",\"args\":[]}<|end_message|>"
        + "<|content_invoke_tool_json|>{\"name\":\"datetime\",\"args\":{}}<|end_message|>")
    parser.finish()
    XCTAssertEqual(parser.toolCalls.map(\.request.function), ["read", "list", "datetime"])
    XCTAssertEqual(parser.toolCalls[1].request.parameters["path"]?.value, ".")
    XCTAssertEqual(parser.text, "")
  }

  func testTextOutsideMessagesAndHeadersWithoutContent() {
    var parser = Inkling2ToolCallParser()
    parser.append("Plain <|unknown|> text<|message_model|>Hello")
    XCTAssertEqual(parser.text, "Plain <|unknown|> text")
    parser.append(" there")
    parser.finish()
    XCTAssertEqual(parser.text, "Plain <|unknown|> textHello there")
    var partial = Inkling2ToolCallParser()
    partial.append("<|message_model|><|content_text|>Done<|end_mess")
    XCTAssertEqual(partial.text, "Done")
    partial.finish()
    XCTAssertEqual(partial.text, "Done<|end_mess")
  }

  func testJSONMatchesPythonCompactSortedDumps() throws {
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(
        with: Data(
          #"{"b":[1,2.5,true,null,"x"],"a":"é/\"\\\n\u0001","c":{"z":1.0,"y":{}}}"#.utf8))
        as? [String: Any])
    XCTAssertEqual(
      Inkling2ToolCallParser.json(object),
      #"{"a":"é/\"\\\n\u0001","b":[1,2.5,true,null,"x"],"c":{"y":{},"z":1.0}}"#)
  }
}
