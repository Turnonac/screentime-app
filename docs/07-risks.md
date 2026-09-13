## Risks, ranked

### 1. The entitlement queue blocks TestFlight and the App Store for an unbounded time — **Severity: critical · Likelihood: certain**
No SLA, no ticket ID, no confirmation email. Observed 2026 range: 1 day to 6+ weeks. Approval emails arrive while the portal still reads "Submitted," with no self-service remedy. The Developer Support contact form itself has been reported broken.
**Mitigation:** File all 5 requests on day 1 (Phase 0) before writing code. Build the entire product on the **development** entitlement — nothing in Phases 1–6 needs approval. Register tester UDIDs on the development profile as the only pre-approval multi-device path. Lock bundle-ID casing before filing anything. Screenshot every submission. Verify the *Provisioning Support* list under the info button, not just the "Assigned" badge.

### 2. `eventDidReachThreshold` is broken across iOS 26.2–26.5.2 — **Severity: critical · Likelihood: high**
Fires immediately, fires at 0 recorded minutes, fires twice, or never arrives. Dozens of Feedback IDs, open threads, and Apple's only partial fix (26.5 beta 1) described by the reporter as intermittently regressing.
**Mitigation:** **Keep quotas out of v1 entirely.** The Andoff model — binary block + friction + schedules — is not threshold-dependent, which is the single best structural reason to port it. When quotas land in v2, ship them explicitly labeled "Beta," make every handler idempotent, verify against your own persisted timestamps, ignore events firing < 60 s after `intervalDidStart`, and give the user a one-tap "this was wrong" unshield. Re-QA every point release.

### 3. Tokens go stale and silently break every saved rule — **Severity: critical · Likelihood: high**
Tokens change after OS updates and re-authorization; tokens handed to `ShieldConfigurationDataSource` / `ShieldActionDelegate` can fail `==` against stored ones (thread 814571, Apple DTS gave no workaround). The iOS 26.5 remedy is itself reported broken for ~30% of new users (FB23391495, Apple: "Potential fix identified — For a future OS update"). Symptom: shields silently stop applying, with no error thrown.
**Mitigation:** Treat token invalidation as a **normal, frequent event**, not an error path. Ship `RecoveryScreen` as a first-class feature. Observe `TokenExpiryMessage` and call `refresh(_:)` on 26.5+. **Reselection is a tightening and must never be gated behind the lock.** Add a "my block isn't working" entry point on the home screen. Never gate a user's blocks behind a server or an account that could also fail.

### 4. `.openParentalControlsApp` may not work under `.individual` — **Severity: high · Likelihood: unknown** *(unverified)*
The documentation is one sentence and parental-centric; no field reports exist for the `.individual` case, and no one has verified whether it passes any context.
**Mitigation:** **Phase 2, Step 2.5 is an explicit go/no-go device test before any UI is built.** If it fails, the entire intervention UX falls back to the local-notification deep link (~1s+ delay, one extra tap, suppressible by Focus and notification summarization) or a user-built Shortcuts automation — which is what ScreenZen and one sec ship today, so it is survivable, but it changes onboarding substantially. Discovering this in week 6 instead of week 1 is the expensive version.

### 5. The monitor extension is unreliable infrastructure — **Severity: high · Likelihood: high**
6 MB ceiling, killed for memory or idleness (Apple Frameworks Engineer), "automatically killed after running for a few days," and reported as **never launched at all** on iOS 26.3.1 with correct configuration (Apple DTS response: "file a Feedback report").
**Mitigation:** Three-layer enforcement by design (architecture): `ManagedSettingsStore` is the enforcement, the monitor is an accelerator, and **foreground reconciliation + `UNCalendarNotificationTrigger` backstops are the correctness path**. Every deadline is an absolute timestamp; the app recomputes ground truth on every activation. The monitor links `GateKernel` only — no SwiftUI, no SwiftData, no networking, no analytics. Every callback assumes a cold start and is idempotent.

