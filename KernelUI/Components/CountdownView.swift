//
//  CountdownView.swift
//  GateKernelUI
//
//  The live countdown to an absolute `Date` — the Lock's deadline
//  (docs/04-product-spec.md V1-3), a grant's expiry (V1-7), a schedule boundary
//  (V1-5), the intervention's forced wait (V1-7).
//
//  Three rules this file exists to enforce:
//
//  1. **No `Timer`.** A repeating `Timer` scheduled from a view has to be
//     invalidated from somewhere, and the somewhere is always missed on one path
//     — a sheet dismissed by a swipe, a row scrolled out of a `List`. `Timeline
//     View` is driven by the render loop: it stops when the view is off screen,
//     when the app backgrounds, and when the view is destroyed, with nothing to
//     remember. It is also the only approach that does not capture mutable state
//     in an escaping closure, which Swift 6 strict concurrency would reject here
//     anyway.
//
//  2. **Every deadline is an absolute `Date`, never a decrementing counter.**
//     The remaining time is recomputed from the deadline on every tick, so a
//     dropped frame, a backgrounded app, a device reboot or a user-changed clock
//     cannot make the display drift away from the value `Ratchet` and
//     `Reconciler` will act on. This is the same discipline the reliability
//     backbone uses (V1-10: "every deadline is an absolute timestamp").
//
//  3. **The deadline passing while visible is a first-class case, not an edge
//     case.** The countdown lands on exactly zero, renders its elapsed copy, and
//     tells its host once via `onElapsed` — which is how the pending-changes
//     banner knows to ask for a reconcile the moment a change ripens instead of
//     waiting for the next foreground.
//
//  Nothing here is time-zone or calendar dependent: it is a duration between two
//  instants. Wall-clock boundaries are `ScheduleBuilder`'s job.
//

import Foundation
import SwiftUI

import GateKernel

// MARK: - GateCountdown

/// Duration formatting, shared by every countdown surface in Gate.
///
/// Pure and `Date`-free — it takes a `TimeInterval` and returns a `String`, so
/// it is trivially testable and cannot accidentally read the clock.
///
/// Deliberately not `DateComponentsFormatter`: that type is a non-`Sendable`
/// class, so a shared instance is a Swift 6 strict-concurrency problem and a
/// per-tick instance is an allocation on the render path; it also cannot produce
/// the zero-padded "12m 04s" shape without positional-format gymnastics.
public enum GateCountdown {

    /// How precise the rendered string is.
    public enum Granularity: String, Sendable, Hashable, CaseIterable {

        /// "12m 04s". For anything the user is actively waiting on — the Lock
        /// banner, the intervention wait.
        case seconds

        /// "12m". For a list of rules, where a per-second repaint of eight rows
        /// buys nothing. Also what the schedule uses to decide how long it may
        /// sleep between ticks.
        case minutes

        /// The smallest unit this granularity can display a change in.
        public var smallestUnit: TimeInterval {
            switch self {
            case .seconds: 1
            case .minutes: 60
            }
        }
    }

    /// Anything longer renders as this. The longest real deadline is
    /// ``GateLimits/maxLockDelay`` (7 days); the clamp exists so a corrupt or
    /// far-future date renders as a number instead of overflowing `Int`.
    public static let maximumDisplayedSeconds: TimeInterval = 999 * 24 * 60 * 60

    /// What ``Granularity/minutes`` says below one minute. Honest: at minute
    /// granularity we genuinely do not know whether it is 59 seconds or 1.
    public static let underAMinuteText = "under a minute"

    /// Wake this far *past* a boundary rather than exactly on it.
    ///
    /// The display floors, so "2h 15m" becomes "2h 14m" the instant the
    /// remaining time drops *below* 15 minutes. Waking exactly on the boundary
    /// would render the value that is about to be stale and hold it for a whole
    /// unit.
    static let tickEpsilon: TimeInterval = 0.02

    /// The remaining time split into whole units, clamped and NaN-safe.
    ///
    /// `Int(_:)` traps on NaN and on anything past `Int.max`, and this runs on
    /// the render path with a `Date` that ultimately came off disk, so neither
    /// is hypothetical.
    public struct Components: Sendable, Equatable, Hashable {
        public var days: Int
        public var hours: Int
        public var minutes: Int
        public var seconds: Int

