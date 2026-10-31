import Algorithms
import Dflat
import Dispatch
import Foundation
import SQLiteDflat

public final class ProjectHistoryManager {
  private struct NodeIdentifier: Hashable {
    var threadId: Int64
    var datetime: Int64
  }

  private let project: SQLiteWorkspace
  private var cacheVersion = 0
  private var nodeCache = [NodeIdentifier: (node: ProjectHistoryNode?, version: Int)]()
  private var threadCache = [Int64: (thread: ProjectThread?, version: Int)]()

  public init(project: SQLiteWorkspace) {
    self.project = project
  }

  public var threadId: Int64 {
    get {
      dispatchPrecondition(condition: .onQueue(.main))
      guard
        let selectedThreadId =
          project.dictionary["selected_thread_identifier", Int.self].map(Int64.init)
      else {
        return -1
      }
      guard selectedThreadId != -1 else {
        return selectedThreadId
      }
      return thread(id: selectedThreadId)?.id ?? -1
    }
    set {
      dispatchPrecondition(condition: .onQueue(.main))
      project.dictionary["selected_thread_identifier", Int.self] = Int(newValue)
    }
  }

  public var threads: [ProjectThread] {
    dispatchPrecondition(condition: .onQueue(.main))
    var threads = project.fetch(for: ProjectThread.self).all(
      orderBy: [ProjectThread.updatedAt.descending, ProjectThread.id.descending]
    ).filter { threadCache[$0.id] == nil }
    for cachedThread in threadCache.values {
      guard let thread = cachedThread.thread else { continue }
      let index = threads.partitioningIndex {
        if $0.updatedAt != thread.updatedAt {
          return $0.updatedAt < thread.updatedAt
        }
        return $0.id < thread.id
      }
      threads.insert(thread, at: index)
    }
    return threads
  }

  public func thread(id: Int64) -> ProjectThread? {
    dispatchPrecondition(condition: .onQueue(.main))
    if let cachedThread = threadCache[id] {
      return cachedThread.thread
    }
    return project.fetch(for: ProjectThread.self).where(
      ProjectThread.id == id, limit: .limit(1)
    ).first
  }

  public func cachedThread(id: Int64) -> ProjectThread? {
    dispatchPrecondition(condition: .onQueue(.main))
    return threadCache[id]?.thread
  }

  public func history(threadId: Int64) -> [ProjectHistoryNode] {
    dispatchPrecondition(condition: .onQueue(.main))
    var nodes = project.fetch(for: ProjectHistoryNode.self).where(
      ProjectHistoryNode.threadId == threadId,
      orderBy: [ProjectHistoryNode.datetime.ascending]
    ).filter {
      nodeCache[NodeIdentifier(threadId: $0.threadId, datetime: $0.datetime)] == nil
    }
    for (identifier, cachedNode) in nodeCache where identifier.threadId == threadId {
      guard let node = cachedNode.node else { continue }
      let index = nodes.partitioningIndex { $0.datetime > node.datetime }
      nodes.insert(node, at: index)
    }
    return nodes
  }

  public func context(threadId: Int64) -> (tokens: [Int32], embedSpans: [EmbedSpan]) {
    dispatchPrecondition(condition: .onQueue(.main))
    return Self.context(history: history(threadId: threadId))
  }

  public static func context(history: [ProjectHistoryNode]) -> (
    tokens: [Int32], embedSpans: [EmbedSpan]
  ) {
    var logTokens = [Int32]()
    var embedSpans = [EmbedSpan]()
    for node in history where node.role == .assistant {
      if node.compacted {
        logTokens.removeAll(keepingCapacity: true)
        embedSpans.removeAll(keepingCapacity: true)
      }
      embedSpans += node.embedSpans.map { $0.offset(by: logTokens.count) }
      logTokens += node.logTokens
    }
    return (logTokens, embedSpans)
  }

  /// Resolve the latest observed targets and system snapshot, including metadata-only review nodes.
  public static func memoryContext(history: [ProjectHistoryNode]) -> (
    memoryContext: MemoryContext?, systemSeenMemoryContext: MemoryContext?
  ) {
    var memoryContext: MemoryContext?
    var systemSeenMemoryContext: MemoryContext?
    for node in history {
      if let context = node.memoryContext {
        memoryContext = MemoryContext(
          user: context.user ?? memoryContext?.user,
          memory: context.memory ?? memoryContext?.memory)
      }
      if let context = node.systemSeenMemoryContext { systemSeenMemoryContext = context }
    }
    return (memoryContext, systemSeenMemoryContext)
  }

