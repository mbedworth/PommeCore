#!/usr/bin/env python3
"""Create an App Store version record, attach its build, and upload "What's New".

Why a script rather than the web UI: the release notes exist in twelve
languages, which is twelve textareas per platform and twenty-four chances to
paste the wrong one. The locale mapping between `docs/release_notes/<lang>.txt`
and App Store Connect's own codes is the part a human gets wrong — `de` is
`de-DE` there but `it`, `ja`, `pl`, `cs` and `uk` are bare — so it is written
down once, here, instead of being re-derived under submission pressure.

It deliberately stops short of submitting for review. Creating a version record
and filling it in is reversible; a submission is not, and is the user's call.

    python3 scripts/asc_release.py --version 26.10.31 \
        --ios-build 20261031.001130 --macos-build 20261031.001220
    python3 scripts/asc_release.py --version 26.10.31 --check   # read back only

Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
"""

import argparse
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Reuse the credential handling, BASE url, token minting and — importantly —
# normalise(), which is the only correct way to compare a build number to the
# one App Store Connect stores. See the versioning note in CLAUDE.md.
_spec = importlib.util.spec_from_file_location(
    "check_build_arrival", os.path.join(HERE, "check_build_arrival.py"))
_cba = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cba)

BASE, APP_ID, token, normalise = _cba.BASE, _cba.APP_ID, _cba.token, _cba.normalise

# docs/release_notes/<lang>.txt  ->  App Store Connect locale.
# Read off the live version's localizations rather than guessed at.
LOCALES = {
    "cs": "cs", "de": "de-DE", "en": "en-US", "es": "es-ES",
    "fr": "fr-FR", "it": "it", "ja": "ja", "nl": "nl-NL",
    "pl": "pl", "pt": "pt-PT", "uk": "uk", "zh-Hans": "zh-Hans",
}

MAX_CHARS = 4000          # App Store Connect rejects a longer "What's New"
PLATFORMS = ("IOS", "MAC_OS")


def request(method, path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        path if path.startswith("http") else f"{BASE}{path}",
        data=body, method=method,
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:900]
        sys.exit(f"{e.code} {method} {path}\n{detail}")


def get(path):
    return request("GET", path)


def load_notes():
    """Read every locale's file, failing on anything that would be rejected."""
    notes, problems = {}, []
    for lang, locale in LOCALES.items():
        path = os.path.join(ROOT, "docs", "release_notes", f"{lang}.txt")
        if not os.path.exists(path):
            problems.append(f"{lang}: missing {path}")
            continue
        with open(path, encoding="utf-8") as handle:
            text = handle.read().strip()
        if not text:
            problems.append(f"{lang}: empty")
        elif len(text) > MAX_CHARS:
            problems.append(f"{lang}: {len(text)} chars, over the {MAX_CHARS} limit")
        else:
            notes[locale] = text
    if problems:
        sys.exit("release notes not ready:\n  " + "\n  ".join(problems))
    return notes


def find_version(version, platform):
    data = get(f"/apps/{APP_ID}/appStoreVersions?limit=50")
    for record in data["data"]:
        attrs = record["attributes"]
        if attrs["versionString"] == version and attrs["platform"] == platform:
            return record
    return None


def ensure_version(version, platform):
    existing = find_version(version, platform)
    if existing:
        print(f"  {platform}: version {version} already exists "
              f"({existing['attributes']['appStoreState']})")
        return existing["id"]
    created = request("POST", "/appStoreVersions", {
        "data": {
            "type": "appStoreVersions",
            "attributes": {"platform": platform, "versionString": version},
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}}},
        }})
    print(f"  {platform}: created version {version}")
    return created["data"]["id"]