        public init(days: Int, hours: Int, minutes: Int, seconds: Int) {
            self.days = days
            self.hours = hours
            self.minutes = minutes
            self.seconds = seconds
        }

        public var isZero: Bool { days == 0 && hours == 0 && minutes == 0 && seconds == 0 }
    }

    public static func components(_ remaining: TimeInterval) -> Components {
        let safe: TimeInterval = remaining.isNaN
            ? 0
            : min(max(remaining, 0), maximumDisplayedSeconds)
        let total = Int(safe.rounded(.down))
        return Components(
            days: total / 86_400,
            hours: (total % 86_400) / 3_600,
            minutes: (total % 3_600) / 60,
            seconds: total % 60
        )
    }

    /// "3d 4h" · "2h 15m" · "12m 04s" · "43s" · "under a minute".
    ///
    /// Two units, never three: a third is noise at every scale a person reasons
    /// about, and the string has to fit on one line next to a rule's name.
    public static func text(for remaining: TimeInterval,
                            granularity: Granularity = .seconds) -> String {
        let parts = components(remaining)
        if parts.days > 0 { return "\(parts.days)d \(parts.hours)h" }
        if parts.hours > 0 { return "\(parts.hours)h \(parts.minutes)m" }
        switch granularity {
        case .seconds:
            if parts.minutes > 0 { return "\(parts.minutes)m \(pad(parts.seconds))s" }
            return "\(parts.seconds)s"
        case .minutes:
            if parts.minutes > 0 { return "\(parts.minutes)m" }
            return underAMinuteText
        }
    }

    /// The same duration for VoiceOver.
    ///
    /// "12m 04s" is read as "twelve em zero four ess". A countdown the user
    /// cannot hear is a countdown that does not exist for them, and this app's
    /// entire proposition is that the wait is real and legible.
    public static func spoken(for remaining: TimeInterval,
                              granularity: Granularity = .seconds) -> String {
        let parts = components(remaining)
        if parts.days > 0 { return "\(unit(parts.days, "day")) \(unit(parts.hours, "hour"))" }
        if parts.hours > 0 { return "\(unit(parts.hours, "hour")) \(unit(parts.minutes, "minute"))" }
        switch granularity {
        case .seconds:
            if parts.minutes > 0 {
                return "\(unit(parts.minutes, "minute")) \(unit(parts.seconds, "second"))"
            }
            return unit(parts.seconds, "second")
        case .minutes:
            if parts.minutes > 0 { return unit(parts.minutes, "minute") }
            return underAMinuteText
        }
    }

    /// A *configured* duration, not a remaining one: "15m", "1m 30s", "7d".
    ///
    /// Countdown text always shows two units so the string never changes width
    /// mid-tick ("15m 00s"). A setting is read once and should not carry digits
    /// that are always zero, so this drops empty trailing components instead.
    /// Used for the Lock delay, the impulse delay and grant durations.
    public static func durationText(for seconds: TimeInterval) -> String {
        let parts = components(seconds)
        if parts.days > 0 {
            return parts.hours > 0 ? "\(parts.days)d \(parts.hours)h" : "\(parts.days)d"
        }
        if parts.hours > 0 {
            return parts.minutes > 0 ? "\(parts.hours)h \(parts.minutes)m" : "\(parts.hours)h"
        }
        if parts.minutes > 0 {
            return parts.seconds > 0 ? "\(parts.minutes)m \(parts.seconds)s" : "\(parts.minutes)m"
        }
        return "\(parts.seconds)s"
    }

    /// Convenience for a one-shot render with no live updates.
    public static func text(until deadline: Date,
                            from now: Date,
                            granularity: Granularity = .seconds) -> String {
        text(for: deadline.timeIntervalSince(now), granularity: granularity)
    }

    /// How long until ``text(for:granularity:)`` would return something else.
    ///
    /// This is what makes the countdown cheap. A fixed one-second tick keeps a
    /// seven-day Lock countdown repainting 604,800 times to change 168 times; a
    /// fixed one-minute tick cannot render "12m 04s" at all. Ticking exactly
    /// when the string changes gives both.
    ///
    /// Returns `0` for a deadline that has already passed or a non-finite input:
    /// the string will never change again, and the caller stops.
    public static func secondsUntilTextChanges(remaining: TimeInterval,
                                               granularity: Granularity = .seconds) -> TimeInterval {
        guard remaining.isFinite, remaining > 0 else { return 0 }
        let step = max(displayUnit(for: remaining), granularity.smallestUnit)
        // The largest whole multiple of `step` at or below `remaining` — i.e. the
        // value currently on screen. The string changes just past it.
        let boundary = (remaining / step).rounded(.down) * step
        return max(remaining - boundary, 0) + tickEpsilon
    }

