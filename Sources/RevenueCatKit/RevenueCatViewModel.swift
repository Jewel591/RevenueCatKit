// MARK: - 更新记录

// 2026-08-16
// - 恢复：曾确认会员突然收到空 entitlement 时进入 7 天降级宽限，
//   且 restore 按宽限后的有效会员状态返回。Key 与 CodeCat 旧 build 对齐，
//   避免覆盖 cachedPremiumAccess 后回滚也无法再进入宽限。

// 2026-03-27
// - 新增：#if DEBUG 的 setPreviewPremiumAccess(_:status:)，用于 SwiftUI Preview 模拟会员状态

// 2026-02-21
// - 重构：从 BodyWatch 项目迁移为独立 SPM Package
// - 重构：移除硬编码配置，改用 configure(config:) 注入模式

// 2025-01-24 (2)
// - 修复：purchase() 错误处理改用 RevenueCat.ErrorCode 枚举，移除魔法数字
// - 修复：purchase() 和 restorePurchases() 添加 waitForInitialization() 等待机制
// - 新增：waitForInitialization() 方法，确保初始化完成后再执行购买操作

// 2025-01-24
// - 同步 MONO 项目的改进
// - 修复：configureRevenueCat() 改为同步调用，避免快捷指令触发时崩溃
// - 修复：提取 updateSubscriptionStatus(from:) 方法，购买/恢复后直接使用返回的 CustomerInfo
// - 修复：refreshSubscriptionStatus() 添加配置完成等待机制，防止竞态条件
// - 新增：使用 UserDefaults 缓存会员状态，解决启动时短暂显示"免费用户"的问题
// - 修复：缓存恢复时只设置 hasPremiumAccess，不假设订阅类型
// - 修复：移除 updateSubscriptionStatus 中重复的 hasPremiumAccess 设置
// - 修复：权益过期时正确更新缓存
// - 修复：triggerSubscriptionPageAnimation 改用 withAnimation + Task.sleep
// - 修复：网络失败或超时时保留当前状态，避免付费用户被误判
// - 修复：购买取消识别使用 error.localizedDescription 判断，避免类型转换失败
// - 修复：未知产品 ID 但权益活跃时视为有效会员（使用 .lifetime）
// - 修复：终身买断分支清理 expirationDate
// - 修复：initialize() 添加 isInitializing 防止并发重入
// - 修复：configurationContinuations 改为数组，支持多个并发等待者
// - 修复：refreshSubscriptionStatus() 在 closure 内部检查配置状态，避免竞态

// Re-export RevenueCat so host Apps can use Package / StoreProduct / PackageType
// through `import RevenueCatKit` only. Direct `import RevenueCat` is not part of
// the supported host integration surface.
@_exported import RevenueCat
import StoreKit
import SwiftUI
import os

/// RevenueCat集成管理器，处理订阅、购买和恢复相关的业务逻辑
///
/// ## 使用示例
///
/// ### 1. 在 App 入口配置
/// ```swift
/// // BodyWatchApp.swift init()
/// RevenueCatViewModel.configure(config: .init(
///     apiKey: "your_api_key",
///     entitlementID: "Pro",
///     monthly: "com.app.monthly",
///     annual: "com.app.annual",
///     lifetime: "com.app.lifetime"
/// ))
/// ```
///
/// ### 2. 在需要权限检查的 View 中引用
/// ```swift
/// struct SomeView: View {
///     private var revenueCatViewModel = RevenueCatViewModel.shared
/// }
/// ```
///
/// ### 3. 在 Button 或其他交互中检查权限
/// ```swift
/// Button("高级功能") {
///     if revenueCatViewModel.checkPremiumAccessOrShowPaywall() {
///         performAdvancedAction()
///     }
/// }
/// ```
///
/// ### 4. 在 ContentView 中配置付费墙
/// ```swift
/// struct ContentView: View {
///     @Bindable private var revenueCatViewModel = RevenueCatViewModel.shared
///
///     var body: some View {
///         TabView()
///             .fullScreenCover(isPresented: $revenueCatViewModel.showPaywall) {
///                 SubscriptionView()
///             }
///     }
/// }
/// ```
///
@Observable
@MainActor
public final class RevenueCatViewModel {
    // MARK: - Properties

    /// 当前可用的产品套餐
    public private(set) var offerings: Offerings?

    /// 用户是否有高级权限
    /// - nil: 正在加载状态，尚未确定
    /// - true: 已确认有高级权限
    /// - false: 已确认无高级权限
    public private(set) var hasPremiumAccess: Bool? = nil

