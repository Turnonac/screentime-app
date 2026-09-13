//
//  Ratchet.swift
//  GateKernel
//
//  The asymmetric-cost settings model — the entire differentiator
//  (docs/04-product-spec.md V1-4, ported whole from Andoff).
//
//  "Changing your mind costs time." Every state change the UI can make is a
//  ``Mutation``. ``Ratchet/direction(of:in:)`` classifies it against the TIGHTEN
//  and LOOSEN lists in V1-4; ``Ratchet/apply(_:to:now:)`` applies tightenings
//  synchronously and turns loosenings into a ``PendingChange`` parked behind the
//  Lock.
//
//  Build plan: docs/06-build-plan.md step 3.5.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  PROPERTIES THIS FILE GUARANTEES
//
//  1. **Total.** No function here can throw, trap or fail. An unknown rule id, a
//     malformed schedule, a selection over the 50-token cap: every one of them
//     returns the state *unchanged* plus a typed ``Ratchet/Refusal``. A settings
//     screen must never be able to wedge the Lock.
//  2. **Pure.** No I/O, no `Date()`, no `Calendar.current`, no randomness beyond
//     the `UUID` a new ``PendingChange`` needs. `now` is always injected, so
//     `Tests/GateKernelTests/RatchetTests.swift` can hit every branch
//     deterministically (docs/06-build-plan.md step 3.11).
//  3. **Non-exploitable.** Wherever the spec is ambiguous this file takes the
//     reading that cannot be used to loosen instantly, and says so in a comment
//     at the site. Search this file for "EXPLOIT" to find all of them.
//  4. **Foundation only.** No `ManagedSettings`, no `DeviceActivity`, no
//     `FamilyControls`, no `os`. The Ratchet runs in the app, but `GateKernel` is
//     linked by the 6 MB monitor extension (docs/03-hard-constraints.md #31) and
//     nothing here may drag a framework into it.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHAT THIS FILE DOES NOT OWN
//
//  - **Tokens.** `ApplicationToken` and friends are opaque and live outside the
//    kernel (docs/03-hard-constraints.md #25). The Ratchet therefore cannot
//    diff two selections itself; the caller does the set algebra where the real
//    `FamilyActivitySelection` values are, and hands the answer in as a
//    ``BreadthChange``. See ``Mutation/setSelection(ruleID:selection:change:)``.
//  - **Selection blobs.** Staging and re-parenting happen in `SelectionTable`
//    (`selections.plist`). The Ratchet reports what the caller must do via
//    ``Ratchet/SideEffects``; it never touches the blob.
//  - **When** a ripe change is applied. `Kernel/Engine/Reconciler.swift` owns the
//    schedule; this file owns *what happens* when one ripens
//    (``Ratchet/releaseRipe(in:now:)``).
//  - **Grant issuance.** A grant is a time-boxed subtraction with its own budget
//    and its own impulse delay (docs/04-product-spec.md V1-7); it is
//    `Kernel/Engine/GrantEngine.swift`'s, not the Lock's. Only *revoking* a grant
//    appears here, because ending one early is a tightening.
//

import Foundation

// MARK: - MutationDirection

/// Which way a ``Mutation`` moves the amount of enforcement in force.
///
/// Exactly the two columns of docs/04-product-spec.md V1-4, and deliberately no
/// third: "tighten" there means *free and immediate*, so a cosmetic change with
/// no effect on enforcement at all (a rename, a reorder) classifies as
/// ``tighten`` too. ``Ratchet/Rationale`` is what tells those apart for UI copy,
/// so a third `neutral` case would buy nothing and would give every `switch` in
/// the app a branch it could forget.
public enum MutationDirection: String, Sendable, Hashable, CaseIterable, Codable {

    /// Adds enforcement, or changes nothing. Applies synchronously, no Lock —
    /// unless the user has switched the ratchet off, which is the whole point of
    /// that switch. See ``Ratchet/Assessment/goesThroughLock``.
    case tighten

    /// Removes enforcement. Queued behind the Lock as a ``PendingChange``,
    /// always, in every configuration.
    case loosen

    /// Whether the Lock must release this before it takes effect.
    ///
    /// Note this is a property of the *direction*, not of a specific mutation:
    /// with the ratchet switched off a tightening is queued too. Ask
    /// ``Ratchet/Assessment/goesThroughLock`` about a concrete mutation.
    public var alwaysRequiresLock: Bool { self == .loosen }
}

// MARK: - BreadthChange

/// How the *breadth* of something changed — a token selection, a schedule
/// window — in pure set terms, before any mode-dependent reading of what
/// "broader" means for enforcement.
///
/// Breadth is not direction. Widening a blocklist tightens enforcement; widening
/// an allowlist loosens it. ``Ratchet`` applies that translation; this type is
/// only the set relation.
public enum BreadthChange: String, Sendable, Hashable, CaseIterable, Codable {

    /// The new value covers exactly what the old one did.
    case unchanged

    /// The new value is a strict superset of the old one.
    case widened

    /// The new value is a strict subset of the old one.
    case narrowed

    /// Neither a superset nor a subset — or the caller could not tell.
    ///
    /// **Treated as a loosening in every mode.** A reshape always removes
    /// *something*, and "could not tell" must never resolve to "free". This is
    /// also the value a caller passes when the old selection cannot be read back
    /// — stale tokens are a documented iOS failure mode
    /// (docs/03-hard-constraints.md #36), and a stale token is exactly when an
    /// exploit would be cheapest.
    case reshaped
}

// MARK: - ReleasePaths

/// The ways a queued ``PendingChange`` can be released.
///
/// Modelled as a set rather than a second deadline: under ``LockKind/both`` the
/// change ripens on elapsed time *or* on the partner passphrase, whichever comes
/// first, and those are not two clocks — one of them is not a clock at all.
/// Under ``LockKind/password`` there is no clock, which is why
/// ``LockPolicy/earliestApplyDate(from:)`` returns `nil` there and why
/// ``PendingChange/isRipe(at:)`` answers "never".
public struct ReleasePaths: OptionSet, Sendable, Hashable {

    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `now >= earliestApplyAt`.
    public static let elapsedTime = ReleasePaths(rawValue: 1 << 0)

    /// A correct partner passphrase, verified against ``LockPolicy/password``.
    public static let password = ReleasePaths(rawValue: 1 << 1)

    /// What `lock` actually offers.
    public static func available(under lock: LockPolicy) -> ReleasePaths {
        var paths: ReleasePaths = []
        if lock.kind.acceptsDelay { paths.insert(.elapsedTime) }
        if lock.kind.acceptsPassword, lock.password != nil { paths.insert(.password) }
        return paths
    }

    /// True when the UI can honestly show a countdown.
    public var hasCountdown: Bool { contains(.elapsedTime) }
}

// MARK: - Mutation

/// Every state change the UI can make, as one closed enum.
///
/// **Exhaustive by construction.** `App/` must route *every* write to `GateState`
/// through ``Ratchet/apply(_:to:now:)`` — that single funnel is what makes the
/// Lock un-bypassable by a screen that forgot to ask. If a screen needs a change
/// that is not a case here, the case is missing and must be added, along with its
/// row in the V1-4 table and its ``PendingChange/Operation`` projection if it can
/// ever be a loosening.
///
/// Three things are deliberately **not** here:
/// - **Grant issuance**, which has its own budget and its own impulse delay
///   (docs/04-product-spec.md V1-7) and belongs to `GrantEngine`.
/// - **Reconciliation bookkeeping** (`lastReconciledAt`, grant expiry), which is
///   time passing rather than the user changing their mind.
/// - **`GrantPolicy` edits**, which have no ``PendingChange/Operation`` to be
///   queued as. See the note on ``Ratchet/Refusal/notRepresentable``.
public enum Mutation: Sendable, Equatable, Hashable {

    // MARK: Rules (docs/04-product-spec.md V1-2)

    /// Add a rule. Tightening: a new rule can only ever add enforcement.
    ///
    /// Refused past ``GateLimits/maxRules`` — 8 in v1, chosen so one named store
    /// and one repeating activity per rule stay inside the 50-store and
    /// 20-activity ceilings.
    case createRule(Rule)

    /// Remove a rule, its store, its activity and its staged selections.
    /// Loosening (V1-4).
    case deleteRule(ruleID: UUID)

    /// Rename. Cosmetic: the name is the shield `title`
    /// (docs/04-product-spec.md V1-6) and nothing else.
    case renameRule(ruleID: UUID, name: String)

    /// Reorder the home screen. Cosmetic.
    case reorderRules(orderedIDs: [UUID])

    /// Turn a rule on (tighten) or off (loosen). V1-4, both lists.
    case setRuleEnabled(ruleID: UUID, enabled: Bool)

    /// Blocklist ⇄ allowlist. `blocklist -> allowlist` tightens — "block
    /// everything except these" is strictly broader than "block these" over the
    /// same token set — and `allowlist -> blocklist` loosens (V1-4).
    case setRuleMode(ruleID: UUID, mode: RuleMode)

    /// Change which apps a rule covers.
    ///
    /// - Parameters:
    ///   - selection: the *new* ``SelectionRef``. For a loosening the caller must
    ///     have staged its blob under ``SelectionOwner/pendingChange(_:)`` using
    ///     the id reported in ``Ratchet/SideEffects/stageSelections``; the
    ///     currently-enforced blob stays owned by the rule until the Lock
    ///     releases, so applying is a re-parent and cannot half-succeed. `nil`
    ///     clears the selection, which stops the rule being enforced at all and
    ///     is therefore a loosening in **both** modes.
    ///   - change: the set relation between the old and new token sets,
    ///     **computed by the caller**. The kernel never sees a token
    ///     (docs/03-hard-constraints.md #25), so it cannot derive this. Pass
    ///     ``BreadthChange/reshaped`` whenever the answer is not certain.
    case setSelection(ruleID: UUID, selection: SelectionRef?, change: BreadthChange)

    /// Re-pick a rule's apps after iOS reissued its identifiers
    /// (docs/04-product-spec.md V1-9).
    ///
    /// **Always a free tightening**, regardless of what it does to breadth. V1-9
    /// is explicit: *"Reselecting is a tightening — never gate recovery behind
    /// the lock, or you will trap users out of their own blocks."* See the
    /// EXPLOIT note on ``Ratchet/direction(of:in:)`` for the bound on what this
    /// can be abused for, and why the UI must only offer it from the recovery
    /// screen.
    case reselectSelection(ruleID: UUID, selection: SelectionRef)

