import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

// MARK - SQLiteValue for Enumerations

// MARK - Serializer

extension ProjectThread: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __title = self.title.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __model = self.model.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __lastMessage = self.lastMessage.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __lastMessageRole =
      zzz_DflatGen_ProjectHistoryRole(rawValue: self.lastMessageRole.rawValue) ?? .user
    let start = zzz_DflatGen_ProjectThread.startProjectThread(&flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(id: self.id, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(title: __title, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(createdAt: self.createdAt, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(updatedAt: self.updatedAt, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(model: __model, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(hasUnreadResponse: self.hasUnreadResponse, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(
      hasIncompleteResponse: self.hasIncompleteResponse, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(
      turnCountSinceLastReview: self.turnCountSinceLastReview, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(lastMessage: __lastMessage, &flatBufferBuilder)
    zzz_DflatGen_ProjectThread.add(lastMessageRole: __lastMessageRole, &flatBufferBuilder)
    return zzz_DflatGen_ProjectThread.endProjectThread(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == ProjectThread {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension ProjectThread {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class ProjectThreadChangeRequest: Dflat.ChangeRequest {
  private var _o: ProjectThread?
  public typealias Element = ProjectThread
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var id: Int64
  public var title: String?
  public var createdAt: Int64
  public var updatedAt: Int64
  public var model: String?
  public var hasUnreadResponse: Bool
  public var hasIncompleteResponse: Bool
  public var turnCountSinceLastReview: Int64
  public var lastMessage: String?
  public var lastMessageRole: ProjectHistoryRole
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    id = 0
    title = nil
    createdAt = 0
    updatedAt = 0
    model = nil
    hasUnreadResponse = false
    hasIncompleteResponse = false
    turnCountSinceLastReview = 0
    lastMessage = nil
    lastMessageRole = .user
  }
  private init(type _type: ChangeRequestType, _ _o: ProjectThread) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    id = _o.id
    title = _o.title
    createdAt = _o.createdAt
    updatedAt = _o.updatedAt
    model = _o.model
    hasUnreadResponse = _o.hasUnreadResponse
    hasIncompleteResponse = _o.hasIncompleteResponse
    turnCountSinceLastReview = _o.turnCountSinceLastReview
    lastMessage = _o.lastMessage
    lastMessageRole = _o.lastMessageRole
  }
  public static func changeRequest(_ o: ProjectThread) -> ProjectThreadChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: ProjectThread.self, for: key)
    return u.map { ProjectThreadChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: ProjectThread) -> ProjectThreadChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    guard
      let u = transactionContext.objectRepository.object(
        transactionContext.connection, ofType: ProjectThread.self, for: key)
    else {
      return Self.creationRequest(o)
    }
    let changeRequest = ProjectThreadChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: ProjectThread) -> ProjectThreadChangeRequest {
    let creationRequest = ProjectThreadChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> ProjectThreadChangeRequest {
    return ProjectThreadChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: ProjectThread) -> ProjectThreadChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: ProjectThread.self, for: key)
    return u.map { ProjectThreadChangeRequest(type: .deletion, $0) }
  }
  var _atom: ProjectThread {
    let atom = ProjectThread(
      id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, model: model,
      hasUnreadResponse: hasUnreadResponse, hasIncompleteResponse: hasIncompleteResponse,
      turnCountSinceLastReview: turnCountSinceLastReview, lastMessage: lastMessage,
      lastMessageRole: lastMessageRole)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      guard
        let insert = toolbox.connection.prepareStaticStatement(
          "INSERT INTO projectthread (__pk0, p) VALUES (?1, ?2)")
      else { return nil }
      id.bindSQLite(insert, parameterId: 1)
      let atom = self._atom
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(
        OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(insert, 2, memory, Int32(byteBuffer.size), SQLITE_STATIC)
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
          "REPLACE INTO projectthread (__pk0, p, rowid) VALUES (?1, ?2, ?3)")
      else { return nil }
      id.bindSQLite(update, parameterId: 1)
      toolbox.flatBufferBuilder.clear()
      let offset = atom.to(flatBufferBuilder: &toolbox.flatBufferBuilder)
      toolbox.flatBufferBuilder.finish(offset: offset)
      let byteBuffer = toolbox.flatBufferBuilder.buffer
      let memory = byteBuffer.memory.advanced(by: byteBuffer.reader)
      let SQLITE_STATIC = unsafeBitCast(
        OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
      sqlite3_bind_blob(update, 2, memory, Int32(byteBuffer.size), SQLITE_STATIC)
      _rowid.bindSQLite(update, parameterId: 3)
      guard SQLITE_DONE == sqlite3_step(update) else { return nil }
      _type = .none
      return .updated(atom)
    case .deletion:
      guard
        let deletion = toolbox.connection.prepareStaticStatement(
          "DELETE FROM projectthread WHERE rowid=?1")
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
