## Build plan — ordered and concrete

Paths are relative to `/home/user/screentime-app/`.

---

### PHASE 0 — Day 1, before any code (the long-pole item)

**Step 0.1 — Lock the bundle IDs.** Write `Docs/ENTITLEMENT-REQUEST.md` containing the exact, final-cased IDs from the architecture table. Bundle-ID casing mismatch between parent and extension produces an Xcode "Prefix Mismatch" error that blocks archiving and forces a re-request (thread 819573).

**Step 0.2 — Create all 5 App IDs** at `developer.apple.com/account/resources/identifiers/list` and enable **Family Controls** on each.

**Step 0.3 — File 5 distribution entitlement requests.** As the **Account Holder** (not an Admin), at `https://developer.apple.com/contact/request/family-controls-distribution` or via the *Capability Requests* tab. Lead each with the blocking flow and the exact user journey; name `FamilyControls`, `ManagedSettings`, `ManagedSettingsUI`, `DeviceActivity` and the specific extension; position as personal digital wellbeing / self-control; state explicitly that you do not collect usage data for advertising or profiling. Screenshot each submission — there is no confirmation email and no ticket ID. Record the date in `Docs/ENTITLEMENT-REQUEST.md`. **Then stop waiting on it and go build** — nothing in Phase 1–4 needs it.

**Step 0.4 — App Store Connect age-rating questionnaire.** Answer the social-media capability questions (answer: **No**). This is already mandatory for any submission as of September 2026.

**Step 0.5 — Register your own device UDID** on the development provisioning profile for all five App IDs.

---

### PHASE 1 — Scaffold (day 1–2)

**Step 1.1 — `Config/Build.xcconfig`:**
```
TEAM_ID = XXXXXXXXXX
APP_GROUP = group.com.example.gate
BUNDLE_ID_PREFIX = com.example.gate
IPHONEOS_DEPLOYMENT_TARGET = 17.0
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
TARGETED_DEVICE_FAMILY = 1,2
```

**Step 1.2 — `project.yml`.** Define a `ScreenTimeExtension` `targetTemplate` with `type: app-extension`, `SKIP_INSTALL: YES`, `APPLICATION_EXTENSION_API_ONLY: YES`, and `entitlements.path: Config/Gate-Extension.entitlements`. Then define all 8 targets. **The `GateReport` target must be `type: extensionkit-extension`, NOT `app-extension`.**

**Step 1.3 — Write the four Info.plists** in `Config/` exactly as given in apiReference §3. Triple-check: monitor ends in `-extension`; shield **action** has **no** `UI`; shield **configuration** **has** `UI`; report uses `EXAppExtensionAttributes` and **no** `NSExtensionPrincipalClass`.

**Step 1.4 — Entitlements.** `Config/Gate-App.entitlements` and `Config/Gate-Extension.entitlements`, each with exactly `com.apple.developer.family-controls` = `true` and `com.apple.security.application-groups` = `[group.com.example.gate]`. **Verify no `com.apple.developer.deviceactivity*` keys exist** — they are phantom keys that break provisioning.

**Step 1.5 — `Makefile`** with `project: ; xcodegen generate`, and `.gitignore` for `*.xcodeproj` / `*.xcworkspace`.

**Step 1.6 — Generate and VERIFY the pbxproj.** Run `make project`, then inspect: `GateReport` must have `productType = com.apple.product-type.extensionkit-extension`, `explicitFileType = wrapper.extensionkit-extension`, and an embed phase with `dstSubfolderSpec = 16` (Extensions/), **not 13** (PlugIns/). Getting this wrong costs a full App Store review cycle.

**Step 1.7 — `Kernel/Identifiers.swift`** — all shared constants in one place:
```swift
public enum GateID {
    public static let appGroup = "group.com.example.gate"
}
public extension ManagedSettingsStore.Name {
    static func rule(_ id: UUID) -> Self { .init("gate.rule.\(id.uuidString)") }
}
public extension DeviceActivityReport.Context {
    static let totalActivity = Self("gate.totalActivity")
}
```

---

### PHASE 2 — Prove the loop on your own device (day 2–4). **This is the go/no-go gate.**

**Step 2.1 — Minimal `App/GateApp.swift` + `App/AppModel.swift`** with a single button calling `try await AuthorizationCenter.shared.requestAuthorization(for: .individual)`. Build to your device with the **development** signing profile. Confirm `authorizationStatus == .approved`. If this fails, nothing downstream matters — fix signing first.

**Step 2.2 — Picker + shield, hardcoded.** Add `.familyActivityPicker(...)`, store the selection in memory, write `ManagedSettingsStore(named: .rule(id)).shield.applications = selection.applicationTokens`. Press Home, tap a selected app, **see Apple's default shield**. Enforcement is now proven end-to-end.

