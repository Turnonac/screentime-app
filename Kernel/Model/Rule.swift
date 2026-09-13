//
//  Rule.swift
//  GateKernel
//
//  The unit of configuration (docs/04-product-spec.md V1-2) plus everything a
//  rule *points at*: the selection side-table that keeps `FamilyActivitySelection`
//  blobs out of `state.plist`, and the opaque-token representation the kernel
//  uses so that no model type has to import ManagedSettings.
//
//  Build plan: docs/06-build-plan.md step 3.1.
//
//  RULES FOR THIS FILE — and for every file in Kernel/Model/
//  1. **Foundation only.** No FamilyControls, no ManagedSettings, no DeviceActivity,
//     no UIKit, no SwiftUI, no os.Logger. Three reasons, in order of severity:
//     (a) GateActivityMonitor links GateKernel under a 6 MB ceiling
//         (docs/03-hard-constraints.md #31);
//     (b) the Kernel is unit-tested as a platform-agnostic SwiftPM package so
//         `swift test` runs with no Xcode and no device
//         (docs/06-build-plan.md step 3.11, project.yml "Schemes");
//     (c) a model that cannot name an SDK type cannot accidentally grow a
//         dependency on daemon state.
//     The SDK boundary is crossed in exactly two places, both outside this
//     directory: `Kernel/Store/SelectionStore.swift` converts
//     `FamilyActivitySelection` <-> `Data`, and `Kernel/Enforcement/TokenGuard.swift`
//     converts `ManagedSettings.Token<_>` <-> ``EncodedToken``.
//  2. Everything `Codable`, `Sendable`, flat and small. `GateState` has an 8 KB
//     budget (docs/05-architecture.md, persistence) and is decoded by the monitor
//     on every callback.
//  3. Every `init(from:)` is lenient: unknown keys are ignored, missing keys take
//     a documented default, unknown enum cases degrade to a documented fallback.
//     A newer build's `state.plist` must never brick an older build, and a
//     half-written file must never cost the user an unenforced block.
//

import Foundation

// MARK: - RuleMode

/// Whether a rule's selection names what to block or what to allow.
///
/// The two modes are enforced very differently (docs/02-api-reference.md §6):
///
/// - ``blocklist``: the selection holds the tokens to shield. Written as
///   `store.shield.applications = appTokens` plus
///   `.specific(categoryTokens, except: perAppExceptions)`.
/// - ``allowlist``: the selection holds the tokens to **exempt**. Written as
///   `store.shield.applicationCategories = .all(except: allowedTokens)`, which is
///   how "block everything except these" is expressed without enumerating 50
///   tokens. Your own app is always exempt from `.all` — Gate can never shield
///   itself out of existence.
public enum RuleMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// The selection is the set of things to block.
    case blocklist
    /// The selection is the set of things to leave reachable; everything else is
    /// shielded via `.all(except:)`.
    case allowlist
}

// MARK: - TokenCollection

/// The four shield collections iOS caps independently at 50 entries **each**
/// (docs/02-api-reference.md §14; docs/03-hard-constraints.md #34).
///
/// The failure is silent: past the cap the store shields *nothing* and the
/// property reads back `nil`. Every count that will become a shield collection is
/// checked against ``GateLimits/maxTokensPerShieldCollection`` before it reaches
/// the framework — in the editor (docs/04-product-spec.md V1-2), again in
/// ``Rule/validate()``, and a third time in `Kernel/Enforcement/TokenGuard.swift`.
public enum TokenCollection: String, Codable, Sendable, Hashable, CaseIterable {
    case applications
    case categories
    case webDomains
}

/// Which flavour of opaque token a blob holds.
///
/// Mirrors `ApplicationToken` / `ActivityCategoryToken` / `WebDomainToken` without
/// naming them, so this file stays Foundation-only. `ShieldActionDelegate` has one
/// `handle(action:for:)` overload per flavour (docs/02-api-reference.md §10) and
/// the kind is the only way to tell the three apart once a token is bytes.
public enum TokenKind: String, Codable, Sendable, Hashable, CaseIterable {
    case application
    case category
    case webDomain

    /// The shield collection a token of this kind lands in.
    public var collection: TokenCollection {
        switch self {
        case .application: .applications
        case .category: .categories
        case .webDomain: .webDomains
        }
    }
}

// MARK: - EncodedToken

/// One opaque Screen Time token, as bytes.
///
/// `ManagedSettings.Token<T>` is `Codable`, `Equatable` and `Hashable` but is not
/// nameable from a Foundation-only module, so the kernel carries the encoded form
/// and `Kernel/Enforcement/TokenGuard.swift` does the round trip with a
/// `JSONEncoder` / `JSONDecoder` pair.
///
/// **Two properties of real tokens this type deliberately does not hide:**
///
/// 1. They are large — hundreds of bytes each — which is exactly why selections
///    live in ``SelectionTable`` and not in `GateState` (8 KB budget,
///    docs/05-architecture.md). Only *individually scoped* tokens ever appear
///    inline in state, and only in a ``Grant`` (see ``GrantScope``).
/// 2. They go stale. Tokens change across OS updates and re-authorization, and a
///    token handed to `ShieldConfigurationDataSource` / `ShieldActionDelegate`
///    can fail `==` against the byte-identical-looking one you stored
///    (docs/03-hard-constraints.md #36, thread 814571 — Apple gave no
///    workaround). So a lookup keyed by ``fingerprint`` is always written with a
///    miss path, never with a `!` or a `precondition`. See
///    ``ShieldCopyTable/copy(forToken:)``.
public struct EncodedToken: Codable, Sendable, Equatable, Hashable {

