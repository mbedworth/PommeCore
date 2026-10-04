#!/usr/bin/env python3
"""Wait for uploaded builds to appear in App Store Connect, and say what they are.

`build-and-distribute.sh` printing "Upload succeeded" means the bytes left this
machine. It does not mean App Store Connect has accepted the build, and the two
are minutes apart on a good night. This is the check that closes that gap.

    ./scripts/check_build_arrival.py 20261003.233425 20261003.233514

With no arguments it reads the build numbers out of the project file, which
covers the single-platform case. A run that built both platforms stamps a
different number per archive and only the last one survives in the project
file, so pass both explicitly after an `all` build.

Exit status is 0 when every requested build is VALID, 1 on timeout, 2 on a
configuration problem.

Credentials come from `.asc.env` in the repository root (gitignored) plus the
private key in ~/.appstoreconnect/private_keys/.

## Why this exists in the form it does

The obvious version of this script asks for one page of builds and looks for
the version string. That is wrong, and quietly so: the app has more builds than
a single page returns, the endpoint does not sort by upload date, and it
refuses a `sort` parameter. A new build can therefore sit on page two while
page one looks complete. This cost an hour on 2026-10-03, twice, and both times
the symptom was a perfectly good build being reported as a failed upload.

So: page through every build via the paging cursor, and never conclude a build
is missing from a partial listing.
"""
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

try:
    import jwt
except ImportError:
    sys.exit("PyJWT is not installed — `pip3 install pyjwt`")

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENV_FILE = ROOT / ".asc.env"
PBXPROJ = ROOT / "PommeCore.xcodeproj" / "project.pbxproj"
BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_APP_ID = "6760626211"          # com.mbedworth.meshcore, not a secret
POLL_SECONDS = 60
DEFAULT_TIMEOUT_MIN = 30


def load_env():
    if not ENV_FILE.exists():
        sys.exit(f"missing {ENV_FILE} — needs ASC_KEY_ID and ASC_KEY_ISSUER")
    env = {}
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    for key in ("ASC_KEY_ID", "ASC_KEY_ISSUER"):
        if key not in env:
            sys.exit(f"{ENV_FILE} is missing {key}")
    return env


ENV = load_env()
KEY_ID = ENV["ASC_KEY_ID"]
ISSUER = ENV["ASC_KEY_ISSUER"]
APP_ID = ENV.get("ASC_APP_ID", DEFAULT_APP_ID)
KEY_PATH = pathlib.Path(
    os.path.expanduser(f"~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8"))
if not KEY_PATH.exists():
    sys.exit(f"missing private key at {KEY_PATH}")
PRIVATE_KEY = KEY_PATH.read_text()


def token():
    # Short-lived and minted per call, so a long poll never carries an expired
    # token into its last request.
    return jwt.encode(
        {"iss": ISSUER, "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
        PRIVATE_KEY, algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def call(path):
    req = urllib.request.Request(
        path if path.startswith("http") else f"{BASE}{path}",
        headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{e.code} GET {path}\n{e.read().decode()[:600]}")


def all_builds():
    """Every build for the app, as {version: (id, processingState)}.

    Pages to exhaustion. The endpoint caps a page below the number of builds
    this app has and will not accept a sort, so anything less than this is a
    listing that can omit the build you are looking for.
    """
    builds, cursor, pages = {}, None, 0
    while True:
        url = (f"/apps/{APP_ID}/builds?limit=200"
               "&fields[builds]=version,processingState,uploadedDate")
        if cursor:
            url += f"&cursor={cursor}"
        page = call(url)
        pages += 1
        for item in page.get("data", []):
            attrs = item["attributes"]
            builds[attrs["version"]] = (item["id"], attrs["processingState"])
        cursor = page.get("meta", {}).get("paging", {}).get("nextCursor")
        if not cursor:
            return builds, pages


def platform_of(build_id):
    data = call(f"/builds/{build_id}/preReleaseVersion").get("data")
    return data["attributes"]["platform"] if data else "?"


def versions_from_project():
    if not PBXPROJ.exists():
        return []
    found = re.findall(r"CURRENT_PROJECT_VERSION = ([0-9][0-9.]*)",
                       PBXPROJ.read_text())
    return sorted(set(found))


def main(argv):
    timeout_min = DEFAULT_TIMEOUT_MIN
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--timeout-min" and i + 1 < len(argv):
            timeout_min = int(argv[i + 1])
            i += 2
        elif argv[i] == "--once":
            timeout_min = 0
            i += 1
        else:
            args.append(argv[i])
            i += 1

    wanted = set(args) or set(versions_from_project())
    if not wanted:
        sys.exit("no build numbers given and none found in the project file")
    print(f"waiting for: {', '.join(sorted(wanted))}")

    deadline = time.time() + timeout_min * 60
    while True:
        builds, pages = all_builds()
        seen = {v: builds[v] for v in wanted if v in builds}
        missing = sorted(wanted - set(seen))
        stamp = time.strftime("%H:%M:%S")
        if seen:
            summary = ", ".join(f"{v}={seen[v][1]}" for v in sorted(seen))
        else:
            summary = "none visible yet"
        print(f"  {stamp}  [{pages} page(s)] {summary}"
              + (f"  missing: {', '.join(missing)}" if missing else ""))

        if not missing and all(state == "VALID" for _, state in seen.values()):
            print("\nAll builds VALID:")
            for v in sorted(seen):
                build_id, _ = seen[v]
                print(f"  {v}  {platform_of(build_id):7} id={build_id}")
            return 0

        if time.time() >= deadline:
            print("\nTimed out.")
            for v in sorted(wanted):
                print(f"  {v}: {seen.get(v, ('—', 'NOT PRESENT'))[1]}")
            print("\nNot present does not always mean the upload failed — but a"
                  "\ncomplete listing was searched, so it is not a paging"
                  "\nartefact either. Check the ASC activity page before"
                  "\nre-uploading, and never re-upload on a partial listing.")
            return 1

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
