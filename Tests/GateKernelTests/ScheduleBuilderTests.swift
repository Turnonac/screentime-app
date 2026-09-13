//
//  ScheduleBuilderTests.swift
//  GateKernelTests
//
//  docs/06-build-plan.md step 3.11 — "DST and timezone boundaries in
//  `ScheduleBuilder`; 20-activity eviction; `ActivityNameCodec` round-trip".
//
//  WHAT THIS FILE IS DEFENDING
//  Three separate silent failures live in this layer:
//
//  1. **Mismatched component sets.** Thread 726331: if `intervalStart` and
//     `intervalEnd` carry different `DateComponents` sets, the previous start
//     resolves *after* the previous end and the schedule reads as continuously
//     active for days — every threshold breaches instantly and nothing in the
//     API tells you (docs/02-api-reference.md §7). `ScheduleSpec.isBalanced` is
//     the invariant; these tests are what prove it is unrepresentable.
//  2. **DST.** A window that vanishes on spring-forward day and happens twice on
//     fall-back day is the *correct* behaviour, and both have to be pinned or a
//     later "fix" will quietly break one of them.
//  3. **The 20-activity cap.** `startMonitoring` throws `.excessiveActivities` at
//     whatever arbitrary moment the budget is exceeded — typically while
//     applying a block. `MonitorPlan` evicts deliberately instead, and the policy
//     (furthest-out timer first) has to hold.
//
//  Every calendar here is constructed with an explicit time zone. Nothing reads
//  `Calendar.current` or `Date()`, so these tests give the same answer in CI, on
//  a developer's machine in another zone, and on a device.
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

private func window(
    _ startHour: Int,
    _ endHour: Int,
    weekdays: WeekdayMask = .everyday,
    warningMinutes: Int? = nil
) -> RuleSchedule {
    RuleSchedule(
        start: TimeOfDay(hour: startHour, minute: 0),
        end: TimeOfDay(hour: endHour, minute: 0),
        weekdays: weekdays,
        warningMinutes: warningMinutes
    )
}

/// How many one-minute samples of a local day fall inside `schedule`.
///
/// The honest way to ask "did this window happen, and for how long" across a DST
/// transition: it counts wall-clock minutes, which is exactly what
/// ``RuleSchedule/contains(_:in:)`` claims to answer.
private func minutesInside(
    _ schedule: RuleSchedule,
    onDayOf date: Date,
    in calendar: Calendar
) -> Int {
    let dayStart = calendar.startOfDay(for: date)
    let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    return stride(from: dayStart, to: nextDay, by: 60)
        .reduce(into: 0) { count, sample in
            if schedule.contains(sample, in: calendar) { count += 1 }
        }
}

// MARK: - DST

@Suite("ScheduleBuilder — daylight saving")
struct ScheduleBuilderDSTTests {

    // America/New_York 2025: DST starts Sun 9 March (02:00 EST -> 03:00 EDT) and
    // ends Sun 2 November (02:00 EDT -> 01:00 EST).
    private let newYork = calendar("America/New_York")

    @Test("Spring forward: a 01:00-04:00 window runs for two real hours, not three")
    func springForwardShortensTheWindow() throws {
        let schedule = window(1, 4)
        let normalDay = try instant(2025, 3, 8, 0, 30, in: newYork)
        let springForward = try instant(2025, 3, 9, 0, 30, in: newYork)

        let normal = try #require(ScheduleBuilder.nextWindow(of: schedule, after: normalDay, in: newYork))
        let shortened = try #require(
            ScheduleBuilder.nextWindow(of: schedule, after: springForward, in: newYork)
        )

        #expect(normal.duration == 3 * 3600)
        #expect(shortened.duration == 2 * 3600, "02:00 does not exist on 9 March 2025 in New York")
        // The wall-clock edges are still 01:00 and 04:00 — the hour is gone from
        // the elapsed time, not from the schedule.
        #expect(newYork.component(.hour, from: shortened.start) == 1)
        #expect(newYork.component(.hour, from: shortened.end) == 4)
    }

    @Test("Spring forward: a window inside the skipped hour simply never matches")
    func springForwardSkippedWindowNeverMatches() throws {
        let skipped = window(2, 3)
        let springForward = try instant(2025, 3, 9, 12, 0, in: newYork)
        let normalDay = try instant(2025, 3, 8, 12, 0, in: newYork)

        // Not "an error", not "always on": no instant that day has an hour
        // component of 2, so the answer is `false` all day. That is the same
        // thing iOS does with the underlying DateComponents.
        #expect(minutesInside(skipped, onDayOf: springForward, in: newYork) == 0)
        #expect(minutesInside(skipped, onDayOf: normalDay, in: newYork) == 60)
    }

    @Test("Fall back: a 01:00-02:00 window happens twice, for two real hours")
    func fallBackRepeatsTheWindow() throws {
        let schedule = window(1, 2)
        let fallBack = try instant(2025, 11, 2, 12, 0, in: newYork)
        let normalDay = try instant(2025, 11, 3, 12, 0, in: newYork)

        #expect(minutesInside(schedule, onDayOf: fallBack, in: newYork) == 120)
        #expect(minutesInside(schedule, onDayOf: normalDay, in: newYork) == 60)
    }

    @Test("Fall back: boundaries resolve to the first occurrence, never both")
    func fallBackEmitsOneBoundaryPair() throws {
        let schedule = window(1, 4)
        let start = try instant(2025, 11, 2, 0, 30, in: newYork)

        let boundaries = ScheduleBuilder.boundaries(of: schedule, after: start, limit: 4, in: newYork)
        #expect(boundaries.count == 4)
        #expect(boundaries.map(\.edge) == [.start, .end, .start, .end])

        // 01:00 EDT through 04:00 EST is four real hours.
        let opened = try #require(ScheduleBuilder.nextWindow(of: schedule, after: start, in: newYork))
        #expect(opened.duration == 4 * 3600)

        // Emitting both fall-back occurrences would double a backstop
        // notification; emitting neither would drop one.
        #expect(boundaries[0].date < boundaries[1].date)
        #expect(boundaries[1].date < boundaries[2].date)
    }

    @Test("absoluteComponents(notEarlierThan:) never arms a timer early in the repeated hour")
    func fallBackAmbiguityResolvesForward() throws {
        // 00:30 EDT is unambiguous; +2h lands on the SECOND 01:30, which is EST.
        let firstMidnightHalf = try instant(2025, 11, 2, 0, 30, in: newYork)
        let secondOneThirty = firstMidnightHalf.addingTimeInterval(2 * 3600)

        // Raw components of that instant resolve BACK to the first 01:30 — an
        // hour early. An auto-revert timer applies a queued loosening, so an
        // hour early is exactly what the Lock exists to prevent.
        let raw = ScheduleBuilder.absoluteComponents(for: secondOneThirty, in: newYork)
        let naive = try #require(newYork.date(from: raw))
        #expect(naive < secondOneThirty)
        #expect(secondOneThirty.timeIntervalSince(naive) == 3600)

        let corrected = ScheduleBuilder.absoluteComponents(
            notEarlierThan: secondOneThirty, in: newYork
        )
        let resolved = try #require(newYork.date(from: corrected))
        #expect(resolved >= secondOneThirty)
        #expect(corrected.hour == 2)
        #expect(corrected.minute == 30)
    }

    @Test("absoluteComponents(notEarlierThan:) is the identity on an unambiguous instant")
    func unambiguousInstantsAreUntouched() throws {
        let ordinary = try instant(2025, 6, 15, 9, 30, in: newYork)
        #expect(
            ScheduleBuilder.absoluteComponents(notEarlierThan: ordinary, in: newYork)
                == ScheduleBuilder.absoluteComponents(for: ordinary, in: newYork)
        )
    }

    @Test("The same window in another zone transitions on that zone's own dates")
    func transitionsAreZoneLocal() throws {
        // Europe/London moved on 30 March 2025, three weeks after New York.
        let london = calendar("Europe/London")
        let schedule = window(1, 4)

        let londonNormal = try instant(2025, 3, 9, 0, 30, in: london)
        let londonSpring = try instant(2025, 3, 30, 0, 30, in: london)

        let normal = try #require(ScheduleBuilder.nextWindow(of: schedule, after: londonNormal, in: london))
        let shortened = try #require(ScheduleBuilder.nextWindow(of: schedule, after: londonSpring, in: london))

        #expect(normal.duration == 3 * 3600)
        #expect(shortened.duration == 2 * 3600)
    }
}

