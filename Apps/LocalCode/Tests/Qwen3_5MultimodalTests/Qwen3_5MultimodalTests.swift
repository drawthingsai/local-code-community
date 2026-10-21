import BashToolContext
import CoreGraphics
import Foundation
import ImageIO
import LLM
import NNC
import PDFKit
import ProjectHistoryManager
import XCTest

import struct LocalCodeCLI.ToolCall

@testable import LocalCodeCLI

final class Qwen3_5MultimodalTests: XCTestCase {
  private let configuration = Qwen3_5ModelConfiguration(
    vocabularySize: 32, hiddenSize: 128, intermediateSize: 256, layers: 2,
    fullAttentionInterval: 2, attentionHeads: 2, keyValueHeads: 1,
    attentionHeadDim: 64, rotaryDim: 64, mropeSection: (11, 11, 10),
    ropeTheta: 10_000, linearNumKeyHeads: 1, linearNumValueHeads: 1,
    linearKeyHeadDim: 64, linearValueHeadDim: 64, linearConvKernel: 4)
  private let vision = Qwen3_5VisionConfiguration.qwen3_5_4B
  private var directory: URL!

  func testMemoryEventsAndFrozenPromptSurviveSuspension() throws {
    let initial = MemoryContext(user: "Known user", memory: "Known memory")
    let external = MemoryContext(user: "External user", memory: "External memory")
    let factories: [(MemoryContext) -> any CodeAgent] = [
      { memory in
        Qwen3_5CodeAgent(
          textGenerator: Qwen3_5TextGenerator(
            filePath: "/missing/model", configuration: .qwen3_5_4B, tieEmbedding: true,
            chunkedPrefillMaxLength: 257),
          graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
          unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
          safeTokenizer: Qwen3_5TextGenerator.safeTokenizer,
          systemPromptTemplate: "You are helpful. {{MEMORY_CONTEXT}}",
          memoryContext: memory,
          prefixTokens: Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
            text: "<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\nHi<|im_end|>\n",
            addSpecialTokens: false
          ).0,
          shouldInjectSystemSeenMemoryContext: true)
      },
      { memory in
        DeepSeek4CodeAgent(
          textGenerator: DeepSeek4_1TextGenerator(
            filePath: "/missing/model", engramFilePath: "/missing/engram"),
          graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
          unsafeTokenizer: DeepSeek4_1TextGenerator.unsafeTokenizer,
          safeTokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
          systemPromptTemplate: "You are helpful.",
          memoryContext: memory,
          prefixTokens: DeepSeek4_1TextGenerator.unsafeTokenizer.tokenize(
            text: "<｜User｜>Hello<｜Assistant｜>Hi<｜end▁of▁sentence｜>",
            addSpecialTokens: false
          ).0,
          shouldInjectSystemSeenMemoryContext: true)
      },
    ]
    let cache = DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 4_096)
    for (modelIndex, factory) in factories.enumerated() {
      for stopAfterRead in [false, true] {
        let agent = factory(initial)
        let threadId = Int64(700 + 2 * modelIndex + (stopAfterRead ? 1 : 0))
        // Temporary reviews and empty aborted turns must leave the snapshot pending.
        for temporary in [true, false, false] {
          let aborted = agent.ask(
            "Hello", imagePaths: [], isMemoryEnabled: true, temporary: temporary,
            allowedTools: nil, threadId: threadId, projectPath: directory.path,
            workspacePath: directory.path, webSearchProvider: .disabled
          ) { _, _ in .abort }
          XCTAssertTrue(aborted.isEmpty)
          XCTAssertEqual(aborted.systemSeenMemoryContext, temporary ? nil : initial)
          XCTAssertEqual(aborted.memoryContext, temporary ? nil : initial)
        }
        _ = agent.ask(
          "Hello", imagePaths: [], isMemoryEnabled: true, temporary: false,
          allowedTools: nil, threadId: threadId, projectPath: directory.path,
          workspacePath: directory.path, webSearchProvider: .disabled
        ) { _, _ in .pause }
        try agent.hibernate(threadId: threadId)
        var saved = try XCTUnwrap(
          JSONSerialization.jsonObject(
            with: XCTUnwrap(cache.loadSuspension(threadId: threadId))) as? [String: Any])
        XCTAssertNotNil(saved["memoryContext"])
        XCTAssertNotNil(saved["systemSeenMemoryContext"])
        XCTAssertNil(saved["systemPromptMemoryContext"])
        // A reconstructed agent may initially load another thread's newer disk contents.
        let restored = factory(external)
        XCTAssertTrue(
          try restored.restoreSuspension(
            threadId: threadId, projectPath: directory.path))
        let result = restored.resume { _, _ in .abort }
        XCTAssertEqual(result.memoryContext, initial)
        XCTAssertEqual(result.systemSeenMemoryContext, initial)

        // A warm turn can reach tools without supplying the system prompt again. Its read
        // records only one target, even when the contents match a previous observation.
        if stopAfterRead {
          saved.removeValue(forKey: "memoryContext")
          saved.removeValue(forKey: "systemSeenMemoryContext")
          saved["stopAfterTools"] = true
        }
        let text = stopAfterRead ? "Known memory" : "Newly observed memory"
        let response = ToolResponse(
          text: text, memory: MemorySnapshot(target: "memory", text: text))
        let call = ToolCall(
          id: 0,
          request: .init(
            function: "memory",
            parameters: [
              "target": .init(string: true, value: "memory")
            ]), response: response)
        saved["toolExecution"] = [
          "toolCalls": try JSONSerialization.jsonObject(with: JSONEncoder().encode([call])),
          "responses": try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([Int32(0): response])),
        ]
        if modelIndex == 0 {
          var generation = try XCTUnwrap(saved["currentGeneration"] as? [String: Any])
          generation["didFinish"] = true
          saved["currentGeneration"] = generation
        }
        cache.saveSuspension(try JSONSerialization.data(withJSONObject: saved), threadId: threadId)
        XCTAssertTrue(
          try restored.restoreSuspension(
            threadId: threadId, projectPath: directory.path))
        if stopAfterRead {
          let readResult = restored.resume { _, _ in .abort }
          XCTAssertEqual(readResult.memoryContext, MemoryContext(memory: text))
          XCTAssertNil(readResult.systemSeenMemoryContext)
          continue
        }
        _ = restored.resume { _, _ in .pause }
        try restored.hibernate(threadId: threadId)
        let paused = try XCTUnwrap(
          JSONSerialization.jsonObject(
            with: XCTUnwrap(cache.loadSuspension(threadId: threadId))) as? [String: Any])
        let prompt = try JSONDecoder().decode(
          MemoryContext.self,
          from: JSONSerialization.data(
            withJSONObject: XCTUnwrap(paused["systemSeenMemoryContext"])))
        XCTAssertEqual(prompt, initial)
        XCTAssertNil(paused["systemPromptMemoryContext"])
        let resumed = factory(external)
        XCTAssertTrue(
          try resumed.restoreSuspension(
            threadId: threadId, projectPath: directory.path))
        let readResult = resumed.resume { _, _ in .abort }
        XCTAssertEqual(readResult.memoryContext, MemoryContext(user: "Known user", memory: text))
        XCTAssertEqual(readResult.systemSeenMemoryContext, initial)
        XCTAssertFalse(readResult.isEmpty)
        resumed.unloadCaches()
        let nextTurn = resumed.ask(
          "Continue", imagePaths: [], isMemoryEnabled: true, temporary: false,
          allowedTools: nil, threadId: threadId, projectPath: directory.path,
          workspacePath: directory.path, webSearchProvider: .disabled
        ) { _, _ in .abort }
        XCTAssertNil(nextTurn.systemSeenMemoryContext)
        XCTAssertNil(nextTurn.memoryContext)
        let disabled = resumed.ask(
          "Continue", imagePaths: [], isMemoryEnabled: false, temporary: false,
          allowedTools: nil, threadId: threadId, projectPath: directory.path,
          workspacePath: directory.path, webSearchProvider: .disabled
        ) { _, _ in .abort }
        XCTAssertEqual(disabled.systemSeenMemoryContext, .empty)
        XCTAssertEqual(disabled.memoryContext, .empty)
      }
    }
  }

  func testMemoryMetadataStaysAbsentWhenReplayingHistory() throws {
    let promptMemory = MemoryContext(user: "Known user", memory: "A")
    let factories: [() -> any CodeAgent] = [
      {
        Qwen3_5CodeAgent(
          textGenerator: Qwen3_5TextGenerator(
            filePath: "/missing/model", configuration: .qwen3_5_4B, tieEmbedding: true,
            chunkedPrefillMaxLength: 257),
          graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
          unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
          safeTokenizer: Qwen3_5TextGenerator.safeTokenizer,
          systemPromptTemplate: "You are helpful. {{MEMORY_CONTEXT}}",
          memoryContext: promptMemory,
          prefixTokens: Qwen3_5TextGenerator.unsafeTokenizer.tokenize(
            text:
              "<|im_start|>user\nRemember B.<|im_end|>\n<|im_start|>assistant\nMemory now contains A+B.<|im_end|>\n",
            addSpecialTokens: false
          ).0,
          shouldInjectSystemSeenMemoryContext: false)
      },
      {
        DeepSeek4CodeAgent(
          textGenerator: DeepSeek4_1TextGenerator(
            filePath: "/missing/model", engramFilePath: "/missing/engram"),
          graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
          unsafeTokenizer: DeepSeek4_1TextGenerator.unsafeTokenizer,
          safeTokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
          systemPromptTemplate: "You are helpful.",
          memoryContext: promptMemory,
          prefixTokens: DeepSeek4_1TextGenerator.unsafeTokenizer.tokenize(
            text: "<｜User｜>Remember B.<｜Assistant｜>Memory now contains A+B.<｜end▁of▁sentence｜>",
            addSpecialTokens: false
          ).0,
          shouldInjectSystemSeenMemoryContext: false)
      },
    ]
    for makeAgent in factories {
      let agent = makeAgent()
      _ = agent.ask(
        "Continue", imagePaths: [], isMemoryEnabled: true, temporary: false,
        allowedTools: nil, threadId: 900, projectPath: directory.path,
        workspacePath: directory.path, webSearchProvider: .disabled
      ) { _, _ in .pause }
      try agent.hibernate(threadId: 900)
      let saved = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: XCTUnwrap(
            DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 4_096)
              .loadSuspension(threadId: 900)))
          as? [String: Any])
      XCTAssertNil(saved["systemSeenMemoryContext"])
      XCTAssertNil(saved["memoryContext"])
      let restored = makeAgent()
      XCTAssertTrue(try restored.restoreSuspension(threadId: 900, projectPath: directory.path))
      let result = restored.resume { _, _ in .abort }
      XCTAssertNil(result.systemSeenMemoryContext)
      XCTAssertNil(result.memoryContext)
      restored.unloadCaches()
      let afterUnload = restored.ask(
        "Continue", imagePaths: [], isMemoryEnabled: true, temporary: false,
        allowedTools: nil, threadId: 900, projectPath: directory.path,
        workspacePath: directory.path, webSearchProvider: .disabled
      ) { _, _ in .abort }
      XCTAssertNil(afterUnload.systemSeenMemoryContext)
      XCTAssertNil(afterUnload.memoryContext)
    }
  }

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func invoke(_ tool: ViewTool, context: BashToolContext = .init()) throws -> ToolResponse {
    let finished = expectation(description: "View completed")
    var response: ToolResponse?
    tool.invoke(context: context) {
      response = $0
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    return try XCTUnwrap(response)
  }

  func testPDFPasswordPromptRetriesAndCancellation() throws {
    let pdfURL = directory.appendingPathComponent("protected.pdf")
    let consumer = try XCTUnwrap(CGDataConsumer(url: pdfURL as CFURL))
    var bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    writer.beginPDFPage(nil)
    writer.setFillColor(CGColor(gray: 1, alpha: 1))
    writer.fill(bounds)
    writer.endPDFPage()
    writer.closePDF()
    let document = try XCTUnwrap(PDFDocument(url: pdfURL))
    XCTAssertTrue(
      document.write(
        to: pdfURL,
        withOptions: [
          .userPasswordOption: "test-password", .ownerPasswordOption: "owner-password",
        ]))
    XCTAssertTrue(try XCTUnwrap(PDFDocument(url: pdfURL)).isLocked)
    let tool = try XCTUnwrap(
      ViewTool.parse(
        .init(function: "view", parameters: ["path": .init(string: true, value: "protected.pdf")]),
        projectPath: directory.path, workspacePath: directory.path))
    let interaction = BashUserInteraction()
    var attempts = [Bool]()
    let context = BashToolContext(requestPDFPassword: {
      url, incorrect, receivedInteraction, reply in
      XCTAssertEqual(url.standardizedFileURL, pdfURL.standardizedFileURL)
      XCTAssertTrue(receivedInteraction === interaction)
      attempts.append(incorrect)
      // Simulate a user response arriving after the tool invocation returns.
      DispatchQueue.main.async { reply(incorrect ? "test-password" : "wrong-password") }
    }).with(bashUserInteraction: interaction)
    let result = try invoke(tool, context: context)
    XCTAssertEqual(attempts, [false, true])
    XCTAssertEqual(result.content.count, 2)
    XCTAssertEqual(result.content.first, .text("Page 1 from protected.pdf:\n"))
    let encoded = try JSONEncoder().encode(result)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("test-password"))
    // Unlocking the in-memory document must not remove protection from the original.
    XCTAssertTrue(try XCTUnwrap(PDFDocument(url: pdfURL)).isLocked)
    let cancelled = try invoke(
      tool,
      context: BashToolContext(requestPDFPassword: { _, _, _, reply in
        reply(nil)
      }))
    XCTAssertEqual(
      cancelled, ToolResponse(text: "Error: PDF password entry was cancelled: protected.pdf"))
    let unavailable = try invoke(tool)
    XCTAssertEqual(unavailable, ToolResponse(text: "Error: PDF requires a password: protected.pdf"))
  }

  func testPDFViewPaginationAndInterleavedPageImages() throws {
    let pdfURL = directory.appendingPathComponent("pages.pdf")
    let consumer = try XCTUnwrap(CGDataConsumer(url: pdfURL as CFURL))
    var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    for color in [
      CGColor(red: 1, green: 0, blue: 0, alpha: 1),
      CGColor(red: 0, green: 1, blue: 0, alpha: 1),
      CGColor(red: 0, green: 0, blue: 1, alpha: 1),
    ] {
      context.beginPDFPage(nil)
      context.setFillColor(color)
      context.fill(bounds)
      context.endPDFPage()
    }
    context.closePDF()
    let document = try XCTUnwrap(PDFDocument(url: pdfURL))
    let rotated = try XCTUnwrap(document.page(at: 1))
    rotated.rotation = 90
    rotated.setBounds(CGRect(x: 20, y: 30, width: 100, height: 200), for: .cropBox)
    XCTAssertTrue(document.write(to: pdfURL))
    func tool(offset: String? = nil, pages: String? = nil) -> ViewTool? {
      var parameters: [String: ToolCall.Request.Parameter] = [
        "path": .init(string: true, value: "pages.pdf")
      ]
      if let offset { parameters["offset"] = .init(string: false, value: offset) }
      if let pages { parameters["pages"] = .init(string: false, value: pages) }
      return ViewTool.parse(
        .init(function: "view", parameters: parameters), projectPath: directory.path,
        workspacePath: directory.path)
    }
    let first = try invoke(XCTUnwrap(tool()))
    XCTAssertEqual(first.content.count, 2)
    XCTAssertEqual(first.content.first, .text("Page 1 from pages.pdf:\n"))
    let response = try invoke(XCTUnwrap(tool(offset: "2", pages: "99")))
    XCTAssertEqual(response.content.count, 4)
    guard response.content.count == 4 else { return }
    XCTAssertEqual(response.content[0], .text("Page 2 from pages.pdf:\n"))
    XCTAssertEqual(response.content[2], .text("Page 3 from pages.pdf:\n"))
    let decoded = try JSONDecoder().decode(ToolResponse.self, from: JSONEncoder().encode(response))
    XCTAssertEqual(decoded, response)
    XCTAssertNil(tool(offset: "0"))
    XCTAssertNil(tool(offset: "-1"))
    XCTAssertNil(tool(pages: "0"))
    XCTAssertNil(tool(pages: "1.5"))
    let outOfRange = try invoke(XCTUnwrap(tool(offset: "4")))
    guard case .text(let error)? = outOfRange.content.first else {
      return XCTFail("Expected a text error")
    }
    XCTAssertTrue(error.contains("out of range"))
    // Rendered page images remain available independently of the source PDF.
    try FileManager.default.removeItem(at: pdfURL)
    let store = EmbedsFileStore(projectPath: directory.path)
    for index in 0..<2 {
      guard case .imageDigest(let digest) = response.content[index * 2 + 1] else {
        return XCTFail("Expected an image after each page label")
      }
      let source = try XCTUnwrap(
        CGImageSourceCreateWithURL(
          URL(fileURLWithPath: store.filePath(for: digest)) as CFURL, nil))
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(image.width, 400)
      XCTAssertEqual(image.height, index == 0 ? 200 : 600)
      let pixels = try XCTUnwrap(
        CGContext(
          data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      pixels.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      let values = try XCTUnwrap(pixels.data).assumingMemoryBound(to: UInt8.self)
      XCTAssertGreaterThan(values[index == 0 ? 1 : 2], 240)
      XCTAssertLessThan(values[0], 15)
    }
    let agent = Qwen3_5CodeAgent(
      textGenerator: Qwen3_5TextGenerator(
        filePath: "/missing/model", configuration: .qwen3_5_4B,
        tieEmbedding: true, chunkedPrefillMaxLength: 257),
      graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
      unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
      safeTokenizer: Qwen3_5TextGenerator.safeTokenizer,
      systemPromptTemplate: "You are a helpful assistant.")
    let call = ToolCall(
      id: 1, request: .init(function: "view", parameters: [:]), response: response)
    let qwen = agent.suspendedToolResultTokens(
      for: [call], responses: [1: response], projectPath: directory.path)
    let deepSeek = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.toolResultTokens(
      for: [call], responses: [1: response], tokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
      projectPath: directory.path)
    for (result, tokenizer) in [
      (qwen, Qwen3_5TextGenerator.safeTokenizer),
      (deepSeek, DeepSeek4_1TextGenerator.safeTokenizer),
    ] {
      XCTAssertEqual(result.embedSpans.count, 2)
      for (index, span) in result.embedSpans.enumerated() {
        XCTAssertEqual(response.content[index * 2 + 1], .imageDigest(Data(span.digest)))
        let start = index == 0 ? 0 : Int(result.embedSpans[index - 1].end)
        let text = tokenizer.decode(Array(result.tokens[start..<Int(span.start)]))
        XCTAssertTrue(text.contains("Page \(index + 2) from pages.pdf:"))
      }
    }
  }

  func testToolCallDecodesLegacyStringResponse() throws {
    let oldCall = Data(
      #"{"id":1,"raw":"","request":{"function":"read","parameters":{}},"response":"old response"}"#
        .utf8)
    XCTAssertEqual(
      try JSONDecoder().decode(ToolCall.self, from: oldCall).response,
      ToolResponse(text: "old response"))
  }

  func testViewResultsPreserveLabelsImagesAndReplay() throws {
    var calls = [ToolCall]()
    var responses = [Int32: ToolResponse]()
    for (index, name) in ["red.png", "blue.png"].enumerated() {
      let source = directory.appendingPathComponent(name)
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 64 * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(
        CGColor(
          red: index == 0 ? 1 : 0, green: 0, blue: index == 1 ? 1 : 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
      let destination = try XCTUnwrap(
        CGImageDestinationCreateWithURL(
          source as CFURL, "public.png" as CFString, 1, nil))
      CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      let request = ToolCall.Request(
        function: "view", parameters: ["path": .init(string: true, value: name)])
      let invocation = try XCTUnwrap(
        ToolsRegistry.parse(
          request, projectPath: directory.path, workspacePath: directory.path))
      let id = Int32(index + 1)
      invocation.invoke { responses[id] = $0 }
      let response = try XCTUnwrap(responses[id])
      XCTAssertEqual(response.content.first, .text("Image from \(name):"))
      XCTAssertEqual(response.content.count, 2)
      guard case .imageDigest = response.content[1] else { return XCTFail("Missing image") }
      calls.append(ToolCall(id: id, request: request, response: response))
      // Replay must use the CAS after the original file has gone away.
      try FileManager.default.removeItem(at: source)
    }
    let savedResponses = try JSONEncoder().encode(responses)
    responses = try JSONDecoder().decode([Int32: ToolResponse].self, from: savedResponses)
    calls = try JSONDecoder().decode([ToolCall].self, from: JSONEncoder().encode(calls))
    XCTAssertEqual(calls[0].response, responses[1])
    XCTAssertNotEqual(responses[1]?.content.last, responses[2]?.content.last)
    let oldResponses = try JSONEncoder().encode([Int32(1): "old text response"])
    let decoded = try JSONDecoder().decode([Int32: ToolResponse].self, from: oldResponses)
    XCTAssertEqual(decoded[1]?.content, [.text("old text response")])
    let agent = Qwen3_5CodeAgent(
      textGenerator: Qwen3_5TextGenerator(
        filePath: "/missing/model", configuration: .qwen3_5_4B,
        tieEmbedding: true, chunkedPrefillMaxLength: 257),
      graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
      unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
      safeTokenizer: Qwen3_5TextGenerator.safeTokenizer,
      systemPromptTemplate: "You are a helpful assistant.")
    let qwen = agent.suspendedToolResultTokens(
      for: calls, responses: responses, projectPath: directory.path)
    let deepSeek = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.toolResultTokens(
      for: calls, responses: responses, tokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
      projectPath: directory.path)
    for (result, pad) in [(qwen, Int32(248_056)), (deepSeek, Int32(129_264))] {
      XCTAssertEqual(result.embedSpans.count, 2)
      for (index, span) in result.embedSpans.enumerated() {
        XCTAssertEqual(.imageDigest(Data(span.digest)), responses[Int32(index + 1)]?.content.last)
        XCTAssertTrue(result.tokens[Int(span.start)..<Int(span.end)].allSatisfy { $0 == pad })
        XCTAssertGreaterThan(span.length, 0)
      }
      XCTAssertLessThan(result.embedSpans[0].end, result.embedSpans[1].start)
    }
    for (index, span) in qwen.embedSpans.enumerated() {
      XCTAssertEqual(qwen.tokens[Int(span.start) - 1], 248_053)
      XCTAssertEqual(qwen.tokens[Int(span.end)], 248_054)
      let start = index == 0 ? 0 : Int(qwen.embedSpans[index - 1].end) + 1
      let text = Qwen3_5TextGenerator.safeTokenizer.decode(
        Array(qwen.tokens[start..<Int(span.start) - 1]))
      XCTAssertTrue(text.contains(index == 0 ? "Image from red.png:" : "Image from blue.png:"))
    }
    // One response can interleave several labels and images in their original order.
    let combined = ToolResponse(
      try XCTUnwrap(responses[1]).content + XCTUnwrap(responses[2]).content)
    XCTAssertEqual(
      try JSONDecoder().decode(ToolResponse.self, from: JSONEncoder().encode(combined)), combined)
    let combinedQwen = agent.suspendedToolResultTokens(
      for: [calls[0]], responses: [1: combined], projectPath: directory.path)
    let combinedDeepSeek = DeepSeek4CodeAgent<DeepSeek4_1TextGenerator>.toolResultTokens(
      for: [calls[0]], responses: [1: combined], tokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
      projectPath: directory.path)
    for (result, tokenizer) in [
      (combinedQwen, Qwen3_5TextGenerator.safeTokenizer),
      (combinedDeepSeek, DeepSeek4_1TextGenerator.safeTokenizer),
    ] {
      XCTAssertEqual(result.embedSpans.count, 2)
      for (index, span) in result.embedSpans.enumerated() {
        XCTAssertEqual(combined.content[index * 2 + 1], .imageDigest(Data(span.digest)))
        let start = index == 0 ? 0 : Int(result.embedSpans[index - 1].end)
        let text = tokenizer.decode(Array(result.tokens[start..<Int(span.start)]))
        XCTAssertTrue(text.contains(index == 0 ? "Image from red.png:" : "Image from blue.png:"))
      }
    }
    // DeepSeek joins a tool result's text and image blocks with "\n\n", like its encoding.py.
    let deepSeekTokenizer = DeepSeek4_1TextGenerator.safeTokenizer
    XCTAssertTrue(
      deepSeekTokenizer.decode(
        Array(combinedDeepSeek.tokens[..<Int(combinedDeepSeek.embedSpans[0].start)])
      ).hasSuffix("Image from red.png:\n\n"))
    XCTAssertEqual(
      deepSeekTokenizer.decode(
        Array(
          combinedDeepSeek.tokens[
            Int(combinedDeepSeek.embedSpans[0].end)..<Int(combinedDeepSeek.embedSpans[1].start)])),
      "\n\nImage from blue.png:\n\n")
    // Qwen ends each tool-response image with "\n" but adds nothing after its label.
    let qwenTokenizer = Qwen3_5TextGenerator.safeTokenizer
    XCTAssertTrue(
      qwenTokenizer.decode(
        Array(combinedQwen.tokens[..<(Int(combinedQwen.embedSpans[0].start) - 1)])
      )
      .hasSuffix("\nImage from red.png:"))
    XCTAssertEqual(
      qwenTokenizer.decode(
        Array(
          combinedQwen.tokens[
            (Int(combinedQwen.embedSpans[0].end) + 1)..<(Int(combinedQwen.embedSpans[1].start) - 1)]
        )),
      "\nImage from blue.png:")
    XCTAssertEqual(
      qwenTokenizer.decode([combinedQwen.tokens[Int(combinedQwen.embedSpans[1].end) + 1]]), "\n")
    // Exercise the persisted boundary between completed tools and the next prefill.
    let factories: [() -> any CodeAgent] = [
      { agent },
      {
        DeepSeek4CodeAgent(
          textGenerator: DeepSeek4_1TextGenerator(
            filePath: "/missing/model", engramFilePath: "/missing/engram"),
          graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
          unsafeTokenizer: DeepSeek4_1TextGenerator.unsafeTokenizer,
          safeTokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
          systemPromptTemplate: "You are a helpful assistant.")
      },
    ]
    // Both context caches use the same suspension storage format and key.
    let cache = DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 4_096)
    for (index, factory) in factories.enumerated() {
      let suspended = factory()
      let threadId = Int64(500 + index)
      _ = suspended.ask(
        "View the two images", imagePaths: [], isMemoryEnabled: false, temporary: false,
        allowedTools: nil, threadId: threadId, projectPath: directory.path,
        workspacePath: directory.path, webSearchProvider: .duckDuckGo
      ) { _, _ in .pause }
      try suspended.hibernate(threadId: threadId)
      var state = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: XCTUnwrap(cache.loadSuspension(threadId: threadId))) as? [String: Any])
      state["toolExecution"] = [
        "toolCalls": try JSONSerialization.jsonObject(with: JSONEncoder().encode(calls)),
        "responses": try JSONSerialization.jsonObject(with: savedResponses),
      ]
      if index == 0 {
        var generation = try XCTUnwrap(state["currentGeneration"] as? [String: Any])
        generation["didFinish"] = true
        state["currentGeneration"] = generation
      }
      cache.saveSuspension(try JSONSerialization.data(withJSONObject: state), threadId: threadId)
      XCTAssertTrue(
        try suspended.restoreSuspension(threadId: threadId, projectPath: directory.path))
      _ = suspended.resume { _, _ in .pause }
      try suspended.hibernate(threadId: threadId)
      let resumedState = try XCTUnwrap(
        JSONSerialization.jsonObject(
          with: XCTUnwrap(cache.loadSuspension(threadId: threadId))) as? [String: Any])
      let spans = try JSONDecoder().decode(
        [EmbedSpan].self,
        from: JSONSerialization.data(
          withJSONObject: XCTUnwrap(resumedState["userEmbedSpans"])))
      XCTAssertEqual(spans, index == 0 ? qwen.embedSpans : deepSeek.embedSpans)
      let history = try JSONDecoder().decode(
        [ToolCall].self,
        from: JSONSerialization.data(
          withJSONObject: XCTUnwrap(resumedState["toolCallHistory"])))
      XCTAssertEqual(history.map(\.response), calls.map(\.response))
    }
    let missing = try invoke(
      XCTUnwrap(
        ViewTool.parse(
          .init(function: "view", parameters: ["path": .init(string: true, value: "missing.png")]),
          projectPath: directory.path, workspacePath: directory.path)
      ))
    guard case .text(let missingText)? = missing.content.first else {
      return XCTFail("Expected a text error")
    }
    XCTAssertTrue(missingText.hasPrefix("Error:"))
    XCTAssertEqual(missing.content.count, 1)
    let invalid = directory.appendingPathComponent("invalid.png")
    try Data("not an image".utf8).write(to: invalid)
    let invalidResult = try invoke(
      XCTUnwrap(
        ViewTool.parse(
          .init(function: "view", parameters: ["path": .init(string: true, value: "invalid.png")]),
          projectPath: directory.path, workspacePath: directory.path)
      ))
    guard case .text(let invalidText)? = invalidResult.content.first else {
      return XCTFail("Expected a text error")
    }
    XCTAssertTrue(invalidText.hasPrefix("Error:"))
    XCTAssertEqual(invalidResult.content.count, 1)
  }

  func testChunkedRotaryAndInsideImageRestoreMatchWholePrompt() {
    // Two rectangular images exercise row boundaries and both H > W and W > H.
    let grids = [(t: 1, h: 12, w: 8), (t: 1, h: 4, w: 14)]
    let spans = [
      EmbedSpan(start: 3, length: 24, digest: [UInt8](repeating: 1, count: 32), kind: .image),
      EmbedSpan(start: 30, length: 14, digest: [UInt8](repeating: 2, count: 32), kind: .image),
    ]
    let count = 49
    // Missing grids must use text positions, including across chunks and MTP lookahead.
    for available in [[0, 1], [0], [1], []] {
      let availableSpans = available.map { spans[$0] }
      let availableGrids = available.map { grids[$0] }
      let imageGrids = Dictionary(
        uniqueKeysWithValues: zip(availableSpans.map(\.start), availableGrids))
      let types: [Int32] = (0..<count).map { position in
        availableSpans.contains { $0.start <= position && position < $0.end } ? 1 : 0
      }
      let ids = Qwen3_5MakeMultimodalPositionIDs(
        tokenTypeIDs: types, imageGridThw: availableGrids, configuration: vision)
      let expected = Qwen3_5RotaryEmbedding(
        positionIDs: ids, configuration: configuration, of: Float.self)
      for chunkLength in [1, 3, 5, 8, 17, 49] {
        var rotary = Qwen3_5ImageRotaryEmbedding<Float>(
          configuration: configuration, visionConfiguration: vision)
        var delta = 0
        for start in stride(from: 0, to: count, by: chunkLength) {
          let length = min(chunkLength, count - start)
          let lookahead = start + length < count ? 1 : 0
          let visibleSpans = spans.filter {
            $0.end > start && $0.start < start + length + lookahead
          }
          let actual = rotary.embedding(
            start: start, length: length, lookahead: lookahead,
            ropeDelta: delta, spans: visibleSpans, imageGrids: imageGrids)
          // A restored session has no per-image tensors, only the checkpoint's scalar.
          var restored = Qwen3_5ImageRotaryEmbedding<Float>(
            configuration: configuration, visionConfiguration: vision)
          let replay = restored.embedding(
            start: start, length: length, lookahead: lookahead,
            ropeDelta: delta, spans: visibleSpans, imageGrids: imageGrids)
          for row in 0..<(length + lookahead) {
            for column in 0..<configuration.attentionHeadDim {
              XCTAssertEqual(
                actual.tensor[0, row, 0, column], expected[0, start + row, 0, column],
                accuracy: 1e-6)
              XCTAssertEqual(
                replay.tensor[0, row, 0, column], expected[0, start + row, 0, column],
                accuracy: 1e-6)
            }
          }
          XCTAssertEqual(actual.ropeDelta, replay.ropeDelta)
          delta = actual.ropeDelta
        }
        XCTAssertEqual(delta, ids.ropeDelta)
      }
    }
  }

  func testCompactionAndRetainedHistoryPreserveImageSpans() {
    func tokenize(_ text: String) -> [Int32] {
      Qwen3_5TextGenerator.unsafeTokenizer.tokenize(text: text, addSpecialTokens: false).0
    }
    let header = tokenize("<|im_start|>user\nBefore <|vision_start|>")
    let image = Array(repeating: Int32(248_056), count: 12)
    let suffix = tokenize("<|vision_end|> after<|im_end|>\n<|im_start|>assistant\n")
    let thought = tokenize("<think>Inspect the image.</think>")
    let answer = tokenize("A shape.<|im_end|>\n")
    let turn = header + image + suffix + thought + answer
    let digest = [UInt8](repeating: 7, count: 32)
    let spans = [
      EmbedSpan(start: Int64(header.count), length: 12, digest: digest, kind: .image),
      EmbedSpan(start: Int64(turn.count + header.count), length: 12, digest: digest, kind: .image),
    ]
    var compactedSpans = spans
    let compacted = Qwen3_5CodeAgent.compact(
      turn + turn, embedSpans: &compactedSpans, effort: .low,
      tokenizer: Qwen3_5TextGenerator.safeTokenizer, projectPath: directory.path)
    let compactedTurn = header + image + suffix + answer
    XCTAssertEqual(compacted, compactedTurn + compactedTurn)
    XCTAssertEqual(compactedSpans, [spans[0], spans[1].offset(by: -thought.count)])
    var retainedSpans = spans
    let retained = Qwen3_5CodeAgent.retainedConversationTokens(
      in: turn + turn, embedSpans: &retainedSpans, tokenBudget: turn.count)
    XCTAssertEqual(retained, turn)
    XCTAssertEqual(retainedSpans, [spans[0]])
  }

  func testExtensionlessCASAndSuspensionPreserveImageIdentity() throws {
    let source = directory.appendingPathComponent("image.png")
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 64, height: 96, bitsPerComponent: 8,
        bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let store = EmbedsFileStore(projectPath: directory.path)
    let digest = try store.insert(filePath: source.path)
    let path = store.filePath(for: digest)
    let image = try XCTUnwrap(Qwen3_5Image(filePath: path, configuration: vision))
    XCTAssertEqual(image.digest, digest)
    XCTAssertEqual(
      image.tokenCount, Qwen3_5VisionTokenCount(gridThw: image.grid, configuration: vision))
    let patches = try XCTUnwrap(image.patches())
    XCTAssertEqual(patches.shape[0], image.grid.t * image.grid.h * image.grid.w)
    func makeAgent() -> Qwen3_5CodeAgent {
      Qwen3_5CodeAgent(
        textGenerator: Qwen3_5TextGenerator(
          filePath: "/missing/model",
          configuration: .qwen3_5_4B, tieEmbedding: true, chunkedPrefillMaxLength: 257),
        graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
        unsafeTokenizer: Qwen3_5TextGenerator.unsafeTokenizer,
        safeTokenizer: Qwen3_5TextGenerator.safeTokenizer,
        systemPromptTemplate: "You are a helpful assistant.")
    }
    let invalidImage = directory.appendingPathComponent("invalid.png")
    try Data("not an image".utf8).write(to: invalidImage)
    let missingImage = directory.appendingPathComponent("missing.png").path
    let factories: [() -> any CodeAgent] = [
      { makeAgent() },
      {
        DeepSeek4CodeAgent(
          textGenerator: DeepSeek4_1TextGenerator(
            filePath: "/missing/model", engramFilePath: "/missing/engram"),
          graph: DynamicGraph(), streamContext: StreamContext(.GPU(0)),
          unsafeTokenizer: DeepSeek4_1TextGenerator.unsafeTokenizer,
          safeTokenizer: DeepSeek4_1TextGenerator.safeTokenizer,
          systemPromptTemplate: "You are a helpful assistant.")
      },
    ]
    for (modelIndex, factory) in factories.enumerated() {
      for (caseIndex, paths) in [
        [missingImage, invalidImage.path, source.path, missingImage],
        [missingImage, invalidImage.path],
        // Relative paths resolve against the project and label the image as given.
        ["image.png", "invalid.png"],
      ].enumerated() {
        let agent = factory()
        let threadId = Int64(200 + modelIndex * 10 + caseIndex)
        var callbacks = 0
        let result = agent.ask(
          "Describe it", imagePaths: paths, isMemoryEnabled: false, temporary: false,
          allowedTools: nil, threadId: threadId, projectPath: directory.path,
          workspacePath: nil, webSearchProvider: .duckDuckGo
        ) { _, _ in
          callbacks += 1
          return .pause
        }
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertNotNil(agent.suspendedResult)
        try agent.hibernate(threadId: threadId)
        let saved =
          modelIndex == 0
          ? Qwen3_5ContextCache(projectPath: directory.path, checkpointStride: 257)
            .loadSuspension(threadId: threadId)
          : DeepSeek4ContextCache(projectPath: directory.path, checkpointStride: 4_096)
            .loadSuspension(threadId: threadId)
        let encoded = try XCTUnwrap(saved)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let spans = try XCTUnwrap(json["userEmbedSpans"] as? [[String: Any]])
        XCTAssertEqual(spans.count, caseIndex == 1 ? 0 : 1)
        if let span = spans.first {
          XCTAssertEqual(span["digest"] as? String, digest.base64EncodedString())
          let tokens = try XCTUnwrap(json["userTokens"] as? [Int]).map(Int32.init)
          let start = try XCTUnwrap(span["start"] as? Int)
          let end = start + (try XCTUnwrap(span["length"] as? Int))
          let label = "Image from \(caseIndex == 0 ? source.path : "image.png"):"
          if modelIndex == 0 {
            let tokenizer = Qwen3_5TextGenerator.safeTokenizer
            XCTAssertEqual(tokenizer.decode(Array(tokens[..<(start - 1)])), label)
            XCTAssertEqual(tokenizer.decode(Array(tokens[(end + 1)...])), "\nDescribe it")
          } else {
            let tokenizer = DeepSeek4_1TextGenerator.safeTokenizer
            XCTAssertEqual(tokenizer.decode(Array(tokens[..<start])), label + "\n\n")
            XCTAssertEqual(tokenizer.decode(Array(tokens[end...])), "\n\nDescribe it")
          }
        }
      }
      let agent = factory()
      var callbacks = 0
      let result = agent.ask(
        "Describe it", imagePaths: [source.path], isMemoryEnabled: false, temporary: false,
        allowedTools: nil, threadId: 300, projectPath: nil, workspacePath: nil,
        webSearchProvider: .duckDuckGo
      ) { _, _ in
        callbacks += 1
        return .pause
      }
      XCTAssertEqual(callbacks, 1)
      XCTAssertTrue(result.output.isEmpty)
    }
    let agent = makeAgent()
    _ = agent.ask(
      "Describe it", imagePaths: [source.path], isMemoryEnabled: false,
      threadId: 123, projectPath: directory.path
    ) { _, _ in .pause }
    XCTAssertNotNil(agent.suspendedResult)
    try agent.hibernate(threadId: 123)
    let encoded = try XCTUnwrap(
      Qwen3_5ContextCache(projectPath: directory.path, checkpointStride: 257)
        .loadSuspension(threadId: 123))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNotNil(json["ropeDelta"])
    let restored = makeAgent()
    XCTAssertTrue(try restored.restoreSuspension(threadId: 123, projectPath: directory.path))
    var callbacks = 0
    _ = restored.resume { _, _ in
      callbacks += 1
      return .pause
    }
    XCTAssertEqual(callbacks, 1)
  }
  func testCheckpointRestoresScalarGDNAndMTPAndHashesImages() throws {
    let graph = DynamicGraph()
    try graph.withNoGrad {
      let capacity = 9
      let conv = graph.variable(
        .GPU(0), .NHWC(1, 3, 1, configuration.linearConvDim), of: Float16.self)
      let recurrent = graph.variable(.GPU(0), .NHWC(1, 1, 64, 64), of: Float.self)
      let key = graph.variable(.GPU(0), .NHWC(1, capacity, 1, 64), of: Float16.self)
      let value = graph.variable(like: key)
      let draftKey = graph.variable(.GPU(0), .NHWC(1, capacity, 1, 64), of: BFloat16.self)
      let draftValue = graph.variable(like: draftKey)
      let hidden = graph.variable(.GPU(0), .NC(1, 128), of: BFloat16.self)
      conv.full(1)
      recurrent.full(2)
      key.full(3)
      value.full(4)
      draftKey.full(5)
      draftValue.full(6)
      hidden.full(7)
      var caches: [DynamicGraph.AnyTensor] = [conv, recurrent, key, value]
      var draft: [DynamicGraph.AnyTensor] = [draftKey, draftValue, hidden]
      let tokens: [Int32] = [1, 2, 3, 4, 4, 4, 4, 4, 5]
      let spans = [
        EmbedSpan(start: 3, length: 5, digest: Array(repeating: 9, count: 32), kind: .image)
      ]
      let cache = Qwen3_5ContextCache(projectPath: directory.path, checkpointStride: 4)
      var hasher = ContextCachePrefixHasher(modelFilePath: "test.ckpt")
      for endpoint in [4, 8] {
        cache.save(
          graph: graph, tokens: tokens, checkpointLength: endpoint,
          configuration: configuration, isMTPEnabled: true, kvCache: caches,
          draftCache: draft, hasher: &hasher, ropeDelta: endpoint == 4 ? 0 : -2,
          embeddingSpans: spans)
      }
      conv.full(0)
      recurrent.full(0)
      key.full(0)
      value.full(0)
      draftKey.full(0)
      draftValue.full(0)
      hidden.full(0)
      var restoreHasher = ContextCachePrefixHasher(modelFilePath: "test.ckpt")
      var delta = 0
      XCTAssertEqual(
        cache.restore(
          graph: graph, tokens: tokens, configuration: configuration,
          isMTPEnabled: true, kvCache: &caches, draftCache: &draft, hasher: &restoreHasher,
          ropeDelta: &delta, embeddingSpans: spans), 8)
      XCTAssertEqual(delta, -2)
      XCTAssertEqual(conv.toCPU().rawValue[0, 0, 0, 0], 1)
      XCTAssertEqual(recurrent.toCPU().rawValue[0, 0, 0, 0], 2)
      XCTAssertEqual(key.toCPU().rawValue[0, 7, 0, 0], 3)
      XCTAssertEqual(draftKey.toCPU().rawValue[0, 7, 0, 0], 5)
      XCTAssertEqual(hidden.toCPU().rawValue[0, 0], 7)
      var missHasher = ContextCachePrefixHasher(modelFilePath: "test.ckpt")
      let different = [
        EmbedSpan(start: 3, length: 5, digest: Array(repeating: 8, count: 32), kind: .image)
      ]
      XCTAssertEqual(
        cache.restore(
          graph: graph, tokens: tokens, configuration: configuration,
          isMTPEnabled: true, kvCache: &caches, draftCache: &draft, hasher: &missHasher,
          ropeDelta: &delta, embeddingSpans: different), 0)
      // A legacy checkpoint is usable for text only. Images require their matching scalar.
      var keyHasher = ContextCachePrefixHasher(modelFilePath: "test.ckpt")
      let hash: String = keyHasher.hash(tokens: tokens, to: 8, embeddingSpans: spans)
      graph.openStore(try XCTUnwrap(contextCacheStorePath(projectPath: directory.path))) {
        $0.remove("\(hash)/rope_delta")
      }
      var legacyHasher = ContextCachePrefixHasher(modelFilePath: "test.ckpt")
      XCTAssertEqual(
        cache.restore(
          graph: graph, tokens: tokens, configuration: configuration,
          isMTPEnabled: true, kvCache: &caches, draftCache: &draft, hasher: &legacyHasher,
          ropeDelta: &delta, embeddingSpans: spans), 0)
    }
  }
}
