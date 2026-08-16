import Foundation

extension RevenueCatClient {
    /// Immutable, App-owned RevenueCat facts.
    ///
    /// Connectivity, logging and distribution-channel detection intentionally stay in
    /// `RevenueCatKit` so every App receives the same company defaults.
    public struct Configuration: Sendable, Equatable {
        public let publicSDKKey: PublicSDKKey
        public let premiumEntitlementID: EntitlementID
        public let identityPolicy: IdentityPolicy

        public init(
            publicSDKKey: PublicSDKKey,
            premiumEntitlementID: EntitlementID,
            identityPolicy: IdentityPolicy
        ) {
            self.publicSDKKey = publicSDKKey
            self.premiumEntitlementID = premiumEntitlementID
            self.identityPolicy = identityPolicy
        }
    }

    /// The public, App-specific key embedded in an Apple client binary.
    public struct PublicSDKKey: RawRepresentable, Hashable, Sendable,
        ExpressibleByStringLiteral
    {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            rawValue = value
        }
    }

    /// A RevenueCat Entitlement identifier mapped to the company's premium access level.
    public struct EntitlementID: RawRepresentable, Hashable, Sendable,
        ExpressibleByStringLiteral
    {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            rawValue = value
        }
    }

    /// A company account identifier supplied by the host App.
    public struct AppUserID: RawRepresentable, Hashable, Sendable,
        ExpressibleByStringLiteral
    {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            rawValue = value
        }
    }

    /// Defines which identity declarations are legal for this App.
    public enum IdentityPolicy: Sendable, Equatable {
        case anonymousOnly
        case identifiedOnly
        case anonymousAndIdentified
    }

    /// The latest account fact declared by the host App.
    ///
    /// Setting this value never configures the RevenueCat SDK by itself. A value declared before
    /// `configure(_:)` is applied with `logIn` after the SDK restores any persisted user.
    public enum DesiredIdentity: Sendable, Equatable {
        case anonymous
        case account(AppUserID)
    }
}

public enum InvalidConfigurationReason: Sendable, Equatable {
    case emptyPublicSDKKey
    case emptyPremiumEntitlementID
    case missingDesiredAccountIdentity
    case accountIdentityNotAllowed
    case emptyAppUserID
    case appUserIDTooLong
    case blockedAppUserID
    case appUserIDContainsInvalidCharacters
    case emptyPlacementID
}

public enum RevenueCatClientError: Error, Sendable, Equatable {
    case invalidConfiguration(InvalidConfigurationReason)
    case notConfigured
    case alreadyConfiguredExternally
    case configurationConflict
    case anonymousIdentityUnavailable
    case operationInProgress
    case optionUnavailable
    case networkUnavailable
    case storeUnavailable
    case purchaseStatusUnknown
    case invalidPurchase
    case identityOperationNotAllowed
    case identityChangedDuringOperation
    case unknown
}

enum RevenueCatLogLevel: Sendable, Equatable {
    case verbose
    case debug
    case info
    case warning
    case error
}

struct RevenueCatRuntimeOptions: Sendable, Equatable {
    let proxyURL: URL?
    let logLevel: RevenueCatLogLevel

    static var companyDefault: Self {
        #if DEBUG
            .init(
                proxyURL: URL(string: "https://api.rc-backup.com/"),
                logLevel: .debug
            )
        #else
            .init(
                proxyURL: URL(string: "https://api.rc-backup.com/"),
                logLevel: .warning
            )
        #endif
    }
}

extension RevenueCatClient.Configuration {
    func validated(
        desiredIdentity: RevenueCatClient.DesiredIdentity?
    ) throws -> (configuration: Self, desiredIdentity: RevenueCatClient.DesiredIdentity?) {
        let publicSDKKey = publicSDKKey.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !publicSDKKey.isEmpty else {
            throw RevenueCatClientError.invalidConfiguration(.emptyPublicSDKKey)
        }

        let premiumEntitlementID = premiumEntitlementID.rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !premiumEntitlementID.isEmpty else {
            throw RevenueCatClientError.invalidConfiguration(.emptyPremiumEntitlementID)
        }

        let validatedDesiredIdentity: RevenueCatClient.DesiredIdentity?
        switch desiredIdentity {
        case .account(let appUserID):
            validatedDesiredIdentity = .account(
                try RevenueCatClient.AppUserID.validated(appUserID)
            )
        case .anonymous:
            validatedDesiredIdentity = .anonymous
        case nil:
            validatedDesiredIdentity = nil
        }

        switch identityPolicy {
        case .anonymousOnly:
            if case .some(.account) = validatedDesiredIdentity {
                throw RevenueCatClientError.invalidConfiguration(.accountIdentityNotAllowed)
            }
        case .identifiedOnly:
            guard case .account = validatedDesiredIdentity else {
                throw RevenueCatClientError.invalidConfiguration(.missingDesiredAccountIdentity)
            }
        case .anonymousAndIdentified:
            break
        }

        return (
            .init(
                publicSDKKey: .init(publicSDKKey),
                premiumEntitlementID: .init(premiumEntitlementID),
                identityPolicy: identityPolicy
            ),
            validatedDesiredIdentity
        )
    }
}

extension RevenueCatClient.AppUserID {
    static func validated(_ appUserID: Self) throws -> Self {
        let value = appUserID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw RevenueCatClientError.invalidConfiguration(.emptyAppUserID)
        }
        guard value.count <= 100 else {
            throw RevenueCatClientError.invalidConfiguration(.appUserIDTooLong)
        }

        let lowercaseValue = value.lowercased()
        if blockedValues.contains(lowercaseValue)
            || lowercaseValue.hasPrefix("$rcanonymousid:")
            || lowercaseValue.hasPrefix("$rc_preview_mode_user")
        {
            throw RevenueCatClientError.invalidConfiguration(.blockedAppUserID)
        }

        let containsInvalidCharacters = value.unicodeScalars.contains { scalar in
            scalar == "/"
                || scalar.properties.isWhitespace
                || scalar.properties.generalCategory == .control
        }
        guard !containsInvalidCharacters else {
            throw RevenueCatClientError.invalidConfiguration(.appUserIDContainsInvalidCharacters)
        }

        return .init(value)
    }

    private static let blockedValues: Set<String> = [
        "no_user",
        "null",
        "none",
        "nil",
        "(null)",
        "nan",
        "unidentified",
        "undefined",
        "unknown",
        "anonymous",
        "guest",
        "-1",
        "0",
        "[]",
        "{}",
        "[object object]",
        "\0",
    ]
}