// MARK: - Midnight crossing and weekday scoping

@Suite("ScheduleBuilder — overnight windows and weekday masks (docs/04-product-spec.md V1-5)")
struct ScheduleBuilderWindowTests {

    private let newYork = calendar("America/New_York")

    @Test("A 22:00-06:00 Friday window covers Friday night and Saturday morning only")
    func overnightWindowBelongsToTheDayItStartsOn() throws {
        let overnight = window(22, 6, weekdays: .friday)

        let fridayEvening = try instant(2025, 6, 13, 23, 0, in: newYork)
        let saturdayMorning = try instant(2025, 6, 14, 3, 0, in: newYork)
        let saturdayEvening = try instant(2025, 6, 14, 23, 0, in: newYork)
        let fridayMorning = try instant(2025, 6, 13, 5, 0, in: newYork)

        #expect(overnight.crossesMidnight)
        #expect(overnight.duration == 8 * 3600)
        #expect(overnight.contains(fridayEvening, in: newYork))
        #expect(overnight.contains(saturdayMorning, in: newYork), "the tail belongs to Friday's occurrence")
        #expect(!overnight.contains(saturdayEvening, in: newYork), "Saturday is not in the mask")
        #expect(!overnight.contains(fridayMorning, in: newYork), "that tail belongs to Thursday")
    }

    @Test("Boundaries of an overnight window are Friday 22:00 then Saturday 06:00")
    func overnightBoundaries() throws {
        let overnight = window(22, 6, weekdays: .friday)
        let fridayNoon = try instant(2025, 6, 13, 12, 0, in: newYork)

        let fridayNight = try instant(2025, 6, 13, 22, 0, in: newYork)
        let saturdayDawn = try instant(2025, 6, 14, 6, 0, in: newYork)

        let boundaries = ScheduleBuilder.boundaries(of: overnight, after: fridayNoon, limit: 2, in: newYork)
        #expect(boundaries.count == 2)
        #expect(boundaries[0].edge == .start)
        #expect(boundaries[0].date == fridayNight)
        #expect(boundaries[1].edge == .end)
        #expect(boundaries[1].date == saturdayDawn)

        // Never Friday 06:00 — that edge belongs to a Thursday occurrence the
        // mask does not cover.
        #expect(ScheduleBuilder.nextBoundary(of: overnight, after: fridayNoon, in: newYork) == boundaries[0])
    }

    @Test("The window that is open right now is returned, not the next one")
    func nextWindowReturnsTheOpenOne() throws {
        let schedule = window(9, 17)
        let midMorning = try instant(2025, 6, 16, 10, 0, in: newYork)

        let opens = try instant(2025, 6, 16, 9, 0, in: newYork)
        let closes = try instant(2025, 6, 16, 17, 0, in: newYork)

        let current = try #require(ScheduleBuilder.nextWindow(of: schedule, after: midMorning, in: newYork))
        #expect(current.start == opens)
        #expect(current.end == closes)
        #expect(current.contains(midMorning))

        // Standing exactly on the opening edge still finds that edge: `contains`
        // is half-open and includes the start.
        let onTheEdge = try instant(2025, 6, 16, 9, 0, in: newYork)
        let fromEdge = try #require(ScheduleBuilder.nextWindow(of: schedule, after: onTheEdge, in: newYork))
        #expect(fromEdge.start == onTheEdge)
    }

