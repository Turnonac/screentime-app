//
//  LockClock.swift
//  GateKernel
//
//  The deadline that survives delete-and-reinstall.
//
//  Build plan: docs/06-build-plan.md step 3.4. Product: docs/04-product-spec.md V1-3.
//
//  WHAT THIS FILE IS FOR
//  Gate's entire promise is "changing your mind costs time"
//  (docs/04-product-spec.md, positioning). Every loosening change is queued with
//  `earliestApplyAt = now + lock.delay` (V1-4, the Ratchet). If deleting the app
//  and reinstalling it cleared that deadline, the delay would cost about fifteen
//  seconds and the product would be a placebo.
//
//  **Keychain items survive app deletion on iOS. The App Group container does
//  not.** That one asymmetry is the whole mechanism. V1-3, verbatim: *"Store
//  `{ pendingChangeID, earliestApplyAt, lockConfigHash }` in the Keychain with
//  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` … Write both; on launch,
//  trust the Keychain copy if it is newer."*
//
//  WHAT IT IS NOT FOR — the honest limits, which the UI copy must match
//  (docs/04-product-spec.md V1-1, "shipping a blocker that overclaims is the #1
//  trust failure in this category"):
//    * Under `.individual` authorization Apple deliberately removes the
//      anti-bypass protections and the user can revoke everything in about four
//      taps, with no API to block, delay, or reliably detect it
//      (docs/03-hard-constraints.md #13, #14). This file raises the cost of
//      reinstalling; it cannot make anything impossible, and nothing in Gate
//      may claim otherwise.
//    * A user who moves the device clock forward skips the wait. See
//      ``LockClock/remaining(_:now:)`` for why that is not worth hardening.
//
//  RULES FOR THIS FILE
//  1. Foundation + Security + CryptoKit + os. No UIKit, no SwiftUI, no SwiftData.
//  2. **App target only at runtime.** `keychain-access-groups` is on
//     `Config/Gate-App.entitlements` and on no extension
//     (`Kernel/Identifiers.swift`, keychain section). No extension reads or
//     writes the lock clock, and every entitlement an `.appex` carries is one
//     more thing that has to match its provisioning profile.
//     `CryptoKit` is therefore only ever *linked* by the monitor, never called:
//     it is a shared-cache system framework, so the import costs the monitor's
//     6 MB budget nothing it does not already pay (docs/03-hard-constraints.md
//     #31). If a device measurement ever says otherwise, replacing
//     ``LockClock/configHash(_:)`` with a hand-rolled SHA-256 is a change local
//     to this file — nothing outside it constructs a config hash.
//  3. Never `SecItemDelete` + `SecItemAdd` to update. See ``writeKeychain(_:)``.
//

import Foundation
import Security
import CryptoKit
import os

/// Computed rather than a stored global: see the note in
/// `Kernel/Store/GateStateStore.swift`.
private var lockLog: Logger {
    Logger(subsystem: GateID.Subsystem.kernel, category: "lock-clock")
}

// MARK: - LockDeadline

/// The lock clock's record: one in the Keychain, one mirrored into `GateState`.
///
/// `GateState` should carry this as `var lockDeadline: LockDeadline?`
/// (`Kernel/Model/GateState.swift`). The two copies are compared by
/// ``revision`` on every launch; see ``LockClock/resolve(keychain:mirror:)``.
///
/// **`nil` and "cleared" are different, and the difference is load-bearing.**
/// * A `nil` `LockDeadline?` means *there is no record at all* — a fresh install
///   whose `state.plist` does not exist yet. It loses to any Keychain record,
///   which is exactly the delete-and-reinstall case this file exists for.
/// * A non-`nil` record with `pendingChangeID == nil` is a **tombstone**: the
///   user cancelled the pending change, which is a tightening and therefore free
///   (docs/04-product-spec.md V1-4). It carries a revision, so it can and must
///   beat an older engaged record. Without the tombstone, cancelling a pending
///   change would be undone by the Keychain on the next launch.
public struct LockDeadline: Codable, Hashable, Sendable {

