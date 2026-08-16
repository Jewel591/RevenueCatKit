import XCTest
@testable import RevenueCatKit

@MainActor
final class RevenueCatConfigurationTests: XCTestCase {
    func testConfigurationRejectsInvalidAppOwnedFactsAndIdentityCombinations() async {
        let cases: [(
            RevenueCatClient.Configuration,
            RevenueCatClient.DesiredIdentity?,
            RevenueCatClientError
        )] = [
            (
                .init(
                    publicSDKKey: "  ",
                    premiumEntitlementID: "premium",
                    identityPolicy: .anonymousOnly
                ),
                nil,
                .invalidConfiguration(.emptyPublicSDKKey)
            ),
            (
                .init(
                    publicSDKKey: "key",
                    premiumEntitlementID: "\n",
                    identityPolicy: .anonymousOnly
                ),
                nil,
                .invalidConfiguration(.emptyPremiumEntitlementID)
            ),
            (
                makeConfiguration(identityPolicy: .identifiedOnly),
                nil,
                .invalidConfiguration(.missingDesiredAccountIdentity)
            ),
            (
                makeConfiguration(identityPolicy: .anonymousOnly),
                .account("user-a"),
                .invalidConfiguration(.accountIdentityNotAllowed)
            ),
            (
                makeConfiguration(),
                .account(" "),
                .invalidConfiguration(.emptyAppUserID)
            ),
        ]

        for (configuration, desiredIdentity, expectedError) in cases {
            let provider = FakeRevenueCatProvider()
            let client = RevenueCatClient(provider: provider)
            if let desiredIdentity {
                client.setDesiredIdentity(desiredIdentity)
            }
            await assertClientError(expectedError) {
                try await client.configure(configuration)
            }
            XCTAssertEqual(provider.configureCallCount, 0)
            XCTAssertEqual(client.state.operation, .idle)
        }
    }

    func testAppUserIDValidationFreezesReservedAndCharacterRules() throws {
        let blocked: [RevenueCatClient.AppUserID] = [
            " anonymous ",
            "[OBJECT OBJECT]",
            "$RCAnonymousID:forged",
            "$rc_preview_mode_user_test",
            "\0",
        ]
        for value in blocked {
            XCTAssertThrowsError(try RevenueCatClient.AppUserID.validated(value)) { error in
                XCTAssertEqual(
                    error as? RevenueCatClientError,
                    .invalidConfiguration(.blockedAppUserID)
                )
            }
        }

        for value: RevenueCatClient.AppUserID in ["user/name", "user name"] {
            XCTAssertThrowsError(try RevenueCatClient.AppUserID.validated(value)) { error in
                XCTAssertEqual(
                    error as? RevenueCatClientError,
                    .invalidConfiguration(.appUserIDContainsInvalidCharacters)
                )
            }
        }
        XCTAssertThrowsError(
            try RevenueCatClient.AppUserID.validated(
                .init(String(repeating: "a", count: 101))
            )
        ) { error in
            XCTAssertEqual(
                error as? RevenueCatClientError,
                .invalidConfiguration(.appUserIDTooLong)
            )
        }
        XCTAssertEqual(
            try RevenueCatClient.AppUserID.validated("  user-123  ").rawValue,
            "user-123"
        )
    }

