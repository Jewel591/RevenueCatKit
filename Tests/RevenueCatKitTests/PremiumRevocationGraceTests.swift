import Foundation
import Testing
@testable import RevenueCatKit

struct PremiumRevocationGraceTests {
    private let now: TimeInterval = 1_700_000_000

    @Test func neverSyncedUserIsNotProtected() {
        let outcome = PremiumRevocationGrace.outcome(
            isEntitlementActive: false,
            hasSyncedBefore: false,
            cachedPremiumAccess: false,
            firstSeenAt: 0,
            now: now
        )
        #expect(outcome.shouldApplyServerStatus)
        #expect(outcome.storedFirstSeenAt == 0)
    }

    @Test func previouslyFreeUserIsNotProtected() {
        let outcome = PremiumRevocationGrace.outcome(
            isEntitlementActive: false,
            hasSyncedBefore: true,
            cachedPremiumAccess: false,
            firstSeenAt: 0,
            now: now
        )
        #expect(outcome.shouldApplyServerStatus)
        #expect(outcome.storedFirstSeenAt == 0)
    }

    @Test func firstEmptySnapshotEntersGraceWithoutApplyingServerStatus() {
        let outcome = PremiumRevocationGrace.outcome(
            isEntitlementActive: false,
            hasSyncedBefore: true,
            cachedPremiumAccess: true,
            firstSeenAt: 0,
            now: now
        )
        #expect(!outcome.shouldApplyServerStatus)
        #expect(outcome.storedFirstSeenAt == now)
    }

    @Test func graceKeepsPremiumAndPreservesFirstSeenAt() {
        let firstSeen = now - (3 * 24 * 60 * 60)
        let outcome = PremiumRevocationGrace.outcome(
            isEntitlementActive: false,
            hasSyncedBefore: true,
            cachedPremiumAccess: true,
            firstSeenAt: firstSeen,
            now: now
        )
        #expect(!outcome.shouldApplyServerStatus)
        #expect(outcome.storedFirstSeenAt == firstSeen)
    }

    @Test func graceExpiryAllowsDowngradeAndClearsClock() {
        let firstSeen = now - PremiumRevocationGrace.period
        let outcome = PremiumRevocationGrace.outcome(
            isEntitlementActive: false,
            hasSyncedBefore: true,
            cachedPremiumAccess: true,
            firstSeenAt: firstSeen,
            now: now
        )
        #expect(outcome.shouldApplyServerStatus)
        #expect(outcome.storedFirstSeenAt == 0)
    }

    @Test func activeEntitlementClearsRevocationClock() {
        let outcome = PremiumRevocationGrace.outcome(
            isEntitlementActive: true,
            hasSyncedBefore: true,
            cachedPremiumAccess: true,
            firstSeenAt: now - 60,
            now: now
        )
        #expect(outcome.shouldApplyServerStatus)
        #expect(outcome.storedFirstSeenAt == 0)
    }

    @Test func onDeviceKeyMatchesOlderCodeCatBuilds() {
        #expect(PremiumRevocationGrace.firstSeenAtKey == "premiumRevocationFirstSeenAt")
    }
}
