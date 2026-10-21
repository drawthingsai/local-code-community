import Dflat
import FlatBuffers

extension ProjectHistoryNode {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    return tr0.threadId
  }
  private static func _or__f4(_ or0: ProjectHistoryNode) -> Int64? {
    return or0.threadId
  }
  public static let threadId: FieldExpr<Int64, ProjectHistoryNode> = FieldExpr(
    name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f6(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    return tr0.datetime
  }
  private static func _or__f6(_ or0: ProjectHistoryNode) -> Int64? {
    return or0.datetime
  }
  public static let datetime: FieldExpr<Int64, ProjectHistoryNode> = FieldExpr(
    name: "__pk1", primaryKey: true, hasIndex: false, tableReader: _tr__f6, objectReader: _or__f6)

  private static func _tr__f8(_ table: ByteBuffer) -> ProjectHistoryRole? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    return ProjectHistoryRole(rawValue: tr0.role.rawValue)!
  }
  private static func _or__f8(_ or0: ProjectHistoryNode) -> ProjectHistoryRole? {
    return or0.role
  }
  public static let role: FieldExpr<ProjectHistoryRole, ProjectHistoryNode> = FieldExpr(
    name: "f8", primaryKey: false, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)

  private static func _tr__f16(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    return tr0.textEdits
  }
  private static func _or__f16(_ or0: ProjectHistoryNode) -> Int64? {
    return or0.textEdits
  }
  public static let textEdits: FieldExpr<Int64, ProjectHistoryNode> = FieldExpr(
    name: "f16", primaryKey: false, hasIndex: false, tableReader: _tr__f16, objectReader: _or__f16)

  private static func _tr__f18(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    return tr0.textLineage
  }
  private static func _or__f18(_ or0: ProjectHistoryNode) -> Int64? {
    return or0.textLineage
  }
  public static let textLineage: FieldExpr<Int64, ProjectHistoryNode> = FieldExpr(
    name: "f18", primaryKey: false, hasIndex: false, tableReader: _tr__f18, objectReader: _or__f18)

  private static func _tr__f20(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    guard let s = tr0.plaintext else { return nil }
    return s
  }
  private static func _or__f20(_ or0: ProjectHistoryNode) -> String? {
    guard let s = or0.plaintext else { return nil }
    return s
  }
  public static let plaintext: FieldExpr<String, ProjectHistoryNode> = FieldExpr(
    name: "f20", primaryKey: false, hasIndex: false, tableReader: _tr__f20, objectReader: _or__f20)

  private static func _tr__f22(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    guard let s = tr0.logPlaintext else { return nil }
    return s
  }
  private static func _or__f22(_ or0: ProjectHistoryNode) -> String? {
    guard let s = or0.logPlaintext else { return nil }
    return s
  }
  public static let logPlaintext: FieldExpr<String, ProjectHistoryNode> = FieldExpr(
    name: "f22", primaryKey: false, hasIndex: false, tableReader: _tr__f22, objectReader: _or__f22)

  private static func _tr__f24(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    return tr0.compacted
  }
  private static func _or__f24(_ or0: ProjectHistoryNode) -> Bool? {
    return or0.compacted
  }
  public static let compacted: FieldExpr<Bool, ProjectHistoryNode> = FieldExpr(
    name: "f24", primaryKey: false, hasIndex: false, tableReader: _tr__f24, objectReader: _or__f24)

  private static func _tr__f26(_ table: ByteBuffer) -> Double? {
    let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
    return tr0.duration
  }
  private static func _or__f26(_ or0: ProjectHistoryNode) -> Double? {
    return or0.duration
  }
  public static let duration: FieldExpr<Double, ProjectHistoryNode> = FieldExpr(
    name: "f26", primaryKey: false, hasIndex: false, tableReader: _tr__f26, objectReader: _or__f26)

  public struct memoryContext {

    private static func _tr__f30__f4(_ table: ByteBuffer) -> String? {
      let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
      guard let tr1 = tr0.memoryContext else { return nil }
      guard let s = tr1.user else { return nil }
      return s
    }
    private static func _or__f30__f4(_ or0: ProjectHistoryNode) -> String? {
      guard let or1 = or0.memoryContext else { return nil }
      guard let s = or1.user else { return nil }
      return s
    }
    public static let user: FieldExpr<String, ProjectHistoryNode> = FieldExpr(
      name: "f30__f4", primaryKey: false, hasIndex: false, tableReader: _tr__f30__f4,
      objectReader: _or__f30__f4)

    private static func _tr__f30__f6(_ table: ByteBuffer) -> String? {
      let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
      guard let tr1 = tr0.memoryContext else { return nil }
      guard let s = tr1.memory else { return nil }
      return s
    }
    private static func _or__f30__f6(_ or0: ProjectHistoryNode) -> String? {
      guard let or1 = or0.memoryContext else { return nil }
      guard let s = or1.memory else { return nil }
      return s
    }
    public static let memory: FieldExpr<String, ProjectHistoryNode> = FieldExpr(
      name: "f30__f6", primaryKey: false, hasIndex: false, tableReader: _tr__f30__f6,
      objectReader: _or__f30__f6)

  }

  public struct systemSeenMemoryContext {

    private static func _tr__f32__f4(_ table: ByteBuffer) -> String? {
      let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
      guard let tr1 = tr0.systemSeenMemoryContext else { return nil }
      guard let s = tr1.user else { return nil }
      return s
    }
    private static func _or__f32__f4(_ or0: ProjectHistoryNode) -> String? {
      guard let or1 = or0.systemSeenMemoryContext else { return nil }
      guard let s = or1.user else { return nil }
      return s
    }
    public static let user: FieldExpr<String, ProjectHistoryNode> = FieldExpr(
      name: "f32__f4", primaryKey: false, hasIndex: false, tableReader: _tr__f32__f4,
      objectReader: _or__f32__f4)

    private static func _tr__f32__f6(_ table: ByteBuffer) -> String? {
      let tr0 = zzz_DflatGen_ProjectHistoryNode.getRootAsProjectHistoryNode(bb: table)
      guard let tr1 = tr0.systemSeenMemoryContext else { return nil }
      guard let s = tr1.memory else { return nil }
      return s
    }
    private static func _or__f32__f6(_ or0: ProjectHistoryNode) -> String? {
      guard let or1 = or0.systemSeenMemoryContext else { return nil }
      guard let s = or1.memory else { return nil }
      return s
    }
    public static let memory: FieldExpr<String, ProjectHistoryNode> = FieldExpr(
      name: "f32__f6", primaryKey: false, hasIndex: false, tableReader: _tr__f32__f6,
      objectReader: _or__f32__f6)

  }
}
