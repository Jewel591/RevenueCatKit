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

/// House-standard classification for “the user paid, but the expected entitlement is not active.”
///
/// Each case maps to a different operational action. The collections on
/// `EntitlementDiagnostics` are lifetime customer history from RevenueCat, not proof that
/// the current StoreKit transaction has posted.
public enum EntitlementFailureDiagnosis: String, Sendable, Equatable {
    /// Expected entitlement key is absent and there is no in-flight purchase to attribute.
    /// Meaningful on the revocation path, where the user was previously confirmed premium.
    case entitlementIDMissing = "entitlement_id_missing"

    /// RevenueCat already lists this product ID on the customer, but the expected entitlement
    /// is not active. The usual action is to fix the Dashboard product-to-entitlement mapping.
    case productNotAttachedToEntitlement = "product_not_attached_to_entitlement"

    /// RevenueCat has no lifetime record of this product ID for the customer. Treat as sync
    /// delay: retry restore, do not change Dashboard mapping.
    case transactionNotYetSynced = "transaction_not_yet_synced"

    /// The expected entitlement key exists but is inactive, and there is no in-flight purchase.
    /// Expiry, refund, and server-side revocation all land here.
    case entitlementInactiveUnknownCause = "entitlement_inactive_unknown_cause"

    /// The expected entitlement is active. Reaching a failure reporter with this result means
    /// the call site’s “is entitled” check has drifted from this classifier.
    case entitlementActive = "entitlement_active"

    /// Classifies why the expected entitlement is inactive.
    ///
    /// When `purchasedProductID` is present, product membership is the watershed and is
    /// evaluated before entitlement-key existence. `entitlements.all` is the set this customer
    /// has been granted, not the project-wide entitlement table, so a first purchase that has
    /// not granted access leaves that set empty.
    public static func classify(
        expectedEntitlementID: String,
        allEntitlementIDs: Set<String>,
        activeEntitlementIDs: Set<String>,
        allPurchasedProductIDs: Set<String>,
        purchasedProductID: String?
    ) -> Self {
        if activeEntitlementIDs.contains(expectedEntitlementID) {
            return .entitlementActive
        }

        if let purchasedProductID {
            return allPurchasedProductIDs.contains(purchasedProductID)
                ? .productNotAttachedToEntitlement
                : .transactionNotYetSynced
        }

        guard allEntitlementIDs.contains(expectedEntitlementID) else {
            return .entitlementIDMissing
        }

        return .entitlementInactiveUnknownCause
    }
}

/// Normalized entitlement collections for diagnostics. Product IDs here are telemetry, not
/// business configuration or access decisions.
public struct EntitlementDiagnostics: Sendable, Equatable {
    public let expectedEntitlementID: String
    public let allEntitlementIDs: Set<String>
    public let activeEntitlementIDs: Set<String>
    /// Product IDs RevenueCat has recorded for this customer. This is lifetime history, not
    /// proof that the current transaction has synced.
    public let allPurchasedProductIDs: Set<String>
    /// Product ID of the in-flight purchase that produced this snapshot, if any.
    public let purchasedProductID: String?

    public static let empty = EntitlementDiagnostics(
        expectedEntitlementID: "",
        allEntitlementIDs: [],
        activeEntitlementIDs: [],
        allPurchasedProductIDs: [],
        purchasedProductID: nil
    )

    public init(
        expectedEntitlementID: String,
        allEntitlementIDs: Set<String>,
        activeEntitlementIDs: Set<String>,
        allPurchasedProductIDs: Set<String>,
        purchasedProductID: String? = nil
    ) {
        self.expectedEntitlementID = expectedEntitlementID
        self.allEntitlementIDs = allEntitlementIDs
        self.activeEntitlementIDs = activeEntitlementIDs
        self.allPurchasedProductIDs = allPurchasedProductIDs
        self.purchasedProductID = purchasedProductID
    }

    public var diagnosis: EntitlementFailureDiagnosis {
        diagnose(purchasedProductID: purchasedProductID)
    }

    public func diagnose(purchasedProductID: String?) -> EntitlementFailureDiagnosis {
        .classify(
            expectedEntitlementID: expectedEntitlementID,
            allEntitlementIDs: allEntitlementIDs,
            activeEntitlementIDs: activeEntitlementIDs,
            allPurchasedProductIDs: allPurchasedProductIDs,
            purchasedProductID: purchasedProductID
        )
    }

    /// Sorted, stable key-value pairs for telemetry. Verdicts may be revised later; the
    /// collections that produced them must remain readable.
    public var telemetryContext: [String: String] {
        [
            "verdict": diagnosis.rawValue,
            "expected_entitlement_id": expectedEntitlementID,
            "all_entitlement_ids": allEntitlementIDs.sorted().joined(separator: ","),
            "active_entitlement_ids": activeEntitlementIDs.sorted().joined(separator: ","),
            "all_purchased_product_ids": allPurchasedProductIDs.sorted().joined(separator: ","),
            "purchased_product_id": purchasedProductID ?? "<none>",
        ]
    }
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
    public let diagnostics: EntitlementDiagnostics

    public init(
        accessLevel: AccessLevel,
        billingCondition: BillingCondition,
        productID: String?,
        expirationDate: Date?,
        willRenew: Bool,
        store: Store,
        isSandbox: Bool,
        requestDate: Date,
        freshness: SnapshotFreshness,
        diagnostics: EntitlementDiagnostics = .empty
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
        self.diagnostics = diagnostics
    }
}

extension EntitlementSnapshot {
    var confirmsPurchaseEntitlement: Bool {
        accessLevel.grantsPremiumAccess && billingCondition != .entitlementTemporarilyMissing
    }

    func withFreshness(_ freshness: SnapshotFreshness) -> Self {
        withDiagnostics(diagnostics, freshness: freshness)
    }

    func withDiagnostics(
        _ diagnostics: EntitlementDiagnostics,
        freshness: SnapshotFreshness? = nil
    ) -> Self {
        .init(
            accessLevel: accessLevel,
            billingCondition: billingCondition,
            productID: productID,
            expirationDate: expirationDate,
            willRenew: willRenew,
            store: store,
            isSandbox: isSandbox,
            requestDate: requestDate,
            freshness: freshness ?? self.freshness,
            diagnostics: diagnostics
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
