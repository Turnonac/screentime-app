//
//  RatchetTests.swift
//  GateKernelTests
//
//  docs/06-build-plan.md step 3.11 — "ratchet classification for every
//  `Mutation`; `setDelay` asymmetry".
//
//  WHAT THIS FILE IS DEFENDING
//  V1-4 is the product. A mutation classified as a tightening applies now; a
//  mutation classified as a loosening waits out the Lock. Getting one row of
//  that table backwards is not a bug that shows up as a crash — it is a silent
//  bypass, and the user never learns their commitment device stopped working.
//
//  So the central test here is *exhaustive by construction*: ``mutationCase(of:)``
//  switches over every `Mutation` case with no `default`, so adding a case to
//  `Mutation` stops this file compiling until somebody writes down which column
//  of V1-4's table it belongs in. That is the point of the file, not a side
//  effect of it.
//
//  Everything is injected: no `Date()`, no `Calendar.current`, no I/O.
//  `AuthorizationCenter`, `DeviceActivityCenter` and `ManagedSettingsStore` are
//  unusable in a test process (docs/03-hard-constraints.md #11), and nothing
//  here touches them — `Ratchet` is pure by design.
//

import Foundation
import Testing

@testable import GateKernel

// MARK: - Fixtures

/// A fixed instant, so every deadline in this file is arithmetic rather than
/// a race with the wall clock. 2026-05-14T04:53:20Z.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private let ruleID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let otherRuleID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let selectionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let newSelectionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private let changeID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
private let grantID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

private func digest(
    apps: Int = 10,
    categories: Int = 0,
    webDomains: Int = 0,
    fingerprint: String = "1111111111111111"
) -> SelectionDigest {
    SelectionDigest(
        applicationCount: apps,
        categoryCount: categories,
        webDomainCount: webDomains,
        includesEntireCategory: false,
        fingerprint: fingerprint,
        byteCount: 256,
        capturedAt: now
    )
}

private func selection(
    _ id: UUID = selectionID,
    apps: Int = 10,
    fingerprint: String = "1111111111111111"
) -> SelectionRef {
    SelectionRef(id: id, digest: digest(apps: apps, fingerprint: fingerprint))
}

private func workdaySchedule(
    startHour: Int = 9,
    endHour: Int = 17,
    weekdays: WeekdayMask = .everyday
) -> RuleSchedule {
    RuleSchedule(
        start: TimeOfDay(hour: startHour, minute: 0),
        end: TimeOfDay(hour: endHour, minute: 0),
        weekdays: weekdays,
        warningMinutes: 5
    )
}

private func makeRule(
    id: UUID = ruleID,
    name: String = "Focus",
    mode: RuleMode = .blocklist,
    isEnabled: Bool = true,
    schedule: RuleSchedule? = workdaySchedule(),
    selection ref: SelectionRef? = selection(),
    sortIndex: Int = 0
) -> Rule {
    Rule(
        id: id,
        name: name,
        mode: mode,
        isEnabled: isEnabled,
        schedule: schedule,
        selection: ref,
        sortIndex: sortIndex,
        createdAt: now,
        updatedAt: now
    )
}

/// A password digest built without CryptoKit, so this file compiles and runs on
/// a platform-agnostic toolchain (docs/06-build-plan.md step 3.11). The bytes
/// are never verified against — see ``FakeHasher`` for the release path.
private func storedPassword(_ bytes: [UInt8] = [0xAB, 0xCD]) -> PasswordDigest {
    PasswordDigest(
        algorithm: .saltedSHA256,
        salt: Data([0x01, 0x02, 0x03, 0x04]),
        digest: Data(bytes),
        createdAt: now,
        hint: "the one you wrote down"
    )
}

private func makeState(
    rules: [Rule] = [makeRule()],
    lock: LockPolicy = .default,
    pendingChanges: [PendingChange] = [],
    grants: [Grant] = [],
    installProtectionEnabled: Bool = false,
    onboardingCompletedAt: Date? = now
) -> GateState {
    GateState(
        schemaVersion: GateState.currentSchemaVersion,
        generation: 1,
        installID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
        createdAt: now,
        updatedAt: now,
        rules: rules,
        lock: lock,
        installProtectionEnabled: installProtectionEnabled,
        pendingChanges: pendingChanges,
        grants: grants,
        grantLedger: GrantLedger(used: 0, periodStart: now),
        onboardingCompletedAt: onboardingCompletedAt
    )
}

private func openChange(
    id: UUID = changeID,
    operation: PendingChange.Operation = .disableRule(ruleID: ruleID),
    requestedAt: Date = now,
    ripensIn seconds: TimeInterval? = GateLimits.defaultLockDelay
) -> PendingChange {
    PendingChange(
        id: id,
        operation: operation,
        requestedAt: requestedAt,
        earliestApplyAt: seconds.map { requestedAt.addingTimeInterval($0) },
        lockConfigHash: LockPolicy.default.configHash
    )
}

private func liveGrant(id: UUID = grantID, rule: UUID = ruleID) -> Grant {
    Grant(
        id: id,
        ruleID: rule,
        scope: .entireRule,
        issuedAt: now,
        expiresAt: now.addingTimeInterval(300),
        source: .intervention
    )
}

/// A `PasswordHashing` that needs no CryptoKit.
///
/// It reports ``PasswordDigest/Algorithm/saltedSHA256`` deliberately: that is the
/// algorithm `LockPolicy.verify(password:using:)` requires a stored digest to
/// carry before it will even attempt a comparison, and the point of the protocol
/// is that the *release path* is testable on a toolchain with no CryptoKit
/// (`Kernel/Model/LockPolicy.swift`, note on ``PasswordHashing``). The real
/// SHA-256 implementation is exercised in the CryptoKit-fenced tests below.
private struct FakeHasher: PasswordHashing {
    var algorithm: PasswordDigest.Algorithm { .saltedSHA256 }

    func digest(password: String, salt: Data) -> Data {
        Data("\(salt.map(String.init).joined(separator: "."))#\(password)".utf8)
    }
}

// MARK: - The exhaustive table

/// One row per case of `Ratchet`'s `Mutation`.
///
/// The enum exists so the table can be *enumerated*; ``mutationCase(of:)`` is
/// what makes it exhaustive. Internal rather than `private` because it appears
/// in a `@Test(arguments:)` function signature, and Swift will not let an
/// internal declaration name a file-private type.
enum MutationCase: String, CaseIterable, Sendable {
    case createRule
    case deleteRule
    case renameRule
    case reorderRules
    case setRuleEnabled
    case setRuleMode
    case setSelection
    case reselectSelection
    case setSchedule
    case setLockDelay
    case setLockKind
    case setLockPassword
    case clearLockPassword
    case setRatchet
    case setInstallProtection
    case revokeAuthorization
    case cancelPendingChange
    case revokeGrant
    case completeOnboarding
    case markTokenExpiry
}

