//
//  LockClockTests.swift
//  GateKernelTests
//
//  docs/06-build-plan.md step 3.11 — "`LockClock` across a simulated reinstall".
//
//  WHAT THIS FILE IS DEFENDING
//  docs/04-product-spec.md V1-3: *"Store `{ pendingChangeID, earliestApplyAt,
//  lockConfigHash }` in the Keychain … Write both; on launch, trust the Keychain
//  copy if it is newer."* Keychain items survive app deletion; the App Group
//  container does not. If that one asymmetry stops working, deleting and
//  reinstalling Gate costs about fifteen seconds and the delay is a placebo.
//
//  There is **no Keychain in a test process**, and there must not be: `SecItemAdd`
//  against a test bundle with no keychain-access-group entitlement fails with
//  `errSecMissingEntitlement` (-34018), which would make this file test the
//  harness rather than the product. So everything here exercises the *pure*
//  halves — `LockClockRecord.merge(appGroup:keychain:)`, `LockClock.resolve`,
//  `remaining`, `isSatisfied`, `configHash` — none of which touch `SecItem*`.
//  The I/O itself is a device-test-matrix item (Docs/DEVICE-TEST-MATRIX.md).
//
//  `LockClockRecord` lives in `Kernel/Model/LockPolicy.swift` and is
//  Foundation-only, so the merge-rule suite runs on any toolchain. `LockDeadline`
//  and `LockClock` live in `Kernel/Store/LockClock.swift`, which imports
//  Security + CryptoKit, so that suite is fenced the same way the source is.
//

import Foundation
import Testing

@testable import GateKernel

// MARK: - Fixtures

/// 2026-05-14T04:53:20Z. Every instant below is derived from it.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private let installA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
private let installB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
private let changeID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
private let otherChangeID = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!

private let lock = LockPolicy(kind: .delay, delay: 4 * 3600, isRatchetEnabled: true, updatedAt: now)

/// Injected wherever a reconcile is driven from here, so the ledger roll inside
/// ``Reconciler/advance(_:now:calendar:)`` cannot depend on the host's time zone.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}()

private func record(
    change: UUID? = changeID,
    ripensIn seconds: TimeInterval? = 4 * 3600,
    configHash: String = lock.configHash,
    install: UUID = installA,
    writtenAt: Date = now
) -> LockClockRecord {
    LockClockRecord(
        pendingChangeID: change,
        earliestApplyAt: seconds.map { now.addingTimeInterval($0) },
        lockConfigHash: configHash,
        installID: install,
        updatedAt: writtenAt
    )
}

// MARK: - The merge rule (Foundation only)

@Suite("LockClockRecord — trust the newer copy (docs/04-product-spec.md V1-3)")
struct LockClockRecordMergeTests {

    @Test("A fresh install with neither copy has no deadline")
    func noRecordAnywhere() {
        #expect(LockClockRecord.merge(appGroup: nil, keychain: nil) == nil)
    }

    @Test("THE REINSTALL: the container is gone, the Keychain is not, and the deadline survives")
    func keychainSurvivesAWipedContainer() {
        // Install #1 queued a loosening four hours out and mirrored it.
        let mirrored = record()

        // The user deletes Gate. The App Group container goes with it, so the
        // fresh install's `GateState.lockClock` is nil. The Keychain item is
        // untouched.
        let merged = LockClockRecord.merge(appGroup: nil, keychain: mirrored)

        #expect(merged == mirrored)
        #expect(merged?.pendingChangeID == changeID)
        #expect(merged?.remaining(at: now) == (14_400 as TimeInterval))
        #expect(merged?.isRipe(at: now) == false)
        // An absent App Group copy is not evidence the deadline was satisfied —
        // it is evidence the container was deleted.
        #expect(merged?.isFromPreviousInstall(currentInstallID: installB) == true)
    }

