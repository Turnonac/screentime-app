//
//  Identifiers.swift
//  GateKernel
//
//  The shared-constants contract. Every one of the other seven targets links
//  GateKernel and reads its identifiers from here; no target ever spells one of
//  these strings out as a literal of its own.
//
//  Build plan: docs/06-build-plan.md step 1.7.
//
//  RULES FOR THIS FILE
//  1. Foundation + ManagedSettings + DeviceActivity only. This file is linked
//     into GateActivityMonitor, which has a 6 MB hard memory ceiling and is
//     jetsam-killed the instant it is exceeded (docs/03-hard-constraints.md #31).
//     No SwiftUI, no UIKit, no os.log — nothing here needs a Logger, only the
//     *subsystem strings* a Logger is built from.
//  2. Constants only. No I/O, no `ManagedSettingsStore` instantiation, no
//     `DeviceActivityCenter` calls. Touching either of those from a type
//     initializer would run daemon work at dyld time in the monitor.
//  3. Nothing here may require an iOS version above the 17.0 floor. The 26.4 and
//     26.5 symbols (`ManagedSettingsStore.stores`, `deleteStores(_:)`,
//     `isActive`, `TokenExpiryMessage`) are used at the call sites in
//     Kernel/Engine/Reconciler.swift behind `if #available`; this file only
//     supplies the names they operate on (docs/02-api-reference.md §13).
//

import Foundation

// The Screen Time frameworks exist only on Apple platforms. `GateKernel` is
// also built as a plain SwiftPM module so `make test` can exercise the pure
// layer off-device, so every SDK symbol in this file sits behind a fence —
// the same pattern Kernel/Engine/ScheduleBuilder.swift already uses. On iOS
// every guard is true and the shipping build is unchanged.
#if canImport(ManagedSettings)
import ManagedSettings
#endif

#if canImport(DeviceActivity)
import DeviceActivity
#endif

// MARK: - GateID

/// Every string that has to be identical in more than one process.
///
/// `GateID` is an uninhabited namespace: `enum` with no cases cannot be
/// instantiated, so there is no chance of someone allocating one in the monitor.
public enum GateID {

    // MARK: App Group

    /// The App Group container identifier.
    ///
    /// This is the **only** supported channel between the app and its four
    /// extensions (docs/05-architecture.md, process/data-flow diagram). It is
    /// deliberately repeated as a literal in `Config/Gate-App.entitlements`,
    /// `Config/Gate-Extension.entitlements` and `APP_GROUP` in
    /// `Config/Build.xcconfig`, because entitlement plists are compared
    /// character-for-character against the group registered in the developer
    /// portal and cannot reference a build setting. `make verify` asserts all
    /// four copies agree; this one is the only copy Swift code may read.
    ///
    /// Nothing else in the Swift sources may contain this literal.
    /// `Kernel/Store/AppGroupContainer.swift` derives every container URL from it.
    public static let appGroup = "group.com.turnonac.gate"

    /// The bundle-identifier prefix shared by the app and all seven other bundles.
    ///
    /// Casing is load-bearing: a mismatch between the parent app and any
    /// extension produces an Xcode "Prefix Mismatch" error that blocks archiving
    /// and forces a fresh Family Controls entitlement request, which has no SLA
    /// (docs/03-hard-constraints.md #5, #7). Mirrors `BUNDLE_ID_PREFIX` in
    /// `Config/Build.xcconfig`; the locked table lives in
    /// `Docs/ENTITLEMENT-REQUEST.md`.
    public static let bundlePrefix = "com.turnonac.gate"

    // MARK: Keychain

    /// `kSecAttrService` for the lock-clock item.
    ///
    /// The lock deadline — `{ pendingChangeID, earliestApplyAt, lockConfigHash }`
    /// — is mirrored into the Keychain under
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, because Keychain items
    /// survive app deletion on iOS and the App Group container does not. That
    /// single fact is what stops delete-and-reinstall from resetting the delay
    /// (docs/04-product-spec.md V1-3; written by `Kernel/Store/LockClock.swift`).
    public static let keychainService = "com.turnonac.gate.lock"