    @Test("A weekday mask skips the days it does not name")
    func weekdayMaskSkipsDays() throws {
        let weekendsOnly = window(9, 17, weekdays: .weekend)
        let thursday = try instant(2025, 6, 12, 12, 0, in: newYork)

        // Saturday 14 June 2025.
        let saturdayMorning = try instant(2025, 6, 14, 9, 0, in: newYork)
        let next = try #require(
            ScheduleBuilder.nextWindow(of: weekendsOnly, after: thursday, in: newYork)
        )
        #expect(next.start == saturdayMorning)
    }

    @Test("An empty mask or a malformed window produces no boundaries at all")
    func unusableSchedulesProduceNothing() throws {
        let anchor = try instant(2025, 6, 16, 12, 0, in: newYork)

        let noDays = window(9, 17, weekdays: [])
        #expect(!noDays.isWellFormed)
        #expect(ScheduleBuilder.boundaries(of: noDays, after: anchor, in: newYork).isEmpty)
        #expect(ScheduleBuilder.nextWindow(of: noDays, after: anchor, in: newYork) == nil)

        let zeroLength = window(9, 9)
        #expect(zeroLength.duration == 0)
        #expect(!zeroLength.isWellFormed)
        #expect(ScheduleBuilder.nextWindow(of: zeroLength, after: anchor, in: newYork) == nil)
    }

    @Test("WeekdayMask bit order matches Calendar's 1...7 weekdays")
    func weekdayMaskBitOrder() {
        #expect(WeekdayMask(calendarWeekday: 1) == .sunday)
        #expect(WeekdayMask(calendarWeekday: 2) == .monday)
        #expect(WeekdayMask(calendarWeekday: 7) == .saturday)
        // Out of range is an empty mask, never a trap and never a wrong day.
        #expect(WeekdayMask(calendarWeekday: 0).isEmpty)
        #expect(WeekdayMask(calendarWeekday: 8).isEmpty)

        #expect(WeekdayMask.everyday.calendarWeekdays == [1, 2, 3, 4, 5, 6, 7])
        #expect(WeekdayMask.workweek.calendarWeekdays == [2, 3, 4, 5, 6])
        #expect(WeekdayMask.weekend.calendarWeekdays == [1, 7])
        #expect(WeekdayMask.workweek.contains(calendarWeekday: 3))
        #expect(!WeekdayMask.workweek.contains(calendarWeekday: 1))
        #expect(WeekdayMask.everyday == WeekdayMask.workweek.union(.weekend))
    }

    @Test("WeekdayMask is stored as a bare Int, and an unreadable one defaults to every day")
    func weekdayMaskCoding() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        let encoded = try encoder.encode(["w": WeekdayMask.workweek])
        let asInt = try PropertyListDecoder().decode([String: Int].self, from: encoded)
        #expect(asInt["w"] == WeekdayMask.workweek.rawValue)
        #expect(asInt["w"] == 62)

        // A malformed value must not silently narrow the days a rule covers:
        // "every day" is the stricter reading.
        let plist: [String: Any] = ["w": "not-an-int"]
        let malformed = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0
        )
        let recovered = try PropertyListDecoder().decode([String: WeekdayMask].self, from: malformed)
        #expect(recovered["w"] == .everyday)
    }

    @Test("TimeOfDay clamps rather than trapping, and wraps past midnight")
    func timeOfDayIsTotal() {
        #expect(TimeOfDay(hour: 99, minute: -4, second: 200) == TimeOfDay(hour: 23, minute: 0, second: 59))
        #expect(TimeOfDay(secondsFromMidnight: -1).secondsFromMidnight == TimeOfDay.secondsPerDay - 1)
        #expect(TimeOfDay(secondsFromMidnight: TimeOfDay.secondsPerDay).secondsFromMidnight == 0)
        #expect(TimeOfDay(hour: 22, minute: 30) > TimeOfDay(hour: 6, minute: 0))
    }
}

// MARK: - The component-set invariant

@Suite("ScheduleBuilder — the identical-component-set invariant (thread 726331)")
struct ScheduleSpecShapeTests {

    private let newYork = calendar("America/New_York")

    @Test("A repeating window carries exactly [.hour, .minute, .second] on both ends")
    func repeatingShape() throws {
        let outcome = ScheduleBuilder.repeatingSpec(for: window(22, 6, warningMinutes: 5))
        guard case .scheduled(let spec, let droppedWarning) = outcome else {
            Issue.record("expected a registrable window, got \(outcome)")
            return
        }

        #expect(!droppedWarning)
        #expect(spec.shape == .timeOfDay)
        #expect(spec.repeats)
        #expect(spec.isBalanced)
        #expect(ScheduleSpec.presentComponents(spec.intervalStart) == [.hour, .minute, .second])
        #expect(ScheduleSpec.presentComponents(spec.intervalEnd) == [.hour, .minute, .second])
        #expect(spec.intervalStart.hour == 22)
        #expect(spec.intervalEnd.hour == 6)
        // Nominal, and correct: it wraps past midnight.
        #expect(spec.nominalDuration == 8 * 3600)

        // The warning lead is a DURATION and is deliberately a different
        // component set; the matching rule governs the two ends and nothing else.
        let warning = try #require(spec.warningTime)
        #expect(warning == DateComponents(minute: 5))
        #expect(ScheduleSpec.presentComponents(warning) == [.minute])
    }

