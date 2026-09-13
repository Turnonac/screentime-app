//
//  GateState.swift
//  GateKernel
//
//  The single persisted document: `state.plist` in the App Group container.
//
//  Also the home of three things every other model file depends on, because they
//  are serialization concerns and this is the serialization file:
//    - ``GateFingerprint``, the deterministic digest used for selection
//      fingerprints, token index keys and ``LockPolicy/configHash``;
//    - the lenient `KeyedDecodingContainer` helpers (`gateValue`, `gateOptional`,
//      `gateRaw`, `gateLossyArray`) every `init(from:)` in Kernel/Model/ uses;
//    - ``GateDecodeContext``, the optional diagnostics sink the debug screen
//      reads (docs/04-product-spec.md V1-11).
//
//  Build plan: docs/06-build-plan.md step 3.1.
//  Foundation only — see the header of Kernel/Model/Rule.swift.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  BUDGET, AND WHY IT IS A HARD NUMBER
//
//  `GateState` must stay under ``GateLimits/maxStateBytes`` (8 KB) encoded
//  (docs/05-architecture.md, persistence). `GateActivityMonitor` decodes this file
//  on every callback under a 6 MB jetsam ceiling, and a kill inside
//  `eventDidReachThreshold` means the block silently never applies
//  (docs/03-hard-constraints.md #31). The budget is met structurally, not by
//  hoping:
//
//    - `FamilyActivitySelection` blobs are NOT here. They live once in
//      ``SelectionTable`` (`selections.plist`) and are referenced by
//      ``SelectionRef`` — an id plus a ~120-byte ``SelectionDigest``.
//    - Pre-rendered shield copy is NOT here. It lives in ``ShieldCopyTable``
//      (`shield.plist`), which only the shield extension reads.
//    - Opaque tokens appear inline in exactly one place, ``ScopedTokens``, capped
//      at ``ScopedTokens/maxScopedTokens`` per grant.
//    - Terminal ``PendingChange``s and expired ``Grant``s are reclaimed by
//      ``pruned(now:)`` so history cannot grow without bound.
//
//  `GateStateStore` logs a warning past the budget rather than failing the write:
//  refusing to persist state would be strictly worse than a slow decode.
//  ─────────────────────────────────────────────────────────────────────────────
//

import Foundation

// MARK: - GateFingerprint

/// A deterministic, process-independent 64-bit digest, rendered as 16 lowercase
/// hex characters.
///
/// **Why not `Hashable`.** Swift seeds its hasher per process, so `hashValue` is
/// different in `Gate.app` and in `GateActivityMonitor.appex` for the same bytes.
/// Anything written to the App Group by one and read by the other has to use a
/// stable digest, and that rules out the standard library entirely.
///
/// **Why not SHA-256.** Three of the four places this is used run in a process
/// where CryptoKit is unavailable or unaffordable: the platform-agnostic SwiftPM
/// test target has no CryptoKit at all (docs/06-build-plan.md step 3.11), and the
/// monitor pays for every framework in its dyld closure against a 6 MB ceiling.
/// FNV-1a is eleven lines, allocation-free, and identical everywhere.
///
/// **This is not a security primitive and nothing in Gate treats it as one.** It
/// answers "are these the same bytes?" for a cooperative writer — our own app —
/// and nothing else. The one genuine secret in the product, the partner
/// passphrase, is protected by ``PasswordDigest`` and CryptoKit's SHA-256. An
/// adversary who can forge an FNV-1a collision in `shield.plist` gains the
/// ability to show themselves the wrong shield title, on a device where they
/// could have revoked Gate's authorization in four taps anyway
/// (docs/03-hard-constraints.md #14).
public enum GateFingerprint {

    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// The "no fingerprint recorded" sentinel.
    ///
    /// A real FNV-1a digest could in principle be all zeroes; the odds are 2⁻⁶⁴
    /// and the consequence would be one selection being considered unchanged when
    /// it changed, which the next foreground reconcile corrects. Not worth a
    /// wider type.
    public static let empty = "0000000000000000"

    public static func hex(_ data: Data) -> String {
        var hash = offsetBasis
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return render(hash)
    }

