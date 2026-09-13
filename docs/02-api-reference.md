## API reference — exact surface

### 1. Frameworks and platform floors

| Framework | Availability |
|---|---|
| `FamilyControls` | iOS 15.0, iPadOS 15.0, Mac Catalyst 15.0 |
| `ManagedSettings` | iOS 15.0, iPadOS 15.0, Mac Catalyst 15.0 (`ManagedSettingsStore` also tvOS 26.0) |
| `ManagedSettingsUI` | iOS 15.0, iPadOS 15.0, Mac Catalyst 15.0 |
| `DeviceActivity` | iOS 15.0; `DeviceActivityReport*` / `DeviceActivityFilter` / `DeviceActivityData` / `DeviceActivityResults` = iOS 16.0 |

**Verified: zero symbols in any of the four frameworks are marked introduced in iOS 27.0.** All 402 documented symbols were enumerated: 237 at 15.0, 1 at 15.2, 105 at 16.0, 8 at 17.0, 12 at 17.4, 1 at 26.0, 1 at 26.2, 21 at 26.4, 9 at 26.5, 0 at 27.0, 0 marked beta. iOS 27's Time Allowances and Ask to Browse shipped with **no developer API**.

**DECISION — deployment target `IPHONEOS_DEPLOYMENT_TARGET = 17.0`.** Rationale: 16.0 is the hard floor for `.individual` and `DeviceActivityReport`; 17.0 buys `@Observable` at negligible install-base cost in Sept 2026; everything above is `@available`-gated. *Your own dev device should run iOS 26.5+ so the primary intervention loop works from day one.*

---

### 2. Entitlements — exact strings

```xml
<!-- Config/Gate-App.entitlements AND Config/Gate-Extension.entitlements -->
<key>com.apple.developer.family-controls</key>
<true/>
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.example.gate</string>
</array>
```

- `com.apple.developer.family-controls` — Boolean. iOS 15.0+, iPadOS 15.0+, Mac Catalyst 15.0+, visionOS 1.0+. Xcode capability label **"Family Controls"**. Required before calling `requestAuthorization(for:)` or `revokeAuthorization(completionHandler:)`. Xcode adds it automatically to any target created from a Screen Time extension template.
- `com.apple.developer.family-controls.app-and-website-usage` — Boolean. **iOS 26.4+ / iPadOS 26.4+ only.** Xcode capability label **"Family Controls App And Website Usage"**. Required for `.approvedWithDataAccess` and `FamilyActivityData`. **Do not ship this in v1–v2** (see hardConstraints).
- `com.apple.security.application-groups` — Array of `group.`-prefixed strings. Required on the app and **every** extension.

**Phantom entitlements that will break your build if present:** `com.apple.developer.deviceactivity` and `com.apple.developer.deviceactivity.reporting` **do not exist**. Developers hand-add them chasing "missing entitlement" errors; they cause provisioning-profile mismatch failures (threads 800785, 801843). Delete them.

---

### 3. Extension point identifiers — all four, exact, with the traps

| Extension | `NSExtensionPointIdentifier` | Plist shape |
|---|---|---|
| **Device Activity Monitor** | `com.apple.deviceactivity.monitor-extension` | Classic `NSExtension` dict **with** `NSExtensionPrincipalClass` |
| **Shield Configuration** | `com.apple.ManagedSettingsUI.shield-configuration-service` | Classic `NSExtension` dict **with** `NSExtensionPrincipalClass` |
| **Shield Action** | `com.apple.ManagedSettings.shield-action-service` | Classic `NSExtension` dict **with** `NSExtensionPrincipalClass` |
| **Device Activity Report** | `com.apple.deviceactivityui.report-extension` | **`EXAppExtensionAttributes` / `EXExtensionPointIdentifier` — NO principal class** |

