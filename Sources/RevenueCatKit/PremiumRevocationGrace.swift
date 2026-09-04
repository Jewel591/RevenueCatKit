import Foundation

/// Identity-scoped protection for a previously confirmed premium entitlement that temporarily
/// disappears from RevenueCat's entitlement table.
@MainActor
final class PremiumRevocationGrace {
    static let period: TimeInterval = 7 * 24 * 60 * 60

    private enum LegacyKey {
        static let hasSynced = "hasSyncedPremiumAccess"
        static let cachedPremium = "cachedPremiumAccess"
        static let firstSeenAt = "premiumRevocationFirstSeenAt"
    }

    private enum Key {
        static let migrationIdentity = "RevenueCatKit.revocationGrace.v2.migrationIdentity"

        static func hasConfirmedPremium(_ identity: String) -> String {
            "RevenueCatKit.revocationGrace.v2.\(encoded(identity)).hasConfirmedPremium"
        }

        static func firstSeenAt(_ identity: String) -> String {
            "RevenueCatKit.revocationGrace.v2.\(encoded(identity)).firstSeenAt"
        }

        /// Expiration of the last confirmed premium entitlement: absent when it was never
        /// recorded (a migrated legacy record), `lifetimeExpiration` when the entitlement had no
        /// expiration date, otherwise the confirmed timestamp.
        static func confirmedExpiresAt(_ identity: String) -> String {
            "RevenueCatKit.revocationGrace.v2.\(encoded(identity)).confirmedExpiresAt"
        }