    /// 缓存的会员状态（使用 UserDefaults 持久化）
    /// 用于 App 启动时立即显示正确的会员状态，避免闪烁
    @ObservationIgnored
    private var cachedPremiumAccess: Bool {
        get { UserDefaults.standard.bool(forKey: "cachedPremiumAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "cachedPremiumAccess") }
    }

    /// 标记是否曾经同步过会员状态（用于判断缓存是否有效）
    @ObservationIgnored
    private var hasSyncedBefore: Bool {
        get { UserDefaults.standard.bool(forKey: "hasSyncedPremiumAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "hasSyncedPremiumAccess") }
    }

    /// 首次观测到已确认会员被服务端撤销的时间。`0` 表示当前不在宽限观察中。
    /// Key 必须与 CodeCat 旧 build 一致。
    @ObservationIgnored
    private var revocationFirstSeenAt: TimeInterval {
        get { UserDefaults.standard.double(forKey: PremiumRevocationGrace.firstSeenAtKey) }
        set { UserDefaults.standard.set(newValue, forKey: PremiumRevocationGrace.firstSeenAtKey) }
    }

    /// 当前订阅状态
    public private(set) var subscriptionStatus: SubscriptionStatus = .none

    /// 订阅到期日期
    public private(set) var expirationDate: Date?

    /// 日志记录器
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.app.revenuecat",
        category: "RevenueCat"
    )

    /// 标记是否已初始化
    private var isInitialized = false

    /// 标记是否正在初始化（防止并发重入）
    private var isInitializing = false

    /// 交易监听任务（用于管理生命周期）
    private var transactionListenerTask: Task<Void, Never>?

    /// 配置完成的 Continuations（支持多个并发等待者）
    private var configurationContinuations: [CheckedContinuation<Void, Never>] = []

    /// 初始化完成的 Continuations（支持多个并发等待者）
    private var initializationContinuations: [CheckedContinuation<Void, Never>] = []

    /// 控制付费墙显示
    public var showPaywall = false

    /// 控制订阅页面内容动画
    public var subscriptionContentAppeared = false

    /// 是否应该显示营销广告
    /// - 仅在确认用户没有高级权限时才显示广告
    /// - 加载中时不显示，避免闪烁
    public var shouldShowAds: Bool {
        return hasPremiumAccess == false
    }

    // MARK: - Singleton

    /// 单例实例
    public static let shared = RevenueCatViewModel()

    /// 注入的配置（通过 configure(config:) 设置）
    private var config: RevenueCatKitConfiguration?

    /// 检查是否已配置 RevenueCat
    private var isRevenueCatConfigured = false

    /// 订阅状态枚举
    public enum SubscriptionStatus: String, Sendable {
        case none = "无订阅"
        case monthly = "月度订阅"
        case annual = "年度订阅"
        case lifetime = "永久买断"

        public var displayName: String {
            return self.rawValue
        }

        /// 获取对应会员类型的徽章颜色
        public var badgeColor: Color {
            switch self {
            case .none:
                return .gray
            case .monthly, .annual:
                return .blue
            case .lifetime:
                return .purple
            }
        }

        /// 获取简短的会员状态标签
        public var badgeText: String {
            switch self {
            case .none:
                return "免费版"
            case .monthly, .annual:
                return "高级会员"
            case .lifetime:
                return "永久会员"
            }
        }
    }

    // MARK: - Configuration

    /// 配置 RevenueCat SDK（必须在 App 启动时调用）
    ///
    /// ```swift
    /// // BodyWatchApp.swift init()
    /// RevenueCatViewModel.configure(config: .init(
    ///     apiKey: "appl_xxx",
    ///     entitlementID: "Pro",
    ///     monthly: "",
    ///     annual: "com.app.annual",
    ///     lifetime: "com.app.lifetime"
    /// ))
    /// ```
    public static func configure(config: RevenueCatKitConfiguration) {
        shared.config = config
        shared.startConfiguration()
    }

    // MARK: - Initialization

    /// 私有初始化方法，防止外部直接创建实例
    private init() {
        // 立即从缓存加载会员状态（避免启动时闪烁）
        // 注意：只设置 hasPremiumAccess，不设置 subscriptionStatus
        // 因为缓存只存储了 Bool 值，无法准确判断具体订阅类型
        if hasSyncedBefore {
            hasPremiumAccess = cachedPremiumAccess
        }
    }

    /// 开始配置流程（configure 调用后触发）
    private func startConfiguration() {
        configureRevenueCat()

        Task { @MainActor in
            await self.initialize()
        }
    }

    /// 配置 RevenueCat SDK（同步方法，确保配置完成后再返回）
    private func configureRevenueCat() {
        guard !isRevenueCatConfigured else { return }
        guard let config else {
            logger.error("RevenueCat 配置未设置，请先调用 RevenueCatViewModel.configure(config:)")
            return
        }

        // 默认关闭 RevenueCat 的详细调试日志，避免运行时控制台被 SDK 噪音淹没
        Purchases.logLevel = .warn

        // 配置 RevenueCat SDK（这是一个同步操作）
        if let proxyURL = config.chinaProxyURL {
            Purchases.proxyURL = URL(string: proxyURL)
        }
        Purchases.configure(withAPIKey: config.apiKey)

        isRevenueCatConfigured = true

        // 恢复所有等待配置完成的 continuations
        let waitingContinuations = configurationContinuations
        configurationContinuations.removeAll()
        for continuation in waitingContinuations {
            continuation.resume()
        }
        if !waitingContinuations.isEmpty {
            logger.debug("已恢复 \(waitingContinuations.count) 个等待配置的调用")
        }
    }

    /// 初始化管理器
    public func initialize() async {
        // 防止并发重入：检查是否已初始化或正在初始化
        guard !isInitialized, !isInitializing else { return }

        // 立即标记为正在初始化，防止后续并发调用进入
        isInitializing = true

        // 加载产品信息
        await loadOfferings()

        // 检查当前订阅状态
        await refreshSubscriptionStatus()

        // 设置交易监听器
        setupTransactionListener()

        isInitialized = true
        isInitializing = false

        // 恢复所有等待初始化完成的 continuations
        let waitingContinuations = initializationContinuations
        initializationContinuations.removeAll()
        for continuation in waitingContinuations {
            continuation.resume()
        }
        if !waitingContinuations.isEmpty {
            logger.debug("已恢复 \(waitingContinuations.count) 个等待初始化的调用")
        }

    }

    /// 等待初始化完成
    /// 如果已初始化则立即返回，否则等待初始化完成
    private func waitForInitialization() async {
        guard !isInitialized else { return }

        logger.debug("等待初始化完成...")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 双重检查：可能在等待期间已完成初始化
            if isInitialized {
                continuation.resume()
                return
            }
            initializationContinuations.append(continuation)
        }

        logger.debug("初始化已完成，继续执行")
    }

    // MARK: - Public Methods

    /// 加载 RevenueCat 产品列表
    public func loadOfferings() async {
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            logger.error("加载 RevenueCat 产品失败: \(error.localizedDescription)")
        }
    }

    /// 购买指定套餐
    public func purchase(package: Package) async throws -> Bool {
        try await purchaseWithOutcome(package: package) == .success
    }

    /// 购买结果细分。Bool 版 `purchase(package:)` 把「用户取消」「支付待批准」
    /// 「交易完成但权益未激活」都折叠成 false——取消应静默，但后两种 UI 必须
    /// 明确反馈（用户可能已付款）。需要区分时用本方法。
    public enum PurchaseOutcome: Sendable, Equatable {
        /// 权益已激活
        case success
        /// 用户主动取消（UI 应保持静默）
        case cancelled
        /// 支付待处理（如家人共享 Ask to Buy 待批准），权益会在批准后到账
        case pending
        /// 交易未被取消也未报错，但目标权益未激活（异常态，提示恢复购买/联系支持）
        case notEntitled
    }

    public func purchaseWithOutcome(package: Package) async throws -> PurchaseOutcome {
        guard let config else { return .notEntitled }

        logger.info("开始购买套餐: \(package.identifier)")

        // 确保初始化完成
        await waitForInitialization()

        do {
            let result = try await Purchases.shared.purchase(package: package)

            // 直接使用 purchase 返回的最新 customerInfo 更新状态
            updateSubscriptionStatus(from: result.customerInfo)

            if result.customerInfo.entitlements[config.entitlementID]?.isActive == true {
                logger.info("成功购买套餐: \(package.identifier)")
                showPaywall = false
                return .success
            }
            if result.userCancelled {
                logger.info("用户取消购买")
                return .cancelled
            }
            logger.warning("购买套餐未激活权限: \(package.identifier)")
            return .notEntitled
        } catch let error as ErrorCode {
            switch error {
            case .purchaseCancelledError:
                logger.info("用户取消购买")
                return .cancelled

            case .paymentPendingError:
                logger.info("支付待处理（例如家人共享待批准）")
                return .pending

            case .productNotAvailableForPurchaseError:
                logger.error("产品不可购买: \(error.localizedDescription)")
                throw error

            case .purchaseInvalidError:
                logger.error("购买无效: \(error.localizedDescription)")
                throw error

            default:
                logger.error("购买失败 (RevenueCat 错误: \(error)): \(error.localizedDescription)")
                throw error
            }
        } catch let error as SKError where error.code == .paymentCancelled {
            logger.info("用户取消购买（StoreKit）")
            return .cancelled
        } catch {
            logger.error("购买套餐失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 恢复购买
    public func restorePurchases() async throws -> Bool {
        guard config != nil else { return false }

        logger.info("开始恢复购买")

        // 确保初始化完成
        await waitForInitialization()

        do {
            let customerInfo = try await Purchases.shared.restorePurchases()

            updateSubscriptionStatus(from: customerInfo)

            // 用更新后的有效会员状态（含降级宽限期）判定成功与否，
            // 而不是原始 CustomerInfo：宽限期内用户实际保有权益，
            // 若按原始数据返回 false，会出现「提示恢复失败但会员仍在」的矛盾反馈
            let success = hasPremiumAccess == true
            if success {
                logger.info("成功恢复购买")
                showPaywall = false
            } else {
                logger.info("恢复购买未找到活跃订阅")
            }

            return success
        } catch {
            logger.error("恢复购买失败: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Helper Methods

    /// 刷新用户会员信息（公开方法，用于下拉刷新）
    public func refreshCustomerInfo() async {
        await refreshSubscriptionStatus()
    }

    /// 使用提供的 CustomerInfo 更新订阅状态
    private func updateSubscriptionStatus(from customerInfo: CustomerInfo) {
        guard let config else { return }

        // 检查是否有活跃权限
        let isActive = customerInfo.entitlements[config.entitlementID]?.isActive == true

        let grace = PremiumRevocationGrace.outcome(
            isEntitlementActive: isActive,
            hasSyncedBefore: hasSyncedBefore,
            cachedPremiumAccess: cachedPremiumAccess,
            firstSeenAt: revocationFirstSeenAt,
            now: Date().timeIntervalSince1970
        )
        revocationFirstSeenAt = grace.storedFirstSeenAt
        if !grace.shouldApplyServerStatus {
            hasPremiumAccess = true
            logger.warning("服务端撤销了已确认的会员权益，处于 7 天降级宽限期内，保持会员状态")
            return
        }

        hasPremiumAccess = isActive
        cachedPremiumAccess = isActive
        hasSyncedBefore = true

        // 确定订阅类型
        if let entitlement = customerInfo.entitlements[config.entitlementID] {
            logger.debug(
                "发现 Pro 权益, 产品 ID: \(entitlement.productIdentifier), 到期时间: \(entitlement.expirationDate?.description ?? "永久")"
            )

            if entitlement.isActive {
                let productId = entitlement.productIdentifier

                if !config.lifetime.isEmpty && productId == config.lifetime {
                    subscriptionStatus = .lifetime
                    expirationDate = nil
                } else if !config.annual.isEmpty && productId == config.annual {
                    subscriptionStatus = .annual
                    expirationDate = entitlement.expirationDate
                } else if !config.monthly.isEmpty && productId == config.monthly {
                    subscriptionStatus = .monthly
                    expirationDate = entitlement.expirationDate
                } else {
                    // 未知产品 ID 但权益活跃，视为有效会员
                    subscriptionStatus = .lifetime
                    expirationDate = nil
                    logger.warning(
                        "未知的产品标识符: \(entitlement.productIdentifier)，已视为有效会员"
                    )
                }
            } else {
                subscriptionStatus = .none
                expirationDate = nil
            }
        } else {
            subscriptionStatus = .none
            expirationDate = nil
        }
    }

    /// 刷新用户订阅状态（从服务器获取最新数据）
    public func refreshSubscriptionStatus() async {
        // 确保 RevenueCat 已配置（防止竞态条件）
        if !isRevenueCatConfigured {
            let configuredInTime = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        Task { @MainActor in
                            if self.isRevenueCatConfigured {
                                continuation.resume()
                                return
                            }
                            self.configurationContinuations.append(continuation)
                        }
                    }
                    return true
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return false
                }

                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }

            guard configuredInTime, isRevenueCatConfigured else {
                logger.error("RevenueCat 配置超时（5秒），无法刷新订阅状态")
                return
            }
        }

        do {
            let customerInfo = try await Purchases.shared.customerInfo()
            updateSubscriptionStatus(from: customerInfo)
        } catch {
            logger.error("刷新订阅状态失败: \(error.localizedDescription)")
            // 网络失败时保留当前状态，避免付费用户因网络问题被误判为免费用户
        }
    }

    /// 设置交易更新监听器
    private func setupTransactionListener() {
        transactionListenerTask?.cancel()

        transactionListenerTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for await _ in StoreKit.Transaction.updates {
                if Task.isCancelled {
                    logger.debug("交易监听任务已取消")
                    break
                }

                await self.refreshSubscriptionStatus()
                self.logger.info("检测到新交易，已更新订阅状态")
            }
        }
    }

    /// 停止交易监听器
    private func stopTransactionListener() {
        transactionListenerTask?.cancel()
        transactionListenerTask = nil
        logger.debug("已停止交易监听器")
    }

    // MARK: - Utility Methods

    /// 获取可用的套餐列表（过滤掉配置为空的产品）
    public var availablePackages: [Package] {
        guard let config,
              let offerings,
              let currentOffering = offerings.current
        else {
            return []
        }

        return currentOffering.availablePackages.filter { package in
            let productId = package.storeProduct.productIdentifier

            return (!config.monthly.isEmpty && productId == config.monthly)
                || (!config.annual.isEmpty && productId == config.annual)
                || (!config.lifetime.isEmpty && productId == config.lifetime)
        }
    }

    /// 获取套餐显示名称
    public func getPackageDisplayName(_ package: Package) -> String {
        switch package.packageType {
        case .monthly:
            return "月度订阅"
        case .annual:
            return "年度订阅"
        case .lifetime:
            return "永久买断"
        default:
            return package.identifier
        }
    }

    /// 计算月均价格
    public func calculateMonthlyPrice(_ package: Package) -> String {
        if package.packageType == .annual {
            let price = package.storeProduct.price
            let monthlyPrice = Double(truncating: price as NSNumber) / 12
            return "¥\(String(format: "%.2f", monthlyPrice))/月"
        }
        return ""
    }

    /// 获取按钮标题
    public func getButtonTitle(for package: Package?) -> String {
        guard let package else {
            return "选择套餐"
        }

        switch package.packageType {
        case .monthly:
            return "开始月度订阅"
        case .annual:
            return "开始年度订阅"
        case .lifetime:
            return "立即购买永久版"
        default:
            return "立即购买"
        }
    }

    /// 获取订阅到期时间文本（仅对订阅会员显示）
    public var subscriptionExpirationText: String? {
        guard subscriptionStatus == .monthly || subscriptionStatus == .annual,
              let expirationDate
        else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "zh_CN")
        return "会员到期时间: \(formatter.string(from: expirationDate))"
    }

    /// 获取简短的会员状态标签
    public var subscriptionBadgeText: String {
        return subscriptionStatus.badgeText
    }

    /// 检查权限并显示付费墙（如果需要）
    ///
    /// 当用户尝试访问高级功能时调用此方法，它会：
    /// 1. 检查用户是否有高级权限
    /// 2. 如果没有权限，自动设置 showPaywall = true 触发付费墙
    /// 3. 返回权限状态供调用方决定是否继续执行功能
    ///
    /// - Returns: 是否有高级权限（true: 有权限；false: 无权限，付费墙已触发）
    public func checkPremiumAccessOrShowPaywall() -> Bool {
        guard let hasAccess = hasPremiumAccess else {
            logger.debug("权限状态未知（首次安装），显示付费墙")
            showPaywall = true
            return false
        }

        if !hasAccess {
            showPaywall = true
            logger.info("用户无高级权限，显示付费墙")
            return false
        }
        return true
    }

    // MARK: - Animation Methods

    /// 触发订阅页面的展示动画
    /// 延迟开始，等待 fullscreenCover 完全显示
    public func triggerSubscriptionPageAnimation() {
        subscriptionContentAppeared = false

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation {
                subscriptionContentAppeared = true
            }
        }
    }

    /// 重置订阅页面的动画状态
    public func resetSubscriptionPageAnimation() {
        subscriptionContentAppeared = false
    }
}

// MARK: - Preview 辅助（仅 DEBUG 可用）

#if DEBUG
extension RevenueCatViewModel {
    /// 为 SwiftUI Preview 设置模拟会员状态，不影响生产逻辑
    public func setPreviewPremiumAccess(_ value: Bool?, status: SubscriptionStatus = .lifetime) {
        hasPremiumAccess = value
        if value == true {
            subscriptionStatus = status
        } else {
            subscriptionStatus = .none
        }
    }
}
#endif
