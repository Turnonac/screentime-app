//
//  StateCodecTests.swift
//  GateKernelTests
//
//  docs/06-build-plan.md step 3.11 — "`GateState` forward-compat with unknown
//  keys"; plus the 50-token guard and the `StateStoring` contract.
//
//  WHAT THIS FILE IS DEFENDING
//  `state.plist` is the only durable record of what the user asked Gate to
//  enforce, and three processes read it. Two failure modes matter, and neither
//  is a crash:
//
//  1. **A decode that gives up.** If a `state.plist` written by a newer build —
//     or half-written by a process that was jetsammed mid-flush — decodes to
//     "no rules", the next reconcile writes empty shield sets and unblocks
//     everything. So every `init(from:)` in `Kernel/Model/` is lenient, and
//     every unknown enum raw degrades toward *more* friction, never less.
//  2. **An older build writing over a newer file.** `Codable` silently drops
//     keys it does not know, so `GateState.migrate` flags a future file with
//     `isFromFuture` and `GateStateStore` must refuse to write.
//
//  Everything here is `PropertyListSerialization` and `PropertyListDecoder` on
//  hand-built dictionaries — the closest a test process can get to "a file some
//  other version of Gate wrote". Binary format throughout: XML plist truncates
//  sub-second date precision and would make round-trip equality a lie.
//

import Foundation
import Testing

@testable import GateKernel

// MARK: - Fixtures

/// 2026-05-14T04:53:20Z. Whole seconds, so it survives every plist format.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private let ruleID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let otherRuleID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let changeID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private let grantID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
private let installID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!

private func plistData(_ value: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
}

/// Gives a nested literal an explicit `[String: Any]` type.
///
/// Without it Swift has to infer the type of every heterogeneous dictionary
/// sitting in an `Any` slot, and warns about it at each one. These literals are
/// standing in for bytes some other version of Gate wrote, so `Any` is exactly
/// what they are.
private func dict(_ value: [String: Any]) -> [String: Any] { value }

private func list(_ value: [[String: Any]]) -> [[String: Any]] { value }

private func decodeState(
    _ value: [String: Any],
    context: GateDecodeContext? = nil
) throws -> GateState {
    let decoder = PropertyListDecoder()
    if let context {
        decoder.userInfo[.gateDecodeContext] = context
    }
    return try decoder.decode(GateState.self, from: plistData(value))
}

private func digestDict(apps: Int = 5, fingerprint: String = "1111111111111111") -> [String: Any] {
    [
        "apps": apps,
        "cats": 0,
        "webs": 0,
        "whole": false,
        "fp": fingerprint,
        "size": 256,
        "at": now,
    ]
}

private func ruleDict(
    id: UUID = ruleID,
    name: String = "Focus",
    mode: String = "blocklist",
    enabled: Bool = true,
    sortIndex: Int = 0,
    merging extra: [String: Any] = [:]
) -> [String: Any] {
    var fields: [String: Any] = [
        "id": id.uuidString,
        "n": name,
        "m": mode,
        "on": enabled,
        "idx": sortIndex,
        "c": now,
        "u": now,
        "sel": dict(["id": UUID().uuidString, "d": digestDict()]),
    ]
    for (key, value) in extra { fields[key] = value }
    return fields
}

private func makeRule(
    id: UUID = ruleID,
    name: String = "Focus",
    mode: RuleMode = .blocklist,
    isEnabled: Bool = true,
    schedule: RuleSchedule? = nil,
    sortIndex: Int = 0,
    createdAt: Date = now
) -> Rule {
    Rule(
        id: id,
        name: name,
        mode: mode,
        isEnabled: isEnabled,
        schedule: schedule,
        selection: SelectionRef(
            id: UUID(),
            digest: SelectionDigest(
                applicationCount: 5, fingerprint: "1111111111111111", byteCount: 256, capturedAt: now
            )
        ),
        sortIndex: sortIndex,
        createdAt: createdAt,
        updatedAt: now
    )
}

// MARK: - Forward compatibility

@Suite("GateState — forward compatibility")
struct GateStateForwardCompatibilityTests {

    @Test("Unknown top-level keys from a newer build are ignored, not fatal")
    func unknownTopLevelKeys() throws {
        let state = try decodeState([
            "v": 1,
            "g": 7,
            "inst": installID.uuidString,
            "c": now,
            "u": now,
            "rules": [ruleDict()],
            // Written by a build that knows things this one does not.
            "quantumLock": ["enabled": true],
            "streakCount": 42,
            "v2Journal": [["entry": "hello"]],
        ])

        #expect(state.schemaVersion == 1)
        #expect(state.generation == 7)
        #expect(state.installID == installID)
        #expect(state.rules.map(\.id) == [ruleID])
        #expect(state.rules[0].name == "Focus")
    }

    @Test("Unknown keys inside a rule are ignored too")
    func unknownRuleKeys() throws {
        let state = try decodeState([
            "v": 1,
            "rules": [
                ruleDict(merging: ["dailyBudgetSeconds": 3600, "escalation": ["tier": 2]])
            ],
        ])

        #expect(state.rules.count == 1)
        #expect(state.rules[0].id == ruleID)
        #expect(state.rules[0].isEnabled)
    }