    /// Set, change or remove a rule's window (docs/04-product-spec.md V1-5).
    ///
    /// `nil` means *no* schedule, i.e. the rule is unconditional whenever it is
    /// on — which is the **broadest** setting, so removing a window tightens and
    /// adding one loosens. Direction between two windows is decided by
    /// ``WeeklyCoverage``, not by comparing durations: a window that gains days
    /// and loses hours is a reshape, and a reshape loosens.
    case setSchedule(ruleID: UUID, schedule: RuleSchedule?)

    // MARK: The Lock (docs/04-product-spec.md V1-3)

    /// Change the wait every loosening costs.
    ///
    /// **The asymmetry that defines the product.** Increasing applies
    /// immediately. Decreasing costs `oldDelay - newDelay` — *not* the full
    /// delay. See ``Ratchet/cost(of:in:)``.
    case setLockDelay(seconds: TimeInterval)

    /// Change the lock type. **Always a loosening** (V1-3, verbatim: "Changing
    /// the lock *type* is a loosening and goes through the lock").
    case setLockKind(LockKind)

    /// Set the partner passphrase, once, during setup.
    ///
    /// Accepted only while the Lock has never been armed — see
    /// ``Ratchet/Refusal/lockPasswordChangeUnavailable`` for the exploit that
    /// closes and for why it cannot simply be queued instead.
    case setLockPassword(PasswordDigest)

    /// Remove the partner passphrase. Loosening — it removes the partner's
    /// authority.
    case clearLockPassword

    /// The V1-4 switch, labelled *"permit tightening changes directly"*.
    /// Enabling tightens, disabling loosens.
    case setRatchet(enabled: Bool)

    // MARK: Install protection (docs/04-product-spec.md V1-8)

    /// "Solid" mode — `store.application.denyAppInstallation`. Enabling is free;
    /// disabling goes through the Lock.
    case setInstallProtection(enabled: Bool)

    // MARK: Authorization

    /// Revoke Family Controls authorization from inside the app. Loosening
    /// (V1-4).
    ///
    /// Gate cannot stop the four-tap Settings route and must never claim to
    /// (docs/03-hard-constraints.md #13, #14). It can decline to be the *quick*
    /// route, which is all this case does.
    case revokeAuthorization

    // MARK: The queue itself

    /// Drop a queued change. **Free** — V1-4: the cancel affordance "is itself a
    /// tightening (free)".
    case cancelPendingChange(id: UUID)

    // MARK: Grants

    /// End a live grant early, re-shielding immediately. A tightening, and the
    /// fast "this was wrong" path the false-positive design calls for
    /// (docs/03-hard-constraints.md #35).
    case revokeGrant(id: UUID)

    // MARK: Bookkeeping

    /// Record that onboarding finished (docs/04-product-spec.md V1-1).
    case completeOnboarding

    /// Record — or clear — the observation that tokens may have expired
    /// (docs/04-product-spec.md V1-9). Set by the app when it sees a
    /// `TokenExpiryMessage` or a non-`.approved` `authorizationStatus`; cleared
    /// when recovery finishes.
    case markTokenExpiry(observedAt: Date?)

    /// The rule this mutation targets, if any.
    public var ruleID: UUID? {
        switch self {
        case .createRule(let rule):
            return rule.id
        case .deleteRule(let id),
             .renameRule(let id, _),
             .setRuleEnabled(let id, _),
             .setRuleMode(let id, _),
             .setSelection(let id, _, _),
             .reselectSelection(let id, _),
             .setSchedule(let id, _):
            return id
        case .reorderRules, .setLockDelay, .setLockKind, .setLockPassword,
             .clearLockPassword, .setRatchet, .setInstallProtection,
             .revokeAuthorization, .cancelPendingChange, .revokeGrant,
             .completeOnboarding, .markTokenExpiry:
            return nil
        }
    }
}

// MARK: - WeeklyCoverage

/// The set of instants in a repeating week that a ``RuleSchedule`` covers,
/// as disjoint half-open ranges of seconds since Sunday 00:00:00.
///
/// This exists because "extending a schedule window" (V1-4, TIGHTEN) and
/// "shrinking a schedule window" (V1-4, LOOSEN) are **set** relations, and
/// comparing ``RuleSchedule/duration`` would get them wrong in both directions:
/// 09:00–17:00 Mon–Fri versus 22:00–23:00 every day is longer per occurrence,
/// fewer days, and covers none of the same time. That is a reshape, and a
/// reshape loosens.
///
/// Wall-clock, not absolute time — deliberately, and for the same reason
/// ``RuleSchedule/contains(_:in:)`` compares components: a repeating
/// `DeviceActivitySchedule` is a time-of-day concept and a DST transition must
/// not make yesterday's window look like a different set from today's
/// (docs/02-api-reference.md §7).
///
/// Midnight-crossing windows are attributed to the weekday they *start* on,
/// exactly as ``RuleSchedule/weekdays`` documents, and wrap around the end of the
/// week into Sunday.
public struct WeeklyCoverage: Sendable, Equatable, Hashable {

    /// Seconds in a repeating week.
    public static let secondsPerWeek = 7 * TimeOfDay.secondsPerDay

    /// Disjoint, sorted, merged, all within `0 ..< secondsPerWeek`.
    public private(set) var intervals: [Range<Int>]

    /// Every second of the week — what a rule with no schedule covers.
    public static let always = WeeklyCoverage(merging: [0 ..< WeeklyCoverage.secondsPerWeek])

    /// No second of the week — what a malformed schedule covers, because
    /// ``RuleSchedule/contains(_:in:)`` returns `false` for one.
    public static let never = WeeklyCoverage(merging: [])

    /// Coverage of a schedule, or ``always`` when there is no schedule.
    public init(_ schedule: RuleSchedule?) {
        guard let schedule else {
            self = .always
            return
        }
        guard schedule.isWellFormed else {
            self = .never
            return
        }

        let length = Int(schedule.duration.rounded())
        guard length > 0 else {
            self = .never
            return
        }

        var raw: [Range<Int>] = []
        for weekday in schedule.weekdays.calendarWeekdays {
            // `calendarWeekday` 1 == Sunday == day index 0, matching
            // `WeekdayMask`'s bit order.
            let dayStart = (weekday - 1) * TimeOfDay.secondsPerDay
            let lower = dayStart + schedule.start.secondsFromMidnight
            let upper = lower + length
            if upper <= WeeklyCoverage.secondsPerWeek {
                raw.append(lower ..< upper)
            } else {
                // Saturday-night window spilling into Sunday morning.
                raw.append(lower ..< WeeklyCoverage.secondsPerWeek)
                raw.append(0 ..< (upper - WeeklyCoverage.secondsPerWeek))
            }
        }
        self.init(merging: raw)
    }

