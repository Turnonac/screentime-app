//
//  ScheduleBuilder.swift
//  GateKernel
//
//  Turns ``Rule``s and absolute deadlines into the `DeviceActivitySchedule` and
//  `DeviceActivityEvent` values `DeviceActivityCenter.startMonitoring` accepts,
//  and owns every piece of calendar arithmetic in the kernel.
//
//  Build plan: docs/06-build-plan.md step 3.6. The 20-activity budget and its
//  eviction policy live one layer up, in `Kernel/Enforcement/MonitorPlan.swift`.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE COMPONENT-SET RULE (docs/02-api-reference.md §7) — the reason this file is
//  not three inline initializers.
//
//  The dossier's sources contradict each other on `DateComponents` granularity.
//  Thread 729841 reports only `[.hour, .minute, .second]` on *both* ends delivers
//  both callbacks; Foqos ships full `[.year … .second]` on both ends in
//  production and depends on `intervalDidEnd`. Thread 726331 shows what happens
//  when the two ends carry **different** component sets: the previous start
//  resolves *after* the previous end, the schedule reads as continuously active
//  for days, and every threshold breaches instantly.
//
//  The invariant both sides agree on, verbatim: *"never mismatch the component set
//  between `intervalStart` and `intervalEnd`."* That invariant is structural here,
//  not a convention — ``ScheduleSpec`` carries a ``ScheduleSpec/Shape`` and both
//  ends of a spec are built from the same shape by the same code path, so a
//  mismatch is unrepresentable. ``ScheduleSpec/isBalanced`` re-checks it anyway
//  and is asserted in `Tests/GateKernelTests/ScheduleBuilderTests.swift`.
//
//  The locked design, per §7:
//    - Repeating daily windows (`repeats: true`)  -> `[.hour, .minute, .second]`.
//      A repeating schedule is a time-of-day concept; adding `.day` makes it an
//      absolute date that conflicts with the repeat.
//    - One-shot expiry timers (`repeats: false`)  -> `[.year … .second]`, start at
//      the start of the current day so the interval is already ongoing and the
//      system calls `intervalDidStart` immediately, end at the deadline. This is
//      Foqos's proven grant scheduler.
//
//  §7 also requires an A/B test of both shapes on the target iOS build
//  (docs/06-build-plan.md step 2.6). Until that runs, which shape delivers which
//  callback on which build is **not verified from a device**. Nothing in Gate's
//  correctness rests on the answer: `DeviceActivityMonitor` is a best-effort
//  accelerator, and the ground truth is recomputed from absolute timestamps on
//  every foreground (docs/05-architecture.md, enforcement layering).
//  ─────────────────────────────────────────────────────────────────────────────
//
//  RULES FOR THIS FILE
//  1. **Pure functions of (input, now, calendar).** No `Date()`, no
//     `Calendar.current` captured at file scope, no `TimeZone.current` read behind
//     the caller's back. Every entry point takes `now` and a `Calendar` so the DST
//     and time-zone cases are testable without touching the process locale
//     (docs/06-build-plan.md step 3.11).
//  2. **Never trap.** Reachable from the monitor, cold, under a 6 MB ceiling
//     (docs/03-hard-constraints.md #31), on data decoded from a file another
//     process may have been killed while writing. Every calendar call that can
//     return `nil` has a documented fallback.
//  3. Foundation only in the pure layer; the SDK lives in the
//     `#if os(iOS)` island at the bottom.
//

import Foundation

#if os(iOS)
import DeviceActivity
#endif

#if os(iOS)
import ManagedSettings
#endif

// MARK: - ScheduleSpec

/// A `DeviceActivitySchedule` in a form that has no SDK dependency.
///
/// The SDK type is constructed on demand in the island at the bottom of this
/// file. Keeping the value plain buys three things: the DST tests run on Linux;
/// the spec is `Sendable` and `Hashable` (`DeviceActivitySchedule` is neither,
/// audited); and ``fingerprint`` gives `MonitorPlan` a cheap way to answer "has
/// this rule's window changed since I armed it?", which the SDK type cannot,
/// because it exposes no stable identity.
public struct ScheduleSpec: Sendable, Equatable, Hashable {

    /// Which component set both ends carry. See the header — the two shapes are
    /// not interchangeable and the ends may never disagree.
    public enum Shape: String, Sendable, Hashable, CaseIterable {

        /// `[.hour, .minute, .second]`, `repeats: true`. A repeating daily window
        /// (docs/04-product-spec.md V1-5).
        case timeOfDay

        /// `[.year, .month, .day, .hour, .minute, .second]`, `repeats: false`. A
        /// one-shot expiry timer for a ``Grant`` or a ``PendingChange``.
        case absolute

        /// The exact set of components a spec of this shape must carry on **both**
        /// ends.
        public var components: Set<Calendar.Component> {
            switch self {
            case .timeOfDay: [.hour, .minute, .second]
            case .absolute: [.year, .month, .day, .hour, .minute, .second]
            }
        }

        public var repeats: Bool { self == .timeOfDay }
    }

    public let shape: Shape
    public let intervalStart: DateComponents
    public let intervalEnd: DateComponents