/// **Exhaustive over `Mutation`, with no `default`.**
///
/// Adding a case to `Mutation` breaks this switch, which breaks the build of
/// this test file, which is the only automated thing standing between a new
/// mutation and an unclassified one. Do not add a `default` here, ever.
private func mutationCase(of mutation: Mutation) -> MutationCase {
    switch mutation {
    case .createRule: .createRule
    case .deleteRule: .deleteRule
    case .renameRule: .renameRule
    case .reorderRules: .reorderRules
    case .setRuleEnabled: .setRuleEnabled
    case .setRuleMode: .setRuleMode
    case .setSelection: .setSelection
    case .reselectSelection: .reselectSelection
    case .setSchedule: .setSchedule
    case .setLockDelay: .setLockDelay
    case .setLockKind: .setLockKind
    case .setLockPassword: .setLockPassword
    case .clearLockPassword: .clearLockPassword
    case .setRatchet: .setRatchet
    case .setInstallProtection: .setInstallProtection
    case .revokeAuthorization: .revokeAuthorization
    case .cancelPendingChange: .cancelPendingChange
    case .revokeGrant: .revokeGrant
    case .completeOnboarding: .completeOnboarding
    case .markTokenExpiry: .markTokenExpiry
    }
}

private struct ClassificationRow: Sendable {
    let subject: MutationCase
    let state: GateState
    let mutation: Mutation
    let direction: MutationDirection
    let rationale: Ratchet.Rationale
    let goesThroughLock: Bool
    var refusal: Ratchet.Refusal? = nil
    /// Why this row reads the way it does, in the spec's own terms.
    let because: String
}

private let classificationTable: [ClassificationRow] = [
    ClassificationRow(
        subject: .createRule,
        state: makeState(rules: []),
        mutation: .createRule(makeRule()),
        direction: .tighten,
        rationale: .addsEnforcement,
        goesThroughLock: false,
        because: "V1-4 TIGHTEN: a new rule can only add enforcement."
    ),
    ClassificationRow(
        subject: .deleteRule,
        state: makeState(),
        mutation: .deleteRule(ruleID: ruleID),
        direction: .loosen,
        rationale: .removesEnforcement,
        goesThroughLock: true,
        because: "V1-4 LOOSEN: deleting a rule removes every block it carried."
    ),
    ClassificationRow(
        subject: .renameRule,
        state: makeState(),
        mutation: .renameRule(ruleID: ruleID, name: "Deep work"),
        direction: .tighten,
        rationale: .cosmetic,
        goesThroughLock: false,
        because: "A rename changes no enforcement; charging 15 minutes would be theatre."
    ),
    ClassificationRow(
        subject: .reorderRules,
        state: makeState(rules: [makeRule(), makeRule(id: otherRuleID, sortIndex: 1)]),
        mutation: .reorderRules(orderedIDs: [otherRuleID, ruleID]),
        direction: .tighten,
        rationale: .cosmetic,
        goesThroughLock: false,
        because: "Order is presentation, not enforcement."
    ),
    ClassificationRow(
        subject: .setRuleEnabled,
        state: makeState(),
        mutation: .setRuleEnabled(ruleID: ruleID, enabled: false),
        direction: .loosen,
        rationale: .removesEnforcement,
        goesThroughLock: true,
        because: "Turning a rule off is the plainest loosening there is."
    ),
    ClassificationRow(
        subject: .setRuleMode,
        state: makeState(),
        mutation: .setRuleMode(ruleID: ruleID, mode: .allowlist),
        direction: .tighten,
        rationale: .addsEnforcement,
        goesThroughLock: false,
        because: "blocklist -> allowlist widens what is blocked over the same tokens."
    ),
    ClassificationRow(
        subject: .setSelection,
        state: makeState(),
        mutation: .setSelection(
            ruleID: ruleID,
            selection: selection(newSelectionID, apps: 12, fingerprint: "2222222222222222"),
            change: .widened
        ),
        direction: .tighten,
        rationale: .addsEnforcement,
        goesThroughLock: false,
        because: "A wider blocklist blocks more."
    ),
    ClassificationRow(
        subject: .reselectSelection,
        state: makeState(),
        mutation: .reselectSelection(
            ruleID: ruleID,
            selection: selection(newSelectionID, apps: 3, fingerprint: "3333333333333333")
        ),
        direction: .tighten,
        rationale: .recoveryReselect,
        goesThroughLock: false,
        because: "V1-9 verbatim: reselecting is a tightening — never gate recovery behind the lock."
    ),
    ClassificationRow(
        subject: .setSchedule,
        state: makeState(),
        mutation: .setSchedule(ruleID: ruleID, schedule: workdaySchedule(startHour: 10)),
        direction: .loosen,
        rationale: .removesEnforcement,
        goesThroughLock: true,
        because: "09:00-17:00 -> 10:00-17:00 is an hour a day of enforcement removed."
    ),
    ClassificationRow(
        subject: .setLockDelay,
        state: makeState(),
        mutation: .setLockDelay(seconds: 60),
        direction: .loosen,
        rationale: .decreasesLockCost,
        goesThroughLock: true,
        because: "V1-3: shortening the delay is itself a loosening."
    ),
    ClassificationRow(
        subject: .setLockKind,
        state: makeState(),
        mutation: .setLockKind(.both),
        direction: .loosen,
        rationale: .decreasesLockCost,
        goesThroughLock: true,
        because: "V1-3 verbatim: changing the lock type is a loosening. Even .delay -> .both."
    ),
    ClassificationRow(
        subject: .setLockPassword,
        state: makeState(onboardingCompletedAt: now),
        mutation: .setLockPassword(storedPassword()),
        direction: .loosen,
        rationale: .refused,
        goesThroughLock: false,
        refusal: .lockPasswordChangeUnavailable,
        because: """
            After the Lock has been armed a new passphrase creates a release path, and \
            PendingChange.Operation has no case to queue it as, so it is refused outright \
            rather than applied for free.
            """
    ),
    ClassificationRow(
        subject: .clearLockPassword,
        state: makeState(lock: LockPolicy(kind: .both, password: storedPassword(), updatedAt: now)),
        mutation: .clearLockPassword,
        direction: .loosen,
        rationale: .decreasesLockCost,
        goesThroughLock: true,
        because: "Removing the partner's authority is a loosening."
    ),
    ClassificationRow(
        subject: .setRatchet,
        state: makeState(),
        mutation: .setRatchet(enabled: false),
        direction: .loosen,
        rationale: .decreasesLockCost,
        goesThroughLock: true,
        because: "Switching the ratchet off makes every future tightening free."
    ),
    ClassificationRow(
        subject: .setInstallProtection,
        state: makeState(installProtectionEnabled: true),
        mutation: .setInstallProtection(enabled: false),
        direction: .loosen,
        rationale: .removesEnforcement,
        goesThroughLock: true,
        because: "V1-8: turning Solid off removes the denyAppInstallation shield."
    ),
    ClassificationRow(
        subject: .revokeAuthorization,
        state: makeState(),
        mutation: .revokeAuthorization,
        direction: .loosen,
        rationale: .removesEnforcement,
        goesThroughLock: true,
        because: "Gate cannot stop the four-tap Settings route; it can refuse to be the quick one."
    ),
    ClassificationRow(
        subject: .cancelPendingChange,
        state: makeState(pendingChanges: [openChange()]),
        mutation: .cancelPendingChange(id: changeID),
        direction: .tighten,
        rationale: .cancellation,
        goesThroughLock: false,
        because: "V1-4: the cancel affordance is itself a tightening (free)."
    ),
    ClassificationRow(
        subject: .revokeGrant,
        state: makeState(grants: [liveGrant()]),
        mutation: .revokeGrant(id: grantID),
        direction: .tighten,
        rationale: .addsEnforcement,
        goesThroughLock: false,
        because: "Ending an unblock early puts the shield back."
    ),
    ClassificationRow(
        subject: .completeOnboarding,
        state: makeState(onboardingCompletedAt: nil),
        mutation: .completeOnboarding,
        direction: .tighten,
        rationale: .cosmetic,
        goesThroughLock: false,
        because: "Bookkeeping; enforces nothing either way."
    ),
    ClassificationRow(
        subject: .markTokenExpiry,
        state: makeState(),
        mutation: .markTokenExpiry(observedAt: now),
        direction: .tighten,
        rationale: .cosmetic,
        goesThroughLock: false,
        because: "Recording that tokens went stale must never cost the user a wait (V1-9)."
    ),
]

