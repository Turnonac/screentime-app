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

token = jwt.encode(
    {
        "iss": issuer,
        "iat": int(time.time()),
        "exp": int(time.time()) + 300,
        "aud": "appstoreconnect-v1",
    },
    p8,
    algorithm="ES256",
    headers={"kid": key_id, "typ": "JWT"},
)

req = urllib.request.Request(
    "https://api.appstoreconnect.apple.com/v1/apps?limit=200",
    headers={"Authorization": f"Bearer {token}"},
)

try:
    with urllib.request.urlopen(req, timeout=30) as r:
        apps = json.load(r).get("data", [])
except urllib.error.HTTPError as e:
    body = e.read().decode()[:400]
    print()
    if e.code == 401:
        print("::error::Apple rejected the key (401). The secrets are well-formed but not valid together.")
        print("  Most likely, in order:")
        print("   1. ASC_KEY_ID and ASC_ISSUER_ID come from different keys, or are swapped.")
        print("   2. The .p8 is not the file belonging to this ASC_KEY_ID.")
        print("   3. The key has been revoked.")
        print("  A .p8 downloads exactly once — if it is the wrong one, revoke the key and make another.")
    elif e.code == 403:
        print("::error::Apple accepted the key but refused the request (403).")
        print("  The key's role is too low. It needs App Manager:")
        print("  Users and Access -> Integrations -> App Store Connect API.")
    else:
        print(f"::error::App Store Connect returned HTTP {e.code}.")
    print(f"  response: {body}")
    sys.exit(1)
except Exception as e:  # noqa: BLE001 — any failure here is fatal and worth naming
    print(f"::error::Could not reach App Store Connect: {type(e).__name__}: {e}")
    sys.exit(1)

print("ok    credentials authenticate against App Store Connect")

bundles = [a.get("attributes", {}).get("bundleId") for a in apps]
if WANT_BUNDLE_ID in bundles:
    print(f"ok    app record exists for {WANT_BUNDLE_ID}")
    sys.exit(0)

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
