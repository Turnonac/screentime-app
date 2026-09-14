//
//  ReportContext.swift
//  GateKernelUI
//
//  The one `DeviceActivityReport.Context` v1 ships.
//
//  This lives in GateKernelUI rather than alongside the other shared
//  identifiers in `Kernel/Identifiers.swift` for one reason: naming
//  `DeviceActivityReport.Context` requires SwiftUI, because
//  `DeviceActivityReport` is itself a SwiftUI view. GateKernel is linked by the
//  DeviceActivityMonitor extension, which runs under a 6 MB jetsam ceiling and
//  is killed silently when it is exceeded — a killed monitor means a block that
//  never applies (docs/03-hard-constraints.md #31). Dragging SwiftUI into that
//  binary to declare one string is not a trade worth making.
//
//  GateKernelUI is linked by exactly the two targets that render a report: the
//  app (`App/Screens/StatsScreen.swift`) and the GateReport extension
//  (`Extensions/Report/TotalActivityReport.swift`). Both already import SwiftUI.
//
//  The raw value must match on both sides or the system silently renders
//  nothing: the app's `DeviceActivityReport(.totalActivity, filter:)` is matched
//  against the extension's `DeviceActivityReportScene.context` by this string
//  (docs/02-api-reference.md §9). Deriving it from `GateID.namespace` is what
//  keeps the two ends from drifting by a character.
//

import DeviceActivity
import GateKernel
import SwiftUI

#if os(iOS)
public extension DeviceActivityReport.Context {

    /// The daily total-activity report, rendered by
    /// `Extensions/Report/TotalActivityReport.swift`
    /// (docs/06-build-plan.md step 1.7; docs/04-product-spec.md V2-5).
    ///
    /// Raw value: `"gate.totalActivity"`.
    nonisolated static var totalActivity: Self {
        Self(GateID.namespace + "totalActivity")
    }
}
#endif