@Suite("Ratchet — classification (docs/04-product-spec.md V1-4)")
struct RatchetClassificationTests {

    @Test("The classification table covers every Mutation case exactly once")
    func tableIsExhaustive() {
        let covered = classificationTable.map(\.subject)
        #expect(Set(covered).count == covered.count, "a Mutation case is listed twice")
        #expect(Set(covered) == Set(MutationCase.allCases))

        // And every row's mutation really is the case it claims to be, so a
        // copy-paste in the table cannot quietly leave a case untested while
        // the coverage check above still passes.
        for row in classificationTable {
            #expect(mutationCase(of: row.mutation) == row.subject)
        }
    }

    @Test("Direction, rationale and lock routing", arguments: MutationCase.allCases)
    func classification(_ subject: MutationCase) throws {
        let row = try #require(classificationTable.first { $0.subject == subject })
        let assessment = Ratchet.assess(row.mutation, in: row.state)

        #expect(assessment.direction == row.direction)
        #expect(assessment.rationale == row.rationale)
        #expect(assessment.goesThroughLock == row.goesThroughLock)
        #expect(assessment.refusal == row.refusal)
        #expect(assessment.isImmediate == (row.refusal == nil && !row.goesThroughLock))

        // `direction(of:)` and `assess` must never disagree; the UI reads one
        // and the apply path reads the other.
        #expect(Ratchet.direction(of: row.mutation, in: row.state) == assessment.direction)

        // A refused mutation costs nothing and offers no release path: there is
        // nothing queued to release.
        if row.refusal != nil {
            #expect(assessment.cost == 0)
            #expect(assessment.releasePaths.isEmpty)
        }
    }

    @Test("Applying each case lands where its assessment said it would", arguments: MutationCase.allCases)
    func applyMatchesAssessment(_ subject: MutationCase) throws {
        let row = try #require(classificationTable.first { $0.subject == subject })
        let outcome = Ratchet.applying(row.mutation, to: row.state, now: now)

        switch outcome.disposition {
        case .queued(let change):
            #expect(row.goesThroughLock)
            #expect(change.status == .pending)
            #expect(change.lockConfigHash == row.state.lock.configHash)
        case .applied(let direction):
            #expect(!row.goesThroughLock)
            #expect(direction == row.direction)
            #expect(outcome.state.pendingChanges.pending.isEmpty)
        case .refused(let refusal):
            #expect(refusal == row.refusal)
            #expect(outcome.state == row.state, "a refusal must leave state byte-identical")
        case .noChange:
            Issue.record("\(subject.rawValue) should not be a no-op: \(row.because)")
        }
    }

    @Test("No-op mutations are free and change nothing")
    func noOpIsFree() {
        let state = makeState()
        let outcome = Ratchet.applying(.setRuleEnabled(ruleID: ruleID, enabled: true), to: state, now: now)

        #expect(outcome.assessment.rationale == .noChange)
        #expect(outcome.assessment.direction == .tighten)
        #expect(outcome.assessment.cost == 0)
        #expect(outcome.disposition == .noChange)
        #expect(!outcome.didChangeState)
        #expect(outcome.state == state)
    }
}

// MARK: - The setLockDelay asymmetry

@Suite("Ratchet — the Lock delay asymmetry (docs/04-product-spec.md V1-3)")
struct RatchetLockDelayTests {

    @Test("Increasing the delay is immediate and free")
    func increaseIsImmediate() {
        let state = makeState(lock: LockPolicy(delay: 900, updatedAt: now))
        let assessment = Ratchet.assess(.setLockDelay(seconds: 3600), in: state)

        #expect(assessment.direction == .tighten)
        #expect(assessment.rationale == .increasesLockCost)
        #expect(assessment.goesThroughLock == false)
        #expect(assessment.cost == 0)
        #expect(assessment.isImmediate)

        let outcome = Ratchet.applying(.setLockDelay(seconds: 3600), to: state, now: now)
        #expect(outcome.disposition == .applied(.tighten))
        #expect(outcome.state.lock.delay == 3600)
        #expect(outcome.state.pendingChanges.isEmpty)
    }

    @Test("Decreasing the delay costs exactly oldDelay − newDelay")
    func decreaseCostsTheDifference() throws {
        let state = makeState(lock: LockPolicy(delay: 900, updatedAt: now))

        #expect(Ratchet.cost(of: .setLockDelay(seconds: 840), in: state) == 60)
        #expect(Ratchet.cost(of: .setLockDelay(seconds: 300), in: state) == 600)
        #expect(Ratchet.cost(of: .setLockDelay(seconds: 60), in: state) == 840)

        let outcome = Ratchet.applying(.setLockDelay(seconds: 300), to: state, now: now)
        let change = try #require(outcome.pendingChange)

        #expect(outcome.assessment.direction == .loosen)
        #expect(outcome.assessment.cost == 600)
        #expect(change.earliestApplyAt == now.addingTimeInterval(600))
        #expect(change.operation == .setLockDelay(seconds: 300))
        // The delay itself has NOT moved yet — that is the whole mechanism.
        #expect(outcome.state.lock.delay == 900)
    }

    @Test("A requested delay below the floor is clamped before the cost is computed")
    func clampedBeforeCosting() {
        let state = makeState(lock: LockPolicy(delay: 900, updatedAt: now))
        // 0 seconds would turn the product off; `clampDelay` lifts it to 60.
        #expect(LockPolicy.clampDelay(0) == GateLimits.minLockDelay)
        #expect(Ratchet.cost(of: .setLockDelay(seconds: 0), in: state) == 900 - GateLimits.minLockDelay)
    }

    @Test("Walking the delay down in steps costs exactly as much as one jump")
    func thereIsNoStaircaseShortcut() {
        // The staircase: 900 -> 600 -> 300 -> 60, releasing each step as it ripens.
        var stepwise = makeState(lock: LockPolicy(delay: 900, updatedAt: now))
        var total: TimeInterval = 0
        for target in [600.0, 300.0, 60.0] {
            total += Ratchet.cost(of: .setLockDelay(seconds: target), in: stepwise)
            Ratchet.applyReleased(.setLockDelay(seconds: target), in: &stepwise, now: now)
        }
        #expect(stepwise.lock.delay == 60)

        let oneJump = Ratchet.cost(
            of: .setLockDelay(seconds: 60),
            in: makeState(lock: LockPolicy(delay: 900, updatedAt: now))
        )
        #expect(total == oneJump)
        #expect(total == 840)
    }

