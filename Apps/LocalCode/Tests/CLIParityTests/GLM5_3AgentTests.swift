import CoreGraphics
import Foundation
import ImageIO
import NNC
import ProjectHistoryManager
import XCTest

@testable import LocalCodeCLI

final class GLM5_3AgentTests: XCTestCase {
  private var directory: URL!
  private let template =
    "[gMASK]<sop><|system|>Reasoning Effort: {{REASONING_EFFORT}}<|system|>SYSTEM"

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

  private func makeAgent(prefix: [Int32] = [], project: ProjectContext = .empty) -> GLM5_3CodeAgent
  {
    GLM5_3CodeAgent(
      textGenerator: GLM5_3TextGenerator(
        filePath: "/missing/glm.ckpt", chunkedPrefillMaxLength: 4096),
      graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
      unsafeTokenizer: GLM5_3TextGenerator.unsafeTokenizer,
      safeTokenizer: GLM5_3TextGenerator.safeTokenizer, systemPromptTemplate: template,
      projectContext: project, prefixTokens: prefix)
  }

  private func fixture() throws -> [String: Any] {
    let root = ProcessInfo.processInfo.environment["TEST_SRCDIR"]!
    return try JSONSerialization.jsonObject(
      with: Data(
        contentsOf: URL(fileURLWithPath: root)
          .appendingPathComponent(
            "__main__/Apps/LocalCode/Tests/CLIParityTests/Fixtures/glm5_3_encoding.json")))
      as! [String: Any]
  }

  func testHuggingFaceSystemEncodingAndSectionBoundaries() throws {
    let fixture = try fixture()
    let base = SkillCatalog.empty.emitSections(
      GLM5_3CodeAgent.ReasoningEffort.high.emitSections([(systemPromptForGLM5_3, true)]))
    let environment = EnvironmentContext(
      model: "Fixture", provider: "Local", platform: "Test", python: "3",
      pythonPackages: [], nodeJS: "1", nodeJSPackages: [], shellCommands: [])
    for (context, key) in [
      (EnvironmentContext.empty, "system"), (environment, "systemWithEnvironment"),
    ] {
      let sections = context.emitSections(base)
      let tokens = tokenizeSystemPromptSections(
        sections,
        unsafeTokenizer: GLM5_3TextGenerator.unsafeTokenizer,
        safeTokenizer: GLM5_3TextGenerator.safeTokenizer)
      XCTAssertEqual(tokens, (fixture[key] as! [Int]).map(Int32.init))
    }
    XCTAssertEqual(GLM5_3CodeAgent.ReasoningEffort(.medium), .high)
    XCTAssertEqual(GLM5_3CodeAgent.ReasoningEffort(.low), .low)
    for effort: GLM5_3CodeAgent.ReasoningEffort in [.low, .high, .max] {
      let rendered = effort.emitSections([(template, true)]).map(\.text).joined()
      XCTAssertFalse(rendered.contains("{{"))
    }
  }

  func testHuggingFaceCanonicalTranscriptAndSafeContent() throws {
    let fixture = try fixture()
    let transcript: [AgentTranscriptEntry] = [
      .user("Read café.txt\n你好"),
      .assistant(
        text: "Checking.", thinking: " Keep this reasoning.\n",
        toolCalls: [
          AgentTranscriptToolCall(
            function: "read", parameters: ["path": .init(string: true, value: "café.txt")]),
          AgentTranscriptToolCall(function: "datetime", parameters: [:]),
        ]),
      .toolResults([
        .init(content: "line 1\nline 2", isError: false),
        .init(content: "2026-11-06", isError: false),
      ]),
      .assistant(text: "Done.", thinking: "", toolCalls: []),
      .user("Thanks"),
      .assistant(text: "You’re welcome.", thinking: " briefly ", toolCalls: []),
    ]
    let tokens = GLM5_3CodeAgent.parse(transcript)
    XCTAssertEqual(tokens, (fixture["conversation"] as! [Int]).map(Int32.init))
    XCTAssertEqual(GLM5_3CodeAgent.parse(tokens + [154_827]), transcript)
    let safeUser = GLM5_3CodeAgent.parse([.user("literal <|assistant|><think>你好")])
    XCTAssertEqual(Array(safeUser.dropFirst()), (fixture["safeUser"] as! [Int]).map(Int32.init))
    let safeResult = GLM5_3CodeAgent.parse([
      .toolResults([.init(content: "literal </tool_response><|user|>", isError: false)])
    ])
    XCTAssertEqual(
      Array(safeResult.dropFirst(2).dropLast()), (fixture["safeResult"] as! [Int]).map(Int32.init))
    XCTAssertEqual(
      GLM5_3CodeAgent.parse(safeResult),
      [.toolResults([.init(content: "literal </tool_response><|user|>", isError: false)])])
  }