    /// Lead time for `intervalWillStartWarning` / `intervalWillEndWarning`
    /// (docs/02-api-reference.md §8). `nil` disables both.
    ///
    /// A **duration**, not a time of day: ``RuleSchedule/warningComponents`` builds
    /// it as a bare `DateComponents(minute:)`. The component-set matching rule in
    /// §7 governs `intervalStart` against `intervalEnd` and nothing else, so this
    /// deliberately carries a different set from either end and ``isBalanced`` does
    /// not consider it.
    public let warningTime: DateComponents?

    public init(
        shape: Shape,
        intervalStart: DateComponents,
        intervalEnd: DateComponents,
        warningTime: DateComponents? = nil
    ) {
        self.shape = shape
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.warningTime = warningTime
    }

    public var repeats: Bool { shape.repeats }

    /// Whether both ends carry exactly the component set their shape demands.
    ///
    /// The one invariant in this file that, if broken, produces the thread-726331
    /// failure — a schedule that reads as continuously active for days. It is
    /// unrepresentable through this type's constructors; this property exists so
    /// the tests can prove that and so the debug screen can show it
    /// (docs/04-product-spec.md V1-11).
    public var isBalanced: Bool {
        let required = shape.components
        return ScheduleSpec.presentComponents(intervalStart) == required
            && ScheduleSpec.presentComponents(intervalEnd) == required
    }

    /// Nominal seconds from start to end, wrapping past midnight for a
    /// ``Shape/timeOfDay`` spec.
    ///
    /// **Nominal**: on a DST transition day the real elapsed time is an hour more
    /// or less. That is the right number for checking iOS's 15-minute floor and
    /// one-week ceiling, which are expressed in wall-clock components — the same
    /// reasoning as ``RuleSchedule/duration``. For real elapsed time, use
    /// ``ScheduleBuilder/nextWindow(of:after:in:)``, which does date arithmetic
    /// through a `Calendar`.
    public var nominalDuration: TimeInterval? {
        switch shape {
        case .timeOfDay:
            guard let startSeconds = ScheduleSpec.secondsOfDay(intervalStart),
                  let endSeconds = ScheduleSpec.secondsOfDay(intervalEnd)
            else { return nil }
            if endSeconds > startSeconds { return TimeInterval(endSeconds - startSeconds) }
            if endSeconds < startSeconds {
                return TimeInterval(TimeOfDay.secondsPerDay - startSeconds + endSeconds)
            }
            return 0

        case .absolute:
            // Resolved against a calendar by the caller; an absolute spec's real
            // length is in the `DateInterval` that
            // ``ScheduleBuilder/oneShotSpec(deadline:now:calendar:)`` returns
            // alongside it, which is the value that was range-checked.
            return nil
        }
    }

    /// A stable digest of everything that would change the armed schedule.
    ///
    /// `startMonitoring` **overwrites** the schedule for a name it already holds
    /// (docs/02-api-reference.md §7), and a `DeviceActivityName` for a rule is just
    /// `gate.rule:<uuid>` — it does not encode the window. So "the name is already
    /// armed" does not imply "armed with the schedule we want". `MonitorPlan.diff`
    /// compares this digest against the one recorded when the activity was armed
    /// and restarts only what actually changed.
    ///
    /// `GateFingerprint` rather than `hashValue`: Swift seeds its hasher per
    /// process, and this value is written by the app and read back by code running
    /// in the monitor (see ``GateFingerprint``).
    public var fingerprint: String {
        GateFingerprint.combine([
            shape.rawValue,
            ScheduleSpec.render(intervalStart),
            ScheduleSpec.render(intervalEnd),
            warningTime.map(ScheduleSpec.render) ?? "-",
        ])
    }

    // MARK: Component helpers

    // The six components this file ever sets or inspects, always in this order.
    // Anything outside the six is treated as absent, which is correct: Gate never
    // sets `.weekday`, `.era` or `.nanosecond` on a schedule, and a
    // `DateComponents` that arrived carrying one did not come from here.
    //
    // Spelled out rather than driven from a table of accessors on purpose: an
    // array of closures is not `Sendable`, and under Swift 6 strict concurrency a
    // non-`Sendable` stored static does not compile.

    /// Which of the six components are actually set.
    static func presentComponents(_ components: DateComponents) -> Set<Calendar.Component> {
        var present: Set<Calendar.Component> = []
        if components.year != nil { present.insert(.year) }
        if components.month != nil { present.insert(.month) }
        if components.day != nil { present.insert(.day) }
        if components.hour != nil { present.insert(.hour) }
        if components.minute != nil { present.insert(.minute) }
        if components.second != nil { present.insert(.second) }
        return present
    }

    /// A deterministic, process-independent rendering, for ``fingerprint``.
    ///
    /// An absent component renders as `-`, so a component that is set to zero can
    /// never be confused with one that is not set at all — which is exactly the
    /// difference between the two shapes.
    static func render(_ components: DateComponents) -> String {
        func field(_ value: Int?) -> String { value.map(String.init) ?? "-" }
        return [
            field(components.year),
            field(components.month),
            field(components.day),
            field(components.hour),
            field(components.minute),
            field(components.second),
        ].joined(separator: ",")
    }

    private static func secondsOfDay(_ components: DateComponents) -> Int? {
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return hour * 3600 + minute * 60 + (components.second ?? 0)
    }
}

// MARK: - ScheduleBoundary

