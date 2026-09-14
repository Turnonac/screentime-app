//
//  ActivityNameCodec.swift
//  GateKernel
//
//  The `DeviceActivityName` codec (docs/05-architecture.md, "The `DeviceActivityName`
//  codec (load-bearing)").
//
//  Build plan: docs/06-build-plan.md step 3.7.
//
//  WHY THIS FILE EXISTS AT ALL
//  A `DeviceActivityMonitor` callback receives **only the name**. Apple, via
//  docs/02-api-reference.md §8: *"The only payload is the name. No tokens, no
//  dates, no userInfo."* There is no `userInfo`, no dictionary, no side channel —
//  `intervalDidStart(for:)`, `intervalDidEnd(for:)` and
//  `eventDidReachThreshold(_:activity:)` are handed a string wrapper and nothing
//  else. Every scrap of context the monitor needs in order to know *what just
//  happened* therefore has to be encoded into that string and parsed back out
//  inside a 6 MB process that was cold-started microseconds ago
//  (docs/03-hard-constraints.md #31).
//
//  That makes this the narrowest and most load-bearing interface in the product.
//  The three shapes, verbatim from docs/05-architecture.md:
//
//      "gate.rule:<ruleUUID>"                        repeating daily window
//      "gate.grant:<ruleUUID>|<grantUUID>"           one-shot expiry timer
//      "gate.revert:<ruleUUID>|<pendingChangeUUID>"  auto-revert timer
//
//  RULES FOR THIS FILE
//  1. **`decode` is total.** Every `String` in the universe maps to either a
//     `GateActivity` or `nil`. No `try!`, no force-unwrap, no precondition, no
//     array subscript that can be out of range. The monitor is handed names by a
//     system daemon across a process boundary; a crash here is a block that
//     silently stops being enforced, and the user has no way to tell.
//  2. **`decode(encode(x)) == x` for every `x`.** Enforced by
//     `Tests/GateKernelTests/ActivityNameCodecTests.swift`
//     (docs/06-build-plan.md step 3.11). The reverse — `encode(decode(s)) == s` —
//     is deliberately *not* guaranteed: decoding is case-insensitive about UUIDs
//     (see ``ActivityNameCodec/decode(_:)``) while encoding is canonical, so a
//     name that came back from the daemon lower-cased still parses but
//     re-encodes upper-cased. Compare parsed values, never raw strings.
//  3. **Foundation only in the pure layer.** The DeviceActivity types live in a
//     `#if os(iOS)` island at the bottom, mirroring the
//     `canImport(CryptoKit)` island in `Kernel/Model/LockPolicy.swift`, so the
//     parsing logic compiles and is testable in the platform-agnostic SwiftPM
//     package (docs/05-architecture.md, module layer split).
//  4. **The prefix comes from ``GateID/namespace``, never from a literal.** The
//     orphan sweep in `Kernel/Engine/Reconciler.swift` tests
//     `DeviceActivityName.isGateActivity` — `hasPrefix(GateID.namespace)` — before
//     it parses anything, and the two must agree or Gate will either stop another
//     component's activity or leak its own.
//

import Foundation

#if os(iOS)
import DeviceActivity
#endif

// MARK: - GateActivityKind

/// The tag that follows ``GateID/namespace`` in an encoded activity name.
///
/// Separate from ``GateActivity`` so the monitor can branch on the *kind* of a
/// name without paying for three `UUID(uuidString:)` parses — see
/// ``ActivityNameCodec/kind(ofRawName:)``. In a process with a 6 MB ceiling that
/// is not a micro-optimization, it is the difference between doing string work
/// and doing string work plus allocation on a path that runs on every callback.
public enum GateActivityKind: String, Sendable, Hashable, CaseIterable {

    /// A rule's repeating daily window. Exactly one per rule — **never one per
    /// weekday**, which would blow the 20-activity cap at rule #3
    /// (docs/04-product-spec.md V1-5). Weekday scoping is a calendar check inside
    /// `intervalDidStart`, via ``Rule/shouldEnforce(at:in:)``.
    case rule

    /// A one-shot timer whose `intervalDidEnd` marks a ``Grant`` as expired
    /// (docs/04-product-spec.md V1-7 step 3).
    case grant