    /// Monotonically increasing, bumped by every write through ``LockClock``.
    ///
    /// The primary "which copy is newer" test. A counter rather than a timestamp
    /// because the device clock is user-settable and `Date` comparisons across a
    /// reinstall are not trustworthy; ``updatedAt`` is only the tiebreak.
    ///
    /// `Int` rather than an unsigned type: this value round-trips through a
    /// binary property list in both the Keychain item and `state.plist`, and
    /// signed 64-bit is the integer width property lists represent without
    /// qualification. Two-to-the-sixty-third revisions is not a constraint.
    public var revision: Int

    /// The queued loosening change this deadline gates, or `nil` for a tombstone.
    ///
    /// One deadline, not a list: `GateState` holds every `PendingChange`, and
    /// this is the single clock that must outlive the container. The app arms it
    /// with the *soonest* outstanding `earliestApplyAt`, so the record answers
    /// exactly one question — "is anything still owed?" — which is the only
    /// question that matters after a reinstall, when there are no rules left to
    /// loosen but the system daemon is still enforcing the shields
    /// (docs/03-hard-constraints.md #37).
    public var pendingChangeID: UUID?

    /// When the queued change becomes applicable. Absolute, never a duration:
    /// docs/05-architecture.md, *"every deadline is an absolute timestamp"*, so
    /// the app can recompute ground truth on every activation without having
    /// been running in between.
    public var earliestApplyAt: Date?

    /// When the deadline was armed. Used only to clamp a backwards clock — see
    /// ``LockClock/remaining(_:now:)``.
    public var armedAt: Date?

    /// A digest of the lock configuration in force when this was armed, from
    /// ``LockClock/configHash(_:)``.
    ///
    /// Lets the app notice that the Keychain record was armed under a different
    /// lock than the one currently configured — the delete-reinstall-and-set-a
    /// -shorter-delay path. **A mismatch must never silently drop the deadline.**
    /// The rule the Ratchet enforces (`Kernel/Engine/Ratchet.swift`): on
    /// mismatch, keep whichever remaining time is longer, because adopting the
    /// shorter one would make reinstalling a discount.
    public var lockConfigHash: String

    /// Wall-clock time of the write. Tiebreak for ``revision``, and diagnostics.
    public var updatedAt: Date

    // MARK: Init

    public init(
        revision: Int,
        pendingChangeID: UUID?,
        earliestApplyAt: Date?,
        armedAt: Date?,
        lockConfigHash: String,
        updatedAt: Date
    ) {
        self.revision = revision
        self.pendingChangeID = pendingChangeID
        self.earliestApplyAt = earliestApplyAt
        self.armedAt = armedAt
        self.lockConfigHash = lockConfigHash
        self.updatedAt = updatedAt
    }

    /// A tombstone: "nothing is pending, as of this revision."
    public static func cleared(revision: Int, lockConfigHash: String, now: Date) -> LockDeadline {
        LockDeadline(
            revision: revision,
            pendingChangeID: nil,
            earliestApplyAt: nil,
            armedAt: nil,
            lockConfigHash: lockConfigHash,
            updatedAt: now
        )
    }

    // MARK: Lenient decoding

    private enum CodingKeys: String, CodingKey {
        case revision, pendingChangeID, earliestApplyAt, armedAt, lockConfigHash, updatedAt
    }

    /// Decodes with a default for every field.
    ///
    /// Not theoretical leniency: a Keychain item genuinely outlives the app that
    /// wrote it, so the bytes read on a fresh install can have been written by
    /// *any* previously installed version of Gate, including ones that predate
    /// fields added later. Throwing there would strand the user behind a lock
    /// nothing can resolve. An all-defaults record decodes to a harmless
    /// revision-0 tombstone, which any real record beats.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        self.pendingChangeID = try container.decodeIfPresent(UUID.self, forKey: .pendingChangeID)
        self.earliestApplyAt = try container.decodeIfPresent(Date.self, forKey: .earliestApplyAt)
        self.armedAt = try container.decodeIfPresent(Date.self, forKey: .armedAt)
        self.lockConfigHash = try container.decodeIfPresent(String.self, forKey: .lockConfigHash) ?? ""
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: Queries

