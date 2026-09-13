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
//  PREREQUISITE — READ BEFORE RUNNING `make test`
//
//  `Kernel/Identifiers.swift` currently does this, unconditionally:
//
//      import Foundation
//      import ManagedSettings
//      import DeviceActivity
//
//  Every other file in `Kernel/` already fences its SDK usage
//  (`#if canImport(ManagedSettings)`, `#if canImport(DeviceActivity)`,
//  `#if canImport(CryptoKit)`, `#if canImport(os)`) precisely so that the pure
//  layer compiles off-device. `Identifiers.swift` is the one that does not — and
//  it is the file that defines `GateID` and `GateLimits`, which every model type
//  reads, so it cannot simply be excluded from the target.
//
//  The Screen Time frameworks are **iOS / iPadOS / Mac Catalyst only**
//  (docs/02-api-reference.md §1; docs/03-hard-constraints.md #9: *"macOS is not
//  available… Target iOS + iPadOS only."*). `canImport(ManagedSettings)` is
//  therefore false on a native macOS host and on Linux — i.e. on every host
//  `swift test` can actually run on. Until those two imports and the three SDK
//  extensions below them (`ManagedSettingsStore.Name`, `DeviceActivityName`,
//  `DeviceActivityReport.Context`) are wrapped in `#if canImport(…)`, this
//  package will not build, and the failure will be at `Identifiers.swift` rather
//  than anywhere in `Tests/`.
//
//  That is a one-file, ~6-line change, it costs the shipping build nothing (the
//  guards are all true on iOS), and it is the last thing standing between this
//  repo and a green `make test`. It is deliberately NOT made here: this manifest
//  does not own that file.
//
//  Once the guards land, the same target also builds on Linux, because the only
//  other SDK-bound files — `Kernel/Store/{GateStateStore,InboxStore,LockClock}.swift`
//  and the `#if canImport(os)` islands that depend on them — are already fenced,
//  and the test files here fence their own suites to match.
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
