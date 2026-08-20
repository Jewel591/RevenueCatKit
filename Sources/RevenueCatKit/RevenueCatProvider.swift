import Foundation

@MainActor
protocol RevenueCatProviding: AnyObject {
    var isConfigured: Bool { get }
    var appUserID: String? { get }
    var isAnonymous: Bool? { get }

    func configure(
        apiKey: String,
        appUserID: String?,
        proxyURL: URL?,
        logLevel: RevenueCatLogLevel
    )
    func customerInfo(policy: CustomerInfoFetchPolicy) async throws -> ProviderCustomerInfo
    func customerInfoInvalidationStream() -> AsyncStream<Void>
    func logIn(appUserID: String) async throws -> ProviderLogInResult
    func logOut() async throws -> ProviderCustomerInfo
    func offering(for placement: PaywallPlacement?) async throws -> ProviderOfferingResult
    func introEligibility(for handle: ProviderPackageHandle) async throws -> ProviderEligibilityResult
    func purchase(handle: ProviderPackageHandle) async throws -> ProviderPurchaseResult
    func restorePurchases() async throws -> ProviderCustomerInfo
    func invalidateCachedHandles(_ handles: Set<ProviderPackageHandle>)
    func invalidateAllCachedHandles()
}

enum ProviderError: Error, Sendable, Equatable {
    case purchaseCancelled
    case storeProblem
    case purchaseNotAllowed
    case purchaseInvalid
    case productNotAvailable
    case productAlreadyPurchased
    case invalidReceipt
    case invalidAppUserID
    case paymentPending
    case logOutAnonymousUser
    case network
    case operationInProgress
    case optionUnavailable
    case taskCancelled
    case unknown
}

struct ProviderEntitlement: Sendable, Equatable {
    let isActiveInCurrentEnvironment: Bool
    let isActiveInAnyEnvironment: Bool
    let willRenew: Bool
    let expirationDate: Date?
    let store: Store
    let productID: String
    let isSandbox: Bool
    let unsubscribeDetectedAt: Date?
    let billingIssueDetectedAt: Date?
}

struct ProviderCustomerInfo: Sendable, Equatable {
    let fetchedForAppUserID: String
    let requestDate: Date
    let entitlements: [String: ProviderEntitlement]
}

struct ProviderLogInResult: Sendable, Equatable {
    let customerInfo: ProviderCustomerInfo
    let created: Bool
}

struct ProviderPackageHandle: Hashable, Sendable {
    let rawValue: UUID
}

struct ProviderPackage: Sendable, Equatable {
    let handle: ProviderPackageHandle
    let identifier: String
    let packageType: PackageType
    let localizedTitle: String
    let localizedDescription: String
    let price: Decimal
    let localizedPrice: String
    let currencyCode: String?
    let subscriptionPeriod: SubscriptionPeriod?
    let introductoryOffer: IntroductoryOffer?
    let productID: String
}

struct ProviderOffering: Sendable, Equatable {
    let identifier: String
    let packages: [ProviderPackage]
}

struct ProviderOfferingResult: Sendable, Equatable {
    let fetchedForAppUserID: String
    let offering: ProviderOffering?
}

struct ProviderEligibilityResult: Sendable, Equatable {
    let fetchedForAppUserID: String
    let eligibility: IntroEligibility
}

struct ProviderPurchaseResult: Sendable, Equatable {
    let customerInfo: ProviderCustomerInfo
    let userCancelled: Bool
}