    @Test("Every missing key takes a documented default and nothing throws")
    func missingKeys() throws {
        let state = try decodeState([:])

        // Version 0, NOT `currentSchemaVersion`: claiming a file is current when
        // it does not say so would skip every repair `migrate` exists to apply.
        #expect(state.schemaVersion == 0)
        #expect(state.generation == 0)
        #expect(state.createdAt == .distantPast)
        #expect(state.rules.isEmpty)
        #expect(state.pendingChanges.isEmpty)
        #expect(state.grants.isEmpty)
        #expect(!state.installProtectionEnabled)
        #expect(state.onboardingCompletedAt == nil)
        #expect(state.tokenExpiryObservedAt == nil)
        #expect(!state.needsRecovery)
        #expect(!state.hasCompletedOnboarding)

        // An unreadable Lock decodes to the 15-minute default, not to "no lock".
        // There is no representable state in which loosening is free.
        #expect(state.lock == .default)
        #expect(state.lock.delay == GateLimits.defaultLockDelay)
        #expect(state.lock.isRatchetEnabled)
        #expect(state.grantPolicy == .default)
    }

    @Test("An unreadable Lock still costs the full default delay")
    func malformedLockFallsBackToTheDefault() throws {
        let state = try decodeState([
            "v": 1,
            "lock": ["k": "quantum", "delay": "not-a-number", "ratchet": "maybe"],
        ])

        // Unknown kind with no digest on file: `.delay` is the only usable
        // answer. A missing delay is 15 minutes, never zero.
        #expect(state.lock.kind == .delay)
        #expect(state.lock.delay == GateLimits.defaultLockDelay)
        #expect(state.lock.isRatchetEnabled, "the stricter reading")
    }

    @Test("An unknown lock kind with a digest on file keeps the partner's authority")
    func unknownKindWithPasswordFallsBackToBoth() throws {
        let state = try decodeState([
            "v": 1,
            "lock": dict([
                "k": "biometric",
                "delay": 900.0,
                "pw": dict([
                    "alg": "salted-sha256",
                    "salt": Data([1, 2, 3]),
                    "d": Data([9, 9, 9]),
                    "c": now,
                ]),
            ]),
        ])

        // A newer build clearly intended a password to matter; `.delay` would
        // discard the partner's authority outright.
        #expect(state.lock.kind == .both)
        #expect(state.lock.password?.algorithm == .saltedSHA256)
    }

    @Test("Unknown enum raw values degrade toward MORE friction, never less")
    func unknownRawValues() throws {
        let state = try decodeState([
            "v": 1,
            "rules": [ruleDict(mode: "quantum")],
            "pending": list([[
                "id": changeID.uuidString,
                "op": dict(["t": "disableRule", "rule": ruleID.uuidString]),
                "req": now,
                "at": now.addingTimeInterval(900),
                "cfg": "abc",
                "st": "gremlin",
            ]]),
        ])

        // A mode we do not understand must not silently start shielding every
        // app on the device.
        #expect(state.rules[0].mode == .blocklist)
        // An unreadable status that decoded as "resolved" would hand out a free
        // loosening to anyone who could corrupt one byte.
        #expect(state.pendingChanges[0].status == .pending)
        #expect(state.pendingChanges[0].isRipe(at: now.addingTimeInterval(1000)))
    }

    @Test("An operation from a newer build survives as `unrecognized` and is never applied")
    func unknownOperationTag() throws {
        let state = try decodeState([
            "v": 1,
            "pending": list([[
                "id": changeID.uuidString,
                "op": dict(["t": "setQuantumLock", "rule": ruleID.uuidString]),
                "req": now,
                "at": now.addingTimeInterval(60),
                "cfg": "abc",
            ]]),
        ])

        let change = try #require(state.pendingChanges.first)
        #expect(change.operation == .unrecognized(type: "setQuantumLock"))
        #expect(!change.isApplicable)
        // Displayed and cancellable, but `ripe(at:)` will not hand it to
        // `Ratchet.applyReleased`.
        #expect(state.pendingChanges.ripe(at: now.addingTimeInterval(600)).isEmpty)
        #expect(change.operation.targetKey == "unrecognized:setQuantumLock")
    }

    @Test("A malformed element loses only itself, and the loss is recorded")
    func lossyArraysDropOnlyBadElements() throws {
        let context = GateDecodeContext()
        let state = try decodeState(
            [
                "v": 1,
                "rules": list([
                    ruleDict(id: ruleID, name: "Good", sortIndex: 0),
                    // No id: cannot be matched to a store, an activity or a
                    // shield copy, so this one element is dropped.
                    ["n": "No id", "on": true],
                    ruleDict(id: otherRuleID, name: "Also good", sortIndex: 1),
                ]),
                "grants": list([
                    // No ruleID: cannot be expired against anything.
                    ["id": grantID.uuidString, "iss": now, "exp": now.addingTimeInterval(300)]
                ]),
            ],
            context: context
        )

        #expect(state.rules.map(\.name) == ["Good", "Also good"])
        #expect(state.grants.isEmpty)
        #expect(!context.isClean)
        #expect(context.notes.contains(GateDecodeNote(field: "rules", droppedElements: 1)))
        #expect(context.notes.contains(GateDecodeNote(field: "grants", droppedElements: 1)))
    }

    @Test("A decode with nothing wrong records nothing")
    func cleanDecodeIsSilent() throws {
        let context = GateDecodeContext()
        _ = try decodeState(["v": 1, "rules": [ruleDict()]], context: context)
        #expect(context.isClean)
        #expect(context.notes.isEmpty)
    }

