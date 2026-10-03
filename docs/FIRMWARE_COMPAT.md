# MeshCore Firmware Compatibility Ledger

Which firmware versions the app has been checked against, what each one changed for us, and the exact
procedure for checking the next release. Update this file whenever a MeshCore release is reviewed —
this is the source of truth for firmware review state, not the local development guide or commit messages.

**Upstream repo:** https://github.com/meshcore-dev/MeshCore
**Release blog:** https://blog.meshcore.io — announcements only; do not trust them as a change list (see Method below).

---

## Current baseline

| | |
|---|---|
| **Reference firmware** | Companion v1.17.1 (Heltec Mesh Pocket) |
| **Also compatible with** | v1.15.0 – v1.16.0 |
| **Protocol version sent** | `app_target_ver = 3` in `CMD_DEVICE_QUERY` — must stay ≥ 3 (see the critical rules in the local development guide) |
| **Last review** | 2026-08-24, covering v1.17.0 and v1.17.1 |
| **Smoke test** | 2026-10-02 on Heltec Mesh Pocket `v1.17.1-d929643` — passed, see below |

The app does **not** gate behaviour on `FIRMWARE_VER_CODE`. Version-specific behaviour keys off the
semantic version string plus response probing (`dutycycle` vs `af`), or off
`RemoteDeviceSession.supportedValue(for:)` for CLI commands. Keep it that way — the version byte has
stayed at 13 across two feature releases, so it cannot be used to detect capabilities.

---

## Version ledger

Tag SHAs are recorded so a re-pointed tag is detectable. Verify with:
`gh api repos/meshcore-dev/MeshCore/git/ref/tags/companion-v<version> --jq '.object.sha'`

| Version | Released | Companion tag SHA | VER_CODE | Reviewed | Outcome | Smoke test |
|---------|----------|-------------------|----------|----------|---------|------------|
| v1.15.0 | 2026-04-19 | `3d999fe69629` | 11 | 2026-04 | Adopted — `dutycycle` rename, `DEFAULT_FLOOD_SCOPE` (0x3F/0x40/0x1C) | Passed |
| v1.16.0 | 2026-06-06 | `24fe7d4b2d17` | 13 | 2026-06-06 | No protocol change; adopted `flood.max.unscoped` + region tree management (shipped build 18) | **Passed** 2026-06-08 — DM delivery ACK + round trip |
| v1.17.0 | 2026-08-09 | `2af6126cfba7` | 13 | 2026-08-24 | No protocol change; three behaviour changes adopted (below) | 2026-10-02 ✅ |
| v1.17.1 | 2026-08-14 | `8fe15c89ed5a` | 13 | 2026-08-24 | Bug-fix release; nothing further to adopt | 2026-10-02 ✅ |

Repeater and room-server tags for the same version are published within a minute of the companion tag
and share the version number. The companion tag is the one that matters for protocol review; the other
two matter only for CLI commands used by Remote Management.

| Version | Repeater tag SHA | Room server tag SHA |
|---------|------------------|---------------------|
| v1.15.0 | `436ebaa65012` | `4c3e51d5bfd1` |
| v1.16.0 | `dfc17c8f7f2a` | `efdca54d7bea` |
| v1.17.0 | `1e0818934edd` | `d7760a2849a7` |
| v1.17.1 | `d2ab960a1d5d` | `2e7880b0d293` |

---

## What each version changed for the app

### v1.17.0 / v1.17.1 — reviewed 2026-08-24, adopted

Companion protocol surface **unchanged** from 1.16.0: `FIRMWARE_VER_CODE` still 13, no new, changed, or
removed `CMD_*` / `RESP_CODE_*` / `PUSH_CODE_*` / `ERR_CODE_*` symbols, and upstream
`docs/companion_protocol.md` differs by two lines (a note that hashtag channels are not private —
anyone who guesses the channel name derives the key). The release is mostly IRQ/preamble collision
fixes, new boards, and an on-device migration of node config to JSON (the old binary format is retained
for rollback).

Three behaviour changes reached the app, all adopted (commits `f0e5735`, `dbdf1cf`, `a2c916f`):

1. **MCU temperature on `TELEM_CHANNEL_SELF`** — `board.getMCUTemperature()` is implemented for both
   ESP32 and nRF52, so nearly every board reports it. Telemetry is now parsed and keyed per LPP channel.
   This fixed a same-name collision *and* a pre-existing stream desync on unparsed LPP types. See
   `docs/PROTOCOL.md` → Telemetry payload.
