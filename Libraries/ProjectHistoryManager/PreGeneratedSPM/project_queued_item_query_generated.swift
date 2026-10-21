import Dflat
import FlatBuffers

extension ProjectQueuedItem {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectQueuedItem.getRootAsProjectQueuedItem(bb: table)
    return tr0.threadId
  }
  private static func _or__f4(_ or0: ProjectQueuedItem) -> Int64? {
    return or0.threadId
  }
  public static let threadId: FieldExpr<Int64, ProjectQueuedItem> = FieldExpr(
    name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectQueuedItem.getRootAsProjectQueuedItem(bb: table)
    return tr0.datetime
  }
  private static func _or__f6(_ or0: ProjectQueuedItem) -> Int64? {
    return or0.datetime
  }
  public static let datetime: FieldExpr<Int64, ProjectQueuedItem> = FieldExpr(
    name: "__pk1", primaryKey: true, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_ProjectQueuedItem.getRootAsProjectQueuedItem(bb: table)
    guard let s = tr0.text else { return nil }
    return s
  }
  private static func _or__f8(_ or0: ProjectQueuedItem) -> String? {
    guard let s = or0.text else { return nil }
    return s
  }
  public static let text: FieldExpr<String, ProjectQueuedItem> = FieldExpr(
    name: "f8", primaryKey: false, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)
}
