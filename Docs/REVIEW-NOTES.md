# Gate — App Review notes

`docs/06-build-plan.md` step 7.6. Only relevant once the Family Controls distribution entitlement reads **"Assigned"** for all five App IDs (`Docs/ENTITLEMENT-REQUEST.md`).

**Guideline 2.5.1 is what actually rejects apps in this category, not 4.10 and not privacy.** Two verbatim rejections on record: *"your app uses ScreenTime API to hide apps"* — for `application.blockedApplications`, used exactly as Apple documents it, with the appeal denied using the same copy-pasted text — and *"the app still includes ScreenTime API without ScreenTime features… It would be appropriate to remove these APIs from the app if you have no approved use case."* So the notes below **pre-argue 2.5.1**; they do not merely give steps.

Gate avoids the first rejection by design: it uses `shield.applications`, never `application.blockedApplications` (`docs/02-api-reference.md` §6).

---

## 1 · App Review Information → Notes

**Paste verbatim. Do not trim it — the framing is the point.**

```text
This is an adult self-control / digital wellbeing app. It uses FamilyControls,
ManagedSettings, ManagedSettingsUI and DeviceActivity for their documented
purpose: the user selects their own apps and websites and the app shields them
on a schedule the user sets. It uses FamilyControlsMember.individual, so no
iCloud account, no Family Sharing group and no second device are needed.

To test (~90 seconds, one device, no login):
1) Launch → "Get Started" → tap Continue on the iOS Screen Time alert →
   authenticate with Face ID / Touch ID.
2) "Choose apps to block" → the system picker appears → select 1–2 installed
   apps → Done. (By design the app never learns which apps you picked — iOS
   returns opaque tokens.)
3) "Start block now."
4) Press Home and tap a selected app — our shield appears.
5) Tap "Not now," reopen the app, tap "End block."

Privacy: all Screen Time data stays on device. The DeviceActivityReport
extension is sandboxed by Apple and cannot pass data back to us; selections are
opaque tokens. Nothing from the Screen Time APIs is transmitted off device.

A demo video of the full flow is attached.
```

### If you need the longer version

Add this only when a reviewer has already pushed back, or when the build adds an extension whose purpose is not obvious from the steps above. Keep the short version as the default — reviewers read the first paragraph.

```text
Why each framework is present, since Guideline 2.5.1 asks for it:

- FamilyControls    — AuthorizationCenter.requestAuthorization(for: .individual)
                      and FamilyActivityPicker. Without it the user cannot
                      select anything and no tokens exist.
- ManagedSettings   — ManagedSettingsStore.shield.applications /
                      .applicationCategories / .webDomains is the enforcement,
                      and ShieldActionDelegate handles the shield's buttons.
                      We deliberately do NOT use application.blockedApplications.
- ManagedSettingsUI — ShieldConfigurationDataSource, so the interstitial shows
                      the user's own rule name and the sentence the user wrote
                      about why they set the rule, instead of the generic
                      system shield.
- DeviceActivity    — DeviceActivitySchedule / DeviceActivityCenter for the
                      user's daily windows and one-shot exception timers, and
                      DeviceActivityReport for a read-only usage summary shown
                      on the user's own device.

There are four app extensions, each requested and assigned separately:
  com.turnonac.gate.activity-monitor      DeviceActivityMonitor
  com.turnonac.gate.shield-configuration  ShieldConfiguration
  com.turnonac.gate.shield-action         ShieldAction
  com.turnonac.gate.report                DeviceActivityReport

The app does not hide, remove, or suppress any app. A shielded app remains
installed and visible on the Home screen; iOS draws an interstitial when it is
opened, and the user can lift the shield at any time from inside Gate, or
revoke Gate entirely in Settings → Screen Time. We say so in onboarding.
```

---

## 2 · Attachment — the demo video

☐ Screen recording attached in **App Review Information → Attachment**.

Apple explicitly sanctions this: *"If features require an environment that is hard to replicate… be prepared to provide a demo video."* **The shield only renders with a live entitlement.** Do not make the reviewer discover that; if their build or account state is off, an unexplained blank screen becomes a rejection.

Record, on device, in one unbroken take, roughly 60–90 seconds:

1. Cold launch → onboarding copy visible, including the honest limits line.
2. "Get Started" → the iOS Screen Time alert → biometric authentication.
3. "Choose apps to block" → the system `FamilyActivityPicker` → select two apps → Done.
4. "Start block now."
5. Press Home → tap a shielded app → **the Gate shield renders**.
6. Tap "Not now" → returns to Home.
7. Reopen Gate → "End block" → press Home → tap the same app → it opens normally.

---

## 3 · App Store description — required by 2.5.1

Guideline 2.5.1 requires you to *"indicate that integration in their app description."* A description that omits it is itself the rejection.

☐ The description contains a sentence to this effect, in the first screenful:

```text
Gate uses Apple's Screen Time (Family Controls) APIs to shield the apps and
websites you choose, on the schedule you set. Your selections stay on your
device as opaque tokens — Gate never learns which apps you picked.
```

---

## 4 · App Privacy — "Data Not Collected"

☐ Answered **Data Not Collected** across the board.

True for a v1 with no account, no server, no analytics and no crash reporter. Apple defines "collect" as transmitting off-device; the report extension renders locally and selections are opaque tokens.

**This answer breaks the moment you add RevenueCat, Crashlytics, or the v2 partner heartbeat** — the nutrition label covers the whole binary including bundled SDKs. Re-answer the questionnaire in the same release that adds any of them.

☐ Five privacy manifests present and validated — the app plus each of the four `.appex` bundles (step 7.1/7.2). Each file must be named `PrivacyInfo.xcprivacy` **inside its bundle**; a source file named `App-PrivacyInfo.xcprivacy` copies in under that name and is silently ignored.
☐ `NSPrivacyAccessedAPICategoryUserDefaults` declared with reason **`1C8F.1`** (the App-Group-shared reason) — **not** `CA92.1`.
☐ No `NSPrivacyTrackingDomains` key anywhere: its presence alongside `NSPrivacyTracking = false` is invalid.
☐ No category declared that the binary does not actually hit — an incorrect declaration is itself rejectable (ITMS-91054 / ITMS-91055).
☐ Organizer → **Generate Privacy Report** produces the expected report.

---

## 5 · Privacy policy — required in two places

☐ Live at a public URL, entered in the App Store Connect metadata field.
☐ Linked **inside the app**, reachable **without an account** (5.1.1(i)). Gate has no accounts, so this is a plain link on the settings screen.

Include the sentence reviewers look for:

```text
Screen Time selections are opaque tokens that never leave the device.
```

---

## 6 · Paywall audit — Guideline 4.10

Guideline 4.10 names "Screen Time APIs" among capabilities you may not monetize.

☐ `AuthorizationCenter.requestAuthorization(for:)` is reachable before any purchase.
☐ `FamilyActivityPicker` is reachable before any purchase.
☐ No paid tier is labelled "App Blocking", "Screen Time", or any synonym. Paid tiers are named for *our* work: "Unlimited Rules", "Intervention Library", "Partner Lock".

(v1 ships no paywall at all, so this section is a pre-check for the first monetized release.)

---

## 7 · Age rating questionnaire

☐ Social-media capability questions answered — **No** on every one. Mandatory since September 2026 for any new app, version update, or notarization request.

---

## 8 · Pre-submission checklist

☐ All five App IDs read **"Assigned"** for Family Controls, and *Provisioning Support* lists App Store and TestFlight.
☐ `make verify` passes — extension point identifiers, entitlements, `GateReport` product type and `dstSubfolderSpec = 16` embed phase.
☐ `Docs/DEVICE-TEST-MATRIX.md` filled in on the shipping iOS **and** the current beta.
☐ No `com.apple.developer.deviceactivity*` entitlement anywhere (phantom keys; they break provisioning).
☐ No `com.apple.developer.family-controls.app-and-website-usage` in v1.
☐ Onboarding states the limit honestly: *"You can always turn Gate off in Settings. Gate makes that cost you time, not impossible."* Overclaiming is the #1 trust failure in this category and the fastest route to one-star reviews.
☐ A prominent teardown path exists — shields can persist after the app is deleted, with no system UI to remove them (`docs/03-hard-constraints.md` #37).
☐ Demo video attached (§2).
☐ App Store description names the Screen Time integration (§3).
