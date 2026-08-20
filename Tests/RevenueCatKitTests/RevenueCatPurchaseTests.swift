import XCTest
@testable import RevenueCatKit

@MainActor
final class RevenueCatPurchaseTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetStandardRevocationGraceState()
    }
    func testPurchaseUsesEntitlementBeforeCancellationFlag() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        provider.purchaseResponse = .success(
            .init(
                customerInfo: makeCustomerInfo(
                    appUserID: "user-a",
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                ),
                userCancelled: true
            )
        )

        let outcome = try await client.purchase(optionID)

        guard case .purchased(let snapshot) = outcome else {
            return XCTFail("Active entitlement must win over the cancellation flag")
        }
        XCTAssertEqual(snapshot.accessLevel, .premium)
        XCTAssertEqual(client.state.accessLevel, .premium)
    }

    func testPurchaseDistinguishesCancelledPendingAndNotEntitled() async throws {
        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .success(
                .init(
                    customerInfo: makeCustomerInfo(appUserID: "user-a"),
                    userCancelled: true
                )
            )
            let outcome = try await client.purchase(optionID)
            XCTAssertEqual(outcome, .cancelled)
        }

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.purchaseCancelled)
            let outcome = try await client.purchase(optionID)
            XCTAssertEqual(outcome, .cancelled)
        }

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.paymentPending)
            let outcome = try await client.purchase(optionID)
            XCTAssertEqual(outcome, .pending)
        }

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .success(
                .init(
                    customerInfo: makeCustomerInfo(appUserID: "user-a"),
                    userCancelled: false
                )
            )
            let outcome = try await client.purchase(optionID)
            XCTAssertEqual(outcome, .notEntitled)
        }
    }

    func testProductAlreadyPurchasedRefetchesAndRequiresActiveEntitlement() async throws {
        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.productAlreadyPurchased)
            provider.customerInfoResponses = [
                .success(
                    makeCustomerInfo(
                        appUserID: "user-a",
                        requestDate: Date(timeIntervalSince1970: 2_000),
                        entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                    )
                ),
            ]
            guard case .purchased = try await client.purchase(optionID) else {
                return XCTFail("Expected refetched active entitlement")
            }
            XCTAssertEqual(provider.customerInfoPolicies.last, .fetchCurrent)
        }

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.productAlreadyPurchased)
            provider.customerInfoResponses = [
                .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 2_000))),
            ]
            await assertClientError(.invalidPurchase) {
                _ = try await client.purchase(optionID)
            }
        }

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.productAlreadyPurchased)
            provider.customerInfoResponses = [.failure(.network)]
            await assertClientError(.networkUnavailable) {
                _ = try await client.purchase(optionID)
            }
        }
    }

    func testAmbiguousStoreProblemRefetchesBeforeChoosingOutcome() async throws {
        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.storeProblem)
            provider.customerInfoResponses = [
                .success(
                    makeCustomerInfo(
                        appUserID: "user-a",
                        requestDate: Date(timeIntervalSince1970: 2_000),
                        entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                    )
                ),
            ]
            guard case .purchased = try await client.purchase(optionID) else {
                return XCTFail("Expected active entitlement after store problem")
            }
        }

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.storeProblem)
            provider.customerInfoResponses = [
                .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 2_000))),
            ]
            await assertClientError(.purchaseStatusUnknown) {
                _ = try await client.purchase(optionID)
            }
        }

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(.storeProblem)
            provider.customerInfoResponses = [.failure(.network)]
            await assertClientError(.networkUnavailable) {
                _ = try await client.purchase(optionID)
            }
        }
    }

    func testPurchaseErrorNormalization() async throws {
        let mappings: [(ProviderError, RevenueCatClientError)] = [
            (.network, .networkUnavailable),
            (.purchaseNotAllowed, .storeUnavailable),
            (.productNotAvailable, .storeUnavailable),
            (.purchaseInvalid, .invalidPurchase),
            (.invalidReceipt, .invalidPurchase),
            (.invalidAppUserID, .invalidPurchase),
            (.operationInProgress, .operationInProgress),
            (.unknown, .unknown),
        ]

        for (providerError, clientError) in mappings {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .failure(providerError)
            await assertClientError(clientError) {
                _ = try await client.purchase(optionID)
            }
        }
    }

    func testCallerCancellationDoesNotReleaseGateBeforeProviderCompletes() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        provider.suspendPurchase = true
        let purchase = Task { @MainActor in
            try await client.purchase(optionID)
        }
        let didStartPurchase = await waitUntil { provider.purchaseCallCount == 1 }
        XCTAssertTrue(didStartPurchase)

        purchase.cancel()
        await assertClientError(.operationInProgress) {
            _ = try await client.purchase(optionID)
        }
        await assertClientError(.operationInProgress) {
            _ = try await client.restorePurchases()
        }
        XCTAssertEqual(provider.purchaseCallCount, 1)
        XCTAssertEqual(provider.restoreCallCount, 0)
        XCTAssertEqual(client.state.operation, .purchasing(optionID))

        provider.resumePurchase(
            with: .success(
                .init(
                    customerInfo: makeCustomerInfo(
                        appUserID: "user-a",
                        entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                    ),
                    userCancelled: false
                )
            )
        )
        do {
            _ = try await purchase.value
            XCTFail("Cancelled caller should receive CancellationError")
        } catch is CancellationError {
            // Expected. The provider task still reconciled state first.
        }
        XCTAssertEqual(client.state.operation, .idle)
        XCTAssertEqual(client.state.accessLevel, .premium)
    }

    func testStalePurchaseCompletionCannotGrantNewIdentity() async throws {
        let (client, provider, optionID) = try await makeClientWithOption()
        provider.suspendPurchase = true
        let purchase = Task { @MainActor in
            try await client.purchase(optionID)
        }
        let didStartPurchase = await waitUntil { provider.purchaseCallCount == 1 }
        XCTAssertTrue(didStartPurchase)

        provider.appUserID = "user-b"
        provider.isAnonymous = false
        provider.resumePurchase(
            with: .success(
                .init(
                    customerInfo: makeCustomerInfo(
                        appUserID: "user-a",
                        entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                    ),
                    userCancelled: false
                )
            )
        )

        do {
            _ = try await purchase.value
            XCTFail("Expected stale purchase to fail")
        } catch let error as RevenueCatClientError {
            XCTAssertEqual(error, .identityChangedDuringOperation)
        }
        XCTAssertEqual(client.state.accessLevel, .free)
        XCTAssertEqual(client.state.operation, .idle)
    }

    func testRestoreUsesCurrentEnvironmentEntitlement() async throws {
        do {
            let provider = FakeRevenueCatProvider()
            let client = try await makeConfiguredClient(provider: provider)
            provider.restoreResponse = .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: Date(timeIntervalSince1970: 2_000),
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                )
            )
            guard case .restored(let snapshot) = try await client.restorePurchases() else {
                return XCTFail("Expected restored entitlement")
            }
            XCTAssertEqual(snapshot.accessLevel, .premium)
        }

        do {
            let provider = FakeRevenueCatProvider()
            let client = try await makeConfiguredClient(provider: provider)
            provider.restoreResponse = .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: Date(timeIntervalSince1970: 2_000),
                    entitlement: makeEntitlement(
                        isActiveInCurrentEnvironment: false,
                        isActiveInAnyEnvironment: true
                    )
                )
            )
            let outcome = try await client.restorePurchases()
            XCTAssertEqual(outcome, .noActiveEntitlement)
        }
    }

    func testBillingGracePeriodStillGrantsPurchaseAndRestoreOutcomes() async throws {
        let marker = Date(timeIntervalSince1970: 1_500)

        do {
            let (client, provider, optionID) = try await makeClientWithOption()
            provider.purchaseResponse = .success(
                .init(
                    customerInfo: makeCustomerInfo(
                        appUserID: "user-a",
                        entitlement: makeEntitlement(
                            isActiveInCurrentEnvironment: true,
                            billingIssueDetectedAt: marker
                        )
                    ),
                    userCancelled: false
                )
            )

            guard case .purchased(let snapshot) = try await client.purchase(optionID) else {
                return XCTFail("An active entitlement in grace period must still grant access")
            }
            XCTAssertEqual(snapshot.accessLevel, .premiumInGracePeriod)
        }

        do {
            let provider = FakeRevenueCatProvider()
            let client = try await makeConfiguredClient(provider: provider)
            provider.restoreResponse = .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    entitlement: makeEntitlement(
                        isActiveInCurrentEnvironment: true,
                        billingIssueDetectedAt: marker
                    )
                )
            )

            guard case .restored(let snapshot) = try await client.restorePurchases() else {
                return XCTFail("An active entitlement in grace period must be restorable")
            }
            XCTAssertEqual(snapshot.accessLevel, .premiumInGracePeriod)
        }
    }

    func testDesiredAnonymousProviderErrorIsNormalizedIntoAlignmentState() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.logOutResponse = .failure(.logOutAnonymousUser)

        client.setDesiredIdentity(.anonymous)

        let didPublishFailure = await waitUntil {
            client.state.identityAlignment == .failed(.identityOperationNotAllowed)
        }
        XCTAssertTrue(didPublishFailure)
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
