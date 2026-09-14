//
//  MonitorPlan.swift
//  GateKernel
//
//  The intended set of monitored activities, derived from ``GateState`` — and the
//  place the 20-activity budget is enforced.
//
//  Build plan: docs/06-build-plan.md step 3.10 (the plan half; the I/O half is
//  `Kernel/Engine/Reconciler.swift`). Budget table: docs/05-architecture.md,
//  "Activity budget (hard cap 20, app + all extensions combined)".
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY A PLAN AND NOT JUST A LOOP OF `startMonitoring` CALLS
//
//  The 20-activity cap is counted across the app **and every one of its
//  extensions together**, and unlike the other three platform caps it is loud:
//  `startMonitoring` throws `MonitoringError.excessiveActivities`
//  (docs/02-api-reference.md §14). Loud is not the same as safe. It throws at
//  whatever arbitrary moment the twenty-first activity is armed, which in practice
//  is halfway through applying a block — leaving some rules armed, some not, and
//  the user with a rule they believe is enforced and is not. docs/05-architecture.md
//  states the remedy plainly: *"The `Reconciler` enforces this and evicts the
//  furthest-out timer if the budget is exceeded, rather than letting
//  `startMonitoring` throw `.excessiveActivities` at an arbitrary moment."*
//
//  Deciding *what* to arm is therefore separated from *arming* it. This file is a
//  pure function of `(GateState, now, Calendar)` — no `DeviceActivityCenter`, no
//  `ManagedSettingsStore`, no file I/O, nothing that can fail halfway. Everything
//  it decides, including every eviction, is a value the caller can log, unit-test
//  without a device (docs/03-hard-constraints.md #11 — there is no Simulator
//  support, ever), and render on the debug screen (docs/04-product-spec.md V1-11).
//
//  The budget, from docs/05-architecture.md:
//
//      Repeating rule windows   <= 8   (one per rule, NEVER one per weekday)
//      Live grant expiries      <= 6
//      Auto-revert timers       <= 4
//      Headroom                    2
//                               ----
//      Hard cap                   20
//
//  The headroom is deliberately unspent. It absorbs an activity armed by a future
//  widget or App Intent target (docs/04-product-spec.md V2-7 — an `AppIntent` must
//  be a member of both the app and widget targets), and it absorbs the window
//  between `stopMonitoring` and `startMonitoring` if the daemon is slow to release
//  a name.
//
//  ALL EVICTION IS SAFE, AND THAT IS NOT AN ACCIDENT. An activity is an
//  *accelerator*, never the enforcement itself. Enforcement is the
//  `ManagedSettingsStore` contents, which survive force-quit, reboot and app
//  deletion; the monitor is best-effort and has been reported as never launching
//  at all (docs/03-hard-constraints.md #32); and every deadline is an absolute
//  timestamp in `state.plist` that the foreground reconcile and the
//  `UNCalendarNotificationTrigger` backstops recompute independently
//  (docs/04-product-spec.md V1-10, docs/05-architecture.md enforcement layering).
//  An evicted timer costs latency. A thrown `.excessiveActivities` costs a block.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  RULES FOR THIS FILE
//  1. **No I/O and no SDK calls.** `DeviceActivityCenter` is constructed and
//     called only by `Kernel/Engine/Reconciler.swift`. This file never reads the
//     daemon's state; it is handed it.
//  2. **Deterministic.** Same inputs, same plan, same order, every time, in every
//     process. Ordering ties break on the encoded name, never on a `Set`'s
//     iteration order or on `hashValue` (which is per-process seeded — see
//     ``GateFingerprint``).
//  3. **Never trap.** Runs in the monitor, cold, under a 6 MB ceiling
//     (docs/03-hard-constraints.md #31), against a `state.plist` that another
//     process may have been killed while writing.
//

import Foundation

#if os(iOS)
import DeviceActivity
#endif

#if os(iOS)
import ManagedSettings
#endif

// MARK: - ActivityPriority

/// What an activity is for, and how readily Gate gives up its slot.
///
/// Ordered by importance, most important first. The ordering is a product
/// judgement, not an arbitrary one:
///
/// - A **rule window** is scheduled enforcement. Losing it means a rule's block
///   starts or ends only on the next foreground.
/// - A **grant expiry** re-*tightens*: it is the callback that puts the shield
///   back after a time-boxed unblock (docs/04-product-spec.md V1-7 step 3).
///   Losing it means an app stays unblocked longer than the user agreed to, which
///   is the failure direction this product cannot have.
/// - A **revert timer** applies a queued *loosening* whose Lock has expired.
///   Losing it means the user waits longer than they were promised — visible,
///   explicable, and corrected by the very next foreground (V1-10).
///
/// So when something has to go, a revert timer goes before a grant expiry, and a
/// timer goes before a window.
public enum ActivityPriority: Int, Sendable, Hashable, Comparable, CaseIterable {

