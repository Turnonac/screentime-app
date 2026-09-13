//
//  LockPolicy.swift
//  GateKernel
//
//  The Lock — Gate's entire differentiator (docs/04-product-spec.md V1-3).
//  Exactly one per install, configured once. Every *loosening* change is queued
//  behind it; every *tightening* change bypasses it entirely
//  (docs/04-product-spec.md V1-4).
//
//  Build plan: docs/06-build-plan.md step 3.1.
//
//  Foundation only, except for one `#if canImport(CryptoKit)` island that holds
//  the SHA-256 implementation of ``PasswordHashing``. See the note on
//  ``SaltedSHA256Hasher`` for why the hashing is behind a protocol rather than
//  called inline: the kernel is unit-tested as a platform-agnostic SwiftPM
//  package (docs/06-build-plan.md step 3.11) and `make test` is documented to run
//  on a Linux toolchain, where CryptoKit does not exist.
//

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - LockKind

/// How a loosening change can be authorized (docs/04-product-spec.md V1-3).
public enum LockKind: String, Codable, Sendable, Hashable, CaseIterable {

    /// Wait it out. Every loosening is queued with
    /// `earliestApplyAt = now + delay`. The default.
    case delay

    /// A passphrase set during the "hand your phone to someone" flow. No wait —
    /// but you do not hold the password.
    case password

    /// Password **or** wait out the delay, whichever comes first.
    case both

    /// Whether a correct password can release a pending change under this kind.
    public var acceptsPassword: Bool { self != .delay }

    /// Whether elapsed time alone can release a pending change under this kind.
    ///
    /// False for ``password``: a pending change under a pure partner lock never
    /// ripens on its own, so `Kernel/Engine/Ratchet.swift` must not set a finite
    /// `earliestApplyAt` for it. See ``LockPolicy/earliestApplyDate(from:)``.
    public var acceptsDelay: Bool { self != .password }
}

// MARK: - PasswordHashing

/// The one-way function behind a ``PasswordDigest``.
///
/// Injected rather than called inline for two reasons, in this order:
///
/// 1. **Testability.** `Tests/` is a platform-agnostic SwiftPM package so
///    `swift test` runs with no Xcode and no device (docs/06-build-plan.md step
///    3.11; the Makefile's `test` target documents a Linux toolchain as
///    supported). CryptoKit does not exist there. A test can inject a trivial
///    deterministic hasher and still exercise every branch of
///    ``LockPolicy/verify(password:)`` and the ratchet paths that depend on it.
/// 2. **Algorithm agility.** ``PasswordDigest/algorithm`` is stored next to the
///    digest, so a future hasher can be introduced without invalidating existing
///    digests: verification refuses a hasher whose algorithm does not match the
///    stored one, rather than silently comparing apples to oranges.
///
/// Conformers must be pure: same password and salt, same bytes, forever.
public protocol PasswordHashing: Sendable {
    /// The identifier recorded in ``PasswordDigest/algorithm``.
    var algorithm: PasswordDigest.Algorithm { get }
    /// Derives the stored digest. Must not be reversible and must depend on both
    /// inputs.
    func digest(password: String, salt: Data) -> Data
}

#if canImport(CryptoKit)
/// `SHA-256(salt || UTF-8(NFC(password)))` — the shipping hasher.
///
/// Salted SHA-256 is chosen over PBKDF2/scrypt/Argon2 deliberately and the
/// trade-off is worth stating plainly, because it is a security decision:
///
/// - The threat model for this field is **not** an attacker who has exfiltrated
///   the file. Under `.individual` authorization Apple deliberately removes the
///   anti-bypass protections and the user can revoke everything in about four
///   taps (docs/03-hard-constraints.md #13, #14). Anyone with the device and the
///   motivation does not need to crack a passphrase; they go to Settings.
/// - What the digest must actually do is stop the *owner* from reading their
///   partner's passphrase back out of `state.plist` on a whim — a plaintext or
///   reversible store would make the partner-lock feature a lie. A salted digest
///   does that.
/// - The salt is per-digest and 32 bytes, so a rainbow table is useless and two
///   installs with the same passphrase produce different digests.
///
/// If the partner lock ever becomes a server-backed feature (docs/04-product-spec.md
/// V2-6) this must be revisited — a digest that leaves the device needs a real
/// KDF with a work factor.
public struct SaltedSHA256Hasher: PasswordHashing {

