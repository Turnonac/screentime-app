//
//  TotalActivityReport.swift
//  GateReport
//
//  Build plan: docs/06-build-plan.md step 4.4.
//
//  The `DeviceActivityReportScene` for `DeviceActivityReport.Context.totalActivity`,
//  the value type it produces, and the streaming aggregator that produces it.
//
//  WHY THE AGGREGATION LOOKS LIKE THIS
//  -----------------------------------
//  `makeConfiguration(representing:)` is handed a three-level tree of async
//  sequences (docs/02-api-reference.md §11):
//
//      DeviceActivityResults<DeviceActivityData>          one per (user, device)
//        └── .activitySegments  → ActivitySegment         one per filter bucket
//              └── .categories  → CategoryActivity        one per app category
//                    └── .applications → ApplicationActivity
//                    └── .webDomains   → WebDomainActivity
//
//  There is **no flat top-level application list**: per-app numbers are reachable
//  only by descending through categories. Every level is a separate
//  `AsyncSequence`, so every level needs its own `for await`.
//
//  Apple's own sample writes this as
//  `await data.flatMap { $0.activitySegments }.reduce(0, …)`. That is a fine
//  demo and a bad idea here: the combinators buffer, the filter the app installs
//  can span a week of hourly segments, and *"materialising everything into arrays
//  is the main cause of black-screen terminations"* (docs/02-api-reference.md
//  §11), against a memory ceiling Apple has never documented — 50 MB and 100 MB
//  are both reported *(unverified, §14)*. So this file streams: nested
//  `for await`, nothing retained per record.
//
//  The one thing that *is* retained is `UsageAccumulator.tallies`, and its size
//  is the number of **distinct applications the user has opened**, not the number
//  of records in the stream. A week of hourly segments is ~168 segments × ~20
//  categories × ~n apps of records folding into at most a few hundred tally
//  entries. It is hard-capped anyway
//  (`UsageAccumulator.maxTrackedApplications`) so that no data set can make
//  this process grow without bound — the cap is visible in the UI rather than
//  silent, because an undercount the user cannot see is worse than an ugly
//  footnote.
//
//  WEB DOMAINS ARE NOT WALKED
//  --------------------------
//  `CategoryActivity.webDomains` exists, but docs/02-api-reference.md §11 lists
//  the members of `ApplicationActivity` and does **not** list the members of
//  `WebDomainActivity`. Rather than guess at a symbol the authoritative reference
//  does not pin down, v1 reports applications only; browser time still lands in
//  the browser's own application row and in the segment total, so nothing is lost
//  from the headline number. Web reporting is a v2 item, gated on confirming that
//  shape against the SDK on device — and worth little in v1 anyway, since web
//  blocking is whole-domain only (docs/03-hard-constraints.md #26).
//
//  WRITES: NONE. See the header of GateReportExtension.swift.
//

import DeviceActivity
import Foundation
import ManagedSettings
import SwiftUI
import os

import GateKernel
import GateKernelUI

/// Computed, not stored: matches the convention in the other three extensions.
private var reportLog: Logger {
    Logger(subsystem: GateID.Subsystem.report, category: "totalActivity")
}

// Shorthand for the nested SDK types this file walks. Spelled out once here so
// the aggregation below reads as the tree it is walking.
private typealias ActivitySegment = DeviceActivityData.ActivitySegment
private typealias CategoryActivity = DeviceActivityData.CategoryActivity
private typealias ApplicationActivity = DeviceActivityData.ApplicationActivity

// MARK: - TotalActivityConfiguration

/// Everything ``TotalActivityView`` renders, and nothing else.
///
/// This type is the boundary between the async aggregation and SwiftUI. It holds
/// only `String`, `Int`, `Double`, `Bool` and `Date` — no `Application`, no
/// `ApplicationToken`, no SDK reference type — which makes it trivially
/// `Sendable` and, more importantly, makes it impossible for a later edit to
/// carry a live SDK handle onto the main actor and hold the daemon's data alive
/// while SwiftUI diffs a view.
///
/// It is also, by construction, *the whole of what leaves the aggregation*. That
/// is worth stating because of where it cannot go: nothing here can be written
/// to the App Group, posted, uploaded or logged (docs/03-hard-constraints.md
/// #30). This value is born, rendered, and discarded inside one extension
/// process.
struct TotalActivityConfiguration: Sendable, Equatable, Hashable {

