import Foundation
import Observation
import os

@MainActor
@Observable
public final class RevenueCatClient {
    public struct State: Sendable, Equatable {
        public let entitlement: EntitlementSnapshot?
        public let operation: OperationState
        public let currentAppUserID: AppUserID?
        public let isAnonymous: Bool
        public let desiredIdentity: DesiredIdentity?
        public let identityAlignment: IdentityAlignment
        public let offerings: [OfferingScope: OfferingLoadState]
        public let distributionChannel: DistributionChannel

        public var accessLevel: AccessLevel {
            guard identityAlignment == .matching else { return .unknown }
            return entitlement?.accessLevel ?? .unknown
        }

        public init(
            entitlement: EntitlementSnapshot? = nil,
            operation: OperationState = .idle,
            currentAppUserID: AppUserID? = nil,
            isAnonymous: Bool = true,
            desiredIdentity: DesiredIdentity? = nil,
            identityAlignment: IdentityAlignment = .undeclared,
            offerings: [OfferingScope: OfferingLoadState] = [:],
            distributionChannel: DistributionChannel = .unknown
        ) {
            self.entitlement = entitlement
            self.operation = operation
            self.currentAppUserID = currentAppUserID
            self.isAnonymous = isAnonymous
            self.desiredIdentity = desiredIdentity
            self.identityAlignment = identityAlignment
            self.offerings = offerings
            self.distributionChannel = distributionChannel
        }

        public func offering(for scope: OfferingScope = .current) -> OfferingLoadState {
            offerings[scope] ?? .idle
        }
    }

    public enum PurchaseOutcome: Sendable, Equatable {
        case purchased(EntitlementSnapshot)
        case cancelled
        case pending
        case notEntitled
    }

    public enum RestoreOutcome: Sendable, Equatable {
        case restored(EntitlementSnapshot)
        case noActiveEntitlement
    }

    public static let shared = RevenueCatClient(provider: RevenueCatSDKAdapter())

    public private(set) var state = State()

