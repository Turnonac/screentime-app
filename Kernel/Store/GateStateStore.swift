//
//  GateStateStore.swift
//  GateKernel
//
//  The source of truth for `GateState`, behind a protocol.
//
//  Build plan: docs/06-build-plan.md step 3.2.
//
//  WHY THE PROTOCOL EXISTS — the one thing to understand about this file.
//  docs/05-architecture.md records an unresolved contradiction: Foqos ships in
//  production writing to `UserDefaults(suiteName:)` from a `ShieldActionDelegate`
//  and it works, while multiple other reports say writes from extensions return
//  success and never propagate, logging
//  "Using kCFPreferencesAnyUser with a container is only allowed for System
//  Containers". The call is an atomic property-list file in the App Group
//  container, because a `PropertyListDecoder` decode is cheaper than the
//  CFPreferences machinery under the monitor's 6 MB ceiling
//  (docs/03-hard-constraints.md #31), because `NSFileCoordinator` gives explicit
//  cross-process ordering that `UserDefaults` does not, and because the failure
//  mode of a flaky `UserDefaults` write is a *silently unenforced block* — the
//  one failure this product cannot have.
//
//  That call is marked as a week-1 on-device validation task
//  (docs/06-build-plan.md step 2.5(c)). ``UserDefaultsStateStore`` below is the
//  fallback, written and ready, so that if coordinated file writes misbehave on
//  device the swap is one line in the app's composition root and **no caller
//  changes at all**. That is the entire reason ``StateStoring`` exists; it is not
//  abstraction for its own sake.
//
//  RULES FOR THIS FILE
//  1. Foundation + os only. Linked into GateActivityMonitor (6 MB ceiling).
//     `os.Logger` is mandatory rather than optional: `print()` is invisible from
//     an extension (docs/06-build-plan.md step 4.1). `Logger` wraps an already
//     loaded libsystem_trace handle; it costs nothing against the ceiling.
//  2. `GateState` is written by the **app only**. Extensions read it and append
//     to `inbox/` (docs/05-architecture.md, single-writer discipline). ``save``
//     enforces that in debug and reports it as a fault in release.
//

import Foundation
import os

/// Computed, not a stored global `let`: `Logger` is an SDK type whose `Sendable`
/// audit we do not want to depend on, and a stored global of such a type is a
/// Swift 6 strict-concurrency error. Same reasoning as
/// `ManagedSettingsStore.Name.solid` in `Kernel/Identifiers.swift`. Hoist it into
/// a local before a loop.
private var storeLog: Logger {
    Logger(subsystem: GateID.Subsystem.kernel, category: "state-store")
}

// MARK: - StateStoring

/// Persistence for ``GateState``.
///
/// Two shipped implementations — ``FileStateStore`` (the call) and
/// ``UserDefaultsStateStore`` (the fallback, see the file header) — plus
/// whatever in-memory fake `Tests/GateKernelTests` needs
/// (docs/06-build-plan.md step 3.11; `DeviceActivityCenter`,
/// `ManagedSettingsStore` and `AuthorizationCenter` are all unusable in a test
/// process, so every kernel test injects fakes).
///
/// `Sendable` because a single store instance is shared between the app's
/// `@MainActor` model and the non-isolated `Reconciler` the monitor calls; both
/// implementations are safe to use from any thread.
public protocol StateStoring: Sendable {

    /// Reads the persisted state.
    ///
    /// - Throws: ``StateStoreError/stateMissing`` when nothing has ever been
    ///   persisted — a genuine first run. Every other failure is a real error
    ///   and must not be treated as "no rules": see ``load(orDefault:)``.
    func load() throws -> GateState

    /// Persists the state, replacing what was there.
    ///
    /// Must be atomic from a reader's point of view: a concurrent reader in
    /// another process sees either the whole previous state or the whole new
    /// one. Bumps the generation beacon on success, and only on success.
    func save(_ state: GateState) throws

