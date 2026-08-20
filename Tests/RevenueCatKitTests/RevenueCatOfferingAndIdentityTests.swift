import XCTest
@testable import RevenueCatKit

@MainActor
final class RevenueCatOfferingAndIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetStandardRevocationGraceState()
    }
    func testBlankPlacementIsRejectedBeforeProviderCall() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)

        let result = try await client.loadOffering(for: .placement(.init(" \n ")))
        XCTAssertEqual(result, .failed(.invalidConfiguration(.emptyPlacementID)))
        XCTAssertTrue(provider.offeringPlacements.isEmpty)
    }

    func testCurrentAndPlacementRequestsPreserveMissingEmptyAndFallbackResults() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)

        provider.offeringValue = nil
        let missingCurrent = try await client.loadOffering()
        XCTAssertEqual(missingCurrent, .missing)
        XCTAssertNil(provider.offeringPlacements.last!)

        provider.offeringValue = .init(identifier: "empty", packages: [])
        let emptyPlacement = try await client.loadOffering(
            for: .placement(.init(" onboarding "))
        )
        XCTAssertEqual(emptyPlacement, .empty)
        XCTAssertEqual(provider.offeringPlacements.last!, .init("onboarding"))

        provider.offeringValue = makeProviderOffering(offeringID: "dashboard-fallback")
        let fallback = try await client.loadOffering(for: .placement("feature_gate"))
        guard case .available(let snapshot) = fallback else {
            return XCTFail("Expected dashboard fallback offering")
        }
        XCTAssertEqual(snapshot.offeringID, "dashboard-fallback")
        XCTAssertEqual(snapshot.placement, .init("feature_gate"))
        XCTAssertEqual(snapshot.purchaseOptions.count, 1)
        let introductoryOffer = snapshot.purchaseOptions.first?.introductoryOffer
        XCTAssertEqual(introductoryOffer?.localizedPrice, "$4.99")
        XCTAssertEqual(introductoryOffer?.paymentMode, .payUpFront)
        XCTAssertEqual(introductoryOffer?.subscriptionPeriod.value, 1)
        XCTAssertEqual(introductoryOffer?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(introductoryOffer?.numberOfPeriods, 1)
    }

    func testProviderFailureIsNotConflatedWithMissingOffering() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringError = .network

        let result = try await client.loadOffering()
        XCTAssertEqual(result, .failed(.networkUnavailable))
    }

    func testMissingRefreshInvalidatesPreviouslyReturnedOption() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering() else {
            return XCTFail("Expected offering")
        }
        let optionID = offering.purchaseOptions[0].id

        provider.offeringValue = nil
        let missing = try await client.loadOffering()
        XCTAssertEqual(missing, .missing)
        await assertClientError(.optionUnavailable) {
            _ = try await client.purchase(optionID)
        }
        XCTAssertEqual(provider.purchaseCallCount, 0)
    }

    func testStaleOfferingThrowsWithoutInstallingOldUsersOptions() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.suspendOffering = true
        let request = Task { @MainActor in
            try await client.loadOffering()
        }

        let didStartOffering = await waitUntil { provider.offeringPlacements.count == 1 }
        XCTAssertTrue(didStartOffering)
        provider.appUserID = "user-b"
        provider.isAnonymous = false
        let staleOffering = makeProviderOffering()
        provider.resumeOffering(fetchedForAppUserID: "user-a", offering: staleOffering)

        let result = try await request.value
        XCTAssertEqual(result, .idle)

        let staleOption = PurchaseOptionID()
        await assertClientError(.optionUnavailable) {
            _ = try await client.purchase(staleOption)
        }
        XCTAssertEqual(provider.purchaseCallCount, 0)
    }

    func testRefreshingSameOfferingInvalidatesPriorSnapshotOption() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringValue = makeProviderOffering(
            offeringID: "current",
            packageIdentifier: "$rc_monthly"
        )
        guard case .available(let firstOffering) = try await client.loadOffering() else {
            return XCTFail("Expected first offering")
        }
        let staleOptionID = firstOffering.purchaseOptions[0].id

        // The dashboard may reuse both identifiers while changing the Store product behind them.
        provider.offeringValue = makeProviderOffering(
            offeringID: "current",
            packageIdentifier: "$rc_monthly"
        )
        guard case .available(let refreshedOffering) = try await client.loadOffering() else {
            return XCTFail("Expected refreshed offering")
        }
        let currentOptionID = refreshedOffering.purchaseOptions[0].id

        XCTAssertNotEqual(staleOptionID, currentOptionID)
        await assertClientError(.optionUnavailable) {
            _ = try await client.purchase(staleOptionID)
        }
        XCTAssertEqual(provider.purchaseCallCount, 0)

        let outcome = try await client.purchase(currentOptionID)
        XCTAssertEqual(outcome, .notEntitled)
        XCTAssertEqual(provider.purchaseCallCount, 1)
    }

    func testIntroEligibilityIsCachedPerIdentityAndInvalidatedByCustomerInfo() async throws {
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a")),
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 2_000))),
        ]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering() else {
            return XCTFail("Expected offering")
        }
        let optionID = offering.purchaseOptions[0].id
        provider.eligibilityValue = .eligible

        let firstEligibility = try await client.checkIntroEligibility(for: optionID)
        let cachedEligibility = try await client.checkIntroEligibility(for: optionID)
        XCTAssertEqual(firstEligibility, .eligible)
        XCTAssertEqual(cachedEligibility, .eligible)
        XCTAssertEqual(provider.eligibilityCallCount, 1)

        _ = try await client.refresh()
        let refreshedEligibility = try await client.checkIntroEligibility(for: optionID)
        XCTAssertEqual(refreshedEligibility, .eligible)
        XCTAssertEqual(provider.eligibilityCallCount, 2)
    }

    func testIdentityTransitionImmediatelyClearsEntitlementAndOldOptions() async throws {
        let provider = FakeRevenueCatProvider()
        let initial = makeCustomerInfo(
            appUserID: "user-a",
            entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
        )
        let client = try await makeConfiguredClient(provider: provider, initialCustomerInfo: initial)
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering() else {
            return XCTFail("Expected offering")
        }
        let oldOptionID = offering.purchaseOptions[0].id

        provider.suspendLogIn = true
        client.setDesiredIdentity(.account("user-b"))
        let didStartLogIn = await waitUntil { provider.logInCallCount == 1 }
        XCTAssertTrue(didStartLogIn)

        XCTAssertNil(client.state.entitlement)
        XCTAssertEqual(client.state.accessLevel, .unknown)
        XCTAssertEqual(client.state.operation, .identityChanging)
        await assertClientError(.operationInProgress) {
            _ = try await client.refresh()
        }
        provider.emitCustomerInfoInvalidation()
        await Task.yield()
        XCTAssertEqual(provider.customerInfoPolicies.count, 1)
        await assertClientError(.operationInProgress) {
            _ = try await client.purchase(oldOptionID)
        }

        let userBInfo = makeCustomerInfo(appUserID: "user-b")
        provider.resumeLogIn(appUserID: "user-b", result: .success(userBInfo))
        let didAlign = await waitUntil { client.state.identityAlignment == .matching }
        XCTAssertTrue(didAlign)
        XCTAssertEqual(client.state.currentAppUserID?.rawValue, "user-b")
        XCTAssertEqual(client.state.accessLevel, .free)
        XCTAssertEqual(provider.purchaseCallCount, 0)
        let didProcessPendingStreamRead = await waitUntil {
            provider.customerInfoPolicies.count == 2
        }
        XCTAssertTrue(didProcessPendingStreamRead)

        await assertClientError(.optionUnavailable) {
            _ = try await client.purchase(oldOptionID)
        }
        XCTAssertEqual(provider.purchaseCallCount, 0)
    }

    func testFailedIdentityChangeKeepsActualProviderIdentityButNeverRestoresOldSnapshot() async throws {
        let provider = FakeRevenueCatProvider()
        let initial = makeCustomerInfo(
            appUserID: "user-a",
            entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
        )
        let client = try await makeConfiguredClient(provider: provider, initialCustomerInfo: initial)
        provider.logInResponse = .failure(.network)

        client.setDesiredIdentity(.account("user-b"))
        let didFail = await waitUntil {
            client.state.identityAlignment == .failed(.networkUnavailable)
        }
        XCTAssertTrue(didFail)

        XCTAssertEqual(client.state.currentAppUserID?.rawValue, "user-a")
        XCTAssertFalse(client.state.isAnonymous)
        XCTAssertNil(client.state.entitlement)
        XCTAssertEqual(client.state.accessLevel, .unknown)
    }

    func testIdentityPolicyRestrictsMutationAPIs() async throws {
        let anonymousProvider = FakeRevenueCatProvider()
        let anonymousClient = RevenueCatClient(provider: anonymousProvider)
        try await anonymousClient.configure(
            makeConfiguration(identityPolicy: .anonymousOnly)
        )
        anonymousClient.setDesiredIdentity(.account("user"))
        XCTAssertEqual(
            anonymousClient.state.identityAlignment,
            .failed(.invalidConfiguration(.accountIdentityNotAllowed))
        )

        let identifiedProvider = FakeRevenueCatProvider()
        let identifiedClient = RevenueCatClient(provider: identifiedProvider)
        identifiedClient.setDesiredIdentity(.account("user-a"))
        try await identifiedClient.configure(
            makeConfiguration(identityPolicy: .identifiedOnly)
        )
        identifiedClient.setDesiredIdentity(.anonymous)
        XCTAssertEqual(
            identifiedClient.state.identityAlignment,
            .failed(.invalidConfiguration(.missingDesiredAccountIdentity))
        )
    }
}
