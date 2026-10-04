#!/usr/bin/env python3
"""
translate_strings.py — translate Localizable.xcstrings via local inference

Usage:
    python3 scripts/translate_strings.py [--lang fr,es,it,...] [--batch 10] [--dry-run]

Defaults to all 10 target languages if --lang is omitted.
Progress is saved after each batch so it's safe to interrupt and resume.
"""

import json
import re
import sys
import time
import argparse
import urllib.request
import urllib.error
from copy import deepcopy

XCSTRINGS_PATH = "Shared/Localizable.xcstrings"
INFERENCE_URL = "http://localhost:11434/api/generate"
MODEL = "aya-expanse:8b"

TARGET_LANGUAGES = {
    "de":      "German",
    "fr":      "French",
    "es":      "Spanish",
    "it":      "Italian",
    "nl":      "Dutch",
    "pt":      "Portuguese",
    "cs":      "Czech",
    "pl":      "Polish",
    "uk":      "Ukrainian",
    "ja":      "Japanese",
    "zh-Hans": "Simplified Chinese",
}

# Terms that must never be translated
PRESERVE_TERMS = [
    "PommeCore", "MeshCore", "MeshCoreKit", "LoRa", "BLE", "RSSI", "SNR",
    "dBm", "MHz", "kHz", "SF", "BW", "CR", "WiFi", "USB", "GPS", "LPP",
    "iCloud", "Siri", "Shortcuts", "TestFlight", "App Store", "iOS", "macOS",
    "watchOS", "SwiftUI", "Meshtastic", "Bluetooth", "JSON", "API", "URL",
    "SHA256", "PSK", "DFU", "OTA", "LPP", "Fresnel", "Cayenne", "ESP32",
    "nRF52", "GitHub", "CloudKit", "KeyValueStore", "Spotlight",
    # Mesh-routing jargon. These have everyday meanings that models reach for
    # first, and the result is confidently wrong rather than awkward: "flood"
    # (flood routing) came back as water flooding in German, Spanish, Czech and
    # Chinese — "Überschwemmungsbereich", "alcance de inundación", "rozsah
    # záplavy", "淹没范围". Treating them as technical terms is the fix; it is
    # also consistent with how LoRa, SNR and PSK are already handled.
    "flood", "flooding", "advert", "repeater", "mesh", "hop", "traceroute",
    # Feature name, not a phrase to translate. Left to the model it produced
    # "Jarro de Dicas" (a jar of *hints*), "Poteau de don" and "Tippotje".
    "Tip Jar",
]

SYSTEM_PROMPT = """You are a professional app translator. Translate app UI strings from English to {lang_name}.

Rules (strictly follow all):
1. Output ONLY a numbered list matching the input numbers. No extra text, no explanations.
2. Preserve ALL format specifiers exactly as-is: %@, %d, %lld, %1$@, %2$@, etc.
3. Never translate these technical terms: {preserve}.
4. Keep UI tone natural and concise — this is a mobile/desktop mesh radio app.
5. If a string is a single symbol, number, or untranslatable term, output it unchanged.
6. Maintain the same capitalization style (title case → title case, sentence case → sentence case).
7. Translate the WHOLE string. Keep every sentence, every numbered step, and every line break (\\n) exactly as in the source. Never summarise, never shorten, never drop a sentence.
8. Output the translation ONLY. Never repeat the English text, and never write "English - translation".

Output format — exactly like this (number, period, space, translation):
1. [translation]
2. [translation]
...
"""

def load_xcstrings(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)