    @Test("A half-written schedule reads as `no schedule`, never as a zero-length window")
    func halfWrittenScheduleBecomesNoSchedule() throws {
        let state = try decodeState([
            "v": 1,
            "rules": [ruleDict(merging: ["sch": dict(["s": ["h": 22, "m": 0, "s": 0], "w": 127])])],
        ])

        // Defaulting the missing end to midnight would manufacture a window that
        // looks configured and enforces nothing.
        #expect(state.rules[0].schedule == nil)
        // "No schedule" means "in force whenever enabled" — the stricter reading.
        #expect(state.rules[0].shouldEnforce(at: now))
    }

    @Test("A schedule with both ends decodes, weekday mask and all")
    func wellFormedScheduleDecodes() throws {
        let state = try decodeState([
            "v": 1,
            "rules": [
                ruleDict(merging: [
                    "sch": dict([
                        "s": ["h": 22, "m": 0, "s": 0],
                        "e": ["h": 6, "m": 30, "s": 0],
                        "w": WeekdayMask.workweek.rawValue,
                        "warn": 5,
                    ])
                ])
            ],
        ])

        let schedule = try #require(state.rules[0].schedule)
        #expect(schedule.start == TimeOfDay(hour: 22, minute: 0))
        #expect(schedule.end == TimeOfDay(hour: 6, minute: 30))
        #expect(schedule.weekdays == .workweek)
        #expect(schedule.warningMinutes == 5)
        #expect(schedule.crossesMidnight)
        #expect(schedule.duration == 8.5 * 3600)
    }

    @Test("Encoding and decoding a full state is lossless")
    func roundTrip() throws {
        let original = GateState(
            schemaVersion: GateState.currentSchemaVersion,
            generation: 12,
            installID: installID,
            createdAt: now,
            updatedAt: now,
            rules: [
                makeRule(
                    id: ruleID,
                    schedule: RuleSchedule(
                        start: TimeOfDay(hour: 9, minute: 0),
                        end: TimeOfDay(hour: 17, minute: 0),
                        weekdays: .workweek,
                        warningMinutes: 5
                    ),
                    sortIndex: 0
                ),
                makeRule(id: otherRuleID, name: "Evenings", mode: .allowlist, sortIndex: 1),
            ],
            lock: LockPolicy(
                kind: .both,
                delay: 3600,
                password: PasswordDigest(
                    algorithm: .saltedSHA256,
                    salt: Data(repeating: 0x5A, count: PasswordDigest.saltByteCount),
                    digest: Data(repeating: 0x7B, count: 32),
                    createdAt: now,
                    hint: "the one you wrote down"
                ),
                isRatchetEnabled: false,
                updatedAt: now
            ),
            lockClock: LockClockRecord(
                pendingChangeID: changeID,
                earliestApplyAt: now.addingTimeInterval(3600),
                lockConfigHash: "abcdef0123456789",
                installID: installID,
                updatedAt: now
            ),
            installProtectionEnabled: true,
            grantPolicy: GrantPolicy(dailyLimit: 2, defaultDuration: 600, impulseDelay: 45, usesLockDelay: true),
            pendingChanges: [
                PendingChange(
                    id: changeID,
                    operation: .replaceSelection(
                        ruleID: ruleID,
                        selection: SelectionRef(
                            id: UUID(),
                            digest: SelectionDigest(applicationCount: 2, fingerprint: "2222222222222222")
                        )
                    ),
                    requestedAt: now,
                    earliestApplyAt: now.addingTimeInterval(3600),
                    lockConfigHash: "abcdef0123456789",
                    note: "fewer apps"
                )
            ],
            grants: [
                Grant(
                    id: grantID,
                    ruleID: ruleID,
                    scope: .tokens(ScopedTokens(token: EncodedToken(bytes: Data([1, 2, 3])), kind: .application)),
                    issuedAt: now,
                    expiresAt: now.addingTimeInterval(300),
                    source: .intervention,
                    requestID: UUID(),
                    reason: "one message"
                )
            ],
            grantLedger: GrantLedger(used: 1, periodStart: now),
            onboardingCompletedAt: now,
            lastReconciledAt: now,
            tokenExpiryObservedAt: nil
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try PropertyListDecoder().decode(GateState.self, from: try encoder.encode(original))

        #expect(decoded == original)
    }

    @Test("A rule stays small, because the selection blob is not in this file")
    func ruleStaysSmall() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode([makeRule(name: String(repeating: "x", count: Rule.maxNameLength))]).count

        // The structural guarantee behind the 8 KB budget: a `Rule` carries a
        // `SelectionRef` — an id plus a ~120-byte digest — never a
        // `FamilyActivitySelection`, which is large "especially if you use
        // includeEntireCategory" (docs/05-architecture.md, persistence). A blob
        // stored inline would blow past this by an order of magnitude.
        #expect(bytes < 600)
    }