    public init() {}

    public var algorithm: PasswordDigest.Algorithm { .saltedSHA256 }

    public func digest(password: String, salt: Data) -> Data {
        var input = Data()
        input.append(salt)
        // Canonical (NFC) composition: the same passphrase typed on a different
        // keyboard, or pasted from a different source, must hash the same. An
        // e-acute entered as one code point and as e + combining-acute are the
        // same string to the user and different bytes to SHA-256.
        input.append(contentsOf: Array(password.precomposedStringWithCanonicalMapping.utf8))
        return Data(SHA256.hash(data: input))
    }
}
#endif

// MARK: - PasswordDigest

/// A salted one-way digest of the partner passphrase. **Never the passphrase.**
public struct PasswordDigest: Codable, Sendable, Equatable, Hashable {

    /// Salt length in bytes.
    public static let saltByteCount = 32

    /// Longest optional hint. The hint is stored in plaintext by definition, so
    /// it is short and the UI must say what it is.
    public static let maxHintLength = 80

    /// Which one-way function produced ``digest``.
    ///
    /// Modelled as an open enum rather than a `String`-raw one so that a digest
    /// written by a newer build survives a round trip through an older build
    /// instead of decoding to a wrong-but-plausible algorithm and failing every
    /// verification with no explanation.
    public enum Algorithm: Sendable, Equatable, Hashable {
        /// `SHA-256(salt || UTF-8(NFC(password)))`.
        case saltedSHA256
        /// Written by a build that knew something this one does not. Verification
        /// always fails; ``LockPolicy/verify(password:)`` reports
        /// ``PasswordVerification/unsupportedAlgorithm`` so the UI can route the
        /// user to the delay path rather than telling them their password is
        /// wrong.
        case unsupported(String)

        public var identifier: String {
            switch self {
            case .saltedSHA256: "salted-sha256"
            case .unsupported(let raw): raw
            }
        }

        public init(identifier: String) {
            switch identifier {
            case "salted-sha256": self = .saltedSHA256
            default: self = .unsupported(identifier)
            }
        }

        /// False for every algorithm this build cannot compute.
        public var isSupported: Bool {
            if case .saltedSHA256 = self { return true }
            return false
        }
    }

    public var algorithm: Algorithm
    public var salt: Data
    public var digest: Data
    public var createdAt: Date

    /// Optional plaintext reminder, shown next to the password prompt. Never the
    /// password, never derived from it — the UI must reject a hint that contains
    /// the passphrase.
    public var hint: String?

    public init(
        algorithm: Algorithm,
        salt: Data,
        digest: Data,
        createdAt: Date,
        hint: String? = nil
    ) {
        self.algorithm = algorithm
        self.salt = salt
        self.digest = digest
        self.createdAt = createdAt
        self.hint = hint.map { String($0.prefix(PasswordDigest.maxHintLength)) }
    }

