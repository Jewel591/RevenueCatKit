import Foundation

/// 7-day hold when a previously confirmed premium entitlement disappears.
///
/// CodeCat shipped this after a real lifetime-purchase incident: StoreKit /
/// RevenueCat can briefly return an empty entitlement table. Writing that
/// snapshot into `cachedPremiumAccess` both drops the user out of paid
/// features immediately and poisons rollback — the older build's grace
/// required `hasSyncedBefore && cachedPremiumAccess`.
///
/// The UserDefaults key name is part of the on-device contract with those
/// older CodeCat builds. Do not rename it.
enum PremiumRevocationGrace {
    static let period: TimeInterval = 7 * 24 * 60 * 60
    static let firstSeenAtKey = "premiumRevocationFirstSeenAt"

    struct Outcome: Equatable {
        /// `true` means apply the server snapshot (active or not).
        /// `false` means keep the cached premium membership and skip cache writes.
        let shouldApplyServerStatus: Bool
        /// Persist this as `premiumRevocationFirstSeenAt`. `0` clears the clock.
        let storedFirstSeenAt: TimeInterval
    }

    static func outcome(
        isEntitlementActive: Bool,
        hasSyncedBefore: Bool,
        cachedPremiumAccess: Bool,
        firstSeenAt: TimeInterval,
        now: TimeInterval
    ) -> Outcome {
        if isEntitlementActive {
            return Outcome(shouldApplyServerStatus: true, storedFirstSeenAt: 0)
        }

        guard hasSyncedBefore, cachedPremiumAccess else {
            return Outcome(shouldApplyServerStatus: true, storedFirstSeenAt: 0)
        }

        if firstSeenAt == 0 {
            return Outcome(shouldApplyServerStatus: false, storedFirstSeenAt: now)
        }

        if now - firstSeenAt < period {
            return Outcome(shouldApplyServerStatus: false, storedFirstSeenAt: firstSeenAt)
        }

        return Outcome(shouldApplyServerStatus: true, storedFirstSeenAt: 0)
    }
}