    @ObservationIgnored
    private let provider: RevenueCatProviding
    @ObservationIgnored
    private let distributionChannelProvider: @MainActor () -> DistributionChannel
    @ObservationIgnored
    private let runtimeOptions: RevenueCatRuntimeOptions
    @ObservationIgnored
    private let revocationGrace: PremiumRevocationGrace
    @ObservationIgnored
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.company.RevenueCatKit",
        category: "RevenueCatClient"
    )

    @ObservationIgnored
    private var configuration: Configuration?
    @ObservationIgnored
    private var sdkConfiguredByClient = false
    @ObservationIgnored
    private var anonymousConfigurationFailed = false
    @ObservationIgnored
    private var didCompleteInitialRefresh = false
    @ObservationIgnored
    private var isInitialRefreshInFlight = false

    @ObservationIgnored
    private var mutationInProgress = false
    @ObservationIgnored
    private var retainedMutationTask: Any?
    @ObservationIgnored
    private var identityGeneration: UInt64 = 0
    @ObservationIgnored
    private var identityReconciliationTask: Task<Void, Never>?

    @ObservationIgnored
    private var optionHandles: [PurchaseOptionID: ProviderPackageHandle] = [:]
    @ObservationIgnored
    private var optionIDsByScope: [OfferingScope: Set<PurchaseOptionID>] = [:]
    @ObservationIgnored
    private var offeringGenerationByScope: [OfferingScope: UInt64] = [:]
    @ObservationIgnored
    private var offeringLoadTasks: [OfferingScope: Task<OfferingLoadState, Error>] = [:]
    @ObservationIgnored
    private var introEligibilityCache: [IntroCacheKey: IntroEligibility] = [:]
    @ObservationIgnored
    private var activePurchaseHandle: ProviderPackageHandle?
    @ObservationIgnored
    private var deferredHandleInvalidations: Set<ProviderPackageHandle> = []

    @ObservationIgnored
    private var streamObservationTask: Task<Void, Never>?
    @ObservationIgnored
    private var streamRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var streamRefreshPending = false

    init(
        provider: RevenueCatProviding,
        distributionChannelProvider: @escaping @MainActor () -> DistributionChannel = RevenueCatClient.detectDistributionChannel,
        runtimeOptions: RevenueCatRuntimeOptions = .companyDefault,
        revocationGrace: PremiumRevocationGrace = PremiumRevocationGrace()
    ) {
        self.provider = provider
        self.distributionChannelProvider = distributionChannelProvider
        self.runtimeOptions = runtimeOptions
        self.revocationGrace = revocationGrace
    }

    deinit {
        identityReconciliationTask?.cancel()
        for task in offeringLoadTasks.values {
            task.cancel()
        }
        streamObservationTask?.cancel()
        streamRefreshTask?.cancel()
    }

    /// Declares the latest App account fact without configuring or otherwise waking the SDK.
    ///
    /// Repeating the same value is a no-op unless the previous alignment attempt failed, in which
    /// case the repeated declaration acts as an explicit retry.
    public func setDesiredIdentity(_ desiredIdentity: DesiredIdentity) {
        let validatedIdentity: DesiredIdentity
        do {
            validatedIdentity = try validated(desiredIdentity)
        } catch let error as RevenueCatClientError {
            identityGeneration &+= 1
            invalidateIdentityScopedState()
            publish(
                entitlement: .replace(nil),
                desiredIdentity: desiredIdentity,
                identityAlignment: .failed(error),
                offerings: clearedOfferingStates()
            )
            return
        } catch {
            identityGeneration &+= 1
            invalidateIdentityScopedState()
            publish(
                entitlement: .replace(nil),
                desiredIdentity: desiredIdentity,
                identityAlignment: .failed(.unknown),
                offerings: clearedOfferingStates()
            )
            return
        }

        if state.desiredIdentity == validatedIdentity {
            guard case .failed = state.identityAlignment else { return }
        } else {
            identityGeneration &+= 1
            invalidateIdentityScopedState()
        }

        publish(
            entitlement: .replace(nil),
            desiredIdentity: validatedIdentity,
            identityAlignment: .transitioning,
            offerings: clearedOfferingStates()
        )
        scheduleIdentityReconciliationIfNeeded()
    }

    public func configure(
        _ configuration: Configuration
    ) async throws {
        try await runRetainedMutation(operation: .configuring) { [self] in
            try await performConfigure(configuration)
        }
    }

    @discardableResult
    public func refresh(
        policy: CustomerInfoFetchPolicy = .notStaleCachedOrFetched
    ) async throws -> EntitlementSnapshot {
        try requireConfigured()
        try requireStableReadIdentity()
        try requireAlignedIdentity()
        let capture = try captureIdentity()
        return try await fetchAndApplyCustomerInfo(policy: policy, capture: capture)
    }

    @discardableResult
    public func forceRefresh() async throws -> EntitlementSnapshot {
        try await refresh(policy: .fetchCurrent)
    }

    @discardableResult
    public func loadOffering(
        for requestedScope: OfferingScope = .current
    ) async throws -> OfferingLoadState {
        do {
            try requireConfigured()
        } catch {
            let failure = OfferingLoadState.failed(normalizedClientError(error))
            setOfferingState(failure, for: requestedScope)
            return failure
        }
        guard state.identityAlignment == .matching else { return .idle }

        let scope: OfferingScope
        do {
            scope = try validatedScope(requestedScope)
        } catch {
            let failure = OfferingLoadState.failed(normalizedClientError(error))
            setOfferingState(failure, for: requestedScope)
            return failure
        }
        if let task = offeringLoadTasks[scope] {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }

        removeOptions(for: scope)
        let generation = nextOfferingGeneration(for: scope)
        setOfferingState(.loading, for: scope)
        let task = Task { @MainActor [weak self] () throws -> OfferingLoadState in
            guard let self else { throw CancellationError() }
            return try await performOfferingLoad(for: scope, generation: generation)
        }
        offeringLoadTasks[scope] = task

        do {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return state.offering(for: scope)
        }
    }

    public func checkIntroEligibility(
        for optionID: PurchaseOptionID
    ) async throws -> IntroEligibility {
        try requireConfigured()
        try requireStableReadIdentity()
        try requireAlignedIdentity()
        guard let handle = optionHandles[optionID] else {
            throw RevenueCatClientError.optionUnavailable
        }

        let capture = try captureIdentity()
        let cacheKey = IntroCacheKey(generation: capture.generation, optionID: optionID)
        if let cached = introEligibilityCache[cacheKey] {
            return cached
        }

        let result: ProviderEligibilityResult
        do {
            result = try await provider.introEligibility(for: handle)
        } catch {
            throw normalizedError(error)
        }
        try validateCompletion(
            capture: capture,
            fetchedForAppUserID: result.fetchedForAppUserID
        )
        introEligibilityCache[cacheKey] = result.eligibility
        return result.eligibility
    }

    public func purchase(_ optionID: PurchaseOptionID) async throws -> PurchaseOutcome {
        try requireConfigured()
        try requireStableReadIdentity()
        try requireAlignedIdentity()
        guard let handle = optionHandles[optionID] else {
            throw RevenueCatClientError.optionUnavailable
        }
        let capture = try captureIdentity()

        return try await runRetainedMutation(operation: .purchasing(optionID)) { [self] in
            try validateCompletion(capture: capture)
            activePurchaseHandle = handle
            defer { releaseActivePurchaseHandle(handle) }
            do {
                let result = try await provider.purchase(handle: handle)
                let snapshot = try applyCustomerInfo(
                    result.customerInfo,
                    freshness: .networkConfirmed,
                    capture: capture
                )
                if snapshot.confirmsPurchaseEntitlement {
                    return .purchased(snapshot)
                }
                if result.userCancelled {
                    return .cancelled
                }
                return .notEntitled
            } catch {
                try validateCompletion(capture: capture)
                return try await handlePurchaseError(error, capture: capture)
            }
        }
    }

    public func restorePurchases() async throws -> RestoreOutcome {
        try requireConfigured()
        try requireStableReadIdentity()
        try requireAlignedIdentity()
        let capture = try captureIdentity()
        return try await runRetainedMutation(operation: .restoring) { [self] in
            try validateCompletion(capture: capture)
            do {
                let customerInfo = try await provider.restorePurchases()
                let snapshot = try applyCustomerInfo(
                    customerInfo,
                    freshness: .networkConfirmed,
                    capture: capture
                )
                return snapshot.accessLevel.grantsPremiumAccess
                    ? .restored(snapshot)
                    : .noActiveEntitlement
            } catch {
                try validateCompletion(capture: capture)
                throw normalizedError(error)
            }
        }
    }
}

