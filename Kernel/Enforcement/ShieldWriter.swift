//
//  ShieldWriter.swift
//  GateKernel
//
//  The only file in the product that writes a `ManagedSettingsStore`.
//
//  Build plan: docs/06-build-plan.md step 3.9. Write pattern and the exact
//  property names: docs/02-api-reference.md §6.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE THREE THINGS THIS FILE HAS TO GET RIGHT
//
//  1. **Mode.** A blocklist rule shields what the user picked:
//     `shield.applications = tokens` plus `.specific(categories, except:)`.
//     An allowlist rule shields the complement: `.all(except: allowed)`. The two
//     are not variations on a theme — they are inverses, and every downstream
//     operation (a grant, a cap check, a diff) inverts with them. Getting this
//     backwards does not under-block; it blocks the entire device.
//
//  2. **Grants are set algebra, never `clearAllSettings()`.**
//     docs/02-api-reference.md §6: *"Temporary unblock = set subtraction on the
//     shielded set plus `.specific(categories, except: grantedAppTokens)` —
//     never `clearAllSettings()`."* `clearAllSettings()` is reached for because
//     it is the obvious way to "let them in for five minutes", and it drops
//     every setting in the store it is called on. Nothing in this file calls it,
//     in any path. ``ShieldWriter/clear(rule:)`` nils exactly the four shield
//     properties Gate writes, on exactly one named store.
//
//     And in allowlist mode "subtraction" runs the other way: the shielded set
//     is the *complement* of the allowed set, so lifting a token means adding it
//     to `except:`. Same grant, opposite operator. See ``ShieldWriter/apply(_:tokens:)``.
//
//  3. **Refusing beats writing something wrong.** Past 50 tokens a collection
//     shields *nothing*, silently (docs/03-hard-constraints.md #34). A store
//     that is left holding yesterday's correct 50 is strictly better than one
//     rewritten into a no-op, so an over-cap plan is refused and the store is
//     not touched. `Kernel/Enforcement/TokenGuard.swift` decides; this file
//     obeys and reports.
//  ─────────────────────────────────────────────────────────────────────────────
//
//  RULES FOR THIS FILE
//  1. The planning half is **pure** — no SDK, no I/O, no `Date()` — so the mode
//     inversion and the grant algebra are unit-testable on Linux
//     (docs/06-build-plan.md step 3.11) where `ManagedSettings` does not exist.
//     The writing half lives in the island at the bottom.
//  2. **Never trap.** This runs inside the monitor, cold, under a 6 MB ceiling
//     (docs/03-hard-constraints.md #31), against a `state.plist` another process
//     may have been killed while writing. Every failure is a value.
//  3. `os.Logger`, never `print()` — `print()` is invisible from an extension
//     (docs/06-build-plan.md step 4.1). The logger lives in the island because
//     `os` does not exist on Linux either.
//  4. Nothing that holds a `Token<_>`, a `ManagedSettingsStore` or a `Logger` is
//     declared `Sendable`: none of them has an audited conformance, and Swift 6
//     strict concurrency is on. Tokens cross this file as parameters, inside one
//     synchronous call.
//

import Foundation

// MARK: - ShieldLiftReason

/// Why a rule is contributing nothing to the shield set right now.
///
/// Every case means the same thing to the daemon — the rule's store is emptied —
/// but they are told apart so the debug screen (docs/04-product-spec.md V1-11)
/// and the logs can say *why* an app is open, which is the single most common
/// support question this product will get.
public enum ShieldLiftReason: String, Sendable, Hashable, CaseIterable {

    /// The user turned the rule off. Turning it off was a loosening and has
    /// already been through the Lock (docs/04-product-spec.md V1-4).
    case ruleDisabled

    /// The rule has a schedule and this is outside its window
    /// (docs/04-product-spec.md V1-5). The normal daily case.
    case outsideSchedule

    /// The rule has never had a selection. Skipped rather than written as an
    /// empty store (docs/06-build-plan.md step 3.2 note on `Rule.selection`).
    case noSelection

    /// The rule's selection resolved to nothing at all, and its digest agrees
    /// that it is empty. In ``RuleMode/blocklist`` that shields nothing; in
    /// ``RuleMode/allowlist`` it would shield *everything*, and Gate declines to
    /// infer a device-wide block from an empty set — see
    /// ``ShieldRefusal/selectionUnresolved(expected:resolved:)`` for the case
    /// where the emptiness is a disagreement rather than a choice.
    case emptySelection

    /// A live ``Grant`` with ``GrantScope/entireRule`` scope covers the whole
    /// rule — the app-side "pause this rule for five minutes" affordance
    /// (docs/04-product-spec.md V1-7). Expires by absolute timestamp.
    case entireRuleGrant
}

// MARK: - ShieldRefusal

/// Why a write was not performed, leaving the store exactly as it was.
///
/// Refusal is never silent: it is the loudest thing this file produces, because
/// the alternative — writing a store that shields nothing — is the failure the
/// whole product is built to avoid.
public enum ShieldRefusal: Sendable, Equatable, Hashable, CustomStringConvertible {

    /// A platform cap would have been exceeded. See ``TokenGuardError``.
    case cap(TokenGuardError)

    /// The rule's ``SelectionDigest`` claims tokens that the resolved selection
    /// does not contain.
    ///
    /// That disagreement means one of `state.plist` and `selections.plist` is
    /// stale or torn, and the two readings differ by an amount that matters:
    /// writing the resolved (empty) set would unshield a blocklist rule, and — in
    /// ``RuleMode/allowlist`` — writing `.all(except: [])` would shield every app
    /// on the device on the strength of a decode that already disagrees with
    /// itself. Neither is a guess worth making, so nothing is written and the
    /// recovery flow (docs/04-product-spec.md V1-9) is the way out.
    case selectionUnresolved(expected: Int, resolved: Int)

    /// The token set could not be resolved at all — the selection blob is
    /// missing, unreadable or belongs to a rule that no longer exists.
    case selectionMissing

    public var description: String {
        switch self {
        case .cap(let error):
            error.description
        case .selectionUnresolved(let expected, let resolved):
            "selection digest claims \(expected) tokens, blob resolved \(resolved)"
        case .selectionMissing:
            "selection blob unavailable"
        }
    }
}

// MARK: - ShieldPlanIssue

/// Something worth reporting about a plan that does not, by itself, stop the
/// write.
///
/// Not `Codable`, for the same reason ``RuleIssue`` is not: these are recomputed
/// from state on every reconcile and a persisted one would outlive its cause.
public enum ShieldPlanIssue: Sendable, Equatable, Hashable, CustomStringConvertible {

