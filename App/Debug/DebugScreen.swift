//
//  DebugScreen.swift
//  Gate
//
//  V1-11 (docs/04-product-spec.md), build plan step 5.8.
//
//  Spec, verbatim: *"ship it in Debug builds; it pays for itself in week 1."* And
//  from the build plan: *"Build it early; it is worth more than any unit test on
//  this stack."* Both are true for the same reason — none of the four Screen Time
//  frameworks works in the Simulator, the monitor extension has no console you
//  can attach to reliably, and the daemon's idea of what is armed is the only
//  thing that actually matters. This screen renders that daemon state directly.
//
//  The whole file is `#if DEBUG`. It reads live daemon state and dumps raw
//  `GateState`, neither of which belongs in a shipping build, and `HomeScreen`
//  compiles its menu entry out alongside it.
//

#if DEBUG

import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftUI
import os

import GateKernel
import GateKernelUI

private var debugLog: Logger {
    Logger(subsystem: GateID.Subsystem.app, category: "Debug")
}

struct DebugScreen: View {

    @Environment(AppModel.self) private var model

    @State private var lastRunSummary: String?
    @State private var breadcrumbs: [InboxEvent] = []
    @State private var stateDump = ""
    @State private var refreshedAt = Date()

    var body: some View {
        List {
            actionsSection
            authorizationSection
            activitiesSection
            storesSection
            planSection
            reportSection
            breadcrumbSection
            containerSection
            stateSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(GateTheme.background)
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        // No pull-to-refresh: `refreshable(action:)` takes a `@Sendable` closure
        // and every button on this screen already re-reads. The explicit
        // "Re-read everything" row is also easier to hit repeatedly while
        // watching a value change.
        .onAppear(perform: refresh)
    }

    // MARK: Actions

    private var actionsSection: some View {
        Section {
            Button {
                runAsApp()
            } label: {
                Label("Run reconcile now (as the app)", systemImage: "arrow.clockwise")
            }

            Button {
                runAsMonitor()
            } label: {
                Label("Run reconcile now (as the monitor)", systemImage: "timer")
            }

            Button {
                refresh()
            } label: {
                Label("Re-read everything", systemImage: "eye")
            }

            if let lastRunSummary {
                Text(lastRunSummary)
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textSecondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Reconcile")
        } footer: {
            // "the exact same code path the monitor calls" — literally: the same
            // `Reconciler.reconcile` entry point, the same selection resolver
            // behaviour, and `ReconcileRole.monitor`, which turns off state
            // writes, the inbox drain and the shield-copy republish exactly as it
            // does inside `GateActivityMonitor.appex`. The only difference is the
            // process it runs in, which is the difference you are trying to
            // isolate when you press it.
            Text("The monitor button runs the same entry point the extension runs, with "
                 + "`role: .monitor` — no state write, no inbox drain, no shield-copy "
                 + "republish. Use it to tell \u{201C}the logic is wrong\u{201D} apart from "
                 + "\u{201C}the extension never launched\u{201D}.")
        }
    }

    // MARK: Authorization

    private var authorizationSection: some View {
        Section {
            KeyValueRow("authorizationStatus", String(describing: model.authorizationStatus))
            KeyValueRow("member", "individual")
            KeyValueRow("notifications", String(describing: model.notificationAuthorization))
            KeyValueRow("needsRecovery", String(model.state.needsRecovery))
            if let observed = model.state.tokenExpiryObservedAt {
                KeyValueRow("tokenExpiryObservedAt", observed.formatted(date: .abbreviated, time: .standard))
            }
        } header: {
            Text("Authorization")
        } footer: {
            // Polled, never observed: `$authorizationStatus` does not emit on
            // revoke while backgrounded without a debugger attached (thread
            // 820796, open). Which means: it *will* look like it works while you
            // are debugging, and not in the field.
            Text("Polled on every foreground. The publisher does not fire on revoke while "
                 + "backgrounded unless a debugger is attached, so it looks reliable "
                 + "exactly when you are watching it.")
        }
    }

    // MARK: Activities (the daemon's view)

    private var activitiesSection: some View {
        let center = DeviceActivityCenter()
        let activities = center.activities

        return Section {
            if activities.isEmpty {
                Text("Nothing is being monitored.")
                    .foregroundStyle(GateTheme.textSecondary)
            }
            ForEach(activities, id: \.rawValue) { name in
                VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                    HStack {
                        Text(name.rawValue)
                            .font(GateTheme.Typography.numeric)
                            .foregroundStyle(GateTheme.textPrimary)
                        Spacer()
                        if !name.isGateActivity {
                            GateChip("foreign", tone: .danger)
                        }
                    }
                    if let decoded = ActivityNameCodec.decode(name.rawValue) {
                        Text(String(describing: decoded))
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.textTertiary)
                    }
                    if let schedule = center.schedule(for: name) {
                        Text(Self.describe(schedule))
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.textSecondary)
                    } else {
                        Text("no schedule returned")
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.danger)
                    }
                    let events = center.events(for: name)
                    if !events.isEmpty {
                        Text("events: " + events.keys.map(\.rawValue).sorted().joined(separator: ", "))
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.textSecondary)
                    }
                }
                .textSelection(.enabled)
            }
        } header: {
            Text("DeviceActivityCenter (\(activities.count)/\(GateLimits.maxConcurrentActivities))")
        } footer: {
            Text("This is the daemon's own list, not Gate's plan. A name here that Gate did "
                 + "not plan is an orphan; a name Gate planned that is missing here never "
                 + "armed. v1 arms no events, so an events line means something is wrong.")
        }
    }

    // MARK: Named stores

    private var storesSection: some View {
        Section {
            // `ManagedSettingsStore.stores` is iOS 26.5+; `TokenGuard.storeAudit()`
            // returns nil below it rather than guessing, because there is no way
            // to enumerate stores on earlier versions at all.
            if let audit = TokenGuard.storeAudit() {
                KeyValueRow("total", "\(audit.total) / \(audit.limit)")
                KeyValueRow("foreign", "\(audit.foreign)")
                ForEach(audit.gateNames.sorted(), id: \.self) { name in
                    Text(name)
                        .font(GateTheme.Typography.numeric)
                        .foregroundStyle(GateTheme.textSecondary)
                        .textSelection(.enabled)
                }
                if let error = audit.error {
                    Text(error.description)
                        .font(GateTheme.Typography.footnote)
                        .foregroundStyle(GateTheme.danger)
                }
            } else {
                Text("Needs iOS 26.5. Below that there is no API to enumerate named stores, "
                     + "so the 50-store cap can only be respected by construction.")
                    .font(GateTheme.Typography.footnote)
                    .foregroundStyle(GateTheme.textSecondary)
            }
            KeyValueRow("expected", "\(TokenGuard.expectedStoreCount(ruleCount: model.state.rules.count))")
        } header: {
            Text("ManagedSettingsStore")
        } footer: {
            Text("The store cap fails silently at 50. Orphans left behind by deleted rules "
                 + "are the only realistic way to reach it.")
        }
    }

    // MARK: The plan

    @ViewBuilder
    private var planSection: some View {
        if let plan = model.lastReport?.plan {
            Section {
                KeyValueRow("entries", "\(plan.entries.count) / \(MonitorPlan.budget)")
                ForEach(plan.entries) { entry in
                    VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                        Text(entry.name)
                            .font(GateTheme.Typography.numeric)
                            .foregroundStyle(GateTheme.textPrimary)
                        Text("priority \(entry.priority.rawValue) \u{00B7} "
                             + "fingerprint \(entry.fingerprint)")
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.textTertiary)
                        if let deadline = entry.deadline {
                            Text("deadline " + deadline.formatted(date: .omitted, time: .standard))
                                .font(GateTheme.Typography.caption)
                                .foregroundStyle(GateTheme.textSecondary)
                        }
                    }
                    .textSelection(.enabled)
                }
                ForEach(plan.evictions, id: \.name) { eviction in
                    Text("evicted \(eviction.name): \(eviction.reason.rawValue)")
                        .font(GateTheme.Typography.caption)
                        .foregroundStyle(GateTheme.danger)
                }
                // Indices rather than `enumerated()`: `ForEach(_:id:)` needs a
                // key path and Swift has none into a tuple element.
                ForEach(plan.diagnostics.indices, id: \.self) { index in
                    Text(String(describing: plan.diagnostics[index]))
                        .font(GateTheme.Typography.caption)
                        .foregroundStyle(GateTheme.pending)
                }
            } header: {
                Text("MonitorPlan")
            } footer: {
                Text("What Gate intends. Diff it against the daemon's list above — that diff "
                     + "is the whole of \u{201C}is enforcement actually armed\u{201D}.")
            }
        }
    }

    // MARK: The last report

    @ViewBuilder
    private var reportSection: some View {
        if let report = model.lastReport {
            Section {
                Text(report.diagnosticDescription())
                    .font(GateTheme.Typography.caption)
                    .foregroundStyle(GateTheme.textSecondary)
                    .textSelection(.enabled)
            } header: {
                Text("Last reconcile (\(report.trigger.rawValue), \(report.role.rawValue))")
            }
        } else if let error = model.lastReconcileError {
            Section {
                Text(error)
                    .font(GateTheme.Typography.caption)
                    .foregroundStyle(GateTheme.danger)
                    .textSelection(.enabled)
            } header: {
                Text("Last reconcile threw")
            }
        }
    }

    // MARK: Breadcrumbs

    private var breadcrumbSection: some View {
        Section {
            if breadcrumbs.isEmpty {
                Text("No un-drained events.")
                    .foregroundStyle(GateTheme.textSecondary)
            }
            ForEach(breadcrumbs) { event in
                VStack(alignment: .leading, spacing: GateTheme.Spacing.xxs) {
                    HStack {
                        GateChip(event.kind.rawValue, tone: Self.tone(for: event.kind))
                        Spacer()
                        Text(event.createdAt.formatted(date: .omitted, time: .standard))
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.textTertiary)
                    }
                    if let detail = event[InboxEvent.Key.detail] {
                        Text(detail)
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.textPrimary)
                    }
                    if let activity = event[InboxEvent.Key.activityName] {
                        Text(activity)
                            .font(GateTheme.Typography.caption)
                            .foregroundStyle(GateTheme.textSecondary)
                    }
                }
                .textSelection(.enabled)
            }
        } header: {
            Text("inbox/ (\(model.diagnostics().inboxPending) pending)")
        } footer: {
            // The breadcrumb trail is the only way to tell a monitor that was
            // jetsam-killed mid-pass from one that was never launched at all —
            // and "never launched despite correct configuration" is a real,
            // reported iOS 26.3.1 behaviour (docs/03-hard-constraints.md #32).
            Text("Two breadcrumbs per healthy monitor callback: \u{201C}enter …\u{201D} on "
                 + "arrival and \u{201C}rules=… armed=…\u{201D} on completion. An arrival "
                 + "with no completion is a jetsam kill mid-pass. No arrival at all means "
                 + "the extension never launched. Peeked, not drained.")
        }
    }

    // MARK: Container

    private var containerSection: some View {
        let diagnostics = model.diagnostics()
        return Section {
            KeyValueRow("store", diagnostics.storeKind)
            KeyValueRow("generation", "\(diagnostics.generation)")
            KeyValueRow("state.plist", "\(diagnostics.stateBytes) / \(GateState.maxEncodedBytes) bytes")
            KeyValueRow("selections.plist", "\(diagnostics.selectionBytes) bytes of payload")
            Text(diagnostics.container)
                .font(GateTheme.Typography.caption)
                .foregroundStyle(GateTheme.textSecondary)
                .textSelection(.enabled)
            Text(diagnostics.lockClock)
                .font(GateTheme.Typography.caption)
                .foregroundStyle(GateTheme.textSecondary)
                .textSelection(.enabled)
            KeyValueRow("monitor ceiling", "\(GateLimits.monitorMemoryCeilingBytes / 1024) KB")
            KeyValueRow("read at", refreshedAt.formatted(date: .omitted, time: .standard))
        } header: {
            Text("App Group")
        } footer: {
            Text("`state.plist` is decoded by the monitor on every callback under a 6 MB "
                 + "ceiling. Past 8 KB, start moving things out of it.")
        }
    }

    // MARK: Raw state

    private var stateSection: some View {
        Section {
            Text(stateDump.isEmpty ? "—" : stateDump)
                .font(GateTheme.Typography.caption)
                .foregroundStyle(GateTheme.textSecondary)
                .textSelection(.enabled)
        } header: {
            Text("GateState")
        }
    }

    // MARK: Work

    private func refresh() {
        refreshedAt = Date()
        breadcrumbs = model.peekInbox(limit: 40).reversed()
        stateDump = Self.dump(model.state)
    }

    private func runAsApp() {
        let started = Date()
        guard let report = model.reconcile(trigger: .debug) else {
            lastRunSummary = "app: reconcile failed — see the section below"
            refresh()
            return
        }
        lastRunSummary = Self.summarize(report, label: "app", started: started)
        refresh()
    }

    /// The monitor's call, spelled the way `GateActivityMonitor` spells it.
    ///
    /// `role: .monitor` is what makes this genuinely the same path: it turns off
    /// `writesState`, `drainsInbox` and `publishesShieldCopy`, so pressing this
    /// cannot change `state.plist` — it only rewrites `ManagedSettingsStore`s and
    /// the activity list from the state already on disk, which is exactly what
    /// the extension does on `intervalDidStart`.
    ///
    /// The role also turns *on* `foldsPendingGrants`, so this pass reads (never
    /// deletes) the pending `.grantIssued` records and honours a shield-submenu
    /// grant the app has not drained yet — again, exactly as the extension does.
    /// `inbox:` is left to default for that reason.
    private func runAsMonitor() {
        let started = Date()
        do {
            let store = try FileStateStore()
            let report = try Reconciler.reconcile(
                now: Date(),
                store: store,
                selections: model.monitorStyleSelectionResolver(),
                options: ReconcileOptions(
                    role: .monitor,
                    trigger: .intervalDidStart,
                    calendar: .current
                )
            )
            lastRunSummary = Self.summarize(report, label: "monitor", started: started)
            debugLog.log("""
                monitor-role reconcile from the debug screen: \
                \(report.diagnosticDescription(), privacy: .public)
                """)
        } catch {
            lastRunSummary = "monitor: threw — \(String(describing: error))"
            debugLog.error("monitor-role reconcile threw: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    // MARK: Formatting

    /// Key paths are hoisted out of the interpolation on purpose: `\.member`
    /// inside a `\(...)` segment is legal but reads as an escape, and the
    /// one-liner it saves is not worth the double-take.
    private static func summarize(_ report: ReconcileReport, label: String, started: Date) -> String {
        let written = report.shieldWrites.filter { $0.didWrite }.count
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        return "\(label): \(report.activities.started.count) started, "
            + "\(report.activities.stopped.count) stopped, "
            + "\(written) stores written, \(report.warnings.count) warnings, "
            + "\(report.failures.count) failures in \(elapsed) ms"
    }

    private static func describe(_ schedule: DeviceActivitySchedule) -> String {
        var line = "start \(Self.describe(schedule.intervalStart))"
            + " \u{2192} end \(Self.describe(schedule.intervalEnd))"
            + " \(schedule.repeats ? "repeating" : "one-shot")"
        if let warning = schedule.warningTime {
            line += " warn \(Self.describe(warning))"
        }
        if let next = schedule.nextInterval {
            line += "\nnext " + next.start.formatted(date: .abbreviated, time: .standard)
                + " \u{2192} " + next.end.formatted(date: .abbreviated, time: .standard)
        }
        return line
    }

    /// Component *sets* are what matter here: a mismatch between `intervalStart`
    /// and `intervalEnd` makes the schedule read as continuously active for days
    /// (docs/02-api-reference.md §7, thread 726331). Printing the keys makes that
    /// visible at a glance.
    private static func describe(_ components: DateComponents) -> String {
        var parts: [String] = []
        if let value = components.year { parts.append("y\(value)") }
        if let value = components.month { parts.append("M\(value)") }
        if let value = components.day { parts.append("d\(value)") }
        if let value = components.hour { parts.append("h\(value)") }
        if let value = components.minute { parts.append("m\(value)") }
        if let value = components.second { parts.append("s\(value)") }
        return parts.isEmpty ? "(empty)" : parts.joined(separator: " ")
    }

    private static func tone(for kind: InboxEvent.Kind) -> GateTheme.Tone {
        switch kind {
        case .grantRequest: .pending
        case .grantIssued: .scheduled
        case .bypassAttempt: .enforcing
        case .breadcrumb: .neutral
        case .tokenExpiry: .danger
        case .unknown: .danger
        }
    }

    private static func dump(_ state: GateState) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state),
              let text = String(data: data, encoding: .utf8) else {
            return "could not encode GateState"
        }
        return text
    }
}

// MARK: - KeyValueRow

private struct KeyValueRow: View {

    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(GateTheme.Typography.footnote)
                .foregroundStyle(GateTheme.textSecondary)
            Spacer(minLength: GateTheme.Spacing.m)
            Text(value)
                .font(GateTheme.Typography.numeric)
                .foregroundStyle(GateTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

#endif
