//
//  Grant.swift
//  GateKernel
//
//  V1-7's time-boxed, token-scoped unblock, plus the daily budget that rations it
//  and the intervention request that earns it (docs/04-product-spec.md V1-7).
//
//  The flow this file models, end to end:
//
//    1. The user taps "Let me in" on the shield.
//    2. `GateShieldAction` appends an ``InterventionRequest`` to `inbox/` and
//       responds `.openParentalControlsApp` (iOS 26.5+) or posts a notification
//       carrying `GateID.interventionURL(ruleID:requestID:)` and responds
//       `.close` (below 26.5). Extensions never write `state.plist`
//       (docs/05-architecture.md, single-writer discipline).
//    3. `App/Screens/InterventionScreen.swift` makes them wait, makes them type a
//       reason, and — if ``GrantLedger`` still has budget — issues a ``Grant``.
//    4. `Kernel/Enforcement/ShieldWriter.swift` applies the grant as **set
//       subtraction** on the shielded set plus `.specific(cats, except: granted)`.
//       Never `clearAllSettings()` (docs/02-api-reference.md §6).
//    5. A one-shot `gate.grant:<ruleUUID>|<grantUUID>` activity — and, because
//       the monitor is best-effort only (docs/03-hard-constraints.md #32), the
//       next foreground reconcile — expires it.
//
//  Build plan: docs/06-build-plan.md step 3.1.
//  Foundation only — see the header of Kernel/Model/Rule.swift.
//

import Foundation

// MARK: - ScopedTokens

/// The specific tokens a ``Grant`` lifts, as bytes.
///
/// Kept deliberately tiny. This is the **only** place opaque tokens appear inline
/// in `state.plist`, and that file has an 8 KB budget which the monitor decodes on
/// every callback (docs/05-architecture.md, persistence). A grant scoped to a
/// whole rule's selection must use ``GrantScope/entireRule`` and let
/// `ShieldWriter` read the blob from ``SelectionTable`` instead.
public struct ScopedTokens: Codable, Sendable, Equatable, Hashable {

    /// Hard cap on tokens named inline by one grant.
    ///
    /// Not an Apple limit — a byte-budget limit of ours. Real grants come from
    /// `ShieldActionDelegate`, which hands over exactly **one** token (Apple:
    /// *"The system doesn't provide the name of a shielded Application…"*,
    /// docs/02-api-reference.md §10), so the realistic value is 1. Eight leaves
    /// room for the app-side "unblock these three for a minute" path without
    /// letting a grant grow to the size of a selection.
    public static let maxScopedTokens = 8

    public var applications: [EncodedToken]
    public var categories: [EncodedToken]
    public var webDomains: [EncodedToken]

    public init(
        applications: [EncodedToken] = [],
        categories: [EncodedToken] = [],
        webDomains: [EncodedToken] = []
    ) {
        self.applications = Array(applications.prefix(ScopedTokens.maxScopedTokens))
        self.categories = Array(categories.prefix(ScopedTokens.maxScopedTokens))
        self.webDomains = Array(webDomains.prefix(ScopedTokens.maxScopedTokens))
    }

    /// The single-token case `ShieldActionDelegate` actually produces.
    public init(token: EncodedToken, kind: TokenKind) {
        switch kind {
        case .application: self.init(applications: [token])
        case .category: self.init(categories: [token])
        case .webDomain: self.init(webDomains: [token])
        }
    }

    public var isEmpty: Bool {
        applications.isEmpty && categories.isEmpty && webDomains.isEmpty
    }

    public var count: Int { applications.count + categories.count + webDomains.count }

    public func tokens(in collection: TokenCollection) -> [EncodedToken] {
        switch collection {
        case .applications: applications
        case .categories: categories
        case .webDomains: webDomains
        }
    }

