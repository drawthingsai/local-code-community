import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import RemoteAPI

final class RemoteImageTests: XCTestCase {
  override func tearDown() {
    MockURLProtocol.handler = nil
    super.tearDown()
  }

  private func fixture(type: String = "public.png") throws -> RemoteImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return try RemoteImage(data: data as Data)
  }

  func testValidationAndSnapshotRoundTrip() throws {
    for type in ["public.png", "public.jpeg", "com.compuserve.gif"] {
      let image = try fixture(type: type)
      XCTAssertEqual(image.width, 32)
      XCTAssertEqual(image.height, 16)
      let entries: [RemoteTranscriptEntry] = [
        .user("Inspect", images: [image]),
        .toolResult(
          "Image", toolCallID: "read1", toolName: "read", isError: false, images: [image]),
      ]
      XCTAssertEqual(
        try RemoteTranscriptCodec.decode(RemoteTranscriptCodec.encode(entries)), entries)
    }
    XCTAssertThrowsError(try fixture(type: "public.tiff"))
    XCTAssertThrowsError(try RemoteImage(data: Data("not an image".utf8)))
    XCTAssertThrowsError(
      try RemoteImage(data: Data(repeating: 0, count: RemoteImage.maximumBytes + 1)))
    let oldResult = #"{"toolCallID":"read1","toolName":"read","content":"text","isError":false}"#
    XCTAssertEqual(
      try JSONDecoder().decode(RemoteToolResult.self, from: Data(oldResult.utf8)).images, [])
  }

  func testOpenRouterSendsImagesAndKeepsToolBatchContiguous() throws {
    let image = try fixture()
    let done = expectation(description: "OpenRouter response")
    let endpoint = try RemoteProviderEndpoint(provider: .openRouter, model: "vision-test")
    let client = try endpoint.makeChatProvider(
      authorization: RemoteAPIKeyAuthorization(apiKey: "fixture-key"), maximumOutputTokens: 512,
      sessionConfiguration: mockSessionConfiguration())
    XCTAssertTrue(client.supportsImageInput)
    MockURLProtocol.handler = { request, protocolClient in
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      XCTAssertEqual(
        messages.compactMap { $0["role"] as? String },
        ["system", "user", "assistant", "tool", "tool", "user", "user", "user"])
      XCTAssertEqual(messages[0]["content"] as? String, "System")
      XCTAssertEqual(messages[3]["tool_call_id"] as? String, "first")
      XCTAssertEqual(messages[4]["tool_call_id"] as? String, "second")
      XCTAssertEqual(messages.last?["content"] as? String, "Follow up")
      for index in [1, 5, 6] {
        let parts = try XCTUnwrap(messages[index]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String, image.dataURL)
      }
      XCTAssertTrue(
        (messages[5]["content"] as? [[String: Any]])?[0]["text"] as? String
          == "Images returned by tool read (tool_call_id: first):")
      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"red\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
              .utf8)
        ])
    }
    _ = client.streamChat(
      messages: [
        .system("System"), .user("Inspect", images: [image]),
        .assistant(
          nil,
          toolCalls: [
            .init(id: "first", name: "read", arguments: "{}"),
            .init(id: "second", name: "read", arguments: "{}"),
          ]),
        .toolResult(
          "First image", toolCallID: "first", toolName: "read", isError: false, images: [image]),
        .toolResult(
          "Second image", toolCallID: "second", toolName: "read", isError: false, images: [image]),
        .user("Follow up"),
      ], tools: [], progress: { _ in },
      completion: { result in
        XCTAssertEqual(try? result.get().text, "red")
        done.fulfill()
      })
    wait(for: [done], timeout: 3)
  }

  func testCompatibleServersSendImages() throws {
    let image = try fixture()
    let endpoint = try RemoteProviderEndpoint(
      provider: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!,
      model: "qwen3.5:9b")
    XCTAssertEqual(
      try OpenAICompatibleConfiguration(baseURL: endpoint.baseURL, model: endpoint.model)
        .maximumRequestBytes,
      32 * 1_024 * 1_024)
    let client = try endpoint.makeChatProvider(
      authorization: RemoteUnauthenticatedAuthorization(), maximumOutputTokens: 512,
      sessionConfiguration: mockSessionConfiguration())
    XCTAssertTrue(client.supportsImageInput)
    MockURLProtocol.handler = { request, protocolClient in
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
      XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "image_url"])
      XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String, image.dataURL)
      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"red\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
              .utf8)
        ])
    }
    let done = expectation(description: "compatible image response")
    _ = client.streamChat(
      messages: [.system("System"), .user("Inspect", images: [image])], tools: [],
      progress: { _ in }
    ) {
      XCTAssertEqual(try? $0.get().text, "red")
      done.fulfill()
    }
    wait(for: [done], timeout: 3)
  }

  func testAnthropicSendsImagesInMessagesAndToolResults() throws {
    let image = try fixture()
    let client = try RemoteProviderEndpoint(provider: .anthropic, model: "claude-test")
      .makeChatProvider(
        authorization: RemoteAPIKeyAuthorization(apiKey: "fixture-key"), maximumOutputTokens: 512,
        sessionConfiguration: mockSessionConfiguration())
    XCTAssertTrue(client.supportsImageInput)
    MockURLProtocol.handler = { request, protocolClient in
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
      let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
      XCTAssertEqual(
        messages.compactMap { $0["role"] as? String }, ["user", "user", "assistant", "user"])
      let source: NSDictionary = [
        "type": "base64", "media_type": "image/png", "data": image.data.base64EncodedString(),
      ]
      let inspect = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
      XCTAssertEqual(inspect.compactMap { $0["type"] as? String }, ["text", "image"])
      XCTAssertEqual(inspect[1]["source"] as? NSDictionary, source)
      // An image-only message has no empty text block, which Claude rejects.
      let imageOnly = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
      XCTAssertEqual(imageOnly.compactMap { $0["type"] as? String }, ["image"])
      let results = try XCTUnwrap(messages[3]["content"] as? [[String: Any]])
      XCTAssertEqual(results.compactMap { $0["tool_use_id"] as? String }, ["read-1", "read-2"])
      XCTAssertEqual(results[0]["content"] as? String, "plain text")
      let parts = try XCTUnwrap(results[1]["content"] as? [[String: Any]])
      XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "image"])
      XCTAssertEqual(parts[1]["source"] as? NSDictionary, source)
      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            """
            data: {"type":"message_start","message":{"usage":{"input_tokens":2}}}

            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"red"}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}

            data: {"type":"message_stop"}

            """.utf8)
        ])
    }
    let done = expectation(description: "Claude image response")
    _ = client.streamChat(
      messages: [
        .system("System"), .user("Inspect", images: [image]), .user("", images: [image]),
        .assistant(
          nil,
          toolCalls: [
            .init(id: "read-1", name: "read", arguments: "{}"),
            .init(id: "read-2", name: "read", arguments: "{}"),
          ]),
        .toolResult("plain text", toolCallID: "read-1", toolName: "read", isError: false),
        .toolResult(
          "Image from a.png", toolCallID: "read-2", toolName: "read", isError: false,
          images: [image]),
      ], tools: [], progress: { _ in }
    ) {
      XCTAssertEqual(try? $0.get().text, "red")
      done.fulfill()
    }
    wait(for: [done], timeout: 3)
  }

  func testOpenAIResponsesSendsImagesInMessagesAndAfterToolOutputs() throws {
    let image = try fixture()
    // An API key at api.openai.com uses the Responses API, as OpenAI sign-in does.
    let client = try RemoteProviderEndpoint(provider: .openAICompatible, model: "gpt-test")
      .makeChatProvider(
        authorization: RemoteAPIKeyAuthorization(apiKey: "fixture-key"), maximumOutputTokens: 512,
        sessionConfiguration: mockSessionConfiguration())
    XCTAssertTrue(client is OpenAIResponsesClient)
    XCTAssertTrue(client.supportsImageInput)
    MockURLProtocol.handler = { request, protocolClient in
      XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(requestBody(request))) as? [String: Any])
      let input = try XCTUnwrap(body["input"] as? [[String: Any]])
      XCTAssertEqual(
        input.compactMap { $0["type"] as? String },
        ["message", "function_call", "function_call", "function_call_output",
          "function_call_output", "message", "message"])
      func parts(_ index: Int) throws -> [[String: Any]] {
        try XCTUnwrap(input[index]["content"] as? [[String: Any]])
      }
      XCTAssertEqual(try parts(0).compactMap { $0["type"] as? String }, ["input_text", "input_image"])
      XCTAssertEqual(try parts(0)[1]["image_url"] as? String, image.dataURL)
      XCTAssertEqual(input[4]["output"] as? String, "Image from a.png")
      // The tool's images follow its batch of outputs, before the next user message.
      XCTAssertEqual(try parts(5).compactMap { $0["type"] as? String }, ["input_text", "input_image"])
      XCTAssertEqual(
        try parts(5)[0]["text"] as? String, "Images returned by tool read (call_id: read-2):")
      XCTAssertEqual(try parts(6).compactMap { $0["text"] as? String }, ["Follow up"])
      protocolClient.respond(
        status: 200,
        chunks: [
          Data(
            """
            data: {"type":"response.output_text.delta","delta":"red"}

            data: {"type":"response.completed","response":{"usage":{"input_tokens":2,"output_tokens":1}}}

            """.utf8)
        ])
    }
    let done = expectation(description: "Responses image response")
    _ = client.streamChat(
      messages: [
        .system("System"), .user("Inspect", images: [image]),
        .assistant(
          nil,
          toolCalls: [
            .init(id: "read-1", name: "read", arguments: "{}"),
            .init(id: "read-2", name: "read", arguments: "{}"),
          ]),
        .toolResult("plain text", toolCallID: "read-1", toolName: "read", isError: false),
        .toolResult(
          "Image from a.png", toolCallID: "read-2", toolName: "read", isError: false,
          images: [image]),
        .user("Follow up"),
      ], tools: [], progress: { _ in }
    ) {
      XCTAssertEqual(try? $0.get().text, "red")
      done.fulfill()
    }
    wait(for: [done], timeout: 3)
  }

  func testAttachmentsAreDownsizedAndReencodedOnlyWhenNeeded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func write(
      _ name: String, type: String, width: Int, height: Int, orientation: Int = 1,
      alpha: CGImageAlphaInfo = .noneSkipLast
    ) throws -> URL {
      let context = try XCTUnwrap(
        CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue))
      context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      let url = directory.appendingPathComponent(name)
      let destination = try XCTUnwrap(
        CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
      CGImageDestinationAddImage(
        destination, try XCTUnwrap(context.makeImage()),
        [kCGImagePropertyOrientation: orientation] as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      return url
    }

    let small = try write("small.png", type: "public.png", width: 64, height: 32)
    XCTAssertEqual(
      try RemoteImage(attachmentContentsOf: small).data, try Data(contentsOf: small))

    let photo = try write("photo.jpg", type: "public.jpeg", width: 4_032, height: 3_024)
    let downsized = try RemoteImage(attachmentContentsOf: photo)
    XCTAssertEqual(downsized.mediaType, "image/jpeg")
    XCTAssertEqual([downsized.width, downsized.height], [1_024, 768])

    let rotated = try write(
      "rotated.jpg", type: "public.jpeg", width: 300, height: 200, orientation: 6)
    let upright = try RemoteImage(attachmentContentsOf: rotated)
    XCTAssertEqual([upright.width, upright.height], [200, 300])

    let transparent = try write(
      "overlay.tiff", type: "public.tiff", width: 2_000, height: 1_000,
      alpha: .premultipliedLast)
    let png = try RemoteImage(attachmentContentsOf: transparent)
    XCTAssertEqual(png.mediaType, "image/png")
    XCTAssertEqual([png.width, png.height], [1_024, 512])

    let text = directory.appendingPathComponent("notes.txt")
    try Data("not an image".utf8).write(to: text)
    XCTAssertThrowsError(try RemoteImage(attachmentContentsOf: text))
  }

  func testImageRequestsHonorExplicitByteLimit() throws {
    let image = try fixture()
    let url = try XCTUnwrap(URL(string: "https://openrouter.ai/api/v1"))
    XCTAssertEqual(
      try OpenAICompatibleConfiguration(baseURL: url, model: "vision").maximumRequestBytes,
      32 * 1_024 * 1_024)
    let client = OpenAICompatibleClient(
      configuration: try OpenAICompatibleConfiguration(
        baseURL: url, model: "vision", maximumRequestBytes: 100),
      authorization: RemoteAPIKeyAuthorization(apiKey: "fixture-key"),
      sessionConfiguration: mockSessionConfiguration())
    MockURLProtocol.handler = { _, _ in
      XCTFail("Oversized requests must fail before network access")
    }
    let done = expectation(description: "request limit")
    _ = client.streamChat(
      messages: [.user("Inspect", images: [image])], tools: [], progress: { _ in }
    ) {
      XCTAssertEqual($0, .failure(.requestTooLarge(maximumBytes: 100)))
      done.fulfill()
    }
    wait(for: [done], timeout: 3)
  }

  func testEveryAdapterAcceptsImagesWithinItsRequestLimit() throws {
    for provider in RemoteProvider.allCases {
      let endpoint = try RemoteProviderEndpoint(
        provider: provider,
        baseURL: provider == .localCode ? URL(string: "https://router.invalid/v1") : nil,
        model: provider == .openRouter ? "vendor/model" : "test")
      let authorization: any RemoteAuthorizationProviding =
        provider == .openAI
        ? TestAuthorization(RemoteRequestAuthorization(kind: .oauth, token: "token"))
        : RemoteAPIKeyAuthorization(apiKey: "fixture-key")
      let client = try endpoint.makeChatProvider(
        authorization: authorization, maximumOutputTokens: 512,
        sessionConfiguration: mockSessionConfiguration())
      XCTAssertTrue(client.supportsImageInput, provider.rawValue)
    }
    // The Local Code router takes 16 MiB, so two images of about 9 MB fail before sending.
    var paddedBytes = try fixture().data
    paddedBytes.append(Data(repeating: 0, count: 9_000_000))
    let large = try RemoteImage(data: paddedBytes)
    MockURLProtocol.handler = { _, _ in
      XCTFail("Oversized requests must fail before network access")
    }
    let client = try RemoteProviderEndpoint(
      provider: .localCode, baseURL: URL(string: "https://router.invalid/v1"), model: "test"
    ).makeChatProvider(
      authorization: RemoteAPIKeyAuthorization(apiKey: "fixture-key"), maximumOutputTokens: 512,
      sessionConfiguration: mockSessionConfiguration())
    let done = expectation(description: "router request limit")
    _ = client.streamChat(
      messages: [.user("Inspect", images: [large, large])], tools: [], progress: { _ in }
    ) {
      XCTAssertEqual($0, .failure(.requestTooLarge(maximumBytes: 16 * 1_024 * 1_024)))
      done.fulfill()
    }
    wait(for: [done], timeout: 3)
  }

  func testAgentRejectsImagesForAProviderWithoutImageInput() throws {
    final class TextOnlyProvider: RemoteChatProviding {
      let modelIdentity = RemoteModelIdentity(provider: "test", model: "text-only")

      func streamChat(
        messages: [RemoteTranscriptEntry], tools: [RemoteFunctionTool],
        progress: @escaping (RemoteStreamProgress) -> Void,
        completion: @escaping (Result<RemoteCompletion, RemoteChatError>) -> Void
      ) -> RemoteRequestCancellable {
        XCTFail("Unsupported images must fail before sending a request")
        return CompletedRemoteRequest.shared
      }
    }
    let agent = RemoteAgent(
      provider: TextOnlyProvider(), systemPrompt: "System", tools: [],
      configuration: .init(contextWindowTokens: 32_768)
    ) { _, _, _ in nil }
    var result: Result<RemoteAgentCompletion, RemoteChatError>?
    agent.send("Inspect", images: [try fixture()], progress: { _ in }) { result = $0 }
    XCTAssertEqual(result, .failure(.imageInputUnsupported))
    XCTAssertTrue(agent.state.transcript.isEmpty)
  }

  func testImageEstimationAndCompactionKeepVisualEvidence() throws {
    let image = try fixture()
    let text = RemoteContext.estimatedTokens(
      messages: [.user("Inspect")], tools: [], tokenPerByte: nil)
    let visual = RemoteContext.estimatedTokens(
      messages: [.user("Inspect", images: [image])], tools: [], tokenPerByte: nil)
    XCTAssertGreaterThanOrEqual(visual.tokens, text.tokens + image.estimatedTokens)
    XCTAssertEqual(visual.bytes, 0)
    var paddedBytes = image.data
    paddedBytes.append(Data(repeating: 0, count: 100_000))
    let padded = try RemoteImage(data: paddedBytes)
    XCTAssertEqual(
      RemoteContext.estimatedTokens(
        messages: [.user("Inspect", images: [padded])], tools: [], tokenPerByte: nil
      ).tokens, visual.tokens)
    XCTAssertEqual(
      RemoteContext.calibratedTokenPerByte(
        promptTokens: 2_000, encodedBytes: visual.bytes, previous: 0.25), 0.25)
    let state = RemoteAgentState(transcript: [
      .user("Inspect the original", images: [image]),
      .assistant(nil, toolCalls: [.init(id: "read", name: "read", arguments: "{}")]),
      .toolResult("image", toolCallID: "read", toolName: "read", isError: false, images: [image]),
      .assistant("Observed red."), .user("Continue"), .assistant("Done"), .user("Next"),
    ])
    let configuration = RemoteAgentConfiguration(contextWindowTokens: 32_768)
    let prepared = RemoteContext.preparedContext(
      state: state, systemPrompt: "System", tools: [], configuration: configuration)
    let request = try XCTUnwrap(
      RemoteContext.compactionRequest(
        state: state, preparedContext: prepared, systemPrompt: "System", tools: [],
        configuration: configuration, force: true))
    XCTAssertEqual(request.messages.flatMap(\.images), [image, image])
    let summaryText = request.messages.last?.text ?? ""
    XCTAssertFalse(summaryText.contains(image.data.base64EncodedString()))
    XCTAssertTrue(summaryText.contains("Image 1"))
    XCTAssertTrue(summaryText.contains("Image 2"))
  }
}