    /// `kSecAttrAccount` for the lock-clock item. Exactly one item exists —
    /// there is exactly one lock per install (docs/04-product-spec.md V1-3).
    public static let keychainAccount = "lock-clock"

    /// The keychain access group **without** the team prefix.
    ///
    /// `Config/Gate-App.entitlements` declares
    /// `$(AppIdentifierPrefix)com.turnonac.gate`, where `$(AppIdentifierPrefix)`
    /// is expanded by Xcode at signing time into `<TeamID>.`. Security.framework
    /// wants the fully-qualified string, which therefore cannot be a compile-time
    /// constant — see ``keychainAccessGroup(teamPrefix:)``.
    ///
    /// The access group is on the **app target only**. No extension reads or
    /// writes the lock clock, and every entitlement an `.appex` carries is one
    /// more thing that has to match its provisioning profile (project.yml).
    public static let keychainAccessGroupSuffix = "com.turnonac.gate"

    /// Fully-qualified keychain access group for an explicit `kSecAttrAccessGroup`.
    ///
    /// - Parameter teamPrefix: the 10-character Apple Developer Team ID, with or
    ///   without its trailing dot.
    ///
    /// Prefer passing `nil` for `kSecAttrAccessGroup` entirely: with a single
    /// entry in `keychain-access-groups`, the app is the sole client and iOS
    /// defaults to the first group in the entitlement. Use this only if a future
    /// target genuinely needs to share the item, and note that an access group
    /// that does not match the provisioning profile fails at runtime with
    /// `errSecMissingEntitlement` (-34018) rather than at build time.
    public static func keychainAccessGroup(teamPrefix: String) -> String {
        let prefix = teamPrefix.hasSuffix(".") ? teamPrefix : teamPrefix + "."
        return prefix + keychainAccessGroupSuffix
    }

    // MARK: Logging subsystems

    /// `os.Logger` subsystems, one per process.
    ///
    /// `print()` is invisible from an extension; every extension logs through
    /// `os.Logger` (docs/06-build-plan.md step 4.1). Separate subsystems are what
    /// make `log stream --predicate 'subsystem == "com.turnonac.gate.monitor"'`
    /// usable while four processes are interleaving.
    ///
    /// `Logger` itself is deliberately **not** constructed here — `import os`
    /// would put an unnecessary module in the monitor's dyld closure, and these
    /// are plain `String`s the call site combines with its own category.
    public enum Subsystem {
        /// The containing app (`Gate.app`).
        public static let app = "com.turnonac.gate"
        /// `GateActivityMonitor.appex`. Under the 6 MB ceiling; log sparingly
        /// (docs/06-build-plan.md step 4.1).
        public static let monitor = "com.turnonac.gate.monitor"
        /// `GateShieldConfiguration.appex`. Latency-bounded: the system
        /// substitutes its default shield if the data source is slow
        /// (docs/03-hard-constraints.md #33).
        public static let shieldConfiguration = "com.turnonac.gate.shield.configuration"
        /// `GateShieldAction.appex`. The only extension that *writes* to the
        /// App Group inbox (docs/05-architecture.md, single-writer discipline).
        public static let shieldAction = "com.turnonac.gate.shield.action"
        /// `GateReport.appex`. Logging is the one thing that escapes the report
        /// extension's sandbox, and even then only to the console — no computed
        /// usage value may be logged, since that would launder Screen Time data
        /// out of a sandbox Apple confirmed is intentional
        /// (docs/03-hard-constraints.md #30). Log control flow, never numbers.
        public static let report = "com.turnonac.gate.report"
        /// Shared kernel code, which runs inside whichever process linked it.
        /// The category should name the caller.
        public static let kernel = "com.turnonac.gate.kernel"
    }

    // MARK: Deep links

