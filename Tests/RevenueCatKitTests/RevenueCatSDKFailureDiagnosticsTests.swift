import Foundation
import RevenueCat
import Testing
@testable import RevenueCatKit

@Suite(.serialized)
@MainActor
struct RevenueCatSDKFailureDiagnosticsTests {
    // #17: SDK configuration and backend failures must survive adapter normalization.
    @Test func configurationAndServiceFailuresRemainDistinct() {
        let adapter = RevenueCatSDKAdapter()
        #expect(adapter.mapError(sdkFailure(.configurationError))
            != adapter.mapError(sdkFailure(.unexpectedBackendResponseError)))
    }

    // #17: retain the finite StoreKit product-request timeout instead of generic unknown.
    @Test func productRequestTimeoutRemainsDistinctFromUnknown() {
        let adapter = RevenueCatSDKAdapter()
        #expect(adapter.mapError(sdkFailure(.productRequestTimedOut))
            != adapter.mapError(sdkFailure(.unknownError)))
    }

    // #17: the second normalization boundary must not discard known store evidence.
    @Test func storeFailureRemainsDistinctAtClientBoundary() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.offeringError = .storeProblem
        let storeFailure = try await client.loadOffering()
        provider.offeringError = .unknown(nil)
        #expect(storeFailure != (try await client.loadOffering()))
    }

    // #17: exact allowlisted codes cross both boundaries with the same unknown user result.
    @Test func finiteCodesReachOfferingFailures() async throws {
        let cases: [(ErrorCode, SDKFailureDiagnostics.Code)] = [
            (.configurationError, .configuration),
            (.invalidCredentialsError, .invalidCredentials),
            (.invalidAppleSubscriptionKeyError, .invalidAppleSubscriptionKey),
            (.unexpectedBackendResponseError, .unexpectedBackendResponse),
            (.unknownBackendError, .unknownBackend),
            (.productRequestTimedOut, .productRequestTimedOut),
            (.storeProblemError, .storeProblem),
            (.productAlreadyPurchasedError, .productAlreadyPurchased)
        ]
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        for (sdkCode, code) in cases {
            provider.offeringError = RevenueCatSDKAdapter().mapError(sdkFailure(sdkCode))
            let failure = try await client.loadOffering()
            #expect(failure == .failed(.unknown(.init(code: code))))
            #expect(client.state.offerings[.current] == failure)
            #expect(failure.purchaseOptions.isEmpty)
            #expect(client.state.accessLevel == .free)
        }
    }

    // #17: the SDK wraps product-request timeouts as configuration errors; preserve both facts.
    @Test func directUnderlyingSDKCodeIsBounded() {
        let wrapped = NSError(domain: (ErrorCode.configurationError as NSError).domain,
                              code: ErrorCode.configurationError.rawValue,
                              userInfo: [NSUnderlyingErrorKey: sdkFailure(.productRequestTimedOut)])
        #expect(RevenueCatSDKAdapter().mapError(wrapped)
            == .unknown(.init(code: .configuration, underlyingCode: .productRequestTimedOut)))
        let hostile = NSError(domain: (ErrorCode.configurationError as NSError).domain,
                              code: ErrorCode.configurationError.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(
                                domain: "private-user", code: ErrorCode.productRequestTimedOut.rawValue)])
        #expect(RevenueCatSDKAdapter().mapError(hostile) == .unknown(.init(code: .configuration)))
        #expect(SDKFailureDiagnostics(code: .configuration, underlyingCode: .productRequestTimedOut)
            .telemetryContext == ["sdk_error_category": "configuration",
                                  "sdk_error_code": "configuration",
                                  "sdk_underlying_error_code": "product_request_timed_out"])
    }

    // #17: absence of evidence must never be turned into a configuration or network diagnosis.
    @Test func unknownAndUnrelatedErrorsHaveNoSDKDiagnosis() {
        let adapter = RevenueCatSDKAdapter()
        #expect(adapter.mapError(sdkFailure(.unknownError)) == .unknown(nil))
        #expect(adapter.mapError(sdkFailure(.invalidWebPurchaseToken)) == .unknown(nil))
        #expect(adapter.mapError(NSError(domain: "arbitrary", code: 23)) == .unknown(nil))
        #expect(adapter.mapError(NSError(domain: (ErrorCode.configurationError as NSError).domain,
                                        code: 987654321)) == .unknown(nil))
        #expect(RevenueCatClientError.unknown(nil).sdkDiagnostics == nil)
        #expect(RevenueCatClientError.networkUnavailable(.init(category: .network)).sdkDiagnostics == nil)
        #expect(adapter.mapError(CancellationError()) == .taskCancelled)
        #expect(adapter.mapError(sdkFailure(.purchaseCancelledError)) == .purchaseCancelled)
        #expect(adapter.mapError(sdkFailure(.paymentPendingError)) == .paymentPending)
    }

    // #17: the same error instance must reach configure, refresh, purchase, restore and eligibility.
    @Test func sharedFailureExitsPreserveDiagnosticWithoutRetries() async throws {
        let failure = RevenueCatSDKAdapter().mapError(sdkFailure(.unexpectedBackendResponseError))
        let expected = RevenueCatClientError.unknown(.init(code: .unexpectedBackendResponse))
        let configuring = FakeRevenueCatProvider()
        configuring.appUserID = "diagnostic-test"
        configuring.isAnonymous = false
        configuring.customerInfoResponses = [.failure(failure)]
        let configuringClient = RevenueCatClient(provider: configuring)
        configuringClient.setDesiredIdentity(.account("diagnostic-test"))
        await expectFailure(expected) { try await configuringClient.configure(makeConfiguration()) }
        #expect(configuringClient.state.identityAlignment == .failed(expected))
        #expect(configuring.customerInfoPolicies.count == 1)

        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        provider.customerInfoResponses = [.failure(failure)]
        await expectFailure(expected) { _ = try await client.forceRefresh() }
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering() else {
            Issue.record("Expected offering")
            return
        }
        let option = offering.purchaseOptions[0].id
        provider.eligibilityError = failure
        await expectFailure(expected) { _ = try await client.checkIntroEligibility(for: option) }
        provider.purchaseResponse = .failure(failure)
        await expectFailure(expected) { _ = try await client.purchase(option) }
        provider.restoreResponse = .failure(failure)
        await expectFailure(expected) { _ = try await client.restorePurchases() }
        #expect(provider.customerInfoPolicies.count == 2)
        #expect(provider.eligibilityCallCount == 1)
        #expect(provider.purchaseCallCount == 1)
        #expect(provider.restoreCallCount == 1)
        #expect(client.state.accessLevel == .free)
        #expect(client.state.operation == .idle)
        #expect(expected.sdkDiagnostics?.telemetryContext == [
            "sdk_error_category": "service", "sdk_error_code": "unexpected_backend_response"
        ])
    }

    private func expectFailure(_ expected: RevenueCatClientError,
                               operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected normalized failure")
        } catch let error as RevenueCatClientError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private func sdkFailure(_ code: ErrorCode) -> NSError {
    NSError(domain: (code as NSError).domain, code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "private-user receipt-secret",
                       NSURLErrorFailingURLErrorKey: "https://example.com/private-user"])
}