    @Test("A no-op delay change is free even though the delay is what it names")
    func sameDelayIsNoChange() {
        let state = makeState(lock: LockPolicy(delay: 900, updatedAt: now))
        let assessment = Ratchet.assess(.setLockDelay(seconds: 900), in: state)
        #expect(assessment.rationale == .noChange)
        #expect(assessment.cost == 0)
        #expect(assessment.goesThroughLock == false)
    }

    @Test("Under a password-only Lock a queued loosening never ripens on time")
    func passwordOnlyLockHasNoDeadline() throws {
        let lock = LockPolicy(kind: .password, delay: 900, password: storedPassword(), updatedAt: now)
        let state = makeState(lock: lock)

        #expect(lock.earliestApplyDate(from: now) == nil)

        let outcome = Ratchet.applying(.deleteRule(ruleID: ruleID), to: state, now: now)
        let change = try #require(outcome.pendingChange)

        #expect(change.earliestApplyAt == nil)
        #expect(change.isRipe(at: now.addingTimeInterval(10 * 365 * 24 * 3600)) == false)
        #expect(change.remaining(at: now) == nil)
        #expect(outcome.assessment.releasePaths == .password)
        #expect(outcome.assessment.releasePaths.hasCountdown == false)
    }

    @Test("Release paths mirror what the Lock actually offers")
    func releasePathsFollowTheLock() {
        #expect(ReleasePaths.available(under: LockPolicy(kind: .delay)) == .elapsedTime)
        #expect(
            ReleasePaths.available(under: LockPolicy(kind: .password, password: storedPassword()))
                == .password
        )
        #expect(
            ReleasePaths.available(under: LockPolicy(kind: .both, password: storedPassword()))
                == [.elapsedTime, .password]
        )
        // A `.both` lock with no digest on file offers only the clock: there is
        // no passphrase to present.
        #expect(ReleasePaths.available(under: LockPolicy(kind: .both)) == .elapsedTime)
    }
}

// MARK: - Cancel, supersede, withdraw

@Suite("Ratchet — the queue")
struct RatchetQueueTests {

    @Test("Cancelling a pending change is free, immediate and needs no Lock")
    func cancelIsFree() throws {
        let state = makeState(pendingChanges: [openChange()])
        let assessment = Ratchet.assess(.cancelPendingChange(id: changeID), in: state)

        #expect(assessment.direction == .tighten)
        #expect(assessment.rationale == .cancellation)
        #expect(assessment.goesThroughLock == false)
        #expect(assessment.cost == 0)

        let outcome = Ratchet.applying(.cancelPendingChange(id: changeID), to: state, now: now)
        let cancelled = try #require(outcome.state.pendingChanges.first { $0.id == changeID })

        #expect(cancelled.status == .cancelled)
        #expect(cancelled.resolvedAt == now)
        #expect(outcome.state.pendingChanges.pending.isEmpty)
        #expect(outcome.effects.discardSelections.contains(.pendingChange(changeID)))
    }

    @Test("Cancelling stays free with the ratchet switch off")
    func cancelIsFreeEvenWithRatchetOff() {
        let lock = LockPolicy(delay: 900, isRatchetEnabled: false, updatedAt: now)
        let state = makeState(lock: lock, pendingChanges: [openChange()])
        let assessment = Ratchet.assess(.cancelPendingChange(id: changeID), in: state)

        // Otherwise a user could be talked into a queue they cannot empty.
        #expect(assessment.goesThroughLock == false)
        #expect(assessment.cost == 0)
    }

    @Test("Cancelling a change that is not open is refused")
    func cancelUnknownIsRefused() {
        let state = makeState()
        let assessment = Ratchet.assess(.cancelPendingChange(id: changeID), in: state)
        #expect(assessment.refusal == .unknownPendingChange(changeID))
    }

    @Test("Re-queueing the same target supersedes rather than stacking two waits")
    func loosenSupersedes() throws {
        let state = makeState()
        let first = Ratchet.applying(.setLockDelay(seconds: 600), to: state, now: now)
        let firstChange = try #require(first.pendingChange)

        let later = now.addingTimeInterval(120)
        let second = Ratchet.applying(.setLockDelay(seconds: 300), to: first.state, now: later)
        let secondChange = try #require(second.pendingChange)

        #expect(second.withdrew.map(\.id) == [firstChange.id])
        let superseded = try #require(second.state.pendingChanges.first { $0.id == firstChange.id })
        #expect(superseded.status == .superseded)
        #expect(superseded.resolvedAt == later)
        #expect(second.state.pendingChanges.pending.map(\.id) == [secondChange.id])
        // One live deadline per target, always.
        #expect(second.state.pendingChanges.pending.count == 1)
    }

    @Test("A tightening that targets an open loosening withdraws it for free")
    func tighteningWithdrawsTheQueuedLoosening() throws {
        let state = makeState()
        let queued = Ratchet.applying(.setRuleEnabled(ruleID: ruleID, enabled: false), to: state, now: now)
        let change = try #require(queued.pendingChange)

        // The user changes their mind back: re-enable is a tightening against
        // the same targetKey.
        var disabled = queued.state
        disabled.rules[0].isEnabled = false
        let back = Ratchet.applying(.setRuleEnabled(ruleID: ruleID, enabled: true), to: disabled, now: now)

        #expect(back.withdrew.map(\.id) == [change.id])
        let withdrawn = try #require(back.state.pendingChanges.first { $0.id == change.id })
        #expect(withdrawn.status == .cancelled)
        #expect(back.state.rules[0].isEnabled)
    }

    @Test("disableRule and deleteRule are different targets and both may be queued")
    func disableAndDeleteDoNotCollapse() {
        let state = makeState()
        let disable = Ratchet.applying(.setRuleEnabled(ruleID: ruleID, enabled: false), to: state, now: now)
        let delete = Ratchet.applying(.deleteRule(ruleID: ruleID), to: disable.state, now: now)

        #expect(delete.withdrew.isEmpty, "a queued disable must not silently become a queued delete")
        #expect(delete.state.pendingChanges.pending.count == 2)
    }

    @Test("A queued selection swap stages the new blob and leaves the old one enforced")
    func selectionSwapStages() throws {
        // Narrowing a blocklist is a loosening: fewer apps blocked.
        let state = makeState()
        let staged = selection(newSelectionID, apps: 4, fingerprint: "4444444444444444")
        let outcome = Ratchet.applying(
            .setSelection(ruleID: ruleID, selection: staged, change: .narrowed),
            to: state,
            now: now
        )
        let change = try #require(outcome.pendingChange)

        #expect(outcome.assessment.direction == .loosen)
        #expect(outcome.effects.stageSelections == [
            Ratchet.SelectionStaging(selectionID: newSelectionID, pendingChangeID: change.id)
        ])
        // The rule still points at the blob that is enforced today.
        #expect(outcome.state.rules[0].selection?.id == selectionID)
    }
}

// MARK: - Mode and selection breadth

@Suite("Ratchet — blocklist vs allowlist (the inversion V1-4 does not spell out)")
struct RatchetBreadthTests {

    @Test("blocklist -> allowlist tightens; allowlist -> blocklist loosens")
    func modeDirections() {
        let blocklist = makeState(rules: [makeRule(mode: .blocklist)])
        let allowlist = makeState(rules: [makeRule(mode: .allowlist)])

        #expect(Ratchet.direction(of: .setRuleMode(ruleID: ruleID, mode: .allowlist), in: blocklist) == .tighten)
        #expect(Ratchet.direction(of: .setRuleMode(ruleID: ruleID, mode: .blocklist), in: allowlist) == .loosen)

        // Setting the mode it already has changes nothing.
        #expect(Ratchet.assess(.setRuleMode(ruleID: ruleID, mode: .blocklist), in: blocklist).rationale == .noChange)
    }

