import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

public struct ConsumableBalance: Equatable, FlatBuffersDecodable {
  public var balance: Double
  public var inProgressBalance: Double
  public init(balance: Double? = 0.0, inProgressBalance: Double? = 0.0) {
    self.balance = balance ?? 0.0
    self.inProgressBalance = inProgressBalance ?? 0.0
  }
  public init(_ obj: zzz_DflatGen_ConsumableBalance) {
    self.balance = obj.balance
    self.inProgressBalance = obj.inProgressBalance
  }

  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ConsumableBalance.getRootAsConsumableBalance(bb: bb))
  }

  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ConsumableBalance>.verify(
        &verifier, at: 0, of: zzz_DflatGen_ConsumableBalance.self)
      return true
    } catch {
      return false
    }
  }

  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
}

public final class LocalConsumableMetadata: Dflat.Atom, SQLiteDflat.SQLiteAtom,
  FlatBuffersDecodable, Equatable
{
  public static func == (lhs: LocalConsumableMetadata, rhs: LocalConsumableMetadata) -> Bool {
    guard lhs.id == rhs.id else { return false }
    guard lhs.boostBalance == rhs.boostBalance else { return false }
    guard lhs.cashBalance == rhs.cashBalance else { return false }
    guard lhs.hasConsent == rhs.hasConsent else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let id: Int64
  public let boostBalance: ConsumableBalance?
  public let cashBalance: ConsumableBalance?
  public let hasConsent: Bool
  public init(
    id: Int64, boostBalance: ConsumableBalance? = nil, cashBalance: ConsumableBalance? = nil,
    hasConsent: Bool? = false
  ) {
    self.id = id
    self.boostBalance = boostBalance ?? nil
    self.cashBalance = cashBalance ?? nil
    self.hasConsent = hasConsent ?? false
  }
  public init(_ obj: zzz_DflatGen_LocalConsumableMetadata) {
    self.id = obj.id
    self.boostBalance = obj.boostBalance.map { ConsumableBalance($0) }
    self.cashBalance = obj.cashBalance.map { ConsumableBalance($0) }
    self.hasConsent = obj.hasConsent
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(
        assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
        capacity: buffer.count)
      return Self(zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_LocalConsumableMetadata>.verify(
        &verifier, at: 0, of: zzz_DflatGen_LocalConsumableMetadata.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "localconsumablemetadata" }
  public static var indexFields: [String] { [] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else {
      return
    }
    sqlite3_exec(
      sqlite.sqlite,
      "CREATE TABLE IF NOT EXISTS localconsumablemetadata (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, p BLOB, UNIQUE(__pk0))",
      nil, nil, nil)
  }
  public static func insertIndex(
    _ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer
  ) -> Bool {
    return true
  }
}

public struct LocalConsumableMetadataBuilder {
  public var id: Int64
  public var boostBalance: ConsumableBalance?
  public var cashBalance: ConsumableBalance?
  public var hasConsent: Bool
  public init(from object: LocalConsumableMetadata) {
    id = object.id
    boostBalance = object.boostBalance
    cashBalance = object.cashBalance
    hasConsent = object.hasConsent
  }
  public func build() -> LocalConsumableMetadata {
    LocalConsumableMetadata(
      id: id, boostBalance: boostBalance, cashBalance: cashBalance, hasConsent: hasConsent)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
  extension LocalConsumableMetadata: @unchecked Sendable {}
#endif
