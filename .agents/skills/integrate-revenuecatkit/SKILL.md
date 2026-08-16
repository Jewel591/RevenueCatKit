---
name: integrate-revenuecatkit
description: Integrate, migrate, review, or troubleshoot an Apple app that uses the company's RevenueCatKit Swift package. Use when adding subscriptions to a Swift/SwiftUI app, replacing direct RevenueCat SDK calls, configuring App User IDs and entitlements, loading current or placement Offerings, implementing purchase or restore flows, or auditing that product IDs and RevenueCat SDK types do not leak into the App layer.
---

# Integrate RevenueCatKit

Use RevenueCatKit as the App's only subscription dependency. Keep RevenueCat Dashboard as the catalog authority and keep App-specific UI and presentation policy in the host App.

## Read the local contract

Read the package `README.md` and current public declarations under `Sources/RevenueCatKit/` before changing an App. Do not reconstruct API names from memory.

Read [references/integration-reference.md](references/integration-reference.md) when writing new integration code or migrating an existing App. Adapt its names to the target App instead of copying product or account identifiers.

Also read and obey the target repository's `AGENTS.md` or equivalent instructions.

## Follow this workflow

1. Inspect the App's authentication lifecycle, current subscription wrapper, paywall surfaces, tests, package graph, and all direct RevenueCat imports.
2. Confirm the RevenueCat Dashboard has the Store App, Public SDK Key, premium Entitlement, products, Current Offering, and any required Placements. Treat Dashboard facts as prerequisites; do not compensate for missing remote configuration with hard-coded product catalogs.
3. Add only the `RevenueCatKit` product to App targets. Remove direct RevenueCat imports and product dependencies after the migration compiles. For Xcode Cloud, commit the App project's `Package.resolved` and verify that the connected SCM provider's GitHub App installation can read this private repository. Reuse provider/repository access where available; never add a token or SSH key to source control.
4. Define one App-owned configuration containing only the Public SDK Key, premium Entitlement ID, and Identity Policy. Do not hard-code Product IDs or Offering IDs, and never branch on them. A `PurchaseOption.productID` received from the Kit may be recorded only as diagnostics. Define Placement IDs only for real App presentation locations.
5. Wait until the App knows the account *fact*, then call `setDesiredIdentity(_:)` before the first `configure(_:)`. Use the App's stable opaque account ID, never an email, display name, Store transaction ID, or RevenueCat anonymous ID. Publish as soon as that fact is known — do not wait for CloudKit, backup owner checks, or other capability verification. The Kit restores any persisted RevenueCat user on first configure, then `logIn` aliases it to the declared account. Do not try to pass the account ID into SDK configure yourself. Later login and account-switch still go through the same entry point. For `.anonymousAndIdentified` Apps where purchases work signed out, signing out of an optional cloud account is not `setDesiredIdentity(.anonymous)`: that calls `Purchases.logOut()` and drops entitlements. Persist the last confirmed purchase identity across process launches; only first launch with no account, account deletion, or an intentional reset should become anonymous.
6. Gate access only with `AccessLevel`. Preserve `.unknown`; grant premium access for `.premium` and `.premiumInGracePeriod`.
7. Render the App's own paywall from `OfferingLoadState` and `OfferingSnapshot`. Use `.current` by default and `.placement(...)` only for configured RevenueCat Placements. Purchase with the latest `PurchaseOptionID` returned by that exact scope snapshot.
8. Handle `RevenueCatClient.PurchaseOutcome`, `RevenueCatClient.RestoreOutcome`, and `RevenueCatClientError` explicitly. Keep user-facing localized copy in the App. Keep restore, privacy, and terms actions available even when Offerings fail.
9. Delete App-owned CustomerInfo mapping, Offering mirrors, purchase locks, SDK delegates, error-code switches, and product-based entitlement logic that RevenueCatKit now owns. Retain only App semantics, identity/session bridging, paywall UI, and localized presentation.
10. Build and run the smallest relevant tests. Add a regression guard that rejects direct `import RevenueCat` across every source root compiled into the App, including shared and extension-owned directories, and rejects direct RevenueCat package/product objects in App targets.

## Preserve these boundaries

- RevenueCat Entitlement answers whether the user has access.
- RevenueCat Offering answers what can currently be purchased.
- The App or its promotion policy answers whether a paywall should appear.
- The App's surface coordinator answers which modal appears first.
- RevenueCatKit performs configure, identity alignment, refresh, purchase, restore, normalized state, and error normalization.
- The App draws the paywall and owns its copy, analytics context, campaign context, and navigation.

Do not add RevenueCat Paywalls UI to this package. Do not expose RevenueCat SDK types through App APIs. Do not hard-code Product IDs or use them to infer membership duration, access, or UI. A Product ID already present in a Kit snapshot may be logged only for diagnostics when necessary.

## Review the result

Before declaring the migration complete, search the entire App source and project file for direct RevenueCat usage. Verify that unknown identity or entitlement state cannot unlock or deny access prematurely, stale purchase handles cannot survive an Offering refresh or identity switch, and failures never expose a previous Offering as purchasable. For an Xcode Cloud consumer, also verify that the shared `Package.resolved` records RevenueCatKit and that the private repository is included in the relevant GitHub App installation's repository access.

Report any RevenueCat Dashboard steps that code cannot verify. State explicitly whether persistent data models, schemas, migrations, synchronization, or backup formats changed.