    /// Normalizes: drops empties, sorts, merges overlapping *and adjacent*
    /// ranges. Adjacency matters — seven consecutive all-day windows must
    /// collapse to one week-long range or containment tests would be wrong at
    /// every midnight.
    public init(merging ranges: [Range<Int>]) {
        let sorted = ranges
            .filter { !$0.isEmpty }
            .sorted { $0.lowerBound < $1.lowerBound }

        var merged: [Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        intervals = merged
    }

    /// Total seconds covered per week.
    public var coveredSeconds: Int {
        intervals.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    public var isEmpty: Bool { intervals.isEmpty }

    /// Whether every second `other` covers is also covered here.
    ///
    /// An empty `other` is contained by everything, which is the right answer:
    /// a schedule that never fires is a subset of one that sometimes does.
    public func contains(_ other: WeeklyCoverage) -> Bool {
        var index = 0
        for candidate in other.intervals {
            while index < intervals.count, intervals[index].upperBound <= candidate.lowerBound {
                index += 1
            }
            guard index < intervals.count,
                  intervals[index].lowerBound <= candidate.lowerBound,
                  intervals[index].upperBound >= candidate.upperBound
            else { return false }
        }
        return true
    }

    /// The set relation between two coverages, in the order
    /// `old -> new`.
    public static func relation(from old: WeeklyCoverage, to new: WeeklyCoverage) -> BreadthChange {
        let newCoversOld = new.contains(old)
        let oldCoversNew = old.contains(new)
        switch (newCoversOld, oldCoversNew) {
        case (true, true): return .unchanged
        case (true, false): return .widened
        case (false, true): return .narrowed
        case (false, false): return .reshaped
        }
    }
}

// MARK: - Ratchet

/// The classifier and the applier.
///
/// Uninhabited: every member is `static`, there is no state to carry, and a
/// private `init` keeps anyone from implying otherwise by writing `Ratchet()`.
public struct Ratchet {

    private init() {}

    // MARK: - Rationale

    /// *Why* a mutation landed in the column it did.
    ///
    /// The direction alone is not enough to write honest UI copy: a rename and a
    /// re-enable are both ``MutationDirection/tighten`` and want completely
    /// different sentences. This is also what the debug screen renders
    /// (docs/04-product-spec.md V1-11) and what the tests assert on, so a
    /// misclassification shows up as a wrong *reason*, not just a wrong column.
    public enum Rationale: String, Sendable, Hashable, CaseIterable, Codable {

        /// More is blocked, or blocked more of the time.
        case addsEnforcement

        /// Less is blocked, or blocked less of the time.
        case removesEnforcement

        /// The Lock itself got more expensive to change your mind against.
        case increasesLockCost

        /// The Lock itself got cheaper — a delay decrease, a type change, a
        /// password removal, the ratchet switched off.
        case decreasesLockCost

        /// Changes nothing about enforcement: a rename, a reorder, a warning
        /// lead time, a bookkeeping timestamp. Free, and exempt from the ratchet
        /// switch (see ``Ratchet/Assessment/goesThroughLock``).
        case cosmetic

        /// Withdrawing a queued change. Free by V1-4.
        case cancellation

        /// Token recovery. Free by V1-9, unconditionally.
        case recoveryReselect

        /// The request asks for what is already true.
        case noChange

        /// A guard refused it; the state is untouched.
        case refused
    }

    // MARK: - Refusal

    /// A guard said no. The state is returned **unchanged** — a refusal is never
    /// a partial application and never a way to dodge the Lock, because nothing
    /// moves at all.
    public enum Refusal: Sendable, Equatable, Hashable {

        /// No rule with that id. Almost always a stale screen.
        case unknownRule(UUID)

        /// No pending change with that id, or it is already resolved.
        case unknownPendingChange(UUID)

        /// No grant with that id.
        case unknownGrant(UUID)

        /// A rule with this id already exists.
        case duplicateRule(UUID)

        /// Already at ``GateLimits/maxRules``.
        case ruleLimitReached(limit: Int)

        /// Over the **silent** 50-token cap on one shield collection
        /// (docs/03-hard-constraints.md #34). Past the cap the store shields
        /// *nothing* and reads back `nil`, so this refusal is the only thing
        /// between the user and a rule that looks armed and does nothing.
        ///
        /// The rule editor enforces the same cap while the user is picking
        /// (docs/04-product-spec.md V1-2); this is the backstop for every other
        /// path into `GateState`.
        case tokenCapExceeded(collection: TokenCollection, count: Int, limit: Int)

        /// A window iOS would reject — under the 15-minute floor, over the
        /// one-week ceiling, zero-length, or with an empty weekday mask.
        /// `startMonitoring` throws these at whatever arbitrary moment the
        /// schedule is armed, typically while applying a block
        /// (docs/02-api-reference.md §14).
        case invalidSchedule([RuleIssue])

        /// The partner passphrase can only be set while the Lock has never been
        /// armed: before onboarding completes, with no passphrase already set,
        /// and with an empty queue.
        ///
        /// **EXPLOIT this closes.** A passphrase is a release path
        /// (``ReleasePaths/password``). Whoever can set one can release every
        /// queued loosening instantly, forever — so setting one is itself a
        /// loosening and would have to be queued. It cannot be: the persisted
        /// ``PendingChange/Operation`` has a `clearLockPassword` case and no
        /// `setLockPassword` case, by design, because the TIGHTEN half of V1-4's
        /// table has no representation there at all. Applying it immediately
        /// would hand the user a key to changes already in flight; queueing it is
        /// not expressible. Refusing is the only honest answer, and it costs
        /// nothing real: V1-3 says the Lock is "configured once", and the
        /// "hand your phone to someone" flow runs during onboarding.
        ///
        /// The route to a *new* passphrase is ``Mutation/clearLockPassword``,
        /// which is representable, is a loosening, and costs a full delay.
        /// Re-setting one afterwards is a documented follow-up that needs a new
        /// `Operation` case first.
        case lockPasswordChangeUnavailable

        /// The mutation is a loosening with no ``PendingChange/Operation`` to be
        /// queued as, so it can be neither applied nor deferred.
        ///
        /// Unreachable for every case of ``Mutation`` as it stands. It exists so
        /// that adding a case without adding its projection fails loudly at
        /// runtime in a test instead of silently applying a loosening for free.
        case notRepresentable
    }

    // MARK: - Assessment

    /// What ``Ratchet/apply(_:to:now:)`` is about to do, without doing it.
    ///
    /// The rule editor and the lock settings screen show this *before* the user
    /// commits — "this will apply immediately" versus "this unlocks in 12m 04s"
    /// — which is most of what makes the product feel honest rather than
    /// obstructive.
    public struct Assessment: Sendable, Equatable, Hashable {

        /// The V1-4 column.
        public var direction: MutationDirection

        /// Why (for copy, logs and tests).
        public var rationale: Rationale

        /// Whether ``Ratchet/apply(_:to:now:)`` will queue this rather than apply
        /// it now.
        ///
        /// Not simply `direction == .loosen`: with the ratchet switch **off**,
        /// tightenings are queued too. That is exactly what the switch is
        /// labelled to do — *"permit tightening changes directly"*
        /// (docs/04-product-spec.md V1-4) — and ``LockPolicy/isRatchetEnabled``
        /// documents the same reading: when off, every mutation is queued.
        public var goesThroughLock: Bool

        /// Nominal seconds to wait, `0` when free.
        ///
        /// For a delay *decrease* this is `oldDelay - newDelay`, the spec's
        /// asymmetry (V1-3), not the full delay. **Do not render this as a
        /// countdown without checking ``releasePaths``** — under
        /// ``LockKind/password`` there is no clock and no deadline.
        public var cost: TimeInterval

        /// How the queued change could be released. Empty when nothing is queued.
        public var releasePaths: ReleasePaths

        /// Non-nil when a guard will refuse and nothing will change.
        public var refusal: Refusal?

        public init(
            direction: MutationDirection,
            rationale: Rationale,
            goesThroughLock: Bool,
            cost: TimeInterval,
            releasePaths: ReleasePaths,
            refusal: Refusal? = nil
        ) {
            self.direction = direction
            self.rationale = rationale
            self.goesThroughLock = goesThroughLock
            self.cost = cost
            self.releasePaths = releasePaths
            self.refusal = refusal
        }

        /// True when the change takes effect the instant the user taps.
        public var isImmediate: Bool { refusal == nil && !goesThroughLock }
    }

    // MARK: - Side effects

    /// A staged selection blob the caller must write before persisting state.
    public struct SelectionStaging: Sendable, Equatable, Hashable {
        /// The ``SelectionRecord`` id the caller supplied in the mutation.
        public var selectionID: UUID
        /// The record must be owned by ``SelectionOwner/pendingChange(_:)`` with
        /// this id until the Lock releases.
        public var pendingChangeID: UUID

        public init(selectionID: UUID, pendingChangeID: UUID) {
            self.selectionID = selectionID
            self.pendingChangeID = pendingChangeID
        }
    }

    /// A staged blob that must now be re-parented onto its rule with
    /// ``SelectionTable/adopt(selectionID:asRule:at:)``.
    public struct SelectionAdoption: Sendable, Equatable, Hashable {
        public var selectionID: UUID
        public var ruleID: UUID

        public init(selectionID: UUID, ruleID: UUID) {
            self.selectionID = selectionID
            self.ruleID = ruleID
        }
    }

    /// Work the Ratchet cannot do itself because it lives outside `state.plist`.
    ///
    /// The Ratchet is pure and `GateState` is only one of the three files an
    /// install owns. Rather than reach for `SelectionTable`, the Keychain or
    /// `AuthorizationCenter` — none of which belong in a pure function, and two
    /// of which would drag a framework into the 6 MB monitor — it returns a
    /// description of what the caller still owes. `App/AppModel.swift` performs
    /// these in the same write batch that persists the state.
    ///
    /// **Order matters:** ``adoptSelections`` first, then ``discardSelections``,
    /// then ``stageSelections``. Adoption re-parents a blob away from the pending
    /// change that owned it, so discarding first would delete the very record
    /// that was about to be adopted, leaving a rule pointing at a
    /// ``SelectionRef`` with no blob behind it — which the reconciler reads as a
    /// rule it cannot vouch for and skips.
    public struct SideEffects: Sendable, Equatable, Hashable {

        /// Write these ``SelectionRecord``s owned by the named pending change.
        public var stageSelections: [SelectionStaging]

        /// Call ``SelectionTable/adopt(selectionID:asRule:at:)`` for each.
        public var adoptSelections: [SelectionAdoption]

        /// Call ``SelectionTable/removeAll(ownedBy:)`` for each.
        public var discardSelections: [SelectionOwner]

        /// Call `AuthorizationCenter.shared.revokeAuthorization(completionHandler:)`.
        ///
        /// Deliberately a flag and not a call: `FamilyControls` must never be
        /// imported here.
        public var revokesAuthorization: Bool

        /// ``GateState/lockClock`` changed; mirror it into the Keychain with
        /// `Kernel/Store/LockClock.swift`.
        ///
        /// The spec's rule is "write both" (docs/04-product-spec.md V1-3) and the
        /// Keychain copy is the one that survives delete-and-reinstall. Skipping
        /// this is what would make deleting the app a free bypass.
        public var mirrorsLockClock: Bool

        public init(
            stageSelections: [SelectionStaging] = [],
            adoptSelections: [SelectionAdoption] = [],
            discardSelections: [SelectionOwner] = [],
            revokesAuthorization: Bool = false,
            mirrorsLockClock: Bool = false
        ) {
            self.stageSelections = stageSelections
            self.adoptSelections = adoptSelections
            self.discardSelections = discardSelections
            self.revokesAuthorization = revokesAuthorization
            self.mirrorsLockClock = mirrorsLockClock
        }

        /// Nothing owed.
        public static let none = SideEffects()

        public var isEmpty: Bool {
            stageSelections.isEmpty
                && adoptSelections.isEmpty
                && discardSelections.isEmpty
                && !revokesAuthorization
                && !mirrorsLockClock
        }

        /// Union, preserving order and dropping exact duplicates.
        public func merging(_ other: SideEffects) -> SideEffects {
            SideEffects(
                stageSelections: SideEffects.appending(stageSelections, other.stageSelections),
                adoptSelections: SideEffects.appending(adoptSelections, other.adoptSelections),
                discardSelections: SideEffects.appending(discardSelections, other.discardSelections),
                revokesAuthorization: revokesAuthorization || other.revokesAuthorization,
                mirrorsLockClock: mirrorsLockClock || other.mirrorsLockClock
            )
        }

        private static func appending<Element: Hashable>(
            _ lhs: [Element], _ rhs: [Element]
        ) -> [Element] {
            var seen = Set(lhs)
            var result = lhs
            for element in rhs where seen.insert(element).inserted {
                result.append(element)
            }
            return result
        }
    }

    // MARK: - Disposition and Outcome

    /// What actually happened.
    public enum Disposition: Sendable, Equatable {

        /// Folded into the state there and then.
        case applied(MutationDirection)

        /// Parked behind the Lock. The associated value is the record that was
        /// appended to ``GateState/pendingChanges``.
        case queued(PendingChange)

        /// The request asks for what is already true. State is unchanged, except
        /// that an opposing queued change may still have been withdrawn — see
        /// ``Ratchet/Outcome/withdrew``.
        case noChange

        /// A guard refused. State is unchanged.
        case refused(Refusal)
    }

    /// The full result of ``Ratchet/applying(_:to:now:note:)``.
    public struct Outcome: Sendable, Equatable {

        /// The new state. Identical to the input for ``Disposition/refused(_:)``
        /// and usually for ``Disposition/noChange``.
        public var state: GateState

        public var disposition: Disposition

        /// What was predicted before applying. Always consistent with
        /// ``disposition``.
        public var assessment: Assessment

        /// Work the caller still owes — selections, the Keychain, authorization.
        public var effects: SideEffects

        /// Queued changes this mutation resolved on the way through: an opposing
        /// change the user has now reverted (``PendingChange/Status/cancelled``)
        /// or an older change for the same target (``PendingChange/Status/superseded``).
        ///
        /// Surfaced so the UI can say "that also cancelled your queued change"
        /// instead of letting one silently vanish from the banner.
        public var withdrew: [PendingChange]

        public init(
            state: GateState,
            disposition: Disposition,
            assessment: Assessment,
            effects: SideEffects = .none,
            withdrew: [PendingChange] = []
        ) {
            self.state = state
            self.disposition = disposition
            self.assessment = assessment
            self.effects = effects
            self.withdrew = withdrew
        }

        /// The record that was queued, if one was.
        public var pendingChange: PendingChange? {
            if case .queued(let change) = disposition { return change }
            return nil
        }

        /// Why nothing happened, if nothing happened.
        public var refusal: Refusal? {
            if case .refused(let reason) = disposition { return reason }
            return nil
        }

        /// True when the state moved at all.
        public var didChangeState: Bool {
            switch disposition {
            case .applied, .queued: true
            case .noChange: !withdrew.isEmpty
            case .refused: false
            }
        }
    }

    // MARK: - Release

    /// The outcome of trying to release one queued change.
    public struct ReleaseResult: Sendable, Equatable {

        public enum Status: Sendable, Equatable {
            /// Released and folded in.
            case released(PendingChange)
            /// The deadline has not passed. `remaining` is `nil` under
            /// ``LockKind/password``, where it never will on time alone.
            case notRipe(remaining: TimeInterval?)
            /// The passphrase did not open it. Carries the reason so the UI can
            /// tell "wrong password" apart from "this build cannot read the
            /// stored digest", which need completely different copy
            /// (see ``PasswordVerification``).
            case passwordRefused(PasswordVerification)
            /// No such change.
            case notFound
            /// Already applied, cancelled or superseded.
            case alreadyResolved(PendingChange.Status)
            /// Written by a newer build; never applied.
            case notApplicable
        }

        public var state: GateState
        public var status: Status
        public var effects: SideEffects

        public init(state: GateState, status: Status, effects: SideEffects = .none) {
            self.state = state
            self.status = status
            self.effects = effects
        }

        /// The change, if it was released.
        public var released: PendingChange? {
            if case .released(let change) = status { return change }
            return nil
        }
    }

    // MARK: - Classification (docs/04-product-spec.md V1-4)

    /// Which column of V1-4 a mutation falls in.
    ///
    /// Total: an unknown rule id, a nonsense value, a no-op — all classify,
    /// because a classifier that can fail is a classifier a screen can skip.
    /// A mutation that changes nothing classifies as ``MutationDirection/tighten``,
    /// which is the free column; ``Ratchet/assess(_:in:)`` reports it as
    /// ``Rationale/noChange``.
    ///
    /// **EXPLOIT notes — the readings this file chose where V1-4 is silent:**
    ///
    /// - **Allowlist inversion.** V1-4 lists "adding a token to a rule" under
    ///   TIGHTEN. That is written with blocklist semantics in mind. In
    ///   ``RuleMode/allowlist`` the selection is the *allowed* set — the store is
    ///   written `.all(except: allowed)` (docs/04-product-spec.md V1-2) — so
    ///   adding a token there **un-blocks** an app and is a loosening. Reading it
    ///   the other way would let anyone unblock anything instantly by flipping a
    ///   rule to allowlist first.
    /// - **Reshapes loosen.** A selection or window that is neither a superset
    ///   nor a subset of the old one always drops *something*, so it is queued.
    ///   Callers that cannot compute the relation pass
    ///   ``BreadthChange/reshaped`` and get the same conservative answer.
    /// - **Uncertainty loosens.** Every "I do not know" path in this file lands
    ///   in the LOOSEN column. The cost of being wrong in that direction is a
    ///   wait; the cost of being wrong in the other is the product.
    /// - **Recovery is exempt, deliberately.** ``Mutation/reselectSelection(ruleID:selection:)``
    ///   is free even when it narrows a rule, because V1-9 says so in as many
    ///   words. The residual abuse is bounded: a reselect cannot delete a rule,
    ///   disable it, change its mode or schedule, or touch the Lock — the rule
    ///   stays armed over whatever was re-picked. The UI must offer it only from
    ///   the recovery screen (`App/Screens/RecoveryScreen.swift`); routine
    ///   editing goes through ``Mutation/setSelection(ruleID:selection:change:)``.
    public static func direction(of mutation: Mutation, in state: GateState) -> MutationDirection {
        classify(mutation, in: state).direction
    }

    /// Direction plus the reason, with no state lookup beyond `state`.
    private static func classify(
        _ mutation: Mutation, in state: GateState
    ) -> (direction: MutationDirection, rationale: Rationale) {
        switch mutation {

        // ── Rules ──────────────────────────────────────────────────────────
        case .createRule:
            return (.tighten, .addsEnforcement)

        case .deleteRule:
            return (.loosen, .removesEnforcement)

        case .renameRule, .reorderRules:
            return (.tighten, .cosmetic)

        case .setRuleEnabled(let ruleID, let enabled):
            guard let rule = state.rule(id: ruleID) else {
                return enabled ? (.tighten, .addsEnforcement) : (.loosen, .removesEnforcement)
            }
            if rule.isEnabled == enabled { return (.tighten, .noChange) }
            return enabled ? (.tighten, .addsEnforcement) : (.loosen, .removesEnforcement)

        case .setRuleMode(let ruleID, let mode):
            if let rule = state.rule(id: ruleID), rule.mode == mode {
                return (.tighten, .noChange)
            }
            // `blocklist -> allowlist` widens what is blocked over the same
            // tokens: "block everything except these" strictly contains "block
            // these" (docs/04-product-spec.md V1-4). An unknown rule classifies
            // by the target mode alone, which keeps this total; the apply path
            // refuses it regardless.
            return mode == .allowlist
                ? (.tighten, .addsEnforcement)
                : (.loosen, .removesEnforcement)

        case .setSelection(let ruleID, let selection, let change):
            guard let rule = state.rule(id: ruleID) else {
                return (.loosen, .removesEnforcement)
            }
            return selectionDirection(
                mode: rule.mode, old: rule.selection, new: selection, change: change
            )

        case .reselectSelection:
            // docs/04-product-spec.md V1-9, verbatim: "Reselecting is a
            // tightening — never gate recovery behind the lock."
            return (.tighten, .recoveryReselect)

        case .setSchedule(let ruleID, let schedule):
            guard let rule = state.rule(id: ruleID) else {
                return (.loosen, .removesEnforcement)
            }
            if rule.schedule == schedule { return (.tighten, .noChange) }
            switch WeeklyCoverage.relation(
                from: WeeklyCoverage(rule.schedule), to: WeeklyCoverage(schedule)
            ) {
            case .widened: return (.tighten, .addsEnforcement)
            case .unchanged: return (.tighten, .cosmetic)   // e.g. warning lead time only
            case .narrowed, .reshaped: return (.loosen, .removesEnforcement)
            }

        // ── The Lock ───────────────────────────────────────────────────────
        case .setLockDelay(let seconds):
            let requested = LockPolicy.clampDelay(seconds)
            if requested == state.lock.delay { return (.tighten, .noChange) }
            return requested > state.lock.delay
                ? (.tighten, .increasesLockCost)
                : (.loosen, .decreasesLockCost)

        case .setLockKind(let kind):
            if kind == state.lock.kind { return (.tighten, .noChange) }
            // docs/04-product-spec.md V1-3, verbatim: "Changing the lock *type*
            // is a loosening and goes through the lock." No exceptions — even
            // `.delay -> .both`, which looks like it only adds an authority but
            // in fact adds a release path.
            return (.loosen, .decreasesLockCost)

        case .setLockPassword:
            // Before the Lock has ever been armed there is nothing to bypass: no
            // queued loosening a new passphrase could release early, and no
            // partner authority it could displace. Adding one then is purely
            // additive — it hands an authority to someone who is, by the design
            // of the flow, not you (docs/04-product-spec.md V1-3).
            //
            // Afterwards it *creates a release path*, which is a loosening — and
            // one with no ``PendingChange/Operation`` to be queued as, so
            // `refusal(for:in:)` refuses it outright rather than applying it for
            // free. See ``Refusal/lockPasswordChangeUnavailable``.
            return lockPasswordRefusal(in: state) == nil
                ? (.tighten, .increasesLockCost)
                : (.loosen, .decreasesLockCost)

        case .clearLockPassword:
            if state.lock.password == nil { return (.tighten, .noChange) }
            return (.loosen, .decreasesLockCost)

        case .setRatchet(let enabled):
            if state.lock.isRatchetEnabled == enabled { return (.tighten, .noChange) }
            return enabled
                ? (.tighten, .increasesLockCost)
                : (.loosen, .decreasesLockCost)

        // ── Install protection ─────────────────────────────────────────────
        case .setInstallProtection(let enabled):
            if state.installProtectionEnabled == enabled { return (.tighten, .noChange) }
            return enabled
                ? (.tighten, .addsEnforcement)
                : (.loosen, .removesEnforcement)

        // ── Authorization ──────────────────────────────────────────────────
        case .revokeAuthorization:
            return (.loosen, .removesEnforcement)

        // ── The queue ──────────────────────────────────────────────────────
        case .cancelPendingChange:
            // docs/04-product-spec.md V1-4: the cancel affordance "is itself a
            // tightening (free)". Withdrawing a loosening can only ever leave
            // more enforcement standing, so this stays free even with the
            // ratchet switched off — otherwise a user could be talked into a
            // queue they cannot empty.
            return (.tighten, .cancellation)

        // ── Grants ─────────────────────────────────────────────────────────
        case .revokeGrant:
            return (.tighten, .addsEnforcement)

        // ── Bookkeeping ────────────────────────────────────────────────────
        case .completeOnboarding, .markTokenExpiry:
            return (.tighten, .cosmetic)
        }
    }

    /// Direction of a selection swap, given the mode that decides what "broader"
    /// means.
    private static func selectionDirection(
        mode: RuleMode,
        old: SelectionRef?,
        new: SelectionRef?,
        change: BreadthChange
    ) -> (direction: MutationDirection, rationale: Rationale) {
        switch (old, new) {
        case (nil, nil):
            return (.tighten, .noChange)

        case (nil, .some):
            // The rule had nothing to enforce and now has something. True in
            // both modes: a blocklist starts blocking, an allowlist starts
            // blocking everything except.
            return (.tighten, .addsEnforcement)

        case (.some, nil):
            // Clearing the selection stops the rule being enforced at all — the
            // reconciler skips a rule with no selection rather than writing an
            // empty store. A loosening in both modes.
            return (.loosen, .removesEnforcement)

        case (.some(let oldRef), .some(let newRef)):
            if oldRef == newRef { return (.tighten, .noChange) }
            switch change {
            case .unchanged:
                // The same token set re-encoded under a new record id. Free.
                return (.tighten, .cosmetic)

            case .widened:
                // More tokens selected. In ``RuleMode/blocklist`` that is more
                // blocked; in ``RuleMode/allowlist`` the selection is the
                // *allowed* set, so a wider one un-blocks an app. This inversion
                // is the reading V1-4 does not spell out — see the EXPLOIT note
                // on ``Ratchet/direction(of:in:)``.
                return mode == .blocklist
                    ? (.tighten, .addsEnforcement)
                    : (.loosen, .removesEnforcement)

            case .narrowed:
                // Mirror image: fewer apps on the allowed list means more apps
                // blocked, while a shorter blocklist blocks less.
                return mode == .allowlist
                    ? (.tighten, .addsEnforcement)
                    : (.loosen, .removesEnforcement)

            case .reshaped:
                // Neither a superset nor a subset — or the caller could not tell.
                // Something was dropped either way, so it goes through the Lock.
                return (.loosen, .removesEnforcement)
            }
        }
    }

    // MARK: - Cost

    /// Nominal seconds a mutation costs, `0` when free.
    ///
    /// **The one special case in the product.** Decreasing the Lock delay costs
    /// `oldDelay - newDelay`, not the full delay (docs/04-product-spec.md V1-3):
    /// dropping 15m to 14m is a one-minute wait, dropping 15m to 1m is fourteen
    /// minutes. The arithmetic is exactly additive, which is the point — walking
    /// 15m down to 1m one second at a time costs 840 seconds of waiting in total,
    /// the same as doing it in a single step. There is no staircase shortcut.
    ///
    /// Everything else that goes through the Lock costs the full
    /// ``LockPolicy/delay``, including a tightening queued because the ratchet
    /// switch is off.
    public static func cost(of mutation: Mutation, in state: GateState) -> TimeInterval {
        let classified = classify(mutation, in: state)
        guard classified.rationale != .noChange else { return 0 }

        if case .setLockDelay(let seconds) = mutation {
            let requested = LockPolicy.clampDelay(seconds)
            guard requested < state.lock.delay else {
                // An increase is a tightening: free unless the ratchet switch is
                // off, in which case it queues at the full current delay like
                // anything else.
                return goesThroughLock(mutation, classified.direction, in: state)
                    ? state.lock.delay
                    : 0
            }
            // The spec's asymmetry, and the only place in the product where the
            // wait is not simply `lock.delay`.
            return state.lock.delay - requested
        }

        return goesThroughLock(mutation, classified.direction, in: state) ? state.lock.delay : 0
    }

    /// When a mutation queued at `now` could ripen, or `nil` if it never ripens
    /// on time alone.
    ///
    /// Delegates the `nil` decision to ``LockPolicy/earliestApplyDate(from:)`` so
    /// that a pure ``LockKind/password`` lock has exactly one implementation of
    /// "there is no clock here" — returning `now + delay` there would let anyone
    /// wait out a partner lock.
    public static func earliestApplyDate(
        cost: TimeInterval, under lock: LockPolicy, from now: Date
    ) -> Date? {
        guard lock.kind.acceptsDelay else { return nil }
        guard cost.isFinite else { return lock.earliestApplyDate(from: now) }
        return now.addingTimeInterval(max(0, cost))
    }

    // MARK: - The ratchet switch

    /// Whether this mutation is queued rather than applied now.
    ///
    /// Loosenings: always queued, in every configuration.
    ///
    /// Tightenings: queued **only** when ``LockPolicy/isRatchetEnabled`` is off.
    /// The switch is labelled *"permit tightening changes directly"*
    /// (docs/04-product-spec.md V1-4) and ``LockPolicy/isRatchetEnabled`` spells
    /// out the same reading — "when off, *every* mutation is queued, including
    /// tightenings" — a stricter mode where no change of mind is impulsive.
    ///
    /// Two classes of tightening stay immediate even then:
    ///
    /// 1. **Exempt by spec.** ``Rationale/cancellation`` (V1-4 calls cancelling
    ///    free), ``Rationale/recoveryReselect`` (V1-9 forbids gating recovery)
    ///    and ``Rationale/cosmetic`` (a rename changes no enforcement, and
    ///    charging fifteen minutes for one would be theatre).
    /// 2. **Not representable.** ``PendingChange/Operation`` has no case for
    ///    creating a rule, enabling a rule, setting a passphrase or revoking a
    ///    grant, because the TIGHTEN half of V1-4's table was deliberately given
    ///    no persisted form. Those apply immediately.
    ///
    /// The gap in (2) is a missing feature, never a hole: **nothing in it can
    /// loosen anything.** Closing it means adding tightening cases to
    /// `PendingChange.Operation`; until then the ratchet switch covers the
    /// tightenings that are expressible, and `Assessment.goesThroughLock` always
    /// tells the UI the truth about the specific mutation in hand.
    private static func goesThroughLock(
        _ mutation: Mutation, _ direction: MutationDirection, in state: GateState
    ) -> Bool {
        switch direction {
        case .loosen:
            return true
        case .tighten:
            guard !state.lock.isRatchetEnabled else { return false }
            let rationale = classify(mutation, in: state).rationale
            switch rationale {
            case .noChange, .cosmetic, .cancellation, .recoveryReselect, .refused:
                return false
            case .addsEnforcement, .removesEnforcement, .increasesLockCost, .decreasesLockCost:
                return deferrableTightening(mutation) != nil
            }
        }
    }

    /// The ``PendingChange/Operation`` that performs `mutation` as a *tightening*
    /// when the ratchet switch is off, or `nil` when the persisted model has no
    /// way to express it.
    private static func deferrableTightening(
        _ mutation: Mutation
    ) -> PendingChange.Operation? {
        switch mutation {
        case .setRuleMode(let ruleID, let mode):
            return .setMode(ruleID: ruleID, mode: mode)
        case .setSchedule(let ruleID, let schedule):
            return .setSchedule(ruleID: ruleID, schedule: schedule)
        case .setSelection(let ruleID, let selection, _):
            return .replaceSelection(ruleID: ruleID, selection: selection)
        case .setLockDelay(let seconds):
            return .setLockDelay(seconds: LockPolicy.clampDelay(seconds))
        case .setRatchet(let enabled):
            return .setRatchet(enabled: enabled)
        case .setInstallProtection(let enabled):
            return .setInstallProtection(enabled: enabled)
        case .createRule, .deleteRule, .renameRule, .reorderRules, .setRuleEnabled,
             .reselectSelection, .setLockKind, .setLockPassword, .clearLockPassword,
             .revokeAuthorization, .cancelPendingChange, .revokeGrant,
             .completeOnboarding, .markTokenExpiry:
            return nil
        }
    }

    /// The ``PendingChange/Operation`` a *loosening* projects onto.
    ///
    /// `nil` means the loosening cannot be queued, which surfaces as
    /// ``Refusal/notRepresentable`` rather than as a free application. Every
    /// current loosening has a projection; the `nil` arm exists so a future case
    /// added without one fails a test instead of shipping a bypass.
    private static func looseningOperation(
        _ mutation: Mutation
    ) -> PendingChange.Operation? {
        switch mutation {
        case .deleteRule(let ruleID):
            return .deleteRule(ruleID: ruleID)
        case .setRuleEnabled(let ruleID, let enabled) where !enabled:
            return .disableRule(ruleID: ruleID)
        case .setRuleMode(let ruleID, let mode):
            return .setMode(ruleID: ruleID, mode: mode)
        case .setSelection(let ruleID, let selection, _):
            return .replaceSelection(ruleID: ruleID, selection: selection)
        case .setSchedule(let ruleID, let schedule):
            return .setSchedule(ruleID: ruleID, schedule: schedule)
        case .setLockDelay(let seconds):
            return .setLockDelay(seconds: LockPolicy.clampDelay(seconds))
        case .setLockKind(let kind):
            return .setLockKind(kind)
        case .clearLockPassword:
            return .clearLockPassword
        case .setRatchet(let enabled):
            return .setRatchet(enabled: enabled)
        case .setInstallProtection(let enabled):
            return .setInstallProtection(enabled: enabled)
        case .revokeAuthorization:
            return .revokeAuthorization
        case .setLockPassword:
            // Intentionally unrepresentable — see
            // `Refusal.lockPasswordChangeUnavailable`.
            return nil
        case .createRule, .renameRule, .reorderRules, .setRuleEnabled,
             .reselectSelection, .cancelPendingChange, .revokeGrant,
             .completeOnboarding, .markTokenExpiry:
            return nil
        }
    }

    /// The ``PendingChange/Operation/targetKey`` this mutation competes with.
    ///
    /// Two queued changes with the same key are mutually exclusive
    /// (``PendingChange/Operation/targetKey``). The keys are **derived** from a
    /// representative `Operation` rather than re-spelled here, so the two files
    /// cannot drift: a rename of one of those strings changes both sides at once.
    private static func targetKey(of mutation: Mutation) -> String? {
        switch mutation {
        case .deleteRule(let ruleID):
            return PendingChange.Operation.deleteRule(ruleID: ruleID).targetKey
        case .setRuleEnabled(let ruleID, _):
            return PendingChange.Operation.disableRule(ruleID: ruleID).targetKey
        case .setRuleMode(let ruleID, let mode):
            return PendingChange.Operation.setMode(ruleID: ruleID, mode: mode).targetKey
        case .setSelection(let ruleID, _, _), .reselectSelection(let ruleID, _):
            return PendingChange.Operation.replaceSelection(ruleID: ruleID, selection: nil).targetKey
        case .setSchedule(let ruleID, _):
            return PendingChange.Operation.setSchedule(ruleID: ruleID, schedule: nil).targetKey
        case .setLockDelay:
            return PendingChange.Operation.setLockDelay(seconds: 0).targetKey
        case .setLockKind(let kind):
            return PendingChange.Operation.setLockKind(kind).targetKey
        case .setLockPassword, .clearLockPassword:
            return PendingChange.Operation.clearLockPassword.targetKey
        case .setRatchet(let enabled):
            return PendingChange.Operation.setRatchet(enabled: enabled).targetKey
        case .setInstallProtection(let enabled):
            return PendingChange.Operation.setInstallProtection(enabled: enabled).targetKey
        case .revokeAuthorization:
            return PendingChange.Operation.revokeAuthorization.targetKey
        case .createRule, .renameRule, .reorderRules, .cancelPendingChange,
             .revokeGrant, .completeOnboarding, .markTokenExpiry:
            return nil
        }
    }

    // MARK: - Guards (docs/06-build-plan.md steps 3.8, and V1-2's rule cap)

    /// The 50-token and 8-rule guards, at the one place every write funnels
    /// through.
    ///
    /// Both caps fail **silently** on the platform: past 50 tokens the shield
    /// collection shields nothing and reads back `nil`
    /// (docs/03-hard-constraints.md #34), and past 50 named stores the store is
    /// simply not created. The rule editor checks the token cap while the user
    /// picks (docs/04-product-spec.md V1-2); this is the backstop for every other
    /// path, including a state file written by an older build.
    ///
    /// A refusal is returned for a *loosening* too. A queued change that would
    /// land an over-cap selection is not a lesser evil for having waited — it
    /// still produces a rule that looks armed and enforces nothing.
    ///
    /// Note what is deliberately **not** guarded here: the number of open pending
    /// changes. Each one wants a `gate.revert:` auto-revert timer and the budget
    /// for those is ``GateLimits/maxRevertActivities``, but that budget is
    /// enforced by eviction in `Kernel/Enforcement/MonitorPlan.swift`, not by
    /// refusal — the timers are accelerators, and a change with no timer still
    /// ripens on absolute timestamp at the next foreground reconcile
    /// (docs/04-product-spec.md V1-10). Refusing to queue a loosening because the
    /// timer budget is full would be a cap on *thinking about* changing your
    /// mind, which is not a thing this product sells.
    private static func refusal(for mutation: Mutation, in state: GateState) -> Refusal? {
        switch mutation {

        case .createRule(let rule):
            if state.rules.contains(where: { $0.id == rule.id }) {
                return .duplicateRule(rule.id)
            }
            if state.rules.count >= GateLimits.maxRules {
                return .ruleLimitReached(limit: GateLimits.maxRules)
            }
            if let overflow = tokenCapRefusal(rule.selection) { return overflow }
            if let schedule = rule.schedule, let issue = scheduleRefusal(schedule) { return issue }
            return nil

        case .setSelection(let ruleID, let selection, _):
            guard state.rule(id: ruleID) != nil else { return .unknownRule(ruleID) }
            return tokenCapRefusal(selection)

        case .reselectSelection(let ruleID, let selection):
            guard state.rule(id: ruleID) != nil else { return .unknownRule(ruleID) }
            return tokenCapRefusal(selection)

        case .setSchedule(let ruleID, let schedule):
            guard state.rule(id: ruleID) != nil else { return .unknownRule(ruleID) }
            guard let schedule else { return nil }
            return scheduleRefusal(schedule)

        case .deleteRule(let ruleID), .renameRule(let ruleID, _),
             .setRuleEnabled(let ruleID, _), .setRuleMode(let ruleID, _):
            return state.rule(id: ruleID) == nil ? .unknownRule(ruleID) : nil

        case .cancelPendingChange(let id):
            let isOpen = state.pendingChanges.contains { $0.id == id && $0.status == .pending }
            return isOpen ? nil : .unknownPendingChange(id)

        case .revokeGrant(let id):
            return state.grants.contains { $0.id == id } ? nil : .unknownGrant(id)

        case .setLockPassword:
            return lockPasswordRefusal(in: state)

        case .reorderRules, .setLockDelay, .setLockKind, .clearLockPassword,
             .setRatchet, .setInstallProtection, .revokeAuthorization,
             .completeOnboarding, .markTokenExpiry:
            return nil
        }
    }

    /// The silent 50-per-collection cap (docs/03-hard-constraints.md #34).
    private static func tokenCapRefusal(_ selection: SelectionRef?) -> Refusal? {
        guard let overflow = selection?.digest.overflowingCollections.first else { return nil }
        return .tokenCapExceeded(
            collection: overflow.collection,
            count: overflow.count,
            limit: GateLimits.maxTokensPerShieldCollection
        )
    }

    /// iOS's thrown schedule limits (docs/02-api-reference.md §14).
    ///
    /// Only the issues that make a window un-registerable are refused. A rule
    /// with no selection yet, or with an empty one, is a legitimate intermediate
    /// state in the editor and is left to ``Rule/validate()`` to surface.
    private static func scheduleRefusal(_ schedule: RuleSchedule) -> Refusal? {
        let blocking = schedule.validate().filter(\.isBlocking)
        return blocking.isEmpty ? nil : .invalidSchedule(blocking)
    }

    /// See ``Refusal/lockPasswordChangeUnavailable``.
    private static func lockPasswordRefusal(in state: GateState) -> Refusal? {
        let neverArmed = state.onboardingCompletedAt == nil
            && state.lock.password == nil
            && state.pendingChanges.pending.isEmpty
        return neverArmed ? nil : .lockPasswordChangeUnavailable
    }

    // MARK: - Assess

    /// What ``apply(_:to:now:)`` will do, without doing it.
    public static func assess(_ mutation: Mutation, in state: GateState) -> Assessment {
        if let refusal = refusal(for: mutation, in: state) {
            return Assessment(
                direction: classify(mutation, in: state).direction,
                rationale: .refused,
                goesThroughLock: false,
                cost: 0,
                releasePaths: [],
                refusal: refusal
            )
        }

        let classified = classify(mutation, in: state)

        if classified.rationale == .noChange {
            return Assessment(
                direction: .tighten,
                rationale: .noChange,
                goesThroughLock: false,
                cost: 0,
                releasePaths: []
            )
        }

        let queued = goesThroughLock(mutation, classified.direction, in: state)

        // A loosening with no persisted form can be neither applied nor
        // deferred. Unreachable today; see `looseningOperation`.
        if queued, classified.direction == .loosen, looseningOperation(mutation) == nil {
            return Assessment(
                direction: .loosen,
                rationale: .refused,
                goesThroughLock: false,
                cost: 0,
                releasePaths: [],
                refusal: .notRepresentable
            )
        }

        return Assessment(
            direction: classified.direction,
            rationale: classified.rationale,
            goesThroughLock: queued,
            cost: queued ? cost(of: mutation, in: state) : 0,
            releasePaths: queued ? ReleasePaths.available(under: state.lock) : []
        )
    }

    // MARK: - Apply

    /// Apply a mutation: tightenings land now, loosenings are parked behind the
    /// Lock (docs/06-build-plan.md step 3.5).
    ///
    /// - Returns: the new state, and the ``PendingChange`` if one was queued.
    ///   A refused mutation returns the state **unchanged** and `nil`; call
    ///   ``applying(_:to:now:note:)`` instead when you need to know why, or when
    ///   you need the ``SideEffects`` — which you do for any mutation that
    ///   touches a selection, authorization, or the Lock clock.
    public static func apply(
        _ mutation: Mutation, to state: GateState, now: Date
    ) -> (GateState, PendingChange?) {
        let outcome = applying(mutation, to: state, now: now)
        return (outcome.state, outcome.pendingChange)
    }

    /// The full-fidelity form of ``apply(_:to:now:)``.
    ///
    /// - Parameters:
    ///   - note: optional user-written context shown in the pending-changes
    ///     banner ("I want to check the group chat"). Ignored for tightenings,
    ///     which leave no record.
    public static func applying(
        _ mutation: Mutation, to state: GateState, now: Date, note: String? = nil
    ) -> Outcome {
        let assessment = assess(mutation, in: state)

        if let refusal = assessment.refusal {
            return Outcome(state: state, disposition: .refused(refusal), assessment: assessment)
        }

        var working = state
        var effects = SideEffects()

        // Resolve the queue first, whichever way this mutation is going.
        //
        // A tightening that targets the same thing as an open loosening *is* the
        // user changing their mind back, so it withdraws it — free, per V1-4. A
        // loosening supersedes the older one instead, so the banner keeps showing
        // one live deadline per target and a re-queue never stacks two waits
        // (``PendingChange/Operation/targetKey``).
        let withdrawalStatus: PendingChange.Status =
            assessment.direction == .loosen ? .superseded : .cancelled
        let withdrawn = resolveConflicts(
            with: targetKey(of: mutation), as: withdrawalStatus, in: &working, now: now
        )
        for change in withdrawn {
            effects.discardSelections.append(.pendingChange(change.id))
        }

        if assessment.rationale == .noChange {
            if withdrawn.isEmpty {
                return Outcome(state: state, disposition: .noChange, assessment: assessment)
            }
            working.updatedAt = now
            effects = effects.merging(refreshLockClock(in: &working, now: now))
            return Outcome(
                state: working,
                disposition: .noChange,
                assessment: assessment,
                effects: effects,
                withdrew: withdrawn
            )
        }

        if assessment.goesThroughLock {
            guard let operation = queuedOperation(for: mutation, direction: assessment.direction)
            else {
                // `assess` already rules this out; belt and braces, and never in
                // the direction of applying a loosening for free.
                return Outcome(
                    state: state,
                    disposition: .refused(.notRepresentable),
                    assessment: assessment
                )
            }

            let change = PendingChange(
                operation: operation,
                requestedAt: now,
                earliestApplyAt: earliestApplyDate(
                    cost: assessment.cost, under: state.lock, from: now
                ),
                lockConfigHash: state.lock.configHash,
                note: note
            )
            working.pendingChanges.append(change)

            // The new blob stays parked under the pending change until the Lock
            // releases; the rule keeps enforcing the old one meanwhile.
            if case .replaceSelection(_, .some(let ref)) = operation {
                effects.stageSelections.append(
                    SelectionStaging(selectionID: ref.id, pendingChangeID: change.id)
                )
            }

            working.updatedAt = now
            effects = effects.merging(refreshLockClock(in: &working, now: now))
            return Outcome(
                state: working,
                disposition: .queued(change),
                assessment: assessment,
                effects: effects,
                withdrew: withdrawn
            )
        }

        effects = effects.merging(performImmediately(mutation, in: &working, now: now))
        working.updatedAt = now
        effects = effects.merging(refreshLockClock(in: &working, now: now))

        return Outcome(
            state: working,
            disposition: .applied(assessment.direction),
            assessment: assessment,
            effects: effects,
            withdrew: withdrawn
        )
    }

    /// The operation to park, for either direction.
    private static func queuedOperation(
        for mutation: Mutation, direction: MutationDirection
    ) -> PendingChange.Operation? {
        switch direction {
        case .loosen: looseningOperation(mutation)
        case .tighten: deferrableTightening(mutation)
        }
    }

    /// Resolves open changes competing for the same target.
    @discardableResult
    private static func resolveConflicts(
        with key: String?, as status: PendingChange.Status, in state: inout GateState, now: Date
    ) -> [PendingChange] {
        guard let key else { return [] }
        var resolved: [PendingChange] = []
        for index in state.pendingChanges.indices {
            let change = state.pendingChanges[index]
            guard change.status == .pending, change.operation.targetKey == key else { continue }
            let updated = status == .cancelled ? change.cancelled(at: now) : change.superseded(at: now)
            state.pendingChanges[index] = updated
            resolved.append(updated)
        }
        return resolved
    }

    // MARK: - Immediate application

    /// Folds a tightening (or a free no-op-adjacent change) straight into state.
    ///
    /// Every branch is guarded by ``refusal(for:in:)`` having already returned
    /// `nil`, so the lookups here cannot fail; they are still written as `guard`s
    /// rather than force-unwraps, because "cannot fail" is a claim about today's
    /// call graph and a trap in the settings screen is not a recoverable event.
    private static func performImmediately(
        _ mutation: Mutation, in state: inout GateState, now: Date
    ) -> SideEffects {
        var effects = SideEffects()

        switch mutation {

        case .createRule(let rule):
            var inserted = rule
            inserted.sortIndex = state.rules.count
            inserted.createdAt = rule.createdAt == .distantPast ? now : rule.createdAt
            inserted.updatedAt = now
            state.rules.append(inserted)
            normalizeSortIndices(in: &state)

        case .deleteRule:
            // Always a loosening; it only ever lands through `applyReleased`.
            // The case is spelled out rather than swept into a `default` so that
            // a new `Mutation` cannot be added without a deliberate decision
            // about what applying it immediately would mean.
            break

        case .renameRule(let ruleID, let name):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].name = String(name.prefix(Rule.maxNameLength))
            state.rules[index].updatedAt = now

        case .reorderRules(let orderedIDs):
            reorder(&state, to: orderedIDs, now: now)

        case .setRuleEnabled(let ruleID, let enabled):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].isEnabled = enabled
            state.rules[index].updatedAt = now

        case .setRuleMode(let ruleID, let mode):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].mode = mode
            state.rules[index].updatedAt = now

        case .setSelection(let ruleID, let selection, _):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].selection = selection
            state.rules[index].updatedAt = now
            effects = effects.merging(reparent(selection, onto: ruleID))

