#!/usr/bin/env python3
"""Add the English keys introduced by firmware 1.17 support to the string catalog.

Xcode extraction is not run as part of test_build.sh, so new UI strings are
registered here and then translated by scripts/translate_strings.py.
Idempotent — existing keys are left untouched.
"""

import json

CATALOG = "Shared/Localizable.xcstrings"

NEW_KEYS = [
    "Unknown node",
    "Requested data from this radio — has not identified itself yet",
    "Listen Before Transmit",
    "Last Boot",
]

with open(CATALOG) as f:
    data = json.load(f)

added = 0
for key in NEW_KEYS:
    if key in data["strings"]:
        print(f"already present: {key}")
        continue
    data["strings"][key] = {"extractionState": "manual", "localizations": {}}
    added += 1

with open(CATALOG, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"Added {added} keys")
