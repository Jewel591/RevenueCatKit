# RevenueCatKit

RevenueCat SDK 的一层封装：订阅状态、购买 / 恢复、offerings 加载、介绍性优惠资格查询。

---

## ⚠️ 定位：参考实现，不是要被依赖的包（2026-07-27 Ivens 定）

**新项目请把这里的代码当作参考，复制进自己项目里独立实现，不要把本仓库作为 SPM 依赖引入。**

这不是「代码质量不够好」的意思，而是依赖本身有成本：

- **Xcode Cloud 需要额外授权**。私有 SPM 依赖要在 App Store Connect 里逐个 Grant「Additional Repositories」，GitHub 侧给了 All access 也不够——漏了就是云构建失败，而失败信息不会直说缺授权（supamate 踩过整整一轮）。
- **依赖跟 `branch = main` 会被动漂移**。消费方不锁 rev 时，这里合并任何改动都会流进对方下一次依赖解析；破坏性改动能当场打断别人的云构建。锁 rev 又意味着改进传不过去，等于手工同步。
- **订阅逻辑天然要按产品改**。权益 ID、商品 ID、状态展示文案、付费墙形态各产品都不同，真正能原样复用的部分远比看起来少。抄一份改自己的，比把差异塞进配置注入更直接。

已有消费方（Apper / supamate）保持现状即可，不必为此专门发一版；后续若做迁移，另行安排。

---

## 怎么用

把 `Sources/RevenueCatKit/` 下的文件复制进你的项目，按需裁剪。两个文件各自独立：

| 文件 | 内容 |
|---|---|
| `RevenueCatViewModel.swift` | `@Observable @MainActor` 的集成管理器：初始化、offerings、购买 / 恢复、订阅状态与缓存 |
| `RevenueCatKitConfiguration.swift` | 配置注入（API key、entitlement ID、商品 ID） |

---

## 两个容易踩的坑（复制代码时别顺手删掉）

### 1. `introductoryDiscount` ≠ 当前账号有资格

`StoreProduct.introductoryDiscount` 只说明**商品配置了**介绍性优惠。用过该订阅组优惠、之后订阅过期的用户重新进入付费墙时，商品上依然挂着 discount，但 Apple 结算按原价收费。

付费墙若直接照 discount 的价格展示，就是**超额承诺**——用户看到首年 $9.99，购买单收 $19.99。

判定优惠能不能展示，三条缺一不可：

```swift
// 1. 商品确实配了优惠
guard let discount = product.introductoryDiscount,
      // 2. paymentMode 与你的话术相符（「首年 X，之后 Y」只适用于 .payUpFront）
      discount.paymentMode == .payUpFront,
      // 3. 当前账号确实有资格
      await viewModel.introEligibility(for: product) == .eligible
else {
    // 任一不成立 → 展示原价，且不要打「早鸟 / 限时」类角标
    return
}
```

`.unknown`（RevenueCat 信息不足、或查询失败）**按 RevenueCat 官方建议同样展示原价**——宁可少承诺，不可多承诺。

> Apper 1.0 提审前踩过：付费墙常显 Early bird 角标却渲染基础价；修掉之后又发现反方向的超额承诺风险（[apper#45](https://github.com/Jewel591/apper/pull/45)，Codex review 抓出）。

### 2. 「加载失败」与「成功但没有商品」必须分开

`loadOfferings()` 返回 `Bool`：`true` = 请求成功（`offerings` 已更新，**可能是空的**——ASC 商品还没建好时就是这样）；`false` = 请求失败，保留上一次快照。

这两者该给的 UI 反馈相反：失败该给 Retry，成功但为空该给「暂未开放」之类的诚实提示。只看 `offerings == nil` 分不开，给反了都是错的。

---

## 依赖

[`purchases-ios-spm`](https://github.com/RevenueCat/purchases-ios-spm) 5.0.0+ · iOS 17+ / macOS 15+ · Swift 6
