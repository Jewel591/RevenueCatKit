import Foundation
import XCTest
@testable import RevenueCatKit

func resetStandardRevocationGraceState() {
    for key in UserDefaults.standard.dictionaryRepresentation().keys
    where key.hasPrefix("RevenueCatKit.revocationGrace.v2.") {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

@MainActor
func seedPersistedAccount(
    _ provider: FakeRevenueCatProvider,
    appUserID: String = "user-a"
) {
    provider.appUserID = appUserID
    provider.isAnonymous = false
}

func makeConfiguration(
    identityPolicy: RevenueCatClient.IdentityPolicy = .anonymousAndIdentified
) -> RevenueCatClient.Configuration {
    .init(
        publicSDKKey: "appl_test_key",
        premiumEntitlementID: "premium",
        identityPolicy: identityPolicy
    )
}

@MainActor
func makeConfiguredClient(
    provider: FakeRevenueCatProvider,
    initialCustomerInfo: ProviderCustomerInfo? = nil,
    distributionChannel: DistributionChannel = .debugSandbox
) async throws -> RevenueCatClient {
    if let initialCustomerInfo {
        provider.customerInfoResponses = [.success(initialCustomerInfo)]
    } else if provider.customerInfoResponses.isEmpty {
        provider.customerInfoResponses = [.success(makeCustomerInfo(appUserID: "user-a"))]
    }
    if provider.appUserID == nil {
        provider.appUserID = "user-a"
        provider.isAnonymous = false
    }
    let client = RevenueCatClient(
        provider: provider,
        distributionChannelProvider: { distributionChannel }
    )
    client.setDesiredIdentity(.account("user-a"))
    try await client.configure(makeConfiguration())
    return client
}

@MainActor
func assertClientError(
    _ expected: RevenueCatClientError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected), but the operation succeeded", file: file, line: line)
    } catch let error as RevenueCatClientError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}

func waitUntil(
    maxYields: Int = 200,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<maxYields {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
