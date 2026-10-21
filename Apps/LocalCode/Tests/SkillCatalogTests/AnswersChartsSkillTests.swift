import Foundation
import Testing

@Suite("Answers charts built-in skill")
struct AnswersChartsSkillTests {
  @Test func discoversPackagedSkillWithinInjectionLimits() throws {
    let fixture = try Fixture()
    let sourceURL = try Self.skillSourceURL()
    let skillsURL = fixture.rootURL.appendingPathComponent("Skills", isDirectory: true)
    let copiedSkillURL = skillsURL.appendingPathComponent("answers-charts", isDirectory: true)
    try FileManager.default.createDirectory(at: copiedSkillURL, withIntermediateDirectories: true)
    try Data(contentsOf: sourceURL).write(
      to: copiedSkillURL.appendingPathComponent("SKILL.md"))

    let catalog = SkillCatalog.find(
      roots: [SkillRoot(url: skillsURL, allowedRootURL: skillsURL, scope: .builtIn)])
    let entry = try #require(catalog.entries.first { $0.name == "answers-charts" })

    #expect(catalog.entries.count == 1)
    #expect(catalog.warnings.isEmpty)
    #expect(entry.scope == .builtIn)
    #expect(!entry.description.isEmpty)
    #expect(entry.name.count <= 64)
    #expect(entry.description.count <= 1_024)
    #expect(try Data(contentsOf: entry.fileURL).count <= SkillCatalog.injectedSkillByteLimit)

    let instructions = try String(contentsOf: entry.fileURL, encoding: .utf8)
    let request = "Use $answers-charts to plot the supplied data."
    let injectedPrompt = catalog.prompt(for: request)
    #expect(injectedPrompt.contains(instructions))
    #expect(injectedPrompt.hasSuffix(request))
    #expect(catalog.prompt(for: "Hello") == "Hello")
  }

  private static func skillSourceURL() throws -> URL {
    let fileManager = FileManager.default
    let environment = ProcessInfo.processInfo.environment
    var candidates = [URL]()
    if let sourceDirectory = environment["TEST_SRCDIR"],
      let workspace = environment["TEST_WORKSPACE"]
    {
      candidates.append(
        URL(fileURLWithPath: sourceDirectory, isDirectory: true)
          .appendingPathComponent(workspace, isDirectory: true)
          .appendingPathComponent(
            "Apps/LocalCode/Resources/Skills/answers-charts/SKILL.md"))
    }
    if let workspace = environment["BUILD_WORKSPACE_DIRECTORY"] {
      candidates.append(
        URL(fileURLWithPath: workspace, isDirectory: true)
          .appendingPathComponent(
            "Apps/LocalCode/Resources/Skills/answers-charts/SKILL.md"))
    }
    let sourceFileURL = URL(fileURLWithPath: #filePath)
    candidates.append(
      sourceFileURL.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(
          "Resources/Skills/answers-charts/SKILL.md"))

    for candidate in candidates {
      var isDirectory = ObjCBool(false)
      if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        return candidate.standardizedFileURL
      }
    }
    throw CocoaError(.fileNoSuchFile)
  }

  private final class Fixture {
    let rootURL: URL

    init() throws {
      rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "AnswersChartsSkillTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    deinit {
      try? FileManager.default.removeItem(at: rootURL)
    }
  }
}
