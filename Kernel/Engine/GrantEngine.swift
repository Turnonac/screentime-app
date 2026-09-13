//
//  GrantEngine.swift
//  GateKernel
//
//  Issue, count and expire grants — the time-boxed, token-scoped unblock at the
//  end of V1-7's intervention (docs/04-product-spec.md V1-7).
//
//  Build plan: the grant half of docs/06-build-plan.md PHASE 3; the shield half
//  is `Kernel/Enforcement/ShieldWriter.swift`, which turns a live ``Grant`` into
//  set subtraction, and the activity half is
//  `Kernel/Enforcement/MonitorPlan.swift`, which arms the one-shot expiry.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THE FOUR INVARIANTS
//
//  1. **Expiry is an absolute timestamp, never a timer.** ``Grant/expiresAt`` is
//     a `Date`, and "is this grant live" is `now < expiresAt`, recomputed from
//     scratch on every foreground and every monitor callback. The one-shot
//     `gate.grant:<rule>|<grant>` activity is an accelerator. The monitor is
//     killed for memory or idleness and has been reported as never launching at
//     all (docs/03-hard-constraints.md #32); if it never fires, the grant still
//     ends at the same instant, because nothing was ever waiting on it.
//
//  2. **The budget rolls at *local* midnight.** ``GrantLedger/rolled(to:in:)``
//     owns that arithmetic, with the `Calendar` injected, so a DST boundary or a
//     time-zone change is a test rather than a field report.
//
//  3. **Running out is a TIGHTENING.** It takes effect the instant the third
//     grant is spent, with no Lock, no `PendingChange` and no countdown — the
//     Lock exists to slow *loosenings* (docs/04-product-spec.md V1-4), and an
//     exhausted budget only ever removes a way out. The same asymmetry runs the
//     other way for the policy itself: see ``GrantEngine/PolicyChange``.
//
//  4. **`now` is always injected.** There is no `Date()` in this file. Every
//     function is a pure function of its arguments, which is what makes
//     `Tests/GateKernelTests/GrantEngineTests.swift` able to cross midnight,
//     exhaust a budget and expire a grant without a device — and there is no
//     device to test on, ever, because the Simulator does not implement these
//     frameworks (docs/03-hard-constraints.md #11).
//  ─────────────────────────────────────────────────────────────────────────────
//
//  WHAT THIS FILE DOES NOT OWN
//
//  - **Revoking a grant.** Ending one early is a tightening and is a
//    ``Mutation/revokeGrant(id:)`` like any other state change, so it goes
//    through `Kernel/Engine/Ratchet.swift` — the single funnel that makes the
//    Lock un-bypassable by a screen that forgot to ask.
//  - **Writing shields.** A grant is a value; `ShieldWriter` is what makes it
//    visible.
//  - **The forced wait.** ``GrantPolicy/interventionWait(under:)`` computes it;
//    `App/Screens/InterventionScreen.swift` serves it. This file is called after
//    the wait is over.
//  - **Persisting.** Callers save through `Kernel/Store/GateStateStore.swift`,
//    which is also what bumps the generation beacon. Engines only set
//    ``GateState/updatedAt``.
//
//  Foundation only, like every other file in Kernel/Engine/. The one place that
//  names a type from `Kernel/Store/InboxStore.swift` is fenced at the bottom.
//

import Foundation

// MARK: - GrantEngine

/// The grant lifecycle: how many are left, issuing one, and noticing that one
/// has ended.
///
/// An uninhabited namespace — nothing here has state, and the state it operates
/// on is passed in and returned.
public enum GrantEngine {

    // MARK: - Budget

    /// Today's grant allowance, as seen from one process at one instant.
    ///
    /// **Why `inFlight` exists.** `GateShieldAction` runs in a different process
    /// and must never write `state.plist` (docs/05-architecture.md, single-writer
    /// discipline): it appends a record to `inbox/` and the app compacts it in on
    /// the next foreground reconcile. Between a shield tap and the next app
    /// launch, ``GrantLedger/used`` is therefore *stale by design*. The extension
    /// computes its effective remaining count by subtracting the records already
    /// sitting in the inbox — ``GrantEngine/inFlightCount(in:)`` counts them —
    /// and without that subtraction a day's budget can be spent twice.
    public struct Budget: Sendable, Equatable, Hashable {

        /// ``GrantPolicy/dailyLimit`` — default ``GateLimits/defaultDailyGrantBudget`` (3).
        public let limit: Int

        /// Grants already recorded in ``GateState/grantLedger`` for today.
        public let spent: Int

        /// Grant records sitting unconsumed in `inbox/`, not yet in the ledger.
        public let inFlight: Int

        /// Local midnight that started this budget period.
        public let periodStart: Date