    @Test("A fully-configured install fits the 8 KB budget the monitor decodes")
    func fullStateFitsTheBudget() throws {
        let rules = (0..<GateLimits.maxRules).map { index in
            makeRule(
                id: UUID(),
                name: String(repeating: "r", count: Rule.maxNameLength),
                schedule: RuleSchedule(
                    start: TimeOfDay(hour: 9, minute: 0),
                    end: TimeOfDay(hour: 17, minute: 0),
                    weekdays: .workweek,
                    warningMinutes: 5
                ),
                sortIndex: index
            )
        }
        let changes = (0..<GateLimits.maxRevertActivities).map { index in
            PendingChange(
                id: UUID(),
                operation: .disableRule(ruleID: rules[index].id),
                requestedAt: now,
                earliestApplyAt: now.addingTimeInterval(3600),
                lockConfigHash: "abcdef0123456789",
                note: String(repeating: "n", count: PendingChange.maxNoteLength)
            )
        }
        let grants = (0..<GateLimits.defaultDailyGrantBudget).map { index in
            Grant(
                id: UUID(),
                ruleID: rules[index].id,
                scope: .tokens(
                    ScopedTokens(token: EncodedToken(bytes: Data(repeating: 0x2A, count: 64)), kind: .application)
                ),
                issuedAt: now,
                expiresAt: now.addingTimeInterval(300),
                source: .intervention
            )
        }

        let state = GateState(
            schemaVersion: GateState.currentSchemaVersion,
            installID: installID,
            createdAt: now,
            updatedAt: now,
            rules: rules,
            pendingChanges: changes,
            grants: grants,
            grantLedger: GrantLedger(used: 3, periodStart: now)
        )

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(state).count

        // `GateActivityMonitor` decodes this on every callback under a 6 MB
        // jetsam ceiling, and a kill inside `eventDidReachThreshold` means the
        // block silently never applies (docs/03-hard-constraints.md #31).
        #expect(bytes < GateState.maxEncodedBytes)
        #expect(GateState.maxEncodedBytes == GateLimits.maxStateBytes)
    }

    @Test("Fingerprints are stable across processes, which `hashValue` is not")
    func fingerprintsAreDeterministic() {
        #expect(GateFingerprint.hex(Data([1, 2, 3])) == GateFingerprint.hex(Data([1, 2, 3])))
        #expect(GateFingerprint.hex("gate") != GateFingerprint.hex("gaTe"))
        #expect(GateFingerprint.hex(Data()).count == 16)
        #expect(GateFingerprint.empty == "0000000000000000")
        // Joined with a separator no part can contain, so these cannot collide.
        #expect(GateFingerprint.combine(["a", "bc"]) != GateFingerprint.combine(["ab", "c"]))
        #expect(EncodedToken(bytes: Data([7])).fingerprint == GateFingerprint.hex(Data([7])))
        #expect(EncodedToken(bytes: Data()).isEmpty)
    }
}

// MARK: - Migration

@Suite("GateState.migrate — structural repair, and only structural repair")
struct GateStateMigrationTests {

    @Test("A file from a NEWER build is returned untouched and flagged")
    func futureFileIsUntouched() throws {
        let decoded = try decodeState([
            "v": GateState.currentSchemaVersion + 1,
            "rules": [ruleDict(sortIndex: 99)],
            "lock": dict(["k": "delay", "delay": 1.0]),
        ])

        let migrated = GateState.migrate(decoded, now: now)

        #expect(migrated.report.isFromFuture)
        #expect(migrated.report.repairs == [.refusedDowngrade(fileVersion: GateState.currentSchemaVersion + 1)])
        // Not even a clamp: whatever the caller does next, it is acting on the
        // bytes that were actually on disk.
        #expect(migrated.state == decoded)
        #expect(migrated.state.lock.delay == GateLimits.minLockDelay, "clamped by the decoder, not by migrate")
        #expect(migrated.state.rules[0].sortIndex == 99)

        // `isFromFuture` is the signal `GateStateStore` must not write over:
        // this build's encoder would silently drop the fields that newer build
        // added.
        #expect(!migrated.report.isNoOp)
    }

    @Test("A versionless file is adopted, not repaired away")
    func versionZeroIsAdopted() throws {
        let decoded = try decodeState(["rules": [ruleDict()]])
        #expect(decoded.schemaVersion == 0)

        let migrated = GateState.migrate(decoded, now: now)
        #expect(migrated.state.schemaVersion == GateState.currentSchemaVersion)
        #expect(migrated.report.repairs.contains(.adoptedSchemaVersion(from: 0)))
        #expect(migrated.report.fromSchemaVersion == 0)
        #expect(migrated.report.toSchemaVersion == GateState.currentSchemaVersion)
        #expect(!migrated.report.isFromFuture)
        #expect(migrated.state.createdAt == now, "a missing creation date is stamped, not left at distantPast")
    }

    @Test("Duplicate rule ids are dropped, first occurrence wins")
    func duplicateRulesAreDropped() throws {
        let decoded = try decodeState([
            "v": 1,
            "rules": [
                ruleDict(id: ruleID, name: "First", sortIndex: 0),
                ruleDict(id: ruleID, name: "Impostor", sortIndex: 1),
            ],
        ])

        let migrated = GateState.migrate(decoded, now: now)
        // Two rules sharing an id would fight over one ManagedSettingsStore and
        // one DeviceActivityName, and the loser's shield set would be silently
        // overwritten on every reconcile.
        #expect(migrated.state.rules.map(\.name) == ["First"])
        #expect(migrated.report.repairs.contains(.droppedDuplicateRules(count: 1)))
    }