    /// The `Codable` encoding of a `ManagedSettings.Token<_>`, produced by
    /// `Kernel/Enforcement/TokenGuard.swift`.
    public var bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// A stable 16-hex-character fingerprint of ``bytes``.
    ///
    /// Computed, never stored: storing it would double the cost of the one thing
    /// this type exists to keep small. Stable across processes and launches,
    /// which `Hashable.hashValue` is **not** — Swift seeds its hasher per process,
    /// so a `hashValue` written to disk by the app and read by the monitor would
    /// not match (see ``GateFingerprint``).
    public var fingerprint: String { GateFingerprint.hex(bytes) }

    public var isEmpty: Bool { bytes.isEmpty }

    // Lenient by construction: a record whose `bytes` key is missing or is not
    // Data decodes to an empty token rather than failing, and an empty token
    // simply never matches anything.
    private enum CodingKeys: String, CodingKey { case bytes = "b" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bytes = container.gateValue(Data.self, forKey: .bytes, default: Data())
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bytes, forKey: .bytes)
    }
}

// MARK: - SelectionDigest

/// Everything the app, the monitor and the shield extensions need to know about a
/// `FamilyActivitySelection` **without decoding it**.
///
/// This is the type that makes the 8 KB `GateState` budget achievable
/// (docs/05-architecture.md, persistence): the blob itself lives once in
/// ``SelectionTable`` and `state.plist` carries only these ~120 bytes of metadata
/// per rule. Apple's own note is the reason — selection blobs are large,
/// "especially if you use `includeEntireCategory`."
///
/// The counts are load-bearing, not cosmetic: they are what lets the rule editor
/// enforce the 50-token cap before a save, and what lets the reconciler decide a
/// rule is unenforceable without paying a `JSONDecoder` pass in the monitor.
public struct SelectionDigest: Codable, Sendable, Equatable, Hashable {

    /// Count of `FamilyActivitySelection.applicationTokens`.
    public var applicationCount: Int
    /// Count of `FamilyActivitySelection.categoryTokens`.
    public var categoryCount: Int
    /// Count of `FamilyActivitySelection.webDomainTokens`.
    public var webDomainCount: Int

    /// Mirrors `FamilyActivitySelection.includeEntireCategory`.
    ///
    /// Spelled with the Swift-idiomatic `includes` prefix; the SDK spells its own
    /// property `includeEntireCategory`. When true a single category token stands
    /// in for every app inside it, which is both the point of the flag and the
    /// reason the encoded blob balloons.
    public var includesEntireCategory: Bool

    /// Stable fingerprint of the encoded blob — see ``GateFingerprint``.
    ///
    /// Lets the reconciler answer "did this rule's selection change since I last
    /// wrote its `ManagedSettingsStore`?" by comparing 16 characters instead of
    /// re-decoding and re-writing a shield collection on every foreground.
    public var fingerprint: String

    /// Size of the encoded blob in bytes. Surfaced on the debug screen
    /// (docs/04-product-spec.md V1-11) because selection size is the single
    /// biggest lever on monitor memory pressure.
    public var byteCount: Int

    /// When the app last captured this digest from a live selection.
    public var capturedAt: Date

    public init(
        applicationCount: Int = 0,
        categoryCount: Int = 0,
        webDomainCount: Int = 0,
        includesEntireCategory: Bool = false,
        fingerprint: String = GateFingerprint.empty,
        byteCount: Int = 0,
        capturedAt: Date = .distantPast
    ) {
        self.applicationCount = max(0, applicationCount)
        self.categoryCount = max(0, categoryCount)
        self.webDomainCount = max(0, webDomainCount)
        self.includesEntireCategory = includesEntireCategory
        self.fingerprint = fingerprint
        self.byteCount = max(0, byteCount)
        self.capturedAt = capturedAt
    }

    /// Builds a digest from an already-encoded selection.
    ///
    /// - Parameters:
    ///   - encodedSelection: `JSONEncoder().encode(selection)` — produced by
    ///     `Kernel/Store/SelectionStore.swift`, the one place that may name
    ///     `FamilyActivitySelection`.
    ///   - applicationCount: `selection.applicationTokens.count`.
    ///   - categoryCount: `selection.categoryTokens.count`.
    ///   - webDomainCount: `selection.webDomainTokens.count`.
    ///   - includesEntireCategory: `selection.includeEntireCategory`.
    ///   - now: capture timestamp; injected so this is testable without a clock.
    public static func make(
        encodedSelection: Data,
        applicationCount: Int,
        categoryCount: Int,
        webDomainCount: Int,
        includesEntireCategory: Bool,
        now: Date
    ) -> SelectionDigest {
        SelectionDigest(
            applicationCount: applicationCount,
            categoryCount: categoryCount,
            webDomainCount: webDomainCount,
            includesEntireCategory: includesEntireCategory,
            fingerprint: GateFingerprint.hex(encodedSelection),
            byteCount: encodedSelection.count,
            capturedAt: now
        )
    }

    /// The count of whichever collection a kind lands in.
    public func count(of collection: TokenCollection) -> Int {
        switch collection {
        case .applications: applicationCount
        case .categories: categoryCount
        case .webDomains: webDomainCount
        }
    }

    /// Total tokens across all three collections. Informational only — the 50-cap
    /// is **per collection**, not on the sum.
    public var totalTokenCount: Int {
        applicationCount + categoryCount + webDomainCount
    }

    /// True when nothing is selected. An empty selection in ``RuleMode/blocklist``
    /// shields nothing; in ``RuleMode/allowlist`` it shields *everything*, which
    /// is a legitimate (if drastic) configuration.
    public var isEmpty: Bool { totalTokenCount == 0 }