    /// A cap was hit. Blocking when ``TokenGuardError/isBlocking`` is true.
    case cap(TokenGuardError)

    /// An allowlist rule selected category tokens, and they cannot be honored.
    ///
    /// `ShieldSettings.ActivityCategoryPolicy.all(except:)` takes
    /// `Set<Token<Activity>>` — app tokens for `applicationCategories`, web-domain
    /// tokens for `webDomainCategories` (docs/02-api-reference.md §6). There is
    /// no shape of that enum that says "everything except this whole category",
    /// so an allowed category is not expressible and is dropped. The rule still
    /// enforces; the editor must say so before the user relies on it.
    case allowlistIgnoresCategories(count: Int)

    /// A live grant names tokens that cannot be lifted in this rule's mode.
    ///
    /// The allowlist case again: lifting an app means adding it to `except:`,
    /// which works for apps and web domains but has no expression for a category
    /// token. The grant still lifts everything else it names.
    case liftNotRepresentable(collection: TokenCollection, count: Int)

    /// A lifted token could not be matched to any live token and could not be
    /// decoded from its stored bytes, so the grant does not lift it.
    ///
    /// The expected cause is token staleness (docs/03-hard-constraints.md #36):
    /// tokens are reissued across OS updates and re-authorization. Fails closed —
    /// the app stays shielded — and the user's route out is the recovery flow.
    case unresolvedLift(collection: TokenCollection, count: Int)

    /// A grant written by a newer build, whose scope this build cannot read.
    ///
    /// Fails closed by construction: ``Grant/isActive(at:)`` already returns
    /// `false` for an unrecognized scope, so the grant lifts nothing. Reported so
    /// the debug screen can explain why a grant the user just earned did nothing.
    case unrecognizedGrantScope(grantID: UUID)

    /// A blocking ``RuleIssue`` carried through to the enforcement layer.
    case rule(RuleIssue)

    /// Whether this issue is the reason a write was refused.
    public var isBlocking: Bool {
        switch self {
        case .cap(let error): error.isBlocking
        case .rule(let issue): issue.isBlocking
        case .allowlistIgnoresCategories, .liftNotRepresentable,
             .unresolvedLift, .unrecognizedGrantScope: false
        }
    }

    public var description: String {
        switch self {
        case .cap(let error):
            error.description
        case .allowlistIgnoresCategories(let count):
            "allowlist rule ignores \(count) selected category token(s): not expressible as .all(except:)"
        case .liftNotRepresentable(let collection, let count):
            "grant cannot lift \(count) \(collection.rawValue) token(s) in this mode"
        case .unresolvedLift(let collection, let count):
            "\(count) lifted \(collection.rawValue) token(s) matched nothing live and would not decode"
        case .unrecognizedGrantScope(let grantID):
            "grant \(grantID.uuidString) has a scope this build cannot read; it lifts nothing"
        case .rule(let issue):
            "rule issue: \(String(describing: issue))"
        }
    }
}

// MARK: - ShieldLift

/// Everything live ``Grant``s take out of one rule's shield set at one instant.
///
/// Tokens as bytes, not as `Token<_>`: this type is `Sendable`, is built in the
/// pure layer, and is handed to the island where the bytes are matched against
/// live tokens by ``EncodedToken/fingerprint``. It is small by construction — a
/// grant names at most ``ScopedTokens/maxScopedTokens`` tokens and realistically
/// names exactly one, because `ShieldActionDelegate` is handed exactly one
/// (docs/02-api-reference.md §10).
public struct ShieldLift: Sendable, Equatable, Hashable {

    /// A grant with ``GrantScope/entireRule`` scope is live, so the rule shields
    /// nothing at all right now.
    public var liftsEverything: Bool

    /// Lifted application tokens, deduplicated and ordered by fingerprint.
    public var applications: [EncodedToken]

    /// Lifted category tokens. Only expressible in ``RuleMode/blocklist`` — see
    /// ``ShieldPlanIssue/liftNotRepresentable(collection:count:)``.
    public var categories: [EncodedToken]

    /// Lifted web-domain tokens.
    public var webDomains: [EncodedToken]

    /// The grants this lift came from, ordered by expiry then id.
    public var grantIDs: [UUID]

    /// The soonest moment one of those grants ends — the next time this rule's
    /// store has to be rewritten (docs/04-product-spec.md V1-10 step 5).
    public var nextExpiry: Date?

    public init(
        liftsEverything: Bool = false,
        applications: [EncodedToken] = [],
        categories: [EncodedToken] = [],
        webDomains: [EncodedToken] = [],
        grantIDs: [UUID] = [],
        nextExpiry: Date? = nil
    ) {
        self.liftsEverything = liftsEverything
        self.applications = applications
        self.categories = categories
        self.webDomains = webDomains
        self.grantIDs = grantIDs
        self.nextExpiry = nextExpiry
    }

    /// Nothing lifted.
    public static var none: ShieldLift { ShieldLift() }

    public var isEmpty: Bool {
        !liftsEverything && applications.isEmpty && categories.isEmpty && webDomains.isEmpty
    }

    public var count: Int { applications.count + categories.count + webDomains.count }

    public func tokens(in collection: TokenCollection) -> [EncodedToken] {
        switch collection {
        case .applications: applications
        case .categories: categories
        case .webDomains: webDomains
        }
    }

    /// The lift a set of grants produces for one rule at one instant.
    ///
    /// Only ``Grant/isActive(at:)`` grants count, which already excludes revoked
    /// grants, expired ones and — deliberately — grants whose scope this build
    /// cannot read. Expiry is by absolute timestamp, so this is correct whether or
    /// not the monitor ever fired the one-shot that was supposed to end the grant
    /// (docs/03-hard-constraints.md #32).
    ///
    /// Ordering is by fingerprint and then by expiry, never by `Set` iteration or
    /// `hashValue`: the same state must produce the same plan in the app and in
    /// the monitor (see ``GateFingerprint``).
    public static func make(from grants: some Collection<Grant>, ruleID: UUID, now: Date) -> ShieldLift {
        let live = grants
            .filter { $0.ruleID == ruleID && $0.isActive(at: now) }
            .sorted {
                $0.expiresAt == $1.expiresAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.expiresAt < $1.expiresAt
            }
        guard !live.isEmpty else { return .none }

        var liftsEverything = false
        var applications: [EncodedToken] = []
        var categories: [EncodedToken] = []
        var webDomains: [EncodedToken] = []

        for grant in live {
            switch grant.scope {
            case .entireRule:
                liftsEverything = true
            case .tokens(let scoped):
                applications.append(contentsOf: scoped.applications)
                categories.append(contentsOf: scoped.categories)
                webDomains.append(contentsOf: scoped.webDomains)
            case .unrecognized:
                // Unreachable: `isActive(at:)` already filtered these out. The
                // arm exists so that adding a scope case fails to compile here
                // rather than silently lifting nothing in production.
                continue
            }
        }

        return ShieldLift(
            liftsEverything: liftsEverything,
            applications: ShieldLift.normalized(applications),
            categories: ShieldLift.normalized(categories),
            webDomains: ShieldLift.normalized(webDomains),
            grantIDs: live.map(\.id),
            nextExpiry: live.map(\.expiresAt).min()
        )
    }