    /// One row of the "most used" list.
    struct ApplicationUsage: Sendable, Equatable, Hashable, Identifiable {
        /// Stable across renders: the token fingerprint where one is available,
        /// otherwise the bundle identifier, otherwise arrival order. Used only
        /// as a SwiftUI `ForEach` identity.
        let id: String
        /// What to draw. Never empty — see the labelling rules in `UsageAccumulator`.
        let displayName: String
        /// `false` when ``displayName`` is a positional placeholder ("App 3")
        /// because iOS withheld the real name. The view says so out loud rather
        /// than letting the user think Gate mislabelled their apps.
        let isNameResolved: Bool
        let duration: TimeInterval
        let pickups: Int
        let notifications: Int

        init(
            id: String,
            displayName: String,
            isNameResolved: Bool,
            duration: TimeInterval,
            pickups: Int,
            notifications: Int
        ) {
            self.id = id
            self.displayName = displayName
            self.isNameResolved = isNameResolved
            self.duration = duration
            self.pickups = pickups
            self.notifications = notifications
        }
    }

    /// Sum of every segment's `totalActivityDuration`.
    ///
    /// This is the headline number and it is **not** the sum of the rows below:
    /// segment totals include activity that never resolves to an application
    /// row, and the row list is truncated to the most-used few.
    let totalDuration: TimeInterval
    /// Sum of every per-application duration seen, including apps that did not
    /// survive into ``applications``.
    let applicationDuration: TimeInterval
    /// Application pickups plus the segments' `totalPickupsWithoutApplicationActivity`.
    let totalPickups: Int
    let totalNotifications: Int
    /// Longest single stretch of use in any segment, if the system reported one.
    let longestSession: TimeInterval?
    /// Earliest pickup across all segments, if the system reported one.
    let firstPickup: Date?
    /// Union of the segment intervals actually returned — i.e. the period this
    /// screen is describing. `nil` when no segment came back at all.
    let coveredInterval: DateInterval?
    /// Most-used applications, longest first, already truncated for display.
    let applications: [ApplicationUsage]
    /// How many distinct applications were tallied (may exceed
    /// `applications.count`, and is itself capped when ``isTallyCapped``).
    let distinctApplicationCount: Int
    /// `true` when the distinct-application hard cap was hit and some apps were
    /// never tallied at all. Surfaced in the UI; never silent.
    let isTallyCapped: Bool
    /// Number of segments the filter produced. Diagnostic only — a filter that
    /// returns zero segments and a device with zero usage look identical in every
    /// other field, and they need different copy.
    let segmentCount: Int

    init(
        totalDuration: TimeInterval = 0,
        applicationDuration: TimeInterval = 0,
        totalPickups: Int = 0,
        totalNotifications: Int = 0,
        longestSession: TimeInterval? = nil,
        firstPickup: Date? = nil,
        coveredInterval: DateInterval? = nil,
        applications: [ApplicationUsage] = [],
        distinctApplicationCount: Int = 0,
        isTallyCapped: Bool = false,
        segmentCount: Int = 0
    ) {
        self.totalDuration = totalDuration
        self.applicationDuration = applicationDuration
        self.totalPickups = totalPickups
        self.totalNotifications = totalNotifications
        self.longestSession = longestSession
        self.firstPickup = firstPickup
        self.coveredInterval = coveredInterval
        self.applications = applications
        self.distinctApplicationCount = distinctApplicationCount
        self.isTallyCapped = isTallyCapped
        self.segmentCount = segmentCount
    }

    /// The state the system hands back constantly: authorised, filtered, and
    /// genuinely nothing to say yet.
    static let empty = TotalActivityConfiguration()

    /// `true` when there is no number worth drawing.
    var hasActivity: Bool {
        totalDuration > 0 || totalPickups > 0 || !applications.isEmpty
    }

    /// `true` when the filter returned no segments at all, as opposed to
    /// returning segments that are all zero. The first means "iOS has nothing
    /// for this period"; the second means "you really did not use the phone".
    var hasNoSegments: Bool { segmentCount == 0 }

    /// `true` when at least one row is a positional placeholder.
    var hasAnonymousApplications: Bool {
        applications.contains { !$0.isNameResolved }
    }

    /// `true` when the list shown is a strict subset of what was tallied.
    var isApplicationListTruncated: Bool {
        distinctApplicationCount > applications.count
    }
}

