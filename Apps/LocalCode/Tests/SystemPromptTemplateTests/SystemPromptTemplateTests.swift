import CryptoKit
import Foundation
import Testing

@Suite("System prompt template store")
struct SystemPromptTemplateTests {
  @Test func createsAndUpdatesAnAppOwnedTemplate() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = "openai/gpt-5"
    let fileURL = SystemPromptTemplate.fileURL(projectURL: fixture.url, model: model)

    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: model, template: "Embedded v1")
        == "Embedded v1")
    let initialContents = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(initialContents.contains("model: \"openai/gpt-5\""))
    #expect(initialContents.hasSuffix("---\nEmbedded v1"))

    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: model, template: "Embedded v2")
        == "Embedded v2")
    let updatedContents = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(updatedContents.hasSuffix("---\nEmbedded v2"))
    #expect(updatedContents != initialContents)
    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: model, template: "Embedded v2")
        == "Embedded v2")
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == updatedContents)
  }

  @Test func preservesAndUsesAnEditedTemplate() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = "qwen_3.8_27b_i4x"
    let fileURL = SystemPromptTemplate.fileURL(projectURL: fixture.url, model: model)
    let _ = SystemPromptTemplate.load(
      projectURL: fixture.url, model: model, template: "Embedded")
    let managedContents = try String(contentsOf: fileURL, encoding: .utf8)
    let editedContents = managedContents.replacingOccurrences(of: "Embedded", with: "Custom")
    try editedContents.write(to: fileURL, atomically: true, encoding: .utf8)

    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: model, template: "Updated embedded")
        == "Custom")
    #expect(try String(contentsOf: fileURL, encoding: .utf8) == editedContents)
  }

  @Test func treatsMissingOrInvalidMetadataAsAnEdit() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let rawModel = "raw"
    let rawURL = SystemPromptTemplate.fileURL(projectURL: fixture.url, model: rawModel)
    try FileManager.default.createDirectory(
      at: rawURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "Raw custom template".write(to: rawURL, atomically: true, encoding: .utf8)

    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: rawModel, template: "Embedded")
        == "Raw custom template")

    let invalidModel = "invalid"
    let invalidURL = SystemPromptTemplate.fileURL(
      projectURL: fixture.url, model: invalidModel)
    let invalidContents = "---\nsha256: [\n---\nCustom body"
    try invalidContents.write(to: invalidURL, atomically: true, encoding: .utf8)
    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: invalidModel, template: "Embedded")
        == "Custom body")
    #expect(try String(contentsOf: invalidURL, encoding: .utf8) == invalidContents)
  }

  @Test func allowsAnEditedTemplateToBeEmpty() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = "empty"
    let fileURL = SystemPromptTemplate.fileURL(projectURL: fixture.url, model: model)
    let _ = SystemPromptTemplate.load(
      projectURL: fixture.url, model: model, template: "Embedded")
    var contents = try String(contentsOf: fileURL, encoding: .utf8)
    let bodyRange = contents.range(of: "---\n", options: .backwards)!
    contents.removeSubrange(bodyRange.upperBound..<contents.endIndex)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)

    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: model, template: "Embedded") == "")
  }

  @Test func encodesModelNamesAndBoundsLongFileNames() {
    #expect(
      SystemPromptTemplate.fileName(model: "openai/gpt-5")
        == "templated_system_prompt_openai%2Fgpt-5.md")
    #expect(
      SystemPromptTemplate.fileName(model: "model 100%")
        == "templated_system_prompt_model%20100%25.md")

    let longModel = String(repeating: "model/", count: 100)
    let digest = SHA256.hash(data: Data(longModel.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let fileName = SystemPromptTemplate.fileName(model: longModel)
    #expect(fileName.utf8.count == 255)
    #expect(fileName.hasSuffix("_\(digest).md"))
  }

  @Test func fallsBackWhenAFileCannotBeReadAsUTF8() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let model = "invalid-utf8"
    let fileURL = SystemPromptTemplate.fileURL(projectURL: fixture.url, model: model)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0xff]).write(to: fileURL)

    #expect(
      SystemPromptTemplate.load(
        projectURL: fixture.url, model: model, template: "Embedded")
        == "Embedded")
  }

  private struct Fixture {
    let url: URL

    init() throws {
      url = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
      try? FileManager.default.removeItem(at: url)
    }
  }
}