    /// Deduplicated by fingerprint, ordered by fingerprint.
    ///
    /// Fingerprint rather than byte equality for the same reason
    /// ``ScopedTokens/contains(_:kind:)`` uses it: it is the one comparison that
    /// stays in one place when the recovery flow has to re-key everything.
    private static func normalized(_ tokens: [EncodedToken]) -> [EncodedToken] {
        var seen: Set<String> = []
        var unique: [EncodedToken] = []
        for token in tokens where !token.isEmpty {
            let fingerprint = token.fingerprint
            if seen.insert(fingerprint).inserted { unique.append(token) }
        }
        return unique.sorted { $0.fingerprint < $1.fingerprint }
    }
}

// MARK: - ShieldDisposition

/// What is to be done with one rule's store.
public enum ShieldDisposition: Sendable, Equatable, Hashable {

    /// Write the rule's shield set.
    case enforce

    /// Empty the rule's store: it contributes nothing right now.
    case lift(ShieldLiftReason)

    /// Touch nothing. The store keeps whatever it last held, which is the last
    /// configuration Gate believed in.
    case refuse(ShieldRefusal)

    public var isEnforcing: Bool { self == .enforce }
}

// MARK: - ShieldPlan

/// What one rule's `ManagedSettingsStore` should contain, decided without
/// touching a token or a daemon.
///
/// The seam that makes enforcement testable: mode inversion, schedule evaluation,
/// grant algebra and cap checking all happen here, in a pure function of
/// `(Rule, [Grant], now, Calendar)`, and the island below only turns the answer
/// into property assignments.
public struct ShieldPlan: Sendable, Equatable, Hashable {

    public var ruleID: UUID

    /// Mode decides everything downstream; see the file header.
    public var mode: RuleMode

    public var disposition: ShieldDisposition

    /// What live grants take out of the set. Empty unless a grant is running.
    public var lift: ShieldLift

    /// Token counts the rule's ``SelectionDigest`` claims, by collection.
    ///
    /// The island compares these against what the selection blob actually
    /// resolved to; a disagreement is
    /// ``ShieldRefusal/selectionUnresolved(expected:resolved:)``.
    public var expectedCounts: [TokenCollection: Int]

    /// Everything worth saying about this plan, in a stable order.
    public var issues: [ShieldPlanIssue]

    /// The soonest moment this plan stops being correct — a grant expiring.
    /// Schedule boundaries are `Kernel/Engine/ScheduleBuilder.swift`'s.
    public var nextDeadline: Date?

    public init(
        ruleID: UUID,
        mode: RuleMode,
        disposition: ShieldDisposition,
        lift: ShieldLift = .none,
        expectedCounts: [TokenCollection: Int] = [:],
        issues: [ShieldPlanIssue] = [],
        nextDeadline: Date? = nil
    ) {
        self.ruleID = ruleID
        self.mode = mode
        self.disposition = disposition
        self.lift = lift
        self.expectedCounts = expectedCounts
        self.issues = issues
        self.nextDeadline = nextDeadline
    }

    public var isEnforcing: Bool { disposition.isEnforcing }

    /// Total tokens the digest claims.
    public var expectedTokenCount: Int {
        TokenCollection.allCases.reduce(0) { $0 + (expectedCounts[$1] ?? 0) }
    }

    public var blockingIssues: [ShieldPlanIssue] { issues.filter(\.isBlocking) }

    /// A stable digest of everything that decides the write.
    ///
    /// Lets `Kernel/Engine/Reconciler.swift` log "rule X: plan unchanged" across
    /// two processes without comparing tokens. Deliberately **not** used to skip
    /// a write: the store is the source of truth and this value is only a
    /// description of our intent toward it.
    public var fingerprint: String {
        var parts: [String] = [ruleID.uuidString, mode.rawValue]
        switch disposition {
        case .enforce: parts.append("enforce")
        case .lift(let reason): parts.append("lift:" + reason.rawValue)
        case .refuse(let refusal): parts.append("refuse:" + refusal.description)
        }
        for collection in TokenCollection.allCases {
            parts.append("\(collection.rawValue)=\(expectedCounts[collection] ?? 0)")
            parts.append(contentsOf: lift.tokens(in: collection).map(\.fingerprint))
        }
        if lift.liftsEverything { parts.append("lift-all") }
        return GateFingerprint.combine(parts)
    }
}

// MARK: - ShieldPlanner

/// Turns state into shield plans. Pure, total, and the same in every process.
public enum ShieldPlanner {