    /// A cheap change beacon: a monotonically increasing integer bumped by every
    /// successful ``save(_:)``.
    ///
    /// This is the *only* thing `UserDefaults(suiteName:)` holds in the shipped
    /// design (docs/05-architecture.md). It lets the monitor skip a decode when
    /// nothing has changed since its last callback. It is an optimization and
    /// never a correctness input: every monitor callback is written assuming a
    /// cold start and must be idempotent (docs/05-architecture.md, enforcement
    /// layering), so a beacon that is stale, reset, or stuck at zero costs a
    /// redundant decode and nothing else.
    var generation: Int { get }

    /// Removes the persisted state.
    ///
    /// Part of the teardown flow: shields can persist after the app is deleted
    /// with no UI to remove them (docs/03-hard-constraints.md #37), so Gate
    /// offers a prominent "remove everything" path. That path must *also* call
    /// `LockClock.eraseKeychain()` explicitly — the lock deliberately outlives
    /// this container (docs/04-product-spec.md V1-3).
    func erase() throws
}

public extension StateStoring {

    /// Beacon-less default, for in-memory fakes.
    var generation: Int { 0 }

    /// No-op default, for in-memory fakes that have nothing durable to remove.
    func erase() throws {}

    /// ``load()``, substituting `fallback` **only** on a genuine first run.
    ///
    /// The asymmetry is deliberate and load-bearing. Returning an empty
    /// `GateState` because a decode failed would make the next reconcile write
    /// empty shield sets and unblock every rule — the silent-unenforcement
    /// failure the whole persistence design exists to avoid. A corrupt file
    /// must surface to the user as an error and a recovery flow, so every error
    /// other than ``StateStoreError/stateMissing`` is rethrown.
    func load(orDefault fallback: @autoclosure () -> GateState) throws -> GateState {
        do {
            return try load()
        } catch StateStoreError.stateMissing {
            return fallback()
        }
    }

    /// Returns the state only if the beacon has moved since `generation`.
    ///
    /// The monitor's hot path: `nil` means "nothing changed, the plan you
    /// already have is current". Callers must still be correct when this
    /// returns `nil` for a state that *did* change — see ``generation``.
    func loadIfChanged(since generation: Int) throws -> (state: GateState, generation: Int)? {
        let current = self.generation
        guard current != generation else { return nil }
        return (try load(), current)
    }

    /// Read–modify–write in one call, substituting `fallback` on a first run.
    ///
    /// There is no cross-process lock here and none is needed: the app is the
    /// single writer of `GateState` (docs/05-architecture.md), and within the
    /// app every mutation goes through the `@MainActor` `AppModel`. Extensions
    /// append to `inbox/` instead (`Kernel/Store/InboxStore.swift`).
    @discardableResult
    func mutate(
        orDefault fallback: @autoclosure () -> GateState,
        _ body: (inout GateState) throws -> Void
    ) throws -> GateState {
        var state = try load(orDefault: fallback())
        try body(&state)
        try save(state)
        return state
    }
}

// MARK: - StateStoreError

/// Every way persistence can fail, as a `Sendable`, `Equatable` value.
///
/// Underlying errors are flattened to `String` on purpose: these values cross
/// isolation domains, are compared in tests, and are rendered on the debug
/// screen (docs/04-product-spec.md V1-11). Nothing here ever carries state
/// *content*.
public enum StateStoreError: Error, Equatable, Sendable, CustomStringConvertible {

    /// Nothing has ever been persisted. A first run, not a failure.
    case stateMissing

    /// The bytes are there but are not a `GateState`.
    ///
    /// Never recovered from silently — see ``StateStoring/load(orDefault:)``.
    case decodeFailed(String)

    /// `GateState` could not be encoded. A programming error in the model.
    case encodeFailed(String)

    /// The read failed for a reason other than absence.
    case readFailed(String)

    /// The write failed.
    case writeFailed(String)

    /// The file exists but is unreadable right now because of data protection.
    ///
    /// Should be unreachable: Gate writes every container file with
    /// `completeUntilFirstUserAuthentication`
    /// (``AppGroupContainer/fileProtection``) precisely so that monitor
    /// callbacks delivered while the screen is locked can still read it. If this
    /// ever fires in the field, a file was written by something that did not go
    /// through ``AppGroupContainer/writingOptions``.
    case protectedWhileLocked(path: String)