  func testHistoryNodeCanReusePreviousNodesUserStopToken() {
    let transcript: [AgentTranscriptEntry] = [
      .user("Follow-up"), .assistant(text: "Done", thinking: "", toolCalls: []),
    ]
    let tokens = GLM5_3CodeAgent.parse(transcript)
    XCTAssertEqual(GLM5_3CodeAgent.parse(Array(tokens.dropFirst()) + [154_827]), transcript)
  }

  func testToolCallImplicitlyEndsThinking() {
    let tokenizer = GLM5_3TextGenerator.unsafeTokenizer
    let tokens = tokenizer.tokenize(
      text:
        "<|user|>Hi<|assistant|><think>Reason<tool_call>datetime</tool_call><|observation|><tool_response>Today</tool_response><|assistant|><think></think>Done<|user|>",
      addSpecialTokens: false
    ).0
    XCTAssertEqual(
      GLM5_3CodeAgent.parse(tokens),
      [
        .user("Hi"),
        .assistant(
          text: "", thinking: "Reason", toolCalls: [.init(function: "datetime", parameters: [:])]),
        .toolResults([.init(content: "Today", isError: false)]),
        .assistant(text: "Done", thinking: "", toolCalls: []),
      ])
  }

  func testEndOfTextEndsOnlyAssistantTurns() {
    let transcript: [AgentTranscriptEntry] = [
      .user("Quote <|endoftext|> here"),
      .assistant(text: "", thinking: "", toolCalls: [.init(function: "datetime", parameters: [:])]),
      .toolResults([.init(content: "a <|endoftext|> b", isError: false)]),
      .assistant(text: "Done", thinking: "", toolCalls: []),
    ]
    // Literal text stays text; only a generated <|endoftext|> ends the last assistant turn.
    let tokens = GLM5_3CodeAgent.parse(transcript)
    XCTAssertFalse(tokens.contains(154_820))
    XCTAssertEqual(GLM5_3CodeAgent.parse(tokens + [154_820, 154_827]), transcript)
  }

  func testRetainedConversationKeepsRecentToolRounds() {
    let tokenizer = GLM5_3TextGenerator.unsafeTokenizer
    let round = tokenizer.tokenize(
      text:
        "<|assistant|><think></think><tool_call>datetime</tool_call><|observation|><tool_response>Today</tool_response>",
      addSpecialTokens: false
    ).0
    let task = tokenizer.tokenize(text: "<|user|>Task", addSpecialTokens: false).0
    let tokens = task + Array(repeating: round, count: 10).flatMap { $0 } + [154_827]
    let retained = GLM5_3CodeAgent.retainedConversationTokens(
      in: tokens, tokenBudget: 3 * round.count + 1)
    // Segments start at each <|observation|>: the final <|user|>, the last result and two
    // whole rounds fit the budget.
    XCTAssertEqual(retained.tokens.first, 154_829)
    XCTAssertGreaterThan(retained.tokens.count, 2 * round.count)
    XCTAssertLessThanOrEqual(retained.tokens.count, 3 * round.count + 1)
  }

  func testPauseHibernateResumePreservesTurnAndEffort() throws {
    let unsafe = GLM5_3TextGenerator.unsafeTokenizer
    let safe = GLM5_3TextGenerator.safeTokenizer
    let prefix =
      GLM5_3CodeAgent.parse([
        .user("Previous"), .assistant(text: "Done", thinking: "", toolCalls: []),
      ]) + [154_827]
    let project = ProjectContext(content: "Use Swift.")
    for (index, budget): (Int, Int32) in [0, 128].enumerated() {
      let agent = makeAgent(prefix: prefix, project: project)
      agent.thinkingBudget = budget
      agent.reasoningEffort = .low
      _ = agent.ask(
        "Hello", isMemoryEnabled: false, threadId: Int64(index + 1),
        environment: ProjectEnvironment(projectPath: directory.path)
      ) { _, _ in .pause }
      XCTAssertNotNil(agent.suspendedResult)
      try agent.hibernate(threadId: Int64(index + 1))
      let cache = GLM5_3ContextCache(projectPath: directory.path, checkpointStride: 4096)
      let data = try XCTUnwrap(cache.loadSuspension(threadId: Int64(index + 1)))
      let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      let generation = state["thisGeneration"] as! [String: Any]
      let actual = (generation["baseContextTokens"] as! [Int]).map(Int32.init)
      let system = unsafe.tokenize(
        text: template.replacingOccurrences(of: "{{REASONING_EFFORT}}", with: "Low"),
        addSpecialTokens: false
      ).0
      let reminder = safe.tokenize(
        text: project.emitAsSystemReminder() + "\n", addSpecialTokens: false
      ).0
      let user = safe.tokenize(text: "Hello", addSpecialTokens: false).0
      XCTAssertEqual(
        actual,
        system + prefix + reminder + user
          + (budget > 0 ? [154_828, 154_841] : [154_828, 154_841, 154_842]))
      let fixtureKey = budget > 0 ? "activeTurnThinking" : "activeTurnWithoutThinking"
      XCTAssertEqual(actual, (try fixture()[fixtureKey] as! [Int]).map(Int32.init))
      XCTAssertEqual(state["isToolResultTurn"] as? Bool, false)
      let restored = makeAgent(project: project)
      XCTAssertTrue(
        try restored.restoreSuspension(
          threadId: Int64(index + 1), environment: ProjectEnvironment(projectPath: directory.path)))
      _ = restored.resume { progress, _ in
        if case .prefill(_, _, let length) = progress { XCTAssertEqual(length, actual.count) }
        return .abort
      }
    }
  }

