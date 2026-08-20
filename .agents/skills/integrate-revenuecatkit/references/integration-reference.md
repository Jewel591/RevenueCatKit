# RevenueCatKit integration reference

Use these snippets as shapes, not as identifiers. Replace every placeholder with facts from the target App and RevenueCat Dashboard.

## 1. App-owned configuration

```swift
import RevenueCatKit

enum AppMonetizationConfiguration {
    static let revenueCat = RevenueCatClient.Configuration(
        publicSDKKey: "appl_REPLACE_WITH_THIS_APP_PUBLIC_KEY",
        premiumEntitlementID: "premium",
        identityPolicy: .anonymousAndIdentified
    )
}
```

Choose the narrowest valid identity policy:

- `.anonymousOnly` for an App that never attaches purchases to accounts.
- `.identifiedOnly` when every purchasing user must have an account.
- `.anonymousAndIdentified` when signed-out purchases and later account login are both supported.

The Public SDK Key is App-specific public configuration, not a server secret. The Entitlement ID is the RevenueCat entitlement that grants the App's unified premium access. Do not add Product IDs or Offering IDs here.

## 2. Bridge unresolved authentication explicitly

Do not treat “the authentication SDK has not answered yet” as signed out. As soon as the App knows the account fact — a stored user ID, or confirmed first-launch anonymity — declare exactly one desired RevenueCat identity. Do not wait for CloudKit, dataset owner checks, or other capability verification; those gate backup, not purchases.

`setDesiredIdentity(.anonymous)` logs the RevenueCat user out. Do not use it for “user signed out of optional cloud backup.” Do not use it on first launch just because the App persist key and account session are both missing — that is the upgrade path where RevenueCat may still hold an identified paid user. Configure first, then adopt the restored identity. Use `.anonymous` only after the restored user is actually anonymous, or for account deletion / an intentional reset.

```swift
import Observation
import RevenueCatKit

@MainActor
final class MembershipIdentityCoordinator {
    enum SessionFact {
        case unresolved
        case signedOutKeepingPurchases
        case resetToAnonymous
        case signedIn(accountID: String)
    }

    private let client = RevenueCatClient.shared
    private var configurationTask: Task<Void, Error>?

    private var persistedPurchaseAppUserID: RevenueCatClient.AppUserID? {
        get {
            UserDefaults.standard.string(forKey: "purchaseAppUserID")
                .map(RevenueCatClient.AppUserID.init)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: "purchaseAppUserID")
        }
    }

    func publish(_ fact: SessionFact) {
        switch fact {
        case .unresolved:
            return
        case .signedOutKeepingPurchases:
            if let persistedPurchaseAppUserID {
                client.setDesiredIdentity(.account(persistedPurchaseAppUserID))
            }
        case .resetToAnonymous:
            persistedPurchaseAppUserID = nil
            client.setDesiredIdentity(.anonymous)
        case .signedIn(let accountID):
            let appUserID = RevenueCatClient.AppUserID(accountID)
            persistedPurchaseAppUserID = appUserID
            client.setDesiredIdentity(.account(appUserID))
        }

        if configurationTask == nil {
            configurationTask = Task { @MainActor [client] in
                try await client.configure(AppMonetizationConfiguration.revenueCat)
            }
        }
    }

    func waitUntilConfigured() async throws {
        guard let configurationTask else {
            throw RevenueCatClientError.notConfigured
        }
        do {
            try await configurationTask.value
            if client.state.desiredIdentity == nil {
                let restoredIdentity: RevenueCatClient.DesiredIdentity
                if client.state.isAnonymous == false,
                   let restoredID = client.state.currentAppUserID {
                    persistedPurchaseAppUserID = restoredID
                    restoredIdentity = .account(restoredID)
                } else {
                    restoredIdentity = .anonymous
                }
                client.setDesiredIdentity(restoredIdentity)
            }
            await waitUntilIdentitySettles()
        } catch {
            self.configurationTask = nil
            throw error
        }
    }

    private func waitUntilIdentitySettles() async {
        while client.state.identityAlignment == .undeclared
            || client.state.identityAlignment == .transitioning {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = client.state.identityAlignment
                } onChange: {
                    Task { @MainActor in continuation.resume() }
                }
            }
        }
    }
}
```

Calling `publish(.signedIn(accountID:))` before awaiting configuration lets the Kit restore any persisted RevenueCat user, then `logIn` to match. Persist the purchase App User ID across process launches if the App allows signed-out purchases. Publish later login, deletion, and account switch through the same coordinator. The example intentionally does nothing for `.unresolved`, so a cold launch never manufactures a signed-out RevenueCat identity while the account fact is still loading. `.signedOutKeepingPurchases` declares the persisted purchase identity before configuration; when that key is absent during an upgrade, `waitUntilConfigured()` configures first, adopts the SDK-restored identity, and waits until alignment is `.matching` or `.failed` before initialization completes.

If the persist key is missing and there is no account session, use the same coordinator's configure-then-adopt path. Do not map “unresolved + nil session” to `.anonymous`:

```swift
coordinator.publish(.signedOutKeepingPurchases)
try await coordinator.waitUntilConfigured()
```

