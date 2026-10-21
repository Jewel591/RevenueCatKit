import CryptoKit
import Foundation

/// An opaque, app-group-portable context issued by the configured client.
/// It contains identity-scoped cache evidence, not a transferable purchase.
public struct ExtensionAccessContext: Codable, Sendable, Equatable {
    enum StoredAccess: String, Codable, Sendable {
        case unknown, free, premium, premiumInGracePeriod
        init(_ access: AccessLevel) {
            switch access {
            case .unknown: self = .unknown
            case .free: self = .free
            case .premium: self = .premium
            case .premiumInGracePeriod: self = .premiumInGracePeriod
            }
        }
        var value: AccessLevel {
            switch self {
            case .unknown: .unknown
            case .free: .free
            case .premium: .premium
            case .premiumInGracePeriod: .premiumInGracePeriod
            }
        }
    }

    let configurationFingerprint: String
    let appUserID: String
    let isAnonymous: Bool
    let access: StoredAccess
    let requestDate: Date
    let validUntil: Date
    let grace: PremiumRevocationGrace.PortableState

    /// Expired evidence is unknown, never confirmed free. Hosts must refresh
    /// through the Kit before granting capacity beyond their included allowance.
    public func accessLevel(at date: Date, for configuration: RevenueCatClient.Configuration) -> AccessLevel {
        guard configurationFingerprint == Self.fingerprint(configuration), date < validUntil else { return .unknown }
        return access.value
    }

    static func fingerprint(_ configuration: RevenueCatClient.Configuration) -> String {
        let policy: String
        switch configuration.identityPolicy {
        case .anonymousOnly: policy = "anonymousOnly"
        case .identifiedOnly: policy = "identifiedOnly"
        case .anonymousAndIdentified: policy = "anonymousAndIdentified"
        }
        let value = [configuration.publicSDKKey.rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
            configuration.premiumEntitlementID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines), policy].joined(separator: "\0")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func deadline(for snapshot: EntitlementSnapshot, graceDeadline: Date?) -> Date {
        // The SDK foreground cache is stale after five minutes. Re-exporting
        // the same snapshot cannot move this deadline because it uses requestDate.
        let freshnessDeadline = snapshot.requestDate.addingTimeInterval(5 * 60)
        if snapshot.billingCondition == .entitlementTemporarilyMissing {
            return min(freshnessDeadline, graceDeadline ?? .distantPast)
        }
        if snapshot.accessLevel == .premium, let expiration = snapshot.expirationDate {
            return min(freshnessDeadline, expiration)
        }
        // A billing issue while the provider still reports active may extend
        // beyond the product expiration. Preserve that explicit grant.
        return freshnessDeadline
    }
}
