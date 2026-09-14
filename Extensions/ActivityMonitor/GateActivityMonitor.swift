//
//  GateActivityMonitor.swift
//  GateActivityMonitor
//
//  The DeviceActivityMonitor extension. Build plan: docs/06-build-plan.md step 4.1.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE 6 MB CEILING IS THE DESIGN
//  ─────────────────────────────────────────────────────────────────────────────
//  This process has a **6 MB hard memory high-watermark**, unchanged since
//  iOS 15 and not increasable — Apple staff, verbatim: *"it seems to be the
//  limit for now and there is no way to increase it."* Exceeding it is an
//  instant `EXC_RESOURCE (RESOURCE_TYPE_MEMORY … limit=6 MB)` jetsam kill with
//  **no callback delivered**, which means a block that silently never applies
//  (docs/03-hard-constraints.md #31, docs/02-api-reference.md §14).
//
//  Everything below follows from that single number:
//
//  * **Links `GateKernel` only.** Never `GateKernelUI`, never a SwiftUI view of
//    our own, never a networking, analytics or crash-reporting SDK, never
//    SwiftData or Core Data — a `ModelContainer` schema build alone can approach
//    the whole budget before any of our code runs (docs/05-architecture.md,
//    module layer split; enforced in `project.yml`, which lists exactly one
//    target dependency here). The one Apple framework beyond
//    `DeviceActivity` / `ManagedSettings` is `FamilyControls`, imported solely to
//    decode a stored `FamilyActivitySelection`; that import is the file's single
//    deliberate deviation from the architecture's module sketch and it is argued
//    out in full on `MonitorSelectionResolver` below. **Verify its real
//    footprint on device** — memory behaviour here cannot be tested in the
//    Simulator or in CI (docs/03-hard-constraints.md #11), so this is a
//    DEVICE-TEST-MATRIX line item, not a settled fact.
//  * **Nothing is held in memory across callbacks.** The class has no stored
//    properties at all. Every callback is written as a **cold start**: re-read
//    the App Group, recompute, write, return (docs/05-architecture.md, "Every
//    monitor callback is written assuming a cold start").
//  * **No `Task { }` that outlives the callback.** The extension is killed for
//    idleness as readily as for memory (docs/03-hard-constraints.md #32), so
//    work detached from the callback is work that may simply never run. Every
//    override is straight-line synchronous.
//  * **`os.Logger`, never `print()`.** `print()` is invisible from an
//    extension. The logger is a file-scope *computed* property, matching
//    `Kernel/Store/InboxStore.swift`: a stored global of a type without an
//    audited `Sendable` conformance is a Swift 6 strict-concurrency error, and
//    a `Logger` is a cheap wrapper.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHAT THIS PROCESS MAY TOUCH
//  ─────────────────────────────────────────────────────────────────────────────
//  Reads `state.plist` and `selections.plist`; writes `ManagedSettingsStore`s,
//  the daemon's activity list, `armed.plist`, `monitor-marks.plist` (below), and
//  appends breadcrumbs to `inbox/`. It **never** writes `state.plist`,
//  `shield.plist` or `selections.plist`, and never *drains* `inbox/` — that is
//  the app's single-writer discipline (docs/05-architecture.md), and it is
//  enforced for us by `ReconcileRole.monitor`, not by care here.
//
//  It does *read* `inbox/` without deleting: `ReconcileOptions.foldsPendingGrants`
//  is on for this role, so a `.grantIssued` record written by `GateShieldAction`
//  is folded into this pass's working state and the shield-submenu grant lifts
//  here rather than waiting for the app's next foreground. The record stays on
//  disk for the app to drain, and nothing this pass folds is persisted — which
//  is the same bargain every other deadline in this process makes.
//
//  Any state change this pass computes — a grant that expired, a loosening whose
//  deadline ripened — is applied to *enforcement* immediately and re-derived
//  from the unchanged file on the next pass. Every deadline in `GateState` is an
//  absolute timestamp precisely so that costs a recomputation and never a wrong
//  answer.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  NO `if #available` IN THIS FILE, DELIBERATELY
//  ─────────────────────────────────────────────────────────────────────────────
//  Every symbol used here — `DeviceActivityMonitor` and its six callbacks,
//  `DeviceActivityName`, `FamilyActivitySelection`, `ManagedSettingsStore` —
//  is iOS 15.0, below the project's 17.0 floor (docs/02-api-reference.md §13).
//  The 26.4/26.5 surfaces (`ManagedSettingsStore.stores`, `deleteStore()`,
//  `TokenExpiryMessage`, shield submenus) are reached only through
//  `Kernel/Enforcement/ShieldWriter.swift` and `Kernel/Engine/Reconciler.swift`,
//  which gate them at their own call sites. Adding an availability-gated symbol
//  here means adding the gate here too.
//