    /// The App Group itself is unusable.
    case container(AppGroupContainer.ContainerError)

    /// `UserDefaults(suiteName:)` returned `nil` — the suite name is invalid or
    /// is the app's own bundle identifier. ``UserDefaultsStateStore`` only.
    case defaultsSuiteUnavailable(String)

    public var description: String {
        switch self {
        case .stateMissing:
            return "No Gate state has been persisted yet."
        case .decodeFailed(let detail):
            return "Persisted Gate state could not be decoded: \(detail)"
        case .encodeFailed(let detail):
            return "Gate state could not be encoded: \(detail)"
        case .readFailed(let detail):
            return "Gate state could not be read: \(detail)"
        case .writeFailed(let detail):
            return "Gate state could not be written: \(detail)"
        case .protectedWhileLocked(let path):
            return "\(path) is unreadable while the device is locked."
        case .container(let error):
            return error.description
        case .defaultsSuiteUnavailable(let suite):
            return "UserDefaults(suiteName: \"\(suite)\") returned nil."
        }
    }
}

// MARK: - PlistFile

/// One `Codable` value in one property-list file, written atomically and
/// optionally under `NSFileCoordinator`.
///
/// The shared primitive behind ``FileStateStore``, `Kernel/Store/InboxStore.swift`
/// and (for `shield.plist`) `Kernel/Enforcement/ShieldWriter.swift`, so that the
/// atomicity, protection-class and error-mapping rules are written once.
///
/// Encodes as a **binary** property list: smaller and faster to parse than XML,
/// which matters on the monitor's decode path. Decoding auto-detects the format,
/// so a hand-written XML file dropped in during debugging still loads.
public struct PlistFile<Value: Codable>: Sendable {

    /// The file's location.
    public let url: URL

    /// Whether reads and writes go through `NSFileCoordinator`.
    ///
    /// Coordination buys *ordering* between processes, not atomicity —
    /// atomicity comes from the `rename(2)` behind `Data.WritingOptions.atomic`
    /// (see ``AppGroupContainer/writingOptions``). It costs a synchronous hop
    /// through the coordination machinery, which is why the latency-bounded
    /// shield-configuration extension (docs/03-hard-constraints.md #33) and the
    /// per-event inbox files read and write uncoordinated.
    public let isCoordinated: Bool

    public init(url: URL, coordinated: Bool) {
        self.url = url
        self.isCoordinated = coordinated
    }

    // MARK: Existence

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Codec

