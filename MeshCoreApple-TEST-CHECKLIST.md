# MeshCoreApple — Complete Testing Checklist

**Version:** 1.0.0 (Build 1)
**Date:** March 15, 2026
**Hardware:** Heltec Mesh Pocket (Companion FW v1.14.0)
**Platforms:** macOS, iPhone (iOS)

Mark each test: ✅ Pass | ❌ Fail (note issue) | ⏭️ Skipped (reason)

---

## 0. CRITICAL — iPhone Navigation

Test these FIRST. If these fail, iPhone is unusable.

| # | Test | iPhone | Notes |
|---|------|--------|-------|
| 0.1 | Tap a chat contact in sidebar → chat view pushes in | ⬜ | |
| 0.2 | Back button returns to sidebar from chat | ⬜ | |
| 0.3 | Tap a channel in sidebar → channel chat opens | ⬜ | |
| 0.4 | Tap a repeater in sidebar → login or management opens | ⬜ | |
| 0.5 | Tap a room server → login flow or chat opens | ⬜ | |
| 0.6 | Tap "Device Settings" row in sidebar → settings view opens | ⬜ | |
| 0.7 | Back navigation works from every pushed view | ⬜ | |

---

## 1. BLE Connection Lifecycle

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 1.1 | App launches, scans for MeshCore- devices | ⬜ | ⬜ | |
| 1.2 | Tap device to connect → "Connected — [name]" | ⬜ | ⬜ | |
| 1.3 | Broadcast icon sends advertisement (NOT disconnect) | ⬜ | ⬜ | |
| 1.4 | Status bar tap when connected → device info popover | ⬜ | ⬜ | |
| 1.5 | Status bar tap when disconnected → scanner opens | ⬜ | ⬜ | |
| 1.6 | Disconnect button cleanly disconnects | ⬜ | ⬜ | |
| 1.7 | After disconnect → auto-scan starts after 2s | ⬜ | ⬜ | |
| 1.8 | Turn off radio → reconnect attempts (3x) → then scan | ⬜ | ⬜ | |
| 1.9 | Walk out of BLE range then return → auto-reconnects | | ⬜ | |
| 1.10 | Background 5 min → receive message → notification | | ⬜ | |
| 1.11 | Background 20 min → receive message → notification | | ⬜ | |
| 1.12 | Background 60 min → check if BLE still connected | | ⬜ | |
| 1.13 | Force-quit app → relaunch → state restoration reconnects | | ⬜ | |

---

## 2. Messaging

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 2.1 | Send DM → shows pending → sent ✓ → delivered ✓✓ | ⬜ | ⬜ | |
| 2.2 | Receive DM → orange incoming bubble displayed | ⬜ | ⬜ | |
| 2.3 | Incoming bubble readable in light mode (soft peach + black text) | ⬜ | ⬜ | |
| 2.4 | Incoming bubble readable in dark mode (warm orange + black text) | ⬜ | ⬜ | |
| 2.5 | Outgoing bubble readable in light mode (soft mint + black text) | ⬜ | ⬜ | |
| 2.6 | Outgoing bubble readable in dark mode (medium green + black text) | ⬜ | ⬜ | |
| 2.7 | Send public channel message (idx 0) | ⬜ | ⬜ | |
| 2.8 | Send non-public channel message → correct channel idx used | ⬜ | ⬜ | |
| 2.9 | Receive channel message → appears in correct channel | ⬜ | ⬜ | |
| 2.10 | Message timestamps show correctly (relative time) | ⬜ | ⬜ | |
| 2.11 | Date separators between message groups (Today, Yesterday) | ⬜ | ⬜ | |
| 2.12 | Character count shows at 160 chars, red when over | ⬜ | ⬜ | |
| 2.13 | Copy message text (right-click / long-press → Copy) | ⬜ | ⬜ | |
| 2.14 | .textSelection(.enabled) works on message bubbles | ⬜ | ⬜ | |
| 2.15 | Send on Return key | ⬜ | ⬜ | |
| 2.16 | Failed message shows red ! and "Tap to retry" | ⬜ | ⬜ | |
| 2.17 | Retry actually resends the message | ⬜ | ⬜ | |
| 2.18 | Keyboard doesn't cover input field | | ⬜ | |
| 2.19 | Scroll dismisses keyboard | | ⬜ | |

