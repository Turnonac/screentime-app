//
//  Reconciler.swift
//  GateKernel
//
//  The one function the app and the monitor extension both call.
//
//  Build plan: docs/06-build-plan.md step 3.10 (the I/O half; the planning half
//  is `Kernel/Enforcement/MonitorPlan.swift`). Product: docs/04-product-spec.md
//  V1-10, "Reconciliation (the reliability backbone)".
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS FILE IS THE WHOLE PRODUCT'S RELIABILITY STORY
//
//  Nothing about this stack is event-driven enough to trust. Taken from
//  docs/03-hard-constraints.md:
//
//    #27  `intervalDidStart` / `intervalDidEnd` fire only when the device is in
//         use, never at the wall-clock boundary. Exact-time start/stop of a
//         block is impossible.
//    #32  The monitor extension is killed for memory or for idleness, and has
//         been reported as never launched at all on iOS 26.3.1 with correct
//         configuration. "It cannot be your sole enforcement path."
//    #35  `eventDidReachThreshold` fires early, fires twice, fires with zero
//         recorded minutes, or never arrives.
//    #36  Tokens go stale, and the iOS 26.5 remedy for that is itself broken for
//         roughly 30 % of new users.
//
//  So Gate does not react to events. It recomputes ground truth from absolute
//  timestamps, from scratch, on every opportunity it gets — and treats every
//  callback as nothing more than an invitation to recompute early
//  (docs/05-architecture.md, "Enforcement layering"). This function is that
//  recomputation. Everything else in the kernel is a pure input to it.
//
//  THE FIVE STEPS, in the order docs/04-product-spec.md V1-10 gives them:
//
//    1. Re-read `GateState` from the App Group.   ← never trust memory
//    2. Drain `inbox/` and fold it in.            ← app only; see below
//    3. Expire grants and release ripe changes by ABSOLUTE timestamp.
//    4. Recompute the intended shield set per rule and rewrite every store.
//    5. Diff `DeviceActivityCenter().activities` against `MonitorPlan`;
//       stop orphans, start the missing ones.
//
//  Step 5 of the spec's own list — re-arming `UNCalendarNotificationTrigger`
//  backstops — is *reported*, not performed: `UserNotifications` must not be
//  linked by the monitor (6 MB, docs/03-hard-constraints.md #31) and only the
//  app can hold notification authorization anyway (docs/06-build-plan.md step
//  5.7). ``ReconcileReport/backstopDates`` is the answer; the app arms them.
//
//  RULES FOR THIS FILE
//
//  1. **Idempotent.** Running twice with the same clock must change nothing the
//     second time: no file written, no store rewritten with different bytes, no
//     activity stopped and restarted. Every write in here is guarded by a
//     comparison against what is already there. The monitor can be invoked
//     several times a minute; churn against the Screen Time daemon is not free.
//  2. **Safe from a 6 MB extension.** No `FamilyControls`, no
//     `UserNotifications`, no `Security`, no SwiftUI, no arrays built where a
//     running count would do. Token decoding — the one genuinely large
//     operation — is injected as ``SelectionResolving`` so that the kernel never
//     names `FamilyActivitySelection` (`Kernel/Enforcement/ShieldWriter.swift`
//     keeps the same boundary for the same reason).
//  3. **Single writer.** Extensions never write `state.plist`, `selections.plist`
//     or `shield.plist` (docs/05-architecture.md). ``ReconcileRole`` is how that
//     rule is expressed in code rather than in a comment: a `.monitor` reconcile
//     computes exactly the same answer and writes only the two things a monitor
//     is allowed to write — the `ManagedSettingsStore`s, and the daemon's
//     activity list.
//  4. **Fail closed.** A reconcile that cannot decode state throws rather than
//     substituting an empty one, because an empty `GateState` means "no rules"
//     means every block silently lifts. A reconcile that cannot resolve one
//     rule's tokens leaves that rule's store *alone* rather than emptying it.
//  5. **One failure never aborts the pass.** `startMonitoring` throwing for one
//     activity must not cost the other seventeen; a shield write failing for
//     rule three must not leave rules four through eight on yesterday's
//     settings. Everything recoverable lands in ``ReconcileReport``, which is
//     also exactly what the debug screen renders (docs/04-product-spec.md V1-11).
//

import Foundation

// MARK: - Role

/// Which process is reconciling, and therefore what it is allowed to write.
///
/// This is the single-writer discipline of docs/05-architecture.md expressed as
/// a value. The *computation* is identical in every role — the same state, the
/// same plans, the same activity diff — because a monitor that computed a
/// different answer from the app would be a second source of truth, which is the
/// one thing this design does not have.
public enum ReconcileRole: String, Sendable, Hashable, CaseIterable {

    /// `Gate.app`. The only writer of `state.plist`, `selections.plist` and
    /// `shield.plist`, and the only process that may drain `inbox/`.
    case app

    /// An app extension — in practice `GateActivityMonitor`.
    ///
    /// Writes `ManagedSettingsStore`s and the daemon's activity list, and
    /// nothing else in the container except the armed-fingerprint cache and a
    /// liveness breadcrumb. Any state change it computes (a grant that expired,
    /// a loosening whose deadline passed) is applied to enforcement immediately
    /// and re-derived from the unchanged file on the next pass, which costs a
    /// recomputation and never a wrong answer — every deadline in `GateState` is
    /// an absolute timestamp precisely so that this is true.
    case monitor

    /// Compute everything, write nothing, anywhere.
    ///
    /// For the debug screen's preview and for a first pass during onboarding,
    /// before the user has agreed to anything.
    case dryRun

    /// Whether this role may persist `GateState`.
    public var writesState: Bool { self == .app }

    /// Whether this role may consume `inbox/`.
    ///
    /// Draining deletes the files it reads, so a role that cannot persist what
    /// it drained must not drain: it would destroy a grant request the user is
    /// on their way to complete.
    ///
    /// The role is the static half of that test. `reconcile` applies the same
    /// rule to the pass in front of it — a `state.plist` from a newer build
    /// refuses every write, and a pass under one does not drain either.
    public var drainsInbox: Bool { self == .app }

    /// Whether this role may write `ManagedSettingsStore`s and the daemon's
    /// activity list.
    public var writesEnforcement: Bool { self != .dryRun }

    /// Whether this role may republish `shield.plist`.
    public var publishesShieldCopy: Bool { self == .app }

    /// Whether this role should leave a liveness breadcrumb in `inbox/`.
    ///
    /// Only the monitor: it is the process whose silence is invisible, and a
    /// breadcrumb trail is the only evidence available that it ran at all
    /// (docs/03-hard-constraints.md #32, docs/04-product-spec.md V1-11). The app
    /// records its own liveness in ``GateState/lastReconciledAt``.
    public var appendsBreadcrumb: Bool { self == .monitor }

    /// The role for the process this code is running in.
    ///
    /// `Bundle.main` inside an `.appex` is the extension bundle, so this is a
    /// reliable test that needs no entitlement
    /// (``AppGroupContainer/isRunningInAppExtension``).
    public static var detected: ReconcileRole {
        AppGroupContainer.isRunningInAppExtension ? .monitor : .app
    }
}

// MARK: - Trigger

/// What caused this reconcile. Recorded in the report and in the monitor's
/// breadcrumb; never changes what the reconcile does.
///
/// Kept as a closed enum rather than a free `String` so the debug screen can
/// group by it and so a typo cannot invent a new category — the whole value of
/// the breadcrumb trail is being able to say "we have seen `intervalDidEnd`
/// eleven times today and `eventDidReachThreshold` never".
public enum ReconcileTrigger: String, Sendable, Hashable, CaseIterable {

    /// `scenePhase == .active` (docs/06-build-plan.md step 5.7).
    case foreground

    /// App launch, before the first `scenePhase` change.
    case launch

    /// A user action the app applied immediately — the settings screen, the
    /// rule editor, a cancelled pending change.
    case userAction

    /// The intervention screen issued a grant and needs the shield lifted now.
    case grantIssued

    /// `DeviceActivityMonitor.intervalDidStart(for:)`.
    case intervalDidStart

    /// `DeviceActivityMonitor.intervalDidEnd(for:)`.
    case intervalDidEnd

    /// `intervalWillStartWarning` / `intervalWillEndWarning`.
    case intervalWarning

    /// `eventDidReachThreshold` — the least reliable surface in the API
    /// (docs/03-hard-constraints.md #35). v1 arms no events, so seeing this in
    /// the breadcrumb trail is itself a finding.
    case eventThreshold

    /// The user tapped a `UNCalendarNotificationTrigger` backstop.
    case notificationBackstop

    /// A `BGAppRefreshTask` / `BGProcessingTask` window.
    case backgroundTask

    /// The debug screen's "run reconcile now" button (docs/04-product-spec.md
    /// V1-11) — deliberately the same code path as every other trigger.
    case debug
}

// MARK: - Options

/// Everything about a reconcile that is not state.
///
/// `Sendable`: `Calendar` and every other member is a value type, so an options
/// value can be built on the main actor and used from the non-isolated reconcile
/// without ceremony.
public struct ReconcileOptions: Sendable {

    /// Which process this is, and therefore what may be written.
    public var role: ReconcileRole

    /// Why this pass is running. Diagnostics only.
    public var trigger: ReconcileTrigger

    /// Injected so DST and time-zone behaviour is testable without a device
    /// (docs/06-build-plan.md step 3.11).
    public var calendar: Calendar

    /// `AuthorizationCenter.shared.authorizationStatus == .approved`.
    ///
    /// Passed in because `FamilyControls` is not linkable from the kernel and is
    /// not usefully readable from an extension at all. `true` by default, which
    /// is the *enforcing* direction: a reconcile that wrongly believed
    /// authorization was gone would stop maintaining shields the daemon is still
    /// honouring.
    ///
    /// Passing `false` records the moment in ``GateState/tokenExpiryObservedAt``
    /// and routes the user to recovery (docs/04-product-spec.md V1-9) — the user
    /// can revoke in about four taps and every token is voided with it
    /// (docs/03-hard-constraints.md #14), so "not approved" on a foreground is
    /// the single most likely reason a rule has silently stopped working.
    public var isAuthorized: Bool

    /// Cap on events consumed from `inbox/` in one pass.
    ///
    /// A bound, not a policy: ``InboxDrain/hasMore`` reports the rest and the
    /// next reconcile takes them. Without it a directory that somehow grew to
    /// thousands of files would turn a foreground activation into a stall.
    public var maxInboxEvents: Int

    // Per-capability overrides. Each defaults to what ``role`` says; set one
    // only to narrow, never to widen — writing `state.plist` from an extension
    // is the race docs/05-architecture.md exists to prevent, and
    // `FileStateStore` will log a `fault` and trap in debug if you try.

    /// Persist the recomputed state. Defaults to ``ReconcileRole/writesState``.
    public var writesState: Bool

    /// Consume `inbox/`. Defaults to ``ReconcileRole/drainsInbox``.
    public var drainsInbox: Bool