        /// The next local midnight, when ``spent`` returns to zero. `nil` only if
        /// the calendar cannot produce the next day, which no real calendar does.
        public let resetsAt: Date?

        public init(
            limit: Int,
            spent: Int,
            inFlight: Int,
            periodStart: Date,
            resetsAt: Date?
        ) {
            self.limit = max(0, limit)
            self.spent = max(0, spent)
            self.inFlight = max(0, inFlight)
            self.periodStart = periodStart
            self.resetsAt = resetsAt
        }

        /// Grants the user may still earn today. Never negative.
        public var remaining: Int { max(0, limit - spent - inFlight) }

        public var hasBudget: Bool { remaining > 0 }

        /// The state that denies an intervention with
        /// ``InterventionRequest/DenialReason/budgetExhausted``.
        ///
        /// A tightening: immediate, free, and nothing to wait for except
        /// ``resetsAt``.
        public var isExhausted: Bool { !hasBudget }

        /// How long until the budget resets, or `nil` when that is unknowable.
        public func timeUntilReset(from now: Date) -> TimeInterval? {
            resetsAt.map { max(0, $0.timeIntervalSince(now)) }
        }
    }

    /// The budget implied by a ledger and a policy.
    ///
    /// Rolls the ledger first: a ledger whose `periodStart` is yesterday reports
    /// today's allowance, not yesterday's leftovers. The roll is not persisted
    /// here — ``issue(_:in:now:calendar:isAuthorized:)`` persists it when it
    /// spends — so this is safe to call from the extension, which may not write.
    public static func budget(
        ledger: GrantLedger,
        policy: GrantPolicy,
        now: Date,
        calendar: Calendar = .current,
        inFlight: Int = 0
    ) -> Budget {
        let rolled = ledger.rolled(to: now, in: calendar)
        return Budget(
            limit: policy.dailyLimit,
            spent: rolled.used,
            inFlight: inFlight,
            periodStart: rolled.periodStart,
            resetsAt: nextReset(after: now, in: calendar)
        )
    }

    /// ``budget(ledger:policy:now:calendar:inFlight:)`` for a whole state.
    public static func budget(
        in state: GateState,
        now: Date,
        calendar: Calendar = .current,
        inFlight: Int = 0
    ) -> Budget {
        budget(
            ledger: state.grantLedger,
            policy: state.grantPolicy,
            now: now,
            calendar: calendar,
            inFlight: inFlight
        )
    }

    /// The next local midnight after `now`.
    ///
    /// `Calendar.date(byAdding:)` rather than `now + 86_400`: the day a DST
    /// transition lands on is 23 or 25 hours long, and a budget that resets an
    /// hour early twice a year is a bug report nobody will ever diagnose.
    public static func nextReset(after now: Date, in calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
    }

    // MARK: - Issuing

    /// Everything needed to mint one ``Grant``.
    ///
    /// A value rather than a pile of arguments so the two callers — the
    /// intervention screen and (on iOS 26.4+, V2-1) the shield submenu — build
    /// the same thing, and so a test can hold one and vary a single field.
    public struct IssueRequest: Sendable, Equatable, Hashable {

        /// The rule whose shield is being lifted.
        public var ruleID: UUID

        /// What to lift. ``GrantScope/tokens(_:)`` for the normal case — the user
        /// tapped one app's shield, so only that app opens.
        public var scope: GrantScope

        /// `nil` uses ``GrantPolicy/defaultDuration`` (5 minutes). The submenu
        /// path passes 1, 15 or 60 minutes explicitly.
        public var duration: TimeInterval?

        public var source: GrantSource

        /// The ``InterventionRequest`` this grant answers, when there is one.
        public var requestID: UUID?

        /// The user's typed reason (docs/04-product-spec.md V1-7 step 2).
        /// Truncated to ``Grant/maxReasonLength`` by ``Grant``'s initializer.
        public var reason: String?

        /// The id the new grant will carry.
        ///
        /// Injectable because it is also the second UUID in the
        /// `gate.grant:<ruleUUID>|<grantUUID>` activity name
        /// (docs/05-architecture.md, the `DeviceActivityName` codec), so a test
        /// that asserts on the armed activity needs to know it in advance.
        public var grantID: UUID

        public init(
            ruleID: UUID,
            scope: GrantScope,
            duration: TimeInterval? = nil,
            source: GrantSource,
            requestID: UUID? = nil,
            reason: String? = nil,
            grantID: UUID = UUID()
        ) {
            self.ruleID = ruleID
            self.scope = scope
            self.duration = duration
            self.source = source
            self.requestID = requestID
            self.reason = reason
            self.grantID = grantID
        }

