import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

// MARK - SQLiteValue for Enumerations

extension PlanType: SQLiteValue {
  public func bindSQLite(_ query: OpaquePointer, parameterId: Int32) {
    self.rawValue.bindSQLite(query, parameterId: parameterId)
  }
}

// MARK - Serializer

extension Account: FlatBuffersEncodable {
  public func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    let __email = self.email.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __shortTermToken =
      self.shortTermToken.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __originalTransactionId =
      self.originalTransactionId.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __appleCredentialId =
      self.appleCredentialId.map { flatBufferBuilder.create(string: $0) } ?? Offset()
    let __serverSubscriptionPlan =
      zzz_DflatGen_PlanType(rawValue: self.serverSubscriptionPlan.rawValue) ?? .free
    let start = zzz_DflatGen_Account.startAccount(&flatBufferBuilder)
    zzz_DflatGen_Account.add(id: self.id, &flatBufferBuilder)
    zzz_DflatGen_Account.add(email: __email, &flatBufferBuilder)
    zzz_DflatGen_Account.add(shortTermToken: __shortTermToken, &flatBufferBuilder)
    zzz_DflatGen_Account.add(originalTransactionId: __originalTransactionId, &flatBufferBuilder)
    zzz_DflatGen_Account.add(isSubscribedIap: self.isSubscribedIap, &flatBufferBuilder)
    zzz_DflatGen_Account.add(isSubscribedOnServer: self.isSubscribedOnServer, &flatBufferBuilder)
    zzz_DflatGen_Account.add(appleCredentialId: __appleCredentialId, &flatBufferBuilder)
    zzz_DflatGen_Account.add(serverSubscriptionPlan: __serverSubscriptionPlan, &flatBufferBuilder)
    return zzz_DflatGen_Account.endAccount(&flatBufferBuilder, start: start)
  }
}

extension Optional where Wrapped == Account {
  func to(flatBufferBuilder: inout FlatBufferBuilder) -> Offset {
    self.map { $0.to(flatBufferBuilder: &flatBufferBuilder) } ?? Offset()
  }
}

extension Account {
  public func toData() -> Data {
    var fbb = FlatBufferBuilder()
    let offset = to(flatBufferBuilder: &fbb)
    fbb.finish(offset: offset)
    return fbb.data
  }
}

// MARK - ChangeRequest

public final class AccountChangeRequest: Dflat.ChangeRequest {
  private var _o: Account?
  public typealias Element = Account
  public var _type: ChangeRequestType
  public var _rowid: Int64
  public var id: Int64
  public var email: String?
  public var shortTermToken: String?
  public var originalTransactionId: String?
  public var isSubscribedIap: Bool
  public var isSubscribedOnServer: Bool
  public var appleCredentialId: String?
  public var serverSubscriptionPlan: PlanType
  private init(type _type: ChangeRequestType) {
    _o = nil
    self._type = _type
    _rowid = -1
    id = 0
    email = nil
    shortTermToken = nil
    originalTransactionId = nil
    isSubscribedIap = false
    isSubscribedOnServer = false
    appleCredentialId = nil
    serverSubscriptionPlan = .free
  }
  private init(type _type: ChangeRequestType, _ _o: Account) {
    self._o = _o
    self._type = _type
    _rowid = _o._rowid
    id = _o.id
    email = _o.email
    shortTermToken = _o.shortTermToken
    originalTransactionId = _o.originalTransactionId
    isSubscribedIap = _o.isSubscribedIap
    isSubscribedOnServer = _o.isSubscribedOnServer
    appleCredentialId = _o.appleCredentialId
    serverSubscriptionPlan = _o.serverSubscriptionPlan
  }
  public static func changeRequest(_ o: Account) -> AccountChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: Account.self, for: key)
    return u.map { AccountChangeRequest(type: .update, $0) }
  }
  public static func upsertRequest(_ o: Account) -> AccountChangeRequest {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    guard
      let u = transactionContext.objectRepository.object(
        transactionContext.connection, ofType: Account.self, for: key)
    else {
      return Self.creationRequest(o)
    }
    let changeRequest = AccountChangeRequest(type: .update, o)
    changeRequest._o = u
    changeRequest._rowid = u._rowid
    return changeRequest
  }
  public static func creationRequest(_ o: Account) -> AccountChangeRequest {
    let creationRequest = AccountChangeRequest(type: .creation, o)
    creationRequest._rowid = -1
    return creationRequest
  }
  public static func creationRequest() -> AccountChangeRequest {
    return AccountChangeRequest(type: .creation)
  }
  public static func deletionRequest(_ o: Account) -> AccountChangeRequest? {
    let transactionContext = SQLiteTransactionContext.current!
    let key: SQLiteObjectKey = o._rowid >= 0 ? .rowid(o._rowid) : .primaryKey([o.id])
    let u = transactionContext.objectRepository.object(
      transactionContext.connection, ofType: Account.self, for: key)
    return u.map { AccountChangeRequest(type: .deletion, $0) }
  }
  var _atom: Account {
    let atom = Account(
      id: id, email: email, shortTermToken: shortTermToken,
      originalTransactionId: originalTransactionId, isSubscribedIap: isSubscribedIap,
      isSubscribedOnServer: isSubscribedOnServer, appleCredentialId: appleCredentialId,
      serverSubscriptionPlan: serverSubscriptionPlan)
    atom._rowid = _rowid
    return atom
  }
  public func commit(_ toolbox: PersistenceToolbox) -> UpdatedObject? {
    guard let toolbox = toolbox as? SQLitePersistenceToolbox else { return nil }
    switch _type {
    case .creation:
      guard
        let insert = toolbox.connection.prepareStaticStatement(
          "INSERT INTO account (__pk0, p) VALUES (?1, ?2)")
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
          "REPLACE INTO account (__pk0, p, rowid) VALUES (?1, ?2, ?3)")
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
          "DELETE FROM account WHERE rowid=?1")
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
