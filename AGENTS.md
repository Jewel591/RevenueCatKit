# RevenueCatKit

Public Swift Package used as the App portfolio's single RevenueCat domain
layer. `README.md` defines the product contract; the integration workflow lives
in `.agents/skills/integrate-revenuecatkit/`.

## Product boundary

- RevenueCatKit owns SDK configuration, identity alignment, entitlement state,
  Offering loading, purchase/restore serialization, normalized errors, and the
  studio-wide proxy/logging policy.
- Host Apps own only their Public SDK Key, premium Entitlement ID, identity
  facts, real Placement IDs, paywall UI/copy, and presentation policy.
- Never expose RevenueCat SDK types through public API. Product IDs and
  Offering IDs are diagnostics, not business logic or configuration.
- Preserve `.unknown` separately from `.free`; grace-period access remains
  premium.
- Do not add RevenueCat Paywalls UI or host-specific product policy.

## Engineering

- Swift 6 strict concurrency; public platforms are iOS 17 and macOS 14.
- Every state-machine or public API change requires focused Swift Testing
  coverage with an injected provider. Do not test against the live SDK.
- Keep the integration skill, reference, README, and public declarations in
  sync in the same PR.
- `CLAUDE.md` is a relative symlink to this file; rules are edited only here.

## Release discipline

- `main` is the only evolving code line. Do not create `legacy/*`, `compat/*`,
  or consumer-specific maintenance branches.
- Runtime changes are delivered only by semver tag. Consumers use compatible
  version ranges and must not pin branch, revision, or commit SHA.
- Breaking API changes use a major release and consumers migrate to it. A
  temporary deprecated adapter, if ever justified, lives on `main` with an
  explicit removal version; it is never maintained on a side branch.
- Before release, run `swift test`, `git diff --check`, and compare the latest
  tag to `main` so every runtime change appears in the changelog.
