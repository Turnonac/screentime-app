//
//  GrantEngineTests.swift
//  GateKernelTests
//
//  docs/06-build-plan.md step 3.11, and docs/04-product-spec.md V1-7 — the
//  intervention, the daily grant budget, and the expiry of a time-boxed unblock.
//
//  WHAT THIS FILE IS DEFENDING
//  Two numbers the user is promised: "three a day" and "five minutes". Both are
//  computed from absolute timestamps and a local calendar, and both have a
//  failure mode that hands out free unblocks rather than crashing:
//
//  * A ledger that rolls when it should not gives an extra day of grants every
//    time the user changes time zone.
//  * A grant whose expiry is recomputed wrongly stays live past its five
//    minutes, and the shield never goes back up.
//
//  So the budget arithmetic is tested against a calendar that is *injected* —
//  including across a DST transition (23- and 25-hour days) and across a
//  timezone change in both directions. `Calendar.current` is never read.
//
//  `GrantEngine`'s inbox bridge is fenced behind `#if canImport(os)` in the
//  source, because `InboxEvent` lives in a file that imports `os`. Everything
//  tested here is above that fence and runs on any toolchain.
//

import Foundation
import Testing

@testable import GateKernel

// MARK: - Fixtures

private func calendar(_ timeZone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func instant(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0,
    in calendar: Calendar
) throws -> Date {
    let components = DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: 0
    )
    return try #require(calendar.date(from: components), "\(year)-\(month)-\(day) \(hour):\(minute)")
}

private let ruleID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let missingRuleID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

private func makeRule(id: UUID = ruleID, now: Date) -> Rule {
    Rule(
        id: id,
        name: "Focus",
        isEnabled: true,
        selection: SelectionRef(
            id: UUID(),
            digest: SelectionDigest(applicationCount: 4, fingerprint: "1111111111111111")
        ),
        sortIndex: 0,
        createdAt: now,
        updatedAt: now
    )
}

private func makeState(
    now: Date,
    rules: [Rule]? = nil,
    grantPolicy: GrantPolicy = .default,
    ledger: GrantLedger? = nil,
    grants: [Grant] = [],
    lastReconciledAt: Date? = nil
) -> GateState {
    GateState(
        schemaVersion: GateState.currentSchemaVersion,
        installID: UUID(),
        createdAt: now,
        updatedAt: now,
        rules: rules ?? [makeRule(now: now)],
        grantPolicy: grantPolicy,
        grants: grants,
        grantLedger: ledger ?? GrantLedger(used: 0, periodStart: now),
        lastReconciledAt: lastReconciledAt
    )
}

private func token(_ byte: UInt8) -> EncodedToken {
    EncodedToken(bytes: Data([byte, byte, byte, byte]))
}

private func request(
    id: UUID = UUID(),
    rule: UUID? = ruleID,
    token value: EncodedToken? = token(0xA1),
    action: ShieldActionKind = .primaryButton,
    createdAt: Date,
    resolution: InterventionRequest.Resolution? = nil
) -> InterventionRequest {
    InterventionRequest(
        id: id,
        ruleID: rule,
        token: value,
        tokenKind: .application,
        action: action,
        createdAt: createdAt,
        resolution: resolution
    )
}

// MARK: - The daily budget

@Suite("GrantEngine — the daily budget (docs/04-product-spec.md V1-7)")
struct GrantBudgetTests {

    private let newYork = calendar("America/New_York")

    @Test("The ledger resets at local midnight, not 24 hours after the last grant")
    func resetsAtLocalMidnight() throws {
        let evening = try instant(2025, 6, 16, 23, 30, in: newYork)
        let spent = GrantLedger(used: 3, periodStart: newYork.startOfDay(for: evening))

        // 23:59 the same day: still spent.
        let lateSameDay = try instant(2025, 6, 16, 23, 59, in: newYork)
        #expect(spent.rolled(to: lateSameDay, in: newYork).used == 3)

        // One minute later it is a new day, and the budget is whole again —
        // even though barely half an hour of grant-time has passed.
        let justAfterMidnight = try instant(2025, 6, 17, 0, 1, in: newYork)
        let rolled = spent.rolled(to: justAfterMidnight, in: newYork)
        #expect(rolled.used == 0)
        #expect(rolled.periodStart == newYork.startOfDay(for: justAfterMidnight))
        #expect(rolled.hasBudget(under: .default))
        #expect(rolled.remaining(under: .default) == GateLimits.defaultDailyGrantBudget)
    }

