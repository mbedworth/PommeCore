#!/usr/bin/env python3
"""Measure every MeshTheme colour against the surface it is used on.

The accessibility nutrition label claims Sufficient Contrast. This is what
backs that claim up: each theme colour, paired with the background it actually
appears on, against the WCAG AA thresholds (4.5:1 for body text, 3:1 for large
text and non-text elements such as a status dot or a map pin).

Run it after any change to the colour system. Exits non-zero on a failure.
"""
import sys


def _linear(c):
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def luminance(rgb):
    r, g, b = (_linear(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) / 255 for i in (0, 2, 4))


# Backgrounds, and the whole point of the list is that it is complete.
#
# The first version of this script measured only the grouped background and the
# card, and so reported everything passing while four dark-mode colours were
# under the bar on `surfaceLight`. Dark mode is where this bites: every
# *lighter* surface reduces contrast for a bright foreground, which is the
# opposite of the intuition built up in light mode, where the darkest surface
# is the tightest. Any new surface in MeshTheme belongs here.
LIGHT_GROUPED = hex_rgb("F2F2F7")      # systemGroupedBackground
LIGHT_CARD = (1.0, 1.0, 1.0)           # secondarySystemGroupedBackground
LIGHT_ELEVATED = hex_rgb("F2F2F7")     # surfaceLight / tertiary
DARK_GROUPED = (0.0, 0.0, 0.0)
DARK_CARD = hex_rgb("1C1C1E")
DARK_ELEVATED = hex_rgb("2C2C2E")      # surfaceLight / tertiary, iOS
DARK_MAC_ELEVATED = hex_rgb("3A3A3C")  # macOS unemphasizedSelectedContent

# MeshTheme values, mirroring Shared/App/Theme.swift.
LIGHT = {
    "accent": (0.0, 0.463, 0.184),
    "statusGood": (0.118, 0.459, 0.200),
    "statusWarn": (0.588, 0.345, 0.0),
    "statusCaution": (0.490, 0.392, 0.0),
    "statusBad": (0.776, 0.165, 0.133),
    "statusInfo": (0.0, 0.388, 0.820),
    "statusIdle": (0.424, 0.424, 0.439),
    "remoteRoom": (0.122, 0.446, 0.504),
    "mapRoom": (0.557, 0.227, 0.722),
}
# Dark mode keeps Apple's system colours where they pass. Red, blue, gray and
# the map violet are brightened, because the system values fall under the bar
# on the elevated surfaces.
DARK = {
    "accent": (0.0, 0.85, 0.35),
    "statusGood": hex_rgb("30D158"),
    "statusWarn": hex_rgb("FF9F0A"),
    "statusCaution": hex_rgb("FFD60A"),
    "statusBad": hex_rgb("FF7B73"),
    "statusInfo": hex_rgb("51A8FF"),
    "statusIdle": hex_rgb("A3A3A8"),
    "remoteRoom": hex_rgb("40C8E0"),
    "mapRoom": hex_rgb("D085F5"),
}

# Foreground-on-fill pairs: text sitting on a filled theme colour.
FILLS = {
    "textOnFill on accent": ((1, 1, 1), LIGHT["accent"], (0, 0, 0), DARK["accent"]),
    "textOnFill on statusBad": ((1, 1, 1), LIGHT["statusBad"], (0, 0, 0), DARK["statusBad"]),
    "textOnFill on remoteRoom": ((1, 1, 1), LIGHT["remoteRoom"], (0, 0, 0), DARK["remoteRoom"]),
    "textOnBubble on outgoingBubble": ((0, 0, 0), (0.75, 0.93, 0.78), (0, 0, 0), (0.0, 0.65, 0.3)),
    "textOnBubble on incomingBubble": ((0, 0, 0), (1.0, 0.88, 0.75), (0, 0, 0), (0.80, 0.45, 0.10)),
    "linkInBubble on outgoingBubble": ((0.0, 0.302, 0.122), (0.75, 0.93, 0.78), (0, 0, 0), (0.0, 0.65, 0.3)),
    "linkInBubble on incomingBubble": ((0.0, 0.302, 0.122), (1.0, 0.88, 0.75), (0, 0, 0), (0.80, 0.45, 0.10)),
    "textOnDarkPanel on darkPanel": ((1, 1, 1), (0.12, 0.12, 0.12), (1, 1, 1), (0.12, 0.12, 0.12)),
}