    /// Encodes `value` as a binary property list.
    public static func encode(_ value: Value) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(value)
        } catch {
            throw StateStoreError.encodeFailed(String(describing: error))
        }
    }

    /// Decodes a property list of either format.
    public static func decode(_ data: Data) throws -> Value {
        do {
            return try PropertyListDecoder().decode(Value.self, from: data)
        } catch {
            throw StateStoreError.decodeFailed(String(describing: error))
        }
    }

    // MARK: Read

    /// Reads and decodes.
    public func read() throws -> Value {
        try Self.decode(try readData())
    }

    /// Reads the raw bytes.
    ///
    /// - Throws: ``StateStoreError/stateMissing`` if the file is absent.
    public func readData() throws -> Data {
        guard isCoordinated else { return try readDirect() }

        var coordinatorError: NSError?
        var outcome: Result<Data, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { target in
            outcome = Result { try Self.rawRead(target) }
        }

        if let outcome { return try outcome.get() }

        // The coordinator never ran the accessor. This is the documented risk of
        // coordinating inside an extension — the other process can hold the
        // file long enough for the coordinator to give up — so fall back to an
        // uncoordinated read rather than reporting "no state" and unenforcing a
        // block. A stale read is recoverable; a missing one is not.
        storeLog.fault("""
            file coordination failed for read of \(url.lastPathComponent, privacy: .public): \
            \(coordinatorError?.localizedDescription ?? "unknown", privacy: .public) — \
            falling back to an uncoordinated read
            """)
        return try readDirect()
    }

    private func readDirect() throws -> Data {
        try Self.rawRead(url)
    }

    private static func rawRead(_ target: URL) throws -> Data {
        do {
            return try Data(contentsOf: target)
        } catch let error as CocoaError {
            switch error.code {
            case .fileNoSuchFile, .fileReadNoSuchFile:
                throw StateStoreError.stateMissing
            case .fileReadNoPermission:
                throw StateStoreError.protectedWhileLocked(path: target.path)
            default:
                throw StateStoreError.readFailed(String(describing: error))
            }
        } catch {
            throw StateStoreError.readFailed(String(describing: error))
        }
    }

    // MARK: Write

    /// Encodes and writes. Returns the number of bytes written.
    @discardableResult
    public func write(_ value: Value) throws -> Int {
        let data = try Self.encode(value)
        try writeData(data)
        return data.count
    }

    /// Writes raw bytes atomically, with Gate's protection class.
    public func writeData(_ data: Data) throws {
        guard isCoordinated else { return try writeDirect(data) }

        var coordinatorError: NSError?
        var accessorError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { target in
            do {
                try data.write(to: target, options: AppGroupContainer.writingOptions)
            } catch {
                accessorError = error
            }
        }

        if let accessorError {
            throw StateStoreError.writeFailed(String(describing: accessorError))
        }
        guard let coordinatorError else { return }

        // Same reasoning as the read path, and safer: the atomic rename does not
        // need the coordinator to be correct, only to be ordered.
        storeLog.fault("""
            file coordination failed for write of \(url.lastPathComponent, privacy: .public): \
            \(coordinatorError.localizedDescription, privacy: .public) — \
            falling back to an uncoordinated atomic write
            """)
        try writeDirect(data)
    }

    private func writeDirect(_ data: Data) throws {
        do {
            try data.write(to: url, options: AppGroupContainer.writingOptions)
        } catch {
            throw StateStoreError.writeFailed(String(describing: error))
        }
    }

    // MARK: Remove

    /// Deletes the file. Absence is success.
    public func delete() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            throw StateStoreError.writeFailed(String(describing: error))
        }
    }

    /// Renames the file out of the way and returns where it went.
    ///
    /// Never called automatically on a decode failure. Losing the bytes loses
    /// every rule the user configured, so the app surfaces the error first and
    /// only quarantines when the user chooses to start over
    /// (docs/04-product-spec.md V1-9 is the equivalent flow for tokens).
    @discardableResult
    public func quarantine(stamp: String) throws -> URL {
        let destination = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).\(stamp).corrupt")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw StateStoreError.writeFailed(String(describing: error))
        }
        return destination
    }
}

// MARK: - DefaultsSuite

/// A `Sendable` handle on the App Group's `UserDefaults` suite.
///
/// A one-property wrapper rather than a stored `UserDefaults` on each type that
/// needs one. `UserDefaults` is documented as thread-safe, but whether the SDK
/// has *annotated* it `Sendable` has varied across Xcode releases, and this
/// module is compiled with `SWIFT_STRICT_CONCURRENCY = complete`. Asserting the
/// guarantee once, here, with a reason attached, keeps every other type in this
/// file conforming to `Sendable` by ordinary checking rather than by assertion.
public final class DefaultsSuite: @unchecked Sendable {

    /// The suite name — `GateID.appGroup` in production.
    public let name: String

    /// The suite. Thread-safe and process-safe by contract; see the type's note.
    public let defaults: UserDefaults

    /// Opens the suite, or returns `nil` if `UserDefaults(suiteName:)` does —
    /// which happens when the name is invalid or is the app's own bundle
    /// identifier.
    public init?(name: String) {
        guard let defaults = UserDefaults(suiteName: name) else { return nil }
        self.name = name
        self.defaults = defaults
    }

    /// Injection point for tests, which pass a throwaway suite.
    public init(name: String, defaults: UserDefaults) {
        self.name = name
        self.defaults = defaults
    }

