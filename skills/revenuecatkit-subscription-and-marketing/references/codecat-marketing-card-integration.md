# CodeCat Marketing Card Integration

当前 `CodeCat` 同时存在首页 toolbar 营销位、首页内容区大卡片和设置页营销卡片。对新项目来说，这三段代码是参考，不是强制照搬。

## 1. 首页 Toolbar 营销位

来源：
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/CodeCat/CodeCat/Features/Pickup/Views/PickupDashboardView.swift`
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/CodeCat/CodeCat/Features/Pickup/Views/PickupPromotionToolbarBadge.swift`

```swift
.toolbar {
    if shouldShowPromotionToolbarBadge {
        ToolbarItem(placement: .automatic) {
            PickupPromotionToolbarBadge(title: "40% 优惠") {
                presentSubscriptionPage()
            }
            .accessibilityIdentifier("pickupPromotionToolbarBadge")
            .accessibilityHint(Text("打开订阅页面"))
        }
    }
}
```

```swift
struct PickupPromotionToolbarBadge: View {
    let title: LocalizedStringResource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "gift.fill")
                Text(title)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }
}
```

适合做轻量 CTA，不适合承载太多文案。

## 2. 首页内容区大卡片

来源：
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/CodeCat/CodeCat/Features/Pickup/Views/PickupDashboardView.swift`
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/CodeCat/CodeCat/Features/RevenueCat/Views/ProMarketingCard.swift`

```swift
if revenueCatViewModel.shouldShowAds {
    ProMarketingCard()
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
}
```

```swift
Button {
    appState.triggerSelectionHaptic()
    showingSubscription = true
} label: {
    HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 6) {
            Text("会员限时优惠")
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("40%")
                Text("优惠")
            }
            HStack(spacing: 6) {
                Text("现价 ¥58")
                Text("原价 ¥98")
            }
        }
        Spacer()
    }
}
.fullScreenCover(isPresented: $showingSubscription) {
    SubscriptionView()
}
```

这种形式适合更强曝光，但会明显占首页空间。

## 3. 设置页营销卡片

来源：
- `/Users/ivensliao/Documents/DevProjects/Swift Projects/CodeCat/CodeCat/Features/Settings/Views/SettingsView.swift`

```swift
if isMembershipPromotionCardVisible {
    GrowthPromotionBanner(
        content: membershipPromotionBannerContent,
        style: membershipPromotionBannerStyle,
        onTap: openPromotionPage,
        onDismiss: dismissPromotionCard
    )
    .padding(.horizontal)
    .transition(.blurReplace)
}
```

```swift
private var shouldShowMembershipPromotionCard: Bool {
    GrowthPromotionVisibilityPolicy.nonPremiumOnly.shouldDisplay(
        for: membershipPromotionAccessState,
        isDismissed: hasDismissedMembershipPromotionCard
    )
}

private var membershipPromotionBannerContent: GrowthPromotionBannerContent {
    .init(
        titleLines: ["分享取件喵使用体验", "得永久会员"],
        iconSystemName: "gift"
    )
}
```

设置页营销卡片是当前推荐的必选展示位，因为它侵入性最低，而且用户预期最明确。
