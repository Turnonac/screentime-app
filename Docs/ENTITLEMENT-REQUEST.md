# Gate — Family Controls distribution entitlement

**This is the long pole. File it on day one, before writing code, then stop waiting on it and go build.** Nothing in Phases 1–6 of `docs/06-build-plan.md` needs it — a development-signed build on your own device works with zero Apple approval and stays valid for the provisioning profile's 12-month lifetime.

What it *does* gate: **App Store distribution and TestFlight, internal testers included.** Apple DTS, verbatim, on whether you can ship an internal TestFlight build while waiting: *"No."* The only pre-approval multi-device path is development signing with each tester's UDID on the development profile (100 devices/year per device class).

Reported 2026 turnaround: **1 day to 6+ weeks.** No SLA, no ticket ID, no confirmation email. The approval email can arrive while the portal still reads "Submitted," which hard-blocks App Store Connect submission with no self-service remedy (thread 820971).

Source: `docs/03-hard-constraints.md` §A, `docs/06-build-plan.md` Phase 0.

---

## 0.1 · Locked bundle IDs — DO NOT CHANGE THE CASING

Bundle-ID casing is load-bearing across parent and extension. Real failure (thread 819573): a parent approved as `com.hayashikento.FocusPact` with an extension requested as `com.hayashikento.focuspact.ShieldConfigurationExtension` produced an Xcode **"Prefix Mismatch"** error, blocked archiving, and forced a fresh request — back to the end of a queue with no SLA.

These strings are generated from `BUNDLE_ID_PREFIX` in `Config/Build.xcconfig` and must be typed into the developer portal exactly as written here. `make verify` asserts the prefix has not drifted.

| # | Target | Bundle ID | Product type | Needs its own App ID? |
|---|---|---|---|---|
| 1 | Gate | `com.turnonac.gate` | `application` | **Yes** |
| 2 | GateKernel | `com.turnonac.gate.kernel` | `framework` | No — embedded in the app bundle |
| 3 | GateKernelUI | `com.turnonac.gate.kernelui` | `framework` | No — embedded in the app bundle |
| 4 | GateActivityMonitor | `com.turnonac.gate.activity-monitor` | `app-extension` | **Yes** |
| 5 | GateShieldConfiguration | `com.turnonac.gate.shield-configuration` | `app-extension` | **Yes** |
| 6 | GateShieldAction | `com.turnonac.gate.shield-action` | `app-extension` | **Yes** |
| 7 | GateReport | `com.turnonac.gate.report` | **`extensionkit-extension`** | **Yes** |
| — | GateWidgets | `com.turnonac.gate.widgets` | `app-extension` | v2 — not yet created, not yet requested |

**App Group (one, shared by all five bundles): `group.com.turnonac.gate`**

Frameworks live inside `Gate.app/Frameworks/`; they are code-signed with the app's identity and need no App ID, no entitlement and no request. Only the five bundles marked **Yes** above ship as separately-identified executables.

---

## 0.2 · Create the five App IDs

<https://developer.apple.com/account/resources/identifiers/list>

For each of the five: **Identifiers → + → App IDs → App → Explicit**, description as below, then enable **Family Controls** under Capabilities. Also register the App Group once and attach it to all five.

| # | Bundle ID | Portal description | App ID created | Family Controls enabled | App Group attached |
|---|---|---|---|---|---|
| 1 | `com.turnonac.gate` | Gate | ☐ ______ | ☐ | ☐ |
| 2 | `com.turnonac.gate.activity-monitor` | Gate Activity Monitor | ☐ ______ | ☐ | ☐ |
| 3 | `com.turnonac.gate.shield-configuration` | Gate Shield Configuration | ☐ ______ | ☐ | ☐ |
| 4 | `com.turnonac.gate.shield-action` | Gate Shield Action | ☐ ______ | ☐ | ☐ |
| 5 | `com.turnonac.gate.report` | Gate Report | ☐ ______ | ☐ | ☐ |