    @Test("A ledger that has never recorded a day starts fresh")
    func unanchoredLedgerRolls() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let never = GrantLedger()
        #expect(never.periodStart == .distantPast)
        #expect(never.rolled(to: now, in: newYork).periodStart == newYork.startOfDay(for: now))
    }

    @Test("TIMEZONE, east to west: the same local day happening twice does not refill the budget")
    func flyingWestKeepsTheSpend() throws {
        let utc = calendar("UTC")
        let tokyo = calendar("Asia/Tokyo")
        let losAngeles = calendar("America/Los_Angeles")

        // 2025-06-15T20:00Z — already the 16th in Tokyo, still the 15th in LA.
        let moment = try instant(2025, 6, 15, 20, 0, in: utc)
        #expect(tokyo.component(.day, from: moment) == 16)
        #expect(losAngeles.component(.day, from: moment) == 15)

        let spentInTokyo = GrantLedger(used: 3, periodStart: tokyo.startOfDay(for: moment))
        let afterLanding = spentInTokyo.rolled(to: moment, in: losAngeles)

        // LA's "today" starts EARLIER than the recorded period, which is what a
        // clock moving backwards looks like. The honest answer is to carry the
        // count forward and re-anchor, not to hand out a second fresh day.
        #expect(afterLanding.used == 3)
        #expect(afterLanding.periodStart == losAngeles.startOfDay(for: moment))
        #expect(!afterLanding.hasBudget(under: .default))
    }

    @Test("TIMEZONE, west to east: crossing into tomorrow does refill — friction, not a boundary")
    func flyingEastRefills() throws {
        let utc = calendar("UTC")
        let tokyo = calendar("Asia/Tokyo")
        let losAngeles = calendar("America/Los_Angeles")

        let moment = try instant(2025, 6, 15, 20, 0, in: utc)
        let spentInLA = GrantLedger(used: 3, periodStart: losAngeles.startOfDay(for: moment))
        let afterLanding = spentInLA.rolled(to: moment, in: tokyo)

        // Tokyo is genuinely on the next local day, so the budget resets. This
        // is not defensible client-side and the product does not pretend
        // otherwise: under `.individual` authorization the user can revoke
        // everything in four taps anyway (docs/03-hard-constraints.md #13, #14).
        #expect(afterLanding.used == 0)
        #expect(afterLanding.periodStart == tokyo.startOfDay(for: moment))
    }

    @Test("The reset instant is calendar arithmetic, so a DST day is 23 or 25 hours long")
    func nextResetIsDSTSafe() throws {
        let springForward = try instant(2025, 3, 9, 12, 0, in: newYork)
        let fallBack = try instant(2025, 11, 2, 12, 0, in: newYork)
        let ordinary = try instant(2025, 6, 16, 12, 0, in: newYork)

        let springStart = newYork.startOfDay(for: springForward)
        let fallStart = newYork.startOfDay(for: fallBack)
        let ordinaryStart = newYork.startOfDay(for: ordinary)

        let springReset = try #require(GrantEngine.nextReset(after: springForward, in: newYork))
        let fallReset = try #require(GrantEngine.nextReset(after: fallBack, in: newYork))
        let ordinaryReset = try #require(GrantEngine.nextReset(after: ordinary, in: newYork))

        #expect(springReset.timeIntervalSince(springStart) == 23 * 3600)
        #expect(fallReset.timeIntervalSince(fallStart) == 25 * 3600)
        #expect(ordinaryReset.timeIntervalSince(ordinaryStart) == 24 * 3600)

        // `now + 86_400` would reset the budget an hour early twice a year — a
        // bug report nobody would ever diagnose.
        #expect(springReset != springStart.addingTimeInterval(24 * 3600))
    }

    @Test("Budget subtracts what is spent and what is already in flight")
    func budgetAccountsForInFlightGrants() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let state = makeState(now: now, ledger: GrantLedger(used: 1, periodStart: newYork.startOfDay(for: now)))

        let plain = GrantEngine.budget(in: state, now: now, calendar: newYork)
        #expect(plain.limit == 3)
        #expect(plain.spent == 1)
        #expect(plain.remaining == 2)
        #expect(plain.hasBudget)

        // The shield-action extension cannot write `state.plist`, so grants it
        // has queued in `inbox/` are not in the ledger yet. Counting them is the
        // only thing standing between a shield tap and a double spend.
        let withInbox = GrantEngine.budget(in: state, now: now, calendar: newYork, inFlight: 2)
        #expect(withInbox.remaining == 0)
        #expect(withInbox.isExhausted)

        #expect(plain.timeUntilReset(from: now) == (43_200 as TimeInterval))
    }

    @Test("Budget never reports a negative remainder")
    func budgetIsClamped() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let over = GrantEngine.budget(
            ledger: GrantLedger(used: 99, periodStart: newYork.startOfDay(for: now)),
            policy: .default,
            now: now,
            calendar: newYork
        )
        #expect(over.remaining == 0)
        #expect(over.isExhausted)
        #expect(GrantLedger(used: -5).used == 0)
    }
}

// MARK: - Issuing

@Suite("GrantEngine — issuing")
struct GrantIssueTests {

    private let newYork = calendar("America/New_York")

    @Test("A grant is minted, the ledger is spent, and the expiry is absolute")
    func happyPath() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let state = makeState(now: now)