def save_xcstrings(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")

def get_source_text(key, value):
    """Return the English source string to translate (prefer the key, which is plain English)."""
    return key

def get_translatable_keys(data, lang):
    """Return list of (key, source_text) for keys that need translation in this lang."""
    result = []
    for key, val in data["strings"].items():
        if val.get("shouldTranslate") is False:
            continue
        locs = val.get("localizations", {})
        if lang in locs:
            continue
        src = get_source_text(key, val)
        # Skip keys that are purely symbols or numbers
        if not src.strip() or re.fullmatch(r'[\d\s\.\-–—:/]+', src):
            continue
        result.append((key, src))
    return result

def run_inference(texts, lang_name, dry_run=False):
    """Send a batch of texts to the local inference endpoint and return translated list."""
    if dry_run:
        return [f"[{lang_name}] {t}" for t in texts]

    preserve_list = ", ".join(PRESERVE_TERMS)
    system = SYSTEM_PROMPT.format(lang_name=lang_name, preserve=preserve_list)

    numbered = "\n".join(f"{i+1}. {t}" for i, t in enumerate(texts))
    prompt = f"{system}\n\nTranslate these {len(texts)} English strings to {lang_name}:\n\n{numbered}"

    payload = json.dumps({
        "model": MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": 0.1,
            "num_predict": 2048,
        }
    }).encode("utf-8")

    req = urllib.request.Request(
        INFERENCE_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read())
            raw = result.get("response", "")
    except urllib.error.URLError as e:
        print(f"  ERROR calling inference endpoint: {e}")
        return None

    return parse_numbered_response(raw, len(texts), texts)

def parse_numbered_response(raw, expected, originals):
    """Parse '1. text\n2. text\n...' response into a list."""
    lines = raw.strip().splitlines()
    translations = {}
    for line in lines:
        m = re.match(r'^(\d+)\.\s*(.*)', line.strip())
        if m:
            idx = int(m.group(1)) - 1
            text = m.group(2).strip()
            # Strip surrounding brackets the model sometimes adds
            if text.startswith("[") and text.endswith("]"):
                text = text[1:-1].strip()
            if 0 <= idx < expected and text:
                translations[idx] = text

    result = []
    for i, orig in enumerate(originals):
        if i in translations:
            result.append(translations[i])
        else:
            # Fall back to original rather than leaving blank
            print(f"    WARNING: no translation for item {i+1}, using original")
            result.append(orig)
    return result

SPECIFIER_RE = re.compile(r"%(?:\d+\$)?(?:lld|[@dsflu])")


def specifier_signature(text):
    """The multiset of format specifiers in a string, position markers removed.

    `%1$@` and `%@` are the same specifier, so a translator that reorders
    arguments is fine. What is not fine is a different *number* of them.
    """
    return sorted(re.sub(r"%\d+\$", "%", m) for m in SPECIFIER_RE.findall(text))


def specifier_mismatch(key, value):
    """Why `value` is not a usable translation of `key`, or None if it is.

    A translation that drops a specifier renders without the data it was meant
    to show — Czech, Dutch and Polish each lost the device name from a login
    title this way. One that gains a specifier is worse: the extra placeholder
    has no argument behind it, so five Portuguese strings rendered a stray
    count. Both ship silently; nothing in the build or the catalog complains.
    """
    want, got = specifier_signature(key), specifier_signature(value)
    if want == got:
        return None
    if len(got) < len(want):
        return f"dropped {sorted(set(want) - set(got)) or want}"
    return f"added {sorted(set(got) - set(want)) or got}"


