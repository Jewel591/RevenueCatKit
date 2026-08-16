# RevenueCatKit

公司内部统一的 RevenueCat 领域适配层。它把 RevenueCat SDK 转换成稳定的会员、商品和购买 API；各 App 只负责注入自己的业务事实并绘制自己的付费墙。

## 安装

仓库为公司私有 Swift Package。先确保开发机或 CI 对 GitHub 私有仓库有读取权限，再在 Xcode 的 **Package Dependencies** 中添加：

```text
https://github.com/Jewel591/RevenueCatKit.git
```

生产项目应依赖已发布的语义化版本。跨仓库联调尚未发布的版本时，可以短期固定到一个完整 commit SHA，避免跟踪可变分支；发布后再切回版本约束。App target 只链接 `RevenueCatKit` product，不再直接链接或 `import RevenueCat`。

### Xcode Cloud 与私有仓库

Xcode Cloud 的授权对象是 **SCM provider / GitHub App installation 可以读取的具体仓库**，不是每条 workflow 单独保存的一份账号密码：

1. 在 GitHub 的 Apple/Xcode Cloud GitHub App repository access 中，明确加入 App 源码仓库和 `RevenueCatKit`。不要因为个人 GitHub 账号能 clone，就假定云端也能读取。
2. 同一个 App Store Connect 团队、同一个 GitHub provider connection 和同一个 GitHub App installation 下，`RevenueCatKit` 一旦已经对 Xcode Cloud 可见，其他 App 的 workflow 可以复用这项仓库访问，不需要为每条 workflow 再配置 token。
3. 每个新 App 仍要完成自己的 Xcode Cloud onboarding 和源码仓库连接。换 App Store Connect 团队、GitHub organization/provider 或 GitHub App installation 时，需要在新的授权边界重新加入 `RevenueCatKit`。
4. 将 App 工程生成的 `Package.resolved` 提交到 `$PROJECT.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。Xcode Cloud 使用它解析精确依赖，不要依赖云端自动解析，也不要把它加入 `.gitignore`。

若首次构建因 private dependency 权限失败，从该 build report 进入修复流程，让 Xcode 或 App Store Connect 引导补齐 SCM connection。不要把 Personal Access Token、SSH 私钥或其他 GitHub 凭据提交到工程中。

GitHub 中的具体入口：个人仓库走 **Settings → Applications → Installed GitHub Apps → Xcode Cloud → Configure**；Organization 仓库走 **Organization Settings → GitHub Apps / Installed GitHub Apps → Xcode Cloud → Configure**。在 **Repository access** 中把 `RevenueCatKit` 加入所选仓库。若 Installed Apps 中没有 Xcode Cloud，由拥有仓库 admin 权限（Organization 通常为 owner）的人完成首次安装；也可以让首次构建失败，再从 build report 的修复入口进入同一授权流程。

Apple 正身文档：[Making dependencies available to Xcode Cloud](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud)、[Connecting Xcode Cloud to GitHub](https://developer.apple.com/documentation/xcode/connecting-xcode-cloud-to-github)。

接入前还要在 RevenueCat Dashboard 完成 App 侧业务配置：

1. 为目标 App 添加对应的 Store App 和 Public SDK Key。
2. 把 App Store Connect 商品导入 RevenueCat，并挂到 Package / Offering。
3. 创建代表高级权限的 Entitlement，并把相应商品关联到该 Entitlement。
4. 配置 Current Offering；需要按场景分流时再配置 Placements。

这些商品关系留在 RevenueCat 后台，不复制到 Kit 或 App 源码。

## 给 Agent 的集成 Skill

仓库内附带 [`$integrate-revenuecatkit`](.agents/skills/integrate-revenuecatkit/SKILL.md)。它包含接入顺序、身份策略、职责边界、迁移检查，以及可直接改造成 App 代码的[参考实现](.agents/skills/integrate-revenuecatkit/references/integration-reference.md)。

让 agent 在本仓工作时可以直接要求：

```text
使用 $integrate-revenuecatkit，把这个 App 迁移到 RevenueCatKit，并完成迁移检查。
```

在其他仓库接入时，把 `.agents/skills/integrate-revenuecatkit` 复制到目标仓库同一路径，或将它安装到 agent 的个人 skills 目录，然后使用同一指令。skill 是实施手册，不替代目标 App 自己的工程约定；若目标仓库有 `AGENTS.md`，两者必须同时遵守。

## 职责边界

RevenueCatKit 统一负责：

- SDK 初始化，以及公司统一的网络代理和日志策略
- 匿名、已登录及混合身份模式与 App User ID 校验
- `CustomerInfo` 获取、主动刷新和变化监听
- Entitlement 到统一 `AccessLevel` 的转换
- 当前 Offering、Placement Offering 和内购资格
- 购买、恢复、重复点击保护及错误归一化
- Sandbox、TestFlight、App Store 等分发环境诊断

每个 App 仍独立负责：

- RevenueCat Public SDK Key
- 代表高级会员的 Entitlement ID
- 允许的身份模式，以及已登录时使用的稳定账号 ID
- 在哪个业务位置请求哪个 Placement
- 何时展示付费墙、多个 Surface 的展示顺序
- 付费墙视觉、文案和 App 内会员方案展示

产品组合、价格和可购买资格来自 RevenueCat Offering，不在 Kit 或 App 代码中维护固定商品清单。App 不按 `productID` 判断权益或推断历史会员方案；当前付费墙只使用 Offering 返回的本地化商品信息与 `packageType`。`productID` 仅保留为诊断信息。

Kit 不依赖 RevenueCat Paywalls UI，也不创建任何页面。

## 初始化

配置类型嵌套在唯一入口 `RevenueCatClient` 下，避免再出现一层同名 Kit 配置：

```swift
import RevenueCatKit