    /// Whether a change is actually queued. `false` for a tombstone.
    public var isEngaged: Bool { pendingChangeID != nil && earliestApplyAt != nil }

    /// Whether this record was armed under `hash`.
    public func matches(configHash hash: String) -> Bool { lockConfigHash == hash }

    /// Ordering for "trust whichever copy is newer": revision, then `updatedAt`.
    public func isNewer(than other: LockDeadline) -> Bool {
        revision != other.revision ? revision > other.revision : updatedAt > other.updatedAt
    }
}

// MARK: - LockClockError

/// Every way the Keychain can refuse, as a `Sendable`, `Equatable` value.
public enum LockClockError: Error, Equatable, Sendable, CustomStringConvertible {

    /// The Keychain cannot answer right now.
    ///
    /// `errSecInteractionNotAllowed` (-25308): the device has not been unlocked
    /// since boot, so an item protected with
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is not readable yet.
    /// `errSecNotAvailable` (-25291) maps here too — a different cause, an
    /// identical response.
    ///
    /// Transient and expected. The caller must retry after unlock and must
    /// **not** treat it as "there is no lock" — see
    /// ``LockClock/Resolution/keychainUnavailable(_:)``.
    case unavailableUntilFirstUnlock(OSStatus)

    /// `errSecMissingEntitlement` (-34018). The keychain access group does not
    /// match the provisioning profile the running bundle was signed with — the
    /// classic symptom of calling this from an `.appex`, which does not carry
    /// `keychain-access-groups` at all (`Config/Gate-Extension.entitlements`).
    case missingEntitlement(OSStatus)

    /// The item is there but its bytes are not a ``LockDeadline``. Recoverable
    /// only by ``LockClock/eraseKeychain()`` from a user-facing screen.
    case decodeFailed(String)

    /// A ``LockDeadline`` could not be encoded. A programming error.
    case encodeFailed(String)

    /// `SecItemCopyMatching` returned success with something that is not `Data`.
    case dataCorrupt

    /// Anything else, with the system's own message when it has one.
    case unexpectedStatus(OSStatus, message: String?)

    /// Maps an `OSStatus` onto this type.
    public static func mapping(_ status: OSStatus) -> LockClockError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable:
            return .unavailableUntilFirstUnlock(status)
        case errSecMissingEntitlement:
            return .missingEntitlement(status)
        default:
            return .unexpectedStatus(status, message: SecCopyErrorMessageString(status, nil) as String?)
        }
    }

    public var description: String {
        switch self {
        case .unavailableUntilFirstUnlock(let status):
            return """
                Keychain item is not readable yet (OSStatus \(status)). The device has not been \
                unlocked since boot. Retry after unlock; do not treat this as "no lock".
                """
        case .missingEntitlement(let status):
            return """
                Keychain access denied (OSStatus \(status), errSecMissingEntitlement). The lock \
                clock is app-only: keychain-access-groups is declared in \
                Config/Gate-App.entitlements and deliberately absent from \
                Config/Gate-Extension.entitlements. Check that this code is running in Gate.app \
                and that the provisioning profile carries the group.
                """
        case .decodeFailed(let detail):
            return "The Keychain lock record could not be decoded: \(detail)"
        case .encodeFailed(let detail):
            return "The lock record could not be encoded: \(detail)"
        case .dataCorrupt:
            return "The Keychain returned a lock item that is not data."
        case .unexpectedStatus(let status, let message):
            return "Keychain error OSStatus \(status)\(message.map { ": \($0)" } ?? "")"
        }
    }
}

// MARK: - LockClock

