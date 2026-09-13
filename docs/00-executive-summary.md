## Verdict: yes, buildable — but "equivalent to Andoff" is not achievable, and saying otherwise would be lying to you

**Andoff is not a screen-time app. It is an MDM-class lockbox.** Its package name literally ends in `.dpc` (Device Policy Controller) and its admin component is `app.plucky.dpc/.PluckyDAR`. It is installed by factory reset or `adb shell dpm set-device-owner`, and everything that makes it feel unbreakable — package suspension, per-app uninstall blocking, blocking Safe Mode, blocking Factory Reset, blocking Developer Options, auto-suspending newly installed apps, protecting a *third-party* filter app from removal — is Android Device Owner privilege. **None of that exists for a third-party iOS app.** Not degraded — absent. The nearest iOS equivalents (Supervision, Activation Lock, MDM restrictions) require Apple Business/School Manager + an MDM server + Apple Configurator supervision, which an App Store consumer app can never touch.

**The single defining asymmetry:** Andoff's escape hatch costs a full factory reset or an ADB session on a PC. The iOS escape hatch is *Settings → Screen Time → Apps with Screen Time Access → toggle off* — roughly four taps, after which every one of your `ManagedSettingsStore` restrictions lifts instantly. Your app cannot block it, cannot delay it, and (per forum thread 820796) cannot even reliably *detect* it while backgrounded. Apple documents this as intentional: under `FamilyControlsMember.individual`, "the system removes any restrictions that prevent the user from bypassing parental controls so the user can delete an authorized app or sign out of iCloud as needed."

**So design for friction, not enforcement.** That is not a consolation prize — it is the correct read of the market. Every shipping iOS product in this category (Opal, Jomo, ScreenZen, one sec, Brick, Clearspace, Roots, Freedom, Unpluq) lives inside exactly these limits.

### What actually ports from Andoff — and it is the best part

Andoff's *product logic* needs **zero platform privilege** and ports at 100%:

| Andoff mechanic | Portability |
|---|---|
| Delay-based locking mechanism (countdown before a change applies) | Pure app logic |
| Password held by an accountability partner | Pure app logic |
| **"Permit tightening changes directly"** — tighten instantly, loosen only through the lock | Pure app logic |
| Auto-Revert (temporary loosening that self-reverts) | Pure app logic |
| Advanced Mode progressive disclosure | Pure app logic |

The **ratchet** — a monotonicity rule over your own settings model where *adding* restriction is free and *removing* restriction is expensive — is the single most copyable idea in Andoff and, as far as the competitive teardown shows, **nobody on iOS has implemented it properly**. ScreenZen has "Lock Settings," Opal has "Deep Focus," Roots has "Monk Mode" — all are session-scoped one-way doors. None is a persistent asymmetric-cost settings model. That is your differentiator, and it is free.

Andoff also has **no analytics, no per-app quotas, no charts, no streaks, no scheduling**. Its moat is enforcement strength. Since enforcement strength is precisely where iOS is weakest, a literal clone would ship the weak half. **Add scheduling** (`DeviceActivitySchedule` — the one axis where iOS is at parity or better) and keep the lock semantics; skip the dashboard, because the `DeviceActivityReportExtension` sandbox makes real analytics impossible outside the EU anyway (Apple DTS confirmed: "Is DeviceActivityReportExtension intentionally sandboxed so Screen Time data cannot be exported to the containing app?" → **"Yes."**).

### What iOS actually gives you (the real, non-trivial wins)

- **OS-level enforcement that survives force-quit, reboot, account switching, and even deleting your app.** `ManagedSettingsStore` state lives in a system daemon, not your process. This is genuinely stronger than an Android AccessibilityService overlay blocker.
- **A system-drawn interstitial** (`ShieldConfiguration`) that is structurally the same *kind* of object as Android's `SuspendDialogInfo` — icon, title, subtitle, two buttons. Andoff's intervention UX ports better than a typical Android overlay blocker's would.
- **iOS 26.5 shipped `ShieldActionResponse.openParentalControlsApp`** — after four years of developers begging, the shield can finally launch your app. This is the single most important new capability in the category and it changes the optimal 2026 architecture: shield → tap → your full SwiftUI intervention. No Shortcuts automation, no local-notification hack.
- **iOS 26.4 shipped `ShieldConfiguration.secondaryButtonSubmenuItems: [String]?`** — up to three named actions on the shield itself ("1 more minute" / "15 more minutes" / "1 hour"), the sanctioned temporary-grant UI.

### Two separate go-to-market paths — do not conflate them

**Personal path (no Apple review, useful in ~2 weeks):** a paid Apple Developer Program membership ($99/yr) is a hard floor — Apple's Supported Capabilities (iOS) table checks Family Controls (development) **only** in the ADP column; ADEP and free "Apple Developer" (Personal Team) cells are empty, and Apple DTS has said flatly "There's no supported way to use capabilities that aren't listed there." With ADP you add the Family Controls capability in Xcode, development-sign onto your own device with a 12-month provisioning profile, and the app works fully. **This requires zero Apple approval and is the path that makes this project worth starting.**

**App Store path (weeks of wall-clock risk before you write code):** you must file the distribution entitlement request **five times** — container app + DeviceActivityMonitor + DeviceActivityReport + ShieldAction + ShieldConfiguration. Reported turnaround in 2026: 1 day to 6+ weeks, no SLA, no ticket ID, no confirmation email, and approval emails that arrive while the portal still reads "Submitted." It gates **TestFlight too** (Apple DTS, thread 766923: *"Can I distribute a build for internal testers via TestFlight without waiting for Apple's reply?" → "No."*). **File all five on day one, before writing a line of code.**

### Honest expectation-setting on reliability

`eventDidReachThreshold` — the only usage-event primitive in the entire API — has been **documented-by-behavior broken across iOS 26.2 through 26.5.2**: fires immediately, fires with 0 recorded Screen Time minutes, fires twice, or silently never fires. There are open threads with no Apple resolution and a dozen Feedback IDs. **Do not put time-quota enforcement on the critical path of your product promise.** Andoff's binary-block-plus-friction model is *not* threshold-dependent, which is another reason it is the right model to port.

### Realistic solo timeline

- **Days 1–2:** file 5 entitlement requests; scaffold XcodeGen project; get authorization + picker + a shield working on your own device.
- **Weeks 1–3:** ratchet engine, lock, schedules, shield handoff → personally useful build on dev signing.
- **Weeks 4–8:** hardening, recovery flows, privacy manifests, StoreKit 2, review notes.
- **Blocked on Apple:** TestFlight and App Store, by the entitlement queue.

**Bottom line: you can build something genuinely better than what ships on iOS today, by porting Andoff's lock semantics rather than its enforcement model. You cannot build something as hard to defeat as Andoff, and no amount of engineering changes that.**