    /// Write `ManagedSettingsStore`s and the daemon's activity list. Defaults to
    /// ``ReconcileRole/writesEnforcement``.
    public var writesEnforcement: Bool

    /// Refresh `shield.plist`'s token index. Defaults to
    /// ``ReconcileRole/publishesShieldCopy``.
    public var publishesShieldCopy: Bool

    /// Append a liveness breadcrumb. Defaults to
    /// ``ReconcileRole/appendsBreadcrumb``.
    public var appendsBreadcrumb: Bool

    /// Read — never delete — the `.grantIssued` records still in `inbox/` and
    /// fold them into the working state for this pass only.
    ///
    /// This is what makes the iOS 26.4+ shield submenu do anything at all. The
    /// submenu runs in `GateShieldAction`, which may not write `state.plist`, so
    /// it records the grant in `inbox/` and arms a one-shot activity whose
    /// interval already started — iOS delivers `intervalDidStart` almost
    /// immediately and the **monitor** is the first process to wake. Without this
    /// option that pass reads a `state.plist` that has never heard of the grant
    /// and re-asserts the shield the user just paid to lift; the lift would not
    /// land until the app was next foregrounded, which is precisely the thing the
    /// submenu exists to avoid.
    ///
    /// Defaults to `role.writesEnforcement && !role.drainsInbox`, which is the
    /// monitor and only the monitor:
    ///
    /// * ``ReconcileRole/app`` drains for real and persists the result, so
    ///   folding a peeked copy first would double-count it.
    /// * ``ReconcileRole/dryRun`` writes no enforcement, so there is nothing for
    ///   a fold to affect.
    ///
    /// **Read-only in both directions.** Nothing is deleted and nothing is
    /// persisted — a pass with this set has `writesState == false` — so the
    /// records are still there for the app to drain, and the ledger is still
    /// decremented in exactly one place. The cost of being wrong is one extra
    /// recomputation on the next pass, which is the same bargain
    /// ``ReconcileRole/monitor`` already makes for every other deadline.
    public var foldsPendingGrants: Bool

    /// Most backstop moments to report. Eight is two days of a pair of daily
    /// windows, which is more notifications than any user wants scheduled at
    /// once.
    public var maxBackstopDates: Int

    public init(
        role: ReconcileRole = .detected,
        trigger: ReconcileTrigger = .foreground,
        calendar: Calendar = .current,
        isAuthorized: Bool = true,
        maxInboxEvents: Int = InboxStore.maxEventsPerDrain,
        maxBackstopDates: Int = 8
    ) {
        self.role = role
        self.trigger = trigger
        self.calendar = calendar
        self.isAuthorized = isAuthorized
        self.maxInboxEvents = maxInboxEvents
        self.maxBackstopDates = maxBackstopDates
        self.writesState = role.writesState
        self.drainsInbox = role.drainsInbox
        self.writesEnforcement = role.writesEnforcement
        self.publishesShieldCopy = role.publishesShieldCopy
        self.appendsBreadcrumb = role.appendsBreadcrumb
        self.foldsPendingGrants = role.writesEnforcement && !role.drainsInbox
    }
}

// MARK: - Failures and warnings

/// Something that went wrong and did not stop the pass.
///
/// A `String` message rather than a wrapped `Error`, so the value stays
/// `Sendable`, `Equatable` and renderable — the same reasoning as
/// ``AppGroupContainer/ContainerError``.
public struct ReconcileFailure: Sendable, Equatable, Hashable, CustomStringConvertible {

    /// Which step failed. Every one of these is survivable; the unrecoverable
    /// failure — being unable to read state at all — is thrown, not reported.
    ///
    /// `startMonitoring` is not here on purpose: an activity that would not arm
    /// is richer than a string and lands in
    /// ``ReconcileReport/ActivitySummary/failures`` as a typed
    /// ``ReconcileReport/ActivityFailure`` instead. Recording it in both places
    /// would make "how many things went wrong" unanswerable.
    public enum Stage: String, Sendable, Hashable, CaseIterable {
        case inboxDrain
        case statePersist
        case selectionTable
        case shieldCopy
        case breadcrumb
    }

    public let stage: Stage

    /// What it was about: an activity name, a rule id, a file name.
    public let subject: String?

    public let message: String

    public init(stage: Stage, subject: String? = nil, message: String) {
        self.stage = stage
        self.subject = subject
        self.message = message
    }

    public var description: String {
        subject.map { "\(stage.rawValue)[\($0)]: \(message)" } ?? "\(stage.rawValue): \(message)"
    }
}

/// Something the reconcile noticed. Not a failure — the pass succeeded — but the
/// explanation the debug screen needs for "why is this rule not doing anything?"
public enum ReconcileWarning: Sendable, Equatable, Hashable {

    /// `state.plist` was written by a newer build of Gate. Enforcement proceeds
    /// on what this build could decode — leniently, and every unknown value
    /// degrades toward *more* friction — but nothing is persisted, because this
    /// build's encoder would silently drop the fields it did not understand.
    case stateFromFutureBuild(fileVersion: Int)

    /// ``GateState/migrate(_:now:)`` repaired the decoded file.
    case stateRepaired(GateState.MigrationReport.Repair)

    /// The authorization check said Gate is no longer approved. Every token is
    /// voided with it (docs/03-hard-constraints.md #14); route to recovery.
    case authorizationLost

    /// An activity the plan wanted had to be given up to stay inside the
    /// 20-activity cap.
    case planEviction(MonitorPlan.Eviction)

    /// Something ``MonitorPlan/make(from:now:calendar:)`` noticed.
    case planDiagnostic(MonitorPlan.Diagnostic)

    /// A rule's store was left exactly as it was, because the write could not be
    /// made safely. **The rule stays enforced as it was** — see
    /// ``ShieldRefusal``.
    case shieldRefused(ruleID: UUID, ShieldRefusal)

    /// A non-blocking problem with one rule's shield plan.
    case shieldIssue(ruleID: UUID, ShieldPlanIssue)

    /// Files in `inbox/` that could not be read this pass — almost always
    /// because the device was locked under a stricter protection class than
    /// Gate's own. They are **never deleted**, only left for the next pass.
    case inboxDeferred(count: Int)

    /// Files in `inbox/` that would not decode and were deleted.
    case inboxCorrupt(count: Int)

    /// Events redelivered because a previous drain deleted the file after
    /// reading it and crashed in between. Delivery is at-least-once by design;
    /// the fold deduplicates (see ``Reconciler/fold(_:into:now:calendar:isAuthorized:)``).
    case inboxRedelivered(count: Int)

    /// Armed `DeviceActivityName`s outside ``GateID/namespace``. Listed so they
    /// are visible; **never** stopped — they belong to another Gate target this
    /// code has not heard of.
    case foreignActivities(names: [String])

    /// A released change asked for a selection blob to be *staged*, which only
    /// the app's picker can produce. Should be unreachable from this path —
    /// `Ratchet.releaseRipe` never stages — so reaching it means a mutation took
    /// a route it should not have.
    case unstageableSelections(count: Int)

    /// ``GateState/lockClock`` moved. The caller must mirror it into the
    /// Keychain with `Kernel/Store/LockClock.swift`; the kernel cannot, because
    /// `keychain-access-groups` is on the app's entitlements and on no
    /// extension's.
    case lockClockNeedsMirroring

    /// A released change wants `AuthorizationCenter.revokeAuthorization`. The
    /// kernel never imports `FamilyControls`; the app performs it.
    case authorizationRevocationPending
}

// MARK: - The armed-fingerprint cache

/// Where the reconciler remembers which schedule each activity was armed with.
///
/// **Why this exists.** `startMonitoring` overwrites whatever is registered
/// under a name (docs/02-api-reference.md §7), and a Gate activity name encodes
/// only an identity — `gate.rule:<uuid>` — never the window behind it. So
/// "this name is in `center.activities`" does not mean "it is armed with the
/// schedule we want": a user who moves a rule from 22:00 to 21:00 changes
/// nothing the daemon can be asked about. `DeviceActivityCenter.schedule(for:)`
/// hands back a `DeviceActivitySchedule` with no audited `Equatable`
/// conformance, so it cannot close the gap either.
///
/// ``PlannedActivity/fingerprint`` closes it, and this is where the fingerprints
/// live between passes.
///
/// **A cache, never state.** Losing it costs one round of redundant
/// stop/start calls. Every implementation is therefore non-throwing: a cache
/// that could fail a reconcile would be worse than no cache at all.
public protocol ArmedActivityRecording: Sendable {

    /// Fingerprints recorded the last time activities were armed, keyed by
    /// `DeviceActivityName` raw value. Empty means "restart everything planned
    /// and armed", which is correct and merely chattier.
    func armedFingerprints() -> [String: String]

    /// Records the fingerprints of everything now known to be armed correctly.
    ///
    /// Called **only after** `startMonitoring` returned without throwing. A map
    /// written before that would claim an activity is armed with a schedule it
    /// is not, and that is the one genuinely unsafe state this type can be in.
    func recordArmedFingerprints(_ fingerprints: [String: String])
}

/// The no-op recorder: every pass re-arms everything.
///
/// The default for tests and for any process where the container is not
/// available. Correct, just chattier — which is the safe direction, since the
/// cost is daemon round trips and the alternative failure is an activity armed
/// with a stale window.
public struct EphemeralArmedActivities: ArmedActivityRecording {

    public init() {}

    public func armedFingerprints() -> [String: String] { [:] }

    public func recordArmedFingerprints(_ fingerprints: [String: String]) {}
}

// MARK: - Reconciler (pure half)

/// The reconcile. See the file header.
///
/// An uninhabited namespace: there is no reconciler *instance* anywhere in Gate,
/// because holding one would mean holding state between passes, and every pass
/// is written assuming a cold start (docs/05-architecture.md, enforcement
/// layering).
public struct Reconciler {

    private init() {}

    // MARK: Temporal advance

    /// What ``advance(_:now:calendar:)`` did: step 3 of V1-10, as a pure value.
    public struct Advance: Sendable, Equatable {

        /// The state after expiry and release. Always usable.
        public let state: GateState

        /// Grants that expired since the last reconcile. Informational — nothing
        /// downstream reads it, because enforcement recomputes liveness from
        /// ``Grant/isActive(at:)`` rather than from a list.
        public let expired: [Grant]

        /// Grants still live, soonest expiry first.
        public let active: [Grant]

        /// When the soonest live grant runs out, if any.
        public let nextGrantExpiry: Date?

        /// Loosenings the Lock released on elapsed time, in deadline order.
        public let released: [PendingChange]

        /// Work outside `state.plist` that the caller still owes:
        /// `selections.plist`, the Keychain, `AuthorizationCenter`.
        public let effects: Ratchet.SideEffects

        public init(
            state: GateState,
            expired: [Grant],
            active: [Grant],
            nextGrantExpiry: Date?,
            released: [PendingChange],
            effects: Ratchet.SideEffects
        ) {
            self.state = state
            self.expired = expired
            self.active = active
            self.nextGrantExpiry = nextGrantExpiry
            self.released = released
            self.effects = effects
        }
    }