    @Test("Widening inverts between the two modes")
    func widthInverts() {
        let blocklist = makeState(rules: [makeRule(mode: .blocklist)])
        let allowlist = makeState(rules: [makeRule(mode: .allowlist)])
        let wider = selection(newSelectionID, apps: 20, fingerprint: "5555555555555555")

        // More apps on a blocklist = more blocked.
        #expect(
            Ratchet.direction(
                of: .setSelection(ruleID: ruleID, selection: wider, change: .widened), in: blocklist
            ) == .tighten
        )
        // More apps on an ALLOWlist = fewer blocked. This is the exploit the
        // kernel has to see through.
        #expect(
            Ratchet.direction(
                of: .setSelection(ruleID: ruleID, selection: wider, change: .widened), in: allowlist
            ) == .loosen
        )
    }

    @Test("Narrowing inverts the same way")
    func narrowingInverts() {
        let blocklist = makeState(rules: [makeRule(mode: .blocklist)])
        let allowlist = makeState(rules: [makeRule(mode: .allowlist)])
        let narrower = selection(newSelectionID, apps: 2, fingerprint: "6666666666666666")

        #expect(
            Ratchet.direction(
                of: .setSelection(ruleID: ruleID, selection: narrower, change: .narrowed), in: blocklist
            ) == .loosen
        )
        #expect(
            Ratchet.direction(
                of: .setSelection(ruleID: ruleID, selection: narrower, change: .narrowed), in: allowlist
            ) == .tighten
        )
    }

    @Test("`reshaped` — or `I could not tell` — is treated as a loosening in both modes")
    func reshapedIsAlwaysALoosening() {
        for mode in RuleMode.allCases {
            let state = makeState(rules: [makeRule(mode: mode)])
            let other = selection(newSelectionID, apps: 10, fingerprint: "7777777777777777")
            #expect(
                Ratchet.direction(
                    of: .setSelection(ruleID: ruleID, selection: other, change: .reshaped), in: state
                ) == .loosen
            )
        }
    }

    @Test("Clearing a selection loosens; giving an empty rule one tightens")
    func selectionPresenceDominatesBreadth() {
        let withSelection = makeState()
        let withoutSelection = makeState(rules: [makeRule(selection: nil)])

        #expect(
            Ratchet.direction(
                of: .setSelection(ruleID: ruleID, selection: nil, change: .narrowed), in: withSelection
            ) == .loosen
        )
        #expect(
            Ratchet.direction(
                of: .setSelection(ruleID: ruleID, selection: selection(), change: .widened),
                in: withoutSelection
            ) == .tighten
        )
    }

    @Test("Removing a schedule makes a rule unconditional, which is a tightening")
    func removingAWindowTightens() {
        let state = makeState()
        #expect(Ratchet.direction(of: .setSchedule(ruleID: ruleID, schedule: nil), in: state) == .tighten)

        let unconditional = makeState(rules: [makeRule(schedule: nil)])
        #expect(
            Ratchet.direction(
                of: .setSchedule(ruleID: ruleID, schedule: workdaySchedule()), in: unconditional
            ) == .loosen
        )
    }

    @Test("Changing only the warning lead time is cosmetic")
    func warningTimeIsCosmetic() {
        let state = makeState()
        var quieter = workdaySchedule()
        quieter.warningMinutes = 1
        #expect(Ratchet.assess(.setSchedule(ruleID: ruleID, schedule: quieter), in: state).rationale == .cosmetic)
    }

    @Test("WeeklyCoverage computes real set relations, including across midnight")
    func weeklyCoverageRelations() {
        let wide = WeeklyCoverage(workdaySchedule(startHour: 9, endHour: 18))
        let narrow = WeeklyCoverage(workdaySchedule(startHour: 10, endHour: 17))

        #expect(wide.contains(narrow))
        #expect(!narrow.contains(wide))
        #expect(WeeklyCoverage.relation(from: wide, to: narrow) == .narrowed)
        #expect(WeeklyCoverage.relation(from: narrow, to: wide) == .widened)
        #expect(WeeklyCoverage.relation(from: wide, to: wide) == .unchanged)

        // Disjoint windows are neither: "reshaped" is the honest answer.
        let morning = WeeklyCoverage(workdaySchedule(startHour: 6, endHour: 8))
        #expect(WeeklyCoverage.relation(from: narrow, to: morning) == .reshaped)

        // No schedule covers the whole week; a malformed one covers nothing.
        #expect(WeeklyCoverage.always.coveredSeconds == WeeklyCoverage.secondsPerWeek)
        #expect(WeeklyCoverage(nil).coveredSeconds == WeeklyCoverage.secondsPerWeek)
        #expect(WeeklyCoverage.always.contains(wide))
        #expect(!wide.contains(WeeklyCoverage.always))
        #expect(WeeklyCoverage.never.isEmpty)
    }

    @Test("A midnight-crossing window wraps into Sunday rather than being truncated")
    func midnightCrossingCoverage() {
        // 22:00 Saturday -> 06:00 Sunday. Eight hours, none of them lost.
        let overnight = RuleSchedule(
            start: TimeOfDay(hour: 22, minute: 0),
            end: TimeOfDay(hour: 6, minute: 0),
            weekdays: .saturday,
            warningMinutes: nil
        )
        #expect(WeeklyCoverage(overnight).coveredSeconds == 8 * 3600)
    }
}

// MARK: - The ratchet switch

@Suite("Ratchet — the switch (docs/04-product-spec.md V1-4)")
struct RatchetSwitchTests {

    private var ratchetOff: LockPolicy {
        LockPolicy(delay: 900, isRatchetEnabled: false, updatedAt: now)
    }

    @Test("With the switch off a representable tightening queues too")
    func representableTighteningQueues() throws {
        let state = makeState(lock: ratchetOff)
        let outcome = Ratchet.applying(.setRuleMode(ruleID: ruleID, mode: .allowlist), to: state, now: now)
        let change = try #require(outcome.pendingChange)

        #expect(outcome.assessment.direction == .tighten)
        #expect(outcome.assessment.goesThroughLock)
        #expect(outcome.assessment.cost == 900, "a queued tightening costs the full delay, not a difference")
        #expect(change.operation == .setMode(ruleID: ruleID, mode: .allowlist))
        #expect(outcome.state.rules[0].mode == .blocklist, "not applied yet")
    }

    @Test("With the switch off a tightening with no persisted form still applies immediately")
    func unrepresentableTighteningStaysImmediate() {
        let state = makeState(lock: ratchetOff, grants: [liveGrant()])

        // `PendingChange.Operation` has no case for revoking a grant, creating a
        // rule or enabling one. The gap is a missing feature, never a hole:
        // nothing in it can loosen anything.
        for mutation: Mutation in [
            .revokeGrant(id: grantID),
            .createRule(makeRule(id: otherRuleID, sortIndex: 1)),
            .setRuleEnabled(ruleID: ruleID, enabled: true),
        ] {
            let assessment = Ratchet.assess(mutation, in: state)
            #expect(assessment.direction == .tighten)
            #expect(assessment.goesThroughLock == false, "\(mutation) must not need a persisted form")
        }
    }