/// One edge of one occurrence of a repeating window, as an absolute instant.
///
/// This is what `Kernel/Engine/Reconciler.swift` arms
/// `UNCalendarNotificationTrigger` backstops against (docs/04-product-spec.md
/// V1-10 step 5). The backstops exist because `intervalDidStart` /
/// `intervalDidEnd` fire only when the device is in use, never at the wall-clock
/// boundary (docs/03-hard-constraints.md #27), and because the monitor extension
/// is killed for memory or idleness and has been reported as never launching at
/// all (#32). ``GateState/nextDeadline(after:)`` covers the other two deadline
/// sources — ripening pending changes and expiring grants — and says explicitly
/// that schedule boundaries come from here.
public struct ScheduleBoundary: Sendable, Equatable, Hashable {

    public enum Edge: String, Sendable, Hashable, CaseIterable {
        /// The window opens: the rule starts contributing to its shield set.
        case start
        /// The window closes.
        case end
    }

    public let date: Date
    public let edge: Edge

    public init(date: Date, edge: Edge) {
        self.date = date
        self.edge = edge
    }
}

// MARK: - EventSpec

/// A `DeviceActivityEvent` in SDK-free form.
///
/// v1 arms **no** events: no v1 ``Rule`` carries a usage budget
/// (docs/04-product-spec.md V1-2), and `eventDidReachThreshold` is the least
/// reliable surface in the whole API — it fires on first unlock, fires with zero
/// recorded minutes, fires twice, fires when the threshold was not met, or never
/// arrives (docs/03-hard-constraints.md #35, ten Feedback IDs). Daily budgets ship
/// as opt-in Beta in v2 (docs/04-product-spec.md V2-4).
///
/// The type exists now because step 3.6 owns event construction and because the
/// V2-4 staircase puts many events inside **one** activity: events are cheap,
/// activities are capped at 20.
public struct EventSpec: Sendable, Equatable, Hashable {

    /// Identity, encoded into the `DeviceActivityEvent.Name`. The monitor gets
    /// only this string back (docs/02-api-reference.md §8).
    public let key: GateEventKey

    /// Whether usage recorded *before* `startMonitoring` was called counts toward
    /// the threshold. iOS 17.4+; the 4-argument initializer is used below that and
    /// behaves as `true` (docs/02-api-reference.md §7, §13).
    ///
    /// Always `false` here. Apple, verbatim: *"if your app calls [startMonitoring]
    /// at 1:30pm with a schedule of 1:00pm to 2:00pm, then this boolean determines
    /// whether any activity between 1:00pm and 1:30pm will contribute to its
    /// threshold. If set to true and the event's schedule does not start on a round
    /// hour … the system will include device activity from the start of the
    /// nearest round hour."* §7's instruction is to set it explicitly to `false`
    /// for session-scoped events. Leaving it `true` on a one-shot timer whose
    /// interval starts at midnight would credit the whole day's usage the instant
    /// the activity is armed.
    public let includesPastActivity: Bool

    public init(key: GateEventKey, includesPastActivity: Bool = false) {
        self.key = key
        self.includesPastActivity = includesPastActivity
    }

    public var name: String { key.rawName }

    /// The threshold as `DateComponents`.
    ///
    /// Always a single `.minute` value, never `[.hour, .minute]`. Screen Time
    /// accounting is minute-grained, and a single component cannot be
    /// misinterpreted by a calendar that normalizes differently than expected. A
    /// sub-minute threshold rounds **up** to one minute: rounding down to zero
    /// would arm an event that is already met, and docs/03-hard-constraints.md #35
    /// says fires-immediately is already a failure mode Gate has to defend
    /// against — it should not manufacture one.
    public var threshold: DateComponents {
        let minutes = max(1, Int((Double(key.thresholdSeconds) / 60).rounded(.up)))
        return DateComponents(minute: minutes)
    }

    public var fingerprint: String {
        GateFingerprint.combine([name, includesPastActivity ? "1" : "0"])
    }
}

// MARK: - ScheduleBuilder

/// Every calendar computation in the kernel.
///
/// An uninhabited namespace, like ``GateID`` and ``ActivityNameCodec``: nothing to
/// allocate inside the monitor.
public enum ScheduleBuilder {

    // MARK: Tunables

    /// Minimum distance between `now` and the end of a one-shot interval.
    ///
    /// A timer armed for an instant that has already passed — or is about to — is
    /// a timer whose `intervalDidEnd` may never arrive, or may arrive before
    /// `startMonitoring` has returned. 60 seconds deliberately matches
    /// ``GateLimits/eventFalsePositiveGuard``, the window inside which the monitor
    /// discards a threshold event as the documented iOS 26.x false positive
    /// (docs/03-hard-constraints.md #35): the two numbers describe the same
    /// "nothing meaningful can have happened yet" interval, and keeping them equal
    /// means an event armed by this builder can never be born inside the monitor's
    /// own suspicion window.
    public static let minimumLead: TimeInterval = GateLimits.eventFalsePositiveGuard

    /// Slack kept away from iOS's one-week ceiling when an interval has to be
    /// clamped. `startMonitoring` throws `.intervalTooLong` on the far side of it
    /// (docs/02-api-reference.md §14) and floating-point seconds are not worth
    /// betting an unenforced block on.
    public static let ceilingMargin: TimeInterval = 60