    /// The collections that are over the silent 50-token cap, with their counts.
    ///
    /// Non-empty means the rule cannot be written to a `ManagedSettingsStore`
    /// without shielding nothing at all (docs/03-hard-constraints.md #34).
    public var overflowingCollections: [(collection: TokenCollection, count: Int)] {
        TokenCollection.allCases.compactMap { collection in
            let value = count(of: collection)
            guard value > GateLimits.maxTokensPerShieldCollection else { return nil }
            return (collection: collection, count: value)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case applicationCount = "apps"
        case categoryCount = "cats"
        case webDomainCount = "webs"
        case includesEntireCategory = "whole"
        case fingerprint = "fp"
        case byteCount = "size"
        case capturedAt = "at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            applicationCount: container.gateValue(Int.self, forKey: .applicationCount, default: 0),
            categoryCount: container.gateValue(Int.self, forKey: .categoryCount, default: 0),
            webDomainCount: container.gateValue(Int.self, forKey: .webDomainCount, default: 0),
            includesEntireCategory: container.gateValue(Bool.self, forKey: .includesEntireCategory, default: false),
            fingerprint: container.gateValue(String.self, forKey: .fingerprint, default: GateFingerprint.empty),
            byteCount: container.gateValue(Int.self, forKey: .byteCount, default: 0),
            capturedAt: container.gateValue(Date.self, forKey: .capturedAt, default: .distantPast)
        )
    }
}

// MARK: - SelectionRef

/// A rule's pointer into ``SelectionTable``, plus the metadata needed to reason
/// about the selection without loading it.
///
/// `GateState` stores this; `selections.plist` stores the blob. That split is the
/// whole reason `state.plist` fits in 8 KB.
public struct SelectionRef: Codable, Sendable, Equatable, Hashable {

    /// Identity of the ``SelectionRecord`` in ``SelectionTable``.
    ///
    /// Deliberately **not** the rule's own id. A queued loosening that swaps a
    /// rule's apps has to park the *new* blob somewhere until the lock expires
    /// (docs/04-product-spec.md V1-4), so a selection is owned by either a rule or
    /// a pending change — see ``SelectionOwner``. Keying the table by rule id
    /// would make staging impossible.
    public var id: UUID

    /// Metadata snapshot of the referenced blob, kept in sync by the app on every
    /// write. ``SelectionRecord/digest`` is the authority; this is the cheap copy.
    public var digest: SelectionDigest

    public init(id: UUID, digest: SelectionDigest) {
        self.id = id
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case digest = "d"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is the one genuinely required field: a ref that names nothing is
        // not repairable, and letting the decode throw lets the lossy array
        // decoder in GateState drop just this element instead of the whole file.
        id = try container.decode(UUID.self, forKey: .id)
        digest = container.gateValue(SelectionDigest.self, forKey: .digest, default: SelectionDigest())
    }
}

// MARK: - Rule

/// A name, a selection, a mode, an optional schedule, and an on/off state
/// (docs/04-product-spec.md V1-2).
///
/// Each rule owns its own `ManagedSettingsStore(named: .rule(id))` so rules never
/// clobber each other's shield sets, and its own repeating `DeviceActivityName`
/// (`gate.rule:<id>`) — **one per rule, never one per weekday**, or the 20-activity
/// cap is blown at rule #3 (docs/04-product-spec.md V1-5). Capped at
/// ``GateLimits/maxRules``.
public struct Rule: Codable, Sendable, Equatable, Hashable, Identifiable {

    /// Longest user-visible rule name. Also the shield `title`
    /// (docs/04-product-spec.md V1-6), which is why it is short: the shield is a
    /// fixed template with no wrapping control (docs/03-hard-constraints.md #28).
    public static let maxNameLength = 60

    public var id: UUID
    public var name: String
    public var mode: RuleMode

    /// The user-facing on/off state. A disabled rule keeps its selection and
    /// schedule; it just contributes nothing to any shield set.
    ///
    /// Turning this **on** is a tightening and applies immediately; turning it
    /// **off** is a loosening and is queued behind the Lock
    /// (docs/04-product-spec.md V1-4).
    public var isEnabled: Bool

    /// `nil` means "whenever the rule is enabled" — no time restriction at all.
    public var schedule: RuleSchedule?

    /// `nil` means the user has not picked anything yet. A rule in that state is
    /// surfaced by ``validate()`` and is skipped by the reconciler rather than
    /// written as an empty store.
    public var selection: SelectionRef?

