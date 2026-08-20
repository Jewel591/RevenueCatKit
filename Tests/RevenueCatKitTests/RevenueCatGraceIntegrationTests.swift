import Foundation
import XCTest
@testable import RevenueCatKit

@MainActor
final class RevenueCatGraceIntegrationTests: XCTestCase {
    private final class Clock {
        var value: TimeInterval = 10_000
    }

    func testConfigureMigratesLegacyAnonymousGraceThroughValidatedAliasButNotAccountSwitch() async throws {
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

    private func activeInfo(requestDate: TimeInterval) -> ProviderCustomerInfo {
        makeCustomerInfo(
            appUserID: "user-a",
            requestDate: Date(timeIntervalSince1970: requestDate),
            entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)
        )
    }
}
