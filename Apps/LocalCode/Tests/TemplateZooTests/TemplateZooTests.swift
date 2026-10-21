import Foundation
import Testing
import ZIPFoundation

/// Serves template archives in place of templates.drawthings.ai; unknown names get a 404.
private final class TemplateURLProtocol: URLProtocol {
  nonisolated(unsafe) static var archives = [String: Data]()

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "templates.drawthings.ai"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let url = request.url!
    let data = Self.archives[url.lastPathComponent]
    let response = HTTPURLResponse(
      url: url, statusCode: data == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let data {
      client?.urlProtocol(self, didLoad: data)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite("Template zoo", .serialized)
struct TemplateZooTests {
  private static let prompts = """
    Sort my Downloads folder into subfolders by file type.
    §
    Find duplicate photos and list them
    with their sizes.
    """

  init() {
    URLProtocol.registerClass(TemplateURLProtocol.self)
  }

  private func project() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Publishes a zip of the given entries; a nil body is a directory entry.
  private func publish(_ name: String, entries: [(path: String, body: String?)]) throws {
    let archive = try #require(Archive(accessMode: .create))
    for (path, body) in entries {
      let data = Data((body ?? "").utf8)
      try archive.addEntry(
        with: path, type: body == nil ? .directory : .file, uncompressedSize: Int64(data.count),
        compressionMethod: .deflate
      ) { position, size in
        data.subdata(in: Int(position)..<Int(position) + size)
      }
    }
    TemplateURLProtocol.archives[name + ".zip"] = archive.data
  }

  private func copy(_ name: String, to folderURL: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      TemplateZoo.copy(templateNamed: name, to: folderURL) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  /// Reads the prompts the way ChatWorkflow does when it starts a new conversation.
  private func firstTimePrompts(_ root: URL) throws -> [String] {
    let data = try #require(
      try ProjectMemory.read(root.appendingPathComponent(".localc/first_time_prompts.txt")))
    return try ProjectMemory.parse(data)
  }

  @Test func extractsHiddenFilesAndDirectories() async throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    try publish(
      "File Organizer",
      entries: [
        ("AGENTS.md", "# File Organizer\n"),
        (".gitignore", "*.tmp\n"),
        (".localc/", nil),
        (".localc/first_time_prompts.txt", Self.prompts),
      ])
    try await copy("File Organizer", to: root)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
    #expect(
      try firstTimePrompts(root) == [
        "Sort my Downloads folder into subfolders by file type.",
        "Find duplicate photos and list them\nwith their sizes.",
      ])
  }

  @Test func extractsHiddenFilesWithoutDirectoryEntries() async throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    // `zip -D` and some tools omit directory entries, so the file entry must create `.localc`.
    try publish(
      "House Chores", entries: [(".localc/first_time_prompts.txt", Self.prompts)])
    try await copy("House Chores", to: root)
    #expect(try firstTimePrompts(root).count == 2)
  }

  @Test func extractsIntoProjectOpenedBeforeDownloadFinished() async throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    // Opening the project creates its metadata before the template lands.
    let metadataURL = root.appendingPathComponent(".localc/metadata.sqlite3")
    try FileManager.default.createDirectory(
      at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("metadata".utf8).write(to: metadataURL)
    try publish(
      "Daily Brief",
      entries: [(".localc/", nil), (".localc/first_time_prompts.txt", Self.prompts)])
    try await copy("Daily Brief", to: root)
    #expect(try firstTimePrompts(root).count == 2)
    #expect(try Data(contentsOf: metadataURL) == Data("metadata".utf8))
  }

  @Test func unpublishedTemplateCopiesNothing() async throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    try await copy("Unpublished Template", to: root)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  private func templateNames() async throws -> [String] {
    try await withCheckedThrowingContinuation { continuation in
      TemplateZoo.fetchTemplateNames { continuation.resume(with: $0) }
    }
  }

  @Test func fetchesTemplateNamesFromIndex() async throws {
    TemplateURLProtocol.archives["templates.json"] = Data(
      #"[{"name": "Explainer Videos"}, {"name": "File Organizer"}]"#.utf8)
    defer { TemplateURLProtocol.archives["templates.json"] = nil }
    #expect(try await templateNames() == ["Explainer Videos", "File Organizer"])
  }

  @Test func missingIndexFails() async throws {
    await #expect(throws: TemplateZoo.Error.self) { try await templateNames() }
  }
}
