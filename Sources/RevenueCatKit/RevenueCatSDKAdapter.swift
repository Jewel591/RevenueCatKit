import Foundation
import RevenueCat
import StoreKit

@MainActor
final class RevenueCatSDKAdapter: RevenueCatProviding {
    private var packagesByHandle: [ProviderPackageHandle: RevenueCat.Package] = [:]

    var isConfigured: Bool {
        Purchases.isConfigured
    }

    var appUserID: String? {
        guard Purchases.isConfigured else { return nil }
        return Purchases.shared.appUserID
    }

    var isAnonymous: Bool? {
        guard Purchases.isConfigured else { return nil }
        return Purchases.shared.isAnonymous
    }

    func configure(
        apiKey: String,
        appUserID: String?,
        proxyURL: URL?,
        logLevel: RevenueCatLogLevel
    ) {
        Purchases.logLevel = logLevel.revenueCatValue
        Purchases.proxyURL = proxyURL

        if let appUserID {
            Purchases.configure(withAPIKey: apiKey, appUserID: appUserID)
        } else {
            Purchases.configure(withAPIKey: apiKey)
        }
    }

    func customerInfo(policy: CustomerInfoFetchPolicy) async throws -> ProviderCustomerInfo {
        guard let fetchedForAppUserID = appUserID else {
            throw ProviderError.unknown
        }

        do {
            let customerInfo = try await Purchases.shared.customerInfo(fetchPolicy: policy.revenueCatValue)
            return makeCustomerInfo(customerInfo, fetchedForAppUserID: fetchedForAppUserID)
        } catch {
            throw mapError(error)
        }
    }

    func customerInfoInvalidationStream() -> AsyncStream<Void> {
        let source = Purchases.shared.customerInfoStream
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                for await _ in source {
                    guard !Task.isCancelled else { break }
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func logIn(appUserID: String) async throws -> ProviderCustomerInfo {
        do {
            let result = try await Purchases.shared.logIn(appUserID)
            return makeCustomerInfo(result.customerInfo, fetchedForAppUserID: Purchases.shared.appUserID)
        } catch {
            throw mapError(error)
        }
    }

    func logOut() async throws -> ProviderCustomerInfo {
        do {
            let customerInfo = try await Purchases.shared.logOut()
            return makeCustomerInfo(customerInfo, fetchedForAppUserID: Purchases.shared.appUserID)
        } catch {
            throw mapError(error)
        }
    }

    func offering(for placement: PaywallPlacement?) async throws -> ProviderOfferingResult {
        guard let fetchedForAppUserID = appUserID else {
            throw ProviderError.unknown
        }

        do {
            let offerings = try await Purchases.shared.offerings()
            let offering = placement.map {
                offerings.currentOffering(forPlacement: $0.rawValue)
            } ?? offerings.current

            guard let offering else {
                return .init(fetchedForAppUserID: fetchedForAppUserID, offering: nil)
            }

            let packages = offering.availablePackages.map { package in
                let handle = ProviderPackageHandle(rawValue: UUID())
                packagesByHandle[handle] = package
                return ProviderPackage(
                    handle: handle,
                    identifier: package.identifier,
                    packageType: package.packageType.companyValue,
                    localizedTitle: package.storeProduct.localizedTitle,
                    localizedDescription: package.storeProduct.localizedDescription,
                    price: package.storeProduct.price,
                    localizedPrice: package.storeProduct.localizedPriceString,
                    currencyCode: package.storeProduct.currencyCode,
                    subscriptionPeriod: package.storeProduct.subscriptionPeriod?.companyValue,
                    introductoryOffer: package.storeProduct.introductoryDiscount.flatMap {
                        guard let subscriptionPeriod = $0.subscriptionPeriod.companyValue else {
                            return nil
                        }
                        return IntroductoryOffer(
                            localizedPrice: $0.localizedPriceString,
                            paymentMode: $0.paymentMode.companyValue,
                            subscriptionPeriod: subscriptionPeriod,
                            numberOfPeriods: $0.numberOfPeriods
                        )
                    },
                    productID: package.storeProduct.productIdentifier
                )
            }

            return .init(
                fetchedForAppUserID: fetchedForAppUserID,
                offering: .init(identifier: offering.identifier, packages: packages)
            )
        } catch {
            throw mapError(error)
        }
    }

    func introEligibility(for handle: ProviderPackageHandle) async throws -> ProviderEligibilityResult {
        guard let package = packagesByHandle[handle] else {
            throw ProviderError.optionUnavailable
        }
        guard let fetchedForAppUserID = appUserID else {
            throw ProviderError.unknown
        }

        let status = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: package.storeProduct)
        return .init(
            fetchedForAppUserID: fetchedForAppUserID,
            eligibility: status.companyValue
        )
    }

    func purchase(handle: ProviderPackageHandle) async throws -> ProviderPurchaseResult {
        guard let package = packagesByHandle[handle] else {
            throw ProviderError.optionUnavailable
        }
        guard let fetchedForAppUserID = appUserID else {
            throw ProviderError.unknown
        }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            return .init(
                customerInfo: makeCustomerInfo(
                    result.customerInfo,
                    fetchedForAppUserID: fetchedForAppUserID
                ),
                userCancelled: result.userCancelled
            )
        } catch {
            throw mapError(error)
        }
    }