    @Test("Past the rule cap it is the bottom of the user's own list that goes")
    func excessRulesAreDroppedFromTheBottom() throws {
        let dicts = (0..<(GateLimits.maxRules + 2)).map { index in
            ruleDict(id: UUID(), name: "Rule \(index)", sortIndex: index)
        }
        let migrated = GateState.migrate(try decodeState(["v": 1, "rules": dicts]), now: now)

        #expect(migrated.state.rules.count == GateLimits.maxRules)
        #expect(migrated.state.rules.map(\.name) == (0..<GateLimits.maxRules).map({ "Rule \($0)" }))
        #expect(migrated.report.repairs.contains(
            .droppedExcessRules(count: 2, limit: GateLimits.maxRules)
        ))
    }

    @Test("Sort indices are normalized to 0..<n and names truncated to the cap")
    func normalization() throws {
        // `Rule.init` truncates, so an over-long name can only reach migration
        // through the `var` — which is exactly how the editor would produce one.
        var overlong = makeRule(id: otherRuleID, sortIndex: 40)
        overlong.name = String(repeating: "x", count: 200)
        let short = makeRule(id: ruleID, name: "Short", sortIndex: 7)

        let decoded = GateState(
            schemaVersion: GateState.currentSchemaVersion,
            installID: installID,
            createdAt: now,
            updatedAt: now,
            rules: [overlong, short]
        )

        let migrated = GateState.migrate(decoded, now: now)
        #expect(migrated.state.rules.map(\.id) == [ruleID, otherRuleID], "ordered by the user's own arrangement")
        #expect(migrated.state.rules.map(\.sortIndex) == [0, 1])
        #expect(migrated.state.rules[1].name.count == Rule.maxNameLength)
        #expect(migrated.report.repairs.contains(.normalizedSortIndexes))
        #expect(migrated.report.repairs.contains(.truncatedRuleNames(count: 1)))
    }

    @Test("Pending changes and grants that name a vanished rule are reclaimed")
    func referentialIntegrity() throws {
        let decoded = try decodeState([
            "v": 1,
            "rules": [ruleDict(id: ruleID)],
            "pending": list([
                [
                    "id": changeID.uuidString,
                    "op": dict(["t": "disableRule", "rule": otherRuleID.uuidString]),
                    "req": now,
                    "cfg": "abc",
                ],
                [
                    // Install-wide operations have no ruleID and are kept.
                    "id": UUID().uuidString,
                    "op": dict(["t": "setLockDelay", "sec": 600.0]),
                    "req": now,
                    "cfg": "abc",
                ],
            ]),
            "grants": list([[
                "id": grantID.uuidString,
                "rule": otherRuleID.uuidString,
                "sc": dict(["t": "entireRule"]),
                "iss": now,
                "exp": now.addingTimeInterval(300),
                "src": "intervention",
            ]]),
        ])

        let migrated = GateState.migrate(decoded, now: now)
        #expect(migrated.state.pendingChanges.count == 1)
        #expect(migrated.state.pendingChanges[0].ruleID == nil)
        #expect(migrated.state.grants.isEmpty)
        #expect(migrated.report.repairs.contains(.droppedOrphanPendingChanges(count: 1)))
        #expect(migrated.report.repairs.contains(.droppedOrphanGrants(count: 1)))
    }

    @Test("A ledger claiming more than the limit is clamped rather than going negative")
    func ledgerIsClamped() throws {
        let decoded = try decodeState([
            "v": 1,
            "gpol": dict(["limit": 2, "dur": 300.0, "impulse": 30.0, "useLock": false]),
            "gledger": dict(["n": 9, "day": now]),
        ])

        let migrated = GateState.migrate(decoded, now: now)
        #expect(migrated.state.grantLedger.used == 2)
        #expect(migrated.state.grantLedger.remaining(under: migrated.state.grantPolicy) == 0)
        #expect(migrated.report.repairs.contains(.clampedGrantLedger(from: 9, to: 2)))
    }

    @Test("A selection with no fingerprint is flagged for recovery, not silently used")
    func unusableSelectionsAreFlagged() throws {
        let decoded = try decodeState([
            "v": 1,
            "rules": [ruleDict(merging: [
                "sel": dict(["id": UUID().uuidString, "d": digestDict(fingerprint: GateFingerprint.empty)])
            ])],
        ])

        let migrated = GateState.migrate(decoded, now: now)
        #expect(migrated.report.repairs.contains(.flaggedUnusableSelections(count: 1)))
        // The rule is kept — it is the user's configuration, and V1-9 recovery
        // is how they get it back.
        #expect(migrated.state.rules.count == 1)
    }

    @Test("Migration is deterministic and idempotent")
    func deterministicAndIdempotent() throws {
        let decoded = try decodeState([
            "rules": [
                ruleDict(id: ruleID, name: "First", sortIndex: 40),
                ruleDict(id: otherRuleID, name: "Second", sortIndex: 3),
            ],
            "gledger": dict(["n": 9, "day": now]),
        ])

        let first = GateState.migrate(decoded, now: now)
        let again = GateState.migrate(decoded, now: now)
        #expect(first.state == again.state)
        #expect(first.report == again.report)

        // Given the same input it returns the same output on any day, which is
        // what makes a migration testable at all.
        let tomorrow = GateState.migrate(decoded, now: now.addingTimeInterval(86_400))
        #expect(tomorrow.state.rules.map(\.id) == first.state.rules.map(\.id))

        let second = GateState.migrate(first.state, now: now)
        #expect(second.state == first.state)
        #expect(second.report.isNoOp)
    }

    @Test("Migration does NOT do the Reconciler's temporal work")
    func migrationIsNotTemporal() throws {
        let expired = Grant(
            id: grantID,
            ruleID: ruleID,
            scope: .entireRule,
            issuedAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval(-300),
            source: .intervention
        )
        let yesterdaysLedger = GrantLedger(used: 3, periodStart: now.addingTimeInterval(-86_400))
        let state = GateState(
            schemaVersion: GateState.currentSchemaVersion,
            installID: installID,
            createdAt: now,
            updatedAt: now,
            rules: [makeRule()],
            grants: [expired],
            grantLedger: yesterdaysLedger
        )

        let migrated = GateState.migrate(state, now: now)
        // Conflating structural repair with temporal cleanup would make
        // migration's output depend on when it ran.
        #expect(migrated.state.grants.map(\.id) == [expired.id])
        #expect(migrated.state.grantLedger == yesterdaysLedger)
        #expect(migrated.report.isNoOp)
    }

    @Test("Post-conditions every other part of the kernel may rely on")
    func postConditions() throws {
        let dicts = (0..<12).map { index in
            ruleDict(id: UUID(), name: "Rule \(index)", sortIndex: 11 - index)
        }
        let decoded = try decodeState([
            "rules": dicts,
            "lock": dict(["k": "delay", "delay": 0.5, "ratchet": true]),
        ])

        let migrated = GateState.migrate(decoded, now: now).state

        #expect(migrated.schemaVersion == GateState.currentSchemaVersion)
        #expect(migrated.rules.count <= GateLimits.maxRules)
        #expect(Set(migrated.rules.map(\.id)).count == migrated.rules.count)
        #expect(migrated.rules.enumerated().allSatisfy({ $0.element.sortIndex == $0.offset }))
        #expect(migrated.lock.delay >= GateLimits.minLockDelay)
        #expect(migrated.lock.delay <= GateLimits.maxLockDelay)
        #expect(migrated.pendingChanges.allSatisfy({ change in
            change.ruleID.map { migrated.ruleIDs.contains($0) } ?? true
        }))
        #expect(migrated.grants.allSatisfy({ migrated.ruleIDs.contains($0.ruleID) }))
    }

    @Test("Pruning is temporal, and keeps live records at any age")
    func pruning() throws {
        let stale = PendingChange(
            id: changeID,
            operation: .disableRule(ruleID: ruleID),
            requestedAt: now.addingTimeInterval(-PendingChange.terminalRetention - 7200),
            earliestApplyAt: now.addingTimeInterval(-PendingChange.terminalRetention - 3600),
            lockConfigHash: "abc"
        ).applied(at: now.addingTimeInterval(-PendingChange.terminalRetention - 3600))

        let open = PendingChange(
            id: UUID(),
            operation: .deleteRule(ruleID: ruleID),
            requestedAt: now.addingTimeInterval(-PendingChange.terminalRetention * 2),
            earliestApplyAt: now.addingTimeInterval(3600),
            lockConfigHash: "abc"
        )

        let state = GateState(
            schemaVersion: GateState.currentSchemaVersion,
            installID: installID,
            createdAt: now,
            updatedAt: now,
            rules: [makeRule()],
            pendingChanges: [stale, open]
        )

        let pruned = state.pruned(now: now)
        #expect(pruned.pendingChanges.map(\.id) == [open.id])
        #expect(!open.isExpired(at: now), "an unresolved change never ages out")
        #expect(stale.isExpired(at: now))
        #expect(pruned.nextDeadline(after: now) == open.earliestApplyAt)
        #expect(pruned.openPendingChanges.count == 1)
    }
}