    /// The unit the *second* displayed component is counted in, which is the one
    /// that changes most often.
    static func displayUnit(for remaining: TimeInterval) -> TimeInterval {
        if remaining >= 86_400 { return 3_600 }   // "3d 4h"   — changes on the hour
        if remaining >= 3_600 { return 60 }       // "2h 15m"  — changes on the minute
        return 1                                  // "12m 04s" — changes every second
    }

    static func pad(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : "\(value)"
    }

    static func unit(_ value: Int, _ singular: String) -> String {
        "\(value) \(singular)\(value == 1 ? "" : "s")"
    }
}

// MARK: - GateCountdownSchedule

/// A `TimelineSchedule` that ticks only when the rendered string would change,
/// and stops at the deadline.
///
/// `.periodic(from:by:)` is the obvious choice and is wrong at both ends of our
/// range: one second is 168× more repaints than a multi-day Lock countdown
/// needs, and one minute cannot render the "12m 04s" the V1-4 banner specifies.
/// The interval here is derived from the deadline itself, so the same view is
/// correct at four seconds and at seven days. It is still `TimelineView` doing
/// the driving — there is no `Timer` and nothing to invalidate.
///
/// The last entry is the deadline exactly, after which the sequence ends and
/// `TimelineView` stops updating. That is deliberate: it gives the view one
/// render at precisely zero and then costs nothing forever.
public struct GateCountdownSchedule: TimelineSchedule, Sendable {

    /// Never tick faster than this, whatever the arithmetic says. Guards the
    /// render loop against a pathological deadline.
    public static let liveFloor: TimeInterval = 0.05

    /// `.lowFrequency` is requested for power-constrained presentations
    /// (watchOS Always On today; iOS asks for `.normal`). Honouring it costs at
    /// most a stale seconds digit on a surface that is, by definition, not being
    /// looked at closely.
    public static let lowFrequencyFloor: TimeInterval = 60

    public let deadline: Date
    public let granularity: GateCountdown.Granularity

    public init(deadline: Date, granularity: GateCountdown.Granularity = .seconds) {
        self.deadline = deadline
        self.granularity = granularity
    }

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let interval: TimeInterval
        switch mode {
        case .lowFrequency: interval = GateCountdownSchedule.lowFrequencyFloor
        default: interval = GateCountdownSchedule.liveFloor
        }
        return Entries(
            deadline: deadline,
            granularity: granularity,
            floorInterval: interval,
            first: startDate
        )
    }

    public struct Entries: Sequence, IteratorProtocol {

        private let deadline: Date
        private let granularity: GateCountdown.Granularity
        private let floorInterval: TimeInterval
        private var upcoming: Date?

        init(deadline: Date,
             granularity: GateCountdown.Granularity,
             floorInterval: TimeInterval,
             first: Date) {
            self.deadline = deadline
            self.granularity = granularity
            self.floorInterval = max(floorInterval, GateCountdownSchedule.liveFloor)
            self.upcoming = first
        }

        public mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            let remaining = deadline.timeIntervalSince(current)
            if remaining > 0 {
                let step = max(
                    floorInterval,
                    GateCountdown.secondsUntilTextChanges(remaining: remaining,
                                                          granularity: granularity)
                )
                let candidate = current.addingTimeInterval(step)
                // Land on the deadline exactly rather than overshooting it, so the
                // view gets one render at zero. `step` is always >= liveFloor, so
                // this is strictly increasing and the sequence always terminates.
                upcoming = candidate >= deadline ? deadline : candidate
            } else {
                upcoming = nil
            }
            return current
        }
    }
}

// MARK: - CountdownView

/// A live countdown to an absolute date.
///
/// ```swift
/// CountdownView(deadline: change.earliestApplyAt ?? .distantFuture,
///               prefix: "unlocks in",
///               elapsedText: "ready",
///               onElapsed: { model.reconcile(trigger: .userAction) })
/// ```
public struct CountdownView: View {