private extension RevenueCatClient {
    struct IdentityCapture: Sendable {
        let generation: UInt64
        let appUserID: AppUserID
    }

    struct IntroCacheKey: Hashable {
        let generation: UInt64
        let optionID: PurchaseOptionID
    }

    enum EntitlementPublication {
        case preserve
        case replace(EntitlementSnapshot?)
    }

    func performConfigure(_ proposedConfiguration: Configuration) async throws {
        let validatedConfiguration: Configuration
        let validatedDesiredIdentity: DesiredIdentity?
        do {
            let validated = try proposedConfiguration.validated(
                desiredIdentity: state.desiredIdentity
            )
            validatedConfiguration = validated.configuration
            validatedDesiredIdentity = validated.desiredIdentity
        } catch {
            throw normalizedError(error)
        }

        let effectiveDesiredIdentity: DesiredIdentity?
        if validatedConfiguration.identityPolicy == .anonymousOnly {
            effectiveDesiredIdentity = .anonymous
        } else {
            effectiveDesiredIdentity = validatedDesiredIdentity
        }

        if state.desiredIdentity != effectiveDesiredIdentity,
           let effectiveDesiredIdentity {
            publish(
                desiredIdentity: effectiveDesiredIdentity,
                identityAlignment: .transitioning
            )
        }

        if let configuration {
            guard configuration == validatedConfiguration else {
                throw RevenueCatClientError.configurationConflict
            }
            if anonymousConfigurationFailed {
                throw RevenueCatClientError.anonymousIdentityUnavailable
            }
            guard let effectiveDesiredIdentity else { return }
            if didCompleteInitialRefresh,
               state.identityAlignment == .matching,
               providerIdentityMatches(effectiveDesiredIdentity) {
                return
            }
            try await performDesiredIdentityAlignment(effectiveDesiredIdentity)
            return
        }

        guard !provider.isConfigured else {
            throw RevenueCatClientError.alreadyConfiguredExternally
        }

        configuration = validatedConfiguration
        // Restore any persisted RevenueCat user first. Passing an account ID into
        // configure() would skip logIn aliasing and orphan purchases on an old
        // anonymous ID.
        provider.configure(
            apiKey: validatedConfiguration.publicSDKKey.rawValue,
            appUserID: nil,
            proxyURL: runtimeOptions.proxyURL,
            logLevel: runtimeOptions.logLevel
        )
        if let restoredAppUserID = provider.appUserID {
            revocationGrace.prepareInitialRestoredIdentity(restoredAppUserID)
        }
        sdkConfiguredByClient = true
        publishProviderIdentity(
            entitlement: nil,
            identityAlignment: effectiveDesiredIdentity == nil ? .undeclared : .transitioning
        )

        if case .anonymousOnly = validatedConfiguration.identityPolicy,
           provider.isAnonymous != true {
            anonymousConfigurationFailed = true
            publish(
                entitlement: .replace(nil),
                identityAlignment: .failed(.anonymousIdentityUnavailable)
            )
            throw RevenueCatClientError.anonymousIdentityUnavailable
        }

        installStreamObserverIfNeeded()
        guard let effectiveDesiredIdentity else { return }
        try await performDesiredIdentityAlignment(effectiveDesiredIdentity)
    }