    /// Display order on the home screen. Normalized to `0..<rules.count` by
    /// ``GateState/migrate(_:now:calendar:)``.
    public var sortIndex: Int

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "",
        mode: RuleMode = .blocklist,
        isEnabled: Bool = false,
        schedule: RuleSchedule? = nil,
        selection: SelectionRef? = nil,
        sortIndex: Int = 0,
        createdAt: Date = .distantPast,
        updatedAt: Date = .distantPast
    ) {
        self.id = id
        self.name = String(name.prefix(Rule.maxNameLength))
        self.mode = mode
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.selection = selection
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Whether this rule should be contributing to a shield set right now.
    ///
    /// This is the exact predicate `GateActivityMonitor.intervalDidStart` uses to
    /// decide whether to no-op: weekday scoping is evaluated here, in the
    /// callback, rather than by registering one `DeviceActivityName` per weekday
    /// (docs/04-product-spec.md V1-5).
    ///
    /// - Parameters:
    ///   - date: the instant to test.
    ///   - calendar: injected so tests can pin a time zone and cross a DST
    ///     boundary without touching the process's current locale
    ///     (docs/06-build-plan.md step 3.11).
    ///
    /// Note this answers only "is the rule in force by its own configuration".
    /// Live ``Grant``s subtract from the shield set afterwards and are applied by
    /// `Kernel/Enforcement/ShieldWriter.swift`, not here.
    public func shouldEnforce(at date: Date, in calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        guard let schedule else { return true }

        // A schedule that is not well-formed — zero length, or no weekdays —
        // cannot express a window at all. It is read as "no window" (always in
        // force), never as "empty window" (never in force).
        //
        // This is the one place in the model where the fail direction is a
        // judgement call, so it is stated plainly. The editor rejects both shapes
        // (``RuleSchedule/validate()`` marks them blocking), so this can only be
        // reached from a torn `state.plist`. Given that, failing open would mean
        // a single bad byte silently removes a block the user is relying on — the
        // one failure this product cannot have (docs/05-architecture.md,
        // persistence rationale). Failing closed instead costs the user a rule
        // that is briefly stricter than they asked for, which is visible,
        // explicable, and fixable in the editor.
        //
        // The honest cost: restoring the intended narrower window afterwards is a
        // *shrink*, so it goes through the Lock (docs/04-product-spec.md V1-4).
        // That is the correct behaviour for a commitment device and the UI should
        // say so rather than special-case it.
        guard schedule.isWellFormed else { return true }
        return schedule.contains(date, in: calendar)
    }

    /// Everything wrong with this rule, in the order the editor should surface it.
    ///
    /// Empty means the rule is safe to write to a `ManagedSettingsStore`. The
    /// caller that ignores a ``RuleIssue/tokenCapExceeded(collection:count:limit:)``
    /// ships a rule that silently shields nothing
    /// (docs/03-hard-constraints.md #34).
    public func validate() -> [RuleIssue] {
        var issues: [RuleIssue] = []

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { issues.append(.emptyName) }
        if name.count > Rule.maxNameLength {
            issues.append(.nameTooLong(limit: Rule.maxNameLength))
        }

        switch selection {
        case .none:
            issues.append(.noSelection)
        case .some(let ref):
            if ref.digest.isEmpty { issues.append(.emptySelection) }
            for overflow in ref.digest.overflowingCollections {
                issues.append(.tokenCapExceeded(
                    collection: overflow.collection,
                    count: overflow.count,
                    limit: GateLimits.maxTokensPerShieldCollection
                ))
            }
        }

        if let schedule {
            issues.append(contentsOf: schedule.validate())
        }

        return issues
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name = "n"
        case mode = "m"
        case isEnabled = "on"
        case schedule = "sch"
        case selection = "sel"
        case sortIndex = "idx"
        case createdAt = "c"
        case updatedAt = "u"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // A rule with no id cannot be matched to its ManagedSettingsStore, its
        // DeviceActivityName or its shield copy, so this is the one hard
        // requirement. Everything else defaults.
        let id = try container.decode(UUID.self, forKey: .id)

        // Unknown `mode` raw value => .blocklist. This only happens when a NEWER
        // build wrote the file, and the store refuses to write back over a
        // newer file (``GateState/MigrationReport/isFromFuture``), so the
        // coercion is display-only and never persisted on top of the real value.
        // .blocklist rather than .allowlist because a mode we do not understand
        // must not silently start shielding every app on the device.
        let mode = container.gateRaw(RuleMode.self, forKey: .mode, default: .blocklist)

        self.init(
            id: id,
            name: container.gateValue(String.self, forKey: .name, default: ""),
            mode: mode,
            isEnabled: container.gateValue(Bool.self, forKey: .isEnabled, default: false),
            schedule: container.gateOptional(RuleSchedule.self, forKey: .schedule),
            selection: container.gateOptional(SelectionRef.self, forKey: .selection),
            sortIndex: container.gateValue(Int.self, forKey: .sortIndex, default: 0),
            createdAt: container.gateValue(Date.self, forKey: .createdAt, default: .distantPast),
            updatedAt: container.gateValue(Date.self, forKey: .updatedAt, default: .distantPast)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode.rawValue, forKey: .mode)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(schedule, forKey: .schedule)
        try container.encodeIfPresent(selection, forKey: .selection)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

// MARK: - RuleIssue

/// A reason a ``Rule`` cannot be saved or cannot be enforced.
///
/// Deliberately **not** `Codable`: these are computed on demand for the editor
/// (docs/04-product-spec.md V1-2) and the debug screen (V1-11) and must never be
/// persisted, or a stale issue outlives the thing that caused it. User-facing
/// copy for each case lives in `GateKernelUI`; the kernel has no localization.
public enum RuleIssue: Sendable, Equatable, Hashable {
    case emptyName
    case nameTooLong(limit: Int)
    case noSelection
    case emptySelection
    /// Over the silent 50-per-collection cap (docs/03-hard-constraints.md #34).
    case tokenCapExceeded(collection: TokenCollection, count: Int, limit: Int)
    /// Window shorter than `DeviceActivityCenter`'s 15-minute floor; would throw
    /// `MonitoringError.intervalTooShort`.
    case scheduleTooShort(seconds: TimeInterval, minimum: TimeInterval)
    /// Window longer than the one-week ceiling; would throw `.intervalTooLong`.
    case scheduleTooLong(seconds: TimeInterval, maximum: TimeInterval)
    /// Start equals end. There is no sane reading of a zero-length daily window
    /// and iOS would reject it as `.intervalTooShort`.
    case degenerateSchedule
    /// A weekday mask with nothing in it never fires.
    case scheduleHasNoWeekdays
    /// `warningTime` must land inside the window or `intervalWillEndWarning`
    /// cannot be scheduled.
    case warningTimeTooLong(seconds: TimeInterval, windowSeconds: TimeInterval)

    /// True for issues that make the rule unenforceable rather than merely
    /// untidy. The editor blocks Save on these; the reconciler skips such rules.
    public var isBlocking: Bool {
        switch self {
        case .nameTooLong, .emptyName:
            false
        case .noSelection, .emptySelection, .tokenCapExceeded,
             .scheduleTooShort, .scheduleTooLong, .degenerateSchedule,
             .scheduleHasNoWeekdays, .warningTimeTooLong:
            true
        }
    }
}

// MARK: - SelectionOwner

/// Who a ``SelectionRecord`` belongs to.
///
/// Two owners, because a queued loosening has to stage a *future* selection while
/// the current one stays enforced (docs/04-product-spec.md V1-4). Applying the
/// pending change is then a re-parent plus a delete, never a blob copy.
public enum SelectionOwner: Sendable, Equatable, Hashable {
    /// Live: this blob is what `Kernel/Enforcement/ShieldWriter.swift` writes.
    case rule(UUID)
    /// Staged: applies only if and when that ``PendingChange`` ripens.
    case pendingChange(UUID)
    /// An owner written by a newer build. Never enforced, never staged — kept so
    /// that a downgrade-then-upgrade round trip does not lose the blob.
    case unrecognized(type: String, id: UUID?)

    /// The owning object's id, when we understand the owner.
    public var id: UUID? {
        switch self {
        case .rule(let id), .pendingChange(let id): id
        case .unrecognized(_, let id): id
        }
    }
}

extension SelectionOwner: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "t"
        case id
    }

    private enum Discriminator {
        static let rule = "rule"
        static let pendingChange = "pending"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = container.gateValue(String.self, forKey: .type, default: "")
        let id = container.gateOptional(UUID.self, forKey: .id)
        switch (type, id) {
        case (Discriminator.rule, .some(let id)): self = .rule(id)
        case (Discriminator.pendingChange, .some(let id)): self = .pendingChange(id)
        default: self = .unrecognized(type: type, id: id)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rule(let id):
            try container.encode(Discriminator.rule, forKey: .type)
            try container.encode(id, forKey: .id)
        case .pendingChange(let id):
            try container.encode(Discriminator.pendingChange, forKey: .type)
            try container.encode(id, forKey: .id)
        case .unrecognized(let type, let id):
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
        }
    }
}

