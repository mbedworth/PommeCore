#!/usr/bin/env python3
"""Translate the App Store "What's New" text into the app's other 11 languages.

Why this exists separately from `translate_strings.py`: that script owns the
string catalog, where a unit of work is a UI key. Release notes are prose, and
the failure modes are different enough to need their own guard rails:

  * **An 8B model summarises a multi-paragraph prompt.** Handed all five
    paragraphs at once it returns three, or one. So each paragraph is its own
    request and the paragraph count is checked on the way back.
  * **The terms of art are the same ones**, and they fail the same way — `ja`
    once shipped "flood limits" as 「洪水制限」 (water-flood) in a published
    release note. PRESERVE_TERMS and the per-language glossary are imported
    from `translate_strings.py` rather than restated, so a term fixed there is
    fixed here.

Output is `docs/release_notes/<lang>.txt`, one file per language, ready to
paste into App Store Connect. English is written out too, so the folder is the
whole submission rather than eleven twelfths of it.

    python3 scripts/translate_release_notes.py            # all languages
    python3 scripts/translate_release_notes.py --lang de   # one
    python3 scripts/translate_release_notes.py --verify     # re-check, no calls
"""

import argparse
import re
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from translate_strings import (  # noqa: E402
    FORBIDDEN_ONLY,
    GLOSSARY,
    INFERENCE_URL,
    MODEL,
    PRESERVE_TERMS,
    TARGET_LANGUAGES,
)

SOURCE_PATH = "docs/release_notes/en.txt"
OUTPUT_DIR = "docs/release_notes"

# App Store Connect rejects a "What's New" longer than this.
MAX_CHARS = 4000


def paragraphs(text):
    return [p.strip() for p in text.strip().split("\n\n") if p.strip()]