    @Test("Reinstalling and shortening the Lock does not shorten the outstanding wait")
    func reconfiguringDoesNotDiscountTheDeadline() throws {
        let armedUnder = record()
        let cheaperLock = LockPolicy(kind: .delay, delay: GateLimits.minLockDelay, updatedAt: now)

        let merged = try #require(LockClockRecord.merge(appGroup: nil, keychain: armedUnder))

        // The config hash notices, and that is ALL it does: a mismatch changes
        // the copy the user sees, never the deadline. Treating it as
        // invalidation would make "reconfigure the Lock" the cleanest bypass in
        // the product.
        #expect(merged.hasConfigDrift(against: cheaperLock))
        #expect(merged.remaining(at: now) == (14_400 as TimeInterval))
        #expect(merged.earliestApplyAt == armedUnder.earliestApplyAt)
    }

    @Test("Whichever copy was written last wins")
    func newerCopyWins() {
        let older = record(change: changeID, ripensIn: 3600, writtenAt: now)
        let newer = record(change: otherChangeID, ripensIn: 7200, writtenAt: now.addingTimeInterval(60))

        #expect(LockClockRecord.merge(appGroup: newer, keychain: older) == newer)
        #expect(LockClockRecord.merge(appGroup: older, keychain: newer) == newer)
    }

    @Test("A tie goes to the Keychain — it is the copy a user cannot clear")
    func tiesGoToTheKeychain() {
        let mirror = record(change: changeID, writtenAt: now)
        let keychain = record(change: otherChangeID, writtenAt: now)

        #expect(LockClockRecord.merge(appGroup: mirror, keychain: keychain) == keychain)
    }

    @Test("A mirror with no Keychain copy is still usable")
    func mirrorAloneSurvives() {
        let mirror = record()
        #expect(LockClockRecord.merge(appGroup: mirror, keychain: nil) == mirror)
    }

    @Test("A record with no write timestamp loses every merge")
    func undatedRecordsLose() throws {
        let undated = LockClockRecord(
            pendingChangeID: changeID,
            earliestApplyAt: now.addingTimeInterval(600),
            lockConfigHash: lock.configHash,
            installID: installA,
            updatedAt: .distantPast
        )
        let dated = record()
        #expect(LockClockRecord.merge(appGroup: undated, keychain: dated) == dated)

        // Decoding a record whose `updatedAt` key is missing produces exactly
        // that shape, and it is the safe direction: it can never displace a copy
        // we can date.
        let plist: [String: Any] = ["pc": changeID.uuidString, "cfg": "x"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let decoded = try PropertyListDecoder().decode(LockClockRecord.self, from: data)
        #expect(decoded.updatedAt == .distantPast)
        #expect(decoded.pendingChangeID == changeID)
    }

    @Test("An idle record is not a deadline")
    func idleRecord() {
        let idle = record(change: nil, ripensIn: nil)
        #expect(idle.isIdle)
        #expect(idle.isRipe(at: now.addingTimeInterval(1_000_000)) == false)
        #expect(idle.remaining(at: now) == nil)
    }

    @Test("A password-only deadline never ripens on time and reports no countdown")
    func passwordOnlyNeverRipens() {
        let queued = record(change: changeID, ripensIn: nil)
        #expect(!queued.isIdle)
        #expect(queued.isRipe(at: now.addingTimeInterval(10 * 365 * 24 * 3600)) == false)
        #expect(queued.remaining(at: now) == nil)
    }

    @Test("`remaining` never goes negative and ripeness is inclusive of the instant")
    func ripeness() {
        let deadline = record(ripensIn: 600)
        #expect(deadline.remaining(at: now.addingTimeInterval(599)) == 1)
        #expect(deadline.isRipe(at: now.addingTimeInterval(599)) == false)
        #expect(deadline.isRipe(at: now.addingTimeInterval(600)))
        #expect(deadline.remaining(at: now.addingTimeInterval(6_000)) == 0)
    }

    @Test("configHash changes with every field that defines the Lock, and with nothing else")
    func configHashCoversTheLock() {
        let base = LockPolicy(kind: .delay, delay: 900, isRatchetEnabled: true, updatedAt: now)

        // `updatedAt` is informational; it must not move the hash, or every
        // launch would look like a reconfiguration.
        var touched = base
        touched.updatedAt = now.addingTimeInterval(10_000)
        #expect(touched.configHash == base.configHash)

        var slower = base
        slower.delay = 1800
        #expect(slower.configHash != base.configHash)

        var loose = base
        loose.isRatchetEnabled = false
        #expect(loose.configHash != base.configHash)

        var partnered = base
        partnered.kind = .both
        partnered.password = PasswordDigest(
            algorithm: .saltedSHA256, salt: Data([1]), digest: Data([2]), createdAt: now
        )
        #expect(partnered.configHash != base.configHash)

        // Deterministic across calls — it is read in the app and compared
        // against a copy written by an earlier launch.
        #expect(base.configHash == LockPolicy(
            kind: .delay, delay: 900, isRatchetEnabled: true, updatedAt: .distantPast
        ).configHash)
    }
}