    /// The App Group suite, or `nil`.
    public static func appGroup() -> DefaultsSuite? {
        DefaultsSuite(name: GateID.appGroup)
    }
}

// MARK: - StateGenerationBeacon

/// The single integer `UserDefaults(suiteName:)` holds in the shipped design.
///
/// docs/05-architecture.md: *"UserDefaults(suite) ← ONLY: stateGeneration: Int
/// (cheap change beacon)"*. Everything else lives in the container.
///
/// Only the app bumps it, because only the app writes `GateState`, so the
/// read-modify-write below has exactly one writer and needs no locking. A
/// process that fails to see a bump loses an optimization, not correctness.
///
/// Note for docs/06-build-plan.md step 7.1: this is App-Group `UserDefaults`, so
/// every `PrivacyInfo.xcprivacy` must declare
/// `NSPrivacyAccessedAPICategoryUserDefaults` with reason **`1C8F.1`** — the
/// App-Group-shared reason, *not* `CA92.1`.
public final class StateGenerationBeacon: Sendable {

    /// `nil` when the suite could not be opened. Tolerated rather than fatal:
    /// the beacon degrades to a constant zero, which costs a redundant decode
    /// per callback and nothing else. See ``StateStoring/generation``.
    private let suite: DefaultsSuite?

    /// The key holding the generation counter.
    public static let defaultsKey = "gate.stateGeneration"

    /// Opens the App Group suite.
    public init(suiteName: String = GateID.appGroup) {
        let suite = DefaultsSuite(name: suiteName)
        if suite == nil {
            storeLog.error("""
                UserDefaults(suiteName: \(suiteName, privacy: .public)) returned nil — \
                the change beacon is disabled; every reader will decode state on every callback
                """)
        }
        self.suite = suite
    }

    /// Injection point for tests, and for sharing one suite with
    /// ``UserDefaultsStateStore``.
    public init(suite: DefaultsSuite?) {
        self.suite = suite
    }

    /// The current generation, or `0` if the suite is unavailable.
    ///
    /// `UserDefaults.integer(forKey:)` returns `0` for a missing key, which is
    /// exactly the right answer here: a reader that has never seen a bump and a
    /// store that has never been written agree.
    public var current: Int {
        suite?.defaults.integer(forKey: Self.defaultsKey) ?? 0
    }

    /// Increments and returns the new value. Call **after** a successful write,
    /// never before, so that a new generation always implies new bytes on disk.
    @discardableResult
    public func bump() -> Int {
        guard let defaults = suite?.defaults else { return 0 }
        let next = defaults.integer(forKey: Self.defaultsKey) &+ 1
        defaults.set(next, forKey: Self.defaultsKey)
        return next
    }

    /// Clears the counter. Teardown only.
    public func reset() {
        suite?.defaults.removeObject(forKey: Self.defaultsKey)
    }
}

// MARK: - FileStateStore

/// The shipped ``StateStoring``: an atomic property-list file in the App Group
/// container, with `NSFileCoordinator` for cross-process ordering.
///
/// docs/05-architecture.md, persistence decision. See the file header for why
/// this and not `UserDefaults`, and for what ``UserDefaultsStateStore`` is for.
public final class FileStateStore: StateStoring {

    /// Every stored property is immutable and `Sendable`, so the `Sendable`
    /// requirement `StateStoring` inherits is satisfied by ordinary checking.
    /// The mutable state this type coordinates lives in the filesystem, which
    /// provides its own cross-process synchronization.
    private let file: PlistFile<GateState>
    private let beacon: StateGenerationBeacon
    private let enforcesSingleWriter: Bool

    /// Where the state lives. Exposed for the debug screen
    /// (docs/04-product-spec.md V1-11).
    public var fileURL: URL { file.url }

    // MARK: Init