// MARK: - Token caps

@Suite("TokenGuard — the silent 50-token cap (docs/03-hard-constraints.md #34)")
struct TokenGuardTests {

    @Test("49 fits, 50 fits, 51 does not")
    func capBoundary() throws {
        #expect(TokenGuard.collectionLimit == GateLimits.maxTokensPerShieldCollection)
        #expect(TokenGuard.collectionLimit == 50)

        #expect(TokenGuard.isWithinCap(49))
        #expect(TokenGuard.isWithinCap(50))
        #expect(!TokenGuard.isWithinCap(51))

        // Under the cap these must simply not throw; letting the error escape
        // the test is a clearer failure than any assertion about it.
        try TokenGuard.check(49, in: .applications)
        try TokenGuard.check(50, in: .applications)
        #expect(
            throws: TokenGuardError.collectionOverflow(collection: .applications, count: 51, limit: 50)
        ) {
            try TokenGuard.check(51, in: .applications)
        }
    }

    @Test("Headroom is what the picker shows the user, and never goes negative")
    func headroom() {
        #expect(TokenGuard.headroom(after: 44) == 6)
        #expect(TokenGuard.headroom(after: 50) == 0)
        #expect(TokenGuard.headroom(after: 80) == 0)
    }

    @Test("The `except:` half of a collection has the same cap")
    func exceptionsCap() throws {
        try TokenGuard.checkExceptions(50, in: .webDomains)
        #expect(
            throws: TokenGuardError.exceptionOverflow(collection: .webDomains, count: 51, limit: 50)
        ) {
            try TokenGuard.checkExceptions(51, in: .webDomains)
        }
    }

    @Test("The unverified combined rule warns and never blocks a write")
    func combinedOverflowIsAdvisory() throws {
        #expect(TokenGuard.combinedIssue(shielded: 30, exceptions: 20, in: .applications) == nil)

        let issue = try #require(TokenGuard.combinedIssue(shielded: 30, exceptions: 21, in: .applications))
        #expect(issue == .combinedOverflow(collection: .applications, shielded: 30, exceptions: 21, limit: 50))
        // Whether iOS sums the two halves against one cap is unverified, so this
        // is a warning value rather than a throw: refusing a legal write on an
        // unverified rule would unenforce a rule the user configured.
        #expect(!issue.isBlocking)
        #expect(issue.isSilent)
    }

    @Test("A stored digest is checked without decoding the selection blob")
    func digestChecks() throws {
        let safe = SelectionDigest(applicationCount: 50, categoryCount: 50, webDomainCount: 50)
        #expect(TokenGuard.issues(in: safe).isEmpty)
        try TokenGuard.check(safe)

        let over = SelectionDigest(applicationCount: 51, categoryCount: 2, webDomainCount: 60)
        let issues = TokenGuard.issues(in: over)
        #expect(issues.count == 2)
        // `TokenCollection.allCases` order, so two processes produce
        // byte-identical diagnostics for the same state.
        #expect(issues[0].collection == .applications)
        #expect(issues[1].collection == .webDomains)
        #expect(throws: TokenGuardError.self) { try TokenGuard.check(over) }

        // The editor renders one string per problem, whichever guard found it.
        #expect(
            issues[0].ruleIssue == .tokenCapExceeded(collection: .applications, count: 51, limit: 50)
        )
        #expect(over.overflowingCollections.map(\.collection) == [.applications, .webDomains])
        #expect(safe.totalTokenCount == 150)
        #expect(SelectionDigest().isEmpty)
    }

    @Test("issues(forCounts:) reports every broken cap, in a deterministic order")
    func issuesForCounts() {
        let issues = TokenGuard.issues(forCounts: [.applications: 51, .categories: 1, .webDomains: 99])
        #expect(issues.count == 2)
        #expect(issues.map(\.collection) == [.applications, .webDomains])
        #expect(TokenGuard.issues(forCounts: [:]).isEmpty)
    }

    @Test("Silent failures are labelled as silent, because nothing else will tell you")
    func silentFailures() {
        // Past 50 tokens the shield collection shields nothing and reads back
        // nil; past 50 named stores the store is simply not created. iOS neither
        // throws nor logs for either.
        #expect(TokenGuardError.collectionOverflow(collection: .applications, count: 51, limit: 50).isSilent)
        #expect(TokenGuardError.namedStoreLimitExceeded(count: 51, limit: 50).isSilent)
        #expect(TokenGuardError.webFilterDomainLimitExceeded(count: 51, limit: 50).isSilent)
        #expect(!TokenGuardError.ruleLimitExceeded(count: 9, limit: 8).isSilent)
    }

    @Test("The rule cap is advisory: it must never stop a shield being written")
    func ruleCapIsAdvisory() throws {
        try TokenGuard.checkRuleCount(GateLimits.maxRules)
        #expect(
            throws: TokenGuardError.ruleLimitExceeded(count: 9, limit: GateLimits.maxRules)
        ) {
            try TokenGuard.checkRuleCount(9)
        }
        // Refusing to write the ninth rule's shield set would silently unenforce
        // a rule the user configured — a loosening caused by our own version
        // check, with no UI anywhere to explain it.
        #expect(!TokenGuardError.ruleLimitExceeded(count: 9, limit: 8).isBlocking)
    }

    @Test("Store accounting: one per rule, plus solid, plus backstop")
    func storeAccounting() throws {
        #expect(TokenGuard.expectedStoreCount(ruleCount: GateLimits.maxRules) == 10)
        #expect(TokenGuard.expectedStoreCount(ruleCount: 0) == 2)
        #expect(TokenGuard.expectedStoreCount(ruleCount: -3) == 2)

        try TokenGuard.checkStoreCount(GateLimits.maxNamedStores)
        try TokenGuard.checkWebFilterDomainCount(GateLimits.maxWebFilterDomains)
        #expect(throws: TokenGuardError.self) { try TokenGuard.checkStoreCount(51) }
        #expect(throws: TokenGuardError.self) { try TokenGuard.checkWebFilterDomainCount(51) }
    }

    @Test("A cap breach surfaces through Rule.validate() too")
    func ruleValidationSeesTheCap() {
        let overloaded = Rule(
            id: ruleID,
            name: "Too much",
            isEnabled: true,
            selection: SelectionRef(
                id: UUID(),
                digest: SelectionDigest(applicationCount: 51, fingerprint: "1111111111111111")
            ),
            createdAt: now,
            updatedAt: now
        )
        let issues = overloaded.validate()
        #expect(issues.contains(.tokenCapExceeded(collection: .applications, count: 51, limit: 50)))
        // An explicit closure, not `where: \.isBlocking`. `contains(where:)` is
        // `rethrows`, and the #expect expansion loses the non-throwing proof
        // through a key-path literal — it reports "call can throw, but it is
        // not marked with 'try'" at a source location inside the macro.
        #expect(issues.contains { $0.isBlocking })

        let nameless = Rule(id: ruleID, name: "   ", createdAt: now, updatedAt: now)
        #expect(nameless.validate().contains(.emptyName))
        #expect(nameless.validate().contains(.noSelection))
    }
}

