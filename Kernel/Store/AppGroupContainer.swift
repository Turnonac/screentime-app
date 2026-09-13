//
//  AppGroupContainer.swift
//  GateKernel
//
//  Every path in the only supported channel between Gate.app and its four
//  extensions (docs/05-architecture.md, process/data-flow diagram).
//
//  Build plan: docs/06-build-plan.md step 3.2.
//
//  RULES FOR THIS FILE
//  1. Foundation only. This file is linked into GateActivityMonitor, which has a
//     6 MB hard memory ceiling and is jetsam-killed the instant it is exceeded
//     with no callback delivered (docs/03-hard-constraints.md #31).
//  2. **No force-unwrap of `containerURL(forSecurityApplicationGroupIdentifier:)`.**
//     docs/05-architecture.md sketches this type with a `!`. That is fine in a
//     sketch and wrong in the product: the call returns `nil` whenever the App
//     Group is missing from the running bundle's entitlements, is absent from
//     the provisioning profile, or is spelled differently in any of the four
//     places it appears. In the app that would be a launch crash; in an
//     extension it is a crash inside a system callback, which the user sees as
//     "the block silently stopped working" and which leaves no actionable
//     signal. Instead every accessor throws ``ContainerError`` and
//     ``diagnosticDescription()`` explains what to check.
//  3. All file protection is `completeUntilFirstUserAuthentication`, matching
//     the Keychain's `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
//     (docs/04-product-spec.md V1-3). `DeviceActivityMonitor` callbacks can be
//     delivered while the device is locked; under the stricter `.complete`
//     class the monitor would fail to read `state.plist` and silently do
//     nothing, which is exactly the failure this product cannot have.
//

import Foundation

// MARK: - AppGroupContainer

/// The App Group container: its URL, the three well-known paths inside it, and
/// the diagnostics you need when it is not there.
///
/// An uninhabited namespace, like ``GateID`` — there is nothing to instantiate.
///
/// Call shape is unchanged from the architecture sketch apart from `try`:
/// ```swift
/// let url = try AppGroupContainer.stateURL
/// ```
/// Read-only computed properties with `get throws` keep the sketch's spelling
/// while making the failure explicit at every call site.
public enum AppGroupContainer {

    // MARK: Identity

    /// The App Group identifier, read from the single constant in
    /// `Kernel/Identifiers.swift`. No other Swift file may spell this literal.
    public static var identifier: String { GateID.appGroup }

    // MARK: Well-known names

    /// `GateState`, property list, written **only** by the app
    /// (docs/05-architecture.md, single-writer discipline).
    public static let stateFileName = "state.plist"

    /// Pre-rendered shield copy and colors, one entry per rule. Written only by
    /// the app; read by `GateShieldConfiguration`, which is network-blocked and
    /// latency-bounded and must return in microseconds
    /// (docs/03-hard-constraints.md #33).
    public static let shieldFileName = "shield.plist"

    /// Append-only event directory. Written by extensions, drained by the app
    /// (see `Kernel/Store/InboxStore.swift`).
    public static let inboxDirectoryName = "inbox"

    // MARK: Errors

    /// Why the container could not be used.
    ///
    /// Deliberately carries `String`s rather than a wrapped `Error`, so the
    /// value stays `Sendable` and `Equatable` and can be handed across isolation
    /// domains, compared in tests, and rendered on the debug screen
    /// (docs/04-product-spec.md V1-11) without ceremony.
    public enum ContainerError: Error, Equatable, Sendable, CustomStringConvertible {

        /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
        /// returned `nil`. The App Group is not usable from this process.
        case unavailable(identifier: String)

        /// The container resolved but is not writable by this process.
        case notWritable(path: String)

        /// Creating a directory inside the container failed.
        case directoryCreationFailed(path: String, underlying: String)

        /// A path that must be a directory exists as a regular file.
        case notADirectory(path: String)