// MARK: - SelectionRecord

/// One `FamilyActivitySelection` blob, stored exactly once.
public struct SelectionRecord: Codable, Sendable, Equatable, Hashable, Identifiable {

    /// Matches ``SelectionRef/id``.
    public var id: UUID

    public var owner: SelectionOwner

    /// `JSONEncoder().encode(familyActivitySelection)`.
    ///
    /// JSON rather than a property list because Apple's own guidance for
    /// persisting a selection is `JSONEncoder` -> App Group
    /// (docs/02-api-reference.md §5), and because the blob is opaque either way —
    /// there is nothing in it a human would want to read out of the plist.
    public var payload: Data

    /// Authoritative digest. ``SelectionRef/digest`` in `state.plist` is a copy
    /// kept in sync on write; if the two ever disagree, this one wins.
    public var digest: SelectionDigest

    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        owner: SelectionOwner,
        payload: Data,
        digest: SelectionDigest,
        updatedAt: Date
    ) {
        self.id = id
        self.owner = owner
        self.payload = payload
        self.digest = digest
        self.updatedAt = updatedAt
    }

    /// A cheap reference to this record, for storing on a ``Rule``.
    public var ref: SelectionRef { SelectionRef(id: id, digest: digest) }

    /// Whether ``payload`` still hashes to what ``digest`` claims.
    ///
    /// A mismatch means a torn write — the file was replaced between the blob and
    /// the metadata. Callers treat it as "selection unknown" and route the user
    /// to the recovery flow (docs/04-product-spec.md V1-9) rather than writing a
    /// shield set they cannot vouch for.
    public var isConsistent: Bool {
        GateFingerprint.hex(payload) == digest.fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case owner = "o"
        case payload = "p"
        case digest = "d"
        case updatedAt = "u"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let payload = container.gateValue(Data.self, forKey: .payload, default: Data())
        self.init(
            id: id,
            owner: container.gateValue(
                SelectionOwner.self,
                forKey: .owner,
                default: .unrecognized(type: "", id: nil)
            ),
            payload: payload,
            digest: container.gateValue(SelectionDigest.self, forKey: .digest, default: SelectionDigest()),
            updatedAt: container.gateValue(Date.self, forKey: .updatedAt, default: .distantPast)
        )
    }
}

// MARK: - SelectionTable

/// The side table: every `FamilyActivitySelection` blob in the install, in one
/// file, keyed by selection id and back-referenced to its owner.
///
/// **Persisted separately from `GateState`, at ``fileName``, by
/// `Kernel/Store/SelectionStore.swift`.** It has no 8 KB budget — eight rules of
/// fifty tokens each is comfortably a few hundred KB and that is fine, because
/// only the processes that actually need tokens ever read it:
///
/// | Process | Reads | Writes |
/// |---|---|---|
/// | `Gate.app` | yes | **yes — sole writer** |
/// | `GateActivityMonitor` | yes, lazily, one record at a time | never |
/// | `GateShieldAction` | only the one record it needs for a grant | never (it appends to `inbox/`) |
/// | `GateShieldConfiguration` | **never** — it is latency-bounded and reads `shield.plist` instead | never |
/// | `GateReport` | never | never |
///
/// The monitor's 6 MB ceiling is why `SelectionStore` must expose a
/// one-record-at-a-time read and why nothing here encourages loading
/// ``records`` whole (docs/03-hard-constraints.md #31).
public struct SelectionTable: Codable, Sendable, Equatable {

    /// Filename inside the App Group container. `AppGroupContainer.selectionsURL`
    /// is built from this constant so the name exists in exactly one place.
    public static let fileName = "selections.plist"

    /// Bumped only for a shape change that ``GateState/migrate(_:now:calendar:)``
    /// would have to know about.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Mirrors ``GateState/generation`` at the time of the write, so a reader can
    /// tell whether the two files came from the same app write. They are written
    /// under one `NSFileCoordinator` batch but are still two files; a mismatch
    /// means the reader raced a write and should re-read.
    public var generation: Int

    public var updatedAt: Date

    /// Unordered. Eight rules plus at most ``GateLimits/maxRevertActivities``
    /// staged changes puts a realistic ceiling around a dozen entries, so linear
    /// lookup is cheaper than building a dictionary the monitor would have to
    /// allocate.
    public var records: [SelectionRecord]