    public static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    /// Digest of several parts, joined by a separator that cannot occur in any of
    /// them, so that `["ab", "c"]` and `["a", "bc"]` cannot collide.
    public static func combine(_ parts: [String]) -> String {
        hex(parts.joined(separator: "\u{1F}"))
    }

    private static func render(_ value: UInt64) -> String {
        let digits: [Character] = Array("0123456789abcdef")
        var output = ""
        output.reserveCapacity(16)
        for shift in stride(from: 60, through: 0, by: -4) {
            output.append(digits[Int((value >> UInt64(shift)) & 0xF)])
        }
        return output
    }
}

// MARK: - Lenient decoding helpers

/// Diagnostics sink for a lenient decode.
///
/// Optional. Put one in `decoder.userInfo[.gateDecodeContext]` and the decode
/// records what it had to throw away; leave it out and the decode is silent and
/// allocation-free. `Gate.app` attaches one so the debug screen can say "2 rules
/// were unreadable" (docs/04-product-spec.md V1-11); the monitor never does,
/// because under a 6 MB ceiling a diagnostic you cannot display is pure cost.
///
/// `@unchecked Sendable` with a lock rather than an actor: `Decoder` is entirely
/// synchronous, so an `await` is not available at the point a note is recorded.
/// The lock makes the class safe to hand across isolation domains afterwards,
/// which is what a caller does when it carries the notes to the UI.
public final class GateDecodeContext: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [GateDecodeNote] = []

    public init() {}

    public func record(_ note: GateDecodeNote) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(note)
    }

    public var notes: [GateDecodeNote] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// True when the decode was completely clean.
    public var isClean: Bool { notes.isEmpty }
}

/// One thing a lenient decode had to discard.
public struct GateDecodeNote: Sendable, Equatable, Hashable {
    /// The field that lost elements, e.g. `"rules"`.
    public var field: String
    /// How many elements were dropped.
    public var droppedElements: Int

    public init(field: String, droppedElements: Int) {
        self.field = field
        self.droppedElements = droppedElements
    }
}

public extension CodingUserInfoKey {
    /// Key for an optional ``GateDecodeContext``.
    ///
    /// `CodingUserInfoKey.init(rawValue:)` is failable but only to satisfy
    /// `RawRepresentable`; it never returns `nil` for a literal.
    static let gateDecodeContext = CodingUserInfoKey(rawValue: "com.turnonac.gate.decodeContext")!
}

/// Wraps one array element so a failure to decode it drops that element instead
/// of the whole array.
///
/// `try? T(from: decoder)` is scoped to this element's decoder, and the unkeyed
/// container advances by exactly one element either way, so a bad element in the
/// middle of an array costs only itself.
private struct GateLossyElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {

    /// Decodes `key`, falling back to `fallback` if it is missing, null, or of
    /// the wrong type.
    ///
    /// This never throws. That is the entire point: a `state.plist` written by a
    /// newer build, or half-written by a process that was jetsammed mid-flush,
    /// must degrade field by field rather than leaving the user with no rules and
    /// no block.
    func gateValue<T: Decodable>(_ type: T.Type = T.self, forKey key: Key, default fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded ?? fallback
    }