        let issuance = GrantEngine.issue(
            GrantEngine.IssueRequest(
                ruleID: ruleID,
                scope: .tokens(ScopedTokens(token: token(0xA1), kind: .application)),
                source: .intervention,
                reason: "checking the group chat"
            ),
            in: state,
            now: now,
            calendar: newYork
        )

        let grant = try #require(issuance.grant)
        #expect(issuance.isIssued)
        #expect(issuance.denial == nil)
        #expect(grant.ruleID == ruleID)
        #expect(grant.issuedAt == now)
        #expect(grant.expiresAt == now.addingTimeInterval(GateLimits.defaultGrantDuration))
        #expect(grant.duration == GateLimits.defaultGrantDuration)
        #expect(grant.reason == "checking the group chat")
        #expect(grant.isActive(at: now))
        #expect(grant.isActive(at: now.addingTimeInterval(299)))
        #expect(!grant.isActive(at: now.addingTimeInterval(300)), "expiry is exclusive")

        #expect(issuance.state.grantLedger.used == 1)
        #expect(issuance.budget.remaining == 2)
        #expect(issuance.state.grants.map(\.id) == [grant.id])
    }

    @Test("The denial order is authorization, then rule, then scope, then budget")
    func denialOrder() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let exhausted = makeState(
            now: now,
            ledger: GrantLedger(used: 3, periodStart: newYork.startOfDay(for: now))
        )

        func issue(
            rule: UUID = ruleID,
            scope: GrantScope = .entireRule,
            authorized: Bool = true,
            in state: GateState
        ) -> GrantEngine.Issuance {
            GrantEngine.issue(
                GrantEngine.IssueRequest(ruleID: rule, scope: scope, source: .intervention),
                in: state,
                now: now,
                calendar: newYork,
                isAuthorized: authorized
            )
        }

        // 1. Revoked authorization voids every token, so a grant would be a lie.
        //    It outranks every other reason, including an exhausted budget.
        #expect(issue(rule: missingRuleID, authorized: false, in: exhausted).denial == .notAuthorized)
        // 2. No rule, nothing to subtract from -> recovery (V1-9).
        #expect(issue(rule: missingRuleID, in: makeState(now: now)).denial == .ruleUnresolved)
        // 3. A scope naming nothing is the signature of a token the extension
        //    could not carry. Widening the unblock on the strength of a failure
        //    is the one direction this product may not fail in.
        #expect(issue(scope: .tokens(ScopedTokens()), in: makeState(now: now)).denial == .ruleUnresolved)
        #expect(issue(scope: .unrecognized(type: "future"), in: makeState(now: now)).denial == .ruleUnresolved)
        // 4. Out for the day.
        #expect(issue(in: exhausted).denial == .budgetExhausted)
    }

    @Test("A denial leaves no grant and spends nothing")
    func denialsAreInert() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let state = makeState(now: now)
        let issuance = GrantEngine.issue(
            GrantEngine.IssueRequest(ruleID: missingRuleID, scope: .entireRule, source: .intervention),
            in: state,
            now: now,
            calendar: newYork
        )

        #expect(!issuance.isIssued)
        #expect(issuance.state.grants.isEmpty)
        #expect(issuance.state.grantLedger.used == 0)
    }

    @Test("The ledger still rolls on a budget denial, so `3 left` is true after midnight")
    func ledgerRollsEvenOnDenial() throws {
        let yesterday = try instant(2025, 6, 15, 22, 0, in: newYork)
        let today = try instant(2025, 6, 16, 9, 0, in: newYork)

        // Spent out yesterday, and the daily limit has since been lowered to
        // zero, so today's tap is still refused — but the ledger must not keep
        // claiming yesterday's spend.
        let state = makeState(
            now: today,
            grantPolicy: GrantPolicy(dailyLimit: 0),
            ledger: GrantLedger(used: 3, periodStart: newYork.startOfDay(for: yesterday))
        )
        let issuance = GrantEngine.issue(
            GrantEngine.IssueRequest(ruleID: ruleID, scope: .entireRule, source: .intervention),
            in: state,
            now: today,
            calendar: newYork
        )

        #expect(issuance.denial == .budgetExhausted)
        #expect(issuance.state.grantLedger.used == 0)
        #expect(issuance.state.grantLedger.periodStart == newYork.startOfDay(for: today))
    }

    @Test("A requested duration is clamped, never trusted")
    func durationIsClamped() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)

        #expect(GrantPolicy.clampDuration(0) == 1)
        #expect(GrantPolicy.clampDuration(-60) == 1)
        #expect(GrantPolicy.clampDuration(.infinity) == GateLimits.defaultGrantDuration)
        #expect(GrantPolicy.clampDuration(.nan) == GateLimits.defaultGrantDuration)
        #expect(GrantPolicy.clampDuration(10 * 24 * 3600) == GateLimits.maxLockDelay)

        let issuance = GrantEngine.issue(
            GrantEngine.IssueRequest(
                ruleID: ruleID, scope: .entireRule, duration: 10 * 24 * 3600, source: .debug
            ),
            in: makeState(now: now),
            now: now,
            calendar: newYork
        )
        let grant = try #require(issuance.grant)
        #expect(grant.expiresAt == now.addingTimeInterval(GateLimits.maxLockDelay))
    }

    @Test("The intervention wait follows the policy switch, not the caller")
    func interventionWait() {
        let lock = LockPolicy(delay: 3600)
        #expect(GrantPolicy.default.interventionWait(under: lock) == GateLimits.defaultImpulseDelay)
        #expect(GrantPolicy(usesLockDelay: true).interventionWait(under: lock) == 3600)
    }
}

