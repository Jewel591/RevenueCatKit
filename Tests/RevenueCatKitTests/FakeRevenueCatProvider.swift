import Foundation
@testable import RevenueCatKit

@MainActor
final class FakeRevenueCatProvider: RevenueCatProviding {
    var isConfigured = false
    var appUserID: String?
    var isAnonymous: Bool?

    private(set) var configureCallCount = 0
    private(set) var configuredAppUserID: String?
    private(set) var customerInfoPolicies: [CustomerInfoFetchPolicy] = []
    private(set) var streamInstallCount = 0
    private(set) var logInCallCount = 0
    private(set) var logOutCallCount = 0
    private(set) var offeringPlacements: [PaywallPlacement?] = []
    private(set) var eligibilityCallCount = 0
    private(set) var purchaseCallCount = 0
    private(set) var restoreCallCount = 0
    private(set) var invalidateHandleCallCount = 0
    private(set) var invalidatedHandleBatches: [Set<ProviderPackageHandle>] = []

    var customerInfoResponses: [Result<ProviderCustomerInfo, ProviderError>] = []
    var logInResponse: Result<ProviderCustomerInfo, ProviderError>?
    var logInCreated = true
    var logOutResponse: Result<ProviderCustomerInfo, ProviderError>?
    var offeringValue: ProviderOffering?
    var offeringError: ProviderError?
    var eligibilityValue: IntroEligibility = .unknown
    var eligibilityError: ProviderError?
    var purchaseResponse: Result<ProviderPurchaseResult, ProviderError>?
    var restoreResponse: Result<ProviderCustomerInfo, ProviderError>?

    var suspendPurchase = false
    var suspendLogIn = false
    var suspendOffering = false
    var suspendCustomerInfo = false

    private var streamContinuation: AsyncStream<Void>.Continuation?
    private var purchaseContinuation: CheckedContinuation<ProviderPurchaseResult, any Error>?
    private var logInContinuation: CheckedContinuation<ProviderLogInResult, any Error>?
    private var offeringContinuation: CheckedContinuation<ProviderOfferingResult, any Error>?
    private var customerInfoContinuation: CheckedContinuation<ProviderCustomerInfo, any Error>?

    func configure(
        apiKey: String,
        appUserID: String?,
        proxyURL: URL?,
        logLevel: RevenueCatLogLevel
    ) {
        configureCallCount += 1
        configuredAppUserID = appUserID
        isConfigured = true

        if let appUserID {
            self.appUserID = appUserID
            isAnonymous = false
        } else if self.appUserID == nil {
            self.appUserID = "$RCAnonymousID:test"
            isAnonymous = true
        }
    }

    func customerInfo(policy: CustomerInfoFetchPolicy) async throws -> ProviderCustomerInfo {
        customerInfoPolicies.append(policy)
        if suspendCustomerInfo {
            return try await withCheckedThrowingContinuation { continuation in
                customerInfoContinuation = continuation
            }
        }
        if !customerInfoResponses.isEmpty {
            return try customerInfoResponses.removeFirst().get()
        }
        return makeCustomerInfo(appUserID: appUserID ?? "missing")
    }

    func customerInfoInvalidationStream() -> AsyncStream<Void> {
        streamInstallCount += 1
        let pair = AsyncStream<Void>.makeStream()
        streamContinuation = pair.continuation
        return pair.stream
    }

    func logIn(appUserID: String) async throws -> ProviderLogInResult {
        logInCallCount += 1
        if suspendLogIn {
            return try await withCheckedThrowingContinuation { continuation in
                logInContinuation = continuation
            }
        }

        if let logInResponse {
            let result = try logInResponse.get()
            self.appUserID = result.fetchedForAppUserID
            isAnonymous = false
            return ProviderLogInResult(customerInfo: result, created: logInCreated)
        }
        self.appUserID = appUserID
        isAnonymous = false
        return ProviderLogInResult(
            customerInfo: makeCustomerInfo(appUserID: appUserID),
            created: logInCreated
        )
    }

    func logOut() async throws -> ProviderCustomerInfo {
        logOutCallCount += 1
        if let logOutResponse {
            let result = try logOutResponse.get()
            appUserID = result.fetchedForAppUserID
            isAnonymous = true
            return result
        }
        appUserID = "$RCAnonymousID:logout"
        isAnonymous = true
        return makeCustomerInfo(appUserID: appUserID!)
    }

    func offering(for placement: PaywallPlacement?) async throws -> ProviderOfferingResult {
        offeringPlacements.append(placement)
        let fetchedForAppUserID = appUserID ?? "missing"
        if suspendOffering {
            return try await withCheckedThrowingContinuation { continuation in
                offeringContinuation = continuation
            }
        }
        if let offeringError {
            throw offeringError
        }
        return .init(fetchedForAppUserID: fetchedForAppUserID, offering: offeringValue)
    }