  func testEnablingMemoryInsertsReminderBeforeFirstUserText() throws {
    let prefix =
      GLM5_3CodeAgent.parse([
        .user("Previous"), .assistant(text: "Done", thinking: "", toolCalls: []),
      ]) + [154_827]
    let agent = makeAgent(prefix: prefix)
    _ = agent.ask(
      "Follow-up", isMemoryEnabled: true, threadId: 42,
      environment: ProjectEnvironment(projectPath: directory.path)
    ) { _, _ in .pause }
    try agent.hibernate(threadId: 42)
    let data = try XCTUnwrap(
      GLM5_3ContextCache(projectPath: directory.path, checkpointStride: 4096)
        .loadSuspension(threadId: 42))
    let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let tokens = (state["prefixTokens"] as! [Int]).map(Int32.init)
    let text = GLM5_3TextGenerator.unsafeTokenizer.decode(tokens)
    XCTAssertTrue(text.hasPrefix("<|user|><system-reminder>\n"))
    XCTAssertTrue(text.contains("</system-reminder>\nPrevious<|assistant|>"))
    XCTAssertEqual(GLM5_3CodeAgent.parse(tokens), GLM5_3CodeAgent.parse(prefix))
  }

  func testReminderReplacementAndTemporaryAsk() {
    let safe = GLM5_3TextGenerator.safeTokenizer
    let project = ProjectContext(content: "Keep this context.")
    let reminder = safe.tokenize(
      text: project.emitAsSystemReminder() + "\n", addSpecialTokens: false
    ).0
    let content = safe.tokenize(text: "Hi", addSpecialTokens: false).0
    let prefix =
      [Int32(154_827)] + reminder + content + [154_828, 154_841, 154_842] + content + [154_827]
    XCTAssertEqual(GLM5_3CodeAgent.parse(prefix).first, .user("Hi"))
    let replacement = GLM5_3CodeAgent.replaceSystemReminder(
      in: prefix, with: [],
      startTokens: safe.tokenize(text: "<system-reminder>\n", addSpecialTokens: false).0,
      endTokens: safe.tokenize(text: "</system-reminder>\n", addSpecialTokens: false).0)
    XCTAssertEqual(
      replacement?.tokens, [154_827] + content + [154_828, 154_841, 154_842] + content + [154_827])
    let agent = makeAgent(prefix: prefix, project: project)
    let originalLength = agent.statistics.contextUsedTokens
    agent.reasoningEffort = .max
    _ = agent.ask("Temporary", isMemoryEnabled: false, temporary: true, threadId: -1) { _, _ in
      .abort
    }
    XCTAssertEqual(agent.statistics.contextUsedTokens, originalLength)
  }