    /// The app's custom URL scheme. Declared in `CFBundleURLTypes` in
    /// `Config/Gate-Info.plist` (and in project.yml, which generates it).
    ///
    /// **Decision — yes, v1 needs a URL scheme, and it is load-bearing below
    /// iOS 26.5.** `ShieldActionResponse.openParentalControlsApp` only exists on
    /// iOS 26.5+ (docs/02-api-reference.md §13), and even there it is
    /// *(unverified)* whether it works at all under `.individual` authorization
    /// and *(unverified)* whether it carries any payload — Apple's wording is
    /// parental-centric and there are no field reports
    /// (docs/02-api-reference.md §10; device-test gate docs/06-build-plan.md 2.5a).
    /// So the fallback path is mandatory in v1: `GateShieldAction` writes the
    /// intent into the App Group inbox, posts a `UNNotificationRequest` carrying
    /// ``interventionURL(ruleID:requestID:)``, and returns `.close`; the user taps
    /// the notification and the app opens `InterventionScreen`
    /// (docs/04-product-spec.md V1-7).
    ///
    /// The URL is a *pointer*, never a payload. It carries two UUIDs and nothing
    /// else; the intent itself is read back out of the App Group. Custom schemes
    /// can be claimed by any other installed app, so a deep link must never be
    /// trusted to do more than name a record the app already wrote itself.
    public static let urlScheme = "gate"

    /// Host of the intervention deep link: `gate://intervention?...`.
    public static let interventionHost = "intervention"

    private static let ruleQueryItem = "rule"
    private static let requestQueryItem = "request"

    /// Builds the deep link the shield-action extension attaches to its
    /// notification on iOS < 26.5 (docs/04-product-spec.md V1-7).
    ///
    /// - Parameters:
    ///   - ruleID: the rule whose shield was tapped.
    ///   - requestID: the intervention request the extension appended to
    ///     `inbox/`. The app resolves this to the real record; if it cannot, it
    ///     falls back to showing the rule's intervention from scratch rather
    ///     than trusting anything in the URL.
    ///
    /// Force-unwrapping `URLComponents.url` is safe here and only here: every
    /// component is a compile-time-constant scheme and host plus two
    /// `UUID.uuidString`s, which are alphanumerics-and-hyphens and need no
    /// percent-encoding. There is no user input on this path.
    public static func interventionURL(ruleID: UUID, requestID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = interventionHost
        components.queryItems = [
            URLQueryItem(name: ruleQueryItem, value: ruleID.uuidString),
            URLQueryItem(name: requestQueryItem, value: requestID.uuidString),
        ]
        return components.url!
    }

    /// Parses a deep link produced by ``interventionURL(ruleID:requestID:)``.
    ///
    /// Returns `nil` for anything that is not an exactly-shaped Gate
    /// intervention link. Any other app on the device can open `gate://`, so
    /// this is a validating parser, not a convenience accessor.
    public static func intervention(from url: URL) -> InterventionLink? {
        guard url.scheme?.lowercased() == urlScheme,
              url.host?.lowercased() == interventionHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return nil }

        func uuid(_ name: String) -> UUID? {
            guard let value = items.first(where: { $0.name == name })?.value else { return nil }
            return UUID(uuidString: value)
        }

