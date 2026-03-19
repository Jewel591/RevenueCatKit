# CodeCat Subscription Integration

当前 `CodeCat` 的订阅接入可以作为 `RevenueCatKit` 使用方式的参考。这个文件只放订阅集成，不放营销卡片。

## 1. App 入口配置

来源：
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/RevenueCatKit/Sources/RevenueCatKit/RevenueCatViewModel.swift`
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/RevenueCatKit/Sources/RevenueCatKit/RevenueCatKitConfiguration.swift`

```swift
RevenueCatViewModel.configure(config: .init(
    apiKey: "appl_xxx",
    entitlementID: "Pro",
    monthly: "",
    annual: "com.app.annual",
    lifetime: "com.app.lifetime"
))
```

这是 `RevenueCatKit` 约定的初始化入口。接入时应在 App 启动早期完成配置，而不是等到某个营销位点击后再初始化。

## 2. Shared 订阅状态

来源：
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/RevenueCatKit/Sources/RevenueCatKit/RevenueCatViewModel.swift`
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/CodeCat/CodeCat/ContentView.swift`

```swift
@Bindable private var revenueCatViewModel = RevenueCatViewModel.shared
```

营销位、设置页和根层 paywall 都应该复用同一个 shared 实例，避免出现多份订阅状态。

## 3. RevenueCat 核心状态

来源：
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/RevenueCatKit/Sources/RevenueCatKit/RevenueCatViewModel.swift`

```swift
public var showPaywall = false

public var shouldShowAds: Bool {
    return hasPremiumAccess == false
}
```

这两个状态是营销面的基础前提：
- `showPaywall`：统一拉起订阅页
- `shouldShowAds`：非会员 gating

## 4. 全局订阅页挂载

来源：
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/CodeCat/CodeCat/ContentView.swift`

```swift
.fullScreenCover(isPresented: $revenueCatViewModel.showPaywall) {
    SubscriptionView()
}
```

建议把 paywall 保持在根层统一挂载，不要在每个营销位里重复各自挂一个全屏订阅页。