// MARK: - Interventions

@Suite("GrantEngine — the intervention (docs/04-product-spec.md V1-7)")
struct InterventionTests {

    private let newYork = calendar("America/New_York")

    @Test("A completed intervention issues a grant and records the resolution")
    func grantedIntervention() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let tap = request(createdAt: now.addingTimeInterval(-60))

        let issuance = GrantEngine.issue(
            for: tap,
            in: makeState(now: now),
            now: now,
            calendar: newYork,
            reason: "one message"
        )

        let grant = try #require(issuance.grant)
        let resolved = try #require(issuance.request)
        #expect(resolved.resolution == .granted(grantID: grant.id))
        #expect(resolved.resolution?.grantID == grant.id)
        #expect(!resolved.isBypassAttempt)
        #expect(grant.requestID == tap.id)
        #expect(grant.source == .intervention)
        #expect(grant.reason == "one message")
        // Only the token the user actually tapped opens.
        #expect(grant.scope.scopedTokens?.contains(token(0xA1), kind: .application) == true)
        #expect(grant.scope.scopedTokens?.count == 1)
    }

    @Test("A submenu tap is attributed to the submenu, not the intervention screen")
    func submenuSource() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let tap = request(action: .firstSubmenuItem, createdAt: now)

        #expect(ShieldActionKind.firstSubmenuItem.requiresSubmenuSupport)
        #expect(!ShieldActionKind.primaryButton.requiresSubmenuSupport)

        let issuance = GrantEngine.issue(for: tap, in: makeState(now: now), now: now, calendar: newYork)
        #expect(issuance.grant?.source == .shieldSubmenu)
    }

    @Test("A request that aged out is stale, and IS a bypass attempt")
    func staleRequest() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let old = request(createdAt: now.addingTimeInterval(-(InterventionRequest.maxAge + 60)))

        #expect(!old.isActionable(at: now))
        let issuance = GrantEngine.issue(for: old, in: makeState(now: now), now: now, calendar: newYork)

        #expect(issuance.denial == .stale)
        #expect(issuance.grant == nil)
        let resolved = try #require(issuance.request)
        #expect(resolved.resolution == .denied(reason: .stale))
        // A request that ends without a grant IS the bypass-attempt record;
        // there is no second type for it.
        #expect(resolved.isBypassAttempt)
        // A deep link tapped an hour later must not resurrect an impulse the
        // user already walked away from.
        #expect(issuance.state.grants.isEmpty)
    }

    @Test("An already-resolved request is never re-resolved")
    func alreadyResolved() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let dismissed = request(createdAt: now, resolution: .dismissed)

        let issuance = GrantEngine.issue(for: dismissed, in: makeState(now: now), now: now, calendar: newYork)
        #expect(issuance.denial == .stale)
        #expect(issuance.request == dismissed, "rewriting it would erase a bypass attempt or double-count a grant")
    }

    @Test("A token the extension could not match routes to recovery")
    func unresolvedToken() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)

        // `ruleID == nil` is EXPECTED, not exceptional: a token handed to the
        // extension can fail `==` against the byte-identical stored one
        // (docs/03-hard-constraints.md #36).
        let unmatched = request(rule: nil, createdAt: now)
        let issuance = GrantEngine.issue(for: unmatched, in: makeState(now: now), now: now, calendar: newYork)
        #expect(issuance.denial == .ruleUnresolved)
        #expect(issuance.request?.resolution == .denied(reason: .ruleUnresolved))

        // A request whose token did not survive the trip does NOT widen into
        // `entireRule`.
        let tokenless = request(token: nil, createdAt: now)
        let widened = GrantEngine.issue(for: tokenless, in: makeState(now: now), now: now, calendar: newYork)
        #expect(widened.denial == .ruleUnresolved)
        #expect(widened.grant == nil)
    }

    @Test("Backing out is recorded as its own outcome, and counted as a win")
    func dismissal() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let dismissed = GrantEngine.dismiss(request(createdAt: now))

        #expect(dismissed.resolution == .dismissed)
        #expect(dismissed.isBypassAttempt)
        #expect(!dismissed.isActionable(at: now))
    }

    @Test("Requests nobody came back for expire in bulk")
    func expiry() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let fresh = request(createdAt: now.addingTimeInterval(-60))
        let abandoned = request(createdAt: now.addingTimeInterval(-3600))
        let settled = request(createdAt: now.addingTimeInterval(-3600), resolution: .dismissed)

        let swept = GrantEngine.expire([fresh, abandoned, settled], now: now)
        #expect(swept[0].resolution == nil)
        #expect(swept[1].resolution == .expired)
        #expect(swept[2].resolution == .dismissed, "an existing resolution is never overwritten")
    }

    @Test("An unrecognized resolution from a newer build still reads as a bypass attempt")
    func unrecognizedResolution() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let alien = request(createdAt: now, resolution: .unrecognized(type: "escalated"))
        #expect(alien.resolution?.grantID == nil)
        #expect(alien.isBypassAttempt)
    }
}