/// Reads, writes and reconciles the lock deadline across the Keychain and
/// `GateState`.
///
/// A value type with no mutable state: everything durable is in the Keychain.
/// Construct one wherever you need it.
///
/// The write order is fixed and load-bearing: **Keychain first, mirror second.**
/// ``arm(pendingChangeID:earliestApplyAt:configHash:previous:now:)`` and
/// ``clear(configHash:previous:now:)`` write the Keychain and hand the caller the
/// record to store in `GateState`. If the process dies between the two writes,
/// the Keychain is one revision ahead of the mirror, which means the surviving
/// copy is the *stricter* one. Reversing the order would make a crash during a
/// loosening change lose the deadline, which is the one direction a commitment
/// device must never fail in.
public struct LockClock: Sendable {

    /// `kSecAttrService`. Defaults to `GateID.keychainService`.
    public let service: String

    /// `kSecAttrAccount`. Defaults to `GateID.keychainAccount`. Exactly one item
    /// exists — there is exactly one lock per install
    /// (docs/04-product-spec.md V1-3).
    public let account: String

    /// `kSecAttrAccessGroup`, or `nil`.
    ///
    /// `nil` is correct for Gate and is the default. `Config/Gate-App.entitlements`
    /// declares exactly one group, `$(AppIdentifierPrefix)com.turnonac.gate`, and
    /// iOS defaults an item with no explicit access group to the first entry in
    /// the entitlement. Passing one explicitly means composing it with the team
    /// prefix at runtime (`GateID.keychainAccessGroup(teamPrefix:)`), and an
    /// access group that does not match the profile fails at *runtime* with
    /// `errSecMissingEntitlement` rather than at build time.
    public let accessGroup: String?