    @Test("A one-shot timer carries exactly [.year ... .second] on both ends")
    func oneShotShape() throws {
        let now = try instant(2025, 6, 16, 14, 0, in: newYork)
        let outcome = ScheduleBuilder.oneShotSpec(
            deadline: now.addingTimeInterval(5 * 60), now: now, calendar: newYork
        )
        guard case .scheduled(let spec, let interval) = outcome else {
            Issue.record("expected a schedulable timer, got \(outcome)")
            return
        }

        #expect(spec.shape == .absolute)
        #expect(!spec.repeats)
        #expect(spec.isBalanced)
        #expect(
            ScheduleSpec.presentComponents(spec.intervalStart)
                == [.year, .month, .day, .hour, .minute, .second]
        )
        #expect(
            ScheduleSpec.presentComponents(spec.intervalEnd)
                == ScheduleSpec.presentComponents(spec.intervalStart)
        )
        // No warning on a one-shot: a second callback to learn nothing the
        // reconcile at intervalDidEnd does not already recompute.
        #expect(spec.warningTime == nil)
        #expect(spec.nominalDuration == nil)

        // Start in the past so the system calls intervalDidStart immediately —
        // the only cheap confirmation that the arm took.
        #expect(interval.start <= now)
        #expect(interval.duration >= GateLimits.minScheduleInterval)
        #expect(interval.duration <= GateLimits.maxScheduleInterval)
    }

    @Test("The two shapes disagree about their component sets, and only about that")
    func shapesAreDistinct() {
        #expect(ScheduleSpec.Shape.timeOfDay.components == [.hour, .minute, .second])
        #expect(
            ScheduleSpec.Shape.absolute.components
                == [.year, .month, .day, .hour, .minute, .second]
        )
        #expect(ScheduleSpec.Shape.timeOfDay.repeats)
        #expect(!ScheduleSpec.Shape.absolute.repeats)
    }

    @Test("An unbalanced spec is detectable, so the debug screen can say so")
    func unbalancedIsDetectable() {
        // Only constructible by hand — every builder path produces a balanced
        // spec. This is the failure thread 726331 describes.
        let mismatched = ScheduleSpec(
            shape: .timeOfDay,
            intervalStart: DateComponents(hour: 22, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 6, minute: 0)
        )
        #expect(!mismatched.isBalanced)
    }

    @Test("The fingerprint distinguishes an absent component from a zero one")
    func fingerprintDistinguishesAbsentFromZero() {
        let withSeconds = ScheduleSpec(
            shape: .timeOfDay,
            intervalStart: DateComponents(hour: 9, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 17, minute: 0, second: 0)
        )
        let withoutSeconds = ScheduleSpec(
            shape: .timeOfDay,
            intervalStart: DateComponents(hour: 9, minute: 0),
            intervalEnd: DateComponents(hour: 17, minute: 0)
        )
        #expect(withSeconds.fingerprint != withoutSeconds.fingerprint)
        // Deterministic across calls and processes — it is written by the app
        // and compared by code running in the monitor.
        #expect(withSeconds.fingerprint == withSeconds.fingerprint)
    }

    @Test("Windows iOS would refuse are refused here instead")
    func unregistrableWindows() {
        let tooShort = window(9, 9, warningMinutes: nil)
        guard case .unregistrable(let degenerate) = ScheduleBuilder.repeatingSpec(for: tooShort) else {
            Issue.record("a zero-length window must not be registrable")
            return
        }
        #expect(degenerate.contains(.degenerateSchedule))

        let tenMinutes = RuleSchedule(
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 9, minute: 10),
            warningMinutes: nil
        )
        guard case .unregistrable(let short) = ScheduleBuilder.repeatingSpec(for: tenMinutes) else {
            Issue.record("a 10-minute window is below the platform floor")
            return
        }
        #expect(short.contains(.scheduleTooShort(seconds: 600, minimum: GateLimits.minScheduleInterval)))

        #expect(ScheduleBuilder.repeatingSpec(for: window(9, 17, weekdays: [])).spec == nil)
    }

    @Test("A warning that does not fit is dropped; the window is still armed")
    func warningTooLongIsRecoverable() throws {
        // Dropping a warningTime costs two advisory callbacks. Dropping the
        // window costs the block.
        let halfHour = RuleSchedule(
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 9, minute: 30),
            warningMinutes: 60
        )
        guard case .scheduled(let spec, let dropped) = ScheduleBuilder.repeatingSpec(for: halfHour) else {
            Issue.record("a too-long warning must not cost the window")
            return
        }
        #expect(dropped)
        #expect(spec.warningTime == nil)
        #expect(spec.isBalanced)
    }

    @Test("A zero-minute warning is normalized away rather than handed to the daemon")
    func zeroWarningIsNormalized() throws {
        let outcome = ScheduleBuilder.repeatingSpec(for: window(9, 17, warningMinutes: 0))
        let spec = try #require(outcome.spec)
        #expect(spec.warningTime == nil)
    }

    @Test("A rule with no schedule, or a disabled one, needs no activity at all")
    func noWindowMeansNoActivity() {
        let unscheduled = Rule(id: UUID(), name: "Always", isEnabled: true, schedule: nil)
        #expect(ScheduleBuilder.repeatingSpec(for: unscheduled) == nil)

        let disabled = Rule(id: UUID(), name: "Off", isEnabled: false, schedule: window(9, 17))
        #expect(ScheduleBuilder.repeatingSpec(for: disabled) == nil)
    }
}

// MARK: - One-shot corrections

@Suite("ScheduleBuilder — one-shot timers")
struct ScheduleBuilderOneShotTests {

    private let newYork = calendar("America/New_York")

    @Test("Just after midnight the start is pulled back a day to clear the 15-minute floor")
    func lateNightFloor() throws {
        // §7's one-line recipe (start = startOfDay, end = max(deadline, now+60))
        // yields a six-minute interval here and `.intervalTooShort` thrown while
        // applying a block.
        let now = try instant(2025, 6, 16, 0, 5, in: newYork)
        let yesterdayMidnight = try instant(2025, 6, 15, 0, 0, in: newYork)
        let outcome = ScheduleBuilder.oneShotSpec(
            deadline: now.addingTimeInterval(60), now: now, calendar: newYork
        )
        let interval = try #require(outcome.interval)
        let spec = try #require(outcome.spec)

        #expect(interval.duration >= GateLimits.minScheduleInterval)
        #expect(interval.start <= now)
        #expect(interval.start == yesterdayMidnight)
        #expect(spec.isBalanced)
    }

    @Test("A seven-day deadline is pulled inside the one-week ceiling")
    func oneWeekCeiling() throws {
        let now = try instant(2025, 6, 16, 14, 0, in: newYork)
        let deadline = now.addingTimeInterval(GateLimits.maxLockDelay)

        let outcome = ScheduleBuilder.oneShotSpec(deadline: deadline, now: now, calendar: newYork)
        let interval = try #require(outcome.interval)

        #expect(interval.duration <= GateLimits.maxScheduleInterval)
        #expect(interval.duration == GateLimits.maxScheduleInterval - ScheduleBuilder.ceilingMargin)
        // The callback that matters — intervalDidEnd — is still on the deadline.
        #expect(interval.end == deadline)
    }