        public var description: String {
            switch self {
            case .unavailable(let identifier):
                return """
                    App Group "\(identifier)" is unavailable in this process. \
                    Check, in this order: (1) the running bundle's entitlements \
                    contain com.apple.security.application-groups with exactly \
                    this string — Config/Gate-App.entitlements for the app, \
                    Config/Gate-Extension.entitlements for all four extensions; \
                    (2) APP_GROUP in Config/Build.xcconfig matches \
                    GateID.appGroup (`make verify` asserts this); (3) the group \
                    is registered on every App ID in the developer portal and \
                    present in the provisioning profile the bundle was signed \
                    with; (4) casing matches everywhere — it is compared \
                    character-for-character.
                    """
            case .notWritable(let path):
                return "App Group container at \(path) is not writable by this process."
            case .directoryCreationFailed(let path, let underlying):
                return "Could not create \(path) in the App Group container: \(underlying)"
            case .notADirectory(let path):
                return "\(path) exists but is not a directory."
            }
        }
    }

    // MARK: Container

    /// The container URL, or `nil` if the App Group is not usable here.
    ///
    /// The non-throwing probe. Use it for "should I even offer this feature"
    /// checks; use ``url`` everywhere a failure needs a reason attached.
    public static var urlIfAvailable: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// The container URL.
    ///
    /// - Throws: ``ContainerError/unavailable(identifier:)``.
    public static var url: URL {
        get throws {
            guard let url = urlIfAvailable else {
                throw ContainerError.unavailable(identifier: identifier)
            }
            return url
        }
    }

    /// Whether the App Group resolves at all in this process.
    public static var isAvailable: Bool { urlIfAvailable != nil }

    // MARK: Paths

    /// `<container>/state.plist`.
    public static var stateURL: URL {
        get throws { try url.appendingPathComponent(stateFileName, isDirectory: false) }
    }

    /// `<container>/shield.plist`.
    public static var shieldURL: URL {
        get throws { try url.appendingPathComponent(shieldFileName, isDirectory: false) }
    }

    /// `<container>/inbox/`.
    ///
    /// The directory is *not* created as a side effect of reading this property
    /// — an accessor that touches the filesystem is a trap in the shield-action
    /// extension. Call ``ensureInboxDirectory()`` before writing.
    public static var inboxURL: URL {
        get throws { try url.appendingPathComponent(inboxDirectoryName, isDirectory: true) }
    }

    // MARK: Data protection

    /// The protection class for every file Gate writes into the container.
    ///
    /// `completeUntilFirstUserAuthentication` deliberately mirrors the Keychain's
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
    /// (`Kernel/Store/LockClock.swift`): both are readable after the first
    /// unlock following boot and neither leaves the device. Monitor callbacks
    /// arrive while the screen is locked; under `.complete` those reads would
    /// fail and the block would silently not apply.
    ///
    /// Computed rather than a stored `static let`: `FileProtectionType` is a
    /// `RawRepresentable` wrapper the SDK has not audited for `Sendable`, and a
    /// stored static of such a type is a Swift 6 strict-concurrency error. Same
    /// reasoning as `ManagedSettingsStore.Name.solid` in
    /// `Kernel/Identifiers.swift`; constructing it per access is free.
    public static var fileProtection: FileProtectionType {
        .completeUntilFirstUserAuthentication
    }

