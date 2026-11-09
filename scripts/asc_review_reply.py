#!/usr/bin/env python3
"""Post or update a developer response to an App Store review.

**A review can hold exactly one developer response.** There is no thread, so
answering a review that already has a reply *replaces* that reply — the old
text is gone and the reader sees only the new one. The script says which it is
doing for every review before it does anything, and `--dry-run` prints the
whole plan without touching the account.

Responses are public and attached to the developer account, so this never runs
unprompted: it reads a plan file and requires `--post` to write.

    python3 scripts/asc_review_reply.py plan.json             # dry run
    python3 scripts/asc_review_reply.py plan.json --post      # actually send

Plan format — a list of {reviewId, responseId|null, nickname, body}.

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
_spec = importlib.util.spec_from_file_location(
    "check_build_arrival", os.path.join(HERE, "check_build_arrival.py"))
_cba = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cba)
BASE, token = _cba.BASE, _cba.token

# App Store Connect rejects a longer developer response.
MAX_CHARS = 5970


def send(method, path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{BASE}{path}", data=body, method=method,
        headers={"Authorization": f"Bearer {token()}",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{e.code} {method} {path}\n{e.read().decode()[:900]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("plan", help="JSON file of replies to post")
    ap.add_argument("--post", action="store_true",
                    help="actually publish; without it nothing is sent")
    args = ap.parse_args()

    with open(args.plan, encoding="utf-8") as handle:
        plan = json.load(handle)

    problems = [f"{e.get('nickname')}: {len(e['body'])} chars, over {MAX_CHARS}"
                for e in plan if len(e["body"]) > MAX_CHARS]
    if problems:
        sys.exit("too long:\n  " + "\n  ".join(problems))

    for entry in plan:
        verb = "REPLACE existing reply" if entry.get("responseId") else "post new reply"
        print(f"\n=== {entry['nickname']} — {verb} ({len(entry['body'])} chars)")
        print(entry["body"])

    if not args.post:
        print("\n--- dry run, nothing sent. Re-run with --post to publish. ---")
        return

    print()
    for entry in plan:
        # There is no edit. `customerReviewResponses` allows CREATE, DELETE and
        # GET_INSTANCE only — a PATCH returns 403 "does not allow 'UPDATE'". So
        # replacing a reply means destroying the old one first, and for a moment
        # the review carries no reply at all. If the create then fails, the old
        # text is gone for good, which is why `docs/review_replies_backup.json`
        # is written before any of this runs.
        if entry.get("responseId"):
            send("DELETE", f"/customerReviewResponses/{entry['responseId']}")
            print(f"  {entry['nickname']}: old reply deleted", flush=True)
        send("POST", "/customerReviewResponses", {
            "data": {"type": "customerReviewResponses",
                     "attributes": {"responseBody": entry["body"]},
                     "relationships": {"review": {
                         "data": {"type": "customerReviews",
                                  "id": entry["reviewId"]}}}}})
        print(f"  {entry['nickname']}: new reply posted")
    print("\nDone. Apple moderates responses before they appear publicly.")


if __name__ == "__main__":
    main()
