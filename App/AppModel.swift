//
//  AppModel.swift
//  Gate
//
//  Build plan: docs/06-build-plan.md PHASE 5. The app's single source of truth
//  and the **only writer of `state.plist`, `selections.plist` and `shield.plist`**
//  (docs/05-architecture.md, single-writer discipline).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  THREE INVARIANTS THIS FILE EXISTS TO ENFORCE
//  ─────────────────────────────────────────────────────────────────────────────
//  1. **`state` is `private(set)`.** No screen can assign to it. The only way a
//     view changes anything durable is `apply(_:note:selection:)`, which routes
//     through `Ratchet` and therefore cannot skip the Lock. That is structural,
//     not a code-review rule: a screen that wanted to write `state.lock.delay`
//     directly would not compile.
//  2. **Every persist is preceded by a `Ratchet` classification.** `Ratchet`
//     decides whether a mutation lands now or is queued behind the Lock
//     (docs/04-product-spec.md V1-4). Bypassing it would make "changing your
//     mind costs time" a UI convention rather than a property of the data.
//  3. **The app never trusts memory across a foreground.** Every activation
//     re-reads the container, because three other processes have been running
//     while we were suspended (docs/04-product-spec.md V1-10).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY RECONCILE RUNS SYNCHRONOUSLY ON THE MAIN ACTOR
//  ─────────────────────────────────────────────────────────────────────────────
//  `Reconciler.reconcile` is a synchronous, non-isolated function that takes
//  `any SelectionResolving` and internally builds `ResolvedTokens`,
//  `ShieldWriter` and `DeviceActivityCenter` values. None of those is `Sendable`
//  — `Token<_>` has no audited conformance — so none of them may cross an
//  isolation boundary or be captured by a `Task`. Calling it synchronously from
//  this `@MainActor` type is therefore the *only* spelling that type-checks
//  under Swift 6 strict concurrency without lying with `@unchecked Sendable`.
//
//  The cost is a main-thread pass that reads two small plists, writes up to ten
//  `ManagedSettingsStore` properties and diffs the activity list. It is bounded
//  by `GateLimits.maxRules` (8) and by the 8 KB `GateState` budget, and it is
//  what the daemon call sites require anyway — `ManagedSettingsStore` writes are
//  already synchronous IPC. If this ever shows up in a hitch trace the fix is to
//  move the *whole* reconcile onto a custom global actor together with the
//  resolver, not to sprinkle `Task { }` around values that cannot travel.
//

import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import Observation
import UserNotifications
import os

import GateKernel
import GateKernelUI

/// Computed, not a stored global: a stored `let` of a type without an audited
/// `Sendable` conformance is a Swift 6 strict-concurrency error, and a `Logger`
/// is a cheap wrapper. Same rule the extensions follow.
private var appLog: Logger {
    Logger(subsystem: GateID.Subsystem.app, category: "AppModel")
}

// MARK: - AppModel

@MainActor
@Observable
final class AppModel {

    // MARK: Startup

    /// Whether the app can do its job at all.
    ///
    /// Both failure cases are real and both have honest copy, because both are
    /// silently catastrophic if presented as anything softer. A container that
    /// will not resolve means the App Group is misconfigured and *nothing* is
    /// being enforced; a `state.plist` that will not decode must never degrade
    /// into an empty `GateState`, because a pass with no rules empties every
    /// store and unblocks everything (`StateStoring.load(orDefault:)`).
    enum Startup: Equatable {
        case pending
        case ready
        case containerUnavailable(String)
        case stateUnreadable(String)

        var isReady: Bool { self == .ready }

        /// True while the app cannot honestly claim to be enforcing anything.
        var isBlocking: Bool {
            switch self {
            case .pending, .ready: false
            case .containerUnavailable, .stateUnreadable: true
            }
        }
    }

    /// No inline default: `startup` is assigned exactly once, in `init`, which
    /// keeps it on `@Observable`'s `@storageRestrictions` initialization path
    /// rather than a default-then-set pair.
    private(set) var startup: Startup

    // MARK: Durable state

    /// The last state this process read or wrote. Never assigned outside
    /// ``adopt(_:)``.
    private(set) var state: GateState

    /// The most recent reconcile, kept whole for the debug screen
    /// (docs/04-product-spec.md V1-11) and to drive the four caller obligations
    /// listed on `Reconciler.reconcile`.
    private(set) var lastReport: ReconcileReport?

    private(set) var lastReconcileError: String?

    // MARK: Authorization

    /// Polled on every foreground, never observed.
    ///
    /// `$authorizationStatus` does not emit on revoke while backgrounded without
    /// a debugger attached (docs/02-api-reference.md §4, thread 820796 — open,
    /// no Apple response), so the publisher is not a supported way to learn that
    /// Gate has been switched off in Settings.
    private(set) var authorizationStatus: AuthorizationStatus = .notDetermined

    private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined

    /// Non-`nil` while an authorization request is in flight, so the button can
    /// disable itself without a second piece of state.
    private(set) var isRequestingAuthorization = false

    /// The last `FamilyControlsError` (or other error) from
    /// `requestAuthorization`, already turned into copy by ``AuthorizationCopy``.
    var authorizationFailure: AuthorizationCopy?

    // MARK: Interventions (V1-7)

    /// Shield taps drained out of `inbox/` that still need the user.
    ///
    /// **Draining deleted the files**, so this array is the only remaining copy
    /// of those requests. Losing it loses the user's tap.
    private(set) var openInterventions: [InterventionRequest] = []

    /// The one being presented, if any.
    var activeIntervention: InterventionRequest?

    // MARK: Recovery (V1-9)

    /// Why the recovery screen is being offered. `nil` means it is not.
    var recovery: RecoveryTrigger?

    /// Why we think tokens went stale. First-class, never an error path.
    enum RecoveryTrigger: String, Equatable, Sendable, CaseIterable, Identifiable {

        var id: String { rawValue }

        /// `ManagedSettingsStore.TokenExpiryMessage`, iOS 26.5+.
        case tokenExpiryMessage
        /// `authorizationStatus` is no longer `.approved` on a foreground.
        case authorizationLost
        /// `GateShieldAction` was handed a token that matched no rule.
        case unmatchedToken
        /// The user said a rule stopped working.
        case userReported
    }

    // MARK: Collaborators

    /// `nil` when the App Group container could not be resolved. Every mutating
    /// path checks it and refuses rather than pretending to save.
    private let store: (any StateStoring)?

    /// Not `Sendable` on purpose — it vends `ResolvedTokens`, which hold
    /// `Token<_>`. Main-actor isolated by virtue of living here, and handed to
    /// `Reconciler.reconcile` synchronously.
    private let selections: AppSelectionStore

    private let inbox: InboxStore?

    private let lockClock = LockClock()

    /// The revision of the Keychain record as this process last saw it.
    ///
    /// `LockClockRecord` (the `state.plist` mirror) carries no revision, so
    /// `LockClockRecord.deadline(revision:)` defaults to `0` and loses every
    /// comparison. Remembering the real number lets the mirror argue its case on
    /// equal terms instead of always deferring, which matters for exactly one
    /// scenario: a change cancelled locally must not be resurrected by an older
    /// Keychain copy on the next launch.
    private var keychainRevision = 0

    /// Per-rule shield subtitles (V1-6's "static line of user-written copy").
    ///
    /// Deliberately **not** in `GateState`: it is presentation copy, it never
    /// affects enforcement, and `GateState` has an 8 KB budget the monitor pays
    /// for on every callback (docs/05-architecture.md). It lives in
    /// `shield.plist`, whose only reader is the shield-configuration extension.
    /// If that file is lost, every rule falls back to the shared fallback copy —
    /// a cosmetic regression, never an unenforced rule.
    private var shieldMessages: [UUID: String] = [:]