    /// How the number is set.
    public enum Style: String, Sendable, Hashable, CaseIterable {

        /// Row and banner copy.
        case inline

        /// The intervention screen's hero number (V1-7's forced wait).
        case prominent

        /// Inherit whatever font the caller set. Digits are still monospaced.
        case plain

        var font: Font? {
            // Explicit `return`s, not a `switch` expression: one branch is `nil`
            // and the rest are `Font`, so the branches only agree after optional
            // promotion. Spelling it out costs three words and removes the
            // question.
            switch self {
            case .inline: return GateTheme.Typography.numeric
            case .prominent: return GateTheme.Typography.numericLarge
            case .plain: return nil
            }
        }
    }

    /// What replaces the number once the deadline has passed.
    ///
    /// Not "0s": zero implies the thing happened, and a ripe pending change has
    /// *not* happened until `Reconciler` folds it in — which needs the app
    /// foregrounded (V1-10). Callers should say what is actually true.
    public static let defaultElapsedText = "now"

    public var deadline: Date
    public var style: Style
    public var granularity: GateCountdown.Granularity
    public var prefix: String?
    public var elapsedText: String
    public var onElapsed: (() -> Void)?

    public init(deadline: Date,
                style: Style = .inline,
                granularity: GateCountdown.Granularity = .seconds,
                prefix: String? = nil,
                elapsedText: String = CountdownView.defaultElapsedText,
                onElapsed: (() -> Void)? = nil) {
        self.deadline = deadline
        self.style = style
        self.granularity = granularity
        self.prefix = prefix
        self.elapsedText = elapsedText
        self.onElapsed = onElapsed
    }

    public var body: some View {
        TimelineView(GateCountdownSchedule(deadline: deadline, granularity: granularity)) { context in
            let remaining = deadline.timeIntervalSince(context.date)
            let hasElapsed = remaining <= 0

            Text(displayText(remaining: remaining, hasElapsed: hasElapsed))
                .font(style.font)
                .monospacedDigit()
                .accessibilityLabel(Text(spokenText(remaining: remaining, hasElapsed: hasElapsed)))
                // Tells VoiceOver this element changes on its own, so a focused
                // countdown is not re-announced from the top on every tick.
                .accessibilityAddTraits(.updatesFrequently)
                // `initial: true` so a deadline that was already in the past when
                // the view appeared still reports itself — that case is exactly
                // how a ripe pending change looks after a cold launch.
                .onChange(of: hasElapsed, initial: true) { _, elapsed in
                    if elapsed { onElapsed?() }
                }
        }
    }

    func displayText(remaining: TimeInterval, hasElapsed: Bool) -> String {
        let value = hasElapsed
            ? elapsedText
            : GateCountdown.text(for: remaining, granularity: granularity)
        return join(prefix, value)
    }

    func spokenText(remaining: TimeInterval, hasElapsed: Bool) -> String {
        let value = hasElapsed
            ? elapsedText
            : GateCountdown.spoken(for: remaining, granularity: granularity)
        return join(prefix, value)
    }

    private func join(_ lead: String?, _ value: String) -> String {
        guard let lead, !lead.isEmpty else { return value }
        return "\(lead) \(value)"
    }
}

#if DEBUG
#Preview("Countdown scales") {
    VStack(alignment: .leading, spacing: GateTheme.Spacing.l) {
        CountdownView(deadline: Date().addingTimeInterval(43), prefix: "unlocks in")
        CountdownView(deadline: Date().addingTimeInterval(12 * 60 + 4), prefix: "unlocks in")
        CountdownView(deadline: Date().addingTimeInterval(2 * 3_600 + 15 * 60), prefix: "unlocks in")
        CountdownView(deadline: Date().addingTimeInterval(3 * 86_400 + 4 * 3_600), prefix: "unlocks in")
        CountdownView(deadline: Date().addingTimeInterval(90), granularity: .minutes, prefix: "ends in")
        CountdownView(deadline: Date().addingTimeInterval(-5), elapsedText: "ready")
        CountdownView(deadline: Date().addingTimeInterval(65), style: .prominent)
    }
    .padding(GateTheme.Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GateTheme.background)
}
#endif
