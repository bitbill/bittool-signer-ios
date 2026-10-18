# Deployment target assessment: could iOS 17 drop to iOS 15?

> **Decided, 17 October 2026: stay on iOS 17.** What follows is the assessment behind that
> decision, kept as a record. If the question is ever reopened, start here.

**Conclusion: it is possible, but iOS 16 is the step that pays for itself. iOS 15 additionally
costs a navigation-architecture rewrite, and it conflicts with positioning this as a security
product. No code was changed during the assessment — the deployment target was altered for a
single build and then restored.**

Method: temporarily set `IPHONEOS_DEPLOYMENT_TARGET` to 15.0 and run a real build (restored
afterwards), then audit the APIs of all 48 Swift files (10,878 lines) one by one.

## The toolchain itself is not in the way

Xcode 26.4 accepts a deployment target of iOS 15.0 with no "deployment target too low"
warning. The build stops at `SwiftEmitModule` with 9 errors — but that phase only checks
**declared signatures**; function bodies are never type-checked, so those 9 are nowhere near
the full count. The real work has to be established by auditing APIs.

Not obstacles: JavaScriptCore (iOS 7), CryptoKit (13), LocalAuthentication, `.privacySensitive()`
(15), `@AppStorage` (14), async/await (back-deployed to 13). The decisive point is that
**nothing in the repository uses `@Observable`** — `ObservableObject` is used throughout.
Otherwise there would be nothing to discuss.

## Work inventory

### Needed to reach iOS 16 (iOS 17 APIs)

| API | Occurrences | Replacement |
|---|---:|---|
| `.onChange(of:) { old, new in }`, the two-parameter form | 37 | Back to the iOS 14 single-parameter form, keeping a copy of the old value where it is needed |
| `.sensoryFeedback` | 8 | `UIImpactFeedbackGenerator` |
| `.symbolEffect` / `.contentTransition(.symbolEffect)` | 8 | Drop, or wrap in `#available` |
| `UIScene.isSceneCaptured` | 5 | `UIScreen.isCaptured` (iOS 11) plus `capturedDidChangeNotification` |
| `ContentUnavailableView` | 3 | Write an empty-state view |
| `AVCaptureDevice.RotationCoordinator` | 2 | Back to the deprecated `videoOrientation` |

About **63 sites**, all point replacements, **with no architectural change**. The one to be
careful with is `isSceneCaptured`: it is a security feature (concealing the recovery phrase and
suspending the signing session during screen recording or mirroring), and the replacement
`UIScreen.isCaptured` is whole-screen rather than per-scene, so its meaning is slightly broader
under iPad multi-window — which for this app is more conservative, and therefore acceptable.

### Additionally needed to reach iOS 15 (iOS 16 APIs)

| API | Occurrences | Replacement |
|---|---:|---|
| `NavigationStack` plus `navigationDestination` | 16 + 3 | **Rewrite as `NavigationView` plus `NavigationLink(isActive:)`** |
| `Grid` / `GridRow` | 14 | `VStack`/`HStack` aligned by hand |
| `Duration` / `Task.sleep(for:)` | 5 | `Task.sleep(nanoseconds:)` |
| `AnyLayout` | 4 | Branch on size class and write two layouts |
| `.scrollBounceBehavior` (16.4) | 4 | Drop |
| `ProposedViewSize` | 3 | Compute sizes directly |
| `.presentationDetents` | 3 | A custom sheet height, or full screen |
| `ViewThatFits` | 2 | Branch on size class |
| `.scrollContentBackground` | 2 | `UITableView.appearance()` |
| `.scrollIndicators` / `.presentationDragIndicator` | 1 + 1 | Drop |
| `Locale.Language.characterDirection` | 1 | `Locale.characterDirection(forLanguage:)` (iOS 8) |

About **55 sites**, but the `NavigationStack` line is not a replacement — it is **an
architectural change**. `AppRouter` currently drives programmatic push and pop from typed route
values (jumping to Pair after creation completes, returning to the welcome page after a wallet
is deleted, resetting the whole stack via `navigationResetEpoch`). iOS 15's `NavigationView`
offers only `isActive` bindings, so all of those flows would need redesigning, and on iPad
`NavigationView` defaults to a split view that would have to be forced into a stack. Several UI
tests assert back-stack behaviour directly and would have to change with it.

## What it buys in devices

| Minimum version | Models additionally covered |
|---|---|
| iOS 17 (current) | iPhone XS / XR (2018) and later |
| iOS 16 | Adds iPhone 8 / X (2017) |
| iOS 15 | Adds iPhone 6s / SE first generation (2015–2016) |

For an offline signer, keeping an old iPhone purely as a signing device is a real use pattern,
so lowering the target has genuine value rather than just padding a number.

## Recommendation

**Drop to iOS 16, not to 15.**

- The 63 iOS 16 sites are mechanical replacements with no architectural risk, and the payoff is
  the iPhone 8 from 2017 — the cheapest and most plentiful tier on the second-hand market.
- The extra cost of iOS 15 is concentrated in the navigation rewrite, and navigation is exactly
  where "where do we return to after signing" and "where do we return to after deleting a
  wallet" live — **coupled to security state**, and the last part of the repository that should
  be disturbed for the sake of compatibility.
- There is also a reason unrelated to models: iOS 15 devices stopped receiving security updates
  long ago. Recommending a device that is no longer patched as a dedicated signing device
  contradicts the app's own security claims. The same applies to the iPhone 8 on iOS 16, so
  whichever tier is chosen, the onboarding pages should say that a dedicated device ought to run
  a version still being maintained.

If this is eventually done, the suggested order is: drop to 16 first, get the full test suite
and the screenshot tour passing, and live with it for a round. iOS 15 should be its own project,
because it touches navigation.