2. **`ADV_TYPE_NONE` contacts** are no longer filtered out of `CMD_GET_CONTACTS` and now carry a
   `lastmod`. They display as "Unknown node · \<hex\>", sort last, and stay out of Spotlight.
3. **`set cad on|off`** (repeater/room only — companion firmware hardcodes CAD off) and
   **`get pwrmgt.bootreason`** exposed in Remote Management. See `docs/CLI_REFERENCE.md`.

**Deliberately not adopted:** `get/set radio.fem.rxgain` / `radio.fem.txgain` — 1.17.1 states companion
firmware cannot configure FEM gain yet, so defaults apply.

**Landed in firmware but not yet usable:** multi-serial interfaces (up to 4) and Ethernet transports
(RAK13800, CH390) — there are no official multi-interface companion builds. `room.post` (room server,
server-originated posts) is unexposed and folded into the room permission manager work.

### v1.16.0 — reviewed 2026-06-06, no protocol change

Companion interface unchanged: `PACKET_ACK` (0x82) byte-identical to 1.15.0, baseline still "v1.12.0+",
no message-format bump. The blog's "extended 6-byte ACK" is the mesh-level `PAYLOAD_TYPE_ACK`, **not**
the companion 0x82 frame — a good example of why the release notes need checking against source.
Adopted `flood.max.unscoped` plus region tree management (View/def/put/remove/save) in Remote
Management, shipped in build 18. Still optional: a full visual `region def` tree editor, raw
full-packet composition.

### v1.15.0 — reviewed 2026-04, adopted

`FIRMWARE_VER_CODE` 10 → 11. `get/set af` deprecated in favour of `get/set dutycycle` — the app fetches
both and uses whichever responds. `CMD_GET/SET_DEFAULT_FLOOD_SCOPE` (0x3F/0x40, response 0x1C) added and
exposed. GROUP_DATA binary packets (0x91+) are handled as `unknown(type:payload:)` — no crash, silently
ignored.

---

## Checking a new release

### Method

Diff the firmware tags directly. **Do not review from the release notes** — for 1.17.x they called
`pwrmgt.bootreason` new when it already existed in 1.16.0, and omitted both behaviour changes that
actually affected the app.

`curl` to raw.githubusercontent is blocked in the sandbox; `gh api` works.

```bash
# 1. Has anything new been published?
gh api repos/meshcore-dev/MeshCore/releases --jq '.[0:6][] | "\(.tag_name)  \(.published_at)"'

# 2. Confirm the tag we reviewed has not been re-pointed
gh api repos/meshcore-dev/MeshCore/git/ref/tags/companion-v1.17.1 --jq '.object.sha'

# 3. File-level diff between the reviewed version and the new one
gh api "repos/meshcore-dev/MeshCore/git/trees/companion-v<old>?recursive=1" --jq '.tree[].path' > old.txt
gh api "repos/meshcore-dev/MeshCore/git/trees/companion-v<new>?recursive=1" --jq '.tree[].path' > new.txt
diff <(sort old.txt) <(sort new.txt)

# 4. Fetch a file at a tag (repeat per file, then diff locally)
gh api "repos/meshcore-dev/MeshCore/contents/<path>?ref=companion-v<version>" --jq '.content' | base64 -d
```

### What to diff, in priority order

1. **`examples/companion_radio/MyMesh.h`** — `FIRMWARE_VER_CODE` and `FIRMWARE_VERSION`.
2. **`examples/companion_radio/MyMesh.cpp`** — the command dispatch. Compare the symbol sets:
   `grep -oE "CMD_[A-Z_]+|RESP_CODE_[A-Z_]+|PUSH_CODE_[A-Z_]+|ERR_CODE_[A-Z_]+" | sort -u`.
   An empty diff means the protocol surface is unchanged; then read the body diff for behaviour changes,
   which is where 1.17's real impact was.
3. **`docs/companion_protocol.md`** — upstream's own protocol doc.
4. **`src/helpers/CommonCLI.cpp`** — new or changed CLI commands for Remote Management. Note which roles
   honour them: a command in CommonCLI is accepted by every role, but the *effect* may be overridden per
   role (e.g. `getCADEnabled()` is hardcoded false on companion).
5. **`src/helpers/SensorManager.h`, `src/helpers/sensors/*`** — telemetry channel assignment and new LPP
   field types. Cross-check payload lengths against `electroniccats/CayenneLPP` at the version pinned in
   `platformio.ini`.

