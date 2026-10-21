import Dflat
import FlatBuffers

extension Account {

  private static func _tr__f4(_ table: ByteBuffer) -> Int64? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    return tr0.id
  }
  private static func _or__f4(_ or0: Account) -> Int64? {
    return or0.id
  }
  public static let id: FieldExpr<Int64, Account> = FieldExpr(
    name: "__pk0", primaryKey: true, hasIndex: false, tableReader: _tr__f4, objectReader: _or__f4)

  private static func _tr__f8(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    guard let s = tr0.email else { return nil }
    return s
  }
  private static func _or__f8(_ or0: Account) -> String? {
    guard let s = or0.email else { return nil }
    return s
  }
  public static let email: FieldExpr<String, Account> = FieldExpr(
    name: "f8", primaryKey: false, hasIndex: false, tableReader: _tr__f8, objectReader: _or__f8)

  private static func _tr__f10(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    guard let s = tr0.shortTermToken else { return nil }
    return s
  }
  private static func _or__f10(_ or0: Account) -> String? {
    guard let s = or0.shortTermToken else { return nil }
    return s
  }
  public static let shortTermToken: FieldExpr<String, Account> = FieldExpr(
    name: "f10", primaryKey: false, hasIndex: false, tableReader: _tr__f10, objectReader: _or__f10)

  private static func _tr__f12(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    guard let s = tr0.originalTransactionId else { return nil }
    return s
  }
  private static func _or__f12(_ or0: Account) -> String? {
    guard let s = or0.originalTransactionId else { return nil }
    return s
  }
  public static let originalTransactionId: FieldExpr<String, Account> = FieldExpr(
    name: "f12", primaryKey: false, hasIndex: false, tableReader: _tr__f12, objectReader: _or__f12)

  private static func _tr__f14(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    return tr0.isSubscribedIap
  }
  private static func _or__f14(_ or0: Account) -> Bool? {
    return or0.isSubscribedIap
  }
  public static let isSubscribedIap: FieldExpr<Bool, Account> = FieldExpr(
    name: "f14", primaryKey: false, hasIndex: false, tableReader: _tr__f14, objectReader: _or__f14)

  private static func _tr__f16(_ table: ByteBuffer) -> Bool? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    return tr0.isSubscribedOnServer
  }
  private static func _or__f16(_ or0: Account) -> Bool? {
    return or0.isSubscribedOnServer
  }
  public static let isSubscribedOnServer: FieldExpr<Bool, Account> = FieldExpr(
    name: "f16", primaryKey: false, hasIndex: false, tableReader: _tr__f16, objectReader: _or__f16)

  private static func _tr__f18(_ table: ByteBuffer) -> String? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    guard let s = tr0.appleCredentialId else { return nil }
    return s
  }
  private static func _or__f18(_ or0: Account) -> String? {
    guard let s = or0.appleCredentialId else { return nil }
    return s
  }
  public static let appleCredentialId: FieldExpr<String, Account> = FieldExpr(
    name: "f18", primaryKey: false, hasIndex: false, tableReader: _tr__f18, objectReader: _or__f18)

  private static func _tr__f20(_ table: ByteBuffer) -> PlanType? {
    let tr0 = zzz_DflatGen_Account.getRootAsAccount(bb: table)
    return PlanType(rawValue: tr0.serverSubscriptionPlan.rawValue)!
  }
  private static func _or__f20(_ or0: Account) -> PlanType? {
    return or0.serverSubscriptionPlan
  }
  public static let serverSubscriptionPlan: FieldExpr<PlanType, Account> = FieldExpr(
    name: "f20", primaryKey: false, hasIndex: false, tableReader: _tr__f20, objectReader: _or__f20)
}
