//
//  TotalActivityView.swift
//  GateReport
//
//  Build plan: docs/06-build-plan.md step 4.4.
//  Rendered by: docs/04-product-spec.md V2-5 (Stats — display only).
//
//  Plain SwiftUI over a plain value type. No `Task`, no `@StateObject`, no
//  `onAppear` work, no timers: everything on screen was computed before this
//  view was constructed (``TotalActivityReport/makeConfiguration(representing:)``),
//  and this file only lays it out.
//
//  WHAT THIS VIEW ACTUALLY IS
//  --------------------------
//  It runs in the report extension's process and is composited into the host
//  app's view hierarchy as a remote view. Three consequences shape the layout:
//
//  1. **The host owns the frame.** A remote view has no intrinsic size the host
//     can read, so `DeviceActivityReport` must be given an explicit frame by the
//     Stats screen — a report view with no frame is the single most common cause
//     of "my report is blank". Everything here is therefore width-flexible and
//     leading-aligned, and nothing assumes a minimum height.
//  2. **The host owns scrolling.** There is deliberately no `ScrollView` here.
//     The content is bounded (at most `UsageAccumulator.maxApplicationRows`
//     rows), and a scroll view inside a remote view inside the app's own scroll
//     view is a gesture conflict, not a feature.
//  3. **The environment does not cross the process boundary.** Nothing the app
//     puts in its SwiftUI environment — theme objects, tints, injected models —
//     is visible here. Colour therefore comes from semantic system styles, which
//     *do* resolve correctly because the trait environment (light/dark, Dynamic
//     Type, accessibility contrast) is forwarded. That is also why the root has
//     no opaque background: it sits on whatever the Stats screen is painted
//     with, and an assumed background would show as a mismatched rectangle.
//
//  NO CHARTS
//  ---------
//  docs/04-product-spec.md, *Explicitly OUT of v1*: "no charts". Text rows only —
//  no bars, no rings, no Swift Charts. That is a product decision first (a
//  commitment device should not be a dashboard you enjoy visiting) and a
//  resource decision second: this process runs under an undocumented memory
//  ceiling, reported at both 50 MB and 100 MB *(unverified,
//  docs/02-api-reference.md §14)*, and a charting framework is the last thing
//  that should be spending it.
//
//  WRITES: NONE. See the header of GateReportExtension.swift.
//

import Foundation
import SwiftUI

// MARK: - ReportTheme

/// The report extension's visual constants.
///
/// Deliberately local. `KernelUI/Theme.swift` is the app-side design system, and
/// this target links `GateKernelUI` — but a remote view cannot read the host's
/// environment (see the file header), so tokens have to be resolved here from
/// values that survive the process hop. These are semantic system styles plus a
/// handful of metrics, so the two sides stay consistent by both deferring to the
/// system rather than by sharing a colour literal that only one of them can
/// resolve. This enum is the one place to change if that ever needs revisiting.
private enum ReportTheme {
    static let contentPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 22
    static let metricSpacing: CGFloat = 12
    static let metricMinimumWidth: CGFloat = 120
    static let rowVerticalPadding: CGFloat = 8

    static var primaryText: Color { .primary }
    static var secondaryText: Color { .secondary }

    /// Rounded, and sized from a text style so it tracks Dynamic Type instead of
    /// clipping at the larger accessibility sizes.
    static var heroFont: Font { .system(.largeTitle, design: .rounded, weight: .semibold) }
    static var eyebrowFont: Font { .caption.weight(.semibold) }
}

// MARK: - ReportFormat

/// Formatting helpers.
///
/// `Duration.UnitsFormatStyle` rather than a `DateComponentsFormatter`: the
/// formatter is a reference type that is not `Sendable`, so sharing one would
/// mean a main-actor-isolated global or a fresh allocation per row, and this
/// value-type style needs neither.
private enum ReportFormat {

    /// `11_520` → `"3 hr 12 min"`.
    ///
    /// Anything under a minute collapses to `"< 1 min"` rather than `"0 min"`:
    /// iOS counts activity in seconds and "0 min" next to a non-zero pickup
    /// count reads as a bug.
    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        guard value >= 60 else {
            return value <= 0 ? "0 min" : "< 1 min"
        }
        return Duration.seconds(value).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)
        )
    }

    /// The period the numbers describe, in the shortest honest form.
    ///
    /// A daily segment's `DateInterval` ends at midnight of the *following* day,
    /// so the last second is trimmed before formatting — otherwise a single day
    /// renders as a two-day range.
    static func period(_ interval: DateInterval) -> String {
        let calendar = Calendar.current
        let start = interval.start
        let end = interval.duration > 1 ? interval.end.addingTimeInterval(-1) : interval.end

        if calendar.isDate(start, inSameDayAs: end) {
            if calendar.isDateInToday(start) { return "Today" }
            if calendar.isDateInYesterday(start) { return "Yesterday" }
            return start.formatted(date: .abbreviated, time: .omitted)
        }

        let from = start.formatted(date: .abbreviated, time: .omitted)
        let to = end.formatted(date: .abbreviated, time: .omitted)
        return "\(from) – \(to)"
    }
}