    @Test("Past the one-week ceiling the timer is simply not armed")
    func beyondTheCeiling() throws {
        let now = try instant(2025, 6, 16, 14, 0, in: newYork)
        let outcome = ScheduleBuilder.oneShotSpec(
            deadline: now.addingTimeInterval(GateLimits.maxScheduleInterval + 3600),
            now: now,
            calendar: newYork
        )

        #expect(outcome.spec == nil)
        if case .unschedulable(let reason) = outcome {
            // Routine and self-healing: a seven-day Lock delay's revert timer is
            // armed once the deadline comes inside the ceiling.
            #expect(reason == .deadlineTooFarOut)
        } else {
            Issue.record("expected .unschedulable, got \(outcome)")
        }
    }

    @Test("A deadline already in the past is pushed to the minimum lead, not rejected")
    func pastDeadlineIsStillArmable() throws {
        let now = try instant(2025, 6, 16, 14, 0, in: newYork)
        let outcome = ScheduleBuilder.oneShotSpec(
            deadline: now.addingTimeInterval(-3600), now: now, calendar: newYork
        )
        let interval = try #require(outcome.interval)

        #expect(interval.end >= now.addingTimeInterval(ScheduleBuilder.minimumLead))
        #expect(ScheduleBuilder.minimumLead == GateLimits.eventFalsePositiveGuard)
    }

    @Test("A one-shot spanning the spring-forward hour is still a legal interval")
    func oneShotAcrossSpringForward() throws {
        let now = try instant(2025, 3, 9, 0, 30, in: newYork)
        let outcome = ScheduleBuilder.oneShotSpec(
            deadline: now.addingTimeInterval(4 * 3600), now: now, calendar: newYork
        )
        let interval = try #require(outcome.interval)
        let spec = try #require(outcome.spec)

        #expect(spec.isBalanced)
        #expect(interval.duration >= GateLimits.minScheduleInterval)
        #expect(interval.duration <= GateLimits.maxScheduleInterval)
        #expect(interval.end == now.addingTimeInterval(4 * 3600))
    }
}

// MARK: - ActivityNameCodec

@Suite("ActivityNameCodec — the monitor's only payload (docs/02-api-reference.md §8)")
struct ActivityNameCodecTests {

    private let ruleID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let grantID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let changeID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    @Test("Round trip: decode(encode(x)) == x for every activity shape")
    func roundTrip() {
        let activities: [GateActivity] = [
            .rule(ruleID: ruleID),
            .grant(ruleID: ruleID, grantID: grantID),
            .revert(ruleID: ruleID, changeID: changeID),
            .revert(ruleID: nil, changeID: changeID),
        ]

        for activity in activities {
            let raw = ActivityNameCodec.encode(activity)
            #expect(ActivityNameCodec.decode(raw) == activity)
            #expect(raw == activity.rawName)
            #expect(ActivityNameCodec.isGateName(raw))
            #expect(ActivityNameCodec.kind(ofRawName: raw) == activity.kind)
        }
    }

    @Test("The wire shapes are exactly what docs/05-architecture.md specifies")
    func wireShapes() {
        #expect(
            ActivityNameCodec.encode(.rule(ruleID: ruleID))
                == "gate.rule:\(ruleID.uuidString)"
        )
        #expect(
            ActivityNameCodec.encode(.grant(ruleID: ruleID, grantID: grantID))
                == "gate.grant:\(ruleID.uuidString)|\(grantID.uuidString)"
        )
        #expect(
            ActivityNameCodec.encode(.revert(ruleID: ruleID, changeID: changeID))
                == "gate.revert:\(ruleID.uuidString)|\(changeID.uuidString)"
        )
        #expect(
            ActivityNameCodec.encode(event: GateEventKey(ruleID: ruleID, thresholdSeconds: 900))
                == "gate.evt:\(ruleID.uuidString)|900"
        )
        // Every name is built from GateID.namespace, never a literal.
        #expect("gate.rule:\(ruleID.uuidString)".hasPrefix(GateID.namespace))
    }

    @Test("An unscoped revert timer uses the reserved all-zero sentinel")
    func unscopedRevert() {
        let raw = ActivityNameCodec.encode(.revert(ruleID: nil, changeID: changeID))
        #expect(raw == "gate.revert:00000000-0000-0000-0000-000000000000|\(changeID.uuidString)")
        #expect(GateActivity.unscopedID.uuidString == "00000000-0000-0000-0000-000000000000")
        #expect(ActivityNameCodec.decode(raw) == .revert(ruleID: nil, changeID: changeID))

        // `UUID()` cannot produce the sentinel — RFC 4122 pins the version and
        // variant bits — so no real rule id can collide with it.
        #expect(UUID() != GateActivity.unscopedID)
    }

    @Test("Malformed names decode to nil rather than throwing or guessing")
    func malformedNamesReturnNil() {
        let bad = [
            "",
            "gate.",
            "gate.rule",
            "gate.rule:",
            "gate.rule:not-a-uuid",
            "gate.rule:\(ruleID.uuidString)|\(grantID.uuidString)",      // an extra field
            "gate.grant:\(ruleID.uuidString)",                            // a missing field
            "gate.grant:|\(grantID.uuidString)",                          // an empty field
            "gate.grant:\(ruleID.uuidString)|",                           // a trailing empty field
            "gate.revert:\(ruleID.uuidString)|\(changeID.uuidString)|x",  // three fields
            "gate.rule:\(ruleID.uuidString):extra",                       // a second tag separator
            "gate.RULE:\(ruleID.uuidString)",                             // the tag is case-sensitive
            "gate.evt:\(ruleID.uuidString)|900",                          // an EVENT name, not an activity
            "com.example.other:\(ruleID.uuidString)",                     // foreign
            "\(ruleID.uuidString)",                                       // no namespace
        ]

        for raw in bad {
            #expect(ActivityNameCodec.decode(raw) == nil, "\(raw) must not decode as an activity")
        }
    }

    @Test("A Gate name that does not decode is still Gate's — the orphan sweep must own it")
    func gateNamesThatDoNotDecode() {
        // An event name, and a name from a build that knows a kind this one does
        // not. Both are inside the namespace, so the reconciler must stop them
        // rather than treating them as another target's foreign activity.
        let eventName = "gate.evt:\(ruleID.uuidString)|900"
        let futureName = "gate.staircase:\(ruleID.uuidString)"

        #expect(ActivityNameCodec.isGateName(eventName))
        #expect(ActivityNameCodec.isGateName(futureName))
        #expect(ActivityNameCodec.decode(eventName) == nil)
        #expect(ActivityNameCodec.decode(futureName) == nil)
        #expect(ActivityNameCodec.kind(ofRawName: futureName) == nil)
        #expect(!ActivityNameCodec.isGateName("com.example.widget:1"))
    }

    @Test("Either UUID casing parses; encoding is canonical")
    func casingIsAcceptedOnTheWayIn() {
        let lowercased = "gate.rule:\(ruleID.uuidString.lowercased())"
        #expect(ActivityNameCodec.decode(lowercased) == .rule(ruleID: ruleID))
        // Compare parsed values, never raw strings: the reverse round trip is
        // deliberately not guaranteed.
        #expect(ActivityNameCodec.encode(.rule(ruleID: ruleID)) != lowercased)
    }

    @Test("Event names round-trip and reject anything Gate would not have written")
    func eventNames() {
        let key = GateEventKey(ruleID: ruleID, thresholdSeconds: 1800)
        #expect(ActivityNameCodec.decode(eventName: key.rawName) == key)
        #expect(ActivityNameCodec.decode(eventName: "gate.rule:\(ruleID.uuidString)") == nil)

        // Strict decimal: anything that does not re-render to itself is a name
        // Gate did not write, and a name Gate did not write is not one it acts on.
        for field in ["+5", "007", " 5", "5 ", "-60", "1e3", ""] {
            #expect(
                ActivityNameCodec.decode(eventName: "gate.evt:\(ruleID.uuidString)|\(field)") == nil,
                "threshold field '\(field)'"
            )
        }
    }

    @Test("Event thresholds clamp and round rather than trapping")
    func eventThresholdArithmetic() {
        #expect(GateEventKey(ruleID: ruleID, thresholdSeconds: -30).thresholdSeconds == 0)
        #expect(GateEventKey(ruleID: ruleID, threshold: 89.6).thresholdSeconds == 90)
        #expect(GateEventKey(ruleID: ruleID, threshold: .infinity).thresholdSeconds == 0)

        // Screen Time accounting is minute-grained, and a zero-minute threshold
        // is not a threshold.
        #expect(EventSpec(key: GateEventKey(ruleID: ruleID, thresholdSeconds: 1)).threshold
            == DateComponents(minute: 1))
        #expect(EventSpec(key: GateEventKey(ruleID: ruleID, thresholdSeconds: 1800)).threshold
            == DateComponents(minute: 30))
        // v1 arms no events at all, and never asks for past activity.
        #expect(EventSpec(key: GateEventKey(ruleID: ruleID, thresholdSeconds: 60)).includesPastActivity == false)
    }

    @Test("Decoded identities answer what the monitor needs to know")
    func decodedIdentities() {
        let grant = GateActivity.grant(ruleID: ruleID, grantID: grantID)
        #expect(grant.ruleID == ruleID)
        #expect(grant.recordID == grantID)
        #expect(grant.isOneShot)

        let ruleWindow = GateActivity.rule(ruleID: ruleID)
        #expect(ruleWindow.recordID == nil)
        #expect(!ruleWindow.isOneShot)

        let unscoped = GateActivity.revert(ruleID: nil, changeID: changeID)
        #expect(unscoped.ruleID == nil)
        #expect(unscoped.recordID == changeID)
        #expect(unscoped.isOneShot)
    }
}