let client = RevenueCatClient.shared
let configuration = RevenueCatClient.Configuration(
    publicSDKKey: "appl_…",
    premiumEntitlementID: "premium",
    identityPolicy: .anonymousAndIdentified
)

client.setDesiredIdentity(.anonymous)
try await client.configure(configuration)
```

若 App 启动时已经拥有稳定账号 ID，先声明运行时身份，再配置 SDK：

```swift
client.setDesiredIdentity(.account(RevenueCatClient.AppUserID(accountID)))
try await client.configure(configuration)
```

`setDesiredIdentity(_:)` 是 App 唯一的身份入口。它可以在 `configure(_:)` 前调用。首次 `configure` 不把账号传给 `Purchases.configure`，先恢复本机已有的 RevenueCat 用户，再用 `logIn` 对齐；这样旧匿名付费身份会被 alias，而不是被新 UUID 直接覆盖。账号事实一确定就应声明，不要等 CloudKit 或其他能力校验。后续登录或换号也走同一入口。

`setDesiredIdentity(.anonymous)` 会让 Kit 调用 `Purchases.logOut()`。允许未登录购买的 App（`.anonymousAndIdentified`）在用户只退出云备份时，应保留上次确认的购买身份；只有首次无账号、删号，或明确要重置购买身份时才声明匿名。

切换期间 `state.identityAlignment` 为 `.transitioning`，`state.accessLevel` 固定为 `.unknown`；失败会落到 `.failed(error)`，重复声明同一身份可显式重试。

身份策略：

- `.anonymousOnly`：只允许 RevenueCat 匿名身份。
- `.identifiedOnly`：配置前必须声明账号身份；可以切换已识别账号，不能切换成匿名身份。
- `.anonymousAndIdentified`：同时支持匿名用户与账号用户。

配置只包含 App 自己拥有的不可变事实。代理、日志级别和环境识别等公司约定留在 Kit 内统一维护。

## 权益

```swift
switch RevenueCatClient.shared.state.accessLevel {
case .premium, .premiumInGracePeriod:
    unlockPremiumFeatures()
case .free:
    requestPaywallIfPolicyAllows()
case .unknown:
    preserveLoadingOrLastKnownState()
}
```

权限只依据配置的 Entitlement 和 RevenueCat `CustomerInfo`。`.premiumInGracePeriod` 仍然授予高级权限；`.unknown` 不应被提前当成免费用户。

无需重复实现这组映射时，可使用安全的三态便利属性：

```swift
let premiumAccess: Bool? = RevenueCatClient.shared.state.accessLevel.premiumAccess
```

其中 `true` 表示已确认有权限，`false` 表示已确认免费，`nil` 表示尚未得到可信结论。

需要更多诊断信息时读取 `state.entitlement`，其中包含账单状态、到期时间、Store、Sandbox 标记、请求时间和快照新鲜度。需要绕过缓存主动确认时：

```swift
let snapshot = try await RevenueCatClient.shared.forceRefresh()
```

## Offering 与购买

默认读取 RevenueCat 当前 Offering：

```swift
let offeringState = try await RevenueCatClient.shared.loadOffering()
```

在 onboarding、功能拦截或活动等位置读取 Placement Offering：

```swift
let offeringState = try await RevenueCatClient.shared.loadOffering(
    for: .placement("onboarding_end")
)
```

App 使用 `OfferingSnapshot.purchaseOptions` 绘制自己的付费墙，并以不透明的 `PurchaseOptionID` 发起购买。数组顺序跟随 RevenueCat Dashboard，不是套餐默认值；若产品要默认终身或年付，按 `packageType` 选择。

```swift
guard case .available(let offering) = offeringState,
      let option = offering.purchaseOptions.first(where: { $0.packageType == .lifetime })
        ?? offering.purchaseOptions.first else {
    return
}