// MARK: - TotalActivityView

/// The report's one screen: a headline total, a few session metrics, and the
/// most-used applications.
struct TotalActivityView: View {

    let configuration: TotalActivityConfiguration

    init(configuration: TotalActivityConfiguration) {
        self.configuration = configuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ReportTheme.sectionSpacing) {
            header

            if !metrics.isEmpty {
                metricsGrid(metrics)
            }

            applicationSection

            // Unconditional: `footnotes` always ends with the privacy line.
            footnoteBlock
        }
        .padding(ReportTheme.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Screen time")
                .font(ReportTheme.eyebrowFont)
                .textCase(.uppercase)
                .foregroundStyle(ReportTheme.secondaryText)

            Text(ReportFormat.duration(configuration.totalDuration))
                .font(ReportTheme.heroFont)
                .monospacedDigit()
                .foregroundStyle(ReportTheme.primaryText)
                // The hero number is the one thing that must never truncate.
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            if let interval = configuration.coveredInterval {
                Text(ReportFormat.period(interval))
                    .font(.footnote)
                    .foregroundStyle(ReportTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Metrics

    private struct Metric: Identifiable, Hashable {
        let id: String
        let title: String
        let value: String
    }

    /// Only metrics the system actually reported. A row of dashes teaches the
    /// user nothing except that the screen is unreliable.
    private var metrics: [Metric] {
        var result: [Metric] = []

        if configuration.totalPickups > 0 {
            result.append(
                Metric(id: "pickups", title: "Pickups", value: configuration.totalPickups.formatted())
            )
        }
        if let longest = configuration.longestSession, longest > 0 {
            result.append(
                Metric(id: "longest", title: "Longest stretch", value: ReportFormat.duration(longest))
            )
        }
        if let first = configuration.firstPickup {
            result.append(
                Metric(
                    id: "first",
                    title: "First pickup",
                    value: first.formatted(date: .omitted, time: .shortened)
                )
            )
        }
        if configuration.totalNotifications > 0 {
            result.append(
                Metric(
                    id: "notifications",
                    title: "Notifications",
                    value: configuration.totalNotifications.formatted()
                )
            )
        }

        return result
    }

    /// Adaptive rather than a fixed `HStack`: the host decides this view's width,
    /// and at accessibility text sizes two of these labels will not share a line.
    private func metricsGrid(_ metrics: [Metric]) -> some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: ReportTheme.metricMinimumWidth),
                    spacing: ReportTheme.metricSpacing,
                    alignment: .leading
                )
            ],
            alignment: .leading,
            spacing: ReportTheme.metricSpacing
        ) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.title)
                        .font(.caption)
                        .foregroundStyle(ReportTheme.secondaryText)
                    Text(metric.value)
                        .font(.headline)
                        .monospacedDigit()
                        .foregroundStyle(ReportTheme.primaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Applications

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Most used")
                .font(ReportTheme.eyebrowFont)
                .textCase(.uppercase)
                .foregroundStyle(ReportTheme.secondaryText)

            if configuration.applications.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Rows carry their own identity, so this walks the array
                    // directly rather than through `enumerated()` — a `ForEach`
                    // over index/element tuples cannot destructure its closure
                    // parameter, and the separator does not need an index.
                    ForEach(configuration.applications) { usage in
                        ApplicationRow(usage: usage)
                        if usage.id != configuration.applications.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// Two genuinely different situations, two different sentences.
    ///
    /// "The filter returned no segments" is an iOS-is-not-ready problem and is
    /// extremely common on a fresh install; "segments came back empty" means the
    /// phone really was not used. Collapsing them into one message sends users
    /// hunting for a bug that is not there.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if configuration.hasNoSegments {
                Text("Nothing to show yet.")
                    .font(.body)
                    .foregroundStyle(ReportTheme.primaryText)
                Text(
                    """
                    iOS reports Screen Time on its own schedule. A new install, or a device \
                    that has not been unlocked in a while, can come back empty for a few hours.
                    """
                )
                    .font(.footnote)
                    .foregroundStyle(ReportTheme.secondaryText)
            } else {
                Text("No recorded app activity.")
                    .font(.body)
                    .foregroundStyle(ReportTheme.primaryText)
                Text("Nothing in this period was used long enough for iOS to count it.")
                    .font(.footnote)
                    .foregroundStyle(ReportTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Footnotes

    private var footnotes: [String] {
        var lines: [String] = []

        if configuration.isApplicationListTruncated {
            lines.append(
                "Showing \(configuration.applications.count) of \(configuration.distinctApplicationCount) apps."
            )
        }
        if configuration.isTallyCapped {
            lines.append(
                """
                This period had more apps than Gate lists individually. Their time is \
                still counted in the total above.
                """
            )
        }
        if configuration.hasAnonymousApplications {
            lines.append("iOS does not share app names with Gate on this screen, so some rows are numbered instead.")
        }

        // Always last, and always present: the honest framing this product is
        // built on (docs/03-hard-constraints.md #30). The user is looking at
        // numbers their own app is structurally unable to read, and saying so is
        // the difference between a privacy guarantee and a privacy claim.
        lines.append("Apple measures this and iOS draws it here. Gate itself never sees these numbers.")

        return lines
    }

    private var footnoteBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(footnotes, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(ReportTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ApplicationRow

/// One application's line.
private struct ApplicationRow: View {

    let usage: TotalActivityConfiguration.ApplicationUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.displayName)
                    .font(.body)
                    // A placeholder name is drawn in the secondary colour so a
                    // numbered row never reads as a real app called "App 3".
                    .foregroundStyle(usage.isNameResolved ? ReportTheme.primaryText : ReportTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(ReportTheme.secondaryText)
                }
            }

            Spacer(minLength: 8)

            Text(ReportFormat.duration(usage.duration))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(ReportTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.vertical, ReportTheme.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        var parts: [String] = []
        if usage.pickups > 0 {
            parts.append("\(usage.pickups.formatted()) pickups")
        }
        if usage.notifications > 0 {
            parts.append("\(usage.notifications.formatted()) notifications")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Previews

#if DEBUG

private extension TotalActivityConfiguration {

    /// Sample data for previews only.
    ///
    /// Previews are the only way to see this view without a physical device:
    /// there is no Simulator support for any part of this stack
    /// (docs/03-hard-constraints.md #11), so a real report cannot be rendered in
    /// Xcode at all. The sample deliberately mixes a resolved name, a
    /// bundle-derived name and two anonymous rows, because which of those the
    /// device produces is itself unverified — see the labelling rules in
    /// `TotalActivityReport.swift`.
    static var previewSample: TotalActivityConfiguration {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)

        return TotalActivityConfiguration(
            totalDuration: 4 * 3600 + 12 * 60,
            applicationDuration: 3 * 3600 + 50 * 60,
            totalPickups: 74,
            totalNotifications: 212,
            longestSession: 52 * 60,
            firstPickup: startOfDay.addingTimeInterval(7 * 3600 + 12 * 60),
            coveredInterval: DateInterval(start: startOfDay, duration: 24 * 3600),
            applications: [
                ApplicationUsage(
                    id: "a1b2c3d4e5f60718",
                    displayName: "Instagram",
                    isNameResolved: true,
                    duration: 88 * 60,
                    pickups: 31,
                    notifications: 96
                ),
                ApplicationUsage(
                    id: "b2c3d4e5f6071829",
                    displayName: "Slack",
                    isNameResolved: true,
                    duration: 64 * 60,
                    pickups: 18,
                    notifications: 74
                ),
                ApplicationUsage(
                    id: "c3d4e5f607182930",
                    displayName: "Social Networking app 1",
                    isNameResolved: false,
                    duration: 41 * 60,
                    pickups: 12,
                    notifications: 0
                ),
                ApplicationUsage(
                    id: "d4e5f60718293041",
                    displayName: "App 2",
                    isNameResolved: false,
                    duration: 37 * 60,
                    pickups: 4,
                    notifications: 42
                )
            ],
            distinctApplicationCount: 23,
            isTallyCapped: false,
            segmentCount: 1
        )
    }

    /// The state a fresh install shows for its first few hours.
    static var previewEmpty: TotalActivityConfiguration { .empty }
}

#Preview("Total activity") {
    TotalActivityView(configuration: .previewSample)
}

#Preview("No data yet") {
    TotalActivityView(configuration: .previewEmpty)
}

#endif