        /// Whether this request names something a shield can actually lift.
        ///
        /// An empty ``ScopedTokens`` means `ShieldActionDelegate` could not name
        /// the token it was handed, so there is nothing to subtract — and
        /// widening that to "lift the whole rule" would hand the user a broader
        /// unblock than they asked for on the strength of a failure. An
        /// unrecognized scope is a grant from a newer build, which
        /// ``Grant/isActive(at:)`` would refuse to honour anyway.
        public var namesSomethingToLift: Bool {
            switch scope {
            case .entireRule: true
            case .tokens(let scoped): !scoped.isEmpty
            case .unrecognized: false
            }
        }
    }

    /// Why Gate refused, reusing the vocabulary the request record already
    /// speaks (``InterventionRequest/DenialReason``) so that a denial is written
    /// straight onto the request without translation.
    public typealias Denial = InterventionRequest.DenialReason

    /// The result of asking for a grant.
    ///
    /// Always carries a usable ``state``: on a denial it is the state that was
    /// passed in, unchanged except for the request's resolution, so a caller can
    /// save unconditionally.
    public struct Issuance: Sendable, Equatable {

        /// The state to persist.
        public let state: GateState

        /// The new grant, or `nil` if it was denied.
        public let grant: Grant?

        /// `nil` when a grant was issued.
        public let denial: Denial?

        /// The budget **after** this call. The intervention screen shows it back
        /// to the user ("2 left today"), which is most of what makes the budget
        /// feel like a budget rather than a punishment.
        public let budget: Budget

        /// The originating request with its ``InterventionRequest/resolution``
        /// filled in, when the call came from one.
        public let request: InterventionRequest?

        public init(
            state: GateState,
            grant: Grant?,
            denial: Denial?,
            budget: Budget,
            request: InterventionRequest? = nil
        ) {
            self.state = state
            self.grant = grant
            self.denial = denial
            self.budget = budget
            self.request = request
        }

        public var isIssued: Bool { grant != nil }
    }

    /// Issues a grant, or explains why not.
    ///
    /// The order of the checks is the order the user experiences them, and each
    /// one maps onto a screen:
    ///
    /// 1. **Authorization.** The user can revoke Family Controls in about four
    ///    taps and every token is voided with it (docs/03-hard-constraints.md
    ///    #13, #14). A grant against a revoked authorization is a lie, so it is
    ///    refused and the caller routes to onboarding.
    /// 2. **The rule.** No rule, nothing to subtract from → recovery
    ///    (docs/04-product-spec.md V1-9).
    /// 3. **The scope.** See ``IssueRequest/namesSomethingToLift``. Also
    ///    recovery: a token the extension could not name is the signature of a
    ///    reissued token (docs/03-hard-constraints.md #36).
    /// 4. **The budget.** Exhausted is a tightening — immediate, no Lock.
    ///
    /// Not checked: whether the rule is *currently enforcing*. A rule that was
    /// disabled or left its window between the shield tap and this call produces
    /// a grant that lifts nothing, which costs one unit of budget and no
    /// enforcement. Denying instead would need a `DenialReason` that does not
    /// exist, and the race is both rare and self-explanatory — the app is
    /// already open.
    ///
    /// - Parameter isAuthorized: `AuthorizationCenter.shared.authorizationStatus
    ///   == .approved`, passed in because `FamilyControls` is not linkable from
    ///   the kernel and is not readable at all from some of the processes that
    ///   call this.
    public static func issue(
        _ request: IssueRequest,
        in state: GateState,
        now: Date,
        calendar: Calendar = .current,
        isAuthorized: Bool = true
    ) -> Issuance {
        func denied(_ reason: Denial) -> Issuance {
            Issuance(
                state: state,
                grant: nil,
                denial: reason,
                budget: budget(in: state, now: now, calendar: calendar)
            )
        }

        guard isAuthorized else { return denied(.notAuthorized) }
        guard state.rule(id: request.ruleID) != nil else { return denied(.ruleUnresolved) }
        guard request.namesSomethingToLift else { return denied(.ruleUnresolved) }

        let rolled = state.grantLedger.rolled(to: now, in: calendar)
        let policy = state.grantPolicy
        guard rolled.hasBudget(under: policy) else {
            // The ledger still rolls on a denial: the user must see "3 left"
            // after midnight even when the call that discovered it was refused.
            // A roll that changed nothing leaves `updatedAt` alone, so a denied
            // tap does not make the state look newer than it is.
            var working = state
            if rolled != state.grantLedger {
                working.grantLedger = rolled
                working.updatedAt = now
            }
            return Issuance(
                state: working,
                grant: nil,
                denial: .budgetExhausted,
                budget: budget(
                    ledger: rolled, policy: policy, now: now, calendar: calendar
                )
            )
        }

        let grant = Grant(
            id: request.grantID,
            ruleID: request.ruleID,
            scope: request.scope,
            issuedAt: now,
            // Absolute, and clamped by ``GrantPolicy/clampDuration(_:)`` so a
            // corrupt duration can neither produce a grant that has already
            // expired nor one that outlives every deadline that could cancel it.
            expiresAt: policy.expiry(from: now, duration: request.duration),
            source: request.source,
            requestID: request.requestID,
            reason: request.reason
        )

        var working = state
        working.grants.append(grant)
        working.grantLedger = rolled.consuming(1)
        working.updatedAt = now
        working = compacted(working, now: now)

        return Issuance(
            state: working,
            grant: grant,
            denial: nil,
            budget: budget(
                ledger: working.grantLedger, policy: policy, now: now, calendar: calendar
            )
        )
    }