// MARK: - Expiry and compaction

@Suite("GrantEngine — sweeping and compacting")
struct GrantSweepTests {

    private let newYork = calendar("America/New_York")

    private func grant(
        rule: UUID = ruleID,
        issuedAt: Date,
        expiresAt: Date,
        scope: GrantScope = .entireRule,
        revokedAt: Date? = nil
    ) -> Grant {
        Grant(
            id: UUID(),
            ruleID: rule,
            scope: scope,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            source: .intervention,
            revokedAt: revokedAt
        )
    }

    @Test("Liveness is recomputed from timestamps, whether or not any timer fired")
    func livenessFromTimestamps() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let live = grant(issuedAt: now, expiresAt: now.addingTimeInterval(300))
        let done = grant(issuedAt: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(-300))
        let revoked = grant(
            issuedAt: now, expiresAt: now.addingTimeInterval(300), revokedAt: now.addingTimeInterval(-1)
        )

        let state = makeState(now: now, grants: [live, done, revoked], lastReconciledAt: now.addingTimeInterval(-900))
        let sweep = GrantEngine.sweep(state, now: now, calendar: newYork)

        #expect(sweep.active.map(\.id) == [live.id])
        #expect(sweep.expired.map(\.id) == [done.id])
        #expect(sweep.nextExpiry == live.expiresAt)
        #expect(sweep.didChangeState)
        #expect(live.remaining(at: now) == 300)
        #expect(done.remaining(at: now) == 0)
    }

    @Test("A grant whose scope this build cannot read fails CLOSED")
    func unrecognizedScopeIsNotLive() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let alien = grant(
            issuedAt: now, expiresAt: now.addingTimeInterval(3600), scope: .unrecognized(type: "future")
        )
        // Lifting a shield for a reason we cannot state is the one thing this
        // must never do.
        #expect(!alien.isActive(at: now))
        #expect(!alien.scope.isRecognized)
    }

    @Test("With no previous sweep there is no delta to report")
    func firstSweepReportsNoDelta() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let done = grant(issuedAt: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(-300))
        let sweep = GrantEngine.sweep(makeState(now: now, grants: [done]), now: now, calendar: newYork)

        #expect(sweep.expired.isEmpty, "`everything that ever expired` is not a delta")
        #expect(!sweep.didChangeState)
    }

    @Test("Active grants are ordered soonest-expiry-first, which is what the next backstop needs")
    func activeGrantsAreOrdered() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let later = grant(issuedAt: now, expiresAt: now.addingTimeInterval(900))
        let sooner = grant(issuedAt: now, expiresAt: now.addingTimeInterval(300))

        let sweep = GrantEngine.sweep(makeState(now: now, grants: [later, sooner]), now: now, calendar: newYork)
        #expect(sweep.active.map(\.id) == [sooner.id, later.id])
        #expect(sweep.nextExpiry == sooner.expiresAt)
        #expect(GrantEngine.activeGrants(forRuleID: ruleID, in: sweep.state, now: now).count == 2)
        #expect(GrantEngine.activeGrants(forRuleID: missingRuleID, in: sweep.state, now: now).isEmpty)
    }

    @Test("Compaction strips token bytes from dead grants and keeps them on live ones")
    func compactionStripsDeadTokens() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let scoped = GrantScope.tokens(ScopedTokens(token: token(0xB2), kind: .application))
        let live = grant(issuedAt: now, expiresAt: now.addingTimeInterval(300), scope: scoped)
        let dead = grant(
            issuedAt: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(-300), scope: scoped
        )

        let compacted = GrantEngine.compacted(makeState(now: now, grants: [live, dead]), now: now)
        let keptLive = try #require(compacted.grants.first { $0.id == live.id })
        let keptDead = try #require(compacted.grants.first { $0.id == dead.id })

        #expect(keptLive.scope == scoped, "a live grant still has to lift something")
        #expect(keptDead.scope == .tokens(ScopedTokens()))
        // The record survives with its times, source and ids — everything the
        // honest counters can ever show.
        #expect(keptDead.issuedAt == dead.issuedAt)
        #expect(keptDead.source == dead.source)
    }

    @Test("History is capped, newest kept, and live grants are never dropped at any count")
    func compactionCapsHistory() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)

        // 30 terminal grants, all inside the retention window so pruning does
        // not do the work for us.
        let terminal = (1...30).map { minutes in
            grant(
                issuedAt: now.addingTimeInterval(TimeInterval(-minutes) * 60 - 300),
                expiresAt: now.addingTimeInterval(TimeInterval(-minutes) * 60)
            )
        }
        let live = (1...3).map { minutes in
            grant(issuedAt: now, expiresAt: now.addingTimeInterval(TimeInterval(minutes) * 60))
        }

        let compacted = GrantEngine.compacted(makeState(now: now, grants: terminal + live), now: now)
        let keptTerminal = compacted.grants.filter { !$0.isActive(at: now) }

        #expect(keptTerminal.count == GrantEngine.maxRetainedGrants)
        #expect(compacted.grants.filter({ $0.isActive(at: now) }).count == 3)
        // Newest first by the moment they ended: the 24 most recent survive.
        #expect(Set(keptTerminal.map(\.id)) == Set(terminal.prefix(24).map(\.id)))

        // Idempotent: compacting twice changes nothing the second time.
        #expect(GrantEngine.compacted(compacted, now: now) == compacted)
    }

    @Test("Grants past their retention are reclaimed entirely")
    func retentionPruning() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let ancient = grant(
            issuedAt: now.addingTimeInterval(-Grant.terminalRetention - 7200),
            expiresAt: now.addingTimeInterval(-Grant.terminalRetention - 3600)
        )
        let recent = grant(issuedAt: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(-300))

        #expect(ancient.isExpired(at: now))
        #expect(!recent.isExpired(at: now))

        let compacted = GrantEngine.compacted(makeState(now: now, grants: [ancient, recent]), now: now)
        #expect(compacted.grants.map(\.id) == [recent.id])
    }

    @Test("Revoking is idempotent and ends the grant immediately")
    func revocation() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let live = grant(issuedAt: now, expiresAt: now.addingTimeInterval(300))

        let revoked = live.revoked(at: now.addingTimeInterval(60))
        #expect(revoked.revokedAt == now.addingTimeInterval(60))
        #expect(!revoked.isActive(at: now.addingTimeInterval(61)))
        #expect(revoked.revoked(at: now.addingTimeInterval(120)) == revoked)
    }

    @Test("Collection helpers agree with the engine")
    func collectionHelpers() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let mine = grant(issuedAt: now, expiresAt: now.addingTimeInterval(300))
        let theirs = grant(rule: missingRuleID, issuedAt: now, expiresAt: now.addingTimeInterval(600))
        let dead = grant(issuedAt: now.addingTimeInterval(-600), expiresAt: now.addingTimeInterval(-1))
        let all = [mine, theirs, dead]

        #expect(all.active(at: now).map(\.id) == [mine.id, theirs.id])
        #expect(all.active(at: now, ruleID: ruleID).map(\.id) == [mine.id])
        #expect(all.nextExpiry(after: now) == mine.expiresAt)
        #expect(all.nextExpiry(after: now.addingTimeInterval(10_000)) == nil)
    }
}