Never call RevenueCat SDK `logIn` or `logOut` from the App. During alignment, `client.state.identityAlignment` is `.transitioning` and access is `.unknown`. If alignment fails, repeating the same desired identity explicitly retries it — do that on network and foreground recovery, not only when the paywall opens.

## 3. Inject the observable client into SwiftUI

```swift
import RevenueCatKit
import SwiftUI

@main
struct ExampleApp: App {
    @State private var revenueCat = RevenueCatClient.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(revenueCat)
        }
    }
}
```

A consuming view can read normalized state without importing RevenueCat:

```swift
import RevenueCatKit
import SwiftUI

struct PremiumFeature: View {
    @Environment(RevenueCatClient.self) private var revenueCat

    var body: some View {
        switch revenueCat.state.accessLevel {
        case .premium, .premiumInGracePeriod:
            PremiumContent()
        case .free:
            UpgradePrompt()
        case .unknown:
            ProgressView()
        }
    }
}
```

Create a thin App `MembershipStore` only when the App needs additional domain names, development overrides, or localized presentation. Do not rebuild the Kit's identity, Offering, purchase, or entitlement state machines inside it.

## 4. Load and render an Offering

Use the Current Offering unless the surface has a configured Placement:

```swift
let current = try await RevenueCatClient.shared.loadOffering()
let onboarding = try await RevenueCatClient.shared.loadOffering(
    for: .placement("onboarding_end")
)
```

Render every state explicitly:

```swift
@ViewBuilder
func plans(for state: OfferingLoadState) -> some View {
    switch state {
    case .idle, .loading:
        ProgressView()
    case .available(let offering):
        PlanPicker(options: offering.purchaseOptions)
    case .missing, .empty:
        UnavailablePlansView()
    case .failed:
        OfferingRetryView()
    }
}
```

Use `PurchaseOption.localizedTitle`, `localizedDescription`, `localizedPrice`, `subscriptionPeriod`, and `packageType` to draw the App's paywall. Do not use Product ID for UI branching. RevenueCatKit deliberately preserves Product ID only for diagnostics.

`purchaseOptions` keeps RevenueCat Dashboard order. That is not a product default. If the App previously selected lifetime or annual, pick by `packageType`; do not use `.first`.

## 5. Purchase and restore

Keep the `PurchaseOptionID` from the currently visible snapshot and pass it back unchanged:

```swift
let outcome = try await RevenueCatClient.shared.purchase(option.id)

switch outcome {
case .purchased:
    dismissPaywall()
case .cancelled:
    break
case .pending:
    showPendingMessage()
case .notEntitled:
    showPurchaseNotActivatedMessage()
}
```

After identity alignment or any Offering reload, discard the old selection and select from the new snapshot. A stale or caller-created `PurchaseOptionID` safely fails with `.optionUnavailable`.

```swift
let outcome = try await RevenueCatClient.shared.restorePurchases()

switch outcome {
case .restored:
    showRestoreSucceededMessage()
case .noActiveEntitlement:
    showNothingToRestoreMessage()
}
```

Use `client.state.operation` to disable purchase and restore controls while a mutation is active. The Kit also rejects duplicate operations, but the App should still provide immediate visual feedback.

## 6. App-owned error presentation

Map normalized errors to localized App copy:

```swift
func purchaseErrorMessage(for error: Error) -> LocalizedStringKey {
    guard let clientError = error as? RevenueCatClientError else {
        return "The purchase could not be completed."
    }

    switch clientError {
    case .networkUnavailable:
        "Unable to connect. Check your network and try again."
    case .storeUnavailable, .optionUnavailable:
        "This plan is currently unavailable."
    case .operationInProgress:
        "A purchase is already in progress."
    default:
        "The purchase could not be completed."
    }
}
```

Do not show `localizedDescription` from RevenueCat or raw internal enum names directly to users.

## 7. Migration searches

Adapt these checks to the target repository:

```sh
rg -n '^[[:space:]]*import[[:space:]]+RevenueCat[[:space:]]*$|Purchases\.|CustomerInfo|entitlements\[' AppDirectory SharedDirectory ExtensionDirectory
rg -n 'XCRemoteSwiftPackageReference "purchases-ios-spm"|productName = RevenueCat(UI)?' AppProject.xcodeproj/project.pbxproj
rg -n 'productID|offeringID' AppDirectory
```

Every remaining match needs an explicit reason. Tests may mention forbidden patterns to enforce the boundary; App production sources should not.

Verify with the package tests, the App's smallest membership test set, and an App build. For a migration, cover at least:

- cold launch while signed out and signed in, with identity published before CloudKit or other capability checks;
- login, optional-cloud logout that keeps the last purchase identity, first upgrade with no persist key plus an already-identified RevenueCat user, deletion/reset to anonymous, and account-to-account switch;
- alignment `.failed` retried on network and foreground recovery;
- `.unknown`, `.free`, `.premium`, and grace-period access;
- Current Offering and one Placement if Placements are used;
- missing, empty, failed, and successful Offering loads;
- purchase success, cancellation, pending, stale option, and duplicate tap;
- restore success and no active entitlement;
- a source/project guard against direct RevenueCat SDK dependency.