    /// Decodes an optional `key`, yielding `nil` for missing, null or malformed.
    func gateOptional<T: Decodable>(_ type: T.Type = T.self, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    /// Decodes a `String`-backed enum, falling back for an unknown raw value.
    ///
    /// The fallback for each call site is chosen so that an unreadable value
    /// costs the user *more* friction, never less — an unreadable
    /// ``PendingChange/Status`` is `.pending`, an unreadable ``RuleMode`` is
    /// `.blocklist`. See each call site's comment.
    func gateRaw<T: RawRepresentable>(
        _ type: T.Type = T.self,
        forKey key: Key,
        default fallback: T
    ) -> T where T.RawValue == String {
        guard let raw = gateOptional(String.self, forKey: key) else { return fallback }
        return T(rawValue: raw) ?? fallback
    }

    /// Decodes an array, skipping elements that fail.
    func gateLossyArray<T: Decodable>(_ type: T.Type = T.self, forKey key: Key) -> [T] {
        gateLossyArrayCounting(T.self, forKey: key).values
    }

    /// ``gateLossyArray(_:forKey:)``, also reporting how many elements were lost,
    /// so `GateState` can record a ``GateDecodeNote``.
    func gateLossyArrayCounting<T: Decodable>(
        _ type: T.Type = T.self,
        forKey key: Key
    ) -> (values: [T], dropped: Int) {
        guard let wrapped = try? decodeIfPresent([GateLossyElement<T>].self, forKey: key),
              let elements = wrapped
        else {
            return ([], 0)
        }
        let values = elements.compactMap(\.value)
        return (values, elements.count - values.count)
    }
}

// MARK: - GateState

/// Everything Gate knows, in one atomically-written property list.
///
/// **Single writer.** `Gate.app` is the only process that may write this file.
/// Extensions read it and append to `inbox/`; the app compacts `inbox/` in on
/// every foreground reconcile (docs/05-architecture.md, single-writer
/// discipline). That rule is not a convention — three processes genuinely race,
/// and a lost write here is a silently unenforced block.
public struct GateState: Codable, Sendable, Equatable {

    /// Filename inside the App Group container. `AppGroupContainer.stateURL` is
    /// built from this constant.
    public static let fileName = "state.plist"

    /// Bump only when ``migrate(_:now:)`` gains a case that must run.
    public static let currentSchemaVersion = 1

    /// The key under which the change beacon lives in
    /// `UserDefaults(suiteName: GateID.appGroup)`.
    ///
    /// That suite holds **exactly this one integer** and nothing else
    /// (docs/05-architecture.md). It is a cheap "something changed" signal an
    /// extension can read without a coordinated file read; the file remains the
    /// source of truth precisely because `UserDefaults` writes from extensions
    /// are reported to silently not propagate, and the failure mode of a dropped
    /// write here would be an unenforced block.
    public static let generationDefaultsKey = "gate.stateGeneration"

    /// Soft ceiling on the encoded size. See the file header.
    public static let maxEncodedBytes = GateLimits.maxStateBytes

    // MARK: Identity and versioning

    /// Schema version of the file this value came from. `0` means "written before
    /// versioning existed", which no shipped build produces but a hand-edited or
    /// truncated file does.
    public var schemaVersion: Int

    /// Monotonic write counter, mirrored into the `UserDefaults` beacon under
    /// ``generationDefaultsKey``. Incremented by `GateStateStore` on every save.
    public var generation: Int

    /// Identifies this installation.
    ///
    /// Regenerated on a fresh install, which is what lets
    /// ``LockClockRecord/isFromPreviousInstall(currentInstallID:)`` detect a
    /// delete-and-reinstall and let the app say something true about it
    /// (docs/04-product-spec.md V1-3).
    public var installID: UUID

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: Configuration

    /// At most ``GateLimits/maxRules``.
    public var rules: [Rule]

    /// Exactly one Lock per install (docs/04-product-spec.md V1-3).
    public var lock: LockPolicy

    /// The App Group mirror of the Keychain deadline. The Keychain copy is
    /// authoritative when it is newer — see ``LockClockRecord/merge(appGroup:keychain:)``.
    public var lockClock: LockClockRecord?

    /// "Solid" mode: `store.application.denyAppInstallation`
    /// (docs/04-product-spec.md V1-8). Enabling is free; disabling goes through
    /// the Lock.
    ///
    /// Deliberately never accompanied by `denyAppRemoval`, which is device-wide,
    /// is only honoured under `.child` enrollment, and has been reported to get
    /// stuck on after uninstall (docs/03-hard-constraints.md #15).
    public var installProtectionEnabled: Bool

    public var grantPolicy: GrantPolicy

    // MARK: Runtime

    public var pendingChanges: [PendingChange]
    public var grants: [Grant]
    public var grantLedger: GrantLedger

    public var onboardingCompletedAt: Date?

    /// When `Reconciler` last completed. Surfaced on the debug screen; a stale
    /// value is the clearest symptom of the monitor extension never launching
    /// (docs/03-hard-constraints.md #32).
    public var lastReconciledAt: Date?