    func testExternallyConfiguredSDKIsNeverReplaced() async {
        let provider = FakeRevenueCatProvider()
        provider.isConfigured = true
        provider.appUserID = "external"
        provider.isAnonymous = false
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))

        await assertClientError(.alreadyConfiguredExternally) {
            try await client.configure(makeConfiguration())
        }

        XCTAssertEqual(provider.configureCallCount, 0)
        XCTAssertEqual(client.state.operation, .idle)
        XCTAssertNil(client.state.entitlement)
    }

    func testIdentifiedConfigurationLogsInAfterRestoringPersistedIdentity() async throws {
        let provider = FakeRevenueCatProvider()
        provider.logInResponse = .success(makeCustomerInfo(appUserID: "user-a"))
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account(" user-a "))

        try await client.configure(makeConfiguration(identityPolicy: .identifiedOnly))

        XCTAssertNil(provider.configuredAppUserID)
        XCTAssertEqual(provider.logInCallCount, 1)
        XCTAssertEqual(provider.configureCallCount, 1)
        XCTAssertEqual(client.state.currentAppUserID?.rawValue, "user-a")
        XCTAssertFalse(client.state.isAnonymous)
    }

    func testAnonymousAndIdentifiedPolicyAcceptsRestoredIdentifiedIdentity() async throws {
        let provider = FakeRevenueCatProvider()
        provider.appUserID = "restored-user"
        provider.isAnonymous = false
        provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "restored-user"))]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("restored-user"))

        try await client.configure(makeConfiguration())

        XCTAssertNil(provider.configuredAppUserID)
        XCTAssertEqual(provider.logInCallCount, 0)
        XCTAssertEqual(client.state.currentAppUserID?.rawValue, "restored-user")
        XCTAssertFalse(client.state.isAnonymous)
    }

    func testAnonymousOnlyRejectsRestoredIdentifiedIdentityBeforeObserverOrRefresh() async {
        let provider = FakeRevenueCatProvider()
        provider.appUserID = "restored-user"
        provider.isAnonymous = false
        let client = RevenueCatClient(provider: provider)
        let configuration = makeConfiguration(identityPolicy: .anonymousOnly)

        await assertClientError(.anonymousIdentityUnavailable) {
            try await client.configure(configuration)
        }

        XCTAssertEqual(client.state.currentAppUserID?.rawValue, "restored-user")
        XCTAssertFalse(client.state.isAnonymous)
        XCTAssertNil(client.state.entitlement)
        XCTAssertEqual(provider.streamInstallCount, 0)
        XCTAssertTrue(provider.customerInfoPolicies.isEmpty)

        await assertClientError(.anonymousIdentityUnavailable) {
            try await client.configure(configuration)
        }
        XCTAssertEqual(provider.configureCallCount, 1)
    }

    func testInitialRefreshFailureCanRetryWithoutReconfigureOrSecondObserver() async throws {
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.customerInfoResponses = [.failure(.network)]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))

        await assertClientError(.networkUnavailable) {
            try await client.configure(makeConfiguration())
        }
        XCTAssertNil(client.state.entitlement)
        XCTAssertEqual(provider.configureCallCount, 1)
        XCTAssertEqual(provider.streamInstallCount, 1)

        provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a"))]
        try await client.configure(makeConfiguration())

        XCTAssertEqual(provider.configureCallCount, 1)
        XCTAssertEqual(provider.streamInstallCount, 1)
        XCTAssertEqual(client.state.accessLevel, .free)
    }

    func testConcurrentConfigureIsBlockedBeforeSecondSDKCall() async throws {
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        provider.suspendCustomerInfo = true
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("user-a"))
        let first = Task { @MainActor in
            try await client.configure(makeConfiguration())
        }

        let didStartInitialRefresh = await waitUntil { provider.customerInfoPolicies.count == 1 }
        XCTAssertTrue(didStartInitialRefresh)
        await assertClientError(.operationInProgress) {
            try await client.configure(makeConfiguration())
        }
        XCTAssertEqual(provider.configureCallCount, 1)

        provider.resumeCustomerInfo(with: .success(makeCustomerInfo(appUserID: "user-a")))
        try await first.value
        XCTAssertEqual(client.state.operation, .idle)
    }

    func testNewCoreDoesNotTouchLegacyUserDefaultsKeys() async throws {
        let defaults = UserDefaults.standard
        let cachedKey = "cachedPremiumAccess"
        let syncedKey = "hasSyncedPremiumAccess"
        let previousCached = defaults.object(forKey: cachedKey)
        let previousSynced = defaults.object(forKey: syncedKey)
        defer {
            if let previousCached {
                defaults.set(previousCached, forKey: cachedKey)
            } else {
                defaults.removeObject(forKey: cachedKey)
            }
            if let previousSynced {
                defaults.set(previousSynced, forKey: syncedKey)
            } else {
                defaults.removeObject(forKey: syncedKey)
            }
        }
        defaults.set("sentinel-cached", forKey: cachedKey)
        defaults.set("sentinel-synced", forKey: syncedKey)

        let provider = FakeRevenueCatProvider()
        _ = try await makeConfiguredClient(provider: provider)

        XCTAssertEqual(defaults.string(forKey: cachedKey), "sentinel-cached")
        XCTAssertEqual(defaults.string(forKey: syncedKey), "sentinel-synced")
    }
}