    /// The plan for one rule.
    ///
    /// Order of decisions is load-bearing:
    ///
    /// 1. **Lift checks first.** A disabled rule, a rule outside its window, a
    ///    rule with no selection and a rule covered by an entire-rule grant all
    ///    resolve to "empty the store" — and emptying always succeeds, no matter
    ///    what the caps say. Checking caps first would let an over-cap rule that
    ///    the user has since *disabled* stay shielded forever.
    /// 2. **Then caps**, on the digest, because they decide whether a write is
    ///    possible at all.
    /// 3. **Then mode-specific expressiveness**, which produces warnings and
    ///    never stops a write.
    ///
    /// - Parameters:
    ///   - rule: the rule to plan for.
    ///   - grants: every grant in state; filtered to this rule here.
    ///   - now: the instant to plan for. No `Date()` is read anywhere in this file.
    ///   - calendar: injected so DST and time-zone cases are testable
    ///     (docs/06-build-plan.md step 3.11).
    public static func plan(
        for rule: Rule,
        grants: some Collection<Grant>,
        now: Date,
        calendar: Calendar = .current
    ) -> ShieldPlan {
        let lift = ShieldLift.make(from: grants, ruleID: rule.id, now: now)
        let digest = rule.selection?.digest
        var counts: [TokenCollection: Int] = [:]
        if let digest {
            for collection in TokenCollection.allCases {
                counts[collection] = digest.count(of: collection)
            }
        }

        var issues: [ShieldPlanIssue] = []

        // A grant a newer build wrote, still inside its window, that this build
        // cannot interpret. `isActive(at:)` excluded it from `lift`; say so.
        for grant in grants where grant.ruleID == rule.id {
            guard grant.revokedAt == nil,
                  now < grant.expiresAt,
                  !grant.scope.isRecognized else { continue }
            issues.append(.unrecognizedGrantScope(grantID: grant.id))
        }

        func planned(_ disposition: ShieldDisposition) -> ShieldPlan {
            ShieldPlan(
                ruleID: rule.id,
                mode: rule.mode,
                disposition: disposition,
                lift: lift,
                expectedCounts: counts,
                issues: issues,
                nextDeadline: lift.nextExpiry
            )
        }

        // ── 1. Lifts ────────────────────────────────────────────────────────
        guard rule.isEnabled else { return planned(.lift(.ruleDisabled)) }
        guard rule.shouldEnforce(at: now, in: calendar) else {
            return planned(.lift(.outsideSchedule))
        }
        guard let digest else { return planned(.lift(.noSelection)) }
        if lift.liftsEverything { return planned(.lift(.entireRuleGrant)) }
        if digest.isEmpty {
            // Both modes. An empty blocklist shields nothing; an empty allowlist
            // would shield the whole device, and Gate does not infer a device-wide
            // block from a set that is empty — the editor blocks saving one
            // (``Rule/validate()`` marks `.emptySelection` blocking), so reaching
            // here means the file, not the user, said this.
            issues.append(.rule(.emptySelection))
            return planned(.lift(.emptySelection))
        }

        // ── 2. Caps (docs/03-hard-constraints.md #34) ───────────────────────
        let capErrors = TokenGuard.issues(in: digest)
        issues.append(contentsOf: capErrors.map { ShieldPlanIssue.cap($0) })
        if let blocking = capErrors.first(where: \.isBlocking) {
            return planned(.refuse(.cap(blocking)))
        }

        // ── 3. Expressiveness of the chosen mode ────────────────────────────
        if rule.mode == .allowlist {
            if digest.categoryCount > 0 {
                issues.append(.allowlistIgnoresCategories(count: digest.categoryCount))
            }
            if !lift.categories.isEmpty {
                issues.append(.liftNotRepresentable(
                    collection: .categories, count: lift.categories.count
                ))
            }
        }

        return planned(.enforce)
    }

    /// A plan per rule, in the user's own order.
    ///
    /// Ordered by ``Rule/sortIndex`` then creation date then id — the same tie
    /// break `Kernel/Enforcement/MonitorPlan.swift` uses — so the write order is
    /// identical in every process and a log from the monitor lines up with a log
    /// from the app.
    public static func plans(
        for state: GateState,
        now: Date,
        calendar: Calendar = .current
    ) -> [ShieldPlan] {
        state.rules
            .sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { plan(for: $0, grants: state.grants, now: now, calendar: calendar) }
    }
}

// MARK: - ShieldWriteSummary

/// What actually landed in a store.
public struct ShieldWriteSummary: Sendable, Equatable, Hashable {

    public let mode: RuleMode

    /// Tokens written into `shield.applications` (blocklist) — always 0 in
    /// allowlist mode, where the property is `nil` by design.
    public let shieldedApplications: Int

    /// Category tokens written into `shield.applicationCategories`.
    public let shieldedCategories: Int

    /// Tokens written into `shield.webDomains`.
    public let shieldedWebDomains: Int

    /// Tokens in the `except:` set of `shield.applicationCategories`.
    public let applicationExceptions: Int

    /// Tokens in the `except:` set of `shield.webDomainCategories`.
    public let webDomainExceptions: Int

    /// Tokens a live grant removed from the shielded set (blocklist) or added to
    /// the allowed set (allowlist).
    public let lifted: Int

    /// Lifted tokens that matched nothing live and would not decode, so they
    /// stayed shielded (docs/03-hard-constraints.md #36).
    public let unresolvedLifts: Int

    public init(
        mode: RuleMode,
        shieldedApplications: Int,
        shieldedCategories: Int,
        shieldedWebDomains: Int,
        applicationExceptions: Int,
        webDomainExceptions: Int,
        lifted: Int,
        unresolvedLifts: Int
    ) {
        self.mode = mode
        self.shieldedApplications = shieldedApplications
        self.shieldedCategories = shieldedCategories
        self.shieldedWebDomains = shieldedWebDomains
        self.applicationExceptions = applicationExceptions
        self.webDomainExceptions = webDomainExceptions
        self.lifted = lifted
        self.unresolvedLifts = unresolvedLifts
    }

    /// Whether this store is shielding anything at all.
    ///
    /// `false` in blocklist mode means the rule is enabled, in its window, and
    /// blocking nothing — which is either an empty selection or a bug, and is
    /// worth a line in the log either way. In allowlist mode a write always
    /// shields (it shields the complement), so this is always `true` there.
    public var shieldsSomething: Bool {
        switch mode {
        case .allowlist: true
        case .blocklist: shieldedApplications + shieldedCategories + shieldedWebDomains > 0
        }
    }
}

// MARK: - ShieldWriteOutcome

/// What a single store operation did.
public enum ShieldWriteOutcome: Sendable, Equatable, Hashable {

    /// The shield set was written.
    case wrote(ShieldWriteSummary)

    /// The store's shield properties were nilled. `reason` is `nil` for an
    /// explicit ``ShieldWriter/clear(rule:)``.
    case cleared(ShieldLiftReason?)

    /// The store was emptied and, on iOS 26.5+, deleted.
    case retired(deleted: Bool)

    /// Nothing was touched. The store keeps its previous contents.
    case refused(ShieldRefusal)

    /// A device-wide setting outside any rule's store was written
    /// (docs/04-product-spec.md V1-8).
    case wroteGlobal(enabled: Bool)

    public var didWrite: Bool {
        switch self {
        case .wrote, .cleared, .retired, .wroteGlobal: true
        case .refused: false
        }
    }
}

// MARK: - ShieldWriteReport

/// One store operation, as a value the reconciler can collect, the debug screen
/// can render and a test can assert on.
public struct ShieldWriteReport: Sendable, Equatable, Hashable {

    /// The `ManagedSettingsStore.Name` raw value that was targeted.
    public let storeName: String

    /// `nil` for global stores (``ManagedSettingsStore/Name/solid``).
    public let ruleID: UUID?

    public let outcome: ShieldWriteOutcome

    /// Everything the plan had to say, plus anything discovered while writing.
    public let issues: [ShieldPlanIssue]

    /// ``ShieldPlan/fingerprint`` of the plan this came from, when there was one.
    public let planFingerprint: String?