    /// Issues the grant an ``InterventionRequest`` earned, and resolves the
    /// request either way.
    ///
    /// The request is resolved on **every** path, because a request that ends
    /// without a grant *is* the bypass attempt the stats screen counts
    /// (docs/04-product-spec.md V2-5) — there is no second record type for that,
    /// and leaving it open would lose the number Gate is most entitled to show.
    ///
    /// - Parameters:
    ///   - request: as drained from `inbox/` and reconstructed by
    ///     ``interventionRequest(from:)``.
    ///   - duration: `nil` uses ``GrantPolicy/defaultDuration``.
    ///   - maxAge: how long a request stays actionable. A deep link tapped an
    ///     hour later must not resurrect an impulse the user already walked away
    ///     from — the URL is a pointer, not a capability
    ///     (``GateID/interventionURL(ruleID:requestID:)``).
    public static func issue(
        for request: InterventionRequest,
        in state: GateState,
        now: Date,
        calendar: Calendar = .current,
        isAuthorized: Bool = true,
        duration: TimeInterval? = nil,
        reason: String? = nil,
        grantID: UUID = UUID(),
        maxAge: TimeInterval = InterventionRequest.maxAge
    ) -> Issuance {
        func resolving(_ resolution: InterventionRequest.Resolution) -> InterventionRequest {
            var copy = request
            copy.resolution = resolution
            if let reason, copy.reason == nil {
                // Assigning the property bypasses the initializer's truncation,
                // and this string rides into `state.plist` on the ``Grant``.
                copy.reason = String(reason.prefix(Grant.maxReasonLength))
            }
            return copy
        }

        // Already resolved: a dismissed tap, or a request that has already
        // produced a grant. Never re-resolve one. The resolution *is* the
        // accounting — a request that ends without a grant is the bypass attempt
        // the stats screen counts (docs/04-product-spec.md V2-5) — so rewriting
        // it would either erase a bypass attempt or double-count a grant. The
        // request is returned exactly as it arrived.
        guard request.resolution == nil else {
            return Issuance(
                state: state,
                grant: nil,
                denial: .stale,
                budget: budget(in: state, now: now, calendar: calendar),
                request: request
            )
        }

        guard request.isActionable(at: now, maxAge: maxAge) else {
            let denial: Denial = .stale
            return Issuance(
                state: state,
                grant: nil,
                denial: denial,
                budget: budget(in: state, now: now, calendar: calendar),
                request: resolving(.denied(reason: denial))
            )
        }

        // The request names a rule only when the extension could match the token
        // it was handed (``InterventionRequest/ruleID``); a miss is expected
        // rather than exceptional, and routes to recovery.
        guard let ruleID = request.ruleID else {
            let denial: Denial = .ruleUnresolved
            return Issuance(
                state: state,
                grant: nil,
                denial: denial,
                budget: budget(in: state, now: now, calendar: calendar),
                request: resolving(.denied(reason: denial))
            )
        }

        let scope: GrantScope = request.token.map {
            .tokens(ScopedTokens(token: $0, kind: request.tokenKind))
        } ?? .tokens(ScopedTokens())

        let issuance = issue(
            IssueRequest(
                ruleID: ruleID,
                scope: scope,
                duration: duration,
                source: request.action.requiresSubmenuSupport ? .shieldSubmenu : .intervention,
                requestID: request.id,
                reason: reason ?? request.reason,
                grantID: grantID
            ),
            in: state,
            now: now,
            calendar: calendar,
            isAuthorized: isAuthorized
        )

        let resolution: InterventionRequest.Resolution
        if let grant = issuance.grant {
            resolution = .granted(grantID: grant.id)
        } else {
            resolution = .denied(reason: issuance.denial ?? .ruleUnresolved)
        }

        return Issuance(
            state: issuance.state,
            grant: issuance.grant,
            denial: issuance.denial,
            budget: issuance.budget,
            request: resolving(resolution)
        )
    }