    public init(
        schemaVersion: Int = SelectionTable.currentSchemaVersion,
        generation: Int = 0,
        updatedAt: Date = .distantPast,
        records: [SelectionRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.updatedAt = updatedAt
        self.records = records
    }

    public subscript(id: UUID) -> SelectionRecord? {
        records.first { $0.id == id }
    }

    /// The live record for a rule, if one is stored.
    public func record(forRuleID ruleID: UUID) -> SelectionRecord? {
        records.first { $0.owner == .rule(ruleID) }
    }

    /// The staged record for a queued loosening, if one is stored.
    public func record(forPendingChangeID pendingChangeID: UUID) -> SelectionRecord? {
        records.first { $0.owner == .pendingChange(pendingChangeID) }
    }

    /// Inserts or replaces a record by id.
    public mutating func upsert(_ record: SelectionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// Re-parents a staged blob onto a rule and drops whatever that rule pointed
    /// at before. This is how a ripe ``PendingChange/Operation/replaceSelection(ruleID:selection:)``
    /// is applied: no blob is ever copied, so the operation cannot half-succeed.
    ///
    /// - Returns: the adopted record, or `nil` if `selectionID` was not present.
    @discardableResult
    public mutating func adopt(selectionID: UUID, asRule ruleID: UUID, at now: Date) -> SelectionRecord? {
        guard records.contains(where: { $0.id == selectionID }) else { return nil }
        records.removeAll { $0.owner == .rule(ruleID) && $0.id != selectionID }
        guard let index = records.firstIndex(where: { $0.id == selectionID }) else { return nil }
        records[index].owner = .rule(ruleID)
        records[index].updatedAt = now
        return records[index]
    }

    /// Drops every record owned by `owner`. Used when a rule is deleted or a
    /// pending change is cancelled.
    public mutating func removeAll(ownedBy owner: SelectionOwner) {
        records.removeAll { $0.owner == owner }
    }

    /// Drops records whose owner no longer exists.
    ///
    /// Called by the app after every reconcile. Without it, a deleted rule's blob
    /// is never reclaimed — and blobs are the only thing in the container with a
    /// meaningful size (docs/05-architecture.md, persistence).
    ///
    /// - Returns: the ids that were dropped, for the debug screen.
    @discardableResult
    public mutating func pruneOrphans(liveRuleIDs: Set<UUID>, livePendingChangeIDs: Set<UUID>) -> [UUID] {
        var dropped: [UUID] = []
        records.removeAll { record in
            let keep: Bool
            switch record.owner {
            case .rule(let id): keep = liveRuleIDs.contains(id)
            case .pendingChange(let id): keep = livePendingChangeIDs.contains(id)
            case .unrecognized(let type, _):
                // A named owner we do not understand belongs to a newer build:
                // preserve it, because reclaiming another version's staged blob
                // would corrupt a pending change we cannot even read. An owner
                // with no name at all is not a future record, it is a torn one —
                // nothing references it and nothing ever will, so it goes.
                keep = !type.isEmpty
            }
            if !keep { dropped.append(record.id) }
            return !keep
        }
        return dropped
    }

    /// Sum of every stored blob, for the debug screen.
    public var payloadByteCount: Int {
        records.reduce(0) { $0 + $1.payload.count }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case generation = "g"
        case updatedAt = "u"
        case records = "r"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: container.gateValue(Int.self, forKey: .schemaVersion, default: 0),
            generation: container.gateValue(Int.self, forKey: .generation, default: 0),
            updatedAt: container.gateValue(Date.self, forKey: .updatedAt, default: .distantPast),
            // Lossy: one unreadable blob must not cost the user every other rule.
            records: container.gateLossyArray(SelectionRecord.self, forKey: .records)
        )
    }
}

// MARK: - TimeOfDay

/// A wall-clock time of day, with no date and no time zone.
///
/// Deliberately *not* a `Date`. A repeating `DeviceActivitySchedule` is a
/// time-of-day concept: Apple's `intervalStart` / `intervalEnd` take
/// `DateComponents`, and adding `.day` to a `repeats: true` schedule turns it into
/// an absolute date that conflicts with the repeat (docs/02-api-reference.md §7).
/// Storing a `Date` here would invite exactly that mistake and would also break
/// the moment the user changed time zone.
public struct TimeOfDay: Codable, Sendable, Hashable, Comparable {

    public static let secondsPerDay = 24 * 60 * 60

    /// 0...23
    public var hour: Int
    /// 0...59
    public var minute: Int
    /// 0...59
    public var second: Int

    /// Clamps rather than traps. These values reach here from a decoded plist and
    /// from pickers; a bad one must degrade, not crash the monitor.
    public init(hour: Int, minute: Int, second: Int = 0) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.second = min(max(second, 0), 59)
    }

    /// Wraps into a single day, so arithmetic on a window that crosses midnight
    /// cannot produce an invalid value.
    public init(secondsFromMidnight seconds: Int) {
        let wrapped = ((seconds % TimeOfDay.secondsPerDay) + TimeOfDay.secondsPerDay) % TimeOfDay.secondsPerDay
        self.init(hour: wrapped / 3600, minute: (wrapped % 3600) / 60, second: wrapped % 60)
    }

    public var secondsFromMidnight: Int { hour * 3600 + minute * 60 + second }

    /// `DateComponents` carrying **exactly** `[.hour, .minute, .second]`.
    ///
    /// The component set is load-bearing. Thread 726331 shows that *mismatched*
    /// component sets between `intervalStart` and `intervalEnd` make the previous
    /// start resolve after the previous end, so the schedule reads as
    /// continuously active for days and every threshold breaches instantly. The
    /// invariant both sides of the dossier's contradiction agree on is: never
    /// mismatch (docs/02-api-reference.md §7). Both ends of a repeating window are
    /// built from this one property, so they cannot disagree.
    ///
    /// One-shot expiry schedules (`repeats: false`) use the full
    /// `[.year ... .second]` set instead and are built by
    /// `Kernel/Engine/ScheduleBuilder.swift` from absolute `Date`s, not from this
    /// type.
    public var dateComponents: DateComponents {
        DateComponents(hour: hour, minute: minute, second: second)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.secondsFromMidnight < rhs.secondsFromMidnight
    }

