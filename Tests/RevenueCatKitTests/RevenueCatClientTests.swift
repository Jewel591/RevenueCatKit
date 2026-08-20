import XCTest
@testable import RevenueCatKit

@MainActor
final class RevenueCatClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        resetStandardRevocationGraceState()
    }
    func testConfigurationKeepsOnlyAppOwnedFacts() {
        let configuration = makeConfiguration()

        XCTAssertEqual(configuration.publicSDKKey.rawValue, "appl_test_key")
        XCTAssertEqual(configuration.premiumEntitlementID.rawValue, "premium")
        XCTAssertEqual(configuration.identityPolicy, .anonymousAndIdentified)
    }

    func testCompanyRuntimeDefaultsOwnConnectivityAndLogging() {
        let options = RevenueCatRuntimeOptions.companyDefault

        XCTAssertEqual(options.proxyURL?.absoluteString, "https://api.rc-backup.com/")
        #if DEBUG
            XCTAssertEqual(options.logLevel, .debug)
        #else
            XCTAssertEqual(options.logLevel, .warning)
        #endif
    }
}