    @Test("With the switch off, cosmetic, cancellation and recovery stay exempt")
    func exemptTighteningsStayFree() {
        let state = makeState(lock: ratchetOff, pendingChanges: [openChange()])

        let exempt: [Mutation] = [
            .renameRule(ruleID: ruleID, name: "Renamed"),
            .cancelPendingChange(id: changeID),
            .reselectSelection(ruleID: ruleID, selection: selection(newSelectionID, apps: 1)),
            .completeOnboarding,
        ]
        for mutation in exempt {
            #expect(Ratchet.assess(mutation, in: state).goesThroughLock == false)
        }
    }

    @Test("A loosening is queued in every configuration")
    func looseningsAlwaysQueue() {
        for ratchet in [true, false] {
            let state = makeState(lock: LockPolicy(delay: 900, isRatchetEnabled: ratchet, updatedAt: now))
            #expect(Ratchet.assess(.deleteRule(ruleID: ruleID), in: state).goesThroughLock)
        }
    }
}

// MARK: - Refusals

@Suite("Ratchet — refusals")
struct RatchetRefusalTests {

    @Test("A selection over the silent 50-token cap is refused in both directions")
    func tokenCapIsRefused() {
        let state = makeState()
        let over = SelectionRef(
            id: newSelectionID,
            digest: digest(apps: 51, fingerprint: "8888888888888888")
        )

        let widening = Ratchet.assess(
            .setSelection(ruleID: ruleID, selection: over, change: .widened), in: state
        )
        #expect(
            widening.refusal
                == .tokenCapExceeded(
                    collection: .applications, count: 51, limit: GateLimits.maxTokensPerShieldCollection
                )
        )

        // A queued change that would land an over-cap selection is not a lesser
        // evil for having waited: it still produces a rule that looks armed and
        // shields nothing (docs/03-hard-constraints.md #34).
        let narrowing = Ratchet.assess(
            .setSelection(ruleID: ruleID, selection: over, change: .narrowed), in: state
        )
        #expect(narrowing.refusal != nil)

        // Recovery reselection is exempt from the Lock but not from the cap.
        #expect(Ratchet.assess(.reselectSelection(ruleID: ruleID, selection: over), in: state).refusal != nil)
    }

    @Test("Exactly 50 tokens is accepted; 51 is not")
    func capBoundary() {
        let state = makeState()
        for (count, expectRefusal) in [(49, false), (50, false), (51, true)] {
            let ref = SelectionRef(id: newSelectionID, digest: digest(apps: count))
            let assessment = Ratchet.assess(
                .setSelection(ruleID: ruleID, selection: ref, change: .widened), in: state
            )
            #expect((assessment.refusal != nil) == expectRefusal, "\(count) tokens")
        }
    }

    @Test("The 8-rule cap refuses a ninth rule")
    func ruleLimit() {
        let rules = (0..<GateLimits.maxRules).map { index in
            makeRule(id: UUID(), name: "Rule \(index)", sortIndex: index)
        }
        let state = makeState(rules: rules)
        let assessment = Ratchet.assess(.createRule(makeRule(id: UUID())), in: state)
        #expect(assessment.refusal == .ruleLimitReached(limit: GateLimits.maxRules))
    }

    @Test("A duplicate rule id is refused")
    func duplicateRule() {
        let state = makeState()
        #expect(Ratchet.assess(.createRule(makeRule()), in: state).refusal == .duplicateRule(ruleID))
    }

    @Test("A window iOS would throw on is refused at the editor instead")
    func scheduleLimits() throws {
        let state = makeState()

        // Shorter than the 15-minute floor: `startMonitoring` would throw
        // `.intervalTooShort` at whatever moment the schedule is armed.
        let tooShort = RuleSchedule(
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 9, minute: 10),
            warningMinutes: nil
        )
        let refusal = try #require(Ratchet.assess(.setSchedule(ruleID: ruleID, schedule: tooShort), in: state).refusal)
        guard case .invalidSchedule(let issues) = refusal else {
            Issue.record("expected .invalidSchedule, got \(refusal)")
            return
        }
        #expect(issues.contains(.scheduleTooShort(seconds: 600, minimum: GateLimits.minScheduleInterval)))

        // Zero-length and empty-weekday windows are refused too.
        let degenerate = RuleSchedule(
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 9, minute: 0),
            warningMinutes: nil
        )
        #expect(Ratchet.assess(.setSchedule(ruleID: ruleID, schedule: degenerate), in: state).refusal != nil)

        let noDays = RuleSchedule(
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 17, minute: 0),
            weekdays: [],
            warningMinutes: nil
        )
        #expect(Ratchet.assess(.setSchedule(ruleID: ruleID, schedule: noDays), in: state).refusal != nil)
    }

    @Test("Mutations naming a rule that does not exist are refused")
    func unknownRule() {
        let state = makeState()
        let missing: [Mutation] = [
            .deleteRule(ruleID: otherRuleID),
            .renameRule(ruleID: otherRuleID, name: "x"),
            .setRuleEnabled(ruleID: otherRuleID, enabled: false),
            .setRuleMode(ruleID: otherRuleID, mode: .allowlist),
            .setSelection(ruleID: otherRuleID, selection: selection(), change: .widened),
            .setSchedule(ruleID: otherRuleID, schedule: workdaySchedule()),
        ]
        for mutation in missing {
            #expect(Ratchet.assess(mutation, in: state).refusal == .unknownRule(otherRuleID))
        }
    }

    @Test("Setting the first passphrase on a never-armed Lock is a free tightening")
    func firstPasswordIsFree() {
        let fresh = makeState(rules: [], lock: .default, onboardingCompletedAt: nil)
        let assessment = Ratchet.assess(.setLockPassword(storedPassword()), in: fresh)

        #expect(assessment.refusal == nil)
        #expect(assessment.direction == .tighten)
        #expect(assessment.rationale == .increasesLockCost)
        #expect(assessment.isImmediate)

        let outcome = Ratchet.applying(.setLockPassword(storedPassword()), to: fresh, now: now)
        #expect(outcome.state.lock.password == storedPassword())
        // A `.delay` lock that acquires a passphrase must become `.both`, or the
        // digest would be a secret nothing consults.
        #expect(outcome.state.lock.kind == .both)
    }

    @Test("A refused mutation never mutates state")
    func refusalIsInert() {
        let state = makeState()
        let over = SelectionRef(id: newSelectionID, digest: digest(apps: 99))
        let outcome = Ratchet.applying(
            .setSelection(ruleID: ruleID, selection: over, change: .widened), to: state, now: now
        )
        #expect(outcome.state == state)
        #expect(!outcome.didChangeState)
        #expect(Ratchet.apply(.setSelection(ruleID: ruleID, selection: over, change: .widened),
                              to: state, now: now).1 == nil)
    }
}

// MARK: - Release

@Suite("Ratchet — release")
struct RatchetReleaseTests {