// MARK: - MonitorPlan

@Suite("MonitorPlan — the 20-activity budget (docs/05-architecture.md)")
struct MonitorPlanTests {

    private let newYork = calendar("America/New_York")

    private func scheduledRule(index: Int) -> Rule {
        Rule(
            id: UUID(),
            name: "Rule \(index)",
            isEnabled: true,
            schedule: window(9, 17),
            selection: SelectionRef(
                id: UUID(),
                digest: SelectionDigest(applicationCount: 3, fingerprint: "aaaaaaaaaaaaaaaa")
            ),
            sortIndex: index,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    private func state(
        rules: [Rule] = [],
        grants: [Grant] = [],
        pendingChanges: [PendingChange] = [],
        now: Date
    ) -> GateState {
        GateState(
            schemaVersion: GateState.currentSchemaVersion,
            installID: UUID(),
            createdAt: now,
            updatedAt: now,
            rules: rules,
            pendingChanges: pendingChanges,
            grants: grants,
            grantLedger: GrantLedger(used: 0, periodStart: now)
        )
    }

    @Test("The budget is the platform cap minus the reserved headroom")
    func budgetArithmetic() {
        #expect(GateLimits.activityHeadroom == 2)
        #expect(MonitorPlan.budget == GateLimits.maxConcurrentActivities - GateLimits.activityHeadroom)
        #expect(MonitorPlan.budget == 18)
        // The three per-kind caps sum to exactly the budget, so the two limits
        // agree by construction rather than by coincidence.
        #expect(
            ActivityPriority.allCases.reduce(0, { $0 + $1.cap }) == MonitorPlan.budget
        )
        #expect(ActivityPriority.ruleWindow.cap == 8)
        #expect(ActivityPriority.grantExpiry.cap == 6)
        #expect(ActivityPriority.revertTimer.cap == 4)
        #expect(ActivityPriority.ruleWindow < ActivityPriority.grantExpiry)
        #expect(ActivityPriority.grantExpiry < ActivityPriority.revertTimer)
        #expect(!ActivityPriority.ruleWindow.isTimer)
        #expect(ActivityPriority.revertTimer.isTimer)
    }

    @Test("Over the grant cap, the FURTHEST-OUT timers are the ones evicted")
    func grantEvictionTakesTheFurthestOut() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rule = scheduledRule(index: 0)

        // Eight live grants, expiring 1 through 8 minutes out.
        let grants = (1...8).map { minutes in
            Grant(
                id: UUID(),
                ruleID: rule.id,
                scope: .entireRule,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(TimeInterval(minutes) * 60),
                source: .intervention
            )
        }
        let plan = MonitorPlan.make(
            from: state(rules: [rule], grants: grants, now: now), now: now, calendar: newYork
        )

        let kept = plan.entries(for: .grantExpiry)
        #expect(kept.count == GateLimits.maxGrantActivities)
        #expect(kept.compactMap(\.deadline) == grants.prefix(6).map(\.expiresAt))

        let evicted = plan.evictions.filter { $0.priority == .grantExpiry }
        #expect(evicted.count == 2)
        #expect(evicted.allSatisfy({ $0.reason == .kindCapExceeded }))
        #expect(evicted.compactMap(\.deadline).sorted() == grants.suffix(2).map(\.expiresAt))

        // Nothing is ever silently dropped: the debug screen renders this.
        for eviction in evicted {
            #expect(ActivityNameCodec.isGateName(eviction.name))
        }
    }