import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import os

import GateKernel

/// Computed, not a stored global: see the header note on Swift 6 and `Sendable`.
private var monitorLog: Logger {
    Logger(subsystem: GateID.Subsystem.monitor, category: "DeviceActivity")
}

// MARK: - GateActivityMonitor

/// The extension's principal class.
///
/// `Config/ActivityMonitor-Info.plist` binds
/// `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).GateActivityMonitor`, so
/// the module name and this type name together are load-bearing — renaming
/// either without the other produces an extension the system cannot instantiate,
/// and the only symptom is silence.
///
/// No stored properties, by policy. The system may create a fresh instance per
/// callback or reuse one; either way nothing survives a callback, so both
/// behave identically.
final class GateActivityMonitor: DeviceActivityMonitor {

    // MARK: Interval callbacks

    /// A rule's window opened — apply its shield.
    ///
    /// Fires only when the device is *in use*, never at the wall-clock boundary
    /// (docs/03-hard-constraints.md #27), so the reconcile below re-derives
    /// everything from absolute timestamps rather than trusting the callback's
    /// arrival time to mean anything.
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let now = Date()
        // Recorded *before* the reconcile: this is the timestamp
        // `eventDidReachThreshold` verifies against, and it must survive a pass
        // that is jetsam-killed halfway through.
        IntervalMarks.record(activity, startedAt: now)
        run(trigger: .intervalDidStart, activity: activity, now: now)
    }

    /// A rule's window closed — lift its shield.
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let now = Date()
        IntervalMarks.forget(activity)
        run(trigger: .intervalDidEnd, activity: activity, now: now)
    }

    /// `schedule.warningTime` ahead of a window opening.
    ///
    /// Gate arms a warning only where `RuleSchedule.warningMinutes` is set, and
    /// uses it for exactly one thing: reconciling early, so the shield is
    /// already in place when the window actually opens.
    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        run(trigger: .intervalWarning, activity: activity, now: Date(), detail: "willStart")
    }

    /// `schedule.warningTime` ahead of a window closing.
    override func intervalWillEndWarning(for activity: DeviceActivityName) {
        super.intervalWillEndWarning(for: activity)
        run(trigger: .intervalWarning, activity: activity, now: Date(), detail: "willEnd")
    }

    // MARK: Event callbacks — the unreliable half of the API

    /// A usage threshold was reached.
    ///
    /// **v1 arms no events at all** (`MonitorPlan.PlannedActivity.events` is
    /// always empty), so every arrival here is unexpected and is itself a
    /// finding — which is exactly why it is breadcrumbed rather than dropped.
    ///
    /// Two guarantees the spec demands of this callback
    /// (docs/04-product-spec.md V2-4, docs/03-hard-constraints.md #35):
    ///
    /// 1. **Idempotent.** Nothing here is event-scoped. The pass recomputes
    ///    ground truth from `state.plist` and absolute timestamps and re-asserts
    ///    it; a second, duplicate firing therefore produces byte-identical
    ///    stores and an identical activity list. `eventDidReachThreshold` is
    ///    documented to fire twice for the same event, to fire when the
    ///    threshold was not met, and to fire with zero recorded minutes
    ///    (FB21450954, FB21267341, FB21560904, FB18927456, and six more) — none
    ///    of which can double-count something that is never counted.
    /// 2. **Ignores events younger than 60 s.** If our *own* record says less
    ///    than `GateLimits.eventFalsePositiveGuard` has elapsed since we saw
    ///    `intervalDidStart` for this activity, the event is suppressed: that is
    ///    the documented iOS 26.x false-positive signature — "fires immediately
    ///    on first unlock," reproducible by leaving a device idle or locked and
    ///    then plugging it into power (docs/03-hard-constraints.md #35;
    ///    docs/04-product-spec.md V2-4, *"If the event fires and your own record
    ///    says < 60 s has elapsed since `intervalDidStart`, ignore it"*).
    ///    Apple's partial fix landed in 26.5 beta 1 and its own reporter calls
    ///    it *"not consistently reproducible,"* so the guard stays regardless of
    ///    OS version.
    override func eventDidReachThreshold(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventDidReachThreshold(event, activity: activity)
        handleEvent(event, activity: activity, warning: false)
    }

    /// The warning ahead of a usage threshold. Same guard, same reasoning.
    override func eventWillReachThresholdWarning(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName
    ) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        handleEvent(event, activity: activity, warning: true)
    }

    private func handleEvent(
        _ event: DeviceActivityEvent.Name,
        activity: DeviceActivityName,
        warning: Bool
    ) {
        let now = Date()
        let label = warning ? "willReach" : "didReach"
        let detail = "\(label) \(event.rawValue)"

        if let suppression = IntervalMarks.suppressionReason(for: activity, now: now) {
            // Suppressed, not deferred: there is nothing to retry. Breadcrumb it
            // so the debug screen can show how often this is happening on the
            // user's OS build (docs/04-product-spec.md V1-11) — the trail is the
            // only evidence that exists.
            monitorLog.notice("""
                ignoring \(detail, privacy: .public) for \
                \(activity.rawValue, privacy: .public): \(suppression, privacy: .public)
                """)
            breadcrumb(
                trigger: .eventThreshold,
                activity: activity,
                detail: "ignored \(detail): \(suppression)",
                now: now
            )
            return
        }

        run(trigger: .eventThreshold, activity: activity, now: now, detail: detail)
    }

    // MARK: The one path all six callbacks take

    /// Decode the name, breadcrumb the arrival, reconcile, return.
    ///
    /// The name is the **only** payload a monitor callback carries — no tokens,
    /// no dates, no `userInfo` (docs/02-api-reference.md §8) — so decoding it is
    /// the whole of this process's input, and `Kernel/Engine/ActivityNameCodec.swift`
    /// is the only thing that may parse it.
    private func run(
        trigger: ReconcileTrigger,
        activity: DeviceActivityName,
        now: Date,
        detail: String? = nil
    ) {
        let log = monitorLog
        let decoded = activity.gateActivity

        // Three cases, and only the third is a bug:
        //
        //   decoded != nil            one of ours, understood.
        //   nil but isGateActivity    ours, written by a newer build. Reconcile
        //                             anyway — the pass re-derives the correct
        //                             activity set and the orphan sweep in
        //                             `MonitorPlan.Diff` owns the stale name.
        //   nil and not ours          a foreign activity delivered to our
        //                             extension. Impossible in principle; touch
        //                             nothing and get out.
        guard decoded != nil || activity.isGateActivity else {
            log.error("""
                foreign activity \(activity.rawValue, privacy: .public) delivered to \
                \(trigger.rawValue, privacy: .public); ignoring
                """)
            return
        }
        if decoded == nil {
            log.notice("""
                unparseable Gate activity \(activity.rawValue, privacy: .public) — \
                newer build? reconciling anyway
                """)
        }

        // The inbox handle is made once and shared with the reconcile, so the
        // arrival breadcrumb and the completion breadcrumb cost one container
        // lookup between them rather than two.
        let inbox = try? InboxStore()

        // ── Arrival ─────────────────────────────────────────────────────────
        //
        // Written before any work, deliberately. `Reconciler` appends its own
        // completion breadcrumb for `ReconcileRole.monitor`, so a healthy pass
        // leaves an arrival/completion *pair*. An arrival with no completion is
        // the signature of a jetsam kill mid-pass; no arrival at all is the
        // signature of an extension that was never launched (thread 819224).
        // Those two failures look identical from the app, and telling them
        // apart is the entire reason the trail exists
        // (docs/03-hard-constraints.md #32).
        append(
            InboxEvent.breadcrumb(
                source: trigger.rawValue,
                activityName: activity.rawValue,
                ruleID: decoded?.ruleID ?? nil,
                detail: detail.map { "enter \($0)" } ?? "enter",
                now: now
            ),
            to: inbox,
            log: log
        )

        // ── The pass ────────────────────────────────────────────────────────
        do {
            // Every capability is left exactly as `ReconcileRole.monitor`
            // defines it. `writesState`, `drainsInbox` and `publishesShieldCopy`
            // are already `false` for this role, which is what keeps the
            // single-writer discipline a property of the code rather than of
            // this comment; `appendsBreadcrumb` stays `true` so the pass closes
            // the pair the arrival breadcrumb above opened.
            //
            // `isAuthorized` keeps its default `true` — the enforcing direction.
            // `AuthorizationCenter` is not usefully readable from an extension,
            // and a monitor that wrongly concluded authorization was gone would
            // stop maintaining shields the daemon is still honouring. The app
            // checks the real status on every foreground and routes to recovery
            // (docs/04-product-spec.md V1-9).
            //
            // `maxInboxEvents` is the one narrowing. `ReconcileRole.monitor`
            // leaves `foldsPendingGrants` on, so this pass *reads* the pending
            // `.grantIssued` records — that is what lets a shield-submenu grant
            // lift here instead of waiting for the app — and reading them under a
            // 6 MB jetsam ceiling (docs/03-hard-constraints.md #31) has to be
            // bounded. Nothing is deleted either way.
            let options = ReconcileOptions(
                role: .monitor,
                trigger: trigger,
                calendar: .current,
                maxInboxEvents: 64
            )

            // Coordinated, as the app's writer is. `FileStateStore.save` logs a
            // `fault` and trips `assertionFailure` in debug if it is ever called
            // from an `.appex` — it never is here, because
            // `ReconcileRole.monitor.writesState` is `false`.
            let store = try FileStateStore()

            let report = try Reconciler.reconcile(
                now: now,
                store: store,
                selections: MonitorSelectionResolver(),
                inbox: inbox,
                options: options
            )

            var wrote = 0
            for write in report.shieldWrites where write.didWrite { wrote += 1 }

            log.log("""
                \(trigger.rawValue, privacy: .public) \(activity.rawValue, privacy: .public): \
                rules=\(report.state.rules.count, privacy: .public) \
                enforcing=\(report.enforcingRuleIDs.count, privacy: .public) \
                wrote=\(wrote, privacy: .public) \
                started=\(report.activities.started.count, privacy: .public) \
                stopped=\(report.activities.stopped.count, privacy: .public) \
                warnings=\(report.warnings.count, privacy: .public) \
                failures=\(report.failures.count, privacy: .public)
                """)

            for failure in report.failures {
                log.error("reconcile failure: \(failure.description, privacy: .public)")
            }
        } catch {
            // `Reconciler.reconcile` throws for exactly one reason: `state.plist`
            // exists and will not decode. That is unrecoverable *here* — the
            // monitor may not quarantine or rewrite it — and it must never
            // degrade into "no rules," which would empty every store and unblock
            // everything. So: leave every store exactly as it is, say so loudly,
            // and let the app's recovery flow handle it on the next foreground.
            log.fault("""
                reconcile failed on \(trigger.rawValue, privacy: .public) for \
                \(activity.rawValue, privacy: .public): \
                \(String(describing: error), privacy: .public) — \
                stores left untouched
                """)
            append(
                InboxEvent.breadcrumb(
                    source: trigger.rawValue,
                    activityName: activity.rawValue,
                    ruleID: decoded?.ruleID ?? nil,
                    detail: "failed: \(error)",
                    now: now
                ),
                to: inbox,
                log: log
            )
        }
    }

    private func breadcrumb(
        trigger: ReconcileTrigger,
        activity: DeviceActivityName,
        detail: String,
        now: Date
    ) {
        let log = monitorLog
        append(
            InboxEvent.breadcrumb(
                source: trigger.rawValue,
                activityName: activity.rawValue,
                ruleID: activity.gateActivity?.ruleID ?? nil,
                detail: detail,
                now: now
            ),
            to: try? InboxStore(),
            log: log
        )
    }

    /// Appends best-effort. A breadcrumb that cannot be written is a diagnostic
    /// we lose, never a reason to abandon enforcement.
    private func append(_ event: InboxEvent, to inbox: InboxStore?, log: Logger) {
        guard let inbox else {
            log.error("no App Group container; breadcrumb dropped")
            return
        }
        _ = inbox.appendBestEffort(event)
    }
}