    @Test("A change released on time applies its operation and is marked applied")
    func releaseOnTime() throws {
        let state = makeState()
        let queued = Ratchet.applying(.setRuleEnabled(ruleID: ruleID, enabled: false), to: state, now: now)
        let change = try #require(queued.pendingChange)
        let ripe = now.addingTimeInterval(GateLimits.defaultLockDelay)

        // One second early is still early.
        let early = Ratchet.releaseOnTime(
            pendingChangeID: change.id, in: queued.state, now: ripe.addingTimeInterval(-1)
        )
        #expect(early.status == .notRipe(remaining: 1))
        #expect(early.state.rules[0].isEnabled)

        let released = Ratchet.releaseOnTime(pendingChangeID: change.id, in: queued.state, now: ripe)
        let applied = try #require(released.released)
        #expect(applied.status == .applied)
        #expect(applied.resolvedAt == ripe)
        #expect(released.state.rules[0].isEnabled == false)
        #expect(released.effects.discardSelections.contains(.pendingChange(change.id)))
    }

    @Test("releaseRipe applies every ripe change in deadline order")
    func releaseRipeOrdersByDeadline() throws {
        let later = openChange(
            id: UUID(),
            operation: .setLockDelay(seconds: 300),
            requestedAt: now,
            ripensIn: 600
        )
        let sooner = openChange(
            id: UUID(),
            operation: .setRatchet(enabled: false),
            requestedAt: now,
            ripensIn: 60
        )
        let state = makeState(pendingChanges: [later, sooner])

        let result = Ratchet.releaseRipe(in: state, now: now.addingTimeInterval(900))
        #expect(result.released.map(\.id) == [sooner.id, later.id])
        #expect(result.state.lock.delay == 300)
        #expect(result.state.lock.isRatchetEnabled == false)
        #expect(result.state.pendingChanges.pending.isEmpty)
    }

    @Test("Releasing a rule deletion supersedes everything else queued against that rule")
    func deletingARuleSupersedesItsQueue() throws {
        let disable = openChange(id: UUID(), operation: .disableRule(ruleID: ruleID), ripensIn: 1200)
        let delete = openChange(id: UUID(), operation: .deleteRule(ruleID: ruleID), ripensIn: 60)
        let state = makeState(pendingChanges: [disable, delete], grants: [liveGrant()])

        let result = Ratchet.releaseRipe(in: state, now: now.addingTimeInterval(120))
        #expect(result.released.map(\.id) == [delete.id])
        #expect(result.state.rules.isEmpty)

        let orphan = try #require(result.state.pendingChanges.first { $0.id == disable.id })
        #expect(orphan.status == .superseded)
        #expect(result.effects.discardSelections.contains(.rule(ruleID)))
        // A live grant against a deleted rule cannot subtract from a shield set
        // that no longer exists.
        #expect(result.state.grants[0].isActive(at: now.addingTimeInterval(120)) == false)
    }

    @Test("An unrecognized operation from a newer build is shown but never applied")
    func unrecognizedOperationsAreNeverApplied() {
        let alien = openChange(id: UUID(), operation: .unrecognized(type: "setQuantumLock"), ripensIn: 60)
        let state = makeState(pendingChanges: [alien])

        #expect(alien.isApplicable == false)
        let result = Ratchet.releaseRipe(in: state, now: now.addingTimeInterval(600))
        #expect(result.released.isEmpty)
        #expect(result.state.pendingChanges[0].status == .pending, "still cancellable, never applied")

        let direct = Ratchet.releaseOnTime(pendingChangeID: alien.id, in: state, now: now.addingTimeInterval(600))
        #expect(direct.status == .notApplicable)
    }

    @Test("A correct passphrase releases a change whose clock is still running")
    func passwordShortCircuitsTheClock() throws {
        let hasher = FakeHasher()
        let digest = PasswordDigest.make(password: "open sesame", salt: Data([7, 7, 7]), hasher: hasher, now: now)
        let lock = LockPolicy(kind: .both, delay: 900, password: digest, updatedAt: now)
        let state = makeState(lock: lock, pendingChanges: [openChange()])

        let wrong = Ratchet.releaseWithPassword(
            "guess", pendingChangeID: changeID, in: state, using: hasher, now: now
        )
        #expect(wrong.status == .passwordRefused(.rejected))
        #expect(wrong.state == state, "a failed attempt must not move the deadline")

        let right = Ratchet.releaseWithPassword(
            "open sesame", pendingChangeID: changeID, in: state, using: hasher, now: now
        )
        let applied = try #require(right.released)
        #expect(applied.status == .applied)
        #expect(right.state.rules[0].isEnabled == false)
    }

    @Test("A `.delay` Lock has no passphrase to present")
    func delayOnlyLockRefusesPasswords() {
        let state = makeState(pendingChanges: [openChange()])
        let result = Ratchet.releaseWithPassword(
            "anything", pendingChangeID: changeID, in: state, using: FakeHasher(), now: now
        )
        #expect(result.status == .passwordRefused(.notConfigured))
    }

    @Test("A digest written by a newer build reports unsupportedAlgorithm, not `wrong password`")
    func unsupportedAlgorithmIsItsOwnAnswer() {
        let alien = PasswordDigest(
            algorithm: .unsupported("argon2id"),
            salt: Data([1]),
            digest: Data([2]),
            createdAt: now
        )
        let lock = LockPolicy(kind: .both, password: alien, updatedAt: now)
        let state = makeState(lock: lock, pendingChanges: [openChange()])

        let result = Ratchet.releaseWithPassword(
            "whatever", pendingChangeID: changeID, in: state, using: FakeHasher(), now: now
        )
        #expect(result.status == .passwordRefused(.unsupportedAlgorithm))
    }

    @Test("Releasing the only passphrase demotes the Lock so it can never be unreleasable")
    func clearingAPasswordDemotesTheKind() {
        var state = makeState(
            lock: LockPolicy(kind: .password, delay: 900, password: storedPassword(), updatedAt: now)
        )
        Ratchet.applyReleased(.clearLockPassword, in: &state, now: now)

        #expect(state.lock.password == nil)
        // A `.password` lock with no passphrase would accept nothing and ripen
        // on no clock: every future loosening trapped forever.
        #expect(state.lock.kind == .delay)
    }

    @Test("Releasing a lock-kind change that cannot use a passphrase drops the digest")
    func demotingTheKindDropsTheDigest() {
        var state = makeState(
            lock: LockPolicy(kind: .both, delay: 900, password: storedPassword(), updatedAt: now)
        )
        Ratchet.applyReleased(.setLockKind(.delay), in: &state, now: now)

        #expect(state.lock.kind == .delay)
        #expect(state.lock.password == nil, "a secret nothing consults must not lie in wait")
    }

    @Test("Revoking authorization routes the user to recovery afterwards")
    func revokeAuthorizationMarksTokenExpiry() {
        var state = makeState()
        let effects = Ratchet.applyReleased(.revokeAuthorization, in: &state, now: now)

        #expect(effects.revokesAuthorization)
        #expect(state.tokenExpiryObservedAt == now)
        #expect(state.needsRecovery)
    }

