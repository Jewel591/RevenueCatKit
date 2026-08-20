import Foundation
import XCTest
@testable import RevenueCatKit

@MainActor
final class PremiumRevocationGraceTests: XCTestCase {
    private func withDefaults(
        _ operation: (UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "RevenueCatKitTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try operation(defaults)
    }

    func testLegacyPremiumMigratesOnlyToInitiallyRestoredIdentityAndPreservesRollbackKeys() {
        withDefaults { defaults in
            defaults.set(true, forKey: "hasSyncedPremiumAccess")
            defaults.set(true, forKey: "cachedPremiumAccess")
            defaults.set(123, forKey: "premiumRevocationFirstSeenAt")
            let grace = PremiumRevocationGrace(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: 200) }
            )

            grace.prepareInitialRestoredIdentity("restored-user")
            grace.prepareInitialRestoredIdentity("later-user")

            XCTAssertNotNil(
                grace.resolveMissingEntitlement(
                    identity: "restored-user",
                    requestDate: .distantPast,
                    freshness: .cachePermitted
                )
            )
            XCTAssertNil(
                grace.resolveMissingEntitlement(
                    identity: "later-user",
                    requestDate: .distantPast,
                    freshness: .cachePermitted
                )
            )
            XCTAssertTrue(defaults.bool(forKey: "hasSyncedPremiumAccess"))
            XCTAssertTrue(defaults.bool(forKey: "cachedPremiumAccess"))
            XCTAssertEqual(defaults.double(forKey: "premiumRevocationFirstSeenAt"), 123)
        }
    }

    func testFirstMissingSnapshotAndRelaunchInsideSevenDaysKeepPremium() {
        withDefaults { defaults in
            var currentTime: TimeInterval = 1_000
            var grace = PremiumRevocationGrace(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: currentTime) }
            )
            grace.recordConfirmedPremium(identity: "user-a")

            let first = grace.resolveMissingEntitlement(
                identity: "user-a",
                requestDate: Date(timeIntervalSince1970: 10),
                freshness: .networkConfirmed
            )
            XCTAssertEqual(first?.accessLevel, .premiumInGracePeriod)
            XCTAssertEqual(first?.billingCondition, .entitlementTemporarilyMissing)

            currentTime += PremiumRevocationGrace.period - 1
            grace = PremiumRevocationGrace(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: currentTime) }
            )
            XCTAssertEqual(
                grace.resolveMissingEntitlement(
                    identity: "user-a",
                    requestDate: Date(timeIntervalSince1970: 11),
                    freshness: .cachePermitted
                )?.accessLevel,
                .premiumInGracePeriod
            )
        }
    }

    func testGraceExpiresAndDoesNotRestartWithoutNewPremiumConfirmation() {
        withDefaults { defaults in
            var currentTime: TimeInterval = 1_000
            let grace = PremiumRevocationGrace(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: currentTime) }
            )
            grace.recordConfirmedPremium(identity: "user-a")
            XCTAssertNotNil(
                grace.resolveMissingEntitlement(
                    identity: "user-a",
                    requestDate: .distantPast,
                    freshness: .cachePermitted
                )
            )

            currentTime += PremiumRevocationGrace.period
            XCTAssertNil(
                grace.resolveMissingEntitlement(
                    identity: "user-a",
                    requestDate: .distantPast,
                    freshness: .networkConfirmed
                )
            )
            XCTAssertNil(
                grace.resolveMissingEntitlement(
                    identity: "user-a",
                    requestDate: .distantPast,
                    freshness: .networkConfirmed
                )
            )
        }
    }

    func testActiveRecoveryClearsOldClockAndStartsFreshWindowOnLaterDisappearance() {
        withDefaults { defaults in
            var currentTime: TimeInterval = 1_000
            let grace = PremiumRevocationGrace(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: currentTime) }
            )
            grace.recordConfirmedPremium(identity: "user-a")
            XCTAssertNotNil(
                grace.resolveMissingEntitlement(
                    identity: "user-a",
                    requestDate: .distantPast,
                    freshness: .cachePermitted
                )
            )

            currentTime += PremiumRevocationGrace.period - 1
            grace.recordConfirmedPremium(identity: "user-a")
            currentTime += 2

            XCTAssertNotNil(
                grace.resolveMissingEntitlement(
                    identity: "user-a",
                    requestDate: .distantPast,
                    freshness: .networkConfirmed
                )
            )
        }
    }

    func testConfirmedPremiumNeverLeaksAcrossAccountSwitch() {
        withDefaults { defaults in
            let grace = PremiumRevocationGrace(defaults: defaults)
            grace.recordConfirmedPremium(identity: "user-a")

            XCTAssertNotNil(
                grace.resolveMissingEntitlement(
                    identity: "user-a",
                    requestDate: .distantPast,
                    freshness: .cachePermitted
                )
            )
            XCTAssertNil(
                grace.resolveMissingEntitlement(
                    identity: "user-b",
                    requestDate: .distantPast,
                    freshness: .cachePermitted
                )
            )
        }
    }
}