> **Do NOT enable `Family Controls App And Website Usage`** (`com.apple.developer.family-controls.app-and-website-usage`). It is a second, separately-gated capability, it is EU-only at runtime, it is single-occupancy per device, and it is currently reported broken in distribution builds while working in development. Out of scope through v3-1 (`docs/03-hard-constraints.md` #8).

> **Do NOT hand-add `com.apple.developer.deviceactivity` or `com.apple.developer.deviceactivity.reporting`.** Those entitlements **do not exist**. Developers add them chasing a "missing entitlement" error and cause provisioning-profile mismatch failures instead (threads 800785, 801843). `make verify` rejects them.

---

## 0.3 · File five distribution entitlement requests

**Form:** <https://developer.apple.com/contact/request/family-controls-distribution>
**Alternative:** Certificates, Identifiers & Profiles → the App ID → **Capability Requests** tab.

**Who:** the Apple Developer **Account Holder**. Not an Admin, not a developer. Apple rejects or ignores requests from any other role.

**One request per App ID, extensions included.** Apple, verbatim: *"If your app includes a Screen Time API app extension such as Device Activity Monitor, Device Activity Report, Shield Action, or Shield Configuration, submit the same request for the extension."*

**Screenshot every submission before you hit send and again after.** The form returns only "Thank you for requesting the API." There is no confirmation email, no ticket ID, and no way to prove later that you filed.

| # | App ID | Submitted | Screenshot saved | Portal status | "Assigned" on | Provisioning Support verified |
|---|---|---|---|---|---|---|
| 1 | `com.turnonac.gate` | ☐ ______ | ☐ | ______ | ______ | ☐ |
| 2 | `com.turnonac.gate.activity-monitor` | ☐ ______ | ☐ | ______ | ______ | ☐ |
| 3 | `com.turnonac.gate.shield-configuration` | ☐ ______ | ☐ | ______ | ______ | ☐ |
| 4 | `com.turnonac.gate.shield-action` | ☐ ______ | ☐ | ______ | ______ | ☐ |
| 5 | `com.turnonac.gate.report` | ☐ ______ | ☐ | ______ | ______ | ☐ |

**Success state:** the capability reads **"Assigned"**, and the info button's *Provisioning Support* section lists every distribution method you need (App Store, TestFlight). "Submitted" is not success, and an approval email can arrive while the portal still says "Submitted" — if that happens, regenerate the provisioning profiles and check again before contacting support.

---

## Ready-to-paste request body — the app

> Paste into the form's free-text field for `com.turnonac.gate`.

```text
App name: Gate
Bundle ID: com.turnonac.gate
Platform: iOS / iPadOS 17.0+
Requested frameworks: FamilyControls, ManagedSettings, ManagedSettingsUI, DeviceActivity
Authorization model: FamilyControlsMember.individual

What the app does
Gate is a personal digital-wellbeing and self-control app for adults. The user
selects their own apps and websites and Gate shields them on a schedule the user
sets for themselves. Its distinguishing feature is an asymmetric change cost:
making a restriction stronger applies immediately, while making one weaker is
queued behind a user-chosen delay (default 15 minutes) or a passphrase the user
has given to a friend. The user is committing their future self in advance; the
app exists to make changing your mind cost time.

Authorization is requested with FamilyControlsMember.individual, so the device
owner authorizes their own device with Face ID or Touch ID. There is no iCloud
sign-in, no Family Sharing group, no parent or guardian, no second device and no
account of any kind.

Exact user journey
1. First launch explains, in plain language, what Gate can and cannot do,
   including that the user can always revoke Gate in Settings.
2. The user taps "Get Started". Gate calls
   AuthorizationCenter.shared.requestAuthorization(for: .individual). iOS shows
   its Screen Time alert; the user authenticates biometrically.
3. The user taps "Choose apps to block", and the system FamilyActivityPicker
   appears. They pick their own apps, website categories and domains. Gate never
   learns which ones — iOS returns opaque tokens.
4. The user names the rule and optionally sets a daily window.
5. Gate writes the selected tokens to a per-rule ManagedSettingsStore
   (shield.applications / shield.applicationCategories / shield.webDomains) and
   registers one DeviceActivitySchedule per rule with DeviceActivityCenter.
6. When the user opens a shielded app, iOS draws Gate's shield, rendered by the
   ShieldConfiguration extension from copy the user wrote themselves.
7. Tapping the shield's primary button hands off to the ShieldAction extension,
   which records the attempt and opens Gate so the user can complete a short
   reflection before being granted a time-boxed exception.

Why each framework is required
- FamilyControls     — authorization and the FamilyActivityPicker. Without it
                       the user cannot select anything and there are no tokens.
- ManagedSettings    — ManagedSettingsStore.shield.* is the enforcement itself,
                       and ShieldActionDelegate handles shield button taps.
- ManagedSettingsUI  — ShieldConfigurationDataSource, so the interstitial shows
                       the user's own rule name and their own written reason
                       rather than the generic system shield.
- DeviceActivity     — DeviceActivitySchedule / DeviceActivityCenter for the
                       user's daily windows and one-shot exception timers, and
                       DeviceActivityReport for a read-only usage summary the
                       user sees on their own device.

Privacy
Gate collects nothing. There is no account, no server, no analytics SDK and no
crash reporter. Screen Time selections are opaque tokens that never leave the
device, and the DeviceActivityReport extension is sandboxed by Apple so nothing
it computes can reach us. We do not collect usage data for advertising,
profiling, ad targeting, or sale to third parties, and we have no mechanism to
do so — there is nothing in this app that transmits anything off the device.

Extensions in this app, each the subject of its own request
- com.turnonac.gate.activity-monitor       (DeviceActivityMonitor)
- com.turnonac.gate.shield-configuration   (ShieldConfiguration)
- com.turnonac.gate.shield-action          (ShieldAction)
- com.turnonac.gate.report                 (DeviceActivityReport)
```

---

## Ready-to-paste request body — the extensions

> One per extension. Replace the two bracketed lines from the table below; leave everything else identical, so the reviewer sees the same app described the same way five times.

```text
Extension name: [EXTENSION NAME]
Bundle ID: [EXTENSION BUNDLE ID]
Parent app: Gate — com.turnonac.gate (requested separately)
Platform: iOS / iPadOS 17.0+
Requested frameworks: FamilyControls, ManagedSettings, ManagedSettingsUI, DeviceActivity
Authorization model: FamilyControlsMember.individual

This is a Screen Time API app extension belonging to Gate, an adult
digital-wellbeing and self-control app, and this request accompanies the request
already filed for the parent app com.turnonac.gate.

Gate lets an adult select their own apps and websites and shields them on a
schedule they set for themselves, with an asymmetric change cost: strengthening
a restriction applies immediately, weakening one is queued behind a delay the
user chose in advance. Authorization uses FamilyControlsMember.individual, so
no iCloud account, no Family Sharing group and no second device are involved.

What this extension does
[ROLE PARAGRAPH]

Privacy
This extension has no network access and transmits nothing. All of its state is
read from, and in one case appended to, the shared App Group container
group.com.turnonac.gate on the same device. Screen Time selections are opaque
tokens that never leave the device. We do not collect usage data for
advertising, profiling, or sale to third parties.
```

| Request | `[EXTENSION NAME]` | `[EXTENSION BUNDLE ID]` | `[ROLE PARAGRAPH]` |
|---|---|---|---|
| 2 | Gate Activity Monitor | `com.turnonac.gate.activity-monitor` | A `DeviceActivityMonitor` subclass. It receives `intervalDidStart` / `intervalDidEnd` for the daily windows the user configured and, on each callback, re-reads the user's own rules from the App Group and applies or lifts the corresponding `ManagedSettingsStore` shields. It also fires one-shot timers that end a temporary exception the user was granted. It writes nothing off-device and links no networking code. |
| 3 | Gate Shield Configuration | `com.turnonac.gate.shield-configuration` | A `ShieldConfigurationDataSource`. When iOS shields an app or website the user chose, this extension returns the `ShieldConfiguration` — the rule's name as the title, and as the subtitle the sentence the user wrote themselves about why they set this rule. Without it the user sees the generic system shield instead of their own words, which is the entire intervention. It reads a pre-rendered configuration file from the App Group and returns synchronously. |
| 4 | Gate Shield Action | `com.turnonac.gate.shield-action` | A `ShieldActionDelegate`. It handles the two buttons on the shield. "Not now" returns `.close`. "Let me in" records the attempt into the App Group and returns `.openParentalControlsApp` on iOS 26.5+, so the user lands in Gate and completes a short reflection before being granted a time-boxed exception; below 26.5 it posts a local notification with a deep link and returns `.close`. |
| 5 | Gate Report | `com.turnonac.gate.report` | A `DeviceActivityReportExtension`. It renders a read-only daily summary of the user's own Screen Time inside the app, on the user's own device. Per Apple's design this extension is sandboxed and cannot pass any computed value back to the containing app, and we neither attempt nor need to: the view is display-only. |

---

## 0.4 · App Store Connect age-rating questionnaire

Already mandatory as of September 2026 — you cannot submit a new app, a version update, or a notarization request without answering the **social-media capability questions**.

For an app blocker the answer is **No** on every social-media capability. That keeps Gate out of the Social Media Time Allowance bucket, and it means Gate does not need `DeclaredAgeRange` or its entitlement. There is no API to read, override or appeal Time Allowance category assignment.

- ☐ Questionnaire answered — date: ______

---

## 0.5 · Register device UDIDs on the development profile

Development signing is the path that makes this project useful in week 2 without any Apple approval. Register your own device — and any tester's — on the development provisioning profile for **all five** App IDs. Limit: 100 devices/year per device class.

| Device | iOS version | UDID registered on all 5 App IDs | Date |
|---|---|---|---|
| ______ | ______ | ☐ | ______ |
| ______ | ______ | ☐ | ______ |

> Your primary dev device should run **iOS 26.5 or later** so `ShieldActionResponse.openParentalControlsApp` — the primary intervention path — works from day one. Keep a second device or a second OS version on the iOS 17/18 floor to exercise the notification fallback.

---

## Things that will cost you a week if you forget them

1. **Paid Apple Developer Program membership is mandatory**, even for a build only you will run. Family Controls (development) is checked in the ADP column only; the free Personal Team and the Enterprise program cells are both empty, and Apple DTS has said there is no supported way to use a capability that is not listed there.
2. **The request is per App ID, not per app.** Five, every time, including on any future prefix change.
3. **Account Holder files it.** An Admin cannot.
4. **Screenshot everything.** There is no receipt.
5. **Casing.** See 0.1. Changing `BUNDLE_ID_PREFIX` later means five new App IDs and five new requests.
6. **Do not wait.** Phases 1–6 are entirely unblocked. Revisit this file only when "Assigned" appears.