    /// Marks a request the user walked away from.
    ///
    /// Backing out is the outcome this product is trying to produce, so it is
    /// recorded as its own resolution and counted as a win rather than an error
    /// (docs/04-product-spec.md V1-7).
    public static func dismiss(_ request: InterventionRequest) -> InterventionRequest {
        var copy = request
        if copy.resolution == nil { copy.resolution = .dismissed }
        return copy
    }

    /// Marks requests nobody came back for.
    public static func expire(
        _ requests: [InterventionRequest],
        now: Date,
        maxAge: TimeInterval = InterventionRequest.maxAge
    ) -> [InterventionRequest] {
        requests.map { request in
            guard request.resolution == nil,
                  !request.isActionable(at: now, maxAge: maxAge) else { return request }
            var copy = request
            copy.resolution = .expired
            return copy
        }
    }

    // MARK: - Expiry

    /// What the passage of time did to the grants in state.
    public struct Sweep: Sendable, Equatable {

        /// State with terminal history pruned and compacted. Persist it.
        public let state: GateState

        /// Grants that ran out since the last sweep.
        ///
        /// **Informational.** Nothing about enforcement depends on noticing the
        /// transition: `ShieldWriter` recomputes the whole shield set from
        /// ``Grant/isActive(at:)`` on every pass, so a missed delta costs a log
        /// line and nothing else. It exists so the app can say "your five
        /// minutes are up" and so the debug screen can show that an expiry the
        /// monitor was supposed to deliver arrived by reconcile instead.
        public let expired: [Grant]

        /// Grants still live at `now`, soonest expiry first.
        public let active: [Grant]

        /// When the next one ends — the moment `Reconciler` must run again, and
        /// the timestamp a `UNCalendarNotificationTrigger` backstop is armed for
        /// (docs/04-product-spec.md V1-10 step 5).
        public let nextExpiry: Date?

        public init(state: GateState, expired: [Grant], active: [Grant], nextExpiry: Date?) {
            self.state = state
            self.expired = expired
            self.active = active
            self.nextExpiry = nextExpiry
        }

        /// Whether anything about the stored grants changed.
        public var didChangeState: Bool { !expired.isEmpty }
    }

    /// Recomputes grant liveness from absolute timestamps.
    ///
    /// Correct whether or not the one-shot expiry activity ever fired, whether
    /// the device was asleep, and whether the app has been open since — which is
    /// the entire reason expiry is a timestamp and not a timer
    /// (docs/04-product-spec.md V1-10).
    ///
    /// - Parameter since: the previous sweep. Defaults to
    ///   ``GateState/lastReconciledAt``; when that is `nil` (a first run, or a
    ///   restored install) ``Sweep/expired`` is empty, because "everything that
    ///   ever expired" is not a delta and is not useful to anybody.
    public static func sweep(
        _ state: GateState,
        now: Date,
        since: Date? = nil,
        calendar: Calendar = .current
    ) -> Sweep {
        let mark = since ?? state.lastReconciledAt

        var expired: [Grant] = []
        if let mark {
            expired = state.grants
                .filter { $0.revokedAt == nil && $0.expiresAt > mark && $0.expiresAt <= now }
                .sorted { $0.expiresAt < $1.expiresAt }
        }

        let active = state.grants
            .active(at: now)
            .sorted { $0.expiresAt < $1.expiresAt }

        return Sweep(
            state: compacted(state, now: now),
            expired: expired,
            active: active,
            nextExpiry: active.first?.expiresAt
        )
    }

    /// How many grants are live for one rule right now.
    public static func activeGrants(
        forRuleID ruleID: UUID,
        in state: GateState,
        now: Date
    ) -> [Grant] {
        state.grants.active(at: now, ruleID: ruleID)
    }

    // MARK: - Compaction

    /// The most terminal (expired or revoked) grants kept as history.
    ///
    /// The arithmetic this defends: `GateState` has an 8 KB budget and the
    /// monitor decodes the whole file on every callback under a 6 MB ceiling
    /// (docs/05-architecture.md, persistence; docs/03-hard-constraints.md #31).
    /// A grant that names a token carries that token's bytes inline — hundreds of
    /// bytes each — so the default budget alone (3/day held for
    /// ``Grant/terminalRetention``, seven days) is twenty-one records and can
    /// approach the entire budget on its own, and a user who raised their daily
    /// limit blows through it.
    public static let maxRetainedGrants = 24

