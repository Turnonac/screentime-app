//
//  PendingChange.swift
//  GateKernel
//
//  The queued-loosening record — the Ratchet's output and the reason the product
//  exists (docs/04-product-spec.md V1-4).
//
//  "Changing your mind costs time." A *tightening* mutation is applied to
//  `GateState` synchronously and leaves no trace here. A *loosening* mutation is
//  turned into one of these, parked, and applied only once the Lock releases it —
//  by elapsed time (``LockKind/delay``), by the partner password
//  (``LockKind/password``), or by either (``LockKind/both``).
//
//  Build plan: docs/06-build-plan.md step 3.1. Classification lives in
//  `Kernel/Engine/Ratchet.swift` (step 3.5); this file is only the record.
//
//  Foundation only — see the header of Kernel/Model/Rule.swift.
//

import Foundation

// MARK: - PendingChange

public struct PendingChange: Codable, Sendable, Equatable, Hashable, Identifiable {

    /// Longest user-supplied note. Kept short on purpose: `state.plist` has an
    /// 8 KB budget (docs/05-architecture.md) and up to
    /// ``GateLimits/maxRevertActivities`` changes can be outstanding at once.
    public static let maxNoteLength = 140

    /// How long a resolved change is kept before ``GateState/pruned(now:)``
    /// reclaims it.
    ///
    /// Resolved changes are not waste — they are the pending-change history the
    /// debug screen renders (docs/04-product-spec.md V1-11) and the honest record
    /// of what the user has talked themselves into. But they are also unbounded
    /// growth inside a fixed byte budget, so they expire.
    public static let terminalRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Also the UUID half of the `gate.revert:<ruleUUID>|<pendingChangeUUID>`
    /// `DeviceActivityName` that arms the auto-revert timer
    /// (docs/05-architecture.md, "The DeviceActivityName codec"). Monitor
    /// callbacks carry no payload but the name, so this id is how a callback
    /// finds its way back to this record.
    public var id: UUID

    /// What will happen when the Lock releases.
    public var operation: Operation

    public var requestedAt: Date

    /// When elapsed time alone is enough to release this change.
    ///
    /// `nil` means *never on time alone* — a pure ``LockKind/password`` lock.
    /// Produced by ``LockPolicy/earliestApplyDate(from:)``, which returns `nil`
    /// for exactly that case. Treating `nil` as "immediately" would be a total
    /// bypass of the partner lock, so ``isRipe(at:)`` treats it as "never".
    public var earliestApplyAt: Date?

    /// ``LockPolicy/configHash`` at the moment this change was queued.
    ///
    /// Never used to invalidate the change — see the note on
    /// ``LockPolicy/configHash``. It exists so the UI can say "the Lock has
    /// changed since you queued this" and so the debug screen can show why a
    /// deadline looks inconsistent with the current settings.
    public var lockConfigHash: String

    public var status: Status

    /// When ``status`` last left ``Status/pending``.
    public var resolvedAt: Date?

    /// Optional user-written context ("I want to check the group chat"). Shown
    /// in the pending-changes banner. Never required.
    public var note: String?

    public init(
        id: UUID = UUID(),
        operation: Operation,
        requestedAt: Date,
        earliestApplyAt: Date?,
        lockConfigHash: String,
        status: Status = .pending,
        resolvedAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.operation = operation
        self.requestedAt = requestedAt
        self.earliestApplyAt = earliestApplyAt
        self.lockConfigHash = lockConfigHash
        self.status = status
        self.resolvedAt = resolvedAt
        self.note = note.map { String($0.prefix(PendingChange.maxNoteLength)) }
    }

    // MARK: Lifecycle

    /// Where a queued change has got to.
    public enum Status: String, Codable, Sendable, Hashable, CaseIterable {
        /// Waiting on the Lock.
        case pending
        /// Released and folded into `GateState`.
        case applied
        /// The user changed their mind back. Cancelling is itself a **tightening**
        /// and is therefore free and immediate (docs/04-product-spec.md V1-4).
        case cancelled
        /// A newer change for the same target replaced this one. Only the newer
        /// change's deadline counts; the older one is not silently deleted,
        /// because a vanished pending change reads as a bug to the user.
        case superseded

        public var isTerminal: Bool { self != .pending }
    }