    /// Expires grants and releases ripe pending changes, by absolute timestamp.
    ///
    /// Pure, total, and the same answer in every process — which is what lets the
    /// monitor apply a release the app has not recorded yet and still be right.
    /// Nothing here consults a timer, a callback, or how long the process has
    /// been alive: *"every deadline is an absolute timestamp in `state.plist`"*
    /// (docs/05-architecture.md), so the correct answer is a function of `now`
    /// alone and survives the device having been asleep for a week.
    ///
    /// Order is deliberate:
    ///
    /// 1. **Sweep grants.** ``GrantEngine/sweep(_:now:since:calendar:)`` also
    ///    compacts — it strips the token bytes from terminal grants and caps the
    ///    history — which is what keeps `GateState` inside its 8 KB budget.
    /// 2. **Release ripe changes**, through ``Ratchet/releaseRipe(in:now:)`` and
    ///    never through a second copy of the projection. Two implementations of
    ///    "what does a released loosening do" is exactly how a rule silently
    ///    keeps enforcing something the user was told it would stop enforcing.
    /// 3. **Prune** terminal history past its retention. Temporal, so it is kept
    ///    out of `migrate` and done here.
    /// 4. **Recompute the Keychain mirror.** ``Ratchet/lockClockMirror(for:now:)``
    ///    is the projection; whether it *changed* is decided field by field,
    ///    ignoring `updatedAt`, because the merge rule is "trust the newer copy"
    ///    and a gratuitous timestamp bump would let a no-op App Group write
    ///    outrank a real Keychain deadline.
    public static func advance(
        _ state: GateState,
        now: Date,
        calendar: Calendar = .current
    ) -> Advance {
        let sweep = GrantEngine.sweep(state, now: now, calendar: calendar)

        let release = Ratchet.releaseRipe(in: sweep.state, now: now)
        var working = release.state.pruned(now: now)
        var effects = release.effects

        let mirror = Ratchet.lockClockMirror(for: working, now: now)
        if !describesSameDeadline(mirror, working.lockClock) {
            working.lockClock = mirror
            effects = effects.merging(Ratchet.SideEffects(mirrorsLockClock: true))
        }

        return Advance(
            state: working,
            expired: sweep.expired,
            active: sweep.active,
            nextGrantExpiry: sweep.nextExpiry,
            released: release.released,
            effects: effects
        )
    }

    /// Whether two mirrors describe the same deadline.
    ///
    /// Every field except `updatedAt`, which ``Ratchet/lockClockMirror(for:now:)``
    /// stamps with `now` on every call and which therefore says nothing about
    /// whether the deadline moved.
    private static func describesSameDeadline(
        _ lhs: LockClockRecord?,
        _ rhs: LockClockRecord?
    ) -> Bool {
        lhs?.pendingChangeID == rhs?.pendingChangeID
            && lhs?.earliestApplyAt == rhs?.earliestApplyAt
            && lhs?.lockConfigHash == rhs?.lockConfigHash
            && lhs?.installID == rhs?.installID
    }

    // MARK: Backstop moments

    /// The upcoming instants worth arming a `UNCalendarNotificationTrigger` for
    /// (docs/04-product-spec.md V1-10 step 5).
    ///
    /// These exist because the two faster paths are both unreliable:
    /// `intervalDidStart` / `intervalDidEnd` fire only when the device is in use
    /// (docs/03-hard-constraints.md #27) and the monitor extension may never
    /// launch at all (#32). A local notification at a boundary is the third,
    /// independent path — it cannot enforce anything itself, but it gives the
    /// user a reason to open the app, and opening the app is a reconcile.
    ///
    /// Sources, merged: every schedule boundary the plan knows about, the moment
    /// the soonest queued loosening ripens, and the moment the soonest live grant
    /// runs out. Returned sorted, de-duplicated to the second, and capped.
    public static func backstopDates(
        state: GateState,
        plan: MonitorPlan,
        now: Date,
        limit: Int = 8
    ) -> [Date] {
        guard limit > 0 else { return [] }

        var seen: Set<Int> = []
        var dates: [Date] = []

        func consider(_ date: Date?) {
            guard let date, date > now else { return }
            // Second resolution: two boundaries a few milliseconds apart are one
            // notification, and `UNCalendarNotificationTrigger` has no finer
            // granularity anyway.
            let key = Int(date.timeIntervalSinceReferenceDate.rounded())
            guard seen.insert(key).inserted else { return }
            dates.append(date)
        }

        for entry in plan.entries {
            consider(entry.occurrence?.start)
            consider(entry.occurrence?.end)
            consider(entry.deadline)
        }
        consider(state.nextDeadline(after: now))

        return Array(dates.sorted().prefix(limit))
    }
}

// MARK: - Report

/// Everything one reconcile did, rich enough to render whole on the debug screen
/// (docs/04-product-spec.md V1-11) and to drive the app's next move.
///
/// `Sendable` and `Equatable` throughout: it crosses from the non-isolated
/// reconcile back to the `@MainActor` model, and comparing two reports is how a
/// test asserts idempotence. Deliberately holds no `ResolvedTokens` and no
/// `Token<_>` — those have no audited `Sendable` conformance and never leave the
/// synchronous call that created them.
public struct ReconcileReport: Sendable, Equatable {

    // MARK: Identity

    /// The instant this pass was computed for. Every decision inside is a
    /// function of it.
    public let now: Date

    public let role: ReconcileRole
    public let trigger: ReconcileTrigger

    // MARK: State

    /// The state after the pass — the value the caller should adopt in memory,
    /// whether or not it was persisted.
    public let state: GateState

    /// What ``GateState/migrate(_:now:)`` had to repair on the way in.
    public let migration: GateState.MigrationReport

    /// Whether `state.plist` was actually rewritten.
    ///
    /// `false` on an idempotent pass is the *expected* outcome, not a problem:
    /// nothing changed, so nothing was written.
    public let didPersistState: Bool

    /// Whether the recomputed state differs from what was on disk.
    public let didChangeState: Bool

    /// The generation beacon after the pass.
    public let generation: Int

    // MARK: Inbox

    /// What came out of `inbox/`.
    public struct InboxSummary: Sendable, Equatable {

        /// Files read and deleted.
        public let consumed: Int

        /// Files that would not decode. Deleted — they can never become
        /// readable — and counted here so a recurring writer bug is visible.
        public let corrupt: Int

        /// Files left in place because they could not be read this pass.
        /// **Never deleted**, so nothing is lost; ``InboxDrain/hasMore``.
        public let deferred: Int

        /// Events that arrived twice because a previous drain deleted after
        /// reading and did not survive to finish.
        public let redelivered: Int

        /// Events by kind.
        public let counts: [InboxEvent.Kind: Int]

        /// Shield taps reconstructed from the drain, oldest first.
        ///
        /// An entry with no ``InterventionRequest/resolution`` is **open** and
        /// the app must route it to the intervention screen now
        /// (docs/04-product-spec.md V1-7): draining deleted the file, so this
        /// report is the only remaining copy. One with a resolution is history —
        /// a "Not now" tap, which is the outcome the product is trying to
        /// produce.
        public let requests: [InterventionRequest]

        /// Grants actually issued while folding (the iOS 26.4+ submenu path,
        /// docs/04-product-spec.md V2-1).
        ///
        /// Empty on any device below iOS 26.4, where no submenu exists and the
        /// grant is earned on the intervention screen rather than at the shield.
        /// On 26.4+ `GateShieldAction.grantFromSubmenu` writes a `.grantIssued`
        /// event, so this is non-empty whenever such a tap was folded — by the
        /// app's drain, or read-only by the monitor under
        /// ``ReconcileOptions/foldsPendingGrants``, in which case the same record
        /// is folded again, for real, on the app's next foreground.
        public let issued: [Grant]

        /// Why issuance was refused, by reason.
        public let denials: [InterventionRequest.DenialReason: Int]

        /// Taps dropped as redeliveries — seen twice in this drain, or already
        /// named by a grant in state. See the deduplication note on
        /// ``Reconciler/fold(_:into:now:calendar:isAuthorized:)``.
        public let duplicates: Int

        public init(
            consumed: Int = 0,
            corrupt: Int = 0,
            deferred: Int = 0,
            redelivered: Int = 0,
            counts: [InboxEvent.Kind: Int] = [:],
            requests: [InterventionRequest] = [],
            issued: [Grant] = [],
            denials: [InterventionRequest.DenialReason: Int] = [:],
            duplicates: Int = 0
        ) {
            self.consumed = consumed
            self.corrupt = corrupt
            self.deferred = deferred
            self.redelivered = redelivered
            self.counts = counts
            self.requests = requests
            self.issued = issued
            self.denials = denials
            self.duplicates = duplicates
        }

        public static let empty = InboxSummary()

        /// Shield taps still awaiting the intervention screen.
        public var openRequests: [InterventionRequest] {
            requests.filter { $0.resolution == nil }
        }

        /// Taps that ended without a grant — the bypass-attempt count
        /// (docs/04-product-spec.md V2-5).
        public var bypassAttempts: Int {
            requests.reduce(into: 0) { $0 += $1.isBypassAttempt ? 1 : 0 }
        }

        /// More files are waiting; run another pass.
        public var hasMore: Bool { deferred > 0 }
    }

    public let inbox: InboxSummary

    // MARK: Time

    /// Grants that ran out since the last reconcile.
    public let expiredGrants: [Grant]

    /// Grants still live, soonest expiry first.
    public let activeGrants: [Grant]

    /// Loosenings the Lock released this pass. These are the moments the user is
    /// owed a truthful "that change is now in effect".
    public let releasedChanges: [PendingChange]

    /// Work outside `state.plist` the caller still owes. ``Reconciler`` performs
    /// the `selections.plist` half itself when the role allows; the Keychain
    /// mirror and `AuthorizationCenter.revokeAuthorization` remain the caller's,
    /// because the kernel links neither `Security` nor `FamilyControls`.
    public let effects: Ratchet.SideEffects

    // MARK: Enforcement

    /// One per rule, in ``ShieldPlanner/plans(for:now:calendar:)`` order.
    public let shieldPlans: [ShieldPlan]

    /// One per store written, in the same order, plus install protection and any
    /// retired store.
    public let shieldWrites: [ShieldWriteReport]

    /// Whether `shield.plist`'s token index was republished this pass.
    public let didPublishShieldCopy: Bool

    // MARK: Activities

    /// What happened at the `DeviceActivityCenter` boundary.
    public struct ActivitySummary: Sendable, Equatable {

        /// `DeviceActivityName`s armed when the pass began.
        public let armedBefore: [String]

        /// Stopped: orphans, plus anything being re-armed with a new schedule.
        public let stopped: [String]

        /// Armed successfully, in plan order — most important first.
        public let started: [String]

        /// Already armed and already correct. Left alone: re-arming an open
        /// window resets its interval and costs a callback for nothing.
        public let unchanged: [String]

        /// Armed names outside ``GateID/namespace``. Reported, never stopped.
        public let foreign: [String]

        /// Activities that refused to arm.
        public let failures: [ActivityFailure]