    /// Whether a token is in scope, matched on ``EncodedToken/fingerprint``.
    ///
    /// Fingerprint rather than byte equality because tokens go stale and can fail
    /// `==` against a stored copy (docs/03-hard-constraints.md #36, thread
    /// 814571). The fingerprint is of the same bytes, so this is not a *fix* for
    /// staleness — nothing client-side is — but it keeps the comparison in one
    /// place, so the recovery flow (docs/04-product-spec.md V1-9) has exactly one
    /// thing to re-key when it reselects.
    public func contains(_ token: EncodedToken, kind: TokenKind) -> Bool {
        tokens(in: kind.collection).contains { $0.fingerprint == token.fingerprint }
    }

    private enum CodingKeys: String, CodingKey {
        case applications = "apps"
        case categories = "cats"
        case webDomains = "webs"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            applications: container.gateLossyArray(EncodedToken.self, forKey: .applications),
            categories: container.gateLossyArray(EncodedToken.self, forKey: .categories),
            webDomains: container.gateLossyArray(EncodedToken.self, forKey: .webDomains)
        )
    }
}

// MARK: - GrantScope

/// What a ``Grant`` lifts.
public enum GrantScope: Sendable, Equatable, Hashable {

    /// Everything the rule shields. Used by the app-side "pause this rule for
    /// five minutes" affordance.
    case entireRule

    /// Only these tokens. The normal case: the user tapped one app's shield, so
    /// only that app opens.
    case tokens(ScopedTokens)

    /// Written by a newer build. `ShieldWriter` must treat an unrecognized scope
    /// as lifting **nothing** — a grant we cannot interpret has to fail closed.
    case unrecognized(type: String)

    public var scopedTokens: ScopedTokens? {
        if case .tokens(let set) = self { return set }
        return nil
    }

    /// False for ``unrecognized(type:)``. `ShieldWriter` skips such grants.
    public var isRecognized: Bool {
        if case .unrecognized = self { return false }
        return true
    }
}

