import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

// MARK - SQLiteValue for Enumerations

// MARK - Serializer

extension PrivacyPass: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __vector_token = flatBufferBuilder.createVector(self.token)
    let start = zzz_DflatGen_PrivacyPass.startPrivacyPass(&flatBufferBuilder)
    zzz_DflatGen_PrivacyPass.add(id: self.id, &flatBufferBuilder)
    zzz_DflatGen_PrivacyPass.addVectorOf(token: __vector_token, &flatBufferBuilder)
    zzz_DflatGen_PrivacyPass.add(expirationDate: self.expirationDate, &flatBufferBuilder)
    return zzz_DflatGen_PrivacyPass.endPrivacyPass(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == PrivacyPass {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension PrivacyPass {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class PrivacyPassChangeRequest: Dflat.ChangeRequest {
  private var _o: PrivacyPass?
  public typealias Element = PrivacyPass
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var id: Int64
  public var token: [UInt8]
  public var expirationDate: UInt64
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    id = 0
    token = []
    expirationDate = 0
  }
  private init(type _type: ChangeRequestType, _ _o: PrivacyPass) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    id = _o.id
    token = _o.token
    expirationDate = _o.expirationDate
  }
  public static func changeRequest(_ o: PrivacyPass) -> PrivacyPassChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: PrivacyPass.self, for: key)
    return u.map { PrivacyPassChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: PrivacyPass) -> PrivacyPassChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    guard
      let u = transactionContext.objectRepository.object(
        transactionContext.connection, ofType: PrivacyPass.self, for: key)
    else {
      return Self.creationRequest(o)
    }
    let changeRequest = PrivacyPassChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: PrivacyPass) -> PrivacyPassChangeRequest {
    let creationRequest = PrivacyPassChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> PrivacyPassChangeRequest {
    return PrivacyPassChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: PrivacyPass) -> PrivacyPassChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: PrivacyPass.self, for: key)
    return u.map { PrivacyPassChangeRequest(type: .deletion, $0) }
  }
  var _atom: PrivacyPass {
    let atom = PrivacyPass(id: id, token: token, expirationDate: expirationDate)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      guard
        let insert = toolbox.connection.prepareStaticStatement(
          "INSERT INTO privacypass (__pk0, p) VALUES (?1, ?2)")
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
          "REPLACE INTO privacypass (__pk0, p, rowid) VALUES (?1, ?2, ?3)")
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
          "DELETE FROM privacypass WHERE rowid=?1")
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