    private enum CodingKeys: String, CodingKey {
        case hour = "h"
        case minute = "m"
        case second = "s"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hour: container.gateValue(Int.self, forKey: .hour, default: 0),
            minute: container.gateValue(Int.self, forKey: .minute, default: 0),
            second: container.gateValue(Int.self, forKey: .second, default: 0)
        )
    }
}

// MARK: - WeekdayMask

/// Which days of the week a ``RuleSchedule`` is live on.
///
/// Bit *n* corresponds to `Calendar` weekday `n + 1`, i.e. bit 0 is Sunday, in
/// line with the Gregorian `weekday` component. `Calendar.firstWeekday` changes
/// how a week is *displayed*, never how `weekday` is *numbered*, so this mapping
/// is locale-independent. (Presentation order is `GateKernelUI`'s problem.)
///
/// This is the mechanism that keeps Gate inside the 20-activity cap: weekday
/// scoping is evaluated in `intervalDidStart` against this mask, instead of
/// registering one `DeviceActivityName` per rule-per-weekday, which would blow
/// the cap at rule #3 (docs/04-product-spec.md V1-5).
public struct WeekdayMask: OptionSet, Sendable, Hashable {

    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let sunday = WeekdayMask(rawValue: 1 << 0)
    public static let monday = WeekdayMask(rawValue: 1 << 1)
    public static let tuesday = WeekdayMask(rawValue: 1 << 2)
    public static let wednesday = WeekdayMask(rawValue: 1 << 3)
    public static let thursday = WeekdayMask(rawValue: 1 << 4)
    public static let friday = WeekdayMask(rawValue: 1 << 5)
    public static let saturday = WeekdayMask(rawValue: 1 << 6)

    public static let everyday: WeekdayMask = [
        .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday,
    ]
    /// Monday through Friday.
    public static let workweek: WeekdayMask = [.monday, .tuesday, .wednesday, .thursday, .friday]
    /// Saturday and Sunday.
    public static let weekend: WeekdayMask = [.saturday, .sunday]

    /// The mask for a single `Calendar` weekday number (1 = Sunday ... 7 =
    /// Saturday). Out-of-range input yields the empty mask, which simply never
    /// matches.
    public init(calendarWeekday weekday: Int) {
        guard (1...7).contains(weekday) else {
            self.init(rawValue: 0)
            return
        }
        self.init(rawValue: 1 << (weekday - 1))
    }

    public func contains(calendarWeekday weekday: Int) -> Bool {
        let single = WeekdayMask(calendarWeekday: weekday)
        return !single.isEmpty && contains(single)
    }

    /// The `Calendar` weekday numbers in this mask, ascending.
    public var calendarWeekdays: [Int] {
        (1...7).filter { contains(calendarWeekday: $0) }
    }
}

extension WeekdayMask: Codable {
    /// Encoded as a bare `Int`, not as `{"rawValue": 127}`. Synthesized
    /// `Codable` for a `RawRepresentable` struct produces the keyed form, which
    /// is four times the bytes for no benefit inside an 8 KB budget.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(Int.self)) ?? WeekdayMask.everyday.rawValue
        // Mask off bits a newer build might define. An unknown weekday bit would
        // otherwise survive round trips and make `contains` unpredictable.
        self.init(rawValue: raw & WeekdayMask.everyday.rawValue)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - RuleSchedule

/// A repeating daily window, optionally scoped to particular weekdays
/// (docs/04-product-spec.md V1-5).
///
/// Maps to exactly one `DeviceActivitySchedule` with `repeats: true`, built by
/// `Kernel/Engine/ScheduleBuilder.swift` from ``intervalStartComponents`` and
/// ``intervalEndComponents``.
///
/// **Honest-copy obligation.** A schedule does not start or stop at the minute.
/// Apple, verbatim: *"Activity begins when someone first uses a device within the
/// scheduled time interval and ends when someone first uses the device outside of
/// the interval."* `intervalDidStart` / `intervalDidEnd` fire only when the device
/// is in use (docs/03-hard-constraints.md #27). The UI must say so
/// (docs/04-product-spec.md V1-5) and the `UNCalendarNotificationTrigger` backstop
/// exists because of it (docs/04-product-spec.md V1-10).
public struct RuleSchedule: Codable, Sendable, Equatable, Hashable {

    /// Default lead time for `intervalWillEndWarning`, in minutes
    /// (docs/04-product-spec.md V1-5).
    public static let defaultWarningMinutes = 5

    public var start: TimeOfDay
    public var end: TimeOfDay

    /// Which days the window *begins* on. For a window that crosses midnight the
    /// mask names the **start** day: a "22:00–06:00, Fridays" schedule is live
    /// from Friday 22:00 to Saturday 06:00, not Friday 00:00–06:00.
    public var weekdays: WeekdayMask

    /// Lead time for `intervalWillStartWarning` / `intervalWillEndWarning`, in
    /// minutes. `nil` disables both warnings.
    public var warningMinutes: Int?

    public init(
        start: TimeOfDay,
        end: TimeOfDay,
        weekdays: WeekdayMask = .everyday,
        warningMinutes: Int? = RuleSchedule.defaultWarningMinutes
    ) {
        self.start = start
        self.end = end
        self.weekdays = weekdays
        self.warningMinutes = warningMinutes.map { max(0, $0) }
    }

    /// True when the window runs past midnight into the following day.
    public var crossesMidnight: Bool { end < start }

    /// Nominal window length in seconds.
    ///
    /// **Nominal**: on a DST transition day the real elapsed time is an hour more
    /// or less. That is correct for validating against iOS's 15-minute floor and
    /// one-week ceiling, which are expressed in wall-clock components, and it is
    /// why ``contains(_:in:)`` compares *components* rather than doing date
    /// arithmetic.
    public var duration: TimeInterval {
        let startSeconds = start.secondsFromMidnight
        let endSeconds = end.secondsFromMidnight
        if endSeconds > startSeconds { return TimeInterval(endSeconds - startSeconds) }
        if endSeconds < startSeconds {
            return TimeInterval(TimeOfDay.secondsPerDay - startSeconds + endSeconds)
        }
        return 0
    }