// MARK: - Grant policy

@Suite("GrantEngine — policy changes are ratcheted too")
struct GrantPolicyTests {

    private let newYork = calendar("America/New_York")

    @Test("Fewer grants, shorter grants and longer waits are all tightenings")
    func tighteningDirections() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let state = makeState(now: now)

        #expect(GrantEngine.direction(of: .dailyLimit(1), in: state) == .tighten)
        #expect(GrantEngine.direction(of: .grantDuration(60), in: state) == .tighten)
        #expect(GrantEngine.direction(of: .impulseDelay(120), in: state) == .tighten)
        #expect(GrantEngine.direction(of: .usesLockDelay(true), in: state) == .tighten)
        // A change that alters nothing is free, exactly as `Ratchet` treats a no-op.
        #expect(GrantEngine.direction(of: .dailyLimit(GateLimits.defaultDailyGrantBudget), in: state) == .tighten)
    }

    @Test("More grants, longer grants and shorter waits are loosenings")
    func looseningDirections() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let state = makeState(now: now)

        #expect(GrantEngine.direction(of: .dailyLimit(10), in: state) == .loosen)
        #expect(GrantEngine.direction(of: .grantDuration(3600), in: state) == .loosen)
        #expect(GrantEngine.direction(of: .impulseDelay(0), in: state) == .loosen)
        #expect(
            GrantEngine.direction(
                of: .usesLockDelay(false), in: makeState(now: now, grantPolicy: GrantPolicy(usesLockDelay: true))
            ) == .loosen
        )
    }

    @Test("A tightening applies immediately; a loosening is refused, never applied for free")
    func applyPolicy() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let state = makeState(now: now)

        let tightened = GrantEngine.apply(.dailyLimit(1), to: state, now: now)
        #expect(tightened.isApplied)
        #expect(tightened.direction == .tighten)
        #expect(tightened.state.grantPolicy.dailyLimit == 1)
        #expect(tightened.state.updatedAt == now)

        // `PendingChange.Operation` has no case that can carry a GrantPolicy
        // edit in v1, so the loosening half is refused outright rather than
        // silently handing the user an unlimited budget.
        let loosened = GrantEngine.apply(.dailyLimit(10), to: state, now: now)
        #expect(!loosened.isApplied)
        #expect(loosened.refusal == .requiresLock(cost: state.lock.delay))
        #expect(loosened.state == state)

        let unchanged = GrantEngine.apply(.dailyLimit(GateLimits.defaultDailyGrantBudget), to: state, now: now)
        #expect(unchanged.refusal == .noChange)
        #expect(unchanged.state == state)
    }

    @Test("A policy tightening applies even with the ratchet switch off")
    func tighteningIgnoresTheRatchetSwitch() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        var state = makeState(now: now)
        state.lock.isRatchetEnabled = false

        // Not an oversight: the gap is safe for the same reason it is safe in
        // `Ratchet` — nothing in it can loosen anything.
        let outcome = GrantEngine.apply(.impulseDelay(300), to: state, now: now)
        #expect(outcome.isApplied)
        #expect(outcome.state.grantPolicy.impulseDelay == 300)
    }

    @Test("Policy values are clamped on the way in")
    func policyClamping() {
        #expect(GrantPolicy(dailyLimit: -4).dailyLimit == 0)
        #expect(GrantPolicy(impulseDelay: -30).impulseDelay == 0)
        #expect(GrantPolicy(impulseDelay: .nan).impulseDelay == GateLimits.defaultImpulseDelay)
        #expect(GrantPolicy(defaultDuration: 0).defaultDuration == 1)
        #expect(GrantPolicy.default.dailyLimit == GateLimits.defaultDailyGrantBudget)
        #expect(GrantPolicy.default.defaultDuration == GateLimits.defaultGrantDuration)
    }

    @Test("ScopedTokens answers membership on fingerprints, never on identity")
    func scopedTokens() {
        let scoped = ScopedTokens(
            applications: [token(0xC1), token(0xC2)],
            webDomains: [token(0xD1)]
        )
        #expect(scoped.count == 3)
        #expect(!scoped.isEmpty)
        #expect(scoped.tokens(in: .applications).count == 2)
        #expect(scoped.tokens(in: .categories).isEmpty)

        // A token handed back by the system can fail `==` against the
        // byte-identical stored one, so every lookup is written with a miss path.
        #expect(scoped.contains(EncodedToken(bytes: token(0xC1).bytes), kind: .application))
        #expect(!scoped.contains(token(0xC1), kind: .webDomain))
        #expect(ScopedTokens().isEmpty)

        #expect(TokenKind.application.collection == .applications)
        #expect(TokenKind.category.collection == .categories)
        #expect(TokenKind.webDomain.collection == .webDomains)
    }
}

