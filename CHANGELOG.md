# Changelog

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
- Add forced network entitlement refresh, introductory-offer display metadata,
  and current-account eligibility.
- Add persisted identity restoration before login alignment so upgrades do not
  discard an existing identified purchase identity.
- Preserve the shipped seven-day protection when a previously confirmed
  premium entitlement temporarily disappears. Legacy global keys migrate once
  to the initially restored RevenueCat identity; new state is identity-scoped,
  and rollback keys remain unchanged.
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
