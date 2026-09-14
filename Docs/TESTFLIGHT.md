# Getting Gate onto your iPhone without a Mac

Everything Gate does is invisible until it runs on real hardware: no Screen Time
API works on a simulator or in a unit test (`docs/03-hard-constraints.md` #11).
The usual route to a device is Xcode on a Mac. This is the other route —
GitHub's macOS runner archives and uploads, and the build lands in the TestFlight
app on your phone.

**Internal testers need no App Review.** A build is installable within about
15 minutes of the upload finishing.

## Before you start

> **This needs the Family Controls _distribution_ entitlement.** TestFlight is
> an App Store Connect upload, and Apple DTS is explicit that the distribution
> entitlement gates it — internal testers included. If your five App IDs do not
> carry it, the archive fails at signing.

You said all five App IDs read **Assigned**. Worth confirming it is really the
distribution grant and not just the development capability, because that
distinction cost a round earlier — see `Docs/ENTITLEMENT-REQUEST.md`, "Reading
the portal". If the archive step fails with a provisioning error, that is your
answer and the five requests still need filing.

## One-time setup — about 20 minutes, all on the web

### 1 · Create the app record in App Store Connect

<https://appstoreconnect.apple.com> → **Apps → +  → New App**

| Field | Value |
|---|---|
| Platform | iOS |
| Name | Gate *(must be globally unique; adjust if taken)* |
| Primary language | English (U.S.) |
| Bundle ID | `com.turnonac.gate` |
| SKU | `gate-ios` *(internal only, any string)* |
| User Access | Full Access |

Only the app's own bundle ID gets a record. The four extensions ship inside it
and need none.

### 2 · Create an App Store Connect API key

**Users and Access → Integrations → App Store Connect API → Team Keys → +**

- Name: `Gate CI`
- Access: **App Manager**

Then collect three things:

| What | Where |
|---|---|
| **Key ID** | the row in the key list, e.g. `A1B2C3D4E5` |
| **Issuer ID** | a UUID shown *above* the list, once per team |
| **`AuthKey_XXXXXXXXXX.p8`** | the download button — **once only** |

The `.p8` downloads exactly one time and cannot be retrieved again. If you lose
it, revoke the key and make another.

### 3 · Find your Team ID

<https://developer.apple.com/account> → **Membership details → Team ID**.
Ten characters.

### 4 · Add four GitHub secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**

| Name | Value |
|---|---|
| `ASC_KEY_ID` | the Key ID from step 2 |
| `ASC_ISSUER_ID` | the Issuer ID from step 2 |
| `ASC_KEY_P8` | the **entire** contents of the `.p8` file, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines |
| `APPLE_TEAM_ID` | the Team ID from step 3 |

On a phone: open the `.p8` in a text editor, select all, copy, paste. It is
about four lines.

## Shipping a build

Repo → **Actions → TestFlight → Run workflow**.

Roughly 15–25 minutes. What it does:

1. writes the API key and your Team ID onto the runner (neither is ever committed)
2. generates `Gate.xcodeproj` from `project.yml`
3. sets the build number from the workflow run number, so it always increases
4. archives Release for a real device, letting Xcode create the distribution
   certificate and all five provisioning profiles from the API key
   (`-allowProvisioningUpdates` — this is what removes the need for a Mac)
5. asserts all four `.appex` bundles are inside the archive
6. exports the `.ipa` and uploads it
7. deletes the key

Then: App Store Connect processes for 5–15 minutes → the build appears under
**TestFlight → iOS Builds**. Add yourself as an **Internal Tester**, install the
TestFlight app on your iPhone, and it is there.

The first build asks you to answer the **export compliance** question. Gate uses
no encryption beyond HTTPS — and in fact makes no network calls at all — so the
answer is **No**.

## When it breaks

| Symptom | Cause |
|---|---|
| Archive fails, provisioning error naming `com.apple.developer.family-controls` | The distribution entitlement is not actually granted. Back to `Docs/ENTITLEMENT-REQUEST.md`. |
| `No profiles for 'com.turnonac.gate.<x>' were found` | One of the five App IDs is missing or misspelled in the portal. Casing is load-bearing. |
| Upload rejected, `ITMS-90022` / missing icon | `App/Assets.xcassets` did not make it into the target. |
| Upload rejected, `ITMS-90717` | The icon has an alpha channel. The committed one does not — regenerate rather than re-export from a design tool. |
| `The bundle version must be higher than the previously uploaded version` | Two runs produced the same build number. Re-run; the run number always increases. |
| Archive succeeds, upload hangs | Usually App Store Connect being slow. The archive is kept as an artifact on failure, so you can re-upload rather than re-archive. |

## Once it is on the phone

Go straight to `Docs/DEVICE-TEST-MATRIX.md`. Test **(a)** is the one that can
still change the architecture:

> Does `ShieldActionResponse.openParentalControlsApp` actually launch the app
> under `.individual` authorization?

Apple's documentation is written for the parental-control case and nobody has
field-reported the individual one. If the answer is no, the whole intervention
flow is redesigned around the notification fallback — and that is much cheaper to
learn now than after anything is built on top of it.