        public init(
            armedBefore: [String] = [],
            stopped: [String] = [],
            started: [String] = [],
            unchanged: [String] = [],
            foreign: [String] = [],
            failures: [ActivityFailure] = []
        ) {
            self.armedBefore = armedBefore
            self.stopped = stopped
            self.started = started
            self.unchanged = unchanged
            self.foreign = foreign
            self.failures = failures
        }

        public static let empty = ActivitySummary()

        /// Nothing to do — the steady state, and the cheapest possible outcome.
        public var isNoOp: Bool { stopped.isEmpty && started.isEmpty }
    }

    /// One activity that would not arm.
    public struct ActivityFailure: Sendable, Equatable, Hashable {

        /// `DeviceActivityCenter.MonitoringError`, flattened so the report stays
        /// free of SDK types and usable from the platform-agnostic test package.
        public enum Kind: String, Sendable, Hashable, CaseIterable {

            /// More than twenty activities across the app and all its
            /// extensions. Should be unreachable: ``MonitorPlan`` evicts to stay
            /// under the cap precisely so this is never thrown at an arbitrary
            /// moment. Reaching it means something outside Gate's plan is armed.
            case excessiveActivities

            /// Longer than one week.
            case intervalTooLong

            /// Shorter than fifteen minutes.
            case intervalTooShort

            /// The `DateComponents` did not resolve.
            case invalidDateComponents

            /// Family Controls authorization is not approved
            /// (docs/03-hard-constraints.md #14).
            case unauthorized

            /// Something else, or a case added after this build.
            case unknown
        }

        public let name: String
        public let kind: Kind
        public let message: String

        public init(name: String, kind: Kind, message: String) {
            self.name = name
            self.kind = kind
            self.message = message
        }
    }

    public let activities: ActivitySummary

    /// The plan this pass tried to realise.
    public let plan: MonitorPlan

    // MARK: Follow-up

    /// Instants the app should arm `UNCalendarNotificationTrigger` backstops for
    /// (docs/04-product-spec.md V1-10 step 5). Sorted, soonest first.
    ///
    /// Reported rather than performed: only the app can hold notification
    /// authorization, and `UserNotifications` must not enter the monitor's dyld
    /// closure (docs/03-hard-constraints.md #31).
    public let backstopDates: [Date]

    /// The soonest of the two deadlines that live in state — a queued loosening
    /// ripening, a live grant running out.
    public let nextStateDeadline: Date?

    // MARK: Diagnostics

    /// Things the pass noticed and survived.
    public let warnings: [ReconcileWarning]

    /// Things that went wrong and did not stop the pass.
    ///
    /// Activities that would not arm are **not** here — they are typed values in
    /// ``ActivitySummary/failures``. ``isClean`` reads both.
    public let failures: [ReconcileFailure]

    public init(
        now: Date,
        role: ReconcileRole,
        trigger: ReconcileTrigger,
        state: GateState,
        migration: GateState.MigrationReport,
        didPersistState: Bool,
        didChangeState: Bool,
        generation: Int,
        inbox: InboxSummary,
        expiredGrants: [Grant],
        activeGrants: [Grant],
        releasedChanges: [PendingChange],
        effects: Ratchet.SideEffects,
        shieldPlans: [ShieldPlan],
        shieldWrites: [ShieldWriteReport],
        didPublishShieldCopy: Bool,
        activities: ActivitySummary,
        plan: MonitorPlan,
        backstopDates: [Date],
        nextStateDeadline: Date?,
        warnings: [ReconcileWarning],
        failures: [ReconcileFailure]
    ) {
        self.now = now
        self.role = role
        self.trigger = trigger
        self.state = state
        self.migration = migration
        self.didPersistState = didPersistState
        self.didChangeState = didChangeState
        self.generation = generation
        self.inbox = inbox
        self.expiredGrants = expiredGrants
        self.activeGrants = activeGrants
        self.releasedChanges = releasedChanges
        self.effects = effects
        self.shieldPlans = shieldPlans
        self.shieldWrites = shieldWrites
        self.didPublishShieldCopy = didPublishShieldCopy
        self.activities = activities
        self.plan = plan
        self.backstopDates = backstopDates
        self.nextStateDeadline = nextStateDeadline
        self.warnings = warnings
        self.failures = failures
    }

    // MARK: Queries

    /// Nothing failed and nothing was refused.
    public var isClean: Bool {
        failures.isEmpty && activities.failures.isEmpty && refusedRuleIDs.isEmpty
    }

    /// Rules whose store this pass deliberately left untouched.
    public var refusedRuleIDs: [UUID] {
        shieldWrites.filter { $0.refusal != nil }.compactMap(\.ruleID)
    }

    /// Rules enforcing a shield right now.
    public var enforcingRuleIDs: [UUID] {
        shieldPlans.filter(\.isEnforcing).map(\.ruleID)
    }

    /// Whether this pass changed anything **durable** — the container, or the
    /// daemon's activity list. `false` is what the second of two identical calls
    /// must report, and is the assertion an idempotence test makes.
    ///
    /// `ManagedSettingsStore` writes are excluded on purpose. ``ShieldWriter``
    /// re-asserts the same four shield properties on every pass, which is
    /// exactly how it heals a store the system dropped or a token the daemon
    /// reissued (docs/03-hard-constraints.md #36), so "a store was written" is
    /// the steady state and not evidence that anything moved.
    public var didChangeAnything: Bool {
        didPersistState
            || didPublishShieldCopy
            || !activities.isNoOp
            || inbox.consumed > 0
    }

    /// The caller must mirror ``GateState/lockClock`` into the Keychain.
    public var needsLockClockMirror: Bool { effects.mirrorsLockClock }

    /// The caller must call `AuthorizationCenter.shared.revokeAuthorization`.
    public var needsAuthorizationRevocation: Bool { effects.revokesAuthorization }