    case ruleWindow = 0
    case grantExpiry = 1
    case revertTimer = 2

    public static func < (lhs: ActivityPriority, rhs: ActivityPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The per-kind slice of the budget (docs/05-architecture.md, activity budget).
    public var cap: Int {
        switch self {
        case .ruleWindow: GateLimits.maxRepeatingActivities
        case .grantExpiry: GateLimits.maxGrantActivities
        case .revertTimer: GateLimits.maxRevertActivities
        }
    }

    /// The name shape this priority is always encoded with.
    public var activityKind: GateActivityKind {
        switch self {
        case .ruleWindow: .rule
        case .grantExpiry: .grant
        case .revertTimer: .revert
        }
    }

    /// Whether entries of this priority are one-shot timers with a deadline.
    public var isTimer: Bool { self != .ruleWindow }
}

// MARK: - PlannedActivity

/// One `(DeviceActivityName, schedule, events)` triple Gate intends to have armed.
///
/// Stores the SDK-free ``ScheduleSpec`` rather than a `DeviceActivitySchedule`:
/// that keeps the type `Sendable` and `Hashable` (the SDK type is neither,
/// audited), keeps the whole plan testable on Linux, and gives
/// ``PlannedActivity/fingerprint`` something stable to digest. The SDK values are
/// produced on demand in the island at the bottom of this file.
public struct PlannedActivity: Sendable, Equatable, Hashable, Identifiable {

    /// The decoded identity. `ActivityNameCodec` turns it into the string the
    /// daemon hands back — the monitor's only payload (docs/02-api-reference.md §8).
    public let activity: GateActivity

    public let spec: ScheduleSpec

    /// Threshold events to arm inside this activity.
    ///
    /// Always empty in v1: no v1 ``Rule`` carries a usage budget, and
    /// `eventDidReachThreshold` is the least reliable surface in the API
    /// (docs/03-hard-constraints.md #35). Daily budgets are V2-4, and they put a
    /// staircase of events inside **one** activity precisely because events are
    /// cheap and activities are capped at 20.
    public let events: [EventSpec]

    public let priority: ActivityPriority

    /// The instant this activity exists to catch, for a one-shot timer:
    /// ``Grant/expiresAt`` or ``PendingChange/earliestApplyAt``. `nil` for a
    /// repeating window, which has no single deadline.
    ///
    /// This is the value the budget sorts on when it has to evict the furthest-out
    /// timer.
    public let deadline: Date?

    /// The concrete occurrence, as absolute instants: for a one-shot, the
    /// range-checked interval the schedule resolves to; for a repeating window, the
    /// occurrence that is open now or opens next.
    ///
    /// Advisory. `intervalDidStart` / `intervalDidEnd` fire only when the device is
    /// in use, never at the wall-clock boundary (docs/03-hard-constraints.md #27),
    /// so this is what the UI counts down to and what the notification backstops
    /// are armed for — never a promise about when a callback arrives.
    public let occurrence: DateInterval?

    public init(
        activity: GateActivity,
        spec: ScheduleSpec,
        events: [EventSpec] = [],
        priority: ActivityPriority,
        deadline: Date? = nil,
        occurrence: DateInterval? = nil
    ) {
        self.activity = activity
        self.spec = spec
        self.events = events
        self.priority = priority
        self.deadline = deadline
        self.occurrence = occurrence
    }

    /// The encoded `DeviceActivityName` string.
    public var name: String { activity.rawName }

    public var id: String { name }