// MARK: - The store contract

// `StateStoring` lives in `Kernel/Store/GateStateStore.swift`, which imports
// `os`. The protocol and its extension are pure, so everything below is a fake
// and touches no file system — but the fence has to match the source's.

#if canImport(os)

/// An in-memory `StateStoring`.
///
/// `@unchecked Sendable` with no lock: each test owns its instance and nothing
/// here is used concurrently. The shipped `FileStateStore` earns its
/// concurrency safety properly; this one only has to satisfy the protocol.
private final class FakeStateStore: StateStoring, @unchecked Sendable {

    private var stored: GateState?
    private var bumps = 0

    /// Injected failure for the next `load()`. The `decodeFailed` case is the
    /// one that matters: it must NOT be swallowed by `load(orDefault:)`.
    var loadFailure: StateStoreError?
    var saveFailure: StateStoreError?
    private(set) var saveCount = 0

    init(seed: GateState? = nil) {
        stored = seed
        bumps = seed == nil ? 0 : 1
    }

    func load() throws -> GateState {
        if let loadFailure { throw loadFailure }
        guard let stored else { throw StateStoreError.stateMissing }
        return stored
    }

    func save(_ state: GateState) throws {
        if let saveFailure { throw saveFailure }
        stored = state
        bumps += 1
        saveCount += 1
    }