    func introEligibility(for handle: ProviderPackageHandle) async throws -> ProviderEligibilityResult {
        eligibilityCallCount += 1
        if let eligibilityError {
            throw eligibilityError
        }
        return .init(
            fetchedForAppUserID: appUserID ?? "missing",
            eligibility: eligibilityValue
        )
    }

    func purchase(handle: ProviderPackageHandle) async throws -> ProviderPurchaseResult {
        purchaseCallCount += 1
        if suspendPurchase {
            return try await withCheckedThrowingContinuation { continuation in
                purchaseContinuation = continuation
            }
        }
        if let purchaseResponse {
            return try purchaseResponse.get()
        }
        return .init(
            customerInfo: makeCustomerInfo(appUserID: appUserID ?? "missing"),
            userCancelled: false
        )
    }

    func restorePurchases() async throws -> ProviderCustomerInfo {
        restoreCallCount += 1
        if let restoreResponse {
            return try restoreResponse.get()
        }
        return makeCustomerInfo(appUserID: appUserID ?? "missing")
    }

    func invalidateCachedHandles(_ handles: Set<ProviderPackageHandle>) {
        invalidateHandleCallCount += 1
        invalidatedHandleBatches.append(handles)
    }

    func invalidateAllCachedHandles() {
        invalidateHandleCallCount += 1
    }

    func emitCustomerInfoInvalidation() {
        streamContinuation?.yield(())
    }

    func resumePurchase(with result: Result<ProviderPurchaseResult, ProviderError>) {
        let continuation = purchaseContinuation
        purchaseContinuation = nil
        suspendPurchase = false
        continuation?.resume(with: result.mapError { $0 as any Error })
    }

    func resumeLogIn(
        appUserID: String,
        isAnonymous: Bool = false,
        created: Bool = true,
        result: Result<ProviderCustomerInfo, ProviderError>
    ) {
        self.appUserID = appUserID
        self.isAnonymous = isAnonymous
        let continuation = logInContinuation
        logInContinuation = nil
        suspendLogIn = false
        continuation?.resume(
            with: result
                .map { ProviderLogInResult(customerInfo: $0, created: created) }
                .mapError { $0 as any Error }
        )
    }

    func resumeOffering(
        fetchedForAppUserID: String,
        offering: ProviderOffering?
    ) {
        let continuation = offeringContinuation
        offeringContinuation = nil
        suspendOffering = false
        continuation?.resume(
            returning: .init(
                fetchedForAppUserID: fetchedForAppUserID,
                offering: offering
            )
        )
    }

    func resumeCustomerInfo(with result: Result<ProviderCustomerInfo, ProviderError>) {
        let continuation = customerInfoContinuation
        customerInfoContinuation = nil
        suspendCustomerInfo = false
        continuation?.resume(with: result.mapError { $0 as any Error })
    }
}

func makeCustomerInfo(
    appUserID: String,
    requestDate: Date = Date(timeIntervalSince1970: 1_000),
    entitlementID: String = "premium",
    entitlement: ProviderEntitlement? = nil
) -> ProviderCustomerInfo {
    .init(
        fetchedForAppUserID: appUserID,
        requestDate: requestDate,
        entitlements: entitlement.map { [entitlementID: $0] } ?? [:]
    )
}

func makeEntitlement(
    isActiveInCurrentEnvironment: Bool,
    isActiveInAnyEnvironment: Bool? = nil,
    willRenew: Bool = true,
    expirationDate: Date? = Date(timeIntervalSince1970: 2_000),
    store: Store = .appStore,
    productID: String = "premium.monthly",
    isSandbox: Bool = false,
    unsubscribeDetectedAt: Date? = nil,
    billingIssueDetectedAt: Date? = nil
) -> ProviderEntitlement {
    .init(
        isActiveInCurrentEnvironment: isActiveInCurrentEnvironment,
        isActiveInAnyEnvironment: isActiveInAnyEnvironment ?? isActiveInCurrentEnvironment,
        willRenew: willRenew,
        expirationDate: expirationDate,
        store: store,
        productID: productID,
        isSandbox: isSandbox,
        unsubscribeDetectedAt: unsubscribeDetectedAt,
        billingIssueDetectedAt: billingIssueDetectedAt
    )
}

func makeProviderOffering(
    offeringID: String = "default",
    packageIdentifier: String = "$rc_monthly"
) -> ProviderOffering {
    .init(
        identifier: offeringID,
        packages: [
            .init(
                handle: .init(rawValue: UUID()),
                identifier: packageIdentifier,
                packageType: .monthly,
                localizedTitle: "Monthly",
                localizedDescription: "Monthly premium access",
                price: 9.99,
                localizedPrice: "$9.99",
                currencyCode: "USD",
                subscriptionPeriod: .init(value: 1, unit: .month),
                introductoryOffer: SubscriptionPeriod(value: 1, unit: .year).map {
                    .init(
                        localizedPrice: "$4.99",
                        paymentMode: .payUpFront,
                        subscriptionPeriod: $0,
                        numberOfPeriods: 1
                    )
                },
                productID: "premium.monthly"
            ),
        ]
    )
}