    func performDesiredIdentityAlignment(_ desiredIdentity: DesiredIdentity) async throws {
        isInitialRefreshInFlight = true
        defer {
            isInitialRefreshInFlight = false
            startStreamRefreshIfNeeded()
        }

        let generation = identityGeneration
        publish(
            entitlement: .replace(nil),
            identityAlignment: .transitioning,
            offerings: clearedOfferingStates()
        )

        do {
            let customerInfo: ProviderCustomerInfo
            let freshness: SnapshotFreshness
            var anonymousAliasSource: String?
            if providerIdentityMatches(desiredIdentity) {
                let capture = try captureIdentity()
                customerInfo = try await provider.customerInfo(
                    policy: .notStaleCachedOrFetched
                )
                try validateCompletion(
                    capture: capture,
                    fetchedForAppUserID: customerInfo.fetchedForAppUserID
                )
                freshness = .cachePermitted
            } else {
                switch desiredIdentity {
                case .anonymous:
                    customerInfo = try await provider.logOut()
                case .account(let appUserID):
                    if provider.isAnonymous == true {
                        anonymousAliasSource = provider.appUserID
                    }
                    customerInfo = try await provider.logIn(appUserID: appUserID.rawValue)
                }
                freshness = .networkConfirmed
            }

            guard identityGeneration == generation,
                  state.desiredIdentity == desiredIdentity,
                  providerIdentityMatches(desiredIdentity),
                  let rawAppUserID = provider.appUserID else {
                throw RevenueCatClientError.identityChangedDuringOperation
            }
            if let anonymousAliasSource,
               case .account = desiredIdentity {
                revocationGrace.transferAnonymousProvenance(
                    from: anonymousAliasSource,
                    to: rawAppUserID
                )
            }
            let capture = IdentityCapture(
                generation: generation,
                appUserID: .init(rawAppUserID)
            )
            _ = try applyCustomerInfo(
                customerInfo,
                freshness: freshness,
                capture: capture
            )
            didCompleteInitialRefresh = true
            publishProviderIdentity(
                entitlement: state.entitlement,
                identityAlignment: .matching
            )
        } catch {
            let normalized = normalizedClientError(error)
            if identityGeneration == generation,
               state.desiredIdentity == desiredIdentity {
                publishProviderIdentity(
                    entitlement: nil,
                    identityAlignment: .failed(normalized)
                )
            }
            throw normalized
        }
    }

    func handlePurchaseError(
        _ error: Error,
        capture: IdentityCapture
    ) async throws -> PurchaseOutcome {
        guard let providerError = error as? ProviderError else {
            throw normalizedError(error)
        }

        switch providerError {
        case .purchaseCancelled:
            return .cancelled
        case .paymentPending:
            return .pending
        case .productAlreadyPurchased:
            do {
                let snapshot = try await fetchAndApplyCustomerInfo(
                    policy: .fetchCurrent,
                    capture: capture
                )
                guard snapshot.confirmsPurchaseEntitlement else {
                    throw RevenueCatClientError.invalidPurchase
                }
                return .purchased(snapshot)
            } catch {
                throw normalizedError(error)
            }
        case .storeProblem:
            do {
                let snapshot = try await fetchAndApplyCustomerInfo(
                    policy: .fetchCurrent,
                    capture: capture
                )
                guard snapshot.confirmsPurchaseEntitlement else {
                    throw RevenueCatClientError.purchaseStatusUnknown
                }
                return .purchased(snapshot)
            } catch {
                throw normalizedError(error)
            }
        default:
            throw normalizedError(providerError)
        }
    }

    func fetchAndApplyCustomerInfo(
        policy: CustomerInfoFetchPolicy,
        capture: IdentityCapture
    ) async throws -> EntitlementSnapshot {
        do {
            let customerInfo = try await provider.customerInfo(policy: policy)
            return try applyCustomerInfo(
                customerInfo,
                freshness: policy == .fetchCurrent ? .networkConfirmed : .cachePermitted,
                capture: capture
            )
        } catch {
            throw normalizedError(error)
        }
    }