    /// The write options for every file Gate writes into the container.
    ///
    /// `.atomic` is what makes a concurrent reader safe without any locking:
    /// Foundation writes to a sibling temporary file and `rename(2)`s it into
    /// place, so another process sees either the complete previous file or the
    /// complete new one, never a torn prefix. `NSFileCoordinator` in
    /// `Kernel/Store/GateStateStore.swift` adds *ordering* on top of that; it is
    /// not what provides atomicity.
    public static var writingOptions: Data.WritingOptions {
        [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    }

    /// Attributes for every directory Gate creates in the container.
    public static var directoryAttributes: [FileAttributeKey: Any] {
        [.protectionKey: fileProtection]
    }

    // MARK: Directory creation

    /// Creates `inbox/` if it does not exist and returns its URL.
    ///
    /// Idempotent, and safe to call concurrently from several processes:
    /// `createDirectory(withIntermediateDirectories: true)` succeeds rather than
    /// failing when the directory already exists.
    @discardableResult
    public static func ensureInboxDirectory() throws -> URL {
        let directory = try inboxURL
        try ensureDirectory(at: directory)
        return directory
    }

    /// Creates a directory inside the container, with Gate's protection class.
    public static func ensureDirectory(at directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ContainerError.notADirectory(path: directory.path)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: directoryAttributes
            )
        } catch {
            // Lost a race with another process between `fileExists` and
            // `createDirectory`? Then the directory is there now and we are done.
            var raced: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &raced),
               raced.boolValue {
                return
            }
            throw ContainerError.directoryCreationFailed(
                path: directory.path,
                underlying: error.localizedDescription
            )
        }
    }

    // MARK: Preflight

    /// Resolves the container, checks it is writable, and creates `inbox/`.
    ///
    /// Call once from the app at launch, before the first reconcile, so that a
    /// misconfigured App Group surfaces as one legible error on a screen you
    /// control rather than as four extensions quietly doing nothing.
    ///
    /// Extensions should **not** call this: `GateShieldConfiguration` is
    /// latency-bounded (docs/03-hard-constraints.md #33) and the monitor should
    /// spend its 6 MB on the reconcile, not on directory bookkeeping. They read
    /// what the app has already created, and log if it is missing.
    public static func preflight() throws {
        let container = try url
        guard FileManager.default.isWritableFile(atPath: container.path) else {
            throw ContainerError.notWritable(path: container.path)
        }
        try ensureInboxDirectory()
    }

    // MARK: Process introspection

    /// Whether this code is running inside an `.appex` rather than in `Gate.app`.
    ///
    /// Used to enforce the single-writer discipline in
    /// `Kernel/Store/GateStateStore.swift`: the app is the only writer of
    /// `state.plist` and `shield.plist`; extensions only append to `inbox/`
    /// (docs/05-architecture.md).
    ///
    /// `Bundle.main` inside an app extension is the `.appex` bundle, not the
    /// host app, so the path extension is a reliable, allocation-free test that
    /// needs no entitlement and no Info.plist lookup.
    public static var isRunningInAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    // MARK: Diagnostics

    /// A multi-line, human-readable report on the container.
    ///
    /// Rendered verbatim by the debug screen (docs/04-product-spec.md V1-11) and
    /// safe to paste into a bug report: it contains paths, sizes and counts, and
    /// never any content. Nothing here is Screen Time data — Gate does not hold
    /// any (docs/03-hard-constraints.md #25, #30).
    ///
    /// Note for docs/06-build-plan.md step 7.1: reading
    /// `.contentModificationDateKey` below is a required-reason API. Every
    /// `PrivacyInfo.xcprivacy` must therefore declare
    /// `NSPrivacyAccessedAPICategoryFileTimestamp` with reason **`C617.1`**
    /// ("files inside the app container, app group container, or CloudKit
    /// container"), alongside `NSPrivacyAccessedAPICategoryUserDefaults` /
    /// `1C8F.1`. Declaring a category you do not hit is itself rejectable, so if
    /// this function is ever deleted, delete that declaration with it.
    public static func diagnosticDescription() -> String {
        var lines: [String] = []
        lines.append("App Group: \(identifier)")
        lines.append("process: \(isRunningInAppExtension ? "app extension" : "app") — \(Bundle.main.bundleIdentifier ?? "<no bundle id>")")

        guard let container = urlIfAvailable else {
            lines.append("container: UNAVAILABLE")
            lines.append("  " + ContainerError.unavailable(identifier: identifier).description)
            return lines.joined(separator: "\n")
        }

        lines.append("container: \(container.path)")
        lines.append("writable: \(FileManager.default.isWritableFile(atPath: container.path) ? "yes" : "NO")")
        lines.append("  \(stateFileName): \(describe(container.appendingPathComponent(stateFileName)))")
        lines.append("  \(shieldFileName): \(describe(container.appendingPathComponent(shieldFileName)))")

        let inbox = container.appendingPathComponent(inboxDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: inbox.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            lines.append("  \(inboxDirectoryName)/: \(contents.count) file(s) pending drain")
        } else {
            lines.append("  \(inboxDirectoryName)/: absent")
        }

        return lines.joined(separator: "\n")
    }

    /// One line describing a single file: size and modification date, or absent.
    private static func describe(_ fileURL: URL) -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return "absent" }
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map { "\($0) bytes" } ?? "size unknown"
        guard let modified = values?.contentModificationDate else { return size }
        return "\(size), modified \(ISO8601DateFormatter().string(from: modified))"
    }
}
