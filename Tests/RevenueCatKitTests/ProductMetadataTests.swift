import Foundation
import RevenueCat
import Testing
@testable import RevenueCatKit

@MainActor @Suite("Product and family-sharing metadata")
struct ProductMetadataTests {
    private func withClient(
        provider: FakeRevenueCatProvider,
        initial: ProviderCustomerInfo? = nil,
        body: (RevenueCatClient) async throws -> Void
    ) async throws {
        let suite = "RevenueCatKit.ProductMetadataTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        provider.appUserID = "user-a"; provider.isAnonymous = false
        provider.customerInfoResponses = [.success(initial ?? makeCustomerInfo(appUserID: "user-a"))]
        let client = RevenueCatClient(provider: provider, revocationGrace: .init(defaults: defaults))
        client.setDesiredIdentity(.account("user-a"))
        try await client.configure(makeConfiguration())
        try await body(client)
    }

    @Test("#21: Package duration does not infer renewal type or family-sharing eligibility")
    func independentProductMetadata() async throws {
        let provider = FakeRevenueCatProvider()
        var fixed = try #require(makeProviderOffering().packages.first)
        fixed.productKind = .nonRenewingSubscription; fixed.isFamilyShareable = false
        var renewing = try #require(makeProviderOffering().packages.first)
        renewing.productKind = .autoRenewableSubscription; renewing.isFamilyShareable = true
        provider.offeringValue = .init(identifier: "metadata-fixture", packages: [fixed, renewing])
        try await withClient(provider: provider) { client in
            guard case .available(let offering) = try await client.loadOffering() else {
                Issue.record("Expected the provider's offering"); return
            }
            let options = offering.purchaseOptions
            #expect(options.count == 2)
            #expect(options[0].packageType == options[1].packageType)
            #expect(options[0].productKind == .nonRenewingSubscription && options[0].isFamilyShareable == false)
            #expect(options[1].productKind == .autoRenewableSubscription && options[1].isFamilyShareable == true)
        }
    }

    @Test("#21: Missing product metadata remains unknown")
    func unknownMetadata() async throws {
        let provider = FakeRevenueCatProvider(); provider.offeringValue = makeProviderOffering()
        try await withClient(provider: provider) { client in
            let option = try #require(try await client.loadOffering().purchaseOptions.first)
            #expect(option.productKind == .unknown && option.isFamilyShareable == nil)
        }
    }

    @Test("#21: Family ownership is retained through refresh but cannot grant an inactive entitlement", arguments: [false, true])
    func familyOwnershipRequiresEntitlement(active: Bool) async throws {
        var entitlement = makeEntitlement(isActiveInCurrentEnvironment: active)
        entitlement.ownership = .familyShared
        let info = makeCustomerInfo(appUserID: "user-a", entitlement: entitlement)
        let provider = FakeRevenueCatProvider()
        try await withClient(provider: provider, initial: info) { client in
            #expect(client.state.entitlement?.ownership == .familyShared)
            #expect(client.state.accessLevel.grantsPremiumAccess == active)
            provider.customerInfoResponses = [.success(info)]
            let refreshed = try await client.forceRefresh()
            #expect(refreshed.ownership == .familyShared)
            #expect(refreshed.accessLevel.grantsPremiumAccess == active)
            #expect(refreshed.withFreshness(.cachePermitted).ownership == .familyShared)
        }
    }

    @Test("#21: The SDK product kinds map without product-ID or description inference",
        arguments: [
            (RevenueCat.StoreProduct.ProductType.consumable, ProductKind.consumable),
            (.nonConsumable, .nonConsumable),
            (.nonRenewableSubscription, .nonRenewingSubscription),
            (.autoRenewableSubscription, .autoRenewableSubscription)
        ])
    func sdkProductKinds(value: RevenueCat.StoreProduct.ProductType, expected: ProductKind) {
        #expect(value.companyValue == expected)
    }

    @Test("#21: SDK ownership preserves purchased, family-shared and unknown evidence",
        arguments: [
            (RevenueCat.PurchaseOwnershipType.purchased, PurchaseOwnership.purchased),
            (.familyShared, .familyShared),
            (.unknown, .unknown)
        ])
    func sdkOwnership(value: RevenueCat.PurchaseOwnershipType, expected: PurchaseOwnership) {
        #expect(value.companyValue == expected)
    }
}
