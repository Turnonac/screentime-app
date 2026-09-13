//
//  GateReportExtension.swift
//  GateReport
//
//  Build plan: docs/06-build-plan.md step 4.4.
//  Consumed by: docs/04-product-spec.md V2-5 (the Stats screen).
//
//  ═══════════════════════════════════════════════════════════════════════════
//  THIS PROCESS WRITES NOTHING. ANYWHERE. EVER.
//  ═══════════════════════════════════════════════════════════════════════════
//
//  Apple DTS, verbatim, answering *"Is DeviceActivityReportExtension
//  intentionally sandboxed so Screen Time data cannot be exported to the
//  containing app?"* — **"Yes."** (docs/02-api-reference.md §11;
//  docs/03-hard-constraints.md #30.)
//
//  The channels that have been tried and confirmed blocked:
//
//  | Channel                                   | Observed behaviour            |
//  |-------------------------------------------|-------------------------------|
//  | App Group `UserDefaults` write            | silently dropped              |
//  | App Group `FileManager` write             | silently dropped              |
//  | HTTP / any network request                | blocked by the sandbox        |
//  | `UNUserNotificationCenter` local notif.   | blocked                       |
//  | `UIPasteboard`                            | blocked                       |
//  | iCloud key-value store                    | `synchronize()` returns false |
//
//  "Silently dropped" is the dangerous word: there is no error, no exception and
//  no log line. Code that writes here *looks* like it works, on device, for as
//  long as you are willing to stare at it. So:
//
//    * these three files contain no `FileManager`, no `UserDefaults`, no
//      `URLSession`, no `UNUserNotificationCenter`, no `UIPasteboard`, and none
//      of `GateKernel`'s store layer — not `AppGroupContainer`, not
//      `FileStateStore`, not `InboxStore`;
//    * `GateKernel` is linked and imported for two read-only things only: the
//      report `Context` name and the logging subsystem string;
//    * nothing may add a write later. There is no clever way around this. The
//      only sanctioned escape is `DeviceActivityData.activityData(filteredBy:)`
//      (iOS 26.4), which needs `.approvedWithDataAccess`, is EU-only, and is
//      explicitly out of scope for v1–v3 (docs/04-product-spec.md, V3 section;
//      docs/03-hard-constraints.md #8).
//
//  The corollary the rest of the product is built on: **Gate's own numbers
//  (grants used, bypass attempts, pending changes) and Apple's numbers can never
//  appear in the same computation.** The Stats screen shows them side by side
//  and labels which is which; it does not add them together, because this
//  process cannot hand anything to that one.
//
//  LOGGING
//  -------
//  `os.Logger` reaches the unified log, which is the one thing that does leave
//  this address space. `GateID.Subsystem.report` documents the resulting rule
//  (Kernel/Identifiers.swift): **log control flow, never numbers.** A duration,
//  a pickup count or an app name in a log line would launder Screen Time data
//  out of a sandbox Apple deliberately closed — and straight into any sysdiagnose
//  the user later mails to a third party. Every log statement in this target is
//  therefore a bare lifecycle marker.
//
//  BUNDLE SHAPE
//  ------------
//  This is a true ExtensionKit extension, not an `NSExtension` plug-in. There is
//  no principal class and no `NSExtension` dictionary in `Config/Report-Info.plist`
//  — the `@main` struct below is the entry point, reached through
//  `EXAppExtensionAttributes` / `EXExtensionPointIdentifier =
//  com.apple.deviceactivityui.report-extension`. Getting this wrong produces a
//  catch-22 that is hard to diagnose: with a principal class, device install
//  fails with `Error 3002 AppexBundleContainsClassOrStoryboard`; without one but
//  packaged as a plug-in, App Store Connect rejects the build for
//  *"No values for NSExtensionMainStoryboard or NSExtensionPrincipalClass found"*
//  (docs/02-api-reference.md §3, Trap 3). The resolution lives in project.yml:
//  `type: extensionkit-extension` plus `dstSubfolderSpec = 16`.
//

import DeviceActivity
import SwiftUI
import os

import GateKernel

/// Computed, not a stored global: see `monitorLog` in the activity-monitor
/// extension for the same reasoning about Swift 6 and `Sendable`.
private var extensionLog: Logger {
    Logger(subsystem: GateID.Subsystem.report, category: "extension")
}

// MARK: - GateReportExtension

/// The report extension's entry point.
///
/// `DeviceActivityReportExtension` refines ExtensionKit's `AppExtension`, so the
/// `@main` attribute synthesises `main()` and the system instantiates this type
/// when the containing app renders a ``DeviceActivityReport`` view. The extension
/// is launched, given the filtered data, asked for a view, and torn down; it has
/// no lifetime of its own and no way to run in the background.
///
/// ## One scene, deliberately
///
/// `body` is a scene *builder*: every `DeviceActivityReport.Context` the app
/// renders needs a matching scene here, and a context with no scene renders the
/// system's blank placeholder. v1 has exactly one context,
/// ``DeviceActivityReport/Context/totalActivity`` (Kernel/Identifiers.swift).
///
/// Resist adding more. Each context the app displays is a separate
/// `DeviceActivityReport` view, each report view is a separate remote-view
/// connection, and **three or more report views on one screen is a reported
/// crash threshold** (docs/02-api-reference.md §11). The product rule that falls
/// out of that — *one report view per screen* — is written into
/// docs/04-product-spec.md V2-5.
@main
struct GateReportExtension: DeviceActivityReportExtension {

    /// Required by `AppExtension`. The log line is the cheapest possible answer
    /// to the question this stack asks most often: *did the extension launch at
    /// all, or is the host showing a blank rectangle because it never did?*
    ///
    /// A black or empty area where the report should be has two very different
    /// causes — a bundle/entitlement problem (this line never appears) versus the
    /// undocumented report-extension memory ceiling, reported at both 50 MB and
    /// 100 MB *(unverified, docs/02-api-reference.md §14)* (this line appears,
    /// then the process dies mid-aggregation). Knowing which one you have is the
    /// difference between editing project.yml and editing
    /// ``TotalActivityReport``.
    init() {
        extensionLog.debug("report extension launched")
    }

    var body: some DeviceActivityReportScene {
        TotalActivityReport { configuration in
            TotalActivityView(configuration: configuration)
        }
    }
}