    /// Opens `state.plist` in the App Group container.
    ///
    /// - Parameter coordinated: whether to use `NSFileCoordinator`. Leave this
    ///   `true`. Pass `false` only for a process that cannot afford to block on
    ///   another process's coordinated write — and note that the atomic write
    ///   makes even an uncoordinated reader safe from torn reads; it only makes
    ///   it possible to read a version that is one write old.
    /// - Throws: ``StateStoreError/container(_:)`` if the App Group is not usable
    ///   here. Loud by design: docs/05-architecture.md sketches a force-unwrap,
    ///   and a crash inside a monitor callback is indistinguishable to the user
    ///   from the block silently not working.
    public convenience init(coordinated: Bool = true) throws {
        let stateURL: URL
        do {
            stateURL = try AppGroupContainer.stateURL
        } catch let error as AppGroupContainer.ContainerError {
            throw StateStoreError.container(error)
        }
        self.init(
            stateURL: stateURL,
            beacon: StateGenerationBeacon(),
            coordinated: coordinated
        )
    }

    /// Designated initializer. Tests point this at a temporary directory.
    public init(
        stateURL: URL,
        beacon: StateGenerationBeacon,
        coordinated: Bool = true,
        enforcesSingleWriter: Bool = true
    ) {
        self.file = PlistFile(url: stateURL, coordinated: coordinated)
        self.beacon = beacon
        self.enforcesSingleWriter = enforcesSingleWriter
    }

    // MARK: StateStoring

    public func load() throws -> GateState {
        try file.read()
    }

    public func save(_ state: GateState) throws {
        assertSingleWriter()

        let bytes = try file.write(state)

        // A warning, never a failure. docs/05-architecture.md budgets `GateState`
        // at 8 KB because the monitor decodes it on every callback under a 6 MB
        // ceiling, and `FamilyActivitySelection` blobs are large "especially if
        // you use includeEntireCategory". Refusing to persist would be worse
        // than a slow decode: it would strand the user's configuration.
        if bytes > GateLimits.maxStateBytes {
            storeLog.warning("""
                GateState is \(bytes, privacy: .public) bytes, over the \
                \(GateLimits.maxStateBytes, privacy: .public)-byte budget — \
                store FamilyActivitySelections once keyed by rule ID and reference them by ID
                """)
        }

        let generation = beacon.bump()
        storeLog.debug("""
            saved GateState: \(bytes, privacy: .public) bytes, \
            generation \(generation, privacy: .public)
            """)
    }

    public var generation: Int { beacon.current }

    public func erase() throws {
        assertSingleWriter()
        try file.delete()
        beacon.reset()
        storeLog.notice("erased GateState")
    }

    // MARK: Recovery

    /// Moves an undecodable `state.plist` aside so the app can start fresh.
    ///
    /// Only ever called from a user-facing recovery path, never automatically:
    /// see ``PlistFile/quarantine(stamp:)``.
    @discardableResult
    public func quarantineCorruptState() throws -> URL {
        let stamp = String(Int(Date().timeIntervalSince1970))
        let destination = try file.quarantine(stamp: stamp)
        beacon.reset()
        storeLog.fault("quarantined undecodable GateState to \(destination.lastPathComponent, privacy: .public)")
        return destination
    }

    // MARK: Single-writer discipline

    /// docs/05-architecture.md: the app is the only writer of `state.plist`;
    /// extensions append to `inbox/` instead.
    ///
    /// Three processes can race here and only one of them is allowed to write,
    /// so the invariant is worth a trap in development and a `fault` in
    /// production. It does not *refuse* the write: a release build that has
    /// found a reason to write from an extension should do it and leave
    /// evidence, not deadlock the user's configuration behind an assertion.
    private func assertSingleWriter() {
        guard enforcesSingleWriter, AppGroupContainer.isRunningInAppExtension else { return }
        storeLog.fault("""
            GateState written from an app extension \
            (\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public)) — \
            only Gate.app may write state.plist; extensions append to inbox/
            """)
        assertionFailure("GateState must only be written by Gate.app (docs/05-architecture.md).")
    }
}

// MARK: - UserDefaultsStateStore

