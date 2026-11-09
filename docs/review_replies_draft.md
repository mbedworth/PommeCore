# App Store review replies — DRAFT, nothing posted

Drafted 2026-11-08. **Not posted.** Replies are public and attached to your
developer account, so each one needs your approval first.

All nine reviews come from one API pool covering both platforms — the endpoint
cannot distinguish iOS from macOS, so platform is noted only where the ASC web
UI confirmed it.

**Accuracy constraint:** the fixes below are in the working tree, not in a
released build. `26.10.31` is live and predates all of them. No reply claims
anything is already fixed for the reader — they say "the next update".

---

## 1. 3★ — Ritejert01, USA, 21 Oct 2026 — **macOS** — no reply yet

> the settings section of the app is a little rough. and it is constantly
> notifiying me that my device is purging the oldest contacts… I want that, and
> I don't need to know every time it happens. For this reason I cannot use the
> app because the notification keeps popping up in the middle of the screen

**Status: root-caused and fixed.** Every purge wrote the message to the modal
error channel, so it appeared as a "Device Error" dialog, one per contact.

### Draft

> You were right, and it was worse than cosmetic: that message was being sent
> through the error channel, so every routine purge opened a modal dialog
> titled "Device Error" — for behaviour that is completely normal and that you
> had every reason to want.
>
> The next update changes it. Purges are now coalesced into a single, brief
> banner that dismisses itself and never blocks the window, and there is a
> Contact Housekeeping switch under Settings → Notifications to silence it
> entirely. The radio keeps making room either way.
>
> Thank you for describing it precisely enough to find — "pops up in the middle
> of the screen" is what identified it as the modal path rather than a
> notification setting.

---

## 2. 2★ — Cmckay2, USA, 11 May 2026 — replied once, no answer since

> Can't seem to hold the correct frequency. Set it to correct preset and save.
> Reports frequency correctly. Then after a few Bluetooth disconnects it resets
> back to 906.

**Status: root-caused and fixed**, six months on, and the reviewer never had to
supply the details the previous reply asked for — the bug was findable from the
description alone.

Cause: `DeviceConfig.reset()` runs on every disconnect and restored the
frequency to a hard-coded 906 MHz, while the radio settings screen treated only
`0` as "unknown". So after a reconnect the screen showed a plausible 906.000 as
though the radio had reported it, and Apply wrote that back.

### Draft

> This was a real bug in the app, not your hardware, and you described it
> accurately enough that it should not have taken this long — apologies for
> that.
>
> On every Bluetooth disconnect the app reset its stored radio settings to
> built-in defaults, one of which was 906 MHz. The settings screen could not
> tell those defaults apart from values the radio had actually reported, so
> opening Radio settings after a reconnect showed 906.000 as if it were real —
> and applying wrote it to the radio, along with default bandwidth, spreading
> factor and coding rate.
>
> In the next update, unknown settings are marked as genuinely unknown, and
> Apply is disabled until the app has read the real configuration from your
> radio. It can no longer write back a setting it never received.
>
> Thank you for the report, and for persisting with it.

---

## 3. 5★ — puma1409, Germany, 1 Nov 2026 — already replied; reviewer confirmed fixed

The reviewer's own updates say the battery reading was their mistake and that
notifications now work ("6. Stern"). **Nothing is outstanding except the map
request**, so a reply is optional — it would only acknowledge that.

Open request: show only already-discovered repeaters on the map. Not built.

### Draft (optional — German, matching the existing reply)

> Danke für die Updates — schön, dass die Benachrichtigungen jetzt greifen.
>
> Dein Wunsch zur Karte ist nicht vergessen: nur bereits entdeckte Repeater
> anzuzeigen, statt alles. Das ist noch nicht gebaut, steht aber auf der Liste.
> Ich melde mich, wenn es so weit ist.

---

## 4. 5★ — "Muy animado con PommeCore", Colombia, 10 Sep 2026 — **reply is mis-targeted**

The review asks whether a message can show **which type of repeater relayed it**,
rather than just "REPETIDO" in the footer.

The published reply answers something else entirely — it announces Spanish
localization and asks the reviewer two questions about battery percentage and
Apple Watch sync, neither of which they raised. It also carries terminal
formatting (stray leading spaces, a long run of trailing whitespace). It reads
as if it were pasted from another context.

**Recommend replacing it.** A `PATCH` to the existing
`customerReviewResponses` resource edits in place.

### Draft replacement (Spanish)

> Gracias por la sugerencia, y disculpa — la respuesta anterior a tu reseña no
> correspondía a lo que preguntaste.
>
> Sobre tu idea: hoy el pie del mensaje solo indica que fue repetido, sin decir
> qué nodo lo replicó. El protocolo sí incluye la ruta que siguió el mensaje, y
> en la última versión esa ruta ya se dibuja en el mapa de la malla, con cada
> salto coloreado según la calidad de la señal. Mostrar el tipo de repetidor
> junto al mensaje es un paso más y lo tengo anotado.

---

## Not replying

The four remaining 5★ reviews (Blackdogreview ×2, Flaschengeier, Tazmadman,
umushs) are general praise; three already have replies.