    var generation: Int { bumps }

    func erase() throws {
        stored = nil
        bumps += 1
    }
}

@Suite("StateStoring — a decode failure must never read as `no rules`")
struct StateStoringContractTests {

    private func seedState() -> GateState {
        GateState(
            schemaVersion: GateState.currentSchemaVersion,
            installID: installID,
            createdAt: now,
            updatedAt: now,
            rules: [makeRule()]
        )
    }

    @Test("A first run reports stateMissing, and only that substitutes the default")
    func firstRun() throws {
        let store = FakeStateStore()
        #expect(throws: StateStoreError.stateMissing) { try store.load() }

        let fallback = GateState.initial(now: now, installID: installID)
        let substituted = try store.load(orDefault: fallback)
        #expect(substituted == fallback)
        #expect(store.generation == 0)
    }

    @Test("A corrupt file surfaces as an error — it never degrades to an empty state")
    func decodeFailureRethrows() {
        let store = FakeStateStore(seed: seedState())
        store.loadFailure = .decodeFailed("truncated")

        // Returning an empty GateState here would make the next reconcile write
        // empty shield sets and unblock every rule. That is the one failure this
        // persistence design exists to avoid.
        #expect(throws: StateStoreError.decodeFailed("truncated")) {
            try store.load(orDefault: GateState.initial(now: now))
        }
    }

    @Test("Saving bumps the beacon; the beacon is an optimization, never correctness")
    func generationBeacon() throws {
        let store = FakeStateStore()
        var state = seedState()

        let unchanged = try store.loadIfChanged(since: 0)
        #expect(unchanged?.generation == nil, "nothing has been saved yet")

        try store.save(state)
        #expect(store.generation == 1)

        let change = try #require(store.loadIfChanged(since: 0))
        #expect(change.generation == 1)
        #expect(change.state == state)
        let stillCurrent = try store.loadIfChanged(since: 1)
        #expect(stillCurrent?.generation == nil, "the beacon has not moved")

        state.rules[0].name = "Renamed"
        try store.save(state)
        #expect(store.generation == 2)
        let renamed = try store.loadIfChanged(since: 1)
        #expect(renamed?.state.rules[0].name == "Renamed")
    }

    @Test("mutate is read-modify-write, seeded on a first run")
    func mutate() throws {
        let store = FakeStateStore()

        let created = try store.mutate(orDefault: GateState.initial(now: now, installID: installID)) {
            $0.rules.append(makeRule())
            $0.updatedAt = now
        }
        #expect(created.rules.count == 1)
        #expect(store.saveCount == 1)

        let persisted = try store.load()
        #expect(persisted.rules.count == 1)

        let grown = try store.mutate(orDefault: GateState.initial(now: now)) {
            $0.rules.append(makeRule(id: otherRuleID, sortIndex: 1))
        }
        #expect(grown.rules.count == 2)
        #expect(store.saveCount == 2)
    }

    @Test("A failed save does not move the beacon")
    func failedSaveDoesNotBumpTheBeacon() {
        let store = FakeStateStore()
        store.saveFailure = .writeFailed("read-only volume")

        #expect(throws: StateStoreError.writeFailed("read-only volume")) {
            try store.save(GateState.initial(now: now))
        }
        #expect(store.generation == 0)
    }

    @Test("Erasing removes the state but still moves the beacon")
    func erase() throws {
        let store = FakeStateStore(seed: seedState())
        let before = store.generation

        try store.erase()
        #expect(store.generation > before)
        #expect(throws: StateStoreError.stateMissing) { try store.load() }
    }

    @Test("The decode-migrate-use order is what the rest of the kernel assumes")
    func decodeMigrateUse() throws {
        let store = FakeStateStore()
        let raw = try decodeState([
            "rules": [ruleDict(sortIndex: 40)],
            "lock": dict(["k": "delay", "delay": 1.0]),
        ])
        try store.save(raw)

        let loaded = try store.load()
        let migrated = GateState.migrate(loaded, now: now)

        #expect(!migrated.report.isFromFuture, "safe to write back")
        #expect(migrated.state.rules[0].sortIndex == 0)
        #expect(migrated.state.lock.delay == GateLimits.minLockDelay)

        try store.save(migrated.state)
        let reloaded = try store.load()
        #expect(reloaded == migrated.state)
    }
}

#endif
