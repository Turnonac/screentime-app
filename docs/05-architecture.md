## Architecture

### Bundle IDs and App Group

| Target | Bundle ID | Type |
|---|---|---|
| Gate (app) | `com.example.gate` | `application` |
| GateKernel | `com.example.gate.kernel` | `framework` |
| GateKernelUI | `com.example.gate.kernelui` | `framework` |
| GateActivityMonitor | `com.example.gate.activity-monitor` | `app-extension` |
| GateShieldConfiguration | `com.example.gate.shield-configuration` | `app-extension` |
| GateShieldAction | `com.example.gate.shield-action` | `app-extension` |
| GateReport | `com.example.gate.report` | **`extensionkit-extension`** |
| GateWidgets (v2) | `com.example.gate.widgets` | `app-extension` |

**App Group: `group.com.example.gate`** — on the app and every extension.

**Five App IDs need the Family Controls entitlement and five separate distribution requests.** Casing is locked here and must never change.

---

### Process / data-flow diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Gate.app  (your process — the ONLY source of truth)                         │
│    @Observable AppModel                                                      │
│    ├─ AuthorizationCenter.shared.requestAuthorization(for: .individual)      │
│    ├─ .familyActivityPicker(...) ──► FamilyActivitySelection (opaque tokens) │
│    ├─ Ratchet.classify(mutation) ──► apply now  |  queue behind the Lock     │
│    ├─ Reconciler.reconcile()  ◄── RUNS ON EVERY scenePhase == .active        │
│    │     ├─ writes ManagedSettingsStore(named:) × N rules                    │
│    │     ├─ DeviceActivityCenter().stopMonitoring / .startMonitoring         │
│    │     └─ re-arms UNCalendarNotificationTrigger backstops                  │
│    └─ Lock deadline mirrored to KEYCHAIN (survives app deletion)             │
└──────────────┬──────────────────────────────────────────┬────────────────────┘
               │ write (single writer)                    │ read
               ▼                                          │