// MARK: - TotalActivityReport

/// The scene bound to ``DeviceActivityReport/Context/totalActivity``.
///
/// The system matches this scene to the app's `DeviceActivityReport(.totalActivity,
/// filter:)` view by the context's raw string, so the name must come from the one
/// place that owns it — `Kernel/Identifiers.swift`, which spells it
/// `"gate.totalActivity"`. A literal here that drifted by one character would
/// render an empty rectangle with no error anywhere.
struct TotalActivityReport: DeviceActivityReportScene {

    /// Computed rather than stored, mirroring `Kernel/Identifiers.swift`:
    /// `DeviceActivityReport` is `@MainActor`, so a stored property of its nested
    /// `Context` type risks inheriting that isolation in a type whose
    /// `makeConfiguration(representing:)` is a non-isolated `async` requirement.
    /// `Context` wraps a `String`, so rebuilding it per access costs nothing.
    var context: DeviceActivityReport.Context { .totalActivity }

    /// Supplied by ``GateReportExtension``.
    ///
    /// Spelled exactly as the protocol declares it in docs/02-api-reference.md
    /// §11 — `var content: (Self.Configuration) -> Self.Content { get }`, with no
    /// `@Sendable`. A property witness has to match its requirement's type, so
    /// decorating this one to satisfy strict concurrency would stop satisfying
    /// the requirement. Nothing is captured by the closure the extension passes,
    /// so there is nothing to make concurrency-safe in the first place.
    let content: (TotalActivityConfiguration) -> TotalActivityView

    init(content: @escaping (TotalActivityConfiguration) -> TotalActivityView) {
        self.content = content
    }

    /// Walks the result tree once, retaining nothing per record.
    ///
    /// Cancellation is checked per segment: the host tears this extension down
    /// when the report view scrolls away or the app backgrounds, and a walk that
    /// ignores that keeps a dying process busy against an undocumented memory
    /// ceiling. A cancelled walk returns what it has rather than throwing — the
    /// view is about to be discarded either way, and a partial total is never
    /// shown long enough to mislead.
    func makeConfiguration(
        representing data: DeviceActivityResults<DeviceActivityData>
    ) async -> TotalActivityConfiguration {
        reportLog.debug("aggregation started")

        var accumulator = UsageAccumulator()
        var wasCancelled = false

        // LEVEL 1 — one element per (user, device) the filter matched. Summed,
        // not deduplicated: `DeviceActivityFilter.devices` is what narrows this,
        // and it is the app's decision, made in the filter it passes.
        results: for await datum in data {
            // LEVEL 2 — one segment per filter bucket (.daily / .hourly / .weekly).
            for await segment in datum.activitySegments {
                if Task.isCancelled {
                    wasCancelled = true
                    break results
                }
                accumulator.observe(segment: segment)

                // LEVEL 3 — categories. There is no flat application list; this
                // hop is mandatory (docs/02-api-reference.md §11).
                for await category in segment.categories {
                    // Resolved once per category, not once per application.
                    // `ActivityCategory.localizedDisplayName` is documented as
                    // optional (§5) and is the fallback label for applications
                    // whose own name iOS withholds.
                    let categoryName = category.category.localizedDisplayName

                    // LEVEL 4 — per application.
                    for await application in category.applications {
                        accumulator.observe(application: application, categoryName: categoryName)
                    }

                    // `category.webDomains` is deliberately not walked; see the
                    // file header.
                }
            }
        }

        if wasCancelled {
            reportLog.notice("aggregation cancelled by host")
        }
        reportLog.debug("aggregation finished")

        // Counts and durations are deliberately absent from every log line in
        // this target: `GateID.Subsystem.report` — "log control flow, never
        // numbers" (docs/03-hard-constraints.md #30).
        return accumulator.finish()
    }
}

// MARK: - UsageAccumulator

/// Folds the result tree into a ``TotalActivityConfiguration`` in one pass.
///
/// Deliberately a `struct` held in a local `var`: it never escapes
/// `makeConfiguration(representing:)`, so it is not shared across isolation
/// domains and does not need to be `Sendable` — which is what lets it hold SDK
/// values (`Application`, `ApplicationToken`) that the configuration must not.
private struct UsageAccumulator {