    @Test("Over the revert cap, the furthest-out revert timer goes first")
    func revertEvictionTakesTheFurthestOut() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rule = scheduledRule(index: 0)

        let changes = (1...6).map { hours in
            PendingChange(
                id: UUID(),
                operation: .disableRule(ruleID: rule.id),
                requestedAt: now,
                earliestApplyAt: now.addingTimeInterval(TimeInterval(hours) * 3600),
                lockConfigHash: "cfg"
            )
        }
        let plan = MonitorPlan.make(
            from: state(rules: [rule], pendingChanges: changes, now: now), now: now, calendar: newYork
        )

        let kept = plan.entries(for: .revertTimer)
        #expect(kept.count == GateLimits.maxRevertActivities)
        #expect(kept.compactMap(\.deadline) == changes.prefix(4).compactMap(\.earliestApplyAt))

        let evicted = plan.evictions.filter { $0.priority == .revertTimer }
        #expect(evicted.count == 2)
        #expect(evicted.compactMap(\.deadline).sorted() == changes.suffix(2).compactMap(\.earliestApplyAt))
    }

    @Test("Over the rule cap, the user's own ordering decides which window survives")
    func windowEvictionFollowsSortIndex() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rules = (0..<10).map { scheduledRule(index: $0) }
        let plan = MonitorPlan.make(from: state(rules: rules, now: now), now: now, calendar: newYork)

        let kept = plan.entries(for: .ruleWindow)
        #expect(kept.count == GateLimits.maxRepeatingActivities)
        #expect(kept.map(\.name) == rules.prefix(8).map({ GateActivity.rule(ruleID: $0.id).rawName }))
        #expect(plan.evictions.filter({ $0.priority == .ruleWindow }).count == 2)
    }

    @Test("A full plan fits the budget exactly and never exceeds the platform cap")
    func fullPlanFitsTheBudget() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rules = (0..<8).map { scheduledRule(index: $0) }
        let grants = (1...6).map { minutes in
            Grant(
                id: UUID(),
                ruleID: rules[0].id,
                scope: .entireRule,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(TimeInterval(minutes) * 60),
                source: .intervention
            )
        }
        let changes = (1...4).map { hours in
            PendingChange(
                id: UUID(),
                operation: .deleteRule(ruleID: rules[0].id),
                requestedAt: now,
                earliestApplyAt: now.addingTimeInterval(TimeInterval(hours) * 3600),
                lockConfigHash: "cfg"
            )
        }

        let plan = MonitorPlan.make(
            from: state(rules: rules, grants: grants, pendingChanges: changes, now: now),
            now: now,
            calendar: newYork
        )

        #expect(plan.entries.count == MonitorPlan.budget)
        #expect(plan.entries.count <= GateLimits.maxConcurrentActivities)
        #expect(plan.evictions.isEmpty)
        // Arm order is priority order: windows, then grant expiries, then
        // reverts, so a throw part-way through degrades in the right direction.
        #expect(plan.entries.map(\.priority) == plan.entries.map(\.priority).sorted())
        #expect(plan.names.count == plan.entries.count)
        #expect(plan.fingerprints.count == plan.entries.count)
    }

    @Test("One activity per rule, never one per weekday")
    func oneActivityPerRule() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        var rule = scheduledRule(index: 0)
        rule.schedule = window(9, 17, weekdays: .workweek)

        let plan = MonitorPlan.make(from: state(rules: [rule], now: now), now: now, calendar: newYork)
        #expect(plan.entries(for: .ruleWindow).count == 1, "five weekdays would blow the cap at rule #3")
        #expect(plan.entry(named: GateActivity.rule(ruleID: rule.id).rawName) != nil)
    }

    @Test("Everything the plan declines to arm is explained, never silent")
    func diagnostics() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)

        var unscheduled = scheduledRule(index: 0)
        unscheduled.schedule = nil

        var unregistrable = scheduledRule(index: 1)
        unregistrable.schedule = RuleSchedule(
            start: TimeOfDay(hour: 9, minute: 0),
            end: TimeOfDay(hour: 9, minute: 5),
            warningMinutes: nil
        )

        let alien = PendingChange(
            id: UUID(),
            operation: .unrecognized(type: "setQuantumLock"),
            requestedAt: now,
            earliestApplyAt: now.addingTimeInterval(3600),
            lockConfigHash: "cfg"
        )
        let orphanGrant = Grant(
            id: UUID(),
            ruleID: UUID(),
            scope: .entireRule,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(600),
            source: .manual
        )

        let plan = MonitorPlan.make(
            from: state(
                rules: [unscheduled, unregistrable],
                grants: [orphanGrant],
                pendingChanges: [alien],
                now: now
            ),
            now: now,
            calendar: newYork
        )

        #expect(plan.diagnostics.contains(.ruleAlwaysInForce(ruleID: unscheduled.id)))
        #expect(plan.diagnostics.contains(.pendingChangeNotApplicable(changeID: alien.id)))
        #expect(plan.diagnostics.contains(.grantWithoutRule(grantID: orphanGrant.id, ruleID: orphanGrant.ruleID)))
        #expect(
            plan.diagnostics.contains { diagnostic in
                if case .windowUnregistrable(let ruleID, _) = diagnostic { return ruleID == unregistrable.id }
                return false
            }
        )
        // A rule with no window is still enforced; it just has no boundaries.
        #expect(plan.entries.isEmpty)
    }

    @Test("A change with no deadline, or one already ripe, arms nothing")
    func timersThatNeedNoActivity() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rule = scheduledRule(index: 0)

        let passwordOnly = PendingChange(
            id: UUID(),
            operation: .disableRule(ruleID: rule.id),
            requestedAt: now,
            earliestApplyAt: nil,
            lockConfigHash: "cfg"
        )
        let alreadyRipe = PendingChange(
            id: UUID(),
            operation: .disableRule(ruleID: rule.id),
            requestedAt: now.addingTimeInterval(-7200),
            earliestApplyAt: now.addingTimeInterval(-60),
            lockConfigHash: "cfg"
        )

        let plan = MonitorPlan.make(
            from: state(rules: [rule], pendingChanges: [passwordOnly, alreadyRipe], now: now),
            now: now,
            calendar: newYork
        )
        #expect(plan.entries(for: .revertTimer).isEmpty)
    }

    @Test("The plan is deterministic: the same inputs give the same order in every process")
    func planIsDeterministic() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rules = (0..<4).map { scheduledRule(index: $0) }
        let snapshot = state(rules: rules, now: now)

        let first = MonitorPlan.make(from: snapshot, now: now, calendar: newYork)
        let second = MonitorPlan.make(from: snapshot, now: now, calendar: newYork)

        #expect(first.entries.map(\.name) == second.entries.map(\.name))
        #expect(first.fingerprints == second.fingerprints)
        #expect(first == second)
    }

    @Test("nextDeadline reports the soonest timer still in the future")
    func nextDeadline() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rule = scheduledRule(index: 0)
        let soon = Grant(
            id: UUID(), ruleID: rule.id, scope: .entireRule,
            issuedAt: now, expiresAt: now.addingTimeInterval(300), source: .intervention
        )
        let later = Grant(
            id: UUID(), ruleID: rule.id, scope: .entireRule,
            issuedAt: now, expiresAt: now.addingTimeInterval(900), source: .intervention
        )

        let plan = MonitorPlan.make(
            from: state(rules: [rule], grants: [later, soon], now: now), now: now, calendar: newYork
        )
        #expect(plan.nextDeadline(after: now) == soon.expiresAt)
        #expect(plan.nextDeadline(after: now.addingTimeInterval(600)) == later.expiresAt)
        #expect(plan.nextDeadline(after: now.addingTimeInterval(9_000)) == nil)
    }
}