        private static func encoded(_ identity: String) -> String {
            Data(identity.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    /// Sentinel for a confirmed entitlement that carries no expiration date.
    private static let lifetimeExpiration: TimeInterval = 0

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Migrates the legacy global cache exactly once, onto the RevenueCat identity restored by
    /// the SDK before any host-requested login. Legacy keys are deliberately left untouched so a
    /// rollback to a ViewModel-era build preserves its protection.
    func prepareInitialRestoredIdentity(_ identity: String) {
        guard defaults.string(forKey: Key.migrationIdentity) == nil else { return }
        defaults.set(identity, forKey: Key.migrationIdentity)

        guard defaults.bool(forKey: LegacyKey.hasSynced) else { return }
        defaults.set(
            defaults.bool(forKey: LegacyKey.cachedPremium),
            forKey: Key.hasConfirmedPremium(identity)
        )
        if defaults.bool(forKey: LegacyKey.cachedPremium) {
            defaults.set(
                defaults.double(forKey: LegacyKey.firstSeenAt),
                forKey: Key.firstSeenAt(identity)
            )
        }
    }

    /// Locally confirmed premium provenance, read without starting or advancing the revocation
    /// clock. Used to render a customer whose premium was already confirmed on this device while
    /// the first entitlement fetch of a launch is still in flight, instead of publishing
    /// `unknown` and showing a paying customer the free presentation for the whole round trip.
    func confirmedPremiumProvenance(
        identity: String,
        requestDate: Date,
        freshness: SnapshotFreshness
    ) -> EntitlementSnapshot? {
        guard defaults.bool(forKey: Key.hasConfirmedPremium(identity)) else { return nil }

        let storedFirstSeenAt = defaults.double(forKey: Key.firstSeenAt(identity))
        guard storedFirstSeenAt == 0
            || now().timeIntervalSince1970 - storedFirstSeenAt < Self.period
        else {
            return nil
        }

        // Without a recorded expiration this can only report "premium, no expiration date",
        // which reads as a lifetime purchase to every consumer. Rather than assert that about a
        // subscriber, stay silent until the next confirmation records the real value.
        guard let confirmedExpiration = confirmedExpiration(identity: identity) else { return nil }
        if storedFirstSeenAt == 0,
           let expirationDate = confirmedExpiration,
           now().timeIntervalSince(expirationDate) >= Self.period {
            return nil
        }

        return protectedSnapshot(
            expirationDate: confirmedExpiration,
            requestDate: requestDate,
            freshness: freshness
        )
    }

    /// Double-optional on purpose: `nil` means no expiration was ever recorded, `.some(nil)` means
    /// a confirmed entitlement that carries no expiration date.
    private func confirmedExpiration(identity: String) -> Date?? {
        guard let stored = defaults.object(forKey: Key.confirmedExpiresAt(identity)) as? Double
        else {
            return nil
        }
        return stored == Self.lifetimeExpiration ? .some(nil) : Date(timeIntervalSince1970: stored)
    }

    func resolveMissingEntitlement(
        identity: String,
        requestDate: Date,
        freshness: SnapshotFreshness
    ) -> EntitlementSnapshot? {
        guard defaults.bool(forKey: Key.hasConfirmedPremium(identity)) else { return nil }

        let currentTime = now().timeIntervalSince1970
        let storedFirstSeenAt = defaults.double(forKey: Key.firstSeenAt(identity))
        let firstSeenAt: TimeInterval
        if storedFirstSeenAt == 0 {
            firstSeenAt = currentTime
            defaults.set(firstSeenAt, forKey: Key.firstSeenAt(identity))
        } else {
            firstSeenAt = storedFirstSeenAt
        }

        guard currentTime - firstSeenAt < Self.period else {
            clear(identity: identity)
            return nil
        }

        return protectedSnapshot(
            expirationDate: confirmedExpiration(identity: identity) ?? nil,
            requestDate: requestDate,
            freshness: freshness
        )
    }

    private func protectedSnapshot(
        expirationDate: Date?,
        requestDate: Date,
        freshness: SnapshotFreshness
    ) -> EntitlementSnapshot {
        .init(
            accessLevel: .premiumInGracePeriod,
            billingCondition: .entitlementTemporarilyMissing,
            productID: nil,
            expirationDate: expirationDate,
            willRenew: false,
            store: .unknown,
            isSandbox: false,
            requestDate: requestDate,
            freshness: freshness
        )
    }

    func recordConfirmedPremium(identity: String, expirationDate: Date?) {
        defaults.set(true, forKey: Key.hasConfirmedPremium(identity))
        defaults.set(0, forKey: Key.firstSeenAt(identity))
        defaults.set(
            expirationDate?.timeIntervalSince1970 ?? Self.lifetimeExpiration,
            forKey: Key.confirmedExpiresAt(identity)
        )
    }

    /// Backfills the expiration omitted by RevenueCatKit 2.0's provenance record from the
    /// RevenueCat SDK's own identity-scoped CustomerInfo cache. It deliberately leaves an
    /// existing revocation clock untouched.
    func backfillConfirmedExpiration(identity: String, expirationDate: Date?) {
        guard defaults.bool(forKey: Key.hasConfirmedPremium(identity)),
              defaults.object(forKey: Key.confirmedExpiresAt(identity)) == nil else { return }
        defaults.set(
            expirationDate?.timeIntervalSince1970 ?? Self.lifetimeExpiration,
            forKey: Key.confirmedExpiresAt(identity)
        )
    }

    func recordConfirmedFree(identity: String) {
        clear(identity: identity)
    }

    /// RevenueCat aliases an anonymous user into the first identified account during `logIn`.
    /// Copy only that anonymous provenance; identified account switches and logout must not carry it.
    func transferAnonymousProvenance(from sourceIdentity: String, to targetIdentity: String) {
        guard sourceIdentity != targetIdentity,
              defaults.bool(forKey: Key.hasConfirmedPremium(sourceIdentity)) else { return }
        defaults.set(true, forKey: Key.hasConfirmedPremium(targetIdentity))
        defaults.set(
            defaults.double(forKey: Key.firstSeenAt(sourceIdentity)),
            forKey: Key.firstSeenAt(targetIdentity)
        )
        if let sourceExpiration = defaults.object(
            forKey: Key.confirmedExpiresAt(sourceIdentity)
        ) as? Double {
            defaults.set(sourceExpiration, forKey: Key.confirmedExpiresAt(targetIdentity))
        }
    }

    private func clear(identity: String) {
        defaults.set(false, forKey: Key.hasConfirmedPremium(identity))
        defaults.set(0, forKey: Key.firstSeenAt(identity))
        defaults.removeObject(forKey: Key.confirmedExpiresAt(identity))
    }
}