    @Test("Releasing an already-resolved or unknown change is reported, not applied")
    func releaseEdgeCases() {
        let cancelled = openChange().cancelled(at: now)
        let state = makeState(pendingChanges: [cancelled])

        #expect(
            Ratchet.releaseOnTime(pendingChangeID: changeID, in: state, now: now.addingTimeInterval(9_000)).status
                == .alreadyResolved(.cancelled)
        )
        #expect(
            Ratchet.releaseOnTime(pendingChangeID: UUID(), in: state, now: now).status == .notFound
        )
    }

    #if canImport(CryptoKit)
    @Test("The shipping SHA-256 hasher round-trips a passphrase")
    func cryptoKitHasherRoundTrip() {
        let digest = PasswordDigest.make(password: "café", now: now)
        #expect(digest.algorithm == .saltedSHA256)
        #expect(digest.salt.count == PasswordDigest.saltByteCount)
        #expect(digest.verify("café"))
        // NFC normalization: e + combining acute is the same passphrase to the
        // user and must be the same passphrase to the Lock.
        #expect(digest.verify("cafe\u{0301}"))
        #expect(!digest.verify("cafe"))

        let lock = LockPolicy(kind: .both, delay: 900, password: digest, updatedAt: now)
        let state = makeState(lock: lock, pendingChanges: [openChange()])
        let result = Ratchet.releaseWithPassword("café", pendingChangeID: changeID, in: state, now: now)
        #expect(result.released?.status == .applied)
    }
    #endif
}

// MARK: - The Keychain mirror

@Suite("Ratchet — the Lock clock mirror")
struct RatchetLockClockMirrorTests {

    @Test("Queueing a loosening produces a mirror record and asks for a Keychain write")
    func queueingArmsTheMirror() throws {
        let state = makeState()
        let outcome = Ratchet.applying(.deleteRule(ruleID: ruleID), to: state, now: now)
        let change = try #require(outcome.pendingChange)
        let mirror = try #require(outcome.state.lockClock)

        #expect(outcome.effects.mirrorsLockClock)
        #expect(mirror.pendingChangeID == change.id)
        #expect(mirror.earliestApplyAt == now.addingTimeInterval(GateLimits.defaultLockDelay))
        #expect(mirror.lockConfigHash == state.lock.configHash)
        #expect(mirror.installID == state.installID)
        #expect(!mirror.isIdle)
    }

    @Test("The mirror anchors on the SOONEST live deadline")
    func mirrorTracksTheSoonestDeadline() throws {
        let far = openChange(id: UUID(), operation: .deleteRule(ruleID: ruleID), ripensIn: 7_200)
        let near = openChange(id: UUID(), operation: .setRatchet(enabled: false), ripensIn: 120)
        let state = makeState(pendingChanges: [far, near])

        let mirror = try #require(Ratchet.lockClockMirror(for: state, now: now))
        #expect(mirror.pendingChangeID == near.id)
        #expect(mirror.earliestApplyAt == near.earliestApplyAt)
    }

    @Test("A password-only queue still records that the Lock is engaged")
    func passwordOnlyQueueIsNotIdle() throws {
        let undated = openChange(id: UUID(), ripensIn: nil)
        let state = makeState(
            lock: LockPolicy(kind: .password, password: storedPassword(), updatedAt: now),
            pendingChanges: [undated]
        )
        let mirror = try #require(Ratchet.lockClockMirror(for: state, now: now))

        #expect(mirror.pendingChangeID == undated.id)
        #expect(mirror.earliestApplyAt == nil)
        #expect(mirror.isRipe(at: now.addingTimeInterval(1_000_000)) == false)
    }

    @Test("An empty queue clears the mirror, and cancelling asks for the tombstone write")
    func cancellingClearsTheMirror() {
        #expect(Ratchet.lockClockMirror(for: makeState(), now: now) == nil)

        let queued = Ratchet.applying(.deleteRule(ruleID: ruleID), to: makeState(), now: now)
        let change = queued.pendingChange
        let cancelled = Ratchet.applying(
            .cancelPendingChange(id: change?.id ?? UUID()), to: queued.state, now: now
        )

        #expect(cancelled.state.lockClock == nil)
        #expect(cancelled.effects.mirrorsLockClock, "the Keychain must learn about the cancellation")
    }

    @Test("Re-running the same mutation does not gratuitously bump the mirror")
    func mirrorDoesNotChurn() {
        let state = makeState()
        let first = Ratchet.applying(.setRatchet(enabled: false), to: state, now: now)
        // A second, identical request supersedes the first and re-arms — but a
        // mutation that changes nothing must leave the record alone.
        let noop = Ratchet.applying(.setRuleEnabled(ruleID: ruleID, enabled: true), to: first.state, now: now)
        #expect(noop.effects.mirrorsLockClock == false)
    }
}

// MARK: - Side-effect ordering

@Suite("Ratchet — side effects")
struct RatchetSideEffectTests {

    @Test("Applying a selection immediately re-parents the blob rather than copying it")
    func immediateSelectionAdopts() {
        let state = makeState()
        let wider = selection(newSelectionID, apps: 20, fingerprint: "aaaaaaaaaaaaaaaa")
        let outcome = Ratchet.applying(
            .setSelection(ruleID: ruleID, selection: wider, change: .widened), to: state, now: now
        )

        #expect(outcome.effects.adoptSelections == [
            Ratchet.SelectionAdoption(selectionID: newSelectionID, ruleID: ruleID)
        ])
        #expect(outcome.effects.stageSelections.isEmpty)
        #expect(outcome.state.rules[0].selection?.id == newSelectionID)
    }

    @Test("Clearing a rule's selection discards its blob")
    func clearingDiscards() {
        var state = makeState()
        let effects = Ratchet.applyReleased(
            .replaceSelection(ruleID: ruleID, selection: nil), in: &state, now: now
        )
        #expect(effects.discardSelections == [.rule(ruleID)])
        #expect(state.rules[0].selection == nil)
    }

    @Test("SideEffects merge without duplicating work")
    func effectsMerge() {
        let left = Ratchet.SideEffects(
            adoptSelections: [Ratchet.SelectionAdoption(selectionID: selectionID, ruleID: ruleID)],
            discardSelections: [.rule(ruleID)]
        )
        let right = Ratchet.SideEffects(
            adoptSelections: [Ratchet.SelectionAdoption(selectionID: selectionID, ruleID: ruleID)],
            discardSelections: [.pendingChange(changeID)],
            mirrorsLockClock: true
        )
        let merged = left.merging(right)

        #expect(merged.adoptSelections.count == 1)
        #expect(merged.discardSelections.count == 2)
        #expect(merged.mirrorsLockClock)
        #expect(Ratchet.SideEffects.none.isEmpty)
    }

    @Test("Creating a rule appends it with a normalized sort index")
    func createNormalizesOrder() {
        let existing = makeRule(sortIndex: 0)
        let state = makeState(rules: [existing])
        let outcome = Ratchet.applying(
            .createRule(makeRule(id: otherRuleID, name: "Second", sortIndex: 99)), to: state, now: now
        )

        #expect(outcome.state.rules.map(\.id) == [ruleID, otherRuleID])
        #expect(outcome.state.rules.map(\.sortIndex) == [0, 1])
    }

    @Test("Reordering assigns sort indices by the given order and ignores unknown ids")
    func reorderIsTotal() {
        let state = makeState(rules: [makeRule(sortIndex: 0), makeRule(id: otherRuleID, sortIndex: 1)])
        let outcome = Ratchet.applying(
            .reorderRules(orderedIDs: [otherRuleID, UUID(), ruleID]), to: state, now: now
        )
        #expect(outcome.state.rules.map(\.id) == [otherRuleID, ruleID])
        #expect(outcome.state.rules.map(\.sortIndex) == [0, 1])
    }
}