    /// Everything that would make an already-armed activity wrong.
    ///
    /// `startMonitoring` **overwrites** whatever is registered under a name
    /// (docs/02-api-reference.md §7), and `gate.rule:<uuid>` does not encode the
    /// window — so "this name is already in `center.activities`" does **not** mean
    /// "it is armed with the schedule we want". A user who edits a rule's window
    /// from 22:00 to 21:00 changes nothing the daemon can see from the name alone.
    /// ``MonitorPlan/diff(against:armedFingerprints:)`` compares this digest
    /// against the one recorded when the activity was armed and restarts only what
    /// genuinely changed.
    ///
    /// Deliberately excludes ``occurrence``: that moves with the clock, and
    /// restarting eight activities on every foreground because "now" advanced is
    /// churn against a daemon Gate does not control.
    public var fingerprint: String {
        GateFingerprint.combine([name, spec.fingerprint] + events.map(\.fingerprint))
    }
}

// MARK: - MonitorPlan

/// The complete set of activities Gate intends to have armed at one instant, and
/// the record of everything it had to give up to fit inside the cap.
public struct MonitorPlan: Sendable, Equatable {

    /// What Gate wants armed, in the order it should be armed: by
    /// ``ActivityPriority``, then most-urgent-first inside each priority.
    ///
    /// The order matters. `startMonitoring` can throw, and if it does, everything
    /// before the throw is armed and everything after is not. Arming the most
    /// important first makes a partial failure degrade in the right direction.
    public let entries: [PlannedActivity]

    /// What did not fit, and why. Never silently dropped: the debug screen renders
    /// this (docs/04-product-spec.md V1-11) and it is the first thing to look at
    /// when a timer did not fire.
    public let evictions: [Eviction]

    /// Everything the plan noticed and could not act on.
    public let diagnostics: [Diagnostic]

    /// The instant this plan was computed for. Plans are snapshots; a plan is
    /// never cached across a reconcile.
    public let generatedAt: Date

    public init(
        entries: [PlannedActivity],
        evictions: [Eviction] = [],
        diagnostics: [Diagnostic] = [],
        generatedAt: Date
    ) {
        self.entries = entries
        self.evictions = evictions
        self.diagnostics = diagnostics
        self.generatedAt = generatedAt
    }

    // MARK: Budget

    /// How many activities a plan may contain.
    ///
    /// ``GateLimits/maxConcurrentActivities`` minus ``GateLimits/activityHeadroom``
    /// — 20 − 2 = 18, which is also exactly the sum of the three per-kind caps, so
    /// the two limits agree by construction rather than by coincidence.
    ///
    /// A headroom of zero or less is a programming error
    /// (`Kernel/Identifiers.swift` says so in as many words). It cannot be fixed
    /// here — the constants live in another file — so the plan falls back to the
    /// platform's own hard cap and reports
    /// ``MonitorPlan/Diagnostic/budgetMisconfigured(headroom:)``. Refusing to plan
    /// at all would mean refusing to enforce, which is never the right answer.
    public static var budget: Int {
        let headroom = GateLimits.activityHeadroom
        guard headroom > 0 else { return GateLimits.maxConcurrentActivities }
        return GateLimits.maxConcurrentActivities - headroom
    }

    // MARK: Derived views

    /// Encoded names of everything in the plan.
    public var names: Set<String> { Set(entries.map(\.name)) }