@Suite("MonitorPlan — diffing against the daemon")
struct MonitorPlanDiffTests {

    private let newYork = calendar("America/New_York")

    @Test("Nothing armed means arm everything; nothing changed means do nothing")
    func diffExtremes() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rule = Rule(
            id: UUID(), name: "Focus", isEnabled: true, schedule: window(9, 17),
            sortIndex: 0, createdAt: now, updatedAt: now
        )
        let snapshot = GateState(installID: UUID(), createdAt: now, updatedAt: now, rules: [rule])
        let plan = MonitorPlan.make(from: snapshot, now: now, calendar: newYork)

        let cold = plan.diff(against: [])
        #expect(cold.toStart.map(\.name) == plan.entries.map(\.name))
        #expect(cold.toStop.isEmpty)
        #expect(!cold.isEmpty)

        let steady = plan.diff(against: plan.names, armedFingerprints: plan.fingerprints)
        #expect(steady.isEmpty)
        #expect(steady.unchanged == plan.entries.map(\.name))
    }

    @Test("An armed name with the wrong schedule is stopped and restarted")
    func editedWindowIsRearmed() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let ruleID = UUID()
        let before = Rule(
            id: ruleID, name: "Focus", isEnabled: true, schedule: window(22, 6),
            sortIndex: 0, createdAt: now, updatedAt: now
        )
        var after = before
        after.schedule = window(21, 6)

        let oldPlan = MonitorPlan.make(
            from: GateState(installID: UUID(), createdAt: now, updatedAt: now, rules: [before]),
            now: now, calendar: newYork
        )
        let newPlan = MonitorPlan.make(
            from: GateState(installID: UUID(), createdAt: now, updatedAt: now, rules: [after]),
            now: now, calendar: newYork
        )

        // `gate.rule:<uuid>` does not encode the window, so the daemon shows no
        // difference at all. The fingerprint is the only thing that notices.
        #expect(oldPlan.names == newPlan.names)
        #expect(oldPlan.fingerprints != newPlan.fingerprints)

        let diff = newPlan.diff(against: oldPlan.names, armedFingerprints: oldPlan.fingerprints)
        #expect(diff.toStop == newPlan.entries.map(\.name))
        #expect(diff.toStart.map(\.name) == newPlan.entries.map(\.name))
        #expect(diff.unchanged.isEmpty)
    }

    @Test("An empty fingerprint map restarts everything — correct, just chattier")
    func missingFingerprintsRestartEverything() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let rule = Rule(
            id: UUID(), name: "Focus", isEnabled: true, schedule: window(9, 17),
            sortIndex: 0, createdAt: now, updatedAt: now
        )
        let plan = MonitorPlan.make(
            from: GateState(installID: UUID(), createdAt: now, updatedAt: now, rules: [rule]),
            now: now, calendar: newYork
        )

        let diff = plan.diff(against: plan.names)
        #expect(diff.toStop == plan.entries.map(\.name))
        #expect(diff.toStart.count == plan.entries.count)
    }

    @Test("Orphaned Gate activities are stopped; foreign ones are never touched")
    func orphansAndForeigners() throws {
        let now = try instant(2025, 6, 16, 12, 0, in: newYork)
        let plan = MonitorPlan.make(
            from: GateState(installID: UUID(), createdAt: now, updatedAt: now),
            now: now, calendar: newYork
        )

        let orphan = GateActivity.rule(ruleID: UUID()).rawName
        let futureGateName = "gate.staircase:\(UUID().uuidString)"
        let foreign = "com.example.widget.refresh"

        let diff = plan.diff(against: [orphan, futureGateName, foreign])
        #expect(Set(diff.toStop) == [orphan, futureGateName])
        #expect(diff.foreign == [foreign])
        // `DeviceActivityCenter` is scoped to this app and its extensions, so a
        // foreign name belongs to another Gate target — stopping it would break
        // a feature this code has never heard of.
        #expect(!diff.toStop.contains(foreign))
        // Deterministic ordering: `Set` iteration order is not.
        #expect(diff.toStop == diff.toStop.sorted())
    }
}
