//
//  RuleRow.swift
//  GateKernelUI
//
//  One rule in the home list (docs/06-build-plan.md step 5.4): its name, its
//  on/off switch, what it is doing right now, when that next changes, and how
//  much it covers.
//
//  The row is a pure function of a ``Rule`` plus `now`. It holds no `@State`
//  about the rule — in particular the switch is **not** mirrored into local
//  state. Turning a rule off is a loosening and is queued behind the Lock
//  (docs/04-product-spec.md V1-4), so a switch that moved on tap and stayed
//  there would be the app's most visible lie: the rule is still enforcing. The
//  binding reads `rule.isEnabled` on every render, so a queued change snaps the
//  switch back, which is the truth. ``disablingGoesThroughLock`` is how the row
//  warns about that *before* the tap instead of surprising the user after it.
//
//  Everything time-dependent is a ``CountdownView``, so a row whose window opens
//  or closes while it is on screen updates itself and tells its host
//  (`onBoundaryPassed`) to reconcile.
//

import Foundation
import SwiftUI

import GateKernel

// MARK: - RuleRow

public struct RuleRow: View {

    // MARK: Activity

    /// What a rule is doing at an instant, and when that changes.
    ///
    /// Computed with ``ScheduleBuilder/nextWindow(of:after:in:)`` — the kernel's
    /// DST- and midnight-aware equivalent of `DeviceActivitySchedule.nextInterval`
    /// — so the row, the backstop notifications and the monitor plan all derive
    /// their boundaries from one implementation.
    public struct Activity: Sendable, Equatable, Hashable {

        public enum Phase: String, Sendable, Hashable, CaseIterable {
            /// The rule is switched off.
            case off
            /// Switched on, but it names nothing, so it blocks nothing.
            case incomplete
            /// In force right now.
            case enforcing
            /// On, waiting for its window to open.
            case idle
        }

        public var phase: Phase

        /// When ``phase`` next changes, if that is knowable.
        ///
        /// `nil` for an unscheduled rule (nothing to count down to — it is always
        /// in force) and for the rare schedule whose edge cannot be located, such
        /// as a start time inside a DST-skipped hour. In the second case a
        /// countdown would be a guess, and the row says less instead of guessing.
        public var boundary: Date?

        /// Whether the rule carries a schedule at all, which is what separates
        /// "always on" from "on, boundary unknown".
        public var isScheduled: Bool

        public init(phase: Phase, boundary: Date?, isScheduled: Bool) {
            self.phase = phase
            self.boundary = boundary
            self.isScheduled = isScheduled
        }

        public var isInForce: Bool { phase == .enforcing }

        public var tone: GateTheme.Tone {
            switch phase {
            case .off: .off
            // Amber, not red: an empty rule is a job half-finished, not a fault.
            case .incomplete: .pending
            case .enforcing: .enforcing
            case .idle: .scheduled
            }
        }
    }

    /// The honest-latency note V1-5 requires next to any schedule.
    ///
    /// `intervalDidStart` / `intervalDidEnd` fire only when the device is in use,
    /// never at the wall-clock boundary (docs/03-hard-constraints.md #27). This
    /// is Apple's documented behaviour, not a bug, and saying so up front
    /// preempts the worst of the support load. Render it once under the list —
    /// not per row.
    public static let scheduleLatencyNote =
        "Blocks start and end the next time you pick up your phone, not exactly at the minute."

    /// Shown in place of an empty name.
    public static let untitledName = "Untitled rule"

    // MARK: Stored

    public var rule: Rule

    /// The instant the row is rendering for. Only the non-live parts read it;
    /// the countdowns run off the absolute boundary date.
    public var now: Date

    public var calendar: Calendar

    /// A change against this rule is queued behind the Lock.
    public var hasPendingChange: Bool

    /// Turning this rule off would be queued rather than applied.
    ///
    /// The row cannot work this out for itself: it depends on the ratchet switch
    /// and the lock policy, which live in `GateState`. The home screen computes
    /// it once with
    /// `Ratchet.assess(.setRuleEnabled(ruleID:enabled:false), in: state).goesThroughLock`.
    public var disablingGoesThroughLock: Bool

    /// `nil` disables the switch (no authorization yet, or a read-only preview).
    public var onSetEnabled: ((Bool) -> Void)?

    /// `nil` makes the row non-tappable.
    public var onSelect: (() -> Void)?

    /// Fired once when the displayed boundary passes while the row is visible.
    /// The host should reconcile: the shield set has just changed.
    public var onBoundaryPassed: (() -> Void)?

    public init(rule: Rule,
                now: Date = Date(),
                calendar: Calendar = .current,
                hasPendingChange: Bool = false,
                disablingGoesThroughLock: Bool = false,
                onSetEnabled: ((Bool) -> Void)? = nil,
                onSelect: (() -> Void)? = nil,
                onBoundaryPassed: (() -> Void)? = nil) {
        self.rule = rule
        self.now = now
        self.calendar = calendar
        self.hasPendingChange = hasPendingChange
        self.disablingGoesThroughLock = disablingGoesThroughLock
        self.onSetEnabled = onSetEnabled
        self.onSelect = onSelect
        self.onBoundaryPassed = onBoundaryPassed
    }

