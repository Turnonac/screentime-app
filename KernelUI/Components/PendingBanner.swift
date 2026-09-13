//
//  PendingBanner.swift
//  GateKernelUI
//
//  The persistent "Pending changes (2) — unlocks in 12m 04s" banner, with the
//  cancel affordance (docs/04-product-spec.md V1-4; docs/06-build-plan.md step
//  5.4).
//
//  This banner *is* the product. Everything else in v1 exists to make it
//  usable: it is the visible form of "changing your mind costs time." Three
//  things follow from that, and all three are load-bearing.
//
//  1. **Cancelling is free and must look free.** Cancelling a queued loosening
//     withdraws it — the strictest possible outcome — so `Ratchet` classifies it
//     as a tightening and applies it synchronously. The banner says so in words,
//     because a "Cancel" button next to a countdown reads like the *expensive*
//     action to anyone who has used one of these apps before.
//
//  2. **A password-only Lock has no countdown, and the banner must not invent
//     one.** `LockPolicy.earliestApplyDate(from:)` returns `nil` for
//     `LockKind.password`, so such a change never ripens on time; it is released
//     by the passphrase or not at all. ``ReleasePaths/available(under:)`` is the
//     single source of truth for which sentence to show.
//
//  3. **A countdown reaching zero does not apply anything.** Ripe changes are
//     folded into state by `Reconciler`, which runs on foreground and on monitor
//     callbacks (V1-10). The banner therefore tells its host the moment a
//     deadline passes (`onDeadlineElapsed`) rather than pretending the change
//     has landed.
//
//  Wording for `PendingChange.Operation` lives here, not in the kernel:
//  `Operation.debugSummary` is explicitly not user copy.
//

import Foundation
import SwiftUI

import GateKernel

// MARK: - PendingBanner

public struct PendingBanner: View {

    /// The V1-4 promise, stated where the user is deciding.
    public static let cancelIsFreeNote =
        "Cancelling is free and takes effect immediately \u{2014} it only ever makes Gate stricter."

    public var changes: [PendingChange]
    public var lock: LockPolicy

    /// Used only for ordering and for the ripe/not-ripe first render; the live
    /// part is a ``CountdownView`` running off each absolute deadline.
    public var now: Date

    /// Rule names by id, so the banner can say *Turn off "Deep work"* instead of
    /// *Turn off this rule*. Missing ids degrade to the generic phrasing rather
    /// than showing a UUID.
    public var ruleNames: [UUID: String]

    /// `nil` hides the cancel affordance (a read-only presentation).
    public var onCancel: ((PendingChange) -> Void)?

    /// Presented only when the Lock actually accepts a password.
    public var onEnterPassword: (() -> Void)?

    /// Fired once when the soonest deadline passes while the banner is visible —
    /// including immediately, if it had already passed when the banner appeared.
    /// The host should reconcile.
    public var onDeadlineElapsed: (() -> Void)?

    @State private var isExpanded = false
    @State private var didElapse = false

    public init(changes: [PendingChange],
                lock: LockPolicy,
                now: Date = Date(),
                ruleNames: [UUID: String] = [:],
                onCancel: ((PendingChange) -> Void)? = nil,
                onEnterPassword: (() -> Void)? = nil,
                onDeadlineElapsed: (() -> Void)? = nil) {
        self.changes = changes
        self.lock = lock
        self.now = now
        self.ruleNames = ruleNames
        self.onCancel = onCancel
        self.onEnterPassword = onEnterPassword
        self.onDeadlineElapsed = onDeadlineElapsed
    }

    // MARK: Body

    public var body: some View {
        // `.pending` filters out applied / cancelled / superseded changes, which
        // `GateState` keeps for 30 days as history.
        let open = PendingBanner.ordered(changes.pending)

        if open.isEmpty {
            // Not a zero-height card: nothing is pending, so nothing is shown.
            EmptyView()
        } else {
            banner(open)
        }
    }

