import Foundation

public enum AccessLevel: Sendable, Equatable {
    case free
    case premium
    case premiumInGracePeriod
    case unknown
}

extension AccessLevel {
    /// Tri-state premium decision for App feature gates.
    ///
    /// `nil` deliberately preserves the distinction between a confirmed free customer and a
    /// customer whose entitlement has not been resolved yet.
    public var premiumAccess: Bool? {
        switch self {
        case .premium, .premiumInGracePeriod:
            true
        case .free:
            false
        case .unknown:
            nil
        }
    }

    var grantsPremiumAccess: Bool {
        premiumAccess == true
    }
}

public enum BillingCondition: Sendable, Equatable {
    case notApplicable
    case expired
    case entitlementTemporarilyMissing
    case billingIssueWhileActive
    case cancelledButActive
    case healthy
    case unknown
}
public enum SnapshotFreshness: Sendable, Equatable {
    case cachePermitted
    case networkConfirmed

    var strength: Int {
        switch self {
        case .cachePermitted: 0
        case .networkConfirmed: 1
        }
    }
}

public enum Store: Sendable, Equatable {
    case appStore
    case macAppStore
    case playStore
    case stripe
    case promotional
    case amazon
    case revenueCat
    case external
    case paddle
    case testStore
    case unknown
}

public enum DistributionChannel: Sendable, Equatable {
    case debugSandbox
    case testFlightSandbox
    case appStoreProduction
    case macOSProduction
    case unknown
}

public struct EntitlementSnapshot: Sendable, Equatable {
    public let accessLevel: AccessLevel
    public let billingCondition: BillingCondition
    public let productID: String?
    public let expirationDate: Date?
    public let willRenew: Bool
    public let store: Store
    public let isSandbox: Bool
    public let requestDate: Date
    public let freshness: SnapshotFreshness

    public init(
        accessLevel: AccessLevel,
        billingCondition: BillingCondition,
        productID: String?,
        expirationDate: Date?,
        willRenew: Bool,
        store: Store,
        isSandbox: Bool,
        requestDate: Date,
        freshness: SnapshotFreshness
    ) {
        self.accessLevel = accessLevel
        self.billingCondition = billingCondition
        self.productID = productID
        self.expirationDate = expirationDate
        self.willRenew = willRenew
        self.store = store
        self.isSandbox = isSandbox
        self.requestDate = requestDate
        self.freshness = freshness
    }
}

extension EntitlementSnapshot {
    var confirmsPurchaseEntitlement: Bool {
        accessLevel.grantsPremiumAccess && billingCondition != .entitlementTemporarilyMissing
    }

    func withFreshness(_ freshness: SnapshotFreshness) -> Self {
        .init(
            accessLevel: accessLevel,
            billingCondition: billingCondition,
            productID: productID,
            expirationDate: expirationDate,
            willRenew: willRenew,
            store: store,
            isSandbox: isSandbox,
            requestDate: requestDate,
            freshness: freshness
        )
    }

}

public enum PackageType: Sendable, Equatable {
    case unknown
    case custom
    case lifetime
    case annual
    case sixMonth
    case threeMonth
    case twoMonth
    case monthly
    case weekly
}

public struct SubscriptionPeriod: Sendable, Equatable {
    public enum Unit: Sendable, Equatable {
        case day
        case week
        case month
        case year
    }

    public let value: Int
    public let unit: Unit

    public init?(value: Int, unit: Unit) {
        guard value > 0 else { return nil }
        self.value = value
        self.unit = unit
    }
}

public struct PaywallPlacement: RawRepresentable, Hashable, Sendable,
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

/// Identifies one independently loaded RevenueCat Offering surface.
///
/// The current Offering and every Placement keep separate state and purchase handles even when
/// RevenueCat resolves them to the same Offering identifier.
public enum OfferingScope: Hashable, Sendable {
    case current
    case placement(PaywallPlacement)
}

