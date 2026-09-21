#!/usr/bin/env python3
"""Validate the App Store Connect credentials before xcodebuild needs them.

Xcode's own failure for a bad key is a 401 from `listTeams.action`, which then
cascades into "No profiles for <bundle id> were found" on every target. That
reads as a provisioning or entitlement problem when it is really a credentials
problem, and the difference matters a lot here: the Family Controls
distribution entitlement is only actually exercised once authentication works.

This asks App Store Connect directly and says which secret is wrong.
Reads ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, APPLE_TEAM_ID from the
environment. Prints no secret, only its shape.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

WANT_BUNDLE_ID = os.environ.get("WANT_BUNDLE_ID", "com.turnonac.gate")

key_id = os.environ.get("ASC_KEY_ID", "")
issuer = os.environ.get("ASC_ISSUER_ID", "")
p8 = os.environ.get("ASC_KEY_P8", "")
team = os.environ.get("APPLE_TEAM_ID", "")

problems = []

if len(key_id) != 10:
    problems.append(
        f"ASC_KEY_ID is {len(key_id)} characters; an App Store Connect key id is 10.\n"
        "     It is the KEY ID column in the key list, and is also in the\n"
        "     filename you downloaded: AuthKey_<KEY_ID>.p8"
    )
else:
    print("ok    ASC_KEY_ID     10 characters")

if not re.fullmatch(r"[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", issuer):
    problems.append(
        "ASC_ISSUER_ID is not a UUID.\n"
        "     The Issuer ID is the UUID shown ABOVE the key list, one per team.\n"
        "     A common mix-up is swapping it with ASC_KEY_ID."
    )
else:
    print("ok    ASC_ISSUER_ID  is a UUID")

if len(team) != 10:
    problems.append(
        f"APPLE_TEAM_ID is {len(team)} characters; an Apple Team ID is 10.\n"
        "     developer.apple.com/account -> Membership details -> Team ID."
    )
else:
    print("ok    APPLE_TEAM_ID  10 characters")

if "BEGIN PRIVATE KEY" not in p8:
    problems.append(
        "ASC_KEY_P8 has no -----BEGIN PRIVATE KEY----- line.\n"
        "     Paste the ENTIRE .p8 file, including the BEGIN and END lines."
    )
elif "\\n" in p8:
    problems.append(
        "ASC_KEY_P8 contains the literal characters \\n instead of real newlines.\n"
        "     Paste the file as-is. GitHub secrets keep newlines; do not escape them."
    )
else:
    print(f"ok    ASC_KEY_P8     BEGIN line present, {len(p8.splitlines())} lines")


def mask(v, head, tail):
    """Show enough to compare against the portal, never the whole value.

    Key ids and issuer ids are not secrets — the .p8 is — but GitHub masks any
    exact secret value in logs, so printing them verbatim yields "***" and tells
    nobody anything. A transformed value is not matched by that masking, so this
    is the only way to surface which values are actually in use.
    """
    if len(v) <= head + tail:
        return "?" * len(v)
    return f"{v[:head]}{'.' * (len(v) - head - tail)}{v[-tail:]}"


print()
print("Compare these against App Store Connect — Users and Access ->")
print("Integrations -> App Store Connect API:")
print(f"  ASC_KEY_ID     {mask(key_id, 3, 2)}   (the KEY ID column, also in AuthKey_<id>.p8)")
print(f"  ASC_ISSUER_ID  {mask(issuer, 8, 12)}   (the Issuer ID above the key list)")
print(f"  APPLE_TEAM_ID  {mask(team, 3, 2)}   (developer.apple.com -> Membership details)")
print()

if problems:
    print()
    for p in problems:
        print(f"::error::{p}")
    print("\nFix these in Settings -> Secrets and variables -> Actions.")
    sys.exit(1)

# ── The authoritative check ────────────────────────────────────────────────
try:
    import jwt
except ImportError:
    print("::error::pyjwt is not installed on the runner.")
    sys.exit(1)

def call(claims, label, path="/v1/apps?limit=200"):
    """Sign `claims` with the .p8 and GET `path`. Returns (ok, data, detail)."""
    tok = jwt.encode(
        {**claims, "iat": int(time.time()), "exp": int(time.time()) + 300,
         "aud": "appstoreconnect-v1"},
        p8, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
    )
    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com{path}",
        headers={"Authorization": f"Bearer {tok}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return True, json.load(r).get("data", []), label
    except urllib.error.HTTPError as e:
        return False, None, f"HTTP {e.code}: {e.read().decode()[:300]}"
    except Exception as e:  # noqa: BLE001
        return False, None, f"{type(e).__name__}: {e}"


# A Team Key signs with `iss` set to the issuer id. An INDIVIDUAL key omits
# `iss` entirely and sets `sub` to "user" instead. Trying only one form makes a
# key of the other type look like a wrong secret, so try both and say which fits.
ok, apps, detail = call({"iss": issuer}, "team")

if not ok:
    # An Apple KEY ID and an Apple TEAM ID are both 10 uppercase alphanumerics,
    # so nothing above can tell them apart and swapping the two secrets passes
    # every shape check while failing authentication exactly like a wrong key.
    # Probe it rather than leave the reader guessing.
    saved_kid = key_id
    key_id = team
    ok_swap, _, _ = call({"iss": issuer}, "team-swapped")
    key_id = saved_kid
    if ok_swap:
        print()
        print("::error::ASC_KEY_ID and APPLE_TEAM_ID are swapped.")
        print("  Authentication succeeds when APPLE_TEAM_ID's value is used as the")
        print("  key id, so the two secrets hold each other's values. Both are 10")
        print("  uppercase alphanumerics, which is why no shape check caught it.")
        print()
        print("  Fix: put the KEY ID (the key list's KEY ID column, and the id in")
        print("  the AuthKey_<id>.p8 filename) in ASC_KEY_ID, and the Team ID")
        print("  (developer.apple.com -> Membership details) in APPLE_TEAM_ID.")
        sys.exit(1)

    ok_ind, _, _ = call({"sub": "user"}, "individual")
    if ok_ind:
        print()
        print("::error::This is an INDIVIDUAL key. It has to be a TEAM key.")
        print("  The credentials are valid — they authenticate when signed the")
        print("  individual way (no iss claim, sub=user). But an individual key")
        print("  cannot reach the Provisioning endpoints, and creating the five")
        print("  distribution profiles on the runner is the entire reason this")
        print("  pipeline needs an API key at all. It would fail at Archive.")
        print()
        print("  Fix: App Store Connect -> Users and Access -> Integrations ->")
        print("  App Store Connect API -> the TEAM KEYS tab (not Individual Keys)")
        print("  -> + -> role App Manager. Then replace ASC_KEY_ID, ASC_ISSUER_ID")
        print("  and ASC_KEY_P8 with the new key's values.")
        sys.exit(1)

    print()
    if detail.startswith("HTTP 401"):
        print("::error::Apple rejected the key (401), signed either way.")
        print("  The secrets are well-formed but do not match a live key:")
        print("   1. ASC_KEY_ID is not the key id for this .p8 file.")
        print("   2. ASC_ISSUER_ID is a different UUID than the one above the key list.")
        print("   3. The key has been revoked.")
        print("   4. The key was created in the last few minutes and has not propagated.")
        print("      If you just made it, wait five minutes and re-run before changing anything.")
    elif detail.startswith("HTTP 403"):
        print("::error::Apple accepted the key but refused the request (403).")
        print("  The key's role is below App Manager. Users and Access ->")
        print("  Integrations -> App Store Connect API -> edit the key's access.")
    else:
        print("::error::Could not validate the credentials.")
    print(f"  response: {detail}")
    sys.exit(1)

print("ok    credentials authenticate against App Store Connect")

bundles = [a.get("attributes", {}).get("bundleId") for a in apps]
if WANT_BUNDLE_ID in bundles:
    print(f"ok    app record exists for {WANT_BUNDLE_ID}")

    # Reading apps and creating signing assets are different privileges, and
    # only the second one matters here: `-allowProvisioningUpdates` has to mint
    # a distribution certificate and five profiles on the runner. A key that
    # can list apps but not touch Certificates, Identifiers & Profiles fails
    # inside Xcode as "Authentication failed: Make sure a bearer token was
    # provided", which reads as a broken key rather than an under-privileged
    # one. Test the privilege that is actually needed.
    ok_prov, _, prov_detail = call({"iss": issuer}, "team", "/v1/certificates?limit=1")
    if ok_prov:
        print("ok    key can reach Certificates, Identifiers & Profiles")
        sys.exit(0)

    print()
    print("::error::The key authenticates but cannot reach the provisioning endpoints.")
    print("  It can list apps, so the credentials themselves are right — it simply")
    print("  lacks the access that `-allowProvisioningUpdates` needs to create the")
    print("  distribution certificate and the five provisioning profiles.")
    print()
    print("  Fix: give the key the ADMIN role. App Manager is enough to upload a")
    print("  build but not to manage Certificates, Identifiers & Profiles.")
    print("  App Store Connect -> Users and Access -> Integrations ->")
    print("  App Store Connect API -> Team Keys -> edit the key's access, or")
    print("  create a new key with Admin and replace the three key secrets.")
    print(f"  response: {prov_detail}")
    sys.exit(1)

print()
print(f"::error::Credentials work, but no app record exists for {WANT_BUNDLE_ID}.")
print("  A build can only be uploaded to an app that already exists.")
print("  App Store Connect -> Apps -> + -> New App, with that exact bundle id.")
if bundles:
    print("  Bundle ids this key CAN see:")
    for b in sorted(x for x in bundles if x):
        print(f"    {b}")
else:
    print("  This key currently sees no apps at all.")
sys.exit(1)
