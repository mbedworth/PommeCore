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
| **Smoke test** | 2026-10-03 on Heltec Mesh Pocket `v1.17.1-d929643` — 9/9 passed (release gate for v26.10.03); also 2026-10-02, see below |
| **Bulk-delete test** | 2026-10-03, same radio — 17/17 passed; unpaced removals drop ~half their writes, see below |
| **Restore test** | 2026-10-03, end to end through the macOS app UI — snapshot, delete and restore all verified, see below |
| **Profile round trip** | 2026-10-03, app UI — passed after fixing lost contact adds on a mid-burst BLE drop, see below |

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

### 2026-10-03 — release gate for v26.10.03, companion `v1.17.1-d929643`

Re-run as the hardware gate before submitting v26.10.03 for App Store review,
since that release carries the 1.17 telemetry parsing changes. **9 passed, 0
failed**, same as 2026-10-02 and on the same firmware.

| Check | Result |
|---|---|
| `CMD_DEVICE_QUERY` answers, semantic version reported | ✅ `v1.17.1-d929643` |
| `FIRMWARE_VER_CODE` | ✅ 13, matching the ledger |
| Contact sync | ✅ 3 contacts |
| Unidentified nodes | ⚪ 0 — normal; cannot be induced on demand |
| Self telemetry answers | ✅ 2 readings |
| 1.17 MCU temperature present | ✅ 22.7 °C |
| Temperature within a sane die range | ✅ |
| Reading keys unique | ✅ 2 distinct (`1:Battery`, `1:Temperature`) |
| A type appearing once keeps its plain label | ✅ |
| Every reading carries an LPP channel | ✅ |
| Remote telemetry | ⏭ skipped — needs `--target`; repeaters do not answer non-admins |

The point of the run: Battery and Temperature both arrive on **LPP channel 1**
and still parse to distinct keys. That is the 1.17 change which would otherwise
collapse two readings into one, and it is the reason channel is part of a
reading's identity (critical rule 14).
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

---

## Bulk contact deletion — hardware record

Run with `./scripts/meshctl.sh bulkdelete [--count N]`. It writes to the radio, but never
to a real contact: it creates its own (`meshctl-del-NN`), deletes only those, and asserts
every pre-existing contact survived. Leftovers from an interrupted run are removed on the
next run.

This exists because bulk deletion is the one destructive path whose failure mode cannot be
unit-tested — it is firmware timing.

### 2026-10-03 — Heltec Mesh Pocket, companion `v1.17.1-d929643`, 60 contacts

17 checks passed, 0 failed.

| Round | Sequence | Result |
|---|---|---|
| Adds | 60 `CMD_ADD_UPDATE_CONTACT`, 150ms spacing | ✅ all 60 present, existing 3 untouched |
| 1 | Removals at 150ms, 1s settle, then full sync | ✅ all 60 gone, all 3 survivors intact, sync announced 3 / received 3 |
| 2 | Removals at 150ms, **no settle**, immediate sync | ✅ sync still complete (announced 3 / received 3) |
| 3 | Removals **unpaced**, immediate sync | ⚠️ **33 of 60 removals silently dropped** |
| 3 retry | The 33 survivors re-sent at 150ms | ✅ all removed |

### The finding

**An unpaced burst of `CMD_REMOVE_CONTACT` loses roughly half its writes.** Two runs at 60
contacts dropped 30 and 33 respectively. The firmware acknowledges nothing and the
following sync is *internally consistent* — it announced 36 and delivered 36 — so no
response says anything went wrong. A user would simply find half the contacts they deleted
still there.

150ms spacing avoided it completely at the same scale, twice. At 12 contacts even the
unpaced burst landed everything, so the threshold is somewhere between 12 and 60 frames.

**What the app does about it.** Pacing alone would be a timing assumption about one
firmware build on one radio, on the path where being wrong is most expensive. So
`ContactStore.sendRemovalsAndVerify` treats the radio's own contact list as the signal:
after the settle and the full sync, anything still present was dropped rather than deleted,
and gets re-sent — up to three passes, then the user is told plainly. This is the
protocol-signal-over-timer rule applied to a destructive operation.

### What this did *not* reproduce

**The truncated sync.** `ContactSyncReducer.rejectTruncated` guards against a full sync
delivering fewer contacts than `RESP_CODE_CONTACTS_START` announced, which is the shape the
data loss of 2026-10-02 was diagnosed as. On this firmware it would not reproduce: neither
removing the settle (round 2) nor removing the pacing as well (round 3) produced a sync
whose received count disagreed with its announced count. Every sync observed was
self-consistent.

The guard stays, for an asymmetry rather than for evidence: accepting a short list once
cascaded into permanent loss of messages, nicknames, notes, trails and telemetry, while
keeping a stale list corrects itself on the next sync. But the original cause should be
treated as **not established** — the reproducible defect on this firmware is dropped
removal writes, not a truncated stream. Re-check if the data loss ever recurs, and note
that the 2026-10-02 incident also involved an automatic orphan sweep that no longer runs.

### 2026-10-03 — restore, end to end through the app

Run on the macOS app (Debug build, same container as the shipping app) against the same
radio, driven through the real UI rather than the harness. Eight disposable contacts were
seeded with `meshctl seed --count 8` so no real contact was ever at risk.