    /// `shield.plist` is read back on every publish, so the stored subtitles are
    /// hydrated **once** and never again. Re-hydrating on every publish would
    /// resurrect a message the user had just cleared: the dictionary no longer
    /// has the key, the file still does, and the merge would put it back.
    private var didLoadShieldMessages = false

    /// An observation token whose SDK type is deliberately not named. See

    // MARK: Init

    init() {
        var resolvedStore: (any StateStoring)?
        var status: Startup = .pending

        do {
            // Resolves the container, proves it is writable and creates `inbox/`.
            // Doing it once here means every later failure is a real failure
            // rather than a missing directory.
            try AppGroupContainer.preflight()
            resolvedStore = try FileStateStore()
        } catch {
            status = .containerUnavailable(String(describing: error))
            appLog.fault("""
                App Group container unavailable: \(String(describing: error), privacy: .public)
                """)
        }

        self.store = resolvedStore
        self.selections = AppSelectionStore()
        self.inbox = try? InboxStore()
        self.state = GateState.initial(now: Date())
        self.startup = status
    }

    // MARK: - Derived state (read-only, for screens)

    /// Whether a mutation can be persisted at all. Screens disable their
    /// controls on `false` rather than accepting input that will not survive.
    var isOperational: Bool { store != nil && !startup.isBlocking }

    /// `.approvedWithDataAccess` is the EU-only iOS 26.4 status and is *also*
    /// approved. Gate never asks for it — it needs no usage data — but a user who
    /// granted it elsewhere must not be told their permission is missing.
    /// The case itself is 26.4+, so it can only be *named* inside `#available`
    /// at a 17.0 deployment target — hence the static helper, which keeps that
    /// gate in exactly one place for every caller.
    var isAuthorized: Bool { Self.isApproved(authorizationStatus) }

    static func isApproved(_ status: AuthorizationStatus) -> Bool {
        if status == .approved { return true }
        if #available(iOS 26.4, *), status == .approvedWithDataAccess { return true }
        return false
    }

    var needsOnboarding: Bool {
        !state.hasCompletedOnboarding || !isAuthorized
    }

    var openChanges: [PendingChange] { state.openPendingChanges }