    /// When a `ManagedSettingsStore.TokenExpiryMessage` was last observed, or
    /// when `authorizationStatus` was last seen to be something other than
    /// `.approved`.
    ///
    /// Drives the recovery screen (docs/04-product-spec.md V1-9). Non-nil means
    /// some rule may be silently shielding nothing. Reselecting is a
    /// **tightening** and must never be gated behind the Lock, or the user is
    /// trapped outside their own blocks.
    public var tokenExpiryObservedAt: Date?

    public init(
        schemaVersion: Int = GateState.currentSchemaVersion,
        generation: Int = 0,
        installID: UUID = UUID(),
        createdAt: Date = .distantPast,
        updatedAt: Date = .distantPast,
        rules: [Rule] = [],
        lock: LockPolicy = .default,
        lockClock: LockClockRecord? = nil,
        installProtectionEnabled: Bool = false,
        grantPolicy: GrantPolicy = .default,
        pendingChanges: [PendingChange] = [],
        grants: [Grant] = [],
        grantLedger: GrantLedger = GrantLedger(),
        onboardingCompletedAt: Date? = nil,
        lastReconciledAt: Date? = nil,
        tokenExpiryObservedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.installID = installID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rules = rules
        self.lock = lock
        self.lockClock = lockClock
        self.installProtectionEnabled = installProtectionEnabled
        self.grantPolicy = grantPolicy
        self.pendingChanges = pendingChanges
        self.grants = grants
        self.grantLedger = grantLedger
        self.onboardingCompletedAt = onboardingCompletedAt
        self.lastReconciledAt = lastReconciledAt
        self.tokenExpiryObservedAt = tokenExpiryObservedAt
    }

    /// A fresh install: no rules, the default 15-minute Lock, ratchet on.
    public static func initial(now: Date, installID: UUID = UUID()) -> GateState {
        GateState(
            schemaVersion: GateState.currentSchemaVersion,
            generation: 0,
            installID: installID,
            createdAt: now,
            updatedAt: now,
            grantLedger: GrantLedger(used: 0, periodStart: now)
        )
    }

    // MARK: Accessors

    public func rule(id: UUID) -> Rule? {
        rules.first { $0.id == id }
    }

    public func ruleIndex(id: UUID) -> Int? {
        rules.firstIndex { $0.id == id }
    }

    public var ruleIDs: Set<UUID> { Set(rules.map(\.id)) }

    /// Rules whose own configuration puts them in force at `date`. Live grants
    /// subtract from these afterwards, in `Kernel/Enforcement/ShieldWriter.swift`.
    public func rulesInForce(at date: Date, in calendar: Calendar = .current) -> [Rule] {
        rules.filter { $0.shouldEnforce(at: date, in: calendar) }
    }

    /// Grants `ShieldWriter` must subtract right now.
    public func activeGrants(at now: Date) -> [Grant] {
        grants.active(at: now)
    }

    /// Queued loosenings still waiting on the Lock — the "Pending changes (2) —
    /// unlocks in 12m 04s" banner (docs/04-product-spec.md V1-4).
    public var openPendingChanges: [PendingChange] { pendingChanges.pending }

    /// Queued loosenings the Lock has released on elapsed time.
    public func ripePendingChanges(at now: Date) -> [PendingChange] {
        pendingChanges.ripe(at: now)
    }

    /// The next moment `Reconciler` must run to keep enforcement correct: the
    /// soonest of a ripening pending change and an expiring grant. Drives the
    /// `UNCalendarNotificationTrigger` backstops (docs/04-product-spec.md V1-10
    /// step 5), which exist because `intervalDidStart`/`intervalDidEnd` fire only
    /// when the device is in use (docs/03-hard-constraints.md #27) and the
    /// monitor may never launch at all (#32).
    ///
    /// Schedule boundaries are added by `Kernel/Engine/ScheduleBuilder.swift`,
    /// which owns calendar arithmetic; this covers only the two deadlines that
    /// live in state.
    public func nextDeadline(after now: Date) -> Date? {
        [pendingChanges.nextDeadline(after: now), grants.nextExpiry(after: now)]
            .compactMap { $0 }
            .min()
    }