let outcome = try await RevenueCatClient.shared.purchase(option.id)
```

每个 `OfferingScope` 都有独立的 `idle / loading / available / missing / empty / failed` 状态，统一保存在 `client.state.offerings`。只有 `.available` 暴露可购买选项；刷新失败、空结果或身份切换都不会继续复用旧商品。相同 Offering ID 同时出现在 current 与 Placement 时，两边的快照和购买句柄也互不干扰。

`PurchaseOptionID` 是快照级不透明标识，只对生成它的当前身份和 Offering scope 快照有效。即使刷新前后复用了相同 Offering ID 与 Package ID，Kit 也不会把旧标识重新绑定到新商品。账号切换或该 scope 刷新后，App 应使用最新状态重绘页面。

恢复购买：

```swift
let outcome = try await RevenueCatClient.shared.restorePurchases()
```

购买和恢复返回有信息量的结果枚举，不用 `Bool` 混淆取消、待处理、无有效权益与真正失败。

## 并发与错误

配置、购买、恢复和身份对齐共享互斥操作门。购买或恢复期间的新身份会排队，在 StoreKit 操作完成后按“最后一次声明优先”对齐；旧身份的完成结果不会重新授予权限。重复操作立即抛出 `RevenueCatClientError.operationInProgress`；取消调用方 Task 不会提前释放仍在 StoreKit 中进行的购买。

上层只处理 `RevenueCatClientError`，无需依赖 RevenueCat `ErrorCode`。可观察的 `client.state.operation` 用于统一驱动加载态和禁用重复点击。

`DistributionChannel` 只用于诊断和环境标记，绝不参与会员权限判断。

## 接入验收

合并前至少确认：

- App 源码没有直接 `import RevenueCat`，App target 没有直接链接 RevenueCat product。
- App 只配置 Public SDK Key、Premium Entitlement ID、Identity Policy 和实际使用的 Placement ID。
- 没有硬编码 Product ID、按 Product ID 分支或判断权益，也没有写死 Offering ID 或本地商品清单；快照里的 `productID` 只可用于诊断。
- 账号事实尚未确定时不抢先配置；一旦知道稳定账号 ID 或确认无账号，就在 `configure(_:)` 前通过 `setDesiredIdentity(_:)` 声明，不等 CloudKit。首次配置必须先恢复本机 RevenueCat 用户再 `logIn`。可选登录的 App 退出云账号时不声明 `.anonymous`，并把上次购买身份持久化到冷启动。
- `.unknown` 与 `.free` 分开处理，`.premiumInGracePeriod` 继续授予高级权限。
- 付费墙完整处理 Offering 的 loading、missing、empty、failed 和 available 状态。
- 购买只使用最新快照的 `PurchaseOptionID`，购买与恢复期间禁用重复提交。
- 恢复购买入口、协议和隐私入口不因 Offering 加载失败而消失。
- App 自己负责本地化错误文案；用户可见文本不直接展示 SDK 错误或内部标识符。
- 至少覆盖配置、身份切换、权益映射、Offering 降级、购买/恢复结果和“App 不直连 SDK”的回归测试。