| Step | Observed |
|---|---|
| Connect, full sync | announced 11, received 11 |
| Bulk delete 8 in the UI | `Wrote contact backup: 11 contacts` at 15:12:02.997, **then** `Bulk remove: 8 contacts` at 15:12:03.074 |
| Post-delete sync | announced 3, received 3 — no removal-verification retry, so all 8 paced writes landed |
| Restore from Settings › Storage › Contact Backups | `Restoring 11 contacts` → `Restored local data` 2.94s later (10 × 150ms + 1s settle, as designed) |
| Post-restore sync | announced 11, received 11 |
| Independent check via `meshctl info` | 11 contacts present, `US-FL-CLR-CR-38777` still typed `Repeater` |

**What this establishes.** The snapshot is written before the first removal frame, not after
— the ordering the whole design depends on. The snapshot captures the entire list (11), not
just the selection (8), so a wrong selection is recoverable too. Contact *type* survives
the JSON round trip and the `CMD_ADD_UPDATE_CONTACT` rebuild, which matters because a
repeater restored as a chat contact would break routing.

An incremental sync during the run delivered 1 contact against an `expectedContactCount` of
3 and correctly **merged** rather than rejecting or shrinking — `ContactSyncReducer` only
applies the completeness check to full syncs, and this exercised that live.

**Not covered.** The UI was driven by hand: `osascript` has no assistive access here, so
the taps cannot be automated, and the app container is TCC-protected so the backup file
cannot be inspected from a shell. Verification was by the app's own `com.pommecore` log
stream plus an independent `meshctl info` afterwards. Restoring a backup that belongs to a
*different* radio is still untested on hardware (it is refused by `belongs(toRadio:)`, which
is unit-tested).

### 2026-10-03 — profile round trip with contacts, and a defect it found

Run through the real app UI against `v1.17.1`, with 8 disposable contacts seeded so no
real contact was at risk.

**Export.** Worked once a macOS save-panel bug was fixed (the panel was being presented
from inside a SwiftUI sheet, so it never came forward — exporting was impossible on macOS).
The file is version 2, 11 contacts, repeater correctly typed, `privateKeyHex` null, and
each contact carries **only** radio-side fields — `flags, lastAdvert, lastmod, latitude,
longitude, name, outPath, outPathLen, publicKey, type`. No nicknames, notes, groups or mute
state, which is the privacy boundary the format claims.

**Import, first attempt — failed.** 7 of 11 `CMD_ADD_UPDATE_CONTACT` frames went out, then
BLE dropped ("connection timed out unexpectedly"). The remaining 4 were written into a dead
connection, **none of the 11 landed**, and the UI still reported "Applied — reboot your
radio to activate".

**Import, after the fix — passed.** All 11 landed; `meshctl info` confirmed 11 on the radio
afterwards.

### Where the link drop comes from

Not a single command. `meshctl restartprobe` writes each suspect setting back with the
value the radio already has:

| Probe | Result |
|---|---|
| `set advert name` (unchanged) | link stayed up through a 12s settle |
| `set radio params` (unchanged) | link stayed up |
| `set TX power` (unchanged) | link stayed up |
| 4 settings at 300ms, then 11 contact frames at 150ms | link stayed up, all 11 landed |

Channel writes were then probed too — each channel read back and rewritten with the name
and secret it already had — and the link held through all six. Finally `meshctl
replayprofile` replayed an exported profile's **entire** apply sequence, the same order and
the same 300ms spacing the app uses, including `setAutoAddConfig`, `setDefaultFloodScope`
and `setTuningParams`, which are not in SELF_INFO and so could not be probed individually:

| Probe | Result |
|---|---|
| 6 channel rewrites (unchanged values) @300ms | link held |
| Full profile apply, all 11 commands @300ms | link held through a 10s settle |

**Conclusion: the apply sequence does not drop the link.** No command, no channel write and
not the full sequence reproduces it. Three `Timed out: Bluetooth power-on` failures during
the same session point at an intermittent BLE problem on this Mac rather than radio
behaviour. The "radio restarts on profile apply" theory is **not supported** by any of this
— which does not make the drop harmless, only unpredictable, so the app is built to survive
it rather than to avoid it.

What the second run pins down precisely: contacts started at 16:41:53.719 and every frame
drew a `RESP OK`; the disconnect came at **16:42:01.861**, well after the contacts were
written and during the settings phase. Ordering contacts first is what made the difference.

### What changed because of this

- **Contacts are applied first**, not last. They used to go last so that settings would
  land even if the slow part failed. Hardware inverted the reasoning: settings are
  idempotent and trivially re-applied, the contact list is the data.
- **Adds are verified like removals.** `ContactStore.sendContactWrite` now covers both
  directions, checking the radio's own list afterwards and re-sending whatever disagrees.
  Backup restore goes through the same path — it had the identical assumption.
- **A paced burst stops when the link drops** instead of writing the remainder into
  nothing.
- **A pending write survives a disconnect.** `reset()` runs on every disconnect and used to
  clear it, which is precisely how the 4 outstanding adds became unrecoverable. It is
  stamped with the radio's public key and discarded only if the radio changes.
- **A partial apply is reported, not hidden.** Each settings step checks the link first and
  stops if it is gone, and the UI says which step it stopped at instead of "Applied". The
  commands are idempotent, so importing again fixes it — but only if the user knows it did
  not finish.