    /// A one-shot timer whose `intervalDidEnd` marks a ``PendingChange`` as ripe,
    /// i.e. the Lock has run out (docs/04-product-spec.md V1-3, V1-4).
    case revert

    /// Number of `|`-separated fields the payload must contain. Used by the
    /// decoder as a hard shape check before any field is interpreted.
    var fieldCount: Int {
        switch self {
        case .rule: 1
        case .grant, .revert: 2
        }
    }
}

// MARK: - GateActivity

/// A decoded `DeviceActivityName`: everything the monitor can know about why it
/// was woken up.
///
/// The associated values are the identities of records in `state.plist`. The
/// monitor does **not** trust them as data — it re-reads `GateState` and
/// recomputes ground truth from absolute timestamps (docs/04-product-spec.md
/// V1-10). They are look-up keys, not payload. That distinction matters because
/// these strings round-trip through a system daemon that Gate does not control.
public enum GateActivity: Sendable, Hashable {

    case rule(ruleID: UUID)
    case grant(ruleID: UUID, grantID: UUID)

    /// An auto-revert timer for a queued loosening.
    ///
    /// `ruleID` is optional because not every ``PendingChange/Operation`` is
    /// rule-scoped: `setLockDelay`, `setRatchet`, `setInstallProtection`,
    /// `clearLockPassword` and `revokeAuthorization` all have
    /// ``PendingChange/Operation/ruleID`` == `nil`. The wire shape from
    /// docs/05-architecture.md has a fixed two-UUID payload, so the absent case is
    /// carried by the reserved sentinel ``GateActivity/unscopedID`` rather than by
    /// a variable-length name. Keeping the shape fixed means every Gate activity
    /// name has the same length and character class, which is what lets
    /// ``ActivityNameCodec/kind(ofRawName:)`` be a prefix test.
    case revert(ruleID: UUID?, changeID: UUID)

    /// The all-zero UUID, reserved to mean "this timer is not scoped to a rule".
    ///
    /// `UUID()` cannot generate it (RFC 4122 pins the version and variant bits),
    /// so no real ``Rule/id`` collides with it. A `state.plist` corrupted into
    /// carrying a zero rule id would decode as unscoped — which costs a diagnostic
    /// line in the debug screen and nothing else, because the reconciler recomputes
    /// from state rather than from the name.
    public static let unscopedID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public var kind: GateActivityKind {
        switch self {
        case .rule: .rule
        case .grant: .grant
        case .revert: .revert
        }
    }

    /// The rule this activity belongs to, if any.
    public var ruleID: UUID? {
        switch self {
        case .rule(let id): id
        case .grant(let id, _): id
        case .revert(let id, _): id
        }
    }

    /// The ``Grant`` or ``PendingChange`` this timer is armed for; `nil` for a
    /// repeating rule window, which has no single record behind it.
    public var recordID: UUID? {
        switch self {
        case .rule: nil
        case .grant(_, let grantID): grantID
        case .revert(_, let changeID): changeID
        }
    }

    /// Whether this activity is a one-shot timer rather than a repeating window.
    ///
    /// The two are armed with different `DeviceActivitySchedule` shapes and
    /// different `DateComponents` sets (docs/02-api-reference.md §7); see
    /// `Kernel/Engine/ScheduleBuilder.swift`.
    public var isOneShot: Bool { kind != .rule }

    /// The canonical encoded name.
    public var rawName: String { ActivityNameCodec.encode(self) }
}

extension GateActivity: CustomStringConvertible {
    /// The encoded name, so `logger.debug("\(activity)")` prints the exact string
    /// the daemon will hand back.
    public var description: String { rawName }
}

// MARK: - GateEventKey