        guard let ruleID = uuid(ruleQueryItem), let requestID = uuid(requestQueryItem) else {
            return nil
        }
        return InterventionLink(ruleID: ruleID, requestID: requestID)
    }

    /// The two identifiers an intervention deep link carries.
    public struct InterventionLink: Hashable, Sendable {
        public let ruleID: UUID
        public let requestID: UUID

        public init(ruleID: UUID, requestID: UUID) {
            self.ruleID = ruleID
            self.requestID = requestID
        }
    }

    // MARK: Notifications

    /// Identifiers for the `UserNotifications` objects that cross the process
    /// boundary. The shield-action extension creates them; the app's
    /// `UNUserNotificationCenterDelegate` matches on them.
    ///
    /// `UserNotifications` is deliberately not imported here — these are the
    /// `String`s that framework's initializers take, and the monitor extension
    /// should not gain a module for the sake of two constants.
    public enum Notifications {
        /// `UNNotificationCategory` for the sub-26.5 "tap to continue"
        /// intervention hand-off (docs/04-product-spec.md V1-7).
        public static let interventionCategory = "gate.intervention"

        /// `UNNotificationCategory` for the `UNCalendarNotificationTrigger`
        /// backstops the app re-arms at every schedule boundary. These exist
        /// because `intervalDidStart` / `intervalDidEnd` fire only when the
        /// device is in use, never at the wall-clock boundary
        /// (docs/03-hard-constraints.md #27), and because the monitor extension
        /// is killed for memory or idleness and has been reported as never
        /// launching at all (#32). Tapping one gives the app a foreground
        /// reconcile (docs/04-product-spec.md V1-10).
        public static let backstopCategory = "gate.backstop"

        /// `userInfo` key under which the deep-link URL string travels.
        public static let urlKey = "gate.url"
    }

    // MARK: Namespace prefix

    /// The reverse-DNS-free prefix every Gate-owned system name starts with:
    /// named `ManagedSettingsStore`s, `DeviceActivityName`s and
    /// `DeviceActivityReport.Context`s.
    ///
    /// Both the store-name helpers below and
    /// `Kernel/Engine/ActivityNameCodec.swift` build their names from this one
    /// constant, so the orphan sweeps in `Kernel/Engine/Reconciler.swift` have a
    /// single test for "is this ours". Keep it short: store and activity names
    /// are round-tripped through the system daemon on every reconcile.
    public static let namespace = "gate."
}

// MARK: - ManagedSettingsStore.Name

#if canImport(ManagedSettings)
public extension ManagedSettingsStore.Name {

    /// The store that enforces one rule.
    ///
    /// Every rule gets its own named store so rules never clobber each other's
    /// shield sets; a named store is automatically shared with all of the app's
    /// extensions (docs/02-api-reference.md §6; docs/04-product-spec.md V1-2).
    ///
    /// Name shape: `gate.rule.<UUID>` — round-trippable via ``ruleID(from:)``.
    static func rule(_ id: UUID) -> Self {
        Self(GateID.namespace + "rule." + id.uuidString)
    }

    /// The inverse of ``rule(_:)``.
    ///
    /// Returns `nil` for any name that is not a Gate rule store — including
    /// ``solid`` and any store belonging to another framework in the process.
    /// This is what lets `Reconciler` diff `ManagedSettingsStore.stores`
    /// (iOS 26.5+, so behind `if #available`) against the rules actually in
    /// `GateState` and delete the orphans, which matters because the named-store
    /// cap is **50 and fails silently** (docs/02-api-reference.md §14).
    ///
    /// `UUID(uuidString:)` accepts either casing, so a name that survived a
    /// round trip through the daemon parses regardless of how it was normalized.
    static func ruleID(from name: Self) -> UUID? {
        let prefix = GateID.namespace + "rule."
        guard name.rawValue.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.rawValue.dropFirst(prefix.count)))
    }

    /// The single global store, separate from every rule store.
    ///
    /// Holds the settings that are device-wide rather than token-scoped, so that
    /// rebuilding a rule's shield set can never disturb them:
    /// `application.denyAppInstallation` for "Solid" mode
    /// (docs/04-product-spec.md V1-8).
    ///
    /// It deliberately does **not** hold `denyAppRemoval`: that is device-wide,
    /// only honored under `.child` enrollment, and has been reported to get
    /// stuck on after uninstall (docs/03-hard-constraints.md #15). v1 never
    /// writes it.
    ///
    /// Declared as a computed property, not a `static let`: a stored static of a
    /// type whose `Sendable` conformance the SDK has not audited is a Swift 6
    /// strict-concurrency error ("not concurrency-safe"), and `Name` is a
    /// `String` wrapper, so constructing it per access costs nothing. Same
    /// reasoning for ``backstop`` and ``DeviceActivityReport/Context/totalActivity``.
    static var solid: Self {
        Self(GateID.namespace + "solid")
    }

    /// Reserved second global store, used only while a reconcile is swapping a
    /// rule's shield set.
    ///
    /// Writing a shield collection is not atomic and the monitor can be killed
    /// mid-callback, so `Kernel/Enforcement/ShieldWriter.swift` can stage the
    /// *tightening* half of a change here first and clear it once the rule store
    /// has been rewritten. The failure mode this exists to prevent is a window
    /// in which a rule is shielding nothing — a silently unenforced block is the
    /// one failure this product cannot have (docs/05-architecture.md,
    /// persistence rationale).
    static var backstop: Self {
        Self(GateID.namespace + "backstop")
    }

    /// Whether this name belongs to Gate at all.
    ///
    /// Used by the 26.5+ orphan sweep before calling
    /// `ManagedSettingsStore.deleteStores(_:)`, so that Gate never deletes a
    /// store it did not create.
    var isGateStore: Bool {
        rawValue.hasPrefix(GateID.namespace)
    }
}
#endif