// MARK: - The Keychain shape

// `Kernel/Store/LockClock.swift` imports Security and CryptoKit, so it is only
// part of the module where those exist. The suite below calls only the pure
// members — `resolve`, `remaining`, `isSatisfied`, `configHash` and the two
// shape conversions — and never `SecItem*`.

#if canImport(Security) && canImport(CryptoKit)

import Security

private func deadline(
    revision: Int,
    change: UUID? = changeID,
    ripensIn seconds: TimeInterval? = 4 * 3600,
    armedAt: Date? = now,
    configHash: String = "cfg",
    install: UUID? = installA,
    writtenAt: Date = now
) -> LockDeadline {
    LockDeadline(
        revision: revision,
        pendingChangeID: change,
        earliestApplyAt: seconds.map { now.addingTimeInterval($0) },
        armedAt: armedAt,
        lockConfigHash: configHash,
        installID: install,
        updatedAt: writtenAt
    )
}

@Suite("LockClock — resolution")
struct LockClockResolutionTests {

    private let clock = LockClock()

    @Test("Neither copy exists")
    func noRecord() {
        #expect(clock.resolve(keychain: nil, mirror: nil) == .noRecord)
    }

    @Test("THE REINSTALL: an engaged Keychain record with no mirror wins and must be written back")
    func reinstall() throws {
        let survivor = deadline(revision: 7)
        let resolution = clock.resolve(keychain: survivor, mirror: nil)

        #expect(resolution == .keychainWins(survivor))
        #expect(resolution.needsMirrorWrite, "the fresh install must adopt this into GateState")
        #expect(resolution.isAuthoritative)
        #expect(resolution.deadline?.isEngaged == true)
        #expect(clock.remaining(survivor, now: now) == 4 * 3600)
        #expect(clock.isSatisfied(survivor, now: now) == false)
        #expect(clock.isSatisfied(survivor, now: now.addingTimeInterval(4 * 3600)))
    }

    @Test("End to end: queue a loosening, wipe the container, and the wait is still owed")
    func simulatedReinstallEndToEnd() throws {
        // ── Install #1 ────────────────────────────────────────────────────
        var state = GateState.initial(now: now, installID: installA)
        state.lock = lock
        state.rules = [
            Rule(id: UUID(), name: "Focus", isEnabled: true, sortIndex: 0, createdAt: now, updatedAt: now)
        ]
        let ruleID = state.rules[0].id

        let queued = Ratchet.applying(.setRuleEnabled(ruleID: ruleID, enabled: false), to: state, now: now)
        let change = try #require(queued.pendingChange)
        let mirror = try #require(queued.state.lockClock)
        #expect(queued.effects.mirrorsLockClock)

        // What `LockClock.arm` would have put in the Keychain. (The write itself
        // is `SecItemUpdate`/`SecItemAdd` and is a device test.)
        let keychainItem = mirror.deadline(revision: 1, armedAt: now)
        #expect(keychainItem.isEngaged)
        #expect(keychainItem.pendingChangeID == change.id)

        // ── The user deletes Gate ─────────────────────────────────────────
        // The App Group container is removed; `state.plist` goes with it. The
        // Keychain item does not.
        let reinstalled = GateState.initial(now: now.addingTimeInterval(60), installID: installB)
        #expect(reinstalled.lockClock == nil)

        // ── Install #2, first launch ──────────────────────────────────────
        let resolution = clock.resolve(
            keychain: keychainItem,
            mirror: reinstalled.lockClock?.deadline(revision: 0)
        )
        #expect(resolution == .keychainWins(keychainItem))
        #expect(resolution.needsMirrorWrite)

        let recovered = try #require(resolution.deadline)
        #expect(clock.isSatisfied(recovered, now: now.addingTimeInterval(60)) == false)
        #expect(clock.remaining(recovered, now: now.addingTimeInterval(60)) == 4 * 3600 - 60)

        // And the app can say something true rather than silently re-imposing a
        // deadline the user does not remember.
        let adopted = recovered.record(currentInstallID: installB)
        #expect(adopted.isFromPreviousInstall(currentInstallID: installB))
        #expect(adopted.pendingChangeID == change.id)
        #expect(adopted.earliestApplyAt == change.earliestApplyAt)

        // ── …and the first reconcile must not undo any of it ──────────────
        //
        // This is where the whole feature used to die. The fresh install has no
        // pending changes — the container is gone — so the mirror projection saw
        // an empty queue, answered `nil`, and `advance` wrote that back over the
        // record it had just adopted *and* asked for a Keychain write, which
        // tombstones the surviving item. Deleting the app cleared the delay in
        // two steps, and the test above stopped one step short of noticing.
        let launch = now.addingTimeInterval(60)
        var fresh = GateState.initial(now: launch, installID: installB)
        fresh.lock = lock
        fresh.lockClock = adopted

        let firstPass = Reconciler.advance(fresh, now: launch, calendar: utc)
        #expect(firstPass.state.lockClock == adopted, "the adopted deadline survives verbatim")
        #expect(
            firstPass.effects.mirrorsLockClock == false,
            "and nothing asks the Keychain to rewrite a record that did not move"
        )