    func applyCustomerInfo(
        _ customerInfo: ProviderCustomerInfo,
        freshness: SnapshotFreshness,
        capture: IdentityCapture
    ) throws -> EntitlementSnapshot {
        try validateCompletion(
            capture: capture,
            fetchedForAppUserID: customerInfo.fetchedForAppUserID
        )
        guard let configuration else {
            throw RevenueCatClientError.notConfigured
        }

        // Revocation grace is persisted state. An out-of-order response must not start or clear
        // its clock before the newer published snapshot wins the request-date comparison below.
        if let existing = state.entitlement,
           customerInfo.requestDate < existing.requestDate {
            return existing
        }

        let incoming = makeEntitlementSnapshot(
            from: customerInfo,
            entitlementID: configuration.premiumEntitlementID.rawValue,
            freshness: freshness,
            appUserID: capture.appUserID.rawValue
        )

        if let existing = state.entitlement {
            if incoming.requestDate == existing.requestDate {
                let mergedFreshness = incoming.freshness.strength > existing.freshness.strength
                    ? incoming.freshness
                    : existing.freshness
                let merged = incoming.withFreshness(mergedFreshness)
                introEligibilityCache.removeAll()
                if merged != existing {
                    publishProviderIdentity(entitlement: merged)
                }
                return merged
            }
        }

        introEligibilityCache.removeAll()
        publishProviderIdentity(entitlement: incoming)
        return incoming
    }

    func makeEntitlementSnapshot(
        from customerInfo: ProviderCustomerInfo,
        entitlementID: String,
        freshness: SnapshotFreshness,
        appUserID: String
    ) -> EntitlementSnapshot {
        guard let entitlement = customerInfo.entitlements[entitlementID] else {
            if let protectedSnapshot = revocationGrace.resolveMissingEntitlement(
                identity: appUserID,
                requestDate: customerInfo.requestDate,
                freshness: freshness
            ) {
                return protectedSnapshot
            }
            return .init(
                accessLevel: .free,
                billingCondition: .notApplicable,
                productID: nil,
                expirationDate: nil,
                willRenew: false,
                store: .unknown,
                isSandbox: false,
                requestDate: customerInfo.requestDate,
                freshness: freshness
            )
        }

        let accessLevel: AccessLevel
        let billingCondition: BillingCondition
        if !entitlement.isActiveInCurrentEnvironment {
            revocationGrace.recordConfirmedFree(identity: appUserID)
            accessLevel = .free
            billingCondition = .expired
        } else if entitlement.billingIssueDetectedAt != nil {
            revocationGrace.recordConfirmedPremium(identity: appUserID)
            accessLevel = .premiumInGracePeriod
            billingCondition = .billingIssueWhileActive
        } else if entitlement.unsubscribeDetectedAt != nil {
            revocationGrace.recordConfirmedPremium(identity: appUserID)
            accessLevel = .premium
            billingCondition = .cancelledButActive
        } else if entitlement.expirationDate == nil {
            revocationGrace.recordConfirmedPremium(identity: appUserID)
            accessLevel = .premium
            billingCondition = .notApplicable
        } else {
            revocationGrace.recordConfirmedPremium(identity: appUserID)
            accessLevel = .premium
            billingCondition = .healthy
        }

        return .init(
            accessLevel: accessLevel,
            billingCondition: billingCondition,
            productID: entitlement.productID,
            expirationDate: entitlement.expirationDate,
            willRenew: entitlement.willRenew,
            store: entitlement.store,
            isSandbox: entitlement.isSandbox,
            requestDate: customerInfo.requestDate,
            freshness: freshness
        )
    }

    @discardableResult
    func replaceOptions(
        for offering: ProviderOffering,
        scope: OfferingScope
    ) -> [PurchaseOption] {
        var installedOptionIDs: Set<PurchaseOptionID> = []
        let options = offering.packages.map { package in
            let optionID = PurchaseOptionID()
            installedOptionIDs.insert(optionID)
            optionHandles[optionID] = package.handle
            return PurchaseOption(
                id: optionID,
                packageType: package.packageType,
                localizedTitle: package.localizedTitle,
                localizedDescription: package.localizedDescription,
                price: package.price,
                localizedPrice: package.localizedPrice,
                currencyCode: package.currencyCode,
                subscriptionPeriod: package.subscriptionPeriod,
                introductoryOffer: package.introductoryOffer,
                productID: package.productID
            )
        }
        optionIDsByScope[scope] = installedOptionIDs
        return options
    }

    func removeOptions(for scope: OfferingScope) {
        guard let optionIDs = optionIDsByScope.removeValue(forKey: scope) else {
            return
        }
        var handles: Set<ProviderPackageHandle> = []
        for optionID in optionIDs {
            if let handle = optionHandles.removeValue(forKey: optionID) {
                handles.insert(handle)
            }
        }
        introEligibilityCache = introEligibilityCache.filter {
            !optionIDs.contains($0.key.optionID)
        }
        invalidateHandles(handles)
    }

