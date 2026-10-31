# Hardware release test

What a simulator and `meshctl` cannot answer. Everything else is already gated
by `check_rules.py`, `check_contrast.py`, `translate_strings.py --verify`, the
151 package tests, `test_build.sh` and `./scripts/meshctl.sh smoke` — run those
first and do not use this list as a substitute for them.

**Install over the existing app, from TestFlight.** Do not delete it first.
Critical Rule 12 is tested only by an install that already has persisted data,
and deleting the app throws away exactly the state that catches decoder and
key-migration faults. Installing from TestFlight rather than Xcode also tests
the distribution-signed artifact that will actually ship.

Record the build you tested, and submit **that build** — not a rebuild. See
"Submitting what you tested" at the end.

---

## 1. Channel notification modes — the highest-risk item

This is what the App Store reviewer reported as *"the notification settings
don't work at all. I always get a notification."* It was a real bug with three
layers, so it gets tested first and most carefully.

**Needs an inbound channel message from another station.** Your own sent
messages never notify, and one radio accepts one connection, so the Mac app
cannot stand in. Either wait for public-channel traffic or use a second radio.

Open the public channel → channel details → Notifications.

| Mode | Send from the other station | Expected |
|---|---|---|
| All | anything | notification arrives |
| Mentions | a message **not** naming you | **no** notification |
| Mentions | a message containing `@yourname` | notification arrives |
| Muted | anything | **no** notification, ever |

Then, still on Mentions or Muted:

- **Force-quit the app and relaunch.** The mode is keyed by channel *index*
  now, not by name; this is what proves the new key is both written and read.
- **Check a second channel**, not just index 0. The old bug only ever hit index
  0, so a test that stays there would have passed before the fix as well.
- **Rename the channel** on the radio, then send again. The index does not
  change when a channel is renamed, which is the reason it is the key.

Mentions matches both `@name` and `@[name]`, so test whichever form your other
client sends.

## 2. Message status must not claim anything the protocol cannot support

Critical Rule 6. A status is a claim about reality.

- **Radio disconnected** (switch the radio off, or Bluetooth off on the phone):
  compose a channel message and send. It must **never** read *Sent*. Expected:
  it stays sending, then fails. A confident "Sent" here is the exact bug the
  rule was rewritten for — `sendCommand` drops the frame and returns `Void`
  when nothing is connected.
- **Reconnected:** send again. It goes *Sent* only once the radio answers
  `PACKET_OK`.
- **A repeater echoes it** (0x88): status becomes *Repeated*, and *Repeated*
  must never be overwritten by a later *Sent*.
- **Direct message:** confirm *Delivered* still appears when the mesh ACKs. A
  channel message must never show *Delivered* — nothing on the mesh can report
  that for a channel.

## 3. The radio's own CLI, over Bluetooth, on iPhone

New in 1.18 and the headline of this release. **It has never run on iOS
hardware** — `meshctl smoke` exercises the same frames from the Mac, which
proves the firmware answers, not that the iOS path works. Requires firmware
1.18 on the radio (`v1.18.0-81dbae5` here).

Settings → Radio Terminal.

- `ver` → version string and build date
- `get name` → your radio's name
- a command that does not exist, e.g. `nonsense` → must print
  **`Unknown command`**. It must *not* appear as an error or a failed command:
  the companion firmware answers an unknown CLI command with that literal
  string, and `supportedValue(for:)` has to recognise it as "answered, not
  supported" rather than as a failure.
- Run several commands in a row. Pacing used to be the USB queue's job; this
  path is new.
- This screen used to be macOS-only. Confirm it is reachable at all on the
  phone — that is the feature.

## 4. Quick Reply, over the air

Long-press a received message → Quick Reply.

- The composed line carries the parts you enabled: hop count, signal, time,
  your location label.
- In a **channel**, it addresses the sender as `@[name]`; in a **DM**, by
  display name.
- Turn every part on and use a long location label: the line must still send.
  It is truncated to **160 UTF-8 bytes**, dropping whole parts rather than
  cutting a character in half — check a label with non-ASCII characters.
- Confirm the other client actually shows what you intended. These are real
  people on other clients, not bots.

## 5. The localization pass

26 UI keys had no catalog entry and 77 now-translated strings were English in
all eleven languages.

Settings → PommeCore → Language → Deutsch (per-app language; faster than
changing the whole phone and easier to undo).

- **Device Info** — every row should be German: `Version`, `Modell`,
  `Build-Datum`, `Max Kontakte`, `Max Kanäle`, `Gerätetakt`-style rows,
  `Spannung`. These were all English before.
- **Channel details** — `Kanaltyp` with a value of `Öffentlich`, and the
  secret row reading `Setzen (16 Bytes)`.
- **Geofences** — the name field and both coordinate placeholders.
- **Danger Zone** — the confirmation field must still say **RESET** in capitals
  with the rest in German. If RESET itself got translated, the field that
  compares the literal can never match and erase becomes impossible.
- **Quick Reply settings** — `Schnellantwort`, and the include toggles.
- Spot-check one other language if you have the patience; `nl` and `cs` had the
  most repaired strings.

## 6. Watch

`MPB-Watch` is paired. The watch app is a paid IAP companion, so a regression
here is a regression in something people bought.

- Contacts and channels appear without the phone reconnecting the radio.
- A message sent from the phone reaches the watch thread.
- Reply from the watch and confirm it leaves.
- VoiceOver on the watch must not speak English for app strings — it did until
  this release.

---

## Submitting what you tested

`./build-and-distribute.sh --release` derives the marketing version from
**today's date** and builds a fresh archive, so running it ships a build that
nobody has tested. To submit the artifact that passed this list, create the App
Store version record matching that build's own marketing version and attach the
build to it. Rebuild only if code changed, and then test again.
