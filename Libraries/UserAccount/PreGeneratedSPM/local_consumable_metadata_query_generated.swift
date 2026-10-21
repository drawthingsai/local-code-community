import Dflat
import FlatBuffers

extension LocalConsumableMetadata {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: table)
    return tr0.id
  }
  private static func _or__f4(_ or0: LocalConsumableMetadata) -> Int64? {
    return or0.id
  }
  public static let id: FieldExpr<Int64, LocalConsumableMetadata> = FieldExpr(
    name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  public struct boostBalance {

    private static func _tr__f6__f4(_ table: ByteBuffer) -> Double? {
      let tr0 = zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: table)
      guard let tr1 = tr0.boostBalance else { return nil }
      return tr1.balance
    }
    private static func _or__f6__f4(_ or0: LocalConsumableMetadata) -> Double? {
      guard let or1 = or0.boostBalance else { return nil }
      return or1.balance
    }
    public static let balance: FieldExpr<Double, LocalConsumableMetadata> = FieldExpr(
      name: "f6__f4", primaryKey: false, hasIndex: false, tableReader: _tr__f6__f4,
      objectReader: _or__f6__f4)

    private static func _tr__f6__f6(_ table: ByteBuffer) -> Double? {
      let tr0 = zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: table)
      guard let tr1 = tr0.boostBalance else { return nil }
      return tr1.inProgressBalance
    }
    private static func _or__f6__f6(_ or0: LocalConsumableMetadata) -> Double? {
      guard let or1 = or0.boostBalance else { return nil }
      return or1.inProgressBalance
    }
    public static let inProgressBalance: FieldExpr<Double, LocalConsumableMetadata> = FieldExpr(
      name: "f6__f6", primaryKey: false, hasIndex: false, tableReader: _tr__f6__f6,
      objectReader: _or__f6__f6)

  }

  public struct cashBalance {

    private static func _tr__f8__f4(_ table: ByteBuffer) -> Double? {
      let tr0 = zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: table)
      guard let tr1 = tr0.cashBalance else { return nil }
      return tr1.balance
    }
    private static func _or__f8__f4(_ or0: LocalConsumableMetadata) -> Double? {
      guard let or1 = or0.cashBalance else { return nil }
      return or1.balance
    }
    public static let balance: FieldExpr<Double, LocalConsumableMetadata> = FieldExpr(
      name: "f8__f4", primaryKey: false, hasIndex: false, tableReader: _tr__f8__f4,
      objectReader: _or__f8__f4)

    private static func _tr__f8__f6(_ table: ByteBuffer) -> Double? {
      let tr0 = zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: table)
      guard let tr1 = tr0.cashBalance else { return nil }
      return tr1.inProgressBalance
    }
    private static func _or__f8__f6(_ or0: LocalConsumableMetadata) -> Double? {
      guard let or1 = or0.cashBalance else { return nil }
      return or1.inProgressBalance
    }
    public static let inProgressBalance: FieldExpr<Double, LocalConsumableMetadata> = FieldExpr(
      name: "f8__f6", primaryKey: false, hasIndex: false, tableReader: _tr__f8__f6,
      objectReader: _or__f8__f6)

  }

  private static func _tr__f10(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_LocalConsumableMetadata.getRootAsLocalConsumableMetadata(bb: table)
    return tr0.hasConsent
  }
  private static func _or__f10(_ or0: LocalConsumableMetadata) -> Bool? {
    return or0.hasConsent
  }
  public static let hasConsent: FieldExpr<Bool, LocalConsumableMetadata> = FieldExpr(
    name: "f10", primaryKey: false, hasIndex: false, tableReader: _tr__f10, objectReader: _or__f10)
}
