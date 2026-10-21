import Dflat
import FlatBuffers
import Foundation
import SQLite3
import SQLiteDflat

public final class ProjectThread: Dflat.Atom, SQLiteDflat.SQLiteAtom, FlatBuffersDecodable,
  Equatable
{
  public static func == (lhs: ProjectThread, rhs: ProjectThread) -> Bool {
    guard lhs.id == rhs.id else { return false }
    guard lhs.title == rhs.title else { return false }
    guard lhs.createdAt == rhs.createdAt else { return false }
    guard lhs.updatedAt == rhs.updatedAt else { return false }
    guard lhs.model == rhs.model else { return false }
    guard lhs.hasUnreadResponse == rhs.hasUnreadResponse else { return false }
    guard lhs.hasIncompleteResponse == rhs.hasIncompleteResponse else { return false }
    guard lhs.turnCountSinceLastReview == rhs.turnCountSinceLastReview else { return false }
    guard lhs.lastMessage == rhs.lastMessage else { return false }
    guard lhs.lastMessageRole == rhs.lastMessageRole else { return false }
    return true
  }
  public var _rowid: Int64 = -1
  public var _changesTimestamp: Int64 = -1
  public let id: Int64
  public let title: String?
  public let createdAt: Int64
  public let updatedAt: Int64
  public let model: String?
  public let hasUnreadResponse: Bool
  public let hasIncompleteResponse: Bool
  public let turnCountSinceLastReview: Int64
  public let lastMessage: String?
  public let lastMessageRole: ProjectHistoryRole
  public init(
    id: Int64, title: String? = nil, createdAt: Int64? = 0, updatedAt: Int64? = 0,
    model: String? = nil, hasUnreadResponse: Bool? = false, hasIncompleteResponse: Bool? = false,
    turnCountSinceLastReview: Int64? = 0, lastMessage: String? = nil,
    lastMessageRole: ProjectHistoryRole? = .user
  ) {
    self.id = id
    self.title = title ?? nil
    self.createdAt = createdAt ?? 0
    self.updatedAt = updatedAt ?? 0
    self.model = model ?? nil
    self.hasUnreadResponse = hasUnreadResponse ?? false
    self.hasIncompleteResponse = hasIncompleteResponse ?? false
    self.turnCountSinceLastReview = turnCountSinceLastReview ?? 0
    self.lastMessage = lastMessage ?? nil
    self.lastMessageRole = lastMessageRole ?? .user
  }
  public init(_ obj: zzz_DflatGen_ProjectThread) {
    self.id = obj.id
    self.title = obj.title
    self.createdAt = obj.createdAt
    self.updatedAt = obj.updatedAt
    self.model = obj.model
    self.hasUnreadResponse = obj.hasUnreadResponse
    self.hasIncompleteResponse = obj.hasIncompleteResponse
    self.turnCountSinceLastReview = obj.turnCountSinceLastReview
    self.lastMessage = obj.lastMessage
    self.lastMessageRole = ProjectHistoryRole(rawValue: obj.lastMessageRole.rawValue) ?? .user
  }
  public static func from(data: Data) -> Self {
    return data.withUnsafeBytes { buffer in
      let bb = ByteBuffer(
        assumingMemoryBound: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
        capacity: buffer.count)
      return Self(zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: bb))
    }
  }
  public static func from(byteBuffer bb: ByteBuffer) -> Self {
    Self(zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: bb))
  }
  public static func verify(byteBuffer bb: ByteBuffer) -> Bool {
    do {
      var bb = bb
      var verifier = try Verifier(buffer: &bb)
      try ForwardOffset<zzz_DflatGen_ProjectThread>.verify(
        &verifier, at: 0, of: zzz_DflatGen_ProjectThread.self)
      return true
    } catch {
      return false
    }
  }
  public static var flatBuffersSchemaVersion: String? {
    return nil
  }
  public static var table: String { "projectthread" }
  public static var indexFields: [String] { [] }
  public static func setUpSchema(_ toolbox: PersistenceToolbox) {
    guard let sqlite = ((toolbox as? SQLitePersistenceToolbox).map { $0.connection }) else {
      return
    }
    sqlite3_exec(
      sqlite.sqlite,
      "CREATE TABLE IF NOT EXISTS projectthread (rowid INTEGER PRIMARY KEY AUTOINCREMENT, __pk0 INTEGER, p BLOB, UNIQUE(__pk0))",
      nil, nil, nil)
  }
  public static func insertIndex(
    _ toolbox: PersistenceToolbox, field: String, rowid: Int64, table: ByteBuffer
  ) -> Bool {
    return true
  }
}

public struct ProjectThreadBuilder {
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
  public init(from object: ProjectThread) {
    id = object.id
    title = object.title
    createdAt = object.createdAt
    updatedAt = object.updatedAt
    model = object.model
    hasUnreadResponse = object.hasUnreadResponse
    hasIncompleteResponse = object.hasIncompleteResponse
    turnCountSinceLastReview = object.turnCountSinceLastReview
    lastMessage = object.lastMessage
    lastMessageRole = object.lastMessageRole
  }
  public func build() -> ProjectThread {
    ProjectThread(
      id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, model: model,
      hasUnreadResponse: hasUnreadResponse, hasIncompleteResponse: hasIncompleteResponse,
      turnCountSinceLastReview: turnCountSinceLastReview, lastMessage: lastMessage,
      lastMessageRole: lastMessageRole)
  }
}

#if compiler(>=5.5) && canImport(_Concurrency)
  extension ProjectThread: @unchecked Sendable {}
#endif