def translate_paragraph(para, lang, lang_name):
    """One paragraph, one request. See the module docstring for why."""
    preserve = ", ".join(PRESERVE_TERMS)
    required = ""
    if lang in GLOSSARY:
        pairs = []
        for term, (req, _forbidden) in GLOSSARY[lang].items():
            pairs.append(f'"{term}" must be translated as "{req[0]}"')
        if pairs:
            required = "\n" + "\n".join(pairs)

    prompt = (
        f"Translate this App Store release note from English into {lang_name}.\n"
        f"It is read by owners of LoRa mesh radios, so it is technical prose, "
        f"not marketing copy. Keep the same tone: plain, direct, no exclamation "
        f"marks that are not in the source.\n"
        f"Leave these terms exactly as written, untranslated: {preserve}"
        f"{required}\n"
        f"Return ONLY the translation. No preamble, no quotes, no notes, no "
        f"alternatives. Keep it one paragraph.\n\n"
        f"{para}"
    )

    body = json.dumps({
        "model": MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.2},
    }).encode()

    req = urllib.request.Request(
        INFERENCE_URL, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            out = json.loads(resp.read()).get("response", "").strip()
    except urllib.error.URLError as e:
        return None, f"inference unreachable: {e}"

    # The model sometimes wraps its answer, or bolts on a note about the
    # terms it was told to preserve. Both have reached a catalog before.
    out = out.strip().strip('"').strip()
    if "\n" in out:
        lines = [l.strip() for l in out.split("\n") if l.strip()]
        # A legitimate answer is one paragraph; extra lines are commentary.
        out = lines[0] if len(lines) > 1 and len(lines[0]) > 40 else " ".join(lines)
    return out, None


def problems(original, translated, lang):
    """Structural and glossary checks. Mirrors translate_strings.py's rules."""
    issues = []
    if not translated:
        return ["empty"]
    if len(translated) < len(original) * 0.3:
        issues.append(f"suspiciously short ({len(translated)} vs {len(original)})")

    low = translated.lower()
    # A term in both lists is governed by the glossary, not by the preserve
    # rule: `flood` must stay "flood" in German ("Flooding") but becomes
    # "inondation" in French, so demanding the English token would reject the
    # correct answer.
    glossed = set(GLOSSARY.get(lang, {}))
    for term in PRESERVE_TERMS:
        if term.lower() in glossed:
            continue
        # Whole word on the source side, substring on the translation side. A
        # bare substring test on the source is wrong in both directions: "BLE"
        # matched "availa(ble)" and then demanded "ble" of every translation,
        # failing nine languages at once while passing French and Spanish by
        # accident ("disponible"). Translations stay a substring test so an
        # inflection still counts — German "Hop-Zahl" contains "hop".
        if not re.search(rf"\b{re.escape(term)}\b", original, re.IGNORECASE):
            continue
        if term.lower() not in low:
            issues.append(f'preserved term "{term}" missing')

    for term, (req, forbidden) in GLOSSARY.get(lang, {}).items():
        if term.lower() not in original.lower():
            continue
        if not any(r.lower() in low for r in req):
            issues.append(f'"{term}" missing required {req}')
        for bad in forbidden:
            if bad.lower() in low:
                issues.append(f'"{term}" used forbidden "{bad}"')

    for term in FORBIDDEN_ONLY:
        for bad in GLOSSARY.get(lang, {}).get(term, ([], []))[1]:
            if bad.lower() in low:
                issues.append(f'forbidden "{bad}"')

    return issues


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", action="append",
                    help="only this language (repeatable)")
    ap.add_argument("--verify", action="store_true",
                    help="re-check existing files, make no inference calls")
    args = ap.parse_args()

    if not os.path.exists(SOURCE_PATH):
        sys.exit(f"missing {SOURCE_PATH} — write the English notes first")

    with open(SOURCE_PATH) as f:
        english = f.read()
    source_paras = paragraphs(english)

    if len(english) > MAX_CHARS:
        sys.exit(f"English is {len(english)} chars, over the {MAX_CHARS} limit")
    print(f"English: {len(source_paras)} paragraphs, {len(english)} chars")

    langs = args.lang or list(TARGET_LANGUAGES)
    failures = 0

    for lang in langs:
        name = TARGET_LANGUAGES.get(lang)
        if not name:
            print(f"  {lang}: unknown language")
            failures += 1
            continue
        path = os.path.join(OUTPUT_DIR, f"{lang}.txt")

        if args.verify:
            if not os.path.exists(path):
                print(f"  {lang}: FAIL missing {path}")
                failures += 1
                continue
            with open(path) as f:
                got = paragraphs(f.read())
            if len(got) != len(source_paras):
                print(f"  {lang}: FAIL {len(got)} paragraphs, expected "
                      f"{len(source_paras)}")
                failures += 1
                continue
            issues = []
            for src, tr in zip(source_paras, got):
                issues += problems(src, tr, lang)
            if issues:
                print(f"  {lang}: FAIL {'; '.join(issues)}")
                failures += 1
            else:
                print(f"  {lang}: ok ({sum(len(p) for p in got)} chars)")
            continue

        out = []
        bad = []
        for i, para in enumerate(source_paras, 1):
            tr, err = translate_paragraph(para, lang, name)
            if err:
                sys.exit(f"{lang} paragraph {i}: {err}")
            issues = problems(para, tr, lang)
            if issues:
                bad.append(f"para {i}: {'; '.join(issues)}")
            out.append(tr)

        text = "\n\n".join(out) + "\n"
        if len(text) > MAX_CHARS:
            bad.append(f"{len(text)} chars, over the {MAX_CHARS} limit")

        os.makedirs(OUTPUT_DIR, exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

        if bad:
            print(f"  {lang}: written with problems — {'; '.join(bad)}")
            failures += 1
        else:
            print(f"  {lang}: ok ({len(text)} chars)")

    en_out = os.path.join(OUTPUT_DIR, "en.txt")
    if not os.path.exists(en_out):
        with open(en_out, "w") as f:
            f.write(english)

    if failures:
        print(f"\n{failures} language(s) need review before submitting.")
        return 1
    print("\nAll languages clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
