# Gate

A commitment device for your iPhone, built on Apple's Screen Time APIs.

Gate blocks apps and websites you choose, on a schedule you set — and then makes
*changing your mind* cost time. Tightening a restriction applies instantly.
Loosening one goes into a queue and waits out a delay you configured earlier.
That asymmetry is the whole product; everything else exists to make it usable.

---

## Status — read this first

**The complete v1 source tree is present. Nothing here has ever been compiled,
run, or validated on a device.**

This repository was authored on Linux, where no Xcode, no Swift compiler and no
iOS SDK exist. The Swift here is written against the exact symbol list in
`docs/02-api-reference.md` and is meant to be correct by construction — but
The tree compiles and its unit tests pass in CI. That is a real floor, and it
is also the whole of what has been verified: no Screen Time behaviour has ever
been observed, because none of it can run on a simulator or in a test process.

| Phase (`docs/06-build-plan.md`) | State |
|---|---|
| 0 — App IDs + 5 entitlement requests | Five App IDs created, Family Controls assigned on each. Checklist in `Docs/ENTITLEMENT-REQUEST.md`. |
| 1 — XcodeGen scaffold, `Config/`, `Kernel/Identifiers.swift` | Written |
| 2 — On-device proof loop + the go/no-go device gate | **Not run.** `Docs/DEVICE-TEST-MATRIX.md` is an unfilled template. |
| 3 — `Kernel/` (model, store, ratchet, scheduling, enforcement, reconciler) | Written |
| 4 — The four extensions | Written |
| 5 — `App/` (SwiftUI screens, `AppModel`, reconcile-on-foreground) | Written and compiling — `GateApp`, `AppModel`, seven screens, `Debug/`. |
| 6 — Personally useful dev-signed build | **Not reached.** Needs a Mac, Xcode 26.5+ and a physical device — none of which have touched this tree. |
| 7 — App Store readiness (privacy manifests, CI, review notes) | CI green. Review notes and all five privacy manifests written; none validated by a real archive |

Concretely, that means:

- **CI is green**, and that means exactly four things: the `Config/` strings
  that make the four extensions launchable are correct; `project.yml` generates
  and nothing generated is committed; the 234 `GateKernel` unit tests pass; and
  all seven targets compile against the iOS 26.5 SDK with `GateReport.appex`
  embedded in `Gate.app/Extensions/` rather than `PlugIns/`.

  It does **not** mean a rule blocks an app, a shield renders, a monitor
  callback arrives, a grant expires on time, or the Lock survives a reinstall
  on real hardware. None of that is reachable from a simulator or a test
  process (`docs/03-hard-constraints.md` #11). A release with a green check and
  an unfilled `Docs/DEVICE-TEST-MATRIX.md` is not tested.

- **One v1 feature is deliberately absent.** The iOS 26.5 accelerator that
  observes `ManagedSettingsStore.TokenExpiryMessage` was removed after two
  spellings were rejected by the SDK; `App/AppModel.swift` records both
  failures and what to try next. V1-9's three other recovery routes are
  unaffected and carry the feature on the iOS 17 floor.
- **Two architectural decisions are still open**, and only a physical device can
  close them — no amount of further reading will. Both are in
  `Docs/DEVICE-TEST-MATRIX.md`: whether `ShieldActionResponse.openParentalControlsApp`
  actually launches the app under `.individual` authorization (if it does not,
  the entire intervention flow is redesigned around the notification fallback),
  and which `DateComponents` granularity actually delivers both
  `intervalDidStart` and `intervalDidEnd`.
- Claims in `docs/` marked `(unverified)` are handled defensively in code with a
  fallback path. They are still unverified.

---

## The honest limitation

**Gate cannot stop you from turning Gate off.** Under
`FamilyControlsMember.individual` — the authorization model an adult self-control
app must use — Apple *deliberately removes* the anti-bypass protections that
exist for parental controls, in their words "so the user can delete an
authorized app or sign out of iCloud as needed." You can revoke Gate's access in
about four taps (Settings → Screen Time → Apps with Screen Time Access), and
every restriction lifts instantly. There is no API to block that, to delay it,
or to reliably detect it; Settings.app itself cannot be shielded, so the hatch is
structurally guaranteed to stay open. Deleting the app does not reset the clock —
the Lock deadline lives in the Keychain, which survives app deletion — but that
is friction, not enforcement. **Gate makes quitting cost you time. It does not
make quitting impossible, and any app in this category that tells you otherwise
is lying.** Real enforcement on iOS requires a device someone else administers —
supervision or MDM — which no third-party App Store app can reach.

---

## What v1 does

Full scope, numbered `V1-1` … `V1-11`, is in `docs/04-product-spec.md`.

- **Rules** — a name, a set of apps/categories/websites picked through Apple's
  system picker, a mode (blocklist, or allowlist = "block everything except
  these"), and an optional repeating daily window. Up to 8 rules; each gets its
  own named `ManagedSettingsStore` so rules never clobber each other.
- **The Lock** — one per install. A delay (1 minute to 7 days, default 15
  minutes), a partner-held password, or both. Increasing the delay is free;
  decreasing it costs `oldDelay − newDelay`. The deadline is mirrored into the
  Keychain so delete-and-reinstall does not reset it.
- **The Ratchet** — every settings change is classified as a tightening or a
  loosening. Tightenings apply immediately. Loosenings become a pending change
  with a visible countdown. Cancelling a pending change is itself a tightening,
  and therefore free.
- **The shield** — your own title, subtitle and buttons on the block screen,
  pre-staged in the App Group because the shield extension is network-blocked
  and latency-bounded. Static copy only, never a live countdown.
- **The intervention** — "Let me in" opens Gate (iOS 26.5+) or posts a
  notification with a deep link (below 26.5), makes you wait, asks what you
  actually want to do in there, and then issues a time-boxed, token-scoped
  grant out of a daily budget. It cannot reopen the blocked app for you; iOS
  provides no API for that, and the copy says so.
- **Install protection** — one toggle for `denyAppInstallation`, so you cannot
  route around a block by installing something new.
- **Recovery** — iOS occasionally reissues the opaque app identifiers Gate
  stores, which silently breaks a rule. Reselecting your apps is a first-class
  screen, and because reselection is a *tightening* it is never gated behind the
  Lock.

Explicitly not in v1: accounts, servers, analytics, crash reporting,
subscriptions, widgets, usage charts. That keeps the App Privacy answer at "Data
Not Collected" and the monitor extension under its 6 MB ceiling.

---

## Two distribution paths — do not conflate them

A **paid Apple Developer Program membership ($99/yr) is a hard floor for both.**
Family Controls is checked only in the ADP column of Apple's supported
capabilities table; it is unavailable on a free Personal Team and on the
Enterprise program. There is no way around this.

| | **Personal (development signing)** | **App Store / TestFlight** |
|---|---|---|
| Apple approval needed | **None** | The Family Controls **distribution entitlement**, ×5 |
| How long | Build it and run it | 1 day to 6+ weeks. No SLA, no ticket ID, no confirmation email. |
| Who files | — | The Apple Developer **Account Holder** personally — not an Admin |
| What you get | The complete app, fully functional, on devices whose UDIDs are on your development profile (100/year per device class) | Everything, plus TestFlight and the store |
| Expiry | The provisioning profile's 12 months; re-sign annually | Normal |

**The personal path is the one that makes this project worth starting.** Phases
1–6 of the build plan need zero Apple approval. Phase 7 is the only part gated
on the entitlement.

The App Store path needs **five separate requests** — the app plus each of the
four extensions — because Apple requires one per App ID, extensions included.
TestFlight is gated too, internal testers included. File all five on day one and
then stop waiting on them. `Docs/ENTITLEMENT-REQUEST.md` is the checklist to work
through: the bundle IDs are already locked there (casing is load-bearing — a
prefix mismatch between the app and an extension blocks archiving and forces a
fresh request), alongside an empty submission tracker.

---

## Quick start

Requirements: macOS with **Xcode 26.5 or newer** (the code compiles against
symbols introduced in the iOS 26.5 SDK, each behind an `if #available` guard so
the shipped app still runs on the iOS 17.0 floor), **XcodeGen ≥ 2.42.0**
(`brew install xcodegen`), a **paid Apple Developer Program** team, and a
**physical iPhone or iPad running iOS 17.0+** — iOS 26.5+ if you want the
primary intervention flow rather than the notification fallback.

```sh
# 1. Your Team ID. Config/Local.xcconfig is git-ignored and is included last by
#    Config/Build.xcconfig, so it overrides the repo default without a diff.
cp Config/Local.xcconfig.example Config/Local.xcconfig
$EDITOR Config/Local.xcconfig          # TEAM_ID = your 10-character team ID

# 2. Generate the Xcode project from project.yml, then check the traps.
make project

# 3. Open it and run — ON A PHYSICAL DEVICE.
open Gate.xcodeproj
```

Step 3 has never been performed. The `Gate` target now has sources, but no part
of this tree has been through a Swift compiler, so expect to fix build errors
before the app runs. Steps 1 and 2 are Linux-safe, as is `make verify`.
See [Status](#status--read-this-first).

**The Simulator is useless for this project and always will be.** There is no
Simulator support for any Screen Time API: `requestAuthorization` fails with
`FamilyControlsError.invalidArgument`, and the picker, the shields, the monitor
callbacks and the report extension do not run at all. A simulator build proves
the code compiles and nothing else.

Your device also needs a passcode (otherwise `.authenticationMethodUnavailable`),
an iCloud account (`.invalidAccountType`) and a network connection
(`.networkError`) before authorization will succeed.

**`Gate.xcodeproj` is generated and git-ignored.** `project.yml` is the single
source of truth. Never commit the project file and never hand-edit it — CI fails
the build if either happens.

### Make targets

| | |
|---|---|
| `make project` | `xcodegen generate`, then `make verify` |
| `make verify` | Pure grep. Extension point identifiers, entitlements, the App Group, the xcconfig invariants, and the `GateReport` product type + embed phase. Runs anywhere, including Linux. |
| `make test` | `swift test` in `Tests/` — the Kernel unit tests, no Xcode project, no device |
| `make lint` | SwiftLint, plus `plutil -lint` on `Config/` |
| `make clean` | Remove the generated project and all build products |

---

## Repo layout

```
project.yml                    XcodeGen spec — the single source of truth for the project
Makefile                       project / verify / test / lint / clean
.github/workflows/ci.yml       compile-only CI; see "CI" below

Config/
  Build.xcconfig               TEAM_ID, BUNDLE_ID_PREFIX, APP_GROUP, iOS 17.0, Swift 6
  Local.xcconfig.example       template for your git-ignored Local.xcconfig
  Gate-App.entitlements        family-controls + app group + keychain access group
  Gate-Extension.entitlements  shared by all four extensions (NO keychain group)
  Gate-Info.plist              app, incl. the gate:// URL scheme
  ActivityMonitor-Info.plist   ─┐
  ShieldConfiguration-Info.plist│ the four extension point identifiers,
  ShieldAction-Info.plist       │ which `make verify` asserts character-for-character
  Report-Info.plist            ─┘ (ExtensionKit form: EXAppExtensionAttributes, no principal class)

Kernel/                        GateKernel.framework — no UIKit, no SwiftUI, extension-safe
  Identifiers.swift            App Group, store names, activity names, log subsystems, caps
  Model/                       Rule, LockPolicy, PendingChange, Grant, ShieldCopy, GateState
  Store/                       AppGroupContainer, GateStateStore, InboxStore, LockClock
  Engine/                      Ratchet, Reconciler, ScheduleBuilder, ActivityNameCodec, GrantEngine
  Enforcement/                 ShieldWriter, MonitorPlan, TokenGuard

KernelUI/                      GateKernelUI.framework — SwiftUI theme + shared components
                               Linked by the app, the shield config extension and the report.
                               NEVER by the monitor.

Extensions/
  ActivityMonitor/             DeviceActivityMonitor. 6 MB ceiling. GateKernel only, no SwiftUI.
  ShieldConfiguration/         Reads shield.plist synchronously and returns in microseconds
  ShieldAction/                Appends to inbox/, then .openParentalControlsApp or .close
  Report/                      ExtensionKit. Renders locally; nothing it computes can escape.

App/                           The Gate app target. SwiftUI, never compiled.
  GateApp.swift                @main, scene-phase hook, notification delegate, gate:// deep link
  AppModel.swift               the single @MainActor observable; owns activate(trigger:)
  GateLinks.swift              the privacy-policy URL — SET IT before submitting (5.1.1(i))
  Screens/                     Home, RuleEditor, LockSettings, Intervention, Recovery, Onboarding, Stats
  Debug/                       DebugScreen — dev-signed builds only

Package.swift                  root SwiftPM manifest — `swift test` only; never a
                               dependency of the generated Xcode project
Tests/GateKernelTests/         Kernel unit tests, run by `make test` (which cd's to
                               Tests/ and finds the root manifest). Never executed.

docs/                          the research dossier this was built from (lowercase)
Docs/                          the operational checklists you fill in (capitalised)

Config/Privacy/App/            PrivacyInfo.xcprivacy for the app bundle
Config/Privacy/Extension/      PrivacyInfo.xcprivacy, shared by all four .appex bundles
Widgets/                       v2
```

**Targets** (7; `GateWidgets` is deferred to v2): the `Gate` app, two frameworks,
three classic `app-extension`s, and `GateReport` as an
**`extensionkit-extension`** — the last of which is not a stylistic choice.
Building it as a plain app-extension either fails to install on device or is
rejected by App Store Connect, and you find out a full review cycle later.

**Everything crosses process boundaries through one App Group,
`group.com.turnonac.gate`, and nothing else.** There is no supported
cross-process notification channel on iOS for this. The app is the only writer
of `state.plist`; extensions append small files to `inbox/` and the app compacts
them on the next foreground.

---

## Documentation

`docs/` (lowercase) is the research dossier — what the platform can and cannot
do, and why the architecture is shaped the way it is. Read it before changing
anything structural.

| Doc | What it answers |
|---|---|
| [docs/00-executive-summary.md](docs/00-executive-summary.md) | Can this be built? What is honestly achievable? |
| [docs/01-capability-matrix.md](docs/01-capability-matrix.md) | Feature by feature: FULL / DEGRADED / BLOCKED |
| [docs/02-api-reference.md](docs/02-api-reference.md) | Exact symbols, entitlement strings, extension point identifiers, iOS minimums |
| [docs/03-hard-constraints.md](docs/03-hard-constraints.md) | The walls. Read before designing anything. |
| [docs/04-product-spec.md](docs/04-product-spec.md) | v1 / v2 / v3 scope — the `V1-n` numbers used throughout the code |
| [docs/05-architecture.md](docs/05-architecture.md) | Targets, App Group, data flow, module split, persistence decision |
| [docs/06-build-plan.md](docs/06-build-plan.md) | Ordered steps — the `PHASE n` / step numbers used in code comments |
| [docs/07-risks.md](docs/07-risks.md) | Ranked risks and mitigations |
| [docs/08-citations.md](docs/08-citations.md) | Sources |

`Docs/` (capitalised) is operational — checklists and records you fill in as you
go. They are templates right now, not results.

| Doc | What it is for |
|---|---|
| [Docs/DEVICE-TEST-MATRIX.md](Docs/DEVICE-TEST-MATRIX.md) | **The go/no-go gate.** Physical-device results. Two cells change the architecture rather than a detail of it. Re-run every iOS point release. |
| [Docs/ENTITLEMENT-REQUEST.md](Docs/ENTITLEMENT-REQUEST.md) | The five App IDs, the locked bundle-ID casing, and the five distribution requests with a submission tracker |
| [Docs/REVIEW-NOTES.md](Docs/REVIEW-NOTES.md) | App Review notes, pre-arguing Guideline 2.5.1 — which is what actually rejects apps in this category |

Anything in `docs/` marked `(unverified)` could not be confirmed against a
primary source. Where code depends on such a claim it takes the defensive path
and says so in a comment.

The two directories differ only in case. Git tracks them as distinct paths, but
on a case-insensitive filesystem — macOS's default — they check out into a single
folder on disk. Nothing breaks, because no two files share a name, but expect to
see all of it in one listing.

---

## CI

`.github/workflows/ci.yml` runs three jobs: config invariants on Linux
(`make verify`, plus a check that no generated or signing file is tracked), the
Kernel unit tests, and an unsigned iOS Simulator compile of every target after
regenerating the project and asserting the working tree stayed clean. The build
job then checks the produced `Gate.app` — `GateReport.appex` must be in
`Extensions/` and the other three in `PlugIns/`, which is the one App Store trap
on this stack a build product can actually prove.

**CI can compile. It can never test any Screen Time behaviour.** No Screen Time
API runs on a simulator or inside a test process, so a green check means the
plists are still right, the project still generates, the Kernel's logic tests
pass, and everything still builds. It says nothing about whether a rule blocks an
app, a shield renders, a monitor callback arrives, a grant expires on time, or
the Lock survives a reinstall.

**Every release needs a manual pass on physical hardware against
`Docs/DEVICE-TEST-MATRIX.md`, on both the shipping iOS and the current beta.** A
release with a green CI and an unfilled device matrix has not been tested.
