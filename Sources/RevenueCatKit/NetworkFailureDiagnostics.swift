import Foundation

/// 仅用于诊断；不得依据网络子类改变权益或自动重试策略。
/// 不保存原始 NSError、userInfo、URL、描述或用户标识。
public struct NetworkFailureDiagnostics: Sendable, Equatable {
    public enum Category: String, Sendable, Equatable {
        case network
        case offline
        case endpointBlocked = "endpoint_blocked"
    }

    /// 有限的系统网络错误码白名单；未知码不透传。
    public enum TransportCode: Int, Sendable, Equatable {
        case cancelled = -999
        case timedOut = -1001
        case cannotFindHost = -1003
        case cannotConnectToHost = -1004
        case connectionLost = -1005
        case dnsLookupFailed = -1006
        case offline = -1009
        case roamingOff = -1018
        case callIsActive = -1019
        case dataNotAllowed = -1020
        case secureConnectionFailed = -1200
        case certificateHasBadDate = -1201
        case certificateUntrusted = -1202
        case certificateHasUnknownRoot = -1203
        case certificateNotYetValid = -1204
        case clientCertificateRejected = -1205
        case clientCertificateRequired = -1206
    }

    public let category: Category
    public let transportCode: TransportCode?

    public init(category: Category, transportCode: TransportCode? = nil) {
        self.category = category
        self.transportCode = transportCode
    }

    /// 可直接附加到宿主已有错误事件，键和值均来自有限集合。
    public var telemetryContext: [String: String] {
        var context = ["network_category": category.rawValue]
        if let transportCode {
            context["network_transport_domain"] = NSURLErrorDomain
            context["network_transport_code"] = String(transportCode.rawValue)
        }
        return context
    }
}

extension RevenueCatClientError {
    public var networkDiagnostics: NetworkFailureDiagnostics? {
        guard case .networkUnavailable(let diagnostics) = self else { return nil }
        return diagnostics
    }
}