// MARK: - DeviceActivityName

#if canImport(DeviceActivity)
public extension DeviceActivityName {

    /// Whether this activity name belongs to Gate.
    ///
    /// Monitor callbacks receive **only the name** — no tokens, no dates, no
    /// `userInfo` — so all context is encoded into the string. The encoding and
    /// decoding of `gate.rule:<uuid>`, `gate.grant:<uuid>|<uuid>` and
    /// `gate.revert:<uuid>|<uuid>` lives in
    /// `Kernel/Engine/ActivityNameCodec.swift` and is **not** duplicated here;
    /// this file owns only the ``GateID/namespace`` prefix that the codec builds
    /// on (docs/05-architecture.md, "The `DeviceActivityName` codec").
    ///
    /// This predicate exists so `Reconciler` can diff
    /// `DeviceActivityCenter().activities` and `stopMonitoring` orphans without
    /// paying the codec's parse for names that were never ours, and without ever
    /// stopping an activity registered by some other component
    /// (docs/04-product-spec.md V1-10 step 4).
    var isGateActivity: Bool {
        rawValue.hasPrefix(GateID.namespace)
    }
}
#endif

// MARK: - DeviceActivityReport.Context

#if canImport(DeviceActivity)
public extension DeviceActivityReport.Context {

    /// The one report context v1 ships: a daily total-activity report rendered
    /// by `Extensions/Report/TotalActivityReport.swift`
    /// (docs/06-build-plan.md step 1.7; docs/04-product-spec.md V2-5).
    ///
    /// This string must match the `context` of the `DeviceActivityReportScene`
    /// in the report extension exactly, or the report view renders blank with no
    /// error. It is the *only* coupling between the app and that extension:
    /// the report extension's sandbox is intentional and absolute, and nothing
    /// it computes can ever reach the app by any channel — App Group
    /// `UserDefaults`, App Group files, HTTP, notifications, pasteboard and
    /// iCloud KVS are all confirmed blocked (docs/03-hard-constraints.md #30).
    ///
    /// Show at most **one** `DeviceActivityReport` per screen; three or more on
    /// one screen is a reported crash threshold (docs/02-api-reference.md §11).
    ///
    /// `nonisolated` and computed rather than `static let`: `DeviceActivityReport`
    /// is declared `@MainActor`, so a plain static on its nested type would be
    /// main-actor-isolated and unusable from the report extension's
    /// `makeConfiguration(representing:)`, which is a non-isolated `async`
    /// requirement. Spelling it this way compiles under Swift 6 strict
    /// concurrency regardless of how the SDK annotates `Context`, and the call
    /// site is unchanged: `DeviceActivityReport(.totalActivity, filter: …)`.
    nonisolated static var totalActivity: Self {
        Self(GateID.namespace + "totalActivity")
    }
}
#endif

// MARK: - GateLimits

/// The platform's hard numbers, plus the product defaults derived from them.
///
/// Most of the platform caps **fail silently** — exceeding the 50-token shield
/// cap makes the store shield *nothing* and read back `nil`
/// (docs/02-api-reference.md §14; docs/03-hard-constraints.md #34). Every one of
/// them is therefore enforced in Gate's own code before the value reaches the
/// framework, which is the entire reason this type exists.
public enum GateLimits {

