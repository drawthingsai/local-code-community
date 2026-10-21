import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

public final class PrivacyPass: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable, Equatable
{
  public static func == (lhs: PrivacyPass, rhs: PrivacyPass) -> Bool {
    guard lhs.id == rhs.id else { return false }
    guard lhs.token == rhs.token else { return false }
    guard lhs.expirationDate == rhs.expirationDate else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let id: Int64
  public let token: [UInt8]
  public let expirationDate: UInt64
  public init(id: Int64, token: [UInt8]? = [], expirationDate: UInt64? = 0) {
    self.id = id
    self.token = token ?? []
    self.expirationDate = expirationDate ?? 0
  }
  public init(_ obj: zzz_DflatGen_PrivacyPass) {
    self.id = obj.id
    self.token = obj.token
    self.expirationDate = obj.expirationDate
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(
        assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
        capacity: buffer.count)
      return Self(zzz_DflatGen_PrivacyPass.getRootAsPrivacyPass(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_PrivacyPass.getRootAsPrivacyPass(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_PrivacyPass>.verify(
        &verifier, at: 0, of: zzz_DflatGen_PrivacyPass.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "privacypass" }
  public static var indexFields: [String] { [] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else {
      return
    }
    sqlite3_exec(
      sqlite.sqlite,
      "CREATE TABLE IF NOT EXISTS privacypass (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, p BLOB, UNIQUE(__pk0))",
      nil, nil, nil)
  }
  public static func insertIndex(
    _ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer
  ) -> Bool {
    return true
  }
}

public struct PrivacyPassBuilder {
  public var id: Int64
  public var token: [UInt8]
  public var expirationDate: UInt64
  public init(from object: PrivacyPass) {
    id = object.id
    token = object.token
    expirationDate = object.expirationDate
  }
  public func build() -> PrivacyPass {
    PrivacyPass(id: id, token: token, expirationDate: expirationDate)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
  extension PrivacyPass: @unchecked Sendable {}
#endif