        // Once it has actually been served, the Lock goes idle and the Keychain
        // is told — otherwise a satisfied deadline would be immortal.
        let served = try #require(adopted.earliestApplyAt).addingTimeInterval(1)
        let laterPass = Reconciler.advance(fresh, now: served, calendar: utc)
        #expect(laterPass.state.lockClock == nil)
        #expect(laterPass.effects.mirrorsLockClock)
    }

    @Test("The Keychain falling behind is healed from the mirror")
    func mirrorHealsTheKeychain() {
        let mirror = deadline(revision: 4)
        #expect(clock.resolve(keychain: nil, mirror: mirror) == .mirrorWins(mirror))
        #expect(clock.resolve(keychain: nil, mirror: mirror).needsMirrorWrite == false)

        let stale = deadline(revision: 3, change: otherChangeID)
        #expect(clock.resolve(keychain: stale, mirror: mirror) == .mirrorWins(mirror))
    }

    @Test("Identical copies agree")
    func agreement() {
        let both = deadline(revision: 2)
        #expect(clock.resolve(keychain: both, mirror: both) == .agreed(both))
        #expect(clock.resolve(keychain: both, mirror: both).needsMirrorWrite == false)
    }

    @Test("Revision decides; updatedAt is only the tiebreak")
    func revisionBeatsTimestamp() {
        // A user-settable device clock must not be able to outrank a counter.
        let highRevisionOldClock = deadline(revision: 9, writtenAt: now.addingTimeInterval(-86_400))
        let lowRevisionNewClock = deadline(
            revision: 2, change: otherChangeID, writtenAt: now.addingTimeInterval(86_400)
        )

        #expect(highRevisionOldClock.isNewer(than: lowRevisionNewClock))
        #expect(clock.resolve(keychain: highRevisionOldClock, mirror: lowRevisionNewClock)
            == .keychainWins(highRevisionOldClock))

        // Same revision, different write times: the timestamp breaks the tie.
        let early = deadline(revision: 5, writtenAt: now)
        let late = deadline(revision: 5, change: otherChangeID, writtenAt: now.addingTimeInterval(1))
        #expect(late.isNewer(than: early))
        #expect(!early.isNewer(than: late))
    }

    @Test("A cancellation tombstone beats an older engaged record")
    func tombstoneBeatsAnOlderDeadline() throws {
        // The user cancelled the pending change — a tightening, and free. The
        // mirror records that with a tombstone carrying a HIGHER revision.
        // Without the tombstone the Keychain would re-impose the deadline on the
        // next launch.
        let stillEngagedInKeychain = deadline(revision: 4)
        let cancelled = LockDeadline.cleared(
            revision: 5, lockConfigHash: "cfg", installID: installA, now: now.addingTimeInterval(30)
        )

        let resolution = clock.resolve(keychain: stillEngagedInKeychain, mirror: cancelled)
        #expect(resolution == .mirrorWins(cancelled))

        let winner = try #require(resolution.deadline)
        #expect(winner.isEngaged == false)
        #expect(clock.isSatisfied(winner, now: now), "a tombstone is trivially satisfied")
        #expect(clock.remaining(winner, now: now) == 0)
    }

    @Test("An older tombstone does NOT clear a newer deadline")
    func staleTombstoneLoses() {
        let freshDeadline = deadline(revision: 9)
        let oldTombstone = LockDeadline.cleared(
            revision: 2, lockConfigHash: "cfg", installID: installA, now: now.addingTimeInterval(-600)
        )
        #expect(clock.resolve(keychain: freshDeadline, mirror: oldTombstone) == .keychainWins(freshDeadline))
    }

    @Test("`keychainUnavailable` is not the same as `no lock`")
    func unavailableIsNotAbsent() {
        // Before the first unlock after boot the Keychain answers
        // errSecInteractionNotAllowed. Treating that as "no record" would let a
        // reboot clear every outstanding deadline.
        let mirror = deadline(revision: 3)
        let resolution = LockClock.Resolution.keychainUnavailable(mirror)

        #expect(resolution.isAuthoritative == false)
        #expect(resolution.deadline == mirror)
        #expect(resolution.needsMirrorWrite == false)

        #expect(LockClockError.mapping(errSecInteractionNotAllowed)
            == .unavailableUntilFirstUnlock(errSecInteractionNotAllowed))
        #expect(LockClockError.mapping(errSecNotAvailable)
            == .unavailableUntilFirstUnlock(errSecNotAvailable))
        #expect(LockClockError.mapping(errSecMissingEntitlement)
            == .missingEntitlement(errSecMissingEntitlement))
    }
}