    // MARK: Body

    public var body: some View {
        let activity = RuleRow.activity(of: rule, now: now, calendar: calendar)

        HStack(alignment: .center, spacing: GateTheme.Spacing.m) {
            GateStatusDot(tone: activity.tone, isFilled: activity.isInForce)

            tappableLabel(activity)

            Spacer(minLength: GateTheme.Spacing.s)

            HStack(spacing: GateTheme.Spacing.xs) {
                if disablingGoesThroughLock, rule.isEnabled {
                    Image(systemName: "lock.fill")
                        .font(GateTheme.Typography.chip)
                        .foregroundStyle(GateTheme.pending)
                        .accessibilityHidden(true)
                }
                toggle
            }
        }
        .padding(.vertical, GateTheme.Spacing.xs)
        .frame(minHeight: GateTheme.Spacing.minimumTapTarget)
    }

    // MARK: Pieces

    @ViewBuilder
    private func tappableLabel(_ activity: Activity) -> some View {
        if let onSelect {
            Button(action: onSelect) {
                label(activity)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Opens this rule"))
        } else {
            label(activity)
                .accessibilityElement(children: .combine)
        }
    }

    private func label(_ activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
            titleLine
            statusLine(activity)
            selectionLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleLine: some View {
        HStack(spacing: GateTheme.Spacing.s) {
            Text(displayName)
                .font(GateTheme.Typography.headline)
                .foregroundStyle(GateTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            if rule.mode == .allowlist {
                GateChip("Allow-list", tone: .neutral)
            }

            if hasPendingChange {
                GateChip("Pending", tone: .pending, systemImage: "lock.fill")
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ activity: Activity) -> some View {
        HStack(spacing: GateTheme.Spacing.xs) {
            switch activity.phase {
            case .off:
                Text("Off")

            case .incomplete:
                Text("On, but nothing is selected")

            case .enforcing:
                Text("Blocking now")
                if let boundary = activity.boundary {
                    Text("\u{00B7}")
                    CountdownView(deadline: boundary,
                                  granularity: .minutes,
                                  prefix: "ends in",
                                  elapsedText: "ending",
                                  onElapsed: onBoundaryPassed)
                }

            case .idle:
                if let boundary = activity.boundary {
                    CountdownView(deadline: boundary,
                                  granularity: .minutes,
                                  prefix: "starts in",
                                  elapsedText: "starting",
                                  onElapsed: onBoundaryPassed)
                } else {
                    Text("On, waiting for its window")
                }
            }
        }
        .font(GateTheme.Typography.footnote)
        .foregroundStyle(activity.phase == .enforcing ? GateTheme.enforcing : GateTheme.textSecondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var selectionLine: some View {
        if let warning = RuleRow.capWarning(for: rule) {
            Text(warning)
                .font(GateTheme.Typography.caption)
                .foregroundStyle(GateTheme.danger)
                .lineLimit(2)
        } else {
            Text(RuleRow.selectionSummary(for: rule))
                .font(GateTheme.Typography.caption)
                .foregroundStyle(GateTheme.textTertiary)
                .lineLimit(1)
        }
    }

    private var toggle: some View {
        // The label is hidden visually but kept for VoiceOver, which otherwise
        // announces eight identical unlabelled switches.
        Toggle(displayName, isOn: Binding(
            get: { rule.isEnabled },
            set: { onSetEnabled?($0) }
        ))
        .labelsHidden()
        .tint(GateTheme.accent)
        .disabled(onSetEnabled == nil)
        .accessibilityHint(Text(toggleHint))
    }

    private var toggleHint: String {
        if rule.isEnabled {
            return disablingGoesThroughLock
                ? "Turning this off is queued behind the Lock"
                : "Turns this rule off"
        }
        // Turning a rule on is a tightening: always immediate, never queued
        // (docs/04-product-spec.md V1-4).
        return "Turns this rule on immediately"
    }

    private var displayName: String {
        let trimmed = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? RuleRow.untitledName : trimmed
    }
}

// MARK: - Derivations

public extension RuleRow {

    /// What `rule` is doing at `now`.
    static func activity(of rule: Rule,
                         now: Date,
                         calendar: Calendar = .current) -> Activity {
        let isScheduled = rule.schedule != nil

        guard rule.isEnabled else {
            return Activity(phase: .off, boundary: nil, isScheduled: isScheduled)
        }

        // A rule with no selection, or an empty one, writes an empty shield set:
        // it is switched on and blocking nothing. Saying so is the difference
        // between a bug report and a two-second fix.
        let namesSomething = rule.selection.map { !$0.digest.isEmpty } ?? false
        guard namesSomething else {
            return Activity(phase: .incomplete, boundary: nil, isScheduled: isScheduled)
        }

        guard let schedule = rule.schedule else {
            return Activity(phase: .enforcing, boundary: nil, isScheduled: false)
        }

        let window = ScheduleBuilder.nextWindow(of: schedule, after: now, in: calendar)

        // `shouldEnforce` is the authority — it is what `ShieldWriter` consults —
        // and it fails *closed* for a malformed schedule, where `nextWindow`
        // returns nil. Deriving the phase from it rather than from `window` keeps
        // the row honest in exactly that case: it says "blocking now" with no
        // end time, which is what is true.
        if rule.shouldEnforce(at: now, in: calendar) {
            var boundary: Date?
            if let window, window.contains(now) { boundary = window.end }
            return Activity(phase: .enforcing, boundary: boundary, isScheduled: true)
        }

        var boundary: Date?
        if let window, window.start > now { boundary = window.start }
        return Activity(phase: .idle, boundary: boundary, isScheduled: true)
    }

    /// "12 apps · 2 categories" · "Everything except 3 apps" · "Nothing selected".
    ///
    /// Counts come from ``SelectionDigest``, which the app captured when the
    /// picker closed. The row never touches the selection blob itself: it lives
    /// in `selections.plist` precisely so `state.plist` stays under 8 KB, and
    /// decoding it to count tokens would undo that.
    static func selectionSummary(for rule: Rule) -> String {
        guard let digest = rule.selection?.digest, !digest.isEmpty else {
            return "Nothing selected"
        }

        var parts: [String] = []
        if digest.applicationCount > 0 {
            parts.append(pluralized(digest.applicationCount, "app", "apps"))
        }
        if digest.categoryCount > 0 {
            parts.append(pluralized(digest.categoryCount, "category", "categories"))
        }
        if digest.webDomainCount > 0 {
            parts.append(pluralized(digest.webDomainCount, "site", "sites"))
        }

        let list = parts.joined(separator: " \u{00B7} ")

        switch rule.mode {
        case .blocklist:
            return list
        case .allowlist:
            // `.all(except:)` — block everything, allow these
            // (docs/04-product-spec.md V1-2).
            return "Everything except \(list)"
        }
    }

    /// The 50-token cap, surfaced.
    ///
    /// Exceeding it makes the store shield *nothing* and read back `nil`, with no
    /// error anywhere (docs/03-hard-constraints.md #34) — so `ShieldWriter`
    /// refuses the write rather than shipping a rule that looks armed and is not.
    /// The row has to say why, or the rule silently does nothing forever.
    static func capWarning(for rule: Rule) -> String? {
        guard let digest = rule.selection?.digest else { return nil }
        guard let first = digest.overflowingCollections.first else { return nil }
        let noun = collectionNoun(first.collection, plural: true)
        return "Too many \(noun): \(first.count) of \(GateLimits.maxTokensPerShieldCollection). "
            + "Gate won't apply this rule until you remove some."
    }

    /// User-facing noun for a token collection. `TokenCollection`'s raw values
    /// are wire names, not copy.
    static func collectionNoun(_ collection: TokenCollection, plural: Bool) -> String {
        switch collection {
        case .applications: plural ? "apps" : "app"
        case .categories: plural ? "categories" : "category"
        case .webDomains: plural ? "sites" : "site"
        }
    }

    private static func pluralized(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

#if DEBUG
#Preview("Rule rows") {
    let now = Date()
    let morning = RuleSchedule(
        start: TimeOfDay(hour: 9, minute: 0),
        end: TimeOfDay(hour: 17, minute: 30),
        weekdays: .workweek
    )

    return VStack(spacing: GateTheme.Spacing.s) {
        RuleRow(
            rule: Rule(name: "Deep work", mode: .blocklist, isEnabled: true,
                       schedule: morning,
                       selection: SelectionRef(id: UUID(),
                                               digest: SelectionDigest(applicationCount: 12,
                                                                       categoryCount: 2)),
                       createdAt: now, updatedAt: now),
            now: now,
            hasPendingChange: true,
            disablingGoesThroughLock: true,
            onSetEnabled: { _ in },
            onSelect: {}
        )

        RuleRow(
            rule: Rule(name: "Evenings", mode: .allowlist, isEnabled: true,
                       selection: SelectionRef(id: UUID(),
                                               digest: SelectionDigest(applicationCount: 3)),
                       createdAt: now, updatedAt: now),
            now: now,
            onSetEnabled: { _ in }
        )

        RuleRow(
            rule: Rule(name: "", mode: .blocklist, isEnabled: true,
                       createdAt: now, updatedAt: now),
            now: now,
            onSetEnabled: { _ in }
        )

        RuleRow(
            rule: Rule(name: "Weekend socials", mode: .blocklist, isEnabled: false,
                       selection: SelectionRef(id: UUID(),
                                               digest: SelectionDigest(applicationCount: 62)),
                       createdAt: now, updatedAt: now),
            now: now,
            onSetEnabled: { _ in }
        )
    }
    .padding(GateTheme.Spacing.l)
    .gateCard()
    .padding(GateTheme.Spacing.l)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(GateTheme.background)
}
#endif