    /// One block of text for the debug screen. Never throws, never elides a
    /// failure, and contains no Screen Time data — Gate holds none
    /// (docs/03-hard-constraints.md #25, #30).
    public func diagnosticDescription() -> String {
        var lines: [String] = []
        lines.append("reconcile \(role.rawValue)/\(trigger.rawValue) at \(now)")
        lines.append("state: \(state.rules.count) rule(s), generation \(generation), "
            + "persisted=\(didPersistState), changed=\(didChangeState)")
        if !migration.isNoOp {
            lines.append("migration: v\(migration.fromSchemaVersion) -> v\(migration.toSchemaVersion), "
                + "\(migration.repairs.count) repair(s), fromFuture=\(migration.isFromFuture)")
        }
        lines.append("inbox: consumed \(inbox.consumed), corrupt \(inbox.corrupt), "
            + "deferred \(inbox.deferred), open requests \(inbox.openRequests.count)")
        lines.append("grants: \(activeGrants.count) active, \(expiredGrants.count) expired this pass")
        lines.append("pending: \(state.openPendingChanges.count) open, "
            + "\(releasedChanges.count) released this pass")
        lines.append("shields: \(enforcingRuleIDs.count) enforcing, "
            + "\(shieldWrites.filter(\.didWrite).count) store write(s), "
            + "\(refusedRuleIDs.count) refused")
        lines.append("activities: \(activities.armedBefore.count) armed -> "
            + "\(activities.stopped.count) stopped, \(activities.started.count) started, "
            + "\(activities.unchanged.count) unchanged, \(activities.failures.count) failed")
        if !plan.evictions.isEmpty {
            lines.append("evictions: \(plan.evictions.count) (20-activity cap)")
        }
        lines.append("next deadline: \(nextStateDeadline.map { "\($0)" } ?? "none")")
        lines.append("backstops: \(backstopDates.count)")
        for warning in warnings { lines.append("  warning: \(String(describing: warning))") }
        for failure in failures { lines.append("  FAILURE: \(failure.description)") }
        for failure in activities.failures {
            lines.append("  FAILURE: startMonitoring[\(failure.name)] \(failure.kind.rawValue): \(failure.message)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Container-backed helpers

// `os` and `PlistFile` (`Kernel/Store/GateStateStore.swift`) are the fence for
// everything that touches the App Group.
//
// Unlike its pure siblings, this file is not a candidate for the
// platform-agnostic SwiftPM package (docs/05-architecture.md, module layer
// split): it is the I/O half of step 3.10 and every meaningful path in it talks
// to a daemon or a container. What the fences buy instead is an accurate
// statement, checked by the compiler, of which SDK each region needs — so the
// reconcile can never quietly acquire a dependency the 6 MB monitor cannot pay
// for (docs/03-hard-constraints.md #31). The arithmetic that *is* worth testing
// without a device — `advance` and `backstopDates` — is pure, injected with
// `now` and a `Calendar`, and reachable from a fake `StateStoring`.

#if canImport(os)

import os

/// Computed rather than a stored global: `Logger` is an SDK type with no audited
/// `Sendable` conformance, so a stored static of one is a Swift 6
/// strict-concurrency error. Constructing it is cheap — it wraps an existing
/// `os_log_t`. Same reasoning as `Kernel/Store/GateStateStore.swift`.
///
/// `print()` is never an option: it is invisible from an extension
/// (docs/06-build-plan.md step 4.1).
private var reconcileLog: Logger {
    Logger(subsystem: GateID.Subsystem.kernel, category: "reconciler")
}

/// The armed-fingerprint cache, in `armed.plist` in the App Group container.
///
/// **The one file in the container an extension may write.** The single-writer
/// discipline exists to protect `state.plist`, `selections.plist` and
/// `shield.plist`, whose loss or corruption is a silently unenforced block. This
/// file is a cache of what the daemon was last told; both processes derive it
/// from the same `state.plist`, so a race between them writes the same values,
/// and the one genuinely divergent case — a process that armed from a state the
/// other has since replaced — self-heals on the next pass, because the newer
/// plan's fingerprints will not match the recorded ones and the activities are
/// simply re-armed.
///
/// Uncoordinated and atomic, like `shield.plist`: `NSFileCoordinator` buys
/// ordering against participating readers, and what makes a concurrent read safe
/// is `rename(2)` (``AppGroupContainer/writingOptions``).
public struct ArmedActivityFile: ArmedActivityRecording {

    private let file: PlistFile<[String: String]>

    /// The default location, `<container>/armed.plist`.
    ///
    /// - Throws: ``AppGroupContainer/ContainerError`` when the App Group does not
    ///   resolve. Prefer ``resolved()``, which degrades to
    ///   ``EphemeralArmedActivities`` instead of failing a reconcile over a cache.
    public init() throws {
        let url = try AppGroupContainer.armedActivitiesURL
        self.init(url: url)
    }

    /// An explicit location, for tests.
    public init(url: URL) {
        self.file = PlistFile(url: url, coordinated: false)
    }

    /// The best recorder available in this process.
    ///
    /// Never fails: without a container there is no cache, and without a cache
    /// every pass re-arms everything, which is correct.
    public static func resolved() -> any ArmedActivityRecording {
        if let file = try? ArmedActivityFile() { return file }
        return EphemeralArmedActivities()
    }

    public func armedFingerprints() -> [String: String] {
        (try? file.read()) ?? [:]
    }

    public func recordArmedFingerprints(_ fingerprints: [String: String]) {
        // Idempotent: an unchanged map is not rewritten, so two identical
        // reconciles touch the filesystem once between them, not twice.
        guard fingerprints != armedFingerprints() else { return }
        do {
            try file.write(fingerprints)
        } catch {
            // A cache miss costs a round of redundant stop/start calls. It must
            // never fail the pass, and it is not worth a `ReconcileFailure`
            // either — the next pass simply re-arms.
            reconcileLog.debug("could not record armed fingerprints: \(String(describing: error), privacy: .public)")
        }
    }
}

/// `selections.plist` — the side table of `FamilyActivitySelection` blobs.
///
/// The reconciler touches it for exactly two reasons, both bookkeeping: applying
/// the ``Ratchet/SideEffects`` a released loosening produced, and sweeping blobs
/// whose owner no longer exists. It never *reads* a payload — decoding one means
/// naming `FamilyActivitySelection`, which `GateKernel` does not do (see
/// ``SelectionResolving``).
public enum SelectionTableFile {

    /// Uncoordinated and atomic, for the same reason as `shield.plist`.
    public static func file() throws -> PlistFile<SelectionTable> {
        PlistFile(url: try AppGroupContainer.selectionsURL, coordinated: false)
    }

    /// The table, or `nil` when there is none yet or it will not decode.
    ///
    /// A missing table is the ordinary first-run state. An undecodable one is
    /// reported by the caller as a ``ReconcileFailure`` and otherwise left
    /// strictly alone: rewriting it from a failed read would delete every
    /// selection in the install.
    public static func read() throws -> SelectionTable? {
        let plist = try file()
        guard plist.exists else { return nil }
        return try plist.read()
    }

    @discardableResult
    public static func write(_ table: SelectionTable) throws -> Int {
        try file().write(table)
    }
}

// MARK: - Folding the inbox

public extension Reconciler {

    /// What ``fold(_:into:now:calendar:isAuthorized:)`` produced.
    struct InboxFold: Sendable, Equatable {

        /// State with the drained events folded in.
        public let state: GateState

        /// Shield taps reconstructed from the drain, oldest first.
        public let requests: [InterventionRequest]

        /// Grants issued while folding — the iOS 26.4+ shield-submenu path
        /// (docs/04-product-spec.md V2-1). Empty below 26.4, where nothing writes
        /// a ``InboxEvent/Kind/grantIssued`` record.
        public let issued: [Grant]

        /// Why issuance was refused, by reason.
        public let denials: [InterventionRequest.DenialReason: Int]

        /// Taps dropped as redeliveries.
        public let duplicates: Int

        /// Events by kind, including the ones that changed nothing.
        public let counts: [InboxEvent.Kind: Int]

        public init(
            state: GateState,
            requests: [InterventionRequest] = [],
            issued: [Grant] = [],
            denials: [InterventionRequest.DenialReason: Int] = [:],
            duplicates: Int = 0,
            counts: [InboxEvent.Kind: Int] = [:]
        ) {
            self.state = state
            self.requests = requests
            self.issued = issued
            self.denials = denials
            self.duplicates = duplicates
            self.counts = counts
        }
    }

    /// Folds drained `inbox/` events into state. Pure — no I/O, no `Date()`.
    ///
    /// ### What each kind does, and why
    ///
    /// * ``InboxEvent/Kind/grantRequest`` — **no grant is issued.** The event
    ///   means "the user tapped *Let me in* on a shield", not "the user earned
    ///   an unblock". Issuing here would hand them the app for one tap and
    ///   delete the product: V1-7 is a forced wait, then a typed reason, *then*
    ///   a grant. The reconstructed ``InterventionRequest`` is returned so the
    ///   app can put the intervention screen in front of them.
    /// * ``InboxEvent/Kind/grantIssued`` — a grant the shield extension already
    ///   decided (the iOS 26.4+ submenu, docs/04-product-spec.md V2-1; written
    ///   whenever the device has the submenu at all). Routed through
    ///   ``GrantEngine/issue(for:in:now:calendar:isAuthorized:duration:reason:grantID:maxAge:)``
    ///   so the daily budget is decremented in exactly one place, and the grant
    ///   adopts the event's `id` so it inherits the one-shot expiry activity the
    ///   extension already armed. This is the one kind a non-draining pass may
    ///   fold read-only (``ReconcileOptions/foldsPendingGrants``), which is safe
    ///   only because the deduplication below makes a second fold a no-op.
    /// * ``InboxEvent/Kind/bypassAttempt`` — a "Not now" tap. The outcome the
    ///   product exists to produce, and the counter the stats screen will show
    ///   (docs/04-product-spec.md V2-5). v1 `GateState` has nowhere to store the
    ///   running total, so it is reported and not persisted.
    /// * ``InboxEvent/Kind/tokenExpiry`` — stamps ``GateState/tokenExpiryObservedAt``
    ///   and puts the recovery screen in front of the user (V1-9).
    /// * ``InboxEvent/Kind/breadcrumb`` and ``InboxEvent/Kind/unknown`` —
    ///   counted, nothing more.
    ///
    /// ### Deduplication
    ///
    /// `InboxStore` delivery is **at-least-once**: it reads a file then deletes
    /// it, and a process that does not survive the gap redelivers. The dedup key
    /// is the event's own id, tested two ways — once against the rest of this
    /// drain, and once against ``Grant/requestID``, which is that same id
    /// recorded on the grant the tap eventually produced.
    ///
    /// That is exact rather than approximate, and it needs no ring of consumed
    /// ids in `GateState`. The window it has to cover is however long the record
    /// stays actionable: ``InterventionRequest/maxAge`` — fifteen minutes — for
    /// a ``InboxEvent/Kind/grantRequest``, and the granted duration for a
    /// ``InboxEvent/Kind/grantIssued`` (see the `.grantIssued` arm below for why
    /// the two differ). A redelivery older than its window is refused as stale
    /// before it can matter. Either way the grant is still inside
    /// ``Grant/terminalRetention`` — seven days — so
    /// ``GrantEngine/compacted(_:now:)`` has not dropped the record the test
    /// looks for. Token bytes are stripped from terminal grants, but
    /// ``Grant/requestID`` is not one of them.
    ///
    /// - Parameter isAuthorized: see ``ReconcileOptions/isAuthorized``.
    static func fold(
        _ events: [InboxEvent],
        into state: GateState,
        now: Date,
        calendar: Calendar = .current,
        isAuthorized: Bool = true
    ) -> InboxFold {
        var working = state
        var requests: [InterventionRequest] = []
        var issued: [Grant] = []
        var denials: [InterventionRequest.DenialReason: Int] = [:]
        var counts: [InboxEvent.Kind: Int] = [:]
        var duplicates = 0
        var seen: Set<UUID> = []

        /// `true` when this tap has already been accounted for — either earlier
        /// in this same drain, or by a grant already in state that names it.
        func isRedelivery(_ id: UUID) -> Bool {
            guard seen.insert(id).inserted else { return true }
            return working.grants.contains { $0.requestID == id }
        }

        for event in events {
            counts[event.kind, default: 0] += 1

            switch event.kind {
            case .grantRequest, .bypassAttempt:
                // Reconstructed and handed back; never issued here.
                guard let request = GrantEngine.interventionRequest(from: event) else { continue }
                guard !isRedelivery(request.id) else {
                    duplicates += 1
                    continue
                }
                requests.append(request)

            case .grantIssued:
                guard let request = GrantEngine.interventionRequest(from: event) else { continue }
                guard !isRedelivery(request.id) else {
                    duplicates += 1
                    continue
                }
                // `grantID: request.id` matches AppModel.grant(for:reason:duration:now:).
                // `GateShieldAction` already armed a one-shot expiry activity named
                // for this id, so the grant must adopt it — minting a fresh UUID
                // here would orphan that timer and make MonitorPlan.diff stop it
                // and start another (docs/05-architecture.md, activity budget).
                let duration = GrantEngine.requestedDuration(in: event)

                // `.grantIssued` does NOT get `InterventionRequest.maxAge`.
                //
                // That fifteen-minute window is a security property of the
                // `.grantRequest` path, where the record is a *pointer* the app
                // must not honour late — an hour-old deep link must not still
                // convert into access. A `.grantIssued` record is the opposite:
                // the iOS 26.4+ submenu already granted it at the shield and
                // already armed the expiry timer, so folding it is bookkeeping
                // over a decision that has been enforced since the tap. Judging
                // it by the request window would deny "1 hour" as `.stale` after
                // fifteen minutes while the timer it describes still fires
                // forty-five minutes later — the ledger disagreeing with the
                // device (docs/04-product-spec.md V2-1).
                //
                // The honest window is the life of the grant itself, floored at
                // the request window so a duration-less record behaves as before.
                // Past it the grant would have expired anyway, so `.stale` is
                // then the correct answer. Dedup is unaffected: `isRedelivery`
                // matches on `Grant/requestID`, retained for
                // `Grant.terminalRetention` (7 days).
                let issuedMaxAge = max(InterventionRequest.maxAge, duration ?? 0)

                let issuance = GrantEngine.issue(
                    for: request,
                    in: working,
                    now: now,
                    calendar: calendar,
                    isAuthorized: isAuthorized,
                    duration: duration,
                    grantID: request.id,
                    maxAge: issuedMaxAge
                )
                working = issuance.state
                if let grant = issuance.grant { issued.append(grant) }
                if let denial = issuance.denial { denials[denial, default: 0] += 1 }
                requests.append(issuance.request ?? request)

            case .tokenExpiry:
                // The latest observation wins. Recovery is a tightening and is
                // never gated behind the Lock (docs/04-product-spec.md V1-9).
                let observed = max(working.tokenExpiryObservedAt ?? .distantPast, event.createdAt)
                if working.tokenExpiryObservedAt != observed {
                    working.tokenExpiryObservedAt = observed
                    working.updatedAt = now
                }

            case .breadcrumb, .unknown:
                continue
            }
        }

        return InboxFold(
            state: working,
            requests: requests.sorted {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            },
            issued: issued,
            denials: denials,
            duplicates: duplicates,
            counts: counts
        )
    }
}

#endif

// MARK: - Selection resolution

#if canImport(ManagedSettings)

import ManagedSettings

/// Turns a rule's stored selection into live tokens.
///
/// **The seam that keeps `FamilyControls` out of the kernel.** Decoding a
/// selection means naming `FamilyActivitySelection`, and `GateKernel` never does
/// — the model layer stores an opaque blob, `Kernel/Enforcement/TokenGuard.swift`
/// owns the token codec, and this protocol is where the one type that must be
/// named enters from outside. `Kernel/Store/SelectionStore.swift` is the intended
/// conformer; the app and the monitor each construct one.
///
/// **Not `Sendable`, deliberately.** ``ResolvedTokens`` holds `Token<_>` values
/// with no audited `Sendable` conformance, so a resolver must not be captured in
/// a `Task`, stored in an actor, or held across an `await`. A reconcile is one
/// synchronous call and everything a resolver produces dies inside it.
public protocol SelectionResolving {

    /// The rule's selection, decoded. `nil` means the blob is missing or will
    /// not decode.
    ///
    /// Returning `nil` makes ``ShieldWriter`` **refuse** that rule's write
    /// rather than empty its store: a store left alone is enforcing yesterday's
    /// correct answer, and a store emptied on the strength of a failed read is
    /// an unblocked app the user asked to have blocked (docs/03-hard-constraints.md
    /// #36 — stale tokens are routine, not exceptional).
    func resolvedTokens(forRuleID ruleID: UUID) -> ResolvedTokens?
}

/// A ``SelectionResolving`` built from a closure, for tests and for a caller
/// that already has the decode in hand.
public struct SelectionResolver: SelectionResolving {

    private let resolve: (UUID) -> ResolvedTokens?

    public init(_ resolve: @escaping (UUID) -> ResolvedTokens?) {
        self.resolve = resolve
    }

    /// Resolves nothing. Every enforcing rule is refused and every store is left
    /// exactly as it is — the correct behaviour for a process that cannot read
    /// selections, and never an accidental unblock.
    public static var none: SelectionResolver { SelectionResolver { _ in nil } }

    public func resolvedTokens(forRuleID ruleID: UUID) -> ResolvedTokens? {
        resolve(ruleID)
    }
}

#endif

// MARK: - The reconcile

// Needs all three SDK surfaces at once: `ManagedSettings` for the stores,
// `DeviceActivity` for the daemon, `os` for the container helpers above. On iOS
// all three are present. Spelling the requirement out is what keeps a future
// edit honest: anything added here that needs a fourth framework has to say so,
// in a fence, where the monitor's dyld closure is visible.

#if canImport(ManagedSettings) && canImport(DeviceActivity) && canImport(os)

import DeviceActivity

public extension Reconciler {

    /// Recomputes ground truth and makes the device match it.
    ///
    /// The single function the app and the monitor both call
    /// (docs/06-build-plan.md step 3.10). Steps, in order:
    ///
    /// 1. Re-read `GateState` from the App Group and migrate it. **Never trust
    ///    in-memory state** — the monitor is always a cold start, and the app
    ///    may have been suspended across a shield tap that wrote to `inbox/`.
    /// 2. Drain `inbox/` and fold it in — app only, and only when this pass may
    ///    persist what it folds in, because draining deletes. A pass that may not
    ///    drain but may enforce reads the pending `.grantIssued` records instead
    ///    and folds them for this pass only
    ///    (``ReconcileOptions/foldsPendingGrants``), which is how a shield-submenu
    ///    grant reaches the monitor before the app has seen it.
    /// 3. Expire grants and release ripe changes by absolute timestamp.
    /// 4. **Persist**, before touching enforcement. A crash after this point
    ///    costs a redundant recomputation; a crash *before* a persist that came
    ///    after the shield writes would cost a spent grant with no record of it.
    ///    Persist-first errs toward friction, which is the product.
    /// 5. Rewrite every `ManagedSettingsStore` from the recomputed state.
    /// 6. Republish `shield.plist`'s token index (app only).
    /// 7. Diff `center.activities` against ``MonitorPlan``; stop orphans, start
    ///    what is missing, **stopping everything before starting anything**
    ///    (docs/02-api-reference.md §7).
    ///
    /// ### Idempotence
    ///
    /// Calling this twice with the same `now` changes nothing the second time:
    /// state is persisted only when it genuinely differs, `shield.plist` only
    /// when its index differs, the armed cache only when the map differs, and
    /// activities only when a fingerprint moved. ``ReconcileReport/didChangeAnything``
    /// is the assertion a test makes.
    ///
    /// ### Throwing
    ///
    /// Throws only for step 1 — a `state.plist` that exists and will not decode.
    /// That must *not* degrade to an empty state: an empty `GateState` has no
    /// rules, and a pass with no rules empties every store and unblocks
    /// everything. Everything after step 1 is survivable and is reported instead:
    /// see ``ReconcileReport/failures`` and ``ReconcileReport/isClean``.
    ///
    /// - Parameters:
    ///   - now: the instant to reconcile for. Injected everywhere; no `Date()` is
    ///     read inside this call.
    ///   - store: `state.plist`, behind ``StateStoring``.
    ///   - center: `DeviceActivityCenter()`. A struct, so it is cheap to pass.
    ///   - writer: the only type in Gate that writes `ManagedSettingsStore`s.
    ///   - selections: the token decode. See ``SelectionResolving``.
    ///   - inbox: `inbox/`. `nil` resolves the default; a process that cannot
    ///     open it simply drains nothing.
    ///   - armed: where the armed-schedule fingerprints live between passes.
    ///   - options: role, trigger, calendar, authorization.
    @discardableResult
    static func reconcile(
        now: Date = Date(),
        store: any StateStoring,
        center: DeviceActivityCenter = DeviceActivityCenter(),
        writer: ShieldWriter = ShieldWriter(),
        selections: any SelectionResolving,
        inbox: InboxStore? = nil,
        armed: any ArmedActivityRecording = ArmedActivityFile.resolved(),
        options: ReconcileOptions = ReconcileOptions()
    ) throws -> ReconcileReport {

        var warnings: [ReconcileWarning] = []
        var failures: [ReconcileFailure] = []

        // ── 1. Read and migrate ─────────────────────────────────────────────
        //
        // `load(orDefault:)` substitutes a fresh state for `.stateMissing` only;
        // every other error — a decode failure above all — rethrows. A corrupt
        // file must reach the user as a recovery flow, never as "no rules".
        let stored = try store.load(orDefault: GateState.initial(now: now))
        let migrated = GateState.migrate(stored, now: now)
        var state = migrated.state
        let baseline = state

        for repair in migrated.report.repairs {
            warnings.append(.stateRepaired(repair))
        }
        if migrated.report.isFromFuture {
            // Enforce on what we could decode — every lenient decode in the
            // kernel degrades toward *more* friction, so this direction is safe
            // — but never write, because this build's encoder would silently
            // drop the fields the newer build added.
            warnings.append(.stateFromFutureBuild(fileVersion: migrated.report.fromSchemaVersion))
            reconcileLog.fault("""
                state.plist was written by a newer build (schema \
                \(migrated.report.fromSchemaVersion, privacy: .public) > \
                \(GateState.currentSchemaVersion, privacy: .public)); enforcing but not persisting
                """)
        }
        let mayPersist = options.writesState && !migrated.report.isFromFuture

        // Authorization is the single most likely reason a rule has silently
        // stopped working: four taps and every token is voided
        // (docs/03-hard-constraints.md #14). Recording it is what puts the
        // recovery screen in front of the user (V1-9).
        if !options.isAuthorized {
            warnings.append(.authorizationLost)
            if state.tokenExpiryObservedAt == nil {
                state.tokenExpiryObservedAt = now
                state.updatedAt = now
            }
        }

        // ── 2. Drain the inbox ──────────────────────────────────────────────
        var inboxSummary = ReconcileReport.InboxSummary.empty
        let inboxStore = inbox ?? (try? InboxStore())
        // Draining deletes. Whatever it folds into `state` is durable only once
        // step 4 writes it, so hold the events for step 4 to put back.
        var drainedEvents: [InboxEvent] = []

        // ``ReconcileRole/drainsInbox``: a pass that cannot persist what it
        // drained must not drain. `writesState` is the role's half of that;
        // `isFromFuture` is this pass's — a state file from a newer build refuses
        // every write for as long as it is there, so draining under one would
        // destroy the records permanently rather than for a single pass.
        if options.drainsInbox, mayPersist, let inboxStore {
            do {
                let drain = try inboxStore.drainDetailed(limit: options.maxInboxEvents)
                drainedEvents = drain.events
                let folded = fold(
                    drain.events,
                    into: state,
                    now: now,
                    calendar: options.calendar,
                    isAuthorized: options.isAuthorized
                )
                state = folded.state
                inboxSummary = ReconcileReport.InboxSummary(
                    consumed: drain.consumed,
                    corrupt: drain.corrupt,
                    deferred: drain.deferred,
                    redelivered: drain.redelivered,
                    counts: folded.counts,
                    requests: folded.requests,
                    issued: folded.issued,
                    denials: folded.denials,
                    duplicates: folded.duplicates
                )
                if drain.corrupt > 0 { warnings.append(.inboxCorrupt(count: drain.corrupt)) }
                if drain.deferred > 0 { warnings.append(.inboxDeferred(count: drain.deferred)) }
                if drain.redelivered > 0 {
                    warnings.append(.inboxRedelivered(count: drain.redelivered))
                }
            } catch {
                // Never fatal: the files are still there, and the next pass takes
                // them. Reconciling without them is strictly better than not
                // reconciling.
                failures.append(ReconcileFailure(
                    stage: .inboxDrain,
                    message: String(describing: error)
                ))
            }
        } else if options.drainsInbox, !mayPersist {
            // `inboxSummary.deferred` is deliberately left at zero. It is what
            // ``ReconcileReport/InboxSummary/hasMore`` reports, and the app
            // re-reconciles while that is true — which a pass that will not drain
            // at all would do for nothing, every activation.
            reconcileLog.notice("not draining inbox: this pass may not persist what it would fold in")
        } else if options.foldsPendingGrants, let inboxStore {
            // ``ReconcileOptions/foldsPendingGrants``: the monitor's pass, woken
            // by the one-shot `GateShieldAction` armed for a submenu grant. `peek`
            // reads without deleting, so the app still drains these records and
            // the ledger is still decremented in exactly one place.
            //
            // Only `.grantIssued`. A `.grantRequest` has not been granted — the
            // user still has to complete the intervention screen — and folding it
            // here would lift a shield nobody paid for. `.bypassAttempt` is
            // already resolved, `.tokenExpiry` would move a timestamp this pass
            // cannot persist, and `.breadcrumb` is this process's own noise.
            //
            // Filtered by `kind:` rather than after the read, and that is
            // load-bearing: the monitor writes two breadcrumbs per callback into
            // this same directory, so an unfiltered peek truncated at
            // `maxInboxEvents` could miss the grant record entirely once a
            // backlog built up. It also means no breadcrumb is ever decoded here.
            let pending = (try? inboxStore.peek(
                kind: .grantIssued,
                limit: options.maxInboxEvents
            )) ?? []
            if !pending.isEmpty {
                let folded = fold(
                    pending,
                    into: state,
                    now: now,
                    calendar: options.calendar,
                    isAuthorized: options.isAuthorized
                )
                state = folded.state
                // `consumed` stays zero: nothing was consumed. What this pass can
                // honestly report is what it folded and what came of it.
                inboxSummary = ReconcileReport.InboxSummary(
                    counts: folded.counts,
                    requests: folded.requests,
                    issued: folded.issued,
                    denials: folded.denials,
                    duplicates: folded.duplicates
                )
                reconcileLog.notice("""
                    folded \(pending.count, privacy: .public) pending grant record(s) \
                    read-only: \(folded.issued.count, privacy: .public) issued
                    """)
            }
        }

        // ── 3. Expire and release, by absolute timestamp ────────────────────
        let advanced = advance(state, now: now, calendar: options.calendar)
        state = advanced.state
        var effects = advanced.effects

        if effects.mirrorsLockClock { warnings.append(.lockClockNeedsMirroring) }
        if effects.revokesAuthorization { warnings.append(.authorizationRevocationPending) }
        if !effects.stageSelections.isEmpty {
            warnings.append(.unstageableSelections(count: effects.stageSelections.count))
        }

        // ── 4. Persist, before touching enforcement ─────────────────────────
        //
        // Idempotence lives here. `lastReconciledAt` is stamped into the copy
        // that gets written but is deliberately *not* what decides whether to
        // write: if it were, every foreground activation would bump the
        // generation beacon and every extension would decode a file that had not
        // meaningfully changed.
        let didChangeState = state != baseline || !migrated.report.isNoOp
        var didPersistState = false

        if mayPersist, didChangeState {
            state.lastReconciledAt = now
            // Mirror what `bump()` will make the beacon, so the file and the
            // beacon agree. An off-by-one here reads downstream as "re-read",
            // never as "accept something stale".
            state.generation = store.generation &+ 1
            do {
                try store.save(state)
                didPersistState = true
            } catch {
                // Enforcement still runs: the computed state is correct, it is
                // only the record of it that is missing, and the next pass
                // recomputes the same answer from the same timestamps.
                failures.append(ReconcileFailure(
                    stage: .statePersist,
                    message: String(describing: error)
                ))
                // The drain already deleted these files, and the only record of
                // what they carried was the state that just failed to write. Put
                // the two kinds that live nowhere else back, under their original
                // ids — ``InboxEvent/fileName`` is derived from the id, so this
                // rewrites the file that was deleted rather than adding another,
                // and `fold`'s redelivery test drops the event again if a later
                // pass finds the grant already in state.
                //
                // `.grantRequest` and `.bypassAttempt` are deliberately not
                // restored: `fold` never persists them, and this same pass already
                // handed them to the caller in ``ReconcileReport/inbox``.
                if let inboxStore {
                    for event in drainedEvents
                    where event.kind == .grantIssued || event.kind == .tokenExpiry {
                        inboxStore.appendBestEffort(event)
                    }
                }
            }
        }

        // ── 4b. The selection table ─────────────────────────────────────────
        //
        // The half of `SideEffects` the kernel can perform: `selections.plist` is
        // a file in the container. The Keychain mirror and
        // `AuthorizationCenter.revokeAuthorization` stay with the caller — the
        // kernel links neither `Security` nor `FamilyControls`.
        if mayPersist {
            applySelectionEffects(
                effects,
                state: state,
                now: now,
                failures: &failures
            )
            // Consumed. Reported so the caller knows what was done, but cleared
            // from the outstanding set so a caller replaying `report.effects`
            // cannot double-apply them.
            effects.adoptSelections = []
            effects.discardSelections = []
            effects.stageSelections = []
        }

        // ── 5. Shields ──────────────────────────────────────────────────────
        let plans = ShieldPlanner.plans(for: state, now: now, calendar: options.calendar)

        // Resolved once, reused by both the writer and the shield index. A
        // `FamilyActivitySelection` decode is the single largest thing this pass
        // does, and the monitor pays for it under a 6 MB ceiling
        // (docs/03-hard-constraints.md #31).
        //
        // Only *enforcing* rules are resolved: a lifted rule's store is emptied
        // without ever asking for its tokens, so a missing blob can never strand
        // a rule the user has disabled.
        var resolvedByRule: [UUID: ResolvedTokens] = [:]
        if options.writesEnforcement || options.publishesShieldCopy {
            for plan in plans where plan.isEnforcing {
                if let tokens = selections.resolvedTokens(forRuleID: plan.ruleID) {
                    resolvedByRule[plan.ruleID] = tokens
                }
            }
        }

        var shieldWrites: [ShieldWriteReport] = []
        if options.writesEnforcement {
            shieldWrites = writer.apply(plans) { resolvedByRule[$0] }
            shieldWrites.append(writer.applyInstallProtection(state.installProtectionEnabled))
            shieldWrites.append(contentsOf: retireOrphanStores(
                writer: writer,
                liveRuleIDs: state.ruleIDs,
                released: advanced.released
            ))
        }

        for plan in plans {
            for issue in plan.issues {
                warnings.append(.shieldIssue(ruleID: plan.ruleID, issue))
            }
        }
        for write in shieldWrites {
            guard let refusal = write.refusal, let ruleID = write.ruleID else { continue }
            warnings.append(.shieldRefused(ruleID: ruleID, refusal))
        }

        // ── 6. The shield copy index ────────────────────────────────────────
        var didPublishShieldCopy = false
        if options.publishesShieldCopy {
            didPublishShieldCopy = refreshShieldCopyIndex(
                plans: plans,
                resolvedByRule: resolvedByRule,
                state: state,
                now: now,
                failures: &failures
            )
        }

        // ── 7. Activities ───────────────────────────────────────────────────
        let monitorPlan = MonitorPlan.make(from: state, now: now, calendar: options.calendar)
        for eviction in monitorPlan.evictions { warnings.append(.planEviction(eviction)) }
        for diagnostic in monitorPlan.diagnostics { warnings.append(.planDiagnostic(diagnostic)) }

        let activities = synchronizeActivities(
            plan: monitorPlan,
            center: center,
            armed: armed,
            writes: options.writesEnforcement
        )
        if !activities.foreign.isEmpty {
            warnings.append(.foreignActivities(names: activities.foreign))
        }

        // ── 8. Breadcrumb ───────────────────────────────────────────────────
        //
        // The monitor's only evidence that it ran. `state.plist` is closed to it,
        // and a process whose silence is indistinguishable from success is a
        // process nobody can debug (docs/03-hard-constraints.md #32).
        if options.appendsBreadcrumb, let inboxStore {
            let breadcrumb = InboxEvent.breadcrumb(
                source: options.trigger.rawValue,
                detail: "rules=\(state.rules.count) armed=\(activities.started.count + activities.unchanged.count)",
                now: now
            )
            if !inboxStore.appendBestEffort(breadcrumb) {
                failures.append(ReconcileFailure(
                    stage: .breadcrumb,
                    message: "could not append the liveness breadcrumb"
                ))
            }
        }

        let report = ReconcileReport(
            now: now,
            role: options.role,
            trigger: options.trigger,
            state: state,
            migration: migrated.report,
            didPersistState: didPersistState,
            didChangeState: didChangeState,
            generation: store.generation,
            inbox: inboxSummary,
            expiredGrants: advanced.expired,
            activeGrants: advanced.active,
            releasedChanges: advanced.released,
            effects: effects,
            shieldPlans: plans,
            shieldWrites: shieldWrites,
            didPublishShieldCopy: didPublishShieldCopy,
            activities: activities,
            plan: monitorPlan,
            backstopDates: backstopDates(
                state: state,
                plan: monitorPlan,
                now: now,
                limit: options.maxBackstopDates
            ),
            nextStateDeadline: state.nextDeadline(after: now),
            warnings: warnings,
            failures: failures
        )

        // One line per pass at `notice`; the detail is in the report, which the
        // debug screen renders in full. The monitor logs under a 6 MB ceiling —
        // this is deliberately not a loop over every rule.
        reconcileLog.notice("""
            \(options.role.rawValue, privacy: .public)/\(options.trigger.rawValue, privacy: .public): \
            \(report.enforcingRuleIDs.count, privacy: .public) enforcing, \
            \(activities.started.count, privacy: .public) armed, \
            \(activities.stopped.count, privacy: .public) stopped, \
            persisted=\(didPersistState, privacy: .public), \
            failures=\(failures.count, privacy: .public)+\(activities.failures.count, privacy: .public)
            """)

        return report
    }

    // MARK: Activities

    /// Makes the daemon's activity list match the plan.
    ///
    /// **Every stop before any start.** docs/02-api-reference.md §7:
    /// `startMonitoring` overwrites whatever is registered under a name, and
    /// stopping first is what avoids stale duplicates and keeps the count under
    /// the 20-activity cap. Starting an activity whose name is about to be
    /// stopped would arm it and then throw it away.
    ///
    /// **One failure never aborts the pass.** `startMonitoring` throws per
    /// activity; each throw is caught, recorded, and the loop continues. The plan
    /// is ordered most-important-first exactly so that a throw partway through
    /// leaves the important ones armed (``MonitorPlan/entries``).
    ///
    /// - Parameter writes: `false` observes only — it reads the daemon's list and
    ///   diffs it, so ``ReconcileRole/dryRun`` produces a report the debug screen
    ///   can render, and arms nothing. ``ReconcileReport/ActivitySummary/stopped``
    ///   and ``ReconcileReport/ActivitySummary/started`` are empty in that case,
    ///   because nothing was: what *would* have happened is
    ///   ``ReconcileReport/plan``.
    private static func synchronizeActivities(
        plan: MonitorPlan,
        center: DeviceActivityCenter,
        armed: any ArmedActivityRecording,
        writes: Bool
    ) -> ReconcileReport.ActivitySummary {

        let armedBefore = center.activities.map(\.rawValue)
        let recorded = armed.armedFingerprints()
        // Explicitly the `Set<String>` overload, which returns the full ``Diff``
        // — the `Set<DeviceActivityName>` one drops `unchanged` and `foreign`,
        // and the debug screen needs both.
        let diff: MonitorPlan.Diff = plan.diff(
            against: Set(armedBefore),
            armedFingerprints: recorded
        )

        guard writes else {
            return ReconcileReport.ActivitySummary(
                armedBefore: armedBefore,
                unchanged: diff.unchanged,
                foreign: diff.foreign
            )
        }

        if !diff.toStop.isEmpty {
            center.stopMonitoring(diff.toStop.map { DeviceActivityName($0) })
        }

        var started: [String] = []
        var activityFailures: [ReconcileReport.ActivityFailure] = []
        var fingerprints: [String: String] = [:]

        // Everything already armed and already correct keeps its recorded
        // fingerprint; it was never touched.
        for name in diff.unchanged {
            fingerprints[name] = plan.entry(named: name)?.fingerprint ?? recorded[name]
        }

        for entry in diff.toStart {
            do {
                try center.startMonitoring(
                    entry.activityName,
                    during: entry.deviceActivitySchedule,
                    // v1 arms no threshold events: no v1 rule carries a usage
                    // budget, and `eventDidReachThreshold` is the least reliable
                    // surface in the API (docs/03-hard-constraints.md #35). The
                    // resolver is never called, so no tokens are decoded here.
                    events: entry.deviceActivityEvents { _ in ([], [], []) }
                )
                started.append(entry.name)
                // Recorded only after the call returned. A fingerprint written
                // before this point would claim an activity is armed with a
                // schedule it is not — the one genuinely unsafe state the cache
                // can be in.
                fingerprints[entry.name] = entry.fingerprint
            } catch {
                let failure = ReconcileReport.ActivityFailure(
                    name: entry.name,
                    kind: activityFailureKind(for: error),
                    message: String(describing: error)
                )
                // Recorded once, in the typed list. It is deliberately *not*
                // also appended to the flat ``ReconcileReport/failures``: two
                // copies of the same failure make "how many things went wrong"
                // unanswerable, and ``ReconcileReport/isClean`` already reads
                // both lists.
                activityFailures.append(failure)
                reconcileLog.error("""
                    startMonitoring failed for \(entry.name, privacy: .public): \
                    \(failure.kind.rawValue, privacy: .public)
                    """)
            }
        }

        armed.recordArmedFingerprints(fingerprints)

        return ReconcileReport.ActivitySummary(
            armedBefore: armedBefore,
            stopped: diff.toStop,
            started: started,
            unchanged: diff.unchanged,
            foreign: diff.foreign,
            failures: activityFailures
        )
    }

    /// Flattens `DeviceActivityCenter.MonitoringError` into a value the report
    /// can carry without naming an SDK type.
    private static func activityFailureKind(
        for error: any Error
    ) -> ReconcileReport.ActivityFailure.Kind {
        guard let monitoring = error as? DeviceActivityCenter.MonitoringError else {
            return .unknown
        }
        switch monitoring {
        case .excessiveActivities: return .excessiveActivities
        case .intervalTooLong: return .intervalTooLong
        case .intervalTooShort: return .intervalTooShort
        case .invalidDateComponents: return .invalidDateComponents
        case .unauthorized: return .unauthorized
        @unknown default: return .unknown
        }
    }

    // MARK: Orphan stores

    /// Empties and, where the API exists, deletes stores for rules that are gone.
    ///
    /// Two independent paths, because neither is sufficient alone:
    ///
    /// * **Exact.** A rule deleted by a release *this pass* is retired by id.
    ///   Works on every supported iOS and needs no enumeration.
    /// * **Opportunistic.** `ManagedSettingsStore.stores` is iOS 26.5 and up
    ///   (docs/02-api-reference.md §6), so above that the whole set can be swept
    ///   and anything Gate-named but unknown to state is reclaimed. This is what
    ///   catches a store stranded by a process that died mid-delete.
    ///
    /// Worth doing because the named-store cap is 50 and **fails silently**
    /// (docs/03-hard-constraints.md #34) — a store that shields nothing still
    /// counts against it. Idempotent: below 26.5 nothing is swept, and above it a
    /// deleted store leaves the set and is not seen again.
    private static func retireOrphanStores(
        writer: ShieldWriter,
        liveRuleIDs: Set<UUID>,
        released: [PendingChange]
    ) -> [ShieldWriteReport] {
        var retired: [ShieldWriteReport] = []
        var handled: Set<UUID> = []

        for change in released {
            guard case .deleteRule(let ruleID) = change.operation,
                  !liveRuleIDs.contains(ruleID),
                  handled.insert(ruleID).inserted
            else { continue }
            retired.append(writer.retire(rule: ruleID))
        }

        // `nil` below iOS 26.5 — there is no way to enumerate stores, and the
        // exact path above is the whole sweep.
        if let audit = TokenGuard.storeAudit() {
            for raw in audit.gateNames {
                let name = ManagedSettingsStore.Name(raw)
                guard let ruleID = ManagedSettingsStore.Name.ruleID(from: name),
                      !liveRuleIDs.contains(ruleID),
                      handled.insert(ruleID).inserted
                else { continue }
                retired.append(writer.retire(rule: ruleID))
            }
        }

        return retired
    }

    // MARK: The selection table

    /// Applies the ``Ratchet/SideEffects`` that live in `selections.plist`.
    ///
    /// **Order is load-bearing and comes from `Ratchet`:** adopt, then discard,
    /// then prune. ``SelectionTable/adopt(selectionID:asRule:at:)`` re-parents a
    /// blob away from the pending change that owned it, so discarding that
    /// change's records first would delete the very record about to be adopted —
    /// leaving a rule pointing at a ``SelectionRef`` with no blob behind it,
    /// which is a rule the reconciler then refuses to write.
    ///
    /// Staging is not performed and cannot be: it needs a `FamilyActivitySelection`
    /// the picker produced, and only the app has one. `Ratchet.releaseRipe` never
    /// stages, so reaching that case is reported as a warning rather than
    /// silently dropped.
    /// How recently a ``SelectionRecord`` must have been written to be exempt
    /// from the orphan sweep. See ``applySelectionEffects(_:state:now:failures:)``.
    static let selectionPruneGrace: TimeInterval = 60

    private static func applySelectionEffects(
        _ effects: Ratchet.SideEffects,
        state: GateState,
        now: Date,
        failures: inout [ReconcileFailure]
    ) {
        let liveRuleIDs = state.ruleIDs
        let liveChangeIDs = Set(state.openPendingChanges.map(\.id))

        let table: SelectionTable?
        do {
            table = try SelectionTableFile.read()
        } catch {
            // Left strictly alone. Rewriting it from a failed read would delete
            // every selection in the install, which is the one mistake here that
            // cannot be undone.
            failures.append(ReconcileFailure(
                stage: .selectionTable,
                subject: SelectionTable.fileName,
                message: String(describing: error)
            ))
            return
        }
        guard var working = table else { return }
        let before = working

        for adoption in effects.adoptSelections {
            working.adopt(
                selectionID: adoption.selectionID,
                asRule: adoption.ruleID,
                at: now
            )
        }
        for owner in effects.discardSelections {
            working.removeAll(ownedBy: owner)
        }

        // The orphan sweep, with one guard. `Ratchet.applying` hands the app a
        // `stageSelections` effect *before* the `PendingChange` that will own the
        // blob reaches `state.plist`; an app that reconciles between those two
        // writes would present this sweep with a record whose owner genuinely
        // does not exist yet, and the sweep would delete the user's freshly
        // picked selection. So a record written within ``selectionPruneGrace`` of
        // `now` is treated as still in flight and its owner is held live for this
        // pass. Reclaiming space can wait a minute; deleting a blob that is about
        // to be referenced cannot be undone.
        var liveRules = liveRuleIDs
        var liveChanges = liveChangeIDs
        for record in working.records
        where now.timeIntervalSince(record.updatedAt) < selectionPruneGrace {
            switch record.owner {
            case .rule(let id): liveRules.insert(id)
            case .pendingChange(let id): liveChanges.insert(id)
            case .unrecognized: break
            }
        }
        working.pruneOrphans(liveRuleIDs: liveRules, livePendingChangeIDs: liveChanges)

        // Idempotent: an unchanged table is not rewritten.
        guard working != before else { return }

        working.generation = state.generation
        working.updatedAt = now
        do {
            try SelectionTableFile.write(working)
        } catch {
            failures.append(ReconcileFailure(
                stage: .selectionTable,
                subject: SelectionTable.fileName,
                message: String(describing: error)
            ))
        }
    }

    // MARK: The shield copy index

    /// Rebuilds `shield.plist`'s token → rule index and its catch-all list.
    ///
    /// **Why on every reconcile.** `ShieldConfigurationDataSource` is handed an
    /// `Application`, never a rule; there is no API that answers "which of my
    /// rules is shielding this?", and the extension is latency-bounded, so it
    /// cannot decode a selection to find out (docs/03-hard-constraints.md #33).
    /// The map has to be pre-computed by the only process that holds decoded
    /// selections, and it has to be right at the moment the shield appears — which
    /// is any moment a rule's window opens, not only when the user edits
    /// something.
    ///
    /// Only the *index* is touched. The copy itself — titles, subtitles, colors,
    /// button labels — is authored by the app's UI layer, and a reconcile that
    /// invented copy would be a reconcile writing product decisions. If
    /// `shield.plist` does not exist yet there is nothing to update: a
    /// ``ShieldCopyTable`` cannot be built without a ``ShieldCopyTable/fallback``,
    /// and inventing one here is exactly the thing not to do.
    ///
    /// Returns whether anything was written. Idempotent: an unchanged index is
    /// not republished, so two identical passes touch the file once.
    private static func refreshShieldCopyIndex(
        plans: [ShieldPlan],
        resolvedByRule: [UUID: ResolvedTokens],
        state: GateState,
        now: Date,
        failures: inout [ReconcileFailure]
    ) -> Bool {
        let file: PlistFile<ShieldCopyTable>
        do {
            file = try ShieldCopyFile.file()
        } catch {
            failures.append(ReconcileFailure(
                stage: .shieldCopy,
                subject: ShieldCopyTable.fileName,
                message: String(describing: error)
            ))
            return false
        }
        guard file.exists else { return false }

        var table: ShieldCopyTable
        do {
            table = try file.read()
        } catch {
            failures.append(ReconcileFailure(
                stage: .shieldCopy,
                subject: ShieldCopyTable.fileName,
                message: String(describing: error)
            ))
            return false
        }
        let before = table

        var tokensByRuleID: [UUID: [EncodedToken]] = [:]
        var catchAll: [(ruleID: UUID, updatedAt: Date)] = []

        for plan in plans where plan.isEnforcing {
            guard let tokens = resolvedByRule[plan.ruleID] else { continue }

            // An allowlist rule shields by `.all(except:)`, so it shields tokens
            // that appear in no selection anywhere and cannot be indexed by
            // fingerprint at all. It goes in the catch-all list instead.
            if plan.mode == .allowlist {
                let updatedAt = state.rule(id: plan.ruleID)?.updatedAt ?? .distantPast
                catchAll.append((plan.ruleID, updatedAt))
                continue
            }

            var encoded: [EncodedToken] = []
            encoded.reserveCapacity(tokens.count)
            for token in tokens.applications {
                if let value = try? TokenGuard.encode(token) { encoded.append(value) }
            }
            for token in tokens.categories {
                if let value = try? TokenGuard.encode(token) { encoded.append(value) }
            }
            for token in tokens.webDomains {
                if let value = try? TokenGuard.encode(token) { encoded.append(value) }
            }
            tokensByRuleID[plan.ruleID] = encoded
        }

        table.rebuildIndex(tokensByRuleID: tokensByRuleID)
        // Most recently activated first: the extension takes the head, and when
        // two allowlist rules are in force at once the token genuinely belongs to
        // both, so the copy shown is approximate by nature. Ordered by id on a
        // tie so the file is byte-identical in every process.
        table.catchAllRuleIDs = catchAll
            .sorted {
                $0.updatedAt == $1.updatedAt
                    ? $0.ruleID.uuidString < $1.ruleID.uuidString
                    : $0.updatedAt > $1.updatedAt
            }
            .map(\.ruleID)

        guard table.ruleIDsByTokenFingerprint != before.ruleIDsByTokenFingerprint
            || table.catchAllRuleIDs != before.catchAllRuleIDs
        else { return false }

        table.generation = state.generation
        table.updatedAt = now
        do {
            try ShieldCopyFile.publish(table)
            return true
        } catch {
            failures.append(ReconcileFailure(
                stage: .shieldCopy,
                subject: ShieldCopyTable.fileName,
                message: String(describing: error)
            ))
            return false
        }
    }
}

#endif