    @ViewBuilder
    private func banner(_ open: [PendingChange]) -> some View {
        let deadline = PendingBanner.soonestDeadline(in: open)
        let paths = ReleasePaths.available(under: lock)
        // One change is always expanded: there is nothing to summarise.
        let showsDetail = isExpanded || open.count == 1

        VStack(alignment: .leading, spacing: GateTheme.Spacing.m) {
            header(count: open.count, deadline: deadline, paths: paths)

            if showsDetail {
                Divider().overlay(GateTheme.Palette.pending.opacity(0.30).color)

                VStack(alignment: .leading, spacing: GateTheme.Spacing.m) {
                    ForEach(open) { change in
                        row(change, paths: paths)
                    }
                }
            }

            footer(paths: paths)
        }
        .gateCard(
            fill: GateTheme.Palette.pending.opacity(0.10).color,
            stroke: GateTheme.Palette.pending.opacity(0.35).color
        )
        // A new soonest deadline (a change cancelled, another queued) re-arms the
        // elapsed latch so the next one is reported too.
        .onChange(of: deadline) { _, _ in
            didElapse = false
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(count: Int, deadline: Date?, paths: ReleasePaths) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GateTheme.Spacing.m) {
            Image(systemName: "lock.fill")
                .font(GateTheme.Typography.callout)
                .foregroundStyle(GateTheme.pending)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                Text(PendingBanner.headline(count: count))
                    .font(GateTheme.Typography.headline)
                    .foregroundStyle(GateTheme.textPrimary)

                headlineStatus(deadline: deadline, paths: paths)
            }

            Spacer(minLength: GateTheme.Spacing.s)

            if count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(GateTheme.Typography.chip)
                        .foregroundStyle(GateTheme.textSecondary)
                        .padding(GateTheme.Spacing.s)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isExpanded ? "Hide the pending changes"
                                                    : "Show the pending changes"))
            }
        }
    }

    @ViewBuilder
    private func headlineStatus(deadline: Date?, paths: ReleasePaths) -> some View {
        HStack(spacing: GateTheme.Spacing.xs) {
            // The *deadline* decides whether there is a countdown, not
            // `paths.hasCountdown`. A change carries the `earliestApplyAt` it was
            // stamped with, and `PendingChange.isRipe(at:)` — the thing
            // `Ratchet.releaseRipe` actually consults — reads only that. Switch
            // the Lock to password-only afterwards and the queued change still
            // ripens on time (a config-hash mismatch never invalidates a
            // deadline). `paths` decides only whether to offer the password.
            if let deadline, !didElapse {
                CountdownView(deadline: deadline,
                              prefix: "unlocks in",
                              elapsedText: PendingBanner.readyText) {
                    // Latch first: once this flips, the countdown leaves the tree,
                    // so the host cannot be asked to reconcile in a loop.
                    guard !didElapse else { return }
                    didElapse = true
                    onDeadlineElapsed?()
                }

                if paths.contains(.password) {
                    Text("\u{00B7} or use the password")
                }
            } else if deadline != nil {
                Text(PendingBanner.readyDetailText)
            } else if paths.contains(.password) {
                Text("Waiting on the partner password")
            } else {
                // No deadline and no password: nothing can release this. Usually a
                // change queued under a password-only Lock whose passphrase was
                // then cleared. Say so plainly rather than showing a countdown
                // that will never move.
                Text(PendingBanner.strandedText)
            }
        }
        .font(GateTheme.Typography.footnote)
        .foregroundStyle(GateTheme.textSecondary)
        .lineLimit(2)
    }

    // MARK: One change

    @ViewBuilder
    private func row(_ change: PendingChange, paths: ReleasePaths) -> some View {
        let summary = PendingChangeCopy.summary(
            of: change.operation,
            ruleName: change.ruleID.flatMap { ruleNames[$0] }
        )

        HStack(alignment: .firstTextBaseline, spacing: GateTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                Text(summary)
                    .font(GateTheme.Typography.callout)
                    .foregroundStyle(GateTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                rowDetail(change, paths: paths)
            }

            Spacer(minLength: GateTheme.Spacing.s)

            if let onCancel {
                Button("Cancel") {
                    onCancel(change)
                }
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.accent)
                .buttonStyle(.plain)
                // Eight "Cancel" buttons in a column are indistinguishable to
                // VoiceOver without this.
                .accessibilityLabel(Text("Cancel: \(summary)"))
                .accessibilityHint(Text("Cancelling is free and takes effect immediately"))
            }
        }
    }

    @ViewBuilder
    private func rowDetail(_ change: PendingChange, paths: ReleasePaths) -> some View {
        Group {
            if !change.isApplicable {
                // `Operation.unrecognized` — written by a newer build of Gate and
                // decoded leniently. It can be cancelled but never applied.
                Text("From a newer version of Gate. This build can't apply it \u{2014} cancelling still works.")
            } else if let applyAt = change.earliestApplyAt {
                // `.plain` so the detail line inherits the caption font applied
                // below; `.inline` would set its own and leave this one row of
                // the list a size larger than its neighbours.
                CountdownView(deadline: applyAt,
                              style: .plain,
                              prefix: "unlocks in",
                              elapsedText: PendingBanner.readyText)
            } else if paths.contains(.password) {
                Text("Released by the partner password")
            } else {
                Text(PendingBanner.strandedText)
            }
        }
        .font(GateTheme.Typography.caption)
        .foregroundStyle(GateTheme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(paths: ReleasePaths) -> some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
            if paths.contains(.password), let onEnterPassword {
                Button("Enter the partner password", action: onEnterPassword)
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.accent)
                    .buttonStyle(.plain)
            }

            Text(PendingBanner.cancelIsFreeNote)
                .font(GateTheme.Typography.caption)
                .foregroundStyle(GateTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Derivations

public extension PendingBanner {

    /// "Ready" the moment a deadline passes. Not "applied": `Reconciler` has to
    /// fold it in first (docs/04-product-spec.md V1-10).
    static let readyText = "ready"

    static let readyDetailText = "Ready \u{2014} applying it now"

    /// A change with no deadline, under a Lock that accepts no password — most
    /// often a change queued under a password-only Lock whose passphrase was
    /// later cleared. `isRipe(at:)` is false forever when `earliestApplyAt` is
    /// `nil`, so nothing will release it.
    ///
    /// The advice is deliberate: cancelling is free and re-queuing stamps the
    /// change with the Lock that is in force now, which is the only route back
    /// to a working deadline. It is also strictly the *stricter* path, so it
    /// cannot be used as a shortcut.
    static let strandedText =
        "Nothing will release this on its own. Cancel it and make the change again "
        + "to put it on the current Lock."

    static func headline(count: Int) -> String {
        count == 1 ? "Pending change" : "Pending changes (\(count))"
    }

    /// The earliest deadline among the changes, *including* ones already in the
    /// past.
    ///
    /// Deliberately not `Collection.nextDeadline(after:)`, which filters to
    /// strictly-future deadlines: that is the right answer for scheduling a
    /// backstop notification and the wrong one here, because it would make a ripe
    /// change vanish from the banner instead of reading "ready".
    static func soonestDeadline(in changes: [PendingChange]) -> Date? {
        changes.compactMap(\.earliestApplyAt).min()
    }

    /// Soonest first; changes with no deadline (password-only) last, since they
    /// are waiting on an action rather than on time.
    static func ordered(_ changes: [PendingChange]) -> [PendingChange] {
        changes.sorted { lhs, rhs in
            switch (lhs.earliestApplyAt, rhs.earliestApplyAt) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.requestedAt < rhs.requestedAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.requestedAt < rhs.requestedAt
            }
        }
    }
}

// MARK: - PendingChangeCopy

/// User-facing wording for a queued change.
///
/// `PendingChange.Operation.debugSummary` exists for logs and the debug screen
/// and says so; this is the copy a person reads. Keeping them apart means the
/// kernel never has to care about tone, and a change to the wording is never a
/// change to a persisted format.
///
/// Every phrase names the *loosening* direction, because that is the only
/// direction that queues: a tightening applies synchronously and never reaches
/// this banner (docs/04-product-spec.md V1-4). The two-way cases below are
/// spelled out anyway — with the ratchet switch off, representable tightenings
/// queue too.
public enum PendingChangeCopy {

    public static let unknownRuleName = "this rule"

    public static func summary(of operation: PendingChange.Operation,
                               ruleName: String? = nil) -> String {
        let name = quoted(ruleName)
        switch operation {
        case .disableRule:
            return "Turn off \(name)"

        case .deleteRule:
            return "Delete \(name)"

        case .replaceSelection(_, let selection):
            return selection == nil
                ? "Clear everything \(name) blocks"
                : "Change what \(name) blocks"

        case .setSchedule(_, let schedule):
            return schedule == nil
                ? "Let \(name) run without a schedule"
                : "Change the schedule for \(name)"

        case .setMode(_, let mode):
            switch mode {
            case .blocklist: return "Switch \(name) to a block-list"
            case .allowlist: return "Switch \(name) to an allow-list"
            }

        case .setLockDelay(let seconds):
            // Only a *decrease* queues; increasing the delay is a tightening and
            // applies immediately (V1-3's asymmetry).
            return "Shorten the Lock delay to \(GateCountdown.durationText(for: seconds))"

        case .setLockKind(let kind):
            return "Change the Lock to \(phrase(for: kind))"

        case .clearLockPassword:
            return "Remove the partner password"

        case .setRatchet(let enabled):
            return enabled ? "Turn the Ratchet on" : "Turn the Ratchet off"

        case .setInstallProtection(let enabled):
            // V1-8 "Solid": denyAppInstallation. Copy says what it is, never
            // more.
            return enabled
                ? "Stop new apps from being installed"
                : "Allow new apps to be installed again"

        case .revokeAuthorization:
            return "Turn off Gate's Screen Time access"

        case .unrecognized:
            return "A change made by a newer version of Gate"
        }
    }

    /// How a ``LockKind`` reads in a sentence.
    public static func phrase(for kind: LockKind) -> String {
        switch kind {
        case .delay: "a waiting period"
        case .password: "a partner password"
        case .both: "a waiting period or a partner password"
        }
    }

    /// A rule name in typographic quotes, or the generic fallback.
    public static func quoted(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return unknownRuleName }
        return "\u{201C}\(trimmed)\u{201D}"
    }
}

