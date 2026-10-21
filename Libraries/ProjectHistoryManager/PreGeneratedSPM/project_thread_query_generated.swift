import Dflat
import FlatBuffers

extension ProjectThread {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    return tr0.id
  }
  private static func _or__f4(_ or0: ProjectThread) -> Int64? {
    return or0.id
  }
  public static let id: FieldExpr<Int64, ProjectThread> = FieldExpr(
    name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    guard let s = tr0.title else { return nil }
    return s
  }
  private static func _or__f6(_ or0: ProjectThread) -> String? {
    guard let s = or0.title else { return nil }
    return s
  }
  public static let title: FieldExpr<String, ProjectThread> = FieldExpr(
    name: "f6", primaryKey: false, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    return tr0.createdAt
  }
  private static func _or__f8(_ or0: ProjectThread) -> Int64? {
    return or0.createdAt
  }
  public static let createdAt: FieldExpr<Int64, ProjectThread> = FieldExpr(
    name: "f8", primaryKey: false, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)

  private static func _tr__f10(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    return tr0.updatedAt
  }
  private static func _or__f10(_ or0: ProjectThread) -> Int64? {
    return or0.updatedAt
  }
  public static let updatedAt: FieldExpr<Int64, ProjectThread> = FieldExpr(
    name: "f10", primaryKey: false, hasIndex: false, tableReader: _tr__f10, objectReader: _or__f10)

  private static func _tr__f12(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    guard let s = tr0.model else { return nil }
    return s
  }
  private static func _or__f12(_ or0: ProjectThread) -> String? {
    guard let s = or0.model else { return nil }
    return s
  }
  public static let model: FieldExpr<String, ProjectThread> = FieldExpr(
    name: "f12", primaryKey: false, hasIndex: false, tableReader: _tr__f12, objectReader: _or__f12)

  private static func _tr__f14(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    return tr0.hasUnreadResponse
  }
  private static func _or__f14(_ or0: ProjectThread) -> Bool? {
    return or0.hasUnreadResponse
  }
  public static let hasUnreadResponse: FieldExpr<Bool, ProjectThread> = FieldExpr(
    name: "f14", primaryKey: false, hasIndex: false, tableReader: _tr__f14, objectReader: _or__f14)

  private static func _tr__f16(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    return tr0.hasIncompleteResponse
  }
  private static func _or__f16(_ or0: ProjectThread) -> Bool? {
    return or0.hasIncompleteResponse
  }
  public static let hasIncompleteResponse: FieldExpr<Bool, ProjectThread> = FieldExpr(
    name: "f16", primaryKey: false, hasIndex: false, tableReader: _tr__f16, objectReader: _or__f16)

  private static func _tr__f18(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    return tr0.turnCountSinceLastReview
  }
  private static func _or__f18(_ or0: ProjectThread) -> Int64? {
    return or0.turnCountSinceLastReview
  }
  public static let turnCountSinceLastReview: FieldExpr<Int64, ProjectThread> = FieldExpr(
    name: "f18", primaryKey: false, hasIndex: false, tableReader: _tr__f18, objectReader: _or__f18)

  private static func _tr__f20(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    guard let s = tr0.lastMessage else { return nil }
    return s
  }
  private static func _or__f20(_ or0: ProjectThread) -> String? {
    guard let s = or0.lastMessage else { return nil }
    return s
  }
  public static let lastMessage: FieldExpr<String, ProjectThread> = FieldExpr(
    name: "f20", primaryKey: false, hasIndex: false, tableReader: _tr__f20, objectReader: _or__f20)

  private static func _tr__f22(_ table: ByteBuffer) -> ProjectHistoryRole? {
    let tr0 = zzz_DflatGen_ProjectThread.getRootAsProjectThread(bb: table)
    return ProjectHistoryRole(rawValue: tr0.lastMessageRole.rawValue)!
  }
  private static func _or__f22(_ or0: ProjectThread) -> ProjectHistoryRole? {
    return or0.lastMessageRole
  }
  public static let lastMessageRole: FieldExpr<ProjectHistoryRole, ProjectThread> = FieldExpr(
    name: "f22", primaryKey: false, hasIndex: false, tableReader: _tr__f22, objectReader: _or__f22)
}
