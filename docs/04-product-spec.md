## Product spec

**Working name: Gate.** Positioning: *a commitment device for your phone* — not a screen-time dashboard. The core promise is **"changing your mind costs time."** Explicitly *not* competing with Opal on analytics (structurally impossible) or with Brick on hardware (v2+).

**Authorization model: `FamilyControlsMember.individual`.** No iCloud sign-in, no Family Sharing, no second device, no account. This is also what makes the app trivially reviewable — see `Docs/REVIEW-NOTES.md`.

---

## v1 — MVP (solo-shippable; useful to you personally on dev signing before any Apple approval)

The v1 scope is deliberately chosen so that **every feature works without the distribution entitlement**, i.e. everything below runs on a development-signed build on your own device from ~week 2.

### V1-1 · Onboarding (one screen, ~60 seconds)
1. Explain the deal honestly, including the limit: *"You can always turn Gate off in Settings. Gate makes that cost you time, not impossible."* Shipping a blocker that overclaims is the #1 trust failure in this category.
2. `try await AuthorizationCenter.shared.requestAuthorization(for: .individual)` → Face ID / Touch ID.
3. Handle every `FamilyControlsError` case with real copy. Specifically: `.authenticationMethodUnavailable` → "Set a device passcode first"; `.invalidAccountType` → "Sign in to iCloud"; `.networkError` → "Connect to the internet."
4. **Nudge (not require) a Screen Time passcode.** On iOS 26.4+ this reportedly gates revocation *(unverified — see hardConstraints #17)*. Offer the deep link and an explicit "give this passcode to someone else" suggestion. Frame it as "make the escape hatch cost more," never as "this makes Gate unremovable."

### V1-2 · Rules (the unit of configuration)
A **Rule** is: a name, a `FamilyActivitySelection`, a mode (`blocklist` | `allowlist`), an optional schedule, and a state (`off` | `on`).

- Selection uses `.familyActivityPicker(title:headerText:footerText:isPresented:selection:)` (fall back to the 2-arg `init` below iOS 26.2).
- **Enforce the 50-token cap yourself in the editor UI** — count `applicationTokens`, `webDomainTokens`, and `categoryTokens` and refuse to save past 50 with an explicit message. The API fails silently.
- Each rule gets its own named `ManagedSettingsStore(named: .init("gate.rule.<uuid>"))` so rules never clobber each other. **Cap at 8 rules in v1** (50-store ceiling, 20-activity ceiling).
- Allowlist mode uses `.all(except: allowedTokens)` — "block everything except these" without enumerating 50 tokens.

### V1-3 · The Lock (Andoff's core, ported whole)
Exactly one lock per install, configured once:

| Lock type | Behavior |
|---|---|
| **Delay** (default) | Every loosening change is queued with `earliestApplyAt = now + delay`. Default 15 min; user-settable 1 min – 7 days. |
| **Partner password** | A passphrase set during a "hand your phone to someone" flow; loosening requires it. |
| **Both** | Password *or* wait out the delay. |

**Asymmetric change cost, exactly as Andoff specifies it:**
- **Increasing the delay** applies immediately (it's a tightening).
- **Decreasing the delay** requires waiting `oldDelay − newDelay`.
- Changing the lock *type* is a loosening and goes through the lock.

**The clock must survive delete-and-reinstall.** Store `{ pendingChangeID, earliestApplyAt, lockConfigHash }` in the **Keychain** with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — Keychain items survive app deletion on iOS. The App Group container does not. Write both; on launch, trust the Keychain copy if it is newer.

### V1-4 · The Ratchet ("permit tightening changes directly")
A single on/off switch, on by default. Every mutation is classified by `Kernel/Engine/Ratchet.swift`:

**TIGHTEN (applies synchronously, no lock):** adding a token to a rule; turning a rule on; extending a schedule window; enabling `denyAppInstallation`; enabling the ratchet; increasing the delay; switching blocklist→allowlist.

**LOOSEN (queued behind the lock):** removing a token; turning a rule off; shrinking a schedule window; disabling `denyAppInstallation`; disabling the ratchet; decreasing the delay; deleting a rule; revoking authorization from inside the app.

The UI shows a persistent **"Pending changes (2) — unlocks in 12m 04s"** banner with a "cancel pending change" affordance that is itself a tightening (free).

This is the entire differentiator. Everything else in v1 exists to make it usable.

### V1-5 · Schedules (a feature *addition* over Andoff)
Per rule: a repeating daily window, optionally weekday-scoped.
- `DeviceActivitySchedule(intervalStart: DateComponents(hour:,minute:,second:), intervalEnd: DateComponents(hour:,minute:,second:), repeats: true, warningTime: DateComponents(minute: 5))` — **identical component sets on both ends** (see apiReference §7).
- **Activity budget discipline:** one `DeviceActivityName` per rule, **not** per rule-per-weekday. Weekday scoping is handled in `intervalDidStart` by checking the calendar and no-oping — otherwise you blow the 20-activity cap at rule #3.
- Honest copy in the UI: *"Blocks start and end the next time you pick up your phone, not exactly at the minute."* This is Apple's documented behavior, not a bug, and saying so preempts your worst support load.

### V1-6 · The shield
`ShieldConfiguration` built from a config blob the app pre-writes to the App Group:
- `backgroundBlurStyle: .systemUltraThinMaterialDark`, `backgroundColor`, a bundled `icon` `UIImage`.
- `title` = the rule's name. `subtitle` = a *static* line of user-written copy ("You said you'd read instead."). **Never a countdown** — configurations are cached/recycled and will render stale (FB14237883).
- `primaryButtonLabel` = "Let me in" → `.openParentalControlsApp` (26.5+) / notification fallback.
- `secondaryButtonLabel` = "Not now" → `.close`.

### V1-7 · The intervention (iOS 26.5+ primary path)
Shield "Let me in" → `.openParentalControlsApp` → `App/Screens/InterventionScreen.swift`:
1. A forced **wait** (the lock delay, or a separate shorter "impulse delay" — default 30 s).
2. A **typed reason**, persisted to a local journal ("what do you actually want to do in there?").
3. On completion, issue a **grant** — a token-scoped, time-boxed subtraction from the shield set.
4. **Explicit copy: "You can open [it] now — press Home and tap the app."** You cannot launch it for them (hardConstraints #20). Do not pretend otherwise.

**Fallback below iOS 26.5:** `ShieldActionDelegate` writes the intent to the App Group, posts a `UNNotificationRequest` with a deep link, and returns `.close`. The user taps the notification. Document in-app that this is an OS limitation, and (optionally) ship a ScreenZen/one-sec-style Shortcuts-automation setup guide.

**Grant budget:** N grants per day (default 3), decremented in `ShieldActionDelegate` and reset at midnight. Running out is a *tightening* and needs no lock.

### V1-8 · Install protection ("Solid" mode)
A single toggle → `store.application.denyAppInstallation = true`. **Do not ship "Smart" mode** — there is no install-event callback on iOS. Copy must say what it is: *"no new apps can be installed while this is on."* Enabling is free; disabling goes through the lock.

### V1-9 · Recovery ("Reselect your apps")
A first-class screen, not an error path. Triggered when:
- `ManagedSettingsStore.TokenExpiryMessage` is observed (26.5+), or
- `authorizationStatus` is no longer `.approved` on foreground, or
- the user reports a rule silently stopped working.

Flow: explain in one sentence that iOS occasionally reissues app identifiers; reopen the picker pre-seeded with what survived; call `ManagedSettingsStore.refresh(&tokens)` first on 26.5+; rewrite stores and App Group state. **Reselecting is a tightening** — never gate recovery behind the lock, or you will trap users out of their own blocks.

### V1-10 · Reconciliation (the reliability backbone)
On **every** `scenePhase == .active`, and on every monitor callback:
1. Re-read `GateState` from the App Group.
2. Expire stale grants and pending changes by absolute timestamp.
3. Recompute the intended shield set per rule and rewrite every `ManagedSettingsStore`.
4. Diff `DeviceActivityCenter().activities` against the intended plan; `stopMonitoring` orphans, `startMonitoring` missing ones.
5. Re-arm `UNCalendarNotificationTrigger` backstops at every upcoming boundary.

**The monitor extension is a best-effort accelerator, never the source of truth.**

### V1-11 · Debug screen (ship it in Debug builds; it pays for itself in week 1)
Renders `AuthorizationCenter.shared.authorizationStatus`, `DeviceActivityCenter().activities`, `center.schedule(for:)`, `center.events(for:)`, `ManagedSettingsStore.stores` (26.5+), the raw `GateState` JSON, the extension breadcrumb log, and a **"run reconcile now"** button that invokes the exact same code path the monitor calls. This makes ~90% of your logic testable without waiting 15 minutes on the daemon.

### Explicitly OUT of v1
No accounts, no server, no analytics SDK, no crash reporter, no subscription, no widgets, no NFC, no quotas, no charts, no `denyAppRemoval`, no EU data entitlement, no VPN. This keeps the App Privacy answer at **"Data Not Collected"**, keeps the monitor extension far under 6 MB, and keeps Guideline 4.10 and 5.4 entirely out of scope.

---

## v2 — Depth (post-entitlement, post-TestFlight)

### V2-1 · Shield submenu grants (iOS 26.4+)
`secondaryButtonSubmenuItems = ["1 more minute", "15 more minutes", "1 hour"]` handled by `.firstSecondarySubmenuItemPressed` / `.second…` / `.third…`. Each consumes one grant from the daily budget. Below 26.4 the secondary button just fires `.secondaryButtonPressed`.

### V2-2 · Intervention library
Selectable per rule, all running in-app after the 26.5 handoff:
- **Breathing** (box, 4-7-8) — one sec's mechanic, with the strongest evidence base (PNAS n=280: 57% reduction in app openings).
- **Typed pledge** — transcribe a sentence you wrote while sober.
- **Math / password transcription** — ScreenZen's cognitive-cost gates.
- **Intention statement** — Jomo's "what will you do instead."
- **Pre-commit session length** — Clearspace's "choose how long before you enter," which then arms a one-shot expiry activity.

### V2-3 · NFC physical friction (Tier 1)
Core NFC foreground tap in-app: tap a tag to **start** a session for free (tightening); tap the same tag to **end** it (loosening — still goes through the lock, or is exempted per user config). Ship a "5 emergency unlocks per month" pressure valve like Brick, because a true one-way door with a lost tag generates refunds.

### V2-4 · Daily budgets — *shipped as opt-in "Beta," behind a clear warning*
`DeviceActivityEvent(applications:categories:webDomains:threshold:includesPastActivity: false)` with a staircase of events inside **one** activity (events are cheap; activities are capped at 20). Mandatory defensive coding:
- `eventDidReachThreshold` must be **idempotent** and must verify against your own persisted timestamps before shielding.
- If the event fires and your own record says < 60 s has elapsed since `intervalDidStart`, **ignore it** — this is the documented iOS 26.x false-positive signature.
- A prominent one-tap "this was wrong, unshield now" path (false positives are common and infuriating).
- Per-point-release QA gate: re-test before shipping against any new iOS.

### V2-5 · Stats — display only
One `DeviceActivityReport(.totalActivity, filter: DeviceActivityFilter(segment: .daily(during: today), …))` on its own screen. **One report view per screen, never three.** Alongside it, show *your own* counters (bypass attempts, grants used, pending-change history) which you *can* read — and label them honestly as "Gate's own data," distinct from the Apple report.

### V2-6 · Accountability partner
- Partner holds the lock password.
- **Server-side heartbeat** for tamper detection: the client POSTs "still authorized" on every foreground and `BGAppRefreshTask`; the **server** infers tampering from missing beats and emails/pushes the partner. This is the only workable approach because revocation is undetectable client-side.
- **This is the first feature that puts you off "Data Not Collected."** Declare `Identifiers → User ID` and (if you add auth) `Contact Info → Email Address`. Keep it strictly opt-in and isolated behind a build flag so the no-account path stays clean.

### V2-7 · Widgets + Control Center
WidgetKit timeline showing active rules and next boundary; `ControlWidget` + `ControlWidgetButton(action: StartRuleIntent())` (iOS 18.0+, `@available`-gated). **The `AppIntent` type must be a member of both the app and widget targets** — put it in `Kernel` and link from both. Prefer `openAppWhenRun = true` so the privileged `DeviceActivityCenter` / `ManagedSettingsStore` work happens in the app.

### V2-8 · Monetization (Guideline 4.10-safe)
StoreKit 2, on-device only (no receipt backend in v2 → still no data collection). **Never gate `requestAuthorization` or `FamilyActivityPicker`.** Free tier: 1 rule, delay lock, schedules, the shield. Paid tier sells *your* work, labeled by your features — "Unlimited Rules," "Intervention Library," "Partner Lock," "Tag Unlock" — never "App Blocking" or "Screen Time."

---

## v3 — Reach

### V3-1 · Guardian Mode (`.child`)
The only path to *real* enforcement: a Family Sharing child account, parent-authenticated authorization, `store.application.denyAppRemoval = true` actually honored, and the user genuinely unable to revoke. Ship it as a separate, clearly-labeled mode. **Note it is exclusive** — `FamilyControlsError.authorizationConflict` if another parental-control app holds it — and handle that error with real copy.

### V3-2 · Camera-verified physical unlock
Vision body-pose pushups/squats as the grant cost (Clearspace's mechanic, 4M+ pushups logged in six months). Entirely independent of Screen Time APIs, so it carries no new platform risk.

### V3-3 · EU data tier — *separate build configuration, opt-in, EU-only*
`com.apple.developer.family-controls.app-and-website-usage` + `.approvedWithDataAccess` + `FamilyActivityData` + `DeviceActivityData.activityData(filteredBy:using:)`. Unlocks real app names, icons, and exportable usage — i.e. everything the rest of the world cannot have. **Gate it behind an explicit user choice** because the consent prompt is all-or-nothing, it is single-occupancy, and it reportedly evicts Apple's own Screen Time from the data (which may break the user's iOS 27 Time Allowances). Do not make it the default anywhere.

### V3-4 · Web allowlist browser
Ship a minimal `WKWebView` browser with a hard allowlist, and shield every other browser the picker exposes. This is the only iOS analogue of Andoff's "block WebView, protect the filtered browser" composition — and it is weak, because you cannot prevent the user installing another browser once `denyAppInstallation` is off.

### V3-5 · Rule-definition sync
Sync rule *definitions* (names, schedules, lock config, intervention choices) via CloudKit. **Never sync tokens** — they are per-device, opaque, and unstable. A new device re-picks; the structure carries over.