// MARK: - The inbox bridge

#if canImport(os)
/// Fenced exactly as the source is: `InboxEvent` lives in a file that imports
/// `os`, so `GrantEngine`'s inbox bridge and `Reconciler.fold` are both behind
/// `#if canImport(os)`. Nothing here touches the filesystem — `fold` is pure and
/// takes the events as a value, which is the whole reason it is testable at all
/// while `Reconciler.reconcile` (fenced on `canImport(ManagedSettings)`) is not.
@Suite("GrantEngine — the inbox bridge (docs/04-product-spec.md V2-1)")
struct InboxBridgeTests {

    private let utc = calendar("UTC")

    private func submenuEvent(
        id: UUID = UUID(),
        rule: UUID? = ruleID,
        duration: TimeInterval,
        at createdAt: Date
    ) -> InboxEvent {
        InboxEvent(
            id: id,
            kind: .grantIssued,
            createdAt: createdAt,
            ruleID: rule,
            payload: GrantEngine.inboxPayload(
                action: .thirdSubmenuItem,
                token: token(0xA1),
                kind: .application,
                duration: duration
            )
        )
    }

    @Test("A pending submenu grant folds into a real grant, and the ledger pays for it once")
    func submenuGrantFolds() throws {
        let now = try instant(2026, 5, 14, 9, 0, in: utc)
        let state = makeState(now: now)
        let event = submenuEvent(duration: 15 * 60, at: now)

        let folded = Reconciler.fold([event], into: state, now: now, calendar: utc)
        let grant = try #require(folded.issued.first)

        // `grantID: request.id`: `GateShieldAction` already armed a one-shot
        // expiry activity named for this id. Minting a fresh UUID here would
        // orphan that timer.
        #expect(grant.id == event.id)
        #expect(grant.requestID == event.id)
        #expect(grant.ruleID == ruleID)
        #expect(grant.source == .shieldSubmenu, "the button named the duration")
        #expect(grant.expiresAt == now.addingTimeInterval(15 * 60))
        #expect(folded.state.grantLedger.used == 1)
    }

