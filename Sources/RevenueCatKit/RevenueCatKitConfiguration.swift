import Foundation

/// RevenueCat 配置结构体
/// 项目只需要创建这个结构体的实例并传递给 RevenueCatViewModel
public struct RevenueCatKitConfiguration: Sendable {
    /// API Key
    public let apiKey: String
    /// 中国区代理地址
    public let chinaProxyURL: String?
    /// 权益 ID
    public let entitlementID: String
    /// 月度订阅产品 ID
    public let monthly: String
    /// 年度订阅产品 ID
    public let annual: String
    /// 终身买断产品 ID
    public let lifetime: String

    public init(
        apiKey: String,
        chinaProxyURL: String? = "https://api.rc-backup.com/",
        entitlementID: String,
        monthly: String,
        annual: String,
        lifetime: String
    ) {
        self.apiKey = apiKey
        self.chinaProxyURL = chinaProxyURL
        self.entitlementID = entitlementID
        self.monthly = monthly
        self.annual = annual
        self.lifetime = lifetime
    }
}

// MARK: - 预设配置

extension RevenueCatKitConfiguration {
    /// 开发环境的默认配置
    /// 用于新项目或暂时不需要真实 RevenueCat 配置的场景
    /// - Note: 这个配置使用虚拟值，不会连接到真实的 RevenueCat 服务
    public static var dev: RevenueCatKitConfiguration {
        return RevenueCatKitConfiguration(
            apiKey: "dev_example_api_key_1234567890",
            entitlementID: "premium",
            monthly: "com.example.app.monthly",
            annual: "com.example.app.annual",
            lifetime: "com.example.app.lifetime"
        )
    }
}
