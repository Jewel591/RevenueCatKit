import Foundation

/// SDK 明确报告的有限分类，仅用于诊断，不代表已确认最终根因。
/// 不保存原始错误、描述、URL、userInfo、账户或收据。
public struct SDKFailureDiagnostics: Sendable, Equatable {
    public enum Code: String, Sendable, Equatable, CaseIterable {
        case configuration = "configuration"
        case invalidCredentials = "invalid_credentials"
        case invalidAppleSubscriptionKey = "invalid_apple_subscription_key"
        case unexpectedBackendResponse = "unexpected_backend_response"
        case unknownBackend = "unknown_backend"
        case productRequestTimedOut = "product_request_timed_out"
        case storeProblem = "store_problem"
        case productAlreadyPurchased = "product_already_purchased"

        public var category: Category {
            switch self {
            case .configuration, .invalidCredentials, .invalidAppleSubscriptionKey:
                .configuration
            case .unexpectedBackendResponse, .unknownBackend:
                .service
            case .productRequestTimedOut, .storeProblem, .productAlreadyPurchased:
                .store
            }
        }
    }

    public enum Category: String, Sendable, Equatable {
        case configuration
        case service
        case store
    }

    public let code: Code
    public let underlyingCode: Code?

    public init(code: Code, underlyingCode: Code? = nil) {
        self.code = code
        self.underlyingCode = underlyingCode
    }

    /// 只合并到宿主已有错误事件；不能据此改变权益、重试或用户文案。
    public var telemetryContext: [String: String] {
        var context = ["sdk_error_category": code.category.rawValue, "sdk_error_code": code.rawValue]
        if let underlyingCode {
            context["sdk_underlying_error_code"] = underlyingCode.rawValue
        }
        return context
    }
}

extension RevenueCatClientError {
    public var sdkDiagnostics: SDKFailureDiagnostics? {
        guard case .unknown(let diagnostics) = self else { return nil }
        return diagnostics
    }
}