    /// Fresh cryptographically-random salt.
    ///
    /// `SystemRandomNumberGenerator` is the platform CSPRNG (`arc4random_buf` on
    /// Darwin), so this needs no CryptoKit and is therefore available to the
    /// platform-agnostic test target as well.
    public static func newSalt(byteCount: Int = PasswordDigest.saltByteCount) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: max(1, byteCount))
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        return Data(bytes)
    }

    /// Derives a digest with an explicit hasher.
    public static func make(
        password: String,
        salt: Data = PasswordDigest.newSalt(),
        hasher: some PasswordHashing,
        hint: String? = nil,
        now: Date
    ) -> PasswordDigest {
        PasswordDigest(
            algorithm: hasher.algorithm,
            salt: salt,
            digest: hasher.digest(password: password, salt: salt),
            createdAt: now,
            hint: hint
        )
    }

    /// Checks a candidate passphrase against this digest.
    ///
    /// Returns `false` — never `true` — when the stored ``algorithm`` is not the
    /// one `hasher` implements. Comparing a SHA-256 digest against bytes produced
    /// by some other function is meaningless, and "meaningless" must resolve to
    /// "denied" on a lock.
    public func verify(_ candidate: String, using hasher: some PasswordHashing) -> Bool {
        guard hasher.algorithm == algorithm else { return false }
        let derived = hasher.digest(password: candidate, salt: salt)
        return PasswordDigest.constantTimeEquals(derived, digest)
    }

    /// Length-independent, early-exit-free comparison.
    ///
    /// `Data == Data` short-circuits on the first differing byte, which leaks the
    /// length of the matching prefix through timing. That is a weak channel here
    /// (an attacker needs the unlocked device to submit guesses at all) but it is
    /// four lines to close and this is the one comparison in the product that
    /// guards a secret.
    ///
    /// The count check itself is not constant-time. It does not need to be: every
    /// digest from a given algorithm has a fixed length, so the comparison leaks
    /// nothing an attacker could not read off ``algorithm``.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private enum CodingKeys: String, CodingKey {
        case algorithm = "alg"
        case salt
        case digest = "d"
        case createdAt = "c"
        case hint = "hint"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A digest with no bytes is not repairable and must not decode to
        // something that could ever compare equal. Let it throw so the lossy
        // decoder drops the field and the lock falls back to its delay.
        let digest = try container.decode(Data.self, forKey: .digest)
        self.init(
            algorithm: Algorithm(
                identifier: container.gateValue(String.self, forKey: .algorithm, default: "")
            ),
            salt: container.gateValue(Data.self, forKey: .salt, default: Data()),
            digest: digest,
            createdAt: container.gateValue(Date.self, forKey: .createdAt, default: .distantPast),
            hint: container.gateOptional(String.self, forKey: .hint)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(algorithm.identifier, forKey: .algorithm)
        try container.encode(salt, forKey: .salt)
        try container.encode(digest, forKey: .digest)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(hint, forKey: .hint)
    }
}

#if canImport(CryptoKit)
public extension PasswordDigest {
    /// Convenience over ``make(password:salt:hasher:hint:now:)`` using the
    /// shipping ``SaltedSHA256Hasher``.
    static func make(password: String, hint: String? = nil, now: Date) -> PasswordDigest {
        make(password: password, salt: newSalt(), hasher: SaltedSHA256Hasher(), hint: hint, now: now)
    }

    /// Convenience over ``verify(_:using:)`` using the shipping hasher.
    func verify(_ candidate: String) -> Bool {
        verify(candidate, using: SaltedSHA256Hasher())
    }
}
#endif

// MARK: - PasswordVerification

/// The result of offering a passphrase to the Lock.
///
/// Three failure cases rather than a `Bool`, because the UI copy for each is
/// completely different and getting it wrong is a trust failure: telling someone
/// their password is wrong when the real problem is that this build cannot read
/// the digest would send them to delete-and-reinstall, which the Keychain lock
/// clock is specifically designed to defeat (docs/04-product-spec.md V1-3).
public enum PasswordVerification: Sendable, Equatable, Hashable {
    /// Correct passphrase. The caller may release the pending change.
    case accepted
    /// Wrong passphrase.
    case rejected
    /// This lock has no password configured — ``LockKind/delay`` only. The caller
    /// should not have shown a password field.
    case notConfigured
    /// The stored digest was produced by an algorithm this build does not
    /// implement (a newer version of Gate wrote it). Offer the delay path.
    case unsupportedAlgorithm
}

// MARK: - LockPolicy

/// The single Lock (docs/04-product-spec.md V1-3).
///
/// **Asymmetric change cost, which is the product.** Increasing ``delay`` is a
/// tightening and applies immediately. Decreasing it costs `oldDelay - newDelay`.
/// Changing ``kind`` is a loosening. Disabling ``isRatchetEnabled`` is a
/// loosening. The classification itself lives in `Kernel/Engine/Ratchet.swift`;
/// this type only holds the configuration and the arithmetic those rules need.
public struct LockPolicy: Codable, Sendable, Equatable, Hashable {

    public var kind: LockKind