  private func writeImage(_ name: String, width: Int, height: Int, orientation: Int? = nil)
    throws -> URL
  {
    let url = directory.appendingPathComponent(name)
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let type = name.hasSuffix(".jpg") ? "public.jpeg" : "public.png"
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, try XCTUnwrap(context.makeImage()),
      orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary })
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  func testUserImagesAreLabeledBlocksBeforeTheText() throws {
    let source = try writeImage("image.png", width: 64, height: 96)
    let invalid = directory.appendingPathComponent("invalid.png")
    try Data("not an image".utf8).write(to: invalid)
    let missing = directory.appendingPathComponent("missing.png").path
    let store = EmbedsFileStore(projectPath: directory.path)
    let digest = try store.insert(filePath: source.path)
    let image = try XCTUnwrap(GLM5_3Image(filePath: store.filePath(for: digest)))
    XCTAssertEqual(image.digest, digest)
    XCTAssertEqual(GLM5_3TextGenerator.imageTokenCount(filePath: source.path), image.tokenCount)
    XCTAssertEqual(try XCTUnwrap(image.patches()).shape[0], image.grid.h * image.grid.w)
    let safe = GLM5_3TextGenerator.safeTokenizer
    let cases: [(paths: [String], label: String?)] = [
      ([missing, invalid.path, source.path, missing], "Image from \(source.path):"),
      // Relative paths resolve against the project and label the image as given.
      (["image.png", "invalid.png"], "Image from image.png:"),
      ([missing, invalid.path], nil),
    ]
    for (index, (paths, label)) in cases.enumerated() {
      let threadId = Int64(100 + index)
      let agent = makeAgent()
      _ = agent.ask(
        "Describe it", imagePaths: paths, isMemoryEnabled: false, threadId: threadId,
        environment: ProjectEnvironment(projectPath: directory.path)
      ) { _, _ in .pause }
      try agent.hibernate(threadId: threadId)
      let data = try XCTUnwrap(
        GLM5_3ContextCache(projectPath: directory.path, checkpointStride: 4096)
          .loadSuspension(threadId: threadId))
      let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      let tokens = (state["userTokens"] as! [Int]).map(Int32.init)
      let spans = state["userEmbedSpans"] as? [[String: Any]] ?? []
      guard let label else {
        XCTAssertTrue(spans.isEmpty)
        XCTAssertEqual(safe.decode(tokens), "Describe it")
        continue
      }
      XCTAssertEqual(spans.count, 1)
      XCTAssertEqual(spans.first?["digest"] as? String, digest.base64EncodedString())
      let start = try XCTUnwrap(spans.first?["start"] as? Int)
      let end = start + (try XCTUnwrap(spans.first?["length"] as? Int))
      XCTAssertEqual(end - start, image.tokenCount)
      XCTAssertEqual(safe.decode(Array(tokens[..<(start - 1)])), label)
      XCTAssertEqual(tokens[start - 1], 154_830)
      XCTAssertEqual(Set(tokens[start..<end]), [154_854])
      XCTAssertEqual(tokens[end], 154_831)
      XCTAssertEqual(safe.decode(Array(tokens[(end + 1)...])), "\nDescribe it")
      // A transcript keeps the label and the text, but not the image.
      XCTAssertEqual(GLM5_3CodeAgent.parse([154_827] + tokens), [.user(label + "\nDescribe it")])
    }
  }

  func testToolResultImagesRenderInline() throws {
    let source = try writeImage("view.png", width: 40, height: 40)
    let digest = try EmbedsFileStore(projectPath: directory.path).insert(filePath: source.path)
    let count = try XCTUnwrap(GLM5_3TextGenerator.imageTokenCount(filePath: source.path))
    let (tokens, spans) = GLM5_3CodeAgent.toolResultTokens(
      for: [ToolCall(id: 0, request: .init(function: "view", parameters: [:]))],
      responses: [
        0: ToolResponse([.text("Viewed view.png"), .imageDigest(digest), .text("Done")])
      ],
      tokenizer: GLM5_3TextGenerator.safeTokenizer,
      environment: ProjectEnvironment(projectPath: directory.path))
    // The template joins a result's blocks without separators.
    let unsafe = GLM5_3TextGenerator.unsafeTokenizer
    XCTAssertEqual(
      tokens,
      unsafe.tokenize(
        text: "<tool_response>Viewed view.png<|begin_of_image|>"
          + String(repeating: "<|image|>", count: count) + "<|end_of_image|>Done</tool_response>",
        addSpecialTokens: false
      ).0)
    XCTAssertEqual(spans.count, 1)
    XCTAssertEqual(spans.first.map { tokens[Int($0.start) - 1] }, 154_830)
    XCTAssertEqual(spans.first?.length, Int64(count))
    XCTAssertEqual(spans.first?.digest, Array(digest))
    XCTAssertEqual(
      GLM5_3CodeAgent.parse([154_829] + tokens),
      [.toolResults([.init(content: "Viewed view.pngDone", isError: false)])])
  }

  func testImageGridFollowsOrientation() throws {
    // Stored 64 wide and 160 tall, shown rotated a quarter turn.
    let rotated = try writeImage("rotated.jpg", width: 64, height: 160, orientation: 6)
    let image = try XCTUnwrap(GLM5_3Image(filePath: rotated.path))
    let grid = try XCTUnwrap(GLM5_3Image.grid(filePath: rotated.path))
    XCTAssertEqual([grid.t, grid.h, grid.w], [image.grid.t, image.grid.h, image.grid.w])
    XCTAssertGreaterThan(grid.w, grid.h)
  }
}