**Step 2.3 — `Extensions/ShieldConfiguration/GateShieldConfiguration.swift`.** Return a hardcoded `ShieldConfiguration`. Confirm your custom shield replaces Apple's.

**Step 2.4 — `Extensions/ShieldAction/GateShieldAction.swift`.** Implement `handle(action:for:completionHandler:)` returning `.openParentalControlsApp` under `if #available(iOS 26.5, *)`, else `.close`.

**Step 2.5 — 🚨 DEVICE TEST GATE — record results in `Docs/DEVICE-TEST-MATRIX.md`:**
- **(a)** Does `.openParentalControlsApp` actually launch the app under **`.individual`** authorization? The doc wording is parental-centric and there are no field reports — *(unverified)*. **If NO, the whole intervention UX must be redesigned around the notification fallback before you build anything else.**
- **(b)** Does it pass any context (token, action, URL)? Assume not; hand off via the App Group.
- **(c)** Can `GateShieldAction` **write** to the App Group container and can the app read it back? (Foqos proves the `UserDefaults` suite works; you are using coordinated files — verify.)
- **(d)** Can `GateShieldConfiguration` write? *(Only reads are proven — assume read-only in the design.)*

**Step 2.6 — Schedule A/B test.** Register two `DeviceActivityName`s: one `repeats: true` with `[.hour,.minute,.second]` on both ends, one `repeats: false` with full `[.year…second]` on both ends. Log which of `intervalDidStart` / `intervalDidEnd` actually fire. **Lock the schedule design to whichever works on your target iOS and record it.** Do not skip — the dossier's sources contradict each other here.

---

### PHASE 3 — The Kernel (week 1–2). Pure logic, unit-testable without a device.

**Step 3.1 — `Kernel/Model/`.** `Rule`, `LockPolicy`, `PendingChange`, `Grant`, `GateState` — all `Codable`, all flat, all small. `GateState` carries a `schemaVersion: Int` and decodes leniently.

**Step 3.2 — `Kernel/Store/AppGroupContainer.swift`** (paths) and **`GateStateStore.swift`** behind a protocol:
```swift
public protocol StateStoring { func load() throws -> GateState; func save(_ s: GateState) throws }
public final class FileStateStore: StateStoring { /* PropertyListEncoder + .atomic + NSFileCoordinator */ }
```
Keeping it behind a protocol is what lets you swap to the `UserDefaults` suite if step 2.5(c) goes badly.

**Step 3.3 — `Kernel/Store/InboxStore.swift`.** Append-only, one small plist per event, consumed and deleted by the app.

**Step 3.4 — `Kernel/Store/LockClock.swift`.** Keychain-backed deadline with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, mirrored into `state.plist`; on load, trust whichever copy is newer.

**Step 3.5 — `Kernel/Engine/Ratchet.swift`.** The heart of the product:
```swift
public enum MutationDirection { case tighten, loosen }
public enum Mutation { case addTokens(UUID, …), removeTokens(UUID, …), enableRule(UUID), disableRule(UUID),
                       setDelay(TimeInterval), setInstallProtection(Bool), deleteRule(UUID), setRatchet(Bool) }
public struct Ratchet {
    public static func direction(of m: Mutation, in s: GateState) -> MutationDirection
    public static func apply(_ m: Mutation, to s: GateState, now: Date) -> (GateState, PendingChange?)
}
```
Tighten → applied immediately. Loosen → returns a `PendingChange` with `earliestApplyAt = now + s.lock.delay`. **`setDelay` is special:** increasing is a tighten; decreasing costs `oldDelay − newDelay`.

**Step 3.6 — `Kernel/Engine/ScheduleBuilder.swift`.** Builds `DeviceActivitySchedule` and `DeviceActivityEvent` values from `Rule`s, with the component-set rule from step 2.6 **and a hard 20-activity budget check that evicts rather than throws**.

**Step 3.7 — `Kernel/Engine/ActivityNameCodec.swift`.** Encode/decode `gate.rule:`, `gate.grant:`, `gate.revert:` names. Round-trip tested.

**Step 3.8 — `Kernel/Enforcement/TokenGuard.swift`.** `guard tokens.count <= 50` for every shield collection, returning a typed error the UI surfaces. **The API fails silently past 50 — this guard is the only thing standing between you and a rule that shields nothing.**

