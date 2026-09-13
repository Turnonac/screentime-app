# Gate — device test matrix

**This is the go/no-go gate.** `docs/06-build-plan.md` steps 2.5 and 2.6. Fill it in on a **physical device** — there is no Simulator support for any Screen Time API, `requestAuthorization` fails there with `FamilyControlsError.invalidArgument` (code 3), and no amount of CI can substitute (`docs/03-hard-constraints.md` #11).

Two of these answers change the architecture rather than a detail of it:

- **If 2.5 (a) is NO**, the whole intervention UX must be redesigned around the notification fallback **before anything else is built**. Do not start Phase 3 until this cell has a verdict.
- **2.6 decides the schedule design.** The dossier's sources contradict each other on `DateComponents` granularity; whichever combination actually delivers both callbacks on your target iOS is the one that gets locked into `Kernel/Engine/ScheduleBuilder.swift`.

Re-run the whole matrix on every new iOS point release before shipping. CI can compile but can never test any Screen Time behaviour.

---

## Preconditions

Everything below assumes the prior steps already pass. If one of these fails, fix it first — nothing downstream is meaningful.

- ☐ **2.1** `AuthorizationCenter.shared.authorizationStatus == .approved` after `requestAuthorization(for: .individual)`, on a development-signed build, on device. Device has a passcode set (otherwise `.authenticationMethodUnavailable`), is signed into iCloud (otherwise `.invalidAccountType`), and is online (otherwise `.networkError`).
- ☐ **2.2** A hardcoded selection written to `ManagedSettingsStore(named:).shield.applications` produces **Apple's default shield** when the app is launched from the Home screen.
- ☐ **2.3** `GateShieldConfiguration` replaces Apple's default shield with ours.
- ☐ **2.4** `GateShieldAction` handles `.primaryButtonPressed` and returns a response.

Device under test: ________________  ·  iOS: ____________  ·  Xcode: ____________  ·  Signing: development / distribution

---

## Results

Verdict vocabulary: **PASS** · **FAIL** · **PARTIAL** · **BLOCKED** (could not run) · **N/A** (OS too old).

| # | Test | iOS version | Expected | Actual | Date | Verdict |
|---|---|---|---|---|---|---|
| 2.5 (a) | Does `ShieldActionResponse.openParentalControlsApp` actually launch Gate under **`.individual`** authorization? Tap the shield's primary button with the app force-quit. **(unverified — Apple's doc wording is parental-centric and there are no field reports.)** | | Gate cold-launches to the foreground within ~1 s of the tap | | | |
| 2.5 (b) | Does `.openParentalControlsApp` pass **any** context — the `ApplicationToken`, the `ShieldAction`, a URL, a launch option, an `NSUserActivity`? **(unverified.)** Log `launchOptions`, `UIApplication.shared.userActivity`, and every `onOpenURL` / `onContinueUserActivity` callback. | | **Assume NO.** Design hands off through the App Group inbox regardless | | | |
| 2.5 (c) | Can `GateShieldAction` **write** to the App Group container, and can the app read it back? Write one `inbox/grant-<uuid>.plist` with `NSFileCoordinator` + `.atomic`, then read it from the app on next foreground. (Foqos proves the `UserDefaults(suiteName:)` suite works; coordinated files are what we chose and are unproven here.) | | File appears, decodes, and the app deletes it after compaction | | | |
| 2.5 (d) | Can `GateShieldConfiguration` **write** to the App Group container? Attempt one write and read it back from the app. **(Only reads are proven — the design assumes read-only.)** | | **Assume NO.** A PASS here is a bonus, never a dependency | | | |
| 2.6 A-start | Schedule **A** — `repeats: true`, `[.hour, .minute, .second]` on **both** ends. Does `intervalDidStart` fire? | | Fires the first time the device is used inside the window | | | |
| 2.6 A-end | Schedule **A** — same activity. Does `intervalDidEnd` fire? | | Fires the first time the device is used after the window | | | |
| 2.6 B-start | Schedule **B** — `repeats: false`, `[.year, .month, .day, .hour, .minute, .second]` on **both** ends, start = `Calendar.current.startOfDay(for: now)`. Does `intervalDidStart` fire? | | Fires effectively immediately, because the interval is already ongoing | | | |
| 2.6 B-end | Schedule **B** — same activity, end = `max(expiresAt, now + 60)`, clearing the 15-minute floor. Does `intervalDidEnd` fire? | | Fires at the first device use after `expiresAt` | | | |

**Do not skip 2.6.** Mismatched component sets between `intervalStart` and `intervalEnd` are a known cause of instant threshold breaches — the previous start resolves *after* the previous end, so the schedule reads as continuously active for days (thread 726331). The one invariant every source agrees on is: **never mismatch the component set between the two ends.**

---

## Locked decisions — fill in from the results above

Copy the outcome here, then encode it in `Kernel/Engine/ScheduleBuilder.swift` and `Kernel/Store/GateStateStore.swift`. This block is the record other phases read.

**Intervention path (from 2.5 a/b)**

- Primary path on iOS 26.5+: ☐ `.openParentalControlsApp` · ☐ notification deep link (a fails) — decided ______
- Context passed by the handoff: ______________________________________________
- Fallback path below iOS 26.5: notification deep link `gate://` — always. Confirmed working: ☐

**Persistence (from 2.5 c/d)**

- `state.plist` / `inbox/` via `NSFileCoordinator` + atomic plist: ☐ works · ☐ fall back to `UserDefaults(suiteName:)`
- Reason / observed failure mode: _______________________________________________
- `FileStateStore` stays the `StateStoring` implementation: ☐ yes · ☐ swapped for `DefaultsStateStore`

> The store sits behind the `StateStoring` protocol precisely so this cell can be answered either way without touching anything above `Kernel/Store/` (`docs/06-build-plan.md` step 3.2).

- `GateShieldConfiguration` treated as read-only: ☐ yes (default) · ☐ no, writes confirmed on iOS ______

**Schedule design (from 2.6)**

- Repeating daily rule windows use: ☐ `[.hour, .minute, .second]` · ☐ full `[.year … .second]` — decided ______
- One-shot grant / revert timers use: ☐ full `[.year … .second]` · ☐ `[.hour, .minute, .second]` — decided ______
- Callbacks that can be relied on: ☐ `intervalDidStart` ☐ `intervalDidEnd` ☐ `intervalWillStartWarning` ☐ `intervalWillEndWarning`
- Callbacks observed unreliable, and therefore backed by a `UNCalendarNotificationTrigger` + foreground reconcile: ____________________

> Whatever the answer, the monitor extension stays a **best-effort accelerator, never the source of truth**. It has a 6 MB ceiling, it is killed for memory or idleness, and it has been reported as never launched at all on iOS 26.3.1 with correct configuration (`docs/03-hard-constraints.md` #32).

---

## Re-test log

Every iOS point release. Both the shipping iOS and the current beta.

| iOS version | Date | Tests re-run | Regressions found | Action taken |
|---|---|---|---|---|
| | | | | |
| | | | | |
| | | | | |

---

## Notes and raw observations

Paste `os.Logger` output, Console.app timestamps, Feedback IDs filed, and anything surprising. Extension `print()` is invisible — everything in `Extensions/` logs through `os.Logger(subsystem: "com.turnonac.gate.<component>", category: …)` and is read in Console.app with the device attached.

```
```