    public init(
        storeName: String,
        ruleID: UUID?,
        outcome: ShieldWriteOutcome,
        issues: [ShieldPlanIssue] = [],
        planFingerprint: String? = nil
    ) {
        self.storeName = storeName
        self.ruleID = ruleID
        self.outcome = outcome
        self.issues = issues
        self.planFingerprint = planFingerprint
    }

    public var didWrite: Bool { outcome.didWrite }

    public var refusal: ShieldRefusal? {
        if case .refused(let refusal) = outcome { return refusal }
        return nil
    }
}

// MARK: - ShieldCopyFile

/// `shield.plist` — the pre-rendered shield copy the configuration extension
/// reads (docs/05-architecture.md, data-flow diagram).
///
/// Lives in this file because it is written on the same beat as the stores: a
/// rule's shield set and the copy shown over it have to change together, or the
/// user sees the wrong rule's title on a block that is enforcing correctly.
/// Foundation-only, so it is available in the test package and in the shield
/// extension alike.
public enum ShieldCopyFile {

    /// Uncoordinated by design.
    ///
    /// The reader is `ShieldConfigurationDataSource`, which is latency-bounded —
    /// the system substitutes its own default shield if the data source is slow
    /// (docs/03-hard-constraints.md #33) — so it reads without
    /// `NSFileCoordinator`, and a coordinated *writer* would buy ordering against
    /// a reader that is not participating. What makes the read safe is
    /// `.atomic`: Foundation writes a sibling file and `rename(2)`s it, so the
    /// extension sees the whole previous file or the whole new one, never a torn
    /// prefix (``AppGroupContainer/writingOptions``).
    public static func file() throws -> PlistFile<ShieldCopyTable> {
        PlistFile(url: try AppGroupContainer.shieldURL, coordinated: false)
    }

    /// Publishes the table. Returns the byte count written.
    ///
    /// Only the app calls this: extensions never write `state.plist` or
    /// `shield.plist` (docs/05-architecture.md, single-writer discipline).
    @discardableResult
    public static func publish(_ table: ShieldCopyTable) throws -> Int {
        try file().write(table)
    }

    /// Reads the table, for the shield extension and the debug screen.
    public static func read() throws -> ShieldCopyTable {
        try file().read()
    }
}

// MARK: - ManagedSettings island

// Everything above is pure and compiles on Linux for the SwiftPM test package
// (docs/05-architecture.md, module layer split). Everything below talks to the
// Screen Time daemon and exists only on iOS.
//
// `os` is imported here rather than at the top for the same reason: it does not
// exist on Linux. `print()` is never an option — it is invisible from an
// extension (docs/06-build-plan.md step 4.1).

#if canImport(ManagedSettings)
import ManagedSettings
import os

/// Computed, not a stored global `let`: `Logger` is an SDK type whose `Sendable`
/// conformance is not audited, and a stored static of such a type is a Swift 6
/// strict-concurrency error. Constructing one is cheap — it wraps an existing
/// `os_log_t` handle. Same reasoning as `Kernel/Store/GateStateStore.swift`.
private var shieldLog: Logger {
    Logger(subsystem: GateID.Subsystem.kernel, category: "shield-writer")
}

// MARK: - ResolvedTokens

/// One rule's selection, decoded into live tokens by the caller.
///
/// The kernel never decodes a `FamilyActivitySelection` itself — that is
/// `Kernel/Store/SelectionStore.swift`'s single job, and it is the only other
/// place allowed to name the type (see the header of `Kernel/Model/Rule.swift`).
/// The writer takes the result.
///
/// **Deliberately not `Sendable`.** `Token<_>` has no audited `Sendable`
/// conformance, so this value must not be captured in a `Task`, stored in an
/// actor, or held across an `await`. It is created, passed to
/// ``ShieldWriter/apply(_:tokens:)`` and dropped, inside one synchronous call.
public struct ResolvedTokens {

    public var applications: Set<ApplicationToken>
    public var categories: Set<ActivityCategoryToken>
    public var webDomains: Set<WebDomainToken>

    public init(
        applications: Set<ApplicationToken> = [],
        categories: Set<ActivityCategoryToken> = [],
        webDomains: Set<WebDomainToken> = []
    ) {
        self.applications = applications
        self.categories = categories
        self.webDomains = webDomains
    }

    public var count: Int { applications.count + categories.count + webDomains.count }

    public var isEmpty: Bool { count == 0 }

    /// Counts by collection, for the cap checks in
    /// `Kernel/Enforcement/TokenGuard.swift`.
    public var counts: [TokenCollection: Int] {
        [
            .applications: applications.count,
            .categories: categories.count,
            .webDomains: webDomains.count
        ]
    }
}

// MARK: - ShieldWriter

/// Writes `ManagedSettingsStore`s. The only type in Gate that does.
///
/// **Not `Sendable`, and not an actor.** Every method is synchronous and touches
/// non-`Sendable` SDK types; the daemon call behind each property assignment is
/// already serialized on its own side. Construct one where you need it — the
/// type holds no state beyond its staging policy — and do not hand it to a
/// `Task`.
public struct ShieldWriter {

    // MARK: Staging

    /// Whether a rewrite is shadowed by ``ManagedSettingsStore/Name/backstop``.
    public enum Staging: String, Hashable, Sendable, CaseIterable {

        /// Write the rule's store directly. The default.
        case off

        /// Write the incoming shield set into
        /// ``ManagedSettingsStore/Name/backstop`` first, then into the rule's own
        /// store, then empty the backstop.
        ///
        /// **What this buys.** A shield set is four separate property
        /// assignments, and a rule that moves an app from `shield.applications`
        /// to a shielded *category* is unshielded for that app between
        /// assignment one and assignment two. Staging the incoming set in a
        /// second store keeps it enforced across the whole rewrite: the daemon
        /// computes effective settings over every store it holds
        /// (docs/02-api-reference.md §6), so a token shielded by either store is
        /// shielded.
        ///
        /// **What it costs.** Eight extra daemon writes per rule, and a window
        /// in which a process killed mid-rewrite leaves the backstop holding one
        /// rule's set — an *over*-block that persists until the next reconcile
        /// calls ``ShieldWriter/releaseBackstop()``, which
        /// the batch
        /// ``ShieldWriter/apply(_:tokens:)`` does at both ends of every pass. Over-blocking is the safe direction, but it is
        /// still wrong, so this is opt-in.
        ///
        /// **(unverified)** Whether the mid-rewrite window is observable at all
        /// is not documented by Apple and has not been measured on a device; the
        /// daemon may well coalesce the four assignments. Leave this `off` until
        /// the device test in docs/06-build-plan.md says otherwise.
        case backstop
    }

    /// The staging policy. ``Staging/off`` unless the caller says otherwise.
    public let staging: Staging

