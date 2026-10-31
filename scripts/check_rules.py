#!/usr/bin/env python3
"""Deterministic checks for the project's critical development rules.

Each check prints nothing when the tree is clean, so any output is a finding.
That is the whole design: a check that always prints something teaches you to
stop reading it.

Findings come in two tiers:

  FAIL  a Critical Rule is broken. Exits 1.
  WARN  a design-principle or known-debt issue. Does not exit 1.

Pre-existing debt lives in scripts/rule_baseline.txt (one `path:line  # note`
per line). A baselined site is silent; a *new* one at a different line is not.
That makes the file a ratchet rather than a wall of noise. Removing a line from
the baseline is how you declare something fixed.

Usage:
    python3 scripts/check_rules.py            # whole tree
    python3 scripts/check_rules.py --changed  # only files changed vs main
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE_PATH = ROOT / "scripts" / "rule_baseline.txt"

findings: list[tuple[str, str, str, str]] = []  # (tier, rule, location, message)


def load_baseline() -> set[str]:
    if not BASELINE_PATH.exists():
        return set()
    out = set()
    for line in BASELINE_PATH.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(line)
    return out


BASELINE = load_baseline()


def report(tier: str, rule: str, path, line: int, message: str) -> None:
    rel = str(pathlib.Path(path).relative_to(ROOT)) if pathlib.Path(path).is_absolute() else str(path)
    loc = f"{rel}:{line}"
    if loc in BASELINE:
        return
    findings.append((tier, rule, loc, message))


def swift_files(subdirs: list[str]) -> list[pathlib.Path]:
    out = []
    for d in subdirs:
        out.extend(sorted((ROOT / d).rglob("*.swift")))
    return out


def lines_of(path: pathlib.Path) -> list[str]:
    return path.read_text(errors="replace").splitlines()


# --------------------------------------------------------------------------
# Rule 15 + 17 — sheet frames must be platform-guarded
# --------------------------------------------------------------------------
def check_sheet_frames() -> None:
    """`.frame(minWidth:)` outside a macOS/Catalyst `#if`.

    Tracks `#if` / `#elseif` / `#else` / `#endif` nesting so the `#else`
    branch of a macOS guard counts as *un*guarded — that branch is iPhone,
    where a sheet should take its natural full width.
    """
    for path in swift_files(["Shared", "watchOS"]):
        stack: list[bool] = []
        for i, line in enumerate(lines_of(path), 1):
            s = line.strip()
            if s.startswith("#if"):
                stack.append("macOS" in s or "macCatalyst" in s)
            elif s.startswith("#elseif"):
                if stack:
                    stack[-1] = "macOS" in s or "macCatalyst" in s
            elif s.startswith("#else"):
                if stack:
                    stack[-1] = False
            elif s.startswith("#endif"):
                if stack:
                    stack.pop()
            elif ".frame(minWidth:" in line and not any(stack):
                # A regular-width check satisfies the rule on its own: the
                # rule is about the *adapted* (compact) presentation, and a
                # popover that stays floating legitimately needs a width.
                #
                # An idiom check used to be accepted here too. It is not any
                # more — idiom and presentation width disagree on iPad Slide
                # Over and on unfolded foldables, so it is not evidence of
                # anything about width. `check_idiom_layout` flags it instead.
                if re.search(r"horizontalSizeClass\s*==\s*\.regular", line):
                    continue
                report("FAIL", "15/17", path, i,
                       "`.frame(minWidth:)` is not inside a macOS/Catalyst #if — "
                       "an iPhone sheet should use its natural full width")


# --------------------------------------------------------------------------
# Rule 18 — Text() must not be handed a String
# --------------------------------------------------------------------------
# Only names that say the value is a human-readable phrase. `Name` and
# `Description` are deliberately absent: `Text(contact.displayName)` and
# `Text(presetName)` carry user or radio data, which is correctly a String and
# must not be localized. Flagging those trained the eye to skip the output.
STRING_VAR_IN_TEXT = re.compile(
    r"\bText\(\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)?"
    r"([a-z][A-Za-z0-9_]*(?:Message|Error|error|err|Text|Label|Title))\b"
    r"\s*(?:\?\?\s*\"[^\"]*\"\s*)?\)"
)


def check_text_takes_string() -> None:
    """`Text(someStringVariable)` bypasses the string catalog.

    A `String` holding an English literal still renders in English in every
    locale, and nothing warns about it. Only variables whose names say they
    carry a message are matched — a broader pattern would flag every
    `Text(contact.name)`, which is user data and correctly a String.
    """
    for path in swift_files(["Shared", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            m = STRING_VAR_IN_TEXT.search(line)
            if m:
                report("WARN", "18", path, i,
                       f"Text() is given the String `{m.group(1)}` — it bypasses the "
                       "string catalog; use LocalizedStringKey or String(localized:)")


def check_localized_params() -> None:
    """A parameter that feeds `Text(...)` must be `LocalizedStringKey`.

    "Feeds Text()" is checked, not assumed: the same name must actually appear
    inside a `Text(...)` in the same file. Without that cross-check this
    flagged every `sendCommand(_:label:)` and log label in the stores, which
    are correctly `String` and never reach the UI.
    """
    pattern = re.compile(r"\b(label|title|subtitle|badge|footer|header)\s*:\s*String\b")
    for path in swift_files(["Shared/Views", "watchOS"]):
        text = path.read_text(errors="replace")
        for i, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            m = pattern.search(line)
            if not m or "LocalizedStringKey" in line:
                continue
            name = m.group(1)
            if re.search(rf"Text\(\s*{name}\b", text):
                report("WARN", "18", path, i,
                       f"`{name}: String` reaches a Text() in this file — it must be "
                       "LocalizedStringKey (rule 18)")


# --------------------------------------------------------------------------
# Rule 19 — optional LocalizedStringKey uses nil, not ""
# --------------------------------------------------------------------------
def check_lsk_isempty() -> None:
    for path in swift_files(["Shared", "watchOS"]):
        text = lines_of(path)
        for i, line in enumerate(text, 1):
            if "LocalizedStringKey" in line and ".isEmpty" in line:
                report("FAIL", "19", path, i,
                       "LocalizedStringKey has no `isEmpty` — use `if let`")


# --------------------------------------------------------------------------
# Rule 4 — BLE: never clear connectedPeripheral on an unexpected disconnect
# --------------------------------------------------------------------------
def check_ble_disconnect() -> None:
    """Flag `connectedPeripheral = nil` inside didDisconnectPeripheral.

    Clearing it there defeats auto-reconnect: the peripheral reference is what
    `central.connect(peripheral)` needs. Only a user-initiated disconnect may
    clear it, so a guard mentioning intent must be on or near the line.
    """
    path = ROOT / "Packages/MeshCoreKit/Sources/MeshCoreKit/BLE/BLEManager.swift"
    if not path.exists():
        return
    lines = lines_of(path)
    start = next((i for i, l in enumerate(lines) if "didDisconnectPeripheral" in l), None)
    if start is None:
        return

    # The violation is not "cleared in this delegate" — three of the sites here
    # clear it legitimately (pairing failure, reconnect timeout, user-initiated
    # disconnect) and flagging all of them is noise. The violation is clearing
    # it while auto-reconnect is still *expected to continue*, because that
    # throws away the reference `central.connect(peripheral)` needs. So the
    # signal is a clear with no nearby statement standing it down.
    stand_down = re.compile(
        r"shouldAutoReconnect\s*=\s*false|User-initiated|user-initiated|"
        r"pairingFailed|reconnect timeout|cancelPeripheralConnection")
    for i in range(start, len(lines)):
        if "connectedPeripheral = nil" not in lines[i]:
            continue
        window = "\n".join(lines[max(0, i - 14):i + 4])
        if not stand_down.search(window):
            report("FAIL", "4", path, i + 1,
                   "connectedPeripheral cleared while auto-reconnect is still live — "
                   "central.connect(peripheral) needs that reference (rule 4)")


# --------------------------------------------------------------------------
# Rule 5 — store the message before sending the frame
# --------------------------------------------------------------------------
def check_store_before_send() -> None:
    """In a function that both stores and sends, the store must come first.

    The BLE response can arrive before the store write, so a send-then-store
    ordering loses the ACK for a message that is not in the store yet.
    """
    path = ROOT / "Shared/Stores/MessageStoreManager.swift"
    if not path.exists():
        return
    lines = lines_of(path)
    func_start, func_name = None, ""
    send_at = None
    for i, line in enumerate(lines, 1):
        if re.match(r"\s*(?:@\w+\s+)*(?:public |private |internal )?func ", line):
            func_start, send_at = i, None
            func_name = line.strip()
        if func_start is None:
            continue
        if send_at is None and re.search(r"sendCommand|buildSendTxt|buildSendChannel", line):
            send_at = i
        elif send_at is not None and re.search(r"\bstoreMessage\(|messages\[[^\]]+\]\?\.append|appendMessage\(", line):
            report("FAIL", "5", path, i,
                   f"message stored after the frame was sent at line {send_at} "
                   f"(in `{func_name[:60]}`) — the response can beat the store write")
            send_at = None


# --------------------------------------------------------------------------
# Rules 7 + 14 — endianness
# --------------------------------------------------------------------------
def check_endianness() -> None:
    """LPP payloads are big-endian; everything else in the protocol is little.

    Reading an LPP field with a little-endian helper byte-swaps the value, and
    the result is a plausible-looking wrong number rather than an error.
    """
    proto = ROOT / "Packages/MeshCoreKit/Sources/MeshCoreKit/Protocol"
    if not proto.exists():
        return
    for path in sorted(proto.rglob("*.swift")):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            if re.search(r"\blpp|cayenne|telemetry", line, re.I) and re.search(
                    r"readUInt16\(|readInt16\(|readUInt32\(", line):
                report("FAIL", "14", path, i,
                       "LPP/telemetry field read with a little-endian helper — "
                       "use readUInt16BE()/readInt16BE()/readUInt32BE()")


# --------------------------------------------------------------------------
# Rule 8 — channel PSK is 16 bytes
# --------------------------------------------------------------------------
def check_psk_length() -> None:
    for path in swift_files(["Shared", "Packages/MeshCoreKit/Sources"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            if re.search(r"(secret|psk)\w*\.count\s*==\s*32", line, re.I) or \
               re.search(r"count:\s*32\s*\)[^\n]*\b(secret|psk)", line, re.I):
                report("FAIL", "8", path, i,
                       "channel secret/PSK is 16 bytes, not 32 (the name field is 32)")


# --------------------------------------------------------------------------
# Rules 1 + 2 — persisted Codable types need a tolerant decoder
# --------------------------------------------------------------------------
def check_codable_decoders() -> None:
    """A persisted Codable type decoded as part of an array needs init(from:).

    Without one, a single record written by an older build fails to decode and
    takes the whole array with it — which is how a backup becomes unreadable.
    """
    for path in swift_files(["Packages/MeshCoreKit/Sources/MeshCoreKit/Models",
                             "Shared/Models"]):
        text = path.read_text(errors="replace")
        if "Codable" not in text:
            continue
        if "init(from decoder" in text or "init(from:" in text:
            continue
        m = re.search(r"(?:struct|final class|class)\s+(\w+)[^\n{]*Codable", text)
        if m:
            report("WARN", "1/2", path, text[:m.start()].count("\n") + 1,
                   f"`{m.group(1)}` is Codable with no init(from:) — one short record "
                   "from an older build discards the whole array")


# --------------------------------------------------------------------------
# Design principle 4 — formatting helpers live in Theme.swift only
# --------------------------------------------------------------------------
def check_duplicate_formatters() -> None:
    """Formatting belongs in Theme.swift / GeoMath, and a copy of it anywhere else.

    This used to match a fixed list of five names, so it could only catch a
    second copy of a formatter someone had already thought to list. It could
    not see a *new* one: `formatBW` sat in three views for months, and the
    three had already stopped matching — two guarded `bw >= 1` and the third
    did not. A check that only knows yesterday's duplicates is not a check
    against duplication.

    Now it collects every `format*` in the tree and reports two things: one
    defined outside the two homes that those homes already provide, and one
    defined in more than one file at all, whatever it is called.
    """
    homes = {"Shared/App/Theme.swift",
             "Packages/MeshCoreKit/Sources/MeshCoreKit/GeoMath/GeoMath.swift"}
    decl = re.compile(r"\bfunc\s+(format[A-Z]\w*)\s*[(<]")
    where: dict[str, list[tuple[pathlib.Path, int]]] = {}
    for path in swift_files(["Shared", "Packages/MeshCoreKit/Sources", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            m = decl.search(line)
            if m:
                where.setdefault(m.group(1), []).append((path, i))

    shared = {n for n, sites in where.items()
              if any(str(p.relative_to(ROOT)) in homes for p, _ in sites)}

    for name, sites in sorted(where.items()):
        outside = [(p, i) for p, i in sites
                   if str(p.relative_to(ROOT)) not in homes]
        if name in shared:
            for p, i in outside:
                report("WARN", "DP4", p, i,
                       f"`{name}` duplicates a Theme.swift/GeoMath helper")
        elif len({p for p, _ in outside}) > 1:
            others = ", ".join(sorted({str(p.relative_to(ROOT)) for p, _ in outside}))
            for p, i in outside:
                report("WARN", "DP4", p, i,
                       f"`{name}` is defined in more than one file ({others}) — "
                       "move it to Theme.swift")


# --------------------------------------------------------------------------
# Design principle 5 — never log key material
# --------------------------------------------------------------------------
def check_secret_logging() -> None:
    log_call = re.compile(r"\b(print|NSLog|debugPrint|os_log|logger\.\w+|\.log)\s*\(")
    secret = re.compile(r"\b(secret|psk|privateKey|password|passphrase|guestPassword)\w*", re.I)
    # Logging *about* a secret is fine and common: a byte count, a present/none
    # marker, or the words "no secret" in a literal. Only an interpolation that
    # would render the bytes themselves is a leak, so look inside each
    # `\(...)` rather than at the whole line.
    safe = re.compile(r"\.count|\.isEmpty|!=\s*nil|==\s*nil|\?\?|present|none|redact", re.I)
    for path in swift_files(["Shared", "Packages/MeshCoreKit/Sources", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//") or not log_call.search(line):
                continue
            for interp in re.findall(r"\\\(([^()]*(?:\([^()]*\)[^()]*)*)\)", line):
                if secret.search(interp) and not safe.search(interp):
                    report("FAIL", "DP5", path, i,
                           f"`{interp.strip()[:50]}` interpolated into a log — log a "
                           "length or a redaction, never key material")
                    break


# --------------------------------------------------------------------------
# Deployment-target audit (the widget shipped at 26.4 for five months)
# --------------------------------------------------------------------------
EXPECTED_TARGETS = {"IPHONEOS": "18.0", "MACOSX": "15.0", "WATCHOS": "11.0"}


def check_deployment_targets() -> None:
    """Every target must share one floor per platform.

    A floor that is wrong from inception produces no warning and no build
    failure: the widget extension was born at an iOS floor of 26.4 and was
    invisible to every user below it for five months.
    """
    pbx = ROOT / "PommeCore.xcodeproj/project.pbxproj"
    if not pbx.exists():
        return
    seen: dict[str, set[str]] = {}
    for i, line in enumerate(lines_of(pbx), 1):
        m = re.search(r"(IPHONEOS|MACOSX|WATCHOS)_DEPLOYMENT_TARGET = ([0-9.]+)", line)
        if m:
            seen.setdefault(m.group(1), set()).add(m.group(2))
            if m.group(2) != EXPECTED_TARGETS[m.group(1)]:
                report("FAIL", "DEPLOY", pbx, i,
                       f"{m.group(1)}_DEPLOYMENT_TARGET = {m.group(2)}, expected "
                       f"{EXPECTED_TARGETS[m.group(1)]} — every target shares one floor")


# --------------------------------------------------------------------------
# Standing rule — no AI tool references anywhere
# --------------------------------------------------------------------------
# Automatic grammar agreement markup, e.g. `^[\(n) hop](inflect: true)`.
INFLECT_MARKUP = re.compile(r'\^\[[^\]]*\]\(inflect:')
# The same markup inside a String(localized:) — where it is never applied.
INFLECT_IN_STRING = re.compile(r'String\(localized:\s*"\^\[[^"]*\]\(inflect:')


def check_inflection_markup() -> None:
    """Inflection markup belongs to `Text`, and a hop count belongs to Theme.

    Two faults, both found on hardware 2026-10-30 and neither visible to a
    build:

    **`String(localized:)` does not inflect.** `Text` applies
    `^[…](inflect: true)` when it draws; `String(localized:)` hands the markup
    straight back. Two call sites did the latter, so the markup rendered
    literally — one of them into a Quick Reply *transmitted over the air*, and
    a recipient on another client read `^[3 hop](inflect: true)`. A string that
    leaves the device is the worst possible place to discover this.

    **Ten call sites wrote the hop markup themselves.** Fixing one fixed a
    tenth of the bug. `hopCountLabel(_:)` and `formatHopCount(_:)` in
    `Theme.swift` are now the only places that decide how a hop count reads,
    per design principle 4 and the "new formatting helper" rule in CLAUDE.md.
    Other inflected nouns appear once each and are left alone — this forbids
    duplication, not inflection.
    """
    theme = ROOT / "Shared" / "App" / "Theme.swift"
    for path in swift_files(["Shared", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            if INFLECT_IN_STRING.search(line):
                report("FAIL", "18", path, i,
                       "inflection markup inside String(localized:) — it is "
                       "applied by Text when drawing, never here, so this "
                       "renders the markup literally. Use formatHopCount() or "
                       "an explicitly pluralised key")
            if (INFLECT_MARKUP.search(line) and " hop]" in line
                    and path.resolve() != theme.resolve()):
                report("FAIL", "DP4", path, i,
                       "a hop count is spelled out here — Theme.swift's "
                       "hopCountLabel()/formatHopCount() are the one place "
                       "that decides how it reads")


# A UI literal with its interpolations flattened, so `\(hopCount)` and
# `\(hops.count)` are recognised as the same shape.
REPEATED_LIT = re.compile(r'(?:Text|String)\(\s*(?:localized:\s*)?"((?:[^"\\]|\\.)+)"')
INTERPOLATION = re.compile(r'\\\([^)]*\)')


def check_repeated_ui_literals() -> None:
    """The same built string, written out in three or more files.

    `check_duplicate_formatters` looks for a duplicated *function*. Duplication
    rarely announces itself that way: it is far more often one expression
    inlined at every call site, which is invisible to a check that only reads
    declarations. `^[\\(n) hop](inflect: true)` was written at **ten** sites
    across five files, and the copies had already diverged — two resolved it
    through `String(localized:)`, where the inflection is never applied, so
    those rendered the markup literally and one transmitted it over the air.
    Nothing objected, because no function had been duplicated.

    Only literals that carry interpolation are reported, and only from three
    files up. Short shared words — `Status`, `Connected`, a bullet — are
    repeated legitimately all over a UI and are not what this is for; a literal
    with a value substituted into a structure is a formatting decision, and a
    formatting decision belongs in one place (design principle 4, and the "new
    formatting helper" rule in CLAUDE.md).

    `WARN`, not `FAIL`: whether two identical strings are one concept or a
    coincidence is a judgement a script should inform, not make.
    """
    where: dict[str, set[pathlib.Path]] = {}
    for path in swift_files(["Shared", "watchOS"]):
        for line in lines_of(path):
            if line.lstrip().startswith("//"):
                continue
            for m in REPEATED_LIT.finditer(line):
                norm = INTERPOLATION.sub("{}", m.group(1))
                if "{}" not in norm or len(norm) < 10:
                    continue
                where.setdefault(norm, set()).add(path)

    for norm, paths in sorted(where.items()):
        if len(paths) < 3:
            continue
        first = sorted(paths)[0]
        report("WARN", "DP4", first, 1,
               f'"{norm[:50]}" is written out in {len(paths)} files — a value '
               "substituted into a structure is a formatting decision, and it "
               "belongs in one helper in Theme.swift")


STATUS_SWITCH = re.compile(r"\bswitch\s+[A-Za-z_][\w.]*\.status\s*\{")


def check_status_switch_exhaustive() -> None:
    """A switch on a message status must not fall back to `default:`.

    Critical Rule 6 says a status is a claim about reality. The model obeyed it:
    a channel message sent with no transport is marked `.failed`. The channel
    bubble then drew it as a plain tick, because its status switch handled
    `.sending` and `.repeated` and sent **everything else** — `.failed`,
    `.retrying`, `.flooding` — to a `default:` that rendered a checkmark. The
    rule was honoured in the data and broken in the one place the user can see,
    and a tester with Bluetooth switched off watched a message claim it had been
    sent. Found on hardware 2026-10-30, by turning Bluetooth off.

    Exhaustiveness is what makes this class of bug a build error instead of a
    screenshot: add a status, and every site that renders one stops compiling
    until it has decided what the new one looks like.
    """
    for path in swift_files(["Shared", "watchOS"]):
        src = lines_of(path)
        for i, line in enumerate(src):
            if not STATUS_SWITCH.search(line) or line.lstrip().startswith("//"):
                continue
            depth = 0
            for j in range(i, len(src)):
                depth += src[j].count("{") - src[j].count("}")
                if j > i and src[j].strip().startswith("default:"):
                    report("FAIL", "6", path, j + 1,
                           "a message status switch falls back to `default:` — "
                           "every status it has not thought about renders as "
                           "whatever that branch draws, which is how `.failed` "
                           "came to display a checkmark. Handle every case")
                    break
                if depth <= 0 and j > i:
                    break


def check_no_tool_references() -> None:
    needle = re.compile(r"co-authored-by:\s*claude|claude\.ai/code|generated with \[claude|"
                        r"\bcopilot\b|\bchatgpt\b", re.I)
    roots = ["Shared", "Packages", "scripts", "docs", "watchOS", "iOS", "macOS"]
    for d in roots:
        base = ROOT / d
        if not base.exists():
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file() or path.suffix not in {
                    ".swift", ".sh", ".py", ".md", ".plist", ".json", ".yml"}:
                continue
            if path.resolve() == pathlib.Path(__file__).resolve():
                continue
            for i, line in enumerate(lines_of(path), 1):
                if needle.search(line):
                    report("FAIL", "NO-REF", path, i,
                           "reference to an AI tool — not permitted anywhere in the repo")


# --------------------------------------------------------------------------
# Rule 18 (catalog side) — a UI literal that never reached the catalog
# --------------------------------------------------------------------------

CATALOG_PATH = ROOT / "Shared" / "Localizable.xcstrings"

# `LabeledContent`, `Toggle`, `Picker` and `TextField` take a
# `LocalizedStringKey` first argument exactly as `Text` does, so a literal
# there is a translatable key — and was invisible to this check until
# 2026-10-28, when 26 of them turned out to have no catalog entry: every row
# of the Device Info panel (`Version`, `Model`, `Max Contacts`, `Device
# Clock`…), the channel-details rows, the geofence name and coordinate
# placeholders, and `Type RESET to confirm`. The original list stopped at the
# containers that look like text; these look like controls, which is why they
# were missed rather than excluded.
UI_LITERAL = re.compile(
    r'(?:Text|Label|navigationTitle|Button|confirmationDialog|alert'
    r'|LabeledContent|Toggle|Picker|TextField)\(\s*"((?:[^"\\]|\\.)+)"'
)


def _unescape_swift(s: str) -> str:
    s = re.sub(r"\\u\{([0-9a-fA-F]+)\}", lambda m: chr(int(m.group(1), 16)), s)
    return (s.replace("\\n", "\n").replace("\\t", "\t")
             .replace('\\"', '"').replace("\\\\", "\\"))


def check_literals_in_catalog() -> None:
    """A UI literal with no catalog entry ships English in every other locale.

    Rule 18 catches a `String` *variable* reaching `Text()`. This catches the
    other half: a perfectly correct `Text("literal")` whose key never made it
    into `Localizable.xcstrings`. Nothing else looks — `SWIFT_EMIT_LOC_STRINGS`
    adds keys only when the archive step extracts them, `translate_strings.py`
    only translates keys the catalog already has, and the build is clean either
    way. Fifty-one strings reached a release this way, found only by reading a
    German screen. Interpolated literals are skipped: their key carries format
    specifiers and is matched by `translate_strings.py --verify` instead.
    """
    if not CATALOG_PATH.exists():
        return
    try:
        keys = set(json.loads(CATALOG_PATH.read_text())["strings"].keys())
    except (json.JSONDecodeError, KeyError):
        report("FAIL", "18", CATALOG_PATH, 1, "string catalog is unreadable")
        return

    for path in swift_files(["Shared", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            for m in UI_LITERAL.finditer(line):
                raw = m.group(1)
                if "\\(" in raw:
                    continue
                key = _unescape_swift(raw)
                if key not in keys:
                    report("FAIL", "18", path, i,
                           f'"{key[:60]}" is not in the string catalog — it will '
                           "render in English in every other language")


# --------------------------------------------------------------------------
# Protocol — a raw path_len rendered as if it were a hop count
# --------------------------------------------------------------------------

# A path_len field formatted straight into a string, rather than decoded.
#
# `.hops` is matched only on a message, because it is the sole raw-byte field
# with that name: `TraceResult.hops` and `PingResult.hops` are already counts,
# and flagging them would be noise that teaches the check to be ignored.
RAW_PATH_LEN = re.compile(
    r'(?:Text|Label|append|String)\([^)]*\\\('
    r'(?:[A-Za-z_][A-Za-z0-9_.]*\.(?:pathLen|outPathLen|inPathLen)\b'
    r'|[A-Za-z_][A-Za-z0-9_]*[Mm]essage\.hops\b'
    r'|message\.hops\b)'
)


def check_path_len_decoding() -> None:
    """`path_len` is two fields; rendering the byte whole prints a wrong number.

    The firmware packs the hop count into the low six bits and the hash size
    into the top two (`Packet.h`), so `0x46` is six hops with two-byte hashes,
    not seventy. A mesh using 2-byte hashes therefore shows every routed
    message as hops + 64.

    This exists because the first fix corrected one of the five places that
    render a hop count and missed the other four — the reported number did not
    change, and a build shipped that looked identical to the user. Nothing was
    checking, so nothing said the other four were still wrong.

    `PathLen.hopCount` is the only correct reading. The raw field may still be
    compared or passed around; what this forbids is formatting it for display.
    """
    for path in swift_files(["Shared", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            stripped = line.lstrip()
            if stripped.startswith("//"):
                continue
            if RAW_PATH_LEN.search(line):
                report("FAIL", "protocol", path, i,
                       "a raw path_len is being displayed — it packs the hash "
                       "size in its top 2 bits, so this prints hops + 64 on a "
                       "2-byte-hash mesh. Use PathLen.hopCount()")


# --------------------------------------------------------------------------
# Rule 18 (help registry) — a manual string with no catalog entry
# --------------------------------------------------------------------------

HELP_SOURCES = [
    pathlib.Path("Shared/Models/HelpCatalog.swift"),
    pathlib.Path("Shared/Models/HelpTopic.swift"),
]


def check_help_catalog() -> None:
    """Help-registry prose with no catalog entry renders English everywhere.

    `check_literals_in_catalog` only looks inside `Text(...)` and friends. The
    manual's text lives in a `HelpText` registry instead, so none of it is
    inside a call that check recognises, and Xcode's extraction cannot see it
    either — `HelpText` resolves its key at runtime by design, because a
    searchable manual needs a `String` and `String(localized:)` takes only a
    literal.

    That leaves the registry as exactly the kind of place 51 untranslated
    strings accumulated in before: real user-facing text that every existing
    tool is blind to. This is the one check that looks, so it is load-bearing
    rather than belt-and-braces.
    """
    if not CATALOG_PATH.exists():
        return
    try:
        keys = set(json.loads(CATALOG_PATH.read_text())["strings"].keys())
    except (json.JSONDecodeError, KeyError):
        report("FAIL", "18", CATALOG_PATH, 1, "string catalog is unreadable")
        return

    for rel in HELP_SOURCES:
        path = ROOT / rel
        if not path.exists():
            continue
        for i, line in enumerate(lines_of(path), 1):
            stripped = line.lstrip()
            if stripped.startswith("//") or stripped.startswith("*"):
                continue
            for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', line):
                raw = m.group(1)
                # Interpolated keys carry format specifiers, so the source
                # literal is not the key; translate_strings.py --verify owns
                # those. Same carve-out as check_literals_in_catalog.
                if "\\(" in raw:
                    continue
                key = _unescape_swift(raw)
                # Identifiers, SF Symbol names and topic slugs are not prose:
                # all-lowercase with dots or hyphens, or no letters at all.
                if len(key) < 3 or not re.search(r"[A-Za-z]", key):
                    continue
                if re.fullmatch(r"[a-z0-9.\-]+", key):
                    continue
                if not (key[0].isupper() or " " in key):
                    continue
                if key not in keys:
                    report("FAIL", "18", path, i,
                           f'"{key[:60]}" is help text with no catalog entry — '
                           "it will render in English in every other language")


# --------------------------------------------------------------------------
# Rule 17 (companion) — layout decided by device idiom rather than size class
# --------------------------------------------------------------------------

IDIOM_CHECK = re.compile(r"userInterfaceIdiom\s*==\s*\.(pad|phone)")


def check_idiom_layout() -> None:
    """`userInterfaceIdiom` is not a layout signal, and foldables broke it.

    Rule 17 is about presentation width: a sheet or popover adapts on compact
    and stays put on regular. Idiom is hardware, and the two stopped agreeing.
    An iPad in Slide Over is compact; a foldable iPhone reports `.phone` while
    unfolded at regular width. Keying layout off idiom is therefore wrong in
    both directions, and the help popover was — it gave an adapted sheet a
    300pt cap on iPad Slide Over, and gave an actual floating popover no width
    at all on an unfolded foldable.

    WARN, not FAIL: idiom is still legitimate for non-layout questions.
    """
    for path in swift_files(["Shared", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            if IDIOM_CHECK.search(line):
                report("WARN", "17", path, i,
                       "layout keyed off userInterfaceIdiom — use "
                       "horizontalSizeClass; idiom and width disagree on "
                       "iPad Slide Over and on unfolded foldables")


# A key is built by interpolating something into a string literal and handed
# straight to the store. `scopedKey` / `legacyKey` are the two legitimate
# spellings, and both live in Theme.swift, so a literal anywhere else is a
# second definition of a key that already has one.
HAND_BUILT_KEY = re.compile(
    r'\b(?:set|string|double|bool|data|array|dictionary|object|removeObject)'
    r'\(\s*(?:[^,()]*,\s*)?forKey:\s*"[^"]*\\\('
)

KEY_HELPER_HOME = pathlib.Path("Shared/App/Theme.swift")


def check_hand_built_icloud_keys() -> None:
    """A key spelled out at the call site is a key with two definitions.

    `scopedString` and `scopedDouble` read a radio-scoped key and fall back to
    the unscoped one an install carried before scoping existed. So a writer has
    to clear *both*, and `saveDraft` spelled its own key out and cleared only
    the scoped half — leaving `draft.00`, which the next read dutifully restored
    into the compose field. The public channel's field would not empty after
    sending; a direct message's did, because its key is per-contact and so was
    rarely stale. `removeiCloudMessageData` already knew about both halves. The
    knowledge existed; it just was not in the one place every caller goes
    through.

    `scopedKey` and `legacyKey` in Theme.swift are that place. Anything that
    interpolates a key into a string literal at the call site has opted out of
    the pairing, and nothing will say so until a stale value surfaces as a bug
    in a screen that looks unrelated.
    """
    for path in swift_files(["Shared", "watchOS"]):
        if path == KEY_HELPER_HOME:
            continue  # where the two key forms are defined
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//"):
                continue
            if HAND_BUILT_KEY.search(line):
                report("FAIL", "DP4", path, i,
                       "an iCloud key is interpolated at the call site — a "
                       "reader falls back to the unscoped form, so a writer "
                       "that spells its own key clears only half of it. Use "
                       "scopedKey/legacyKey or the setScoped* helpers")


def check_cross_platform_symbols() -> None:
    """A symbol the iOS build needs must not sit inside a macOS-only guard.

    `sendCompanionCLI` runs a command on the radio's own CLI over whichever
    transport is connected, which is the whole reason firmware 1.18.0 matters:
    it is the first CLI path that does not need USB, so it is the one that works
    on iOS, where `USBSerialManager` can never run. It was written *below* the
    `#if os(macOS)` guarding the USB transport — purely because the other CLI
    functions live there — and the closure calling it was wired inside the same
    guard in `PommeCoreViewModel`. Both vanished from the iOS build. The probe
    never ran on iPhone, support was never detected, the Radio Terminal row
    never appeared, and the release notes announced the feature anyway. Found on
    hardware 2026-10-30.

    Nothing else could have caught it. It compiled for both platforms with zero
    warnings, because code that has been compiled away is not an error. The 151
    package tests passed, because the frame builder was fine. `meshctl smoke`
    passed, because it proves the *firmware* answers — and it runs on the Mac.
    Proximity is not a reason to share a platform guard, and a doc comment
    saying "this is the one that works on iOS" is not a mechanism.

    Deliberately a name list rather than a heuristic. There is no way to infer
    which symbols the iOS build needs, and a check that guesses would either
    miss this or drown the real USB-only code in noise. A cross-platform
    feature added behind this kind of guard belongs on the list the day it is
    written.
    """
    cross_platform = [
        "sendCompanionCLI",
        "probeCompanionCLI",
        "runCompanionCLI",
        "onCompanionCLIReady",
        "handleCompanionCLIUnsupported",
        "buildRunCLICommand",
    ]
    needle = re.compile(r"\b(" + "|".join(cross_platform) + r")\b")
    mac_guard = re.compile(r"#if\s+os\(macOS\)|#if\s+targetEnvironment\(macCatalyst\)")

    for path in swift_files(["Shared", "watchOS"]):
        depth = 0           # nesting of #if blocks
        guarded_at = None   # depth at which a macOS guard opened
        for i, line in enumerate(lines_of(path), 1):
            stripped = line.strip()
            if stripped.startswith("#if"):
                depth += 1
                if guarded_at is None and mac_guard.search(stripped):
                    guarded_at = depth
                continue
            if stripped.startswith("#endif"):
                if guarded_at == depth:
                    guarded_at = None
                depth = max(0, depth - 1)
                continue
            if stripped.startswith("#else") and guarded_at == depth:
                # The !macOS side of a macOS guard is where iOS code belongs.
                guarded_at = None
                continue
            if guarded_at is None or stripped.startswith("//"):
                continue
            m = needle.search(line)
            if m:
                report("FAIL", "DP4", path, i,
                       f"`{m.group(1)}` is inside a macOS-only guard, so it is "
                       "absent from the iOS build. This is the companion-CLI "
                       "defect: the feature that exists to reach iPhone was "
                       "compiled out of it, with no warning and no test failure")


def check_single_send_gate() -> None:
    """"Did the frame go out" has one answer: what `sendCommand` returned.

    A channel message composed with Bluetooth off displayed a confident "Sent".
    `sendCommand` returned `Void` and dropped the frame when nothing was
    connected, so the caller could not tell. The first fix gave it a `Bool`
    return — and left the caller asking a separate `canSend` predicate first and
    then discarding that return value. Two evaluations of one question at two
    different moments: the prediction decided the status, the write was never
    consulted, and a transport that dropped out in between left the message
    armed as though it had gone out. The doc comment claimed the duplication was
    gone while the code kept both halves.

    So: no second predicate, and no call site that throws the answer away when
    it is deciding what to tell the user.
    """
    predicate = re.compile(r"\b(canSend|canSendCommand|isAbleToSend|couldSend)\b")
    for path in swift_files(["Shared", "watchOS"]):
        for i, line in enumerate(lines_of(path), 1):
            if line.lstrip().startswith("//") or line.lstrip().startswith("///"):
                continue
            m = predicate.search(line)
            if m:
                report("FAIL", "6", path, i,
                       f"`{m.group(1)}` is a second answer to a question "
                       "`sendCommand`'s return value already answers, evaluated "
                       "at a different moment. That gap is how a dropped frame "
                       "came to display \"Sent\" — act on the write, not on a "
                       "prediction of it")


CHECKS = [
    check_sheet_frames,
    check_text_takes_string,
    check_localized_params,
    check_lsk_isempty,
    check_ble_disconnect,
    check_store_before_send,
    check_endianness,
    check_psk_length,
    check_codable_decoders,
    check_duplicate_formatters,
    check_secret_logging,
    check_deployment_targets,
    check_no_tool_references,
    check_literals_in_catalog,
    check_inflection_markup,
    check_repeated_ui_literals,
    check_status_switch_exhaustive,
    check_cross_platform_symbols,
    check_single_send_gate,
    check_help_catalog,
    check_path_len_decoding,
    check_hand_built_icloud_keys,
    check_idiom_layout,
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--changed", action="store_true",
                    help="only report findings in files changed against main")
    args = ap.parse_args()

    for check in CHECKS:
        check()

    keep = findings
    if args.changed:
        diff = subprocess.run(["git", "diff", "--name-only", "main...HEAD"],
                              cwd=ROOT, capture_output=True, text=True)
        changed = {l.strip() for l in diff.stdout.splitlines() if l.strip()}
        if changed:
            keep = [f for f in findings if f[2].split(":")[0] in changed]

    fails = [f for f in keep if f[0] == "FAIL"]
    warns = [f for f in keep if f[0] == "WARN"]

    for tier, label in (("FAIL", "FAIL"), ("WARN", "WARN")):
        group = fails if tier == "FAIL" else warns
        for _, rule, loc, msg in group:
            print(f"{label} [rule {rule}] {loc}\n      {msg}")

    if not keep:
        print("No findings.")
    else:
        print(f"\n{len(fails)} FAIL, {len(warns)} WARN "
              f"({len(BASELINE)} site(s) baselined in scripts/rule_baseline.txt)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