    public var isTerminal: Bool { status.isTerminal }

    /// Whether the Lock has released this change on elapsed time.
    ///
    /// A password release does not go through here — the UI verifies the
    /// passphrase against ``LockPolicy`` and then calls ``applied(at:)`` directly.
    public func isRipe(at now: Date) -> Bool {
        guard status == .pending, let earliestApplyAt else { return false }
        return now >= earliestApplyAt
    }

    /// Seconds still to wait, or `nil` when this change never ripens on time
    /// alone. Drives the "unlocks in 12m 04s" banner (docs/04-product-spec.md
    /// V1-4); `GateKernelUI` formats it.
    public func remaining(at now: Date) -> TimeInterval? {
        guard let earliestApplyAt else { return nil }
        return max(0, earliestApplyAt.timeIntervalSince(now))
    }

    /// False for an ``Operation/unrecognized(type:)`` written by a newer build.
    /// Such a change is displayed and can be cancelled, but is never applied —
    /// applying an operation whose meaning we do not know could loosen anything.
    public var isApplicable: Bool { operation.isRecognized }

    public func cancelled(at now: Date) -> PendingChange {
        resolved(as: .cancelled, at: now)
    }

    public func applied(at now: Date) -> PendingChange {
        resolved(as: .applied, at: now)
    }

    public func superseded(at now: Date) -> PendingChange {
        resolved(as: .superseded, at: now)
    }

    private func resolved(as newStatus: Status, at now: Date) -> PendingChange {
        guard status == .pending else { return self }
        var copy = self
        copy.status = newStatus
        copy.resolvedAt = now
        return copy
    }

    /// The rule this change affects, if it is rule-scoped.
    public var ruleID: UUID? { operation.ruleID }