    // MARK: Repeating windows (V1-5)

    /// What ``repeatingSpec(for:)`` decided.
    public enum RepeatingOutcome: Sendable, Equatable {

        /// A registrable window.
        ///
        /// - Parameter droppedWarning: the stored ``RuleSchedule/warningMinutes``
        ///   did not fit inside the window, so `warningTime` was left `nil` rather
        ///   than the whole window being abandoned. `MonitorPlan` reports this as a
        ///   diagnostic.
        case scheduled(ScheduleSpec, droppedWarning: Bool)

        /// The window cannot be registered at all. Carries
        /// ``RuleSchedule/validate()``'s reasons so the debug screen can say which
        /// (docs/04-product-spec.md V1-11).
        case unregistrable([RuleIssue])

        public var spec: ScheduleSpec? {
            if case .scheduled(let spec, _) = self { return spec }
            return nil
        }
    }

    /// Builds the one repeating `DeviceActivitySchedule` for a rule's window.
    ///
    /// **One activity per rule, never one per weekday.** A rule with
    /// `weekdays == [.monday, .wednesday]` still produces exactly one spec; the
    /// weekday test happens in `intervalDidStart`, through
    /// ``Rule/shouldEnforce(at:in:)``, which no-ops on a day the rule does not
    /// cover. Registering a name per rule-per-weekday would blow the 20-activity
    /// cap at rule #3 (docs/04-product-spec.md V1-5;
    /// ``GateLimits/maxRepeatingActivities``).
    ///
    /// **Midnight crossing.** A 22:00 → 06:00 window is expressed exactly as
    /// stored: `intervalStart` hour 22, `intervalEnd` hour 6, `repeats: true`. No
    /// splitting into two activities, which would double the activity count and
    /// double every callback. Whether the system wraps such a schedule to the
    /// following day is **not stated anywhere in docs/02-api-reference.md** and is
    /// therefore unverified until step 2.6's device A/B test runs; the
    /// alternatives are worse (two activities per wrapping rule) and nothing
    /// depends on the answer, because ``RuleSchedule/contains(_:in:)`` and
    /// ``boundaries(of:after:limit:in:)`` compute the wrap themselves for the
    /// foreground reconcile and the notification backstops, which are the
    /// *correct* enforcement path (docs/05-architecture.md, enforcement layering).
    /// If the daemon turns out not to wrap, Gate loses callback timeliness on
    /// overnight rules and loses no enforcement.
    ///
    /// **Registration is more permissive than the editor.**
    /// ``RuleIssue/isBlocking`` marks ``RuleIssue/warningTimeTooLong(seconds:windowSeconds:)``
    /// blocking, and the editor refuses to *create* such a schedule. A schedule
    /// that already exists is a different question: dropping a `warningTime` costs
    /// two advisory callbacks, while dropping the window costs the block. So the
    /// partition here is by allowlist — only a too-long warning is recoverable, and
    /// any `RuleIssue` case added later defaults to blocking.
    public static func repeatingSpec(for schedule: RuleSchedule) -> RepeatingOutcome {
        let issues = schedule.validate()
        let blocking = issues.filter { !isRecoverableAtRegistration($0) }
        guard blocking.isEmpty else { return .unregistrable(blocking) }

        // `isWellFormed` is re-checked because it — not `validate()` — is the
        // predicate ``Rule/shouldEnforce(at:in:)`` uses to decide that a malformed
        // schedule means "always in force". A window that is always in force has no
        // boundaries, so it needs no activity, and the two files must agree or Gate
        // arms a timer for an edge that can never arrive. Every way of failing
        // `isWellFormed` also produces a blocking issue above, so this guard is
        // unreachable today; it is here so that adding a well-formedness condition
        // without a matching `RuleIssue` fails closed instead of arming a window
        // nobody can describe.
        guard schedule.isWellFormed else { return .unregistrable([.degenerateSchedule]) }

        let warningTooLong = issues.contains { isRecoverableAtRegistration($0) }

        // A zero-minute lead is indistinguishable from no warning at all — the
        // callback would fire at the same boundary `intervalDidStart` /
        // `intervalDidEnd` already cover — and `RuleSchedule.init` clamps negatives
        // to zero, so it is reachable from the editor. Normalize it away rather
        // than handing the daemon `DateComponents(minute: 0)` and finding out.
        let hasUsableWarning = (schedule.warningMinutes ?? 0) > 0 && !warningTooLong

        let spec = ScheduleSpec(
            shape: .timeOfDay,
            intervalStart: schedule.intervalStartComponents,
            intervalEnd: schedule.intervalEndComponents,
            warningTime: hasUsableWarning ? schedule.warningComponents : nil
        )
        return .scheduled(spec, droppedWarning: warningTooLong)
    }

    /// ``repeatingSpec(for:)`` for a whole rule.
    ///
    /// A rule with **no** schedule produces `nil`, not an empty spec: it is in
    /// force whenever it is enabled, so it has no boundaries, so it needs no
    /// `DeviceActivityName` and should not spend one of the twenty. A disabled rule
    /// likewise produces `nil` — an armed window for a rule that contributes
    /// nothing is a callback that wakes a 6 MB process to do nothing.
    public static func repeatingSpec(for rule: Rule) -> RepeatingOutcome? {
        guard rule.isEnabled, let schedule = rule.schedule else { return nil }
        return repeatingSpec(for: schedule)
    }