def translation_problem(key, value, lang=None):
    """Why `value` is not a usable translation of `key`, or None if it is.

    Three failure modes, all found in strings that had already shipped. Each is
    invisible at build time: the catalog is valid, the app compiles, and the
    wrong text simply appears.
    """
    spec = specifier_mismatch(key, value)
    if spec is not None:
        return spec

    # Structure loss. A key carrying numbered steps or paragraphs came back as
    # a single line, so the steps were summarised away: a troubleshooting
    # string with eight newlines was flattened to none in ten languages.
    # Newline count is the one structural property that holds across languages.
    want_nl = key.count("\n")
    got_nl = value.count("\n")
    if want_nl and got_nl != want_nl:
        return f"structure lost ({want_nl} newline(s) in source, {got_nl} here)"

    # Misalignment. A numbered reply whose items do not correspond to the
    # request writes each translation onto the wrong key, and the result is not
    # broken-looking — it is another string's perfectly good translation. The
    # French for "180 min" became "Allez dans Réglages → Bluetooth" this way,
    # because a multi-line key in the same batch was answered as several
    # numbered items and everything after it shifted. A single-line source whose
    # translation gained newlines is the cheapest reliable tell.
    if not want_nl and got_nl:
        return f"misaligned (source is one line, translation has {got_nl} newline(s))"

    # Echo. The model sometimes answers "source <sep> translation" and both
    # halves get stored, so a picker row reads "15 min - Quinze minutes" or
    # "180 min → 180 minutos".
    stripped = value.strip()
    for sep in (" - ", " — ", " – ", " → ", " / ", ": "):
        head, _, tail = stripped.partition(sep)
        if tail and head.strip().casefold() == key.strip().casefold():
            return f"echoes the English source before the translation ({sep.strip()!r})"

    # Trailing commentary. "60 min [soixante minutes]" — the source kept intact
    # with a gloss bolted on, which renders literally.
    for open_, close in (("[", "]"), ("(", ")")):
        if stripped.endswith(close) and open_ in stripped:
            head = stripped[:stripped.rindex(open_)].strip()
            if head.casefold() == key.strip().casefold():
                return f"appends a {open_}{close} gloss to the untranslated source"

    # Implausible expansion. A short label cannot honestly become a sentence,
    # so this catches both halves of the damage a misaligned batch does and the
    # model's own commentary leaking into the catalog. Real examples: "Cancel"
    # became "Ga naar Instellingen → Bluetooth", "Icon" became "Tap 'Forget
    # This Device'" in eight languages, and "Tip Jar" became "Tip Jar (non
    # traduit, terme anglais conservé)". Bounded to short sources, because a
    # long source expanding is normal prose variation.
    #
    # Sources of four characters or fewer are exempt. They are abbreviations
    # and units — "Avg", "SNR", "dBm" — and most languages have no short form,
    # so the honest translation is the spelled-out phrase: Ukrainian renders
    # "Avg" as "Середнє значення". Below five characters the ratio carries no
    # signal, and enforcing it only pushes correct translations out.
    if 5 <= len(key) <= 14 and len(stripped) > 2.5 * len(key) + 8:
        return (f"implausible expansion ({len(key)} chars in, {len(stripped)} out) — "
                "misaligned reply or model commentary")

    # Implausible contraction, the mirror image and the other half of a
    # misaligned batch: a sentence that became a fragment. "Can't Connect to
    # Radio?" was answered with 取消 — simply "Cancel" — and a paragraph about
    # deleting synced messages was answered with the RESET confirmation line in
    # three languages. Chinese and Japanese are genuinely far denser than
    # English, so they get their own floor.
    if len(key) >= 18:
        # 0.15 for CJK, not 0.22: Chinese really is that dense. "Communicate
        # Off-Grid" → 无网通信 is four characters and a good translation, so a
        # tighter floor would reject correct work.
        floor = 0.15 if lang in ("ja", "zh-Hans") else 0.40
        if len(stripped) < floor * len(key):
            return (f"implausible contraction ({len(key)} chars in, {len(stripped)} out) — "
                    "misaligned reply or a summarised answer")

    return None