        case .reselectSelection(let ruleID, let selection):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].selection = selection
            state.rules[index].updatedAt = now
            effects = effects.merging(reparent(selection, onto: ruleID))

        case .setSchedule(let ruleID, let schedule):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].schedule = schedule
            state.rules[index].updatedAt = now

        case .setLockDelay(let seconds):
            state.lock.delay = LockPolicy.clampDelay(seconds)
            state.lock.updatedAt = now

        case .setLockKind(let kind):
            // Only reachable as a no-op (`kind == state.lock.kind`), because a
            // real type change is always a loosening. Harmless and total.
            state.lock.kind = kind
            state.lock.updatedAt = now

        case .setLockPassword(let digest):
            // Guarded by `lockPasswordRefusal`: the Lock has never been armed.
            state.lock.password = digest
            if state.lock.kind == .delay { state.lock.kind = .both }
            state.lock.updatedAt = now

        case .clearLockPassword:
            // Only reachable as a no-op (there is no password). See
            // `applyReleased` for the real removal, which must also demote the
            // kind or the Lock becomes unreleasable.
            state.lock.password = nil
            state.lock.updatedAt = now

        case .setRatchet(let enabled):
            state.lock.isRatchetEnabled = enabled
            state.lock.updatedAt = now

        case .setInstallProtection(let enabled):
            state.installProtectionEnabled = enabled

        case .revokeAuthorization:
            // Always a loosening; never applied here.
            break

        case .cancelPendingChange(let id):
            guard let index = state.pendingChanges.firstIndex(where: { $0.id == id }) else { break }
            let cancelled = state.pendingChanges[index].cancelled(at: now)
            state.pendingChanges[index] = cancelled
            effects.discardSelections.append(.pendingChange(id))

        case .revokeGrant(let id):
            guard let index = state.grants.firstIndex(where: { $0.id == id }) else { break }
            state.grants[index] = state.grants[index].revoked(at: now)

        case .completeOnboarding:
            if state.onboardingCompletedAt == nil { state.onboardingCompletedAt = now }

        case .markTokenExpiry(let observedAt):
            state.tokenExpiryObservedAt = observedAt
        }

        return effects
    }

    /// The selection-table work a rule's new ``SelectionRef`` implies.
    ///
    /// Adoption is enough on its own to reclaim the blob the rule pointed at
    /// before: ``SelectionTable/adopt(selectionID:asRule:at:)`` drops every other
    /// record owned by that rule as part of re-parenting, so there is no separate
    /// discard to emit and no window in which the rule owns two blobs. Clearing a
    /// selection has no record to adopt, so it discards instead.
    private static func reparent(_ selection: SelectionRef?, onto ruleID: UUID) -> SideEffects {
        guard let selection else {
            return SideEffects(discardSelections: [.rule(ruleID)])
        }
        return SideEffects(
            adoptSelections: [SelectionAdoption(selectionID: selection.id, ruleID: ruleID)]
        )
    }

    /// Assigns `sortIndex` by the given order; ids not listed keep their relative
    /// order behind the listed ones, and unknown ids are ignored.
    private static func reorder(_ state: inout GateState, to orderedIDs: [UUID], now: Date) {
        var position: [UUID: Int] = [:]
        for (offset, id) in orderedIDs.enumerated() { position[id] = offset }

        let fallbackBase = orderedIDs.count
        let ordered = state.rules.enumerated().sorted { lhs, rhs in
            let left = position[lhs.element.id] ?? (fallbackBase + lhs.offset)
            let right = position[rhs.element.id] ?? (fallbackBase + rhs.offset)
            if left == right { return lhs.offset < rhs.offset }
            return left < right
        }.map(\.element)

        state.rules = ordered
        for index in state.rules.indices where state.rules[index].sortIndex != index {
            state.rules[index].sortIndex = index
            state.rules[index].updatedAt = now
        }
    }

    /// Keeps `sortIndex` dense and in array order, the invariant
    /// ``GateState/migrate(_:now:calendar:)`` also restores.
    private static func normalizeSortIndices(in state: inout GateState) {
        for index in state.rules.indices where state.rules[index].sortIndex != index {
            state.rules[index].sortIndex = index
        }
    }

    // MARK: - The lock clock mirror

    /// The Keychain mirror the current queue implies, or `nil` when nothing is
    /// queued.
    ///
    /// The App Group container is deleted with the app; Keychain items are not
    /// (docs/04-product-spec.md V1-3). Mirroring the soonest live deadline is
    /// what makes delete-and-reinstall cost the same as waiting.
    ///
    /// The anchor is the soonest *dated* open change. If every open change is
    /// password-only — a ``LockKind/password`` lock, where nothing ripens on time
    /// — the oldest one anchors the record with a `nil` date, so the Keychain
    /// still records that the Lock is engaged rather than reading as idle.
    public static func lockClockMirror(for state: GateState, now: Date) -> LockClockRecord? {
        let open = state.pendingChanges.pending
        guard !open.isEmpty else { return nil }

        let dated = open.filter { $0.earliestApplyAt != nil }
        let soonest = dated.min(by: { lhs, rhs in
            (lhs.earliestApplyAt ?? .distantFuture) < (rhs.earliestApplyAt ?? .distantFuture)
        })
        let oldest = open.min(by: { $0.requestedAt < $1.requestedAt })

        guard let anchor = soonest ?? oldest else { return nil }

        return LockClockRecord(
            pendingChangeID: anchor.id,
            earliestApplyAt: anchor.earliestApplyAt,
            lockConfigHash: state.lock.configHash,
            installID: state.installID,
            updatedAt: now
        )
    }

    /// Recomputes ``GateState/lockClock`` and reports whether the Keychain copy
    /// needs rewriting.
    ///
    /// `updatedAt` is only bumped when something the record actually describes
    /// has moved — the merge rule in ``LockClockRecord/merge(appGroup:keychain:)``
    /// is "trust the newer copy", so a gratuitous bump would let a no-op App
    /// Group write outrank a real Keychain deadline.
    @discardableResult
    private static func refreshLockClock(in state: inout GateState, now: Date) -> SideEffects {
        let candidate = lockClockMirror(for: state, now: now)
        let current = state.lockClock

        let unchanged = candidate?.pendingChangeID == current?.pendingChangeID
            && candidate?.earliestApplyAt == current?.earliestApplyAt
            && candidate?.lockConfigHash == current?.lockConfigHash
            && candidate?.installID == current?.installID
        if unchanged { return SideEffects.none }

        state.lockClock = candidate
        return SideEffects(mirrorsLockClock: true)
    }

    // MARK: - Release (the loosening finally lands)

    /// Releases a change whose deadline has passed.
    ///
    /// `Kernel/Engine/Reconciler.swift` owns *when* this is called — on every
    /// `scenePhase == .active` and on every monitor callback
    /// (docs/04-product-spec.md V1-10). This owns what happens.
    public static func releaseOnTime(
        pendingChangeID: UUID, in state: GateState, now: Date
    ) -> ReleaseResult {
        guard let change = state.pendingChanges.first(where: { $0.id == pendingChangeID }) else {
            return ReleaseResult(state: state, status: .notFound)
        }
        guard change.status == .pending else {
            return ReleaseResult(state: state, status: .alreadyResolved(change.status))
        }
        guard change.isApplicable else {
            return ReleaseResult(state: state, status: .notApplicable)
        }
        guard change.isRipe(at: now) else {
            return ReleaseResult(state: state, status: .notRipe(remaining: change.remaining(at: now)))
        }
        return perform(release: change, in: state, now: now)
    }

    /// Releases a change by presenting the partner passphrase.
    ///
    /// **A separate release path, not a second deadline** — under
    /// ``LockKind/both`` the passphrase short-circuits a deadline that is still
    /// running, and under ``LockKind/password`` it is the only way through at all.
    /// The deadline is never rewritten by a password attempt, successful or not,
    /// so a failed attempt cannot shorten the wait and a successful one leaves no
    /// trace on the clock.
    ///
    /// - Parameter hasher: the one-way function. Injected for the same reason
    ///   ``PasswordHashing`` exists: `Tests/` is a platform-agnostic SwiftPM
    ///   package where CryptoKit does not exist (docs/06-build-plan.md step 3.11).
    public static func releaseWithPassword(
        _ candidate: String,
        pendingChangeID: UUID,
        in state: GateState,
        using hasher: some PasswordHashing,
        now: Date
    ) -> ReleaseResult {
        guard let change = state.pendingChanges.first(where: { $0.id == pendingChangeID }) else {
            return ReleaseResult(state: state, status: .notFound)
        }
        guard change.status == .pending else {
            return ReleaseResult(state: state, status: .alreadyResolved(change.status))
        }
        guard change.isApplicable else {
            return ReleaseResult(state: state, status: .notApplicable)
        }

        let verification = state.lock.verify(password: candidate, using: hasher)
        guard verification == .accepted else {
            return ReleaseResult(state: state, status: .passwordRefused(verification))
        }
        return perform(release: change, in: state, now: now)
    }

    /// Every change the Lock has released on elapsed time, applied in deadline
    /// order.
    ///
    /// Deadline order matters: two changes can touch the same rule, and applying
    /// the later one first would leave the earlier one writing over it.
    /// Unrecognized operations are skipped and left `pending` — they are shown
    /// and can be cancelled, but applying an operation whose meaning this build
    /// does not know could loosen anything (``PendingChange/isApplicable``).
    public static func releaseRipe(
        in state: GateState, now: Date
    ) -> (state: GateState, released: [PendingChange], effects: SideEffects) {
        var working = state
        var released: [PendingChange] = []
        var effects = SideEffects()

        let ripe = state.pendingChanges
            .ripe(at: now)
            .sorted { ($0.earliestApplyAt ?? .distantFuture) < ($1.earliestApplyAt ?? .distantFuture) }

        for change in ripe {
            // Re-read from `working`: an earlier release (a rule deletion) may
            // have superseded this one on the way past.
            guard let current = working.pendingChanges.first(where: { $0.id == change.id }),
                  current.status == .pending
            else { continue }

            let result = perform(release: current, in: working, now: now)
            working = result.state
            effects = effects.merging(result.effects)
            if let applied = result.released { released.append(applied) }
        }

        return (working, released, effects)
    }

    /// Folds a released change into state and marks it applied.
    private static func perform(
        release change: PendingChange, in state: GateState, now: Date
    ) -> ReleaseResult {
        var working = state

        // Marked applied *before* the operation runs, not after. Releasing a
        // `.deleteRule` supersedes every other change still queued against that
        // rule, and the change doing the deleting must not supersede itself —
        // ``PendingChange/applied(at:)`` is a no-op on an already-resolved
        // record, so it would end up `.superseded` and read as never having
        // happened.
        var applied = change
        if let index = working.pendingChanges.firstIndex(where: { $0.id == change.id }) {
            applied = working.pendingChanges[index].applied(at: now)
            working.pendingChanges[index] = applied
        }

        var effects = applyReleased(change.operation, in: &working, now: now)
        // The staged blob has either just been adopted onto the rule — in which
        // case it is no longer owned by this change and this is a no-op — or it
        // is dead weight. Callers must run `adoptSelections` before
        // `discardSelections` for exactly that reason.
        effects.discardSelections.append(.pendingChange(change.id))
        effects = effects.merging(refreshLockClock(in: &working, now: now))
        working.updatedAt = now

        return ReleaseResult(state: working, status: .released(applied), effects: effects)
    }

    /// The inverse projection: a persisted ``PendingChange/Operation`` back into
    /// `GateState`.
    ///
    /// Public because `Reconciler` needs exactly this and must not grow a second
    /// copy of it — two implementations of "what does a released loosening do"
    /// is precisely how a product like this ends up enforcing something the user
    /// was told it would stop enforcing.
    @discardableResult
    public static func applyReleased(
        _ operation: PendingChange.Operation, in state: inout GateState, now: Date
    ) -> SideEffects {
        var effects = SideEffects()

        switch operation {

        case .disableRule(let ruleID):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].isEnabled = false
            state.rules[index].updatedAt = now

        case .deleteRule(let ruleID):
            state.rules.removeAll { $0.id == ruleID }
            normalizeSortIndices(in: &state)
            effects.discardSelections.append(.rule(ruleID))

            // Everything else queued against a rule that no longer exists is
            // meaningless. Marked superseded rather than deleted, because a
            // pending change that silently vanishes reads as a bug
            // (``PendingChange/Status/superseded``). Their staged blobs go with
            // them — those are the only things in the container with a
            // meaningful size (docs/05-architecture.md, persistence).
            for index in state.pendingChanges.indices {
                let change = state.pendingChanges[index]
                guard change.status == .pending, change.ruleID == ruleID else { continue }
                let superseded = change.superseded(at: now)
                state.pendingChanges[index] = superseded
                effects.discardSelections.append(.pendingChange(superseded.id))
            }

            // Live grants against a deleted rule cannot subtract from a shield
            // set that no longer exists.
            for index in state.grants.indices {
                let grant = state.grants[index]
                guard grant.ruleID == ruleID, grant.isActive(at: now) else { continue }
                state.grants[index] = grant.revoked(at: now)
            }

        case .replaceSelection(let ruleID, let selection):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].selection = selection
            state.rules[index].updatedAt = now
            effects = effects.merging(reparent(selection, onto: ruleID))

        case .setSchedule(let ruleID, let schedule):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].schedule = schedule
            state.rules[index].updatedAt = now

        case .setMode(let ruleID, let mode):
            guard let index = state.ruleIndex(id: ruleID) else { break }
            state.rules[index].mode = mode
            state.rules[index].updatedAt = now

        case .setLockDelay(let seconds):
            state.lock.delay = LockPolicy.clampDelay(seconds)
            state.lock.updatedAt = now

        case .setLockKind(let kind):
            state.lock.kind = kind
            // A kind that cannot use a passphrase must not keep one on file: a
            // stored digest that nothing consults is a secret with no purpose,
            // and it would come back to life the moment the kind changed again.
            if !kind.acceptsPassword { state.lock.password = nil }
            state.lock.updatedAt = now

        case .clearLockPassword:
            state.lock.password = nil
            // **Never leave a `.password`-only Lock with no passphrase.** It
            // would accept no password and ripen on no clock
            // (``LockKind/acceptsDelay``), trapping every future loosening
            // forever with no supported way out but deleting the app — which the
            // Keychain clock is specifically designed to defeat.
            if state.lock.kind != .delay { state.lock.kind = .delay }
            state.lock.updatedAt = now

        case .setRatchet(let enabled):
            state.lock.isRatchetEnabled = enabled
            state.lock.updatedAt = now

        case .setInstallProtection(let enabled):
            state.installProtectionEnabled = enabled

        case .revokeAuthorization:
            effects.revokesAuthorization = true
            // Revocation voids every issued token (docs/03-hard-constraints.md
            // #14), so every rule is now shielding nothing. Recording it here is
            // what puts the recovery screen in front of the user if they
            // re-authorize (docs/04-product-spec.md V1-9) instead of leaving them
            // with rules that look armed and do nothing.
            state.tokenExpiryObservedAt = now

        case .unrecognized:
            // Written by a newer build. Displayed, cancellable, never applied.
            break
        }

        return effects
    }
}

// MARK: - CryptoKit convenience

#if canImport(CryptoKit)
public extension Ratchet {

    /// ``releaseWithPassword(_:pendingChangeID:in:using:now:)`` with the shipping
    /// ``SaltedSHA256Hasher``.
    ///
    /// Gated the same way ``LockPolicy`` gates its own convenience: CryptoKit
    /// does not exist in the platform-agnostic SwiftPM test package, and the
    /// explicit-hasher form above is what `Tests/GateKernelTests/RatchetTests.swift`
    /// calls (docs/06-build-plan.md step 3.11).
    static func releaseWithPassword(
        _ candidate: String,
        pendingChangeID: UUID,
        in state: GateState,
        now: Date
    ) -> ReleaseResult {
        releaseWithPassword(
            candidate,
            pendingChangeID: pendingChangeID,
            in: state,
            using: SaltedSHA256Hasher(),
            now: now
        )
    }
}
#endif
