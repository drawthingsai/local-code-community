import Foundation
import XCTest

final class HuggingFaceXetMetadataTests: XCTestCase {
  func testMirrorRepositoryReplacesOfficialOwner() throws {
    XCTAssertEqual(
      try HuggingFaceXetMetadataResolver.mirrorRepository(for: "Qwen/Qwen3.8-27B"),
      "drawthingsai/Qwen3.8-27B")
    XCTAssertEqual(
      try HuggingFaceXetMetadataResolver.mirrorRepository(
        for: "https://huggingface.co/Qwen/Qwen3.8-27B"),
      "drawthingsai/Qwen3.8-27B")
  }

  func testMetadataParsesXetHeaders() throws {
    let refreshURL =
      "https://huggingface.co/api/models/drawthingsai/Qwen3.8-27B/xet-read-token/commit"
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: URL(
          string: "https://huggingface.co/drawthingsai/Qwen3.8-27B/resolve/main/model.ckpt")!,
        statusCode: 302, httpVersion: nil,
        headerFields: [
          "X-Xet-Hash": "ef030706a30fc548aae071153d892879b32e821938eb8f472870afbf766df595",
          "X-Linked-Size": "21348270080",
          "Link": "<\(refreshURL)>; rel=\"xet-auth\", <https://example.com>; rel=\"other\"",
        ]))

    XCTAssertEqual(
      try HuggingFaceXetMetadataResolver.metadata(from: response),
      HuggingFaceXetMetadata(
        fileHash: "ef030706a30fc548aae071153d892879b32e821938eb8f472870afbf766df595",
        fileSize: 21_348_270_080, refreshURL: URL(string: refreshURL)!))
  }

  func testMetadataRejectsOrdinaryHTTPFile() throws {
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: URL(string: "https://huggingface.co/drawthingsai/repo/resolve/main/model.ckpt")!,
        statusCode: 302, httpVersion: nil, headerFields: [:]))
    XCTAssertThrowsError(try HuggingFaceXetMetadataResolver.metadata(from: response))
  }
}