    /// Prunes and shrinks grant history.
    ///
    /// Three passes, in order:
    ///
    /// 1. ``GateState/pruned(now:)`` drops terminal records past their retention.
    /// 2. **Token bytes are dropped from terminal records.** A grant that has
    ///    expired or been revoked can never lift anything again — ``ShieldLift``
    ///    only ever reads ``Grant/isActive(at:)`` grants — so its
    ///    ``ScopedTokens`` are dead weight, and they are the only large field in
    ///    the record. The record itself survives with its times, source, reason
    ///    and ids intact, which is everything the honest "Gate's own data"
    ///    counters can ever show: token bytes cannot be rendered as an app name
    ///    outside `ShieldConfigurationDataSource` anyway
    ///    (docs/02-api-reference.md §10).
    /// 3. The oldest terminal records past ``maxRetainedGrants`` are dropped.
    ///    Live grants are never dropped, at any count.
    ///
    /// Idempotent: compacting twice changes nothing the second time.
    public static func compacted(_ state: GateState, now: Date) -> GateState {
        var working = state.pruned(now: now)

        working.grants = working.grants.map { grant in
            guard !grant.isActive(at: now), case .tokens(let scoped) = grant.scope,
                  !scoped.isEmpty else { return grant }
            var copy = grant
            copy.scope = .tokens(ScopedTokens())
            return copy
        }

        let live = working.grants.filter { $0.isActive(at: now) }
        var terminal = working.grants.filter { !$0.isActive(at: now) }
        if terminal.count > maxRetainedGrants {
            // Newest first by the moment they ended, then by id so two grants
            // that ended in the same instant order identically in every process
            // (see ``GateFingerprint`` on why `hashValue` cannot be used).
            terminal.sort {
                let left = $0.revokedAt ?? $0.expiresAt
                let right = $1.revokedAt ?? $1.expiresAt
                return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            }
            terminal = Array(terminal.prefix(maxRetainedGrants))
        }

        // Stable output order: issue time, then id.
        working.grants = (live + terminal).sorted {
            $0.issuedAt == $1.issuedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.issuedAt < $1.issuedAt
        }
        return working
    }

    // MARK: - Policy

    /// A change to ``GrantPolicy`` — the only part of ``GateState`` that
    /// `Kernel/Engine/Ratchet.swift` deliberately does not model.
    ///
    /// It is modelled here instead, with the same classification rules, because
    /// the alternative is a settings screen writing `state.grantPolicy` directly
    /// and quietly handing the user an unlimited budget.
    public enum PolicyChange: Sendable, Equatable, Hashable {

        /// Grants per day. Lower is a tightening.
        case dailyLimit(Int)

        /// How long a grant lasts. Shorter is a tightening.
        case grantDuration(TimeInterval)

        /// The forced wait on the intervention screen. Longer is a tightening.
        case impulseDelay(TimeInterval)

        /// Whether the intervention makes the user wait the full Lock delay
        /// instead of the impulse delay. Switching it on is a tightening.
        case usesLockDelay(Bool)
    }

    /// Why a policy change was not applied.
    public enum PolicyRefusal: Sendable, Equatable, Hashable, CustomStringConvertible {

        /// The change loosens, and a loosening must go through the Lock
        /// (docs/04-product-spec.md V1-4) — but ``PendingChange/Operation`` has no
        /// case that can carry a `GrantPolicy` edit, so it can be neither applied
        /// nor queued.
        ///
        /// This is exactly the shape of ``Ratchet/Refusal/notRepresentable``, and
        /// the same reasoning applies: applying it immediately would hand the
        /// user a bigger budget the moment they wanted one, which is the one
        /// thing a commitment device may not do. Refusing is the honest answer
        /// until `Operation` grows a `setGrantPolicy` case in the next schema
        /// version — a documented follow-up, not a mystery.
        ///
        /// `cost` is what the wait *would* be, so the UI can say "this would take
        /// 15 minutes" rather than "no".
        case requiresLock(cost: TimeInterval)

        /// The value is already in force.
        case noChange

        public var description: String {
            switch self {
            case .requiresLock(let cost):
                "loosening a grant policy needs the Lock (\(Int(cost))s) and has no queued form in v1"
            case .noChange:
                "no change"
            }
        }
    }

    /// What a policy change did.
    public struct PolicyOutcome: Sendable, Equatable {

        /// The state to persist — unchanged when ``refusal`` is set.
        public let state: GateState

        public let direction: MutationDirection

        /// `nil` when the change was applied.
        public let refusal: PolicyRefusal?

        public init(state: GateState, direction: MutationDirection, refusal: PolicyRefusal?) {
            self.state = state
            self.direction = direction
            self.refusal = refusal
        }

        public var isApplied: Bool { refusal == nil }
    }

