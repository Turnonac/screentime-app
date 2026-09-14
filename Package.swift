// swift-tools-version: 6.0
//
//  Package.swift
//  Gate
//
//  THIS PACKAGE EXISTS FOR `swift test` AND FOR NOTHING ELSE.
//
//  docs/05-architecture.md, "Module layer split", is unambiguous: **the shipping
//  GateKernel is an Xcode `framework` target, not a local SPM package.** SPM has
//  no first-class `APPLICATION_EXTENSION_API_ONLY`, the
//  `.unsafeFlags(["-fapplication-extension"])` workaround makes a package
//  unusable as a versioned dependency, and a known Xcode bug lets it override
//  the linking project's settings — the symptom being *"linking against a dylib
//  which is not safe for use in application extensions"* plus `UIApplication.shared`
//  compiling and then trapping inside the monitor. `project.yml` remains the
//  single source of truth for every shipped binary. **Never add this package as
//  a dependency of the generated Xcode project.**
//
//  What the same section permits is exactly this: *"If you want `swift test` on
//  Linux, keep a separate, strictly platform-agnostic SPM target with zero
//  Apple-framework imports."* That is what the test target below runs against,
//  and it is the only way the Kernel is testable at all — `AuthorizationCenter`,
//  `DeviceActivityCenter` and `ManagedSettingsStore` are all unusable in a test
//  process and there is no Simulator support for any Screen Time API
//  (docs/03-hard-constraints.md #11).
//
//  WHY THE MANIFEST IS AT THE REPO ROOT AND NOT IN Tests/
//  SwiftPM refuses a target whose `path` escapes the package root, so a
//  `Tests/Package.swift` could not reach `../Kernel`. It does, however, search
//  parent directories for a manifest, so the Makefile's `cd Tests && swift test`
//  (`make test`) finds this file and runs the same tests. One manifest, one
//  `.build`, and `make clean` already removes both.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHERE `make test` RUNS — READ BEFORE FILING A BUILD FAILURE
//
//  **macOS: yes. Linux: not yet.**
//
//  `Kernel/Identifiers.swift` used to import ManagedSettings and DeviceActivity
//  unconditionally, which broke this package on every host `swift test` can run
//  on. That is fixed: both imports and the three SDK extensions below them
//  (`ManagedSettingsStore.Name`, `DeviceActivityName`,
//  `DeviceActivityReport.Context`) are now behind `#if canImport(…)`, and the
//  Screen Time frameworks are iOS / iPadOS / Mac Catalyst only
//  (docs/02-api-reference.md §1; docs/03-hard-constraints.md #9), so on a native
//  macOS host every one of those guards is false and the pure layer compiles.
//
//  What that means for the tests: anything fenced on `canImport(ManagedSettings)`
//  or `canImport(DeviceActivity)` is NOT compiled here and cannot be tested here.
//  `Reconciler.reconcile` is the big one — it is the whole of
//  `#if canImport(ManagedSettings) && canImport(DeviceActivity) && canImport(os)`
//  — which is why the suites exercise the pure projections it calls
//  (`Reconciler.advance`, `Reconciler.fold`, `Ratchet`, `GrantEngine`,
//  `ScheduleBuilder`) rather than the pass itself. Full-pass coverage is a device
//  item (Docs/DEVICE-TEST-MATRIX.md), not a gap somebody forgot to fill.
//
//  Linux is still blocked, on `os` rather than on Screen Time:
//  `Kernel/Store/{LockClock,GateStateStore,InboxStore}.swift` import `os` at file
//  scope (LockClock also imports Security and CryptoKit), and `os` does not exist
//  off Apple platforms. Fencing those three would need a Logger shim rather than
//  a `#if` — they log from every code path — so it is a real piece of work and
//  not the ~6 lines the Identifiers fix was. The Makefile's `test` recipe
//  describes a Linux toolchain as supported; until that shim exists, read that as
//  an intention.
//  ─────────────────────────────────────────────────────────────────────────────
//

import PackageDescription

let package = Package(
    name: "Gate",

    // Deployment targets match Config/Build.xcconfig (IPHONEOS_DEPLOYMENT_TARGET
    // = 17.0). macOS is listed only so the package has a host platform to run
    // `swift test` on; nothing in Gate ships there (hard constraint #9).
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],

    products: [
        .library(name: "GateKernel", targets: ["GateKernel"])
    ],

    targets: [
        // The same sources `project.yml` compiles into GateKernel.framework.
        // No `exclude:` list: every file in Kernel/ is either Foundation-only or
        // fences its own SDK usage, and an exclude list here would silently
        // diverge from the shipping target's file set.
        //
        // Swift 6 language mode is the tools-version default, which matches
        // SWIFT_VERSION = 6.0 / SWIFT_STRICT_CONCURRENCY = complete in the
        // xcconfig — so a concurrency error surfaces here as well as in Xcode.
        .target(
            name: "GateKernel",
            path: "Kernel"
        ),

        // docs/06-build-plan.md step 3.11. Swift Testing (@Test / #expect),
        // which ships with the 6.0 toolchain and needs no dependency here.
        .testTarget(
            name: "GateKernelTests",
            dependencies: ["GateKernel"],
            path: "Tests/GateKernelTests"
        ),
    ]
)
