import Foundation
import RevenueCat
import Testing
@testable import RevenueCatKit

@Suite(.serialized)
@MainActor
struct RevenueCatNetworkDiagnosticsTests {
    // #15 / coworkers#391: SDK network subclasses must survive the first mapping boundary.
    @Test func sdkNetworkSubclassesRemainDistinct() {
        let adapter = RevenueCatSDKAdapter()
        let errors = [ErrorCode.networkError, .offlineConnectionError, .apiEndpointBlockedError]
            .map { adapter.mapError(sdkError($0)) }
        #expect(errors[0] != errors[1])
        #expect(errors[0] != errors[2])
        #expect(errors[1] != errors[2])
    }

    // #15: timeout and DNS failures currently collapse to the same network error.
    @Test func underlyingTransportCodesRemainDistinct() {
        let adapter = RevenueCatSDKAdapter()
        let timeout = adapter.mapError(sdkError(.networkError, transportCode: NSURLErrorTimedOut))
        let dns = adapter.mapError(sdkError(.networkError, transportCode: NSURLErrorCannotFindHost))
        #expect(timeout != dns)
    }

    // #15: no raw message, URL, arbitrary domain or unknown integer may escape.
    @Test func telemetryContainsOnlyAllowlistedValues() throws {
        let adapter = RevenueCatSDKAdapter()
        let mapped = adapter.mapError(sdkError(.networkError, transportCode: NSURLErrorTimedOut))
        guard case .network(let diagnostics) = mapped else {
            Issue.record("Expected a network failure")
            return
        }
        #expect(diagnostics.telemetryContext == [
            "network_category": "network",
            "network_transport_domain": NSURLErrorDomain,
            "network_transport_code": "-1001"
        ])
        let hostile = NSError(
            domain: (ErrorCode.networkError as NSError).domain,
            code: ErrorCode.networkError.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: "private@example.com", code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: "receipt-secret"]
            )]
        )
        #expect(adapter.mapError(hostile) == .network(.init(category: .network)))
        #expect(adapter.mapError(sdkError(.networkError, transportCode: 987654321))
            == .network(.init(category: .network)))
        #expect(adapter.mapError(sdkError(.offlineConnectionError))
            == .network(.init(category: .offline)))
        #expect(adapter.mapError(sdkError(.apiEndpointBlockedError))
            == .network(.init(category: .endpointBlocked)))
    }

    // #15: configure must throw the same user-result category and retain diagnostics in state.
    @Test func configurePreservesFailureAndDoesNotRetry() async {
        let provider = FakeRevenueCatProvider()
        provider.appUserID = "diagnostic-test"
        provider.isAnonymous = false
        let diagnostics = NetworkFailureDiagnostics(category: .offline)
        provider.customerInfoResponses = [.failure(.network(diagnostics))]
        let client = RevenueCatClient(provider: provider)
        client.setDesiredIdentity(.account("diagnostic-test"))
        await expectNetwork(diagnostics) { try await client.configure(makeConfiguration()) }
        #expect(client.state.identityAlignment == .failed(.networkUnavailable(diagnostics)))
        #expect(client.state.accessLevel == .unknown)
        #expect(provider.customerInfoPolicies.count == 1)
        #expect(client.state.operation == .idle)
    }

    // #15: every existing consuming path keeps its previous failure/access behavior.
    @Test func refreshOfferingPurchaseRestoreAndEligibilityCarryDiagnostics() async throws {
        let provider = FakeRevenueCatProvider()
        let client = try await makeConfiguredClient(provider: provider)
        let diagnostics = NetworkFailureDiagnostics(category: .network, transportCode: .timedOut)
        let failure = RevenueCatSDKAdapter().mapError(
            sdkError(.networkError, transportCode: NSURLErrorTimedOut)
        )
        provider.customerInfoResponses = [.failure(failure)]
        await expectNetwork(diagnostics) { _ = try await client.forceRefresh() }
        #expect(client.state.accessLevel == .free)
        #expect(provider.customerInfoPolicies.count == 2)

        provider.offeringError = failure
        let failedOffering = try await client.loadOffering()
        #expect(failedOffering == .failed(.networkUnavailable(diagnostics)))
        #expect(client.state.offerings[.current] == failedOffering)

        provider.offeringError = nil
        provider.offeringValue = makeProviderOffering()
        guard case .available(let offering) = try await client.loadOffering() else {
            Issue.record("Expected offering")
            return
        }
        let option = offering.purchaseOptions[0].id
        provider.eligibilityError = failure
        await expectNetwork(diagnostics) { _ = try await client.checkIntroEligibility(for: option) }
        provider.purchaseResponse = .failure(failure)
        await expectNetwork(diagnostics) { _ = try await client.purchase(option) }
        provider.restoreResponse = .failure(failure)
        await expectNetwork(diagnostics) { _ = try await client.restorePurchases() }
        #expect(provider.eligibilityCallCount == 1)
        #expect(provider.purchaseCallCount == 1)
        #expect(provider.restoreCallCount == 1)
        #expect(client.state.accessLevel == .free)
        #expect(client.state.operation == .idle)
    }

    // #15: diagnostic enrichment must not convert cancellation/store errors into network failures.
    @Test func unrelatedErrorsKeepTheirResults() {
        let adapter = RevenueCatSDKAdapter()
        #expect(adapter.mapError(CancellationError()) == .taskCancelled)
        #expect(adapter.mapError(sdkError(.purchaseCancelledError)) == .purchaseCancelled)
        #expect(adapter.mapError(sdkError(.purchaseNotAllowedError)) == .purchaseNotAllowed)
        #expect(RevenueCatClientError.storeUnavailable.networkDiagnostics == nil)
    }

    private func expectNetwork(
        _ expected: NetworkFailureDiagnostics,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("Expected networkUnavailable")
        } catch let error as RevenueCatClientError {
            guard case .networkUnavailable = error else {
                Issue.record("Unexpected user-result category: \(error)")
                return
            }
            #expect(error.networkDiagnostics == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private func sdkError(_ code: ErrorCode, transportCode: Int? = nil) -> NSError {
    let domain = (code as NSError).domain
    var info: [String: Any] = [NSLocalizedDescriptionKey: "private@example.com receipt-secret"]
    if let transportCode {
        info[NSUnderlyingErrorKey] = NSError(
            domain: NSURLErrorDomain,
            code: transportCode,
            userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/private-user-id")!]
        )
    }
    return NSError(domain: domain, code: code.rawValue, userInfo: info)
}