    private static func isRecoverableAtRegistration(_ issue: RuleIssue) -> Bool {
        switch issue {
        case .warningTimeTooLong:
            true
        case .emptyName, .nameTooLong, .noSelection, .emptySelection, .tokenCapExceeded,
             .scheduleTooShort, .scheduleTooLong, .degenerateSchedule, .scheduleHasNoWeekdays:
            false
        }
    }

    // MARK: One-shot timers (grants, auto-reverts)

    /// What ``oneShotSpec(deadline:now:calendar:)`` decided.
    public enum OneShotOutcome: Sendable, Equatable {

        /// A registrable timer, plus the absolute interval it resolves to. The
        /// interval is what was range-checked against iOS's floor and ceiling, and
        /// what `MonitorPlan` sorts by when it has to evict the furthest-out timer.
        case scheduled(ScheduleSpec, interval: DateInterval)

        case unschedulable(Reason)

        public enum Reason: String, Sendable, Hashable, CaseIterable {

            /// The deadline is more than one week out, so no interval can both end
            /// on it and satisfy `DeviceActivityCenter`'s one-week ceiling
            /// (``GateLimits/maxScheduleInterval``, `.intervalTooLong`).
            ///
            /// Reachable in normal use: ``GateLimits/maxLockDelay`` is exactly
            /// seven days, so a pending change queued behind a maximum-length Lock
            /// has no timer for its first few hours. That is correct and
            /// self-healing — the deadline is an absolute timestamp in
            /// `state.plist`, the next foreground reconcile re-plans, and the timer
            /// is armed as soon as it fits (docs/04-product-spec.md V1-10).
            case deadlineTooFarOut

            /// A `Calendar` call returned `nil` or produced an interval that still
            /// violates the bounds after one corrective pass. Not reachable with a
            /// Gregorian calendar; handled rather than trapped because this code
            /// runs in the monitor against decoded state.
            case calendarArithmeticFailed
        }

        public var spec: ScheduleSpec? {
            if case .scheduled(let spec, _) = self { return spec }
            return nil
        }

        public var interval: DateInterval? {
            if case .scheduled(_, let interval) = self { return interval }
            return nil
        }
    }