    /// Seconds a queued loosening must wait. Always within
    /// `GateLimits.minLockDelay ... GateLimits.maxLockDelay` — the setter clamps,
    /// so no decode path and no UI path can produce a zero delay and quietly
    /// disable the product.
    public var delay: TimeInterval {
        didSet { delay = LockPolicy.clampDelay(delay) }
    }

    /// `nil` unless ``kind`` accepts a password.
    public var password: PasswordDigest?

    /// V1-4's single on/off switch, on by default.
    ///
    /// Lives on the Lock rather than on `GateState` because it is lock
    /// configuration: enabling it is a tightening, disabling it is a loosening
    /// that goes through the Lock, and it participates in ``configHash``. When
    /// off, *every* mutation is queued — including tightenings — which is a
    /// stricter, simpler mode some users prefer.
    public var isRatchetEnabled: Bool

    /// When the user last changed any of the above. Purely informational; the
    /// authority on "has the config changed" is ``configHash``.
    public var updatedAt: Date

    public init(
        kind: LockKind = .delay,
        delay: TimeInterval = GateLimits.defaultLockDelay,
        password: PasswordDigest? = nil,
        isRatchetEnabled: Bool = true,
        updatedAt: Date = .distantPast
    ) {
        self.kind = kind
        self.delay = LockPolicy.clampDelay(delay)
        self.password = password
        self.isRatchetEnabled = isRatchetEnabled
        self.updatedAt = updatedAt
    }

    /// The shipping default: 15-minute delay, ratchet on, no password.
    public static let `default` = LockPolicy()

