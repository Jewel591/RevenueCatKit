import XCTest
@testable import RevenueCatKit

/// #13: hosts must be able to tell a Dashboard mapping gap from a product that has not
/// yet appeared in RevenueCat's lifetime purchase history. These cases lock the house
/// classifier and the snapshot plumbing that used to drop the raw collections.
@MainActor
final class EntitlementDiagnosticsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetStandardRevocationGraceState()
    }

    private let entitlementID = "premium"
    private let lifetimeProductID = "premium.lifetime"

    // MARK: - Classifier (#13)

    func testPurchasedProductKnownToRevenueCatButEntitlementInactive_isConfigurationGap() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [entitlementID],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [lifetimeProductID],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnosis, .productNotAttachedToEntitlement)
    }

    func testPurchasedProductUnknownToRevenueCat_isSyncDelay() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [entitlementID],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnosis, .transactionNotYetSynced)
    }

    func testRevenueCatKnowsOtherProductsButNotThisOne_isStillSyncDelay() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [entitlementID],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: ["premium.monthly"],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnosis, .transactionNotYetSynced)
    }

    /// First-purchase customers have an empty entitlement table. Checking key existence
    /// first would collapse both target verdicts into `entitlementIDMissing`.
    func testFirstPurchaseWithEmptyEntitlementTableButProductKnown_isConfigurationGap() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [lifetimeProductID],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnosis, .productNotAttachedToEntitlement)
    }

    func testFirstPurchaseWithEmptyEntitlementTableAndProductUnknown_isSyncDelay() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnosis, .transactionNotYetSynced)
    }

    func testPurchaseWithUnrelatedEntitlementKeysPresent_stillClassifiesByProduct() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: ["some_other_entitlement"],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [lifetimeProductID],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnosis, .productNotAttachedToEntitlement)
    }

    func testEntitlementKeyGoneOnRevocationPath_isMissingEntitlementID() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: ["some_other_entitlement"],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [lifetimeProductID],
            purchasedProductID: nil
        )

        XCTAssertEqual(diagnosis, .entitlementIDMissing)
    }

    func testEntitlementPresentButInactiveWithoutPurchaseContext_isUnknownCause() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [entitlementID],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [lifetimeProductID],
            purchasedProductID: nil
        )

        XCTAssertEqual(diagnosis, .entitlementInactiveUnknownCause)
    }

    func testActiveEntitlementReachingReportSite_isFlaggedAsInstrumentationDefect() {
        let diagnosis = EntitlementFailureDiagnosis.classify(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [entitlementID],
            activeEntitlementIDs: [entitlementID],
            allPurchasedProductIDs: [lifetimeProductID],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnosis, .entitlementActive)
    }

    func testTelemetryContextCarriesSortedCollectionsAndPurchasedProduct() {
        let diagnostics = EntitlementDiagnostics(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [entitlementID, "legacy_pro"],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: ["zeta", "alpha", lifetimeProductID],
            purchasedProductID: lifetimeProductID
        )

        XCTAssertEqual(diagnostics.diagnosis, .productNotAttachedToEntitlement)
        XCTAssertEqual(diagnostics.telemetryContext["verdict"], "product_not_attached_to_entitlement")
        XCTAssertEqual(diagnostics.telemetryContext["all_entitlement_ids"], "legacy_pro,premium")
        XCTAssertEqual(
            diagnostics.telemetryContext["all_purchased_product_ids"],
            "alpha,premium.lifetime,zeta"
        )
        XCTAssertEqual(diagnostics.telemetryContext["purchased_product_id"], lifetimeProductID)
    }

    func testMissingPurchaseContextIsReportedExplicitlyRatherThanOmitted() {
        let diagnostics = EntitlementDiagnostics(
            expectedEntitlementID: entitlementID,
            allEntitlementIDs: [entitlementID],
            activeEntitlementIDs: [],
            allPurchasedProductIDs: [],
            purchasedProductID: nil
        )

        XCTAssertEqual(diagnostics.telemetryContext["purchased_product_id"], "<none>")
    }

    // MARK: - Snapshot plumbing (#13)

    func testPurchaseNotEntitledWithKnownProduct_publishesMappingGapDiagnostics() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        provider.purchaseResponse = .success(
            .init(
                customerInfo: makeCustomerInfo(
                    appUserID: "user-a",
                    allPurchasedProductIDs: ["premium.monthly"]
                ),
                userCancelled: false
            )
        )

        let outcome = try await client.purchase(optionID)

        XCTAssertEqual(outcome, .notEntitled)
        let diagnostics = client.state.entitlement?.diagnostics
        XCTAssertEqual(diagnostics?.allPurchasedProductIDs, ["premium.monthly"])
        XCTAssertEqual(diagnostics?.purchasedProductID, "premium.monthly")
        XCTAssertEqual(diagnostics?.diagnosis, .productNotAttachedToEntitlement)
    }

    func testPurchaseNotEntitledWithUnknownProduct_publishesSyncDelayDiagnostics() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        provider.purchaseResponse = .success(
            .init(
                customerInfo: makeCustomerInfo(appUserID: "user-a"),
                userCancelled: false
            )
        )

        let outcome = try await client.purchase(optionID)

        XCTAssertEqual(outcome, .notEntitled)
        let diagnostics = client.state.entitlement?.diagnostics
        XCTAssertEqual(diagnostics?.allPurchasedProductIDs, [])
        XCTAssertEqual(diagnostics?.purchasedProductID, "premium.monthly")
        XCTAssertEqual(diagnostics?.diagnosis, .transactionNotYetSynced)
    }

    func testFirstPurchaseEmptyEntitlementTableStillClassifiesByProductMembership() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        // A first-purchase customer has no expected key at all — not an inactive one.
        provider.purchaseResponse = .success(
            .init(
                customerInfo: makeCustomerInfo(
                    appUserID: "user-a",
                    allPurchasedProductIDs: ["premium.monthly"]
                ),
                userCancelled: false
            )
        )

        _ = try await client.purchase(optionID)

        XCTAssertEqual(client.state.entitlement?.diagnostics.allEntitlementIDs, [])
        XCTAssertEqual(
            client.state.entitlement?.diagnostics.diagnosis,
            .productNotAttachedToEntitlement
        )
    }

    func testRefreshWithoutPurchaseContextKeepsRevocationPathDiagnosis() async throws {
        let info = makeCustomerInfo(
            appUserID: "user-a",
            entitlement: makeEntitlement(isActiveInCurrentEnvironment: false),
            allPurchasedProductIDs: ["premium.monthly"]
        )
        let client = try await makeConfiguredClient(provider: FakeRevenueCatProvider(), initialCustomerInfo: info)

        XCTAssertEqual(client.state.entitlement?.diagnostics.allPurchasedProductIDs, ["premium.monthly"])
        XCTAssertNil(client.state.entitlement?.diagnostics.purchasedProductID)
        XCTAssertEqual(
            client.state.entitlement?.diagnostics.diagnosis,
            .entitlementInactiveUnknownCause
        )
    }

    func testActiveCurrentEnvironmentEntitlementIsRecordedInActiveSet() async throws {
        let info = makeCustomerInfo(
            appUserID: "user-a",
            entitlement: makeEntitlement(isActiveInCurrentEnvironment: true),
            allPurchasedProductIDs: ["premium.monthly"]
        )
        let client = try await makeConfiguredClient(provider: FakeRevenueCatProvider(), initialCustomerInfo: info)

        XCTAssertEqual(client.state.entitlement?.diagnostics.activeEntitlementIDs, ["premium"])
        XCTAssertEqual(client.state.entitlement?.diagnostics.diagnosis, .entitlementActive)
    }

    func testAnyEnvironmentActiveDoesNotEnterTheActiveDiagnosticSet() async throws {
        let info = makeCustomerInfo(
            appUserID: "user-a",
            entitlement: makeEntitlement(
                isActiveInCurrentEnvironment: false,
                isActiveInAnyEnvironment: true
            ),
            allPurchasedProductIDs: ["premium.monthly"]
        )
        let client = try await makeConfiguredClient(provider: FakeRevenueCatProvider(), initialCustomerInfo: info)

        XCTAssertEqual(client.state.entitlement?.diagnostics.allEntitlementIDs, ["premium"])
        XCTAssertEqual(client.state.entitlement?.diagnostics.activeEntitlementIDs, [])
        XCTAssertEqual(
            client.state.entitlement?.diagnostics.diagnosis,
            .entitlementInactiveUnknownCause
        )
    }

    /// #13: RevenueCat emits CustomerInfo on purchase. The stream refresh has no
    /// purchase context and must not replace the mapping-gap / sync-delay verdict
    /// with the revocation-path fallback.
    func testStreamRefreshAfterNotEntitledPurchaseKeepsPurchasePathDiagnosis() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        let purchaseDate = Date(timeIntervalSince1970: 4_000)
        provider.purchaseResponse = .success(
            .init(
                customerInfo: makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: purchaseDate,
                    allPurchasedProductIDs: ["premium.monthly"]
                ),
                userCancelled: false
            )
        )

        let outcome = try await client.purchase(optionID)
        XCTAssertEqual(outcome, .notEntitled)
        XCTAssertEqual(
            client.state.entitlement?.diagnostics.diagnosis,
            .productNotAttachedToEntitlement
        )

        provider.customerInfoResponses = [
            .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: Date(timeIntervalSince1970: 4_001),
                    allPurchasedProductIDs: ["premium.monthly"]
                )
            ),
        ]
        provider.emitCustomerInfoInvalidation()
        let didReRead = await waitUntil {
            provider.customerInfoPolicies.contains(.notStaleCachedOrFetched)
        }
        XCTAssertTrue(didReRead)

        let diagnostics = client.state.entitlement?.diagnostics
        XCTAssertEqual(diagnostics?.purchasedProductID, "premium.monthly")
        XCTAssertEqual(diagnostics?.diagnosis, .productNotAttachedToEntitlement)
    }

    /// #13: a confirmed entitlement must drop purchase-path attribution, or a
    /// later expiry / refund refresh is misread as a Dashboard mapping gap.
    func testLaterRevocationAfterSuccessfulPurchaseUsesRevocationPath() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        provider.purchaseResponse = .success(
            .init(
                customerInfo: makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: Date(timeIntervalSince1970: 4_000),
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: true),
                    allPurchasedProductIDs: ["premium.monthly"]
                ),
                userCancelled: false
            )
        )

        let outcome = try await client.purchase(optionID)
        guard case .purchased = outcome else {
            return XCTFail("Expected a successful purchase")
        }

        provider.customerInfoResponses = [
            .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: Date(timeIntervalSince1970: 5_000),
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: false),
                    allPurchasedProductIDs: ["premium.monthly"]
                )
            ),
        ]
        provider.emitCustomerInfoInvalidation()
        let didReRead = await waitUntil {
            provider.customerInfoPolicies.contains(.notStaleCachedOrFetched)
        }
        XCTAssertTrue(didReRead)

        let diagnostics = client.state.entitlement?.diagnostics
        XCTAssertNil(diagnostics?.purchasedProductID)
        XCTAssertEqual(diagnostics?.diagnosis, .entitlementInactiveUnknownCause)
    }

    /// #13: offering reload drops prior option IDs. The product ID captured at
    /// purchase start must still classify the completed `.notEntitled` result.
    func testOfferingReloadDuringPurchaseStillClassifiesWithFrozenProductID() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        provider.suspendPurchase = true
        let purchase = Task { @MainActor in
            try await client.purchase(optionID)
        }
        let didStartPurchase = await waitUntil { provider.purchaseCallCount == 1 }
        XCTAssertTrue(didStartPurchase)

        provider.offeringValue = makeProviderOffering(
            offeringID: "default",
            packageIdentifier: "$rc_monthly"
        )
        guard case .available = try await client.loadOffering() else {
            return XCTFail("Expected reloaded offering")
        }

        provider.resumePurchase(
            with: .success(
                .init(
                    customerInfo: makeCustomerInfo(
                        appUserID: "user-a",
                        allPurchasedProductIDs: ["premium.monthly"]
                    ),
                    userCancelled: false
                )
            )
        )
        let outcome = try await purchase.value
        XCTAssertEqual(outcome, .notEntitled)

        let diagnostics = client.state.entitlement?.diagnostics
        XCTAssertEqual(diagnostics?.purchasedProductID, "premium.monthly")
        XCTAssertEqual(diagnostics?.diagnosis, .productNotAttachedToEntitlement)
    }

    func testFreshnessMergePreservesDiagnosticCollections() async throws {
        let date = Date(timeIntervalSince1970: 3_000)
        let info = makeCustomerInfo(
            appUserID: "user-a",
            requestDate: date,
            allPurchasedProductIDs: ["premium.monthly"]
        )
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.customerInfoResponses = [.success(info), .success(info), .success(info)]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())

        let forced = try await client.forceRefresh()

        XCTAssertEqual(forced.freshness, .networkConfirmed)
        XCTAssertEqual(forced.diagnostics.allPurchasedProductIDs, ["premium.monthly"])
        XCTAssertEqual(client.state.entitlement?.diagnostics.allPurchasedProductIDs, ["premium.monthly"])
    }

    private func makeClientWithOption() async throws -> (
        client: RevenueCatClient,
        provider: FakeRevenueCatProvider,
        optionID: PurchaseOptionID
    ) {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering() else {
            throw RevenueCatClientError.optionUnavailable
        }
        return (client, provider, offering.purchaseOptions[0].id)
    }
}