    func performOfferingLoad(
        for scope: OfferingScope,
        generation: UInt64
    ) async throws -> OfferingLoadState {
        defer {
            if isCurrentOfferingGeneration(generation, for: scope) {
                offeringLoadTasks[scope] = nil
            }
        }

        let capture: IdentityCapture
        do {
            capture = try captureIdentity()
        } catch {
            return publishOfferingFailureIfCurrent(
                normalizedClientError(error),
                for: scope,
                generation: generation
            )
        }

        do {
            let result = try await provider.offering(for: placement(for: scope))
            if Task.isCancelled {
                discardProviderHandles(in: result.offering)
                throw CancellationError()
            }

            do {
                try validateCompletion(
                    capture: capture,
                    fetchedForAppUserID: result.fetchedForAppUserID
                )
            } catch {
                discardProviderHandles(in: result.offering)
                guard isCurrentOfferingGeneration(generation, for: scope) else {
                    return .idle
                }
                throw error
            }

            guard isCurrentOfferingGeneration(generation, for: scope),
                  state.identityAlignment == .matching else {
                discardProviderHandles(in: result.offering)
                return .idle
            }

            guard let offering = result.offering else {
                setOfferingState(.missing, for: scope)
                return .missing
            }
            guard !offering.packages.isEmpty else {
                setOfferingState(.empty, for: scope)
                return .empty
            }

            let snapshot = OfferingSnapshot(
                offeringID: offering.identifier,
                placement: placement(for: scope),
                purchaseOptions: replaceOptions(for: offering, scope: scope)
            )
            let available = OfferingLoadState.available(snapshot)
            setOfferingState(available, for: scope)
            return available
        } catch is CancellationError {
            if isCurrentOfferingGeneration(generation, for: scope) {
                setOfferingState(.idle, for: scope)
            }
            throw CancellationError()
        } catch RevenueCatClientError.identityChangedDuringOperation {
            if isCurrentOfferingGeneration(generation, for: scope) {
                setOfferingState(.idle, for: scope)
            }
            return .idle
        } catch {
            return publishOfferingFailureIfCurrent(
                normalizedClientError(error),
                for: scope,
                generation: generation
            )
        }
    }

    func publishOfferingFailureIfCurrent(
        _ error: RevenueCatClientError,
        for scope: OfferingScope,
        generation: UInt64
    ) -> OfferingLoadState {
        guard isCurrentOfferingGeneration(generation, for: scope) else {
            return .idle
        }
        let failed = OfferingLoadState.failed(error)
        setOfferingState(failed, for: scope)
        return failed
    }

    func setOfferingState(_ offeringState: OfferingLoadState, for scope: OfferingScope) {
        var offerings = state.offerings
        offerings[scope] = offeringState
        publish(offerings: offerings)
    }

    func nextOfferingGeneration(for scope: OfferingScope) -> UInt64 {
        let generation = (offeringGenerationByScope[scope] ?? 0) &+ 1
        offeringGenerationByScope[scope] = generation
        return generation
    }

    func isCurrentOfferingGeneration(_ generation: UInt64, for scope: OfferingScope) -> Bool {
        offeringGenerationByScope[scope] == generation
    }

    func placement(for scope: OfferingScope) -> PaywallPlacement? {
        switch scope {
        case .current:
            nil
        case .placement(let placement):
            placement
        }
    }

    func validatedScope(_ scope: OfferingScope) throws -> OfferingScope {
        switch scope {
        case .current:
            .current
        case .placement(let placement):
            .placement(try validatedPlacement(placement)!)
        }
    }

    func discardProviderHandles(in offering: ProviderOffering?) {
        guard let offering else { return }
        invalidateHandles(Set(offering.packages.map(\.handle)))
    }

    func invalidateHandles(_ handles: Set<ProviderPackageHandle>) {
        guard !handles.isEmpty else { return }
        var handlesToInvalidate = handles
        if let activePurchaseHandle,
           handlesToInvalidate.remove(activePurchaseHandle) != nil {
            deferredHandleInvalidations.insert(activePurchaseHandle)
        }
        if !handlesToInvalidate.isEmpty {
            provider.invalidateCachedHandles(handlesToInvalidate)
        }
    }

    func releaseActivePurchaseHandle(_ handle: ProviderPackageHandle) {
        guard activePurchaseHandle == handle else { return }
        activePurchaseHandle = nil
        guard !deferredHandleInvalidations.isEmpty else { return }
        provider.invalidateCachedHandles(deferredHandleInvalidations)
        deferredHandleInvalidations.removeAll()
    }