/// A decoded `DeviceActivityEvent.Name`.
///
/// `eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity:)` has the
/// same "only the name" limitation as the interval callbacks
/// (docs/02-api-reference.md §8), so event names get the same treatment: shape
/// `"gate.evt:<ruleUUID>|<thresholdSeconds>"`.
///
/// v1 arms **no** events — no v1 `Rule` carries a usage budget
/// (docs/04-product-spec.md V1-2), and `eventDidReachThreshold` is the least
/// reliable part of the whole API (docs/03-hard-constraints.md #35). The codec
/// exists now because `Kernel/Engine/ScheduleBuilder.swift` builds
/// `DeviceActivityEvent` values (docs/06-build-plan.md step 3.6) and because the
/// V2-4 staircase puts many events inside **one** activity — events are cheap,
/// activities are capped at 20 (docs/04-product-spec.md V2-4). Encoding the
/// threshold into the name is what lets the monitor tell the steps apart.
public struct GateEventKey: Sendable, Hashable {

    /// The rule whose usage this event measures.
    public let ruleID: UUID

    /// The threshold in whole seconds. Screen Time accounting is minute-grained,
    /// so ``ScheduleBuilder`` only ever mints whole-minute values; seconds are the
    /// storage unit because `TimeInterval` does not round-trip through a decimal
    /// string identically on every platform and this string must compare equal
    /// across two processes.
    public let thresholdSeconds: Int

    /// Negative thresholds clamp to zero rather than trapping: this initializer is
    /// reachable from a decoded `state.plist`.
    public init(ruleID: UUID, thresholdSeconds: Int) {
        self.ruleID = ruleID
        self.thresholdSeconds = max(0, thresholdSeconds)
    }

    /// Convenience for callers holding a `TimeInterval`. Rounds to the nearest
    /// second; non-finite input becomes zero.
    public init(ruleID: UUID, threshold: TimeInterval) {
        let seconds = threshold.isFinite ? Int(threshold.rounded()) : 0
        self.init(ruleID: ruleID, thresholdSeconds: seconds)
    }

    /// The canonical encoded name.
    public var rawName: String { ActivityNameCodec.encode(event: self) }
}

extension GateEventKey: CustomStringConvertible {
    public var description: String { rawName }
}

// MARK: - ActivityNameCodec

/// Encodes and decodes every system-visible name Gate registers with
/// `DeviceActivityCenter`.
///
/// An uninhabited namespace, like ``GateID``: there is nothing to allocate and no
/// instance to keep alive inside the monitor.
public enum ActivityNameCodec {

    // MARK: Grammar

    /// Separates the kind tag from its payload: `gate.` **`grant`** `:` payload.
    ///
    /// Chosen because it cannot appear in a `UUID.uuidString` (hex digits and
    /// hyphens only) or in ``GateID/namespace``, so the grammar is unambiguous and
    /// the decoder can reject a second occurrence outright.
    public static let tagSeparator: Character = ":"

    /// Separates payload fields: `<ruleUUID>` **`|`** `<grantUUID>`. Also outside
    /// the UUID character set.
    public static let fieldSeparator: Character = "|"

    /// Tag for a `DeviceActivityEvent.Name`. Deliberately *not* a
    /// ``GateActivityKind`` case: an event name is not an activity name, and
    /// ``decode(_:)`` must reject one.
    public static let eventTag = "evt"

    // MARK: Encoding

    /// The canonical `DeviceActivityName` string for an activity.
    ///
    /// Total and allocation-bounded: two or three `uuidString`s and a join.
    public static func encode(_ activity: GateActivity) -> String {
        switch activity {
        case .rule(let ruleID):
            return name(tag: GateActivityKind.rule.rawValue, fields: [ruleID.uuidString])

        case .grant(let ruleID, let grantID):
            return name(
                tag: GateActivityKind.grant.rawValue,
                fields: [ruleID.uuidString, grantID.uuidString]
            )

        case .revert(let ruleID, let changeID):
            // `nil` becomes the reserved sentinel so the payload stays two fields
            // wide for every revert timer — see ``GateActivity/unscopedID``.
            let scope = (ruleID ?? GateActivity.unscopedID).uuidString
            return name(tag: GateActivityKind.revert.rawValue, fields: [scope, changeID.uuidString])
        }
    }

    /// The canonical `DeviceActivityEvent.Name` string for an event.
    public static func encode(event key: GateEventKey) -> String {
        name(tag: eventTag, fields: [key.ruleID.uuidString, String(key.thresholdSeconds)])
    }

