import XCTest
@testable import RevenueCatKit

@MainActor
final class RevenueCatEntitlementTests: XCTestCase {
    func testMissingEntitlementIsKnownFree() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)

        XCTAssertEqual(client.state.accessLevel, .free)
        XCTAssertEqual(client.state.entitlement?.billingCondition, .notApplicable)
        XCTAssertNil(client.state.entitlement?.productID)
        XCTAssertEqual(client.state.entitlement?.freshness, .cachePermitted)
    }

    func testAnyEnvironmentActiveNeverGrantsCurrentEnvironmentAccess() async throws {
        let provider = FakeRevenueCatProvider()
        let info = makeCustomerInfo(
            appUserID: "user-a",
            entitlement: makeEntitlement(
                isActiveInCurrentEnvironment: false,
                isActiveInAnyEnvironment: true,
                isSandbox: true
            )
        )
        let client = try await makeConfiguredClient(provider: provider, initialCustomerInfo: info)

        XCTAssertEqual(client.state.accessLevel, .free)
        XCTAssertEqual(client.state.entitlement?.billingCondition, .expired)
    }

    func testBillingConditionDecisionTable() async throws {
        struct Case {
            let entitlement: ProviderEntitlement
            let expectedAccess: AccessLevel
            let expectedBilling: BillingCondition
        }
        let marker = Date(timeIntervalSince1970: 1_500)
        let cases: [Case] = [
            .init(
                entitlement: makeEntitlement(isActiveInCurrentEnvironment: false),
                expectedAccess: .free,
                expectedBilling: .expired
            ),
            .init(
                entitlement: makeEntitlement(
                    isActiveInCurrentEnvironment: true,
                    unsubscribeDetectedAt: marker,
                    billingIssueDetectedAt: marker
                ),
                expectedAccess: .premiumInGracePeriod,
                expectedBilling: .billingIssueWhileActive
            ),
            .init(
                entitlement: makeEntitlement(
                    isActiveInCurrentEnvironment: true,
                    unsubscribeDetectedAt: marker
                ),
                expectedAccess: .premium,
                expectedBilling: .cancelledButActive
            ),
            .init(
                entitlement: makeEntitlement(
                    isActiveInCurrentEnvironment: true,
                    expirationDate: nil
                ),
                expectedAccess: .premium,
                expectedBilling: .notApplicable
            ),
            .init(
                entitlement: makeEntitlement(isActiveInCurrentEnvironment: true),
                expectedAccess: .premium,
                expectedBilling: .healthy
            ),
        ]

        for testCase in cases {
            let provider = FakeRevenueCatProvider()
            let info = makeCustomerInfo(appUserID: "user-a", entitlement: testCase.entitlement)
            let client = try await makeConfiguredClient(provider: provider, initialCustomerInfo: info)
            XCTAssertEqual(client.state.accessLevel, testCase.expectedAccess)
            XCTAssertEqual(client.state.entitlement?.billingCondition, testCase.expectedBilling)
        }
    }

    func testTestFlightChannelIsDiagnosticAndDoesNotDenyCurrentSandboxEntitlement() async throws {
        let provider = FakeRevenueCatProvider()
        let info = makeCustomerInfo(
            appUserID: "user-a",
            entitlement: makeEntitlement(
                isActiveInCurrentEnvironment: true,
                isSandbox: true
            )
        )
        let client = try await makeConfiguredClient(
            provider: provider,
            initialCustomerInfo: info,
            distributionChannel: .testFlightSandbox
        )

        XCTAssertEqual(client.state.distributionChannel, .testFlightSandbox)
        XCTAssertEqual(client.state.accessLevel, .premium)
    }

    func testForceRefreshUpgradesFreshnessAndCacheReadCannotDowngradeIt() async throws {
        let date = Date(timeIntervalSince1970: 3_000)
        let info = makeCustomerInfo(appUserID: "user-a", requestDate: date)
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.customerInfoResponses = [.success(info), .success(info), .success(info)]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        XCTAssertEqual(client.state.entitlement?.freshness, .cachePermitted)

        let forced = try await client.forceRefresh()
        XCTAssertEqual(forced.freshness, .networkConfirmed)

        let cached = try await client.refresh(policy: .cachedOrFetched)
        XCTAssertEqual(cached.freshness, .networkConfirmed)
        XCTAssertEqual(client.state.entitlement?.freshness, .networkConfirmed)
        XCTAssertEqual(client.state.entitlement?.requestDate, date)
    }

    func testOlderSameIdentityRefreshReturnsPublishedNewerSnapshot() async throws {
        let newerDate = Date(timeIntervalSince1970: 4_000)
        let olderDate = Date(timeIntervalSince1970: 2_000)
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: newerDate)),
            .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: olderDate,
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                )
            ),
        ]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())

        let result = try await client.refresh()

        XCTAssertEqual(result.requestDate, newerDate)
        XCTAssertEqual(result.accessLevel, .free)
        XCTAssertEqual(client.state.entitlement, result)
    }

    func testRefreshFailureRetainsKnownSnapshotAndNoSnapshotFailureStaysUnknown() async throws {
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.customerInfoResponses = [
            .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                )
            ),
            .failure(.network),
        ]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        let known = client.state.entitlement

        await assertClientError(.networkUnavailable) {
            _ = try await client.refresh()
        }
        XCTAssertEqual(client.state.entitlement, known)

        let failingProvider = FakeRevenueCatProvider()
        seedPersistedAccount(failingProvider)
        failingProvider.customerInfoResponses = [.failure(.network)]
        let failingClient = RevenueCatClient(provider: failingProvider)
        failingClient.setDesiredIdentity(.account("user-a"))
        await assertClientError(.networkUnavailable) {
            try await failingClient.configure(makeConfiguration())
        }
        XCTAssertNil(failingClient.state.entitlement)
        XCTAssertEqual(failingClient.state.accessLevel, .unknown)
    }

    func testStaleRefreshThrowsAndNeverReturnsPreviousUsersData() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.suspendCustomerInfo = true
        let refresh = Task { @MainActor in
            try await client.refresh()
        }

        let didStartRefresh = await waitUntil { provider.customerInfoPolicies.count == 2 }
        XCTAssertTrue(didStartRefresh)
        provider.appUserID = "user-b"
        provider.isAnonymous = false
        provider.resumeCustomerInfo(
            with: .success(
                makeCustomerInfo(
                    appUserID: "user-a",
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
                )
            )
        )

        do {
            _ = try await refresh.value
            XCTFail("Expected stale refresh to fail")
        } catch let error as RevenueCatClientError {
            XCTAssertEqual(error, .identityChangedDuringOperation)
        }
        XCTAssertEqual(client.state.accessLevel, .free)
    }

    func testStreamInvalidationReReadsCurrentIdentityAndKeepsStrongFreshness() async throws {
        let date = Date(timeIntervalSince1970: 5_000)
        let info = makeCustomerInfo(appUserID: "user-a", requestDate: date)
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.customerInfoResponses = [.success(info), .success(info), .success(info)]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        _ = try await client.forceRefresh()

        provider.emitCustomerInfoInvalidation()
        let didReRead = await waitUntil { provider.customerInfoPolicies.count == 3 }
        XCTAssertTrue(didReRead)
        XCTAssertEqual(client.state.entitlement?.freshness, .networkConfirmed)
        XCTAssertEqual(provider.streamInstallCount, 1)
    }
}