    /// Whether the window is usable at all: non-zero length, at least one weekday.
    ///
    /// Distinct from ``validate()``, which additionally checks iOS's interval
    /// limits. A 10-minute window is well-formed but cannot be registered with
    /// `DeviceActivityCenter`.
    public var isWellFormed: Bool { duration > 0 && !weekdays.isEmpty }

    /// `DateComponents` for `DeviceActivitySchedule.intervalStart`.
    /// Always `[.hour, .minute, .second]` — see ``TimeOfDay/dateComponents``.
    public var intervalStartComponents: DateComponents { start.dateComponents }

    /// `DateComponents` for `DeviceActivitySchedule.intervalEnd`. Same component
    /// set as ``intervalStartComponents``, by construction.
    public var intervalEndComponents: DateComponents { end.dateComponents }

    /// `DateComponents` for `DeviceActivitySchedule.warningTime`, or `nil`.
    public var warningComponents: DateComponents? {
        warningMinutes.map { DateComponents(minute: $0) }
    }

    /// Whether `date` falls inside this window.
    ///
    /// The monitor calls this in `intervalDidStart` to decide whether to no-op on
    /// a weekday the rule does not cover (docs/04-product-spec.md V1-5), and the
    /// reconciler calls it to recompute the intended shield set from absolute
    /// timestamps on every foreground (V1-10).
    ///
    /// Half-open: `start` is inside the window, `end` is not. Two adjacent
    /// windows therefore never both claim the boundary second.
    ///
    /// **DST.** Comparison is on the wall-clock components of `date`, never on
    /// dates reconstructed from ``start``/``end``. On a spring-forward day a
    /// 02:00–03:00 window simply never matches, because no instant that day has
    /// an hour component of 2 — which is the same thing iOS does with the
    /// underlying `DateComponents`. On a fall-back day the window matches twice,
    /// for a real two hours. Both are the correct answers and both are covered by
    /// `Tests/GateKernelTests/ScheduleBuilderTests.swift`.
    ///
    /// - Parameter calendar: injected so tests can pin a time zone.
    public func contains(_ date: Date, in calendar: Calendar = .current) -> Bool {
        guard isWellFormed else { return false }

        let components = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
        guard let weekday = components.weekday,
              let hour = components.hour,
              let minute = components.minute
        else { return false }

        let secondsIntoDay = hour * 3600 + minute * 60 + (components.second ?? 0)
        let startSeconds = start.secondsFromMidnight
        let endSeconds = end.secondsFromMidnight

        guard crossesMidnight else {
            guard weekdays.contains(calendarWeekday: weekday) else { return false }
            return secondsIntoDay >= startSeconds && secondsIntoDay < endSeconds
        }

        // Wrapping window. The tail after midnight belongs to the PREVIOUS day's
        // occurrence, so it is gated on the previous weekday's bit.
        if secondsIntoDay >= startSeconds {
            return weekdays.contains(calendarWeekday: weekday)
        }
        if secondsIntoDay < endSeconds {
            return weekdays.contains(calendarWeekday: weekday == 1 ? 7 : weekday - 1)
        }
        return false
    }

    /// Everything that would stop this window being registered with
    /// `DeviceActivityCenter`.
    ///
    /// `startMonitoring` throws `.intervalTooShort` / `.intervalTooLong` at
    /// whatever arbitrary moment the schedule is armed — typically while applying
    /// a block. Catching it here means the editor can refuse the save instead
    /// (docs/02-api-reference.md §7, §14).
    public func validate() -> [RuleIssue] {
        var issues: [RuleIssue] = []
        if weekdays.isEmpty { issues.append(.scheduleHasNoWeekdays) }

        let seconds = duration
        if seconds == 0 {
            issues.append(.degenerateSchedule)
        } else if seconds < GateLimits.minScheduleInterval {
            issues.append(.scheduleTooShort(seconds: seconds, minimum: GateLimits.minScheduleInterval))
        } else if seconds > GateLimits.maxScheduleInterval {
            issues.append(.scheduleTooLong(seconds: seconds, maximum: GateLimits.maxScheduleInterval))
        }

        if let warningMinutes, seconds > 0 {
            let warningSeconds = TimeInterval(warningMinutes * 60)
            if warningSeconds >= seconds {
                issues.append(.warningTimeTooLong(seconds: warningSeconds, windowSeconds: seconds))
            }
        }
        return issues
    }

    private enum CodingKeys: String, CodingKey {
        case start = "s"
        case end = "e"
        case weekdays = "w"
        case warningMinutes = "warn"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Both ends are required, and this is the one initializer in Kernel/Model
        // that deliberately throws. Defaulting a missing end to midnight would
        // manufacture a zero-length window — a schedule that looks configured and
        // enforces nothing. Throwing instead makes `Rule.init(from:)`'s
        // `gateOptional` yield `nil`, i.e. "this rule has no schedule", which is a
        // coherent state the user can see and edit, and which
        // ``Rule/shouldEnforce(at:in:)`` reads as always-in-force.
        guard let start = container.gateOptional(TimeOfDay.self, forKey: .start),
              let end = container.gateOptional(TimeOfDay.self, forKey: .end)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: CodingKeys.start,
                in: container,
                debugDescription: "RuleSchedule requires both intervalStart and intervalEnd."
            )
        }

        self.init(
            start: start,
            end: end,
            weekdays: container.gateValue(WeekdayMask.self, forKey: .weekdays, default: .everyday),
            warningMinutes: container.gateOptional(Int.self, forKey: .warningMinutes)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encodeIfPresent(warningMinutes, forKey: .warningMinutes)
    }
}