    /// Whether the recovery flow should be offered (docs/04-product-spec.md V1-9).
    public var needsRecovery: Bool { tokenExpiryObservedAt != nil }

    public var hasCompletedOnboarding: Bool { onboardingCompletedAt != nil }

    // MARK: Pruning

    /// Drops resolved history that has aged out.
    ///
    /// Separate from ``migrate(_:now:)`` on purpose: migration is *structural*
    /// (it repairs a decoded file), pruning is *temporal* (it reclaims space as
    /// the clock advances). Conflating them would make migration's output
    /// depend on when it ran, which is exactly the property that makes a
    /// migration untestable.
    ///
    /// Called by `Reconciler` after applying ripe changes, so the pending-change
    /// history the user sees survives at least ``PendingChange/terminalRetention``.
    public func pruned(now: Date) -> GateState {
        var copy = self
        copy.pendingChanges.removeAll { $0.isExpired(at: now) }
        copy.grants.removeAll { grant in
            !grant.isActive(at: now) && grant.isExpired(at: now)
        }
        return copy
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case generation = "g"
        case installID = "inst"
        case createdAt = "c"
        case updatedAt = "u"
        case rules
        case lock
        case lockClock = "clock"
        case installProtectionEnabled = "solid"
        case grantPolicy = "gpol"
        case pendingChanges = "pending"
        case grants
        case grantLedger = "gledger"
        case onboardingCompletedAt = "onboarded"
        case lastReconciledAt = "reconciled"
        case tokenExpiryObservedAt = "expiry"
    }

    /// Lenient by construction.
    ///
    /// - **Unknown keys are ignored.** `Codable` asks only for the keys it knows,
    ///   so a field added by a newer build costs nothing here. What it *does*
    ///   cost is on the way back out — an older build re-encoding this value
    ///   would silently drop that field — which is why ``migrate(_:now:)`` flags
    ///   a future file with ``MigrationReport/isFromFuture`` and
    ///   `GateStateStore` must refuse to write over one.
    /// - **Missing keys take documented defaults**, never a trap and never a
    ///   throw. A state file that fails to decode is a state file that costs the
    ///   user every block they had configured.
    /// - **Malformed arrays lose only their bad elements**, via
    ///   ``KeyedDecodingContainer/gateLossyArrayCounting(_:forKey:)``.
    ///
    /// There is exactly one throwing path left: `try decoder.container(keyedBy:)`
    /// fails when the file is not a keyed container at all — a truncated or
    /// foreign file. `GateStateStore` treats that as "no state" and starts from
    /// ``initial(now:installID:)``, which is the only honest reading.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let context = decoder.userInfo[.gateDecodeContext] as? GateDecodeContext

        let rules = container.gateLossyArrayCounting(Rule.self, forKey: .rules)
        let pending = container.gateLossyArrayCounting(PendingChange.self, forKey: .pendingChanges)
        let grants = container.gateLossyArrayCounting(Grant.self, forKey: .grants)

        if let context {
            if rules.dropped > 0 {
                context.record(GateDecodeNote(field: "rules", droppedElements: rules.dropped))
            }
            if pending.dropped > 0 {
                context.record(GateDecodeNote(field: "pendingChanges", droppedElements: pending.dropped))
            }
            if grants.dropped > 0 {
                context.record(GateDecodeNote(field: "grants", droppedElements: grants.dropped))
            }
        }