**Trap 1 — the asymmetry is real and deliberate.** Shield *Configuration* uses `ManagedSettingsUI` (it vends UI); Shield *Action* uses `ManagedSettings` (it vends behavior). Using `com.apple.ManagedSettingsUI.shield-action-service` builds and runs locally but is rejected by App Store Connect: *"Invalid Info.plist value. The value of the NSExtensionPointIdentifier key, com.apple.ManagedSettingsUI.shield-action-service, in the Info.plist of "YourApp.app/PlugIns/ShieldActionExtension.appex" is invalid."* (Apple DTS, thread 814945.)

**Trap 2 — dropping `-extension` from the monitor identifier.** `com.apple.deviceactivity.monitor` silently produces an extension that is **never launched**. `startMonitoring` still succeeds and `DeviceActivityCenter().activities` still lists the activity, so there is no runtime signal (thread 820956).

**Trap 3 — the report extension catch-22.** With `NSExtensionPrincipalClass` present, device install fails with `Error 3002 AppexBundleContainsClassOrStoryboard`. Without it, App Store Connect rejects with *"Missing Info.plist values. No values for NSExtensionMainStoryboard or NSExtensionPrincipalClass found."* (note ASC names `PlugIns/` — that's the tell). **Resolution: make it a true ExtensionKit extension.**

```
productType       = com.apple.product-type.extensionkit-extension
explicitFileType  = wrapper.extensionkit-extension
embed dstSubfolderSpec = 16   (Extensions/, NOT 13 = PlugIns/)
dstPath           = $(EXTENSIONS_FOLDER_PATH)
```

Working plists:

```xml
<!-- Config/ActivityMonitor-Info.plist -->
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.deviceactivity.monitor-extension</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).GateActivityMonitor</string>
</dict>

<!-- Config/ShieldConfiguration-Info.plist -->
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.ManagedSettingsUI.shield-configuration-service</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).GateShieldConfiguration</string>
</dict>

<!-- Config/ShieldAction-Info.plist -->
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.ManagedSettings.shield-action-service</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).GateShieldAction</string>
</dict>

<!-- Config/Report-Info.plist  (whole file body) -->
<key>EXAppExtensionAttributes</key>
<dict>
  <key>EXExtensionPointIdentifier</key>
  <string>com.apple.deviceactivityui.report-extension</string>
</dict>
```

---

### 4. Authorization — `FamilyControls`

```swift
final class AuthorizationCenter: ObservableObject {
    static let shared: AuthorizationCenter
    func requestAuthorization(for member: FamilyControlsMember) async throws   // iOS 16.0
    func revokeAuthorization(completionHandler: (Result<Void, any Error>) -> Void)  // iOS 15.0
    var authorizationStatus: AuthorizationStatus
    var $authorizationStatus: Published<AuthorizationStatus>.Publisher
    // DEPRECATED: requestAuthorization(completionHandler:)
}

@objc enum FamilyControlsMember {      // iOS 16.0
    case child        // parent/guardian credential required; EXCLUSIVE, one app per device
    case individual   // device owner, Face ID / Touch ID; ANY NUMBER of apps per device
    var description: String
}

enum AuthorizationStatus {             // iOS 15.0
    case notDetermined
    case denied
    case approved
    case approvedWithDataAccess        // iOS 26.4 — EU-only for customers, one app per device
    var description: String
}

enum FamilyControlsError: LocalizedError {
    case invalidAccountType              // device not signed into a valid iCloud account
    case authorizationConflict           // another authorized app already provides parental controls (.child only)
    case authorizationCanceled
    case invalidArgument                 // ← what you get on Simulator
    case unavailable
    case restricted
    case networkError                    // enrollment requires network
    case authenticationMethodUnavailable // NO DEVICE PASSCODE SET — hard prerequisite for .individual
    case unauthorized                    // FamilyActivityData outside the EU
    var errorDescription: String?
}
```

Call site: `try await AuthorizationCenter.shared.requestAuthorization(for: .individual)`.

Apple: *"Always request authorization when your app first launches."* After approval, repeat calls do **not** re-prompt biometrics. Status can change externally (parent changes it in Settings, another app takes data access). **Poll `authorizationStatus` on every foreground** — do not trust the publisher (thread 820796: it does not emit on revoke while backgrounded without a debugger attached; open, no Apple response).

---

### 5. Selection and tokens

```swift
struct FamilyActivitySelection: Codable, Equatable {   // NOT Hashable
    init()
    init(includeEntireCategory: Bool)
    let includeEntireCategory: Bool
    var applicationTokens: Set<ApplicationToken>
    var categoryTokens:    Set<ActivityCategoryToken>
    var webDomainTokens:   Set<WebDomainToken>
    var applications: Set<Application>          // bundleIdentifier / localizedDisplayName are nil under .approved
    var categories:   Set<ActivityCategory>
    var webDomains:   Set<WebDomain>
}

struct Token<T>: Codable, Equatable, Hashable   // ManagedSettings
typealias ApplicationToken      = Token<Application>
typealias ActivityCategoryToken = Token<ActivityCategory>
typealias WebDomainToken        = Token<WebDomain>

struct Application {
    init(bundleIdentifier: String); init(token: ApplicationToken)
    let bundleIdentifier: String?       // nil outside ShieldConfigurationDataSource
    let localizedDisplayName: String?   // nil outside ShieldConfigurationDataSource
    let token: ApplicationToken?
}
struct WebDomain { init(domain: String); init(token: WebDomainToken); let domain: String? }
struct ActivityCategory { init(token: ActivityCategoryToken); let localizedDisplayName: String?; let token: ActivityCategoryToken? }

@MainActor struct FamilyActivityPicker: View {      // iOS 15.0
    init(selection: Binding<FamilyActivitySelection>)
    init(headerText: String?, footerText: String?, selection: Binding<FamilyActivitySelection>)
}
extension View {
    func familyActivityPicker(title: String?, headerText: String? = nil, footerText: String? = nil,
                              isPresented: Binding<Bool>,
                              selection: Binding<FamilyActivitySelection>) -> some View   // iOS 26.2 for the 5-arg form
}
```

**Use the `.familyActivityPicker(...)` modifier, not a raw `.sheet { FamilyActivityPicker(...) }`** — the raw sheet is a known source of layout bugs. The picker runs out-of-process; the host app never learns what was chosen.

Persist via `JSONEncoder` → App Group. **Apple: "If a user, parent, or guardian revokes authorization of your app, any tokens that `FamilyActivitySelection` provided while your app was authorized are voided."**

---

### 6. Enforcement — `ManagedSettingsStore`

```swift
class ManagedSettingsStore {
    init()                                                  // the .default store
    convenience init(named: ManagedSettingsStore.Name)      // iOS 16.0; auto-shared with all your extensions
    struct Name { static let `default`: Name }

    var shield: ShieldSettings
    var application: ApplicationSettings     // blockedApplications, denyAppInstallation, denyAppRemoval
    var webContent: WebContentSettings       // blockedByFilter: WebContentSettings.FilterPolicy?
    var account: AccountSettings             // lockAccounts
    var appStore: AppStoreSettings           // denyInAppPurchases, maximumRating, requirePasswordForPurchases
    var cellular: CellularSettings           // lockAppCellularData, lockCellularPlan, lockESIM
    var dateAndTime: DateAndTimeSettings     // requireAutomaticDateAndTime
    var gameCenter: GameCenterSettings       // denyMultiplayerGaming, denyAddingFriends
    var media: MediaSettings                 // maximumMovieRating, maximumTVShowRating, denyExplicitContent, …
    var passcode: PasscodeSettings           // lockPasscode
    var safari: SafariSettings               // cookiePolicy, denyAutoFill
    var siri: SiriSettings                   // denySiri

    func clearAllSettings()

    // iOS 26.5:
    var isActive: Bool { get set }                                   // false ⇒ excluded from the effective-settings calc
    static var stores: Set<ManagedSettingsStore.Name> { get }
    func deleteStore()
    static func deleteStores(_ names: Set<ManagedSettingsStore.Name>)
    struct TokenExpiryMessage                                        // posted to NotificationCenter on token expiry
    static func refresh(_ tokens: inout [ApplicationToken]) throws
    static func refresh(_ tokens: inout [ActivityCategoryToken]) throws
    static func refresh(_ tokens: inout [WebDomainToken]) throws

    // Readable with NO Family Controls authorization:
    var effectiveMaximumMovieRating: Int { get }
    var effectiveMaximumTVShowRating: Int { get }
    var effectiveDenyExplicitContent: Bool { get }
}

struct ShieldSettings {
    var applications:        Set<ApplicationToken>?
    var webDomains:          Set<WebDomainToken>?
    var applicationCategories: ShieldSettings.ActivityCategoryPolicy<Application>?
    var webDomainCategories:   ShieldSettings.ActivityCategoryPolicy<WebDomain>?
}
enum ShieldSettings.ActivityCategoryPolicy<Activity> {
    case none
    case all(except: Set<Token<Activity>>)                              // allowlist mode
    case specific(Set<ActivityCategoryToken>, except: Set<Token<Activity>>)
}
```

Apple's non-guarantee, verbatim: *"The system doesn't guarantee that the settings you specify govern the device's behavior. The system is responsible for determining its effective state based on all the settings it receives."* Setting a property to `nil` deletes your configuration for that setting. **Your app is exempt from `.all`** — your own app never gets shielded by your own allowlist.

**DECISION — use `shield.applications`, never `application.blockedApplications`.** The latter has a documented Guideline 2.5.1 rejection precedent (thread 776058) even for an entitlement-holding developer using it exactly as Apple documents it; the appeal was answered with the same copy-pasted text. `shield.applications` is also what gives you the `ShieldConfiguration` + `ShieldAction` UI surface you need.

Write pattern (blocklist + allowlist), derived from shipping code:

```swift
let store = ManagedSettingsStore(named: .init("gate.rule.\(ruleID)"))
if allowlistMode {
    store.shield.applicationCategories = .all(except: allowedAppTokens)
    store.shield.webDomainCategories   = .all(except: allowedWebTokens)
} else {
    store.shield.applications = appTokens.isEmpty ? nil : appTokens
    store.shield.applicationCategories = categoryTokens.isEmpty
        ? nil : .specific(categoryTokens, except: perAppExceptions)
    store.shield.webDomains = webTokens.isEmpty ? nil : webTokens
}
store.application.denyAppInstallation = installProtectionSolid
```

Temporary unblock = **set subtraction** on the shielded set plus `.specific(categories, except: grantedAppTokens)` — never `clearAllSettings()`.

---

### 7. Scheduling and events — `DeviceActivity`

```swift
struct DeviceActivityCenter {                                   // a STRUCT, not a class
    init()
    func startMonitoring(_ activity: DeviceActivityName,
                         during schedule: DeviceActivitySchedule,
                         events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]) throws
    func stopMonitoring(_ activities: [DeviceActivityName])
    var activities: [DeviceActivityName]
    func events(for: DeviceActivityName) -> [DeviceActivityEvent.Name: DeviceActivityEvent]
    func schedule(for: DeviceActivityName) -> DeviceActivitySchedule?
}
enum DeviceActivityCenter.MonitoringError: LocalizedError {
    case excessiveActivities    // "The maximum number of activities that can be monitored at one time
                                //  by an app and its extensions is twenty."
    case intervalTooLong        // "The maximum interval length … is one week."
    case intervalTooShort       // "The minimum interval length … is fifteen minutes."
    case invalidDateComponents
    case unauthorized
    var errorDescription: String?; var recoverySuggestion: String?
}

struct DeviceActivitySchedule {
    init(intervalStart: DateComponents, intervalEnd: DateComponents,
         repeats: Bool, warningTime: DateComponents? = nil)
    var nextInterval: DateInterval?     // next, or current if ongoing — use for UI countdowns
}

struct DeviceActivityEvent {
    init(applications: Set<ApplicationToken>, categories: Set<ActivityCategoryToken>,
         webDomains: Set<WebDomainToken>, threshold: DateComponents)
    init(applications:categories:webDomains:threshold:includesPastActivity: Bool)   // iOS 17.4
    var includesPastActivity: Bool      // iOS 17.4
    struct Name
}
```

`startMonitoring` **overwrites** any previous schedule+events for the same `DeviceActivityName`. Always `stopMonitoring([name])` first to avoid stale duplicates and stay under the 20-activity cap.

**CONTRADICTION RESOLVED — `DateComponents` granularity.** Thread 729841 reports only `[.hour, .minute, .second]` on *both* ends delivers both callbacks; Foqos ships full `[.year,.month,.day,.hour,.minute,.second]` on both ends and depends on `intervalDidEnd`. Thread 726331 shows *mismatched* component sets cause instant threshold breaches (the previous start resolves after the previous end, so the schedule reads as continuously active for days). **The invariant both sides agree on is: never mismatch the component set between `intervalStart` and `intervalEnd`.** My call:

- **Repeating daily windows (`repeats: true`) → `[.hour, .minute, .second]` on both ends.** A repeating schedule is a time-of-day concept; adding `.day` makes it an absolute date and conflicts with `repeats`.
- **One-shot expiry timers (`repeats: false`) → `[.year,.month,.day,.hour,.minute,.second]` on both ends**, start = `Calendar.current.startOfDay(for: now)` so the interval is already ongoing (system calls `intervalDidStart` immediately) and end = `max(expiresAt, now + 60)` to clear the 15-minute floor. This is Foqos's proven grant scheduler.
- A/B test both on device in week 1 against the target iOS build. This is an explicit validation task, not an assumption.

**`includesPastActivity` accounting quirk, verbatim:** *"if your app calls [startMonitoring] at 1:30pm with a schedule of 1:00pm to 2:00pm, then this boolean determines whether any activity between 1:00pm and 1:30pm will contribute to its threshold. If set to true and the event's schedule does not start on a round hour (for example, it starts at 1:15pm instead of 1:00pm), the system will include device activity from the start of the nearest round hour."* Set it explicitly to `false` for session-scoped events.

**"Activity" is defined as frontmost screen time.** Web domain activity includes domains visited in Safari or any third-party browser that contributes usage via an `STWebpageController`.

---

### 8. Monitor callbacks — `DeviceActivityMonitor`

```swift
@objc class DeviceActivityMonitor: NSObject {          // NSExtensionPrincipalClass target
    func intervalDidStart(for activity: DeviceActivityName)
    func intervalDidEnd(for activity: DeviceActivityName)
    func intervalWillStartWarning(for activity: DeviceActivityName)   // needs schedule.warningTime
    func intervalWillEndWarning(for activity: DeviceActivityName)     // needs schedule.warningTime
    func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName)
    func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName)
}
```

Always call `super`. **There is no "app opened" or "app closed" callback anywhere in the API.**

**The only payload is the name.** No tokens, no dates, no userInfo. Encode structured context *into* the `DeviceActivityName` string — e.g. `"gate.grant:<ruleUUID>|<grantUUID>"` — and parse it back.

**Timing semantics, verbatim from Apple:** *"Activity begins when someone first uses a device within the scheduled time interval and ends when someone first uses the device outside of the interval. The system only invokes the [intervalDidStart] and [intervalDidEnd] when the device is in use."* **Exact-time start/stop of a block is impossible.**

---

### 9. Shield UI — `ManagedSettingsUI`

```swift
struct ShieldConfiguration {                     // all properties are `let` and Optional (nil = system default)
    let backgroundBlurStyle: UIBlurEffect.Style?
    let backgroundColor: UIColor?
    let icon: UIImage?
    let title: ShieldConfiguration.Label?
    let subtitle: ShieldConfiguration.Label?
    let primaryButtonLabel: ShieldConfiguration.Label?
    let primaryButtonBackgroundColor: UIColor?
    let secondaryButtonLabel: ShieldConfiguration.Label?
    let secondaryButtonSubmenuItems: [String]?   // iOS 26.4, MAX 3, system adds Cancel
    struct Label { init(text: String, color: UIColor); let text: String; let color: UIColor }
}

@objc class ShieldConfigurationDataSource: NSObject {
    func configuration(shielding application: Application) -> ShieldConfiguration
    func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration
    func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration
    func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration
}
```

**There is no `secondaryButtonBackgroundColor`.** Total customization surface: blur style, background color, one icon, two colored labels, two colored button labels, one button background color, and (26.4+) up to three submenu strings. No custom views, no SwiftUI, no animation, no text field, no live countdown.

Apple, verbatim: *"The system provides your extension with the display names, bundle identifiers, and domains for each application, website, or category it shields"* — so **inside this extension you DO get real names**, even though your app cannot. And: *"your extension runs in a sandbox. This sandbox prevents your extension from making network requests or moving sensitive content outside the extension's address space. The system provides a default appearance for any methods that your subclass doesn't override, or if it takes too long."* No numeric timeout published — treat as sub-second and synchronous.

**Known defect (FB14237883, open ~2 years):** if you apply a shield while the target app is already frontmost, iOS reuses a stale/recycled `ShieldConfiguration`, and there is no API to force a re-request. **Never put a live countdown or state-dependent text in shield copy.**

---

### 10. Shield actions — `ManagedSettings`

```swift
@objc class ShieldActionDelegate: NSObject {
    func handle(action: ShieldAction, for application: ApplicationToken,
                completionHandler: @escaping (ShieldActionResponse) -> Void)
    func handle(action: ShieldAction, for category: ActivityCategoryToken,
                completionHandler: @escaping (ShieldActionResponse) -> Void)
    func handle(action: ShieldAction, for webDomain: WebDomainToken,
                completionHandler: @escaping (ShieldActionResponse) -> Void)
}

enum ShieldAction {
    case primaryButtonPressed
    case secondaryButtonPressed
    case firstSecondarySubmenuItemPressed     // iOS 26.4
    case secondSecondarySubmenuItemPressed    // iOS 26.4
    case thirdSecondarySubmenuItemPressed     // iOS 26.4
}

enum ShieldActionResponse {
    case close                      // close the app / browser
    case `defer`                    // keep shield up and re-draw it (backtick required — Swift keyword)
    case none
    case openParentalControlsApp    // iOS 26.5 — OPEN YOUR APP
}
```

**Asymmetry that bites:** `ShieldConfigurationDataSource` receives an `Application` (with names); `ShieldActionDelegate` receives a bare `ApplicationToken`. Apple: *"The system doesn't provide the name of a shielded Application, ActivityCategory, or WebDomain to preserve the Family Sharing group's privacy."*

Canonical handler:

```swift
override func handle(action: ShieldAction, for application: ApplicationToken,
                     completionHandler: @escaping (ShieldActionResponse) -> Void) {
    switch action {
    case .primaryButtonPressed:
        GateStateStore.shared.recordBypassAttempt(token: application)   // App Group write
        if #available(iOS 26.5, *) { completionHandler(.openParentalControlsApp) }
        else { postDeepLinkNotification(); completionHandler(.close) }
    case .firstSecondarySubmenuItemPressed:
        issueGrant(token: application, minutes: 1);  completionHandler(.close)
    case .secondSecondarySubmenuItemPressed:
        issueGrant(token: application, minutes: 15); completionHandler(.close)
    case .thirdSecondarySubmenuItemPressed:
        issueGrant(token: application, minutes: 60); completionHandler(.close)
    default:
        completionHandler(.close)
    }
}
```

**`(unverified)`: whether `.openParentalControlsApp` works under `.individual` authorization at all** — the doc wording is parental-centric and no field reports exist. **`(unverified)`: whether it passes any context** (which token, which action, a URL). Assume it cold-launches with no payload and hand off through the App Group first. **Both must be device-tested on day 1.**

---

### 11. Reporting — display-only, sandboxed

```swift
@MainActor struct DeviceActivityReport: View {                      // iOS 16.0
    init(_ context: DeviceActivityReport.Context, filter: DeviceActivityFilter)
    struct Context: RawRepresentable { init(_ : String); var rawValue: String }
}
protocol DeviceActivityReportExtension: AppExtension {              // ExtensionKit, @main
    associatedtype Body: DeviceActivityReportScene
    var body: Self.Body { get }
}
protocol DeviceActivityReportScene: AppExtensionScene {
    associatedtype Configuration
    associatedtype Content: View
    var context: DeviceActivityReport.Context { get }
    var content: (Self.Configuration) -> Self.Content { get }
    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> Self.Configuration
}

struct DeviceActivityFilter {
    init(segment: SegmentInterval, devices: Devices?, applications: Set<ApplicationToken>,
         categories: Set<ActivityCategoryToken>, webDomains: Set<WebDomainToken>)
    enum SegmentInterval { case daily(during: DateInterval); case hourly(during: DateInterval); case weekly(during: DateInterval) }
}

// Readable ONLY inside the extension — a three-level async tree:
DeviceActivityData → .activitySegments: DeviceActivityResults<ActivitySegment>
  ActivitySegment  → dateInterval, totalActivityDuration, longestActivity: DateInterval?,
                     firstPickup: Date?, totalPickupsWithoutApplicationActivity: Int,
                     categories: DeviceActivityResults<CategoryActivity>
  CategoryActivity → category, totalActivityDuration,
                     applications: DeviceActivityResults<ApplicationActivity>,
                     webDomains:  DeviceActivityResults<WebDomainActivity>
  ApplicationActivity → application, totalActivityDuration, numberOfPickups: Int, numberOfNotifications: Int
```

Every level is a separate async sequence requiring `for await`. There is **no flat top-level applications list** — per-app data is reachable only by descending through categories. Materializing everything into arrays is the main cause of black-screen terminations. **One `DeviceActivityReport` view per screen; three or more on one screen is a reported crash threshold.**

Apple DTS, verbatim answer to *"Is DeviceActivityReportExtension intentionally sandboxed so Screen Time data cannot be exported to the containing app?"* → **"Yes."** Confirmed-blocked channels: App Group `UserDefaults` writes (silently dropped), App Group `FileManager` writes, HTTP, local notifications, `UIPasteboard`, iCloud KVS (`synchronize()` returns false).

---

### 12. EU-only de-tokenization (iOS 26.4) — *documented, not recommended for v1–v3*

```swift
final class FamilyActivityData {                                   // iOS 26.4
    static let shared: FamilyActivityData
    var activityCategories: Set<ActivityCategory> { get async throws }
    var installedApplications: [Application] { get async throws }
    var visitedWebDomains: [WebDomain] { get async throws }
}
extension DeviceActivityData {
    static func activityData(filteredBy filter: DeviceActivityFilter = .init(),
                             using policy: DeviceActivityData.Policy = .cached)
        -> some AsyncSequence<DeviceActivityData, any Error>        // the ONLY sanctioned sandbox escape
    enum Policy { case cached; case live }
    enum Error { case unavailable; case unauthorized; case missingData; var errorDescription: String? }
}
```

Requires `.approvedWithDataAccess` + `com.apple.developer.family-controls.app-and-website-usage`. Apple, verbatim: *"Customer installations of your app can only use the class on devices located in the EU that are signed in with an Apple Account with an EU country or region."* Outside the EU, `authorizationStatus` **never** returns `.approvedWithDataAccess`.

---

### 13. Version-gate cheat sheet

| iOS | Unlocks |
|---|---|
| 15.0 | All four frameworks, `AuthorizationCenter`, `FamilyActivityPicker`, `FamilyActivitySelection`, all `Token` types, `ManagedSettingsStore` + all settings groups, `ShieldConfiguration` (8-arg init), `ShieldConfigurationDataSource`, `ShieldActionDelegate`, `ShieldAction` (2 cases), `ShieldActionResponse` (3 cases), `DeviceActivityCenter`, `DeviceActivitySchedule`, `DeviceActivityEvent` (4-arg), `DeviceActivityMonitor` (6 callbacks) |
| **16.0** | `FamilyControlsMember`, `requestAuthorization(for:)`, `.individual`, named `ManagedSettingsStore`s, `DeviceActivityReport(Extension/Scene/Builder)`, `DeviceActivityFilter`, `DeviceActivityData`, `DeviceActivityResults`, `SegmentInterval` |
| **17.0** | `@Observable` (Observation) — **project floor** |
| 17.4 | `DeviceActivityEvent.includesPastActivity` + 5-arg init |
| 18.0 | `ControlWidget` / `ControlWidgetButton` / `ControlWidgetToggle` |
| 26.0 | `DeclaredAgeRange` (separate framework), `PermissionKit` |
| 26.2 | 5-arg `.familyActivityPicker(title:headerText:footerText:isPresented:selection:)` |
| **26.4** | `AuthorizationStatus.approvedWithDataAccess`, `FamilyActivityData`, `DeviceActivityData.activityData(filteredBy:using:)`, `.Policy`, `.Error`, `com.apple.developer.family-controls.app-and-website-usage`, `ShieldConfiguration.secondaryButtonSubmenuItems` + 9-arg init, `ShieldAction.{first,second,third}SecondarySubmenuItemPressed` |
| **26.5** | `ShieldActionResponse.openParentalControlsApp`, `ManagedSettingsStore.isActive`, `.stores`, `deleteStore()`, `deleteStores(_:)`, `TokenExpiryMessage`, `refresh(_:)` ×3 |
| 27.0 | **Nothing.** Zero Screen Time symbols. |

All 26.4/26.5 symbols are **GA, not beta**, as of Sept 2026.

---

### 14. Hard numeric limits (enforce these yourself — most fail silently)

| Limit | Value | Failure mode |
|---|---|---|
| DeviceActivityMonitor memory | **6 MB** high watermark | `EXC_RESOURCE (RESOURCE_TYPE_MEMORY … limit=6 MB)`, instant kill, no callback delivered |
| Concurrent monitored activities (app + all extensions) | **20** | `MonitoringError.excessiveActivities` (thrown) |
| `DeviceActivitySchedule` interval | **≥ 15 min, ≤ 1 week** | `.intervalTooShort` / `.intervalTooLong` (thrown) |
| Tokens per shield collection (each of `applications`, `webDomains`, `applicationCategories`, `webDomainCategories`) | **50** | **SILENT** — store shields nothing, property reads back `nil` |
| Named `ManagedSettingsStore`s per process | **50** | Silent |
| `webContent.blockedByFilter` domains / exceptDomains | **50 each** | Silent |
| `secondaryButtonSubmenuItems` | **3** | Excess ignored |
| Events per activity | **undocumented** — a 30-event staircase is known to work in production | — |
| Report extension memory | **undocumented** — 50 MB and 100 MB both reported *(unverified)* | Black screen where the report view should be |

Also: any `webContent.blockedByFilter` policy other than `.none` **disables Safari private browsing**. Time the user spends staring at *your* shield is still counted by the system as usage of the shielded app.

---

### 15. Adjacent APIs (not Screen Time, but relevant to the product)

- **Core NFC** — `NFCTagReaderSession` / `NFCNDEFReaderSession` for Brick-style physical friction. Background NDEF tag reading needs a universal link and iPhone XS+ with screen on; foreground tap in your app is reliable.
- **Vision / CoreMotion** — body-pose for Clearspace-style exercise unlocks. Entirely independent of Screen Time.
- **`PermissionKit`** (iOS 26.0, **no entitlement**) — **cannot** build "child asks for more time." `AskCenter.ask` is overloaded only for `PermissionQuestion<CommunicationTopic>` and `PermissionQuestion<SignificantAppUpdateTopic>`; `QuestionTopic` has no generic `ask()`. It is also iMessage-only and child-Apple-Account-only. Build request-more-time yourself.
- **`DeclaredAgeRange`** (iOS 26.0, entitlement `com.apple.developer.declared-age-range`) — only compelled if you answer "social media capabilities, disabled under 13" in the App Store Connect age-rating questionnaire. An app blocker should not.
- **`DeviceActivityAuthorization`** (iOS 17.0) — `authorizedClientIdentifiers`, `isOverridden`, `sharingEnabled`. Apple's page is **entirely blank**. Do not build on it.