    /// Builds the one-shot `DeviceActivitySchedule` whose `intervalDidEnd` fires at
    /// `deadline`.
    ///
    /// Shape, per docs/02-api-reference.md §7: full `[.year … .second]` on both
    /// ends, `repeats: false`, start at `Calendar.startOfDay(for: now)` so the
    /// interval is *already ongoing* and the system calls `intervalDidStart`
    /// immediately — which is the only cheap confirmation that the arm took.
    ///
    /// Three corrections §7's one-line recipe does not cover, each of which is a
    /// real `MonitoringError` if skipped:
    ///
    /// 1. **The late-night floor.** §7 says end = `max(expiresAt, now + 60)` "to
    ///    clear the 15-minute floor". That clears it only because start-of-day is
    ///    usually hours behind. At 00:05 it is not: start 00:00, end 00:06, a
    ///    six-minute interval, `.intervalTooShort` thrown while applying a block.
    ///    The start is moved back a whole day — still a clean day boundary, still
    ///    in the past, and at least 24 hours long.
    /// 2. **The one-week ceiling.** A seven-day Lock delay
    ///    (``GateLimits/maxLockDelay``) plus a start at today's midnight exceeds
    ///    ``GateLimits/maxScheduleInterval``. The start is pulled forward to
    ///    `end − (1 week − ``ceilingMargin``)`. That can land slightly *after*
    ///    `now`, which forfeits the immediate `intervalDidStart` but keeps
    ///    `intervalDidEnd` on the deadline — the callback that actually matters.
    /// 3. **DST ambiguity at the end.** During a fall-back repeated hour, the
    ///    wall-clock components of an instant name two instants, and `Calendar`
    ///    resolves them to the *earlier* one. See
    ///    ``absoluteComponents(notEarlierThan:in:)``.
    ///
    /// - Parameters:
    ///   - deadline: ``Grant/expiresAt`` or ``PendingChange/earliestApplyAt``.
    ///     A deadline in the past is pushed to `now + ``minimumLead``` rather than
    ///     rejected; the reconciler resolves an already-ripe record from its
    ///     timestamp on this very pass, and an already-passed timer is harmless
    ///     because every monitor callback does nothing but re-run the
    ///     timestamp-driven reconcile.
    ///   - now: the instant the plan is being computed for.
    ///   - calendar: injected; carries the time zone.
    public static func oneShotSpec(
        deadline: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> OneShotOutcome {
        let requestedEnd = max(deadline, now.addingTimeInterval(minimumLead))

        guard requestedEnd.timeIntervalSince(now) <= GateLimits.maxScheduleInterval else {
            return .unschedulable(.deadlineTooFarOut)
        }

        // End first: its components may move the instant later (DST), and the
        // start has to be chosen against the instant that actually results.
        let endComponents = absoluteComponents(notEarlierThan: requestedEnd, in: calendar)
        let end = calendar.date(from: endComponents) ?? requestedEnd

        var start = calendar.startOfDay(for: now)
        if end.timeIntervalSince(start) < GateLimits.minScheduleInterval {
            start = calendar.date(byAdding: .day, value: -1, to: start)
                ?? start.addingTimeInterval(-TimeInterval(TimeOfDay.secondsPerDay))
        }
        if end.timeIntervalSince(start) > GateLimits.maxScheduleInterval {
            start = end.addingTimeInterval(-(GateLimits.maxScheduleInterval - ceilingMargin))
        }

        // The start's own components can resolve to a different instant for the
        // same DST reason, which changes the interval length that iOS will see.
        // Measure what the components actually mean, then correct once.
        var startComponents = absoluteComponents(for: start, in: calendar)
        var resolvedStart = calendar.date(from: startComponents) ?? start

        if !isLegalInterval(from: resolvedStart, to: end) {
            let corrected = correctedStart(forEnd: end)
            startComponents = absoluteComponents(for: corrected, in: calendar)
            resolvedStart = calendar.date(from: startComponents) ?? corrected
            guard isLegalInterval(from: resolvedStart, to: end) else {
                return .unschedulable(.calendarArithmeticFailed)
            }
        }

        let spec = ScheduleSpec(
            shape: .absolute,
            intervalStart: startComponents,
            intervalEnd: endComponents,
            // No `warningTime` on a one-shot. `intervalWillEndWarning` would wake
            // the monitor a second time to learn nothing the reconcile at
            // `intervalDidEnd` does not already recompute, and every avoided
            // callback is memory not spent under the 6 MB ceiling.
            warningTime: nil
        )

        // `DateInterval(start:end:)` has a `precondition(end >= start)` and would
        // trap. Both paths above reach here only having passed `isLegalInterval`,
        // whose floor is ``GateLimits/minScheduleInterval`` — 15 minutes, strictly
        // positive — so `end > resolvedStart` holds by construction.
        return .scheduled(spec, interval: DateInterval(start: resolvedStart, end: end))
    }

    private static func isLegalInterval(from start: Date, to end: Date) -> Bool {
        let length = end.timeIntervalSince(start)
        return length >= GateLimits.minScheduleInterval && length <= GateLimits.maxScheduleInterval
    }

    /// A start that is comfortably inside both bounds for a given end: one day
    /// back, which is far above the 15-minute floor and far below the one-week
    /// ceiling.
    private static func correctedStart(forEnd end: Date) -> Date {
        end.addingTimeInterval(-TimeInterval(TimeOfDay.secondsPerDay))
    }

    // MARK: Calendar primitives

    /// `[.year, .month, .day, .hour, .minute, .second]` for an instant.
    ///
    /// The component set is fixed here so both ends of an absolute spec are built
    /// by this one function and cannot drift apart (see the header).
    public static func absoluteComponents(for date: Date, in calendar: Calendar) -> DateComponents {
        calendar.dateComponents(ScheduleSpec.Shape.absolute.components, from: date)
    }

    /// Absolute components that a `Calendar` will resolve back to an instant **no
    /// earlier than** `date`.
    ///
    /// During a fall-back DST transition the same wall clock happens twice — in
    /// US Eastern, 01:30 occurs at 01:30 EDT and again an hour later at 01:30 EST.
    /// `Calendar.date(from:)` resolves such components to the *first* occurrence.
    /// Handing iOS the raw components of the second occurrence would arm a timer
    /// that fires up to an hour **early**.
    ///
    /// Firing early is the wrong direction. An auto-revert timer applies a queued
    /// *loosening*; letting one land ahead of its deadline is exactly what the
    /// Lock exists to prevent (docs/04-product-spec.md V1-3). So on detecting the
    /// skew the instant is pushed forward by it and re-expressed, at most twice,
    /// then returned regardless — a bounded loop, never a `while`, because this
    /// runs in the monitor.
    ///
    /// The cost of the other direction is small and self-correcting: a callback an
    /// hour late still finds the deadline passed and does the right thing, and
    /// nothing waits on it anyway. Every monitor callback does nothing but re-run
    /// the timestamp-driven reconcile (docs/04-product-spec.md V1-10), so an early
    /// fire would be a silent no-op and a late fire is a delay the foreground
    /// reconcile and the notification backstop both cover independently.
    ///
    /// Spring-forward needs no counterpart here: components extracted from a real
    /// instant always denote a real instant. The non-existent-time case arises only
    /// when *constructing* from components, which for repeating windows is iOS's
    /// job — ``RuleSchedule/contains(_:in:)`` documents that a 02:00–03:00 window
    /// simply never matches on that day — and for boundary enumeration is handled
    /// by `matchingPolicy: .nextTime` in ``boundaries(of:after:limit:in:)``.
    public static func absoluteComponents(
        notEarlierThan date: Date,
        in calendar: Calendar
    ) -> DateComponents {
        var target = date
        for _ in 0..<2 {
            let components = absoluteComponents(for: target, in: calendar)
            guard let resolved = calendar.date(from: components) else { return components }
            if resolved >= date { return components }
            target = target.addingTimeInterval(date.timeIntervalSince(resolved))
        }
        return absoluteComponents(for: target, in: calendar)
    }

    // MARK: Boundary enumeration

    /// Hard cap on iterations of the boundary walk, so a pathological calendar or
    /// weekday mask can never spin in the monitor.
    private static let boundarySearchCeiling = 64

    /// The next occurrences of a window's edges, in chronological order.
    ///
    /// Weekday-scoped and midnight-aware, matching ``RuleSchedule/contains(_:in:)``
    /// edge for edge — for a wrapping window the tail after midnight belongs to the
    /// **previous** day's occurrence, so an `end` boundary is gated on the previous
    /// day's bit. A "22:00–06:00, Fridays" schedule yields Friday 22:00 and
    /// Saturday 06:00, never Friday 06:00.
    ///
    /// **DST.** Enumeration goes through `Calendar.nextDate(after:matching:)` with
    /// `matchingPolicy: .nextTime` and `repeatedTimePolicy: .first`, so a
    /// non-existent spring-forward boundary (02:30 on the day 02:00 becomes 03:00)
    /// moves to the next instant that does exist, and a repeated fall-back boundary
    /// resolves to its first occurrence — the same rules `DateComponents` get
    /// everywhere else in the system. Emitting nothing on spring-forward day would
    /// silently drop a backstop notification; emitting both fall-back occurrences
    /// would double one.
    ///
    /// When a DST shift makes a start and an end land on the same instant — a
    /// window entirely inside the skipped hour — the `end` is emitted and the
    /// `start` is not, which matches ``RuleSchedule/contains(_:in:)`` returning
    /// `false` all that day.
    ///
    /// - Parameters:
    ///   - schedule: the window.
    ///   - start: boundaries strictly after this instant.
    ///   - limit: how many to return. The reconciler wants the next two — one
    ///     start, one end — for its backstops (docs/04-product-spec.md V1-10 step 5).
    ///   - calendar: injected; carries the time zone.
    public static func boundaries(
        of schedule: RuleSchedule,
        after start: Date,
        limit: Int = 2,
        in calendar: Calendar = .current
    ) -> [ScheduleBoundary] {
        guard schedule.isWellFormed, limit > 0 else { return [] }

        var found: [ScheduleBoundary] = []
        found.reserveCapacity(limit)
        var cursor = start
        var iterations = 0

        while found.count < limit && iterations < boundarySearchCeiling {
            iterations += 1

            let nextStart = nextOccurrence(
                of: schedule.intervalStartComponents, after: cursor, in: calendar
            )
            let nextEnd = nextOccurrence(
                of: schedule.intervalEndComponents, after: cursor, in: calendar
            )

            let candidate: (date: Date, edge: ScheduleBoundary.Edge)
            switch (nextStart, nextEnd) {
            case (nil, nil):
                return found
            case (.some(let startDate), nil):
                candidate = (startDate, .start)
            case (nil, .some(let endDate)):
                candidate = (endDate, .end)
            case (.some(let startDate), .some(let endDate)):
                // On a tie the end wins: closing a window Gate may have opened is
                // the conservative order, and the start it displaces is one that
                // ``RuleSchedule/contains(_:in:)`` would report as never open.
                candidate = endDate <= startDate ? (endDate, .end) : (startDate, .start)
            }

            cursor = candidate.date
            if isLive(schedule: schedule, edge: candidate.edge, at: candidate.date, in: calendar) {
                found.append(ScheduleBoundary(date: candidate.date, edge: candidate.edge))
            }
        }

        return found
    }

    /// The single next boundary, or `nil` if the schedule can never produce one
    /// (not well-formed, or an empty weekday mask).
    public static func nextBoundary(
        of schedule: RuleSchedule,
        after start: Date,
        in calendar: Calendar = .current
    ) -> ScheduleBoundary? {
        boundaries(of: schedule, after: start, limit: 1, in: calendar).first
    }

    /// The window that is open at `now`, or the next one that will open.
    ///
    /// The kernel's answer to `DeviceActivitySchedule.nextInterval`
    /// (docs/02-api-reference.md §7) — same semantics, *"next, or current if
    /// ongoing"* — but computed from a `Calendar` the caller supplies, so it works
    /// in the SwiftPM tests, in the monitor, and for the home-screen countdown,
    /// and so the DST and midnight-crossing cases are covered by the same code the
    /// backstops use.
    ///
    /// Returns `nil` for a schedule that is not well-formed, and for the rare case
    /// where a window is reported open but its opening edge cannot be located — a
    /// DST-skipped start. Returning `nil` there is deliberate: a half-known
    /// interval shown in the UI as a countdown would be a lie, and the UI's
    /// fallback copy — *"blocks start and end the next time you pick up your
    /// phone"* (docs/04-product-spec.md V1-5) — is honest.
    public static func nextWindow(
        of schedule: RuleSchedule,
        after now: Date,
        in calendar: Calendar = .current
    ) -> DateInterval? {
        guard schedule.isWellFormed else { return nil }

        if schedule.contains(now, in: calendar) {
            // Search backwards from just after `now` so that a `now` sitting
            // exactly on the opening edge finds that edge: `contains` is half-open
            // and includes the start, but `nextDate(after:direction: .backward)` is
            // strictly before its anchor.
            guard let opened = calendar.nextDate(
                after: now.addingTimeInterval(1),
                matching: schedule.intervalStartComponents,
                matchingPolicy: .nextTime,
                repeatedTimePolicy: .first,
                direction: .backward
            ),
                isLive(schedule: schedule, edge: .start, at: opened, in: calendar),
                let closes = firstBoundary(.end, of: schedule, after: now, in: calendar),
                closes >= opened
            else { return nil }

            return DateInterval(start: opened, end: closes)
        }

        guard let opens = firstBoundary(.start, of: schedule, after: now, in: calendar),
              let closes = firstBoundary(.end, of: schedule, after: opens, in: calendar),
              closes >= opens
        else { return nil }

        return DateInterval(start: opens, end: closes)
    }

    /// The next boundary of one specific edge, skipping the other edge entirely.
    private static func firstBoundary(
        _ edge: ScheduleBoundary.Edge,
        of schedule: RuleSchedule,
        after start: Date,
        in calendar: Calendar
    ) -> Date? {
        let components = edge == .start
            ? schedule.intervalStartComponents
            : schedule.intervalEndComponents

        var cursor = start
        for _ in 0..<boundarySearchCeiling {
            guard let candidate = nextOccurrence(of: components, after: cursor, in: calendar) else {
                return nil
            }
            cursor = candidate
            if isLive(schedule: schedule, edge: edge, at: candidate, in: calendar) {
                return candidate
            }
        }
        return nil
    }

    private static func nextOccurrence(
        of components: DateComponents,
        after date: Date,
        in calendar: Calendar
    ) -> Date? {
        calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    /// Whether an edge landing at `date` belongs to an occurrence the weekday mask
    /// actually covers.
    ///
    /// Deliberately identical in structure to the wrapping branch of
    /// ``RuleSchedule/contains(_:in:)``. If these two ever disagree, the monitor
    /// no-ops on a day the backstop fired for, or the reverse, and the symptom is
    /// an overnight rule that enforces on the wrong nights.
    private static func isLive(
        schedule: RuleSchedule,
        edge: ScheduleBoundary.Edge,
        at date: Date,
        in calendar: Calendar
    ) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        switch edge {
        case .start:
            return schedule.weekdays.contains(calendarWeekday: weekday)
        case .end where schedule.crossesMidnight:
            // The tail after midnight belongs to the previous day's occurrence.
            return schedule.weekdays.contains(calendarWeekday: weekday == 1 ? 7 : weekday - 1)
        case .end:
            return schedule.weekdays.contains(calendarWeekday: weekday)
        }
    }
}

// MARK: - DeviceActivity island

// The SDK types, fenced so everything above compiles in the platform-agnostic
// SwiftPM test package (docs/05-architecture.md, module layer split), exactly as
// `Kernel/Model/LockPolicy.swift` fences CryptoKit.
//
// All computed, none stored: `DeviceActivitySchedule` and `DeviceActivityEvent`
// have no audited `Sendable` conformance, so a stored static or a stored property
// of one inside a `Sendable` type is a Swift 6 strict-concurrency error. Same
// reasoning as `ManagedSettingsStore.Name.solid` in `Kernel/Identifiers.swift`.

#if os(iOS)

public extension ScheduleSpec {

