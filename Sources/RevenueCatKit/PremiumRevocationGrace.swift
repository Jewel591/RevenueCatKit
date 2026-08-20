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

        private static func encoded(_ identity: String) -> String {
            Data(identity.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }
    }

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

        return .init(
            accessLevel: .premiumInGracePeriod,
            billingCondition: .entitlementTemporarilyMissing,
            productID: nil,
            expirationDate: nil,
            willRenew: false,
            store: .unknown,
            isSandbox: false,
            requestDate: requestDate,
            freshness: freshness
        )
    }

    func recordConfirmedPremium(identity: String) {
        defaults.set(true, forKey: Key.hasConfirmedPremium(identity))
        defaults.set(0, forKey: Key.firstSeenAt(identity))
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
    }

    private func clear(identity: String) {
        defaults.set(false, forKey: Key.hasConfirmedPremium(identity))
        defaults.set(0, forKey: Key.firstSeenAt(identity))
    }
}