def translate_multiline(key, lang_name, dry_run=False):
    """Translate a multi-line string one line at a time.

    Asked for a whole multi-line string, an 8B model summarises: a
    troubleshooting key with eight newlines and numbered steps came back as a
    single sentence in ten languages, every step gone. Splitting on newlines
    and translating the lines makes the structure impossible to lose — blank
    lines are preserved untouched and the result is rejoined at the original
    positions. Each line is short enough that the specifiers survive too.
    """
    lines = key.split("\n")
    idx = [i for i, l in enumerate(lines) if l.strip()]
    if not idx:
        return None
    out = run_inference([lines[i] for i in idx], lang_name, dry_run)
    if out is None or len(out) != len(idx):
        return None
    merged = list(lines)
    for i, translated in zip(idx, out):
        # A line whose own specifiers did not survive keeps its English, which
        # is better than a line that renders the wrong value.
        merged[i] = translated if specifier_mismatch(lines[i], translated) is None else lines[i]
    return "\n".join(merged)


def write_translations(data, keys_texts, translations, lang):
    """Write translations back into data dict.

    A translation that fails validation is not written at all. Leaving the key
    untranslated means it falls back to English, which is visibly incomplete
    but correct; writing it would ship text that silently omits, invents or
    duplicates content.
    """
    rejected = []
    for (key, _src), translated in zip(keys_texts, translations):
        if key not in data["strings"]:
            continue
        why = translation_problem(key, translated, lang)
        if why is not None:
            rejected.append((key, translated, why))
            continue
        val = data["strings"][key]
        if "localizations" not in val:
            val["localizations"] = {}
        val["localizations"][lang] = {
            "stringUnit": {
                "state": "translated",
                "value": translated,
            }
        }
    for key, translated, why in rejected:
        print(f"    REJECTED [{lang}] {why}: {key[:48]!r} -> {translated[:48]!r}")
    return len(rejected)

def translate_language(data, lang, lang_name, batch_size, dry_run, path):
    keys = get_translatable_keys(data, lang)
    total = len(keys)
    if total == 0:
        print(f"  {lang}: nothing to translate, skipping.")
        return

    print(f"\n=== {lang_name} ({lang}) — {total} strings ===")
    done = 0
    errors = 0
    rejected = 0

    # A multi-line key must never share a batch with anything else. Asked for
    # one, the model answers with its lines as separate numbered items, so the
    # reply has more items than the request and every translation after it
    # lands on the wrong key. That is how the French for "180 min" became
    # "Allez dans Réglages → Bluetooth". These go one at a time, line by line.
    multiline = [(k, s) for k, s in keys if "\n" in k]
    keys = [(k, s) for k, s in keys if "\n" not in k]
    total = len(keys)

    for key, src in multiline:
        print(f"  multi-line: {key[:40]!r}...", end="", flush=True)
        merged = translate_multiline(key, lang_name, dry_run)
        if merged is None:
            print(" FAILED")
            errors += 1
            continue
        rejected += write_translations(data, [(key, src)], [merged], lang)
        done += 1
        print(" done")
        if not dry_run:
            save_xcstrings(path, data)

    for batch_start in range(0, total, batch_size):
        batch = keys[batch_start:batch_start + batch_size]
        texts = [src for _, src in batch]
        batch_end = min(batch_start + batch_size, total)
        print(f"  [{batch_end}/{total}] translating batch...", end="", flush=True)

        translations = run_inference(texts, lang_name, dry_run)
        if translations is None:
            print(" FAILED, skipping batch")
            errors += 1
            time.sleep(2)
            continue

        rejected += write_translations(data, batch, translations, lang)
        done += len(batch)
        print(f" done")

        if not dry_run:
            save_xcstrings(path, data)

    # Retry whatever was rejected, one string per request. A batch gives the
    # model room to drift between items; alone, with only its own specifiers to
    # preserve, it usually gets them right on the second ask.
    if rejected and not dry_run:
        still = get_translatable_keys(data, lang)
        retry = list(still)
        if retry:
            print(f"  retrying {len(retry)} rejected string(s) individually...")
            for key, src in retry:
                # Multi-line strings go line by line; a whole-string retry just
                # reproduces the same summarising failure.
                if "\n" in key:
                    merged = translate_multiline(key, lang_name, dry_run)
                    out = [merged] if merged is not None else None
                else:
                    out = run_inference([src], lang_name, dry_run)
                if out:
                    write_translations(data, [(key, src)], out, lang)
            save_xcstrings(path, data)

    left = len(get_translatable_keys(data, lang))
    print(f"  Completed {done} strings, {errors} batch errors, "
          f"{rejected} rejected, {left} still untranslated")