    public init(staging: Staging = .off) {
        self.staging = staging
    }

    // MARK: Applying a plan

    /// Writes one rule's shield set.
    ///
    /// The whole of docs/02-api-reference.md §6's write pattern, plus the grant
    /// algebra, plus the cap guard. Never throws: a reconcile writes every rule,
    /// and a throw on rule three would leave rules four through eight holding
    /// yesterday's settings with no record of why. Every failure is in the
    /// returned report.
    ///
    /// - Parameters:
    ///   - plan: from ``ShieldPlanner/plan(for:grants:now:calendar:)``.
    ///   - tokens: the rule's selection, already decoded.
    public func apply(_ plan: ShieldPlan, tokens: ResolvedTokens) -> ShieldWriteReport {
        let name = ManagedSettingsStore.Name.rule(plan.ruleID)
        var issues = plan.issues

        switch plan.disposition {
        case .refuse(let refusal):
            return refuse(refusal, name: name, plan: plan, issues: issues)
        case .lift(let reason):
            return clear(name: name, ruleID: plan.ruleID, reason: reason,
                         issues: issues, planFingerprint: plan.fingerprint)
        case .enforce:
            break
        }

        // ── Cap guard, on the real token sets ───────────────────────────────
        //
        // Checked *before* any grant is subtracted, and deliberately so. A rule
        // holding 52 apps whose grant currently lifts two would otherwise write
        // a legal 50 today and refuse tomorrow when the grant expires — leaving
        // those two apps permanently unshielded, silently, which is exactly the
        // failure docs/03-hard-constraints.md #34 describes. The honest size of
        // the rule is what has to fit.
        //
        // The digest was checked in the planner; this checks the blob, which can
        // disagree with it.
        if let overflow = TokenGuard.issues(forCounts: tokens.counts).first(where: \.isBlocking) {
            issues.append(.cap(overflow))
            return refuse(.cap(overflow), name: name, plan: plan, issues: issues)
        }

        // ── Coherence: does the blob agree with the digest? ─────────────────
        //
        // Only the unambiguous disagreement is refused: the digest claims tokens
        // and the blob produced none. A digest that lags the blob by one or two
        // tokens is normal for a reconcile that races an edit; a digest that
        // claims thirty apps over a blob that resolved zero means one of the two
        // files is torn, and in allowlist mode acting on it would shield the
        // entire device.
        if plan.expectedTokenCount > 0, tokens.isEmpty {
            let refusal = ShieldRefusal.selectionUnresolved(
                expected: plan.expectedTokenCount, resolved: 0
            )
            return refuse(refusal, name: name, plan: plan, issues: issues)
        }

        // ── Grants ─────────────────────────────────────────────────────────
        let lift = resolve(plan.lift, in: tokens, into: &issues)

        let store = ManagedSettingsStore(named: name)
        let summary: ShieldWriteSummary
        let writeShape: (ManagedSettingsStore) -> Void

        switch plan.mode {
        case .blocklist:
            // Set subtraction, exactly as docs/02-api-reference.md §6 specifies:
            // the granted tokens come out of the shielded sets *and* go into the
            // category policy's `except:`, because an app can be shielded twice
            // over — once by name and once by the category it belongs to.
            let shieldedApplications = tokens.applications.subtracting(lift.applications)
            let shieldedCategories = tokens.categories.subtracting(lift.categories)
            let shieldedWebDomains = tokens.webDomains.subtracting(lift.webDomains)

            // The `except:` set rides inside the `applicationCategories`
            // collection and is capped with it. If the exceptions alone would
            // break the cap, drop them rather than the write: keeping the
            // category shielded costs the user their grant, while an over-cap
            // write costs them the whole rule, silently.
            var exceptions = lift.applications
            if let overflow = TokenGuard.combinedIssue(
                shielded: shieldedCategories.count,
                exceptions: exceptions.count,
                in: .categories
            ) {
                issues.append(.cap(overflow))
            }
            if exceptions.count > TokenGuard.collectionLimit {
                issues.append(.cap(.exceptionOverflow(
                    collection: .applications,
                    count: exceptions.count,
                    limit: TokenGuard.collectionLimit
                )))
                issues.append(.unresolvedLift(
                    collection: .applications, count: exceptions.count
                ))
                exceptions = []
            }
            let appExceptions = exceptions

            writeShape = { target in
                target.shield.applications =
                    shieldedApplications.isEmpty ? nil : shieldedApplications
                if shieldedCategories.isEmpty {
                    target.shield.applicationCategories = nil
                } else {
                    target.shield.applicationCategories =
                        .specific(shieldedCategories, except: appExceptions)
                }
                target.shield.webDomains =
                    shieldedWebDomains.isEmpty ? nil : shieldedWebDomains
                // `nil`, never `.none`: `ActivityCategoryPolicy` has a case
                // spelled `none` and the property is `Optional`, so `.none` is
                // ambiguous to a reader and resolves to `Optional.none` anyway.
                // Written explicitly on every pass because a rule that used to
                // be an allowlist left `.all(except:)` here, and leaving that
                // behind would shield every web domain on the device.
                target.shield.webDomainCategories = nil
            }

            summary = ShieldWriteSummary(
                mode: .blocklist,
                shieldedApplications: shieldedApplications.count,
                shieldedCategories: shieldedCategories.count,
                shieldedWebDomains: shieldedWebDomains.count,
                applicationExceptions: appExceptions.count,
                webDomainExceptions: 0,
                lifted: lift.count,
                unresolvedLifts: lift.unresolved
            )

        case .allowlist:
            // The inversion. The shielded set is the complement of the allowed
            // set, so a grant that "subtracts from the shield" *adds* to
            // `except:`. Same grant, opposite operator — see the file header.
            var allowedApplications = tokens.applications.union(lift.applications)
            var allowedWebDomains = tokens.webDomains.union(lift.webDomains)

            // Same reasoning as the blocklist exceptions: if the lift pushes the
            // allowed set over the silent cap, drop the lift, not the rule.
            if allowedApplications.count > TokenGuard.collectionLimit {
                issues.append(.cap(.exceptionOverflow(
                    collection: .applications,
                    count: allowedApplications.count,
                    limit: TokenGuard.collectionLimit
                )))
                issues.append(.unresolvedLift(
                    collection: .applications, count: lift.applications.count
                ))
                allowedApplications = tokens.applications
            }
            if allowedWebDomains.count > TokenGuard.collectionLimit {
                issues.append(.cap(.exceptionOverflow(
                    collection: .webDomains,
                    count: allowedWebDomains.count,
                    limit: TokenGuard.collectionLimit
                )))
                issues.append(.unresolvedLift(
                    collection: .webDomains, count: lift.webDomains.count
                ))
                allowedWebDomains = tokens.webDomains
            }
            let exceptApplications = allowedApplications
            let exceptWebDomains = allowedWebDomains

            writeShape = { target in
                // Nilled explicitly: a rule that used to be a blocklist left
                // token sets here, and `.all(except:)` plus a stale blocklist is
                // not the configuration anyone asked for.
                target.shield.applications = nil
                target.shield.applicationCategories = .all(except: exceptApplications)
                target.shield.webDomains = nil
                target.shield.webDomainCategories = .all(except: exceptWebDomains)
            }

            summary = ShieldWriteSummary(
                mode: .allowlist,
                shieldedApplications: 0,
                shieldedCategories: 0,
                shieldedWebDomains: 0,
                applicationExceptions: exceptApplications.count,
                webDomainExceptions: exceptWebDomains.count,
                lifted: lift.count,
                unresolvedLifts: lift.unresolved
            )
        }

        if staging == .backstop {
            writeShape(ManagedSettingsStore(named: .backstop))
        }
        writeShape(store)
        activate(store)
        if staging == .backstop {
            _ = releaseBackstop()
        }

        let exceptionCount = summary.applicationExceptions + summary.webDomainExceptions
        shieldLog.info(
            """
            rule \(plan.ruleID.uuidString, privacy: .public) \
            mode=\(plan.mode.rawValue, privacy: .public) \
            apps=\(summary.shieldedApplications, privacy: .public) \
            cats=\(summary.shieldedCategories, privacy: .public) \
            webs=\(summary.shieldedWebDomains, privacy: .public) \
            except=\(exceptionCount, privacy: .public) \
            lifted=\(summary.lifted, privacy: .public) \
            unresolved=\(summary.unresolvedLifts, privacy: .public)
            """
        )
        if !summary.shieldsSomething {
            shieldLog.warning(
                "rule \(plan.ruleID.uuidString, privacy: .public) is enforcing but shields nothing"
            )
        }

        return ShieldWriteReport(
            storeName: name.rawValue,
            ruleID: plan.ruleID,
            outcome: .wrote(summary),
            issues: issues,
            planFingerprint: plan.fingerprint
        )
    }