---

## 3. Contacts & Favourites

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 3.1 | Contacts sync on connect | ⬜ | ⬜ | |
| 3.2 | Contact type icons correct (person/antenna/server/sensor) | ⬜ | ⬜ | |
| 3.3 | Contact type icon colors correct (blue/green/purple/orange) | ⬜ | ⬜ | |
| 3.4 | Last seen relative time shows under contacts | ⬜ | ⬜ | |
| 3.5 | Path info shows (direct / X hops) | ⬜ | ⬜ | |
| 3.6 | Star a contact → star icon appears → moves to top | ⬜ | ⬜ | |
| 3.7 | Unstar a contact → star removed → normal sort | ⬜ | ⬜ | |
| 3.8 | Disconnect + reconnect → favourites persist (read from radio) | ⬜ | ⬜ | |
| 3.9 | Swipe-to-favourite on contact row | | ⬜ | |
| 3.10 | Send flood advertisement → new contacts appear automatically | ⬜ | ⬜ | |
| 3.11 | Multiple rapid adverts → debounced sync (no flicker) | ⬜ | ⬜ | |
| 3.12 | Contacts don't disappear during remote admin | ⬜ | ⬜ | |
| 3.13 | Contact context menu has all actions | ⬜ | ⬜ | |

---

## 4. Nicknames

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 4.1 | Right-click/long-press contact → "Set Nickname" | ⬜ | ⬜ | |
| 4.2 | Enter nickname → Save → nickname replaces adv_name in sidebar | ⬜ | ⬜ | |
| 4.3 | Original adv_name shows in small text below nickname | ⬜ | ⬜ | |
| 4.4 | Nickname shows in chat header | ⬜ | ⬜ | |
| 4.5 | Nickname shows in notifications | ⬜ | ⬜ | |
| 4.6 | "Edit Nickname" shows current nickname pre-filled | ⬜ | ⬜ | |
| 4.7 | "Remove Nickname" clears nickname → adv_name shows again | ⬜ | ⬜ | |
| 4.8 | Nicknames persist across app restarts | ⬜ | ⬜ | |
| 4.9 | Nicknames persist across disconnect/reconnect | ⬜ | ⬜ | |
| 4.10 | Nickname sheet shows original name and public key prefix | ⬜ | ⬜ | |

---

## 5. Channels

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 5.1 | Public channel shows megaphone icon, first in section | ⬜ | ⬜ | |
| 5.2 | Hashtag channels show # icon, no double hash | ⬜ | ⬜ | |
| 5.3 | Private channels show lock icon, no # prefix | ⬜ | ⬜ | |
| 5.4 | Channel sync completes (all channels appear) | ⬜ | ⬜ | |
| 5.5 | Channel messages use correct index (not hardcoded 0) | ⬜ | ⬜ | |

---

## 6. Room Server & Repeater Management

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 6.1 | Room server chat shows name in header | ⬜ | ⬜ | |
| 6.2 | Room server requires login before messaging | ⬜ | ⬜ | |
| 6.3 | Login with password → success → input enables | ⬜ | ⬜ | |
| 6.4 | "Remember Password" saves to Keychain | ⬜ | ⬜ | |
| 6.5 | Next visit → password auto-fills | ⬜ | ⬜ | |
| 6.6 | Auto-login fires on tap (skips login sheet) | ⬜ | ⬜ | |
| 6.7 | Wrong password → stale credential deleted → manual login | ⬜ | ⬜ | |
| 6.8 | "Forget Saved Password" clears credential | ⬜ | ⬜ | |
| 6.9 | Sidebar icons: lock (no creds) / key (saved) / unlocked (logged in) | ⬜ | ⬜ | |
| 6.10 | Remote management settings populate after login | ⬜ | ⬜ | |
| 6.11 | Radio presets picker available in remote management | ⬜ | ⬜ | |
| 6.12 | Apply preset fills remote radio params field | ⬜ | ⬜ | |
| 6.13 | Change a setting and apply → written to device | ⬜ | ⬜ | |
| 6.14 | Permission-based UI (admin sees more than guest) | ⬜ | ⬜ | |
| 6.15 | CLI terminal shows command/response pairs | ⬜ | ⬜ | |
| 6.16 | Settings fields readable in dark mode (primary text, visible fields) | ⬜ | ⬜ | |
| 6.17 | Settings fields readable in light mode | ⬜ | ⬜ | |

