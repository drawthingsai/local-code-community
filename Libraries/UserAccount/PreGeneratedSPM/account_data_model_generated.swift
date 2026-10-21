import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

public enum PlanType: Int8, DflatFriendlyValue, CaseIterable {
  case free = 0
  case community = 1
  case plus = 2
  case maxEdition = 3
  public static func < (lhs: PlanType, rhs: PlanType) -> Bool {
    return lhs.rawValue < rhs.rawValue
  }
}

public final class Account: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable {
  public static func == (lhs: Account, rhs: Account) -> Bool {
    guard lhs.id == rhs.id else { return false }
    guard lhs.email == rhs.email else { return false }
    guard lhs.shortTermToken == rhs.shortTermToken else { return false }
    guard lhs.originalTransactionId == rhs.originalTransactionId else { return false }
    guard lhs.isSubscribedIap == rhs.isSubscribedIap else { return false }
    guard lhs.isSubscribedOnServer == rhs.isSubscribedOnServer else { return false }
    guard lhs.appleCredentialId == rhs.appleCredentialId else { return false }
    guard lhs.serverSubscriptionPlan == rhs.serverSubscriptionPlan else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let id: Int64
  public let email: String?
  public let shortTermToken: String?
  public let originalTransactionId: String?
  public let isSubscribedIap: Bool
  public let isSubscribedOnServer: Bool
  public let appleCredentialId: String?
  public let serverSubscriptionPlan: PlanType
  public init(
    id: Int64, email: String? = nil, shortTermToken: String? = nil,
    originalTransactionId: String? = nil, isSubscribedIap: Bool? = false,
    isSubscribedOnServer: Bool? = false, appleCredentialId: String? = nil,
    serverSubscriptionPlan: PlanType? = .free
  ) {
    self.id = id
    self.email = email ?? nil
    self.shortTermToken = shortTermToken ?? nil
    self.originalTransactionId = originalTransactionId ?? nil
    self.isSubscribedIap = isSubscribedIap ?? false
    self.isSubscribedOnServer = isSubscribedOnServer ?? false
    self.appleCredentialId = appleCredentialId ?? nil
    self.serverSubscriptionPlan = serverSubscriptionPlan ?? .free
  }
  public init(_ obj: zzz_DflatGen_Account) {
    self.id = obj.id
    self.email = obj.email
    self.shortTermToken = obj.shortTermToken
    self.originalTransactionId = obj.originalTransactionId
    self.isSubscribedIap = obj.isSubscribedIap
    self.isSubscribedOnServer = obj.isSubscribedOnServer
    self.appleCredentialId = obj.appleCredentialId
    self.serverSubscriptionPlan = PlanType(rawValue: obj.serverSubscriptionPlan.rawValue) ?? .free
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(
        assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
        capacity: buffer.count)
      return Self(zzz_DflatGen_Account.getRootAsAccount(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_Account.getRootAsAccount(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_Account>.verify(
        &verifier, at: 0, of: zzz_DflatGen_Account.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "account" }
  public static var indexFields: [String] { [] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else {
      return
    }
    sqlite3_exec(
      sqlite.sqlite,
      "CREATE TABLE IF NOT EXISTS account (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, p BLOB, UNIQUE(__pk0))",
      nil, nil, nil)
  }
  public static func insertIndex(
    _ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer
  ) -> Bool {
    return true
  }
}

public struct AccountBuilder {
  public var id: Int64
  public var email: String?
  public var shortTermToken: String?
  public var originalTransactionId: String?
  public var isSubscribedIap: Bool
  public var isSubscribedOnServer: Bool
  public var appleCredentialId: String?
  public var serverSubscriptionPlan: PlanType
  public init(from object: Account) {
    id = object.id
    email = object.email
    shortTermToken = object.shortTermToken
    originalTransactionId = object.originalTransactionId
    isSubscribedIap = object.isSubscribedIap
    isSubscribedOnServer = object.isSubscribedOnServer
    appleCredentialId = object.appleCredentialId
    serverSubscriptionPlan = object.serverSubscriptionPlan
  }
  public func build() -> Account {
    Account(
      id: id, email: email, shortTermToken: shortTermToken,
      originalTransactionId: originalTransactionId, isSubscribedIap: isSubscribedIap,
      isSubscribedOnServer: isSubscribedOnServer, appleCredentialId: appleCredentialId,
      serverSubscriptionPlan: serverSubscriptionPlan)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
  extension Account: @unchecked Sendable {}
#endif