  @discardableResult
  public func createThread(
    title: String, model: String, userTokens: [Int32], textEdits: Int, textLineage: Int64,
    plaintext: String? = nil, imagePaths: [String] = [], lastMessage: String? = nil
  ) -> ProjectThread {
    dispatchPrecondition(condition: .onQueue(.main))
    let id = newThreadId()
    let datetime = newDatetime()
    let thread = ProjectThread(
      id: id, title: title, createdAt: id, updatedAt: datetime, model: model,
      lastMessage: lastMessage ?? plaintext, lastMessageRole: .user)
    let node = ProjectHistoryNode(
      threadId: id, datetime: datetime, role: .user, tokens: userTokens,
      textEdits: Int64(textEdits), textLineage: textLineage, plaintext: plaintext,
      imagePaths: imagePaths)
    let version = uniqueCacheVersion()
    threadCache[id] = (thread, version)
    let nodeIdentifier = NodeIdentifier(threadId: id, datetime: datetime)
    nodeCache[nodeIdentifier] = (node, version)
    project.performChanges([ProjectThread.self, ProjectHistoryNode.self]) { transactionContext in
      transactionContext.try(submit: ProjectThreadChangeRequest.upsertRequest(thread))
      transactionContext.try(submit: ProjectHistoryNodeChangeRequest.upsertRequest(node))
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.threadCache[id]?.version == version {
          self.threadCache[id] = nil
        }
        if self.nodeCache[nodeIdentifier]?.version == version {
          self.nodeCache[nodeIdentifier] = nil
        }
      }
    }
    return thread
  }

  @discardableResult
  public func appendUser(
    threadId: Int64, tokens: [Int32], textEdits: Int, textLineage: Int64,
    plaintext: String? = nil, imagePaths: [String] = [], lastMessage: String? = nil
  ) -> ProjectHistoryNode? {
    dispatchPrecondition(condition: .onQueue(.main))
    return append(
      threadId: threadId, role: .user, logTokens: [], tokens: tokens, toolCalls: [],
      textEdits: Int64(textEdits), textLineage: textLineage, plaintext: plaintext,
      logPlaintext: nil, compacted: false, imagePaths: imagePaths,
      lastMessage: lastMessage ?? plaintext)
  }

  @discardableResult
  public func appendAssistant(
    threadId: Int64, logTokens: [Int32], embedSpans: [EmbedSpan] = [], tokens: [Int32],
    toolCalls: [ToolCall], plaintext: String? = nil,
    logPlaintext: String? = nil, duration: TimeInterval = 0, compacted: Bool,
    incrementTurnCountSinceLastReview: Bool = false, memoryContext: MemoryContext? = nil,
    systemSeenMemoryContext: MemoryContext? = nil, lastMessage: String? = nil
  ) -> ProjectHistoryNode? {
    dispatchPrecondition(condition: .onQueue(.main))
    return append(
      threadId: threadId, role: .assistant, logTokens: logTokens, embedSpans: embedSpans,
      tokens: tokens,
      toolCalls: toolCalls, textEdits: -1, textLineage: -1, plaintext: plaintext,
      logPlaintext: logPlaintext, compacted: compacted, duration: duration,
      incrementTurnCountSinceLastReview: incrementTurnCountSinceLastReview,
      memoryContext: memoryContext, systemSeenMemoryContext: systemSeenMemoryContext,
      lastMessage: lastMessage)
  }

  /// Append review metadata without changing the visible conversation or its recency.
  @discardableResult
  public func appendMemory(threadId: Int64, memoryContext: MemoryContext) -> ProjectHistoryNode? {
    dispatchPrecondition(condition: .onQueue(.main))
    return append(
      threadId: threadId, role: .memory, logTokens: [], tokens: [], toolCalls: [],
      textEdits: -1, textLineage: -1, plaintext: nil, logPlaintext: nil, compacted: false,
      memoryContext: memoryContext)
  }

  @discardableResult
  public func setThreadTurnCountSinceLastReview(id: Int64, turnCountSinceLastReview: Int64) -> Bool
  {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: id) else { return false }
    guard thread.turnCountSinceLastReview != turnCountSinceLastReview else { return true }
    var builder = ProjectThreadBuilder(from: thread)
    builder.turnCountSinceLastReview = turnCountSinceLastReview
    let updatedThread = builder.build()
    let version = uniqueCacheVersion()
    threadCache[id] = (updatedThread, version)
    project.performChanges([ProjectThread.self]) { transactionContext in
      guard let changeRequest = ProjectThreadChangeRequest.changeRequest(thread) else { return }
      changeRequest.turnCountSinceLastReview = turnCountSinceLastReview
      transactionContext.try(submit: changeRequest)
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.threadCache[id]?.version == version else { return }
        self.threadCache[id] = nil
      }
    }
    return true
  }

  @discardableResult
  public func setThreadHasUnreadResponse(id: Int64, hasUnreadResponse: Bool) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: id) else { return false }
    guard thread.hasUnreadResponse != hasUnreadResponse else { return true }
    var builder = ProjectThreadBuilder(from: thread)
    builder.hasUnreadResponse = hasUnreadResponse
    let updatedThread = builder.build()
    let version = uniqueCacheVersion()
    threadCache[id] = (updatedThread, version)
    project.performChanges([ProjectThread.self]) { transactionContext in
      guard let changeRequest = ProjectThreadChangeRequest.changeRequest(thread) else { return }
      changeRequest.hasUnreadResponse = hasUnreadResponse
      transactionContext.try(submit: changeRequest)
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.threadCache[id]?.version == version else { return }
        self.threadCache[id] = nil
      }
    }
    return true
  }

  @discardableResult
  public func setThreadHasIncompleteResponse(id: Int64, hasIncompleteResponse: Bool) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: id) else { return false }
    guard thread.hasIncompleteResponse != hasIncompleteResponse else { return true }
    var builder = ProjectThreadBuilder(from: thread)
    builder.hasIncompleteResponse = hasIncompleteResponse
    let updatedThread = builder.build()
    let version = uniqueCacheVersion()
    threadCache[id] = (updatedThread, version)
    project.performChanges([ProjectThread.self]) { transactionContext in
      guard let changeRequest = ProjectThreadChangeRequest.changeRequest(thread) else { return }
      changeRequest.hasIncompleteResponse = hasIncompleteResponse
      transactionContext.try(submit: changeRequest)
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.threadCache[id]?.version == version else { return }
        self.threadCache[id] = nil
      }
    }
    return true
  }

  @discardableResult
  public func replaceUser(
    threadId: Int64, datetime: Int64, tokens: [Int32], textEdits: Int, textLineage: Int64,
    plaintext: String? = nil, imagePaths: [String] = [], lastMessage: String? = nil
  ) -> ProjectHistoryNode? {
    dispatchPrecondition(condition: .onQueue(.main))
    let oldIdentifier = NodeIdentifier(threadId: threadId, datetime: datetime)
    let oldNode: ProjectHistoryNode?
    if let cachedNode = nodeCache[oldIdentifier] {
      oldNode = cachedNode.node
    } else {
      oldNode =
        project.fetch(for: ProjectHistoryNode.self).where(
          ProjectHistoryNode.threadId == threadId && ProjectHistoryNode.datetime == datetime,
          limit: .limit(1)
        ).first
    }
    guard let oldNode, oldNode.role == .user,
      let thread = thread(id: threadId)
    else { return nil }
    let newDatetime = newDatetime()
    let node = ProjectHistoryNode(
      threadId: threadId, datetime: newDatetime, role: .user, tokens: tokens,
      textEdits: Int64(textEdits), textLineage: textLineage, plaintext: plaintext,
      imagePaths: imagePaths)
    let lastMessage = lastMessage ?? plaintext
    var threadBuilder = ProjectThreadBuilder(from: thread)
    threadBuilder.updatedAt = newDatetime
    threadBuilder.lastMessage = lastMessage
    threadBuilder.lastMessageRole = .user
    let updatedThread = threadBuilder.build()
    let version = uniqueCacheVersion()
    threadCache[threadId] = (updatedThread, version)
    nodeCache[oldIdentifier] = (nil, version)
    let newIdentifier = NodeIdentifier(threadId: threadId, datetime: newDatetime)
    nodeCache[newIdentifier] = (node, version)
    project.performChanges([ProjectThread.self, ProjectHistoryNode.self]) { transactionContext in
      guard
        let threadChangeRequest = ProjectThreadChangeRequest.changeRequest(thread),
        let nodeChangeRequest = ProjectHistoryNodeChangeRequest.changeRequest(oldNode)
      else { return }
      threadChangeRequest.updatedAt = newDatetime
      threadChangeRequest.lastMessage = lastMessage
      threadChangeRequest.lastMessageRole = .user
      nodeChangeRequest.threadId = threadId
      nodeChangeRequest.datetime = newDatetime
      nodeChangeRequest.role = .user
      nodeChangeRequest.logTokens = []
      nodeChangeRequest.embedSpans = []
      nodeChangeRequest.tokens = tokens
      nodeChangeRequest.toolCalls = []
      nodeChangeRequest.textEdits = Int64(textEdits)
      nodeChangeRequest.textLineage = textLineage
      nodeChangeRequest.plaintext = plaintext
      nodeChangeRequest.logPlaintext = nil
      nodeChangeRequest.compacted = false
      nodeChangeRequest.duration = 0
      nodeChangeRequest.imagePaths = imagePaths
      transactionContext.try(submit: threadChangeRequest)
      transactionContext.try(submit: nodeChangeRequest)
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.threadCache[threadId]?.version == version {
          self.threadCache[threadId] = nil
        }
        if self.nodeCache[oldIdentifier]?.version == version {
          self.nodeCache[oldIdentifier] = nil
        }
        if self.nodeCache[newIdentifier]?.version == version {
          self.nodeCache[newIdentifier] = nil
        }
      }
    }
    return node
  }

  @discardableResult
  public func renameThread(id: Int64, title: String) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: id) else { return false }
    var builder = ProjectThreadBuilder(from: thread)
    builder.title = title
    let updatedThread = builder.build()
    let version = uniqueCacheVersion()
    threadCache[id] = (updatedThread, version)
    project.performChanges([ProjectThread.self]) { transactionContext in
      transactionContext.try(submit: ProjectThreadChangeRequest.upsertRequest(updatedThread))
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.threadCache[id]?.version == version else { return }
        self.threadCache[id] = nil
      }
    }
    return true
  }

  public func queuedItems(threadId: Int64) -> [ProjectQueuedItem] {
    dispatchPrecondition(condition: .onQueue(.main))
    return Array(
      project.fetch(for: ProjectQueuedItem.self).where(ProjectQueuedItem.threadId == threadId))
  }

  /// Writes the thread to `destination` under a new identifier, and deletes it here only once that
  /// write succeeds and the thread has not changed meanwhile; a change takes the copy back out, so
  /// nothing written during the move is lost. That check sees this manager's writes, so anything
  /// opening the project meanwhile must share this manager. Both workspaces must stay open until
  /// `completion`, which receives the new identifier, or nil if the thread stayed here.
  public func moveThread(
    id: Int64, to destination: ProjectHistoryManager, completion: @escaping (Int64?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: id) else {
      completion(nil)
      return
    }
    let nodes = history(threadId: id)
    let queuedItems = self.queuedItems(threadId: id)
    let newId = destination.newThreadId()
    var threadBuilder = ProjectThreadBuilder(from: thread)
    threadBuilder.id = newId
    let movedThread = threadBuilder.build()
    let movedNodes = nodes.map { node -> ProjectHistoryNode in
      var builder = ProjectHistoryNodeBuilder(from: node)
      builder.threadId = newId
      return builder.build()
    }
    let movedQueuedItems = queuedItems.map { queuedItem -> ProjectQueuedItem in
      var builder = ProjectQueuedItemBuilder(from: queuedItem)
      builder.threadId = newId
      return builder.build()
    }
    let version = destination.uniqueCacheVersion()
    destination.threadCache[newId] = (movedThread, version)
    let nodeIdentifiers = movedNodes.map {
      NodeIdentifier(threadId: $0.threadId, datetime: $0.datetime)
    }
    for (nodeIdentifier, node) in zip(nodeIdentifiers, movedNodes) {
      destination.nodeCache[nodeIdentifier] = (node, version)
    }
    destination.project.performChanges([
      ProjectThread.self, ProjectHistoryNode.self, ProjectQueuedItem.self,
    ]) { transactionContext in
      transactionContext.try(submit: ProjectThreadChangeRequest.upsertRequest(movedThread))
      for node in movedNodes {
        transactionContext.try(submit: ProjectHistoryNodeChangeRequest.upsertRequest(node))
      }
      for queuedItem in movedQueuedItems {
        transactionContext.try(submit: ProjectQueuedItemChangeRequest.upsertRequest(queuedItem))
      }
    } completionHandler: { success in
      DispatchQueue.main.async {
        if destination.threadCache[newId]?.version == version {
          destination.threadCache[newId] = nil
        }
        for nodeIdentifier in nodeIdentifiers
        where destination.nodeCache[nodeIdentifier]?.version == version {
          destination.nodeCache[nodeIdentifier] = nil
        }
        guard success else {
          completion(nil)
          return
        }
        guard self.thread(id: id) == thread, self.history(threadId: id) == nodes,
          self.queuedItems(threadId: id) == queuedItems
        else {
          destination.deleteThread(id: newId)
          completion(nil)
          return
        }
        self.deleteThread(id: id)
        completion(newId)
      }
    }
  }

  @discardableResult
  public func deleteThread(id: Int64) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: id) else { return false }
    let nodes = history(threadId: id)
    let queuedItems = self.queuedItems(threadId: id)
    let wasSelected = threadId == id
    let version = uniqueCacheVersion()
    threadCache[id] = (nil, version)
    let nodeIdentifiers = nodes.map {
      NodeIdentifier(threadId: $0.threadId, datetime: $0.datetime)
    }
    for nodeIdentifier in nodeIdentifiers {
      nodeCache[nodeIdentifier] = (nil, version)
    }
    if wasSelected {
      threadId = threads.first?.id ?? -1
    }
    project.performChanges([ProjectThread.self, ProjectHistoryNode.self, ProjectQueuedItem.self]) {
      transactionContext in
      guard let threadDeletionRequest = ProjectThreadChangeRequest.deletionRequest(thread) else {
        return
      }
      let nodeDeletionRequests = nodes.compactMap(ProjectHistoryNodeChangeRequest.deletionRequest)
      guard nodeDeletionRequests.count == nodes.count else { return }
      let queuedItemDeletionRequests = queuedItems.compactMap(
        ProjectQueuedItemChangeRequest.deletionRequest)
      guard queuedItemDeletionRequests.count == queuedItems.count else { return }
      transactionContext.try(submit: threadDeletionRequest)
      for nodeDeletionRequest in nodeDeletionRequests {
        transactionContext.try(submit: nodeDeletionRequest)
      }
      for queuedItemDeletionRequest in queuedItemDeletionRequests {
        transactionContext.try(submit: queuedItemDeletionRequest)
      }
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.threadCache[id]?.version == version {
          self.threadCache[id] = nil
        }
        for nodeIdentifier in nodeIdentifiers
        where self.nodeCache[nodeIdentifier]?.version == version {
          self.nodeCache[nodeIdentifier] = nil
        }
      }
    }
    return true
  }

  @discardableResult
  public func updateThreadModel(id: Int64, model: String) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: id) else { return false }
    var builder = ProjectThreadBuilder(from: thread)
    builder.model = model
    let updatedThread = builder.build()
    let version = uniqueCacheVersion()
    threadCache[id] = (updatedThread, version)
    project.performChanges([ProjectThread.self]) { transactionContext in
      transactionContext.try(submit: ProjectThreadChangeRequest.upsertRequest(updatedThread))
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self, self.threadCache[id]?.version == version else { return }
        self.threadCache[id] = nil
      }
    }
    return true
  }

  @discardableResult
  public func rewriteHistory(
    threadId: Int64, nodes: [ProjectHistoryNode], model: String
  ) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: threadId), nodes.allSatisfy({ $0.threadId == threadId }) else {
      return false
    }
    let existingIdentifiers = Set(
      history(threadId: threadId).map {
        NodeIdentifier(threadId: $0.threadId, datetime: $0.datetime)
      })
    let rewrittenIdentifiers = Set(
      nodes.map { NodeIdentifier(threadId: $0.threadId, datetime: $0.datetime) })
    guard existingIdentifiers == rewrittenIdentifiers else { return false }

    var threadBuilder = ProjectThreadBuilder(from: thread)
    threadBuilder.model = model
    let updatedThread = threadBuilder.build()
    let version = uniqueCacheVersion()
    threadCache[threadId] = (updatedThread, version)
    for node in nodes {
      nodeCache[NodeIdentifier(threadId: node.threadId, datetime: node.datetime)] = (node, version)
    }
    project.performChanges([ProjectThread.self, ProjectHistoryNode.self]) { transactionContext in
      transactionContext.try(submit: ProjectThreadChangeRequest.upsertRequest(updatedThread))
      for node in nodes {
        transactionContext.try(submit: ProjectHistoryNodeChangeRequest.upsertRequest(node))
      }
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.threadCache[threadId]?.version == version {
          self.threadCache[threadId] = nil
        }
        for node in nodes {
          let identifier = NodeIdentifier(threadId: node.threadId, datetime: node.datetime)
          if self.nodeCache[identifier]?.version == version {
            self.nodeCache[identifier] = nil
          }
        }
      }
    }
    return true
  }

  private func append(
    threadId: Int64, role: ProjectHistoryRole, logTokens: [Int32],
    embedSpans: [EmbedSpan] = [], tokens: [Int32],
    toolCalls: [ToolCall], textEdits: Int64, textLineage: Int64,
    plaintext: String?, logPlaintext: String?, compacted: Bool, duration: TimeInterval = 0,
    incrementTurnCountSinceLastReview: Bool = false, memoryContext: MemoryContext? = nil,
    systemSeenMemoryContext: MemoryContext? = nil, imagePaths: [String] = [],
    lastMessage: String? = nil
  ) -> ProjectHistoryNode? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let thread = thread(id: threadId) else { return nil }
    let datetime = newDatetime()
    let node = ProjectHistoryNode(
      threadId: threadId, datetime: datetime, role: role, logTokens: logTokens,
      tokens: tokens, toolCalls: toolCalls, textEdits: textEdits, textLineage: textLineage,
      plaintext: plaintext, logPlaintext: logPlaintext, compacted: compacted,
      duration: duration, embedSpans: embedSpans, memoryContext: memoryContext,
      systemSeenMemoryContext: systemSeenMemoryContext, imagePaths: imagePaths)
    var threadBuilder = ProjectThreadBuilder(from: thread)
    if role != .memory {
      threadBuilder.updatedAt = datetime
      threadBuilder.lastMessage = lastMessage
      threadBuilder.lastMessageRole = role
    }
    if incrementTurnCountSinceLastReview {
      threadBuilder.turnCountSinceLastReview += 1
    }
    let updatedThread = threadBuilder.build()
    let version = uniqueCacheVersion()
    threadCache[threadId] = (updatedThread, version)
    let nodeIdentifier = NodeIdentifier(threadId: threadId, datetime: datetime)
    nodeCache[nodeIdentifier] = (node, version)
    project.performChanges([ProjectThread.self, ProjectHistoryNode.self]) { transactionContext in
      transactionContext.try(submit: ProjectThreadChangeRequest.upsertRequest(updatedThread))
      transactionContext.try(submit: ProjectHistoryNodeChangeRequest.upsertRequest(node))
    } completionHandler: { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.threadCache[threadId]?.version == version {
          self.threadCache[threadId] = nil
        }
        if self.nodeCache[nodeIdentifier]?.version == version {
          self.nodeCache[nodeIdentifier] = nil
        }
      }
    }
    return node
  }

  private func uniqueCacheVersion() -> Int {
    dispatchPrecondition(condition: .onQueue(.main))
    let version = cacheVersion
    cacheVersion += 1
    return version
  }

  private func newThreadId() -> Int64 {
    dispatchPrecondition(condition: .onQueue(.main))
    let latestPersistedIdentifier =
      project.fetch(for: ProjectThread.self).all(
        limit: .limit(1), orderBy: [ProjectThread.id.descending]
      ).first?.id ?? 0
    let latestCachedIdentifier = threadCache.keys.max() ?? 0
    return max(latestPersistedIdentifier, latestCachedIdentifier) + 1
  }

  private func newDatetime() -> Int64 {
    dispatchPrecondition(condition: .onQueue(.main))
    let latestPersistedDatetime =
      project.fetch(for: ProjectHistoryNode.self).all(
        limit: .limit(1),
        orderBy: [ProjectHistoryNode.datetime.descending]
      ).first?.datetime ?? -1
    let latestCachedDatetime = nodeCache.keys.lazy.map(\.datetime).max() ?? -1
    let wallClock = Int64(Date().timeIntervalSince1970 * 1_000)
    return max(wallClock, max(latestPersistedDatetime, latestCachedDatetime) + 1)
  }
}
