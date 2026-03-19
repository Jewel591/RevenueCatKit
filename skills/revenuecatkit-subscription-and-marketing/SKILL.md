---
name: revenuecatkit-subscription-and-marketing
description: "Inspect a SwiftUI app's current RevenueCatKit subscription integration and marketing-surface implementation before making changes. Use when adding, reviewing, or refactoring RevenueCatKit configuration, shared subscription state, root paywall presentation, homepage toolbar promo badges, homepage content-area promo cards, or settings-page promo cards. This skill enforces: inspect current subscription and promo state first, settings-page promo is mandatory, homepage should use exactly one of toolbar badge or content card for fresh implementations, and when neither homepage option exists it must ask the user to choose 1.toolbar or 2.content card before coding. Also use when you want current RevenueCatKit subscription wiring plus CodeCat toolbar/content/settings promo implementations as reference examples."
---

# RevenueCatKit Subscription And Marketing

先审查当前项目，再决定怎么接入。整个 skill 保持一个入口，但执行和参考代码要分成两个部分：

1. 订阅集成
2. 营销卡片集成

不要直接写代码。

## Workflow

### 1. Part 1: 先审查订阅集成

先搜索并记录以下订阅核心：

1. `RevenueCatViewModel.configure`
2. `RevenueCatViewModel.shared`
3. `showPaywall`
4. `SubscriptionView`
5. 根层是否存在统一的 `.fullScreenCover(isPresented: $revenueCatViewModel.showPaywall)`

### 2. Part 2: 再审查营销卡片集成

再搜索并记录以下三项：

1. 首页 toolbar 营销位是否存在
   - `ToolbarItem`
   - `shouldShowAds`
   - 紧凑型 badge / pill / capsule CTA

2. 首页内容区大卡片是否存在
   - `ProMarketingCard`
   - 自定义大营销卡片
   - 内容区 CTA 是否拉起订阅页或活动页

3. 设置页营销卡片是否存在
   - 设置页 promo card / banner / marketing card
   - 非会员 gating
   - 点击行为和关闭行为

输出一个简短审查结论：

```md
## RevenueCatKit 订阅与营销审查
- 订阅集成：✅ / ❌
- 首页 toolbar 营销位：✅ / ❌
- 首页内容区大卡片：✅ / ❌
- 设置页营销卡片：✅ / ❌
- 推荐动作：<下一步>
```

### 2. 应用规则

- 设置页营销卡片是必选项，缺失时必须补上
- 首页营销位在新实现中只选一个：
  - `1.` toolbar badge
  - `2.` 内容区大卡片
- 如果首页 `1` 和 `2` 都没有实现：
  - 先问用户选择 `1` 还是 `2`
  - 没有用户选择前，不要擅自实现首页营销位
- 如果首页已经实现了其中一个：
  - 沿用现有首页形态
- 如果首页已经同时有两个：
  - 先在审查结论中指出这是“双首页营销位”
  - 除非用户明确要求收敛，否则不要主动删除其中一个

### 3. 实现要求

- 付费墙入口优先复用 `RevenueCatViewModel.showPaywall`
- 营销位默认只在 `shouldShowAds == true` 时显示
- 当 `hasPremiumAccess == nil` 时不要显示营销位，避免启动闪烁
- 设置页营销卡片必须存在，即使首页营销位尚未确定
- 首页 toolbar badge 适合轻量 CTA
- 首页内容区大卡片适合强曝光 CTA
- 点击行为只保留一个明确目标：
  - 拉起订阅页
  - 或跳活动页
- 不要在同一营销位里同时承担两个目标

### 4. 参考代码

优先按两部分读取参考：

1. 订阅集成参考
   - [Sources/RevenueCatKit/RevenueCatViewModel.swift](../../Sources/RevenueCatKit/RevenueCatViewModel.swift)
   - [Sources/RevenueCatKit/RevenueCatKitConfiguration.swift](../../Sources/RevenueCatKit/RevenueCatKitConfiguration.swift)
   - [references/codecat-subscription-integration.md](references/codecat-subscription-integration.md)

2. 营销卡片集成参考
   - [references/codecat-marketing-card-integration.md](references/codecat-marketing-card-integration.md)

两个 reference 的职责要分清：
- `codecat-subscription-integration.md`
  - 只放 RevenueCat 状态、配置、全局 paywall 挂载
- `codecat-marketing-card-integration.md`
  - 只放首页 toolbar badge、首页内容区大卡片、设置页营销卡片

### 5. 验证

- 编译宿主 app / workspace
- 确认 `showPaywall` 仍然由根层统一展示
- 确认设置页营销卡片存在
- 确认首页营销位满足当前规则
- 确认营销位不会对会员或加载中用户误显示

## Key Rules

- 永远先审查现状，再实现
- 设置页营销卡片是必选项
- 首页营销位在新实现里只选 toolbar 或内容区二者之一
- 如果首页两者都不存在，必须先问用户选 `1` 还是 `2`
- `shouldShowAds` 是默认的非会员 gating 入口
- 付费墙展示优先复用根层 `showPaywall`
