# Changelog

## 4.0.0 - 2026-10-04

- 修复有限 SDK 诊断在 adapter 与客户端未知错误归一化边界丢失的问题（#17）。
- `unknown` 新增可选 `SDKFailureDiagnostics` 关联值；只保留白名单 SDK 分类和直接底层白名单码，宿主读取 `sdkDiagnostics.telemetryContext` 接入已有错误事件。
- 源代码不兼容升级：无载荷构造改为 `.unknown(nil)`，依赖最低版本更新为 `4.0.0` 并刷新解析文件；迁移合同见 README。
- SDK 分类不证明最终根因，空诊断不证明配置或网络失败；历史事件无法补回。权益、商品、购买、恢复、取消与重试语义保持不变。

## 3.0.0 - 2026-09-07

- 修复网络诊断在 SDK 和客户端两层错误归一化中丢失的问题（#15）。
- `networkUnavailable` 新增 `NetworkFailureDiagnostics` 关联值，区分网络、离线和端点阻断；仅保留白名单系统网络码，不保留原始错误内容。
- 这是源代码不兼容升级；宿主须更新错误构造与依赖解析，并将当前错误的诊断上下文接入已有事件。具体迁移见 README。
- 权益、购买、恢复、取消和重试策略不变；诊断交付不表示宿主购买故障已修复。

## 2.1.0 - 2026-09-04

### Added

- Expose `EntitlementDiagnostics` on every `EntitlementSnapshot`, including the customer's
  entitlement keys, current-environment active keys, and lifetime purchased product IDs.
- Add `EntitlementFailureDiagnosis` as the house-standard classifier for "paid but not
  entitled." Purchase applies the bought product ID automatically; hosts read
  `state.entitlement?.diagnostics.diagnosis` after `.notEntitled` and do not reimplement
  the mapping-gap vs sync-delay split. The purchased product ID is frozen at purchase
  start and kept across later CustomerInfo stream refreshes only while that purchase
  remains unentitled; a later confirmed entitlement returns refresh/restore to the
  revocation path (#13).

## 2.0.1 - 2026-09-04

### Fixed

- Keep a locally confirmed premium entitlement visible while the first launch refresh is in
  flight, without carrying access across an identity switch or hiding a refresh failure.
- Preserve the confirmed expiration in the launch seed, backfill RevenueCatKit 2.0 records from
  RevenueCat's identity-scoped cache, and bound an elapsed subscription period by the existing
  seven-day revocation grace.

## 2.0.0 - 2026-08-19

RevenueCatKit 2.0 establishes the package as the single subscription domain
layer for the App portfolio.

### Added

- Add `RevenueCatClient` as the canonical observable entry point for
  configuration, identity alignment, entitlement refresh, Offerings, purchase,
  and restore.
- Add normalized access, entitlement, Offering, purchase-option, operation,
  distribution, and error models without exposing RevenueCat SDK types.
- Add Current Offering and Placement Offering state with identity- and
  snapshot-scoped purchase handles.
- Add forced network entitlement refresh, complete introductory-offer display
  metadata (price, payment mode, period, and period count), and current-account
  eligibility.
- Add persisted identity restoration before login alignment so upgrades do not
  discard an existing identified purchase identity.
- Preserve the shipped seven-day protection when a previously confirmed
  premium entitlement temporarily disappears. Legacy global keys migrate once
  to the initially restored RevenueCat identity; new state is identity-scoped,
  rollback keys remain unchanged, and anonymous provenance moves only when
  RevenueCat confirms login created a new alias target.
- Add a complete integration skill and host migration reference.

### Changed

- Replace the legacy `RevenueCatViewModel` and product-ID-driven configuration
  with App facts only: Public SDK Key, premium Entitlement ID, and identity
  policy.
- Move paywall presentation, UI, copy, and campaign decisions fully into each
  host App.
- Require consumers to use compatible semver ranges; branch and commit-SHA
  dependencies are not supported release channels.

### Removed

- Remove App-facing RevenueCat SDK types, hard-coded product catalogs, shared
  paywall visibility state, and Boolean purchase/restore results.