**Step 3.9 — `Kernel/Enforcement/ShieldWriter.swift`.** Given a `Rule` + resolved tokens, write the correct `ManagedSettingsStore` fields (blocklist vs `.all(except:)` allowlist), applying live grants as **set subtraction** plus `.specific(cats, except: grantedTokens)`. Never `clearAllSettings()` for a temporary unblock.

**Step 3.10 — `Kernel/Engine/Reconciler.swift`.** The single function both the app and the monitor call:
```swift
public struct Reconciler {
    public static func reconcile(now: Date, store: any StateStoring,
                                 center: DeviceActivityCenter,
                                 writer: ShieldWriter) throws -> ReconcileReport
}
```
Expire grants and pending changes → recompute intended shields → write stores → diff `center.activities` against `MonitorPlan` → stop orphans, start missing.

**Step 3.11 — `Tests/GateKernelTests/`.** Swift Testing (`@Test` / `#expect`). Cover: ratchet classification for every `Mutation`; `setDelay` asymmetry; `LockClock` across a simulated reinstall; DST and timezone boundaries in `ScheduleBuilder`; 20-activity eviction; 50-token guard; `ActivityNameCodec` round-trip; `GateState` forward-compat with unknown keys. All injected fakes — `DeviceActivityCenter`, `ManagedSettingsStore`, `AuthorizationCenter` are all unusable in a test process.

---

### PHASE 4 — Wire the extensions (week 2)

**Step 4.1 — `Extensions/ActivityMonitor/GateActivityMonitor.swift`.** **Target ~200 lines. Links `GateKernel` only — never `GateKernelUI`, never SwiftUI, never a networking or analytics SDK.** Every override: read `state.plist`, call `Reconciler.reconcile`, append a breadcrumb, return. No `Task { }` that outlives the callback. `eventDidReachThreshold` must be idempotent and must ignore events whose activity started < 60 s ago (the documented iOS 26.x false-positive signature). Use `os.Logger(subsystem: "com.example.gate.monitor", category: "DeviceActivity")` — `print()` is invisible from an extension.

**Step 4.2 — `Extensions/ShieldConfiguration/GateShieldConfiguration.swift`.** Read `shield.plist` synchronously; return in microseconds. Add `secondaryButtonSubmenuItems` under `if #available(iOS 26.4, *)`. **Static copy only — no countdowns** (stale-config bug FB14237883).

**Step 4.3 — `Extensions/ShieldAction/GateShieldAction.swift`.** Append a grant or bypass-attempt record to `inbox/`, arm the one-shot expiry activity, then respond `.openParentalControlsApp` / `.close`. On scheduling failure, roll the grant back before responding.

**Step 4.4 — `Extensions/Report/GateReportExtension.swift`.** `@main struct GateReportExtension: DeviceActivityReportExtension { var body: some DeviceActivityReportScene { TotalActivityReport { … } } }`. Aggregate **lazily** inside `makeConfiguration(representing:)` with nested `for await` — never build arrays. **Write nothing anywhere; it is silently discarded.**

---

### PHASE 5 — The app (week 2–4)

**Step 5.1 — `App/Screens/OnboardingScreen.swift`** — honest framing, authorization, every `FamilyControlsError` case handled with real copy, Screen Time passcode nudge.

**Step 5.2 — `App/Screens/RuleEditorScreen.swift`** — picker modifier, mode toggle, live token count with the 50-cap warning, schedule editor.

**Step 5.3 — `App/Screens/LockSettingsScreen.swift`** — delay picker, optional partner password, ratchet toggle. Every control routed through `Ratchet.apply`.

**Step 5.4 — `App/Screens/HomeScreen.swift`** — rule list, active/next-boundary state from `DeviceActivitySchedule.nextInterval`, and the persistent pending-changes banner with live countdown.

**Step 5.5 — `App/Screens/InterventionScreen.swift`** — the `.openParentalControlsApp` landing screen: wait → typed reason → issue grant → **"You can open it now — press Home and tap the app."** Below 26.5, this screen is reached by a notification deep link instead.

**Step 5.6 — `App/Screens/RecoveryScreen.swift`** — token-expiry recovery. Observe `ManagedSettingsStore.TokenExpiryMessage` via `NotificationCenter` and call `ManagedSettingsStore.refresh(&tokens)` under `if #available(iOS 26.5, *)`. Reselection is a **tightening** and must never be gated behind the lock.

**Step 5.7 — Reconcile-on-foreground.** In `GateApp.swift`, `.onChange(of: scenePhase)` → poll `authorizationStatus`, run `Reconciler.reconcile`, drain `inbox/`, re-arm `UNCalendarNotificationTrigger` backstops. Request notification authorization here — extensions cannot present the permission prompt, and if the app never asks, every extension-posted notification silently vanishes.

