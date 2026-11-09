#!/usr/bin/env python3
"""Submit a filled-in App Store version for review, one platform at a time.

`asc_release.py` deliberately stops before this step, and this is the other
half of that pair: it creates a `reviewSubmission`, adds the version to it as
an item, and only then flips `submitted` to true.

Why a script rather than the web UI: the UI's `Add for Review` button animates
to "Processing" before any error comes back, which reads as success. On
2026-10-31 both of us believed iOS had been submitted while neither platform
had moved — the real blocker was an incomplete Age Ratings questionnaire, and
the version sat at PREPARE_FOR_SUBMISSION looking perfectly ready the whole
time. The API returns the error instead of a spinner, and `--check` reads
`appStoreState` back, which is the only answer that cannot be a spinner.

It refuses to write without `--submit`, and prints exactly what it would do
otherwise. It also refuses a version that is not actually ready: no build, a
build that is not VALID, or a locale missing its "What's New" would each be a
submission that comes straight back.

    python3 scripts/asc_submit.py --version 26.11.08             # dry run
    python3 scripts/asc_submit.py --version 26.11.08 --submit
    python3 scripts/asc_submit.py --version 26.11.08 --check

Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
"""

import argparse
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Reuse the credential handling, request plumbing, locale table and version
# lookup from asc_release.py rather than restating any of it. The locale map in
# particular is the thing a second copy would get wrong.
_spec = importlib.util.spec_from_file_location(
    "asc_release", os.path.join(HERE, "asc_release.py"))
_rel = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_rel)

APP_ID, PLATFORMS, LOCALES = _rel.APP_ID, _rel.PLATFORMS, _rel.LOCALES
get, request, find_version = _rel.get, _rel.request, _rel.find_version

# A submission in one of these states is already with Apple, or is waiting for
# the developer to act on something. Either way a second submission for the
# same platform is not what anyone wants, so we stop and say which it is.
OPEN_STATES = ("READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW",
               "UNRESOLVED_ISSUES")

SUBMITTABLE = ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED",
               "REJECTED", "METADATA_REJECTED", "INVALID_BINARY")


def readiness(version, platform):
    """Everything that has to be true before submitting, as (id, problems)."""
    record = find_version(version, platform)
    if not record:
        return None, [f"no {version} version record — run asc_release.py first"]

    version_id = record["id"]
    state = record["attributes"]["appStoreState"]
    problems = []
    if state not in SUBMITTABLE:
        problems.append(f"state is {state}, not submittable")

    build = (get(f"/appStoreVersions/{version_id}/build").get("data") or {})
    attrs = build.get("attributes")
    if not attrs:
        problems.append("no build attached")
    elif attrs.get("processingState") != "VALID":
        problems.append(f"build {attrs.get('version')} is "
                        f"{attrs.get('processingState')}, not VALID")

    rows = get(f"/appStoreVersions/{version_id}"
               f"/appStoreVersionLocalizations?limit=50")["data"]
    filled = {r["attributes"]["locale"]: (r["attributes"].get("whatsNew") or "")
              for r in rows}
    missing = [loc for loc in LOCALES.values() if not filled.get(loc, "").strip()]
    if missing:
        problems.append(f"\"What's New\" missing for {', '.join(sorted(missing))}")

    print(f"{platform}: {version} — {state}")
    print(f"  build: {attrs['version']} ({attrs['processingState']})"
          if attrs else "  build: NONE ATTACHED")
    print(f"  what's new: {len(LOCALES) - len(missing)}/{len(LOCALES)} locales")
    return version_id, problems


def open_submission(platform):
    """An existing submission for this platform, or None."""
    data = get(f"/reviewSubmissions?filter[app]={APP_ID}"
               f"&filter[platform]={platform}&limit=50")["data"]
    for record in data:
        if record["attributes"].get("state") in OPEN_STATES:
            return record
    return None


def submit(version_id, platform, version):
    created = request("POST", "/reviewSubmissions", {
        "data": {
            "type": "reviewSubmissions",
            "attributes": {"platform": platform},
            "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}}},
        }})
    submission_id = created["data"]["id"]
    print(f"  {platform}: created submission {submission_id}")

    request("POST", "/reviewSubmissionItems", {
        "data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {
                    "data": {"type": "reviewSubmissions", "id": submission_id}},
                "appStoreVersion": {
                    "data": {"type": "appStoreVersions", "id": version_id}}},
        }})
    print(f"  {platform}: added version {version} to it")

    # Only now does anything leave the account. Anything above this line is
    # still a draft submission that can simply be deleted.
    done = request("PATCH", f"/reviewSubmissions/{submission_id}", {
        "data": {"type": "reviewSubmissions", "id": submission_id,
                 "attributes": {"submitted": True}}})
    print(f"  {platform}: submitted — "
          f"{done['data']['attributes'].get('state')}")


def check(version):
    _rel.check(version)
    for platform in PLATFORMS:
        existing = open_submission(platform)
        print(f"{platform}: submission "
              + (f"{existing['id']} — {existing['attributes']['state']}"
                 if existing else "none open"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True,
                        help="marketing version, e.g. 26.11.08")
    parser.add_argument("--submit", action="store_true",
                        help="actually submit; without it this is a dry run")
    parser.add_argument("--check", action="store_true",
                        help="read the account back and change nothing")
    args = parser.parse_args()

    if args.check:
        check(args.version)
        return

    plan, blocked = {}, False
    for platform in PLATFORMS:
        version_id, problems = readiness(args.version, platform)
        existing = open_submission(platform) if version_id else None
        if existing:
            problems.append(f"submission {existing['id']} is already "
                            f"{existing['attributes']['state']}")
        for problem in problems:
            print(f"  BLOCKED: {problem}")
        if problems:
            blocked = True
        else:
            plan[platform] = version_id
            print("  ready to submit")

    if blocked:
        sys.exit("\nnothing submitted — resolve the blockers above first")

    if not args.submit:
        print(f"\ndry run. Would submit {args.version} for "
              f"{', '.join(plan)}. Re-run with --submit to do it.")
        return

    print()
    for platform, version_id in plan.items():
        submit(version_id, platform, args.version)

    print("\nreading the account back:")
    check(args.version)


if __name__ == "__main__":
    main()