def main():
    parser = argparse.ArgumentParser(description="Translate Localizable.xcstrings via local inference")
    parser.add_argument("--lang", default="", help="Comma-separated language codes (default: all)")
    parser.add_argument("--batch", type=int, default=10, help="Strings per inference request (default: 10)")
    parser.add_argument("--dry-run", action="store_true", help="Don't call inference endpoint, write dummy translations")
    parser.add_argument("--verify", action="store_true",
                        help="Check every existing translation's format specifiers and exit")
    parser.add_argument("--fix-invalid", action="store_true",
                        help="Delete translations whose specifiers don't match the source, so a "
                             "normal run re-translates them")
    args = parser.parse_args()

    if args.verify or args.fix_invalid:
        data = load_xcstrings(XCSTRINGS_PATH)
        bad = []
        for key, entry in data["strings"].items():
            for lang, loc in list((entry.get("localizations") or {}).items()):
                if lang == "en":
                    continue
                value = (loc.get("stringUnit") or {}).get("value")
                if value is None:
                    continue
                why = translation_problem(key, value, lang)
                if why is not None:
                    bad.append((lang, key, value, why))

        # Misalignment is only visible across the whole catalog. A translation
        # written onto the wrong key is some other key's perfectly good text,
        # so the tell is one value sitting under two sources that could not
        # plausibly share a translation. Sources of similar length are spared:
        # "TX Power"/"transmit power" and "Unblock"/"Unlock" legitimately
        # collide, whereas "180 min" and a line of Bluetooth instructions
        # cannot.
        seen = {}
        for key, entry in data["strings"].items():
            if entry.get("shouldTranslate") is False:
                continue
            for lang, loc in (entry.get("localizations") or {}).items():
                if lang == "en":
                    continue
                value = ((loc.get("stringUnit") or {}).get("value") or "").strip()
                if len(value) <= 6:
                    continue
                prev = seen.setdefault((lang, value), key)
                if prev == key:
                    continue
                short, long_ = sorted((prev, key), key=len)
                if len(long_) > 3 * max(len(short), 1) or (
                        len(short) <= 10 and len(long_) >= 25):
                    bad.append((lang, key, value,
                                f"collides with the translation of {short[:34]!r} — "
                                "almost certainly written onto the wrong key"))

        for lang, key, value, why in bad:
            print(f"  [{lang}] {why}: {key[:52]!r}\n        -> {value[:70]!r}")
        if args.fix_invalid:
            for lang, key, _value, _why in bad:
                del data["strings"][key]["localizations"][lang]
            save_xcstrings(XCSTRINGS_PATH, data)
            print(f"\nRemoved {len(bad)} invalid translation(s) — re-run without "
                  f"--fix-invalid to translate them again.")
        else:
            print(f"\n{len(bad)} invalid translation(s)."
                  if bad else "All format specifiers match.")
        sys.exit(1 if bad and not args.fix_invalid else 0)

    langs = {}
    if args.lang:
        for code in args.lang.split(","):
            code = code.strip()
            if code in TARGET_LANGUAGES:
                langs[code] = TARGET_LANGUAGES[code]
            else:
                print(f"Unknown language code: {code}")
                sys.exit(1)
    else:
        langs = TARGET_LANGUAGES

    data = load_xcstrings(XCSTRINGS_PATH)

    for lang, lang_name in langs.items():
        translate_language(data, lang, lang_name, args.batch, args.dry_run, XCSTRINGS_PATH)

    print("\nAll done.")

if __name__ == "__main__":
    main()