    /// Hard ceiling on distinct applications tallied.
    ///
    /// Bounds this process's memory against any data set at all. 512 is far
    /// above a realistic phone (a heavy user opens a few dozen apps a week) and
    /// far below anything that could threaten even the pessimistic reading of
    /// the undocumented report-extension ceiling *(unverified,
    /// docs/02-api-reference.md §14)*. When it is hit, the overflow is counted
    /// and shown, never silently dropped.
    static let maxTrackedApplications = 512

    /// How many application rows survive into the configuration.
    ///
    /// A report is a glance, not a ledger — and every extra row is another
    /// remote view the host has to lay out.
    static let maxApplicationRows = 8

    private struct Tally {
        let insertionIndex: Int
        let token: ApplicationToken?
        let localizedDisplayName: String?
        let bundleIdentifier: String?
        var categoryName: String?
        var duration: TimeInterval
        var pickups: Int
        var notifications: Int
    }

    private var tallies: [Application: Tally] = [:]
    private var nextInsertionIndex = 0

    private var segmentCount = 0
    private var totalDuration: TimeInterval = 0
    private var applicationDuration: TimeInterval = 0
    private var applicationPickups = 0
    private var standalonePickups = 0
    private var notifications = 0
    private var longestSession: TimeInterval = 0
    private var didObserveLongestSession = false
    private var firstPickup: Date?
    private var coveredStart: Date?
    private var coveredEnd: Date?
    private var isTallyCapped = false

    // MARK: Folding

    mutating func observe(segment: ActivitySegment) {
        segmentCount += 1
        totalDuration += max(0, segment.totalActivityDuration)

        // Pickups that the system could not attribute to any application. Added
        // to the per-application pickups in `finish()`; together they are the
        // documented decomposition of "how often was this phone picked up".
        standalonePickups += max(0, segment.totalPickupsWithoutApplicationActivity)

        if let longest = segment.longestActivity {
            longestSession = max(longestSession, max(0, longest.duration))
            didObserveLongestSession = true
        }

        if let pickup = segment.firstPickup {
            firstPickup = firstPickup.map { min($0, pickup) } ?? pickup
        }

        let interval = segment.dateInterval
        coveredStart = coveredStart.map { min($0, interval.start) } ?? interval.start
        coveredEnd = coveredEnd.map { max($0, interval.end) } ?? interval.end
    }

    /// Folds one application record.
    ///
    /// The same application reappears in every segment it was used in — and, if
    /// the system files it under more than one category, more than once per
    /// segment. Tallying by `Application` rather than appending is what makes a
    /// week-long filter cost the same memory as a one-day filter.
    mutating func observe(application record: ApplicationActivity, categoryName: String?) {
        let application = record.application
        let duration = max(0, record.totalActivityDuration)
        let pickups = max(0, record.numberOfPickups)
        let notificationCount = max(0, record.numberOfNotifications)

        applicationDuration += duration
        applicationPickups += pickups
        notifications += notificationCount

        if let index = tallies.index(forKey: application) {
            // In-place: avoids the copy a `tallies[application] = modified`
            // round-trip would make of every value in the bucket.
            tallies.values[index].duration += duration
            tallies.values[index].pickups += pickups
            tallies.values[index].notifications += notificationCount
            if tallies.values[index].categoryName == nil {
                tallies.values[index].categoryName = categoryName
            }
            return
        }

        guard tallies.count < Self.maxTrackedApplications else {
            // Its time is still in `applicationDuration` and in the segment
            // totals; only its row is lost. The flag makes that visible.
            isTallyCapped = true
            return
        }

        tallies[application] = Tally(
            insertionIndex: nextInsertionIndex,
            token: application.token,
            localizedDisplayName: application.localizedDisplayName,
            bundleIdentifier: application.bundleIdentifier,
            categoryName: categoryName,
            duration: duration,
            pickups: pickups,
            notifications: notificationCount
        )
        nextInsertionIndex += 1
    }

    // MARK: Finishing