    // MARK: Platform caps — fixed by iOS, not by us

    /// Tokens per shield collection: `applications`, `webDomains`,
    /// `applicationCategories` and `webDomainCategories` are capped at 50 *each*.
    ///
    /// **Silent failure.** Over the cap, the store shields nothing and the
    /// property reads back `nil`. Guarded in the rule editor
    /// (docs/04-product-spec.md V1-2) and again in
    /// `Kernel/Enforcement/TokenGuard.swift` before any write.
    public static let maxTokensPerShieldCollection = 50

    /// Named `ManagedSettingsStore`s per process: 50. Silent failure.
    ///
    /// `maxRules` (8) plus ``ManagedSettingsStore/Name/solid`` and
    /// ``ManagedSettingsStore/Name/backstop`` is 10, so the cap is only reachable
    /// through orphaned stores left behind by deleted rules — which is what the
    /// 26.5+ `deleteStores(_:)` sweep and ``ManagedSettingsStore/Name/ruleID(from:)``
    /// exist to prevent.
    public static let maxNamedStores = 50

    /// Domains in `webContent.blockedByFilter` and in its `exceptDomains`:
    /// 50 each. Silent failure.
    ///
    /// Note that *any* `blockedByFilter` policy other than `.none` disables
    /// Safari private browsing (docs/02-api-reference.md §14).
    public static let maxWebFilterDomains = 50

    /// Concurrently monitored `DeviceActivityName`s, counted across the app
    /// **and all of its extensions together**: 20.
    ///
    /// Unlike the others this one is loud — `startMonitoring` throws
    /// `DeviceActivityCenter.MonitoringError.excessiveActivities` — but it
    /// throws at whatever arbitrary moment the 21st activity is armed, which in
    /// practice is while applying a block. `Kernel/Enforcement/MonitorPlan.swift`
    /// enforces the budget below instead, evicting the furthest-out timer
    /// (docs/05-architecture.md, activity budget).
    public static let maxConcurrentActivities = 20

    /// Minimum `DeviceActivitySchedule` interval: 15 minutes.
    /// Throws `.intervalTooShort` (docs/02-api-reference.md §14).
    public static let minScheduleInterval: TimeInterval = 15 * 60

    /// Maximum `DeviceActivitySchedule` interval: one week.
    /// Throws `.intervalTooLong` (docs/02-api-reference.md §14).
    public static let maxScheduleInterval: TimeInterval = 7 * 24 * 60 * 60

    /// `ShieldConfiguration.secondaryButtonSubmenuItems`: 3. Excess is ignored.
    /// iOS 26.4+, so every use site is `if #available`-gated; v2 feature
    /// (docs/04-product-spec.md V2-1).
    public static let maxShieldSubmenuItems = 3

    /// The monitor extension's hard memory high-watermark: 6 MB, unchanged since
    /// iOS 15 and not increasable. Exceeding it is an instant
    /// `EXC_RESOURCE (RESOURCE_TYPE_MEMORY)` kill with no callback delivered
    /// (docs/03-hard-constraints.md #31).
    ///
    /// Informational — nothing can read its own high-watermark cheaply enough to
    /// act on it. It is here so the number appears in the debug screen
    /// (docs/04-product-spec.md V1-11) next to the breadcrumb log, where a run of
    /// missing breadcrumbs is the only symptom you will ever see.
    public static let monitorMemoryCeilingBytes = 6 * 1024 * 1024

    // MARK: Product caps — our choices, derived from the platform caps

    /// Rules per install: 8 (docs/04-product-spec.md V1-2).
    ///
    /// Chosen so that one store and one repeating activity per rule stay well
    /// inside the 50-store and 20-activity ceilings even with grants and
    /// auto-revert timers outstanding.
    public static let maxRules = 8