**Step 5.8 — `App/Debug/DebugScreen.swift`** — the full introspection panel plus a "run reconcile now" button. Build it early; it is worth more than any unit test on this stack.

---

### PHASE 6 — 🎉 Personal milestone (end of week 2–4)

**You now have a fully functional app on your own phone, development-signed, with zero Apple approval.** It stays valid for the provisioning profile's 12-month lifetime; re-sign annually. **Stop here if App Store distribution never arrives** — the product is already doing its job for you.

---

### PHASE 7 — App Store readiness (only once "Assigned" appears)

**Step 7.1 — Privacy manifests, five of them.** `Config/Privacy/App-PrivacyInfo.xcprivacy` plus one copy per `.appex`, each added to that target's **Copy Bundle Resources** phase. Each contains:
```xml
<key>NSPrivacyTracking</key><false/>
<!-- deliberately NO NSPrivacyTrackingDomains key — its presence with tracking=false is INVALID -->
<key>NSPrivacyCollectedDataTypes</key><array/>
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>1C8F.1</string></array>
  </dict>
</array>
```
`1C8F.1` is the App-Group-shared reason, **not** `CA92.1`. Add `NSPrivacyAccessedAPICategoryFileTimestamp` / `C617.1` if you stat files in the App Group container, and `NSPrivacyAccessedAPICategorySystemBootTime` / `35F9.1` if you use `mach_absolute_time`-family elapsed-time measurement. **Do not pre-declare categories you do not hit** — an incorrect declaration is itself rejectable (ITMS-91054/91055).

**Step 7.2 — Validate.** `plutil -lint Config/Privacy/*.xcprivacy` on each, then Product → Archive → Organizer → **Generate Privacy Report**.

**Step 7.3 — App Privacy answers: "Data Not Collected"**, truthfully, for a v1 with no account, no server, and no analytics. Apple defines "collect" as transmitting off-device; the report extension renders locally and tokens are opaque. **Adding RevenueCat, Crashlytics, or the v2 partner heartbeat breaks this** — the nutrition label covers the whole binary including bundled SDKs.

**Step 7.4 — Privacy policy** live at a URL, entered in App Store Connect **and** linked in-app without requiring an account (5.1.1(i)). Include the sentence reviewers look for: *Screen Time selections are opaque tokens that never leave the device.*

**Step 7.5 — App Store description must name the integration.** Guideline 2.5.1 requires you to "indicate that integration in their app description." Say plainly that Gate uses Apple's Screen Time (Family Controls) APIs to shield apps and websites the user selects.

**Step 7.6 — `Docs/REVIEW-NOTES.md` → paste into App Review Information.** Must pre-argue 2.5.1, not just give steps:
> This is an adult self-control / digital wellbeing app. It uses FamilyControls, ManagedSettings, ManagedSettingsUI and DeviceActivity for their documented purpose: the user selects their own apps and websites and the app shields them on a schedule the user sets. It uses `FamilyControlsMember.individual`, so **no iCloud account, no Family Sharing group and no second device are needed.**
> **To test (~90 seconds, one device, no login):** 1) Launch → "Get Started" → tap Continue on the iOS Screen Time alert → authenticate with Face ID / Touch ID. 2) "Choose apps to block" → the system picker appears → select 1–2 installed apps → Done. *(By design the app never learns which apps you picked — iOS returns opaque tokens.)* 3) "Start block now." 4) Press Home and tap a selected app — our shield appears. 5) Tap "Not now," reopen the app, tap "End block."
> **Privacy:** all Screen Time data stays on device. The DeviceActivityReport extension is sandboxed by Apple and cannot pass data back to us; selections are opaque tokens. Nothing from the Screen Time APIs is transmitted off device.
> A demo video of the full flow is attached.

**Step 7.7 — Attach a screen recording** in the App Review Information Attachment section. Apple explicitly sanctions this: *"If features require an environment that is hard to replicate… be prepared to provide a demo video."* The shield only renders with a live entitlement — do not make the reviewer discover that.

**Step 7.8 — Paywall audit (Guideline 4.10).** Confirm `requestAuthorization` and `FamilyActivityPicker` are **not** behind the paywall, and that no paid tier is labeled "App Blocking" or "Screen Time."

**Step 7.9 — CI** at `.github/workflows/ci.yml`: `runs-on: macos-26`, explicit `sudo xcode-select -s /Applications/Xcode_26.4.1.app`, `xcodegen generate` + fail on a dirty git tree, `swift test` for the Kernel, and a simulator build with `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`. **CI can compile but can never test any Screen Time behavior** — budget a physical-device manual QA pass every release, on both the shipping iOS and the current beta.