    /// Which column of docs/04-product-spec.md V1-4 a policy change falls in.
    ///
    /// "Tighten" means *adds friction*, which for a grant policy is: fewer
    /// grants, shorter grants, longer waits. A change that alters nothing
    /// classifies as ``MutationDirection/tighten`` — the free column — exactly as
    /// `Ratchet` treats a no-op.
    public static func direction(of change: PolicyChange, in state: GateState) -> MutationDirection {
        let policy = state.grantPolicy
        return switch change {
        case .dailyLimit(let limit):
            max(0, limit) <= policy.dailyLimit ? .tighten : .loosen
        case .grantDuration(let duration):
            GrantPolicy.clampDuration(duration) <= policy.defaultDuration ? .tighten : .loosen
        case .impulseDelay(let delay):
            max(0, delay) >= policy.impulseDelay ? .tighten : .loosen
        case .usesLockDelay(let uses):
            // No change and switching the longer wait *on* are both free;
            // switching it off removes friction and is a loosening.
            uses == policy.usesLockDelay ? .tighten : (uses ? .tighten : .loosen)
        }
    }

    /// Applies a policy change, or refuses it.
    ///
    /// Tightenings apply immediately, including when the ratchet switch is off.
    /// That is not an oversight: `Ratchet` defers a tightening only when
    /// ``PendingChange/Operation`` can express it, and applies it immediately
    /// otherwise (see `Ratchet.goesThroughLock`). A `GrantPolicy` edit has no
    /// `Operation`, so it falls in the same "not representable, therefore
    /// immediate" class — and the gap is safe for the same reason it is safe
    /// there: **nothing in it can loosen anything.** The loosening half is
    /// refused outright.
    public static func apply(
        _ change: PolicyChange,
        to state: GateState,
        now: Date
    ) -> PolicyOutcome {
        let direction = direction(of: change, in: state)
        var policy = state.grantPolicy

        switch change {
        case .dailyLimit(let limit):
            policy.dailyLimit = max(0, limit)
        case .grantDuration(let duration):
            policy.defaultDuration = GrantPolicy.clampDuration(duration)
        case .impulseDelay(let delay):
            policy.impulseDelay = max(0, delay.isFinite ? delay : GateLimits.defaultImpulseDelay)
        case .usesLockDelay(let uses):
            policy.usesLockDelay = uses
        }

        guard policy != state.grantPolicy else {
            return PolicyOutcome(state: state, direction: .tighten, refusal: .noChange)
        }
        guard direction == .tighten else {
            return PolicyOutcome(
                state: state,
                direction: direction,
                refusal: .requiresLock(cost: state.lock.delay)
            )
        }

        var working = state
        working.grantPolicy = policy
        working.updatedAt = now
        return PolicyOutcome(state: working, direction: .tighten, refusal: nil)
    }
}

// MARK: - Inbox bridge

// `InboxEvent` lives in `Kernel/Store/InboxStore.swift`, which imports `os`, and
// `os` does not exist on Linux — so naming it here would keep this file out of
// the platform-agnostic SwiftPM test package that
// `Tests/GateKernelTests/GrantEngineTests.swift` runs in
// (docs/05-architecture.md, module layer split; docs/06-build-plan.md step 3.11).
// Fencing on exactly that condition keeps the budget arithmetic, the issuing
// rules and the compaction above testable on Linux, and puts only the transport
// behind the fence.
//
// Everything here is transport: how a shield tap becomes bytes in `inbox/` and
// how those bytes become an ``InterventionRequest`` again. Extensions never
// write `state.plist` (docs/05-architecture.md, single-writer discipline), so
// this is the entire channel between the shield-action extension and the grant
// ledger.

#if canImport(os)

public extension GrantEngine {

    /// The two payload keys Gate's grant flow adds to an ``InboxEvent``.
    ///
    /// `InboxEvent.Key` is `InboxStore`'s vocabulary and is not extended here;
    /// the payload is deliberately open ("a writer in a future version must be
    /// able to add a key without this type rejecting it"), and these two are the
    /// grant flow's own. They are declared in one place so
    /// `Extensions/ShieldAction/GateShieldAction.swift` and the app's foreground
    /// compaction cannot spell them differently — a typo here is a token that
    /// never arrives and a grant that lifts nothing.
    enum InboxKey {

        /// Base64 of ``EncodedToken/bytes``.
        ///
        /// The token has to travel: `ShieldActionDelegate` is handed a bare
        /// `ApplicationToken` with no name and no rule
        /// (docs/02-api-reference.md §10), and without carrying it across, the
        /// app can only offer to unblock the *entire* rule — a broader unblock
        /// than the user asked for, granted because we lost a value we had.
        static let token = "token"

        /// ``TokenKind`` raw value: which of the three `handle(action:for:)`
        /// overloads fired.
        static let tokenKind = "tokenKind"
    }