### 6. Guideline 2.5.1 rejection — **Severity: high · Likelihood: medium**
The live rejection risk in this category, not 4.10. Two documented rejections: one for using `blockedApplications` exactly as Apple documents it (appeal denied with the same copy-pasted text), and one for shipping the API without visible Screen Time features.
**Mitigation:** Use `shield.applications`, **never `application.blockedApplications`**. Name the Screen Time integration in the App Store description (2.5.1's own requirement). Pre-argue the intended-use point in review notes. Attach a demo video. Never touch private API — a rejection for `LSApplicationWorkspace` was reported May 2026. If you ever remove the feature, also remove Family Controls from the App ID at developer.apple.com, not just from the Xcode target.

### 7. The product's core promise is defeatable in four taps — **Severity: high · Likelihood: certain**
Settings → Screen Time → Apps with Screen Time Access → off. Undetectable while backgrounded, unblockable, and Settings.app cannot be shielded.
**Mitigation:** **Honesty as product design.** Onboarding says it plainly: *"You can always turn Gate off in Settings. Gate makes that cost you time, not impossible."* Layer friction the user cannot cheaply defeat: a delay clock in the Keychain that survives reinstall; a partner who holds the password; an NFC tag (v2); a Screen Time passcode you nudge them to hand to someone else. For users who genuinely need enforcement, ship `.child` Guardian Mode in v3 — the only model where `denyAppRemoval` is honored. Do not ship copy claiming "impossible to bypass"; your 1-star reviews will be written by the users who believed it.

### 8. Cross-process persistence fails silently — **Severity: high · Likelihood: medium**
The dossier contradicts itself: Foqos ships `UserDefaults(suiteName:)` writes from `ShieldActionDelegate` in production; other reports say extension writes return success and never propagate. The failure mode is a **silently unenforced block**.
**Mitigation:** `StateStoring` is a protocol from day one so the backend is swappable in an afternoon. Default: atomic plist + `NSFileCoordinator`. Validate on device in Phase 2 Step 2.5(c). Single-writer discipline — extensions append to `inbox/`, only the app compacts. Assume `ShieldConfiguration` is read-only. Keep `GateState` under 8 KB.

### 9. 50-token / 50-store / 20-activity caps fail silently — **Severity: medium · Likelihood: high**
Exceed 50 tokens and the store shields **nothing** while reading back `nil`. No throw, no warning.
**Mitigation:** `TokenGuard` enforces `count <= 50` per collection with a typed error surfaced in the rule editor as a live count. `ScheduleBuilder` enforces the 20-activity budget by **evicting** the furthest-out timer rather than letting `startMonitoring` throw at an arbitrary moment. One activity per rule, never one per rule-per-weekday. Cap v1 at 8 rules.

### 10. Report-extension packaging catch-22 costs a review cycle — **Severity: medium · Likelihood: medium**
`NSExtensionPrincipalClass` present → device install fails (Error 3002). Absent → App Store Connect rejects. Both are real.
**Mitigation:** Make it a true ExtensionKit extension from step one: `extensionkit-extension` product type, `EXAppExtensionAttributes`/`EXExtensionPointIdentifier`, `dstSubfolderSpec = 16`. **Verify the generated pbxproj in Phase 1 Step 1.6** rather than at upload time. XcodeGen's `extensionkit-extension` emission for a report extension is not documented by a public example — *(unverified)* — so inspect it.

### 11. Monetization drifts into Guideline 4.10 — **Severity: medium · Likelihood: low-medium**
4.10 names "Screen Time APIs" among capabilities you may not monetize. No 4.10 rejection letter for a screen-time app was found — *(unverified whether 4.10 is dormant here)* — but a paywall reading as "pay to unlock app blocking" is exactly what a reviewer reaches for it with.
**Mitigation:** Never gate `requestAuthorization` or `FamilyActivityPicker`. Free tier includes real blocking. Label paid tiers by *your* features. Opal, Jomo, one sec and Clearspace all ship subscriptions in this category, which demonstrates the model clears review when the subscription bundles the developer's own value.

### 12. Building the wrong product — an analytics app you cannot build — **Severity: medium · Likelihood: medium (design risk)**
The obvious instinct is charts, streaks and insights. The report-extension sandbox makes that structurally impossible outside the EU, and Opal already owns the analytics position with a price complaint attached.
**Mitigation:** Andoff itself has **no** analytics surface — no usage stats, no quotas, no charts, no widgets, no streaks. Its moat is lock semantics. Port the lock, add scheduling, and count *your own* events (bypass attempts, grants used, pending changes) which you legitimately can read. Label Apple's report view and your own counters as distinct things.

### 13. EU data-access tier backfires — **Severity: medium · Likelihood: medium (if adopted)**
All-or-nothing consent prompt hurting conversion (thread 820283); single-occupancy that silently reverts your status to `.notDetermined`; reportedly **evicts Apple's own Screen Time from usage data** (thread 844661), which may break the user's iOS 27 Time Allowances; currently reported broken in distribution builds while working in development (844541, 844623).
**Mitigation:** Do not ship `com.apple.developer.family-controls.app-and-website-usage` in v1 or v2. In v3, gate it behind a separate build configuration and an explicit opt-in, never a default. Shipping only the base entitlement keeps the narrower `.approved` status and a much less alarming consent prompt.

### 14. Platform and tooling churn — **Severity: low-medium · Likelihood: medium**
Each iOS point release has broken something in this stack. Xcode-version-sensitive plist behavior. macOS/Catalyst/visionOS all non-viable despite contradictory availability metadata.
**Mitigation:** Two physical devices — one on shipping iOS, one on the current beta. Pin the Xcode version explicitly in CI (`macos-26` + `xcode-select`). Target iOS + iPadOS only; do not spend a day on Catalyst. `Docs/DEVICE-TEST-MATRIX.md` re-run every release. Note for planning: **iOS 27 added zero Screen Time API surface** (all 402 symbols verified) — Time Allowances and Ask to Browse are user-facing only, so there is nothing new to adopt, but also nothing new to break.

### 15. Undocumented interaction between your shields and iOS 27's Time Allowances / Ask to Browse — **Severity: low · Likelihood: unknown** *(unverified — entirely undocumented)*
Ask to Browse gates Safari navigation; so do `shield.webDomains` and `webContent.blockedByFilter`. Whether an approved URL bypasses your filter, or your filter suppresses the prompt, is unknown. Apple has published nothing, and no forum thread covers it.
**Mitigation:** Low priority for an adult self-control app (Time Allowances apply to child accounts). If you ship v3 Guardian Mode, add a day-one device test on an iOS 27 child account: (a) domain you block + approved via Ask to Browse; (b) domain you allow + denied via Ask to Browse; (c) `.all(except:)` vs Ask to Browse's allowlist.
