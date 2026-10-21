import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

public final class ProjectQueuedItem: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable,
  Equatable
{
  public static func == (lhs: ProjectQueuedItem, rhs: ProjectQueuedItem) -> Bool {
    guard lhs.threadId == rhs.threadId else { return false }
    guard lhs.datetime == rhs.datetime else { return false }
    guard lhs.text == rhs.text else { return false }
    guard lhs.imagePaths == rhs.imagePaths else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let threadId: Int64
  public let datetime: Int64
  public let text: String?
  public let imagePaths: [String]
  public init(threadId: Int64, datetime: Int64, text: String? = nil, imagePaths: [String]? = []) {
    self.threadId = threadId
    self.datetime = datetime
    self.text = text ?? nil
    self.imagePaths = imagePaths ?? []
  }
  public init(_ obj: zzz_DflatGen_ProjectQueuedItem) {
    self.threadId = obj.threadId
    self.datetime = obj.datetime
    self.text = obj.text
    var __imagePaths = [String]()
    for i: Int32 in 0..<obj.imagePathsCount {
      guard let o = obj.imagePaths(at: i) else { break }
      __imagePaths.append(String(o))
    }
    self.imagePaths = __imagePaths
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(
        assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
        capacity: buffer.count)
      return Self(zzz_DflatGen_ProjectQueuedItem.getRootAsProjectQueuedItem(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ProjectQueuedItem.getRootAsProjectQueuedItem(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ProjectQueuedItem>.verify(
        &verifier, at: 0, of: zzz_DflatGen_ProjectQueuedItem.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "projectqueueditem" }
  public static var indexFields: [String] { [] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else {
      return
    }
    sqlite3_exec(
      sqlite.sqlite,
      "CREATE TABLE IF NOT EXISTS projectqueueditem (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, __pk1 INTEGER, p BLOB, UNIQUE(__pk0, __pk1))",
      nil, nil, nil)
  }
  public static func insertIndex(
    _ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer
  ) -> Bool {
    return true
  }
}

public struct ProjectQueuedItemBuilder {
  public var threadId: Int64
  public var datetime: Int64
  public var text: String?
  public var imagePaths: [String]
  public init(from object: ProjectQueuedItem) {
    threadId = object.threadId
    datetime = object.datetime
    text = object.text
    imagePaths = object.imagePaths
  }
  public func build() -> ProjectQueuedItem {
    ProjectQueuedItem(threadId: threadId, datetime: datetime, text: text, imagePaths: imagePaths)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
  extension ProjectQueuedItem: @unchecked Sendable {}
#endif
