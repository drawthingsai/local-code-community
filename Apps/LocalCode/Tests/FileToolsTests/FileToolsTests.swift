import BashToolContext
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@Suite("File tools")
struct FileToolsTests {
  @Test func canonicalQwenReadCallParsesAndReadsFile() async throws {
    let fixture = try Fixture()
    var parser = Qwen3_5ToolCallParser()
    let result = parser.append(
      """
      <tool_call>
      <function=read>
      <parameter=path>
      file.txt
      </parameter>
      <parameter=whole>
      true
      </parameter>
      <parameter=raw>
      true
      </parameter>
      </function>
      </tool_call>
      """)
    let request = try #require(result.toolCalls.first?.request)
    let tool = try #require(
      ReadTool.parse(
        request, projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path))

    #expect(tool.path == "file.txt")
    #expect(await invoke(tool) == "before\ntarget\nafter\n")
  }

  @Test func qwenRemovesExactlyOneBoundaryLineBreak() throws {
    var parser = Qwen3_5ToolCallParser()
    let result = parser.append(
      """
      <tool_call>
      <function=edit>
      <parameter=new>

      first
      last

      </parameter>
      </function>
      </tool_call>
      """)

    #expect(result.toolCalls.first?.request.parameters["new"]?.value == "\nfirst\nlast\n")
  }

  @Test func deepSeek4DoesNotRemoveBoundaryLineBreaks() throws {
    var parser = DeepSeek4ToolCallParser(format: .init(version: .deepseek_4_flash))
    let result = parser.append(
      """
      <｜DSML｜tool_calls>
      <｜DSML｜invoke name="edit">
      <｜DSML｜parameter name="new" string="true">
      replacement
      </｜DSML｜parameter>
      </｜DSML｜invoke>
      </｜DSML｜tool_calls>
      """)

    #expect(result.toolCalls.first?.request.parameters["new"]?.value == "\nreplacement\n")
  }

  @Test func canonicalTaggedEditDoesNotAddBlankLinesForQwenAndDeepSeek4() async throws {
    for request in try await taggedEditRequests(replacement: "replacement") {
      let fixture = try Fixture()
      let tool = try #require(
        EditTool.parse(
          request, projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path))

      #expect(await invoke(tool) == "Edited file.txt lines 2-2")
      #expect(
        try String(contentsOf: fixture.fileURL, encoding: .utf8) == "before\nreplacement\nafter\n")
    }
  }

  @Test func emptyTaggedReplacementKeepsTheSelectedLineBlank() async throws {
    for request in try await taggedEditRequests(replacement: "") {
      let fixture = try Fixture()
      let tool = try #require(
        EditTool.parse(
          request, projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path))

      #expect(await invoke(tool) == "Edited file.txt lines 2-2")
      #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8) == "before\n\nafter\n")
    }
  }

  @Test func oldNewReplacementIncludingNewlineDeletesPhysicalLine() async throws {
    let fixture = try Fixture()
    let tool = EditTool(
      path: "file.txt", line: nil, tag: nil, lines: nil, old: "target\n", new: "",
      projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)

    #expect(await invoke(tool) == "Edited file.txt using old/new replacement")
    #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8) == "before\nafter\n")
  }

  @Test func listIncludesHiddenEntries() async throws {
    let fixture = try Fixture()
    try Data().write(to: fixture.rootURL.appendingPathComponent(".hidden-file"))
    try FileManager.default.createDirectory(
      at: fixture.rootURL.appendingPathComponent(".hidden-directory"),
      withIntermediateDirectories: false)
    let tool = ListTool(
      path: ".", projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)

    #expect(await invoke(tool) == ".hidden-directory/\n.hidden-file\nfile.txt")
  }

  @Test func allFileToolsUseLiveGrantsAndRejectRevokedPaths() async throws {
    let project = try Fixture()
    let external = try Fixture()
    let grants = Grants()
    let provider = { grants.urls }
    let read = ReadTool(
      path: external.fileURL.path, startLine: 1, maxLines: 1, whole: false, raw: true,
      projectPath: project.rootURL.path, workspacePath: project.rootURL.path)
    let more = MoreTool(
      count: 1, projectPath: project.rootURL.path, workspacePath: project.rootURL.path)
    let write = WriteTool(
      path: external.rootURL.appendingPathComponent("created.txt").path,
      content: "written", projectPath: project.rootURL.path, workspacePath: project.rootURL.path)
    let edit = EditTool(
      path: external.fileURL.path, line: nil, tag: nil, lines: nil, old: "target", new: "changed",
      projectPath: project.rootURL.path, workspacePath: project.rootURL.path)
    let list = ListTool(
      path: external.rootURL.path, projectPath: project.rootURL.path,
      workspacePath: project.rootURL.path)
    let search = try #require(
      SearchTool.parse(
        ToolCall.Request(
          function: "search",
          parameters: [
            "path": .init(string: true, value: external.rootURL.path),
            "query": .init(string: true, value: "changed"),
          ]), projectPath: project.rootURL.path, workspacePath: project.rootURL.path))

    #expect(
      await response {
        read.invoke(context: BashToolContext(permittedDirectoryURLs: provider), completion: $0)
      }
      .hasPrefix("Error:"))
    grants.urls = [external.rootURL]
    #expect(
      await response {
        read.invoke(context: BashToolContext(permittedDirectoryURLs: provider), completion: $0)
      }
      .hasPrefix("before\n[Read truncated"))
    #expect(
      await response {
        more.invoke(context: BashToolContext(permittedDirectoryURLs: provider), completion: $0)
      }
      .hasPrefix("target\n[Read truncated"))
    #expect(
      await response { write.invoke(permittedDirectoryURLs: provider, completion: $0) }
        .hasPrefix("Wrote "))
    #expect(try String(contentsOfFile: write.path, encoding: .utf8) == "written")
    #expect(
      await response { edit.invoke(permittedDirectoryURLs: provider, completion: $0) }
        .hasPrefix("Edited "))
    #expect(try String(contentsOf: external.fileURL, encoding: .utf8) == "before\nchanged\nafter\n")
    #expect(
      await response { list.invoke(permittedDirectoryURLs: provider, completion: $0) }
        == "created.txt\nfile.txt")
    let matches = await response { search.invoke(permittedDirectoryURLs: provider, completion: $0) }
    #expect(matches.hasPrefix(external.fileURL.path + ":\n"))
    #expect(matches.contains("> changed"))

    grants.urls = []
    let denied = await [
      response {
        read.invoke(context: BashToolContext(permittedDirectoryURLs: provider), completion: $0)
      },
      response {
        more.invoke(context: BashToolContext(permittedDirectoryURLs: provider), completion: $0)
      },
      response { write.invoke(permittedDirectoryURLs: provider, completion: $0) },
      response { edit.invoke(permittedDirectoryURLs: provider, completion: $0) },
      response { list.invoke(permittedDirectoryURLs: provider, completion: $0) },
      response { search.invoke(permittedDirectoryURLs: provider, completion: $0) },
    ]
    for result in denied {
      #expect(result.hasPrefix("Error:"))
      #expect(result.contains("permit"))
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: project.rootURL.path) == ["file.txt"])
    #expect(try String(contentsOfFile: write.path, encoding: .utf8) == "written")
  }

  @Test func pdfReadKeepsTagsAndMoreUsesTheSameMarkdown() async throws {
    let fixture = try Fixture()
    try writePDF(to: fixture.rootURL.appendingPathComponent("document.pdf"))
    var read = ReadTool(
      path: "document.pdf", startLine: 1, maxLines: 2, whole: true, raw: false,
      projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)
    let whole = await invoke(read)
    #expect(whole.contains("extracted PDF Markdown"))
    #expect(whole.contains("<!-- Page 1 -->"))
    #expect(whole.contains("<!-- Page 2 -->"))
    #expect(whole.contains("Alpha"))
    #expect(whole.contains("Beta"))
    let expected = Array(whole.components(separatedBy: "\n").dropFirst())
    #expect(
      expected.allSatisfy {
        $0.range(of: #"^\d+:[0-9A-Za-z_-]{4}> "#, options: .regularExpression) != nil
      })
    read.whole = false
    var part = await invoke(read)
    var lines = Array(part.components(separatedBy: "\n").dropFirst())
    let more = MoreTool(
      count: 2, projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)
    for _ in 0..<100 where part.contains("continue_offset=") {
      part = await response { more.invoke(completion: $0) }
      lines += part.components(separatedBy: "\n").dropFirst()
    }
    #expect(lines == expected)
    read.whole = true
    read.raw = true
    let raw = await invoke(read)
    #expect(raw.hasPrefix("<!-- Page 1 -->"))
    #expect(!raw.contains("continue_offset="))
    let edit = EditTool(
      path: read.path, line: nil, tag: nil, lines: nil, old: "Alpha", new: "Changed",
      projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)
    #expect(await invoke(edit).contains("Save it to a Markdown file"))
  }

  @Test func pdfPasswordRetriesAndMoreDoesNotAskAgain() async throws {
    let fixture = try Fixture()
    let url = fixture.rootURL.appendingPathComponent("protected.pdf")
    try writePDF(to: url, password: "secret")
    let read = ReadTool(
      path: url.path, startLine: 1, maxLines: 1, whole: false, raw: false,
      projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)
    var attempts = [Bool]()
    let context = BashToolContext(requestPDFPassword: { _, incorrect, _, reply in
      attempts.append(incorrect)
      DispatchQueue.global().async { reply(incorrect ? "secret" : "wrong") }
    })
    let first = await response { read.invoke(context: context, completion: $0) }
    #expect(first.contains("<!-- Page 1 -->"))
    #expect(attempts == [false, true])
    let more = MoreTool(
      count: 500, projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)
    let remaining = await response { more.invoke(completion: $0) }
    #expect(remaining.contains("Beta"))
    #expect(attempts == [false, true])
    #expect(try #require(PDFDocument(url: url)).isLocked)
    let cancelled = await response {
      read.invoke(
        context: BashToolContext(requestPDFPassword: { _, _, _, reply in reply(nil) }),
        completion: $0)
    }
    #expect(cancelled.contains("cancelled"))
    #expect(await invoke(read).contains("requires a password"))
  }

  @Test func pdfContinuationChecksSourceAndPermissions() async throws {
    let project = try Fixture()
    let external = try Fixture()
    let url = external.rootURL.appendingPathComponent("document.pdf")
    try writePDF(to: url)
    let grants = Grants()
    grants.urls = [external.rootURL]
    let context = BashToolContext(permittedDirectoryURLs: { grants.urls })
    let read = ReadTool(
      path: url.path, startLine: 1, maxLines: 1, whole: false, raw: false,
      projectPath: project.rootURL.path, workspacePath: project.rootURL.path)
    #expect(await response { read.invoke(context: context, completion: $0) }.contains("Page 1"))
    let more = MoreTool(
      count: 500, projectPath: project.rootURL.path, workspacePath: project.rootURL.path)
    grants.urls = []
    #expect(await response { more.invoke(context: context, completion: $0) }.contains("permit"))
    grants.urls = [external.rootURL]
    try writePDF(to: url, text: "Updated")
    let updated = await response { more.invoke(context: context, completion: $0) }
    #expect(updated.contains("Updated"))
    #expect(!updated.contains("Alpha"))
  }

  @Test func pdfBlankPageIsExplicit() async throws {
    let fixture = try Fixture()
    try writePDF(to: fixture.rootURL.appendingPathComponent("blank.pdf"), text: "")
    let read = ReadTool(
      path: "blank.pdf", startLine: 1, maxLines: 500, whole: true, raw: true,
      projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path)
    let result = await invoke(read)
    #expect(result.contains("<!-- Page 1 -->"))
    #expect(result.contains("OCR or visual inspection"))
  }

  private func writePDF(to url: URL, text: String = "Alpha", password: String? = nil) throws {
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    for text in [text, "Beta"] {
      context.beginPDFPage(nil)
      context.textPosition = CGPoint(x: 40, y: 300)
      let attributed = NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
            "Helvetica" as CFString, 14, nil)
        ])
      CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
      context.endPDFPage()
    }
    context.closePDF()
    if let password {
      let document = try #require(PDFDocument(url: url))
      #expect(
        document.write(
          to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: "owner"]))
    }
  }

  private func response(_ invoke: (@escaping (String) -> Void) -> Void) async -> String {
    await withCheckedContinuation { continuation in
      invoke { continuation.resume(returning: $0) }
    }
  }

  private final class Grants: @unchecked Sendable {
    private let lock = NSLock()
    private var value = [URL]()
    var urls: [URL] {
      get {
        lock.lock()
        defer { lock.unlock() }
        return value
      }
      set {
        lock.lock()
        value = newValue
        lock.unlock()
      }
    }
  }

  private func taggedEditRequests(replacement: String) async throws -> [ToolCall.Request] {
    let fixture = try Fixture()
    let readResponse = await invoke(
      ReadTool(
        path: "file.txt", startLine: 1, maxLines: 500, whole: true, raw: false,
        projectPath: fixture.rootURL.path, workspacePath: fixture.rootURL.path))
    let taggedLine = try #require(
      readResponse.split(separator: "\n").first(where: { $0.hasPrefix("2:") }))
    let tag = String(taggedLine.dropFirst(2).prefix(4))

    var qwenParser = Qwen3_5ToolCallParser()
    let qwenResult = qwenParser.append(
      """
      <tool_call>
      <function=edit>
      <parameter=path>
      file.txt
      </parameter>
      <parameter=line>
      2
      </parameter>
      <parameter=tag>
      \(tag)
      </parameter>
      <parameter=new>
      \(replacement)
      </parameter>
      </function>
      </tool_call>
      """)
    let qwenRequest = try #require(qwenResult.toolCalls.first?.request)

    var deepSeekParser = DeepSeek4ToolCallParser(format: .init(version: .deepseek_4_flash))
    let deepSeekResult = deepSeekParser.append(
      """
      <｜DSML｜tool_calls>
      <｜DSML｜invoke name="edit">
      <｜DSML｜parameter name="path" string="true">file.txt</｜DSML｜parameter>
      <｜DSML｜parameter name="line" string="false">2</｜DSML｜parameter>
      <｜DSML｜parameter name="tag" string="true">\(tag)</｜DSML｜parameter>
      <｜DSML｜parameter name="new" string="true">\(replacement)</｜DSML｜parameter>
      </｜DSML｜invoke>
      </｜DSML｜tool_calls>
      """)
    let deepSeekRequest = try #require(deepSeekResult.toolCalls.first?.request)
    return [qwenRequest, deepSeekRequest]
  }

  private func invoke(_ tool: ReadTool) async -> String {
    await withCheckedContinuation { continuation in
      tool.invoke { continuation.resume(returning: $0) }
    }
  }

  private func invoke(_ tool: EditTool) async -> String {
    await withCheckedContinuation { continuation in
      tool.invoke { continuation.resume(returning: $0) }
    }
  }

  private func invoke(_ tool: ListTool) async -> String {
    await withCheckedContinuation { continuation in
      tool.invoke { continuation.resume(returning: $0) }
    }
  }

  private final class Fixture {
    let rootURL: URL
    let fileURL: URL

    init() throws {
      rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "FileToolsTests-\(UUID().uuidString)", isDirectory: true)
      fileURL = rootURL.appendingPathComponent("file.txt")
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      try Data("before\ntarget\nafter\n".utf8).write(to: fileURL)
    }

    deinit {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }
}