    private static func name(tag: String, fields: [String]) -> String {
        GateID.namespace + tag + String(tagSeparator)
            + fields.joined(separator: String(fieldSeparator))
    }

    // MARK: Decoding

    /// Parses a raw `DeviceActivityName` string.
    ///
    /// Returns `nil` — never throws, never traps — for anything that is not an
    /// exactly-shaped Gate activity name: a foreign name, a Gate *event* name, a
    /// truncated name, a name with an extra separator, an empty field, a field
    /// that is not a UUID, or the empty string. The monitor treats `nil` as "not
    /// mine, do nothing but log", which is the only safe reading of a name whose
    /// meaning is unknown.
    ///
    /// **Case.** `UUID(uuidString:)` accepts either casing, matching
    /// ``ManagedSettingsStore/Name/ruleID(from:)`` in `Kernel/Identifiers.swift`,
    /// so a name the daemon normalized still parses. The *tag* is matched
    /// case-sensitively: it is a fixed keyword Gate writes itself, and accepting
    /// `GATE.RULE:` would mean accepting a name Gate could not have produced.
    public static func decode(_ raw: String) -> GateActivity? {
        guard let parsed = split(raw) else { return nil }
        let fields = parsed.fields

        switch parsed.kind {
        case .rule:
            guard let ruleID = uuid(fields[0]) else { return nil }
            return .rule(ruleID: ruleID)

        case .grant:
            guard let ruleID = uuid(fields[0]), let grantID = uuid(fields[1]) else { return nil }
            return .grant(ruleID: ruleID, grantID: grantID)

        case .revert:
            guard let scope = uuid(fields[0]), let changeID = uuid(fields[1]) else { return nil }
            return .revert(
                ruleID: scope == GateActivity.unscopedID ? nil : scope,
                changeID: changeID
            )
        }
    }

    /// Parses a raw `DeviceActivityEvent.Name` string. `nil` on anything else,
    /// including a well-formed *activity* name.
    public static func decode(eventName raw: String) -> GateEventKey? {
        guard let parsed = tagAndFields(raw),
              parsed.tag == eventTag,
              parsed.fields.count == 2,
              let ruleID = uuid(parsed.fields[0]),
              let seconds = nonNegativeInteger(parsed.fields[1])
        else { return nil }

        return GateEventKey(ruleID: ruleID, thresholdSeconds: seconds)
    }

    /// The kind of a raw name without parsing its payload.
    ///
    /// For the monitor's hot path: `intervalDidEnd` needs to know whether it was
    /// woken by a window, a grant or a revert before it decides whether the full
    /// parse is worth doing. Returns `nil` for an event name and for anything
    /// foreign.
    public static func kind(ofRawName raw: String) -> GateActivityKind? {
        guard let parsed = tagAndFields(raw) else { return nil }
        return GateActivityKind(rawValue: parsed.tag)
    }

    /// Whether `raw` is inside Gate's namespace at all.
    ///
    /// Mirrors `DeviceActivityName.isGateActivity` in `Kernel/Identifiers.swift`
    /// for callers holding a plain `String` (the debug screen,
    /// docs/04-product-spec.md V1-11, and the SwiftPM tests). A name can be
    /// Gate's and still fail ``decode(_:)`` — an event name, or a name written by
    /// a newer build — and that combination is precisely what the reconciler's
    /// orphan sweep must **not** treat as foreign.
    public static func isGateName(_ raw: String) -> Bool {
        raw.hasPrefix(GateID.namespace)
    }

    // MARK: Parsing primitives

    /// Splits a raw name into a validated kind plus a payload of exactly the right
    /// number of fields. All shape checks live here so the three `decode` arms
    /// cannot disagree about them — and so `fields[0]` / `fields[1]` below are
    /// provably in range.
    private static func split(_ raw: String) -> (kind: GateActivityKind, fields: [Substring])? {
        guard let parsed = tagAndFields(raw),
              let kind = GateActivityKind(rawValue: parsed.tag),
              parsed.fields.count == kind.fieldCount
        else { return nil }
        return (kind, parsed.fields)
    }

