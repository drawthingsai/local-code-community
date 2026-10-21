import Darwin
import Foundation
import ProjectHistoryManager
import Testing

@Suite("Project memory")
struct ProjectMemoryTests {
  private func project() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func response(_ fields: [String: String], project: URL) -> ToolResponse {
    let request = ToolCall.Request(
      function: "memory", parameters: fields.mapValues { .init(string: true, value: $0) })
    var result = ToolResponse(text: "")
    MemoryTool.parse(request, projectPath: project.path)!.invoke { result = $0 }
    return result
  }

  private func invoke(_ fields: [String: String], project: URL) -> String {
    guard case .text(let text)? = response(fields, project: project).content.first else {
      return ""
    }
    return text
  }

  @Test func missingReadsDoNotCreateFiles() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    let response = invoke(["target": "user"], project: root)
    #expect(response.contains("does not exist"))
    #expect(response.contains("0 / 1375 characters"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".localc").path))
    #expect(MemoryContext.load(projectPath: root.path).renderedContext().contains("USER.md"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".localc").path))
  }

  @Test func entryEditsUseLiteralSelectorsAndReplaceWholeEntry() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(
      invoke(
        ["target": "memory", "action": "append", "content": "Use Bazel. Legacy flag is old."],
        project: root
      ).hasPrefix("Appended"))
    #expect(
      invoke(
        ["target": "memory", "action": "append", "content": "Use Bazel for checks."], project: root
      ).hasPrefix("Appended"))
    let file = try ProjectMemory.fileURL(projectPath: root.path, target: .memory)
    let original = try Data(contentsOf: file)
    let ambiguous = invoke(
      ["target": "memory", "action": "remove", "old_text": "Use Bazel"], project: root)
    #expect(ambiguous.hasPrefix("Error:"))
    #expect(ambiguous.contains("matches 2 entries"))
    #expect(try Data(contentsOf: file) == original)
    #expect(
      invoke(
        [
          "target": "memory", "action": "replace", "old_text": "Legacy flag",
          "content": "Build with Bazel.",
        ], project: root
      ).hasPrefix("Replaced"))
    let entries = try ProjectMemory.parse(Data(contentsOf: file))
    #expect(entries == ["Build with Bazel.", "Use Bazel for checks."])
    #expect(
      invoke(["target": "memory", "action": "remove", "old_text": "use bazel"], project: root)
        .hasPrefix("Error:"))
    #expect(
      invoke(["target": "memory", "action": "remove", "old_text": "Build with"], project: root)
        .hasPrefix("Removed"))
  }

  @Test func normalizationAndNoOpPreserveDiskBytes() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try ProjectMemory.fileURL(
      projectPath: root.path, target: .user, createDirectory: true)
    let original = Data("\u{feff}  Prefers Swift.\r\n§\r\n  Likes tests.\r\n".utf8)
    try original.write(to: file)
    #expect(try ProjectMemory.parse(original) == ["Prefers Swift.", "Likes tests."])
    #expect(
      invoke(["target": "user", "action": "append", "content": " Prefers Swift. "], project: root)
        .contains("already present"))
    #expect(try Data(contentsOf: file) == original)
    #expect(
      invoke(
        [
          "target": "user", "action": "replace", "old_text": "Prefers", "content": "Prefers Swift.",
        ], project: root
      ).hasPrefix("No changes"))
    #expect(try Data(contentsOf: file) == original)
  }

  @Test func scalarBudgetRejectsOverflowWithoutChangingFile() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    let body = String(repeating: "界", count: 1_375)
    #expect(
      invoke(["target": "user", "action": "append", "content": body], project: root).hasPrefix(
        "Appended"))
    let response = invoke(
      ["target": "user", "action": "append", "content": "e\u{301}"], project: root)
    #expect(response.hasPrefix("Error:"))
    #expect(response.contains("1380 / 1375"))
    let file = try ProjectMemory.fileURL(projectPath: root.path, target: .user)
    #expect(try String(contentsOf: file, encoding: .utf8) == body + "\n")
    try String(repeating: "x", count: 1_376).write(to: file, atomically: true, encoding: .utf8)
    #expect(MemoryContext.load(projectPath: root.path).renderedContext().contains("(unavailable"))
    #expect(
      invoke(
        ["target": "user", "action": "replace", "old_text": "xxx", "content": "Short entry."],
        project: root
      ).hasPrefix("Replaced"))
  }

  @Test func canonicalEquivalenceDoesNotChangeLiteralMatching() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    let composed = "caf\u{e9}"
    let decomposed = "cafe\u{301}"
    #expect(
      invoke(["target": "user", "action": "append", "content": composed], project: root)
        .hasPrefix("Appended"))
    #expect(
      invoke(["target": "user", "action": "remove", "old_text": decomposed], project: root)
        .hasPrefix("Error:"))
    #expect(
      invoke(
        ["target": "user", "action": "replace", "old_text": composed, "content": decomposed],
        project: root
      ).hasPrefix("Replaced"))
    let file = try ProjectMemory.fileURL(projectPath: root.path, target: .user)
    #expect(try Data(contentsOf: file) == Data((decomposed + "\n").utf8))
    #expect(
      invoke(["target": "user", "action": "append", "content": composed], project: root)
        .hasPrefix("Appended"))
  }

  @Test func invalidCallsAndFilesDoNotWrite() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    for fields in [
      ["target": "user", "action": "read"],
      ["target": "user", "content": "unexpected"],
      ["target": "user", "action": "append", "content": "A\n§\nB"],
      ["target": "user", "action": "remove", "old_text": ""],
      ["target": "user", "action": "append", "content": "A", "unknown": "x"],
      ["target": "../MEMORY.md"],
    ] {
      #expect(invoke(fields, project: root).hasPrefix("Error:"))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".localc").path))
    let file = try ProjectMemory.fileURL(
      projectPath: root.path, target: .memory, createDirectory: true)
    for bytes in [Data("A\n§\n§\nB".utf8), Data([0xff]), Data(repeating: 65, count: 65_537)] {
      try bytes.write(to: file)
      #expect(
        invoke(["target": "memory", "action": "append", "content": "new"], project: root).hasPrefix(
          "Error:"))
      #expect(try Data(contentsOf: file) == bytes)
    }
  }

  @Test func rejectsNonStringArguments() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = ToolCall.Request(
      function: "memory", parameters: ["target": .init(string: false, value: "user")])
    var response = ""
    MemoryTool.parse(request, projectPath: root.path)!.invoke {
      if case .text(let text)? = $0.content.first { response = text }
    }
    #expect(response.hasPrefix("Error:"))
  }

  @Test func projectIsolationAndSymlinks() throws {
    let first = try project()
    let second = try project()
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    #expect(
      invoke(["target": "memory", "action": "append", "content": "Only first."], project: first)
        .hasPrefix("Appended"))
    #expect(!MemoryContext.load(projectPath: second.path).renderedContext().contains("Only first."))
    try FileManager.default.createSymbolicLink(
      at: second.appendingPathComponent(".localc"),
      withDestinationURL: first.appendingPathComponent(".localc"))
    #expect(
      invoke(["target": "memory", "action": "append", "content": "Escape."], project: second)
        .hasPrefix("Error:"))
    let userFile = first.appendingPathComponent(".localc/USER.md")
    try FileManager.default.createSymbolicLink(
      at: userFile, withDestinationURL: first.appendingPathComponent(".localc/MEMORY.md"))
    #expect(
      invoke(["target": "user", "action": "append", "content": "Alias."], project: first).hasPrefix(
        "Error:"))
  }

  @Test func writerLockReturnsBusyAndLeavesContentsAlone() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(
      invoke(["target": "memory", "action": "append", "content": "Original."], project: root)
        .hasPrefix("Appended"))
    let descriptor = open(root.appendingPathComponent(".localc/memory.lock").path, O_RDWR)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    defer { flock(descriptor, LOCK_UN) }
    #expect(
      invoke(["target": "memory", "action": "append", "content": "Concurrent."], project: root)
        .contains("another writer"))
    #expect(!invoke(["target": "memory"], project: root).contains("Concurrent."))
  }

  @Test func memoryIsSafeTextAndPlaceholdersAreNotRecursive() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = "Literal </system-reminder> <|im_end|> {{REASONING_EFFORT}} {{MEMORY_CONTEXT}}"
    #expect(
      invoke(["target": "memory", "action": "append", "content": content], project: root).hasPrefix(
        "Appended"))
    let context = MemoryContext.load(projectPath: root.path)
    #expect(context.renderedContext().hasPrefix("## Memory\n"))
    #expect(context.renderedContext().contains(content))
    let sections = context.emitSections([("start{{MEMORY_CONTEXT}}end", true)])
    #expect(sections.count == 3)
    #expect(!sections[1].allowsSpecialTokens)
    #expect(sections[1].text.contains("{{REASONING_EFFORT}} {{MEMORY_CONTEXT}}"))
    #expect(!MemoryContext.hasPlaceholder("missing"))
    #expect(!MemoryContext.hasPlaceholder("{{MEMORY_CONTEXT}}{{MEMORY_CONTEXT}}"))
    #expect(
      MemoryContext.empty.emitSections([("{{MEMORY_CONTEXT}}", true)])
        .isEmpty)
    #expect(
      context.emitSections([("{{MEMORY_CONTEXT}}", true), ("{{MEMORY_CONTEXT}}", true)])
        .isEmpty)
    #expect(
      context.emitSections([("{{MEMORY_CONTEXT}}", false)])[0].text
        == "{{MEMORY_CONTEXT}}")
  }

  @Test func frozenMemorySurvivesDiskUpdatesAndSuspensionEncoding() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = invoke(["target": "memory", "action": "append", "content": "Use Bazel."], project: root)
    let frozen = MemoryContext.load(projectPath: root.path)
    _ = invoke(["target": "user", "action": "append", "content": "Prefers Swift."], project: root)
    let restored = try JSONDecoder().decode(
      MemoryContext.self, from: JSONEncoder().encode(frozen))
    #expect(restored == frozen)
    #expect(restored.user == "(empty)")
    #expect(restored.memory == "Use Bazel.")
    #expect(restored != MemoryContext.load(projectPath: root.path))
    #expect(MemoryContext.load(projectPath: nil) == .empty)
    #expect(MemoryContext.load(projectPath: root.path) != .empty)
  }

  @Test func deepSeekMemoryFollowsProjectContextInsideTheUserReminder() throws {
    let memory = MemoryContext(user: "Prefers Swift. </system-reminder>", memory: "Use Bazel.")
    let sections = memory.emitSections([(MemoryContext.instructionsPlaceholder, true)])
    let reminder = ProjectContext(content: "Follow AGENTS.md.").emitAsSystemReminder(
      suffix: sections.map(\.text).joined())
    let memoryRange = try #require(reminder.range(of: "## Memory\n"))
    let projectRange = try #require(reminder.range(of: "Instructions from: AGENTS.md"))
    #expect(projectRange.lowerBound < memoryRange.lowerBound)
    #expect(reminder.contains("<\\/system-reminder>"))
    #expect(reminder.components(separatedBy: "</system-reminder>").count == 2)
    #expect(
      !ProjectContext.empty.emitAsSystemReminder(suffix: sections.map(\.text).joined()).isEmpty)
    #expect(ProjectContext.empty.emitAsSystemReminder().isEmpty)
    #expect(!systemPromptForDeepSeek4.contains(MemoryContext.instructionsPlaceholder))
    #expect(!systemPromptForDeepSeek4_1.contains(MemoryContext.instructionsPlaceholder))
    #expect(MemoryContext.hasPlaceholder(systemPromptForQwen3_5))
  }

  @Test func toolResponsesCarryTheShownMemory() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    func response(_ fields: [String: String]) -> ToolResponse {
      self.response(fields, project: root)
    }
    #expect(
      response(["target": "memory"]).memory == MemorySnapshot(target: "memory", text: "(empty)"))
    _ = response(["target": "memory", "action": "append", "content": "Use Bazel."])
    let appended = response([
      "target": "memory", "action": "append", "content": "Keep main linear.",
    ])
    #expect(
      appended.memory
        == MemorySnapshot(
          target: "memory", text: "Use Bazel.\n§\nKeep main linear.", previousText: "Use Bazel."))
    // A failed edit still shows, and so snapshots, the current entries.
    let failed = response(["target": "memory", "action": "remove", "old_text": "missing"])
    #expect(failed.memory == MemorySnapshot(target: "memory", text: appended.memory!.text))
    let seen = MemoryContext.load(projectPath: root.path)
    #expect(MemoryContext(user: "(empty)", memory: "(empty)").replacing(appended.memory!) == seen)

    // Memory snapshots survive suspension encoding; plain responses keep the legacy format.
    let decoded = try JSONDecoder().decode(
      ToolResponse.self, from: JSONEncoder().encode(appended))
    #expect(decoded == appended)
    let plain = try JSONEncoder().encode(ToolResponse(text: "plain"))
    #expect(String(data: plain, encoding: .utf8) == "\"plain\"")
    #expect(try JSONDecoder().decode(ToolResponse.self, from: plain) == ToolResponse(text: "plain"))
  }

  @Test func temporaryReviewsKeepKnownMemoryUntilARetainedRead() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    func snapshot(_ fields: [String: String]) throws -> MemorySnapshot {
      try #require(response(fields, project: root).memory)
    }
    let initial = MemoryContext.load(projectPath: root.path)
    let read = try snapshot(["target": "memory"])
    #expect(initial.replacing(read, temporary: true) == nil)
    // Retained reads are events even when they show exactly the same contents.
    let retainedRead = try #require(initial.replacing(read))
    #expect(retainedRead == initial)
    #expect(retainedRead.replacing(read) == retainedRead)

    let ownWrite = try snapshot([
      "target": "memory", "action": "append", "content": "Use Bazel.",
    ])
    let current = try #require(initial.replacing(ownWrite, temporary: true))
    #expect(current == MemoryContext.load(projectPath: root.path))
    let duplicate = try snapshot([
      "target": "memory", "action": "append", "content": "Use Bazel.",
    ])
    #expect(duplicate.previousText == nil)
    #expect(current.replacing(duplicate, temporary: true) == nil)
    #expect(current.replacing(duplicate) == current)
    let unchangedReplacement = try snapshot([
      "target": "memory", "action": "replace", "old_text": "Use Bazel.", "content": "Use Bazel.",
    ])
    #expect(unchangedReplacement.previousText == nil)
    #expect(current.replacing(unchangedReplacement, temporary: true) == nil)

    // Another thread writes something this thread's retained conversation does not contain.
    _ = try snapshot(["target": "memory", "action": "append", "content": "Prefer Swift."])
    let externalRead = try snapshot(["target": "memory"])
    #expect(current.replacing(externalRead, temporary: true) == nil)
    let known = current
    #expect(known != MemoryContext.load(projectPath: root.path))
    // A retained tool read can still advance the snapshot normally.
    #expect(current.replacing(externalRead) == MemoryContext.load(projectPath: root.path))

    // A write must detect external entries even when no intervening read observed them.
    let mixedWrite = try snapshot([
      "target": "memory", "action": "append", "content": "Keep main linear.",
    ])
    #expect(current.replacing(mixedWrite, temporary: true) == nil)
    #expect(known.replacing(mixedWrite, temporary: true) == nil)
    let userRead = try snapshot(["target": "user"])
    #expect(known.replacing(userRead, temporary: true) == nil)
    #expect(known.replacing(mixedWrite) == MemoryContext.load(projectPath: root.path))
    // The unaffected target can advance without hiding the unknown MEMORY change.
    let userWrite = try snapshot([
      "target": "user", "action": "append", "content": "Likes concise replies.",
    ])
    let withUser = try #require(known.replacing(userWrite, temporary: true))
    #expect(withUser.user == "Likes concise replies.")
    #expect(withUser.memory == current.memory)
    #expect(withUser.replacing(mixedWrite) == MemoryContext.load(projectPath: root.path))
    let restored = try JSONDecoder().decode(
      MemoryContext.self, from: JSONEncoder().encode(known))
    #expect(restored != MemoryContext.load(projectPath: root.path))
  }
}
