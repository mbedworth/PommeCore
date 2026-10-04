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
                # An iPad idiom check satisfies the rule on its own: the rule is
                # about iPhone sheets, and on iPad a popover stays a popover and
                # legitimately needs a width.
                if re.search(r"isPadIdiom|userInterfaceIdiom\s*==\s*\.pad|"
                             r"horizontalSizeClass\s*==\s*\.regular", line):
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
    allowed = {"Shared/App/Theme.swift",
               "Packages/MeshCoreKit/Sources/MeshCoreKit/GeoMath/GeoMath.swift"}
    pattern = re.compile(r"\bfunc\s+(format(?:Frequency|Coordinate|Duration|Distance|Elevation)\w*)\b")
    for path in swift_files(["Shared", "Packages/MeshCoreKit/Sources", "watchOS"]):
        rel = str(path.relative_to(ROOT))
        if rel in allowed:
            continue
        for i, line in enumerate(lines_of(path), 1):
            m = pattern.search(line)
            if m:
                report("WARN", "DP4", path, i,
                       f"`{m.group(1)}` duplicates a Theme.swift/GeoMath helper")


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