#if DEBUG
#Preview("Pending changes") {
    let now = Date()
    let ruleID = UUID()
    let names = [ruleID: "Deep work"]
    let lock = LockPolicy(kind: .delay, delay: 15 * 60, updatedAt: now)

    let queued = [
        PendingChange(operation: .disableRule(ruleID: ruleID),
                      requestedAt: now.addingTimeInterval(-3 * 60),
                      earliestApplyAt: now.addingTimeInterval(12 * 60 + 4),
                      lockConfigHash: lock.configHash),
        PendingChange(operation: .setLockDelay(seconds: 5 * 60),
                      requestedAt: now.addingTimeInterval(-60),
                      earliestApplyAt: now.addingTimeInterval(2 * 3_600),
                      lockConfigHash: lock.configHash)
    ]

    return ScrollView {
        VStack(spacing: GateTheme.Spacing.l) {
            PendingBanner(changes: queued, lock: lock, now: now,
                          ruleNames: names, onCancel: { _ in })

            PendingBanner(changes: [queued[0]], lock: lock, now: now,
                          ruleNames: names, onCancel: { _ in })

            PendingBanner(
                changes: [PendingChange(operation: .clearLockPassword,
                                        requestedAt: now,
                                        earliestApplyAt: nil,
                                        lockConfigHash: "")],
                lock: LockPolicy(kind: .password, updatedAt: now),
                now: now,
                onCancel: { _ in }
            )
        }
        .padding(GateTheme.Spacing.l)
    }
    .background(GateTheme.background)
}
#endif