// MARK: - IntervalMarks

/// "Your own persisted timestamps" — when this process last saw
/// `intervalDidStart` for each repeating activity.
///
/// docs/04-product-spec.md V2-4 requires `eventDidReachThreshold` to *"verify
/// against your own persisted timestamps before shielding"* and to ignore an
/// event when *"your own record says < 60 s has elapsed since
/// `intervalDidStart`."* Two records could serve, and only one of them is right:
///
/// * `DeviceActivityCenter().schedule(for:)?.nextInterval` gives the daemon's
///   **wall-clock** interval start. It is wrong for this guard. Intervals begin
///   at the wall clock but `intervalDidStart` is delivered only when the device
///   is next *in use* (docs/03-hard-constraints.md #27), so a window that opened
///   at 09:00 and was first touched at 14:00 reads as five hours old at the
///   exact moment the "fires immediately on first unlock" false positive
///   arrives — the guard would pass and the bug would land.
/// * This file records **delivery** time, which is what the false positive is
///   relative to. So this file is what the guard reads.
///
/// A monitor-owned cache, in the same spirit as `armed.plist`: it is not state,
/// nothing depends on it being present, and losing it costs one suppression. It
/// is deliberately *not* `state.plist` — extensions never write that
/// (docs/05-architecture.md, single-writer discipline).
private enum IntervalMarks {