╔══════════════════════════════════════════════════════════════════════════════╗
║  App Group container  group.com.example.gate                                 ║
║    state.plist         ← GateState, PropertyList, atomic + NSFileCoordinator ║
║    shield.plist        ← pre-rendered shield copy/colors per rule (read-only)║
║    inbox/*.plist       ← APPEND-ONLY events written BY extensions            ║
║    UserDefaults(suite) ← ONLY: stateGeneration: Int (cheap change beacon)    ║
╚══════▲═══════════════════▲══════════════════════▲════════════════════════════╝
       │ read              │ read                 │ read + append
       │                   │                      │
┌──────┴─────────┐  ┌──────┴──────────┐  ┌────────┴────────────┐  ┌───────────┐
│ GateActivity   │  │ GateShield      │  │ GateShieldAction    │  │ GateReport│
│ Monitor .appex │  │ Configuration   │  │ .appex              │  │ .appex    │
│                │  │ .appex          │  │                     │  │(ExtKit)   │
│ 6 MB CEILING   │  │ no network      │  │ no network          │  │ SEALED    │
│ Foundation +   │  │ sub-second      │  │ WRITES grants +     │  │ SANDBOX:  │
│ DeviceActivity │  │ returns         │  │ bypass counters     │  │ NOTHING   │
│ + ManagedSet.  │  │ ShieldConfig    │  │ .openParentalCtrls  │  │ ESCAPES   │
│ NO SwiftUI     │  │ (sees REAL app  │  │ App (26.5+)         │  │ render-   │
│ NO networking  │  │  names — but    │  │                     │  │ only      │
│ NO SwiftData   │  │  can't export)  │  │                     │  │           │
└────────────────┘  └─────────────────┘  └─────────────────────┘  └───────────┘
        │ writes                                  │ writes
        └──────────► ManagedSettingsStore ◄───────┘
                     (system daemon — survives force-quit,
                      reboot, account switch, and app deletion)
```

**Reading the diagram:** the report extension has **no arrow out**. That is the whole point — it renders, and nothing it computes ever reaches you. Everything else communicates exclusively through the App Group container; there is no other supported channel.

---

### Module layer split (driven entirely by the 6 MB ceiling)

```
GateKernel      pure Swift. Foundation only. NO UIKit, NO SwiftUI, NO SwiftData,
                NO networking. APPLICATION_EXTENSION_API_ONLY = YES.
                Linked by: App, ActivityMonitor, ShieldConfiguration, ShieldAction, Report, Widgets.

GateKernelUI    SwiftUI views, colors, formatters.
                Linked by: App, ShieldConfiguration (colors/strings only), Report, Widgets.
                NEVER linked by ActivityMonitor.
```

**Use an Xcode `framework` target, not a local SPM package.** SPM has no first-class `APPLICATION_EXTENSION_API_ONLY` setting; the `.unsafeFlags(["-fapplication-extension"])` workaround makes the package unusable as a versioned dependency and a known Xcode bug lets it override the linking project's settings. Symptom of getting it wrong: *"linking against a dylib which is not safe for use in application extensions"* plus `UIApplication.shared` compiling and then trapping in an extension. If you want `swift test` on Linux, keep a *separate*, strictly platform-agnostic SPM target with zero Apple-framework imports and wrap it in the framework.

---

### Persistence — the decision, and why

**CONTRADICTION IN THE DOSSIER:** Foqos ships in production writing grants to `UserDefaults(suiteName:)` from `ShieldActionDelegate`, and it works. Multiple other reports say writes from extensions return success and never propagate, with the `"Using kCFPreferencesAnyUser with a container is only allowed for System Containers"` warning.

**CALL: an atomic property-list file in the App Group container is the source of truth; `UserDefaults(suiteName:)` holds exactly one integer.**

Rationale: (1) a small `PropertyListDecoder` decode is cheaper than the `UserDefaults`/CFPreferences machinery under a 6 MB ceiling; (2) `NSFileCoordinator` gives explicit cross-process ordering that `UserDefaults` does not; (3) the failure mode of a flaky `UserDefaults` write is a *silently unenforced block*, which is the one failure this product cannot have. **Mark this as an explicit week-1 on-device validation task** — if coordinated file writes misbehave, fall back to the proven Foqos `UserDefaults` suite pattern, which is why the store is behind a protocol.

```swift
// Kernel/Store/AppGroupContainer.swift
public enum AppGroupContainer {
    public static let identifier = "group.com.example.gate"
    public static var url: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)!
    }
    public static var stateURL: URL { url.appendingPathComponent("state.plist") }
    public static var shieldURL: URL { url.appendingPathComponent("shield.plist") }
    public static var inboxURL: URL  { url.appendingPathComponent("inbox", isDirectory: true) }
}
```

**Single-writer discipline (mandatory — three processes can race):**
- The **app** is the only writer of `state.plist` and `shield.plist`.
- **Extensions never mutate `state.plist`.** `GateShieldAction` *appends* one tiny plist per event into `inbox/` (`grant-<uuid>.plist`, `bypass-<uuid>.plist`). `GateActivityMonitor` reads `state.plist`, writes `ManagedSettingsStore`, and appends a breadcrumb.
- The **app compacts** `inbox/` into `state.plist` on every foreground reconcile and deletes the consumed files.

Keep `GateState` **under 8 KB**. Store selections once keyed by rule ID and reference them by ID elsewhere — `FamilyActivitySelection` blobs are large, "especially if you use `includeEntireCategory`."

**Keychain:** the lock deadline and lock config hash live in a Keychain item with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. **Keychain survives app deletion; the App Group container does not.** This is what makes delete-and-reinstall not reset the delay.

**SwiftData / Core Data:** allowed in the **app and widget only**, for the v2 journal/history, via `ModelConfiguration(groupContainer: .identifier("group.com.example.gate"))`. **Never in the monitor.** A `ModelContainer` schema build alone can approach the 6 MB budget before your code runs, and a jetsam kill in `eventDidReachThreshold` means the block silently never applies.

---

### The `DeviceActivityName` codec (load-bearing)

Monitor callbacks receive **only the name** — no tokens, no dates, no userInfo. Encode context into the string:

```swift
// Kernel/Engine/ActivityNameCodec.swift
// "gate.rule:<ruleUUID>"                       repeating daily window
// "gate.grant:<ruleUUID>|<grantUUID>"          one-shot expiry timer
// "gate.revert:<ruleUUID>|<pendingChangeUUID>" auto-revert timer
```

**Activity budget (hard cap 20, app + all extensions combined):**

| Kind | Count |
|---|---|
| Repeating rule windows | ≤ 8 (one per rule — **never one per weekday**) |
| Live grant expiries | ≤ 6 |
| Auto-revert timers | ≤ 4 |
| Headroom | 2 |

The `Reconciler` enforces this and evicts the furthest-out timer if the budget is exceeded, rather than letting `startMonitoring` throw `.excessiveActivities` at an arbitrary moment.

---

### Enforcement layering — three independent paths, by design

1. **`ManagedSettingsStore`** — the actual enforcement; system-side, survives everything.
2. **`GateActivityMonitor`** — the *fast* path (applies/lifts at interval boundaries). **Best-effort only:** 6 MB ceiling, killed for memory or idleness, and reported as never launched at all on iOS 26.3.1 with correct configuration.
3. **Foreground reconciliation + `UNCalendarNotificationTrigger` backstops** — the *correct* path. Every deadline is an absolute timestamp in `state.plist`; the app recomputes ground truth from timestamps on every activation, and a notification at each boundary gives the user a reason to open the app.

Every monitor callback is written assuming a **cold start**: re-read everything from the App Group, hold no state in extension memory across callbacks, and be idempotent (the same event can fire twice).

---

### Repo layout

```
/home/user/screentime-app/
├── project.yml                          # XcodeGen — the single source of truth
├── Makefile                             # `make project`, `make test`, `make lint`
├── .gitignore                           # *.xcodeproj, *.xcworkspace
├── .github/workflows/ci.yml
├── Config/
│   ├── Build.xcconfig                   # TEAM_ID, APP_GROUP, BUNDLE_ID_PREFIX, DEPLOYMENT_TARGET
│   ├── Gate-App.entitlements
│   ├── Gate-Extension.entitlements      # shared by all four extensions
│   ├── Gate-Info.plist
│   ├── ActivityMonitor-Info.plist
│   ├── ShieldConfiguration-Info.plist
│   ├── ShieldAction-Info.plist
│   ├── Report-Info.plist                # EXAppExtensionAttributes form
│   └── Privacy/
│       ├── App-PrivacyInfo.xcprivacy
│       └── Extension-PrivacyInfo.xcprivacy
├── Kernel/                              # GateKernel.framework
│   ├── Identifiers.swift                # App Group, store names, activity names, report contexts
│   ├── Model/{Rule,LockPolicy,PendingChange,Grant,GateState,ShieldCopy}.swift
│   ├── Store/{AppGroupContainer,GateStateStore,InboxStore,LockClock}.swift
│   ├── Engine/{Ratchet,Reconciler,ScheduleBuilder,ActivityNameCodec,GrantEngine}.swift
│   └── Enforcement/{ShieldWriter,MonitorPlan,TokenGuard}.swift
├── KernelUI/                            # GateKernelUI.framework
│   ├── Theme.swift
│   └── Components/{CountdownView,RuleRow,PendingBanner}.swift
├── App/
│   ├── GateApp.swift
│   ├── AppModel.swift                   # @Observable
│   ├── Screens/{Onboarding,Home,RuleEditor,LockSettings,Intervention,Recovery,Stats}Screen.swift
│   ├── Intents/StartRuleIntent.swift    # v2 — must also be in the widget target
│   └── Debug/DebugScreen.swift
├── Extensions/
│   ├── ActivityMonitor/GateActivityMonitor.swift
│   ├── ShieldConfiguration/GateShieldConfiguration.swift
│   ├── ShieldAction/GateShieldAction.swift
│   └── Report/{GateReportExtension,TotalActivityReport,TotalActivityView}.swift
├── Widgets/                             # v2
├── Tests/GateKernelTests/{RatchetTests,LockClockTests,ScheduleBuilderTests,GrantEngineTests,StateCodecTests}.swift
└── Docs/{ENTITLEMENT-REQUEST.md,REVIEW-NOTES.md,DEVICE-TEST-MATRIX.md}
```

**Project generation: XcodeGen, not Tuist, not hand-written `pbxproj`.** Tuist requires Xcode 16.3+ to compile its Swift manifests, so it cannot generate on a machine without Xcode; `project.yml` is plain YAML, editable anywhere, and XcodeGen has the `extensionkit-extension` target type and the "Embed ExtensionKit Extensions" phase the report extension requires. Hand-written `pbxproj` across 8 targets × entitlements × embed phases is exactly the merge-conflict surface generators exist to remove — and the `dstSubfolderSpec = 16` embed spec is easy to silently corrupt by hand.