# watchOS, in PommeCoreWatchKit. The watch UI uses the system palette rather
# than MeshTheme, and watchOS resolves it differently from iOS dark mode —
# red is #FF4245 here, not #FF453A, and orange #FF9230, not #FF9F0A. These
# values were measured, not assumed: a swatch app rendering each colour as a
# solid band, run on a watchOS simulator, screenshotted, pixels sampled. Redo
# it that way if the palette ever looks wrong; guessing from the iOS values
# is what this comment exists to prevent.
WATCH = {
    "green": hex_rgb("30D158"),
    "red": hex_rgb("FF4245"),
    "orange": hex_rgb("FF9230"),
    "yellow": hex_rgb("FFD600"),
    "white": (1.0, 1.0, 1.0),
    "primary": (1.0, 1.0, 1.0),
    "secondary": hex_rgb("8D8D93"),
    "bubbleIn": hex_rgb("333333"),
    "panel": hex_rgb("262626"),
    "black": (0.0, 0.0, 0.0),
}

# (description, foreground, background, is_text)
WATCH_PAIRS = [
    ("outgoing bubble text", "black", "green", True),
    ("incoming bubble text", "primary", "bubbleIn", True),
    ("total unread badge", "black", "red", True),
    ("per-contact unread badge", "black", "green", True),
    ("channel unread badge", "black", "orange", True),
    ("sender / timestamp / hops", "secondary", "black", True),
    ("accent text", "green", "black", True),
    ("channel amber", "orange", "black", True),
    ("activity yellow", "yellow", "black", True),
    ("failed-status glyph", "red", "black", True),
    ("connection dot", "green", "black", False),
]

TEXT_AA, NONTEXT_AA = 4.5, 3.0


def main():
    failures = []
    print("MeshTheme colours as TEXT, on every surface they can land on")
    print(f"{'colour':17} {'lt grp':>7} {'lt card':>8} {'lt elev':>8} "
          f"{'dk grp':>7} {'dk card':>8} {'dk elev':>8} {'mac elev':>9}")
    for name in LIGHT:
        row = [contrast(LIGHT[name], LIGHT_GROUPED), contrast(LIGHT[name], LIGHT_CARD),
               contrast(LIGHT[name], LIGHT_ELEVATED),
               contrast(DARK[name], DARK_GROUPED), contrast(DARK[name], DARK_CARD),
               contrast(DARK[name], DARK_ELEVATED), contrast(DARK[name], DARK_MAC_ELEVATED)]
        worst = min(row)
        mark = " " if worst >= TEXT_AA else ("~" if worst >= NONTEXT_AA else "X")
        if worst < TEXT_AA:
            failures.append((f"{name} as text", worst, TEXT_AA))
        print(f"{mark}{name:16} " + " ".join(f"{v:8.2f}" for v in row))

    print("\nForegrounds ON a filled theme colour")
    print(f"{'pair':34} {'light':>8} {'dark':>8}")
    for name, (fl, bl, fd, bd) in FILLS.items():
        lv, dv = contrast(fl, bl), contrast(fd, bd)
        worst = min(lv, dv)
        mark = " " if worst >= TEXT_AA else ("~" if worst >= NONTEXT_AA else "X")
        if worst < TEXT_AA:
            failures.append((name, worst, TEXT_AA))
        print(f"{mark}{name:33} {lv:8.2f} {dv:8.2f}")

    print("\nwatchOS (PommeCoreWatchKit) — measured on a simulator")
    print(f"{'pair':30} {'fg on bg':26} {'ratio':>7}")
    for desc, fg, bg, is_text in WATCH_PAIRS:
        v = contrast(WATCH[fg], WATCH[bg])
        bar = TEXT_AA if is_text else NONTEXT_AA
        mark = " " if v >= bar else "X"
        if v < bar:
            failures.append((f"watchOS {desc}", v, bar))
        print(f"{mark}{desc:29} {fg + ' on ' + bg:26} {v:7.2f}")

    print(f"\nWCAG AA: {TEXT_AA}:1 body text, {NONTEXT_AA}:1 large text and "
          "non-text. Marks: blank passes text, ~ passes non-text only, X fails.")
    if failures:
        print(f"\n{len(failures)} below the body-text bar:")
        for name, got, want in failures:
            print(f"  {name}: {got:.2f}:1 (need {want}:1)")
        return 1
    print("\nAll pairs clear the body-text bar.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