/// The fallback ``StateStoring``: the whole state as one `Data` value in
/// `UserDefaults(suiteName:)`.
///
/// **This is the proven Foqos pattern, kept ready rather than kept theoretical.**
/// Foqos ships in production writing to an App Group `UserDefaults` suite from a
/// `ShieldActionDelegate`, and it works. Against that, multiple reports describe
/// writes from extensions that return success and never propagate, accompanied
/// by "Using kCFPreferencesAnyUser with a container is only allowed for System
/// Containers" (docs/05-architecture.md). The contradiction is unresolved on
/// paper and is resolved on a device at docs/06-build-plan.md step 2.5(c).
///
/// If that test goes badly for coordinated files, change one line in the app's
/// composition root:
/// ```swift
/// let store: any StateStoring = try UserDefaultsStateStore()
/// ```
/// Nothing else in the kernel, the app, or the extensions changes.
///
/// Two deliberate choices:
/// * One `Data` blob under one key, encoded by the same ``PlistFile`` codec, so
///   the two implementations have identical `Codable` semantics. Foqos stores
///   loose values; that would make the fallback a different data model rather
///   than a different transport, and the swap would stop being one line.
/// * No `synchronize()`. It has been a deprecated no-op since iOS 12 and does
///   not affect the CFPreferences container behavior above. Calling it would
///   only make the fallback look like it is doing something it is not.
public final class UserDefaultsStateStore: StateStoring {

    /// All three are immutable and `Sendable`; see the note on
    /// ``FileStateStore``. ``DefaultsSuite`` is where the `UserDefaults`
    /// thread-safety assertion is made, once.
    private let suite: DefaultsSuite
    private let key: String
    private let beacon: StateGenerationBeacon

    /// The key the whole encoded state sits under.
    public static let defaultsKey = "gate.state"

    /// Opens the App Group suite.
    ///
    /// - Throws: ``StateStoreError/defaultsSuiteUnavailable(_:)`` if
    ///   `UserDefaults(suiteName:)` returns `nil`, which happens when the suite
    ///   name is invalid or is the app's own bundle identifier.
    public convenience init(suiteName: String = GateID.appGroup) throws {
        guard let suite = DefaultsSuite(name: suiteName) else {
            throw StateStoreError.defaultsSuiteUnavailable(suiteName)
        }
        self.init(
            suite: suite,
            key: UserDefaultsStateStore.defaultsKey,
            beacon: StateGenerationBeacon(suite: suite)
        )
    }

    /// Designated initializer. Tests pass a throwaway suite.
    public init(suite: DefaultsSuite, key: String = UserDefaultsStateStore.defaultsKey, beacon: StateGenerationBeacon) {
        self.suite = suite
        self.key = key
        self.beacon = beacon
    }

    // MARK: StateStoring

    public func load() throws -> GateState {
        guard let data = suite.defaults.data(forKey: key) else {
            throw StateStoreError.stateMissing
        }
        return try PlistFile<GateState>.decode(data)
    }

    public func save(_ state: GateState) throws {
        let data = try PlistFile<GateState>.encode(state)

        if data.count > GateLimits.maxStateBytes {
            storeLog.warning("""
                GateState is \(data.count, privacy: .public) bytes, over the \
                \(GateLimits.maxStateBytes, privacy: .public)-byte budget
                """)
        }

        suite.defaults.set(data, forKey: key)

        // Read it straight back. This is the failure this fallback exists to
        // detect: a CFPreferences write that reports success and does not land.
        // It is one extra read of a value that is by budget under 8 KB and is
        // almost certainly still in the in-process cache, and it converts a
        // silently unenforced block into a thrown error.
        guard let readback = suite.defaults.data(forKey: key), readback == data else {
            throw StateStoreError.writeFailed(
                "UserDefaults(suiteName:) accepted the write but did not read it back — "
                + "the CFPreferences container issue described in docs/05-architecture.md"
            )
        }

        let generation = beacon.bump()
        storeLog.debug("""
            saved GateState to the defaults suite: \(data.count, privacy: .public) bytes, \
            generation \(generation, privacy: .public)
            """)
    }

    public var generation: Int { beacon.current }

    public func erase() throws {
        suite.defaults.removeObject(forKey: key)
        beacon.reset()
        storeLog.notice("erased GateState from the defaults suite")
    }
}