def attach_build(version_id, platform, build_number):
    """Point the version at the build whose number matches, after normalising.

    Never compare these by string equality: App Store Connect parses
    CFBundleVersion as dot-separated integers and stores `20261031.001130` as
    `20261031.1130`.
    """
    wanted = normalise(build_number)
    # `preReleaseVersion` has to be named in fields[builds] as well as in
    # include: narrowing the fields without it drops the `relationships` object
    # from every row, so the platform cannot be read and the lookup dies on a
    # KeyError rather than simply not matching.
    url = (f"/builds?filter[app]={APP_ID}&limit=200&include=preReleaseVersion"
           "&fields[builds]=version,processingState,preReleaseVersion")
    build_id, state = None, None
    while url and not build_id:
        page = get(url)
        included = {item["id"]: item for item in page.get("included", [])}
        for build in page["data"]:
            pre = build["relationships"].get("preReleaseVersion", {}).get("data")
            build_platform = (included.get(pre["id"], {})
                              .get("attributes", {}).get("platform") if pre else None)
            if (normalise(build["attributes"].get("version") or "0") == wanted
                    and build_platform == platform):
                build_id = build["id"]
                state = build["attributes"].get("processingState")
                break
        url = page.get("links", {}).get("next")

    if not build_id:
        sys.exit(f"  {platform}: no build {build_number} found for this app")
    if state != "VALID":
        sys.exit(f"  {platform}: build {build_number} is {state}, not VALID")

    request("PATCH", f"/appStoreVersions/{version_id}/relationships/build",
            {"data": {"type": "builds", "id": build_id}})
    print(f"  {platform}: attached build {build_number}")


def upload_notes(version_id, platform, notes):
    """Fill in "What's New" per locale.

    A new version record arrives with localizations already copied from the
    previous one, so each locale is a PATCH of an existing row. A locale that
    is genuinely absent is created. Both cases are handled because which one
    applies depends on account state, not on anything in this repository.
    """
    existing = {row["attributes"]["locale"]: row["id"] for row in
                get(f"/appStoreVersions/{version_id}"
                    f"/appStoreVersionLocalizations?limit=50")["data"]}
    for locale, text in sorted(notes.items()):
        if locale in existing:
            request("PATCH",
                    f"/appStoreVersionLocalizations/{existing[locale]}",
                    {"data": {"type": "appStoreVersionLocalizations",
                              "id": existing[locale],
                              "attributes": {"whatsNew": text}}})
            action = "updated"
        else:
            request("POST", "/appStoreVersionLocalizations", {
                "data": {"type": "appStoreVersionLocalizations",
                         "attributes": {"locale": locale, "whatsNew": text},
                         "relationships": {"appStoreVersion": {
                             "data": {"type": "appStoreVersions",
                                      "id": version_id}}}}})
            action = "created"
        print(f"  {platform}: {locale} {action} ({len(text)} chars)")


def check(version):
    """Read the account back. The only report worth trusting is this one."""
    for platform in PLATFORMS:
        record = find_version(version, platform)
        if not record:
            print(f"{platform}: no {version} version record")
            continue
        version_id = record["id"]
        print(f"{platform}: {version} — {record['attributes']['appStoreState']}")
        build = get(f"/appStoreVersions/{version_id}/build")
        attrs = (build.get("data") or {}).get("attributes")
        print(f"  build: {attrs['version']} ({attrs['processingState']})"
              if attrs else "  build: NONE ATTACHED")
        rows = get(f"/appStoreVersions/{version_id}"
                   f"/appStoreVersionLocalizations?limit=50")["data"]
        filled = {r["attributes"]["locale"]: (r["attributes"].get("whatsNew") or "")
                  for r in rows}
        missing = [loc for loc in LOCALES.values() if not filled.get(loc, "").strip()]
        print(f"  what's new: {len(LOCALES) - len(missing)}/{len(LOCALES)} locales"
              + (f" — MISSING {', '.join(sorted(missing))}" if missing else ""))
        extra = sorted(set(filled) - set(LOCALES.values()))
        if extra:
            print(f"  note: {len(extra)} locale(s) on the record we do not "
                  f"translate: {', '.join(extra)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="marketing version, e.g. 26.10.31")
    parser.add_argument("--ios-build")
    parser.add_argument("--macos-build")
    parser.add_argument("--check", action="store_true",
                        help="read the account back and change nothing")
    args = parser.parse_args()

    if args.check:
        check(args.version)
        return

    if not (args.ios_build and args.macos_build):
        sys.exit("--ios-build and --macos-build are both required "
                 "(iOS and macOS share one app record and release together)")

    notes = load_notes()
    print(f"release notes: {len(notes)} locales, "
          f"longest {max(len(t) for t in notes.values())} chars")

    builds = {"IOS": args.ios_build, "MAC_OS": args.macos_build}
    for platform in PLATFORMS:
        version_id = ensure_version(args.version, platform)
        attach_build(version_id, platform, builds[platform])
        upload_notes(version_id, platform, notes)

    print("\nreading the account back:")
    check(args.version)
    print("\nNot submitted for review — that step is deliberately manual.")


if __name__ == "__main__":
    main()