        self.init(
            // `0` for a missing version, never `currentSchemaVersion`: claiming
            // a file is current when it does not say so would skip every repair
            // ``migrate(_:now:)`` exists to apply.
            schemaVersion: container.gateValue(Int.self, forKey: .schemaVersion, default: 0),
            generation: container.gateValue(Int.self, forKey: .generation, default: 0),
            installID: container.gateValue(UUID.self, forKey: .installID, default: UUID()),
            createdAt: container.gateValue(Date.self, forKey: .createdAt, default: .distantPast),
            updatedAt: container.gateValue(Date.self, forKey: .updatedAt, default: .distantPast),
            rules: rules.values,
            // An unreadable Lock decodes to the 15-minute default, not to "no
            // lock". There is no representable state in which loosening is free.
            lock: container.gateValue(LockPolicy.self, forKey: .lock, default: .default),
            lockClock: container.gateOptional(LockClockRecord.self, forKey: .lockClock),
            installProtectionEnabled: container.gateValue(
                Bool.self, forKey: .installProtectionEnabled, default: false
            ),
            grantPolicy: container.gateValue(GrantPolicy.self, forKey: .grantPolicy, default: .default),
            pendingChanges: pending.values,
            grants: grants.values,
            grantLedger: container.gateValue(
                GrantLedger.self, forKey: .grantLedger, default: GrantLedger()
            ),
            onboardingCompletedAt: container.gateOptional(Date.self, forKey: .onboardingCompletedAt),
            lastReconciledAt: container.gateOptional(Date.self, forKey: .lastReconciledAt),
            tokenExpiryObservedAt: container.gateOptional(Date.self, forKey: .tokenExpiryObservedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generation, forKey: .generation)
        try container.encode(installID, forKey: .installID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(rules, forKey: .rules)
        try container.encode(lock, forKey: .lock)
        try container.encodeIfPresent(lockClock, forKey: .lockClock)
        try container.encode(installProtectionEnabled, forKey: .installProtectionEnabled)
        try container.encode(grantPolicy, forKey: .grantPolicy)
        try container.encode(pendingChanges, forKey: .pendingChanges)
        try container.encode(grants, forKey: .grants)
        try container.encode(grantLedger, forKey: .grantLedger)
        try container.encodeIfPresent(onboardingCompletedAt, forKey: .onboardingCompletedAt)
        try container.encodeIfPresent(lastReconciledAt, forKey: .lastReconciledAt)
        try container.encodeIfPresent(tokenExpiryObservedAt, forKey: .tokenExpiryObservedAt)
    }
}

// MARK: - Migration

public extension GateState {

    /// A migrated state plus an account of what had to change.
    public struct Migrated: Sendable, Equatable {
        public let state: GateState
        public let report: MigrationReport

        public init(state: GateState, report: MigrationReport) {
            self.state = state
            self.report = report
        }
    }

    /// What ``GateState/migrate(_:now:)`` did.
    public struct MigrationReport: Sendable, Equatable, Hashable {

        /// The version the file claimed.
        public let fromSchemaVersion: Int
        /// The version the returned state carries.
        public let toSchemaVersion: Int

        /// The file was written by a **newer** build of Gate.
        ///
        /// When this is true, ``GateState/migrate(_:now:)`` returns the decoded
        /// state *completely unmodified* and applies no repairs. `GateStateStore`
        /// must then refuse to write, because this build's encoder would silently
        /// drop every field it does not know — including, potentially, a rule's
        /// enforcement configuration. Downgrading a user's blocks without telling
        /// them is the one failure this product cannot have.
        public let isFromFuture: Bool

        public let repairs: [Repair]

        public init(
            fromSchemaVersion: Int,
            toSchemaVersion: Int,
            isFromFuture: Bool,
            repairs: [Repair]
        ) {
            self.fromSchemaVersion = fromSchemaVersion
            self.toSchemaVersion = toSchemaVersion
            self.isFromFuture = isFromFuture
            self.repairs = repairs
        }

        /// Nothing had to change; the file was already canonical.
        public var isNoOp: Bool {
            repairs.isEmpty && fromSchemaVersion == toSchemaVersion && !isFromFuture
        }