@Suite("LockClock — elapsed time")
struct LockClockElapsedTimeTests {

    private let clock = LockClock()

    @Test("A deadline in the past is satisfied")
    func pastDeadline() {
        let ripe = deadline(revision: 1, ripensIn: -60)
        #expect(clock.remaining(ripe, now: now) == 0)
        #expect(clock.isSatisfied(ripe, now: now))
    }

    @Test("A backwards device clock cannot strand the user for longer than they agreed to")
    func backwardsClockIsClamped() throws {
        // Armed at `now` for four hours. The user (or a flight, or a bad NTP
        // sync) sets the clock back a year: the naive `earliestApplyAt - now` is
        // now a year and four hours.
        let armed = deadline(revision: 1, ripensIn: 4 * 3600, armedAt: now)
        let clockWentBack = now.addingTimeInterval(-365 * 24 * 3600)

        let naive = try #require(armed.earliestApplyAt).timeIntervalSince(clockWentBack)
        #expect(naive > 4 * 3600)
        // Clamped to the duration that was actually armed.
        #expect(clock.remaining(armed, now: clockWentBack) == 4 * 3600)
    }

    @Test("The clamp can never shorten the agreed wait itself")
    func clampNeverShortensTheAgreedWait() {
        let armed = deadline(revision: 1, ripensIn: 4 * 3600, armedAt: now)
        // Halfway through, with a sane clock: two hours still owed, not four.
        #expect(clock.remaining(armed, now: now.addingTimeInterval(2 * 3600)) == 2 * 3600)
    }

    @Test("A record with no armedAt falls back to the naive remainder")
    func noArmedAtMeansNoClamp() {
        let legacy = deadline(revision: 1, ripensIn: 600, armedAt: nil)
        #expect(clock.remaining(legacy, now: now) == 600)
        #expect(clock.remaining(legacy, now: now.addingTimeInterval(-600)) == 1200)
    }

    @Test("A tombstone owes nothing")
    func tombstoneOwesNothing() {
        let cleared = LockDeadline.cleared(revision: 3, lockConfigHash: "cfg", now: now)
        #expect(clock.remaining(cleared, now: now) == 0)
        #expect(clock.isSatisfied(cleared, now: now))
        #expect(cleared.isEngaged == false)
        #expect(cleared.installID == nil)
    }
}

