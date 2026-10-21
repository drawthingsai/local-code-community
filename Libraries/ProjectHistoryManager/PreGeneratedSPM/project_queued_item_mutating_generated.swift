import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

// MARK - SQLiteValue for Enumerations

// MARK - Serializer

extension ProjectQueuedItem: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __text = self.text.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    var __imagePaths = [Offset]()
    for i in imagePaths {
      __imagePaths.append(flatBufferBuilder.create(string: i))
    }
    let __vector_imagePaths = flatBufferBuilder.createVector(ofOffsets: __imagePaths)
    let start = zzz_DflatGen_ProjectQueuedItem.startProjectQueuedItem(&flatBufferBuilder)
    zzz_DflatGen_ProjectQueuedItem.add(threadId: self.threadId, &flatBufferBuilder)
    zzz_DflatGen_ProjectQueuedItem.add(datetime: self.datetime, &flatBufferBuilder)
    zzz_DflatGen_ProjectQueuedItem.add(text: __text, &flatBufferBuilder)
    zzz_DflatGen_ProjectQueuedItem.addVectorOf(imagePaths: __vector_imagePaths, &flatBufferBuilder)
    return zzz_DflatGen_ProjectQueuedItem.endProjectQueuedItem(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == ProjectQueuedItem {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension ProjectQueuedItem {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class ProjectQueuedItemChangeRequest: Dflat.ChangeRequest {
  private var _o: ProjectQueuedItem?
  public typealias Element = ProjectQueuedItem
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var threadId: Int64
  public var datetime: Int64
  public var text: String?
  public var imagePaths: [String]
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    threadId = 0
    datetime = 0
    text = nil
    imagePaths = []
  }
  private init(type _type: ChangeRequestType, _ _o: ProjectQueuedItem) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    threadId = _o.threadId
    datetime = _o.datetime
    text = _o.text
    imagePaths = _o.imagePaths
  }
  public static func changeRequest(_ o: ProjectQueuedItem) -> ProjectQueuedItemChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey =
      o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.threadId, o.datetime])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: ProjectQueuedItem.self, for: key)
    return u.map { ProjectQueuedItemChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: ProjectQueuedItem) -> ProjectQueuedItemChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey =
      o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.threadId, o.datetime])
    guard
      let u = transactionContext.objectRepository.object(
        transactionContext.connection, ofType: ProjectQueuedItem.self, for: key)
    else {
      return Self.creationRequest(o)
    }
    let changeRequest = ProjectQueuedItemChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: ProjectQueuedItem) -> ProjectQueuedItemChangeRequest {
    let creationRequest = ProjectQueuedItemChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> ProjectQueuedItemChangeRequest {
    return ProjectQueuedItemChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: ProjectQueuedItem) -> ProjectQueuedItemChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey =
      o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.threadId, o.datetime])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: ProjectQueuedItem.self, for: key)
    return u.map { ProjectQueuedItemChangeRequest(type: .deletion, $0) }
  }
  var _atom: ProjectQueuedItem {
    let atom = ProjectQueuedItem(
      threadId: threadId, datetime: datetime, text: text, imagePaths: imagePaths)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      guard
        let insert = toolbox.connection.prepareStaticStatement(
          "INSERT INTO projectqueueditem (__pk0, __pk1, p) VALUES (?1, ?2, ?3)")
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
          "REPLACE INTO projectqueueditem (__pk0, __pk1, p, rowid) VALUES (?1, ?2, ?3, ?4)")
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
          "DELETE FROM projectqueueditem WHERE rowid=?1")
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