---

## 7. Radio Presets & BLE PIN

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 7.1 | Presets picker appears in local settings | ⬜ | ⬜ | |
| 7.2 | Select "USA/Canada (Recommended)" → shows freq/BW/SF/CR | ⬜ | ⬜ | |
| 7.3 | "Apply Preset" fills radio params field | ⬜ | ⬜ | |
| 7.4 | "Apply Radio Settings" sends to device | ⬜ | ⬜ | |
| 7.5 | Presets grouped by region | ⬜ | ⬜ | |
| 7.6 | "Custom" option shows when no preset selected | ⬜ | ⬜ | |
| 7.7 | BLE PIN field shows current PIN | ⬜ | ⬜ | |
| 7.8 | "Randomize PIN" generates random 6-digit number | ⬜ | ⬜ | |
| 7.9 | Apply PIN shows confirmation dialog (warns about re-pairing) | ⬜ | ⬜ | |
| 7.10 | PIN change writes to device | ⬜ | ⬜ | |

---

## 8. Network Tools

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 8.1 | Trace route to multi-hop contact → visual trace with SNR | ⬜ | ⬜ | |
| 8.2 | Trace route to direct neighbor → "no hops" message | ⬜ | ⬜ | |
| 8.3 | Request status from repeater → response displayed | ⬜ | ⬜ | |
| 8.4 | Request status from chat node → warning + timeout | ⬜ | ⬜ | |
| 8.5 | Request telemetry from sensor → data displayed | ⬜ | ⬜ | |
| 8.6 | Show path → "Direct" or "X hops: [hex IDs]" | ⬜ | ⬜ | |
| 8.7 | Discover → falls back to flood advert → shows results | ⬜ | ⬜ | |
| 8.8 | All activity timeouts dismiss cleanly with result message | ⬜ | ⬜ | |
| 8.9 | Contextual messages by node type (status/telemetry) | ⬜ | ⬜ | |

---

## 9. Notifications & Badges

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 9.1 | Notification permission requested on first launch | | ⬜ | |
| 9.2 | DM received in background → notification fires | | ⬜ | |
| 9.3 | Channel message in background → notification fires | | ⬜ | |
| 9.4 | Room server message in background → notification fires | | ⬜ | |
| 9.5 | Toggle "Direct Messages" off → DM notification suppressed | | ⬜ | |
| 9.6 | Toggle "Channel Messages" off → channel notification suppressed | | ⬜ | |
| 9.7 | Toggle "Room Server Messages" off → room notification suppressed | | ⬜ | |
| 9.8 | Notification shows nickname (not raw adv_name) | | ⬜ | |
| 9.9 | Unread badge on contact in sidebar | ⬜ | ⬜ | |
| 9.10 | Badge clears when contact chat is opened | ⬜ | ⬜ | |
| 9.11 | App icon badge shows total unread count | | ⬜ | |
| 9.12 | App icon badge clears when all messages are read | | ⬜ | |
| 9.13 | Badge count updates when new message arrives in background | | ⬜ | |

---

## 10. Theme & Visual Design

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 10.1 | Theme picker in settings (System / Light / Dark) | ⬜ | ⬜ | |
| 10.2 | "System" follows OS setting | ⬜ | ⬜ | |
| 10.3 | Manual light mode — all text readable | ⬜ | ⬜ | |
| 10.4 | Manual dark mode — all text readable | ⬜ | ⬜ | |
| 10.5 | Labels match icon color (green accent) | ⬜ | ⬜ | |
| 10.6 | Green buttons/badges have black text (both modes) | ⬜ | ⬜ | |
| 10.7 | Incoming bubbles: soft peach (light) / warm orange (dark) | ⬜ | ⬜ | |
| 10.8 | Outgoing bubbles: soft mint (light) / medium green (dark) | ⬜ | ⬜ | |
| 10.9 | Text fields readable in both modes (visible borders, primary text) | ⬜ | ⬜ | |
| 10.10 | Settings values readable (primary color, not secondary) | ⬜ | ⬜ | |
| 10.11 | Empty states show guidance (no blank screens) | ⬜ | ⬜ | |
| 10.12 | App icon visible on home screen (bright, recognizable at 60x60) | | ⬜ | |
| 10.13 | Settings help text/footers readable in both modes | ⬜ | ⬜ | |
| 10.14 | Confirmation dialogs on reboot and factory reset | ⬜ | ⬜ | |
| 10.15 | Adaptive accent: deep emerald (light) / bright green (dark) | ⬜ | ⬜ | |
| 10.16 | Interactive green (buttons/badges): soft mint (light) / medium green (dark) | ⬜ | ⬜ | |