    public init(
        service: String = GateID.keychainService,
        account: String = GateID.keychainAccount,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    // MARK: Keychain primitives

    /// The attributes that identify Gate's single lock item.
    private var identityQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Explicit, though it is also the default for a query: the item must
            // never be a synchronizable one. `…ThisDeviceOnly` accessibility and
            // iCloud Keychain are mutually exclusive, and a lock that synced to
            // another device would be both wrong and a privacy regression.
            kSecAttrSynchronizable as String: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    /// Reads the Keychain record, or `nil` if there has never been one.
    ///
    /// - Throws: ``LockClockError``. In particular
    ///   ``LockClockError/unavailableUntilFirstUnlock(_:)`` before the first
    ///   unlock after boot, which is **not** the same as `nil`.
    public func readKeychain() throws -> LockDeadline? {
        var query = identityQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw LockClockError.dataCorrupt }
            do {
                return try PropertyListDecoder().decode(LockDeadline.self, from: data)
            } catch {
                throw LockClockError.decodeFailed(String(describing: error))
            }
        case errSecItemNotFound:
            return nil
        default:
            let error = LockClockError.mapping(status)
            lockLog.error("keychain read failed: \(error.description, privacy: .public)")
            throw error
        }
    }

    /// Writes the record, creating the item if it does not exist.
    ///
    /// **Update-then-add, never delete-then-add.** `SecItemUpdate` replaces the
    /// value in one Keychain transaction. Deleting and re-adding opens a window
    /// in which no lock item exists at all; a crash, a jetsam kill, or a reboot
    /// inside that window silently frees the user from the commitment they made,
    /// which is precisely the failure this file exists to prevent. The
    /// `errSecDuplicateItem` branch below handles the reverse race — another
    /// copy of the app process adding the item between our update and our add.
    public func writeKeychain(_ deadline: LockDeadline) throws {
        let data: Data
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            data = try encoder.encode(deadline)
        } catch {
            throw LockClockError.encodeFailed(String(describing: error))
        }

        // `kSecAttrAccessible` is set on both paths. Keychain items survive app
        // deletion (the mechanism), and `…AfterFirstUnlockThisDeviceOnly` is the
        // strictest class that is still readable when the app is launched into
        // the background after a reboot, and never leaves the device or reaches
        // a backup restored onto different hardware
        // (docs/04-product-spec.md V1-3).
        let mutableAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(identityQuery as CFDictionary, mutableAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            lockLog.debug("lock clock updated to revision \(deadline.revision, privacy: .public)")
            return

        case errSecItemNotFound:
            var addAttributes = identityQuery
            addAttributes[kSecValueData as String] = data
            addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // Cosmetic, and only on create: a legible label in any Keychain
            // inspector. Deliberately not part of `identityQuery`, or changing it
            // would orphan the item.
            addAttributes[kSecAttrLabel as String] = "Gate lock"
            addAttributes[kSecAttrDescription as String] = "Commitment deadline. Survives app deletion by design."

            let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                lockLog.notice("lock clock created at revision \(deadline.revision, privacy: .public)")
                return
            case errSecDuplicateItem:
                let retry = SecItemUpdate(identityQuery as CFDictionary, mutableAttributes as CFDictionary)
                guard retry == errSecSuccess else { throw LockClockError.mapping(retry) }
                return
            default:
                let error = LockClockError.mapping(addStatus)
                lockLog.error("keychain add failed: \(error.description, privacy: .public)")
                throw error
            }

        default:
            let error = LockClockError.mapping(updateStatus)
            lockLog.error("keychain update failed: \(error.description, privacy: .public)")
            throw error
        }
    }

    /// Deletes the item. Absence is success.
    ///
    /// **Not part of any normal flow.** Reached from two places only: the
    /// explicit teardown screen (docs/03-hard-constraints.md #37 — shields can
    /// persist after the app is deleted, so Gate offers a prominent "remove
    /// everything"), and the recovery path for a record that will not decode.
    /// Calling it anywhere else hands the user a free reinstall.
    public func eraseKeychain() throws {
        let status = SecItemDelete(identityQuery as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            lockLog.notice("lock clock erased")
        default:
            throw LockClockError.mapping(status)
        }
    }

    // MARK: Resolution

    /// The outcome of comparing the Keychain record with the `GateState` mirror.
    public enum Resolution: Sendable, Equatable {

        /// Neither copy exists. A genuinely fresh install that has never armed
        /// the lock.
        case noRecord

        /// Both copies exist and agree.
        case agreed(LockDeadline)

        /// The Keychain copy is newer. **The delete-and-reinstall case**: the
        /// container is gone, the Keychain is not. The caller must write this
        /// record into `GateState`.
        case keychainWins(LockDeadline)

        /// The mirror is newer, so the Keychain had fallen behind and has been
        /// healed by ``LockClock/load(mirror:)``.
        case mirrorWins(LockDeadline)

        /// The Keychain could not be read yet — before the first unlock after
        /// boot. The mirror, if any, is attached.
        ///
        /// The caller may proceed on the mirror but must **not** write a
        /// tombstone or otherwise conclude that no lock exists, and should retry
        /// once the device is unlocked. ``isAuthoritative`` is `false`.
        case keychainUnavailable(LockDeadline?)

        /// The record to act on, if any.
        public var deadline: LockDeadline? {
            switch self {
            case .noRecord: return nil
            case .agreed(let d), .keychainWins(let d), .mirrorWins(let d): return d
            case .keychainUnavailable(let d): return d
            }
        }

        /// Whether the durable copy was actually consulted.
        public var isAuthoritative: Bool {
            if case .keychainUnavailable = self { return false }
            return true
        }

        /// Whether the caller must write ``deadline`` back into `GateState`.
        public var needsMirrorWrite: Bool {
            if case .keychainWins = self { return true }
            return false
        }
    }

    /// Compares the two copies. Pure; no I/O.
    ///
    /// V1-3: *"on launch, trust the Keychain copy if it is newer."* ``LockDeadline/isNewer(than:)``
    /// defines "newer" as revision first and `updatedAt` only as a tiebreak,
    /// because the device clock is user-settable. An exact tie that still differs
    /// in content resolves to the Keychain: it is the durable copy, and after a
    /// reinstall it is the only one that was not just created from defaults.
    public func resolve(keychain: LockDeadline?, mirror: LockDeadline?) -> Resolution {
        switch (keychain, mirror) {
        case (nil, nil):
            return .noRecord
        case (let keychain?, nil):
            // A record with no mirror at all. This is the reinstall path — note
            // that a *cancelled* pending change leaves a tombstone in the mirror
            // rather than removing it, so it does not land here.
            return .keychainWins(keychain)
        case (nil, let mirror?):
            // The Keychain was cleared without the mirror being cleared. Heal it.
            return .mirrorWins(mirror)
        case (let keychain?, let mirror?):
            if keychain == mirror { return .agreed(keychain) }
            return mirror.isNewer(than: keychain) ? .mirrorWins(mirror) : .keychainWins(keychain)
        }
    }

    /// Reads the Keychain, resolves against the mirror, and heals the Keychain
    /// if it is the one that is behind.
    ///
    /// Call once per launch and on every return to the foreground, before the
    /// reconcile (docs/04-product-spec.md V1-10). The caller mirrors
    /// ``Resolution/deadline`` back into `GateState` when
    /// ``Resolution/needsMirrorWrite`` is `true`; this function never writes the
    /// container, because the app owns that file and this type does not.
    public func load(mirror: LockDeadline?) throws -> Resolution {
        let keychain: LockDeadline?
        do {
            keychain = try readKeychain()
        } catch LockClockError.unavailableUntilFirstUnlock(let status) {
            // Do not fail open and do not fail closed: report it. Treating this
            // as "no lock" would let a reboot clear every deadline.
            lockLog.notice("""
                keychain not readable before first unlock (OSStatus \(status, privacy: .public)); \
                proceeding on the GateState mirror and retrying later
                """)
            return .keychainUnavailable(mirror)
        }

        let resolution = resolve(keychain: keychain, mirror: mirror)

        if case .mirrorWins(let deadline) = resolution {
            try writeKeychain(deadline)
        }
        if case .keychainWins(let deadline) = resolution, mirror == nil, deadline.isEngaged {
            lockLog.notice("""
                restored an engaged lock from the keychain with no local mirror — \
                app data was removed while revision \(deadline.revision, privacy: .public) was outstanding
                """)
        }

        return resolution
    }

    // MARK: Mutation

    /// Arms the clock and returns the record to mirror into `GateState`.
    ///
    /// - Parameters:
    ///   - pendingChangeID: the queued loosening change this gates.
    ///   - earliestApplyAt: absolute; `now + lock.delay`, computed by
    ///     `Kernel/Engine/Ratchet.swift`.
    ///   - configHash: from ``configHash(_:)``, over the lock configuration in
    ///     force right now.
    ///   - previous: the record currently in force, from ``load(mirror:)``.
    ///     Supplies the revision to increment; `nil` starts at 1.
    public func arm(
        pendingChangeID: UUID,
        earliestApplyAt: Date,
        configHash: String,
        previous: LockDeadline?,
        now: Date = Date()
    ) throws -> LockDeadline {
        let deadline = LockDeadline(
            revision: (previous?.revision ?? 0) &+ 1,
            pendingChangeID: pendingChangeID,
            earliestApplyAt: earliestApplyAt,
            armedAt: now,
            lockConfigHash: configHash,
            updatedAt: now
        )
        try writeKeychain(deadline)
        return deadline
    }

    /// Writes a tombstone and returns the record to mirror into `GateState`.
    ///
    /// Use when the pending change was applied or cancelled. Cancelling is itself
    /// a tightening and costs nothing (docs/04-product-spec.md V1-4), so this
    /// path is not gated by anything — but it must still be a *tombstone* and not
    /// a delete, or the old engaged record in the mirror would win on the next
    /// launch. See ``LockDeadline``.
    public func clear(
        configHash: String,
        previous: LockDeadline?,
        now: Date = Date()
    ) throws -> LockDeadline {
        let deadline = LockDeadline.cleared(
            revision: (previous?.revision ?? 0) &+ 1,
            lockConfigHash: configHash,
            now: now
        )
        try writeKeychain(deadline)
        return deadline
    }

    // MARK: Elapsed time

    /// Seconds still owed on `deadline`, never negative.
    ///
    /// **Backwards clock.** If the device clock has moved back behind
    /// ``LockDeadline/armedAt``, the naive `earliestApplyAt - now` exceeds the
    /// delay the user actually agreed to — a clock error or a timezone-hopping
    /// flight could strand someone for years. The result is therefore clamped to
    /// the originally-armed duration. That clamp can only ever *shorten* a wait
    /// that was already longer than the user agreed to; it can never shorten the
    /// agreed wait itself.
    ///
    /// **Forwards clock — the honest limit.** Setting the clock forward skips
    /// the wait, and this file does not defend against it. There is no trusted
    /// time source on an offline device. The only monotonic alternative,
    /// `ProcessInfo.systemUptime`, resets on reboot — which is one more thing the
    /// user can do at will — and is a required-reason API that would oblige every
    /// one of the five privacy manifests to declare
    /// `NSPrivacyAccessedAPICategorySystemBootTime` / `35F9.1`
    /// (docs/06-build-plan.md step 7.1). It would buy nothing: under
    /// `.individual` authorization the user can revoke Gate's access entirely in
    /// about four taps and there is no API to block, delay, or detect that
    /// (docs/03-hard-constraints.md #13, #14). The clock is not the weakest link,
    /// and the product's copy already says so (docs/04-product-spec.md V1-1).
    public func remaining(_ deadline: LockDeadline, now: Date = Date()) -> TimeInterval {
        guard let earliestApplyAt = deadline.earliestApplyAt else { return 0 }
        let naive = earliestApplyAt.timeIntervalSince(now)
        guard naive > 0 else { return 0 }
        guard let armedAt = deadline.armedAt, now < armedAt else { return naive }

        let agreed = earliestApplyAt.timeIntervalSince(armedAt)
        guard agreed > 0 else { return 0 }
        lockLog.notice("""
            device clock is behind the lock's armed time by \
            \(Int(armedAt.timeIntervalSince(now)), privacy: .public)s — \
            clamping the remaining wait to the agreed \(Int(agreed), privacy: .public)s
            """)
        return min(naive, agreed)
    }

    /// Whether the queued change may now be applied.
    ///
    /// A tombstone is trivially satisfied: there is nothing queued.
    public func isSatisfied(_ deadline: LockDeadline, now: Date = Date()) -> Bool {
        guard deadline.isEngaged else { return true }
        return remaining(deadline, now: now) <= 0
    }

    // MARK: Config hash

    /// SHA-256 over an ordered list of configuration components, lowercase hex.
    ///
    /// Takes an explicit, caller-ordered list rather than hashing an encoded
    /// `LockPolicy`, because property-list encoding makes no guarantee about
    /// dictionary key order and a hash that changes between two encodings of the
    /// same value would make every launch look like a configuration change.
    /// `Kernel/Engine/Ratchet.swift` owns the component list; it must be stable
    /// across releases, and adding a component to it deliberately invalidates
    /// every outstanding record's ``LockDeadline/lockConfigHash``, which is
    /// handled — a mismatch keeps the longer remaining time, it never drops the
    /// deadline.
    ///
    /// Components are joined with U+001F (unit separator), a character no lock
    /// setting can contain, so `["a", "bc"]` and `["ab", "c"]` cannot collide.
    public static func configHash(_ components: [String]) -> String {
        let canonical = components.joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Diagnostics

    /// A line for the debug screen (docs/04-product-spec.md V1-11).
    ///
    /// Reports the Keychain's own view, independent of `GateState`, which is what
    /// makes a mirror bug visible. Never throws — the debug screen must render.
    public func diagnosticDescription(now: Date = Date()) -> String {
        do {
            guard let deadline = try readKeychain() else {
                return "lock clock: no keychain item (service \(service), account \(account))"
            }
            guard deadline.isEngaged else {
                return "lock clock: cleared at revision \(deadline.revision)"
            }
            return """
                lock clock: revision \(deadline.revision), \
                \(Int(remaining(deadline, now: now)))s remaining, \
                change \(deadline.pendingChangeID?.uuidString ?? "-"), \
                config \(deadline.lockConfigHash.prefix(8))
                """
        } catch {
            return "lock clock: unreadable — \(String(describing: error))"
        }
    }
}