        /// One structural repair. Rendered verbatim on the debug screen
        /// (docs/04-product-spec.md V1-11) — a migration that quietly deletes a
        /// user's rule and says nothing is indistinguishable from a bug.
        public enum Repair: Sendable, Equatable, Hashable {
            /// The file carried no version; adopted ``GateState/currentSchemaVersion``.
            case adoptedSchemaVersion(from: Int)
            /// The file is newer than this build. Nothing was touched.
            case refusedDowngrade(fileVersion: Int)
            case clampedLockDelay(from: TimeInterval, to: TimeInterval)
            case clampedGrantPolicy
            case clampedGrantLedger(from: Int, to: Int)
            case droppedDuplicateRules(count: Int)
            case droppedExcessRules(count: Int, limit: Int)
            case truncatedRuleNames(count: Int)
            case normalizedSortIndexes
            /// Pending changes whose target rule no longer exists.
            case droppedOrphanPendingChanges(count: Int)
            /// Grants whose rule no longer exists.
            case droppedOrphanGrants(count: Int)
            /// Selections referenced by a rule are checked by `SelectionStore`,
            /// not here; this records a rule whose ``SelectionRef`` was structurally
            /// unusable (an empty digest fingerprint), which routes the user to
            /// recovery rather than to a silently empty shield.
            case flaggedUnusableSelections(count: Int)
        }
    }