    /// Applies a whole pass.
    ///
    /// - Parameters:
    ///   - plans: in ``ShieldPlanner/plans(for:now:calendar:)`` order.
    ///   - tokens: resolves a rule's selection. Returning `nil` refuses that
    ///     rule's write with ``ShieldRefusal/selectionMissing`` — the blob is
    ///     gone or unreadable, and a store left alone is better than a store
    ///     emptied on the strength of a failed read. A rule whose plan is
    ///     ``ShieldDisposition/lift(_:)`` is cleared without ever asking for its
    ///     tokens, so a missing blob never strands a disabled rule.
    public func apply(
        _ plans: [ShieldPlan],
        tokens: (UUID) -> ResolvedTokens?
    ) -> [ShieldWriteReport] {
        // Clear any set a previous pass staged and was killed before releasing.
        if staging == .backstop { _ = releaseBackstop() }

        var reports: [ShieldWriteReport] = []
        reports.reserveCapacity(plans.count)

        for plan in plans {
            guard plan.isEnforcing else {
                reports.append(apply(plan, tokens: ResolvedTokens()))
                continue
            }
            guard let resolved = tokens(plan.ruleID) else {
                let name = ManagedSettingsStore.Name.rule(plan.ruleID)
                reports.append(
                    refuse(.selectionMissing, name: name, plan: plan, issues: plan.issues)
                )
                continue
            }
            reports.append(apply(plan, tokens: resolved))
        }

        if staging == .backstop { _ = releaseBackstop() }
        return reports
    }

    // MARK: Clearing

    /// Empties exactly one rule's store.
    ///
    /// Nils the four shield properties Gate writes and **nothing else**. There is
    /// no `clearAllSettings()` in this file, in any path: docs/02-api-reference.md
    /// §6 names set subtraction as the way to unblock temporarily, and a blunt
    /// clear would also drop any setting a future version of Gate stores
    /// alongside the shield. Setting a property to `nil` is Apple's documented
    /// "delete my configuration for this setting".
    ///
    /// Other rules are untouched by construction — each rule owns its own named
    /// store (``ManagedSettingsStore/Name/rule(_:)``) — and so is
    /// ``ManagedSettingsStore/Name/solid``, which is where install protection
    /// lives precisely so that rebuilding a shield set can never disturb it.
    @discardableResult
    public func clear(rule ruleID: UUID) -> ShieldWriteReport {
        clear(
            name: .rule(ruleID),
            ruleID: ruleID,
            reason: nil,
            issues: [],
            planFingerprint: nil
        )
    }

    /// Empties the backstop staging store.
    ///
    /// Idempotent and safe to call at any time — it is a store Gate owns and
    /// nothing else reads.
    @discardableResult
    public func releaseBackstop() -> ShieldWriteReport {
        clear(
            name: .backstop,
            ruleID: nil,
            reason: nil,
            issues: [],
            planFingerprint: nil
        )
    }