---

## 11. Toolbar & Navigation

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 11.1 | Broadcast icon → sends advertisement + confirmation | ⬜ | ⬜ | |
| 11.2 | Settings gear → opens settings | ⬜ | ⬜ | |
| 11.3 | Remote management wrench → only visible when logged in | ⬜ | ⬜ | |
| 11.4 | Refresh → re-syncs contacts and channels | ⬜ | ⬜ | |
| 11.5 | Tooltips on hover (macOS) | ⬜ | | |
| 11.6 | Accessibility labels on all toolbar buttons | | ⬜ | |
| 11.7 | Settings accessible from sidebar on iPhone | | ⬜ | |

---

## 12. Edge Cases & Stress

| # | Test | Mac | iPhone | Notes |
|---|------|-----|--------|-------|
| 12.1 | Receive message while in settings/management | ⬜ | ⬜ | |
| 12.2 | Multiple rapid advertisements → debounced sync | ⬜ | ⬜ | |
| 12.3 | Very long message (close to 160 chars) | ⬜ | ⬜ | |
| 12.4 | Message at exactly 160 chars → sends | ⬜ | ⬜ | |
| 12.5 | Message at 161 chars → blocked by UI | ⬜ | ⬜ | |
| 12.6 | Contact with empty adv_name → shows pubkey prefix | ⬜ | ⬜ | |
| 12.7 | Contact with nickname + empty adv_name → shows nickname | ⬜ | ⬜ | |
| 12.8 | Switch theme while connected → smooth, no state loss | ⬜ | ⬜ | |
| 12.9 | Low battery on radio → display updates | ⬜ | ⬜ | |
| 12.10 | Contact storage full notification (0x90) | ⬜ | ⬜ | |
| 12.11 | Contact deleted notification (0x8F) | ⬜ | ⬜ | |
| 12.12 | Set nickname → disconnect → reconnect → nickname persists | ⬜ | ⬜ | |
| 12.13 | Set nickname → force-quit → relaunch → nickname persists | ⬜ | ⬜ | |
| 12.14 | Rotate iPhone (if not locked to portrait) | | ⬜ | |
| 12.15 | Apply radio preset → verify radio params changed on device | ⬜ | ⬜ | |
| 12.16 | Change BLE PIN → re-pair with new PIN | ⬜ | ⬜ | |

---

## Test Summary

| Section | Total Tests | Passed | Failed | Skipped |
|---------|------------|--------|--------|---------|
| 0 — iPhone Navigation | 7 | | | |
| 1 — BLE Connection | 13 | | | |
| 2 — Messaging | 19 | | | |
| 3 — Contacts & Favourites | 13 | | | |
| 4 — Nicknames | 10 | | | |
| 5 — Channels | 5 | | | |
| 6 — Room Server & Repeater | 17 | | | |
| 7 — Radio Presets & BLE PIN | 10 | | | |
| 8 — Network Tools | 9 | | | |
| 9 — Notifications & Badges | 13 | | | |
| 10 — Theme & Visual | 16 | | | |
| 11 — Toolbar & Navigation | 7 | | | |
| 12 — Edge Cases | 16 | | | |
| **TOTAL** | **155** | | | |

---

## Bug Log

Record any failures here with details:

| Test # | Description | Severity | Screenshot | Fix Status |
|--------|-------------|----------|------------|------------|
| | | | | |
| | | | | |
| | | | | |

Severity: 🔴 Blocker | 🟡 Major | 🟢 Minor | 💅 Cosmetic
