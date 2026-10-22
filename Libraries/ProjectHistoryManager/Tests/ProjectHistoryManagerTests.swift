import Dflat
import Foundation
import SQLiteDflat
import XCTest

@testable import ProjectHistoryManager

final class ProjectHistoryManagerTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var workspace: SQLiteWorkspace!

  override func setUpWithError() throws {
    try super.setUpWithError()
    temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "ProjectHistoryManagerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
    workspace = SQLiteWorkspace(
      filePath: temporaryDirectory.appendingPathComponent("metadata.sqlite3").path,
      fileProtectionLevel: .noProtection)
  }

  override func tearDownWithError() throws {
    workspace.shutdown(flags: .truncate)
    workspace = nil
    try? FileManager.default.removeItem(at: temporaryDirectory)
    temporaryDirectory = nil
    try super.tearDownWithError()
  }

  private func createThread(
    _ manager: ProjectHistoryManager, title: String, model: String, tokens: [Int32],
    textEdits: Int = 1, textLineage: Int64 = 0
  ) -> ProjectThread {
    manager.createThread(
      title: title, model: model, userTokens: tokens, textEdits: textEdits,
      textLineage: textLineage)
  }

  private func appendUser(
    _ manager: ProjectHistoryManager, threadId: Int64, tokens: [Int32],
    textEdits: Int = 1, textLineage: Int64 = 0
  ) -> ProjectHistoryNode {
    try! XCTUnwrap(
      manager.appendUser(
        threadId: threadId, tokens: tokens, textEdits: textEdits,
        textLineage: textLineage))
  }

  private func appendAssistant(
    _ manager: ProjectHistoryManager, threadId: Int64, logTokens: [Int32],
    tokens: [Int32], toolCalls: [ToolCall] = [], plaintext: String? = nil,
    logPlaintext: String? = nil, duration: TimeInterval = 0, compacted: Bool,
    incrementTurnCountSinceLastReview: Bool = false
  ) -> ProjectHistoryNode {
    try! XCTUnwrap(
      manager.appendAssistant(
        threadId: threadId, logTokens: logTokens, tokens: tokens, toolCalls: toolCalls,
        plaintext: plaintext, logPlaintext: logPlaintext, duration: duration,
        compacted: compacted,
        incrementTurnCountSinceLastReview: incrementTurnCountSinceLastReview))
  }

  func testMemoryNodesPersistWithoutChangingConversationOrAssistant() throws {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Memory", model: "model.ckpt", tokens: [1])
    let initial = MemoryContext(user: "Initial user", memory: "Initial memory")
    let reviewed = MemoryContext(user: "Initial user", memory: "Reviewed memory")
    let assistant = try XCTUnwrap(
      manager.appendAssistant(
        threadId: thread.id, logTokens: [2, 3], tokens: [3], toolCalls: [], compacted: false,
        incrementTurnCountSinceLastReview: true, memoryContext: initial,
        systemSeenMemoryContext: initial))
    let beforeReview = try XCTUnwrap(manager.thread(id: thread.id))
    let review = try XCTUnwrap(manager.appendMemory(threadId: thread.id, memoryContext: reviewed))
    XCTAssertEqual(review.role, .memory)
    XCTAssertTrue(review.tokens.isEmpty)
    XCTAssertTrue(review.logTokens.isEmpty)
    XCTAssertNil(review.systemSeenMemoryContext)
    XCTAssertEqual(manager.thread(id: thread.id), beforeReview)
    XCTAssertEqual(manager.context(threadId: thread.id).tokens, [2, 3])
    XCTAssertEqual(manager.history(threadId: thread.id).dropLast().last, assistant)
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 1)

    workspace.shutdown(flags: [])
    workspace = SQLiteWorkspace(filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restored = ProjectHistoryManager(project: workspace)
    let history = restored.history(threadId: thread.id)
    XCTAssertEqual(history.map(\.role), [.user, .assistant, .memory])
    XCTAssertEqual(history[1], assistant)
    let memory = ProjectHistoryManager.memoryContext(history: history)
    XCTAssertEqual(memory.memoryContext, reviewed)
    XCTAssertEqual(memory.systemSeenMemoryContext, initial)
    XCTAssertEqual(restored.context(threadId: thread.id).tokens, [2, 3])
    XCTAssertEqual(restored.thread(id: thread.id)?.updatedAt, beforeReview.updatedAt)
  }

  func testMemorySnapshotsResolveIndependentlyAcrossCompactionAndRewrite() throws {
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Memory", model: "model.ckpt", tokens: [1])
    XCTAssertNil(
      ProjectHistoryManager.memoryContext(history: manager.history(threadId: thread.id))
        .memoryContext)
    let initial = MemoryContext(user: "User", memory: "Initial")
    let reviewed = MemoryContext(user: "User", memory: "Reviewed")
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [2], tokens: [2], toolCalls: [], compacted: false,
      memoryContext: initial, systemSeenMemoryContext: initial)
    _ = manager.appendMemory(threadId: thread.id, memoryContext: reviewed)
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [3], tokens: [3], toolCalls: [], compacted: true)
    let beforeRefresh = ProjectHistoryManager.memoryContext(
      history: manager.history(threadId: thread.id))
    XCTAssertEqual(beforeRefresh.memoryContext, reviewed)
    XCTAssertEqual(beforeRefresh.systemSeenMemoryContext, initial)
    XCTAssertEqual(manager.context(threadId: thread.id).tokens, [3])
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [4], tokens: [4], toolCalls: [], compacted: false,
      systemSeenMemoryContext: reviewed)
    let history = manager.history(threadId: thread.id)
    XCTAssertTrue(manager.rewriteHistory(threadId: thread.id, nodes: history, model: "other.ckpt"))
    let afterRefresh = ProjectHistoryManager.memoryContext(
      history: manager.history(threadId: thread.id))
    XCTAssertEqual(afterRefresh.memoryContext, reviewed)
    XCTAssertEqual(afterRefresh.systemSeenMemoryContext, reviewed)
    // An earlier history prefix cannot pick up a later review's metadata.
    let earlier = ProjectHistoryManager.memoryContext(history: Array(history.prefix(2)))
    XCTAssertEqual(earlier.memoryContext, initial)
    XCTAssertEqual(earlier.systemSeenMemoryContext, initial)
  }

  func testMemoryEventsInheritOnlyUnobservedTargets() throws {
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Memory events", model: "model.ckpt", tokens: [1])
    let initial = MemoryContext(user: "User", memory: "Initial")
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [2], tokens: [2], toolCalls: [], compacted: false,
      memoryContext: initial, systemSeenMemoryContext: initial)
    // Reading MEMORY.md must not replace USER.md with whatever is currently on disk.
    let observed = MemoryContext(memory: "Observed")
    for _ in 0..<2 {
      let node = try XCTUnwrap(
        manager.appendAssistant(
          threadId: thread.id, logTokens: [3], tokens: [3], toolCalls: [], compacted: false,
          memoryContext: observed))
      XCTAssertEqual(node.memoryContext, observed)
      XCTAssertNil(node.memoryContext?.user)
      XCTAssertNil(node.systemSeenMemoryContext)
    }
    let noEvent = try XCTUnwrap(
      manager.appendAssistant(
        threadId: thread.id, logTokens: [4], tokens: [4], toolCalls: [], compacted: false))
    XCTAssertNil(noEvent.memoryContext)
    let resolved = ProjectHistoryManager.memoryContext(
      history: manager.history(threadId: thread.id))
    XCTAssertEqual(resolved.memoryContext, MemoryContext(user: "User", memory: "Observed"))
    XCTAssertEqual(resolved.systemSeenMemoryContext, initial)
    // Missing targets stay missing through suspension encoding; explicit empty targets reset.
    let decoded = try JSONDecoder().decode(
      MemoryContext.self, from: JSONEncoder().encode(observed))
    XCTAssertEqual(decoded, observed)
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [5], tokens: [5], toolCalls: [], compacted: false,
      memoryContext: MemoryContext(user: "", memory: ""))
    XCTAssertEqual(
      ProjectHistoryManager.memoryContext(history: manager.history(threadId: thread.id))
        .memoryContext,
      MemoryContext(user: "", memory: ""))
  }

  func testEmbeddingSpansRoundTripAndRebaseAcrossHistoryNodes() throws {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Images", model: "model.ckpt", tokens: [1])
    let span = EmbedSpan(
      start: 1, length: 2, digest: Array(repeating: 7, count: 32), kind: .image)
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [10, 129264, 129264, 11], embedSpans: [span],
      tokens: [11], toolCalls: [], compacted: false)
    _ = appendUser(manager, threadId: thread.id, tokens: [12])
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [20, 129264, 129264, 21], embedSpans: [span],
      tokens: [21], toolCalls: [], compacted: false)
    let expected = [span, span.offset(by: 4)]
    XCTAssertEqual(manager.context(threadId: thread.id).embedSpans, expected)
    workspace.shutdown(flags: [])
    workspace = SQLiteWorkspace(filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restored = ProjectHistoryManager(project: workspace)
    XCTAssertEqual(
      restored.context(threadId: thread.id).tokens,
      [10, 129264, 129264, 11, 20, 129264, 129264, 21])
    XCTAssertEqual(restored.context(threadId: thread.id).embedSpans, expected)
    XCTAssertEqual(restored.history(threadId: thread.id).last?.embedSpans, [span])
    XCTAssertEqual(restored.history(threadId: thread.id).first?.embedSpans, [])
  }

  func testUserImagePathsPersistThroughReplace() throws {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = manager.createThread(
      title: "Images", model: "model.ckpt", userTokens: [1], textEdits: 1, textLineage: 0,
      imagePaths: ["a.png"])
    let first = try XCTUnwrap(manager.history(threadId: thread.id).first)
    XCTAssertEqual(first.imagePaths, ["a.png"])
    let replaced = try XCTUnwrap(
      manager.replaceUser(
        threadId: thread.id, datetime: first.datetime, tokens: [1, 2], textEdits: 2,
        textLineage: 0, imagePaths: ["a.png", "b.png"]))
    XCTAssertEqual(replaced.imagePaths, ["a.png", "b.png"])
    _ = try XCTUnwrap(
      manager.appendUser(
        threadId: thread.id, tokens: [3], textEdits: 3, textLineage: 0, imagePaths: ["c.png"]))
    workspace.shutdown(flags: [])
    workspace = SQLiteWorkspace(filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restored = ProjectHistoryManager(project: workspace)
    XCTAssertEqual(
      restored.history(threadId: thread.id).map(\.imagePaths), [["a.png", "b.png"], ["c.png"]])
  }

  func testCompactionReplacesSpansAndRewritePreservesThem() throws {
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Images", model: "model.ckpt", tokens: [1])
    let old = EmbedSpan(
      start: 0, length: 2, digest: Array(repeating: 1, count: 32), kind: .image)
    let kept = EmbedSpan(
      start: 1, length: 1, digest: Array(repeating: 2, count: 32), kind: .image)
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [2, 2], embedSpans: [old], tokens: [], toolCalls: [],
      compacted: false)
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [3, 2, 4], embedSpans: [kept], tokens: [], toolCalls: [],
      compacted: true)
    _ = manager.appendAssistant(
      threadId: thread.id, logTokens: [5, 2, 6], embedSpans: [kept], tokens: [], toolCalls: [],
      compacted: false)
    XCTAssertEqual(manager.context(threadId: thread.id).tokens, [3, 2, 4, 5, 2, 6])
    XCTAssertEqual(manager.context(threadId: thread.id).embedSpans, [kept, kept.offset(by: 3)])
    XCTAssertTrue(
      manager.rewriteHistory(
        threadId: thread.id, nodes: manager.history(threadId: thread.id), model: "new.ckpt"))
    XCTAssertEqual(manager.context(threadId: thread.id).embedSpans, [kept, kept.offset(by: 3)])
  }

  func testImageFilesAreCopiedByEncodedFileDigest() throws {
    let source = temporaryDirectory.appendingPathComponent("input.jpg")
    let original = Data("abc".utf8)
    try original.write(to: source)
    let store = EmbedsFileStore(projectPath: temporaryDirectory.path)
    let digest = try store.insert(filePath: source.path)
    XCTAssertEqual(
      digest.map { String(format: "%02x", $0) }.joined(),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let stored = store.filePath(for: digest)
    XCTAssertEqual(
      URL(fileURLWithPath: stored).deletingLastPathComponent().path,
      temporaryDirectory.appendingPathComponent(".localc/cas").path)
    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let storedAttributes = try FileManager.default.attributesOfItem(atPath: stored)
    XCTAssertNotEqual(
      sourceAttributes[.systemFileNumber] as? NSNumber,
      storedAttributes[.systemFileNumber] as? NSNumber)
    XCTAssertEqual(try store.insert(filePath: source.path), digest)
    let alias = temporaryDirectory.appendingPathComponent("image-link.jpg")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    XCTAssertEqual(try store.insert(filePath: alias.path), digest)
    // Overwriting the source in place keeps its inode; the CAS entry must not follow it.
    let file = try FileHandle(forWritingTo: source)
    try file.write(contentsOf: Data("xyz".utf8))
    try file.close()
    XCTAssertEqual(
      sourceAttributes[.systemFileNumber] as? NSNumber,
      try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber]
        as? NSNumber)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stored)), original)
    try FileManager.default.removeItem(at: source)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stored)), original)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: URL(fileURLWithPath: stored).deletingLastPathComponent().path
      ).count, 1)
  }

  func testLockedImageFilesAreCopiedUnlocked() throws {
    let source = temporaryDirectory.appendingPathComponent("locked.jpg")
    let original = Data("abc".utf8)
    try original.write(to: source)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: source.path)
    defer {
      try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: source.path)
    }
    let store = EmbedsFileStore(projectPath: temporaryDirectory.path)
    let digest = try store.insert(filePath: source.path)
    XCTAssertEqual(
      digest.map { String(format: "%02x", $0) }.joined(),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let stored = store.filePath(for: digest)
    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let storedAttributes = try FileManager.default.attributesOfItem(atPath: stored)
    XCTAssertNotEqual(
      sourceAttributes[.systemFileNumber] as? NSNumber,
      storedAttributes[.systemFileNumber] as? NSNumber)
    XCTAssertEqual(storedAttributes[.immutable] as? Bool, false)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stored)), original)
    XCTAssertEqual(try store.insert(filePath: source.path), digest)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: URL(fileURLWithPath: stored).deletingLastPathComponent().path
      ).count, 1)
  }

  func testSpanCoordinatesSurviveTextEditsSlicesAndCodableRoundTrip() throws {
    let span = EmbedSpan(
      start: 8, length: 3, digest: Array(repeating: 5, count: 32), kind: .image)
    let moved = EmbedSpan.replacingTokens([span], range: 2..<6, replacementCount: 1)
    XCTAssertEqual(moved, [span.offset(by: -3)])
    XCTAssertEqual(EmbedSpan.slice(moved, range: 3..<10), [span.offset(by: -6)])
    XCTAssertEqual(
      try JSONDecoder().decode([EmbedSpan].self, from: JSONEncoder().encode(moved)), moved)
    // The former runtime span encoded its digest as Data (base64), not a byte array.
    let savedSession = Data(
      #"[{"start":5,"length":3,"digest":"BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU=","kind":0}]"#
        .utf8)
    XCTAssertEqual(try JSONDecoder().decode([EmbedSpan].self, from: savedSession), moved)
  }

  func testCreateThreadPersistsMetadataAndFirstUserNode() {
    let manager = ProjectHistoryManager(project: workspace)

    let thread = manager.createThread(
      title: "First prompt", model: "model.ckpt", userTokens: [1, 2], textEdits: 1,
      textLineage: 0)

    XCTAssertEqual(thread.id, 1)
    XCTAssertEqual(thread.title, "First prompt")
    XCTAssertEqual(thread.createdAt, thread.id)
    XCTAssertEqual(thread.model, "model.ckpt")
    XCTAssertEqual(thread.turnCountSinceLastReview, 0)
    let history = manager.history(threadId: thread.id)
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(thread.updatedAt, history[0].datetime)
    XCTAssertEqual(history[0].role, .user)
    XCTAssertEqual(history[0].tokens, [1, 2])
    XCTAssertEqual(history[0].logTokens, [])
    XCTAssertEqual(history[0].textEdits, 1)
    XCTAssertEqual(history[0].textLineage, 0)
    XCTAssertNil(history[0].plaintext)
    XCTAssertNil(history[0].logPlaintext)
    XCTAssertEqual(history[0].duration, 0)
  }

  func testAssistantDurationPersists() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    let assistant = appendAssistant(
      manager, threadId: thread.id, logTokens: [2], tokens: [3], duration: 62.5,
      compacted: false)

    XCTAssertEqual(assistant.duration, 62.5)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restoredAssistant = ProjectHistoryManager(project: workspace).history(
      threadId: thread.id
    ).last
    XCTAssertEqual(restoredAssistant?.duration, 62.5)
  }

  func testTurnCountSinceLastReviewPersistsAcrossReopenAndModelChanges() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    var manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    let otherThread = createThread(manager, title: "Other", model: "model.ckpt", tokens: [1])
    _ = appendUser(manager, threadId: thread.id, tokens: [2])
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [3], tokens: [3], compacted: false)
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 0)

    for _ in 0..<11 {
      _ = appendAssistant(
        manager, threadId: thread.id, logTokens: [4], tokens: [4], compacted: false,
        incrementTurnCountSinceLastReview: true)
    }
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 11)
    XCTAssertTrue(manager.updateThreadModel(id: thread.id, model: "replacement.ckpt"))
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    manager = ProjectHistoryManager(project: workspace)
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 11)
    XCTAssertEqual(manager.thread(id: thread.id)?.model, "replacement.ckpt")
    XCTAssertEqual(manager.thread(id: otherThread.id)?.turnCountSinceLastReview, 0)
    XCTAssertEqual(manager.history(threadId: thread.id).filter { $0.role == .assistant }.count, 12)
  }

  func testReviewCountResetPersistsWithoutChangingHistoryOrRecency() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    var manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [2], tokens: [2], compacted: false,
      incrementTurnCountSinceLastReview: true)
    let updatedAt = manager.thread(id: thread.id)?.updatedAt
    let history = manager.history(threadId: thread.id)
    XCTAssertTrue(
      manager.setThreadTurnCountSinceLastReview(id: thread.id, turnCountSinceLastReview: 0))
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 0)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    manager = ProjectHistoryManager(project: workspace)
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 0)
    XCTAssertEqual(manager.thread(id: thread.id)?.updatedAt, updatedAt)
    XCTAssertEqual(manager.history(threadId: thread.id), history)
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [3], tokens: [3], compacted: false,
      incrementTurnCountSinceLastReview: true)
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 1)
  }

  func testReviewCountReductionPersistsAndNextTurnIncrementsReducedCount() throws {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    var manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    for _ in 0..<11 {
      _ = appendAssistant(
        manager, threadId: thread.id, logTokens: [2], tokens: [2], compacted: false,
        incrementTurnCountSinceLastReview: true)
    }
    let beforeReview = try XCTUnwrap(manager.thread(id: thread.id))
    let history = manager.history(threadId: thread.id)
    XCTAssertTrue(
      manager.setThreadTurnCountSinceLastReview(
        id: thread.id, turnCountSinceLastReview: beforeReview.turnCountSinceLastReview / 2))
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 5)
    XCTAssertEqual(manager.thread(id: thread.id)?.updatedAt, beforeReview.updatedAt)
    XCTAssertEqual(manager.history(threadId: thread.id), history)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    manager = ProjectHistoryManager(project: workspace)
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 5)
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [3], tokens: [3], compacted: false,
      incrementTurnCountSinceLastReview: true)
    XCTAssertEqual(manager.thread(id: thread.id)?.turnCountSinceLastReview, 6)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    XCTAssertEqual(
      ProjectHistoryManager(project: workspace).thread(id: thread.id)?.turnCountSinceLastReview, 6)
  }

  func testUnreadResponseStatusPersistsAndCanBeCleared() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    var manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [2], tokens: [3], compacted: false)
    XCTAssertTrue(
      manager.setThreadHasUnreadResponse(id: thread.id, hasUnreadResponse: true))

    XCTAssertEqual(manager.thread(id: thread.id)?.hasUnreadResponse, true)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    manager = ProjectHistoryManager(project: workspace)
    XCTAssertEqual(manager.thread(id: thread.id)?.hasUnreadResponse, true)

    XCTAssertTrue(
      manager.setThreadHasUnreadResponse(id: thread.id, hasUnreadResponse: false))
    XCTAssertEqual(manager.thread(id: thread.id)?.hasUnreadResponse, false)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    XCTAssertEqual(
      ProjectHistoryManager(project: workspace).thread(id: thread.id)?.hasUnreadResponse, false)
  }

  func testIncompleteResponseStatusPersistsAndCanBeCleared() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    var manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    XCTAssertTrue(
      manager.setThreadHasIncompleteResponse(id: thread.id, hasIncompleteResponse: true))

    XCTAssertEqual(manager.thread(id: thread.id)?.hasIncompleteResponse, true)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    manager = ProjectHistoryManager(project: workspace)
    XCTAssertEqual(manager.thread(id: thread.id)?.hasIncompleteResponse, true)

    XCTAssertTrue(
      manager.setThreadHasIncompleteResponse(id: thread.id, hasIncompleteResponse: false))
    XCTAssertEqual(manager.thread(id: thread.id)?.hasIncompleteResponse, false)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    XCTAssertEqual(
      ProjectHistoryManager(project: workspace).thread(id: thread.id)?.hasIncompleteResponse,
      false)
  }

  func testPlaintextNodesPersistWithoutTokenRepresentation() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = manager.createThread(
      title: "Remote prompt", model: "model.ckpt", userTokens: [], textEdits: 1,
      textLineage: 0, plaintext: "Remote prompt")
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [], tokens: [], plaintext: "Remote answer",
      logPlaintext: "Remote continuation state", compacted: false)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let history = ProjectHistoryManager(project: workspace).history(threadId: thread.id)

    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history[0].plaintext, "Remote prompt")
    XCTAssertEqual(history[0].tokens, [])
    XCTAssertEqual(history[0].logTokens, [])
    XCTAssertEqual(history[1].plaintext, "Remote answer")
    XCTAssertEqual(history[1].logPlaintext, "Remote continuation state")
    XCTAssertEqual(history[1].tokens, [])
    XCTAssertEqual(history[1].logTokens, [])
    XCTAssertEqual(history[1].toolCalls, [])
  }

  func testContextContainsOnlyCompletedAssistantLogTokens() {
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [10, 11], tokens: [2], compacted: false)
    _ = appendUser(manager, threadId: thread.id, tokens: [3])

    XCTAssertEqual(manager.context(threadId: thread.id).tokens, [10, 11])
    XCTAssertEqual(
      manager.history(threadId: thread.id).map(\.role), [.user, .assistant, .user])
  }

  func testCompactedAssistantReplacesEarlierContext() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [10, 11], tokens: [2], compacted: false)
    _ = appendUser(manager, threadId: thread.id, tokens: [3])
    let compactedAssistant = appendAssistant(
      manager, threadId: thread.id, logTokens: [20, 21], tokens: [4], compacted: true)
    _ = appendUser(manager, threadId: thread.id, tokens: [5])
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [30, 31], tokens: [6], compacted: false)

    XCTAssertTrue(compactedAssistant.compacted)
    XCTAssertEqual(manager.context(threadId: thread.id).tokens, [20, 21, 30, 31])

    workspace.shutdown(flags: [])
    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restoredManager = ProjectHistoryManager(project: workspace)

    XCTAssertEqual(restoredManager.context(threadId: thread.id).tokens, [20, 21, 30, 31])
  }

  func testAssistantToolCallsPersistInOrder() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    let toolCalls = [
      ToolCall(
        function: "read",
        parameters: [
          ToolCallParameter(name: "path", value: "Sources/One.swift")
        ]),
      ToolCall(
        function: "search",
        parameters: [
          ToolCallParameter(name: "query", value: "ProjectHistoryNode"),
          ToolCallParameter(name: "path", value: "Libraries"),
        ]),
    ]

    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [2], tokens: [], toolCalls: toolCalls,
      compacted: false)
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restoredManager = ProjectHistoryManager(project: workspace)

    let restoredAssistant = restoredManager.history(threadId: thread.id).last
    XCTAssertEqual(restoredAssistant?.toolCalls, toolCalls)
    XCTAssertNil(restoredAssistant?.plaintext)
    XCTAssertNil(restoredAssistant?.logPlaintext)
  }

  func testLastMessageTracksLatestVisibleMessage() throws {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = manager.createThread(
      title: "Thread", model: "model.ckpt", userTokens: [1], textEdits: 1, textLineage: 0,
      lastMessage: "Hello")
    XCTAssertEqual(thread.lastMessage, "Hello")
    XCTAssertEqual(thread.lastMessageRole, .user)

    _ = try XCTUnwrap(
      manager.appendAssistant(
        threadId: thread.id, logTokens: [2], tokens: [3], toolCalls: [],
        plaintext: "**bash**\n---\nDone.", compacted: false, lastMessage: "Done."))
    XCTAssertEqual(manager.thread(id: thread.id)?.lastMessage, "Done.")
    XCTAssertEqual(manager.thread(id: thread.id)?.lastMessageRole, .assistant)

    _ = try XCTUnwrap(
      manager.appendMemory(
        threadId: thread.id, memoryContext: MemoryContext(user: "User", memory: "Memory")))
    XCTAssertEqual(manager.thread(id: thread.id)?.lastMessage, "Done.")
    XCTAssertEqual(manager.thread(id: thread.id)?.lastMessageRole, .assistant)

    let user = try XCTUnwrap(
      manager.appendUser(
        threadId: thread.id, tokens: [], textEdits: 2, textLineage: 0, plaintext: "Again"))
    XCTAssertEqual(manager.thread(id: thread.id)?.lastMessage, "Again")
    XCTAssertEqual(manager.thread(id: thread.id)?.lastMessageRole, .user)

    _ = try XCTUnwrap(
      manager.replaceUser(
        threadId: thread.id, datetime: user.datetime, tokens: [4], textEdits: 3,
        textLineage: 0, lastMessage: "Replaced"))

    workspace.shutdown(flags: [])
    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restored = try XCTUnwrap(ProjectHistoryManager(project: workspace).thread(id: thread.id))
    XCTAssertEqual(restored.lastMessage, "Replaced")
    XCTAssertEqual(restored.lastMessageRole, .user)
  }

  func testDatetimeIsMonotonic() {
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    let assistant = appendAssistant(
      manager, threadId: thread.id, logTokens: [2], tokens: [3], compacted: false)
    let user = appendUser(manager, threadId: thread.id, tokens: [4])

    XCTAssertGreaterThan(assistant.datetime, thread.updatedAt)
    XCTAssertGreaterThan(user.datetime, assistant.datetime)
  }

  func testReplaceUserRemovesOldNodeAndPersistsNewCursor() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    _ = appendAssistant(
      manager, threadId: thread.id, logTokens: [2], tokens: [3], compacted: false)
    let oldUser = appendUser(
      manager, threadId: thread.id, tokens: [4], textEdits: 12, textLineage: 3)

    let replacement = try! XCTUnwrap(
      manager.replaceUser(
        threadId: thread.id, datetime: oldUser.datetime, tokens: [5, 6],
        textEdits: 18, textLineage: 4))

    XCTAssertGreaterThan(replacement.datetime, oldUser.datetime)
    XCTAssertEqual(replacement.tokens, [5, 6])
    XCTAssertEqual(replacement.textEdits, 18)
    XCTAssertEqual(replacement.textLineage, 4)
    let history = manager.history(threadId: thread.id)
    XCTAssertEqual(history.count, 3)
    XCTAssertFalse(history.contains { $0.datetime == oldUser.datetime })
    XCTAssertEqual(history.map(\.role), [.user, .assistant, .user])
    XCTAssertEqual(history.last?.datetime, replacement.datetime)
    XCTAssertEqual(manager.thread(id: thread.id)?.updatedAt, replacement.datetime)

    workspace.shutdown(flags: [])
    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restoredManager = ProjectHistoryManager(project: workspace)
    let restoredHistory = restoredManager.history(threadId: thread.id)

    XCTAssertFalse(restoredHistory.contains { $0.datetime == oldUser.datetime })
    XCTAssertEqual(restoredHistory.last?.tokens, [5, 6])
    XCTAssertEqual(restoredHistory.last?.textEdits, 18)
    XCTAssertEqual(restoredHistory.last?.textLineage, 4)
  }

  func testThreadsHaveIsolatedCompositeHistoryKeysAndRecentActivityOrder() {
    let manager = ProjectHistoryManager(project: workspace)
    let first = createThread(manager, title: "First", model: "one.ckpt", tokens: [1])
    let second = createThread(manager, title: "Second", model: "two.ckpt", tokens: [2])
    _ = appendUser(manager, threadId: first.id, tokens: [3])

    XCTAssertEqual(first.id, 1)
    XCTAssertEqual(second.id, 2)
    XCTAssertEqual(manager.history(threadId: first.id).count, 2)
    XCTAssertEqual(manager.history(threadId: second.id).count, 1)
    XCTAssertEqual(manager.threads.map(\.id), [first.id, second.id])
  }

  func testSelectionAndRename() {
    let manager = ProjectHistoryManager(project: workspace)
    let thread = createThread(manager, title: "Original", model: "one.ckpt", tokens: [1])
    manager.threadId = -1
    XCTAssertEqual(manager.threadId, -1)
    manager.threadId = thread.id
    XCTAssertEqual(manager.threadId, thread.id)

    XCTAssertTrue(manager.renameThread(id: thread.id, title: "Renamed"))

    let updatedThread = manager.thread(id: thread.id)
    XCTAssertEqual(updatedThread?.title, "Renamed")
    XCTAssertEqual(updatedThread?.model, "one.ckpt")
    XCTAssertEqual(updatedThread?.updatedAt, thread.updatedAt)

    XCTAssertTrue(manager.updateThreadModel(id: thread.id, model: "two.ckpt"))
    XCTAssertEqual(manager.thread(id: thread.id)?.model, "two.ckpt")
    XCTAssertEqual(manager.thread(id: thread.id)?.updatedAt, thread.updatedAt)
  }

  func testMissingOrInvalidSelectionSelectsNewThread() {
    let manager = ProjectHistoryManager(project: workspace)
    let first = createThread(manager, title: "First", model: "one.ckpt", tokens: [1])
    let second = createThread(manager, title: "Second", model: "two.ckpt", tokens: [2])
    _ = appendUser(manager, threadId: first.id, tokens: [3])

    XCTAssertEqual(manager.threadId, -1)
    manager.threadId = second.id + 1_000
    XCTAssertEqual(manager.threadId, -1)
  }

  func testDeleteThreadRemovesHistoryAndQueuedItemsAndUpdatesSelection() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    var manager = ProjectHistoryManager(project: workspace)
    let first = createThread(manager, title: "First", model: "one.ckpt", tokens: [1])
    let second = createThread(manager, title: "Second", model: "two.ckpt", tokens: [2])
    _ = appendAssistant(
      manager, threadId: first.id, logTokens: [3], tokens: [4], compacted: false)
    workspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      transactionContext.try(
        submit: ProjectQueuedItemChangeRequest.upsertRequest(
          ProjectQueuedItem(threadId: first.id, datetime: 10, text: "queued")))
    }
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    manager = ProjectHistoryManager(project: workspace)
    manager.threadId = first.id

    XCTAssertTrue(manager.deleteThread(id: first.id))
    XCTAssertNil(manager.thread(id: first.id))
    XCTAssertEqual(manager.history(threadId: first.id), [])
    XCTAssertEqual(manager.threads.map(\.id), [second.id])
    XCTAssertEqual(manager.threadId, second.id)
    XCTAssertFalse(manager.deleteThread(id: first.id))
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    manager = ProjectHistoryManager(project: workspace)

    XCTAssertNil(manager.thread(id: first.id))
    XCTAssertEqual(manager.history(threadId: first.id), [])
    XCTAssertEqual(manager.threads.map(\.id), [second.id])
    XCTAssertEqual(manager.threadId, second.id)
    XCTAssertTrue(
      workspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == first.id
      ).isEmpty)
  }

  func testDraftSelectionPersistsAcrossWorkspaceReopen() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let manager = ProjectHistoryManager(project: workspace)
    _ = createThread(manager, title: "Thread", model: "model.ckpt", tokens: [1])
    manager.threadId = -1
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    let restoredManager = ProjectHistoryManager(project: workspace)

    XCTAssertEqual(restoredManager.threadId, -1)
  }

  func testQueuedItemsPersistInOrderAndCanBeDeleted() {
    let databaseURL = temporaryDirectory.appendingPathComponent("metadata.sqlite3")
    let first = ProjectQueuedItem(threadId: 4, datetime: 10, text: "first")
    let second = ProjectQueuedItem(threadId: 4, datetime: 20, text: "second")
    workspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      transactionContext.try(submit: ProjectQueuedItemChangeRequest.upsertRequest(second))
      transactionContext.try(submit: ProjectQueuedItemChangeRequest.upsertRequest(first))
    }
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    var queuedItems = Array(
      workspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == 4,
        orderBy: [ProjectQueuedItem.datetime.ascending]))
    XCTAssertEqual(queuedItems.map(\.datetime), [10, 20])
    XCTAssertEqual(queuedItems.compactMap(\.text), ["first", "second"])

    workspace.performChanges([ProjectQueuedItem.self]) { transactionContext in
      guard let deletionRequest = ProjectQueuedItemChangeRequest.deletionRequest(queuedItems[0])
      else { return }
      transactionContext.try(submit: deletionRequest)
    }
    workspace.shutdown(flags: [])

    workspace = SQLiteWorkspace(
      filePath: databaseURL.path, fileProtectionLevel: .noProtection)
    queuedItems = Array(
      workspace.fetch(for: ProjectQueuedItem.self).where(
        ProjectQueuedItem.threadId == 4,
        orderBy: [ProjectQueuedItem.datetime.ascending]))
    XCTAssertEqual(queuedItems.map(\.datetime), [20])
    XCTAssertEqual(queuedItems.compactMap(\.text), ["second"])
  }
}