    /// Whether this record may be reclaimed by ``GateState/pruned(now:)``.
    public func isExpired(at now: Date, retention: TimeInterval = PendingChange.terminalRetention) -> Bool {
        guard let resolvedAt, status.isTerminal else { return false }
        return now.timeIntervalSince(resolvedAt) > retention
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case operation = "op"
        case requestedAt = "req"
        case earliestApplyAt = "at"
        case lockConfigHash = "cfg"
        case status = "st"
        case resolvedAt = "res"
        case note
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Both are genuinely required. A change with no id cannot be matched to
        // its auto-revert DeviceActivityName; a change with no operation cannot
        // be described to the user, let alone applied. Throwing lets the lossy
        // array decoder drop this one element and keep the rest of the queue.
        let id = try container.decode(UUID.self, forKey: .id)
        let operation = try container.decode(Operation.self, forKey: .operation)

        self.init(
            id: id,
            operation: operation,
            requestedAt: container.gateValue(Date.self, forKey: .requestedAt, default: .distantPast),
            earliestApplyAt: container.gateOptional(Date.self, forKey: .earliestApplyAt),
            lockConfigHash: container.gateValue(String.self, forKey: .lockConfigHash, default: ""),
            // An unreadable status decodes to `.pending`, i.e. "still costs you
            // time". The alternative default — treating it as resolved — would
            // hand out a free loosening to anyone who could corrupt one byte.
            status: container.gateRaw(Status.self, forKey: .status, default: .pending),
            resolvedAt: container.gateOptional(Date.self, forKey: .resolvedAt),
            note: container.gateOptional(String.self, forKey: .note)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(operation, forKey: .operation)
        try container.encode(requestedAt, forKey: .requestedAt)
        try container.encodeIfPresent(earliestApplyAt, forKey: .earliestApplyAt)
        try container.encode(lockConfigHash, forKey: .lockConfigHash)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

// MARK: - PendingChange.Operation

public extension PendingChange {

    /// The loosening mutations that can be queued.
    ///
    /// **This is the persisted form of a loosening, not the in-memory one.**
    /// `Kernel/Engine/Ratchet.swift` defines `Mutation`, which is the richer type
    /// the UI hands to `Ratchet.apply(_:to:now:)` — it may carry live token sets
    /// and other things that must never be written to an 8 KB file. `Ratchet`
    /// projects a loosening `Mutation` down to one of these cases, and
    /// `Reconciler` projects it back up when the change ripens. Every case here
    /// is therefore small and self-contained: identifiers, scalars, and at most a
    /// ``SelectionRef``.
    ///
    /// The `TIGHTEN` half of the Ratchet's table (docs/04-product-spec.md V1-4)
    /// has no representation here at all — by construction, because a tightening
    /// is applied synchronously and never queued.
    public enum Operation: Sendable, Equatable, Hashable {

        /// Turn a rule off.
        case disableRule(ruleID: UUID)

        /// Delete a rule outright, along with its store, its activity and its
        /// staged selections.
        case deleteRule(ruleID: UUID)

        /// Swap a rule's selection — the queued form of "remove a token".
        ///
        /// The replacement blob is staged in ``SelectionTable`` under
        /// ``SelectionOwner/pendingChange(_:)`` while the current one stays
        /// enforced, so applying this is a re-parent
        /// (``SelectionTable/adopt(selectionID:asRule:at:)``) rather than a copy
        /// and cannot half-succeed. `nil` clears the selection entirely.
        case replaceSelection(ruleID: UUID, selection: SelectionRef?)

        /// Shrink or remove a rule's schedule. `nil` removes the schedule, which
        /// makes the rule unconditional — note that removing a *window* is a
        /// tightening, not a loosening, so `Ratchet` only queues this case when
        /// the new window is strictly smaller than the old one.
        case setSchedule(ruleID: UUID, schedule: RuleSchedule?)

        /// Change a rule between blocklist and allowlist. Queued only in the
        /// loosening direction (allowlist -> blocklist).
        case setMode(ruleID: UUID, mode: RuleMode)

        /// Decrease the Lock delay. The cost is `oldDelay - newDelay`, not the
        /// full delay — the spec's asymmetry (docs/04-product-spec.md V1-3) — and
        /// `Ratchet` encodes that by computing ``PendingChange/earliestApplyAt``
        /// from the difference rather than from ``LockPolicy/delay``.
        case setLockDelay(seconds: TimeInterval)

        /// Change the Lock type. Always a loosening (docs/04-product-spec.md V1-4).
        case setLockKind(LockKind)

        /// Remove the partner passphrase.
        case clearLockPassword

        /// Turn the Ratchet off, i.e. stop letting tightenings apply for free.
        case setRatchet(enabled: Bool)

        /// Turn "Solid" install protection off (docs/04-product-spec.md V1-8).
        case setInstallProtection(enabled: Bool)

        /// Revoke Family Controls authorization from inside the app — the
        /// in-app version of the four-tap Settings escape. Gate cannot stop the
        /// Settings route (docs/03-hard-constraints.md #14) but it can refuse to
        /// be the quick one.
        case revokeAuthorization

        /// Written by a newer build of Gate. Displayed, cancellable, never
        /// applied. See ``PendingChange/isApplicable``.
        case unrecognized(type: String)

        /// The rule this operation targets, or `nil` for install-wide operations.
        public var ruleID: UUID? {
            switch self {
            case .disableRule(let id),
                 .deleteRule(let id),
                 .replaceSelection(let id, _),
                 .setSchedule(let id, _),
                 .setMode(let id, _):
                id
            case .setLockDelay, .setLockKind, .clearLockPassword, .setRatchet,
                 .setInstallProtection, .revokeAuthorization, .unrecognized:
                nil
            }
        }

        public var isRecognized: Bool {
            if case .unrecognized = self { return false }
            return true
        }

        /// A stable key identifying *what* this operation changes, ignoring the
        /// value it changes it to.
        ///
        /// Two queued changes with the same key are mutually exclusive: queueing
        /// "disable rule X" twice must not cost two separate waits, and queueing
        /// "set delay to 5m" after "set delay to 10m" must supersede rather than
        /// stack. `Kernel/Engine/Ratchet.swift` uses this to mark the older one
        /// ``PendingChange/Status/superseded``.
        ///
        /// ``deleteRule(ruleID:)`` and ``disableRule(ruleID:)`` deliberately get
        /// *different* keys even though both target the same rule: they are
        /// different intentions with different costs, and collapsing them would
        /// let a queued disable silently become a queued delete.
        public var targetKey: String {
            switch self {
            case .disableRule(let id): "rule.enabled:\(id.uuidString)"
            case .deleteRule(let id): "rule.delete:\(id.uuidString)"
            case .replaceSelection(let id, _): "rule.selection:\(id.uuidString)"
            case .setSchedule(let id, _): "rule.schedule:\(id.uuidString)"
            case .setMode(let id, _): "rule.mode:\(id.uuidString)"
            case .setLockDelay: "lock.delay"
            case .setLockKind: "lock.kind"
            case .clearLockPassword: "lock.password"
            case .setRatchet: "lock.ratchet"
            case .setInstallProtection: "install.protection"
            case .revokeAuthorization: "authorization"
            case .unrecognized(let type): "unrecognized:\(type)"
            }
        }

        /// Non-localized one-line description, for the debug screen
        /// (docs/04-product-spec.md V1-11) and for `os.Logger` at the call sites
        /// that have a logger. **Not user-facing copy** — the kernel has no
        /// localization and the banner's wording lives in `GateKernelUI`.
        public var debugSummary: String {
            switch self {
            case .disableRule(let id):
                return "disable rule \(id.uuidString)"
            case .deleteRule(let id):
                return "delete rule \(id.uuidString)"
            case .replaceSelection(let id, let ref):
                let target = ref?.id.uuidString ?? "none"
                return "replace selection of rule \(id.uuidString) with \(target)"
            case .setSchedule(let id, let schedule):
                let window: String
                if let schedule {
                    window = String(schedule.start.secondsFromMidnight)
                        + "-" + String(schedule.end.secondsFromMidnight)
                        + " mask " + String(schedule.weekdays.rawValue)
                } else {
                    window = "none"
                }
                return "set schedule of rule \(id.uuidString) to \(window)"
            case .setMode(let id, let mode):
                return "set rule \(id.uuidString) to \(mode.rawValue)"
            case .setLockDelay(let seconds):
                return "set lock delay to \(Int(seconds))s"
            case .setLockKind(let kind):
                return "set lock kind to \(kind.rawValue)"
            case .clearLockPassword:
                return "clear lock password"
            case .setRatchet(let enabled):
                return "set ratchet \(enabled)"
            case .setInstallProtection(let enabled):
                return "set install protection \(enabled)"
            case .revokeAuthorization:
                return "revoke authorization"
            case .unrecognized(let type):
                return "unrecognized operation '\(type)'"
            }
        }
    }
}

// MARK: - PendingChange.Operation: Codable

extension PendingChange.Operation: Codable {

    private enum CodingKeys: String, CodingKey {
        case type = "t"
        case ruleID = "rule"
        case selection = "sel"
        case schedule = "sch"
        case mode = "m"
        case seconds = "sec"
        case lockKind = "k"
        case enabled = "on"
    }

    /// Discriminator strings. Hand-written rather than synthesized so that an
    /// unknown case from a newer build decodes to ``unrecognized(type:)`` instead
    /// of throwing and taking the whole pending queue with it. Never renumber or
    /// rename one of these: they are on disk.
    private enum Tag {
        static let disableRule = "disableRule"
        static let deleteRule = "deleteRule"
        static let replaceSelection = "replaceSelection"
        static let setSchedule = "setSchedule"
        static let setMode = "setMode"
        static let setLockDelay = "setLockDelay"
        static let setLockKind = "setLockKind"
        static let clearLockPassword = "clearLockPassword"
        static let setRatchet = "setRatchet"
        static let setInstallProtection = "setInstallProtection"
        static let revokeAuthorization = "revokeAuthorization"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = container.gateValue(String.self, forKey: .type, default: "")
        let ruleID = container.gateOptional(UUID.self, forKey: .ruleID)

        switch type {
        case Tag.disableRule:
            guard let ruleID else { self = .unrecognized(type: type); return }
            self = .disableRule(ruleID: ruleID)

        case Tag.deleteRule:
            guard let ruleID else { self = .unrecognized(type: type); return }
            self = .deleteRule(ruleID: ruleID)

        case Tag.replaceSelection:
            guard let ruleID else { self = .unrecognized(type: type); return }
            self = .replaceSelection(
                ruleID: ruleID,
                selection: container.gateOptional(SelectionRef.self, forKey: .selection)
            )

        case Tag.setSchedule:
            guard let ruleID else { self = .unrecognized(type: type); return }
            self = .setSchedule(
                ruleID: ruleID,
                schedule: container.gateOptional(RuleSchedule.self, forKey: .schedule)
            )

        case Tag.setMode:
            guard let ruleID else { self = .unrecognized(type: type); return }
            self = .setMode(
                ruleID: ruleID,
                mode: container.gateRaw(RuleMode.self, forKey: .mode, default: .blocklist)
            )

        case Tag.setLockDelay:
            // Clamped on the way in as well as on the way out: a queued change
            // that would set a zero delay is the one value that could quietly
            // turn the whole product off.
            let seconds = container.gateValue(
                TimeInterval.self, forKey: .seconds, default: GateLimits.defaultLockDelay
            )
            self = .setLockDelay(seconds: LockPolicy.clampDelay(seconds))

        case Tag.setLockKind:
            self = .setLockKind(container.gateRaw(LockKind.self, forKey: .lockKind, default: .delay))

        case Tag.clearLockPassword:
            self = .clearLockPassword

        case Tag.setRatchet:
            self = .setRatchet(enabled: container.gateValue(Bool.self, forKey: .enabled, default: true))

        case Tag.setInstallProtection:
            self = .setInstallProtection(
                enabled: container.gateValue(Bool.self, forKey: .enabled, default: true)
            )

        case Tag.revokeAuthorization:
            self = .revokeAuthorization

        default:
            self = .unrecognized(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disableRule(let ruleID):
            try container.encode(Tag.disableRule, forKey: .type)
            try container.encode(ruleID, forKey: .ruleID)

        case .deleteRule(let ruleID):
            try container.encode(Tag.deleteRule, forKey: .type)
            try container.encode(ruleID, forKey: .ruleID)

        case .replaceSelection(let ruleID, let selection):
            try container.encode(Tag.replaceSelection, forKey: .type)
            try container.encode(ruleID, forKey: .ruleID)
            try container.encodeIfPresent(selection, forKey: .selection)

        case .setSchedule(let ruleID, let schedule):
            try container.encode(Tag.setSchedule, forKey: .type)
            try container.encode(ruleID, forKey: .ruleID)
            try container.encodeIfPresent(schedule, forKey: .schedule)

        case .setMode(let ruleID, let mode):
            try container.encode(Tag.setMode, forKey: .type)
            try container.encode(ruleID, forKey: .ruleID)
            try container.encode(mode.rawValue, forKey: .mode)

        case .setLockDelay(let seconds):
            try container.encode(Tag.setLockDelay, forKey: .type)
            try container.encode(seconds, forKey: .seconds)

        case .setLockKind(let kind):
            try container.encode(Tag.setLockKind, forKey: .type)
            try container.encode(kind.rawValue, forKey: .lockKind)

        case .clearLockPassword:
            try container.encode(Tag.clearLockPassword, forKey: .type)

        case .setRatchet(let enabled):
            try container.encode(Tag.setRatchet, forKey: .type)
            try container.encode(enabled, forKey: .enabled)

        case .setInstallProtection(let enabled):
            try container.encode(Tag.setInstallProtection, forKey: .type)
            try container.encode(enabled, forKey: .enabled)

        case .revokeAuthorization:
            try container.encode(Tag.revokeAuthorization, forKey: .type)

        case .unrecognized(let type):
            // Round-tripped verbatim. The payload a newer build attached is
            // genuinely lost — there is nowhere in a typed struct to keep it —
            // which is precisely why `GateState.migrate` refuses to let an older
            // build write back over a newer file at all
            // (``GateState/MigrationReport/isFromFuture``). Preserving the tag
            // keeps the user's pending-change count honest in the meantime.
            try container.encode(type, forKey: .type)
        }
    }
}

// MARK: - Collection helpers

public extension Collection where Element == PendingChange {

    /// Still waiting on the Lock.
    var pending: [PendingChange] { filter { $0.status == .pending } }

    /// Released by elapsed time and ready for `Reconciler` to fold into state.
    func ripe(at now: Date) -> [PendingChange] {
        filter { $0.isRipe(at: now) && $0.isApplicable }
    }

    /// The soonest deadline among still-pending changes, for the banner countdown
    /// (docs/04-product-spec.md V1-4). Ignores password-only changes, which have
    /// no deadline to count down to.
    func nextDeadline(after now: Date) -> Date? {
        pending
            .compactMap(\.earliestApplyAt)
            .filter { $0 > now }
            .min()
    }
}