    /// Name → fingerprint, for the caller to persist after a successful arm and
    /// hand back to ``diff(against:armedFingerprints:)`` next time.
    public var fingerprints: [String: String] {
        Dictionary(entries.map { ($0.name, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
    }

    public func entry(named name: String) -> PlannedActivity? {
        entries.first { $0.name == name }
    }

    public func entries(for priority: ActivityPriority) -> [PlannedActivity] {
        entries.filter { $0.priority == priority }
    }

    /// The soonest one-shot deadline in the plan. Pairs with
    /// ``GateState/nextDeadline(after:)``, which covers the same deadlines from the
    /// state side; if these two disagree, a timer was evicted.
    public func nextDeadline(after now: Date) -> Date? {
        entries.compactMap(\.deadline).filter { $0 > now }.min()
    }

    // MARK: - Eviction

    /// One activity the budget could not accommodate.
    public struct Eviction: Sendable, Equatable, Hashable {

        public let name: String
        public let priority: ActivityPriority

        /// The deadline that will now be caught by the foreground reconcile or a
        /// notification backstop instead of by a monitor callback.
        public let deadline: Date?

        public let reason: Reason

        public enum Reason: String, Sendable, Hashable, CaseIterable {
            /// Over this kind's slice of the budget — more than 8 windows, 6 grant
            /// timers or 4 revert timers (docs/05-architecture.md, activity budget).
            case kindCapExceeded
            /// Inside every per-kind cap but over ``MonitorPlan/budget`` in total.
            /// Unreachable while the three caps sum to the budget; kept because the
            /// constants can change and `.excessiveActivities` must not be how we
            /// find out.
            case globalBudgetExceeded
        }

        public init(name: String, priority: ActivityPriority, deadline: Date?, reason: Reason) {
            self.name = name
            self.priority = priority
            self.deadline = deadline
            self.reason = reason
        }

        init(evicting entry: PlannedActivity, reason: Reason) {
            self.init(
                name: entry.name,
                priority: entry.priority,
                deadline: entry.deadline,
                reason: reason
            )
        }
    }

    // MARK: - Diagnostic

    /// Something the plan noticed. Not errors — the plan always succeeds — but the
    /// explanations the debug screen needs for "why is this rule not in
    /// `DeviceActivityCenter().activities`?", which is the single most common
    /// question this stack produces.
    public enum Diagnostic: Sendable, Equatable, Hashable {

        /// An enabled rule with no schedule. In force whenever it is enabled, so it
        /// has no boundaries, so it spends no activity. This is a feature: it is
        /// how a rule with no window stays free.
        case ruleAlwaysInForce(ruleID: UUID)

        /// The rule's stored window cannot be registered with
        /// `DeviceActivityCenter` — shorter than 15 minutes, longer than a week,
        /// zero-length, or with an empty weekday mask (docs/02-api-reference.md §14).
        /// ``Rule/shouldEnforce(at:in:)`` reads such a schedule as "always in
        /// force", so the rule is still enforced; only the boundary callbacks are
        /// lost.
        case windowUnregistrable(ruleID: UUID, issues: [RuleIssue])

        /// The stored `warningTime` did not fit inside the window, so it was
        /// dropped and the window was armed without it. Costs
        /// `intervalWillStartWarning` / `intervalWillEndWarning`, nothing else.
        case warningTimeDropped(ruleID: UUID)

        /// A one-shot timer could not be expressed as a legal
        /// `DeviceActivitySchedule`. With ``ScheduleBuilder/OneShotOutcome/Reason/deadlineTooFarOut``
        /// this is routine and self-healing: a seven-day Lock delay is exactly
        /// ``GateLimits/maxLockDelay``, so its revert timer is armed once the
        /// deadline comes inside the one-week ceiling.
        case timerUnschedulable(
            name: String,
            deadline: Date,
            reason: ScheduleBuilder.OneShotOutcome.Reason
        )

        /// An active grant whose rule is gone. No store to write and no shield to
        /// restore, so no timer. `GateState.migrate` normally reaps these.
        case grantWithoutRule(grantID: UUID, ruleID: UUID)

        /// A pending change written by a newer build
        /// (``PendingChange/Operation/unrecognized(type:)``). It is displayed and
        /// can be cancelled, but never applied — so arming a timer to apply it
        /// would be arming a timer for something Gate must not do.
        case pendingChangeNotApplicable(changeID: UUID)

        /// Two entries claimed the same encoded name. Impossible from well-formed
        /// state — the payload is a UUID — so it means duplicate record ids in
        /// `state.plist`. The first occurrence wins.
        case duplicateActivityName(String)

        /// ``GateLimits/activityHeadroom`` is zero or negative: the three per-kind
        /// caps have grown to consume the whole 20-activity cap.
        case budgetMisconfigured(headroom: Int)
    }
}

// MARK: - Building the plan

public extension MonitorPlan {

    /// Derives the intended activity set from state.
    ///
    /// Pure: no `Date()`, no `Calendar.current` read behind the caller's back, no
    /// daemon access. The same `(state, now, calendar)` always yields the same plan
    /// in the same order, in the app and in the monitor alike.
    ///
    /// - Parameters:
    ///   - state: the decoded `state.plist`. Read-only.
    ///   - now: the instant to plan for.
    ///   - calendar: injected so the DST and time-zone cases are testable
    ///     (docs/06-build-plan.md step 3.11).
    static func make(
        from state: GateState,
        now: Date,
        calendar: Calendar = .current
    ) -> MonitorPlan {
        var diagnostics: [Diagnostic] = []

        let windows = planWindows(state: state, now: now, calendar: calendar, into: &diagnostics)
        let grants = planGrantExpiries(state: state, now: now, calendar: calendar, into: &diagnostics)
        let reverts = planReverts(state: state, now: now, calendar: calendar, into: &diagnostics)

        // Plan order is priority order, and inside each priority the most urgent
        // first. Everything downstream — the per-kind trim, the budget trim, and
        // the order `startMonitoring` is called in — depends on it.
        let (unique, duplicates) = deduplicated(windows + grants + reverts)
        diagnostics.append(contentsOf: duplicates.map { Diagnostic.duplicateActivityName($0) })

        var evictions: [Eviction] = []
        let withinKindCaps = trimToKindCaps(unique, into: &evictions)

        if GateLimits.activityHeadroom <= 0 {
            diagnostics.append(.budgetMisconfigured(headroom: GateLimits.activityHeadroom))
        }
        let kept = trimToBudget(withinKindCaps, budget: MonitorPlan.budget, into: &evictions)

        return MonitorPlan(
            entries: kept,
            evictions: evictions,
            diagnostics: diagnostics,
            generatedAt: now
        )
    }

    // MARK: Repeating rule windows (V1-5)

    /// One activity per rule — **never one per weekday**.
    ///
    /// A rule scoped to `[.monday, .wednesday]` still gets exactly one
    /// `DeviceActivityName`; the weekday test happens inside `intervalDidStart` via
    /// ``Rule/shouldEnforce(at:in:)``, which no-ops on an uncovered day. One name
    /// per rule-per-weekday would blow the 20-activity cap at rule #3
    /// (docs/04-product-spec.md V1-5).
    private static func planWindows(
        state: GateState,
        now: Date,
        calendar: Calendar,
        into diagnostics: inout [Diagnostic]
    ) -> [PlannedActivity] {
        var planned: [PlannedActivity] = []

        // The user's own order decides which windows survive a cap. Ties break on
        // creation date and then on id, so the plan is identical in every process.
        let ordered = state.rules.sorted {
            ($0.sortIndex, $0.createdAt, $0.id.uuidString)
                < ($1.sortIndex, $1.createdAt, $1.id.uuidString)
        }

        for rule in ordered {
            guard rule.isEnabled else { continue }

            guard let schedule = rule.schedule else {
                // No window means no boundaries, so no activity and no slot spent.
                diagnostics.append(.ruleAlwaysInForce(ruleID: rule.id))
                continue
            }

            switch ScheduleBuilder.repeatingSpec(for: schedule) {
            case .unregistrable(let issues):
                diagnostics.append(.windowUnregistrable(ruleID: rule.id, issues: issues))

            case .scheduled(let spec, let droppedWarning):
                if droppedWarning {
                    diagnostics.append(.warningTimeDropped(ruleID: rule.id))
                }
                planned.append(
                    PlannedActivity(
                        activity: .rule(ruleID: rule.id),
                        spec: spec,
                        priority: .ruleWindow,
                        deadline: nil,
                        occurrence: ScheduleBuilder.nextWindow(
                            of: schedule, after: now, in: calendar
                        )
                    )
                )
            }
        }

        return planned
    }

    // MARK: Grant expiries (V1-7)

    private static func planGrantExpiries(
        state: GateState,
        now: Date,
        calendar: Calendar,
        into diagnostics: inout [Diagnostic]
    ) -> [PlannedActivity] {
        var planned: [PlannedActivity] = []
        let liveRuleIDs = state.ruleIDs

        // Soonest expiry first: the most urgent timer is the last one the budget
        // will take away.
        let ordered = state.grants
            .active(at: now)
            .sorted { ($0.expiresAt, $0.id.uuidString) < ($1.expiresAt, $1.id.uuidString) }

        for grant in ordered {
            guard liveRuleIDs.contains(grant.ruleID) else {
                diagnostics.append(.grantWithoutRule(grantID: grant.id, ruleID: grant.ruleID))
                continue
            }

            let activity = GateActivity.grant(ruleID: grant.ruleID, grantID: grant.id)
            switch ScheduleBuilder.oneShotSpec(deadline: grant.expiresAt, now: now, calendar: calendar) {
            case .unschedulable(let reason):
                diagnostics.append(
                    .timerUnschedulable(
                        name: activity.rawName, deadline: grant.expiresAt, reason: reason
                    )
                )

            case .scheduled(let spec, let interval):
                planned.append(
                    PlannedActivity(
                        activity: activity,
                        spec: spec,
                        priority: .grantExpiry,
                        deadline: grant.expiresAt,
                        occurrence: interval
                    )
                )
            }
        }

        return planned
    }

    // MARK: Auto-revert timers (V1-3, V1-4)

    private static func planReverts(
        state: GateState,
        now: Date,
        calendar: Calendar,
        into diagnostics: inout [Diagnostic]
    ) -> [PlannedActivity] {
        var planned: [PlannedActivity] = []

        let ordered = state.pendingChanges.pending
            .sorted {
                ($0.earliestApplyAt ?? .distantFuture, $0.id.uuidString)
                    < ($1.earliestApplyAt ?? .distantFuture, $1.id.uuidString)
            }

        for change in ordered {
            guard change.isApplicable else {
                diagnostics.append(.pendingChangeNotApplicable(changeID: change.id))
                continue
            }

            // A password-only Lock has no `earliestApplyAt` — there is no deadline
            // to count down to, only a passphrase to verify
            // (docs/04-product-spec.md V1-3), so there is nothing to arm.
            guard let deadline = change.earliestApplyAt else { continue }

            // Already ripe: the reconcile that produced this plan applies it on this
            // very pass. Arming a timer for a moment in the past would spend a slot
            // to be told something Gate already knows.
            guard deadline > now else { continue }

            let activity = GateActivity.revert(ruleID: change.ruleID, changeID: change.id)
            switch ScheduleBuilder.oneShotSpec(deadline: deadline, now: now, calendar: calendar) {
            case .unschedulable(let reason):
                diagnostics.append(
                    .timerUnschedulable(name: activity.rawName, deadline: deadline, reason: reason)
                )

            case .scheduled(let spec, let interval):
                planned.append(
                    PlannedActivity(
                        activity: activity,
                        spec: spec,
                        priority: .revertTimer,
                        deadline: deadline,
                        occurrence: interval
                    )
                )
            }
        }

        return planned
    }

    // MARK: Budget enforcement

    /// Drops entries that would register the same `DeviceActivityName` twice.
    ///
    /// `startMonitoring` overwrites silently, so a duplicate would not throw — it
    /// would quietly replace the first entry's schedule with the second's, and the
    /// plan and the daemon would disagree about what is armed. First occurrence
    /// wins, which given the plan's ordering is the more urgent one.
    private static func deduplicated(
        _ entries: [PlannedActivity]
    ) -> (unique: [PlannedActivity], duplicates: [String]) {
        var seen: Set<String> = []
        var unique: [PlannedActivity] = []
        var duplicates: [String] = []
        unique.reserveCapacity(entries.count)

        for entry in entries {
            if seen.insert(entry.name).inserted {
                unique.append(entry)
            } else {
                duplicates.append(entry.name)
            }
        }
        return (unique, duplicates)
    }

    /// Applies the per-kind slices of the budget: 8 windows, 6 grant timers, 4
    /// revert timers.
    ///
    /// Each group arrives most-urgent-first, so keeping the prefix keeps the most
    /// urgent — which for timers is the soonest deadline and for windows is the
    /// user's own ordering on the home screen.
    private static func trimToKindCaps(
        _ entries: [PlannedActivity],
        into evictions: inout [Eviction]
    ) -> [PlannedActivity] {
        var kept: [PlannedActivity] = []
        kept.reserveCapacity(entries.count)

        for priority in ActivityPriority.allCases {
            let group = entries.filter { $0.priority == priority }
            let cap = max(0, priority.cap)
            kept.append(contentsOf: group.prefix(cap))
            evictions.append(contentsOf: group.dropFirst(cap).map {
                Eviction(evicting: $0, reason: .kindCapExceeded)
            })
        }
        return kept
    }

    /// Applies the global budget, **evicting the furthest-out timer first**.
    ///
    /// The policy is docs/05-architecture.md's, verbatim, and it is temporal rather
    /// than categorical: among timers, the one whose deadline is furthest away goes
    /// first, whichever kind it is. A timer far in the future is the one with the
    /// most chances to be re-armed by a later reconcile before it is needed, and
    /// the one whose deadline the foreground path is most likely to reach first
    /// anyway.
    ///
    /// Repeating windows are only evicted once every timer is gone, and then in
    /// reverse plan order — the rules the user sorted to the bottom.
    ///
    /// Unreachable today: the three per-kind caps sum to exactly ``budget``, so a
    /// set that survived ``trimToKindCaps(_:into:)`` already fits. It exists so
    /// that changing one of those constants cannot turn into a thrown
    /// `.excessiveActivities` in front of a user.
    private static func trimToBudget(
        _ entries: [PlannedActivity],
        budget: Int,
        into evictions: inout [Eviction]
    ) -> [PlannedActivity] {
        let ceiling = max(0, budget)
        guard entries.count > ceiling else { return entries }

        let overflow = entries.count - ceiling

        // Most-evictable first. The comparator is a total order — every branch ends
        // in a tie-break on position or name — so `sorted` is deterministic.
        let ranked = entries.indices.sorted { left, right in
            let lhs = entries[left]
            let rhs = entries[right]

            if lhs.priority.isTimer != rhs.priority.isTimer {
                return lhs.priority.isTimer  // timers before windows
            }

            if lhs.priority.isTimer {
                let lhsDeadline = lhs.deadline ?? .distantFuture
                let rhsDeadline = rhs.deadline ?? .distantFuture
                if lhsDeadline != rhsDeadline { return lhsDeadline > rhsDeadline }
                return lhs.name > rhs.name
            }

            return left > right  // windows: reverse plan order
        }

        let doomed = Set(ranked.prefix(overflow))
        for index in ranked.prefix(overflow) {
            evictions.append(Eviction(evicting: entries[index], reason: .globalBudgetExceeded))
        }

        return entries.indices.filter { !doomed.contains($0) }.map { entries[$0] }
    }
}

// MARK: - Diffing against what is actually armed

public extension MonitorPlan {

    /// What `Kernel/Engine/Reconciler.swift` has to do to make the daemon match
    /// the plan (docs/04-product-spec.md V1-10 step 4).
    struct Diff: Sendable, Equatable {

        /// Names to pass to `DeviceActivityCenter.stopMonitoring(_:)` — orphans Gate
        /// no longer wants, plus activities that are armed with the wrong schedule
        /// and must be re-armed. Stop **everything** in this list before starting
        /// anything: §7 of docs/02-api-reference.md says `startMonitoring`
        /// overwrites and to stop first "to avoid stale duplicates and stay under
        /// the 20-activity cap".
        public var toStop: [String]

        /// Activities to arm, in plan order — most important first, so a throw
        /// part-way through leaves the important ones armed.
        public var toStart: [PlannedActivity]

        /// Already armed, already correct. Left strictly alone: re-arming a
        /// currently-open window would reset its interval and cost a callback for
        /// nothing.
        public var unchanged: [String]

        /// Armed activities outside ``GateID/namespace``. Listed so the debug screen
        /// can show them; **never** stopped. `DeviceActivityCenter` is scoped to
        /// this app and its extensions, so these belong to another Gate target —
        /// a future widget or App Intent (docs/04-product-spec.md V2-7) — and
        /// stopping one would break a feature this code has never heard of.
        public var foreign: [String]

        public init(
            toStop: [String] = [],
            toStart: [PlannedActivity] = [],
            unchanged: [String] = [],
            foreign: [String] = []
        ) {
            self.toStop = toStop
            self.toStart = toStart
            self.unchanged = unchanged
            self.foreign = foreign
        }

        /// Nothing to do. The steady state on a foreground reconcile where nothing
        /// changed, and the cheapest possible outcome — no daemon round trip at all.
        public var isEmpty: Bool { toStop.isEmpty && toStart.isEmpty }
    }

    /// Diffs the plan against the names currently registered with the daemon.
    ///
    /// - Parameters:
    ///   - current: `DeviceActivityCenter().activities`, as raw strings.
    ///   - armedFingerprints: ``PlannedActivity/fingerprint`` values recorded the
    ///     last time each name was armed, as returned by ``fingerprints``.
    ///
    ///     This map is what distinguishes "already armed" from "already armed
    ///     *correctly*". A `DeviceActivityName` for a rule is `gate.rule:<uuid>`
    ///     and does not encode the window, so editing a rule's schedule changes
    ///     nothing the daemon shows. Without a recorded fingerprint there is no
    ///     cheap way to tell — `DeviceActivityCenter.schedule(for:)` returns a
    ///     `DeviceActivitySchedule` with no audited `Equatable` conformance — so
    ///     the **empty map means restart everything**, which is correct, just
    ///     chattier. Passing a stale map is the only genuinely unsafe option, and
    ///     the caller avoids it by writing the map only after `startMonitoring`
    ///     returns without throwing.
    func diff(
        against current: Set<String>,
        armedFingerprints: [String: String] = [:]
    ) -> Diff {
        var diff = Diff()
        var planned: Set<String> = []
        planned.reserveCapacity(entries.count)

        for entry in entries {
            planned.insert(entry.name)

            guard current.contains(entry.name) else {
                diff.toStart.append(entry)
                continue
            }

            if armedFingerprints[entry.name] == entry.fingerprint {
                diff.unchanged.append(entry.name)
            } else {
                diff.toStop.append(entry.name)
                diff.toStart.append(entry)
            }
        }

        // Sorted so the orphan list is deterministic across processes; `Set`
        // iteration order is not.
        for name in current.sorted() where !planned.contains(name) {
            if ActivityNameCodec.isGateName(name) {
                diff.toStop.append(name)
            } else {
                diff.foreign.append(name)
            }
        }

        return diff
    }
}

// MARK: - DeviceActivity island

// The SDK types, fenced so everything above compiles in the platform-agnostic
// SwiftPM test package (docs/05-architecture.md, module layer split), exactly as
// `Kernel/Model/LockPolicy.swift` fences CryptoKit. The 20-activity eviction tests
// (docs/06-build-plan.md step 3.11) run against the pure layer.
//
// All computed, none stored: `DeviceActivityName` and `DeviceActivitySchedule`
// have no audited `Sendable` conformance, so storing one inside a `Sendable` type
// is a Swift 6 strict-concurrency error — the same reasoning that makes
// `ManagedSettingsStore.Name.solid` computed in `Kernel/Identifiers.swift`.

#if os(iOS)

public extension PlannedActivity {

    /// The name to pass to `startMonitoring`.
    var activityName: DeviceActivityName { activity.activityName }

    /// The schedule to pass to `startMonitoring`.
    var deviceActivitySchedule: DeviceActivitySchedule { spec.deviceActivitySchedule }
}

#endif

#if os(iOS)

public extension PlannedActivity {

    /// The `events:` dictionary to pass to `startMonitoring`.
    ///
    /// The kernel stores tokens as ``EncodedToken`` and never as
    /// `ManagedSettings.Token` (`Kernel/Model/Rule.swift` explains why: the model
    /// layer must not name an SDK type), so the caller supplies the conversion —
    /// `Kernel/Enforcement/TokenGuard.swift`, which owns that boundary and also
    /// enforces the silent 50-token cap (docs/03-hard-constraints.md #34).
    ///
    /// In v1 this returns `[:]` without ever calling `resolve`, because no v1
    /// ``Rule`` carries a usage budget and ``PlannedActivity/events`` is always
    /// empty (docs/04-product-spec.md V1-2, V2-4).
    ///
    /// An ``EventSpec`` whose tokens all resolve empty is skipped rather than armed
    /// — see ``ScheduleBuilder/makeEvent(_:applications:categories:webDomains:)``.
    func deviceActivityEvents(
        resolvingTokensFor resolve: (EventSpec) -> (
            applications: Set<ApplicationToken>,
            categories: Set<ActivityCategoryToken>,
            webDomains: Set<WebDomainToken>
        )
    ) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var built: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        built.reserveCapacity(events.count)

        for spec in events {
            let tokens = resolve(spec)
            guard let made = ScheduleBuilder.makeEvent(
                spec,
                applications: tokens.applications,
                categories: tokens.categories,
                webDomains: tokens.webDomains
            ) else { continue }
            built[spec.key.eventName] = made.event
        }
        return built
    }
}

#endif

#if os(iOS)

public extension MonitorPlan {

    /// ``diff(against:armedFingerprints:)`` for the value
    /// `DeviceActivityCenter.activities` actually returns.
    ///
    /// Returns the pair the reconciler consumes directly. Stop every name in
    /// `toStop` first, then start `toStart` in order — that sequencing is required
    /// by docs/02-api-reference.md §7, not a preference.
    func diff(
        against current: [DeviceActivityName],
        armedFingerprints: [String: String] = [:]
    ) -> (toStop: [DeviceActivityName], toStart: [PlannedActivity]) {
        diff(against: Set(current), armedFingerprints: armedFingerprints)
    }

    /// Set-typed overload, for a caller that has already de-duplicated
    /// `center.activities`.
    func diff(
        against current: Set<DeviceActivityName>,
        armedFingerprints: [String: String] = [:]
    ) -> (toStop: [DeviceActivityName], toStart: [PlannedActivity]) {
        let raw: Diff = diff(
            against: Set(current.map(\.rawValue)),
            armedFingerprints: armedFingerprints
        )
        return (raw.toStop.map { DeviceActivityName($0) }, raw.toStart)
    }
}

#endif