### After the review

- [ ] Update the ledger table and the per-version section above.
- [ ] Update the development guide header lines (reference firmware, protocol version) if they changed.
- [ ] Update `docs/PROTOCOL.md` / `docs/CLI_REFERENCE.md` for any new frames or commands.
- [ ] Register and translate any new UI strings (`docs/LOCALIZATION.md`).
- [ ] `./scripts/test_build.sh` — zero errors, zero warnings.
- [ ] Hardware smoke test on a real node, and record the result in the ledger:
      `./scripts/meshctl.sh smoke` (see `Packages/MeshCoreKit/Sources/meshctl/`).

---

## Smoke test record

Run with `./scripts/meshctl.sh smoke`, which talks to the radio over BLE with the same
service UUIDs and frame format as the app. `--target <pubkey-prefix>` adds a remote
telemetry request.

### 2026-10-02 (second run) — after the BLE and deframing changes

Re-run on the same node after round 2 of the code audit, which touched the BLE
delegate path and replaced both stream transports' frame scanning with shared
code. 9 checks passed, 0 failed — same assertions as the first run.

Two differences from the morning run, both benign:

- MCU temperature read 26.0 °C rather than 43.7 °C. The radio had been idle
  rather than driving an active BLE connection, so this is the expected
  direction and a useful sanity check that the value is a live reading and not
  a cached constant.
- Contact count was 73 rather than 103. Nothing in the app removes contacts
  from a radio except an explicit user delete; the companion firmware evicts
  old contacts when its store fills, which the app already surfaces via
  `ERR`/contact-removed handling. Worth a glance if it keeps falling, but not
  attributable to the audit changes.

### 2026-10-02 — Heltec Mesh Pocket, companion `v1.17.1-d929643`

9 checks passed, 0 failed.

| Check | Result |
|---|---|
| `CMD_DEVICE_QUERY` answers, semantic version reported | ✅ `v1.17.1-d929643`, build 14-Aug-2026 |
| `FIRMWARE_VER_CODE` | ✅ 13, matching the ledger |
| Contact sync | ✅ 103 contacts |
| Self telemetry answers | ✅ 2 readings |
| 1.17 MCU temperature present | ✅ 43.7 °C |
| Temperature within a sane die range | ✅ |
| Reading keys unique | ✅ 2 distinct |
| A type appearing once keeps its plain label | ✅ |
| Every reading carries an LPP channel | ✅ |

**What this confirms.** Battery (`0x74`) and Temperature (`0x67`) both arrived on
**LPP channel 1**, and both parsed into distinct readings with distinct keys
(`1:Battery`, `1:Temperature`). That is the 1.17.0 change this release cycle was about:
before 1.17.0 channel 1 carried only voltage, so a parser keyed on LPP type alone did not
collide. It does now. See critical rule 14 in the development guide.

The self-telemetry path (`CMD_SEND_TELEMETRY_REQ` with `len == 4`, no recipient) is used
by the harness, not the app — the firmware answers it immediately with the same
`PUSH_CODE_TELEMETRY_RESPONSE` (0x8B) frame shape as a remote request, with no mesh round
trip, which makes it the only deterministic way to exercise this.

**What hardware did not cover, and why.**

- **Two temperatures in one response** (MCU on channel 1 plus an external sensor on its own
  channel). This node has no external sensor fitted. Covered by
  `TelemetryParsingTests.swift` instead, which asserts duplicate types stay distinct and
  that same-channel duplicates get indexed keys.
- **Remote telemetry.** Tried against three repeaters (`SOLARRSR4`, `WSO Solar`,
  `🦖 InGen`); none answered. That is firmware policy, not a defect — a node only answers a
  telemetry request from an admin, or when it has telemetry sharing enabled for everyone.
- **Unidentified nodes** (`ADV_TYPE_NONE` contact entries, new in 1.17.0). This mesh
  returned 0 of them, and they cannot be induced on demand — a node creates one only after
  being asked for data by a radio that has not yet adverted. The handling is defensive
  (placeholder name plus key prefix, sorted last, excluded from Spotlight) and is unit-free
  by nature; re-check opportunistically.
- **Listen Before Transmit (`get cad`) and `pwrmgt.bootreason` rows.** Both need a remote
  admin login to a repeater. The UI gates each row on
  `RemoteDeviceSession.supportedValue(for:)` returning non-nil, so on firmware without the
  key the row is simply absent — the failure mode is a missing row, not a wrong value.
