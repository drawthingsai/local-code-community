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

  func testIncompleteCallLeavesOutWhatCannotBeReadYet() {
    func incomplete(_ body: String, header: String = "write") -> ToolCall.Request? {
      var parser = Inkling2ToolCallParser()
      parser.append("<|message_model|>" + header + "<|content_invoke_tool_json|>" + body)
      XCTAssertTrue(parser.hasIncompleteToolCall)
      return parser.incompleteToolCall?.request
    }
    // A key shows once its value has started.
    for body in [
      #"{"name":"write","args":{"path":"a.txt","#, #"{"name":"write","args":{"path":"a.txt","cont"#,
      #"{"name":"write","args":{"path":"a.txt","content""#,
      #"{"name":"write","args":{"path":"a.txt","content":"#,
      #"{"name":"write","args":{"path":"a.txt","content":""#,
      #"{"name":"write","args":{"path":"a.txt","whole":tr"#,
      #"{"name":"write","args":{"path":"a.txt","max_lines":-"#,
    ] {
      XCTAssertEqual(incomplete(body)?.parameters.mapValues(\.value), ["path": "a.txt"], body)
    }
    // An escape sequence shows once whole, and a surrogate pair once both halves are.
    for (body, content) in [
      (#"{"name":"write","args":{"content":"a\"#, "a"),
      (#"{"name":"write","args":{"content":"a\n\u00e"#, "a\n"),
      (#"{"name":"write","args":{"content":"a\ud83d"#, "a"),
      (#"{"name":"write","args":{"content":"a\ud83d\ude0"#, "a"),
      (#"{"name":"write","args":{"content":"a\ud83d\ude00"#, "a😀"),
      (#"{"name":"write","args":{"content":"a\\"#, "a\\"),
    ] {
      XCTAssertEqual(incomplete(body)?.parameters["content"]?.value, content, body)
    }
    // A number reads up to its last digit, and other values once whole.
    let scalars = incomplete(#"{"name":"read","args":{"whole":true,"offset":null,"max_lines":12."#)
    XCTAssertEqual(
      scalars?.parameters.mapValues(\.value),
      ["whole": "true", "max_lines": "12", "offset": "null"])
    XCTAssertEqual(scalars?.parameters["max_lines"]?.string, false)
    // Arguments stay while the name follows them, or a marker starts after the body.
    for body in [
      #"{"args":{"path":"a.txt"},"na"#, #"{"args":{"path":"a.txt"},"name":"wri"#,
      #"{"name":"write","args":{"path":"a.txt"}}<|end_mess"#,
    ] {
      XCTAssertEqual(incomplete(body)?.parameters.mapValues(\.value), ["path": "a.txt"], body)
    }
    // Without a header, the body's name counts once whole.
    XCTAssertNil(incomplete(#"{"name":"bash"#, header: ""))
    XCTAssertEqual(
      incomplete(#"{"name":"bash_wait","args":{"job":2"#, header: "")?.function, "bash_wait")
  }

  func testNamesAndMalformedCalls() {
    var parser = Inkling2ToolCallParser()
    parser.append(
      // The header's name wins over the body's, as Inkling 2 Mini has written them apart; either
      // names a call that lacks the other.
      "<|message_model|>bash_wait<|content_invoke_tool_json|>{\"name\":\"bash\",\"args\":{\"job\":2}}<|end_message|>"
        + "<|message_model|>list<|content_invoke_tool_json|>{\"args\":{\"path\":\".\"}}<|end_message|>"
        // Malformed bodies and names are not calls.
        + "<|message_model|>read<|content_invoke_tool_json|>{\"name\":\"read\",\"args\":<|end_message|>"
        + "<|message_model|>a<b<|content_invoke_tool_json|>{\"args\":{}}<|end_message|>"
        + "<|message_model|>read<|content_invoke_tool_json|>{\"name\":\"read\",\"args\":[]}<|end_message|>"
        + "<|content_invoke_tool_json|>{\"name\":\"datetime\",\"args\":{}}<|end_message|>")
    parser.finish()
    XCTAssertEqual(parser.toolCalls.map(\.request.function), ["bash_wait", "list", "datetime"])
    XCTAssertEqual(parser.toolCalls[0].request.parameters["job"]?.value, "2")
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