    /// Ranks, labels and truncates. The only array this file builds, built once,
    /// after the streams are exhausted, bounded by
    /// ``maxTrackedApplications`` — not by the length of the input.
    func finish() -> TotalActivityConfiguration {
        let ranked = tallies.values.sorted { lhs, rhs in
            if lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
            // Arrival order, so the ordering is deterministic for equal
            // durations. `Dictionary` iteration order is not, and a list that
            // reshuffles between two renders of identical data reads as a bug.
            return lhs.insertionIndex < rhs.insertionIndex
        }

        var anonymousCount = 0
        var rows: [TotalActivityConfiguration.ApplicationUsage] = []
        rows.reserveCapacity(min(ranked.count, Self.maxApplicationRows))

        for tally in ranked.prefix(Self.maxApplicationRows) {
            let label = Self.label(for: tally, anonymousCount: &anonymousCount)
            rows.append(
                TotalActivityConfiguration.ApplicationUsage(
                    id: Self.identifier(for: tally),
                    displayName: label.text,
                    isNameResolved: label.isResolved,
                    duration: tally.duration,
                    pickups: tally.pickups,
                    notifications: tally.notifications
                )
            )
        }

        var covered: DateInterval?
        if let start = coveredStart, let end = coveredEnd, end >= start {
            covered = DateInterval(start: start, end: end)
        }

        return TotalActivityConfiguration(
            totalDuration: totalDuration,
            applicationDuration: applicationDuration,
            totalPickups: applicationPickups + standalonePickups,
            totalNotifications: notifications,
            longestSession: didObserveLongestSession ? longestSession : nil,
            firstPickup: firstPickup,
            coveredInterval: covered,
            applications: rows,
            distinctApplicationCount: tallies.count,
            isTallyCapped: isTallyCapped,
            segmentCount: segmentCount
        )
    }

    // MARK: Labelling

    /// Resolves what to draw for one application.
    ///
    /// ## The unverified part
    ///
    /// docs/02-api-reference.md §5 annotates `Application.localizedDisplayName`
    /// and `.bundleIdentifier` as *"nil outside `ShieldConfigurationDataSource`"*,
    /// and docs/03-hard-constraints.md #25 states flatly that app identity is
    /// opaque outside that one extension. Apple's own report-extension sample,
    /// meanwhile, draws `localizedDisplayName` — inside *this* extension, which
    /// is sandboxed precisely so that names may be shown and not exported.
    ///
    /// The two cannot both be right, and this is exactly the class of question
    /// that cannot be settled off-device (docs/03-hard-constraints.md #11: no
    /// Simulator support, ever). **Device-test item:** open the Stats screen on
    /// a real device and note whether rows carry real names.
    ///
    /// So this resolves defensively, and both answers render correctly:
    ///
    /// 1. a non-empty `localizedDisplayName`;
    /// 2. else a name derived from `bundleIdentifier`;
    /// 3. else a positional placeholder, qualified by the category name when the
    ///    system gave us one ("Social Networking app 2" beats "App 2"), and
    ///    flagged `isNameResolved: false` so the view can explain itself.
    ///
    /// Placeholders are numbered in rank order, which is stable because `ranked`
    /// is totally ordered.
    private static func label(
        for tally: Tally,
        anonymousCount: inout Int
    ) -> (text: String, isResolved: Bool) {
        if let name = tally.localizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return (name, true)
        }

        if let bundle = tally.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundle.isEmpty {
            return (readableName(fromBundleIdentifier: bundle), true)
        }

        anonymousCount += 1

        if let category = tally.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !category.isEmpty {
            return ("\(category) app \(anonymousCount)", false)
        }

        return ("App \(anonymousCount)", false)
    }

    /// `com.burbn.instagram` → `Instagram`.
    ///
    /// A heuristic, and only ever reached when the real display name is missing —
    /// at which point the last component of a reverse-DNS identifier is the best
    /// guess available and is usually the product name. Falls back to the whole
    /// identifier for anything that does not look like reverse DNS.
    private static func readableName(fromBundleIdentifier bundle: String) -> String {
        guard let last = bundle.split(separator: ".").last, !last.isEmpty else {
            return bundle
        }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// A `ForEach` identity that is stable across renders of the same data.
    ///
    /// `TokenGuard.fingerprint(of:)` (Kernel/Enforcement/TokenGuard.swift) is the
    /// product's one token digest and is stable across processes, unlike
    /// `hashValue`, which Swift seeds per process. Computed here — for at most
    /// ``maxApplicationRows`` tokens — rather than in the fold, where it would
    /// run once per record.
    private static func identifier(for tally: Tally) -> String {
        if let token = tally.token, let fingerprint = TokenGuard.fingerprint(of: token) {
            return fingerprint
        }
        if let bundle = tally.bundleIdentifier, !bundle.isEmpty {
            return bundle
        }
        return "app-\(tally.insertionIndex)"
    }
}
