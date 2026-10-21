import XCTest

@testable import UserAccount

final class SubscriptionPlanResolutionTests: XCTestCase {
  func testAccountPlanResolutionUsesHighestPaidTierAcrossStoreKitAndServer() {
    let cases:
      [(
        local: ProductsManager.PurchaseStatus, isSubscribedIap: Bool, server: PlanType,
        legacyServerPaid: Bool, expected: PlanType
      )] = [
        (.none, false, .community, false, .community),
        (
          .purchased(
            subscriptionIdentifier: ProductsManager.plusSubscriptionIdentifier,
            originalTransactionId: 1), true, .community, false, .plus
        ),
        (
          .purchased(
            subscriptionIdentifier: ProductsManager.maxSubscriptionIdentifier,
            originalTransactionId: 1),
          true, .community, false, .maxEdition
        ),
        (.none, false, .plus, false, .plus),
        (.none, false, .maxEdition, false, .maxEdition),
        (
          .purchased(
            subscriptionIdentifier: ProductsManager.plusSubscriptionIdentifier,
            originalTransactionId: 1), true, .maxEdition, false, .maxEdition
        ),
        (
          .purchased(
            subscriptionIdentifier: ProductsManager.maxSubscriptionIdentifier,
            originalTransactionId: 1),
          true, .plus, false, .maxEdition
        ),
        (
          .purchased(
            subscriptionIdentifier: ProductsManager.plusSubscriptionIdentifier,
            originalTransactionId: 1), true, .free, true, .plus
        ),
        (.none, false, .free, true, .plus),
        (.none, false, .free, false, .community),
      ]

    for testCase in cases {
      XCTAssertEqual(
        Account.resolvedPlan(
          localPurchaseStatus: testCase.local, isSubscribedIap: testCase.isSubscribedIap,
          serverSubscriptionPlan: testCase.server,
          isSubscribedOnServer: testCase.legacyServerPaid),
        testCase.expected,
        "server: \(testCase.server), legacyServerPaid: \(testCase.legacyServerPaid)"
      )
    }
  }

  func testAccountPaidPlanIncludesPlusAndMaxServerPlans() {
    let cases: [(serverPlan: PlanType, isSubscribedOnServer: Bool, expected: Bool)] = [
      (.community, false, false),
      (.free, true, true),
      (.plus, true, true),
      (.maxEdition, true, true),
    ]

    for testCase in cases {
      let account = Account(
        id: 0, isSubscribedOnServer: testCase.isSubscribedOnServer,
        serverSubscriptionPlan: testCase.serverPlan)
      XCTAssertEqual(
        account.hasPaidPlan, testCase.expected,
        "server: \(testCase.serverPlan), isSubscribedOnServer: \(testCase.isSubscribedOnServer)"
      )
    }
  }

  func testAccountPlanResolutionPreservesPersistedLocalPaidPlanWhileStoreKitIsUnresolved() {
    XCTAssertEqual(
      Account.resolvedPlan(
        localPurchaseStatus: .unresolved, isSubscribedIap: true,
        serverSubscriptionPlan: .community, isSubscribedOnServer: false),
      .plus)
    XCTAssertEqual(
      Account.resolvedPlan(
        localPurchaseStatus: .unresolved, isSubscribedIap: false,
        serverSubscriptionPlan: .community, isSubscribedOnServer: false),
      .community)
  }

  func testAccountPlanResolutionClearsPersistedLocalPaidPlanWhenStoreKitReportsNone() {
    XCTAssertEqual(
      Account.resolvedPlan(
        localPurchaseStatus: .none, isSubscribedIap: true, serverSubscriptionPlan: .community,
        isSubscribedOnServer: false),
      .community)
  }
}
