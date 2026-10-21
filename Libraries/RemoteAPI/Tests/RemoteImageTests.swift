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

  func testOtherAdaptersRejectImagesBeforeNetworkAccess() throws {
    let image = try fixture()
    MockURLProtocol.handler = { _, _ in
      XCTFail("Unsupported images must fail before sending a request")
    }
    for provider in [RemoteProvider.localCode, .anthropic, .openAICompatible] {
      let endpoint = try RemoteProviderEndpoint(
        provider: provider,
        baseURL: provider == .localCode ? URL(string: "https://router.invalid/v1") : nil,
        model: "test")
      let client = try endpoint.makeChatProvider(
        authorization: RemoteAPIKeyAuthorization(apiKey: "fixture-key"), maximumOutputTokens: 512,
        sessionConfiguration: mockSessionConfiguration())
      XCTAssertFalse(client.supportsImageInput)
      var error: RemoteChatError?
      _ = client.streamChat(
        messages: [.user("Inspect", images: [image])], tools: [], progress: { _ in }
      ) {
        if case .failure(let failure) = $0 { error = failure }
      }
      XCTAssertEqual(error, .imageInputUnsupported)
      let agent = RemoteAgent(
        provider: client, systemPrompt: "System", tools: [],
        configuration: .init(contextWindowTokens: 32_768)
      ) { _, _, _ in nil }
      agent.send("Inspect", images: [image], progress: { _ in }) {
        if case .failure(let failure) = $0 {
          XCTAssertEqual(failure, .imageInputUnsupported)
        } else {
          XCTFail("Images should fail")
        }
      }
      XCTAssertTrue(agent.state.transcript.isEmpty)
    }
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
