import Foundation
import XCTest

final class ChatAttachmentTests: XCTestCase {
  private func sessionCopy(_ contents: String, name: String) throws -> ChatAttachment {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return ChatAttachment(url: url, sourceURL: nil)
  }

  func testCopyReusesIdenticalFilesAndNumbersConflicts() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    try Data("existing".utf8).write(to: project.appendingPathComponent("notes.txt"))
    let same = try sessionCopy("existing", name: "notes.txt")
    let different = try sessionCopy("different", name: "notes.txt")
    let fresh = try sessionCopy("fresh", name: "README")
    let names = try ChatAttachment.copy([same, different, fresh], into: project)
    XCTAssertEqual(names, ["notes.txt", "notes 2.txt", "README"])
    XCTAssertEqual(
      try String(contentsOf: project.appendingPathComponent("notes 2.txt"), encoding: .utf8),
      "different")
    // Copying the same draft again references the files already copied.
    XCTAssertEqual(try ChatAttachment.copy([same, different, fresh], into: project), names)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: project.path).sorted(),
      ["README", "notes 2.txt", "notes.txt"])
  }

  func testCopyReferencesFilesDroppedFromTheProject() throws {
    let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sources = project.appendingPathComponent("Sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: project) }
    let source = sources.appendingPathComponent("main.swift")
    try Data("print(1)".utf8).write(to: source)
    let copy = try sessionCopy("print(1)", name: "main.swift")
    let attachment = ChatAttachment(url: copy.url, sourceURL: source)
    XCTAssertEqual(try ChatAttachment.copy([attachment], into: project), ["Sources/main.swift"])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path), ["Sources"])
  }

  func testEmitSectionsLinksAttachedFiles() {
    XCTAssertEqual(
      ChatAttachment.emitSections(
        "Fix this", paths: ["a.png", "notes 2.txt", "Sources/main.swift"]),
      "Fix this\n\n**Attached**: [a.png](a.png), [notes 2.txt](<notes 2.txt>), "
        + "[main.swift](Sources/main.swift)")
    XCTAssertEqual(
      ChatAttachment.emitSections("", paths: ["a.png"]), "**Attached**: [a.png](a.png)")
    XCTAssertEqual(ChatAttachment.emitSections("Fix this", paths: []), "Fix this")
  }

  func testParseSectionsRestoresTheTrailingAttachmentLine() {
    let paths = ["a.png", "notes (2).txt", "Sources/main.swift"]
    let text = "Fix this\n\n**Attached**: [x.png](x.png)\n\nkeep it"
    let parsed = ChatAttachment.parseSections(ChatAttachment.emitSections(text, paths: paths))
    XCTAssertEqual(parsed.text, text)
    XCTAssertEqual(parsed.paths, paths)
    let attachmentsOnly = ChatAttachment.parseSections(
      ChatAttachment.emitSections("", paths: ["b.png"]))
    XCTAssertEqual(attachmentsOnly.text, "")
    XCTAssertEqual(attachmentsOnly.paths, ["b.png"])
    // Only a well-formed last paragraph is an attachment line.
    for text in [text, "Fix this\n\n**Attached**: not a link list", "Plain text"] {
      XCTAssertEqual(ChatAttachment.parseSections(text).text, text)
      XCTAssertEqual(ChatAttachment.parseSections(text).paths, [])
    }
  }
}