    /// `uniquingKeysWith:` rather than `uniqueKeysWithValues:`: rule ids are
    /// unique after `GateState.migrate` and after every `Ratchet` apply, but a
    /// duplicate here would *trap*, and a display accessor is the last place that
    /// should be able to crash the app.
    var ruleNames: [UUID: String] {
        Dictionary(state.rules.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    func rule(id: UUID) -> Rule? { state.rule(id: id) }

    /// Live grants, soonest expiry first.
    func activeGrants(at now: Date = Date()) -> [Grant] { state.activeGrants(at: now) }

    func grantBudget(at now: Date = Date()) -> GrantEngine.Budget {
        GrantEngine.budget(in: state, now: now)
    }

    /// What tapping "off" on this rule would cost, for the row's lock glyph.
    func disablingGoesThroughLock(ruleID: UUID) -> Bool {
        Ratchet.assess(.setRuleEnabled(ruleID: ruleID, enabled: false), in: state).goesThroughLock
    }

    /// Preview a mutation without performing it — "applies immediately" versus
    /// "unlocks in 12m 04s". Every destructive control in the UI shows this
    /// *before* the tap.
    func assess(_ mutation: Mutation) -> Ratchet.Assessment {
        Ratchet.assess(mutation, in: state)
    }

    func shieldMessage(forRuleID ruleID: UUID) -> String {
        shieldMessages[ruleID] ?? ""
    }

    // MARK: - The single mutating entry point

    /// Applies a mutation through the Ratchet, persists, performs the side
    /// effects the kernel cannot, and reconciles.
    ///
    /// - Parameters:
    ///   - mutation: classified by `Ratchet`. Tightenings land now; loosenings
    ///     are queued behind the Lock (docs/04-product-spec.md V1-4).
    ///   - note: optional user-written context shown in the pending banner.
    ///   - selection: the freshly-picked blob whose ``SelectionRef`` the mutation
    ///     carries, if any. Written into `selections.plist` under whichever owner
    ///     the outcome turns out to need — `.rule` for an applied change,
    ///     `.pendingChange` for a queued one. The owner cannot be known before
    ///     the call, which is why the payload is passed *in* rather than written
    ///     by the caller beforehand.
    ///
    /// - Returns: the outcome, or `nil` when the app is not operational — in
    ///   which case **nothing was attempted** and ``startup`` says why. Never
    ///   returns a success the user cannot rely on.
    @discardableResult
    func apply(
        _ mutation: Mutation,
        note: String? = nil,
        selection: StagedSelection? = nil,
        now: Date = Date()
    ) -> Ratchet.Outcome? {
        guard let store else {
            appLog.error("refusing mutation: no state store")
            return nil
        }

        let outcome = Ratchet.applying(mutation, to: state, now: now, note: note)

        if let refusal = outcome.refusal {
            appLog.notice("""
                refused \(String(describing: mutation), privacy: .public): \
                \(String(describing: refusal), privacy: .public)
                """)
            return outcome
        }

        // ── Persist, before touching anything else ────────────────────────────
        //
        // The order `Reconciler` uses (its steps 4 and 4b), for the same reason:
        // a crash after the state write costs a recomputation, whereas a crash
        // after the *selection* write but before the state write would leave a
        // rule pointing at a `SelectionRef` whose blob is gone. That second case
        // is survivable — `ShieldWriter` refuses a rule whose tokens will not
        // resolve, so the store keeps yesterday's correct answer instead of
        // emptying — but survivable is not a reason to pick it.
        var next = outcome.state
        if outcome.didChangeState {
            next.generation = store.generation &+ 1
            do {
                try store.save(next)
            } catch {
                appLog.error("""
                    could not persist after \(String(describing: mutation), privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
                // The in-memory copy is not adopted: showing a change that did
                // not survive the write is the one lie this screen must not tell.
                return nil
            }
        }
        adopt(next)

        // ── Selection table, in the documented order ──────────────────────────
        //
        // adopt → discard → stage. Adoption re-parents a blob away from the
        // pending change that owned it, so discarding that change's records
        // first would delete the record about to be adopted and leave a rule
        // pointing at a `SelectionRef` with no blob behind it — a rule the
        // reconciler then refuses to write.
        selections.applyEffects(
            outcome.effects,
            newPayload: selection,
            state: next,
            now: now
        )

        // ── The two side effects the kernel cannot perform itself ─────────────
        if outcome.effects.mirrorsLockClock { mirrorLockClock(now: now) }
        if outcome.effects.revokesAuthorization { revokeAuthorization() }

        // ── Re-derive everything ──────────────────────────────────────────────
        publishShieldCopy(now: now)
        reconcile(trigger: .userAction, now: now)
        return outcome
    }

    /// Releases a queued change with the partner passphrase (V1-3).
    ///
    /// A separate release path, never a second deadline: a failed attempt cannot
    /// shorten the wait and a successful one leaves no trace on the clock.
    @discardableResult
    func release(pendingChangeID: UUID, password: String, now: Date = Date()) -> Ratchet.ReleaseResult? {
        guard let store else { return nil }

        let result = Ratchet.releaseWithPassword(
            password,
            pendingChangeID: pendingChangeID,
            in: state,
            using: SaltedSHA256Hasher(),
            now: now
        )
        guard result.released != nil else { return result }

        var next = result.state
        next.generation = store.generation &+ 1
        do {
            try store.save(next)
        } catch {
            appLog.error("""
                could not persist a password release: \(String(describing: error), privacy: .public)
                """)
            return nil
        }
        adopt(next)
        selections.applyEffects(result.effects, newPayload: nil, state: next, now: now)

        if result.effects.mirrorsLockClock { mirrorLockClock(now: now) }
        if result.effects.revokesAuthorization { revokeAuthorization() }

        publishShieldCopy(now: now)
        reconcile(trigger: .userAction, now: now)
        return result
    }

    // MARK: - Reconcile (V1-10, build-plan 5.7)

    /// The same entry point the monitor extension calls, with `role: .app`.
    ///
    /// `.app` is what unlocks state writes, the inbox drain and the shield-copy
    /// republish; the monitor's `.monitor` role has all three off. No capability
    /// is widened here beyond the role's defaults.
    @discardableResult
    func reconcile(
        trigger: ReconcileTrigger,
        now: Date = Date(),
        redrains: Int = 0
    ) -> ReconcileReport? {
        guard let store else { return nil }

        let options = ReconcileOptions(
            role: .app,
            trigger: trigger,
            calendar: .current,
            // The enforcing direction is the default; passing the real status
            // means a revoked install stamps `tokenExpiryObservedAt` and routes
            // to V1-9 instead of quietly writing stores that will never apply.
            isAuthorized: isAuthorized
        )

        // `Reconciler` writes `selections.plist` itself at its step 4b (adopting a
        // released loosening re-parents a blob), and then reads tokens back at
        // step 5. Dropping the cache first is what stops step 5 being served a
        // table from before that re-parent — which would resolve a rule to the
        // selection it was enforcing *yesterday*.
        selections.invalidate()

        let report: ReconcileReport
        do {
            report = try Reconciler.reconcile(
                now: now,
                store: store,
                selections: selections,
                inbox: inbox,
                options: options
            )
        } catch {
            // `reconcile` throws for exactly one reason: `state.plist` exists and
            // will not decode. Stores are left exactly as they are — an empty
            // `GateState` would unblock everything — and the user gets a real
            // recovery path.
            let message = String(describing: error)
            appLog.fault("reconcile failed: \(message, privacy: .public)")
            lastReconcileError = message
            startup = .stateUnreadable(message)
            return nil
        }

        lastReconcileError = nil
        startup = .ready
        adopt(report.state)
        lastReport = report

        for warning in report.warnings {
            appLog.notice("reconcile warning: \(String(describing: warning), privacy: .public)")
        }
        for failure in report.failures {
            appLog.error("reconcile failure: \(failure.description, privacy: .public)")
        }

        // ── The four things the caller still owes ─────────────────────────────
        if report.needsLockClockMirror { mirrorLockClock(now: now) }
        if report.needsAuthorizationRevocation { revokeAuthorization() }
        absorb(openRequests: report.inbox.openRequests)
        rearmBackstops(report.backstopDates)

        // V1-9: the reconciler stamps `tokenExpiryObservedAt` when the inbox
        // carried a token-expiry record or authorization was lost.
        if report.state.needsRecovery, recovery == nil {
            recovery = isAuthorized ? .unmatchedToken : .authorizationLost
        }

        // A drain that hit its per-pass limit left files behind; take them now
        // rather than making the user foreground the app twice. Bounded, because
        // `InboxDrain.deferred` also counts files that could not be *read* — those
        // would defer forever and an unbounded loop here would hang the app.
        if report.inbox.hasMore, redrains < Self.maxInboxRedrains {
            appLog.notice("inbox has more events; draining again")
            return reconcile(trigger: trigger, now: now, redrains: redrains + 1)
        }
        if report.inbox.hasMore {
            appLog.error("""
                inbox still reports \(report.inbox.deferred, privacy: .public) deferred events \
                after \(Self.maxInboxRedrains, privacy: .public) passes; leaving them for the \
                next activation
                """)
        }

        return report
    }

    /// The whole of build-plan step 5.7, in order.
    ///
    /// Called from `GateApp`'s `.onChange(of: scenePhase)` and once at launch.
    func activate(trigger: ReconcileTrigger, now: Date = Date()) async {
        guard store != nil else { return }

        // 1. Poll authorization. Never observed — see `authorizationStatus`.
        refreshAuthorizationStatus()

        // 2. Resolve the Lock clock against the Keychain before anything reads a
        //    deadline. The Keychain copy survives delete-and-reinstall and the
        //    container does not (docs/04-product-spec.md V1-3).
        resolveLockClock(now: now)

        // 3. Make sure `shield.plist` exists and says the right thing before the
        //    reconcile indexes it: `Reconciler` only refreshes an index that is
        //    already there, and inventing shield copy is not its job. It stays
        //    ahead of step 4 for that reason; on a cold launch, where step 4 is
        //    what loads `state` in the first place, `publishShieldCopy` declines
        //    to write at all and the file keeps the copy the last mutation
        //    published — which is the current copy.
        publishShieldCopy(now: now)

        // 4. Reconcile — which also drains `inbox/` and computes the backstops
        //    that step 6 arms.
        reconcile(trigger: trigger, now: now)

        // 5. Ask for notification permission. **Extensions cannot present this
        //    prompt.** If the app never asks, every notification the shield
        //    action posts — the entire sub-26.5 intervention path — silently
        //    vanishes (docs/06-build-plan.md step 5.7).
        await requestNotificationAuthorizationIfNeeded()

        // 6. Clear intervention notifications: we are in the app, which is what
        //    they existed to achieve. Scoped by identifier prefix — calling
        //    `removeAllPendingNotificationRequests()` would also wipe the V1-10
        //    calendar backstops (Extensions/ShieldAction contract).
        await clearInterventionNotifications()

        // 7. Start listening for token expiry, if the OS can tell us.
    }

    // MARK: - Authorization (V1-1)

    func refreshAuthorizationStatus() {
        let wasApproved = isAuthorized
        authorizationStatus = AuthorizationCenter.shared.authorizationStatus
        guard wasApproved, !isAuthorized else { return }

        // Authorization went away while we were backgrounded. Every token we
        // hold is voided (docs/02-api-reference.md §5), so this is a recovery
        // situation and not an error banner.
        // `self.` is required: Logger interpolation is an autoclosure, so this
        // is a closure capture rather than a plain property read.
        appLog.notice("authorization lost: \(String(describing: self.authorizationStatus), privacy: .public)")
        recovery = .authorizationLost
        noteTokenExpiry(source: "authorizationStatus")
    }

    /// V1-1 step 2. Every `FamilyControlsError` case is handled by
    /// ``AuthorizationCopy``; nothing reaches the user as a raw error string.
    func requestAuthorization() async {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        authorizationFailure = nil
        defer { isRequestingAuthorization = false }

        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            refreshAuthorizationStatus()
            appLog.log("authorization granted for .individual")
        } catch {
            authorizationFailure = AuthorizationCopy(error)
            refreshAuthorizationStatus()
            appLog.error("requestAuthorization failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// V1-1 step 2 finishes here: onboarding is complete once the user has
    /// approved *and* dismissed the explanation. Recorded through the Ratchet
    /// like everything else (it is a free, cosmetic tightening).
    func completeOnboarding(now: Date = Date()) {
        apply(.completeOnboarding, now: now)
    }

    /// Revoking from inside the app is a **loosening** and goes through the Lock
    /// (V1-4), so this is only ever reached from `Ratchet`'s side effects — never
    /// called directly by a screen.
    private func revokeAuthorization() {
        AuthorizationCenter.shared.revokeAuthorization { [weak self] result in
            // The completion handler is not documented as main-thread, so the
            // work hops. `Result<Void, any Error>` is **not** `Sendable` and must
            // not be captured by the `Task`; it is flattened to a `String?` here,
            // on whatever thread the handler arrived on, and only that crosses.
            let failure: String?
            switch result {
            case .success: failure = nil
            case .failure(let error): failure = String(describing: error)
            }
            Task { @MainActor in
                if let failure {
                    appLog.error("revokeAuthorization failed: \(failure, privacy: .public)")
                } else {
                    appLog.notice("authorization revoked at the user's request")
                }
                self?.refreshAuthorizationStatus()
            }
        }
    }

    // MARK: - Selections

    /// Encodes a picked selection and stamps its digest.
    ///
    /// `.sortedKeys` so the same selection encodes to the same bytes in every
    /// process and the fingerprint in `SelectionDigest` is stable — that
    /// fingerprint is what `SelectionRecord.isConsistent` uses as a torn-write
    /// detector, and what the monitor checks before spending a decode.
    static func stage(_ selection: FamilyActivitySelection, now: Date) throws -> StagedSelection {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(selection)
        let digest = SelectionDigest.make(
            encodedSelection: payload,
            applicationCount: selection.applicationTokens.count,
            categoryCount: selection.categoryTokens.count,
            webDomainCount: selection.webDomainTokens.count,
            includesEntireCategory: selection.includeEntireCategory,
            now: now
        )
        return StagedSelection(ref: SelectionRef(id: UUID(), digest: digest), payload: payload)
    }

    /// The blob a rule is currently enforcing, for re-seeding the picker.
    func currentSelection(forRuleID ruleID: UUID) -> FamilyActivitySelection? {
        selections.selection(forRuleID: ruleID)
    }

    /// The set relation between two selections, **computed here** because the
    /// kernel never sees a token (docs/03-hard-constraints.md #25).
    ///
    /// Mode-agnostic on purpose: this answers "is the token set bigger or
    /// smaller", and `Ratchet` inverts it for allowlist rules, where a wider
    /// *allowed* set means less is blocked.
    static func breadth(
        from old: FamilyActivitySelection?,
        to new: FamilyActivitySelection
    ) -> BreadthChange {
        guard let old else {
            let isEmpty = new.applicationTokens.isEmpty
                && new.categoryTokens.isEmpty
                && new.webDomainTokens.isEmpty
            return isEmpty ? .unchanged : .widened
        }

        let grew = new.applicationTokens.isSuperset(of: old.applicationTokens)
            && new.categoryTokens.isSuperset(of: old.categoryTokens)
            && new.webDomainTokens.isSuperset(of: old.webDomainTokens)
        let shrank = old.applicationTokens.isSuperset(of: new.applicationTokens)
            && old.categoryTokens.isSuperset(of: new.categoryTokens)
            && old.webDomainTokens.isSuperset(of: new.webDomainTokens)

        // `includeEntireCategory` widens what a category token covers, so a
        // selection that turns it on cannot be called narrower even if it lists
        // fewer tokens. When in doubt the honest answer is `.reshaped`, which
        // `Ratchet` treats as a loosening in both modes.
        let categoryBreadthGrew = new.includeEntireCategory && !old.includeEntireCategory
        let categoryBreadthShrank = old.includeEntireCategory && !new.includeEntireCategory

        switch (grew && !categoryBreadthShrank, shrank && !categoryBreadthGrew) {
        case (true, true): return .unchanged
        case (true, false): return .widened
        case (false, true): return .narrowed
        case (false, false): return .reshaped
        }
    }

    /// Token counts per collection, for the editor's live 50-cap guard (V1-2).
    static func counts(of selection: FamilyActivitySelection) -> [TokenCollection: Int] {
        [
            .applications: selection.applicationTokens.count,
            .categories: selection.categoryTokens.count,
            .webDomains: selection.webDomainTokens.count
        ]
    }

    // MARK: - Recovery (V1-9)

    /// Asks iOS to reissue any identifiers it has rotated, in place.
    ///
    /// iOS 26.5 only; below that the only remedy is re-picking, which the
    /// recovery screen offers either way. Returns one human-readable line per
    /// collection that could not be refreshed — the screen shows them rather
    /// than claiming a clean refresh it did not get, because the 26.5 remedy is
    /// itself reported broken for ~30% of new users (docs/03-hard-constraints.md
    /// #36, FB23391495).
    func refreshTokens(in selection: inout FamilyActivitySelection) -> [String] {
        guard #available(iOS 26.5, *) else {
            return ["This version of iOS cannot re-issue app identifiers. Re-pick your apps below."]
        }

        var problems: [String] = []

        var applications = Array(selection.applicationTokens)
        do {
            try ManagedSettingsStore.refresh(&applications)
            selection.applicationTokens = Set(applications)
        } catch {
            problems.append("Apps could not be refreshed (\(error.localizedDescription)).")
        }

        var categories = Array(selection.categoryTokens)
        do {
            try ManagedSettingsStore.refresh(&categories)
            selection.categoryTokens = Set(categories)
        } catch {
            problems.append("Categories could not be refreshed (\(error.localizedDescription)).")
        }

        var webDomains = Array(selection.webDomainTokens)
        do {
            try ManagedSettingsStore.refresh(&webDomains)
            selection.webDomainTokens = Set(webDomains)
        } catch {
            problems.append("Websites could not be refreshed (\(error.localizedDescription)).")
        }

        return problems
    }

    /// Re-pick a rule's apps. **A tightening, always, free, by V1-9** — never
    /// gated behind the Lock, or a user whose tokens went stale is trapped
    /// outside their own blocks.
    @discardableResult
    func reselect(
        ruleID: UUID,
        selection: FamilyActivitySelection,
        now: Date = Date()
    ) -> Ratchet.Outcome? {
        let staged: StagedSelection
        do {
            staged = try AppModel.stage(selection, now: now)
        } catch {
            appLog.error("could not encode a reselection: \(String(describing: error), privacy: .public)")
            return nil
        }
        return apply(
            .reselectSelection(ruleID: ruleID, selection: staged.ref),
            selection: staged,
            now: now
        )
    }

    /// Recovery finished: clear the flag so the home screen stops offering it.
    func completeRecovery(now: Date = Date()) {
        recovery = nil
        apply(.markTokenExpiry(observedAt: nil), now: now)
    }

    /// Records that tokens may have gone stale, from whichever channel noticed.
    func noteTokenExpiry(source: String, now: Date = Date()) {
        appLog.notice("token expiry observed via \(source, privacy: .public)")
        guard state.tokenExpiryObservedAt == nil else { return }
        apply(.markTokenExpiry(observedAt: now), now: now)
    }

    // V1-9's 26.5 accelerator — `ManagedSettingsStore.TokenExpiryMessage` —
    // is DELIBERATELY NOT OBSERVED here, after two attempts that a real SDK
    // rejected:
    //
    //   1. `NotificationCenter.addObserver(of:for:using:)` — refused, because
    //      the overload requires the message to conform to
    //      `NotificationCenter.MainActorMessage` and this one does not.
    //   2. `addObserver(forName: ...TokenExpiryMessage.name, ...)` — refused,
    //      because that static property "is not concurrency-safe because it
    //      involves shared mutable state" under Swift 6 strict concurrency.
    //
    // The remaining possibility is the AsyncMessage form of the typed API, and
    // guessing a third spelling against an SDK nobody here can read is how the
    // first two rounds were spent. Restore it on a machine with Xcode, where
    // code completion settles the question in seconds.
    //
    // Nothing is lost meanwhile. This was always an accelerator, never a floor:
    // all three recovery routes below work on the iOS 17 deployment target and
    // do not depend on it —
    //   * `ManagedSettingsStore.refresh(&tokens)` on the next reconcile;
    //   * the shield action reporting a token that matches no rule, folded into
    //     `GateState.tokenExpiryObservedAt`;
    //   * the home screen's "a rule stopped working" (`RecoveryTrigger/userReported`).

    // MARK: - Interventions (V1-7)

    /// Takes the requests a drain produced, de-duplicating against what we are
    /// already showing.
    private func absorb(openRequests: [InterventionRequest]) {
        guard !openRequests.isEmpty else { return }
        var known = Set(openInterventions.map(\.id))
        if let activeIntervention { known.insert(activeIntervention.id) }

        for request in openRequests where !known.contains(request.id) {
            openInterventions.append(request)
            known.insert(request.id)

            // A request whose token matched no rule is the V1-9 signature: the
            // shield fired against a token the app can no longer place.
            if request.ruleID == nil, recovery == nil {
                recovery = .unmatchedToken
            }
        }
        promoteNextIntervention()
    }

    /// Presents the oldest actionable request, if nothing else is up.
    func promoteNextIntervention(now: Date = Date()) {
        guard activeIntervention == nil else { return }

        // Anything past `maxAge` is not resurrected: the URL is a pointer, not a
        // capability, and an impulse the user walked away from an hour ago must
        // not be re-offered (GateID.interventionURL).
        openInterventions.removeAll { !$0.isActionable(at: now) }
        guard !openInterventions.isEmpty else { return }
        activeIntervention = openInterventions.removeFirst()
    }

    /// The user completed the wait and typed a reason: issue the grant.
    ///
    /// `grantID: request.id` is load-bearing. `GateShieldAction` already armed a
    /// `gate.grant:<ruleID>|<requestID>` one-shot activity to end this grant; any
    /// other id orphans that timer (`MonitorPlan.diff` sweeps it, so the grant
    /// still expires on its absolute timestamp — it just loses its accelerator).
    @discardableResult
    func grant(
        for request: InterventionRequest,
        reason: String,
        duration: TimeInterval? = nil,
        now: Date = Date()
    ) -> GrantEngine.Issuance? {
        guard let store else { return nil }

        let issuance = GrantEngine.issue(
            for: request,
            in: state,
            now: now,
            calendar: .current,
            isAuthorized: isAuthorized,
            duration: duration,
            reason: reason,
            grantID: request.id
        )

        // `Issuance.state` is always usable — a denial still rolls the ledger and
        // records the resolution — so it is saved on every path.
        var next = issuance.state
        if next != state {
            next.generation = store.generation &+ 1
            do {
                try store.save(next)
            } catch {
                appLog.error("could not persist a grant: \(String(describing: error), privacy: .public)")
                return nil
            }
            adopt(next)
        }

        // `activeIntervention` is deliberately **not** cleared here. It is the
        // `sheet(item:)` binding, so clearing it would dismiss the screen the
        // instant the grant is issued — and the screen still has the one sentence
        // that matters to say: "You can open it now — press Home and tap the app."
        // The screen clears it by dismissing itself when the user is done.
        reconcile(trigger: .grantIssued, now: now)

        if issuance.grant == nil, let denial = issuance.denial {
            appLog.notice("grant denied: \(denial.rawValue, privacy: .public)")
            if denial == .ruleUnresolved, recovery == nil { recovery = .unmatchedToken }
        }
        return issuance
    }

    /// The user backed out. This is the outcome the product exists to produce,
    /// so it is a completion and not a cancellation.
    ///
    /// The resolved copy is computed and dropped on purpose: the `inbox/` record
    /// was deleted when it was drained, and `GateState` has no counter for
    /// "reached the intervention screen and walked away". The bypass-attempt
    /// number Gate *can* show comes from the shield's own "Not now"
    /// (`InboxEvent.Kind.bypassAttempt`), counted at drain time. Persisting this
    /// second, better signal needs a field on `GateState` and is a follow-up, not
    /// something to fake here.
    func dismissIntervention(_ request: InterventionRequest) {
        _ = GrantEngine.dismiss(request)
        if activeIntervention?.id == request.id { activeIntervention = nil }
        openInterventions.removeAll { $0.id == request.id }
        appLog.log("intervention dismissed without a grant")
        promoteNextIntervention()
    }

    /// End a live grant early. A tightening, and the fast "this was wrong" path
    /// the false-positive design calls for (docs/03-hard-constraints.md #35).
    func revokeGrant(id: UUID, now: Date = Date()) {
        apply(.revokeGrant(id: id), now: now)
    }

    // MARK: - Deep links (V1-7, sub-26.5 fallback)

    /// Handles `gate://intervention?rule=…&request=…`.
    ///
    /// The URL is a **pointer, never a payload**: any app on the device can open
    /// `gate://`, so the two UUIDs are only used to look up a record this app
    /// already wrote. If the record is gone — drained and resolved, or expired —
    /// the link does nothing rather than fabricating a request.
    func handle(url: URL, now: Date = Date()) {
        guard let link = GateID.intervention(from: url) else {
            appLog.notice("ignoring unrecognized URL")
            return
        }

        // The record may still be in `inbox/`; a reconcile drains it into
        // `openInterventions`, which is then the only copy.
        reconcile(trigger: .launch, now: now)

        if let match = openInterventions.first(where: { $0.id == link.requestID }) {
            openInterventions.removeAll { $0.id == link.requestID }
            activeIntervention = match
            return
        }
        if activeIntervention?.id == link.requestID { return }

        // Already resolved, expired, or a link some other app invented. The
        // reconcile above has already promoted anything genuinely open, so there
        // is nothing left to do — and fabricating a request from two UUIDs in a
        // URL would turn a custom scheme any app can claim into a way to spend a
        // day's unblock budget.
        appLog.notice("""
            intervention request \(link.requestID.uuidString, privacy: .public) is not open; \
            ignoring the link
            """)
    }

    // MARK: - Notifications

    private func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationAuthorization = settings.authorizationStatus

        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            // No `.timeSensitive` and no critical alerts: neither is entitled,
            // and the shield-action extension deliberately does not carry the
            // entitlement that would be needed to post one.
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            notificationAuthorization = granted ? .authorized : .denied
            appLog.log("notification authorization granted=\(granted, privacy: .public)")
        } catch {
            appLog.error("""
                notification authorization failed: \(String(describing: error), privacy: .public)
                """)
        }
    }

    /// Re-arms the `UNCalendarNotificationTrigger` backstops (V1-10 step 5).
    ///
    /// These exist because `intervalDidStart` / `intervalDidEnd` fire only when
    /// the device is in use (docs/03-hard-constraints.md #27) and the monitor
    /// extension is killed for memory or idleness and has been reported as never
    /// launching at all (#32). A notification cannot enforce anything — it gives
    /// the user a reason to open the app, and opening the app is a reconcile.
    private func rearmBackstops(_ dates: [Date]) {
        let identifiers = dates.enumerated().map { index, date in
            (id: Self.backstopIdentifierPrefix + String(Int(date.timeIntervalSince1970)) + ".\(index)",
             date: date)
        }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()

            // Scoped removal only. `removeAllPendingNotificationRequests()` would
            // also wipe the intervention hand-off notifications the shield-action
            // extension posts (Extensions/ShieldAction contract).
            let pending = await center.pendingNotificationRequests()
            let stale = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(Self.backstopIdentifierPrefix) }
            if !stale.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: stale)
            }

            let calendar = Calendar.current
            for entry in identifiers {
                let content = UNMutableNotificationContent()
                content.title = "Gate"
                content.body = "A block is starting or ending. Open Gate to keep it accurate."
                content.categoryIdentifier = GateID.Notifications.backstopCategory
                content.sound = nil

                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: entry.date
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(
                    identifier: entry.id,
                    content: content,
                    trigger: trigger
                )
                do {
                    try await center.add(request)
                } catch {
                    appLog.error("""
                        could not arm a backstop: \(String(describing: error), privacy: .public)
                        """)
                }
            }
        }
    }

    /// Clears the shield-action extension's pending intervention notifications.
    ///
    /// On iOS 26.5+ those are 12-second silent backstops posted *behind*
    /// `.openParentalControlsApp`, in case that response does nothing under
    /// `.individual` authorization — which is *(unverified)*
    /// (docs/02-api-reference.md §10). Reaching this method means the hand-off
    /// worked, so the backstop is redundant and would read as a phantom alert.
    private func clearInterventionNotifications() async {
        let center = UNUserNotificationCenter.current()
        let prefix = GateID.Notifications.interventionCategory + "."
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        appLog.debug("cleared \(ours.count, privacy: .public) pending intervention notifications")
    }

    static let backstopIdentifierPrefix = GateID.Notifications.backstopCategory + "."

    /// How many extra drain passes one activation will pay for. Two is enough to
    /// clear a burst of shield taps; more than that and the files are not
    /// merely numerous, they are unreadable.
    private static let maxInboxRedrains = 2

    // MARK: - The Lock clock (V1-3)

    /// Reads the Keychain, merges it with the `state.plist` mirror, and heals
    /// whichever copy is behind.
    ///
    /// The Keychain copy survives app deletion; the App Group container does not.
    /// That single fact is what makes delete-and-reinstall not reset the delay.
    private func resolveLockClock(now: Date = Date()) {
        guard let store else { return }

        // The PERSISTED state, never `self.state`: this runs at step 2 of
        // `activate`, and the only thing that loads `state.plist` is the
        // reconcile at step 4. On a cold launch `self.state` is still
        // `GateState.initial`, so reading the mirror from it reports "no
        // mirror", resolves to `.keychainWins`, and then persists that empty
        // state over every rule the user has.
        let stored: GateState
        do {
            stored = try store.load()
        } catch StateStoreError.stateMissing {
            // A genuine first run or a reinstall: there is no file to protect,
            // and mirroring the surviving Keychain deadline into a fresh state
            // is exactly the delete-and-reinstall path (V1-3).
            stored = GateState.initial(now: now)
        } catch {
            // The file exists and will not decode. Writing anything here would
            // destroy it; step 4 raises `.stateUnreadable` and the user gets the
            // recovery path instead.
            appLog.error("""
                lock clock: state.plist exists but will not decode, not resolving: \
                \(String(describing: error), privacy: .public)
                """)
            return
        }

        let mirror = stored.lockClock?.deadline(revision: keychainRevision)
        do {
            let resolution = try lockClock.load(mirror: mirror)
            if let deadline = resolution.deadline {
                keychainRevision = max(keychainRevision, deadline.revision)
            }
            guard resolution.needsMirrorWrite, let deadline = resolution.deadline else { return }

            appLog.notice("""
                lock clock: \(String(describing: resolution), privacy: .public) — mirroring into state
                """)
            // Based on `stored`, so the write carries the persisted install's
            // own `installID`. Stamping the throwaway one a fresh
            // `GateState.initial` mints would make
            // `LockClockRecord.isFromPreviousInstall(currentInstallID:)` lie for
            // any Keychain record that carries no `installID` of its own.
            var next = stored
            next.lockClock = deadline.record(currentInstallID: stored.installID)
            persistQuietly(next, now: now)
        } catch LockClockError.unavailableUntilFirstUnlock(let status) {
            // Before first unlock the item is genuinely unreadable. That is NOT
            // "no lock" — treating it as one would hand the user a free bypass
            // by rebooting. Retry on the next activation.
            appLog.notice("""
                lock clock unavailable until first unlock (\(status, privacy: .public)); retrying later
                """)
        } catch {
            appLog.error("lock clock read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes `state.lockClock` into the Keychain. Keychain first, mirror second:
    /// a crash between the two leaves the Keychain one revision ahead, i.e. the
    /// *stricter* copy survives.
    private func mirrorLockClock(now: Date = Date()) {
        let previous = try? lockClock.readKeychain()
        if let previous { keychainRevision = max(keychainRevision, previous.revision) }

        do {
            let written: LockDeadline
            if let record = state.lockClock,
               let changeID = record.pendingChangeID,
               let earliest = record.earliestApplyAt {
                written = try lockClock.arm(
                    pendingChangeID: changeID,
                    earliestApplyAt: earliest,
                    configHash: record.lockConfigHash,
                    previous: previous,
                    installID: state.installID,
                    now: now
                )
            } else {
                // A tombstone, never a delete: a delete would let the old engaged
                // record in the mirror win on the next launch.
                written = try lockClock.clear(
                    configHash: state.lock.configHash,
                    previous: previous,
                    installID: state.installID,
                    now: now
                )
            }
            keychainRevision = written.revision
            appLog.debug("lock clock mirrored at revision \(written.revision, privacy: .public)")
        } catch {
            // The deadline still lives in `state.plist`, so the wait is still
            // enforced on this install. Only the survives-reinstall guarantee is
            // lost, and only until the next successful write.
            appLog.error("""
                could not mirror the lock clock: \(String(describing: error), privacy: .public)
                """)
        }
    }

    // MARK: - Shield copy (V1-6)

    /// Republishes `shield.plist` — the copy half.
    ///
    /// `Reconciler` maintains the *index* (`ruleIDsByTokenFingerprint`,
    /// `catchAllRuleIDs`) on every pass and deliberately never invents copy; the
    /// app owns titles, subtitles, colors and button labels. Both halves are
    /// preserved here: the existing index is read back and carried forward
    /// untouched, so publishing copy never blinds the extension.
    ///
    /// Publishes **only when `state` has actually been loaded**. This is step 3
    /// of ``activate(trigger:now:)`` and the reconcile at step 4 is what reads
    /// `state.plist`, so on a cold launch `state` is still `GateState.initial`;
    /// writing that out would publish a table with zero entries and prune the
    /// whole index. Reading the file — and therefore hydrating
    /// ``shieldMessages`` — happens either way.
    func publishShieldCopy(now: Date = Date()) {
        guard store != nil else { return }

        var table: ShieldCopyTable
        do {
            table = try ShieldCopyFile.read()
            loadShieldMessages(from: table)
        } catch {
            // Not an error on a first run — the file simply does not exist yet.
            table = ShieldCopyTable(fallback: GateTheme.Shield.fallbackCopy)
        }

        // An empty `state` is only publishable once something has confirmed it
        // really is empty. `startup.isReady` means a reconcile loaded it; a
        // non-empty rule list means it came from somewhere real either way.
        // Neither holds before step 4 of the first `activate`, and the file on
        // disk is already correct there — every writer of a rule name or a
        // subtitle republishes as part of the same call.
        guard startup.isReady || !state.rules.isEmpty else { return }

        let entries = state.rules.map { rule -> ShieldCopy in
            let title = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = shieldMessages[rule.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return GateTheme.Shield.copy(
                ruleID: rule.id,
                title: title.isEmpty ? RuleRow.untitledName : title,
                subtitle: (message?.isEmpty ?? true) ? nil : message,
                // v1 ships no submenu items: `secondaryButtonSubmenuItems` is
                // iOS 26.4+ and is V2-1.
                submenuItems: []
            )
        }

        let before = table
        table.fallback = GateTheme.Shield.fallbackCopy
        table.entries = entries

        // Drop index entries for rules that no longer exist, so a deleted rule's
        // shield stops claiming a name. The reconciler rebuilds the rest.
        let live = state.ruleIDs
        table.ruleIDsByTokenFingerprint = table.ruleIDsByTokenFingerprint.filter {
            live.contains($0.value)
        }
        table.catchAllRuleIDs = table.catchAllRuleIDs.filter { live.contains($0) }

        guard table != before else { return }

        table.schemaVersion = ShieldCopyTable.currentSchemaVersion
        table.generation = state.generation
        table.updatedAt = now

        do {
            let bytes = try ShieldCopyFile.publish(table)
            appLog.debug("published shield.plist (\(bytes, privacy: .public) bytes)")
        } catch {
            appLog.error("could not publish shield.plist: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sets one rule's static shield line (V1-6).
    ///
    /// Presentation only: it changes no token, no window and no lock, so it is
    /// not a `Mutation` and does not touch `GateState`. Saying "cosmetic" here is
    /// a claim about the data, not about intent — nothing the shield *says* can
    /// change what it blocks.
    func setShieldMessage(_ message: String, forRuleID ruleID: UUID, now: Date = Date()) {
        let trimmed = String(message.prefix(ShieldCopy.maxSubtitleLength))
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shieldMessages.removeValue(forKey: ruleID)
        } else {
            shieldMessages[ruleID] = trimmed
        }
        publishShieldCopy(now: now)
    }

    private func loadShieldMessages(from table: ShieldCopyTable) {
        guard !didLoadShieldMessages else { return }
        didLoadShieldMessages = true
        for entry in table.entries where entry.id != GateTheme.Shield.fallbackID {
            if let subtitle = entry.subtitle, !subtitle.text.isEmpty {
                shieldMessages[entry.id] = subtitle.text
            }
        }
    }

    // MARK: - Teardown (V1-10 / hard-constraints #37)

    /// Removes every shield, every activity and every file Gate owns.
    ///
    /// Shields can persist after the app is deleted with no UI to remove them
    /// (docs/03-hard-constraints.md #37), so a prominent teardown is a shipping
    /// requirement rather than a nicety. It deliberately does **not** wait for
    /// the Lock: leaving a user with permanently stuck shields to punish them for
    /// uninstalling would be indefensible, and the four-tap Settings revoke
    /// achieves the same thing anyway (#14).
    func tearDownEverything(now: Date = Date()) {
        let writer = ShieldWriter()
        for rule in state.rules {
            _ = writer.retire(rule: rule.id)
        }
        _ = writer.releaseBackstop()
        _ = writer.applyInstallProtection(false)

        let center = DeviceActivityCenter()
        let ours = center.activities.filter(\.isGateActivity)
        if !ours.isEmpty { center.stopMonitoring(ours) }

        try? inbox?.erase()
        try? selections.erase()
        try? ShieldCopyFile.file().delete()
        try? store?.erase()
        try? lockClock.eraseKeychain()
        keychainRevision = 0

        // Scoped removal only, here as everywhere: the V1-10 calendar backstops
        // and the shield-action hand-off notifications are ours, and nothing
        // else is.
        Task { @MainActor in
            let notificationCenter = UNUserNotificationCenter.current()
            let pending = await notificationCenter.pendingNotificationRequests()
            let ourIdentifiers = pending.map(\.identifier).filter {
                $0.hasPrefix(Self.backstopIdentifierPrefix)
                    || $0.hasPrefix(GateID.Notifications.interventionCategory + ".")
            }
            if !ourIdentifiers.isEmpty {
                notificationCenter.removePendingNotificationRequests(withIdentifiers: ourIdentifiers)
            }
        }

        adopt(GateState.initial(now: now))
        shieldMessages = [:]
        didLoadShieldMessages = true
        openInterventions = []
        activeIntervention = nil
        recovery = nil
        lastReport = nil
        appLog.notice("teardown complete: stores, activities and container files removed")
    }

    // MARK: - Plumbing

    private func adopt(_ next: GateState) {
        state = next
    }

    /// A persist that is allowed to fail quietly: used only for bookkeeping the
    /// next pass can recompute (the lock-clock mirror).
    private func persistQuietly(_ next: GateState, now: Date) {
        guard let store else { return }
        var working = next
        working.generation = store.generation &+ 1
        do {
            try store.save(working)
            adopt(working)
        } catch {
            appLog.error("""
                could not persist bookkeeping: \(String(describing: error), privacy: .public)
                """)
        }
    }

    // MARK: - Debug support (V1-11)

    /// Everything the debug screen renders that only this type can reach.
    struct Diagnostics: Sendable {
        var container: String
        var generation: Int
        var storeKind: String
        var inboxPending: Int
        var selectionBytes: Int
        var stateBytes: Int
        var lockClock: String
    }

    func diagnostics() -> Diagnostics {
        var stateBytes = 0
        if let data = try? PlistFile<GateState>.encode(state) { stateBytes = data.count }

        return Diagnostics(
            container: AppGroupContainer.diagnosticDescription(),
            generation: store?.generation ?? -1,
            storeKind: store.map { String(describing: type(of: $0)) } ?? "none",
            inboxPending: inbox?.pendingCount ?? -1,
            selectionBytes: selections.payloadByteCount,
            stateBytes: stateBytes,
            lockClock: lockClock.diagnosticDescription()
        )
    }

    /// A resolver that behaves exactly as the monitor extension's does: read
    /// `selections.plist`, check `SelectionRecord.isConsistent`, decode the blob,
    /// and return `nil` on every failure so `ShieldWriter` refuses the write
    /// rather than emptying a store.
    ///
    /// A *fresh* instance, not the model's own, so a debug run cannot be served
    /// from a table this process cached earlier in the turn — the extension is
    /// always a cold start and the debug button has to be one too.
    ///
    /// Not `Sendable`; hand it straight to a synchronous `Reconciler.reconcile`
    /// call and drop it.
    func monitorStyleSelectionResolver() -> any SelectionResolving {
        AppSelectionStore()
    }

    /// The last few extension breadcrumbs, without consuming them.
    func peekInbox(limit: Int = 40) -> [InboxEvent] {
        guard let inbox else { return [] }
        return (try? inbox.peek(limit: limit)) ?? []
    }
}

// MARK: - StagedSelection

/// A picked `FamilyActivitySelection`, encoded once, with its digest.
///
/// `Sendable` because it is only bytes and counts: the blob is opaque here, and
/// no `Token<_>` ever reaches this type.
struct StagedSelection: Sendable, Equatable {
    let ref: SelectionRef
    let payload: Data
}

// MARK: - AuthorizationCopy

/// Real copy for every `FamilyControlsError` case (V1-1 step 3).
///
/// The spec names three verbatim; the rest are written in the same register.
/// Nothing here reaches the user as a raw error description, because every one of
/// these has a concrete next action and a raw error hides it.
struct AuthorizationCopy: Equatable, Sendable, Identifiable {

    var id: String { title + message }
    let title: String
    let message: String
    /// True when the fix lives in Settings and we should offer the jump.
    let offersSettings: Bool
    /// True when simply trying again is the right advice.
    let offersRetry: Bool

    init(_ error: any Error) {
        guard let familyError = error as? FamilyControlsError else {
            self.init(
                title: "Gate could not get permission",
                message: "iOS returned an unexpected error: \(error.localizedDescription) "
                    + "Try again, and if it keeps happening, restart your device.",
                offersSettings: false,
                offersRetry: true
            )
            return
        }

        switch familyError {
        case .authenticationMethodUnavailable:
            self.init(
                title: "Set a device passcode first",
                message: "Screen Time needs a device passcode before any app can use it. "
                    + "Open Settings › Face ID & Passcode (or Touch ID & Passcode), turn a "
                    + "passcode on, then come back.",
                offersSettings: true,
                offersRetry: true
            )

        case .invalidAccountType:
            self.init(
                title: "Sign in to iCloud",
                message: "Screen Time enrollment needs a signed-in Apple Account. "
                    + "Open Settings, sign in at the top of the list, then come back.",
                offersSettings: true,
                offersRetry: true
            )

        case .networkError:
            self.init(
                title: "Connect to the internet",
                message: "Enrolling in Screen Time is a one-time online step. "
                    + "Join Wi-Fi or turn on cellular data and try again. "
                    + "After this, Gate works entirely offline.",
                offersSettings: false,
                offersRetry: true
            )

        case .authorizationCanceled:
            self.init(
                title: "Permission cancelled",
                message: "You cancelled the Screen Time prompt. Gate cannot block anything "
                    + "without it. Tap Continue when you are ready.",
                offersSettings: false,
                offersRetry: true
            )

        case .authorizationConflict:
            self.init(
                title: "Another app holds parental controls",
                message: "iOS lets only one app manage Screen Time as a guardian. "
                    + "Turn that app's access off in Settings › Screen Time › "
                    + "Apps with Screen Time Access, then try again.",
                offersSettings: true,
                offersRetry: true
            )

        case .invalidArgument:
            self.init(
                title: "Screen Time is not available here",
                message: "iOS rejected the request. This is what the Simulator always "
                    + "returns — Screen Time only works on a real iPhone or iPad. "
                    + "On a device, restarting usually clears it.",
                offersSettings: false,
                offersRetry: true
            )

        case .restricted:
            self.init(
                title: "Screen Time is restricted on this device",
                message: "A configuration profile, an MDM policy, or an existing Screen Time "
                    + "restriction is blocking new access. Check Settings › Screen Time › "
                    + "Content & Privacy Restrictions.",
                offersSettings: true,
                offersRetry: false
            )

        case .unavailable:
            self.init(
                title: "Screen Time is unavailable",
                message: "iOS says the Screen Time service is not available right now. "
                    + "This is usually temporary — try again in a moment, or after a restart.",
                offersSettings: false,
                offersRetry: true
            )

        case .unauthorized:
            self.init(
                title: "Not authorized for app and website data",
                message: "Gate does not ask for usage data and does not need it. "
                    + "If you see this, close and reopen Gate and try again.",
                offersSettings: false,
                offersRetry: true
            )

        @unknown default:
            // A case added by a newer iOS. Say what is true rather than
            // guessing, and keep the retry.
            self.init(
                title: "Gate could not get permission",
                message: "iOS returned a Screen Time error this version of Gate does not "
                    + "recognize: \(familyError.localizedDescription) Try again, and update "
                    + "Gate if there is an update available.",
                offersSettings: true,
                offersRetry: true
            )
        }
    }

    init(title: String, message: String, offersSettings: Bool, offersRetry: Bool) {
        self.title = title
        self.message = message
        self.offersSettings = offersSettings
        self.offersRetry = offersRetry
    }
}

// MARK: - AppSelectionStore

/// The app's half of the selection seam: `selections.plist`.
///
/// `Kernel/Store/SelectionStore.swift` does not exist yet (`ShieldWriter.swift`
/// names it as a future home), so this type owns both directions until it does:
/// the write side, which only the app may use, and `SelectionResolving`, which
/// `Reconciler` calls back into.
///
/// **Deliberately not `Sendable`.** `resolvedTokens(forRuleID:)` returns
/// `ResolvedTokens`, which holds `Token<_>` values with no audited `Sendable`
/// conformance. It must never be captured in a `Task` or held across an `await`;
/// living inside a `@MainActor` type and being handed to a synchronous
/// `Reconciler.reconcile` call is exactly the usage that is safe.
final class AppSelectionStore: SelectionResolving {

    /// One decoded copy, held between calls so a reconcile that resolves eight
    /// rules pays for one read rather than eight.
    ///
    /// Invalidated by ``invalidate()`` before every reconcile, because
    /// `Reconciler` writes this file itself and a cache that outlived its own
    /// write would answer with the selection a rule was enforcing before a queued
    /// loosening landed.
    private var cached: SelectionTable?

    var payloadByteCount: Int { (table() ?? SelectionTable()).payloadByteCount }

    // MARK: SelectionResolving

    /// Fails **closed**: every failure path returns `nil`, which makes
    /// `ShieldWriter` refuse that rule's write and leave its store exactly as it
    /// was. A store left alone is enforcing yesterday's correct answer; a store
    /// emptied on a failed read is an unblocked app the user asked to have
    /// blocked (docs/03-hard-constraints.md #36).
    func resolvedTokens(forRuleID ruleID: UUID) -> ResolvedTokens? {
        guard let selection = selection(forRuleID: ruleID) else { return nil }
        return ResolvedTokens(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens
        )
    }

    // MARK: Reading

    func selection(forRuleID ruleID: UUID) -> FamilyActivitySelection? {
        guard let record = table()?.record(forRuleID: ruleID) else { return nil }
        return decode(record)
    }

    func selection(forPendingChangeID changeID: UUID) -> FamilyActivitySelection? {
        guard let record = table()?.record(forPendingChangeID: changeID) else { return nil }
        return decode(record)
    }

    private func decode(_ record: SelectionRecord) -> FamilyActivitySelection? {
        // Torn-write detector: the payload no longer hashes to the digest the app
        // stamped on it. Checked before the decode, because a blob that already
        // disagrees with itself is not worth the work.
        guard record.isConsistent else {
            appLog.error("""
                selection blob \(record.id.uuidString, privacy: .public) does not match its digest
                """)
            return nil
        }
        do {
            return try JSONDecoder().decode(FamilyActivitySelection.self, from: record.payload)
        } catch {
            appLog.error("""
                could not decode selection \(record.id.uuidString, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }
    }

    // MARK: Writing

    /// Applies a `Ratchet` side-effect set plus, optionally, one freshly picked
    /// blob whose owner depends on how the mutation landed.
    ///
    /// Order is load-bearing and matches `Reconciler.applySelectionEffects`:
    /// **adopt → discard → stage**.
    func applyEffects(
        _ effects: Ratchet.SideEffects,
        newPayload: StagedSelection?,
        state: GateState,
        now: Date
    ) {
        guard !(effects.isEmpty && newPayload == nil) else { return }

        var working = table() ?? SelectionTable()
        let before = working

        for adoption in effects.adoptSelections {
            working.adopt(selectionID: adoption.selectionID, asRule: adoption.ruleID, at: now)
        }
        for owner in effects.discardSelections {
            working.removeAll(ownedBy: owner)
        }

        if let payload = newPayload {
            // A staged blob belongs to the pending change that will apply it; an
            // applied one belongs to the rule that is enforcing it now. Getting
            // this backwards is how a queued loosening starts enforcing early.
            let staging = effects.stageSelections.first { $0.selectionID == payload.ref.id }
            let owner: SelectionOwner?
            if let staging {
                owner = .pendingChange(staging.pendingChangeID)
            } else if let ruleID = ruleOwning(selectionID: payload.ref.id, in: state) {
                owner = .rule(ruleID)
            } else {
                // Neither staged nor referenced by any rule: the mutation was
                // refused, or superseded on the way through. Nothing to write.
                owner = nil
            }

            if let owner {
                // **One record per owner.** `SelectionTable.record(forRuleID:)`
                // takes the *first* match, and `upsert` keys on the record id, so
                // an applied selection change — which mints a new record id and
                // leaves the old one still claiming the rule — would shadow the
                // new blob behind the old one. The rule would go on enforcing the
                // selection the user just replaced, and nothing anywhere would
                // look wrong. `SelectionTable.adopt` does this same removal for
                // the queued path; this is the immediate path's half.
                working.records.removeAll { $0.owner == owner && $0.id != payload.ref.id }
                working.upsert(SelectionRecord(
                    id: payload.ref.id,
                    owner: owner,
                    payload: payload.payload,
                    digest: payload.ref.digest,
                    updatedAt: now
                ))
            } else {
                appLog.notice("dropping a picked selection that no rule or change references")
            }
        }

        working.pruneOrphans(
            liveRuleIDs: state.ruleIDs,
            livePendingChangeIDs: Set(state.openPendingChanges.map(\.id))
        )

        guard working != before else { return }
        working.schemaVersion = SelectionTable.currentSchemaVersion
        working.generation = state.generation
        working.updatedAt = now
        write(working)
    }

    private func ruleOwning(selectionID: UUID, in state: GateState) -> UUID? {
        state.rules.first { $0.selection?.id == selectionID }?.id
    }

    func erase() throws {
        cached = nil
        try SelectionTableFile.file().delete()
    }

    /// Drops the decoded copy. Cheap: the next read re-decodes a file that is
    /// measured in kilobytes.
    func invalidate() {
        cached = nil
    }

    // MARK: File access

    private func table() -> SelectionTable? {
        if let cached { return cached }
        do {
            cached = try SelectionTableFile.read()
        } catch {
            // Left strictly alone: rewriting this file from a failed read would
            // delete every selection in the install, and that cannot be undone.
            appLog.error("""
                could not read selections.plist: \(String(describing: error), privacy: .public)
                """)
            cached = nil
        }
        return cached
    }

    private func write(_ table: SelectionTable) {
        do {
            let bytes = try SelectionTableFile.write(table)
            cached = table
            appLog.debug("wrote selections.plist (\(bytes, privacy: .public) bytes)")
        } catch {
            appLog.error("""
                could not write selections.plist: \(String(describing: error), privacy: .public)
                """)
        }
    }
}