    @Test("Re-folding the same record is a no-op once the grant is in state")
    func submenuGrantIsIdempotent() throws {
        // This is what makes `ReconcileOptions.foldsPendingGrants` safe. The
        // monitor folds the record read-only on every pass until the app drains
        // it, so the *second* fold — against a state that already carries the
        // grant — must not spend the budget again.
        let now = try instant(2026, 5, 14, 9, 0, in: utc)
        let event = submenuEvent(duration: 15 * 60, at: now)

        let first = Reconciler.fold([event], into: makeState(now: now), now: now, calendar: utc)
        let second = Reconciler.fold([event], into: first.state, now: now, calendar: utc)

        #expect(second.issued.isEmpty)
        #expect(second.duplicates == 1)
        #expect(second.state.grantLedger.used == 1, "billed once, however many passes see it")
        #expect(second.state.grants.count == 1)

        // Two copies of the same record inside one fold are the redelivery case
        // and collapse the same way.
        let twice = Reconciler.fold([event, event], into: makeState(now: now), now: now, calendar: utc)
        #expect(twice.issued.count == 1)
        #expect(twice.duplicates == 1)
    }

    @Test("A pending grant older than InterventionRequest.maxAge is refused as stale")
    func staleSubmenuGrantIsDenied() throws {
        // KNOWN GAP, pinned here so it cannot change silently: `fold` issues
        // through the default `maxAge` of 15 minutes, but the submenu's third
        // item asks for an hour. A record the app does not reach inside 15
        // minutes is denied — and the one-shot expiry activity armed for it
        // still fires an hour later. Widening `maxAge` here is NOT the fix on its
        // own: `GrantEngine.issue` dates the grant from `now` rather than from
        // the tap, so a 45-minute-old hour-long request would expire 1h45m after
        // the tap. See Docs/REVIEW-NOTES.md.
        let now = try instant(2026, 5, 14, 9, 0, in: utc)
        let tapped = now.addingTimeInterval(-(InterventionRequest.maxAge + 60))
        let event = submenuEvent(duration: 60 * 60, at: tapped)

        let folded = Reconciler.fold([event], into: makeState(now: now), now: now, calendar: utc)
        #expect(folded.issued.isEmpty)
        #expect(folded.denials[.stale] == 1)
        #expect(folded.state.grantLedger.used == 0, "a refusal spends nothing")

        // Inside the window the same record is honoured.
        let fresh = submenuEvent(duration: 60 * 60, at: now.addingTimeInterval(-60))
        let ok = Reconciler.fold([fresh], into: makeState(now: now), now: now, calendar: utc)
        #expect(ok.issued.count == 1)
    }

    @Test("A grant request is reported, never issued — only the app's screen can issue one")
    func grantRequestIsNotAGrant() throws {
        // The reason `foldsPendingGrants` filters to `.grantIssued`: a
        // `.grantRequest` is a shield tap the user has not paid for yet.
        let now = try instant(2026, 5, 14, 9, 0, in: utc)
        let request = InboxEvent(
            kind: .grantRequest,
            createdAt: now,
            ruleID: ruleID,
            payload: GrantEngine.inboxPayload(
                action: .primaryButton, token: token(0xA1), kind: .application
            )
        )

        let folded = Reconciler.fold([request], into: makeState(now: now), now: now, calendar: utc)
        #expect(folded.issued.isEmpty)
        #expect(folded.requests.count == 1)
        #expect(folded.requests[0].resolution == nil, "open: the app must route it to V1-7")
        #expect(folded.state.grantLedger.used == 0)
    }

    @Test("In-flight records close the double-spend window between a tap and a foreground")
    func inFlightCounting() throws {
        let now = try instant(2026, 5, 14, 9, 0, in: utc)
        let events = [
            submenuEvent(duration: 60, at: now),                                    // counted
            InboxEvent(kind: .grantRequest, createdAt: now, ruleID: ruleID),        // counted
            InboxEvent(kind: .bypassAttempt, createdAt: now, ruleID: ruleID),       // already over
            InboxEvent(kind: .breadcrumb, createdAt: now),                          // not a tap
            submenuEvent(duration: 60, at: now.addingTimeInterval(-3_600))          // nobody is coming back
        ]

        #expect(GrantEngine.inFlightCount(in: events, now: now) == 2)

        // And the budget shrinks by exactly that, which is what stops a day's
        // grants being spent twice from a `state.plist` the extension cannot
        // update.
        let ledger = GrantLedger(used: 0, periodStart: now)
        let budget = GrantEngine.budget(
            ledger: ledger, policy: .default, now: now, calendar: utc, inFlight: 2
        )
        #expect(budget.remaining == GateLimits.defaultDailyGrantBudget - 2)
    }
}
#endif