    /// Repeating rule windows: at most one `DeviceActivityName` per rule — never
    /// one per weekday.
    ///
    /// Weekday scoping is handled inside `intervalDidStart` by checking the
    /// calendar and no-oping; a name per rule-per-weekday blows the 20-activity
    /// cap at rule #3 (docs/04-product-spec.md V1-5).
    public static let maxRepeatingActivities = 8

    /// One-shot grant-expiry timers armed at once: 6
    /// (docs/05-architecture.md, activity budget).
    public static let maxGrantActivities = 6

    /// One-shot pending-change auto-revert timers armed at once: 4
    /// (docs/05-architecture.md, activity budget).
    public static let maxRevertActivities = 4

    /// Deliberately unused slack in the 20-activity budget.
    ///
    /// Derived rather than written down, so the budget can never silently stop
    /// summing to ``maxConcurrentActivities``. `MonitorPlan` treats a headroom of
    /// zero or less as a programming error.
    public static let activityHeadroom =
        maxConcurrentActivities - (maxRepeatingActivities + maxGrantActivities + maxRevertActivities)

    /// Serialized `GateState` byte budget: 8 KB
    /// (docs/05-architecture.md, persistence).
    ///
    /// The monitor decodes this file on every callback under a 6 MB ceiling.
    /// `FamilyActivitySelection` blobs are large, "especially if you use
    /// `includeEntireCategory`", so selections are stored once keyed by rule ID
    /// and referenced by ID everywhere else. `GateStateStore` logs a warning past
    /// this size rather than failing the write — refusing to persist state would
    /// be worse than a slow decode.
    public static let maxStateBytes = 8 * 1024

    // MARK: Product defaults

    /// Default Lock delay: 15 minutes (docs/04-product-spec.md V1-3).
    ///
    /// Every *loosening* change is queued with `earliestApplyAt = now + delay`.
    /// Tightening changes apply immediately and never consult the delay
    /// (docs/04-product-spec.md V1-4, the Ratchet).
    public static let defaultLockDelay: TimeInterval = 15 * 60

    /// Minimum user-settable Lock delay: 1 minute (docs/04-product-spec.md V1-3).
    public static let minLockDelay: TimeInterval = 60

    /// Maximum user-settable Lock delay: 7 days (docs/04-product-spec.md V1-3).
    ///
    /// Unrelated to ``maxScheduleInterval``, which happens to share the value:
    /// the Lock delay is an absolute timestamp in `state.plist` and the Keychain,
    /// not a `DeviceActivitySchedule`.
    public static let maxLockDelay: TimeInterval = 7 * 24 * 60 * 60

    /// Default impulse delay: 30 seconds — the forced wait on the intervention
    /// screen, separate from and normally much shorter than the Lock delay
    /// (docs/04-product-spec.md V1-7 step 1).
    public static let defaultImpulseDelay: TimeInterval = 30

    /// Default grants per day: 3, decremented in `ShieldActionDelegate` and reset
    /// at midnight (docs/04-product-spec.md V1-7).
    ///
    /// Running out is a *tightening*, so it needs no lock and takes effect
    /// immediately.
    public static let defaultDailyGrantBudget = 3

    /// Default grant duration: 5 minutes — the length of the time-boxed
    /// subtraction from a rule's shield set after a completed intervention
    /// (docs/04-product-spec.md V1-7 step 3).
    ///
    /// A grant is set subtraction plus `.specific(categories, except: granted)`,
    /// never `clearAllSettings()` (docs/02-api-reference.md §6).
    public static let defaultGrantDuration: TimeInterval = 5 * 60

    /// Ignore an `eventDidReachThreshold` whose activity started less than this
    /// long ago: 60 seconds.
    ///
    /// This is the documented iOS 26.x false-positive signature — the event
    /// fires immediately on first unlock, or with 0 recorded minutes, or twice
    /// for the same event, or when the threshold was not met
    /// (docs/03-hard-constraints.md #35; docs/06-build-plan.md step 4.1). The
    /// monitor compares against its own persisted `intervalDidStart` timestamp,
    /// never against a value the system hands it.
    public static let eventFalsePositiveGuard: TimeInterval = 60
}