extension GrantScope: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "t"
        case tokens = "tok"
    }

    private enum Tag {
        static let entireRule = "entireRule"
        static let tokens = "tokens"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = container.gateValue(String.self, forKey: .type, default: "")
        switch type {
        case Tag.entireRule:
            self = .entireRule
        case Tag.tokens:
            self = .tokens(container.gateValue(ScopedTokens.self, forKey: .tokens, default: ScopedTokens()))
        default:
            self = .unrecognized(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .entireRule:
            try container.encode(Tag.entireRule, forKey: .type)
        case .tokens(let set):
            try container.encode(Tag.tokens, forKey: .type)
            try container.encode(set, forKey: .tokens)
        case .unrecognized(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

// MARK: - GrantSource

/// Where a grant came from. Purely for the honest "Gate's own data" counters
/// (docs/04-product-spec.md V2-5) and the debug screen — it never changes
/// enforcement.
public enum GrantSource: String, Codable, Sendable, Hashable, CaseIterable {
    /// Earned through the full intervention: wait, then typed reason
    /// (docs/04-product-spec.md V1-7).
    case intervention
    /// Taken from the shield's secondary submenu — "1 more minute", "15 more
    /// minutes", "1 hour". iOS 26.4+ only (docs/04-product-spec.md V2-1).
    case shieldSubmenu
    /// Issued from inside the app without an intervention, e.g. the "this was
    /// wrong, unshield now" false-positive escape hatch (docs/04-product-spec.md
    /// V2-4).
    case manual
    /// Debug builds only (docs/04-product-spec.md V1-11).
    case debug
}

// MARK: - Grant

/// A time-boxed, token-scoped subtraction from a rule's shield set.
public struct Grant: Codable, Sendable, Equatable, Hashable, Identifiable {

    /// Longest stored intervention reason. V1-7 persists "what do you actually
    /// want to do in there?" to a local journal; this is the copy that rides
    /// along in `state.plist`, so it is capped hard.
    public static let maxReasonLength = 200

    /// Grants resolved longer ago than this are reclaimed by
    /// ``GateState/pruned(now:)``.
    public static let terminalRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Also the second UUID in the `gate.grant:<ruleUUID>|<grantUUID>`
    /// `DeviceActivityName` that arms the one-shot expiry activity
    /// (docs/05-architecture.md, "The DeviceActivityName codec").
    public var id: UUID

    public var ruleID: UUID

    public var scope: GrantScope

    public var issuedAt: Date

    /// Absolute expiry. Absolute, never a duration — every deadline in this
    /// product is a timestamp so that ground truth can be recomputed on every
    /// foreground regardless of what the monitor did or did not do
    /// (docs/04-product-spec.md V1-10).
    public var expiresAt: Date

    public var source: GrantSource

    /// The ``InterventionRequest`` that produced this grant, when there was one.
    public var requestID: UUID?

    /// The user's typed reason. Truncated to ``maxReasonLength``.
    public var reason: String?

    /// Set when the user ends a grant early, which is a **tightening** and is
    /// therefore free (docs/04-product-spec.md V1-4).
    public var revokedAt: Date?

    public init(
        id: UUID = UUID(),
        ruleID: UUID,
        scope: GrantScope,
        issuedAt: Date,
        expiresAt: Date,
        source: GrantSource,
        requestID: UUID? = nil,
        reason: String? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.scope = scope
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.source = source
        self.requestID = requestID
        self.reason = reason.map { String($0.prefix(Grant.maxReasonLength)) }
        self.revokedAt = revokedAt
    }

    /// Whether `ShieldWriter` should be subtracting this grant right now.
    ///
    /// An unrecognized scope fails closed: a grant whose meaning this build does
    /// not know is not live, because the alternative is lifting a shield for
    /// reasons we cannot state.
    public func isActive(at now: Date) -> Bool {
        guard scope.isRecognized, revokedAt == nil else { return false }
        return now < expiresAt
    }

    public func remaining(at now: Date) -> TimeInterval {
        max(0, expiresAt.timeIntervalSince(now))
    }

    public var duration: TimeInterval { max(0, expiresAt.timeIntervalSince(issuedAt)) }

    /// Ends the grant now. Idempotent.
    public func revoked(at now: Date) -> Grant {
        guard revokedAt == nil else { return self }
        var copy = self
        copy.revokedAt = now
        return copy
    }

    /// Whether this grant may be reclaimed by ``GateState/pruned(now:)``.
    public func isExpired(at now: Date, retention: TimeInterval = Grant.terminalRetention) -> Bool {
        let ended = revokedAt ?? expiresAt
        return now.timeIntervalSince(ended) > retention
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ruleID = "rule"
        case scope = "sc"
        case issuedAt = "iss"
        case expiresAt = "exp"
        case source = "src"
        case requestID = "req"
        case reason
        case revokedAt = "rev"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required: a grant that names neither itself nor its rule cannot be
        // expired, cannot be matched to its one-shot activity, and cannot be
        // applied. Let it throw so the lossy array decoder drops just this one.
        let id = try container.decode(UUID.self, forKey: .id)
        let ruleID = try container.decode(UUID.self, forKey: .ruleID)

        self.init(
            id: id,
            ruleID: ruleID,
            scope: container.gateValue(GrantScope.self, forKey: .scope, default: .unrecognized(type: "")),
            issuedAt: container.gateValue(Date.self, forKey: .issuedAt, default: .distantPast),
            // A grant with no expiry decodes as already expired, never as
            // permanent. `.distantFuture` here would be an unbounded unblock
            // created by one corrupt field.
            expiresAt: container.gateValue(Date.self, forKey: .expiresAt, default: .distantPast),
            source: container.gateRaw(GrantSource.self, forKey: .source, default: .manual),
            requestID: container.gateOptional(UUID.self, forKey: .requestID),
            reason: container.gateOptional(String.self, forKey: .reason),
            revokedAt: container.gateOptional(Date.self, forKey: .revokedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ruleID, forKey: .ruleID)
        try container.encode(scope, forKey: .scope)
        try container.encode(issuedAt, forKey: .issuedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(source.rawValue, forKey: .source)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(revokedAt, forKey: .revokedAt)
    }
}

// MARK: - GrantPolicy

/// The user's grant configuration: how many, how long, and how hard to earn
/// (docs/04-product-spec.md V1-7).
public struct GrantPolicy: Codable, Sendable, Equatable, Hashable {

    /// Grants per day. Default ``GateLimits/defaultDailyGrantBudget`` (3).
    /// Lowering it is a tightening; raising it is a loosening.
    public var dailyLimit: Int

    /// How long a grant lasts. Default ``GateLimits/defaultGrantDuration`` (5 min).
    public var defaultDuration: TimeInterval

    /// The short forced wait on the intervention screen. Default
    /// ``GateLimits/defaultImpulseDelay`` (30 s).
    public var impulseDelay: TimeInterval

    /// When true the intervention makes the user wait the full ``LockPolicy/delay``
    /// instead of ``impulseDelay``. V1-7 offers both; this is the switch.
    public var usesLockDelay: Bool

    public init(
        dailyLimit: Int = GateLimits.defaultDailyGrantBudget,
        defaultDuration: TimeInterval = GateLimits.defaultGrantDuration,
        impulseDelay: TimeInterval = GateLimits.defaultImpulseDelay,
        usesLockDelay: Bool = false
    ) {
        self.dailyLimit = max(0, dailyLimit)
        self.defaultDuration = GrantPolicy.clampDuration(defaultDuration)
        self.impulseDelay = max(0, impulseDelay.isFinite ? impulseDelay : GateLimits.defaultImpulseDelay)
        self.usesLockDelay = usesLockDelay
    }

    public static let `default` = GrantPolicy()

    /// A grant shorter than a second is not a grant, and one longer than the
    /// maximum lock delay would outlive any deadline that could cancel it.
    public static func clampDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return GateLimits.defaultGrantDuration }
        return min(max(value, 1), GateLimits.maxLockDelay)
    }

    /// How long the intervention screen must make the user wait.
    public func interventionWait(under lock: LockPolicy) -> TimeInterval {
        usesLockDelay ? lock.delay : impulseDelay
    }

    /// The expiry timestamp for a grant issued now.
    public func expiry(from now: Date, duration: TimeInterval? = nil) -> Date {
        now.addingTimeInterval(GrantPolicy.clampDuration(duration ?? defaultDuration))
    }

    private enum CodingKeys: String, CodingKey {
        case dailyLimit = "limit"
        case defaultDuration = "dur"
        case impulseDelay = "impulse"
        case usesLockDelay = "useLock"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dailyLimit: container.gateValue(
                Int.self, forKey: .dailyLimit, default: GateLimits.defaultDailyGrantBudget
            ),
            defaultDuration: container.gateValue(
                TimeInterval.self, forKey: .defaultDuration, default: GateLimits.defaultGrantDuration
            ),
            impulseDelay: container.gateValue(
                TimeInterval.self, forKey: .impulseDelay, default: GateLimits.defaultImpulseDelay
            ),
            usesLockDelay: container.gateValue(Bool.self, forKey: .usesLockDelay, default: false)
        )
    }
}

// MARK: - GrantLedger

/// Today's grant count.
///
/// Rolls at local midnight (docs/04-product-spec.md V1-7). Running out is a
/// **tightening**, so it takes effect immediately and needs no Lock.
///
/// **Cross-process caveat.** `GateShieldAction` decrements the budget, but
/// extensions never write `state.plist` (docs/05-architecture.md, single-writer
/// discipline) — the extension appends an ``InterventionRequest`` to `inbox/` and
/// the app compacts it in on the next foreground reconcile. So between a shield
/// tap and the next app launch this ledger is *stale by design*. The extension
/// must compute its effective remaining count as
/// `ledger.rolled(to: now, in: cal).remaining(under: policy)` minus the number of
/// unconsumed grant records already sitting in `inbox/`; ``consuming(_:)`` exists
/// for exactly that arithmetic. Getting this wrong means the budget can be
/// spent twice in one day.
public struct GrantLedger: Codable, Sendable, Equatable, Hashable {

    /// Grants issued since ``periodStart``.
    public var used: Int

    /// Start of the current day, in the user's calendar.
    public var periodStart: Date

    public init(used: Int = 0, periodStart: Date = .distantPast) {
        self.used = max(0, used)
        self.periodStart = periodStart
    }

    /// This ledger, rolled forward to `now`'s day.
    ///
    /// Pure and calendar-injected so `Tests/GateKernelTests/GrantEngineTests.swift`
    /// can cross midnight, cross a DST boundary and change time zone without
    /// touching the process locale.
    public func rolled(to now: Date, in calendar: Calendar = .current) -> GrantLedger {
        let today = calendar.startOfDay(for: now)

        // Strictly-later comparison, not `!=`. A `periodStart` in the *future* is
        // what a backwards clock change produces, and the honest answer to "the
        // clock moved back" is to keep today's count and re-anchor to today —
        // not to hand out a second fresh day of grants. The count is pulled
        // forward rather than reset.
        //
        // The reverse (setting the clock forward to buy a reset) is not
        // defensible client-side and this does not pretend otherwise: under
        // `.individual` authorization the user can revoke everything in about
        // four taps anyway (docs/03-hard-constraints.md #13, #14). The budget is
        // friction, not a security boundary, and the product copy says so.
        guard today > periodStart else {
            return GrantLedger(used: used, periodStart: today)
        }
        return GrantLedger(used: 0, periodStart: today)
    }

    public func remaining(under policy: GrantPolicy) -> Int {
        max(0, policy.dailyLimit - used)
    }

    public func hasBudget(under policy: GrantPolicy) -> Bool {
        remaining(under: policy) > 0
    }

    /// This ledger with `count` more grants spent. Does not roll — call
    /// ``rolled(to:in:)`` first.
    public func consuming(_ count: Int = 1) -> GrantLedger {
        GrantLedger(used: used + max(0, count), periodStart: periodStart)
    }

    private enum CodingKeys: String, CodingKey {
        case used = "n"
        case periodStart = "day"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            used: container.gateValue(Int.self, forKey: .used, default: 0),
            // `.distantPast` means "no day recorded", which `rolled(to:)` turns
            // into a fresh day. Defaulting to `now` is not an option: the model
            // layer has no clock.
            periodStart: container.gateValue(Date.self, forKey: .periodStart, default: .distantPast)
        )
    }
}

// MARK: - ShieldActionKind

/// Which shield control the user pressed.
///
/// Mirrors `ManagedSettings.ShieldAction` without importing it, so this file stays
/// Foundation-only (docs/02-api-reference.md §10). The three submenu cases exist
/// only on iOS 26.4+ and every mapping site in
/// `Extensions/ShieldAction/GateShieldAction.swift` is `if #available`-gated; the
/// *model* carries them unconditionally so that a record written on 26.4 is still
/// readable by the same binary running on iOS 17.
public enum ShieldActionKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// "Let me in" (docs/04-product-spec.md V1-6).
    case primaryButton
    /// "Not now".
    case secondaryButton
    /// iOS 26.4+ submenu, item 1 (docs/04-product-spec.md V2-1).
    case firstSubmenuItem
    /// iOS 26.4+ submenu, item 2.
    case secondSubmenuItem
    /// iOS 26.4+ submenu, item 3.
    case thirdSubmenuItem

    /// True for the three cases that do not exist below iOS 26.4.
    public var requiresSubmenuSupport: Bool {
        switch self {
        case .primaryButton, .secondaryButton: false
        case .firstSubmenuItem, .secondSubmenuItem, .thirdSubmenuItem: true
        }
    }
}

// MARK: - InterventionRequest

/// One shield tap, as recorded by `GateShieldAction` in `inbox/`.
///
/// This is both halves of V1-7's accounting: a request that ends in
/// ``Resolution/granted(grantID:)`` is a completed intervention, and a request
/// that ends any other way **is** the bypass attempt the stats screen counts
/// (docs/04-product-spec.md V2-5). There is no second record type for that.
///
/// ``id`` is the `requestID` in `GateID.interventionURL(ruleID:requestID:)`.
public struct InterventionRequest: Codable, Sendable, Equatable, Hashable, Identifiable {

    /// How long a request stays actionable.
    ///
    /// A deep-link notification tapped an hour later must not resurrect an
    /// intervention for an impulse the user has long since walked away from — and
    /// the URL is a pointer, not a capability, so honouring a stale one would be
    /// a real hole (see the ``GateID/interventionURL(ruleID:requestID:)`` note in
    /// Kernel/Identifiers.swift). A stale request is shown as history, never
    /// converted into a grant.
    public static let maxAge: TimeInterval = 15 * 60

    public var id: UUID

    /// The rule whose shield was tapped, if it could be resolved.
    ///
    /// `nil` is a real and expected state, not a bug. `ShieldActionDelegate`
    /// receives a bare token with no name and no rule (docs/02-api-reference.md
    /// §10); the extension resolves it through
    /// ``ShieldCopyTable/ruleID(forToken:)``, and that lookup misses whenever the
    /// token has been reissued (docs/03-hard-constraints.md #36). When it misses,
    /// the extension still writes the request and still hands off — it just
    /// cannot name the rule, so it passes ``id`` in the URL's `rule` position and
    /// the app, finding no rule with that id, resolves the record by `requestID`
    /// and shows the generic intervention. The URL is advisory; this record is
    /// the truth.
    public var ruleID: UUID?

    /// The token that was shielded, as handed to the extension.
    public var token: EncodedToken?

    public var tokenKind: TokenKind

    public var action: ShieldActionKind

    public var createdAt: Date

    /// The user's typed reason, captured on the intervention screen and copied
    /// onto the resulting ``Grant``.
    public var reason: String?

    /// `nil` while the request is still open.
    public var resolution: Resolution?

    public init(
        id: UUID = UUID(),
        ruleID: UUID?,
        token: EncodedToken?,
        tokenKind: TokenKind,
        action: ShieldActionKind,
        createdAt: Date,
        reason: String? = nil,
        resolution: Resolution? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.token = token
        self.tokenKind = tokenKind
        self.action = action
        self.createdAt = createdAt
        self.reason = reason.map { String($0.prefix(Grant.maxReasonLength)) }
        self.resolution = resolution
    }

    /// How a request ended.
    public enum Resolution: Sendable, Equatable, Hashable {
        /// The user completed the intervention and a ``Grant`` was issued.
        case granted(grantID: UUID)
        /// The user backed out. This is the outcome the product is trying to
        /// produce, and it is counted as a win, not an error.
        case dismissed
        /// Nobody came back for it within ``InterventionRequest/maxAge``.
        case expired
        /// Gate refused.
        case denied(reason: DenialReason)
        /// Written by a newer build.
        case unrecognized(type: String)

        public var grantID: UUID? {
            if case .granted(let id) = self { return id }
            return nil
        }
    }

    /// Why Gate refused to issue a grant.
    public enum DenialReason: String, Codable, Sendable, Hashable, CaseIterable {
        /// ``GrantLedger`` is out for the day. A tightening — no Lock involved.
        case budgetExhausted
        /// The token could not be matched to a rule, so there is nothing to
        /// subtract from. Routes the user to recovery
        /// (docs/04-product-spec.md V1-9).
        case ruleUnresolved
        /// Family Controls authorization is no longer `.approved`
        /// (docs/03-hard-constraints.md #14).
        case notAuthorized
        /// The request aged out before the user returned.
        case stale
    }

    /// Whether this request may still be converted into a grant.
    public func isActionable(at now: Date, maxAge: TimeInterval = InterventionRequest.maxAge) -> Bool {
        resolution == nil && now.timeIntervalSince(createdAt) <= maxAge
    }

    /// True for a request that produced no grant — i.e. a bypass attempt the user
    /// did not complete.
    public var isBypassAttempt: Bool {
        guard let resolution else { return false }
        return resolution.grantID == nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ruleID = "rule"
        case token = "tok"
        case tokenKind = "kind"
        case action = "act"
        case createdAt = "c"
        case reason
        case resolution = "res"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        self.init(
            id: id,
            ruleID: container.gateOptional(UUID.self, forKey: .ruleID),
            token: container.gateOptional(EncodedToken.self, forKey: .token),
            tokenKind: container.gateRaw(TokenKind.self, forKey: .tokenKind, default: .application),
            action: container.gateRaw(ShieldActionKind.self, forKey: .action, default: .primaryButton),
            createdAt: container.gateValue(Date.self, forKey: .createdAt, default: .distantPast),
            reason: container.gateOptional(String.self, forKey: .reason),
            resolution: container.gateOptional(Resolution.self, forKey: .resolution)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(ruleID, forKey: .ruleID)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encode(tokenKind.rawValue, forKey: .tokenKind)
        try container.encode(action.rawValue, forKey: .action)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(resolution, forKey: .resolution)
    }
}

extension InterventionRequest.Resolution: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "t"
        case grantID = "g"
        case reason = "r"
    }

    private enum Tag {
        static let granted = "granted"
        static let dismissed = "dismissed"
        static let expired = "expired"
        static let denied = "denied"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = container.gateValue(String.self, forKey: .type, default: "")
        switch type {
        case Tag.granted:
            guard let grantID = container.gateOptional(UUID.self, forKey: .grantID) else {
                // "Granted, but we lost which grant" is unusable. Downgrade to
                // dismissed rather than leave a dangling reference: the worst
                // outcome is that the user has to ask again, never that a shield
                // stays down with nothing to expire it.
                self = .dismissed
                return
            }
            self = .granted(grantID: grantID)
        case Tag.dismissed:
            self = .dismissed
        case Tag.expired:
            self = .expired
        case Tag.denied:
            self = .denied(
                reason: container.gateRaw(
                    InterventionRequest.DenialReason.self, forKey: .reason, default: .stale
                )
            )
        default:
            self = .unrecognized(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .granted(let grantID):
            try container.encode(Tag.granted, forKey: .type)
            try container.encode(grantID, forKey: .grantID)
        case .dismissed:
            try container.encode(Tag.dismissed, forKey: .type)
        case .expired:
            try container.encode(Tag.expired, forKey: .type)
        case .denied(let reason):
            try container.encode(Tag.denied, forKey: .type)
            try container.encode(reason.rawValue, forKey: .reason)
        case .unrecognized(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

// MARK: - Collection helpers

public extension Collection where Element == Grant {

    /// Grants `ShieldWriter` must subtract right now.
    func active(at now: Date) -> [Grant] {
        filter { $0.isActive(at: now) }
    }

    /// Active grants for one rule.
    func active(at now: Date, ruleID: UUID) -> [Grant] {
        filter { $0.ruleID == ruleID && $0.isActive(at: now) }
    }

    /// The soonest expiry among active grants — the moment `Reconciler` next has
    /// to rewrite a shield set, and the timestamp a `UNCalendarNotificationTrigger`
    /// backstop is armed for (docs/04-product-spec.md V1-10 step 5).
    func nextExpiry(after now: Date) -> Date? {
        active(at: now).map(\.expiresAt).min()
    }
}