    /// Repairs a freshly decoded ``GateState`` into something every other part of
    /// the kernel may assume is well-formed.
    ///
    /// **Structural only, and therefore deterministic.** It does not expire
    /// grants, does not roll the grant ledger, and does not apply ripe pending
    /// changes — all of that is time-dependent and belongs to
    /// `Kernel/Engine/Reconciler.swift` (docs/06-build-plan.md step 3.10). `now`
    /// is used only to stamp ``GateState/updatedAt`` and to fill in a missing
    /// ``GateState/createdAt``. Given the same input, this returns the same
    /// output on any day, which is what makes
    /// `Tests/GateKernelTests/StateCodecTests.swift` able to assert on it.
    ///
    /// Invariants callers may rely on afterwards, unless ``MigrationReport/isFromFuture``:
    ///
    /// - `state.schemaVersion == GateState.currentSchemaVersion`
    /// - rule ids are unique and `rules.count <= GateLimits.maxRules`
    /// - `rules[i].sortIndex == i`
    /// - `lock.delay` is within `GateLimits.minLockDelay ... maxLockDelay`
    /// - every ``PendingChange`` with a ``PendingChange/ruleID`` names a rule that
    ///   exists, and every ``Grant`` names a rule that exists
    public static func migrate(_ decoded: GateState, now: Date) -> Migrated {
        let fileVersion = decoded.schemaVersion

        // A newer build wrote this. Touch nothing — not even a clamp — so that
        // whatever the caller does next, it is acting on the bytes that were
        // actually on disk.
        guard fileVersion <= GateState.currentSchemaVersion else {
            return Migrated(
                state: decoded,
                report: MigrationReport(
                    fromSchemaVersion: fileVersion,
                    toSchemaVersion: fileVersion,
                    isFromFuture: true,
                    repairs: [.refusedDowngrade(fileVersion: fileVersion)]
                )
            )
        }

        var state = decoded
        var repairs: [MigrationReport.Repair] = []

        // ── Versioning ───────────────────────────────────────────────────────
        if fileVersion < GateState.currentSchemaVersion {
            // v0 -> v1 is a pure adoption: v0 is "a file with no version key",
            // which no shipped build produces, so there is no field to rewrite.
            // Future versions add their transforms here, each guarded on
            // `fileVersion < n`, in ascending order, so that a file two versions
            // behind is carried forward through every step.
            repairs.append(.adoptedSchemaVersion(from: fileVersion))
            state.schemaVersion = GateState.currentSchemaVersion
        }

        if state.createdAt == .distantPast { state.createdAt = now }

        // ── Lock ─────────────────────────────────────────────────────────────
        let clampedDelay = LockPolicy.clampDelay(state.lock.delay)
        if clampedDelay != state.lock.delay {
            repairs.append(.clampedLockDelay(from: state.lock.delay, to: clampedDelay))
            state.lock.delay = clampedDelay
        }

        // ── Grant configuration ──────────────────────────────────────────────
        let canonicalPolicy = GrantPolicy(
            dailyLimit: state.grantPolicy.dailyLimit,
            defaultDuration: state.grantPolicy.defaultDuration,
            impulseDelay: state.grantPolicy.impulseDelay,
            usesLockDelay: state.grantPolicy.usesLockDelay
        )
        if canonicalPolicy != state.grantPolicy {
            repairs.append(.clampedGrantPolicy)
            state.grantPolicy = canonicalPolicy
        }

        // A ledger claiming more grants used than the limit allows is not
        // corruption — it is what lowering the daily limit mid-day produces, and
        // the honest reading is "you are out for today". Clamp it so
        // `remaining(under:)` cannot go negative, and record it so the debug
        // screen can show it happened.
        if state.grantLedger.used > state.grantPolicy.dailyLimit {
            repairs.append(.clampedGrantLedger(
                from: state.grantLedger.used, to: state.grantPolicy.dailyLimit
            ))
            state.grantLedger.used = state.grantPolicy.dailyLimit
        }

        // ── Rules ────────────────────────────────────────────────────────────
        var seen = Set<UUID>()
        var deduplicated: [Rule] = []
        deduplicated.reserveCapacity(state.rules.count)
        for rule in state.rules {
            // First occurrence wins. Two rules sharing an id would fight over one
            // ManagedSettingsStore and one DeviceActivityName, and the loser's
            // shield set would be silently overwritten on every reconcile.
            guard seen.insert(rule.id).inserted else { continue }
            deduplicated.append(rule)
        }
        if deduplicated.count != state.rules.count {
            repairs.append(.droppedDuplicateRules(count: state.rules.count - deduplicated.count))
        }

        // Order by the user's own arrangement before truncating, so that dropping
        // to the cap removes the rules at the bottom of their list rather than
        // whichever ones the plist happened to serialize last.
        deduplicated.sort { lhs, rhs in
            lhs.sortIndex == rhs.sortIndex ? lhs.createdAt < rhs.createdAt : lhs.sortIndex < rhs.sortIndex
        }

        if deduplicated.count > GateLimits.maxRules {
            repairs.append(.droppedExcessRules(
                count: deduplicated.count - GateLimits.maxRules, limit: GateLimits.maxRules
            ))
            deduplicated = Array(deduplicated.prefix(GateLimits.maxRules))
        }

        var truncatedNames = 0
        var unusableSelections = 0
        var needsSortNormalization = false
        for index in deduplicated.indices {
            if deduplicated[index].name.count > Rule.maxNameLength {
                deduplicated[index].name = String(deduplicated[index].name.prefix(Rule.maxNameLength))
                truncatedNames += 1
            }
            if let selection = deduplicated[index].selection,
               selection.digest.fingerprint == GateFingerprint.empty {
                unusableSelections += 1
            }
            if deduplicated[index].sortIndex != index {
                deduplicated[index].sortIndex = index
                needsSortNormalization = true
            }
        }
        if truncatedNames > 0 { repairs.append(.truncatedRuleNames(count: truncatedNames)) }
        if unusableSelections > 0 {
            repairs.append(.flaggedUnusableSelections(count: unusableSelections))
        }
        if needsSortNormalization { repairs.append(.normalizedSortIndexes) }

        state.rules = deduplicated
        let liveRuleIDs = state.ruleIDs

        // ── Referential integrity ────────────────────────────────────────────
        // A pending change or grant that names a rule which no longer exists can
        // never be applied and can never be expired against anything, so it is
        // pure weight inside an 8 KB budget. Install-wide operations
        // (`setLockDelay`, `revokeAuthorization`, …) have no ruleID and are kept.
        let keptPending = state.pendingChanges.filter { change in
            guard let ruleID = change.ruleID else { return true }
            return liveRuleIDs.contains(ruleID)
        }
        if keptPending.count != state.pendingChanges.count {
            repairs.append(.droppedOrphanPendingChanges(
                count: state.pendingChanges.count - keptPending.count
            ))
            state.pendingChanges = keptPending
        }

        let keptGrants = state.grants.filter { liveRuleIDs.contains($0.ruleID) }
        if keptGrants.count != state.grants.count {
            repairs.append(.droppedOrphanGrants(count: state.grants.count - keptGrants.count))
            state.grants = keptGrants
        }

        if !repairs.isEmpty { state.updatedAt = now }

        return Migrated(
            state: state,
            report: MigrationReport(
                fromSchemaVersion: fileVersion,
                toSchemaVersion: state.schemaVersion,
                isFromFuture: false,
                repairs: repairs
            )
        )
    }
}