    /// `<App Group>/monitor-marks.plist`.
    static let fileName = "monitor-marks.plist"

    /// One day plus a DST hour. A mark older than the window it belongs to is
    /// noise; pruning on write is what keeps this file a fixed few hundred bytes
    /// instead of an ever-growing map of dead one-shot activity names.
    static let retention: TimeInterval = 25 * 60 * 60

    /// Only repeating rule windows can carry events, and there are at most
    /// `GateLimits.maxRepeatingActivities` of those.
    static let capacity = GateLimits.maxRepeatingActivities

    private static func file() throws -> PlistFile<[String: Date]> {
        PlistFile(
            url: try AppGroupContainer.url.appendingPathComponent(fileName, isDirectory: false),
            coordinated: false
        )
    }

    private static func load() -> [String: Date] {
        guard let plist = try? file(), plist.exists else { return [:] }
        return (try? plist.read()) ?? [:]
    }

    private static func store(_ marks: [String: Date]) {
        do {
            try file().write(marks)
        } catch {
            // Best-effort. Losing a mark makes the next threshold event
            // suppressed rather than acted on, which is the safe direction.
            monitorLog.error("could not write marks: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stamps `activity` as having started now.
    ///
    /// Only `gate.rule:` windows are marked. The one-shot `gate.grant:` and
    /// `gate.revert:` timers are scheduled as already-ongoing intervals, so each
    /// one fires `intervalDidStart` the moment it is armed
    /// (docs/02-api-reference.md §7) — marking those would mean a file write per
    /// grant for a name that can never carry an event, and would blow the
    /// `capacity` bound this type advertises.
    static func record(_ activity: DeviceActivityName, startedAt now: Date) {
        guard let kind = activity.gateActivity?.kind, kind == .rule else { return }
        var marks = prune(load(), now: now)
        marks[activity.rawValue] = now
        store(trim(marks))
    }

    /// Drops `activity`'s mark — its window closed. Gated identically to
    /// ``record(_:startedAt:)``, so a one-shot's `intervalDidEnd` does not even
    /// open the file.
    static func forget(_ activity: DeviceActivityName) {
        guard let kind = activity.gateActivity?.kind, kind == .rule else { return }
        var marks = load()
        guard marks.removeValue(forKey: activity.rawValue) != nil else { return }
        store(marks)
    }

    /// `nil` to admit the event; otherwise a short reason to suppress it.
    ///
    /// Suppressing is the safe default in every uncertain case. In v1 no events
    /// are armed at all, so a suppressed event costs nothing; in v2 a wrongly
    /// admitted one shields an app the user had not actually overused, which
    /// docs/04-product-spec.md V2-4 calls out as *"common and infuriating."*
    static func suppressionReason(for activity: DeviceActivityName, now: Date) -> String? {
        guard let started = load()[activity.rawValue] else {
            return "no recorded intervalDidStart"
        }
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= 0 else {
            // The device clock moved backwards. Nothing about the mark can be
            // trusted, and a negative age cannot clear a 60 s floor anyway.
            return "clock moved backwards"
        }
        guard elapsed >= GateLimits.eventFalsePositiveGuard else {
            return "interval started \(Int(elapsed))s ago"
        }
        return nil
    }

    private static func prune(_ marks: [String: Date], now: Date) -> [String: Date] {
        marks.filter { now.timeIntervalSince($0.value) < retention }
    }

    /// Keeps the `capacity` most recent marks. A belt-and-braces bound: `prune`
    /// already removes anything stale, and this removes anything merely
    /// numerous.
    private static func trim(_ marks: [String: Date]) -> [String: Date] {
        guard marks.count > capacity else { return marks }
        let newest = marks.sorted { $0.value > $1.value }.prefix(capacity)
        return Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}

// MARK: - MonitorSelectionResolver

/// Turns a rule id into live tokens, by reading `selections.plist`.
///
/// `Reconciler` takes this as `any SelectionResolving` because `GateKernel`
/// never names `FamilyActivitySelection` — the model layer stores the blob
/// opaquely and this is the seam where the one type that must be named enters
/// from outside (`Kernel/Engine/Reconciler.swift`, "Selection resolution").
///
/// **On `import FamilyControls` in a 6 MB process.** The architecture's module
/// sketch lists this extension as `Foundation + DeviceActivity + ManagedSettings`
/// (docs/05-architecture.md, data-flow diagram), and FamilyControls pulls
/// SwiftUI into the dyld closure for the picker we will never present. It is
/// imported anyway, because the alternative is worse: without decoding the blob
/// the monitor can only *lift* shields and never apply one, since
/// `ShieldWriter` refuses any enforcing write whose tokens did not resolve. A
/// monitor that can unblock but not block is a commitment device that fails in
/// the user's favour at every interval boundary. Mirroring
/// `FamilyActivitySelection`'s JSON by hand was the other option and was
/// rejected: Apple documents the `Codable` conformance but not its wire shape,
/// so a hand-written mirror would decode to empty sets against any future
/// change and look exactly like a healthy read.
///
/// The cost is contained rather than avoided:
///
/// * **Lazy.** `Reconciler` only asks about rules that are actually enforcing,
///   and the table is not read at all until the first such question. The common
///   `intervalDidEnd` pass — everything lifting — never opens the file.
/// * **Per-pass.** The decoded table dies with the reconcile; nothing is cached
///   across callbacks.
/// * **Fails closed.** Every failure path returns `nil`, which makes
///   `ShieldWriter` refuse that rule's write and leave its store exactly as the
///   app last wrote it. A store left alone is enforcing yesterday's correct
///   answer; a store emptied on a failed read is an unblocked app the user asked
///   to have blocked (docs/03-hard-constraints.md #36).
///
/// A `final class`, not a `struct`, so the lazy read can memoize through a
/// non-mutating protocol requirement. Deliberately **not** `Sendable`:
/// `ResolvedTokens` holds `Token<_>` values with no audited conformance, so this
/// must never be captured in a `Task` or held across an `await`. Nothing here
/// is, and nothing in this extension is asynchronous at all.
private final class MonitorSelectionResolver: SelectionResolving {

    private var table: SelectionTable?
    private var didLoad = false

    func resolvedTokens(forRuleID ruleID: UUID) -> ResolvedTokens? {
        let log = monitorLog

        guard let table = loadedTable() else { return nil }
        guard let record = table.record(forRuleID: ruleID) else {
            log.error("no selection record for rule \(ruleID.uuidString, privacy: .public)")
            return nil
        }

        // Cheap torn-write detector: the payload no longer hashes to the digest
        // the app stamped on it. Checked before the decode, because a blob that
        // already disagrees with itself is not worth the memory.
        guard record.isConsistent else {
            log.error("""
                selection blob for rule \(ruleID.uuidString, privacy: .public) does not \
                match its digest; refusing the write
                """)
            return nil
        }

        let selection: FamilyActivitySelection
        do {
            selection = try JSONDecoder().decode(FamilyActivitySelection.self, from: record.payload)
        } catch {
            log.error("""
                could not decode the selection for rule \(ruleID.uuidString, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }

        return ResolvedTokens(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens
        )
    }

    private func loadedTable() -> SelectionTable? {
        if didLoad { return table }
        didLoad = true
        do {
            table = try SelectionTableFile.read()
            if table == nil {
                // The ordinary pre-first-rule state, not a fault.
                monitorLog.debug("no selections.plist yet")
            }
        } catch {
            // Left strictly alone. Rewriting this file from a failed read would
            // delete every selection in the install, and this process may not
            // write it in any case.
            monitorLog.error("""
                could not read selections.plist: \(String(describing: error), privacy: .public)
                """)
            table = nil
        }
        return table
    }
}
