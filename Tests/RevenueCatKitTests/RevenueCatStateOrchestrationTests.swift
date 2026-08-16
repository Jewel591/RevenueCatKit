import Observation
import XCTest
@testable import RevenueCatKit

private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
final class RevenueCatStateOrchestrationTests: XCTestCase {
    func testFreshAccountIdentityRestoresPersistedUserThenLogsIn() async throws {
        let provider = FakeRevenueCatProvider()
        let client = RevenueCatClient(provider: provider)

        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())

        XCTAssertNil(provider.configuredAppUserID)
        XCTAssertEqual(provider.logInCallCount, 1)
        XCTAssertEqual(client.state.identityAlignment, .matching)
        XCTAssertEqual(client.state.currentAppUserID, "user-a")
    }

    func testPersistedAnonymousPurchasesAreAliasedOnFirstIdentifiedConfigure() async throws {
        let provider = FakeRevenueCatProvider()
        provider.appUserID = "$RCAnonymousID:legacy"
        provider.isAnonymous = true
        provider.logInResponse = .success(makeCustomerInfo(appUserID: "user-a"))
        let client = RevenueCatClient(provider: provider)

        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())

        XCTAssertNil(provider.configuredAppUserID)
        XCTAssertEqual(provider.logInCallCount, 1)
        XCTAssertEqual(provider.appUserID, "user-a")
        XCTAssertEqual(client.state.identityAlignment, .matching)
        XCTAssertEqual(client.state.currentAppUserID, "user-a")
    }

    func testDesiredAnonymousCorrectsRestoredIdentifiedIdentityBeforeInitialRefresh() async throws {
        let provider = FakeRevenueCatProvider()
        provider.appUserID = "restored-user"
        provider.isAnonymous = false
        let client = RevenueCatClient(provider: provider)

        client.setDesiredIdentity(.anonymous)
        try await client.configure(makeConfiguration())

        XCTAssertEqual(provider.logOutCallCount, 1)
        XCTAssertTrue(provider.customerInfoPolicies.isEmpty)
        XCTAssertTrue(client.state.isAnonymous)
        XCTAssertEqual(client.state.identityAlignment, .matching)
        XCTAssertEqual(client.state.accessLevel, .free)
    }

    func testLatestDesiredIdentityWinsWithoutPollingOrStoppingOnIntermediateIdentity() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.suspendLogIn = true

        client.setDesiredIdentity(.account("user-b"))
        let didStartFirstLogin = await waitUntil { provider.logInCallCount == 1 }
        XCTAssertTrue(didStartFirstLogin)
        client.setDesiredIdentity(.account("user-c"))

        provider.resumeLogIn(
            appUserID: "user-b",
            result: .success(makeCustomerInfo(appUserID: "user-b"))
        )

        let didReachLatestIdentity = await waitUntil { provider.logInCallCount == 2 }
        XCTAssertTrue(didReachLatestIdentity)
        XCTAssertEqual(client.state.currentAppUserID, "user-c")
        XCTAssertEqual(client.state.desiredIdentity, .account("user-c"))
        XCTAssertEqual(client.state.identityAlignment, .matching)
    }

    func testSameDesiredIdentityRetriesOnlyAfterAlignmentFailure() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.logInResponse = .failure(.network)

        client.setDesiredIdentity(.account("user-b"))
        let didFailAlignment = await waitUntil {
            client.state.identityAlignment == .failed(.networkUnavailable)
        }
        XCTAssertTrue(didFailAlignment)
        XCTAssertEqual(provider.logInCallCount, 1)

        provider.logInResponse = .success(makeCustomerInfo(appUserID: "user-b"))
        client.setDesiredIdentity(.account("user-b"))

        let didRetryAlignment = await waitUntil { client.state.identityAlignment == .matching }
        XCTAssertTrue(didRetryAlignment)
        XCTAssertEqual(provider.logInCallCount, 2)
        client.setDesiredIdentity(.account("user-b"))
        await Task.yield()
        XCTAssertEqual(provider.logInCallCount, 2)
    }

    func testIdentityChangeWaitsForPurchaseAndNeverPublishesOldUsersEntitlement() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering() else {
            return XCTFail("Expected current Offering")
        }
        let optionID = offering.purchaseOptions[0].id
        provider.suspendPurchase = true
        let purchase = Task { @MainActor in
            try await client.purchase(optionID)
        }
        let didStartPurchase = await waitUntil { provider.purchaseCallCount == 1 }
        XCTAssertTrue(didStartPurchase)

        client.setDesiredIdentity(.anonymous)

        XCTAssertEqual(provider.logOutCallCount, 0)
        XCTAssertEqual(client.state.accessLevel, .unknown)
        XCTAssertNil(client.state.entitlement)
        XCTAssertEqual(client.state.offering(for: .current), .idle)

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
            XCTFail("The superseded identity must reject the old purchase result")
        } catch let error as RevenueCatClientError {
            XCTAssertEqual(error, .identityChangedDuringOperation)
        }

        let didLogOut = await waitUntil { provider.logOutCallCount == 1 }
        XCTAssertTrue(didLogOut)
        let didAlignAnonymously = await waitUntil { client.state.identityAlignment == .matching }
        XCTAssertTrue(didAlignAnonymously)
        XCTAssertTrue(client.state.isAnonymous)
        XCTAssertEqual(client.state.accessLevel, .free)
    }

    func testSameOfferingIdentifierAcrossScopesKeepsBothSnapshotsPurchasable() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering(offeringID: "shared")
        guard case .available(let current) = try await client.loadOffering() else {
            return XCTFail("Expected current Offering")
        }

        provider.offeringValue = makeProviderOffering(offeringID: "shared")
        let placement: OfferingScope = .placement("onboarding")
        guard case .available(let placed) = try await client.loadOffering(for: placement) else {
            return XCTFail("Expected placement Offering")
        }

        XCTAssertEqual(client.state.offering(for: .current), .available(current))
        XCTAssertEqual(client.state.offering(for: placement), .available(placed))
        _ = try await client.purchase(current.purchaseOptions[0].id)
        _ = try await client.purchase(placed.purchaseOptions[0].id)
        XCTAssertEqual(provider.purchaseCallCount, 2)
    }

    func testReloadingOneScopeInvalidatesOnlyThatScopesPreviousOptions() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering(offeringID: "shared")
        guard case .available(let current) = try await client.loadOffering() else {
            return XCTFail("Expected current Offering")
        }
        let placement: OfferingScope = .placement("feature_gate")
        guard case .available(let firstPlacement) = try await client.loadOffering(for: placement) else {
            return XCTFail("Expected placement Offering")
        }

        guard case .available(let refreshedPlacement) = try await client.loadOffering(for: placement) else {
            return XCTFail("Expected refreshed placement Offering")
        }

        await assertClientError(.optionUnavailable) {
            _ = try await client.purchase(firstPlacement.purchaseOptions[0].id)
        }
        _ = try await client.purchase(current.purchaseOptions[0].id)
        _ = try await client.purchase(refreshedPlacement.purchaseOptions[0].id)
        XCTAssertEqual(provider.purchaseCallCount, 2)
    }

    func testOfferingMissingEmptyAndFailureRemainDistinctAndCannotReuseOldOption() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering()
        guard case .available(let available) = try await client.loadOffering() else {
            return XCTFail("Expected current Offering")
        }
        let staleOptionID = available.purchaseOptions[0].id

        provider.offeringValue = nil
        let missing = try await client.loadOffering()
        XCTAssertEqual(missing, .missing)
        provider.offeringValue = .init(identifier: "empty", packages: [])
        let empty = try await client.loadOffering()
        XCTAssertEqual(empty, .empty)
        provider.offeringError = .network
        let failed = try await client.loadOffering()
        XCTAssertEqual(failed, .failed(.networkUnavailable))
        XCTAssertTrue(client.state.offering(for: .current).purchaseOptions.isEmpty)
        await assertClientError(.optionUnavailable) {
            _ = try await client.purchase(staleOptionID)
        }
    }

    func testOfferingStatePublishesThroughObservationAsOneStateReplacement() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering()
        let flag = ObservationFlag()

        withObservationTracking {
            _ = client.state
        } onChange: {
            flag.fired = true
        }

        _ = try await client.loadOffering()
        XCTAssertTrue(flag.fired)
        XCTAssertEqual(client.state.offering(for: .current).purchaseOptions.count, 1)
    }
}