    /// Strips the namespace, splits off the tag, and splits the payload into
    /// fields. Rejects a missing prefix, a missing or repeated tag separator, and
    /// a payload containing a second tag separator.
    private static func tagAndFields(_ raw: String) -> (tag: String, fields: [Substring])? {
        guard raw.hasPrefix(GateID.namespace) else { return nil }
        let body = raw.dropFirst(GateID.namespace.count)

        // `omittingEmptySubsequences: false` is load-bearing on both splits: it is
        // what makes "gate.grant:|<uuid>" produce ["", "<uuid>"] and fail the UUID
        // check, instead of collapsing to a single field and being mistaken for
        // some other shape.
        let halves = body.split(
            separator: tagSeparator,
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard halves.count == 2 else { return nil }

        let tag = halves[0]
        let payload = halves[1]
        guard !tag.isEmpty, !payload.contains(tagSeparator) else { return nil }

        let fields = payload.split(separator: fieldSeparator, omittingEmptySubsequences: false)
        return (String(tag), fields)
    }

    private static func uuid(_ field: Substring) -> UUID? {
        UUID(uuidString: String(field))
    }

    /// Strict non-negative decimal parse.
    ///
    /// Re-rendering and comparing rejects `"+5"`, `"007"`, `" 5"` and `"5 "`,
    /// which `Int(_:)` would otherwise accept or ignore. Anything that does not
    /// re-render to itself is a name Gate did not write, and a name Gate did not
    /// write is not one it should act on.
    private static func nonNegativeInteger(_ field: Substring) -> Int? {
        guard let value = Int(field), value >= 0, String(value) == String(field) else { return nil }
        return value
    }
}

// MARK: - DeviceActivity island

// Everything below needs the SDK. It is fenced so the parsing logic above
// compiles in the platform-agnostic SwiftPM test package
// (docs/05-architecture.md, module layer split; docs/06-build-plan.md step 3.11),
// exactly as `Kernel/Model/LockPolicy.swift` fences CryptoKit.
//
// Note what is *not* here: no stored `static let` of a `DeviceActivityName`.
// `DeviceActivityName` has no audited `Sendable` conformance, and a stored static
// of such a type is a Swift 6 strict-concurrency error — the same reasoning that
// makes `ManagedSettingsStore.Name.solid` a computed property in
// `Kernel/Identifiers.swift`. These are all computed, and a `Name` is a `String`
// wrapper, so constructing one per access costs nothing.

#if os(iOS)

public extension GateActivity {

    /// The `DeviceActivityName` to hand `DeviceActivityCenter.startMonitoring`.
    var activityName: DeviceActivityName {
        DeviceActivityName(rawName)
    }

    /// Parses a name handed back by a monitor callback or by
    /// `DeviceActivityCenter.activities`. `nil` for anything not Gate's.
    init?(_ name: DeviceActivityName) {
        guard let decoded = ActivityNameCodec.decode(name.rawValue) else { return nil }
        self = decoded
    }
}

public extension DeviceActivityName {

    /// The decoded activity, or `nil` if this name is not one of Gate's three
    /// shapes.
    ///
    /// Pairs with `isGateActivity` in `Kernel/Identifiers.swift`: that one answers
    /// "may Gate stop this?", this one answers "what is it?". The reconciler needs
    /// both and they are not the same question — a name can be inside
    /// ``GateID/namespace`` (so Gate owns it, so Gate must clean it up) and still
    /// be unparseable here (written by a newer build).
    var gateActivity: GateActivity? {
        ActivityNameCodec.decode(rawValue)
    }
}

public extension GateEventKey {

    /// The `DeviceActivityEvent.Name` key for the `events:` dictionary passed to
    /// `startMonitoring`.
    var eventName: DeviceActivityEvent.Name {
        DeviceActivityEvent.Name(rawName)
    }

    /// Parses the name handed to `eventDidReachThreshold(_:activity:)`.
    init?(_ name: DeviceActivityEvent.Name) {
        guard let decoded = ActivityNameCodec.decode(eventName: name.rawValue) else { return nil }
        self = decoded
    }
}

public extension DeviceActivityEvent.Name {

    /// The decoded event key, or `nil` if this is not one of Gate's event names.
    var gateEventKey: GateEventKey? {
        ActivityNameCodec.decode(eventName: rawValue)
    }
}

#endif