    func restorePurchases() async throws -> ProviderCustomerInfo {
        guard let fetchedForAppUserID = appUserID else {
            throw ProviderError.unknown
        }

        do {
            let customerInfo = try await Purchases.shared.restorePurchases()
            return makeCustomerInfo(customerInfo, fetchedForAppUserID: fetchedForAppUserID)
        } catch {
            throw mapError(error)
        }
    }

    func invalidateCachedHandles(_ handles: Set<ProviderPackageHandle>) {
        for handle in handles {
            packagesByHandle[handle] = nil
        }
    }

    func invalidateAllCachedHandles() {
        packagesByHandle.removeAll()
    }

    private func makeCustomerInfo(
        _ customerInfo: CustomerInfo,
        fetchedForAppUserID: String
    ) -> ProviderCustomerInfo {
        let entitlements = customerInfo.entitlements.all.mapValues { entitlement in
            ProviderEntitlement(
                isActiveInCurrentEnvironment: entitlement.isActiveInCurrentEnvironment,
                isActiveInAnyEnvironment: entitlement.isActiveInAnyEnvironment,
                willRenew: entitlement.willRenew,
                expirationDate: entitlement.expirationDate,
                store: entitlement.store.companyValue,
                productID: entitlement.productIdentifier,
                isSandbox: entitlement.isSandbox,
                unsubscribeDetectedAt: entitlement.unsubscribeDetectedAt,
                billingIssueDetectedAt: entitlement.billingIssueDetectedAt
            )
        }
        return .init(
            fetchedForAppUserID: fetchedForAppUserID,
            requestDate: customerInfo.requestDate,
            entitlements: entitlements
        )
    }

    private func mapError(_ error: Error) -> ProviderError {
        if error is CancellationError {
            return .taskCancelled
        }

        if let storeKitError = error as? StoreKitError,
           case .userCancelled = storeKitError {
            return .purchaseCancelled
        }

        let nsError = error as NSError
        if nsError.domain == SKErrorDomain,
           nsError.code == SKError.paymentCancelled.rawValue {
            return .purchaseCancelled
        }

        guard let errorCode = error as? ErrorCode else {
            return .unknown
        }
        switch errorCode {
        case .purchaseCancelledError:
            return .purchaseCancelled
        case .storeProblemError:
            return .storeProblem
        case .purchaseNotAllowedError:
            return .purchaseNotAllowed
        case .purchaseInvalidError:
            return .purchaseInvalid
        case .productNotAvailableForPurchaseError:
            return .productNotAvailable
        case .productAlreadyPurchasedError:
            return .productAlreadyPurchased
        case .invalidReceiptError:
            return .invalidReceipt
        case .invalidAppUserIdError:
            return .invalidAppUserID
        case .paymentPendingError:
            return .paymentPending
        case .logOutAnonymousUserError:
            return .logOutAnonymousUser
        case .networkError, .offlineConnectionError, .apiEndpointBlockedError:
            return .network
        case .operationAlreadyInProgressForProductError:
            return .operationInProgress
        default:
            return .unknown
        }
    }
}

private extension StoreProductDiscount.PaymentMode {
    var companyValue: IntroductoryOffer.PaymentMode {
        switch self {
        case .payAsYouGo: .payAsYouGo
        case .payUpFront: .payUpFront
        case .freeTrial: .freeTrial
        @unknown default: .unknown
        }
    }
}

private extension RevenueCatLogLevel {
    var revenueCatValue: RevenueCat.LogLevel {
        switch self {
        case .verbose: .verbose
        case .debug: .debug
        case .info: .info
        case .warning: .warn
        case .error: .error
        }
    }
}

private extension CustomerInfoFetchPolicy {
    var revenueCatValue: RevenueCat.CacheFetchPolicy {
        switch self {
        case .fromCacheOnly: .fromCacheOnly
        case .fetchCurrent: .fetchCurrent
        case .notStaleCachedOrFetched: .notStaleCachedOrFetched
        case .cachedOrFetched: .cachedOrFetched
        }
    }
}

private extension RevenueCat.Store {
    var companyValue: Store {
        switch self {
        case .appStore: .appStore
        case .macAppStore: .macAppStore
        case .playStore: .playStore
        case .stripe: .stripe
        case .promotional: .promotional
        case .amazon: .amazon
        case .rcBilling: .revenueCat
        case .external: .external
        case .paddle: .paddle
        case .testStore: .testStore
        case .unknownStore, .galaxy: .unknown
        @unknown default: .unknown
        }
    }
}

private extension RevenueCat.PackageType {
    var companyValue: PackageType {
        switch self {
        case .unknown: .unknown
        case .custom: .custom
        case .lifetime: .lifetime
        case .annual: .annual
        case .sixMonth: .sixMonth
        case .threeMonth: .threeMonth
        case .twoMonth: .twoMonth
        case .monthly: .monthly
        case .weekly: .weekly
        @unknown default: .unknown
        }
    }
}

private extension RevenueCat.SubscriptionPeriod {
    var companyValue: SubscriptionPeriod? {
        let unit: SubscriptionPeriod.Unit
        switch self.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return .init(value: value, unit: unit)
    }
}

private extension IntroEligibilityStatus {
    var companyValue: IntroEligibility {
        switch self {
        case .eligible: .eligible
        case .ineligible, .noIntroOfferExists: .ineligible
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }
}