    public static func clampDelay(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return GateLimits.defaultLockDelay }
        return min(max(value, GateLimits.minLockDelay), GateLimits.maxLockDelay)
    }

    /// When a loosening queued at `date` becomes applicable.
    ///
    /// `nil` for ``LockKind/password``: a pure partner lock never ripens on its
    /// own, and returning `now + delay` there would hand the user a silent
    /// bypass — wait fifteen minutes and the partner lock evaporates.
    /// `Kernel/Engine/Ratchet.swift` stores this verbatim in
    /// ``PendingChange/earliestApplyAt``, so the nil case is what makes
    /// ``PendingChange/isRipe(at:)`` correctly answer "never".
    public func earliestApplyDate(from date: Date) -> Date? {
        guard kind.acceptsDelay else { return nil }
        return date.addingTimeInterval(delay)
    }

    /// Checks a passphrase against this policy.
    ///
    /// - Parameter hasher: the one-way function to use. The CryptoKit-backed
    ///   convenience overload below is what ships.
    public func verify(password candidate: String, using hasher: some PasswordHashing) -> PasswordVerification {
        guard kind.acceptsPassword, let stored = password else { return .notConfigured }
        guard stored.algorithm.isSupported, stored.algorithm == hasher.algorithm else {
            return .unsupportedAlgorithm
        }
        return stored.verify(candidate, using: hasher) ? .accepted : .rejected
    }

    /// A stable fingerprint of everything that defines this Lock.
    ///
    /// Mirrored into the Keychain alongside the deadline (see ``LockClockRecord``)
    /// so that after a delete-and-reinstall the app can tell whether the deadline
    /// it found belongs to the Lock it is now configured with.
    ///
    /// **This hash never invalidates a deadline.** A mismatch sets
    /// ``LockClockRecord/hasConfigDrift(against:)`` and changes the copy the user
    /// sees; it must never be treated as a reason to drop the pending change,
    /// because "change the Lock config to clear your queued loosening" would be
    /// the single cleanest bypass in the product. That is also why the value is
    /// computed, not stored — a stored copy could drift from the fields it claims
    /// to summarize.
    ///
    /// Not a cryptographic commitment and not claimed to be one: it is
    /// ``GateFingerprint``, a deterministic non-cryptographic digest, chosen
    /// because it must produce identical output in the app, in the monitor
    /// extension, and in a Linux test process — CryptoKit is unavailable in the
    /// third. The security boundary is ``PasswordDigest``, not this.
    public var configHash: String {
        GateFingerprint.combine([
            "lock.v1",
            kind.rawValue,
            String(Int(delay.rounded())),
            isRatchetEnabled ? "ratchet" : "noratchet",
            password.map { digest in
                digest.algorithm.identifier
                    + ":" + GateFingerprint.hex(digest.salt)
                    + ":" + GateFingerprint.hex(digest.digest)
            } ?? "nopassword",
        ])
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "k"
        case delay = "delay"
        case password = "pw"
        case isRatchetEnabled = "ratchet"
        case updatedAt = "u"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let password = container.gateOptional(PasswordDigest.self, forKey: .password)

        // Unknown `kind` => the most restrictive reading that is still coherent
        // with what else is in the record. If a digest is present, a newer build
        // clearly intended a password to matter, so fall back to `.both` (which
        // honours both the password and the delay) rather than to `.delay`,
        // which would discard the partner's authority. With no digest there is
        // nothing to honour and `.delay` is the only usable answer.
        let kind: LockKind
        if let raw = container.gateOptional(String.self, forKey: .kind), let known = LockKind(rawValue: raw) {
            kind = known
        } else {
            kind = password == nil ? .delay : .both
        }

        self.init(
            kind: kind,
            // A missing or absurd delay falls back to the 15-minute default
            // rather than to zero. Zero would silently turn every loosening into
            // an instant one, which is the failure this product cannot have.
            delay: container.gateValue(TimeInterval.self, forKey: .delay, default: GateLimits.defaultLockDelay),
            password: password,
            isRatchetEnabled: container.gateValue(Bool.self, forKey: .isRatchetEnabled, default: true),
            updatedAt: container.gateValue(Date.self, forKey: .updatedAt, default: .distantPast)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(delay, forKey: .delay)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encode(isRatchetEnabled, forKey: .isRatchetEnabled)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

#if canImport(CryptoKit)
public extension LockPolicy {
    /// Convenience over ``verify(password:using:)`` with the shipping hasher.
    func verify(password candidate: String) -> PasswordVerification {
        verify(password: candidate, using: SaltedSHA256Hasher())
    }

    /// Returns a copy with a new partner passphrase and a ``kind`` that can
    /// actually use it.
    ///
    /// Setting a password is a **tightening** and applies immediately; removing
    /// one is a loosening (docs/04-product-spec.md V1-4). This helper therefore
    /// only sets — `Kernel/Engine/Ratchet.swift` owns removal.
    func settingPassword(_ newPassword: String, hint: String? = nil, now: Date) -> LockPolicy {
        var copy = self
        copy.password = PasswordDigest.make(password: newPassword, hint: hint, now: now)
        copy.kind = kind == .delay ? .both : kind
        copy.updatedAt = now
        return copy
    }
}
#endif

// MARK: - LockClockRecord

/// The deadline, mirrored into the Keychain so it survives app deletion
/// (docs/04-product-spec.md V1-3).
///
/// **Why this type exists at all.** The App Group container is removed when the
/// app is deleted; Keychain items are not. Delete-and-reinstall is therefore the
/// obvious escape from a queued loosening, and writing this record to the
/// Keychain under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the one
/// thing that closes it. `Kernel/Store/LockClock.swift` owns the
/// `SecItemAdd`/`SecItemCopyMatching` side; this is the value it stores, and it
/// is defined here so that `GateState` and the Keychain agree on the shape
/// byte-for-byte.
///
/// **The merge rule, verbatim from the spec: "Write both; on launch, trust the
/// Keychain copy if it is newer."** ``merge(appGroup:keychain:)`` is that rule,
/// as a pure function, so `Tests/GateKernelTests/LockClockTests.swift` can
/// simulate a reinstall without a Keychain.
public struct LockClockRecord: Codable, Sendable, Equatable, Hashable {

    /// The pending change this deadline belongs to, if any. `nil` means "no
    /// loosening is queued" — the Lock is idle.
    public var pendingChangeID: UUID?

    /// Absolute timestamp. Absolute, never a duration: the whole enforcement
    /// design recomputes ground truth from timestamps on every activation
    /// (docs/04-product-spec.md V1-10), and a stored duration would reset itself
    /// every time the process did.
    ///
    /// `nil` alongside a non-nil ``pendingChangeID`` means a ``LockKind/password``
    /// lock: queued, but it will never ripen on time alone.
    public var earliestApplyAt: Date?

    /// ``LockPolicy/configHash`` at the moment the deadline was written.
    public var lockConfigHash: String

    /// Which install wrote this record.
    ///
    /// After a delete-and-reinstall the fresh `GateState` has a new
    /// ``GateState/installID``, so a Keychain record whose `installID` differs is
    /// positive evidence of a reinstall. That is worth knowing — it is the one
    /// moment the app can say something true and useful ("this delay was set
    /// before you reinstalled; it still has 4h 12m to run") instead of silently
    /// re-imposing a deadline the user does not remember.
    public var installID: UUID

    /// Write timestamp. The sole input to the "trust the newer copy" rule.
    public var updatedAt: Date

    public init(
        pendingChangeID: UUID? = nil,
        earliestApplyAt: Date? = nil,
        lockConfigHash: String,
        installID: UUID,
        updatedAt: Date
    ) {
        self.pendingChangeID = pendingChangeID
        self.earliestApplyAt = earliestApplyAt
        self.lockConfigHash = lockConfigHash
        self.installID = installID
        self.updatedAt = updatedAt
    }

    /// True when nothing is queued.
    public var isIdle: Bool { pendingChangeID == nil }

    /// Whether the deadline has passed at `now`.
    ///
    /// False when ``earliestApplyAt`` is `nil` — a password-only lock never
    /// ripens with time.
    public func isRipe(at now: Date) -> Bool {
        guard let earliestApplyAt else { return false }
        return now >= earliestApplyAt
    }

    /// Seconds still to wait, or `nil` if this deadline never ripens on its own.
    public func remaining(at now: Date) -> TimeInterval? {
        guard let earliestApplyAt else { return nil }
        return max(0, earliestApplyAt.timeIntervalSince(now))
    }

    /// Whether the Lock has been reconfigured since this deadline was written.
    ///
    /// Informational only — it changes the copy, never the deadline. See the note
    /// on ``LockPolicy/configHash``.
    public func hasConfigDrift(against policy: LockPolicy) -> Bool {
        lockConfigHash != policy.configHash
    }

    /// Whether this record came from a previous install of Gate.
    public func isFromPreviousInstall(currentInstallID: UUID) -> Bool {
        installID != currentInstallID
    }

    /// Reconciles the App Group copy with the Keychain copy.
    ///
    /// The rule is "trust the newer copy" (docs/04-product-spec.md V1-3), with
    /// one deliberate asymmetry: when only the Keychain copy exists, it wins
    /// outright. That is the reinstall case, and it is the entire reason the
    /// Keychain mirror exists — an absent App Group copy is not evidence that the
    /// deadline was satisfied, it is evidence that the container was deleted.
    ///
    /// Ties go to the Keychain for the same reason: a same-timestamp
    /// disagreement is a torn write, and of the two copies the Keychain one is
    /// the one an adversarial user cannot clear by deleting the app.
    public static func merge(appGroup: LockClockRecord?, keychain: LockClockRecord?) -> LockClockRecord? {
        switch (appGroup, keychain) {
        case (nil, nil):
            return nil
        case (.some(let local), nil):
            return local
        case (nil, .some(let stored)):
            return stored
        case (.some(let local), .some(let stored)):
            return local.updatedAt > stored.updatedAt ? local : stored
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pendingChangeID = "pc"
        case earliestApplyAt = "at"
        case lockConfigHash = "cfg"
        case installID = "inst"
        case updatedAt = "u"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pendingChangeID: container.gateOptional(UUID.self, forKey: .pendingChangeID),
            earliestApplyAt: container.gateOptional(Date.self, forKey: .earliestApplyAt),
            lockConfigHash: container.gateValue(String.self, forKey: .lockConfigHash, default: ""),
            installID: container.gateValue(UUID.self, forKey: .installID, default: UUID()),
            // A record with no write timestamp loses every merge, which is the
            // safe direction: it can never displace a copy we can date.
            updatedAt: container.gateValue(Date.self, forKey: .updatedAt, default: .distantPast)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pendingChangeID, forKey: .pendingChangeID)
        try container.encodeIfPresent(earliestApplyAt, forKey: .earliestApplyAt)
        try container.encode(lockConfigHash, forKey: .lockConfigHash)
        try container.encode(installID, forKey: .installID)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
