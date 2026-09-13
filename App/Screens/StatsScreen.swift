//
//  StatsScreen.swift
//  Gate
//
//  Hosts the one `DeviceActivityReport` v1 ships (docs/04-product-spec.md V2-5,
//  rendered by `Extensions/Report/`), plus Gate's own counters.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  TWO KINDS OF NUMBER ON ONE SCREEN, NEVER MIXED
//  ─────────────────────────────────────────────────────────────────────────────
//  The `DeviceActivityReport` below is a **remote view**. It renders in
//  `GateReport.appex`, inside a sandbox Apple has confirmed is intentional, and
//  **nothing it computes can ever reach this process** — App Group `UserDefaults`
//  writes are silently dropped, App Group file writes fail, HTTP is blocked,
//  local notifications, `UIPasteboard` and iCloud KVS are all confirmed closed
//  (docs/03-hard-constraints.md #30, docs/02-api-reference.md §11).
//
//  So the two halves of this screen are physically separate: Gate cannot add its
//  grant count to Apple's screen-time total, cannot sort apps by either, and
//  cannot show "you spent X minutes in apps you blocked". Every number under
//  "Gate's own data" was written by Gate, and the heading says so.
//
//  **One report view per screen.** Three or more on one screen is a reported
//  crash threshold (docs/02-api-reference.md §11), and the view has **no
//  intrinsic size** — a remote view that is not given a frame renders as nothing
//  at all, which looks exactly like a broken extension.
//

import DeviceActivity
import SwiftUI

import GateKernel
import GateKernelUI

struct StatsScreen: View {

    @Environment(AppModel.self) private var model

    private enum Window: String, CaseIterable, Identifiable {
        case today
        case week

        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: "Today"
            case .week: "Last 7 days"
            }
        }
    }

    @State private var window: Window = .today

    /// Built from ``interval``, which is a whole calendar day (or seven), so the
    /// value is stable for the whole day even though the property is recomputed
    /// on every render. That stability is the point: a `DeviceActivityReport` is
    /// a remote view, and handing it a filter that differs on every layout pass
    /// is how the report ends up blank.
    private var filter: DeviceActivityFilter {
        DeviceActivityFilter(
            segment: .daily(during: interval),
            devices: nil,
            applications: [],
            categories: [],
            webDomains: []
        )
    }

    private var interval: DateInterval {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: now, duration: 24 * 60 * 60)
        switch window {
        case .today:
            return today
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: today.start) ?? today.start
            return DateInterval(start: start, end: today.end)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GateTheme.Spacing.xl) {
                Picker("Window", selection: $window) {
                    ForEach(Window.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                appleReport
                gateData
            }
            .padding(GateTheme.Spacing.l)
        }
        .background(GateTheme.background)
        .navigationTitle("Screen time")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Apple's numbers

    private var appleReport: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
            SectionHeading(
                title: "From iOS",
                detail: "Rendered by iOS inside a sandbox. Gate can show you this and "
                    + "nothing more — it cannot read, store or export a single number of it."
            )

            // The host owns the frame *and* the scrolling; the view inside adds
            // neither. `.totalActivity` is matched against the report extension's
            // scene by raw string, so a typo renders blank with no error
            // anywhere — which is why it comes from `Kernel/Identifiers.swift`.
            DeviceActivityReport(.totalActivity, filter: filter)
                .frame(height: 420)
                .frame(maxWidth: .infinity)
                .clipShape(
                    RoundedRectangle(cornerRadius: GateTheme.Radius.card, style: .continuous)
                )
        }
    }

    // MARK: Gate's numbers

    private var gateData: some View {
        let now = Date()
        let budget = model.grantBudget(at: now)
        let active = model.activeGrants(at: now)
        let recentGrants = model.state.grants
            .sorted { $0.issuedAt > $1.issuedAt }
            .prefix(5)

        return VStack(alignment: .leading, spacing: GateTheme.Spacing.m) {
            SectionHeading(
                title: "Gate's own data",
                detail: "Written by Gate, on this device. Deliberately kept apart from the "
                    + "numbers above: the two come from different processes and cannot be "
                    + "combined."
            )

            HStack(spacing: GateTheme.Spacing.m) {
                Metric(value: "\(budget.spent)", label: "unblocks used today")
                Metric(value: "\(budget.remaining)", label: "left")
                Metric(value: "\(active.count)", label: "live now")
            }

            if let report = model.lastReport, report.inbox.bypassAttempts > 0 {
                Text("\(report.inbox.bypassAttempts) shield taps ended in \u{201C}Not now\u{201D} "
                     + "since the last time you opened Gate. That is the product working.")
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textSecondary)
            }

            if !recentGrants.isEmpty {
                VStack(alignment: .leading, spacing: GateTheme.Spacing.s) {
                    Text("Why you asked")
                        .font(GateTheme.Typography.headline)
                        .foregroundStyle(GateTheme.textPrimary)

                    ForEach(Array(recentGrants)) { grant in
                        VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                            Text(grant.reason?.isEmpty == false
                                 ? "\u{201C}\(grant.reason ?? "")\u{201D}"
                                 : "No reason recorded")
                                .font(GateTheme.Typography.body)
                                .foregroundStyle(GateTheme.textPrimary)
                            Text("\(model.ruleNames[grant.ruleID] ?? "A deleted rule") \u{00B7} "
                                 + grant.issuedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(GateTheme.Typography.footnote)
                                .foregroundStyle(GateTheme.textTertiary)
                        }
                    }

                    // `GrantEngine.compacted` strips token bytes from terminal
                    // grants and caps history at 24 records, so this list is
                    // short by construction and `state.plist` stays under 8 KB.
                    Text("Gate keeps the last few, then forgets them.")
                        .font(GateTheme.Typography.footnote)
                        .foregroundStyle(GateTheme.textTertiary)
                }
                .gateCard()
            }
        }
    }
}

// MARK: - Pieces

private struct SectionHeading: View {

    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
            Text(title)
                .font(GateTheme.Typography.headline)
                .foregroundStyle(GateTheme.textPrimary)
            Text(detail)
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Metric: View {

    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
            Text(value)
                .font(GateTheme.Typography.numericLarge)
                .foregroundStyle(GateTheme.textPrimary)
            Text(label)
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .gateCard(padding: GateTheme.Spacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}
