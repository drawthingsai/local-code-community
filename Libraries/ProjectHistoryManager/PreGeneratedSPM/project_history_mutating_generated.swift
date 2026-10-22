import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

// MARK - SQLiteValue for Enumerations

extension ProjectHistoryRole: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

extension EmbedKind: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

// MARK - Serializer

extension MemoryContext: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __user = self.user.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __memory = self.memory.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let start = zzz_DflatGen_MemoryContext.startMemoryContext(&flatBufferBuilder)
    zzz_DflatGen_MemoryContext.add(user: __user, &flatBufferBuilder)
    zzz_DflatGen_MemoryContext.add(memory: __memory, &flatBufferBuilder)
    return zzz_DflatGen_MemoryContext.endMemoryContext(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == MemoryContext {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension ToolCallParameter: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __name = self.name.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __value = self.value.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let start = zzz_DflatGen_ToolCallParameter.startToolCallParameter(&flatBufferBuilder)
    zzz_DflatGen_ToolCallParameter.add(name: __name, &flatBufferBuilder)
    zzz_DflatGen_ToolCallParameter.add(value: __value, &flatBufferBuilder)
    return zzz_DflatGen_ToolCallParameter.endToolCallParameter(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == ToolCallParameter {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension ToolCall: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __function = self.function.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    var __parameters = [Offset]()
    for i in self.parameters {
      __parameters.append(i.to(flatBufferBuilder: &flatBufferBuilder))
    }
    let __vector_parameters = flatBufferBuilder.createVector(ofOffsets: __parameters)
    let start = zzz_DflatGen_ToolCall.startToolCall(&flatBufferBuilder)
    zzz_DflatGen_ToolCall.add(function: __function, &flatBufferBuilder)
    zzz_DflatGen_ToolCall.addVectorOf(parameters: __vector_parameters, &flatBufferBuilder)
    return zzz_DflatGen_ToolCall.endToolCall(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == ToolCall {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension EmbedSpan: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __vector_digest = flatBufferBuilder.createVector(self.digest)
    let __kind = zzz_DflatGen_EmbedKind(rawValue: self.kind.rawValue) ?? .image
    let start = zzz_DflatGen_EmbedSpan.startEmbedSpan(&flatBufferBuilder)
    zzz_DflatGen_EmbedSpan.add(start: self.start, &flatBufferBuilder)
    zzz_DflatGen_EmbedSpan.add(length: self.length, &flatBufferBuilder)
    zzz_DflatGen_EmbedSpan.addVectorOf(digest: __vector_digest, &flatBufferBuilder)
    zzz_DflatGen_EmbedSpan.add(kind: __kind, &flatBufferBuilder)
    return zzz_DflatGen_EmbedSpan.endEmbedSpan(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == EmbedSpan {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension ProjectHistoryNode: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __role = zzz_DflatGen_ProjectHistoryRole(rawValue: self.role.rawValue) ?? .user
    let __vector_logTokens = flatBufferBuilder.createVector(self.logTokens)
    let __vector_tokens = flatBufferBuilder.createVector(self.tokens)
    var __toolCalls = [Offset]()
    for i in self.toolCalls {
      __toolCalls.append(i.to(flatBufferBuilder: &flatBufferBuilder))
    }
    let __vector_toolCalls = flatBufferBuilder.createVector(ofOffsets: __toolCalls)
    let __plaintext = self.plaintext.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __logPlaintext = self.logPlaintext.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    var __embedSpans = [Offset]()
    for i in self.embedSpans {
      __embedSpans.append(i.to(flatBufferBuilder: &flatBufferBuilder))
    }
    let __vector_embedSpans = flatBufferBuilder.createVector(ofOffsets: __embedSpans)
    let __memoryContext = self.memoryContext.to(flatBufferBuilder: &flatBufferBuilder)
    let __systemSeenMemoryContext = self.systemSeenMemoryContext.to(
      flatBufferBuilder: &flatBufferBuilder)
    var __imagePaths = [Offset]()
    for i in imagePaths {
      __imagePaths.append(flatBufferBuilder.create(string: i))
    }
    let __vector_imagePaths = flatBufferBuilder.createVector(ofOffsets: __imagePaths)
    let start = zzz_DflatGen_ProjectHistoryNode.startProjectHistoryNode(&flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(threadId: self.threadId, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(datetime: self.datetime, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(role: __role, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.addVectorOf(logTokens: __vector_logTokens, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.addVectorOf(tokens: __vector_tokens, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.addVectorOf(toolCalls: __vector_toolCalls, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(textEdits: self.textEdits, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(textLineage: self.textLineage, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(plaintext: __plaintext, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(logPlaintext: __logPlaintext, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(compacted: self.compacted, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(duration: self.duration, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.addVectorOf(embedSpans: __vector_embedSpans, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(memoryContext: __memoryContext, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.add(
      systemSeenMemoryContext: __systemSeenMemoryContext, &flatBufferBuilder)
    zzz_DflatGen_ProjectHistoryNode.addVectorOf(imagePaths: __vector_imagePaths, &flatBufferBuilder)
    return zzz_DflatGen_ProjectHistoryNode.endProjectHistoryNode(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == ProjectHistoryNode {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension ProjectHistoryNode {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class ProjectHistoryNodeChangeRequest: Dflat.ChangeRequest {
  private var _o: ProjectHistoryNode?
  public typealias Element = ProjectHistoryNode
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var threadId: Int64
  public var datetime: Int64
  public var role: ProjectHistoryRole
  public var logTokens: [Int32]
  public var tokens: [Int32]
  public var toolCalls: [ToolCall]
  public var textEdits: Int64
  public var textLineage: Int64
  public var plaintext: String?
  public var logPlaintext: String?
  public var compacted: Bool
  public var duration: Double
  public var embedSpans: [EmbedSpan]
  public var memoryContext: MemoryContext?
  public var systemSeenMemoryContext: MemoryContext?
  public var imagePaths: [String]
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    threadId = 0
    datetime = 0
    role = .user
    logTokens = []
    tokens = []
    toolCalls = []
    textEdits = -1
    textLineage = -1
    plaintext = nil
    logPlaintext = nil
    compacted = false
    duration = 0.0
    embedSpans = []
    memoryContext = nil
    systemSeenMemoryContext = nil
    imagePaths = []
  }
  private init(type _type: ChangeRequestType, _ _o: ProjectHistoryNode) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    threadId = _o.threadId
    datetime = _o.datetime
    role = _o.role
    logTokens = _o.logTokens
    tokens = _o.tokens
    toolCalls = _o.toolCalls
    textEdits = _o.textEdits
    textLineage = _o.textLineage
    plaintext = _o.plaintext
    logPlaintext = _o.logPlaintext
    compacted = _o.compacted
    duration = _o.duration
    embedSpans = _o.embedSpans
    memoryContext = _o.memoryContext
    systemSeenMemoryContext = _o.systemSeenMemoryContext
    imagePaths = _o.imagePaths
  }
  public static func changeRequest(_ o: ProjectHistoryNode) -> ProjectHistoryNodeChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey =
      o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.threadId, o.datetime])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: ProjectHistoryNode.self, for: key)
    return u.map { ProjectHistoryNodeChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: ProjectHistoryNode) -> ProjectHistoryNodeChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey =
      o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.threadId, o.datetime])
    guard
      let u = transactionContext.objectRepository.object(
        transactionContext.connection, ofType: ProjectHistoryNode.self, for: key)
    else {
      return Self.creationRequest(o)
    }
    let changeRequest = ProjectHistoryNodeChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: ProjectHistoryNode) -> ProjectHistoryNodeChangeRequest {
    let creationRequest = ProjectHistoryNodeChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> ProjectHistoryNodeChangeRequest {
    return ProjectHistoryNodeChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: ProjectHistoryNode) -> ProjectHistoryNodeChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey =
      o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.threadId, o.datetime])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: ProjectHistoryNode.self, for: key)
    return u.map { ProjectHistoryNodeChangeRequest(type: .deletion, $0) }
  }
  var _atom: ProjectHistoryNode {
    let atom = ProjectHistoryNode(
      threadId: threadId, datetime: datetime, role: role, logTokens: logTokens, tokens: tokens,
      toolCalls: toolCalls, textEdits: textEdits, textLineage: textLineage, plaintext: plaintext,
      logPlaintext: logPlaintext, compacted: compacted, duration: duration, embedSpans: embedSpans,
      memoryContext: memoryContext, systemSeenMemoryContext: systemSeenMemoryContext,
      imagePaths: imagePaths)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      guard
        let insert = toolbox.connection.prepareStaticStatement(
          "INSERT INTO projecthistorynode (__pk0, __pk1, p) VALUES (?1, ?2, ?3)")
      else { return nil }
      threadId.bindSQLite(insert, parameterId: 1)
      datetime.bindSQLite(insert, parameterId: 2)
      let atom = self._atom
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(
        OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(insert, 3, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      guard SQLITE_DONE == sqlite3_step(insert) else { return nil }
      _rowid = sqlite3_last_insert_rowid(toolbox.connection.sqlite)
      _type = .none
      atom._rowid = _rowid
      return .inserted(atom)
    case .update:
      guard let o = _o else { return nil }
      let atom = self._atom
      guard atom != o else {
        _type = .none
        return .identity(atom)
      }
      guard
        let update = toolbox.connection.prepareStaticStatement(
          "REPLACE INTO projecthistorynode (__pk0, __pk1, p, rowid) VALUES (?1, ?2, ?3, ?4)")
      else { return nil }
      threadId.bindSQLite(update, parameterId: 1)
      datetime.bindSQLite(update, parameterId: 2)
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(
        OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(update, 3, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      _rowid.bindSQLite(update, parameterId: 4)
      guard SQLITE_DONE == sqlite3_step(update) else { return nil }
      _type = .none
      return .updated(atom)
    case .deletion:
      guard
        let deletion = toolbox.connection.prepareStaticStatement(
          "DELETE FROM projecthistorynode WHERE rowid=?1")
      else { return nil }
      _rowid.bindSQLite(deletion, parameterId: 1)
      guard SQLITE_DONE == sqlite3_step(deletion) else { return nil }
      _type = .none
      return .deleted(_rowid)
    case .none:
      preconditionFailure()
    }
  }
}