    /// Empties a deleted rule's store and, where the API exists, removes it.
    ///
    /// The named-store cap is 50 and fails silently (docs/02-api-reference.md
    /// §14), so orphaned stores are worth reclaiming — but `deleteStore()` is an
    /// iOS 26.5 symbol (§13). Below 26.5 there is no delete at all and the store
    /// is left empty, which is inert: an emptied store contributes nothing to the
    /// effective settings, and Gate's own naming keeps the count at
    /// ``TokenGuard/expectedStoreCount(ruleCount:)`` — ten at the rule cap.
    @discardableResult
    public func retire(rule ruleID: UUID) -> ShieldWriteReport {
        let name = ManagedSettingsStore.Name.rule(ruleID)
        let store = ManagedSettingsStore(named: name)
        empty(store)

        var deleted = false
        if #available(iOS 26.5, *) {
            store.deleteStore()
            deleted = true
        }
        shieldLog.info(
            "retired store \(name.rawValue, privacy: .public) deleted=\(deleted, privacy: .public)"
        )
        return ShieldWriteReport(
            storeName: name.rawValue,
            ruleID: ruleID,
            outcome: .retired(deleted: deleted)
        )
    }

    // MARK: Install protection (docs/04-product-spec.md V1-8)

    /// Writes "Solid" mode into ``ManagedSettingsStore/Name/solid``.
    ///
    /// A device-wide setting, so it lives in its own store and never rides along
    /// with a rule's shield set. Enabling is a tightening and free; disabling
    /// goes through the Lock — `Kernel/Engine/Ratchet.swift` decides that, and
    /// by the time a value reaches here the decision has been made.
    ///
    /// `false` is written as `nil` rather than as `false`: Apple's
    /// documented meaning for `nil` is "delete my configuration for this
    /// setting" (docs/02-api-reference.md §6), which is what "off" means here.
    /// Writing `false` would assert a preference Gate does not have and would
    /// leave Gate's store in the effective-settings calculation for a setting it
    /// no longer cares about.
    ///
    /// `denyAppRemoval` is **never** written. It is device-wide, only honored
    /// under `.child` enrollment, and has been reported stuck on after the app
    /// is uninstalled (docs/03-hard-constraints.md #15).
    @discardableResult
    public func applyInstallProtection(_ enabled: Bool) -> ShieldWriteReport {
        let name = ManagedSettingsStore.Name.solid
        let store = ManagedSettingsStore(named: name)
        store.application.denyAppInstallation = enabled ? true : nil
        activate(store)
        let stateWord = enabled ? "on" : "off"
        shieldLog.info("install protection \(stateWord, privacy: .public)")
        return ShieldWriteReport(
            storeName: name.rawValue,
            ruleID: nil,
            outcome: .wroteGlobal(enabled: enabled)
        )
    }

    // MARK: Internals

    /// Resolves an encoded lift against the rule's live tokens.
    ///
    /// Live token first, stored bytes second. The order matters: a token handed
    /// over by the system can fail `==` against a byte-identical-looking stored
    /// copy (docs/03-hard-constraints.md #36, thread 814571, no workaround from
    /// Apple), so subtracting the system's own object is the only reliable
    /// removal. Decoding is the fallback for a token that is genuinely not in
    /// this rule's selection — an app shielded by its *category*, which is the
    /// common case for a grant issued from a shield tap.
    ///
    /// Anything that resolves to neither stays shielded and is counted in
    /// ``ResolvedLift/unresolved``. Failing closed here costs the user a grant
    /// they earned; failing open would cost them a block they asked for.
    private func resolve(
        _ lift: ShieldLift,
        in tokens: ResolvedTokens,
        into issues: inout [ShieldPlanIssue]
    ) -> ResolvedLift {
        guard !lift.isEmpty else { return ResolvedLift() }

        var resolved = ResolvedLift()

        if !lift.applications.isEmpty {
            let index = TokenGuard.fingerprintIndex(tokens.applications, kind: .application)
            var unresolved = 0
            for encoded in lift.applications {
                if let live = index[encoded.fingerprint] {
                    resolved.applications.insert(live)
                } else if let decoded = try? TokenGuard.decodeApplication(encoded) {
                    resolved.applications.insert(decoded)
                } else {
                    unresolved += 1
                }
            }
            if unresolved > 0 {
                issues.append(.unresolvedLift(collection: .applications, count: unresolved))
                resolved.unresolved += unresolved
            }
        }

        if !lift.categories.isEmpty {
            let index = TokenGuard.fingerprintIndex(tokens.categories, kind: .category)
            var unresolved = 0
            for encoded in lift.categories {
                if let live = index[encoded.fingerprint] {
                    resolved.categories.insert(live)
                } else if let decoded = try? TokenGuard.decodeCategory(encoded) {
                    resolved.categories.insert(decoded)
                } else {
                    unresolved += 1
                }
            }
            if unresolved > 0 {
                issues.append(.unresolvedLift(collection: .categories, count: unresolved))
                resolved.unresolved += unresolved
            }
        }

        if !lift.webDomains.isEmpty {
            let index = TokenGuard.fingerprintIndex(tokens.webDomains, kind: .webDomain)
            var unresolved = 0
            for encoded in lift.webDomains {
                if let live = index[encoded.fingerprint] {
                    resolved.webDomains.insert(live)
                } else if let decoded = try? TokenGuard.decodeWebDomain(encoded) {
                    resolved.webDomains.insert(decoded)
                } else {
                    unresolved += 1
                }
            }
            if unresolved > 0 {
                issues.append(.unresolvedLift(collection: .webDomains, count: unresolved))
                resolved.unresolved += unresolved
            }
        }

        return resolved
    }

    /// A ``ShieldLift`` with its tokens resolved. Not `Sendable`; see
    /// ``ResolvedTokens``.
    private struct ResolvedLift {
        var applications: Set<ApplicationToken> = []
        var categories: Set<ActivityCategoryToken> = []
        var webDomains: Set<WebDomainToken> = []
        var unresolved: Int = 0

        var count: Int { applications.count + categories.count + webDomains.count }
    }

    /// Nils the four shield properties. The only "clear" in the product.
    private func empty(_ store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
    }

    /// Asserts that this store participates in the effective-settings
    /// calculation.
    ///
    /// `isActive` is iOS 26.5 (docs/02-api-reference.md §13) and its default for
    /// a store Gate has never touched is **(unverified)** — Apple documents what
    /// `false` does ("excluded from the effective-settings calc") and not what a
    /// fresh store holds. Gate therefore states the value it needs instead of
    /// assuming it, on every enforcing write, and does nothing at all below 26.5
    /// where the property does not exist and stores are always active.
    private func activate(_ store: ManagedSettingsStore) {
        if #available(iOS 26.5, *) {
            store.isActive = true
        }
    }

    private func clear(
        name: ManagedSettingsStore.Name,
        ruleID: UUID?,
        reason: ShieldLiftReason?,
        issues: [ShieldPlanIssue],
        planFingerprint: String?
    ) -> ShieldWriteReport {
        empty(ManagedSettingsStore(named: name))
        let reasonWord = reason?.rawValue ?? "explicit"
        shieldLog.info(
            """
            cleared \(name.rawValue, privacy: .public) \
            reason=\(reasonWord, privacy: .public)
            """
        )
        return ShieldWriteReport(
            storeName: name.rawValue,
            ruleID: ruleID,
            outcome: .cleared(reason),
            issues: issues,
            planFingerprint: planFingerprint
        )
    }

    private func refuse(
        _ refusal: ShieldRefusal,
        name: ManagedSettingsStore.Name,
        plan: ShieldPlan,
        issues: [ShieldPlanIssue]
    ) -> ShieldWriteReport {
        // `error`, not `info`: a refused write means the store is enforcing
        // something other than what state says it should, and that is exactly
        // the condition the debug screen and any bug report need to surface.
        shieldLog.error(
            """
            refused \(name.rawValue, privacy: .public): \
            \(refusal.description, privacy: .public) — store left as it was
            """
        )
        return ShieldWriteReport(
            storeName: name.rawValue,
            ruleID: plan.ruleID,
            outcome: .refused(refusal),
            issues: issues,
            planFingerprint: plan.fingerprint
        )
    }
}

#endif
