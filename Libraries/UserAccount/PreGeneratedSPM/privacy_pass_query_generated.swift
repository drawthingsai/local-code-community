import Dflat
import FlatBuffers

extension PrivacyPass {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_PrivacyPass.getRootAsPrivacyPass(bb: table)
    return tr0.id
  }
  private static func _or__f4(_ or0: PrivacyPass) -> Int64? {
    return or0.id
  }
  public static let id: FieldExpr<Int64, PrivacyPass> = FieldExpr(
    name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f8(_ table: ByteBuffer) -> UInt64? {
    let tr0 = zzz_DflatGen_PrivacyPass.getRootAsPrivacyPass(bb: table)
    return tr0.expirationDate
  }
  private static func _or__f8(_ or0: PrivacyPass) -> UInt64? {
    return or0.expirationDate
  }
  public static let expirationDate: FieldExpr<UInt64, PrivacyPass> = FieldExpr(
    name: "f8", primaryKey: false, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)
}