    /// The payload for a shield tap.
    ///
    /// - Parameter duration: only for the iOS 26.4+ submenu path
    ///   (docs/04-product-spec.md V2-1), where the button itself names the
    ///   length. v1 leaves it `nil` and the policy decides.
    static func inboxPayload(
        action: ShieldActionKind,
        token: EncodedToken?,
        kind: TokenKind,
        duration: TimeInterval? = nil
    ) -> [String: String] {
        var payload: [String: String] = [
            InboxEvent.Key.action: action.rawValue,
            InboxKey.tokenKind: kind.rawValue
        ]
        if let token, !token.isEmpty {
            payload[InboxKey.token] = token.bytes.base64EncodedString()
        }
        if let duration, duration.isFinite, duration > 0 {
            payload[InboxEvent.Key.durationSeconds] = String(Int(duration.rounded()))
        }
        return payload
    }

    /// The event `GateShieldAction` appends when the user taps "Let me in".
    ///
    /// The returned event's ``InboxEvent/id`` is the `requestID` in
    /// ``GateID/interventionURL(ruleID:requestID:)``, which is how the
    /// sub-iOS-26.5 notification fallback finds its way back to this record.
    static func grantRequestEvent(
        id: UUID = UUID(),
        ruleID: UUID?,
        token: EncodedToken?,
        tokenKind: TokenKind,
        action: ShieldActionKind,
        now: Date
    ) -> InboxEvent {
        InboxEvent(
            id: id,
            kind: action == .secondaryButton ? .bypassAttempt : .grantRequest,
            createdAt: now,
            ruleID: ruleID,
            payload: inboxPayload(action: action, token: token, kind: tokenKind)
        )
    }

    /// Reconstructs the request a drained event describes.
    ///
    /// `nil` for events that are not about a shield tap — breadcrumbs, token
    /// expiries and records written by a version of Gate this one does not know.
    ///
    /// Lenient in the same one direction as every other decoder in the kernel: a
    /// missing or corrupt token yields a request with no token, which
    /// ``issue(for:in:now:calendar:isAuthorized:duration:reason:grantID:maxAge:)``
    /// denies as ``InterventionRequest/DenialReason/ruleUnresolved`` and routes to
    /// recovery (docs/04-product-spec.md V1-9). It never yields a request that
    /// lifts more than the user asked for.
    static func interventionRequest(from event: InboxEvent) -> InterventionRequest? {
        let resolution: InterventionRequest.Resolution?
        switch event.kind {
        case .grantRequest, .grantIssued:
            // Still open. A `grantIssued` record (V2-1, never written by v1) is
            // re-issued through the same path as everything else, so the ledger
            // is decremented in exactly one place.
            resolution = nil
        case .bypassAttempt:
            // Already over: the user pressed "Not now", which is the outcome the
            // product is trying to produce.
            resolution = .dismissed
        case .breadcrumb, .tokenExpiry, .unknown:
            return nil
        }

        let token = event[InboxKey.token]
            .flatMap { Data(base64Encoded: $0) }
            .map { EncodedToken(bytes: $0) }

        return InterventionRequest(
            id: event.id,
            ruleID: event.ruleID,
            token: token,
            tokenKind: event[InboxKey.tokenKind].flatMap { TokenKind(rawValue: $0) } ?? .application,
            action: event[InboxEvent.Key.action].flatMap { ShieldActionKind(rawValue: $0) }
                ?? .primaryButton,
            createdAt: event.createdAt,
            resolution: resolution
        )
    }

    /// The duration a submenu event asked for, if it named one.
    static func requestedDuration(in event: InboxEvent) -> TimeInterval? {
        event.integer(InboxEvent.Key.durationSeconds).map { TimeInterval($0) }
    }

    /// Grant records already in `inbox/` that the ledger has not seen yet.
    ///
    /// Pass to ``budget(ledger:policy:now:calendar:inFlight:)`` as `inFlight`.
    /// Without it, `GateShieldAction` reads a ledger that is stale between a
    /// shield tap and the next app launch, and a day's budget can be spent twice
    /// (see ``GrantEngine/Budget``).
    ///
    /// **Counts optimistically against the user**, on purpose: an open
    /// `grantRequest` has not actually spent anything — the app may never issue
    /// it, because the user may walk away, which is a win rather than a spend —
    /// but treating it as spent errs toward friction, and friction is the
    /// product. The over-count lasts until the next foreground compaction
    /// resolves the record, and records older than `maxAge` are ignored because
    /// nobody is coming back for them.
    static func inFlightCount(
        in events: [InboxEvent],
        now: Date,
        maxAge: TimeInterval = InterventionRequest.maxAge
    ) -> Int {
        events.reduce(into: 0) { total, event in
            switch event.kind {
            case .grantRequest, .grantIssued:
                if now.timeIntervalSince(event.createdAt) <= maxAge { total += 1 }
            case .bypassAttempt, .breadcrumb, .tokenExpiry, .unknown:
                break
            }
        }
    }
}

#endif