    func invalidateIdentityScopedState() {
        for task in offeringLoadTasks.values {
            task.cancel()
        }
        offeringLoadTasks.removeAll()
        let scopes = Set(offeringGenerationByScope.keys)
            .union(optionIDsByScope.keys)
            .union(state.offerings.keys)
        for scope in scopes {
            offeringGenerationByScope[scope] = (offeringGenerationByScope[scope] ?? 0) &+ 1
        }

        let handles = Set(optionHandles.values)
        optionHandles.removeAll()
        optionIDsByScope.removeAll()
        introEligibilityCache.removeAll()
        if activePurchaseHandle == nil {
            deferredHandleInvalidations.removeAll()
            provider.invalidateAllCachedHandles()
        } else {
            invalidateHandles(handles)
        }
    }

    func clearedOfferingStates() -> [OfferingScope: OfferingLoadState] {
        Dictionary(uniqueKeysWithValues: state.offerings.keys.map { ($0, .idle) })
    }

    func validated(_ desiredIdentity: DesiredIdentity) throws -> DesiredIdentity {
        if let configuration {
            let validated = try configuration.validated(desiredIdentity: desiredIdentity)
            guard let desiredIdentity = validated.desiredIdentity else {
                throw RevenueCatClientError.unknown
            }
            return desiredIdentity
        }
        switch desiredIdentity {
        case .anonymous:
            return .anonymous
        case .account(let appUserID):
            return .account(try AppUserID.validated(appUserID))
        }
    }

    func providerIdentityMatches(_ desiredIdentity: DesiredIdentity) -> Bool {
        switch desiredIdentity {
        case .anonymous:
            provider.isAnonymous == true
        case .account(let appUserID):
            provider.isAnonymous == false && provider.appUserID == appUserID.rawValue
        }
    }