    /// The `DeviceActivitySchedule` to hand `startMonitoring`.
    ///
    /// Both ends come from this value's own stored components, which were built
    /// from a single ``ScheduleSpec/Shape``, so the component sets cannot be
    /// mismatched here (docs/02-api-reference.md §7).
    var deviceActivitySchedule: DeviceActivitySchedule {
        DeviceActivitySchedule(
            intervalStart: intervalStart,
            intervalEnd: intervalEnd,
            repeats: repeats,
            warningTime: warningTime
        )
    }
}

#endif

#if os(iOS)

public extension ScheduleBuilder {

    /// Builds a `DeviceActivityEvent` for a threshold over a set of resolved
    /// tokens.
    ///
    /// `includesPastActivity` and its five-argument initializer are iOS 17.4
    /// (docs/02-api-reference.md §13) and the project floor is 17.0, so the call is
    /// `#available`-gated. Below 17.4 the four-argument initializer is used and the
    /// system behaves as though the flag were `true` — usage from the start of the
    /// nearest round hour counts toward the threshold. That is the wrong answer for
    /// a session-scoped event and cannot be corrected on those builds; the caller
    /// is told through the returned flag rather than being left to guess.
    ///
    /// - Returns: `nil` when every token set is empty. An event with no tokens
    ///   measures nothing and can never reach its threshold, so arming one only
    ///   spends an entry in the `events:` dictionary and invites one more chance
    ///   for the false-positive behaviour in docs/03-hard-constraints.md #35.
    static func makeEvent(
        _ spec: EventSpec,
        applications: Set<ApplicationToken>,
        categories: Set<ActivityCategoryToken>,
        webDomains: Set<WebDomainToken>
    ) -> (event: DeviceActivityEvent, honorsIncludesPastActivity: Bool)? {
        guard !applications.isEmpty || !categories.isEmpty || !webDomains.isEmpty else {
            return nil
        }

        if #available(iOS 17.4, *) {
            let event = DeviceActivityEvent(
                applications: applications,
                categories: categories,
                webDomains: webDomains,
                threshold: spec.threshold,
                includesPastActivity: spec.includesPastActivity
            )
            return (event, true)
        } else {
            let event = DeviceActivityEvent(
                applications: applications,
                categories: categories,
                webDomains: webDomains,
                threshold: spec.threshold
            )
            return (event, false)
        }
    }
}

#endif
