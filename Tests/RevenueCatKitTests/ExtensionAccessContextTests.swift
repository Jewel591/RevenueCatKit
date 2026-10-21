import Foundation
import Testing
@testable import RevenueCatKit

@MainActor private final class ExtensionTestClock {
    var date = Date(timeIntervalSince1970: 1_000)
}

@MainActor @Suite("Portable extension access evidence")
struct ExtensionAccessContextTests {
    private func withClient(
        entitlement: ProviderEntitlement?,
        configuration: RevenueCatClient.Configuration = makeConfiguration(),
        owner: String = "user-a",
        anonymous: Bool = false,
        body: (RevenueCatClient, FakeRevenueCatProvider, ExtensionTestClock) async throws -> Void
    ) async throws {
        let suite = "RevenueCatKit.ExtensionAccessTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ExtensionTestClock(), provider = FakeRevenueCatProvider()
        let client = RevenueCatClient(provider: provider,
            revocationGrace: .init(defaults: defaults, now: { clock.date }))
        #expect(client.extensionAccessContext() == nil)
        provider.appUserID = owner; provider.isAnonymous = anonymous
        provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: owner, entitlement: entitlement))]
        client.setDesiredIdentity(anonymous ? .anonymous : .account(.init(owner)))
        try await client.configure(configuration)
        try await body(client, provider, clock)
    }

    private func withFreshClient(clock: ExtensionTestClock,
        body: (RevenueCatClient, FakeRevenueCatProvider) async throws -> Void) async throws {
        let suite = "RevenueCatKit.ExtensionReaderTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = FakeRevenueCatProvider()
        let client = RevenueCatClient(provider: provider, revocationGrace: .init(defaults: defaults, now: { clock.date }))
        try await body(client, provider)
    }

    @Test("#20: Re-exporting and Codable transport do not renew free evidence")
    func freeEvidenceExpires() async throws {
        try await withClient(entitlement: nil) { client, _, clock in
            let context = try #require(client.extensionAccessContext())
            let roundTrip = try JSONDecoder().decode(ExtensionAccessContext.self, from: JSONEncoder().encode(context))
            #expect(roundTrip == context)
            #expect(roundTrip.accessLevel(at: clock.date, for: makeConfiguration()) == .free)
            clock.date = Date(timeIntervalSince1970: 1_299)
            #expect(client.extensionAccessContext() == context)
            #expect(context.accessLevel(at: clock.date, for: makeConfiguration()) == .free)
            clock.date = Date(timeIntervalSince1970: 1_300)
            #expect(context.accessLevel(at: clock.date, for: makeConfiguration()) == .unknown)
            #expect(context.accessLevel(at: Date(timeIntervalSince1970: 1_001), for: .init(publicSDKKey: "another-public-key", premiumEntitlementID: "premium", identityPolicy: .anonymousAndIdentified)) == .unknown)
        }
    }

    @Test("#20: A paid decision expires at the earlier product or freshness boundary", arguments: [Date?.none, Date(timeIntervalSince1970: 1_100)])
    func paidEvidenceExpires(expiration: Date?) async throws {
        try await withClient(entitlement: makeEntitlement(isActiveInCurrentEnvironment: true, expirationDate: expiration)) { client, _, _ in
            let context = try #require(client.extensionAccessContext())
            let end = expiration ?? Date(timeIntervalSince1970: 1_300)
            #expect(context.accessLevel(at: end.addingTimeInterval(-1), for: makeConfiguration()) == .premium)
            #expect(context.accessLevel(at: end, for: makeConfiguration()) == .unknown)
        }
    }

    @Test("#20: Provider-confirmed billing grace survives an earlier product expiration")
    func activeBillingGrace() async throws {
        let entitlement = makeEntitlement(isActiveInCurrentEnvironment: true,
            expirationDate: Date(timeIntervalSince1970: 900), billingIssueDetectedAt: Date(timeIntervalSince1970: 800))
        try await withClient(entitlement: entitlement) { client, _, clock in
            let context = try #require(client.extensionAccessContext())
            #expect(context.accessLevel(at: clock.date, for: makeConfiguration()) == .premiumInGracePeriod)
            #expect(context.accessLevel(at: Date(timeIntervalSince1970: 1_300), for: makeConfiguration()) == .unknown)
        }
    }

    @Test("#20: Missing-entitlement grace uses its existing clock and cannot outlive that deadline")
    func missingEntitlementGraceDeadline() async throws {
        try await withClient(entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)) { client, provider, clock in
            clock.date = Date(timeIntervalSince1970: 2_100)
            provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
            _ = try await client.forceRefresh()
            let graceEnd = clock.date.addingTimeInterval(PremiumRevocationGrace.period)
            clock.date = graceEnd.addingTimeInterval(-30)
            provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
            _ = try await client.forceRefresh()
            let context = try #require(client.extensionAccessContext())
            #expect(context.accessLevel(at: graceEnd.addingTimeInterval(-1), for: makeConfiguration()) == .premiumInGracePeriod)
            #expect(context.accessLevel(at: graceEnd, for: makeConfiguration()) == .unknown)
            #expect(client.extensionAccessContext()?.validUntil == context.validUntil)
        }
    }

    @Test("#20: An extension refreshes the original anonymous owner without login, logout or a new purchase identity")
    func anonymousExtensionRefresh() async throws {
        let configuration = makeConfiguration(identityPolicy: .anonymousOnly)
        let owner = "$RCAnonymousID:extension-source"
        try await withClient(entitlement: makeEntitlement(isActiveInCurrentEnvironment: true, expirationDate: nil),
            configuration: configuration, owner: owner, anonymous: true) { main, _, clock in
            let context = try #require(main.extensionAccessContext())
            clock.date = Date(timeIntervalSince1970: 1_400)
            #expect(context.accessLevel(at: clock.date, for: configuration) == .unknown)
            try await withFreshClient(clock: clock) { reader, provider in
                provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: owner, requestDate: clock.date,
                    entitlement: makeEntitlement(isActiveInCurrentEnvironment: true, expirationDate: nil)))]
                try await reader.configureForExtension(configuration, restoring: context)
                #expect(provider.configuredAppUserID == owner && provider.isAnonymous == true)
                #expect(provider.logInCallCount == 0 && provider.logOutCallCount == 0)
                #expect(provider.customerInfoPolicies == [.fetchCurrent])
                #expect(reader.state.accessLevel == .premium && reader.state.entitlement?.freshness == .networkConfirmed)
                let refreshed = try #require(reader.extensionAccessContext())
                #expect(refreshed.accessLevel(at: clock.date, for: configuration) == .premium)
            }
        }
    }

    @Test("#20: Refresh failures preserve unknown and configuration mismatches never configure the provider")
    func extensionFailureAndBinding() async throws {
        try await withClient(entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)) { main, _, clock in
            let context = try #require(main.extensionAccessContext())
            try await withFreshClient(clock: clock) { reader, provider in
                let foreign = RevenueCatClient.Configuration(publicSDKKey: "foreign", premiumEntitlementID: "premium", identityPolicy: .anonymousAndIdentified)
                await #expect(throws: RevenueCatClientError.configurationConflict) {
                    try await reader.configureForExtension(foreign, restoring: context)
                }
                #expect(provider.configureCallCount == 0 && reader.state.accessLevel == .unknown)
                provider.customerInfoResponses = [.failure(.network(.init(category: .offline)))]
                await #expect(throws: RevenueCatClientError.networkUnavailable(.init(category: .offline))) {
                    try await reader.configureForExtension(makeConfiguration(), restoring: context)
                }
                #expect(reader.state.accessLevel == .unknown)
                provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "another-owner", requestDate: clock.date))]
                await #expect(throws: RevenueCatClientError.identityChangedDuringOperation) {
                    try await reader.configureForExtension(makeConfiguration(), restoring: context)
                }
                #expect(reader.state.accessLevel == .unknown && provider.logInCallCount == 0 && provider.logOutCallCount == 0)
            }
        }
    }

    @Test("#20: Extension grace returns to the main app without restarting its revocation clock")
    func graceReturnsToMain() async throws {
        try await withClient(entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)) { main, mainProvider, clock in
            let context = try #require(main.extensionAccessContext())
            clock.date = Date(timeIntervalSince1970: 2_100)
            try await withFreshClient(clock: clock) { reader, provider in
                provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
                try await reader.configureForExtension(makeConfiguration(), restoring: context)
                let firstMissing = try #require(reader.extensionAccessContext())
                #expect(reader.state.accessLevel == .premiumInGracePeriod)
                let end = clock.date.addingTimeInterval(PremiumRevocationGrace.period)
                clock.date = end.addingTimeInterval(-15)
                try await withFreshClient(clock: clock) { coldMain, coldProvider in
                    coldProvider.appUserID = "user-a"; coldProvider.isAnonymous = false
                    coldProvider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
                    coldMain.setDesiredIdentity(.account("user-a"))
                    try await coldMain.configure(makeConfiguration(), restoringAccessFrom: firstMissing)
                    #expect(coldProvider.configuredAppUserID == nil)
                    #expect(coldProvider.logInCallCount == 0 && coldProvider.logOutCallCount == 0)
                    #expect(coldMain.extensionAccessContext()?.validUntil == end)
                }
                mainProvider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
                _ = try await main.forceRefresh(restoringAccessFrom: firstMissing)
                let returned = try #require(main.extensionAccessContext())
                #expect(returned.validUntil == end)
                #expect(returned.accessLevel(at: clock.date, for: makeConfiguration()) == .premiumInGracePeriod)
                provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
                try await reader.configureForExtension(makeConfiguration(), restoring: returned)
                #expect(reader.extensionAccessContext()?.validUntil == end)
                clock.date = end
                provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
                try await reader.configureForExtension(makeConfiguration(), restoring: returned)
                #expect(reader.state.accessLevel == .free)
            }
        }
    }

    @Test("#20: Older portable missing evidence cannot undo a newer confirmed response", arguments: [false, true])
    func newerConfirmationOwnsTheClock(active: Bool) async throws {
        try await withClient(entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)) { main, provider, clock in
            clock.date = Date(timeIntervalSince1970: 2_100)
            provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
            _ = try await main.forceRefresh()
            let oldMissing = try #require(main.extensionAccessContext())
            clock.date = Date(timeIntervalSince1970: 3_000)
            provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date,
                entitlement: makeEntitlement(isActiveInCurrentEnvironment: active, expirationDate: nil)))]
            _ = try await main.forceRefresh()
            clock.date = Date(timeIntervalSince1970: 4_000)
            provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a", requestDate: clock.date))]
            _ = try await main.forceRefresh(restoringAccessFrom: oldMissing)
            if active {
                #expect(main.extensionAccessContext()?.grace.firstSeenAt == 4_000)
                #expect(main.state.accessLevel == .premiumInGracePeriod)
            } else {
                #expect(main.state.accessLevel == .free)
                #expect(main.extensionAccessContext()?.grace.hasConfirmedPremium == false)
            }
        }
    }

    @Test("#20: Main-app restoration never imports another owner's premium provenance")
    func mainRestoresOnlyItsOwner() async throws {
        try await withClient(entitlement: makeEntitlement(isActiveInCurrentEnvironment: true)) { main, _, clock in
            let context = try #require(main.extensionAccessContext())
            try await withFreshClient(clock: clock) { other, provider in
                provider.appUserID = "user-b"; provider.isAnonymous = false
                provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-b", requestDate: clock.date))]
                other.setDesiredIdentity(.account("user-b"))
                try await other.configure(makeConfiguration(), restoringAccessFrom: context)
                #expect(other.state.currentAppUserID?.rawValue == "user-b" && other.state.accessLevel == .free)
                #expect(provider.configuredAppUserID == nil && provider.logInCallCount == 0)
            }
        }
    }
}