    func scheduleIdentityReconciliationIfNeeded() {
        if case .failed = state.identityAlignment {
            return
        }
        guard sdkConfiguredByClient,
              !anonymousConfigurationFailed,
              !mutationInProgress,
              identityReconciliationTask == nil,
              let desiredIdentity = state.desiredIdentity,
              state.identityAlignment != .matching || !providerIdentityMatches(desiredIdentity) else {
            return
        }

        identityReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                identityReconciliationTask = nil
                scheduleIdentityReconciliationIfNeeded()
            }
            do {
                try await runRetainedMutation(operation: .identityChanging) { [self] in
                    try await performDesiredIdentityAlignment(desiredIdentity)
                }
            } catch is CancellationError {
                return
            } catch RevenueCatClientError.identityChangedDuringOperation {
                return
            } catch {
                // performDesiredIdentityAlignment publishes a normalized, retryable failure.
            }
        }
    }

    func installStreamObserverIfNeeded() {
        guard streamObservationTask == nil else { return }
        let stream = provider.customerInfoInvalidationStream()
        streamObservationTask = Task { @MainActor [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled else { break }
                streamRefreshPending = true
                startStreamRefreshIfNeeded()
            }
        }
    }

    func startStreamRefreshIfNeeded() {
        guard streamRefreshPending,
              !isInitialRefreshInFlight,
              streamRefreshTask == nil,
              sdkConfiguredByClient,
              !anonymousConfigurationFailed,
              state.identityAlignment == .matching,
              state.operation != .configuring,
              state.operation != .identityChanging else {
            return
        }

        streamRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while streamRefreshPending, !Task.isCancelled {
                streamRefreshPending = false
                await performStreamRefresh()
            }
            streamRefreshTask = nil
            if streamRefreshPending {
                startStreamRefreshIfNeeded()
            }
        }
    }

    func performStreamRefresh() async {
        do {
            let capture = try captureIdentity()
            _ = try await fetchAndApplyCustomerInfo(
                policy: .notStaleCachedOrFetched,
                capture: capture
            )
        } catch RevenueCatClientError.identityChangedDuringOperation {
            // An identity transition intentionally invalidated this internal re-read.
        } catch {
            logger.error("CustomerInfo stream re-read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func beginMutation(_ operation: OperationState) throws {
        guard !mutationInProgress else {
            throw RevenueCatClientError.operationInProgress
        }
        mutationInProgress = true
        publish(operation: operation)
    }

    func finishMutation() {
        mutationInProgress = false
        retainedMutationTask = nil
        publish(operation: .idle)
        startStreamRefreshIfNeeded()
        scheduleIdentityReconciliationIfNeeded()
    }

    func runRetainedMutation<Value: Sendable>(
        operation: OperationState,
        body: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try beginMutation(operation)
        let task = Task { @MainActor [weak self] () throws -> Value in
            guard let self else { throw CancellationError() }
            defer { finishMutation() }
            return try await body()
        }
        retainedMutationTask = task

        do {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    @discardableResult
    func requireConfigured() throws -> Configuration {
        if anonymousConfigurationFailed {
            throw RevenueCatClientError.anonymousIdentityUnavailable
        }
        guard sdkConfiguredByClient, let configuration else {
            throw RevenueCatClientError.notConfigured
        }
        return configuration
    }

    func captureIdentity() throws -> IdentityCapture {
        guard let rawAppUserID = provider.appUserID else {
            throw RevenueCatClientError.notConfigured
        }
        return .init(
            generation: identityGeneration,
            appUserID: .init(rawAppUserID)
        )
    }

    func requireStableReadIdentity() throws {
        switch state.operation {
        case .configuring, .identityChanging:
            throw RevenueCatClientError.operationInProgress
        case .idle, .purchasing, .restoring:
            break
        }
    }

    func requireAlignedIdentity() throws {
        switch state.identityAlignment {
        case .matching:
            return
        case .failed(let error):
            throw error
        case .transitioning:
            throw RevenueCatClientError.operationInProgress
        case .undeclared:
            throw RevenueCatClientError.identityOperationNotAllowed
        }
    }

    func validateCompletion(
        capture: IdentityCapture,
        fetchedForAppUserID: String? = nil
    ) throws {
        guard identityGeneration == capture.generation,
              provider.appUserID == capture.appUserID.rawValue,
              fetchedForAppUserID == nil || fetchedForAppUserID == capture.appUserID.rawValue else {
            throw RevenueCatClientError.identityChangedDuringOperation
        }
    }

    func validatedPlacement(_ placement: PaywallPlacement?) throws -> PaywallPlacement? {
        guard let placement else { return nil }
        let rawValue = placement.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            throw RevenueCatClientError.invalidConfiguration(.emptyPlacementID)
        }
        return .init(rawValue)
    }

    func publish(
        entitlement: EntitlementPublication = .preserve,
        operation: OperationState? = nil,
        currentAppUserID: AppUserID? = nil,
        isAnonymous: Bool? = nil,
        desiredIdentity: DesiredIdentity? = nil,
        identityAlignment: IdentityAlignment? = nil,
        offerings: [OfferingScope: OfferingLoadState]? = nil,
        distributionChannel: DistributionChannel? = nil
    ) {
        let publishedEntitlement: EntitlementSnapshot?
        switch entitlement {
        case .preserve:
            publishedEntitlement = state.entitlement
        case .replace(let value):
            publishedEntitlement = value
        }
        state = State(
            entitlement: publishedEntitlement,
            operation: operation ?? state.operation,
            currentAppUserID: currentAppUserID ?? state.currentAppUserID,
            isAnonymous: isAnonymous ?? state.isAnonymous,
            desiredIdentity: desiredIdentity ?? state.desiredIdentity,
            identityAlignment: identityAlignment ?? state.identityAlignment,
            offerings: offerings ?? state.offerings,
            distributionChannel: distributionChannel ?? state.distributionChannel
        )
    }

    func publishProviderIdentity(
        entitlement: EntitlementSnapshot?,
        identityAlignment: IdentityAlignment? = nil
    ) {
        publish(
            entitlement: .replace(entitlement),
            currentAppUserID: provider.appUserID.map { AppUserID($0) },
            isAnonymous: provider.isAnonymous,
            identityAlignment: identityAlignment,
            distributionChannel: distributionChannelProvider()
        )
    }

    func normalizedClientError(_ error: Error) -> RevenueCatClientError {
        normalizedError(error) as? RevenueCatClientError ?? .unknown
    }

    func normalizedError(_ error: Error) -> Error {
        if let error = error as? RevenueCatClientError {
            return error
        }
        guard let error = error as? ProviderError else {
            return error is CancellationError ? CancellationError() : RevenueCatClientError.unknown
        }
        switch error {
        case .network:
            return RevenueCatClientError.networkUnavailable
        case .purchaseNotAllowed, .productNotAvailable:
            return RevenueCatClientError.storeUnavailable
        case .purchaseInvalid, .invalidReceipt, .invalidAppUserID:
            return RevenueCatClientError.invalidPurchase
        case .logOutAnonymousUser:
            return RevenueCatClientError.identityOperationNotAllowed
        case .operationInProgress:
            return RevenueCatClientError.operationInProgress
        case .optionUnavailable:
            return RevenueCatClientError.optionUnavailable
        case .taskCancelled:
            return CancellationError()
        default:
            return RevenueCatClientError.unknown
        }
    }

    static func detectDistributionChannel() -> DistributionChannel {
        #if DEBUG
        return .debugSandbox
        #else
        guard let receiptURL = Bundle.main.appStoreReceiptURL else {
            return .unknown
        }
        if receiptURL.lastPathComponent == "sandboxReceipt" {
            return .testFlightSandbox
        }
        #if os(macOS)
        return .macOSProduction
        #else
        return .appStoreProduction
        #endif
        #endif
    }
}
