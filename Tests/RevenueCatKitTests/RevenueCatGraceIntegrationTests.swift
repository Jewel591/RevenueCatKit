import Foundation
import XCTest
@testable import RevenueCatKit

@MainActor
final class RevenueCatGraceIntegrationTests: XCTestCase {
    private final class Clock {
        var value: TimeInterval = 10_000
    }

    func testConfigureMigratesLegacyAnonymousGraceOnlyToNewAliasTargetAndNotAccountSwitch() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let defaults = context.defaults
        defaults.set(true, forKey: "hasSyncedPremiumAccess")
        defaults.set(true, forKey: "cachedPremiumAccess")
        defaults.set(9_000, forKey: "premiumRevocationFirstSeenAt")

        let provider = FakeRevenueCatProvider()
        provider.appUserID = "$RCAnonymousID:legacy"
        provider.isAnonymous = true
        provider.logInResponse = .success(makeCustomerInfo(appUserID: "user-a"))
        let client = makeClient(provider: provider, defaults: defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))

        try await client.configure(makeConfiguration())

        XCTAssertEqual(client.state.identityAlignment, .matching)
        XCTAssertEqual(client.state.accessLevel, .premiumInGracePeriod)
        XCTAssertEqual(client.state.entitlement?.billingCondition, .entitlementTemporarilyMissing)
        XCTAssertTrue(defaults.bool(forKey: "hasSyncedPremiumAccess"))
        XCTAssertTrue(defaults.bool(forKey: "cachedPremiumAccess"))
        XCTAssertEqual(defaults.double(forKey: "premiumRevocationFirstSeenAt"), 9_000)

        provider.logInResponse = .success(
            makeCustomerInfo(appUserID: "user-b", requestDate: Date(timeIntervalSince1970: 2_000))
        )
        client.setDesiredIdentity(.account("user-b"))
        let didAlign = await waitUntil {
            client.state.identityAlignment == .matching
                && client.state.currentAppUserID == .init("user-b")
        }
        XCTAssertTrue(didAlign)
        XCTAssertEqual(client.state.accessLevel, .free)
    }

    func testConfigureNeverMigratesLegacyAnonymousGraceToExistingAccount() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let defaults = context.defaults
        defaults.set(true, forKey: "hasSyncedPremiumAccess")
        defaults.set(true, forKey: "cachedPremiumAccess")
        defaults.set(9_000, forKey: "premiumRevocationFirstSeenAt")

        let provider = FakeRevenueCatProvider()
        provider.appUserID = "$RCAnonymousID:legacy"
        provider.isAnonymous = true
        provider.logInCreated = false
        provider.logInResponse = .success(makeCustomerInfo(appUserID: "existing-user"))
        let client = makeClient(provider: provider, defaults: defaults, clock: context.clock)
        client.setDesiredIdentity(.account("existing-user"))

        try await client.configure(makeConfiguration())

        XCTAssertEqual(client.state.identityAlignment, .matching)
        XCTAssertEqual(client.state.currentAppUserID, .init("existing-user"))
        XCTAssertEqual(client.state.accessLevel, .free)
        XCTAssertTrue(defaults.bool(forKey: "hasSyncedPremiumAccess"))
        XCTAssertTrue(defaults.bool(forKey: "cachedPremiumAccess"))
        XCTAssertEqual(defaults.double(forKey: "premiumRevocationFirstSeenAt"), 9_000)
    }

    func testActiveMissingRelaunchExpiryAndRecoveryRunThroughClientPersistence() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let defaults = context.defaults
        let provider = identifiedProvider()
        provider.customerInfoResponses = [
            .success(activeInfo(requestDate: 1_000)),
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 2_000))),
        ]
        let client = makeClient(provider: provider, defaults: defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        XCTAssertEqual(client.state.accessLevel, .premium)

        _ = try await client.forceRefresh()
        XCTAssertEqual(client.state.accessLevel, .premiumInGracePeriod)

        let relaunchedProvider = identifiedProvider()
        relaunchedProvider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 3_000))),
        ]
        let relaunched = makeClient(provider: relaunchedProvider, defaults: defaults, clock: context.clock)
        relaunched.setDesiredIdentity(.account("user-a"))
        try await relaunched.configure(makeConfiguration())
        XCTAssertEqual(relaunched.state.accessLevel, .premiumInGracePeriod)

        relaunchedProvider.customerInfoResponses = [.success(activeInfo(requestDate: 4_000))]
        _ = try await relaunched.forceRefresh()
        XCTAssertEqual(relaunched.state.accessLevel, .premium)

        context.clock.value += PremiumRevocationGrace.period + 1
        relaunchedProvider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 5_000))),
        ]
        _ = try await relaunched.forceRefresh()
        XCTAssertEqual(relaunched.state.accessLevel, .premiumInGracePeriod)

        context.clock.value += PremiumRevocationGrace.period
        let expiredProvider = identifiedProvider()
        expiredProvider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 6_000))),
        ]
        let expired = makeClient(provider: expiredProvider, defaults: defaults, clock: context.clock)
        expired.setDesiredIdentity(.account("user-a"))
        try await expired.configure(makeConfiguration())
        XCTAssertEqual(expired.state.accessLevel, .free)
    }

    func testStaleMissingAndActiveResponsesCannotStartOrClearPersistedGraceClock() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let defaults = context.defaults
        let provider = identifiedProvider()
        provider.customerInfoResponses = [.success(activeInfo(requestDate: 3_000))]
        let client = makeClient(provider: provider, defaults: defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())

        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 2_000))),
        ]
        _ = try await client.forceRefresh()
        context.clock.value += PremiumRevocationGrace.period
        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 4_000))),
        ]
        _ = try await client.forceRefresh()
        XCTAssertEqual(client.state.accessLevel, .premiumInGracePeriod)

        provider.customerInfoResponses = [.success(activeInfo(requestDate: 5_000))]
        _ = try await client.forceRefresh()
        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 6_000))),
            .success(activeInfo(requestDate: 5_500)),
        ]
        _ = try await client.forceRefresh()
        _ = try await client.forceRefresh()
        context.clock.value += PremiumRevocationGrace.period
        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 7_000))),
        ]
        _ = try await client.forceRefresh()
        XCTAssertEqual(client.state.accessLevel, .free)
    }

    func testDisappearanceGraceNeverProvesPurchaseOrAmbiguousPurchaseRecovery() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        let defaults = context.defaults
        let provider = identifiedProvider()
        provider.customerInfoResponses = [.success(activeInfo(requestDate: 1_000))]
        let client = makeClient(provider: provider, defaults: defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering(),
              let optionID = offering.purchaseOptions.first?.id else {
            return XCTFail("Missing purchase option")
        }

        provider.purchaseResponse = .success(
            .init(
                customerInfo: makeCustomerInfo(
                    appUserID: "user-a",
                    requestDate: Date(timeIntervalSince1970: 2_000)
                ),
                userCancelled: false
            )
        )
        let purchaseOutcome = try await client.purchase(optionID)
        XCTAssertEqual(purchaseOutcome, .notEntitled)

        provider.purchaseResponse = .failure(.productAlreadyPurchased)
        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 3_000))),
        ]
        await assertClientError(.invalidPurchase) {
            _ = try await client.purchase(optionID)
        }

        provider.purchaseResponse = .failure(.storeProblem)
        provider.customerInfoResponses = [
            .success(makeCustomerInfo(appUserID: "user-a", requestDate: Date(timeIntervalSince1970: 4_000))),
        ]
        await assertClientError(.purchaseStatusUnknown) {
            _ = try await client.purchase(optionID)
        }
    }

    /// #11: a relaunch must not report a customer whose premium this device already
    /// confirmed as `unknown` while the first customer-info fetch is still in flight — that is
    /// what showed paying customers the free presentation for the first seconds of every launch.
    func testRelaunchRendersConfirmedPremiumWhileFirstFetchIsStillInFlight() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        let renewal = Date(timeIntervalSince1970: context.clock.value + 86_400)
        let provider = identifiedProvider()
        provider.customerInfoResponses = [
            .success(activeInfo(requestDate: 1_000, expirationDate: renewal)),
        ]
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        XCTAssertEqual(client.state.accessLevel, .premium)

        let relaunchedProvider = identifiedProvider()
        relaunchedProvider.suspendCustomerInfo = true
        let relaunched = makeClient(
            provider: relaunchedProvider,
            defaults: context.defaults,
            clock: context.clock
        )
        relaunched.setDesiredIdentity(.account("user-a"))
        let configureTask = Task { try await relaunched.configure(makeConfiguration()) }

        let didSeedPremium = await waitUntil {
            relaunched.state.accessLevel.premiumAccess == true
        }
        XCTAssertTrue(didSeedPremium)
        XCTAssertEqual(relaunched.state.identityAlignment, .matching)
        XCTAssertEqual(relaunched.state.entitlement?.freshness, .cachePermitted)
        // A subscriber must not be seeded as "premium with no expiration date": every consumer
        // reads that as a lifetime purchase.
        XCTAssertEqual(relaunched.state.entitlement?.expirationDate, renewal)

        relaunchedProvider.resumeCustomerInfo(
            with: .success(activeInfo(requestDate: 2_000, expirationDate: renewal))
        )
        try await configureTask.value
        XCTAssertEqual(relaunched.state.accessLevel, .premium)
        XCTAssertEqual(relaunched.state.entitlement?.requestDate, Date(timeIntervalSince1970: 2_000))
    }

    /// #11 counterpart: without confirmed premium provenance the in-flight window stays
    /// `unknown`. A launch must never invent premium the device has not seen.
    func testFirstFetchStaysUnknownWithoutConfirmedPremiumProvenance() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        let provider = identifiedProvider()
        provider.suspendCustomerInfo = true
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        let configureTask = Task { try await client.configure(makeConfiguration()) }

        let didReachProvider = await waitUntil {
            !provider.customerInfoPolicies.isEmpty
        }
        XCTAssertTrue(didReachProvider)
        XCTAssertEqual(client.state.accessLevel, .unknown)

        provider.resumeCustomerInfo(with: .success(activeInfo(requestDate: 1_000)))
        try await configureTask.value
        XCTAssertEqual(client.state.accessLevel, .premium)
    }

    /// #11: a customer who launches shortly after the last confirmed period elapsed stays
    /// protected by the same seven-day grace while RevenueCat confirms the renewal.
    func testRecentlyLapsedConfirmedExpirationIsSeededWithinGraceOnRelaunch() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        let lapsed = Date(timeIntervalSince1970: context.clock.value - 60)
        let provider = identifiedProvider()
        provider.customerInfoResponses = [
            .success(activeInfo(requestDate: 1_000, expirationDate: lapsed)),
        ]
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        XCTAssertEqual(client.state.accessLevel, .premium)

        let relaunchedProvider = identifiedProvider()
        relaunchedProvider.suspendCustomerInfo = true
        let relaunched = makeClient(
            provider: relaunchedProvider,
            defaults: context.defaults,
            clock: context.clock
        )
        relaunched.setDesiredIdentity(.account("user-a"))
        let configureTask = Task { try await relaunched.configure(makeConfiguration()) }

        let didReachProvider = await waitUntil {
            !relaunchedProvider.customerInfoPolicies.isEmpty
        }
        XCTAssertTrue(didReachProvider)
        XCTAssertEqual(relaunched.state.accessLevel, .premiumInGracePeriod)
        XCTAssertEqual(relaunched.state.entitlement?.expirationDate, lapsed)

        relaunchedProvider.resumeCustomerInfo(
            with: .success(activeInfo(requestDate: 2_000, expirationDate: lapsed))
        )
        try await configureTask.value
    }

    /// #11 boundary: the launch seed expires at the end of the existing seven-day grace even
    /// when no network response has arrived to start the missing-entitlement clock.
    func testConfirmedExpirationBeyondGraceIsNotSeededOnRelaunch() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        let expired = Date(timeIntervalSince1970: context.clock.value - PremiumRevocationGrace.period)
        let provider = identifiedProvider()
        provider.customerInfoResponses = [
            .success(activeInfo(requestDate: 1_000, expirationDate: expired)),
        ]
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())

        let relaunchedProvider = identifiedProvider()
        relaunchedProvider.suspendCustomerInfo = true
        let relaunched = makeClient(
            provider: relaunchedProvider,
            defaults: context.defaults,
            clock: context.clock
        )
        relaunched.setDesiredIdentity(.account("user-a"))
        let configureTask = Task { try await relaunched.configure(makeConfiguration()) }

        let didReachProvider = await waitUntil {
            !relaunchedProvider.customerInfoPolicies.isEmpty
        }
        XCTAssertTrue(didReachProvider)
        XCTAssertEqual(relaunched.state.accessLevel, .unknown)

        relaunchedProvider.resumeCustomerInfo(
            with: .success(activeInfo(requestDate: 2_000, expirationDate: expired))
        )
        try await configureTask.value
    }

    /// #11: RevenueCatKit 2.0 did not persist the confirmed expiration. Backfill it from
    /// RevenueCat's own identity-scoped cache so the first launch after upgrading is protected.
    func testMigratedLegacyRecordBackfillsExpirationFromProviderCache() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.defaults.set(true, forKey: "hasSyncedPremiumAccess")
        context.defaults.set(true, forKey: "cachedPremiumAccess")

        let renewal = Date(timeIntervalSince1970: context.clock.value + 86_400)
        let provider = identifiedProvider()
        provider.cachedCustomerInfo = activeInfo(requestDate: 900, expirationDate: renewal)
        provider.suspendCustomerInfo = true
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        let configureTask = Task { try await client.configure(makeConfiguration()) }

        let didReachProvider = await waitUntil { !provider.customerInfoPolicies.isEmpty }
        XCTAssertTrue(didReachProvider)
        XCTAssertEqual(client.state.accessLevel, .premiumInGracePeriod)
        XCTAssertEqual(client.state.entitlement?.expirationDate, renewal)

        provider.resumeCustomerInfo(
            with: .success(activeInfo(requestDate: 1_000, expirationDate: renewal))
        )
        try await configureTask.value
        XCTAssertEqual(client.state.accessLevel, .premium)
    }

    /// #11 boundary: a migrated provenance flag without RevenueCat's cached entitlement carries
    /// no expiration evidence, so the Kit stays `unknown` until the network confirms it.
    func testMigratedLegacyRecordWithoutProviderCacheStaysUnknown() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }
        context.defaults.set(true, forKey: "hasSyncedPremiumAccess")
        context.defaults.set(true, forKey: "cachedPremiumAccess")

        let provider = identifiedProvider()
        provider.suspendCustomerInfo = true
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        let configureTask = Task { try await client.configure(makeConfiguration()) }

        let didReachProvider = await waitUntil { !provider.customerInfoPolicies.isEmpty }
        XCTAssertTrue(didReachProvider)
        XCTAssertEqual(client.state.accessLevel, .unknown)

        provider.resumeCustomerInfo(with: .success(activeInfo(requestDate: 1_000)))
        try await configureTask.value
        XCTAssertEqual(client.state.accessLevel, .premium)
    }

    /// #11 scope boundary: the launch seed only covers an in-flight first refresh. A real
    /// refresh failure must remain observable as `.failed` so hosts can run their documented
    /// network and foreground retry path.
    func testAlignedRelaunchReportsFirstFetchFailureForExplicitRetry() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        let renewal = Date(timeIntervalSince1970: context.clock.value + 86_400)
        let provider = identifiedProvider()
        provider.customerInfoResponses = [
            .success(activeInfo(requestDate: 1_000, expirationDate: renewal)),
        ]
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())

        let relaunchedProvider = identifiedProvider()
        relaunchedProvider.customerInfoResponses = [.failure(.network)]
        let relaunched = makeClient(
            provider: relaunchedProvider,
            defaults: context.defaults,
            clock: context.clock
        )
        relaunched.setDesiredIdentity(.account("user-a"))

        do {
            try await relaunched.configure(makeConfiguration())
            XCTFail("Expected the network refresh to fail")
        } catch {
            XCTAssertEqual(error as? RevenueCatClientError, .networkUnavailable)
        }

        XCTAssertEqual(relaunched.state.identityAlignment, .failed(.networkUnavailable))
        XCTAssertNil(relaunched.state.entitlement)
        XCTAssertEqual(relaunched.state.accessLevel, .unknown)
    }

    /// #11 boundary: the seed is identity scoped. Switching to another account must still
    /// tear the entitlement down instead of carrying the previous customer's provenance.
    func testAccountSwitchStillPublishesUnknownDespiteConfirmedPremiumProvenance() async throws {
        guard let context = makeContext() else { return XCTFail("Missing isolated defaults") }
        defer { context.defaults.removePersistentDomain(forName: context.suiteName) }

        let provider = identifiedProvider()
        provider.customerInfoResponses = [.success(activeInfo(requestDate: 1_000))]
        let client = makeClient(provider: provider, defaults: context.defaults, clock: context.clock)
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        XCTAssertEqual(client.state.accessLevel, .premium)

        provider.suspendLogIn = true
        client.setDesiredIdentity(.account("user-b"))
        let didStartLogIn = await waitUntil { provider.logInCallCount == 1 }
        XCTAssertTrue(didStartLogIn)
        XCTAssertEqual(client.state.accessLevel, .unknown)

        provider.resumeLogIn(
            appUserID: "user-b",
            result: .success(makeCustomerInfo(
                appUserID: "user-b",
                requestDate: Date(timeIntervalSince1970: 2_000)
            ))
        )
        let didAlign = await waitUntil {
            client.state.identityAlignment == .matching
                && client.state.currentAppUserID == .init("user-b")
        }
        XCTAssertTrue(didAlign)
        XCTAssertEqual(client.state.accessLevel, .free)
    }

    private func makeClient(
        provider: FakeRevenueCatProvider,
        defaults: UserDefaults,
        clock: Clock
    ) -> RevenueCatClient {
        RevenueCatClient(
            provider: provider,
            revocationGrace: PremiumRevocationGrace(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: clock.value) }
            )
        )
    }

    private func makeContext() -> (suiteName: String, defaults: UserDefaults, clock: Clock)? {
        let suiteName = "RevenueCatGraceIntegrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        return (suiteName, defaults, Clock())
    }

    private func identifiedProvider() -> FakeRevenueCatProvider {
        let provider = FakeRevenueCatProvider()
        seedPersistedAccount(provider)
        return provider
    }

    private func activeInfo(
        requestDate: TimeInterval,
        expirationDate: Date? = Date(timeIntervalSince1970: 2_000)
    ) -> ProviderCustomerInfo {
        makeCustomerInfo(
            appUserID: "user-a",
            requestDate: Date(timeIntervalSince1970: requestDate),
            entitlement: makeEntitlement(
                isActiveInCurrentEnvironment: true,
                expirationDate: expirationDate
            )
        )
    }
}