@Suite("LockClock — the stored shape")
struct LockDeadlineCodingTests {

    @Test("Every field defaults, because a Keychain item outlives the build that wrote it")
    func leniencyOnDecode() throws {
        // An item written by a version of Gate that predates every field here.
        let data = try PropertyListSerialization.data(
            fromPropertyList: [String: Any](), format: .binary, options: 0
        )
        let decoded = try PropertyListDecoder().decode(LockDeadline.self, from: data)

        #expect(decoded.revision == 0)
        #expect(decoded.pendingChangeID == nil)
        #expect(decoded.earliestApplyAt == nil)
        #expect(decoded.lockConfigHash.isEmpty)
        #expect(decoded.installID == nil)
        #expect(decoded.isEngaged == false)
        // A revision-0 tombstone, which any real record beats.
        #expect(deadline(revision: 1).isNewer(than: decoded))
    }

    @Test("A partial record keeps the fields it does carry")
    func partialDecode() throws {
        let plist: [String: Any] = [
            "revision": 12,
            "pendingChangeID": changeID.uuidString,
            "earliestApplyAt": now.addingTimeInterval(900),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        let decoded = try PropertyListDecoder().decode(LockDeadline.self, from: data)

        #expect(decoded.revision == 12)
        #expect(decoded.pendingChangeID == changeID)
        #expect(decoded.isEngaged)
        #expect(decoded.armedAt == nil)
    }

    @Test("Encoding and decoding is lossless")
    func roundTrip() throws {
        let original = deadline(revision: 42, configHash: LockClock.configHash(["lock", "v1"]))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let decoded = try PropertyListDecoder().decode(
            LockDeadline.self, from: try encoder.encode(original)
        )
        #expect(decoded == original)
    }

    @Test("The two shapes convert losslessly in both directions")
    func shapeConversions() {
        let mirror = record()
        let asDeadline = mirror.deadline(revision: 3, armedAt: now)

        #expect(asDeadline.revision == 3)
        #expect(asDeadline.pendingChangeID == mirror.pendingChangeID)
        #expect(asDeadline.earliestApplyAt == mirror.earliestApplyAt)
        #expect(asDeadline.lockConfigHash == mirror.lockConfigHash)
        #expect(asDeadline.installID == mirror.installID)

        #expect(asDeadline.record(currentInstallID: installB) == mirror)

        // A record with no revision of its own claims 0, which loses every
        // comparison — the safe direction.
        #expect(mirror.deadline().revision == 0)

        // A Keychain item written before `installID` existed is attributed to
        // the CURRENT install, so the app stays quiet rather than claiming a
        // reinstall it cannot evidence.
        let anonymous = deadline(revision: 1, install: nil)
        #expect(anonymous.record(currentInstallID: installB).installID == installB)
        #expect(anonymous.record(currentInstallID: installB)
            .isFromPreviousInstall(currentInstallID: installB) == false)
    }

    @Test("configHash is deterministic, ordered, and cannot be collided by re-splitting")
    func configHashProperties() {
        #expect(LockClock.configHash(["a", "b"]) == LockClock.configHash(["a", "b"]))
        #expect(LockClock.configHash(["a", "b"]) != LockClock.configHash(["b", "a"]))
        // U+001F joins the components, so these cannot collide.
        #expect(LockClock.configHash(["a", "bc"]) != LockClock.configHash(["ab", "c"]))
        // SHA-256, lowercase hex.
        #expect(LockClock.configHash(["a"]).count == 64)
        #expect(LockClock.configHash(["a"]).allSatisfy({ $0.isHexDigit && !$0.isUppercase }))
    }

    @Test("`matches(configHash:)` reports drift without ever acting on it")
    func matchesConfigHash() {
        let armed = deadline(revision: 1, configHash: "abc")
        #expect(armed.matches(configHash: "abc"))
        #expect(!armed.matches(configHash: "def"))
        // Drift changes copy, not the deadline: the remaining time is untouched.
        #expect(LockClock().remaining(armed, now: now) == 4 * 3600)
    }
}

#endif