public struct PurchaseOptionID: Hashable, Sendable {
    private let rawValue: UUID

    /// Creates an opaque identifier for previews and test fixtures.
    ///
    /// Production purchase identifiers are created by `RevenueCatClient` and are valid only for
    /// the Offering snapshot that returned them. A caller-created identifier cannot resolve to a
    /// RevenueCat package and will safely produce `optionUnavailable`.
    public init() {
        rawValue = UUID()
    }
}

public struct PurchaseOption: Sendable, Equatable {
    public let id: PurchaseOptionID
    public let packageType: PackageType
    public let localizedTitle: String
    public let localizedDescription: String
    public let price: Decimal
    public let localizedPrice: String
    public let currencyCode: String?
    public let subscriptionPeriod: SubscriptionPeriod?
    public let introductoryOffer: IntroductoryOffer?
    public let productID: String

    public init(
        id: PurchaseOptionID,
        packageType: PackageType,
        localizedTitle: String,
        localizedDescription: String,
        price: Decimal,
        localizedPrice: String,
        currencyCode: String?,
        subscriptionPeriod: SubscriptionPeriod?,
        introductoryOffer: IntroductoryOffer? = nil,
        productID: String
    ) {
        self.id = id
        self.packageType = packageType
        self.localizedTitle = localizedTitle
        self.localizedDescription = localizedDescription
        self.price = price
        self.localizedPrice = localizedPrice
        self.currencyCode = currencyCode
        self.subscriptionPeriod = subscriptionPeriod
        self.introductoryOffer = introductoryOffer
        self.productID = productID
    }
}

public struct IntroductoryOffer: Sendable, Equatable {
    public enum PaymentMode: Sendable, Equatable {
        case payAsYouGo
        case payUpFront
        case freeTrial
        case unknown
    }

    public let localizedPrice: String
    public let paymentMode: PaymentMode
    public let subscriptionPeriod: SubscriptionPeriod
    public let numberOfPeriods: Int

    public init(
        localizedPrice: String,
        paymentMode: PaymentMode,
        subscriptionPeriod: SubscriptionPeriod,
        numberOfPeriods: Int
    ) {
        self.localizedPrice = localizedPrice
        self.paymentMode = paymentMode
        self.subscriptionPeriod = subscriptionPeriod
        self.numberOfPeriods = numberOfPeriods
    }
}

public struct OfferingSnapshot: Sendable, Equatable {
    public let offeringID: String
    public let placement: PaywallPlacement?
    public let purchaseOptions: [PurchaseOption]

    public init(
        offeringID: String,
        placement: PaywallPlacement?,
        purchaseOptions: [PurchaseOption]
    ) {
        self.offeringID = offeringID
        self.placement = placement
        self.purchaseOptions = purchaseOptions
    }
}

public enum OfferingLoadState: Sendable, Equatable {
    case idle
    case loading
    case available(OfferingSnapshot)
    case missing
    case empty
    case failed(RevenueCatClientError)
}

extension OfferingLoadState {
    /// The only purchase options that are valid for a host App to display and buy.
    ///
    /// Starting a reload, losing identity alignment, receiving an empty response, or failing a
    /// request all make this collection empty immediately. A previous snapshot is never reused.
    public var purchaseOptions: [PurchaseOption] {
        guard case .available(let offering) = self else { return [] }
        return offering.purchaseOptions
    }
}

public enum IntroEligibility: Sendable, Equatable {
    case eligible
    case ineligible
    case unknown
}

public enum IdentityAlignment: Sendable, Equatable {
    case undeclared
    case matching
    case transitioning
    case failed(RevenueCatClientError)
}

public enum CustomerInfoFetchPolicy: Sendable, Equatable {
    case fromCacheOnly
    case fetchCurrent
    case notStaleCachedOrFetched
    case cachedOrFetched
}

public enum OperationState: Sendable, Equatable {
    case idle
    case configuring
    case identityChanging
    case purchasing(PurchaseOptionID)
    case restoring
}
